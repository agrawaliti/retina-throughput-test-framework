#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="kube-system"
RETINA_CONFIGMAP="retina-config"
RETINA_DS="retina-agent"
POOL_LABEL="agentpool=usr32"
RETINA_LABEL_KEY="perf-test-retina"
RETINA_LABEL_VALUE="enabled"
AB_SCRIPT="./scripts/run_reuseport_ab.sh"
OUTDIR_DEFAULT="results/reuseport_three_modes"

CLIENT_PODS="4"
CONNECTIONS_PER_POD="8"
DURATION="10s"
LISTENERS="16"
WORKERS="64"
PAYLOAD_BYTES="65536"
OUTDIR="$OUTDIR_DEFAULT"

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
Usage: run_reuseport_three_modes.sh [options]

Runs a reproducible three-mode benchmark on usr32 nodes and stores artifacts for:
  1) baseline (Retina excluded)
  2) perf-array (Retina enabled, packetParserRingBuffer disabled)
  3) ringbuf (Retina enabled, packetParserRingBuffer enabled)

This script calls scripts/run_reuseport_ab.sh twice:
  - first with perf-array config
  - second with ringbuf config

Options:
  --client-pods <n>             Number of client pods for each run (default: 4)
  --connections-per-pod <n>     Connections per client pod (default: 8)
  --duration <duration>         Test duration (default: 10s)
  --listeners <n>               Receiver listeners (default: 16)
  --workers <n>                 Receiver workers (default: 64)
  --payload-bytes <n>           Client payload size (default: 65536)
  --results-dir <dir>           Output directory (default: results/reuseport_three_modes)
  -h, --help                    Show this help

Prerequisites:
  - AKS cluster context configured in kubectl
  - usr32 nodepool exists with at least 2 nodes
  - retina-agent DaemonSet and retina-config ConfigMap exist in kube-system
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

if [[ ! -x "$AB_SCRIPT" ]]; then
  echo "Missing executable AB script at $AB_SCRIPT" >&2
  echo "Fix with: chmod +x $AB_SCRIPT" >&2
  exit 1
fi

mkdir -p "$OUTDIR"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
RUN_DIR="$OUTDIR/$RUN_ID"
PERF_ARRAY_DIR="$RUN_DIR/perf_array"
RINGBUF_DIR="$RUN_DIR/ringbuf"
mkdir -p "$PERF_ARRAY_DIR" "$RINGBUF_DIR"

json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

set_retina_node_selector() {
  k -n "$NAMESPACE" patch ds "$RETINA_DS" --type merge -p \
    '{"spec":{"template":{"spec":{"nodeSelector":{"perf-test-retina":"enabled"}}}}}' >/dev/null
}

set_packet_parser_ringbuf() {
  local mode="$1"
  local value
  local tmp

  case "$mode" in
    perf-array)
      value="disabled"
      ;;
    ringbuf)
      value="enabled"
      ;;
    *)
      echo "Invalid ringbuf mode: $mode" >&2
      exit 1
      ;;
  esac

  tmp="$(mktemp)"
  k -n "$NAMESPACE" get cm "$RETINA_CONFIGMAP" -o jsonpath='{.data.config\.yaml}' > "$tmp"

  if grep -q '^packetParserRingBuffer:' "$tmp"; then
    sed -i -E "s/^packetParserRingBuffer:.*/packetParserRingBuffer: ${value}/" "$tmp"
  else
    echo "packetParserRingBuffer: ${value}" >> "$tmp"
  fi

  k -n "$NAMESPACE" create cm "$RETINA_CONFIGMAP" --from-file=config.yaml="$tmp" -o yaml --dry-run=client | k apply -f - >/dev/null
  rm -f "$tmp"

  k -n "$NAMESPACE" rollout restart ds/"$RETINA_DS" >/dev/null
  k -n "$NAMESPACE" rollout status ds/"$RETINA_DS" --timeout=600s >/dev/null
}

label_usr32_for_retina() {
  k label node -l "$POOL_LABEL" "${RETINA_LABEL_KEY}=${RETINA_LABEL_VALUE}" --overwrite >/dev/null
}

run_ab_once() {
  local dir="$1"
  "$AB_SCRIPT" \
    --client-pods "$CLIENT_PODS" \
    --connections-per-pod "$CONNECTIONS_PER_POD" \
    --duration "$DURATION" \
    --listeners "$LISTENERS" \
    --workers "$WORKERS" \
    --payload-bytes "$PAYLOAD_BYTES" \
    --results-dir "$dir"
}

