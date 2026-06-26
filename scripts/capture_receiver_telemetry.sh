#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "$SCRIPT_DIR/common.sh"

NIC=""
DURATION="30"
INTERVAL="1"
OUT_DIR="$RESULTS_DIR_DEFAULT/receiver_telemetry"
TAG="run"
PERF_RECORD=0
PERF_FREQUENCY="99"
PERF_CALLGRAPH="dwarf"
BPFTOOL_SNAPSHOT=0
GENERATE_FLAMEGRAPH=1

usage() {
  cat <<'EOF'
Usage: capture_receiver_telemetry.sh --nic <name> [options]

Captures receiver-side snapshots around an iperf3 run.

Options:
  --nic <name>              NIC name (required), e.g. eth0
  -t, --duration <seconds>  Sampling duration (default: 30)
  -i, --interval <seconds>  Sampling interval (default: 1)
  -o, --out-dir <dir>       Output directory (default: results/receiver_telemetry)
      --tag <name>          Label used in output files (default: run)
      --perf-record          Run perf record during the capture window
      --perf-frequency <n>   perf record sample frequency (default: 99)
      --perf-callgraph <m>   perf call graph mode: dwarf or fp (default: dwarf)
      --no-flamegraph        Skip flamegraph generation even if tools exist
      --bpftool-snapshot     Capture bpftool prog/map/link/net snapshots
  -h, --help                Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --nic)
      NIC="$2"
      shift 2
      ;;
    -t|--duration)
      DURATION="$2"
      shift 2
      ;;
    -i|--interval)
      INTERVAL="$2"
      shift 2
      ;;
    -o|--out-dir)
      OUT_DIR="$2"
      shift 2
      ;;
    --tag)
      TAG="$2"
      shift 2
      ;;
    --perf-record)
      PERF_RECORD=1
      shift
      ;;
    --perf-frequency)
      PERF_FREQUENCY="$2"
      shift 2
      ;;
    --perf-callgraph)
      PERF_CALLGRAPH="$2"
      shift 2
      ;;
    --no-flamegraph)
      GENERATE_FLAMEGRAPH=0
      shift
      ;;
    --bpftool-snapshot)
      BPFTOOL_SNAPSHOT=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      log ERROR "Unknown argument: $1"
      usage
      exit 1
      ;;
  esac
done

if [[ -z "$NIC" ]]; then
  log ERROR "--nic is required"
  usage
  exit 1
fi

if [[ ! -e "/sys/class/net/$NIC" ]]; then
  log ERROR "NIC '$NIC' not found"
  exit 1
fi

if [[ "$PERF_RECORD" -eq 1 ]] && ! command -v perf >/dev/null 2>&1; then
  log ERROR "--perf-record requested but 'perf' is not available"
  exit 1
fi

if [[ "$BPFTOOL_SNAPSHOT" -eq 1 ]] && ! command -v bpftool >/dev/null 2>&1; then
  log ERROR "--bpftool-snapshot requested but 'bpftool' is not available"
  exit 1
fi

ensure_results_dir "$OUT_DIR"

TS="$(date -u +"%Y%m%dT%H%M%SZ")"
RUN_DIR="$OUT_DIR/${TS}_${TAG}"
mkdir -p "$RUN_DIR"

log INFO "Capturing telemetry in $RUN_DIR"

{
  echo "timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  echo "hostname=$(hostname -f 2>/dev/null || hostname)"
  echo "nic=$NIC"
  echo "duration=$DURATION"
  echo "interval=$INTERVAL"
} > "$RUN_DIR/meta.env"

lscpu > "$RUN_DIR/lscpu.txt" || true
if command -v numactl >/dev/null 2>&1; then
  numactl --hardware > "$RUN_DIR/numa.txt" || true
fi

cat /proc/softirqs > "$RUN_DIR/softirqs.before.txt"
cat /proc/interrupts > "$RUN_DIR/interrupts.before.txt"
if command -v ethtool >/dev/null 2>&1; then
  ethtool -l "$NIC" > "$RUN_DIR/ethtool_channels.txt" || true
  ethtool -S "$NIC" > "$RUN_DIR/ethtool_stats.before.txt" || true
