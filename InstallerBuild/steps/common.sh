#!/usr/bin/env bash

log(){ printf "\033[1;36m[INFO]\033[0m %s\n" "$*"; }
err(){ printf "\033[1;31m[ERR ]\033[0m %s\n" "$*"; }

chart_version_from_tag() {
  local tag="$1"
  local ts; ts="$(date -u +%Y%m%d%H%M%S)"

  if [[ "$tag" == ":test" || "$tag" == "test" ]]; then
    echo "0.0.0-test.${ts}"
    return
  fi

  if [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([.-].*)?$ ]]; then
    echo "${tag#v}"
    return
  fi

  if [[ "$tag" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-].*)?$ ]]; then
    echo "$tag"
    return
  fi

  local safe="${tag//[^A-Za-z0-9.-]/-}"
  echo "0.0.0-${safe}.${ts}"
}

ns(){
  kubectl get ns "$1" >/dev/null 2>&1 || kubectl create ns "$1"
}

has_crd(){
  kubectl get crd "$1" >/dev/null 2>&1
}

wait_crd(){
  local crd="$1"
  local timeout="${2:-180s}"
  log "Waiting for CRD: $crd (timeout=${timeout})"
  if ! kubectl wait --for=condition=Established "crd/${crd}" --timeout="${timeout}"; then
    err "CRD not established: ${crd}"
    return 1
  fi
}

require_crd(){
  local crd="$1"
  if has_crd "$crd"; then
    return 0
  fi
  err "Required CRD missing: ${crd}"
  return 1
}

ensure_strimzi_operator(){
  local crd="kafkas.kafka.strimzi.io"

  if has_crd "$crd" \
    && kubectl -n kafka get deployment strimzi-cluster-operator >/dev/null 2>&1 \
    && kubectl -n kafka wait deployment/strimzi-cluster-operator --for=condition=Available --timeout=30s >/dev/null 2>&1; then
    log "Strimzi operator already healthy — skipping helm upgrade"
    wait_crd "$crd" 60s
    return 0
  fi

  if has_crd "$crd"; then
    log "Strimzi CRD present — installing/upgrading operator..."
  else
    log "Strimzi CRD missing — installing Strimzi Kafka Operator..."
  fi

  helm_retry "helm upgrade --install strimzi-operator strimzi/strimzi-kafka-operator \
    -n kafka --create-namespace \
    --set resources.requests.cpu=200m \
    --set resources.requests.memory=384Mi \
    --set resources.limits.cpu=1000m \
    --set resources.limits.memory=768Mi \
    --wait --atomic --timeout 10m"

  wait_crd "$crd" 300s

  log "Waiting for Strimzi cluster operator deployment..."
  kubectl -n kafka rollout status deployment/strimzi-cluster-operator --timeout=300s
}

wait_api(){
  log "Checking API server availability..."
  for i in {1..120}; do
    kubectl get --raw=/version >/dev/null 2>&1 && return 0
    sleep 2
  done
  err "Kubernetes API is not available"; exit 1
}

# ── helm_retry: dumb retry, for transient errors only ──────────────────────
helm_retry() {
  local cmd="$1"; local tries="${2:-6}"
  local tmp; tmp="$(mktemp)"
  for i in $(seq 1 "$tries"); do
    if eval "$cmd" >"$tmp" 2>&1; then
      rm -f "$tmp"; return 0
    fi
    log "[retry $i/$tries] helm busy/failed, retrying in 8s..."
    tail -n 15 "$tmp" || true
    sleep 8; wait_api
  done
  err "helm command did not succeed after ${tries} attempts"
  tail -n 30 "$tmp" || true
  rm -f "$tmp"; return 1
}

