#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "$SCRIPT_DIR/common.sh"

SERVER_IP=""
PORT="5201"
BANDWIDTH="10000M"
PARALLEL="8"
LENGTH="128K"
DURATION="30"
INTERVAL="1"
PROTOCOL="tcp"
TEST_NAME="single_run"
RESULTS_DIR="$RESULTS_DIR_DEFAULT/client"

usage() {
  cat <<'EOF'
Usage: run_client_once.sh --server-ip <ip> [options]

Runs one iperf3 client test and stores JSON + summary CSV row.

Options:
  --server-ip <ip>          Receiver node IP or hostname (required)
  -p, --port <port>         Server port (default: 5201)
  -b, --bandwidth <rate>    Target rate (e.g., 10000M) (default: 10000M)
  -P, --parallel <flows>    Number of parallel TCP flows (default: 8)
  -l, --length <bytes>      Write buffer size (default: 128K)
  -t, --duration <seconds>  Test duration (default: 30)
  -i, --interval <seconds>  Report interval (default: 1)
      --protocol <tcp|udp>  Protocol (default: tcp)
      --test-name <name>    Label for result row (default: single_run)
  -o, --results-dir <dir>   Output directory (default: results/client)
  -h, --help                Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --server-ip)
      SERVER_IP="$2"
      shift 2
      ;;
    -p|--port)
      PORT="$2"
      shift 2
      ;;
    -b|--bandwidth)
      BANDWIDTH="$2"
      shift 2
      ;;
    -P|--parallel)
      PARALLEL="$2"
      shift 2
      ;;
    -l|--length)
      LENGTH="$2"
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
    --protocol)
      PROTOCOL="$2"
      shift 2
      ;;
    --test-name)
      TEST_NAME="$2"
      shift 2
      ;;
    -o|--results-dir)
      RESULTS_DIR="$2"
      shift 2
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

if [[ -z "$SERVER_IP" ]]; then
  log ERROR "--server-ip is required"
  usage
  exit 1
fi

if [[ "$PROTOCOL" != "tcp" && "$PROTOCOL" != "udp" ]]; then
  log ERROR "--protocol must be tcp or udp"
  exit 1
fi

require_cmd iperf3
ensure_results_dir "$RESULTS_DIR"

RUN_ID="$(date -u +"%Y%m%dT%H%M%SZ")_${TEST_NAME}"
JSON_FILE="$RESULTS_DIR/${RUN_ID}.json"
TXT_FILE="$RESULTS_DIR/${RUN_ID}.txt"
SUMMARY_FILE="$RESULTS_DIR/summary.csv"

CMD=(iperf3 -c "$SERVER_IP" -p "$PORT" -P "$PARALLEL" -l "$LENGTH" -t "$DURATION" -i "$INTERVAL" --json)
if [[ "$PROTOCOL" == "udp" ]]; then
  CMD+=(--udp -b "$BANDWIDTH")
else
  CMD+=(-b "$BANDWIDTH")
fi

log INFO "Running test '$TEST_NAME' to $SERVER_IP:$PORT"
log INFO "Params: protocol=$PROTOCOL bandwidth=$BANDWIDTH parallel=$PARALLEL length=$LENGTH duration=$DURATION"
printf '%s\n' "${CMD[*]}" | tee "$TXT_FILE"
"${CMD[@]}" | tee "$JSON_FILE" >/dev/null

THROUGHPUT_BPS="$(json_get "$JSON_FILE" '.end.sum_sent.bits_per_second // empty')"
RETRANSMITS="$(json_get "$JSON_FILE" '.end.sum_sent.retransmits // empty')"
CPU_LOCAL="$(json_get "$JSON_FILE" '.end.cpu_utilization_percent.host_total // empty')"
CPU_REMOTE="$(json_get "$JSON_FILE" '.end.cpu_utilization_percent.remote_total // empty')"

if [[ -z "$THROUGHPUT_BPS" ]]; then
  THROUGHPUT_GBPS="NA"
else
  THROUGHPUT_GBPS="$(awk -v bps="$THROUGHPUT_BPS" 'BEGIN {printf "%.3f", bps/1000000000}')"
fi

if [[ -z "$RETRANSMITS" ]]; then
  RETRANSMITS="NA"
fi
if [[ -z "$CPU_LOCAL" ]]; then
  CPU_LOCAL="NA"
fi
if [[ -z "$CPU_REMOTE" ]]; then
  CPU_REMOTE="NA"
fi

if [[ ! -f "$SUMMARY_FILE" ]]; then
  printf '%s\n' 'timestamp,test_name,sender_host,server_ip,port,protocol,bandwidth,parallel,length,duration_s,throughput_gbps,retransmits,sender_cpu_pct,receiver_cpu_pct,json_file' > "$SUMMARY_FILE"
fi

printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
  "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
  "$(csv_escape "$TEST_NAME")" \
  "$(csv_escape "$(hostname -s)")" \
  "$(csv_escape "$SERVER_IP")" \
  "$(csv_escape "$PORT")" \
  "$(csv_escape "$PROTOCOL")" \
  "$(csv_escape "$BANDWIDTH")" \
  "$(csv_escape "$PARALLEL")" \
  "$(csv_escape "$LENGTH")" \
  "$(csv_escape "$DURATION")" \
  "$(csv_escape "$THROUGHPUT_GBPS")" \
  "$(csv_escape "$RETRANSMITS")" \
  "$(csv_escape "$CPU_LOCAL")" \
  "$(csv_escape "$CPU_REMOTE")" \
  "$(csv_escape "$JSON_FILE")" >> "$SUMMARY_FILE"

log INFO "Wrote result JSON: $JSON_FILE"
log INFO "Updated summary CSV: $SUMMARY_FILE"
if ! command -v jq >/dev/null 2>&1; then
  log INFO "Install 'jq' to parse throughput/retransmits automatically in summary.csv"
fi
