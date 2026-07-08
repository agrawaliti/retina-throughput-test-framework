#!/usr/bin/env bash
# =============================================================================
# run_hx_abc_sweep.sh — Single-cluster sequential A/B/C on HX176rs (176-core)
# =============================================================================
#
# PURPOSE
#   Runs the reuseport TCP workload on ONE cluster (the HX cluster in
#   southeastasia), reconfiguring Retina in place to produce a sequential
#   A/B/C comparison on identical hardware:
#
#     A = baseline    : no Retina installed            -> throughput ceiling
#     B = perf-array  : Retina, packetParserRingBuffer=disabled
#                        + VERIFY packetparser / adv-* metrics present
#     C = ring-buffer : packetParserRingBuffer=enabled
#                        + VERIFY ring buffer initialised AND metrics present
#
#   Because a freshly-created cluster has no Retina, the natural order is:
#     A (before install) -> install for B -> toggle configmap for C.
#
# HARDWARE SCALING
#   Defaults are tuned for 176-core Standard_HX176rs (see scenarios/hx_176core.env).
#   The receiver uses 175 of 176 cores (LISTENERS=175, WORKERS=700,
#   RECEIVER_GOMAXPROCS=175); the sender is spread across 50 pods to stay ahead
#   of the receiver. All knobs are env-overridable.
#
# USAGE
#   set -a; source scenarios/hx_176core.env; set +a
#   CTX=retina-bench-hx ./scripts/run_hx_abc_sweep.sh
# =============================================================================
set -euo pipefail

CTX="${CTX:-retina-bench-hx}"
NAMESPACE="default"
IMAGE="golang:1.24.5-bookworm"
SRC_CONFIGMAP="reuseport-src"
DURATION="${DURATION:-90s}"

# Core-count knobs — defaults saturate a 176-core HX176rs node.
LISTENERS="${LISTENERS:-175}"
WORKERS="${WORKERS:-700}"
RECEIVER_GOMAXPROCS="${RECEIVER_GOMAXPROCS:-175}"
CLIENT_GOMAXPROCS="${CLIENT_GOMAXPROCS:-5}"
CLIENT_PODS="${CLIENT_PODS:-50}"
CONNECTIONS="${CONNECTIONS:-280}"
PAYLOAD_SIZES=(${PAYLOAD_SIZES:-1024 8192 65536})

# Retina OSS install (advanced mode). Overridable if a different chart is used.
RETINA_NS="kube-system"
RETINA_CHART="${RETINA_CHART:-oci://ghcr.io/microsoft/retina/charts/retina}"
RETINA_VERSION="${RETINA_VERSION:-v0.0.30}"
RETINA_CONFIGMAP="retina-config"
RETINA_DS="retina-agent"
RB_SIZE="${RB_SIZE:-8388608}"

OUTDIR="results/hx_abc"
mkdir -p "$OUTDIR"
SWEEP_ID="$(date -u +%Y%m%dT%H%M%SZ)"
SUMMARY="$OUTDIR/${SWEEP_ID}_hx_abc_summary.csv"
echo "payload_bytes,connections,noretina_gbps,perf_array_gbps,ring_buffer_gbps,winner,perf_retina_cpu,ring_retina_cpu,perf_metrics_ok,ring_metrics_ok,ring_initialised" > "$SUMMARY"

log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }

