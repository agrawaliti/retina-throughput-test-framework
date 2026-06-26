#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

CLIENT_PODS="4"
CONNECTIONS_PER_POD="8"
DURATION="10s"
LISTENERS="16"
WORKERS="64"
PAYLOAD_BYTES="65536"
RESULTS_DIR_DEFAULT="$ROOT_DIR/results/ringbuf_capture"
RESULTS_DIR="$RESULTS_DIR_DEFAULT"
NIC=""
NODE_NAME=""
POD_IMAGE="ubuntu:22.04"
CAPTURE_DURATION="30"
CAPTURE_INTERVAL="1"
CAPTURE_TAG="ringbuf"

usage() {
  cat <<'EOF'
Usage: run_ringbuf_capture.sh [options]

Runs the ringbuf benchmark and captures perf + bpftool telemetry from the receiver.
The capture pod mounts the host's own perf/bpftool binaries so no kernel-version
package install is needed.

Options:
  --client-pods <n>             Number of client pods (default: 4)
  --connections-per-pod <n>     Connections per client pod (default: 8)
  --duration <duration>         Benchmark duration (default: 10s)
  --listeners <n>               Receiver listeners (default: 16)
  --workers <n>                 Receiver workers (default: 64)
  --payload-bytes <n>           Client payload size (default: 65536)
  --results-dir <dir>           Output directory for benchmark results
  --nic <name>                  Receiver NIC name for telemetry capture (required)
  --node <name>                 Receiver node name for telemetry capture (required)
  --pod-image <image>           Capture pod image (default: ubuntu:22.04)
  --capture-duration <seconds>  Telemetry capture duration (default: 30)
  --capture-interval <seconds>  Telemetry sampling interval (default: 1)
  --capture-tag <name>          Telemetry capture label (default: ringbuf)
  -h, --help                    Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --client-pods)       CLIENT_PODS="$2";       shift 2 ;;
    --connections-per-pod) CONNECTIONS_PER_POD="$2"; shift 2 ;;
    --duration)          DURATION="$2";          shift 2 ;;
    --listeners)         LISTENERS="$2";         shift 2 ;;
    --workers)           WORKERS="$2";           shift 2 ;;
    --payload-bytes)     PAYLOAD_BYTES="$2";     shift 2 ;;
    --results-dir)       RESULTS_DIR="$2";       shift 2 ;;
    --nic)               NIC="$2";               shift 2 ;;
    --node)              NODE_NAME="$2";          shift 2 ;;
    --pod-image)         POD_IMAGE="$2";         shift 2 ;;
    --capture-duration)  CAPTURE_DURATION="$2";  shift 2 ;;
    --capture-interval)  CAPTURE_INTERVAL="$2";  shift 2 ;;
    --capture-tag)       CAPTURE_TAG="$2";       shift 2 ;;
    -h|--help)           usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

if [[ -z "$NIC" ]]; then
  echo "--nic is required for telemetry capture" >&2; exit 1
fi
if [[ -z "$NODE_NAME" ]]; then
  echo "--node is required for telemetry capture" >&2; exit 1
fi

mkdir -p "$RESULTS_DIR"

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
RUN_LOG="$RESULTS_DIR/${RUN_ID}_ringbuf_capture.log"

echo "Starting ringbuf benchmark and capture run: $RUN_ID" | tee "$RUN_LOG"

echo "1/2: starting perf + bpftool telemetry capture" | tee -a "$RUN_LOG"
CAPTURE_DIR="$RESULTS_DIR/${RUN_ID}_capture"
mkdir -p "$CAPTURE_DIR"
CAPTURE_POD_NAME="ringbuf-capture-$(printf '%s' "$RUN_ID" | tr '[:upper:]' '[:lower:]')"

# Write the pod YAML using a quoted heredoc (no shell expansion in the template).
# Placeholders are substituted with sed after writing.
cat > "$CAPTURE_DIR/capture-pod.yaml" <<'YAML'
apiVersion: v1
kind: Pod
metadata:
  name: POD_NAME_PLACEHOLDER
  namespace: default
