#!/usr/bin/env bash
# =============================================================================
# Record a deployment in Git for Argo CD
# =============================================================================
# Copies charts/carelink exactly as it is at commit <sha> onto the branch
# env/<environment> and sets global.imageTag to <sha> in values-<environment>.yaml.
# Argo CD in that environment's cluster watches env/<environment> and rolls the
# change out. Each commit on env/<environment> is one deployment, so
# `git log origin/env/production` is the production deployment history.
#
# env/* branches are written only by the pipeline (cd.yaml); people change the
# app through pull requests to main.
#
# Usage: scripts/promote.sh <staging|production> <git-sha>
# Prints the env-branch commit that Argo CD should end up on (last line).
# =============================================================================
set -euo pipefail

ENVIRONMENT=${1:?usage: promote.sh <staging|production> <git-sha>}
SHA=${2:?usage: promote.sh <staging|production> <git-sha>}
case "$ENVIRONMENT" in
  staging | production) ;;
  *) echo "unknown environment: $ENVIRONMENT" >&2; exit 2 ;;
esac

BRANCH="env/${ENVIRONMENT}"
VALUES="charts/carelink/values-${ENVIRONMENT}.yaml"
SHA=$(git rev-parse --verify --quiet "${SHA}^{commit}") || { echo "commit not found: $2" >&2; exit 1; }

WORKDIR=$(mktemp -d)
cleanup() { git worktree remove --force "$WORKDIR" >/dev/null 2>&1 || rm -rf "$WORKDIR"; }
trap cleanup EXIT

if git ls-remote --exit-code --heads origin "$BRANCH" >/dev/null; then
  git fetch --quiet origin "$BRANCH"
  git worktree add --quiet --detach "$WORKDIR" FETCH_HEAD
else
  # First deployment to this environment: start the branch with no history.
  git worktree add --quiet --detach "$WORKDIR"
  git -C "$WORKDIR" checkout --quiet --orphan "promote-${ENVIRONMENT}"
  git -C "$WORKDIR" rm -rq --cached .
  git -C "$WORKDIR" clean -fdxq
fi

# The env branch holds only the chart as it was at $SHA, plus the image tag.
rm -rf "$WORKDIR/charts"
git archive "$SHA" charts/carelink | tar -x -C "$WORKDIR"
perl -pi -e 's/^(\s*imageTag:).*/$1 "'"$SHA"'"/' "$WORKDIR/$VALUES"
grep -q "imageTag: \"$SHA\"" "$WORKDIR/$VALUES" || { echo "could not set imageTag in $VALUES" >&2; exit 1; }

git -C "$WORKDIR" add -A
if git -C "$WORKDIR" diff --cached --quiet; then
  echo "$BRANCH is already at $SHA; nothing to commit" >&2
else
  git -C "$WORKDIR" \
    -c user.name="github-actions[bot]" \
    -c user.email="41898282+github-actions[bot]@users.noreply.github.com" \
    commit --quiet \
    -m "deploy(${ENVIRONMENT}): ${SHA:0:7}" \
    -m "Chart and images from main@${SHA}." \
    -m "Triggered by ${GITHUB_ACTOR:-$(git config user.name || echo unknown)} in run ${GITHUB_SERVER_URL:-}/${GITHUB_REPOSITORY:-}/actions/runs/${GITHUB_RUN_ID:-local}."
  git -C "$WORKDIR" push --quiet origin "HEAD:refs/heads/${BRANCH}"
  echo "pushed $BRANCH" >&2
fi

git -C "$WORKDIR" rev-parse HEAD
