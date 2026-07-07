#!/usr/bin/env bash
# =============================================================================
# run_reuseport_ab.sh — A/B Throughput Benchmark: Baseline vs Retina
# =============================================================================
#
# PURPOSE:
#   Measures the throughput overhead of Microsoft Retina's packetparser plugin
#   on high-core-count (32+) nodes under sustained multi-core network load.
#   Reproduces the findings from:
#     https://blog.zmalik.dev/p/who-will-observe-the-observability
#
# METHODOLOGY:
#   Phase A (Baseline): Retina is fully uninstalled via helm. Traffic runs
#     through pod networking (veths) with zero eBPF observability overhead.
#   Phase B (With Retina): Retina is freshly installed in Advanced Mode with
#     packetparser enabled. TC-BPF programs attach to pod veths, generating
#     per-packet events through perf_event_arrays on all 32 CPU cores.
#   Both phases use identical workload, nodes, and networking path.
#
# TRAFFIC GENERATION:
#   - Receiver: SO_REUSEPORT with N listeners + 4N workers (kernel distributes
#     SYN packets across listeners by flow hash)
#   - Sender: 15 client pods, each opening ~17 TCP connections, writing
#     PAYLOAD_BYTES per write() call in a tight loop for DURATION
#   - Total flows: FLOWS_PER_CORE × effective_active_cores (default: 248)
#   - Pod networking (no hostNetwork) so packetparser sees traffic on veths
#
# THROUGHPUT MEASUREMENT:
#   - Sender-side: sum(bytes_written × 8 / elapsed) across all client pods
#   - Receiver-side (authoritative): total_bytes_read × 8 / elapsed
#     (receiver outputs JSON on SIGTERM with gbps_received)
#   - Overhead = (baseline_gbps - retina_gbps) / baseline_gbps × 100
#
# RESOURCE CAPTURE:
#   Mid-test (at 15s mark): kubectl top nodes + kubectl top pods for Retina
#   agents and benchmark pods. Saved to per-phase resource files.
#
# RETINA INSTALLATION (for Phase B):
#   helm upgrade --install retina oci://ghcr.io/microsoft/retina/charts/retina \
#     --version v1.2.2 \
#     --namespace kube-system \
#     --set image.tag=v1.2.2 \
#     --set operator.tag=v1.2.2 \
#     --set image.pullPolicy=Always \
#     --set logLevel=info \
#     --set operator.enabled=true \
#     --set operator.enableRetinaEndpoint=true \
#     --set enabledPlugin_linux="\[dropreason\,packetforward\,linuxutil\,dns\,packetparser\]" \
#     --set enablePodLevel=true \
#     --set enableAnnotations=true
#
#   Then the default namespace is annotated: retina.sh=observe
#   This enables Advanced Mode with Local Context, producing metrics:
#     - networkobservability_adv_forward_count
#     - networkobservability_adv_forward_bytes
#     - networkobservability_adv_tcpflags_count
#     - networkobservability_adv_node_apiserver_latency
#     - networkobservability_adv_node_apiserver_no_response
#     - networkobservability_adv_node_apiserver_tcp_handshake_latency
#
# CLUSTER REQUIREMENTS:
#   - 2 Linux worker nodes with 32+ cores, tainted workload=benchmark:NoSchedule
#   - Nodes labeled workload=benchmark
#   - Azure CNI Overlay (networkPlugin=azure, networkPluginMode=overlay)
#   - kubectl, helm, jq available on the runner
#
# USAGE:
#   # On baseline cluster (no Retina):
#   kubectl config use-context retina-bench-baseline
#   ./scripts/run_reuseport_ab.sh --node-label workload=benchmark --active-cores 32
#
#   # On Retina cluster (with Retina advanced mode pre-installed):
#   kubectl config use-context retina-bench-withretina
#   ./scripts/run_reuseport_ab.sh --node-label workload=benchmark --active-cores 32
#
# RESULTS (observed on Standard_D32s_v3 nodes):
#   - 64KB payloads, 8 flows/core:  ~3% overhead (low packet rate)
#   - 1KB payloads, 80 flows/core: ~41% overhead (high packet rate)
#   Key insight: overhead scales with packets/second, not bandwidth.
# =============================================================================
set -euo pipefail

