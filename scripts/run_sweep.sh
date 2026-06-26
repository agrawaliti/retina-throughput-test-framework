#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "$SCRIPT_DIR/common.sh"

SERVER_IP=""
PORT="5201"
SCENARIO_FILE="$SCENARIOS_DIR_DEFAULT/tcp_sweep.csv"
RESULTS_DIR="$RESULTS_DIR_DEFAULT/client"

usage() {
  cat <<'EOF'
Usage: run_sweep.sh --server-ip <ip> [options]

Executes a CSV-defined scenario sweep with run_client_once.sh.

CSV format:
  test_name,bandwidth,parallel,length,duration,protocol

Options:
  --server-ip <ip>          Receiver node IP or hostname (required)
  -p, --port <port>         Receiver port (default: 5201)
  -s, --scenario <file>     Scenario CSV (default: scenarios/tcp_sweep.csv)
  -o, --results-dir <dir>   Output directory (default: results/client)
  -h, --help                Show this help message
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
    -s|--scenario)
      SCENARIO_FILE="$2"
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

if [[ ! -f "$SCENARIO_FILE" ]]; then
  log ERROR "Scenario file not found: $SCENARIO_FILE"
  exit 1
fi

ensure_results_dir "$RESULTS_DIR"

log INFO "Running scenario sweep from $SCENARIO_FILE"

line_no=0
while IFS=, read -r test_name bandwidth parallel length duration protocol; do
  line_no=$((line_no + 1))

  if [[ $line_no -eq 1 ]]; then
    continue
  fi

  if [[ -z "$test_name" || "$test_name" =~ ^[[:space:]]*# ]]; then
    continue
  fi

  log INFO "Scenario line $line_no: $test_name"
  "$SCRIPT_DIR/run_client_once.sh" \
    --server-ip "$SERVER_IP" \
    --port "$PORT" \
    --test-name "$test_name" \
    --bandwidth "$bandwidth" \
    --parallel "$parallel" \
    --length "$length" \
    --duration "$duration" \
    --protocol "$protocol" \
    --results-dir "$RESULTS_DIR"
done < "$SCENARIO_FILE"

log INFO "Scenario sweep completed"
