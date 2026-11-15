#!/usr/bin/env bash
# =============================================================================
# Wait until Argo CD has applied a deployment and the app is healthy
# =============================================================================
# Succeeds when the Application is Synced to <revision> (the env-branch commit
# that scripts/promote.sh printed) and Argo CD reports it Healthy, which
# includes every Deployment having finished its rollout. Fails after
# <timeout-seconds> and prints the Application status, so a bad deployment
# turns the pipeline red instead of passing silently.
#
# Usage: scripts/wait-for-argocd.sh <application> <revision> [timeout-seconds]
# Needs kubectl pointed at the environment's cluster.
# =============================================================================
set -euo pipefail

APP=${1:?usage: wait-for-argocd.sh <application> <revision> [timeout-seconds]}
REVISION=${2:?usage: wait-for-argocd.sh <application> <revision> [timeout-seconds]}
TIMEOUT=${3:-900}
NS=argocd

kubectl -n "$NS" get application "$APP" >/dev/null

# Ask Argo CD to look at Git now instead of at its next 3-minute poll.
kubectl -n "$NS" annotate application "$APP" argocd.argoproj.io/refresh=normal --overwrite >/dev/null

deadline=$((SECONDS + TIMEOUT))
while ((SECONDS < deadline)); do
  IFS='|' read -r rev sync health phase <<<"$(kubectl -n "$NS" get application "$APP" \
    -o jsonpath='{.status.sync.revision}|{.status.sync.status}|{.status.health.status}|{.status.operationState.phase}')"
  echo "$(date -u +%T) revision=${rev:0:7} sync=${sync:-?} health=${health:-?} operation=${phase:-none}"
  if [[ "$rev" == "$REVISION" && "$sync" == "Synced" && "$health" == "Healthy" ]]; then
    echo "$APP is Synced and Healthy at ${REVISION:0:7}"
    exit 0
  fi
  sleep 10
done

echo "Timed out after ${TIMEOUT}s waiting for $APP to be Synced and Healthy at ${REVISION:0:7}" >&2
kubectl -n "$NS" get application "$APP" -o jsonpath='{.status.conditions}{"\n"}{.status.operationState.message}{"\n"}' >&2 || true
kubectl -n "$NS" get application "$APP" -o jsonpath='{range .status.resources[?(@.health.status!="Healthy")]}{.kind}/{.name}: {.health.status} {.health.message}{"\n"}{end}' >&2 || true
exit 1