RETINA_LABEL_KEY="perf-test-retina"
RETINA_LABEL_VALUE="enabled"
RETINA_TARGET_LABEL_KEY="perf-ab-target"
RETINA_TARGET_LABEL_VALUE="true"
RETINA_RELEASE_NAME="retina"
RETINA_NAMESPACE="kube-system"
RETINA_VERSION="v1.2.2"
NAMESPACE="default"
SERVER_NAME="reuseport-receiver32"
CLIENT_JOB_PREFIX="reuseport-client"
SERVER_PORT="9000"
NODE_LABEL=""
TARGET_ACTIVE_CORES="32"
FLOWS_PER_CORE="8"
CLIENT_PODS=""
CONNECTIONS_PER_POD=""
DURATION="180s"
LISTENERS=""
WORKERS=""
RECEIVER_GOMAXPROCS=""
CLIENT_GOMAXPROCS=""
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

Runs a controlled no-Retina vs with-Retina benchmark using a topology-driven
SO_REUSEPORT receiver and multiple TCP flood client pods. By default it shapes a
32-active-core workload regardless of which cluster it runs on, as long as two
Linux worker nodes are available.

Options:
  --node-label <selector>        Optional node selector for candidate workers
  --active-cores <n>             Target active data-plane cores (default: 32)
  --flows-per-core <n>           Long-lived flows to drive per active core (default: 8)
  --client-pods <n>              Number of parallel client pods (auto-derived by default)
  --connections-per-pod <n>      Long-lived TCP connections per client pod (auto-derived by default)
  --duration <duration>          Test duration, e.g. 30s (default: 30s)
  --listeners <n>                Number of receiver listeners (defaults to active cores)
  --workers <n>                  Number of receiver workers (defaults to active cores x 4)
  --receiver-gomaxprocs <n>      Receiver runtime threads (defaults to active cores)
  --client-gomaxprocs <n>        Client runtime threads per pod (auto-derived by default)
  --payload-bytes <n>            Client write size (default: 65536)
  --results-dir <dir>            Output directory (default: results/reuseport_ab)
  -h, --help                     Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --node-label)
      NODE_LABEL="$2"
      shift 2
      ;;
    --active-cores)
      TARGET_ACTIVE_CORES="$2"
      shift 2
      ;;
    --flows-per-core)
      FLOWS_PER_CORE="$2"
      shift 2
      ;;
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
    --receiver-gomaxprocs)
      RECEIVER_GOMAXPROCS="$2"
      shift 2
      ;;
    --client-gomaxprocs)
      CLIENT_GOMAXPROCS="$2"
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

ceil_div() {
  local numerator="$1"
  local denominator="$2"
  echo $(((numerator + denominator - 1) / denominator))
}

cpu_to_cores() {
  local cpu="$1"
  if [[ "$cpu" == *m ]]; then
    echo $(( ${cpu%m} / 1000 ))
  else
    echo "$cpu"
  fi
}

max_int() {
  local a="$1"
  local b="$2"
  if (( a > b )); then
    echo "$a"
  else
    echo "$b"
  fi
}

min_int() {
  local a="$1"
  local b="$2"
  if (( a < b )); then
    echo "$a"
  else
    echo "$b"
  fi
}

ensure_positive_int() {
  local name="$1"
  local value="$2"
  if ! [[ "$value" =~ ^[0-9]+$ ]] || (( value <= 0 )); then
    echo "${name} must be a positive integer, got '${value}'" >&2
    exit 1
  fi
}

wait_for_retina_state_on_selected_nodes() {
  local mode="$1"
  local attempts=60
  local attempt=1
  local matching_pods
  local ready_pods

  while (( attempt <= attempts )); do
    matching_pods="$( (k -n kube-system get pods -l app.kubernetes.io/name=retina -o json || true) | jq -r --arg receiver "$RECEIVER_NODE" --arg sender "$SENDER_NODE" '
      [.items[] | select(.spec.nodeName == $receiver or .spec.nodeName == $sender)] | length
    ')"

    if [[ "$mode" == "off" ]]; then
      if [[ "$matching_pods" == "0" ]]; then
        return 0
      fi
    else
      ready_pods="$( (k -n kube-system get pods -l app.kubernetes.io/name=retina -o json || true) | jq -r --arg receiver "$RECEIVER_NODE" --arg sender "$SENDER_NODE" '
        [
          .items[]
          | select(.spec.nodeName == $receiver or .spec.nodeName == $sender)
          | select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))
        ] | length
      ')"
      if [[ "$matching_pods" == "2" && "$ready_pods" == "2" ]]; then
        return 0
      fi
    fi

    sleep 5
    attempt=$((attempt + 1))
  done

  echo "Timed out waiting for Retina mode '${mode}' on selected nodes" >&2
  k -n kube-system get pods -l app.kubernetes.io/name=retina -o wide >&2 || true
  return 1
}

