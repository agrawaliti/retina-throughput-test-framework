#!/usr/bin/env bash
# =============================================================================
# run_buffer_crossover_sweep.sh — Find where ring-buffer beats perf-array
# =============================================================================
#
# PURPOSE:
#   Sweeps payload sizes across two pre-configured Retina clusters:
#     - PERF_CTX  (perf-array mode):  retina-bench-baseline
#     - RING_CTX  (ring-buffer mode): retina-bench-withretina
#   Both run identical Retina advanced-mode config (enablePodLevel=true,
#   enableAnnotations=true, packetparser active, CPU limit 500m). The ONLY
#   difference is packetParserRingBuffer disabled vs enabled.
#
#   Based on https://blog.zmalik.dev/p/who-will-observe-the-observability :
#   ring buffers win when Retina's userspace reader is CPU-throttled (500m)
#   AND packet rate is high enough that perf-array's per-CPU buffer polling
#   wastes cycles. This sweep finds that crossover packet rate.
#
# MEASUREMENT:
#   For each payload size, runs the reuseport workload on BOTH clusters and
#   records receiver-side Gbps + Retina agent CPU. Whichever buffer mode gives
#   higher throughput at a given payload size "wins" there.
#
# USAGE:
#   ./scripts/run_buffer_crossover_sweep.sh
# =============================================================================
set -euo pipefail

PERF_CTX="retina-bench-baseline"
RING_CTX="retina-bench-withretina"
NAMESPACE="default"
IMAGE="golang:1.24.5-bookworm"
SRC_CONFIGMAP="reuseport-src"
DURATION="${DURATION:-120s}"
LISTENERS=31
WORKERS=124
RECEIVER_GOMAXPROCS=31
CLIENT_GOMAXPROCS=3
CLIENT_PODS=15

# Payload sizes to sweep (bytes). Small = high packet rate.
PAYLOAD_SIZES=(${PAYLOAD_SIZES:-512 1024 2048 4096 8192 16384})
# Connections per client pod (tune total flows / packet pressure)
CONNECTIONS="${CONNECTIONS:-165}"

OUTDIR="results/buffer_crossover"
mkdir -p "$OUTDIR"
SWEEP_ID="$(date -u +%Y%m%dT%H%M%SZ)"
SUMMARY="$OUTDIR/${SWEEP_ID}_sweep_summary.csv"
echo "payload_bytes,connections,perf_array_gbps,ring_buffer_gbps,winner,perf_retina_cpu,ring_retina_cpu,perf_conn_errors,ring_conn_errors" > "$SUMMARY"