spec:
  hostPID: true
  restartPolicy: Never
  nodeSelector:
    kubernetes.io/hostname: NODE_NAME_PLACEHOLDER
  containers:
  - name: capture
    image: POD_IMAGE_PLACEHOLDER
    securityContext:
      privileged: true
    command: ["/bin/bash", "-c"]
    args:
      - |
        set -euo pipefail
        echo "=== capture starting ==="

        # Run perf via chroot into the host filesystem so all host libraries
        # are available (perf is a host binary and needs host glibc etc.)
        HOST_ROOT=/host-root
        HOST_KERNEL=$(chroot "$HOST_ROOT" uname -r 2>/dev/null || uname -r)

        # Resolve the perf path inside the chroot
        PERF_INNER=/usr/lib/linux-tools/${HOST_KERNEL}/perf
        if ! chroot "$HOST_ROOT" test -x "$PERF_INNER" 2>/dev/null; then
          PERF_INNER=$(chroot "$HOST_ROOT" find /usr/lib -name perf -type f 2>/dev/null | head -1 || true)
        fi
        if [[ -z "$PERF_INNER" ]]; then
          echo "ERROR: perf binary not found inside host chroot (kernel=$HOST_KERNEL)" >&2
          exit 1
        fi
        # Wrapper: runs any command inside the host chroot
        PERF_BIN="chroot $HOST_ROOT $PERF_INNER"
        echo "perf (via chroot): $PERF_INNER"

        # bpftool via chroot as well
        BPFTOOL_INNER=$(chroot "$HOST_ROOT" /bin/bash -lc 'command -v bpftool' 2>/dev/null || true)
        if [[ -z "$BPFTOOL_INNER" ]]; then
          BPFTOOL_INNER=$(chroot "$HOST_ROOT" find /usr/sbin -maxdepth 1 -name 'bpftool*' -type f 2>/dev/null | head -1 || true)
        fi
        if [[ -z "$BPFTOOL_INNER" ]]; then
          echo "WARNING: bpftool not found in host, skipping bpf snapshots"
          BPFTOOL_BIN=""
        else
          BPFTOOL_BIN="chroot $HOST_ROOT $BPFTOOL_INNER"
          echo "bpftool (via chroot): $BPFTOOL_INNER"
        fi

        # Install flamegraph scripts (small perl scripts, no kernel deps)
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq 2>&1 | tail -1
        apt-get install -y --no-install-recommends perl curl wget ca-certificates 2>&1 | tail -3 || true
        # Download FlameGraph tools from GitHub if not already present
        if [[ ! -f /usr/local/bin/stackcollapse-perf.pl ]]; then
          curl -fsSL https://raw.githubusercontent.com/brendangregg/FlameGraph/master/stackcollapse-perf.pl \
            -o /usr/local/bin/stackcollapse-perf.pl 2>/dev/null \
            || wget -qO /usr/local/bin/stackcollapse-perf.pl \
               https://raw.githubusercontent.com/brendangregg/FlameGraph/master/stackcollapse-perf.pl 2>/dev/null \
            || true
          chmod +x /usr/local/bin/stackcollapse-perf.pl 2>/dev/null || true
        fi
        if [[ ! -f /usr/local/bin/flamegraph.pl ]]; then
          curl -fsSL https://raw.githubusercontent.com/brendangregg/FlameGraph/master/flamegraph.pl \
            -o /usr/local/bin/flamegraph.pl 2>/dev/null \
            || wget -qO /usr/local/bin/flamegraph.pl \
               https://raw.githubusercontent.com/brendangregg/FlameGraph/master/flamegraph.pl 2>/dev/null \
            || true
          chmod +x /usr/local/bin/flamegraph.pl 2>/dev/null || true
        fi
        FG_COLLAPSE=/usr/local/bin/stackcollapse-perf.pl
        FG_RENDER=/usr/local/bin/flamegraph.pl
        if [[ ! -x "$FG_COLLAPSE" ]]; then
          FG_COLLAPSE=""
        fi
        if [[ ! -x "$FG_RENDER" ]]; then
          FG_RENDER=""
        fi
        echo "stackcollapse-perf.pl: ${FG_COLLAPSE:-not found}"
        echo "flamegraph.pl: ${FG_RENDER:-not found}"

        mkdir -p /capture
        TS=$(date -u +%Y%m%dT%H%M%SZ)
        RUN_DIR=/capture/$TS
        mkdir -p "$RUN_DIR"

        echo capture_tag=CAPTURE_TAG_PLACEHOLDER > "$RUN_DIR/meta.env"
        echo node=NODE_NAME_PLACEHOLDER          >> "$RUN_DIR/meta.env"
        echo nic=NIC_PLACEHOLDER                 >> "$RUN_DIR/meta.env"
        echo kernel=$HOST_KERNEL                 >> "$RUN_DIR/meta.env"
        echo perf=$PERF_BIN                      >> "$RUN_DIR/meta.env"

        cat /proc/softirqs   > "$RUN_DIR/softirqs.before.txt"
        cat /proc/interrupts > "$RUN_DIR/interrupts.before.txt"

        if [[ -n "$BPFTOOL_BIN" ]]; then
          eval "$BPFTOOL_BIN" prog show > "$RUN_DIR/bpftool.prog.before.txt" 2>&1 || true
          eval "$BPFTOOL_BIN" map  show > "$RUN_DIR/bpftool.map.before.txt"  2>&1 || true
          eval "$BPFTOOL_BIN" link show > "$RUN_DIR/bpftool.link.before.txt" 2>&1 || true
          eval "$BPFTOOL_BIN" net  show > "$RUN_DIR/bpftool.net.before.txt"  2>&1 || true
        fi

        # perf runs in host chroot, so output path must exist in host FS.
        PERF_HOST_OUT="/tmp/ringbuf-perf-${TS}.data"
        echo "starting perf record (CAPTURE_DURATION_PLACEHOLDERs) ..."
        eval "$PERF_BIN" record -a -g --call-graph fp -e cpu-clock -F 99 \
          -o "$PERF_HOST_OUT" -- sleep CAPTURE_DURATION_PLACEHOLDER \
          >"$RUN_DIR/perf.record.out.txt" 2>"$RUN_DIR/perf.record.err.txt" &
        PERF_PID=$!

        printf '%s\n' 'timestamp,net_rx_total,net_tx_total' > "$RUN_DIR/samples.csv"
        END_TIME=$((SECONDS + CAPTURE_DURATION_PLACEHOLDER))
        while [[ $SECONDS -lt $END_TIME ]]; do
          NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
          NET_RX=$(awk '/NET_RX/ {s=0; for(i=2;i<=NF;i++) s+=$i; print s}' /proc/softirqs)
          NET_TX=$(awk '/NET_TX/ {s=0; for(i=2;i<=NF;i++) s+=$i; print s}' /proc/softirqs)
          printf '%s,%s,%s\n' "$NOW" "$NET_RX" "$NET_TX" >> "$RUN_DIR/samples.csv"
          sleep CAPTURE_INTERVAL_PLACEHOLDER
        done

        echo "waiting for perf to finish ..."
        set +e
        wait "$PERF_PID"
        PERF_RC=$?
        set -e
        echo "perf exit code: $PERF_RC" | tee -a "$RUN_DIR/meta.env"

        if [[ -f "/host-root$PERF_HOST_OUT" ]]; then
          cp "/host-root$PERF_HOST_OUT" "$RUN_DIR/perf.data" || true
        fi

        if [[ -s "$RUN_DIR/perf.data" ]]; then
          echo "perf done. generating perf.script.txt ..."
          set +e
          eval "$PERF_BIN" script -i "$PERF_HOST_OUT" > "$RUN_DIR/perf.script.txt" 2>"$RUN_DIR/perf.script.err.txt"
          PERF_SCRIPT_RC=$?
          set -e
          echo "perf script exit code: $PERF_SCRIPT_RC" | tee -a "$RUN_DIR/meta.env"
        else
          echo "WARNING: perf.data missing or empty" | tee -a "$RUN_DIR/meta.env"
          if [[ -s "$RUN_DIR/perf.record.err.txt" ]]; then
            echo "--- perf.record.err.txt ---"
            sed -n '1,120p' "$RUN_DIR/perf.record.err.txt" || true
            echo "--- end perf.record.err.txt ---"
          fi
        fi

        if [[ -n "$FG_COLLAPSE" && -n "$FG_RENDER" && -s "$RUN_DIR/perf.script.txt" ]]; then
          echo "generating flamegraph ..."
          "$FG_COLLAPSE" < "$RUN_DIR/perf.script.txt" > "$RUN_DIR/perf.folded.txt" 2>"$RUN_DIR/stackcollapse.err.txt" || true
          "$FG_RENDER" "$RUN_DIR/perf.folded.txt" > "$RUN_DIR/flamegraph.svg" 2>"$RUN_DIR/flamegraph.err.txt" || true
          echo "flamegraph written: $RUN_DIR/flamegraph.svg"
        else
          echo "WARNING: skipping flamegraph (tools missing or perf.script.txt missing)"
        fi

        if [[ -n "$BPFTOOL_BIN" ]]; then
          eval "$BPFTOOL_BIN" prog show > "$RUN_DIR/bpftool.prog.after.txt" 2>&1 || true
          eval "$BPFTOOL_BIN" map  show > "$RUN_DIR/bpftool.map.after.txt"  2>&1 || true
          eval "$BPFTOOL_BIN" link show > "$RUN_DIR/bpftool.link.after.txt" 2>&1 || true
          eval "$BPFTOOL_BIN" net  show > "$RUN_DIR/bpftool.net.after.txt"  2>&1 || true
        fi

        cat /proc/softirqs   > "$RUN_DIR/softirqs.after.txt"
        cat /proc/interrupts > "$RUN_DIR/interrupts.after.txt"

        echo "copying results to host ..."
        ln -sfn "$RUN_DIR" /capture/latest
        find "$RUN_DIR" -maxdepth 1 -type f | sort > "$RUN_DIR/files.txt" || true
        cp -R "$RUN_DIR" /host-capture/
        echo "leaving pod alive briefly for kubectl cp ..."
        sleep 180
        echo "=== capture complete: /host-capture/$TS ==="
    volumeMounts:
    - name: capture
      mountPath: /capture
    - name: host-capture
      mountPath: /host-capture
    - name: host-root
      mountPath: /host-root
      readOnly: false
  volumes:
  - name: capture
    emptyDir: {}
  - name: host-capture
    hostPath:
      path: CAPTURE_DIR_PLACEHOLDER
      type: DirectoryOrCreate
  - name: host-root
    hostPath:
      path: /
      type: Directory
