#!/usr/bin/env bash
# =============================================================================
# run_three_cluster_sweep.sh — Simultaneous 3-cluster throughput comparison
# =============================================================================
#
# PURPOSE
#   Runs the identical reuseport TCP workload on THREE separate AKS clusters at
#   the SAME wall-clock time, for each payload size, and records one merged CSV
#   row per payload comparing all three:
#
#     - NORETINA_CTX (retina-bench-noretina)   : no Retina installed  -> ceiling
#     - PERF_CTX     (retina-bench-baseline)    : Retina, perf-array mode
#     - RING_CTX     (retina-bench-withretina)  : Retina, ring-buffer mode
#
#   The two Retina clusters run byte-identical Retina advanced-mode config
#   (enablePodLevel=true, enableAnnotations=true, packetparser active,
#   dataAggregationLevel=low, agent CPU request 500m). The ONLY difference
#   between them is packetParserRingBuffer: disabled (perf-array) vs enabled
#   (ring-buffer). The no-Retina cluster has NO Retina agent at all, giving the
#   hardware/kernel throughput ceiling for the same workload.
#
# WHY SIMULTANEOUS
#   The three clusters are independent (separate control planes, separate VMSS
#   node pools of the same SKU: Standard_D32s_v3). Launching all three passes
#   concurrently removes time-of-day / noisy-neighbour skew between modes: each
#   payload size is measured on all three clusters within the same time window.
#   Each cluster still runs its own private receiver + sender pods, so there is
#   no cross-cluster traffic interference — only shared wall-clock timing.
#
# =============================================================================
# WHAT THE WORKLOAD IS (per cluster)
#   Receiver pod  (cmd/reuseport-receiver): opens ${LISTENERS} SO_REUSEPORT
#     TCP listeners on :9000, hands accepted connections to ${WORKERS} reader
#     goroutines that drain bytes as fast as possible. GOMAXPROCS is pinned to
#     ${RECEIVER_GOMAXPROCS} so the receiver uses a fixed slice of the 32 vCPUs.
#     Runs on the node labelled perf-role32=receiver.
#   Sender Job    (cmd/reuseport-client): ${CLIENT_PODS} indexed pods, each
#     opening ${CONNECTIONS} long-lived TCP connections to the receiver pod IP
#     and writing ${payload}-byte buffers in a tight loop for ${DURATION}.
#     Each client pod pins GOMAXPROCS=${CLIENT_GOMAXPROCS}. Runs on the node
#     labelled perf-role32=sender. Total offered flows per cluster =
#     CLIENT_PODS * CONNECTIONS.
#
# WHAT IS MEASURED
#   throughput_gbps : MEDIAN of the receiver's per-interval interval_gbps
#     samples (only windows > 0.05 Gbps are kept, to drop ramp-up/drain).
#     Median (not mean) is used because it is robust to the first/last partial
#     windows. This is receiver-side goodput on the wire.
#   retina_cpu      : PEAK Retina agent CPU (millicores) observed across two
#     `kubectl top pods -l app.kubernetes.io/name=retina` samples taken during
#     steady state (~45s and ~75s into the run). For the no-Retina cluster this
#     is naturally 0m / NA (no agent pods match the selector).
#   conn_errors     : receiver-side cumulative non-EOF socket errors +
#     worker-queue-full drops (see cmd/reuseport-receiver/main.go). This is
#     dominated by connection teardown (RST on shutdown) and is a fixed
#     function of flow count, so it is expected to be constant across payloads.
#
# HOW THE WINNER IS PICKED
#   Among the three throughput_gbps values, the highest wins. A 3% band is used
#   so near-identical results are reported as "tie".
#
# USAGE
#   ./scripts/run_three_cluster_sweep.sh
#   PAYLOAD_SIZES="1024 8192 65536" DURATION=90s CONNECTIONS=165 \
#     ./scripts/run_three_cluster_sweep.sh
#
# TUNABLES (env vars)
#   PAYLOAD_SIZES  space-separated payload byte sizes (default full sweep)
#   CONNECTIONS    connections per client pod          (default 165)
#   DURATION       per-payload traffic duration         (default 120s)
# =============================================================================
set -euo pipefail