# ── helm_smart_upgrade: recovery-aware helm upgrade ────────────────────────
# Handles the most common fatal failure modes automatically:
#
#  1. Release in failed/pending state                    → helm rollback, then retry
#  2. "cannot patch" / type mismatch / number            → retry with --force
#  3. Immutable field change                             → retry with --force
#  4. http2/connection reset/EOF (transient API blip)    → wait_api + rollback + retry
#  5. pre-upgrade/pre-install hook failure               → rollback + retry with --no-hooks
#  6. Persistent failures                                → helm_nuke_release (nuclear option)
#
# Usage: helm_smart_upgrade <release> <namespace> <helm-upgrade-cmd> [tries]
#
helm_smart_upgrade() {
  local release="$1"
  local ns="$2"
  local cmd="$3"
  local tries="${4:-3}"
  local tmp; tmp="$(mktemp)"
  local attempt_force=false

  _helm_release_status() {
    helm status "$release" -n "$ns" -o json 2>/dev/null \
      | grep -o '"status":"[^"]*"' | grep -o '[^"]*"$' | tr -d '"' \
      || echo "unknown"
  }

  for i in $(seq 1 "$tries"); do
    log "[smart-upgrade $i/$tries] Running: ${cmd:0:120}..."

    if eval "$cmd" >"$tmp" 2>&1; then
      rm -f "$tmp"; return 0
    fi

    local out; out="$(cat "$tmp")"
    log "[smart-upgrade $i/$tries] FAILED. Error analysis:"
    tail -n 25 "$tmp" || true

    # ── Recovery 1: release stuck in failed/pending-upgrade ──────────────
    local status; status="$(_helm_release_status)"
    if [[ "$status" == "failed" || "$status" == "pending-upgrade" || "$status" == "pending-install" ]]; then
      log "Release '$release' is in '$status' state — rolling back to last good revision"
      helm rollback "$release" -n "$ns" --wait --timeout 5m 2>/dev/null \
        && log "Rollback succeeded" \
        || log "WARN: rollback failed (may be first install) — continuing"
      sleep 5
    fi

    # ── Recovery 2: type mismatch / cannot patch / immutable field ────────
    # PVC spec is immutable after binding — --force cannot help because the PVC
    # can't be deleted while bound. Skip this error; the PVC will remain as-is.
    # All PVC templates should carry "helm.sh/resource-policy: keep" to prevent
    # Helm from trying to patch them in the first place.
    if echo "$out" | grep -qiE "PersistentVolumeClaim.*immutable|spec.*immutable.*after creation|spec.*Forbidden.*immutable"; then
      log "PVC immutability error detected — this is expected for bound PVCs."
      log "The PVC will keep its current spec. Ensure 'helm.sh/resource-policy: keep' is set."
      log "Continuing upgrade (PVC change is safely ignored)..."
      # Re-run with --force to let Helm skip PVC update and continue with other resources
      local force_cmd="${cmd} --force"
      if eval "$force_cmd" >"$tmp" 2>&1; then
        rm -f "$tmp"; return 0
      fi
      log "WARN: --force did not fully resolve PVC issue (may be fine if other resources succeeded):"
      tail -n 15 "$tmp" || true
    fi

    if echo "$out" | grep -qiE \
      "cannot patch|Invalid value.*number|must be of type integer,string|immutable|field is immutable"; then
      if ! $attempt_force; then
        attempt_force=true
        log "Patch conflict detected — retrying with --force (kubectl replace --force)"
        local force_cmd="${cmd} --force"
        if eval "$force_cmd" >"$tmp" 2>&1; then
          rm -f "$tmp"; return 0
        fi
        log "WARN: --force also failed:"
        tail -n 20 "$tmp" || true
      fi
    fi

    # ── Recovery 3: CRD not established yet ──────────────────────────────
    if echo "$out" | grep -qiE "no kind.*registered|resource mapping not found|CRD.*not found|ensure CRDs are installed"; then
      log "CRD not ready — ensuring Strimzi operator is installed"
      if [[ "$release" == "kafka-cluster" ]]; then
        ensure_strimzi_operator || true
      fi
      sleep 15; wait_api
    fi

    # ── Recovery 4: transient k8s API connection failure ─────────────────
    # Covers two distinct failure modes:
    #  a) Transport-level: HTTP/2 connection lost, reset by peer, EOF, TLS timeout.
    #     These are network/protocol issues between helm and the API server.
    #  b) Server-side timeout: API server received the request but could not
    #     respond in time ("unable to return a response in the time allotted").
    #     Common on single-node k3s under load when RBAC hooks (POST rolebindings)
    #     hit the default admission timeout. The server may still finish the
    #     operation in the background, so we wait before retrying.
    # NOTE: wait_api only checks GET /version; write operations (PUT/POST)
    # may still fail on an overloaded API server. We sleep an extra 40s buffer
    # after wait_api returns to let the write path stabilise.
    if echo "$out" | grep -qiE \
      "http2: client connection lost|connection reset by peer|i/o timeout|context deadline exceeded|EOF|net/http: TLS handshake timeout|transport is closing|\
unable to return a response in the time allotted|may still be processing the request|etcdserver: request timed out|context canceled"; then
      log "Transient API connection error detected — waiting 60s for API stabilization"
      sleep 60; wait_api
      # Extra buffer: wait_api only verifies GET /version; write operations
      # (PUT/POST) need additional time on constrained single-node k3s.
      log "API is responding. Sleeping 40s extra for write-path stabilisation..."
      sleep 40

      # If the release is now stuck in failed state, roll it back so the next
      # attempt starts from a clean revision.
      local status; status="$(_helm_release_status)"
      if [[ "$status" == "failed" || "$status" == "pending-upgrade" || "$status" == "pending-install" ]]; then
        log "Release '$release' stuck in '$status' after connection drop — rolling back"
        helm rollback "$release" -n "$ns" --wait --timeout 5m 2>/dev/null \
          || helm uninstall "$release" -n "$ns" --timeout 3m 2>/dev/null || true
        sleep 10
      fi
      continue
    fi

    # ── Recovery 5: pre-upgrade / pre-install hook failure ───────────────
    # Hooks may fail if API connection drops mid-hook, or if RBAC resources
    # already exist from a previous (partially completed) install.
    if echo "$out" | grep -qiE "pre-upgrade hooks failed|pre-install hooks failed|hook.*failed"; then
      log "Hook failure detected"

      # Roll back to leave a clean state for the next attempt
      local status; status="$(_helm_release_status)"
      if [[ "$status" == "failed" || "$status" == "pending-upgrade" ]]; then
        log "Rolling back stuck release '$release' before retry"
        helm rollback "$release" -n "$ns" --wait --timeout 5m 2>/dev/null || true
        sleep 10
      fi

      # Retry with --no-hooks to bypass the failing hook.
      # This is safe when hooks only create RBAC/cert resources that may already exist.
      if [[ $i -lt $tries ]]; then
        log "Retrying with --no-hooks to bypass pre-upgrade hook"
        local nohooks_cmd="${cmd} --no-hooks"
        if eval "$nohooks_cmd" >"$tmp" 2>&1; then
          rm -f "$tmp"; return 0
        fi
        log "WARN: --no-hooks also failed:"
        tail -n 15 "$tmp" || true
      fi
    fi

    sleep 10; wait_api
  done

  err "helm_smart_upgrade: release '$release' could not be upgraded after $tries attempts."
  err "To force a clean reinstall run: helm_nuke_release $release $ns"
  rm -f "$tmp"; return 1
}