mkdir -p "$OUTDIR"
if [[ ! -d "$OUTDIR" ]]; then
  echo "Failed to create results directory: $OUTDIR" >&2
  exit 1
fi
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
SUMMARY_FILE="$OUTDIR/${RUN_ID}_summary.txt"
PROFILE_FILE="$OUTDIR/${RUN_ID}_profile.json"

ensure_positive_int active-cores "$TARGET_ACTIVE_CORES"
ensure_positive_int flows-per-core "$FLOWS_PER_CORE"
if [[ -n "$CLIENT_PODS" ]]; then
  ensure_positive_int client-pods "$CLIENT_PODS"
fi
if [[ -n "$CONNECTIONS_PER_POD" ]]; then
  ensure_positive_int connections-per-pod "$CONNECTIONS_PER_POD"
fi
if [[ -n "$LISTENERS" ]]; then
  ensure_positive_int listeners "$LISTENERS"
fi
if [[ -n "$WORKERS" ]]; then
  ensure_positive_int workers "$WORKERS"
fi
if [[ -n "$RECEIVER_GOMAXPROCS" ]]; then
  ensure_positive_int receiver-gomaxprocs "$RECEIVER_GOMAXPROCS"
fi
if [[ -n "$CLIENT_GOMAXPROCS" ]]; then
  ensure_positive_int client-gomaxprocs "$CLIENT_GOMAXPROCS"
fi

selector="kubernetes.io/os=linux"
if [[ -n "$NODE_LABEL" ]]; then
  selector="${NODE_LABEL},${selector}"
fi

