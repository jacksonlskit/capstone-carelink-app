#!/usr/bin/env bash
# =============================================================================
# Prove the app's data lives in RDS, not inside the pods
# =============================================================================
#   1. Write a new owner through the public HTTPS API.
#   2. Read it back several times: requests are spread over both
#      customers-service pods, so both must see the same database.
#   3. Delete EVERY app pod in the namespace and wait until all are back.
#   4. Read the owner again: it must still be there.
#
# With --tls it also checks encryption in transit: a MySQL client inside the
# cluster tries to connect without TLS (must be refused) and with TLS (must
# work), using the same credentials as the app.
#
# Usage:  scripts/test-db-persistence.sh <staging|production> [--tls]
# Needs:  curl, jq, and kubectl pointed at that environment's cluster.
#
# The test owner (last name "PersistTest<timestamp>") is left in the database
# on purpose: it is synthetic data and shows up in the UI as evidence.
# =============================================================================
set -euo pipefail

ENVIRONMENT=${1:?usage: test-db-persistence.sh <staging|production> [--tls]}
CHECK_TLS=${2:-}
case "$ENVIRONMENT" in staging | production) ;; *) echo "unknown environment: $ENVIRONMENT" >&2; exit 2 ;; esac

BASE="https://carelink-${ENVIRONMENT}.sctp-sandbox.com/api/customer/owners"
NS="$ENVIRONMENT"
LAST_NAME="PersistTest$(date +%s)"

step() { printf '\n== %s\n' "$*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

read_owner() { # prints the owner's last name, or nothing
  curl -sf -m 15 "$BASE/$1" | jq -r '.lastName // empty' 2>/dev/null || true
}

step "1. Create owner $LAST_NAME in $ENVIRONMENT"
ID=$(curl -sf -m 15 -X POST "$BASE" -H 'Content-Type: application/json' \
  -d "{\"firstName\":\"Persistence\",\"lastName\":\"$LAST_NAME\",\"address\":\"1 Test Street\",\"city\":\"Singapore\",\"telephone\":\"6512345678\"}" |
  jq -r '.id') || fail "could not create the owner"
[[ "$ID" =~ ^[0-9]+$ ]] || fail "unexpected response, no owner id"
echo "created owner id $ID"

step "2. Read it back 10 times (requests spread over both customers-service pods)"
for i in $(seq 1 10); do
  [[ "$(read_owner "$ID")" == "$LAST_NAME" ]] || fail "read $i did not return the owner: replicas do not share one database"
done
echo "10/10 reads returned $LAST_NAME"

step "3. Delete every app pod in namespace $NS"
kubectl -n "$NS" get pods -o name | sed 's/^/   /'
kubectl -n "$NS" delete pods --all --wait=false
sleep 10
for d in $(kubectl -n "$NS" get deploy -o name); do
  kubectl -n "$NS" rollout status "$d" --timeout=600s
done
echo "waiting for the API to answer again..."
for i in $(seq 1 60); do
  curl -sf -m 10 -o /dev/null "$BASE" && break
  sleep 5
done
kubectl -n "$NS" get pods -o wide | awk 'NR==1 || /Running/ {print "   "$1, $3, $5, $7}'

step "4. Read the owner again after all pods were replaced"
[[ "$(read_owner "$ID")" == "$LAST_NAME" ]] || fail "owner $ID is gone after the restart: data is not persistent"
echo "PASS: owner $ID ($LAST_NAME) survived the loss of every pod"

if [[ "$CHECK_TLS" == "--tls" ]]; then
  step "5. MySQL must refuse connections without TLS"
  # Runs a throwaway MySQL client pod with the app's own credentials, taken
  # from the carelink-db Secret by Kubernetes (never printed or copied here).
  OVERRIDES=$(jq -n '{
    spec: {
      restartPolicy: "Never",
      containers: [{
        name: "mysql-tls-check",
        image: "mysql:8.0",
        command: ["sh", "-c", "HOST=$(echo \"$DB_URL\" | sed -E \"s#jdbc:mysql://([^:/]+).*#\\\\1#\"); echo \"without TLS:\"; mysql -h \"$HOST\" -u \"$DB_USER\" -p\"$DB_PASS\" --ssl-mode=DISABLED -e \"SELECT 1\" 2>&1 | grep -v Warning; echo \"with TLS:\"; mysql -h \"$HOST\" -u \"$DB_USER\" -p\"$DB_PASS\" --ssl-mode=REQUIRED -N -e \"SHOW STATUS LIKE \\\"Ssl_version\\\"\" 2>&1 | grep -v Warning"],
        env: [
          {name: "DB_URL",  valueFrom: {secretKeyRef: {name: "carelink-db", key: "url"}}},
          {name: "DB_USER", valueFrom: {secretKeyRef: {name: "carelink-db", key: "username"}}},
          {name: "DB_PASS", valueFrom: {secretKeyRef: {name: "carelink-db", key: "password"}}}
        ]
      }]
    }
  }')
  OUT=$(kubectl -n "$NS" run "mysql-tls-check-$(date +%s)" --rm -i --quiet --restart=Never \
    --image=mysql:8.0 --overrides="$OVERRIDES" 2>&1) || true
  echo "$OUT" | sed 's/^/   /'
  echo "$OUT" | grep -q "insecure transport are prohibited" || fail "a connection without TLS was not refused"
  echo "$OUT" | grep -qE "Ssl_version[[:space:]]+TLS" || fail "a TLS connection did not work"
  echo "PASS: non-TLS connection refused, TLS connection works"
fi
