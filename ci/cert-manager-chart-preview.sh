#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT_DIR"

BASE_REF=${BASE_REF:-${PULL_BASE_SHA:-}}
if [[ -z $BASE_REF ]]; then
  echo "ℹ️  Skipping cert-manager chart preview (set BASE_REF or run in a Prow PR job)"
  exit 0
fi
git rev-parse --verify "$BASE_REF^{commit}" >/dev/null

SUBMODULE_PATH=argocd/config/shared/cert-manager/upstream
CHART_PATH=deploy/charts/cert-manager
COMPONENT_DIR=argocd/config/shared/cert-manager
SUBMODULE_DIR="$ROOT_DIR/$SUBMODULE_PATH"

gitlink_sha() {
  local treeish=$1
  git ls-tree "$treeish" -- "$SUBMODULE_PATH" | awk '$1 == "160000" && $2 == "commit" { print $3 }'
}

old_sha=$(gitlink_sha "$BASE_REF")
new_sha=$(gitlink_sha HEAD)
if [[ -z $old_sha || -z $new_sha ]]; then
  echo "ℹ️  Skipping chart preview until both $BASE_REF and HEAD contain the cert-manager submodule"
  exit 0
fi
if [[ $old_sha == "$new_sha" ]]; then
  echo "ℹ️  cert-manager submodule unchanged; skipping chart preview"
  exit 0
fi

echo "🔎 cert-manager submodule update: $old_sha -> $new_sha"

if [[ ! -e "$SUBMODULE_DIR/.git" ]]; then
  git submodule update --init "$SUBMODULE_PATH"
fi
for sha in "$old_sha" "$new_sha"; do
  if ! git -C "$SUBMODULE_DIR" cat-file -e "$sha^{commit}" 2>/dev/null; then
    git -C "$SUBMODULE_DIR" fetch --no-tags --depth=1 origin "$sha"
  fi
done

if git -C "$SUBMODULE_DIR" diff --quiet "$old_sha" "$new_sha" -- "$CHART_PATH"; then
  echo "ℹ️  The submodule moved, but $CHART_PATH is unchanged; this is not a cert-manager chart update."
  exit 0
fi

echo "📦 Upstream chart files changed:"
git -C "$SUBMODULE_DIR" diff --stat "$old_sha" "$new_sha" -- "$CHART_PATH"
git -C "$SUBMODULE_DIR" diff --name-status "$old_sha" "$new_sha" -- "$CHART_PATH"

tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

prepare_chart_tree() {
  local sha=$1
  local destination=$2

  mkdir -p "$destination"
  tar -C "$COMPONENT_DIR" --exclude='./upstream' -cf - . | tar -C "$destination" -xf -
  mkdir -p "$destination/upstream"
  git -C "$SUBMODULE_DIR" archive "$sha" | tar -C "$destination/upstream" -xf -
}

prepare_chart_tree "$old_sha" "$tmp_dir/old"
prepare_chart_tree "$new_sha" "$tmp_dir/new"

echo "🧪 Rendering old chart with current values and Kustomize patches..."
kubectl kustomize --enable-helm "$tmp_dir/old" > "$tmp_dir/old-rendered.yaml"
echo "🧪 Rendering new chart with current values and Kustomize patches..."
kubectl kustomize --enable-helm "$tmp_dir/new" > "$tmp_dir/new-rendered.yaml"

echo "📄 Rendered manifest diff (old chart -> new chart, after patches):"
set +e
git diff --no-index --no-ext-diff -- "$tmp_dir/old-rendered.yaml" "$tmp_dir/new-rendered.yaml"
diff_status=$?
set -e
if [[ $diff_status -eq 0 ]]; then
  echo "No rendered manifest changes after Kustomize patches."
elif [[ $diff_status -ne 1 ]]; then
  exit "$diff_status"
fi
