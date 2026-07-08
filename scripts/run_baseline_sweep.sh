#!/usr/bin/env bash
# =============================================================================
# run_baseline_sweep.sh — No-Retina baseline throughput across payload sizes
# =============================================================================
#
# Runs the reuseport workload on a single cluster (no Retina installed) across
# the same payload sizes used by run_buffer_crossover_sweep.sh, producing the
# true baseline ceiling for each payload. Combine with the buffer sweep for a
# 3-way comparison: no-Retina vs perf-array vs ring-buffer.
#
# Metric: MEDIAN of non-zero receiver interval_gbps (stable steady-state).
#
# USAGE:
#   BASELINE_CTX=retina-bench-noretina \
#   PAYLOAD_SIZES="512 1024 2048 4096 8192 16384 65536" CONNECTIONS=165 DURATION=120s \
#   ./scripts/run_baseline_sweep.sh
# =============================================================================
set -euo pipefail

CTX="${BASELINE_CTX:-retina-bench-noretina}"
NAMESPACE="default"
IMAGE="golang:1.24.5-bookworm"
SRC_CONFIGMAP="reuseport-src"
DURATION="${DURATION:-120s}"
LISTENERS=31
WORKERS=124
RECEIVER_GOMAXPROCS=31
CLIENT_GOMAXPROCS=3
CLIENT_PODS=15
PAYLOAD_SIZES=(${PAYLOAD_SIZES:-512 1024 2048 4096 8192 16384 65536})
CONNECTIONS="${CONNECTIONS:-165}"

OUTDIR="results/buffer_crossover"
mkdir -p "$OUTDIR"
SWEEP_ID="$(date -u +%Y%m%dT%H%M%SZ)"
SUMMARY="$OUTDIR/${SWEEP_ID}_baseline_summary.csv"
echo "payload_bytes,connections,baseline_gbps,conn_errors" > "$SUMMARY"

run_one() {
  local payload="$1" conns="$2" tag="$3"
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

  kubectl --context "$CTX" wait --for=condition=Ready "pod/${server}" --timeout=240s >/dev/null
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

  kubectl --context "$CTX" wait --for=condition=complete "job/${job}" --timeout=600s >/dev/null

  local recv_gbps errors
  recv_gbps="$(kubectl --context "$CTX" logs "$server" --tail=80 \
    | grep -oE 'interval_gbps=[0-9.]+' | cut -d= -f2 \
    | awk '$1>0.05' | sort -n \
    | awk '{a[NR]=$1} END{ if(NR==0){print 0} else if(NR%2){printf "%.2f", a[(NR+1)/2]} else {printf "%.2f", (a[NR/2]+a[NR/2+1])/2} }')"
  errors="$(kubectl --context "$CTX" logs "$server" --tail=80 | grep -oE 'errors=[0-9]+' | cut -d= -f2 | sort -rn | head -1)"

  kubectl --context "$CTX" delete pod "$server" --ignore-not-found >/dev/null 2>&1 || true
  kubectl --context "$CTX" delete job "$job" --ignore-not-found >/dev/null 2>&1 || true

  echo "${recv_gbps:-0}|${errors:-0}"
}

echo "Baseline sweep ${SWEEP_ID} on ${CTX}: DURATION=${DURATION} CONNECTIONS=${CONNECTIONS}"
echo "Payload sizes: ${PAYLOAD_SIZES[*]}"
echo ""

for payload in "${PAYLOAD_SIZES[@]}"; do
  echo "=== Payload ${payload} bytes (baseline, no Retina) ==="
  result="$(run_one "$payload" "$CONNECTIONS" "base${payload}")"
  IFS='|' read -r gbps err <<< "$result"
  echo "  baseline=${gbps} Gbps (err ${err})"
  echo "${payload},${CONNECTIONS},${gbps},${err}" >> "$SUMMARY"
  echo ""
done

echo "=== BASELINE SWEEP COMPLETE ==="
column -t -s, "$SUMMARY"
echo ""
echo "Summary saved to: $SUMMARY"