YAML

# Substitute placeholders
sed -i \
  -e "s|POD_NAME_PLACEHOLDER|$CAPTURE_POD_NAME|g" \
  -e "s|NODE_NAME_PLACEHOLDER|$NODE_NAME|g" \
  -e "s|POD_IMAGE_PLACEHOLDER|$POD_IMAGE|g" \
  -e "s|CAPTURE_TAG_PLACEHOLDER|$CAPTURE_TAG|g" \
  -e "s|NIC_PLACEHOLDER|$NIC|g" \
  -e "s|CAPTURE_DIR_PLACEHOLDER|$CAPTURE_DIR|g" \
  -e "s|CAPTURE_DURATION_PLACEHOLDER|$CAPTURE_DURATION|g" \
  -e "s|CAPTURE_INTERVAL_PLACEHOLDER|$CAPTURE_INTERVAL|g" \
  "$CAPTURE_DIR/capture-pod.yaml"

kubectl delete pod "$CAPTURE_POD_NAME" --ignore-not-found >/dev/null 2>&1 || true

create_ok=0
for attempt in 1 2 3; do
  if kubectl create --validate=false -f "$CAPTURE_DIR/capture-pod.yaml" >/dev/null 2>&1; then
    create_ok=1
    break
  fi
  sleep 3