latest_summary_file() {
  local dir="$1"
  ls -1t "$dir"/*_summary.txt | head -n1
}

extract_metric() {
  local file="$1"
  local key="$2"
  awk -F= -v k="$key" '$1==k{print $2}' "$file" | tail -n1
}

summarize_run() {
  local summary_file="$1"
  local mode_label="$2"
  local baseline_gbps
  local retina_gbps
  local overhead_pct

  baseline_gbps="$(extract_metric "$summary_file" baseline_gbps)"
  retina_gbps="$(extract_metric "$summary_file" with_retina_gbps)"
  overhead_pct="$(extract_metric "$summary_file" overhead_pct)"

  cat <<EOF
${mode_label}_summary_file=$(basename "$summary_file")
${mode_label}_baseline_gbps=${baseline_gbps}
${mode_label}_retina_gbps=${retina_gbps}
${mode_label}_overhead_pct=${overhead_pct}
EOF
}

echo "Preparing Retina DaemonSet selector and usr32 labels..."
set_retina_node_selector
label_usr32_for_retina

echo "Running perf-array pass (packetParserRingBuffer: disabled)..."
set_packet_parser_ringbuf perf-array
run_ab_once "$PERF_ARRAY_DIR"
PERF_SUMMARY_FILE="$(latest_summary_file "$PERF_ARRAY_DIR")"

echo "Running ringbuf pass (packetParserRingBuffer: enabled)..."
set_packet_parser_ringbuf ringbuf
run_ab_once "$RINGBUF_DIR"
RING_SUMMARY_FILE="$(latest_summary_file "$RINGBUF_DIR")"

PERF_BASELINE_GBPS="$(extract_metric "$PERF_SUMMARY_FILE" baseline_gbps)"
PERF_ARRAY_GBPS="$(extract_metric "$PERF_SUMMARY_FILE" with_retina_gbps)"
RINGBUF_BASELINE_GBPS="$(extract_metric "$RING_SUMMARY_FILE" baseline_gbps)"
RINGBUF_GBPS="$(extract_metric "$RING_SUMMARY_FILE" with_retina_gbps)"

CANONICAL_BASELINE="$PERF_BASELINE_GBPS"

PERF_ARRAY_DROP_PCT="$(awk -v b="$CANONICAL_BASELINE" -v r="$PERF_ARRAY_GBPS" 'BEGIN { printf("%.1f", (b-r)*100/b) }')"
RINGBUF_DROP_PCT="$(awk -v b="$CANONICAL_BASELINE" -v r="$RINGBUF_GBPS" 'BEGIN { printf("%.1f", (b-r)*100/b) }')"

CONSOLIDATED_TXT="$RUN_DIR/three_mode_summary.txt"
CONSOLIDATED_JSON="$RUN_DIR/three_mode_summary.json"
CONSOLIDATED_CSV="$RUN_DIR/three_mode_summary.csv"

{
  echo "run_id=$RUN_ID"
  echo "run_dir=$RUN_DIR"
  summarize_run "$PERF_SUMMARY_FILE" perf_array
  summarize_run "$RING_SUMMARY_FILE" ringbuf
  echo "canonical_baseline_gbps=$CANONICAL_BASELINE"
  echo "perf_array_drop_vs_canonical_baseline_pct=$PERF_ARRAY_DROP_PCT"
  echo "ringbuf_drop_vs_canonical_baseline_pct=$RINGBUF_DROP_PCT"
} | tee "$CONSOLIDATED_TXT"

{
  echo 'mode,baseline_gbps,retina_gbps,drop_vs_canonical_baseline_pct'
  echo "baseline,$CANONICAL_BASELINE,$CANONICAL_BASELINE,0.0"
  echo "perf-array,$CANONICAL_BASELINE,$PERF_ARRAY_GBPS,$PERF_ARRAY_DROP_PCT"
  echo "ringbuf,$CANONICAL_BASELINE,$RINGBUF_GBPS,$RINGBUF_DROP_PCT"
} > "$CONSOLIDATED_CSV"

cat > "$CONSOLIDATED_JSON" <<EOF
{
  "run_id": "$(json_escape "$RUN_ID")",
  "run_dir": "$(json_escape "$RUN_DIR")",
  "canonical_baseline_gbps": $CANONICAL_BASELINE,
  "modes": {
    "baseline": {
      "gbps": $CANONICAL_BASELINE
    },
    "perf_array": {
      "gbps": $PERF_ARRAY_GBPS,
      "drop_vs_canonical_baseline_pct": $PERF_ARRAY_DROP_PCT,
      "source_summary_file": "$(json_escape "$PERF_SUMMARY_FILE")"
    },
    "ringbuf": {
      "gbps": $RINGBUF_GBPS,
      "drop_vs_canonical_baseline_pct": $RINGBUF_DROP_PCT,
      "source_summary_file": "$(json_escape "$RING_SUMMARY_FILE")"
    }
  },
  "notes": {
    "ringbuf_run_baseline_gbps": $RINGBUF_BASELINE_GBPS
  }
}
EOF

echo
echo "Three-mode benchmark complete."
echo "Summary text: $CONSOLIDATED_TXT"
echo "Summary csv:  $CONSOLIDATED_CSV"
echo "Summary json: $CONSOLIDATED_JSON"
