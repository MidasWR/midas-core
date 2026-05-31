#!/usr/bin/env bash

# ===== ServiceMonitor for Midas =====
wait_crd "servicemonitors.monitoring.coreos.com"
wait_crd "prometheusrules.monitoring.coreos.com"

kubectl apply -f - <<'YAML'
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: midas-services-sm
  namespace: monitoring
  labels:
    release: kube-prom
spec:
  namespaceSelector:
    matchNames: ["midas"]
  selector:
    matchLabels:
      metrics-enabled: "true"
  endpoints:
    - port: http
      path: /metrics
      interval: 15s
YAML

# Label all Go services that expose /metrics so Prometheus scrapes them
for svc in \
  log-gateway-src \
  log-event-src \
  log-analyse-src \
  log-llm-gpt-src \
  log-auth-src \
  log-agent-scaler-src \
  log-control-plane-src \
  log-sys-info-src \
  log-setting-src; do
  kubectl -n midas label svc "${svc}" metrics-enabled=true --overwrite 2>/dev/null || \
    log "WARN: service ${svc} not found yet, skipping label"
done

# ===== ServiceMonitor for Kafka Exporter (consumer lag metrics) =====
log "Creating ServiceMonitor for Kafka Exporter..."
kubectl apply -f - <<'YAML'
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: kafka-exporter-sm
  namespace: monitoring
  labels:
    release: kube-prom
spec:
  namespaceSelector:
    matchNames: ["kafka"]
  selector:
    matchLabels:
      strimzi.io/kind: Kafka
  endpoints:
    - port: tcp-prometheus
      path: /metrics
      interval: 30s
YAML

# ===== ServiceMonitor for cert-manager =====
log "Creating ServiceMonitor for cert-manager..."
kubectl apply -f - <<'YAML'
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: cert-manager-sm
  namespace: monitoring
  labels:
    release: kube-prom
spec:
  namespaceSelector:
    matchNames: ["cert-manager"]
  selector:
    matchLabels:
      app.kubernetes.io/name: cert-manager
      app.kubernetes.io/component: controller
  endpoints:
    - port: http-metrics
      path: /metrics
      interval: 60s
YAML

# ===== AlertManager: route critical midas/kafka/clickhouse alerts to a receiver =====
# We patch the kube-prometheus-stack AlertManager config with additional routes.
# This is additive — the default "null" routes for Watchdog etc. are preserved.
ALERTMANAGER_SECRET="alertmanager-kube-prom-kube-prometheus-alertmanager"

log "Checking if AlertManager secret exists..."
if kubectl -n monitoring get secret "${ALERTMANAGER_SECRET}" >/dev/null 2>&1; then
  log "AlertManager secret found. Patching with Midas alert routes..."

  # Decode existing config, inject midas routes, re-encode and patch
  EXISTING_CFG=$(kubectl -n monitoring get secret "${ALERTMANAGER_SECRET}" \
    -o jsonpath='{.data.alertmanager\.yaml}' | base64 -d 2>/dev/null || echo "")

  # Only patch if it doesn't already have midas routes (idempotent)
  if ! echo "${EXISTING_CFG}" | grep -q "midas-critical"; then
    NEW_CFG=$(cat <<'AMCFG'
global:
  resolve_timeout: 5m

route:
  group_by: ['alertname', 'namespace']
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 4h
  receiver: 'null'
  routes:
    # Critical infrastructure alerts — Kafka, ClickHouse, service CrashLoops
    - receiver: 'midas-critical'
      group_wait: 10s
      group_interval: 1m
      repeat_interval: 30m
      matchers:
        - severity = "critical"
        - team = "midas"
    # Watchdog heartbeat (kube-prometheus default)
    - receiver: 'null'
      matchers:
        - alertname = "Watchdog"

receivers:
  - name: 'null'
  # Replace webhook_url with your actual notification endpoint
  # (Slack, PagerDuty, email, etc.) after deployment.
  - name: 'midas-critical'
    webhook_configs:
      - url: 'http://log-gateway-src.midas.svc.cluster.local:8060/api/alerts/webhook'
        send_resolved: true
        http_config:
          follow_redirects: true

inhibit_rules:
  - source_matchers:
      - severity = "critical"
    target_matchers:
      - severity = "warning"
    equal: ['alertname', 'namespace']
AMCFG
    )

    ENCODED=$(echo "${NEW_CFG}" | base64 -w 0)
    kubectl -n monitoring patch secret "${ALERTMANAGER_SECRET}" \
      --type='merge' \
      -p "{\"data\":{\"alertmanager.yaml\":\"${ENCODED}\"}}" \
      && log "AlertManager config patched successfully." \
      || log "WARN: Failed to patch AlertManager config — configure manually."
  else
    log "AlertManager already contains midas routes, skipping patch."
  fi