# ---------------------------------------------------------------------------
# run_workload: create receiver pod + sender Job, measure median receiver Gbps.
#   $1=payload $2=tag  -> echoes "gbps|retina_cpu|errors"
# ---------------------------------------------------------------------------
run_workload() {
  local payload="$1" tag="$2"
  local server="reuseport-recv-${tag}"
  local job="reuseport-cli-${tag}"

  local recv_node sender_node
  recv_node="$(kubectl --context "$CTX" get nodes -l 'workload=benchmark,kubernetes.io/os=linux' -o jsonpath='{.items[0].metadata.name}')"
  sender_node="$(kubectl --context "$CTX" get nodes -l 'workload=benchmark,kubernetes.io/os=linux' -o jsonpath='{.items[1].metadata.name}')"
  kubectl --context "$CTX" label node "$recv_node" perf-role32=receiver --overwrite >/dev/null
  kubectl --context "$CTX" label node "$sender_node" perf-role32=sender --overwrite >/dev/null

  kubectl --context "$CTX" -n "$NAMESPACE" create configmap "$SRC_CONFIGMAP" \
    --from-file=go.mod=go.mod \
    --from-file=reuseport-receiver.go=cmd/reuseport-receiver/main.go \
    --from-file=reuseport-client.go=cmd/reuseport-client/main.go \
    --dry-run=client -o yaml | kubectl --context "$CTX" apply -f - >/dev/null

  kubectl --context "$CTX" delete pod "$server" --ignore-not-found >/dev/null 2>&1 || true
  kubectl --context "$CTX" delete job "$job" --ignore-not-found >/dev/null 2>&1 || true
  sleep 2

  cat <<POD | kubectl --context "$CTX" create -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: ${server}
  namespace: ${NAMESPACE}
spec:
  restartPolicy: Never
  nodeSelector:
    perf-role32: receiver
  tolerations:
  - key: workload
    operator: Equal
    value: benchmark
    effect: NoSchedule
  containers:
  - name: receiver
    image: ${IMAGE}
    workingDir: /workspace
    command: ["/bin/sh", "-lc"]
    args:
      - |
        export PATH=/usr/local/go/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
        mkdir -p /workspace/cmd/reuseport-receiver /workspace/cmd/reuseport-client
        cp /src/go.mod /workspace/go.mod
        cp /src/reuseport-receiver.go /workspace/cmd/reuseport-receiver/main.go
        cp /src/reuseport-client.go /workspace/cmd/reuseport-client/main.go
        go run ./cmd/reuseport-receiver --listen-addr :9000 --listeners ${LISTENERS} --workers ${WORKERS} --gomaxprocs ${RECEIVER_GOMAXPROCS}
    volumeMounts:
    - name: src
      mountPath: /src
    - name: work
      mountPath: /workspace
  volumes:
  - name: src
    configMap:
      name: ${SRC_CONFIGMAP}
  - name: work
    emptyDir: {}
POD

  kubectl --context "$CTX" wait --for=condition=Ready "pod/${server}" --timeout=300s >/dev/null
  local target_ip
  target_ip="$(kubectl --context "$CTX" get pod "$server" -o jsonpath='{.status.podIP}')"

  cat <<JOB | kubectl --context "$CTX" create -f - >/dev/null
apiVersion: batch/v1
kind: Job
metadata:
  name: ${job}
  namespace: ${NAMESPACE}
spec:
  parallelism: ${CLIENT_PODS}
  completions: ${CLIENT_PODS}
  completionMode: Indexed
  template:
    spec:
      restartPolicy: Never
      nodeSelector:
        perf-role32: sender
      tolerations:
      - key: workload
        operator: Equal
        value: benchmark
        effect: NoSchedule
      containers:
      - name: client
        image: ${IMAGE}
        workingDir: /workspace
        command: ["/bin/sh", "-lc"]
        args:
          - |
            export PATH=/usr/local/go/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
            mkdir -p /workspace/cmd/reuseport-receiver /workspace/cmd/reuseport-client
            cp /src/go.mod /workspace/go.mod
            cp /src/reuseport-receiver.go /workspace/cmd/reuseport-receiver/main.go
            cp /src/reuseport-client.go /workspace/cmd/reuseport-client/main.go
            go run ./cmd/reuseport-client --target ${target_ip}:9000 --connections ${CONNECTIONS} --duration ${DURATION} --payload-bytes ${payload} --gomaxprocs ${CLIENT_GOMAXPROCS}
        volumeMounts:
        - name: src
          mountPath: /src
        - name: work
          mountPath: /workspace
      volumes:
      - name: src
        configMap:
          name: ${SRC_CONFIGMAP}
      - name: work
        emptyDir: {}
JOB

  # Sample Retina agent CPU twice during steady state; keep peak (0 if no Retina).
  sleep 45
  local cpu1 cpu2 retina_cpu
  cpu1="$(kubectl --context "$CTX" top pods -n "$RETINA_NS" -l app.kubernetes.io/name=retina --no-headers 2>/dev/null | awk 'NR>0{gsub("m","",$2); if($2>max)max=$2} END{print max+0}')"
  sleep 30
  cpu2="$(kubectl --context "$CTX" top pods -n "$RETINA_NS" -l app.kubernetes.io/name=retina --no-headers 2>/dev/null | awk 'NR>0{gsub("m","",$2); if($2>max)max=$2} END{print max+0}')"
  retina_cpu="$(awk -v a="${cpu1:-0}" -v b="${cpu2:-0}" 'BEGIN{print (a>b?a:b)"m"}')"

  kubectl --context "$CTX" wait --for=condition=complete "job/${job}" --timeout=900s >/dev/null

  local recv_gbps errors
  recv_gbps="$(kubectl --context "$CTX" logs "$server" --tail=120 \
    | grep -oE 'interval_gbps=[0-9.]+' | cut -d= -f2 \
    | awk '$1>0.05' | sort -n \
    | awk '{a[NR]=$1} END{ if(NR==0){print 0} else if(NR%2){printf "%.2f", a[(NR+1)/2]} else {printf "%.2f", (a[NR/2]+a[NR/2+1])/2} }')"
  errors="$(kubectl --context "$CTX" logs "$server" --tail=120 | grep -oE 'errors=[0-9]+' | cut -d= -f2 | sort -rn | head -1)"

  kubectl --context "$CTX" delete pod "$server" --ignore-not-found >/dev/null 2>&1 || true
  kubectl --context "$CTX" delete job "$job" --ignore-not-found >/dev/null 2>&1 || true

  echo "${recv_gbps:-0}|${retina_cpu:-NA}|${errors:-0}"
}