mapfile -t POOL_NODES < <(k get nodes -l "$selector" -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.status.allocatable.cpu}{"|"}{.metadata.labels.node\.kubernetes\.io/instance-type}{"\n"}{end}' | sort)
if [[ ${#POOL_NODES[@]} -lt 2 ]]; then
  echo "Need at least 2 Linux nodes matching selector '${selector}', found ${#POOL_NODES[@]}" >&2
  exit 1
fi

IFS='|' read -r RECEIVER_NODE RECEIVER_ALLOCATABLE_CPU RECEIVER_INSTANCE_TYPE <<< "${POOL_NODES[0]}"
IFS='|' read -r SENDER_NODE SENDER_ALLOCATABLE_CPU SENDER_INSTANCE_TYPE <<< "${POOL_NODES[1]}"

RECEIVER_CORES="$(cpu_to_cores "$RECEIVER_ALLOCATABLE_CPU")"
SENDER_CORES="$(cpu_to_cores "$SENDER_ALLOCATABLE_CPU")"
AVAILABLE_CORES="$(min_int "$RECEIVER_CORES" "$SENDER_CORES")"
ACTIVE_CORES="$(min_int "$TARGET_ACTIVE_CORES" "$AVAILABLE_CORES")"
if (( ACTIVE_CORES <= 0 )); then
  echo "Selected nodes do not expose at least one full allocatable CPU core" >&2
  exit 1
fi

if [[ -z "$LISTENERS" ]]; then
  LISTENERS="$ACTIVE_CORES"
fi
if [[ -z "$WORKERS" ]]; then
  WORKERS="$((ACTIVE_CORES * 4))"
fi
if [[ -z "$CLIENT_PODS" ]]; then
  CLIENT_PODS="$(max_int 4 $((ACTIVE_CORES / 2)))"
fi
TOTAL_FLOWS="$((ACTIVE_CORES * FLOWS_PER_CORE))"
if [[ -z "$CONNECTIONS_PER_POD" ]]; then
  CONNECTIONS_PER_POD="$(ceil_div "$TOTAL_FLOWS" "$CLIENT_PODS")"
fi
if [[ -z "$RECEIVER_GOMAXPROCS" ]]; then
  RECEIVER_GOMAXPROCS="$ACTIVE_CORES"
fi
if [[ -z "$CLIENT_GOMAXPROCS" ]]; then
  CLIENT_GOMAXPROCS="$(max_int 1 "$(ceil_div "$ACTIVE_CORES" "$CLIENT_PODS")")"
fi

ACTUAL_TOTAL_FLOWS="$((CLIENT_PODS * CONNECTIONS_PER_POD))"

k label node "$RECEIVER_NODE" perf-role32=receiver --overwrite >/dev/null
k label node "$SENDER_NODE" perf-role32=sender --overwrite >/dev/null
k label node "$RECEIVER_NODE" "${RETINA_TARGET_LABEL_KEY}=${RETINA_TARGET_LABEL_VALUE}" --overwrite >/dev/null
k label node "$SENDER_NODE" "${RETINA_TARGET_LABEL_KEY}=${RETINA_TARGET_LABEL_VALUE}" --overwrite >/dev/null

cat > "$PROFILE_FILE" <<EOF
{
  "run_id": "${RUN_ID}",
  "node_selector": "${NODE_LABEL}",
  "selected_nodes": {
    "receiver": {
      "name": "${RECEIVER_NODE}",
      "allocatable_cpu": "${RECEIVER_ALLOCATABLE_CPU}",
      "instance_type": "${RECEIVER_INSTANCE_TYPE}"
    },
    "sender": {
      "name": "${SENDER_NODE}",
      "allocatable_cpu": "${SENDER_ALLOCATABLE_CPU}",
      "instance_type": "${SENDER_INSTANCE_TYPE}"
    }
  },
  "workload_shape": {
    "requested_active_cores": ${TARGET_ACTIVE_CORES},
    "effective_active_cores": ${ACTIVE_CORES},
    "flows_per_core": ${FLOWS_PER_CORE},
    "client_pods": ${CLIENT_PODS},
    "connections_per_pod": ${CONNECTIONS_PER_POD},
    "total_flows": ${ACTUAL_TOTAL_FLOWS},
    "listeners": ${LISTENERS},
    "workers": ${WORKERS},
    "receiver_gomaxprocs": ${RECEIVER_GOMAXPROCS},
    "client_gomaxprocs": ${CLIENT_GOMAXPROCS},
    "payload_bytes": ${PAYLOAD_BYTES}
  }
}
EOF

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
        --gomaxprocs ${RECEIVER_GOMAXPROCS}
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

ensure_retina_uninstalled() {
  helm uninstall "$RETINA_RELEASE_NAME" -n "$RETINA_NAMESPACE" >/dev/null 2>&1 || true
  wait_for_retina_state_on_selected_nodes off
}

install_retina_on_selected_nodes() {
  # Install Retina in Advanced Mode with Local Context
  # This enables packetparser to attach TC-BPF to pod veths and emit adv_* metrics
  helm upgrade --install "$RETINA_RELEASE_NAME" oci://ghcr.io/microsoft/retina/charts/retina \
    --version "$RETINA_VERSION" \
    --namespace "$RETINA_NAMESPACE" \
    --create-namespace \
    --set image.tag="$RETINA_VERSION" \
    --set operator.tag="$RETINA_VERSION" \
    --set image.pullPolicy=Always \
    --set logLevel=info \
    --set operator.enabled=true \
    --set operator.enableRetinaEndpoint=true \
    --set enabledPlugin_linux='\[dropreason\,packetforward\,linuxutil\,dns\,packetparser\]' \
    --set enablePodLevel=true \
    --set enableAnnotations=true >/dev/null

  # Annotate default namespace so packetparser observes benchmark pods
  k annotate namespace "$NAMESPACE" "retina.sh=observe" --overwrite >/dev/null 2>&1 || true

  # Patch DaemonSet to tolerate benchmark taint and target selected nodes
  k -n "$RETINA_NAMESPACE" patch ds retina-agent --type merge -p "{\"spec\":{\"template\":{\"spec\":{\"nodeSelector\":{\"kubernetes.io/os\":\"linux\",\"${RETINA_TARGET_LABEL_KEY}\":\"${RETINA_TARGET_LABEL_VALUE}\"},\"tolerations\":[{\"key\":\"workload\",\"operator\":\"Equal\",\"value\":\"benchmark\",\"effect\":\"NoSchedule\"}]}}}}" >/dev/null

  k -n "$RETINA_NAMESPACE" rollout status ds/retina-agent --timeout=300s >/dev/null
  wait_for_retina_state_on_selected_nodes on
  sleep 15
}

capture_resource_usage() {
  local label="$1"
  local file="$OUTDIR/${RUN_ID}_${label}_resources.txt"
  {
    echo "=== node resource usage ($label) ==="
    k top nodes --no-headers 2>/dev/null || true
    echo ""
    echo "=== retina-agent pod resource usage ($label) ==="
    k top pods -n kube-system -l app.kubernetes.io/name=retina --no-headers 2>/dev/null || true
    echo ""
    echo "=== benchmark pod resource usage ($label) ==="
    k top pods -l app=reuseport-client --no-headers 2>/dev/null || true
    k top pods --field-selector metadata.name="$SERVER_NAME" --no-headers 2>/dev/null || true
  } > "$file" 2>&1
  cat "$file"
}

PERF_EVENT_POD="perf-event-counter"

start_perf_event_counter() {
  k delete pod "$PERF_EVENT_POD" --ignore-not-found >/dev/null 2>&1 || true
  sleep 2
  cat <<'BPFPOD' | k create -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: perf-event-counter
  namespace: default
spec:
  restartPolicy: Never
  nodeSelector:
    perf-role32: receiver
  tolerations:
  - key: workload
    operator: Equal
    value: benchmark
    effect: NoSchedule
  hostPID: true
  volumes:
  - name: root
    hostPath:
      path: /
  containers:
  - name: bpftrace
    image: ubuntu:22.04
    securityContext:
      privileged: true
    volumeMounts:
    - name: root
      mountPath: /host
    command: ["chroot", "/host", "sh", "-c"]
    args:
      - |
        bpftrace -e '
          BEGIN { @streams = 0; @wakeups = 0; }
          kprobe:perf_event_output { @streams++; }
          kprobe:perf_event_wakeup { @wakeups++; }
          interval:s:5 {
            printf("{\"ts\":%d,\"streams_total\":%d,\"wakeups_total\":%d,\"streams_per_sec\":%d,\"wakeups_per_sec\":%d}\n",
              elapsed / 1000000000, @streams, @wakeups, @streams / (elapsed / 1000000000), @wakeups / (elapsed / 1000000000));
          }
          END {
            printf("{\"final\":true,\"streams_total\":%d,\"wakeups_total\":%d,\"elapsed_sec\":%d,\"streams_per_sec\":%d,\"wakeups_per_sec\":%d,\"wakeup_ratio_pct\":%.1f}\n",
              @streams, @wakeups, elapsed / 1000000000,
              @streams / (elapsed / 1000000000), @wakeups / (elapsed / 1000000000),
              @wakeups * 100.0 / (@streams > 0 ? @streams : 1));
          }
        ' 2>/dev/null
BPFPOD
  k wait --for=condition=Ready pod/"$PERF_EVENT_POD" --timeout=60s >/dev/null 2>&1 || true
}

stop_perf_event_counter() {
  local tag="$1"
  local out_file="$OUTDIR/${RUN_ID}_${tag}_perf_events.json"
  # Send SIGINT to bpftrace to trigger END block
  k exec "$PERF_EVENT_POD" -- chroot /host sh -c 'killall -INT bpftrace' >/dev/null 2>&1 || true
  sleep 3
  k logs "$PERF_EVENT_POD" --tail=20 | grep '^{' | tail -1 > "$out_file" 2>/dev/null || true
  k delete pod "$PERF_EVENT_POD" --ignore-not-found >/dev/null 2>&1 || true
  cat "$out_file" 2>/dev/null || echo "{}"
}

run_clients() {
  local tag="$1"
  local job_tag
  local target_ip
  job_tag="${tag//_/-}"
  target_ip="$(k get pod "$SERVER_NAME" -o jsonpath='{.status.podIP}')"

  mkdir -p "$OUTDIR"

  # Start perf_event counter on receiver node
  start_perf_event_counter

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
            --gomaxprocs ${CLIENT_GOMAXPROCS}
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
  # Capture resource usage mid-test (after ~15s of traffic)
  (sleep 15 && capture_resource_usage "${tag}_during" >/dev/null 2>&1) &
  local capture_pid=$!

  k wait --for=condition=complete "job/${CLIENT_JOB_PREFIX}-${job_tag}" --timeout=900s >/dev/null
  wait "$capture_pid" 2>/dev/null || true

  # Signal receiver to stop and emit its JSON summary
  k exec "$SERVER_NAME" -- kill -TERM 1 >/dev/null 2>&1 || true
  sleep 3
  local receiver_file="$OUTDIR/${RUN_ID}_${tag}_receiver.json"
  k logs "$SERVER_NAME" --tail=5 | grep '^{' | tail -1 > "$receiver_file" 2>/dev/null || true

  local logs_file="$OUTDIR/${RUN_ID}_${tag}_clients.jsonl"
  k logs -l job-name="${CLIENT_JOB_PREFIX}-${job_tag}" --tail=-1 > "$logs_file"

  local receiver_gbps
  receiver_gbps="$(jq -r '.gbps_received // 0' "$receiver_file" 2>/dev/null || echo 0)"

  jq -s --arg tag "$tag" --arg receiver_gbps "$receiver_gbps" '
    map(select(type == "object"))
    | {
        tag: $tag,
        pods: length,
        sender_total_gbps: ((map(.bits_per_second) | add) / 1e9),
        receiver_gbps: ($receiver_gbps | tonumber),
        total_bytes_sent: (map(.bytes_sent) | add),
        total_connect_errors: (map(.connect_errors) | add),
        total_write_errors: (map(.write_errors) | add)
      }
  ' "$logs_file"
}

deploy_server

ensure_retina_uninstalled
mkdir -p "$OUTDIR"
BASELINE_JSON="$(run_clients baseline | tee "$OUTDIR/${RUN_ID}_baseline_summary.json")"

install_retina_on_selected_nodes
mkdir -p "$OUTDIR"
WITH_RETINA_JSON="$(run_clients with_retina | tee "$OUTDIR/${RUN_ID}_with_retina_summary.json")"

BASELINE_GBPS="$(printf '%s' "$BASELINE_JSON" | jq -r '.receiver_gbps // .sender_total_gbps')"
WITH_RETINA_GBPS="$(printf '%s' "$WITH_RETINA_JSON" | jq -r '.receiver_gbps // .sender_total_gbps')"

{
  echo "run_id=${RUN_ID}"
  echo "profile_file=${PROFILE_FILE}"
  echo "node_selector=${NODE_LABEL:-<any-linux-worker>}"
  echo "receiver_node=${RECEIVER_NODE}"
  echo "sender_node=${SENDER_NODE}"
  echo "requested_active_cores=${TARGET_ACTIVE_CORES}"
  echo "effective_active_cores=${ACTIVE_CORES}"
  echo "flows_per_core=${FLOWS_PER_CORE}"
  echo "client_pods=${CLIENT_PODS}"
  echo "connections_per_pod=${CONNECTIONS_PER_POD}"
  echo "total_flows=${ACTUAL_TOTAL_FLOWS}"
  echo "listeners=${LISTENERS}"
  echo "workers=${WORKERS}"
  echo "receiver_gomaxprocs=${RECEIVER_GOMAXPROCS}"
  echo "client_gomaxprocs=${CLIENT_GOMAXPROCS}"
  echo "baseline_json=$BASELINE_JSON"
  echo "with_retina_json=$WITH_RETINA_JSON"
  awk -v b="$BASELINE_GBPS" -v r="$WITH_RETINA_GBPS" 'BEGIN { printf("baseline_gbps=%.2f\nwith_retina_gbps=%.2f\noverhead_pct=%.1f\n", b, r, (b-r)*100/b) }'
  echo ""
  echo "=== resource usage during baseline ==="
  cat "$OUTDIR/${RUN_ID}_baseline_during_resources.txt" 2>/dev/null || echo "(not captured)"
  echo ""
  echo "=== resource usage during with_retina ==="
  cat "$OUTDIR/${RUN_ID}_with_retina_during_resources.txt" 2>/dev/null || echo "(not captured)"
} | tee "$SUMMARY_FILE"