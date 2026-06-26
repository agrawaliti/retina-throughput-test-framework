#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "$SCRIPT_DIR/common.sh"

SERVER_IP=""
SCENARIO_FILE=""
RESULTS_DIR="$RESULTS_DIR_DEFAULT/netperf_client"
SKIP_FAILED="false"

usage() {
  cat <<'EOF'
Usage: run_netperf_sweep.sh --server-ip <ip> --scenario <file> [options]

Runs netperf TCP_RR tests from a CSV scenario matrix.
Each row defines a latency test configuration.

CSV format (header required):
  test_name,port,req_size,resp_size,num_trans,parallel

Options:
  --server-ip <ip>          Receiver node IP (required)
  --scenario <file>         Scenario CSV file (required)
  -o, --results-dir <dir>   Output directory (default: results/netperf_client)
      --skip-failed         Continue if a test fails (default: exit on failure)
  -h, --help                Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --server-ip)
      SERVER_IP="$2"
      shift 2
      ;;
    --scenario)
      SCENARIO_FILE="$2"
      shift 2
      ;;
    -o|--results-dir)
      RESULTS_DIR="$2"
      shift 2
      ;;
    --skip-failed)
      SKIP_FAILED="true"
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

if [[ -z "$SERVER_IP" || -z "$SCENARIO_FILE" ]]; then
  log ERROR "--server-ip and --scenario are required"
  usage
  exit 1
fi

if [[ ! -f "$SCENARIO_FILE" ]]; then
  log ERROR "Scenario file not found: $SCENARIO_FILE"
  exit 1
fi

require_cmd netperf
ensure_results_dir "$RESULTS_DIR"

log INFO "=== Netperf TCP_RR Sweep ==="
log INFO "Server: $SERVER_IP"
log INFO "Scenario: $SCENARIO_FILE"
log INFO "Results: $RESULTS_DIR"

# Count tests
NUM_TESTS=$(tail -n +2 "$SCENARIO_FILE" | wc -l)
log INFO "Total tests to run: $NUM_TESTS"

PASSED=0
FAILED=0
CURRENT=0

while IFS=',' read -r test_name port req_size resp_size num_trans parallel; do
  CURRENT=$((CURRENT + 1))
  
  # Skip header row
  if [[ "$test_name" == "test_name" ]]; then
    continue
  fi
  
  log INFO "[$CURRENT/$NUM_TESTS] Running: $test_name (parallel=$parallel)"
  
  if "$SCRIPT_DIR/run_netperf_once.sh" \
    --server-ip "$SERVER_IP" \
    -p "$port" \
    -r "$req_size" \
    -s "$resp_size" \
    -n "$num_trans" \
    -P "$parallel" \
    --test-name "$test_name" \
    -o "$RESULTS_DIR"; then
    PASSED=$((PASSED + 1))
    log INFO "✓ $test_name completed"
  else
    FAILED=$((FAILED + 1))
    log ERROR "✗ $test_name failed"
    if [[ "$SKIP_FAILED" != "true" ]]; then
      log ERROR "Stopping sweep due to failure (use --skip-failed to continue)"
      exit 1
    fi
  fi
done < "$SCENARIO_FILE"

log INFO ""
log INFO "=== Sweep Complete ==="
log INFO "Passed: $PASSED/$NUM_TESTS"
log INFO "Failed: $FAILED/$NUM_TESTS"
log INFO "Summary CSV: $RESULTS_DIR/summary.csv"

if [[ $FAILED -eq 0 ]]; then
  exit 0
else
  exit 1
fi
