#!/usr/bin/env bash

# ===== Infrastructure: Kafka + ClickHouse =====

# ── Kafka cluster ────────────────────────────────────────────────────────────
log "Installing Kafka cluster..."
ensure_strimzi_operator
require_crd "kafkas.kafka.strimzi.io"
KAFKA_CHART="${MIDAS_PROJECT_ROOT}/MidasCore/KafkaStrimzi"
if [[ -f "${KAFKA_CHART}/Chart.yaml" ]]; then
  KAFKA_CMD="helm upgrade --install kafka-cluster ${KAFKA_CHART} \
    -n kafka --create-namespace \
    --atomic --timeout 10m"
else
  KAFKA_CMD="helm upgrade --install kafka-cluster midas-edge/KafkaStrimzi \
    -n kafka --create-namespace \
    --version ${CHART_VERSION} \
    --atomic --timeout 10m"
fi

# Use smart upgrade: handles type-mismatch errors (cpu: number vs string),
# stuck releases, and immutable field changes automatically.
if ! helm_smart_upgrade "kafka-cluster" "kafka" "$KAFKA_CMD" 3; then
  log "WARN: Smart upgrade failed — attempting nuclear reinstall of kafka-cluster"
  log "WARN: This will delete all Kafka resources. PVCs are preserved (deleteClaim: false)."
  helm_nuke_release "kafka-cluster" "kafka" "$KAFKA_CMD"
fi

# ── ClickHouse cluster ───────────────────────────────────────────────────────
log "Installing ClickHouse cluster..."
ATLAS_SCHEMA_ENABLED="false"
if [[ "${MIDAS_ENABLE_ATLAS:-false}" == "true" || -n "${MIDAS_ATLAS_TOKEN:-}" ]]; then
  ATLAS_SCHEMA_ENABLED="true"
fi

CLICKHOUSE_CHART="${MIDAS_PROJECT_ROOT}/MidasCore/ClickhouseAltiniti"
if [[ -f "${CLICKHOUSE_CHART}/Chart.yaml" ]]; then
  CH_CMD="helm upgrade --install clickhouse-cluster ${CLICKHOUSE_CHART} \
    -n clickhouse --create-namespace \
    --set atlasSchema.enabled=${ATLAS_SCHEMA_ENABLED} \
    --atomic --timeout 10m"
else
  CH_CMD="helm upgrade --install clickhouse-cluster midas-edge/ClickhouseAltiniti \
    -n clickhouse --create-namespace \
    --version ${CHART_VERSION} \
    --set atlasSchema.enabled=${ATLAS_SCHEMA_ENABLED} \
    --atomic --timeout 10m"
fi

if ! helm_smart_upgrade "clickhouse-cluster" "clickhouse" "$CH_CMD" 3; then
  log "WARN: Smart upgrade failed — attempting nuclear reinstall of clickhouse-cluster"
  helm_nuke_release "clickhouse-cluster" "clickhouse" "$CH_CMD"
fi
