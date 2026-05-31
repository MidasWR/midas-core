#!/usr/bin/env bash

# ===== External IP detection =====
EXTERNAL_IP="$(resolve_midas_node_ip)"

if [[ -z "${EXTERNAL_IP}" ]]; then
  err "Failed to resolve node IP. Set MIDAS_EXTERNAL_IP explicitly."
  exit 1
fi
export MIDAS_RESOLVED_EXTERNAL_IP="${EXTERNAL_IP}"

log "Node external IP: $EXTERNAL_IP"

if helm status logger-services -n midas >/dev/null 2>&1; then
    log "Release logger-services already exists. Skipping 120s sleep."
else
    log "Waiting 120s for infrastructure to settle..."
    sleep 120
fi

log "Installing MidasCore services..."
MIDAS_SERVICES_CHART="${MIDAS_PROJECT_ROOT}/MidasCore/LoggerServices"
if [[ -f "${MIDAS_SERVICES_CHART}/Chart.yaml" ]]; then
  MIDAS_CMD="helm upgrade --install logger-services ${MIDAS_SERVICES_CHART} \
    -n midas --create-namespace \
    --set Tag=${MIDAS_TAG} \
    --set ExternalIP=${EXTERNAL_IP} \
    --timeout 10m \
    --wait=false"
else
  MIDAS_CMD="helm upgrade --install logger-services midas-edge/MidasCoreServices \
    -n midas --create-namespace \
    --version ${CHART_VERSION} \
    --set Tag=${MIDAS_TAG} \
    --set ExternalIP=${EXTERNAL_IP} \
    --timeout 10m \
    --wait=false"
fi

helm_smart_upgrade "logger-services" "midas" "$MIDAS_CMD" 3

kubectl -n midas get pods -o wide












