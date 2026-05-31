#!/usr/bin/env bash

# ===== Operators =====
log "Installing Strimzi Kafka Operator..."
# Memory limits are set explicitly to prevent OOMKill — the default operator limits
# are often too low on single-node clusters, causing silent reconciliation failures.
ensure_strimzi_operator

log "Installing Altinity ClickHouse Operator..."
helm_retry "helm upgrade --install altinity-clickhouse-operator altinity/altinity-clickhouse-operator -n clickhouse --create-namespace --wait --atomic --timeout 10m"
wait_crd "clickhouseinstallations.clickhouse.altinity.com"

log "Installing Atlas Operator..."
ATLAS_ENABLED="${MIDAS_ENABLE_ATLAS:-false}"
if [[ -n "${MIDAS_ATLAS_TOKEN:-}" ]]; then
  ATLAS_ENABLED="true"
fi

if [[ "${ATLAS_ENABLED}" == "true" ]]; then
  if [[ -z "${MIDAS_ATLAS_TOKEN:-}" ]]; then
    err "MIDAS_ENABLE_ATLAS=true requires MIDAS_ATLAS_TOKEN to be set"
    exit 1
  fi

  kubectl -n atlas-system create secret generic atlas-token-secret \
    --from-literal=ATLAS_TOKEN="${MIDAS_ATLAS_TOKEN}" \
    --dry-run=client -o yaml | kubectl apply -f -

  helm_retry "helm upgrade --install atlas-operator oci://ghcr.io/ariga/charts/atlas-operator \
    -n atlas-system --create-namespace \
    --set extraEnvs[0].name=ATLAS_TOKEN \
    --set extraEnvs[0].valueFrom.secretKeyRef.name=atlas-token-secret \
    --set extraEnvs[0].valueFrom.secretKeyRef.key=ATLAS_TOKEN \
    --wait --atomic --timeout 10m"
  wait_crd "atlasschemas.db.atlasgo.io"
else
  log "Skipping Atlas Operator (set MIDAS_ENABLE_ATLAS=true and MIDAS_ATLAS_TOKEN to enable)"
fi

# ===================== Longhorn =====================
log "Installing Longhorn..."
helm upgrade --install longhorn longhorn/longhorn \
  -n longhorn-system --create-namespace \
  --set defaultSettings.defaultReplicaCount=1 \
  --set persistence.defaultClassReplicaCount=1 \
  --set defaultSettings.defaultLonghornStaticStorageClass=true \
  --wait --atomic --timeout 10m

# Wait for longhorn-manager pods
kubectl -n longhorn-system wait --for=condition=ready pod -l app=longhorn-manager --timeout=600s

# ============== Ensure Longhorn disk path exists on nodes ==============
# Longhorn won't schedule disks if the path doesn't exist.
LONGHORN_DISK_PATH="${LONGHORN_DISK_PATH:-/var/lib/longhorn}"
# normalize trailing slash to avoid /path vs /path/
LONGHORN_DISK_PATH="${LONGHORN_DISK_PATH%/}"

log "Ensuring Longhorn disk path exists on all nodes: ${LONGHORN_DISK_PATH}"

kubectl apply -f - <<YAML
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: longhorn-disk-prepare
  namespace: longhorn-system
spec:
  selector:
    matchLabels:
      app: longhorn-disk-prepare
  template:
    metadata:
      labels:
        app: longhorn-disk-prepare
    spec:
      hostPID: true
      tolerations:
        - operator: Exists
      containers:
        - name: prepare
          image: busybox:1.36
          securityContext:
            privileged: true
          command:
            - sh
            - -c
            - |
              set -e
              mkdir -p /host${LONGHORN_DISK_PATH}
              chmod 700 /host${LONGHORN_DISK_PATH}
              echo "prepared /host${LONGHORN_DISK_PATH}"
              sleep 3600
          volumeMounts:
            - name: host
              mountPath: /host
      volumes:
        - name: host
          hostPath:
            path: /
YAML

kubectl -n longhorn-system rollout status ds/longhorn-disk-prepare --timeout=300s

# ============== Patch Longhorn Node CRs to add disk ==============
log "Patching Longhorn nodes to add disk path: ${LONGHORN_DISK_PATH}"

# wait until Node CRs exist
for i in {1..60}; do
  if kubectl -n longhorn-system get nodes.longhorn.io >/dev/null 2>&1; then
    break
  fi
  log "Waiting for Longhorn node CRs... ($i/60)"
  sleep 2
done

