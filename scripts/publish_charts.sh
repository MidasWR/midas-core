#!/usr/bin/env bash
set -euo pipefail

# ========= Config =========
TAG="${TAG:-test}"

# Where your chart sources live (directories containing Chart.yaml)
CHARTS_SRC_DIR="${CHARTS_SRC_DIR:-MidasCore}"

# Output dir for packaged charts and index.yaml (local workspace)
DIST_DIR="${DIST_DIR:-.charts_dist}"

# Git repo where index.yaml and tgz are hosted (your charts repo)
CHARTS_REPO_URL="${CHARTS_REPO_URL:-git@github.com:midaswr/midas-edge-charts.git}"

# Branch to push to (commonly gh-pages for chart repos)
CHARTS_REPO_BRANCH="${CHARTS_REPO_BRANCH:-gh-pages}"

# Public URL used in index.yaml (must match your Pages URL)
CHARTS_REPO_PUBLIC_URL="${CHARTS_REPO_PUBLIC_URL:-https://midaswr.github.io/midas-edge-charts}"

# ========= Helpers =========
need() { command -v "$1" >/dev/null 2>&1 || { echo "❌ Missing dependency: $1"; exit 1; }; }

# Strict SemVer for Helm chart version (supports prerelease like 1.0.0-a, 1.0.0-alpha.1)
# Allowed:
# - 1.2.3
# - 1.2.3-a
# - 1.2.3-alpha.1
# - 1.2.3-rc.1
# Not allowed: leading "v" (keep it clean) and build metadata "+" (optional, but we keep it strict).
chart_version_from_tag_strict() {
  local tag="$1"

  if [[ "$tag" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z]+(\.[0-9A-Za-z]+)*)?$ ]]; then
    echo "$tag"
    return 0
  fi

  echo "❌ TAG must be semver like 1.0.0 or 1.0.0-a or 1.0.0-alpha.1 (got: $tag)" >&2
  exit 1
}

# ========= Main =========
need git
need helm

echo "✅ Charts publish only. Services are NOT touched."
echo "Using TAG=${TAG}"

CHART_VERSION="$(chart_version_from_tag_strict "$TAG")"
APP_VERSION="$TAG"

echo "Resolved:"
echo "  CHART_VERSION=${CHART_VERSION}"
echo "  APP_VERSION=${APP_VERSION}"
echo

# Fresh workspace
rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"

# Clone charts repo
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

echo "📥 Cloning charts repo: ${CHARTS_REPO_URL} (branch: ${CHARTS_REPO_BRANCH})"
git clone --depth 1 --branch "$CHARTS_REPO_BRANCH" "$CHARTS_REPO_URL" "$WORKDIR/repo"

REPO_DIR="$WORKDIR/repo"

# Package charts from source directory
if [[ ! -d "$CHARTS_SRC_DIR" ]]; then
  echo "❌ CHARTS_SRC_DIR not found: $CHARTS_SRC_DIR"
  exit 1
fi

echo "📦 Packaging charts from: $CHARTS_SRC_DIR (overwrite mode)"
shopt -s nullglob
found_any=false

for chart_dir in "$CHARTS_SRC_DIR"/*; do
  if [[ -d "$chart_dir" && -f "$chart_dir/Chart.yaml" ]]; then
    found_any=true
    name="$(basename "$chart_dir")"
    tgz="${name}-${CHART_VERSION}.tgz"

    echo ">>> Packaging ${name} -> version ${CHART_VERSION} (overwrite if exists)"

    # Overwrite mode:
    # Remove old chart archive with same version from both repo and dist
    rm -f "$REPO_DIR/$tgz"
    rm -f "$DIST_DIR/$tgz"

    helm package "$chart_dir" \
      --destination "$DIST_DIR" \
      --version "$CHART_VERSION" \
      --app-version "$APP_VERSION"
  fi
done

if [[ "$found_any" == false ]]; then
  echo "❌ No charts found in ${CHARTS_SRC_DIR} (expected subdirs with Chart.yaml)"
  exit 1
fi

echo
echo "🧾 Updating index.yaml (overwrite mode)"
cp -f "$DIST_DIR"/*.tgz "$REPO_DIR/"

# Rebuild index in repo root
helm repo index "$REPO_DIR" --url "$CHARTS_REPO_PUBLIC_URL"

echo
echo "🔎 Sanity check (repo root):"
ls -lah "$REPO_DIR" | sed -n '1,160p'

echo
echo "📤 Committing & pushing to charts repo (charts + index)"
cd "$REPO_DIR"

git add -A

if git diff --cached --quiet; then
  echo "ℹ️ Nothing to publish (no changes)."
  exit 0
fi

git commit -m "chore(charts): republish ${CHART_VERSION} (tag=${TAG})"
git push origin "$CHARTS_REPO_BRANCH"

echo
echo "✅ Done. Republished charts version: ${CHART_VERSION}"
echo "Repo URL base: ${CHARTS_REPO_PUBLIC_URL}"
