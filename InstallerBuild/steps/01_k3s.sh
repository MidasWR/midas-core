#!/usr/bin/env bash


# ===== install k3s if missing =====
if ! command -v k3s >/dev/null 2>&1; then
  log "Installing k3s..."
  curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--write-kubeconfig-mode=0644 --disable traefik" sh -s -
  log "Waiting for API server..."
  for i in {1..100}; do
    k3s kubectl get --raw=/version >/dev/null 2>&1 && break
    sleep 2
  done
else
  log "k3s already installed"
fi