# ---------------------------------------------------------------------------
# verify_metrics: scrape retina-agent :10093 and assert adv-*/packetparser
#   families are present. echoes "yes" / "no".
# ---------------------------------------------------------------------------
verify_metrics() {
  local pod count
  pod="$(kubectl --context "$CTX" -n "$RETINA_NS" get pods -l app.kubernetes.io/name=retina -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
  [[ -z "$pod" ]] && { echo "no"; return; }
  kubectl --context "$CTX" -n "$RETINA_NS" port-forward "pod/$pod" 10093:10093 >/tmp/pf_hx.log 2>&1 &
  local pf=$!
  sleep 4
  count="$(curl -s http://localhost:10093/metrics 2>/dev/null | grep -cE '^networkobservability_(adv_forward_count|adv_forward_bytes|adv_tcpflags_count|tcp_state|tcp_connection_stats)')"
  kill "$pf" 2>/dev/null || true
  if [[ "${count:-0}" -gt 0 ]]; then echo "yes"; else echo "no"; fi
}

# ---------------------------------------------------------------------------
# verify_ringbuf_init: grep retina-agent logs for ring buffer initialisation.
#   echoes "yes" / "no".
# ---------------------------------------------------------------------------
verify_ringbuf_init() {
  local pod
  pod="$(kubectl --context "$CTX" -n "$RETINA_NS" get pods -l app.kubernetes.io/name=retina -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
  [[ -z "$pod" ]] && { echo "no"; return; }
  if kubectl --context "$CTX" -n "$RETINA_NS" logs "$pod" 2>/dev/null \
       | grep -qiE 'Compiling with Ring Buffer enabled|Initializing Ring Buffer reader'; then
    echo "yes"
  else
    echo "no"
  fi
}

install_retina_perf_array() {
  log "Installing Retina (advanced, perf-array: packetParserRingBuffer disabled)..."
  helm --kube-context "$CTX" upgrade --install retina "$RETINA_CHART" \
    --version "$RETINA_VERSION" \
    --namespace "$RETINA_NS" \
    --set enablePodLevel=true \
    --set enableAnnotations=true \
    --set-string dataAggregationLevel=low \
    --set 'enabledPlugin_linux={dropreason,packetforward,linuxutil,dns,packetparser}' \
    --set-string packetParserRingBuffer=disabled \
    --set packetParserRingBufferSize="$RB_SIZE" \
    --wait --timeout 5m >/dev/null
  kubectl --context "$CTX" -n "$RETINA_NS" rollout status ds/"$RETINA_DS" --timeout=300s >/dev/null
  sleep 15
}

set_ringbuf() {
  local value="$1"   # enabled|disabled
  local tmp; tmp="$(mktemp)"
  kubectl --context "$CTX" -n "$RETINA_NS" get cm "$RETINA_CONFIGMAP" -o jsonpath='{.data.config\.yaml}' > "$tmp"
  if grep -q '^packetParserRingBuffer:' "$tmp"; then
    sed -i -E "s/^packetParserRingBuffer:.*/packetParserRingBuffer: ${value}/" "$tmp"
  else
    echo "packetParserRingBuffer: ${value}" >> "$tmp"
  fi
  kubectl --context "$CTX" -n "$RETINA_NS" create cm "$RETINA_CONFIGMAP" --from-file=config.yaml="$tmp" -o yaml --dry-run=client \
    | kubectl --context "$CTX" apply -f - >/dev/null
  rm -f "$tmp"
  kubectl --context "$CTX" -n "$RETINA_NS" rollout restart ds/"$RETINA_DS" >/dev/null
  kubectl --context "$CTX" -n "$RETINA_NS" rollout status ds/"$RETINA_DS" --timeout=300s >/dev/null
  sleep 15
}

