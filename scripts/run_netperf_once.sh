#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "$SCRIPT_DIR/common.sh"

SERVER_IP=""
PORT="12865"
REQUEST_SIZE="1"
RESPONSE_SIZE="1"
NUM_TRANSACTIONS="10000"
PARALLEL="1"
TEST_NAME="single_run"
RESULTS_DIR="$RESULTS_DIR_DEFAULT/netperf_client"

usage() {
  cat <<'EOF'
Usage: run_netperf_once.sh --server-ip <ip> [options]

Runs one netperf TCP_RR latency test and stores results.
Measures request-response round-trip latency (complementary to iperf3 throughput).

Options:
  --server-ip <ip>          Receiver node IP or hostname (required)
  -p, --port <port>         Server port (default: 12865)
  -r, --req-size <bytes>    Request size (default: 1)
  -s, --resp-size <bytes>   Response size (default: 1)
  -n, --num-trans <count>   Number of transactions (default: 10000)
  -P, --parallel <flows>    Number of parallel instances (default: 1)
      --test-name <name>    Label for result row (default: single_run)
  -o, --results-dir <dir>   Output directory (default: results/netperf_client)
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
    -r|--req-size)
      REQUEST_SIZE="$2"
      shift 2
      ;;
    -s|--resp-size)
      RESPONSE_SIZE="$2"
      shift 2
      ;;
    -n|--num-trans)
      NUM_TRANSACTIONS="$2"
      shift 2
      ;;
    -P|--parallel)
      PARALLEL="$2"
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

require_cmd netperf
ensure_results_dir "$RESULTS_DIR"

RUN_ID="$(date -u +"%Y%m%dT%H%M%SZ")_${TEST_NAME}"
JSON_FILE="$RESULTS_DIR/${RUN_ID}.json"
TXT_FILE="$RESULTS_DIR/${RUN_ID}.txt"
SUMMARY_FILE="$RESULTS_DIR/summary.csv"

log INFO "Running netperf TCP_RR test '$TEST_NAME' to $SERVER_IP:$PORT"
log INFO "Params: req_size=$REQUEST_SIZE resp_size=$RESPONSE_SIZE num_trans=$NUM_TRANSACTIONS parallel=$PARALLEL"

if [[ $PARALLEL -eq 1 ]]; then
  # Single instance
  CMD=(netperf -H "$SERVER_IP" -p "$PORT" -t omni -- -d rr -r "$REQUEST_SIZE","$RESPONSE_SIZE" -n "$NUM_TRANSACTIONS" -v 2)
  printf '%s\n' "${CMD[*]}" | tee "$TXT_FILE"
  OUTPUT=$("${CMD[@]}" 2>&1)
  echo "$OUTPUT" | tee -a "$TXT_FILE" > "$JSON_FILE"
else
  # Multiple parallel instances
  TMP_DIR=$(mktemp -d)
  trap "rm -rf $TMP_DIR" EXIT
  
  log INFO "Running $PARALLEL parallel netperf instances..."
  for i in $(seq 1 "$PARALLEL"); do
    (
      OUT_FILE="$TMP_DIR/netperf_$i.txt"
      netperf -H "$SERVER_IP" -p "$PORT" -t omni -- -d rr -r "$REQUEST_SIZE","$RESPONSE_SIZE" -n "$NUM_TRANSACTIONS" -v 2 > "$OUT_FILE" 2>&1
    ) &
  done
  wait
  
  # Aggregate results
  cat "$TMP_DIR"/*.txt > "$JSON_FILE"
  cat "$TMP_DIR"/*.txt | tee "$TXT_FILE" >> /dev/null
fi

# Extract key metrics from netperf output
# netperf omni -d rr outputs lines like:
#   Throughput    10000.0 Trans/s
#   Min_Latency=0.001  Max_Latency=10.234  Mean_Latency=0.234
#   P50_Latency=0.100  P90_Latency=0.500  P99_Latency=2.000

THROUGHPUT_TPS=$(grep -oP '(?<=Throughput\s+)[0-9.]+' "$JSON_FILE" | head -1 || printf "NA")
MIN_LAT=$(grep -oP '(?<=Min_Latency=)[0-9.]+' "$JSON_FILE" | head -1 || printf "NA")
MAX_LAT=$(grep -oP '(?<=Max_Latency=)[0-9.]+' "$JSON_FILE" | head -1 || printf "NA")
MEAN_LAT=$(grep -oP '(?<=Mean_Latency=)[0-9.]+' "$JSON_FILE" | head -1 || printf "NA")
P50_LAT=$(grep -oP '(?<=P50_Latency=)[0-9.]+' "$JSON_FILE" | head -1 || printf "NA")
P90_LAT=$(grep -oP '(?<=P90_Latency=)[0-9.]+' "$JSON_FILE" | head -1 || printf "NA")
P99_LAT=$(grep -oP '(?<=P99_Latency=)[0-9.]+' "$JSON_FILE" | head -1 || printf "NA")

if [[ ! -f "$SUMMARY_FILE" ]]; then
  printf '%s\n' 'timestamp,test_name,sender_host,server_ip,port,req_size,resp_size,num_trans,parallel,throughput_tps,min_lat_ms,max_lat_ms,mean_lat_ms,p50_lat_ms,p90_lat_ms,p99_lat_ms,results_file' > "$SUMMARY_FILE"
fi

printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
  "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
  "$(csv_escape "$TEST_NAME")" \
  "$(csv_escape "$(hostname -s)")" \
  "$(csv_escape "$SERVER_IP")" \
  "$(csv_escape "$PORT")" \
  "$(csv_escape "$REQUEST_SIZE")" \
  "$(csv_escape "$RESPONSE_SIZE")" \
  "$(csv_escape "$NUM_TRANSACTIONS")" \
  "$(csv_escape "$PARALLEL")" \
  "$(csv_escape "$THROUGHPUT_TPS")" \
  "$(csv_escape "$MIN_LAT")" \
  "$(csv_escape "$MAX_LAT")" \
  "$(csv_escape "$MEAN_LAT")" \
  "$(csv_escape "$P50_LAT")" \
  "$(csv_escape "$P90_LAT")" \
  "$(csv_escape "$P99_LAT")" \
  "$(csv_escape "$JSON_FILE")" >> "$SUMMARY_FILE"

log INFO "Wrote result file: $JSON_FILE"
log INFO "Updated summary CSV: $SUMMARY_FILE"
