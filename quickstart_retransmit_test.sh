#!/bin/bash
# Quick-start: Deploy cluster and run retransmit threshold test

set -e

PROJ_DIR="/home/itiagrawal/Projects/iperf3-test"

cat <<'EOF'
╔════════════════════════════════════════════════════════════════╗
║    Retransmit Threshold Test: Find Your Network Ceiling       ║
╚════════════════════════════════════════════════════════════════╝

Reference Data (Your Baseline From Different Setup):
  1 Gbps cap:  1.0 Gbps achieved, 0 retransmits
  10 Gbps cap: 10.0 Gbps achieved, 124 retransmits
  Uncapped:    11.2 Gbps achieved, 228 retransmits

You will discover: At what throughput does YOUR Azure cluster start 
retransmitting packets?

══════════════════════════════════════════════════════════════════
                         STEP 1: DEPLOY
══════════════════════════════════════════════════════════════════

This creates two D64s_v3 VMs with enhanced network telemetry:
  - Receiver: vmss000000 (iperf3 server)
  - Sender:   vmss000001 (iperf3 client + test runner)

Time: ~7 minutes

EOF

read -p "Ready to deploy? (y/n) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
  echo "Aborted."
  exit 1
fi

cd "$PROJ_DIR"

echo ""
echo "[1/5] Deploying infrastructure..."
./deploy/deploy.sh

echo ""
echo "✓ Cluster deployed!"
echo ""
echo "Connection info saved to: deploy/CLUSTER_INFO.txt"
cat deploy/CLUSTER_INFO.txt

cat <<'EOF'

══════════════════════════════════════════════════════════════════
                    STEP 2: EXTRACT IPS & SSH
══════════════════════════════════════════════════════════════════

Extract public IPs:
EOF

RECEIVER_PUB=$(grep "Receiver Public IP" deploy/CLUSTER_INFO.txt | cut -d: -f2 | xargs)
SENDER_PUB=$(grep "Sender Public IP" deploy/CLUSTER_INFO.txt | cut -d: -f2 | xargs)
RECEIVER_PRIV=$(grep "Receiver Private IP" deploy/CLUSTER_INFO.txt | cut -d: -f2 | xargs)

echo "Receiver: $RECEIVER_PUB (private: $RECEIVER_PRIV)"
echo "Sender:   $SENDER_PUB"
echo ""
echo "SSH Commands:"
echo "  Receiver: ssh azureuser@$RECEIVER_PUB"
echo "  Sender:   ssh azureuser@$SENDER_PUB"
echo ""

cat <<'EOF'

In TWO terminals, run:

  Terminal 1 (Receiver):
    $ ssh azureuser@<RECEIVER_PUBLIC_IP>
    $ cd /home/itiagrawal/Projects/iperf3-test
    $ ./scripts/start_server.sh --port 5201

  Terminal 2 (Sender):
    $ ssh azureuser@<SENDER_PUBLIC_IP>
    $ cd /home/itiagrawal/Projects/iperf3-test

══════════════════════════════════════════════════════════════════
           STEP 3: RUN RETRANSMIT THRESHOLD TEST
══════════════════════════════════════════════════════════════════

In Terminal 2 (Sender), run:

  $ ./scripts/test_retransmit_threshold.sh --server-ip 10.0.1.5

  This will:
    • Run 6 tests from 5 Gbps to 30 Gbps
    • Capture throughput and retransmits for each
    • Show you where retransmits start increasing
    • Write results to: results/retransmit_analysis/retransmit_summary.csv

  Expected time: ~3 minutes

══════════════════════════════════════════════════════════════════
                   STEP 4: ANALYZE RESULTS
══════════════════════════════════════════════════════════════════

View summary:
  $ cat results/retransmit_analysis/retransmit_summary.csv | column -t -s','

Expected pattern:
  - Low bandwidth (5 Gbps): 0-50 retransmits
  - Medium (10-15 Gbps): 100-300 retransmits
  - High (20+ Gbps): 500+ retransmits (CPU ceiling)

Find: The throughput where achieved < target (CPU ceiling)

══════════════════════════════════════════════════════════════════
                       YOUR NEXT STEPS
══════════════════════════════════════════════════════════════════

After running the test:

1. Compare your ceiling to reference (~11 Gbps)
   If yours is 20-25 Gbps: You have better NIC than reference! ✓

2. Identify retransmit threshold
   Where do retransmits first appear? At what Gbps?

3. Run multi-flow test to validate scaling
   $ ./scripts/run_sweep.sh --server-ip 10.0.1.5 \
     --scenario scenarios/tcp_sweep.csv

4. Test latency under load
   $ ./scripts/run_netperf_sweep.sh --server-ip 10.0.1.5 \
     --scenario scenarios/netperf_sweep.csv

5. Check enhanced telemetry on receiver
   # Live retransmit collection (receiver terminal):
   /opt/benchmark/collect_stats.sh /tmp/net_stats 1
   
   # Parse iperf3 results:
   /opt/benchmark/parse_iperf_retrans.sh \
     results/client/<your_json_file>.json

══════════════════════════════════════════════════════════════════
                      DETAILED GUIDE
══════════════════════════════════════════════════════════════════

Read full analysis guide: RETRANSMIT_ANALYSIS.md

Covers:
  • Interpreting retransmit numbers
  • Comparison to reference data
  • Troubleshooting high/low retransmits
  • Multi-flow scaling expectations

EOF

echo ""
read -p "Continue with SSH info? (y/n) " -n 1 -r
echo

if [[ $REPLY =~ ^[Yy]$ ]]; then
  cat <<EOF

══════════════════════════════════════════════════════════════════
                    QUICK SSH & TEST COMMANDS
══════════════════════════════════════════════════════════════════

Copy-paste into Terminal 1 (Receiver):
───────────────────────────────────────
ssh azureuser@$RECEIVER_PUB
cd /home/itiagrawal/Projects/iperf3-test
./scripts/start_server.sh --port 5201


Copy-paste into Terminal 2 (Sender):
─────────────────────────────────────
ssh azureuser@$SENDER_PUB
cd /home/itiagrawal/Projects/iperf3-test
./scripts/test_retransmit_threshold.sh --server-ip $RECEIVER_PRIV


After test completes:
──────────────────────
cat results/retransmit_analysis/retransmit_summary.csv | column -t -s','

EOF
fi

echo ""
echo "✓ Ready to start testing!"