else
  log "WARN: AlertManager secret not found. Prometheus/Grafana may not be installed yet."
fi

# ===== ClickHouse schema =====
log "Applying ClickHouse schema..."

CH_POD="chi-log-c-clickhouse-main-0-0-0"
CH_NS="clickhouse"
ATLAS_SCHEMA_ENABLED="false"
if [[ "${MIDAS_ENABLE_ATLAS:-false}" == "true" || -n "${MIDAS_ATLAS_TOKEN:-}" ]]; then
  ATLAS_SCHEMA_ENABLED="true"
fi

apply_clickhouse_schema_direct() {
  kubectl -n "$CH_NS" exec "$CH_POD" -- clickhouse-client --multiquery --query "
CREATE DATABASE IF NOT EXISTS logs ENGINE = Atomic;

CREATE TABLE IF NOT EXISTS logs.event_logs_local
(
    timestamp     DateTime64(3) DEFAULT now64(3),
    severity      Int32,
    severity_text String,
    body          String,
    trace_id      String,
    span_id       String,
    attributes    Map(String,String),
    project       String
)
ENGINE = ReplacingMergeTree()
PARTITION BY toYYYYMM(timestamp)
ORDER BY (project, timestamp, trace_id)
TTL toDateTime(timestamp) + INTERVAL 7 DAY DELETE;

CREATE TABLE IF NOT EXISTS logs.event_logs
AS logs.event_logs_local
ENGINE = Distributed('main', 'logs', 'event_logs_local', rand());
"
}

# Attempt to force-detach a Longhorn volume that is stuck "in use".
# Called when mke2fs refuses to format the device because it is still
# held open by a stale Longhorn frontend/engine from a previous install.
#
# Flow:
#   1. Resolve PVC → PV name (= Longhorn volume name)
#   2. Patch the Longhorn volume spec.nodeID="" to trigger force-detach
#   3. Wait up to 90 s for the volume state to become "detached"
#   4. Force-delete the stuck pod so the StatefulSet recreates it fresh
remediate_longhorn_stuck_volume() {
  local pod="$1" ns="$2"

  log "Longhorn FailedMount detected — attempting force-detach remediation..."

  local pvc
  pvc="$(kubectl -n "$ns" get pod "$pod" \
         -o jsonpath='{.spec.volumes[?(@.persistentVolumeClaim.claimName)].persistentVolumeClaim.claimName}' \
         2>/dev/null | awk '{print $1}')"

  if [[ -z "$pvc" ]]; then
    err "Could not resolve PVC name from pod $ns/$pod — manual remediation required."
    return 1
  fi
  log "PVC: $pvc"

  local lh_vol
  lh_vol="$(kubectl -n "$ns" get pvc "$pvc" -o jsonpath='{.spec.volumeName}' 2>/dev/null)"
  if [[ -z "$lh_vol" ]]; then
    err "Could not resolve Longhorn volume name from PVC $ns/$pvc — manual remediation required."
    return 1
  fi
  log "Longhorn volume: $lh_vol"

  # Request force-detach by clearing the target node
  if kubectl -n longhorn-system patch volume "$lh_vol" \
      --type=merge -p '{"spec":{"nodeID":""}}' 2>/dev/null; then
    log "Force-detach patch applied to Longhorn volume $lh_vol"
  else
    log "WARN: Could not patch Longhorn volume directly (may not be installed in longhorn-system)."
    log "Trying alternative: delete the VolumeAttachment for the PV..."
    local va
    va="$(kubectl get volumeattachment -o json \
          | jq -r --arg pv "$lh_vol" \
            '.items[] | select(.spec.source.persistentVolumeName==$pv) | .metadata.name' \
          2>/dev/null | head -1)"
    if [[ -n "$va" ]]; then
      kubectl delete volumeattachment "$va" --timeout=30s 2>/dev/null \
        && log "VolumeAttachment $va deleted" \
        || log "WARN: Could not delete VolumeAttachment $va"
    else
      log "WARN: No VolumeAttachment found for $lh_vol"
    fi
  fi

  # Wait for Longhorn to confirm the volume is detached
  log "Waiting up to 90 s for Longhorn volume $lh_vol to detach..."
  for i in {1..18}; do
    local state
    state="$(kubectl -n longhorn-system get volume "$lh_vol" \
              -o jsonpath='{.status.state}' 2>/dev/null || echo "unknown")"
    if [[ "$state" == "detached" || "$state" == "" || "$state" == "unknown" ]]; then
      log "Longhorn volume is detached (state=$state). Proceeding."
      break
    fi
    log "Longhorn volume state=$state ($i/18) — waiting 5 s..."
    sleep 5
  done

  # Force-delete the stuck pod so the StatefulSet immediately recreates it
  log "Force-deleting stuck pod $ns/$pod for StatefulSet to recreate..."
  kubectl -n "$ns" delete pod "$pod" --force --grace-period=0 2>/dev/null \
    && log "Pod deleted." \
    || log "WARN: delete pod returned non-zero (may already be gone)."

  sleep 10
}

