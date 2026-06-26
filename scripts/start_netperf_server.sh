#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "$SCRIPT_DIR/common.sh"

PORT="12865"
LOG_DIR="$RESULTS_DIR_DEFAULT/netperf_server"

usage() {
  cat <<'EOF'
Usage: start_netperf_server.sh [options]

Starts netperf server for request-response latency testing.
Netperf in TCP_RR mode measures round-trip request-response latency.

Options:
  -p, --port <port>         Server port (default: 12865)
  -o, --log-dir <dir>       Output directory for server logs
  -h, --help                Show this help message
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -p|--port)
      PORT="$2"
      shift 2
      ;;
    -o|--log-dir)
      LOG_DIR="$2"
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

require_cmd netserver
ensure_results_dir "$LOG_DIR"

LOG_FILE="$LOG_DIR/netperf_server_$(date -u +"%Y%m%dT%H%M%SZ").log"
log INFO "Starting netperf server on port $PORT"
log INFO "Server log: $LOG_FILE"
log INFO "Connect with: netperf -H <receiver_ip> -p $PORT -t omni -- -d rr"

netserver -p "$PORT" 2>&1 | tee -a "$LOG_FILE"
