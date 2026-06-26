#!/usr/bin/env bash
set -euo pipefail

NIC="enP40153s1"
CAPTURE_DURATION="30"
CAPTURE_INTERVAL="1"
CAPTURE_TAG="ringbuf"
OUT_DIR="/home/itiagrawal/Projects/iperf3-test/results/ringbuf_capture/20260625T142306Z_capture"
mkdir -p "$OUT_DIR"

TS="$(date -u +%Y%m%dT%H%M%SZ)"
RUN_DIR="$OUT_DIR/$TS"
mkdir -p "$RUN_DIR"

echo "capture_tag=$CAPTURE_TAG" > "$RUN_DIR/meta.env"
echo "node=aks-usr32-25342902-vmss000000" >> "$RUN_DIR/meta.env"
echo "nic=$NIC" >> "$RUN_DIR/meta.env"

cat /proc/softirqs > "$RUN_DIR/softirqs.before.txt"
cat /proc/interrupts > "$RUN_DIR/interrupts.before.txt"
bpftool prog show > "$RUN_DIR/bpftool.prog.before.txt" 2>&1 || true
bpftool map show > "$RUN_DIR/bpftool.map.before.txt" 2>&1 || true
bpftool link show > "$RUN_DIR/bpftool.link.before.txt" 2>&1 || true
bpftool net show > "$RUN_DIR/bpftool.net.before.txt" 2>&1 || true

perf record -a -g --call-graph dwarf -F 99 -o "$RUN_DIR/perf.data" -- sleep "$CAPTURE_DURATION" >/dev/null 2>&1 &
PERF_PID="$!"

printf '%s\n' 'timestamp,net_rx_total,net_tx_total' > "$RUN_DIR/samples.csv"
end_time=$((SECONDS + CAPTURE_DURATION))
while [[ $SECONDS -lt $end_time ]]; do
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  net_rx_total="$(awk '/NET_RX/ {sum=0; for (i=2; i<=NF; i++) sum+=$i; print sum}' /proc/softirqs)"
  net_tx_total="$(awk '/NET_TX/ {sum=0; for (i=2; i<=NF; i++) sum+=$i; print sum}' /proc/softirqs)"
  printf '%s,%s,%s\n' "$now" "$net_rx_total" "$net_tx_total" >> "$RUN_DIR/samples.csv"
  sleep "$CAPTURE_INTERVAL"
done

wait "$PERF_PID"
perf script -i "$RUN_DIR/perf.data" > "$RUN_DIR/perf.script.txt"

if command -v stackcollapse-perf.pl >/dev/null 2>&1 && command -v flamegraph.pl >/dev/null 2>&1; then
  stackcollapse-perf.pl < "$RUN_DIR/perf.script.txt" > "$RUN_DIR/perf.folded.txt"
  flamegraph.pl "$RUN_DIR/perf.folded.txt" > "$RUN_DIR/flamegraph.svg"
fi

bpftool prog show > "$RUN_DIR/bpftool.prog.after.txt" 2>&1 || true
bpftool map show > "$RUN_DIR/bpftool.map.after.txt" 2>&1 || true
bpftool link show > "$RUN_DIR/bpftool.link.after.txt" 2>&1 || true
bpftool net show > "$RUN_DIR/bpftool.net.after.txt" 2>&1 || true
cat /proc/softirqs > "$RUN_DIR/softirqs.after.txt"
cat /proc/interrupts > "$RUN_DIR/interrupts.after.txt"
