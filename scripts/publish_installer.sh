#!/usr/bin/env bash
set -Eeuo pipefail

TAG="${TAG:-test}"

# Где лежит Go-проект инсталлера
INSTALLER_DIR="${INSTALLER_DIR:-InstallerBuild}"
BUILD_TARGET="${BUILD_TARGET:-.}"

# Куда собирать
BIN_NAME="${BIN_NAME:-installer}"

# Куда публиковать релиз/ассет
REPO="${REPO:-MidasWR/midas-core-installer}"
BRANCH="${BRANCH:-}" # не нужно, просто оставлено на будущее

log(){ printf "\033[1;36m[INFO]\033[0m %s\n" "$*"; }
err(){ printf "\033[1;31m[ERR ]\033[0m %s\n" "$*"; }

need() { command -v "$1" >/dev/null 2>&1 || { err "Missing dependency: $1"; exit 1; }; }

need go
need gh

if [[ ! -d "$INSTALLER_DIR" ]]; then
  err "INSTALLER_DIR not found: $INSTALLER_DIR"
  exit 1
fi

# Вшиваем тег прямо в бинарь (в Go должен быть var BuildTag string в package main)
LDFLAGS="${LDFLAGS:--s -w -X main.BuildTag=${TAG}}"

log "Using TAG=$TAG"
log "Building installer from: ${INSTALLER_DIR} (${BUILD_TARGET})"
log "LDFLAGS: ${LDFLAGS}"

pushd "$INSTALLER_DIR" >/dev/null

OUT="./${BIN_NAME}"
rm -f "$OUT"

# --- build with garble if possible, otherwise fallback to go build ---
if command -v garble >/dev/null 2>&1; then
  log "garble detected, trying obfuscated build..."
  set +e
  garble build -o "$OUT" -ldflags "$LDFLAGS" "$BUILD_TARGET"
  GARBLE_RC=$?
  set -e

  if [[ $GARBLE_RC -ne 0 ]]; then
    err "garble build failed (rc=$GARBLE_RC). Falling back to go build..."
    go build -o "$OUT" -ldflags "$LDFLAGS" "$BUILD_TARGET"
  fi
else
  log "garble not found, using go build..."
  go build -o "$OUT" -ldflags "$LDFLAGS" "$BUILD_TARGET"
fi

chmod +x "$OUT"
log "Built: $(pwd)/$BIN_NAME"
ls -lah "$OUT"

popd >/dev/null

ASSET_PATH="${INSTALLER_DIR}/${BIN_NAME}"

log "Publishing installer to GitHub Releases"
log "Repo: ${REPO}"
log "Tag:  ${TAG}"
log "Asset: ${ASSET_PATH} -> ${BIN_NAME}"

# релиз создаём если его нет, иначе просто заливаем asset с перезаписью
if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  log "Release exists. Uploading asset (clobber)..."
  gh release upload "$TAG" "$ASSET_PATH#${BIN_NAME}" --clobber --repo "$REPO"
else
  log "Release not found. Creating..."
  gh release create "$TAG" "$ASSET_PATH#${BIN_NAME}" \
    --title "$TAG" \
    --notes "Release $TAG" \
    --repo "$REPO"
fi

log "✅ Installer published successfully"
