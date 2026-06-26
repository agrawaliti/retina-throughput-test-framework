#!/usr/bin/env bash
set -euo pipefail

# Test retransmit threshold with single-flow ceiling scenario
# Runs bandwidth sweep and captures retransmit progression

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

SERVER_IP=""
RECEIVER_NIC="eth0"
RESULTS_DIR="${ROOT_DIR}/results/retransmit_analysis"

usage() {
  cat <<'EOF'
Usage: test_retransmit_threshold.sh --server-ip <IP> [options]

Runs single-flow ceiling test with retransmit collection.
Tests bandwidth from 5 Gbps to 30 Gbps and captures:
  - Actual throughput achieved
  - TCP retransmits at each level
  - Retransmit/throughput ratio

Options:
  --server-ip <IP>          Receiver node IP (required)
  --nic <nic>               Receiver NIC for telemetry (default: eth0)
  -o, --results-dir <dir>   Output directory (default: results/retransmit_analysis)
  -h, --help                Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --server-ip)
      SERVER_IP="$2"
      shift 2
      ;;
    --nic)
      RECEIVER_NIC="$2"
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
      echo "Unknown argument: $1"
      usage
      exit 1
      ;;
  esac
done

if [[ -z "$SERVER_IP" ]]; then
  echo "Error: --server-ip is required"
  usage
  exit 1
fi

mkdir -p "$RESULTS_DIR"

echo "=== Retransmit Threshold Analysis ==="
echo "Server: $SERVER_IP"
echo "Scenario: scenarios/single_flow_ceiling.csv"
echo "Results: $RESULTS_DIR"
echo ""

# Create summary file
SUMMARY_FILE="$RESULTS_DIR/retransmit_summary.csv"
cat > "$SUMMARY_FILE" <<'HEADER'
test_name,target_gbps,achieved_gbps,retransmits,retrans_per_gbps,cpu_percent,results_file
HEADER

# Run each test from single-flow scenario
CSV_FILE="$ROOT_DIR/scenarios/single_flow_ceiling.csv"

while IFS=',' read -r test_name bandwidth parallel length duration protocol; do
  # Skip header
  [[ "$test_name" == "test_name" ]] && continue
  
  # Extract target bandwidth from string like "5000M"
  TARGET_GBPS=$(echo "$bandwidth" | sed 's/M$//' | awk '{print $1/1000}')
  
  echo "Running: $test_name (target: $TARGET_GBPS Gbps)"
  
  # Run the test
  TEST_OUTPUT=$("$ROOT_DIR/scripts/run_client_once.sh" \
    --server-ip "$SERVER_IP" \
    -b "$bandwidth" \
    -P "$parallel" \
    -l "$length" \
    -t "$duration" \
    --protocol "$protocol" \
    --test-name "$test_name" \
    -o "$RESULTS_DIR" 2>&1)
  
  # Extract results from iperf3 JSON
  JSON_FILE=$(find "$RESULTS_DIR" -name "*${test_name}*.json" -type f | sort | tail -1)
  
  if [[ -f "$JSON_FILE" ]]; then
    ACHIEVED_GBPS=$(jq -r '.end.sum_sent.bits_per_second / 1000000000' "$JSON_FILE" 2>/dev/null || echo "0")
    RETRANSMITS=$(jq -r '.end.sum_sent.retransmits' "$JSON_FILE" 2>/dev/null || echo "0")
    
    # Calculate retransmits per Gbps
    if (( $(echo "$ACHIEVED_GBPS > 0" | bc -l) )); then
      RETRANS_PER_GBPS=$(echo "scale=2; $RETRANSMITS / $ACHIEVED_GBPS" | bc -l 2>/dev/null || echo "0")
    else
      RETRANS_PER_GBPS="0"
    fi
    
    CPU_PCT=$(jq -r '.end.cpu_utilization_sender.user // "N/A"' "$JSON_FILE" 2>/dev/null || echo "N/A")
    
    echo "  ✓ Achieved: $ACHIEVED_GBPS Gbps, Retransmits: $RETRANSMITS, Ratio: $RETRANS_PER_GBPS/Gbps"
    
    echo "$test_name,$TARGET_GBPS,$ACHIEVED_GBPS,$RETRANSMITS,$RETRANS_PER_GBPS,$CPU_PCT,$JSON_FILE" >> "$SUMMARY_FILE"
  else
    echo "  ✗ No JSON result found"
  fi
  
done < "$CSV_FILE"

echo ""
echo "=== Results Summary ==="
cat "$SUMMARY_FILE" | column -t -s','

echo ""
echo "=== Analysis ==="
echo "Summary file: $SUMMARY_FILE"
echo ""
echo "Expected pattern (baseline from reference setup):"
echo "  1 Gbps cap   → 0 retransmits"
echo "  10 Gbps cap  → ~124 retransmits"
echo "  Uncapped     → 11.2 Gbps max, ~228 retransmits"
echo ""
echo "Your threshold: Look for where retransmits start increasing significantly"
