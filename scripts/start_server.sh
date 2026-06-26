#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "$SCRIPT_DIR/common.sh"

PORT="5201"
LOG_DIR="$RESULTS_DIR_DEFAULT/server"
ONE_OFF="false"

usage() {
  cat <<'EOF'
Usage: start_server.sh [options]

Starts iperf3 server on the receiver node.

Options:
  -p, --port <port>         Server port (default: 5201)
  -o, --log-dir <dir>       Output directory for server logs
      --one-off             Exit after a single client test
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
    --one-off)
      ONE_OFF="true"
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

require_cmd iperf3
ensure_results_dir "$LOG_DIR"

LOG_FILE="$LOG_DIR/iperf3_server_$(date -u +"%Y%m%dT%H%M%SZ").log"
log INFO "Starting iperf3 server on port $PORT"
log INFO "Server log: $LOG_FILE"

if [[ "$ONE_OFF" == "true" ]]; then
  iperf3 -s -p "$PORT" --one-off | tee -a "$LOG_FILE"
else
  iperf3 -s -p "$PORT" | tee -a "$LOG_FILE"
fi