run_one() {
  # $1=context $2=payload $3=connections $4=tag
  local ctx="$1" payload="$2" conns="$3" tag="$4"
  local server="reuseport-recv-${tag}"
  local job="reuseport-cli-${tag}"

  local recv_node sender_node
  recv_node="$(kubectl --context "$ctx" get nodes -l 'workload=benchmark,kubernetes.io/os=linux' -o jsonpath='{.items[0].metadata.name}')"
  sender_node="$(kubectl --context "$ctx" get nodes -l 'workload=benchmark,kubernetes.io/os=linux' -o jsonpath='{.items[1].metadata.name}')"
  kubectl --context "$ctx" label node "$recv_node" perf-role32=receiver --overwrite >/dev/null
  kubectl --context "$ctx" label node "$sender_node" perf-role32=sender --overwrite >/dev/null

  kubectl --context "$ctx" -n "$NAMESPACE" create configmap "$SRC_CONFIGMAP" \
    --from-file=go.mod=go.mod \
    --from-file=reuseport-receiver.go=cmd/reuseport-receiver/main.go \
    --from-file=reuseport-client.go=cmd/reuseport-client/main.go \
    --dry-run=client -o yaml | kubectl --context "$ctx" apply -f - >/dev/null

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

  kubectl --context "$ctx" wait --for=condition=Ready "pod/${server}" --timeout=240s >/dev/null
  local target_ip
  target_ip="$(kubectl --context "$ctx" get pod "$server" -o jsonpath='{.status.podIP}')"

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

  # Capture Retina CPU mid-run (peak of two samples during steady state)
  sleep 45
  local cpu1 cpu2 retina_cpu
  cpu1="$(kubectl --context "$ctx" top pods -n kube-system -l app.kubernetes.io/name=retina --no-headers 2>/dev/null | awk 'NR>0{gsub("m","",$2); if($2>max)max=$2} END{print max+0}')"
  sleep 30
  cpu2="$(kubectl --context "$ctx" top pods -n kube-system -l app.kubernetes.io/name=retina --no-headers 2>/dev/null | awk 'NR>0{gsub("m","",$2); if($2>max)max=$2} END{print max+0}')"
  retina_cpu="$(awk -v a="${cpu1:-0}" -v b="${cpu2:-0}" 'BEGIN{print (a>b?a:b)"m"}')"

  kubectl --context "$ctx" wait --for=condition=complete "job/${job}" --timeout=600s >/dev/null

  # Receiver-side throughput: MEDIAN of non-zero interval_gbps windows (robust
  # to ramp-up and drain outliers). This is the stable steady-state average.
  local recv_gbps errors
  recv_gbps="$(kubectl --context "$ctx" logs "$server" --tail=80 \
    | grep -oE 'interval_gbps=[0-9.]+' | cut -d= -f2 \
    | awk '$1>0.05' | sort -n \
    | awk '{a[NR]=$1} END{ if(NR==0){print 0} else if(NR%2){printf "%.2f", a[(NR+1)/2]} else {printf "%.2f", (a[NR/2]+a[NR/2+1])/2} }')"
  errors="$(kubectl --context "$ctx" logs "$server" --tail=80 | grep -oE 'errors=[0-9]+' | cut -d= -f2 | sort -rn | head -1)"

  kubectl --context "$ctx" delete pod "$server" --ignore-not-found >/dev/null 2>&1 || true
  kubectl --context "$ctx" delete job "$job" --ignore-not-found >/dev/null 2>&1 || true

  echo "${recv_gbps:-0}|${retina_cpu:-NA}|${errors:-0}"
}

echo "Sweep ${SWEEP_ID}: DURATION=${DURATION} CONNECTIONS=${CONNECTIONS}"
echo "Payload sizes: ${PAYLOAD_SIZES[*]}"
echo ""

for payload in "${PAYLOAD_SIZES[@]}"; do
  echo "=== Payload ${payload} bytes ==="

  echo "  [perf-array] running on ${PERF_CTX}..."
  perf_result="$(run_one "$PERF_CTX" "$payload" "$CONNECTIONS" "perf${payload}")"
  IFS='|' read -r perf_gbps perf_cpu perf_err <<< "$perf_result"

  echo "  [ring-buffer] running on ${RING_CTX}..."
  ring_result="$(run_one "$RING_CTX" "$payload" "$CONNECTIONS" "ring${payload}")"
  IFS='|' read -r ring_gbps ring_cpu ring_err <<< "$ring_result"

  winner="$(awk -v p="$perf_gbps" -v r="$ring_gbps" 'BEGIN { if (r > p*1.03) print "ring-buffer"; else if (p > r*1.03) print "perf-array"; else print "tie"; }')"

  echo "  perf-array=${perf_gbps} Gbps (cpu ${perf_cpu}, err ${perf_err}) | ring-buffer=${ring_gbps} Gbps (cpu ${ring_cpu}, err ${ring_err}) | winner=${winner}"
  echo "${payload},${CONNECTIONS},${perf_gbps},${ring_gbps},${winner},${perf_cpu},${ring_cpu},${perf_err},${ring_err}" >> "$SUMMARY"
  echo ""
done

echo "=== SWEEP COMPLETE ==="
column -t -s, "$SUMMARY"
echo ""
echo "Summary saved to: $SUMMARY"
