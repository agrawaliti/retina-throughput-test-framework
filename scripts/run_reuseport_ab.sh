#!/usr/bin/env bash
set -euo pipefail

POOL_LABEL="agentpool=usr32"
RETINA_LABEL_KEY="perf-test-retina"
RETINA_LABEL_VALUE="enabled"
NAMESPACE="default"
SERVER_NAME="reuseport-receiver32"
CLIENT_JOB_PREFIX="reuseport-client"
SERVER_PORT="9000"
CLIENT_PODS="16"
CONNECTIONS_PER_POD="16"
DURATION="30s"
LISTENERS="32"
WORKERS="128"
PAYLOAD_BYTES="65536"
IMAGE="golang:1.24.5-bookworm"
OUTDIR_DEFAULT="results/reuseport_ab"
OUTDIR="$OUTDIR_DEFAULT"
SRC_CONFIGMAP="reuseport-src"

retry_cmd() {
  local max_attempts="${RETRY_MAX_ATTEMPTS:-5}"
  local attempt=1
  while true; do
    if "$@"; then
      return 0
    fi
    if [[ $attempt -ge $max_attempts ]]; then
      echo "Command failed after ${max_attempts} attempts: $*" >&2
      return 1
    fi
    sleep $((attempt * 2))
    attempt=$((attempt + 1))
  done
}

k() {
  retry_cmd kubectl "$@"
}

usage() {
  cat <<'EOF'
Usage: run_reuseport_ab.sh [options]

Runs a controlled no-Retina vs with-Retina benchmark on the usr32 nodepool using
a SO_REUSEPORT receiver and multiple TCP flood client pods.

Options:
  --client-pods <n>             Number of parallel client pods (default: 16)
  --connections-per-pod <n>     Long-lived TCP connections per client pod (default: 16)
  --duration <duration>         Test duration, e.g. 30s (default: 30s)
  --listeners <n>               Number of receiver listeners (default: 32)
  --workers <n>                 Number of receiver workers (default: 128)
  --payload-bytes <n>           Client write size (default: 65536)
  --results-dir <dir>           Output directory (default: results/reuseport_ab)
  -h, --help                    Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --client-pods)
      CLIENT_PODS="$2"
      shift 2
      ;;
    --connections-per-pod)
      CONNECTIONS_PER_POD="$2"
      shift 2
      ;;
    --duration)
      DURATION="$2"
      shift 2
      ;;
    --listeners)
      LISTENERS="$2"
      shift 2
      ;;
    --workers)
      WORKERS="$2"
      shift 2
      ;;
    --payload-bytes)
      PAYLOAD_BYTES="$2"
      shift 2
      ;;
    --results-dir)
      OUTDIR="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

mkdir -p "$OUTDIR"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
SUMMARY_FILE="$OUTDIR/${RUN_ID}_summary.txt"