# ── helm_nuke_release: nuclear option — uninstall + purge + reinstall ───────
# USE ONLY when smart_upgrade fails. Destroys all resources of the release.
# Data in PVCs is NOT deleted (deleteClaim: false protects PVs).
#
# Usage: helm_nuke_release <release> <namespace> <helm-install-cmd>
#
helm_nuke_release() {
  local release="$1"
  local ns="$2"
  local cmd="$3"
  local tmp; tmp="$(mktemp)"

  log "NUKE: Uninstalling release '$release' in namespace '$ns'..."
  helm uninstall "$release" -n "$ns" --wait --timeout 5m 2>/dev/null \
    && log "NUKE: Release uninstalled." \
    || log "WARN: helm uninstall returned non-zero (release may not exist). Continuing."

  # Give operators a moment to reconcile after resource deletion
  sleep 10; wait_api

  log "NUKE: Reinstalling release '$release'..."
  if eval "$cmd" >"$tmp" 2>&1; then
    rm -f "$tmp"
    log "NUKE: Reinstall succeeded."
    return 0
  fi

  err "NUKE: Reinstall also failed:"
  tail -n 30 "$tmp" || true
  rm -f "$tmp"; return 1
}

ensure_default_sc() {
  if ! kubectl get sc | grep -q '(default)'; then
    log "No default StorageClass found — marking local-path as default"
    kubectl annotate sc local-path storageclass.kubernetes.io/is-default-class="true" --overwrite || true
  fi
}