# Helper: patch with retries when Longhorn is syncing disks.
# IMPORTANT: Never patch /spec/disks as a whole. Only patch a single key.
patch_longhorn_node_disk() {
  local node="$1"
  local disk_key="$2"

  for attempt in {1..60}; do
    local out patch_json

    # 1) Try to add ONLY our disk key (doesn't touch existing disks)
    patch_json="$(
      cat <<JSON
[
  { "op": "add", "path": "/spec/disks/${disk_key}", "value": {
      "path": "${LONGHORN_DISK_PATH}",
      "allowScheduling": true,
      "storageReserved": 0,
      "tags": []
  }}
]
JSON
    )"

    out="$(kubectl -n longhorn-system patch nodes.longhorn.io "${node}" --type='json' -p "${patch_json}" 2>&1)" && {
      log "   patched OK: ${node} -> ${disk_key}=${LONGHORN_DISK_PATH}"
      return 0
    }

    # 2) If spec.disks doesn't exist yet, create it (only if missing), then retry add.
    if echo "$out" | grep -Eqi 'missing path|does not exist|no such path|cannot add.*spec/disks'; then
      # This add is safe ONLY when /spec/disks is missing.
      # If it already exists, kubectl will error and we ignore.
      kubectl -n longhorn-system patch nodes.longhorn.io "${node}" --type='json' \
        -p='[{"op":"add","path":"/spec/disks","value":{}}]' >/dev/null 2>&1 || true

      out="$(kubectl -n longhorn-system patch nodes.longhorn.io "${node}" --type='json' -p "${patch_json}" 2>&1)" && {
        log "   patched OK: ${node} -> ${disk_key}=${LONGHORN_DISK_PATH}"
        return 0
      }
    fi

    # 3) If the key exists already, replace it (idempotent)
    if echo "$out" | grep -Eqi 'already exists|cannot add'; then
      patch_json="$(
        cat <<JSON
[
  { "op": "replace", "path": "/spec/disks/${disk_key}", "value": {
      "path": "${LONGHORN_DISK_PATH}",
      "allowScheduling": true,
      "storageReserved": 0,
      "tags": []
  }}
]
JSON
      )"
      out="$(kubectl -n longhorn-system patch nodes.longhorn.io "${node}" --type='json' -p "${patch_json}" 2>&1)" && {
        log "   patched (replace) OK: ${node} -> ${disk_key}=${LONGHORN_DISK_PATH}"
        return 0
      }
    fi

    # 4) Longhorn webhook sync gate: retry with backoff
    if echo "$out" | grep -qi 'being syncing and please retry later'; then
      log "   Longhorn is syncing disks for ${node}, retrying... (${attempt}/60)"
      sleep 5
      continue
    fi

    # 5) Any other error: stop for this node
    log "   patch failed for ${node}: $out"
    return 1
  done

  log "   patch timed out for ${node} (still syncing?)"
  return 1
}

# After patch, wait until disk appears in status.diskStatus (Longhorn recognized it)
wait_longhorn_disk_status() {
  local node="$1"
  local path="$2"

  for attempt in {1..120}; do
    # In some Longhorn versions diskStatus is a map, in others it behaves like a list.
    # We just grep the YAML for the path as a pragmatic approach.
    if kubectl -n longhorn-system get nodes.longhorn.io "${node}" -o yaml 2>/dev/null | grep -Fq "path: ${path}"; then
      log "   diskStatus looks present on ${node} for path ${path}"
      return 0
    fi
    log "   waiting diskStatus on ${node} (${attempt}/120)"
    sleep 5
  done

  log "   diskStatus still not ready on ${node} for path ${path}"
  return 1
}

# Use unique disk key derived from path (avoid collisions with default-disk-*)
disk_key="disk-$(echo "${LONGHORN_DISK_PATH}" | tr '/.' '--' | tr -cd 'a-zA-Z0-9-_')"

# patch all nodes
while read -r n; do
  [[ -z "$n" ]] && continue
  log " - patching longhorn node: $n"
  if patch_longhorn_node_disk "$n" "$disk_key"; then
    wait_longhorn_disk_status "$n" "${LONGHORN_DISK_PATH}" || true
  fi
done < <(kubectl -n longhorn-system get nodes.longhorn.io -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')

# sanity: show disks
kubectl -n longhorn-system get nodes.longhorn.io -o yaml | sed -n '1,220p'

# optional: remove prepare DS later (or keep it harmlessly)
# kubectl -n longhorn-system delete ds/longhorn-disk-prepare --ignore-not-found

# ===================== Prometheus + Grafana =====================
log "Installing Prometheus + Grafana (Grafana enabled: ${MIDAS_ENABLE_GRAFANA:-false})..."

GRAFANA_ARGS="--set grafana.enabled=false"
if [[ "${MIDAS_ENABLE_GRAFANA:-false}" == "true" ]]; then
  GRAFANA_ARGS="--set grafana.enabled=true \
  --set grafana.adminPassword='prom-operator' \
  --set grafana.service.type=NodePort \
  --set grafana.service.nodePort=32000"
fi

helm_retry "helm upgrade --install kube-prom prometheus-community/kube-prometheus-stack \
  -n monitoring --create-namespace \
  ${GRAFANA_ARGS} \
  --wait --atomic --timeout 15m
"

log ">>> Operators gate: final Strimzi check before infrastructure deploy"
ensure_strimzi_operator