mapfile -t POOL_NODES < <(k get nodes -l "$POOL_LABEL" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
if [[ ${#POOL_NODES[@]} -lt 2 ]]; then
  echo "Need at least 2 nodes matching label '$POOL_LABEL', found ${#POOL_NODES[@]}" >&2
  exit 1
fi

RECEIVER_NODE="${POOL_NODES[0]}"
SENDER_NODE="${POOL_NODES[1]}"
k label node "$RECEIVER_NODE" perf-role32=receiver --overwrite >/dev/null
k label node "$SENDER_NODE" perf-role32=sender --overwrite >/dev/null

cleanup() {
  k delete pod "$SERVER_NAME" --ignore-not-found >/dev/null 2>&1 || true
  k delete jobs -l app=reuseport-client --ignore-not-found >/dev/null 2>&1 || true
}
trap cleanup EXIT

create_source_configmap() {
  k -n "$NAMESPACE" create configmap "$SRC_CONFIGMAP" \
    --from-file=go.mod=go.mod \
    --from-file=reuseport-receiver.go=cmd/reuseport-receiver/main.go \
    --from-file=reuseport-client.go=cmd/reuseport-client/main.go \
    --dry-run=client -o yaml | k apply -f - >/dev/null
}

deploy_server() {
  cleanup
  create_source_configmap
  cat <<EOF | k create -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: ${SERVER_NAME}
  namespace: ${NAMESPACE}
spec:
  restartPolicy: Never
  nodeSelector:
    perf-role32: receiver
  hostNetwork: true
  containers:
  - name: receiver
    image: ${IMAGE}
    workingDir: /workspace
    command: ["/bin/sh", "-lc"]
    args:
      - >-
        export PATH=/usr/local/go/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin &&
        mkdir -p /workspace/cmd/reuseport-receiver /workspace/cmd/reuseport-client &&
        cp /src/go.mod /workspace/go.mod &&
        cp /src/reuseport-receiver.go /workspace/cmd/reuseport-receiver/main.go &&
        cp /src/reuseport-client.go /workspace/cmd/reuseport-client/main.go &&
        go run ./cmd/reuseport-receiver
        --listen-addr :${SERVER_PORT}
        --listeners ${LISTENERS}
        --workers ${WORKERS}
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
EOF
  k wait --for=condition=Ready "pod/${SERVER_NAME}" --timeout=240s >/dev/null
}

set_retina_on_usr32() {
  local mode="$1"
  local desired
  if [[ "$mode" == "off" ]]; then
    k label node -l "$POOL_LABEL" "${RETINA_LABEL_KEY}-" --overwrite >/dev/null 2>&1 || true
  else
    k label node -l "$POOL_LABEL" "${RETINA_LABEL_KEY}=${RETINA_LABEL_VALUE}" --overwrite >/dev/null
  fi

  desired="$(k -n kube-system get ds/retina-agent -o jsonpath='{.status.desiredNumberScheduled}')"
  if [[ "$desired" == "0" ]]; then
    return 0
  fi

  k -n kube-system rollout status ds/retina-agent --timeout=300s >/dev/null

  # Allow data-path hooks to settle before measuring the with-retina phase.
  if [[ "$mode" != "off" ]]; then
    sleep 15
  fi
}

run_clients() {
  local tag="$1"
  local job_tag
  local target_ip
  job_tag="${tag//_/-}"
  target_ip="$(k get pod "$SERVER_NAME" -o jsonpath='{.status.podIP}')"

  # Avoid AlreadyExists from interrupted previous runs.
  k delete "job/${CLIENT_JOB_PREFIX}-${job_tag}" --ignore-not-found >/dev/null 2>&1 || true

  create_source_configmap
  cat <<EOF | k create -f - >/dev/null
apiVersion: batch/v1
kind: Job
metadata:
  name: ${CLIENT_JOB_PREFIX}-${job_tag}
  namespace: ${NAMESPACE}
  labels:
    app: reuseport-client
spec:
  parallelism: ${CLIENT_PODS}
  completions: ${CLIENT_PODS}
  completionMode: Indexed
  template:
    metadata:
      labels:
        app: reuseport-client
    spec:
      restartPolicy: Never
      nodeSelector:
        perf-role32: sender
      hostNetwork: true
      containers:
      - name: client
        image: ${IMAGE}
        workingDir: /workspace
        command: ["/bin/sh", "-lc"]
        args:
          - >-
            export PATH=/usr/local/go/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin &&
            mkdir -p /workspace/cmd/reuseport-receiver /workspace/cmd/reuseport-client &&
            cp /src/go.mod /workspace/go.mod &&
            cp /src/reuseport-receiver.go /workspace/cmd/reuseport-receiver/main.go &&
            cp /src/reuseport-client.go /workspace/cmd/reuseport-client/main.go &&
            go run ./cmd/reuseport-client
            --target ${target_ip}:${SERVER_PORT}
            --connections ${CONNECTIONS_PER_POD}
            --duration ${DURATION}
            --payload-bytes ${PAYLOAD_BYTES}
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
EOF
  k wait --for=condition=complete "job/${CLIENT_JOB_PREFIX}-${job_tag}" --timeout=900s >/dev/null

  local logs_file="$OUTDIR/${RUN_ID}_${tag}_clients.jsonl"
  k logs -l job-name="${CLIENT_JOB_PREFIX}-${job_tag}" --tail=-1 > "$logs_file"
  jq -s --arg tag "$tag" '
    map(select(type == "object"))
    | {
        tag: $tag,
        pods: length,
        total_bits_per_second: (map(.bits_per_second) | add),
        total_gbps: ((map(.bits_per_second) | add) / 1e9),
        total_bytes_sent: (map(.bytes_sent) | add),
        total_connect_errors: (map(.connect_errors) | add),
        total_write_errors: (map(.write_errors) | add)
      }
  ' "$logs_file"
}

deploy_server

set_retina_on_usr32 off
BASELINE_JSON="$(run_clients baseline | tee "$OUTDIR/${RUN_ID}_baseline_summary.json")"

set_retina_on_usr32 on
WITH_RETINA_JSON="$(run_clients with_retina | tee "$OUTDIR/${RUN_ID}_with_retina_summary.json")"

BASELINE_GBPS="$(printf '%s' "$BASELINE_JSON" | jq -r '.total_gbps')"
WITH_RETINA_GBPS="$(printf '%s' "$WITH_RETINA_JSON" | jq -r '.total_gbps')"

{
  echo "run_id=${RUN_ID}"
  echo "baseline_json=$BASELINE_JSON"
  echo "with_retina_json=$WITH_RETINA_JSON"
  awk -v b="$BASELINE_GBPS" -v r="$WITH_RETINA_GBPS" 'BEGIN { printf("baseline_gbps=%.2f\nwith_retina_gbps=%.2f\noverhead_pct=%.1f\n", b, r, (b-r)*100/b) }'
} | tee "$SUMMARY_FILE"