NORETINA_CTX="${NORETINA_CTX:-retina-bench-noretina}"
PERF_CTX="${PERF_CTX:-retina-bench-baseline}"
RING_CTX="${RING_CTX:-retina-bench-withretina}"

NAMESPACE="default"
IMAGE="golang:1.24.5-bookworm"
SRC_CONFIGMAP="reuseport-src"
DURATION="${DURATION:-120s}"
LISTENERS=31
WORKERS=124
RECEIVER_GOMAXPROCS=31
CLIENT_GOMAXPROCS=3
CLIENT_PODS=15

# Payload sizes to sweep (bytes). Small = high packet rate = more Retina work.
PAYLOAD_SIZES=(${PAYLOAD_SIZES:-512 1024 2048 4096 8192 16384 65536})
# Connections per client pod (total flows = CLIENT_PODS * CONNECTIONS).
CONNECTIONS="${CONNECTIONS:-165}"

OUTDIR="results/buffer_crossover"
mkdir -p "$OUTDIR"
SWEEP_ID="$(date -u +%Y%m%dT%H%M%SZ)"
DBGDIR="$OUTDIR/debug/${SWEEP_ID}"
mkdir -p "$DBGDIR"
SUMMARY="$OUTDIR/${SWEEP_ID}_three_cluster_summary.csv"
echo "payload_bytes,connections,noretina_gbps,perf_array_gbps,ring_buffer_gbps,winner,perf_retina_cpu,ring_retina_cpu,noretina_errors,perf_conn_errors,ring_conn_errors" > "$SUMMARY"

# kctl: kubectl with retry+backoff to ride out intermittent AKS API-server
# i/o timeouts (observed ~15-20% blip rate on these clusters). Passes stdout
# through so it is safe inside $( ). Returns non-zero only after all retries.
kctl() {
  local attempt=1 max=5
  while :; do
    kubectl "$@" && return 0
    [[ $attempt -ge $max ]] && return 1
    sleep $((attempt * 3))
    attempt=$((attempt + 1))
  done
}