fi

capture_bpftool_snapshot() {
  local suffix="$1"
  if [[ "$BPFTOOL_SNAPSHOT" -ne 1 ]]; then
    return 0
  fi

  bpftool prog show > "$RUN_DIR/bpftool.prog.${suffix}.txt" 2>&1 || true
  bpftool map show > "$RUN_DIR/bpftool.map.${suffix}.txt" 2>&1 || true
  bpftool link show > "$RUN_DIR/bpftool.link.${suffix}.txt" 2>&1 || true
  bpftool net show > "$RUN_DIR/bpftool.net.${suffix}.txt" 2>&1 || true
}

generate_flamegraph() {
  local perf_script_file="$RUN_DIR/perf.script.txt"
  local folded_file="$RUN_DIR/perf.folded.txt"
  local svg_file="$RUN_DIR/flamegraph.svg"
  local stackcollapse_cmd=""
  local flamegraph_cmd=""

  if [[ "$GENERATE_FLAMEGRAPH" -ne 1 ]]; then
    return 0
  fi

  if command -v stackcollapse-perf.pl >/dev/null 2>&1 && command -v flamegraph.pl >/dev/null 2>&1; then
    stackcollapse_cmd="stackcollapse-perf.pl"
    flamegraph_cmd="flamegraph.pl"
  elif [[ -n "${FLAMEGRAPH_DIR:-}" ]] && [[ -x "${FLAMEGRAPH_DIR}/stackcollapse-perf.pl" ]] && [[ -x "${FLAMEGRAPH_DIR}/flamegraph.pl" ]]; then
    stackcollapse_cmd="${FLAMEGRAPH_DIR}/stackcollapse-perf.pl"
    flamegraph_cmd="${FLAMEGRAPH_DIR}/flamegraph.pl"
  else
    log INFO "Flamegraph tools not found; keeping perf script only"
    return 0
  fi

  "$stackcollapse_cmd" < "$perf_script_file" > "$folded_file"
  "$flamegraph_cmd" "$folded_file" > "$svg_file"
  log INFO "Flamegraph generated: $svg_file"
}

PERF_PID=""
if [[ "$PERF_RECORD" -eq 1 ]]; then
  capture_bpftool_snapshot before
  log INFO "Starting perf record: frequency=$PERF_FREQUENCY callgraph=$PERF_CALLGRAPH"
  perf record -a -g --call-graph "$PERF_CALLGRAPH" -F "$PERF_FREQUENCY" -o "$RUN_DIR/perf.data" -- sleep "$DURATION" >/dev/null 2>&1 &
  PERF_PID="$!"
fi

SAMPLES_FILE="$RUN_DIR/samples.csv"
printf '%s\n' 'timestamp,net_rx_total,net_tx_total' > "$SAMPLES_FILE"

end_time=$((SECONDS + DURATION))
while [[ $SECONDS -lt $end_time ]]; do
  now="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  net_rx_total="$(awk '/NET_RX/ {sum=0; for (i=2; i<=NF; i++) sum+=$i; print sum}' /proc/softirqs)"
  net_tx_total="$(awk '/NET_TX/ {sum=0; for (i=2; i<=NF; i++) sum+=$i; print sum}' /proc/softirqs)"
  printf '%s,%s,%s\n' "$now" "$net_rx_total" "$net_tx_total" >> "$SAMPLES_FILE"
  sleep "$INTERVAL"
done

cat /proc/softirqs > "$RUN_DIR/softirqs.after.txt"
cat /proc/interrupts > "$RUN_DIR/interrupts.after.txt"
if command -v ethtool >/dev/null 2>&1; then
  ethtool -S "$NIC" > "$RUN_DIR/ethtool_stats.after.txt" || true
fi

if [[ -n "$PERF_PID" ]]; then
  wait "$PERF_PID"
  perf script -i "$RUN_DIR/perf.data" > "$RUN_DIR/perf.script.txt"
  generate_flamegraph
fi

capture_bpftool_snapshot after

log INFO "Telemetry capture complete: $RUN_DIR"