issue_client_bundle() {
  set -Eeuo pipefail

  # ====== params ======
  local USER="${1:-client}"
  local TLS_SECRET_NAME="${2:-log-gateway-tls}"   # can be overridden
  local TLS_NS="${3:-midas}"
  local OUTDIR="${4:-$(pwd)/out}"

  # ====== deps ======
  command -v kubectl >/dev/null || { echo "[ERR ] kubectl not found"; return 1; }
  command -v openssl >/dev/null || { echo "[ERR ] openssl not found"; return 1; }

  if ! command -v zip >/dev/null 2>&1; then
    echo "[INFO] Installing zip..."
    if command -v apt-get >/dev/null 2>&1; then
      apt-get update -y
      apt-get install -y zip
    elif [ -f /etc/alpine-release ]; then
      apk add --no-cache zip
    else
      echo "[WARN] Could not install zip (unsupported OS)"
    fi
  else
    echo "[INFO] zip is already installed, skipping"
  fi

  mkdir -p "$OUTDIR"

  # ====== resolve namespace if not provided ======
  if [[ -z "${TLS_NS}" ]]; then
    TLS_NS="$(kubectl get secret -A -o jsonpath="{range .items[?(@.metadata.name=='${TLS_SECRET_NAME}')]}.metadata.namespace{'\n'}{end}" | head -n1 || true)"
    [[ -z "${TLS_NS}" ]] && TLS_NS="midas"
  fi

  echo "[INFO] Waiting for secret ${TLS_NS}/${TLS_SECRET_NAME}…"
  for i in {1..120}; do
    kubectl -n "${TLS_NS}" get secret "${TLS_SECRET_NAME}" >/dev/null 2>&1 && break
    sleep 1
  done
  kubectl -n "${TLS_NS}" get secret "${TLS_SECRET_NAME}" >/dev/null 2>&1 || { echo "[ERR ] secret not found: ${TLS_NS}/${TLS_SECRET_NAME}"; return 1; }

  # ====== validate secret type/keys ======
  local stype
  stype="$(kubectl -n "${TLS_NS}" get secret "${TLS_SECRET_NAME}" -o jsonpath='{.type}')"
  [[ "${stype}" != "kubernetes.io/tls" ]] && echo "[WARN] secret type=${stype}, expected kubernetes.io/tls"

  # ====== temp dir with cleanup ======
  local tmpd; tmpd="$(mktemp -d)"
  # trap '[ -n "${tmpd:-}" ] && rm -rf "${tmpd}"' RETURN # Removing this trap as it might conflict with global traps

  # ====== extract leaf cert and key ======
  kubectl -n "${TLS_NS}" get secret "${TLS_SECRET_NAME}" -o jsonpath='{.data.tls\.crt}' | base64 -d > "${tmpd}/cert.pem"
  kubectl -n "${TLS_NS}" get secret "${TLS_SECRET_NAME}" -o jsonpath='{.data.tls\.key}' | base64 -d > "${tmpd}/key.pem"

  if ! grep -q "BEGIN CERTIFICATE" "${tmpd}/cert.pem"; then echo "[ERR ] empty/broken tls.crt"; return 1; fi
  if ! grep -q "BEGIN .* PRIVATE KEY" "${tmpd}/key.pem"; then echo "[ERR ] empty/broken tls.key"; return 1; fi

  # ====== fetch CA from cert-manager ======
  kubectl -n cert-manager get secret cluster-ca-secret -o jsonpath='{.data.tls\.crt}' | base64 -d > "${tmpd}/ca.pem"
  if ! grep -q "BEGIN CERTIFICATE" "${tmpd}/ca.pem"; then echo "[ERR ] failed to read CA from cert-manager/cluster-ca-secret"; return 1; fi

  # ====== build fullchain ======
  cat "${tmpd}/cert.pem" "${tmpd}/ca.pem" > "${tmpd}/fullchain.pem"

  # ====== name artifacts ======
  # shellcheck disable=SC2155
  local CERT_NAME="${USER}-$(date +%Y%m%d-%H%M%S)"

  # ====== PKCS#12 export ======
  local PASS; PASS="$(openssl rand -base64 18)"
  umask 077
  openssl pkcs12 -export \
    -in "${tmpd}/cert.pem" -inkey "${tmpd}/key.pem" \
    -certfile "${tmpd}/ca.pem" \
    -name "${CERT_NAME}" \
    -passout pass:"${PASS}" \
    -out "${tmpd}/${CERT_NAME}.p12"

  # verify p12
  openssl pkcs12 -info -in "${tmpd}/${CERT_NAME}.p12" -passin pass:"${PASS}" -nokeys -nodes >/dev/null 2>&1 || { echo "[ERR ] p12 is corrupted"; return 1; }

  # ====== write password file ======
  printf "p12-pass:%s\n" "${PASS}" > "${tmpd}/password.txt"

  # ====== zip bundle ======
  local ZIP="${OUTDIR}/${CERT_NAME}.zip"
  (cd "${tmpd}" && zip -q "${ZIP}" cert.pem key.pem ca.pem fullchain.pem "${CERT_NAME}.p12" password.txt)

  echo "[INFO] Bundle ready: ${ZIP}"
  echo "[INFO]   Secret:  ${TLS_NS}/${TLS_SECRET_NAME}"
  echo "[INFO]   Subject: $(openssl x509 -noout -subject -in "${tmpd}/cert.pem" | sed 's/^subject= //')"
  echo "[INFO]   Expires: $(openssl x509 -noout -enddate -in "${tmpd}/cert.pem" | sed 's/notAfter=//')"

  rm -rf "${tmpd}"
}