# -----------------------------------------------------------------------------
# run_one: execute one workload pass on a single cluster.
#   $1=context $2=payload $3=connections $4=tag $5=output-file
# Writes exactly one line "gbps|retina_cpu|errors" to $5 on stdout redirect.
# All kubectl chatter is suppressed so the file holds only the result tuple.
# -----------------------------------------------------------------------------
run_one() {
  local ctx="$1" payload="$2" conns="$3" tag="$4"
  local server="reuseport-recv-${tag}"
  local job="reuseport-cli-${tag}"

  local recv_node sender_node
  recv_node="$(kctl --context "$ctx" get nodes -l 'workload=benchmark,kubernetes.io/os=linux' -o jsonpath='{.items[0].metadata.name}')"
  sender_node="$(kctl --context "$ctx" get nodes -l 'workload=benchmark,kubernetes.io/os=linux' -o jsonpath='{.items[1].metadata.name}')"
  if [[ -z "$recv_node" || -z "$sender_node" ]]; then
    echo "run_one $tag: node discovery failed (recv='$recv_node' sender='$sender_node')" >&2
    return 1
  fi
  kctl --context "$ctx" label node "$recv_node" perf-role32=receiver --overwrite >/dev/null
  kctl --context "$ctx" label node "$sender_node" perf-role32=sender --overwrite >/dev/null

  kubectl --context "$ctx" -n "$NAMESPACE" create configmap "$SRC_CONFIGMAP" \
    --from-file=go.mod=go.mod \
    --from-file=reuseport-receiver.go=cmd/reuseport-receiver/main.go \
    --from-file=reuseport-client.go=cmd/reuseport-client/main.go \
    --dry-run=client -o yaml | kctl --context "$ctx" apply -f - >/dev/null

  kubectl --context "$ctx" delete pod "$server" --ignore-not-found >/dev/null 2>&1 || true
  kubectl --context "$ctx" delete job "$job" --ignore-not-found >/dev/null 2>&1 || true
  sleep 2

  cat <<POD | kubectl --context "$ctx" create -f - >/dev/null
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

  kctl --context "$ctx" wait --for=condition=Ready "pod/${server}" --timeout=300s >/dev/null
  local target_ip
  target_ip="$(kctl --context "$ctx" get pod "$server" -o jsonpath='{.status.podIP}')"
  if [[ -z "$target_ip" ]]; then
    echo "run_one $tag: empty target_ip after wait" >&2
    return 1
  fi

  cat <<JOB | kubectl --context "$ctx" create -f - >/dev/null
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
            go run ./cmd/reuseport-client --target ${target_ip}:9000 --connections ${conns} --duration ${DURATION} --payload-bytes ${payload} --gomaxprocs ${CLIENT_GOMAXPROCS}
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

  # Sample Retina CPU twice during steady state; keep the peak. On the
  # no-Retina cluster the selector matches nothing, so this stays 0m.
  sleep 45
  local cpu1 cpu2 retina_cpu
  cpu1="$(kubectl --context "$ctx" top pods -n kube-system -l app.kubernetes.io/name=retina --no-headers 2>/dev/null | awk 'NR>0{gsub("m","",$2); if($2>max)max=$2} END{print max+0}')"
  sleep 30
  cpu2="$(kubectl --context "$ctx" top pods -n kube-system -l app.kubernetes.io/name=retina --no-headers 2>/dev/null | awk 'NR>0{gsub("m","",$2); if($2>max)max=$2} END{print max+0}')"
  retina_cpu="$(awk -v a="${cpu1:-0}" -v b="${cpu2:-0}" 'BEGIN{print (a>b?a:b)"m"}')"

  kctl --context "$ctx" wait --for=condition=complete "job/${job}" --timeout=600s >/dev/null

  # Receiver-side throughput: MEDIAN of non-zero interval_gbps windows.
  local recv_gbps errors
  recv_gbps="$(kctl --context "$ctx" logs "$server" --tail=80 \
    | grep -oE 'interval_gbps=[0-9.]+' | cut -d= -f2 \
    | awk '$1>0.05' | sort -n \
    | awk '{a[NR]=$1} END{ if(NR==0){print 0} else if(NR%2){printf "%.2f", a[(NR+1)/2]} else {printf "%.2f", (a[NR/2]+a[NR/2+1])/2} }')"
  errors="$(kctl --context "$ctx" logs "$server" --tail=80 | grep -oE 'errors=[0-9]+' | cut -d= -f2 | sort -rn | head -1)"

  # A 0/empty median means no throughput windows were captured = measurement
  # failure (usually an API blip), NOT a real zero. Treat as failure so the
  # payload row is retried/skipped instead of polluting stats with a false 0.
  if [[ -z "$recv_gbps" || "$recv_gbps" == "0" || "$recv_gbps" == "0.00" ]]; then
    echo "run_one $tag: recv_gbps='$recv_gbps' (measurement failure)" >&2
    kubectl --context "$ctx" delete pod "$server" --ignore-not-found >/dev/null 2>&1 || true
    kubectl --context "$ctx" delete job "$job" --ignore-not-found >/dev/null 2>&1 || true
    return 1
  fi

  kubectl --context "$ctx" delete pod "$server" --ignore-not-found >/dev/null 2>&1 || true
  kubectl --context "$ctx" delete job "$job" --ignore-not-found >/dev/null 2>&1 || true

  echo "${recv_gbps:-0}|${retina_cpu:-NA}|${errors:-0}"
}