echo "HX A/B/C sweep ${SWEEP_ID} on ${CTX}"
echo "  cores: receiver GOMAXPROCS=${RECEIVER_GOMAXPROCS} listeners=${LISTENERS} workers=${WORKERS}"
echo "  sender: pods=${CLIENT_PODS} gomaxprocs=${CLIENT_GOMAXPROCS} conns=${CONNECTIONS} (flows=$((CLIENT_PODS*CONNECTIONS)))"
echo "  DURATION=${DURATION}  payloads: ${PAYLOAD_SIZES[*]}"
echo ""

declare -A A_GBPS B_GBPS C_GBPS B_CPU C_CPU

# ---- Phase A: baseline (no Retina) ----
if helm --kube-context "$CTX" status retina -n "$RETINA_NS" >/dev/null 2>&1; then
  log "Retina present; uninstalling for a clean baseline (Phase A)..."
  helm --kube-context "$CTX" uninstall retina -n "$RETINA_NS" --wait --timeout 3m >/dev/null 2>&1 || true
  sleep 10
fi
log "=== Phase A: baseline (no Retina) ==="
for p in "${PAYLOAD_SIZES[@]}"; do
  r="$(run_workload "$p" "a${p}")"; A_GBPS[$p]="${r%%|*}"
  log "  A payload=${p} -> ${A_GBPS[$p]} Gbps"
done

# ---- Phase B: perf-array ----
install_retina_perf_array
B_METRICS="$(verify_metrics)"
B_RB_INIT="$(verify_ringbuf_init)"   # expect "no" for perf-array
log "=== Phase B: perf-array (metrics_ok=${B_METRICS}, ringbuf_init=${B_RB_INIT}) ==="
for p in "${PAYLOAD_SIZES[@]}"; do
  r="$(run_workload "$p" "b${p}")"; B_GBPS[$p]="${r%%|*}"; B_CPU[$p]="$(echo "$r" | cut -d'|' -f2)"
  log "  B payload=${p} -> ${B_GBPS[$p]} Gbps (cpu ${B_CPU[$p]})"
done

# ---- Phase C: ring-buffer ----
set_ringbuf enabled
C_METRICS="$(verify_metrics)"
C_RB_INIT="$(verify_ringbuf_init)"   # expect "yes"
log "=== Phase C: ring-buffer (metrics_ok=${C_METRICS}, ringbuf_init=${C_RB_INIT}) ==="
for p in "${PAYLOAD_SIZES[@]}"; do
  r="$(run_workload "$p" "c${p}")"; C_GBPS[$p]="${r%%|*}"; C_CPU[$p]="$(echo "$r" | cut -d'|' -f2)"
  log "  C payload=${p} -> ${C_GBPS[$p]} Gbps (cpu ${C_CPU[$p]})"
done

# ---- Consolidate ----
for p in "${PAYLOAD_SIZES[@]}"; do
  winner="$(awk -v n="${A_GBPS[$p]:-0}" -v pf="${B_GBPS[$p]:-0}" -v rb="${C_GBPS[$p]:-0}" 'BEGIN{
    max=n; w="no-retina";
    if (pf>max*1.03){max=pf; w="perf-array"}
    if (rb>max*1.03){max=rb; w="ring-buffer"}
    print w }')"
  echo "${p},${CONNECTIONS},${A_GBPS[$p]:-0},${B_GBPS[$p]:-0},${C_GBPS[$p]:-0},${winner},${B_CPU[$p]:-NA},${C_CPU[$p]:-NA},${B_METRICS},${C_METRICS},${C_RB_INIT}" >> "$SUMMARY"
done

echo ""
echo "=== HX A/B/C SWEEP COMPLETE ==="
column -t -s, "$SUMMARY"
echo ""
echo "Verification: perf-array metrics_ok=${B_METRICS} | ring-buffer metrics_ok=${C_METRICS} ringbuf_init=${C_RB_INIT}"
echo "Summary saved to: $SUMMARY"
