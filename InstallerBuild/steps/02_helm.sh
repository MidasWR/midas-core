#!/usr/bin/env bash

# ===== helm =====
case ":$PATH:" in *:/usr/local/bin:*) ;; *) export PATH="/usr/local/bin:$PATH";; esac
if ! command -v helm >/dev/null 2>&1; then
  log "Installing Helm..."
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

# ===== namespaces =====
for n in kafka clickhouse monitoring midas cert-manager; do ns "$n"; done

rm -f ~/.cache/helm/repository/midas-edge* 2>/dev/null || true

# ===== helm repos =====
log "Adding Helm repositories..."
helm repo add strimzi https://strimzi.io/charts/ || true
helm repo add altinity https://helm.altinity.com || true
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts || true
helm repo add jetstack https://charts.jetstack.io || true
helm repo add midas-edge https://midaswr.github.io/midas-edge-charts || true
helm repo add longhorn https://charts.longhorn.io || true

# Ensure Gateway API CRDs exist before Envoy Gateway starts.
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.0/standard-install.yaml
kubectl wait --for=condition=Established crd/gatewayclasses.gateway.networking.k8s.io --timeout=60s || true
kubectl wait --for=condition=Established crd/httproutes.gateway.networking.k8s.io      --timeout=60s || true

# Install Envoy Gateway with retry + recovery.
#
# Why this is fragile on single-node k3s:
#   The certgen pre-upgrade hook creates a Job + RoleBinding. On a busy
#   kube-apiserver the POST to rolebindings.rbac.authorization.k8s.io can
#   time out ("server was unable to return a response in the time allotted")
#   even if the object is eventually created. We mitigate by:
#     1. Pre-creating the namespace so the first hook attempt has less to do.
#     2. Cleaning up any leftover certgen Job/RoleBinding from a prior failed
#        attempt — otherwise the hook fails on "already exists".
#     3. Forcing HTTP/1.1 (GODEBUG=http2client=0) to avoid http2 connection drops.
#     4. Using 6 retries with the 100s API-stabilisation wait in Recovery 4.

ns envoy-gateway-system

# Remove leftover certgen artifacts from any prior failed attempt so hooks
# don't fail with "resource already exists".
kubectl delete job -n envoy-gateway-system \
  -l "app.kubernetes.io/managed-by=Helm,helm.sh/chart=gateway-helm" \
  --ignore-not-found --wait=false 2>/dev/null || true
kubectl delete rolebinding,clusterrolebinding -n envoy-gateway-system \
  -l "app.kubernetes.io/managed-by=Helm,helm.sh/chart=gateway-helm" \
  --ignore-not-found 2>/dev/null || true

# Give API server a moment after the deletes before the install attempt.
sleep 5; wait_api

export GODEBUG=http2client=0
helm_smart_upgrade "eg" "envoy-gateway-system" \
  "helm upgrade --install eg oci://docker.io/envoyproxy/gateway-helm \
    --version v1.7.0 \
    -n envoy-gateway-system \
    --create-namespace \
    --wait --timeout 10m" 6
unset GODEBUG

helm repo update
# ===== defaults =====
ensure_default_sc

# ===== Vertical Pod Autoscaler =====
if [[ ! -d autoscaler ]]; then
  git clone https://github.com/kubernetes/autoscaler.git
fi
# shellcheck disable=SC2164
cd autoscaler/vertical-pod-autoscaler

# CRDs
kubectl apply -f deploy/vpa-v1-crd-gen.yaml

# components
# We check if vpa is already up to avoid unnecessary restart or errors
if ! kubectl get pods -n kube-system | grep -q 'vpa-recommender'; then
    ./hack/vpa-up.sh
else
    log "VPA already installed"
fi

# check
kubectl get pods -n kube-system | grep -E 'vpa-|vertical' || true

cd - >/dev/null 2>&1 || true