# 1) Wait until pod exists
for i in {1..30}; do
  if kubectl -n "$CH_NS" get pod "$CH_POD" >/dev/null 2>&1; then
    break
  fi
  log "Waiting for ClickHouse pod to appear... ($i/30)"
  sleep 5
done

# 2) Wait until pod is Ready — with automatic Longhorn FailedMount remediation
if ! kubectl -n "$CH_NS" wait --for=condition=Ready "pod/$CH_POD" --timeout=300s; then

  # Check whether the failure is the known Longhorn "in use" mount error
  MOUNT_ERR="$(kubectl -n "$CH_NS" get events \
    --field-selector "involvedObject.name=${CH_POD}" \
    -o jsonpath='{range .items[?(@.reason=="FailedMount")]}{.message}{"\n"}{end}' \
    2>/dev/null | head -5)"

  if echo "$MOUNT_ERR" | grep -qiE "will not make a filesystem here|FailedMount|MountVolume.MountDevice failed"; then
    remediate_longhorn_stuck_volume "$CH_POD" "$CH_NS"

    # Wait for the pod to reappear after force-deletion
    for i in {1..30}; do
      kubectl -n "$CH_NS" get pod "$CH_POD" >/dev/null 2>&1 && break
      log "Waiting for ClickHouse pod to reappear after remediation... ($i/30)"
      sleep 5
    done

    # Retry with an extended timeout
    log "Retrying ClickHouse pod readiness (600 s)..."
    if ! kubectl -n "$CH_NS" wait --for=condition=Ready "pod/$CH_POD" --timeout=600s; then
      kubectl -n "$CH_NS" get pod "$CH_POD" -o wide || true
      kubectl -n "$CH_NS" describe pod "$CH_POD" || true
      err "ClickHouse pod is not Ready after Longhorn remediation"
      exit 1
    fi
  else
    kubectl -n "$CH_NS" get pod "$CH_POD" -o wide || true
    kubectl -n "$CH_NS" describe pod "$CH_POD" || true
    err "ClickHouse pod is not Ready"
    exit 1
  fi
fi

# 3) Apply schema (Atlas optional)
if [[ "${ATLAS_SCHEMA_ENABLED}" == "true" ]]; then
  log "Waiting for Atlas Schema to be applied..."
  if ! kubectl -n "$CH_NS" wait --for=condition=Ready atlasschema/midas-logs-schema --timeout=300s; then
    kubectl -n "$CH_NS" describe atlasschema midas-logs-schema || true
    log "Atlas Schema is not Ready, applying schema directly via clickhouse-client..."
    if ! apply_clickhouse_schema_direct; then
      err "Atlas Schema failed and direct schema apply failed"
      exit 1
    fi
  fi
else
  log "Atlas Schema disabled, applying schema directly via clickhouse-client..."
  if ! apply_clickhouse_schema_direct; then
    err "Direct schema apply failed"
    exit 1
  fi
fi

if ! kubectl -n "$CH_NS" exec "$CH_POD" -- clickhouse-client --query "EXISTS TABLE logs.event_logs" | grep -q "^1$"; then
  err "Schema verification failed: logs.event_logs table not found"
  exit 1
fi
log "ClickHouse schema applied successfully."

kubectl -n midas get certificate,issuer,clusterissuer || true

# ===== sysctl / limits =====
if [[ "${MIDAS_UPDATE_MODE:-false}" != "true" ]]; then
    sysctl -w net.netfilter.nf_conntrack_max=1048576 || log "WARN: Failed to set sysctl"
    sysctl -w net.ipv4.tcp_max_syn_backlog=262144 || log "WARN: Failed to set sysctl"
    sysctl -w net.core.somaxconn=65535 || log "WARN: Failed to set sysctl"
    sysctl -w net.core.netdev_max_backlog=16384 || log "WARN: Failed to set sysctl"
    ulimit -n 262144 || log "WARN: Failed to set ulimit"

    if ! grep -q "soft nofile 262144" /etc/security/limits.conf; then
        echo "* soft nofile 262144" >> /etc/security/limits.conf
    fi
    if ! grep -q "hard nofile 262144" /etc/security/limits.conf; then
        echo "* hard nofile 262144" >> /etc/security/limits.conf
    fi
else
    log "Skipping sysctl/limits in Update Mode"
fi