ensure_kubeconfig() {
  local sa_dir="/var/run/secrets/kubernetes.io/serviceaccount"
  local tmp_cfg="/tmp/midas-incluster-kubeconfig"

  if [[ -n "${KUBERNETES_SERVICE_HOST:-}" && -d "$sa_dir" ]]; then
    log "[INFO] In-cluster: building kubeconfig from ServiceAccount"

    local token ca ns apiserver
    token="$(cat "$sa_dir/token")"
    ca="$sa_dir/ca.crt"
    ns="$(cat "$sa_dir/namespace")"
    apiserver="https://${KUBERNETES_SERVICE_HOST}:${KUBERNETES_SERVICE_PORT:-443}"

    cat > "$tmp_cfg" <<EOF
apiVersion: v1
kind: Config
clusters:
- name: in-cluster
  cluster:
    certificate-authority: ${ca}
    server: ${apiserver}
contexts:
- name: in-cluster
  context:
    cluster: in-cluster
    namespace: ${ns}
    user: sa
current-context: in-cluster
users:
- name: sa
  user:
    token: ${token}
EOF

    export KUBECONFIG="$tmp_cfg"
    log "[INFO] Using KUBECONFIG=$KUBECONFIG"
    return 0
  fi

  # Node mode
  local default_cfg="/etc/rancher/k3s/k3s.yaml"
  if [[ -z "${KUBECONFIG:-}" ]]; then
    [[ -f "$default_cfg" ]] || { err "KUBECONFIG not set and $default_cfg not found"; exit 1; }
    export KUBECONFIG="$default_cfg"
    log "[INFO] Using node KUBECONFIG=$KUBECONFIG"
  else
    log "[INFO] Using provided KUBECONFIG=$KUBECONFIG"
  fi
}

resolve_midas_node_ip() {
  if [[ -n "${MIDAS_EXTERNAL_IP:-}" ]]; then
    printf "%s\n" "${MIDAS_EXTERNAL_IP}"
    return 0
  fi

  local nodes_json
  if ! nodes_json="$(kubectl get node -o json 2>/dev/null)"; then
    hostname -I 2>/dev/null | awk '{print $1}'
    return 0
  fi

  local local_hostname local_hostname_short local_hostname_fqdn
  local_hostname="$(hostname 2>/dev/null || true)"
  local_hostname_short="$(hostname -s 2>/dev/null || true)"
  local_hostname_fqdn="$(hostname -f 2>/dev/null || true)"

  mapfile -t local_ips < <(
    {
      hostname -I 2>/dev/null || true
      ip -o -4 addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 || true
    } | tr ' ' '\n' | awk 'NF' | sort -u
  )

  local ips_json target_node ip
  ips_json="$(printf '%s\n' "${local_ips[@]:-}" | awk 'NF' | jq -R . | jq -s .)"

  target_node="$(
    jq -r \
      --arg h "${local_hostname}" \
      --arg hs "${local_hostname_short}" \
      --arg hf "${local_hostname_fqdn}" \
      --argjson ips "${ips_json}" '
        [
          .items[]
          | select(
              (.metadata.name == $h) or
              (.metadata.name == $hs) or
              (.metadata.name == $hf) or
              (
                ([.status.addresses[].address] as $addrs
                | any($ips[]; . as $candidate | ($addrs | index($candidate) != null)))
              )
            )
          | .metadata.name
        ][0] // ""
      ' <<< "${nodes_json}"
  )"

  if [[ -z "${target_node}" ]]; then
    target_node="$(jq -r '.items[0].metadata.name // ""' <<< "${nodes_json}")"
  fi

  ip="$(
    jq -r --arg n "${target_node}" '
      .items[]
      | select(.metadata.name == $n)
      | (
          ([.status.addresses[] | select(.type=="ExternalIP") | .address][0])
          // ([.status.addresses[] | select(.type=="InternalIP") | .address][0])
          // ""
        )
    ' <<< "${nodes_json}"
  )"

  if [[ -z "${ip}" ]]; then
    ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  fi

  printf "%s\n" "${ip}"
}