# run_one_retry: run run_one, capturing stderr to a per-tag debug log. If it
# produces no result (a set -e failure inside run_one left the output empty),
# force-clean this tag's pods/job and retry exactly once. Never aborts the
# caller; an empty output file signals a hard failure to the payload loop.
run_one_retry() {
  local ctx="$1" payload="$2" conns="$3" tag="$4" out="$5"
  local errlog="$DBGDIR/${tag}.err"
  run_one "$ctx" "$payload" "$conns" "$tag" > "$out" 2>"$errlog" || true
  if [[ ! -s "$out" ]]; then
    echo "--- attempt 1 failed, retrying $tag ---" >> "$errlog"
    kubectl --context "$ctx" delete pod "reuseport-recv-${tag}" --force --grace-period=0 --ignore-not-found >/dev/null 2>&1 || true
    kubectl --context "$ctx" delete job "reuseport-cli-${tag}" --ignore-not-found >/dev/null 2>&1 || true
    sleep 5
    run_one "$ctx" "$payload" "$conns" "$tag" > "$out" 2>>"$errlog" || true
  fi
}

echo "3-cluster sweep ${SWEEP_ID}"
echo "  no-retina : ${NORETINA_CTX}"
echo "  perf-array: ${PERF_CTX}"
echo "  ring-buffer: ${RING_CTX}"
echo "  DURATION=${DURATION} CONNECTIONS=${CONNECTIONS} (flows/cluster=$((CLIENT_PODS*CONNECTIONS)))"
echo "  Payload sizes: ${PAYLOAD_SIZES[*]}"
echo ""

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

for payload in "${PAYLOAD_SIZES[@]}"; do
  echo "=== Payload ${payload} bytes — launching all 3 clusters simultaneously ==="

  run_one_retry "$NORETINA_CTX" "$payload" "$CONNECTIONS" "nr${payload}" "$TMPDIR/nr" &
  pid_nr=$!
  run_one_retry "$PERF_CTX"     "$payload" "$CONNECTIONS" "pf${payload}" "$TMPDIR/pf" &
  pid_pf=$!
  run_one_retry "$RING_CTX"     "$payload" "$CONNECTIONS" "rb${payload}" "$TMPDIR/rb" &
  pid_rb=$!

  wait "$pid_nr" || true
  wait "$pid_pf" || true
  wait "$pid_rb" || true

  # Tolerant parse: an empty file = that cluster's run failed even after retry.
  # Skip the whole payload row (don't pollute stats with zeros) and continue.
  nr_line="$(cat "$TMPDIR/nr" 2>/dev/null || true)"
  pf_line="$(cat "$TMPDIR/pf" 2>/dev/null || true)"
  rb_line="$(cat "$TMPDIR/rb" 2>/dev/null || true)"
  IFS='|' read -r nr_gbps nr_cpu nr_err <<<"$nr_line" || true
  IFS='|' read -r pf_gbps pf_cpu pf_err <<<"$pf_line" || true
  IFS='|' read -r rb_gbps rb_cpu rb_err <<<"$rb_line" || true

  if [[ -z "$nr_line" || -z "$pf_line" || -z "$rb_line" ]]; then
    echo "  WARN payload ${payload} SKIPPED (cluster failure) nr='${nr_line}' pf='${pf_line}' rb='${rb_line}' -- see $DBGDIR/*.err"
    echo ""
    continue
  fi

  winner="$(awk -v n="${nr_gbps:-0}" -v p="${pf_gbps:-0}" -v r="${rb_gbps:-0}" 'BEGIN {
    max=n; w="no-retina";
    if (p>max*1.03){max=p; w="perf-array"}
    if (r>max*1.03){max=r; w="ring-buffer"}
    print w;
  }')"

  echo "  no-retina=${nr_gbps} Gbps (err ${nr_err}) | perf-array=${pf_gbps} Gbps (cpu ${pf_cpu}, err ${pf_err}) | ring-buffer=${rb_gbps} Gbps (cpu ${rb_cpu}, err ${rb_err}) | winner=${winner}"
  echo "${payload},${CONNECTIONS},${nr_gbps},${pf_gbps},${rb_gbps},${winner},${pf_cpu},${rb_cpu},${nr_err},${pf_err},${rb_err}" >> "$SUMMARY"
  echo ""
done

echo "=== 3-CLUSTER SWEEP COMPLETE ==="
column -t -s, "$SUMMARY"
echo ""
echo "Summary saved to: $SUMMARY"
