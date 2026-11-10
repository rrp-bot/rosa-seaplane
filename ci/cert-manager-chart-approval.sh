#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT_DIR"

BASE_REF=${BASE_REF:-${PULL_BASE_SHA:-}}
CANDIDATE_REF=${CANDIDATE_REF:-${PULL_PULL_SHA:-HEAD}}
if [[ -z $BASE_REF ]]; then
  echo "❌ Set PULL_BASE_SHA in Prow or BASE_REF when running locally."
  exit 2
fi
git rev-parse --verify "$BASE_REF^{commit}" >/dev/null
git rev-parse --verify "$CANDIDATE_REF^{commit}" >/dev/null

SUBMODULE_PATH=argocd/config/shared/cert-manager/upstream

gitlink_sha() {
  local treeish=$1
  git ls-tree "$treeish" -- "$SUBMODULE_PATH" | awk '$1 == "160000" && $2 == "commit" { print $3 }'
}

old_sha=$(gitlink_sha "$BASE_REF")
new_sha=$(gitlink_sha "$CANDIDATE_REF")
if [[ $old_sha == "$new_sha" ]]; then
  echo "ℹ️  No cert-manager submodule pin change; skipping chart approval check."
  exit 0
fi
if [[ -z $old_sha || -z $new_sha ]]; then
  echo "❌ The cert-manager chart submodule was added or removed; manual review is required."
  exit 1
fi

echo "🔎 Cert-manager submodule changed: $old_sha -> $new_sha"
BASE_REF=$BASE_REF \
  CANDIDATE_REF=$CANDIDATE_REF \
  REQUIRE_CHART_APPROVAL=1 \
  make cert-manager-chart-preview
