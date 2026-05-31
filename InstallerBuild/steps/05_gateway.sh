#!/usr/bin/env bash

# ===== Gateway API + Envoy Gateway =====
log "Installing Gateway API CRDs..."
gateway_standard_url="https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.0/standard-install.yaml"
gateway_experimental_url="https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.0/experimental-install.yaml"

tmp_apply_log="$(mktemp)"
if ! kubectl apply -f "${gateway_standard_url}" >"${tmp_apply_log}" 2>&1; then
  if grep -q 'grpcroutes.gateway.networking.k8s.io' "${tmp_apply_log}" \
    && grep -q 'storedVersions' "${tmp_apply_log}" \
    && grep -q 'v1alpha2' "${tmp_apply_log}"; then
    log "Detected legacy Gateway API storage version (v1alpha2). Falling back to experimental CRDs for safe migration."
    if ! kubectl apply -f "${gateway_experimental_url}"; then
      err "Failed to apply Gateway API experimental CRDs after migration fallback."
      rm -f "${tmp_apply_log}"
      exit 1
    fi
  else
    cat "${tmp_apply_log}"
    err "Failed to apply Gateway API standard CRDs."
    rm -f "${tmp_apply_log}"
    exit 1
  fi
fi
rm -f "${tmp_apply_log}"


# ===== cert-manager =====
log "Installing cert-manager..."
kubectl create ns cert-manager || true
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager --version v1.14.0 --set installCRDs=true \
  --wait --atomic --timeout 10m

kubectl wait --for=condition=Established crd/certificates.cert-manager.io   --timeout=180s || true
kubectl wait --for=condition=Established crd/issuers.cert-manager.io         --timeout=180s || true
kubectl wait --for=condition=Established crd/clusterissuers.cert-manager.io  --timeout=180s || true

# ===== Envoy GatewayClass binding =====
log "Ensuring Envoy Gateway controller is ready..."
# Envoy Gateway was installed in step 02; wait for it to become available.
# It may still be pulling the image or starting on slow nodes.
for _eg_wait in {1..60}; do
  if kubectl -n envoy-gateway-system get deploy/envoy-gateway >/dev/null 2>&1; then break; fi
  log "Waiting for envoy-gateway deployment to appear... (${_eg_wait}/60)"
  sleep 3
done
kubectl -n envoy-gateway-system rollout status deploy/envoy-gateway --timeout=300s || true

existing_gc_controller="$(
  kubectl get gatewayclass eg -o jsonpath='{.spec.controllerName}' 2>/dev/null || true
)"
if [[ -n "${existing_gc_controller}" && "${existing_gc_controller}" != "gateway.envoyproxy.io/gatewayclass-controller" ]]; then
  err "GatewayClass 'eg' exists with unexpected controller '${existing_gc_controller}'"
  err "Expected: gateway.envoyproxy.io/gatewayclass-controller"
  exit 1
fi

kubectl apply -f - <<'YAML'
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: eg
spec:
  controllerName: gateway.envoyproxy.io/gatewayclass-controller
YAML

log "Waiting GatewayClass 'eg' to be accepted..."
for i in {1..60}; do
  gc_status="$(kubectl get gatewayclass eg -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}' 2>/dev/null || true)"
  if [[ "${gc_status}" == "True" ]]; then
    break
  fi
  sleep 2
done
if [[ "$(kubectl get gatewayclass eg -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}' 2>/dev/null || true)" != "True" ]]; then
  kubectl describe gatewayclass eg || true
  err "GatewayClass 'eg' is not accepted by Envoy Gateway controller"
  exit 1
fi