done
if [[ "$create_ok" -ne 1 ]]; then
  echo "ERROR: failed to create capture pod after retries" | tee -a "$RUN_LOG"
  exit 1
fi

pod_seen=0
for attempt in 1 2 3 4 5; do
  if kubectl get pod "$CAPTURE_POD_NAME" >/dev/null 2>&1; then
    pod_seen=1
    break
  fi
  sleep 2
done
if [[ "$pod_seen" -ne 1 ]]; then
  echo "ERROR: capture pod was not observed after creation" | tee -a "$RUN_LOG"
  exit 1
fi

CAPTURE_LOG="$RESULTS_DIR/${RUN_ID}_capture.log"
(
  kubectl wait --for=condition=Ready "pod/${CAPTURE_POD_NAME}" --timeout=300s >/dev/null 2>&1 || true
  # Copy artifacts from the running pod before it exits.
  sleep "$((CAPTURE_DURATION + 20))"
  kubectl cp "default/${CAPTURE_POD_NAME}:/capture/latest" "$CAPTURE_DIR/pod_capture" >/dev/null 2>&1 || true
  kubectl wait --for=condition=Succeeded "pod/${CAPTURE_POD_NAME}" --timeout=900s >/dev/null 2>&1 || true
  kubectl logs "pod/${CAPTURE_POD_NAME}" > "$CAPTURE_LOG" 2>&1 || true
) &
CAPTURE_PID="$!"

echo "2/2: running ringbuf benchmark" | tee -a "$RUN_LOG"
RINGBUF_RESULTS_DIR="$RESULTS_DIR/ringbuf_benchmark"
"$ROOT_DIR/scripts/run_reuseport_ab.sh" \
  --client-pods "$CLIENT_PODS" \
  --connections-per-pod "$CONNECTIONS_PER_POD" \
  --duration "$DURATION" \
  --listeners "$LISTENERS" \
  --workers "$WORKERS" \
  --payload-bytes "$PAYLOAD_BYTES" \
  --results-dir "$RINGBUF_RESULTS_DIR" \
  | tee -a "$RUN_LOG"

wait "$CAPTURE_PID"
cat "$CAPTURE_LOG" | tee -a "$RUN_LOG"

echo "Ringbuf capture complete. Benchmark results: $RINGBUF_RESULTS_DIR" | tee -a "$RUN_LOG"
