#!/usr/bin/env bash
set -Eeuo pipefail

log(){  printf "\033[1;36m[INFO]\033[0m %s\n" "$*"; }
warn(){ printf "\033[1;33m[WARN]\033[0m %s\n" "$*"; }
err(){  printf "\033[1;31m[ERR ]\033[0m %s\n" "$*"; }

# -------------------------
# APT/DPKG lock handling
# -------------------------
now_s(){ date +%s; }

fmt_dur() {
  local s="${1:-0}"
  local h=$((s/3600)) m=$(((s%3600)/60)) ss=$((s%60))
  if (( h>0 )); then printf "%dh %02dm %02ds" "$h" "$m" "$ss"
  elif (( m>0 )); then printf "%dm %02ds" "$m" "$ss"
  else printf "%ds" "$ss"
  fi
}

with_timer() {
  local title="$1"; shift
  local start; start="$(now_s)"

  ( "$@" ) &
  local pid=$!

  while kill -0 "$pid" 2>/dev/null; do
    local elapsed=$(( $(now_s) - start ))
    printf "\r\033[1;36m[WAIT]\033[0m %s: %s" "$title" "$(fmt_dur "$elapsed")"
    sleep 1
  done

  wait "$pid"
  local rc=$?
  local total=$(( $(now_s) - start ))
  if (( rc == 0 )); then
    printf "\r\033[1;32m[DONE]\033[0m %s: %s\033[K\n" "$title" "$(fmt_dur "$total")"
  else
    printf "\r\033[1;31m[FAIL]\033[0m %s: %s\033[K\n" "$title" "$(fmt_dur "$total")"
  fi
  return "$rc"
}

is_debian_like() {
  command -v apt-get >/dev/null 2>&1 && command -v dpkg-query >/dev/null 2>&1
}

is_alpine() {
  [ -f /etc/alpine-release ]
}

is_pkg_installed() {
  if is_debian_like; then
    # True only if installed
    dpkg-query -W -f='${Status}\n' "$1" 2>/dev/null | grep -q "install ok installed"
  elif is_alpine; then
    apk info -e "$1" >/dev/null 2>&1
  else
    return 1
  fi
}

apt_locks_present() {
  fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 && return 0
  fuser /var/lib/dpkg/lock          >/dev/null 2>&1 && return 0
  fuser /var/lib/apt/lists/lock     >/dev/null 2>&1 && return 0
  fuser /var/cache/apt/archives/lock >/dev/null 2>&1 && return 0
  return 1
}

kill_apt_holders() {
  # Stop unattended upgrades if it exists
  systemctl stop unattended-upgrades >/dev/null 2>&1 || true
  systemctl stop apt-daily.service apt-daily.timer >/dev/null 2>&1 || true
  systemctl stop apt-daily-upgrade.service apt-daily-upgrade.timer >/dev/null 2>&1 || true

  # Kill common offenders (best-effort)
  pkill -9 -f unattended-upgr >/dev/null 2>&1 || true
  pkill -9 -f "apt-get|apt |aptitude" >/dev/null 2>&1 || true
  pkill -9 -f "dpkg" >/dev/null 2>&1 || true
}

force_release_apt() {
  # Dangerously effective. Exactly what you want in an installer on a fresh VPS.
  kill_apt_holders

  rm -f /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock \
        /var/lib/apt/lists/lock /var/cache/apt/archives/lock || true

  # Repair half-configured packages
  dpkg --configure -a >/dev/null 2>&1 || true
  apt-get -f install -y >/dev/null 2>&1 || true
}

wait_or_kill_apt_lock() {
  local max_wait_s="${1:-30}"
  local start; start="$(now_s)"

  while apt_locks_present; do
    local elapsed=$(( $(now_s) - start ))
    printf "\r\033[1;36m[WAIT]\033[0m Waiting for apt/dpkg lock: %s" "$(fmt_dur "$elapsed")"
    if (( elapsed >= max_wait_s )); then
      printf "\n"
      warn "apt/dpkg lock still held after ${max_wait_s}s. Forcing release..."
      force_release_apt
      return 0
    fi
    sleep 1
  done
  printf "\r\033[K"
  return 0
}

apt_safe_update_install() {
  local pkgs=("$@")

  wait_or_kill_apt_lock 30
  apt-get update -qq

  wait_or_kill_apt_lock 30
  apt-get install -y -qq "${pkgs[@]}"
}

# -------------------------
# YOUR DEPENDENCY SETUP
# -------------------------
: "${MIDAS_VERSION:?MIDAS_VERSION is required}"

MIDAS_TAG="$MIDAS_VERSION"
export MIDAS_TAG

CHART_VERSION="$(chart_version_from_tag "$MIDAS_TAG")"
export CHART_VERSION

log "Release tag (images): $MIDAS_TAG"
log "Helm chart version:   $CHART_VERSION"

if ! is_debian_like && ! is_alpine; then
  err "This dependency installer currently supports Debian/Ubuntu or Alpine Linux."
  err "If you need CentOS/RHEL support, add it explicitly."
  exit 1
fi

# IMPORTANT:
# - Only package names here (dpkg packages)
# - Don't put awk/grep here. If those are missing, the OS is basically a museum exhibit.
REQUIRED_PKGS=(jq open-iscsi nfs-common curl)
if is_alpine; then
  # Alpine mapping
  REQUIRED_PKGS=(jq open-iscsi nfs-utils curl)
fi

missing=()
for p in "${REQUIRED_PKGS[@]}"; do
  if ! is_pkg_installed "$p"; then
    missing+=("$p")
  fi
done

if (( ${#missing[@]} > 0 )); then
  log "[SETUP] Installing missing dependencies: ${missing[*]}"
  if is_debian_like; then
    apt_safe_update_install "${missing[@]}"
  elif is_alpine; then
    apk add --no-cache "${missing[@]}"
  fi
  hash -r || true
else
  log "All required dependencies already installed."
fi
