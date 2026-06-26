# Retransmit Threshold Analysis: Finding Your Network Ceiling

## Concept: Where Do Retransmits Start?

As throughput increases on a single flow:
1. **Low throughput (< 10 Gbps)**: No packet loss, zero retransmits
2. **Medium throughput (10-20 Gbps)**: NIC RX queue saturation begins, some retransmits appear
3. **High throughput (> 20 Gbps)**: CPU at 100%, more drops, retransmit rate increases
4. **Ceiling (~25 Gbps)**: One CPU maxed out, throughput plateaus despite higher target

---

## Reference Data (Your Baseline)

From your setup elsewhere:

| Config | Throughput | Retransmits | Retrans/Gbps |
|--------|-----------|-------------|--------------|
| 1 Gbps cap | 1.0 Gbps | 0 | 0.0 |
| 10 Gbps cap | 10.0 Gbps | 124 | **12.4** |
| Uncapped | 11.2 Gbps | 228 | **20.4** |

**Interpretation:**
- At 1 Gbps: **Perfect** (no congestion)
- At 10 Gbps: **Some queueing** (124 retransmits = NIC RX queue saturation starting)
- Uncapped: **CPU bottleneck** (retransmits spike as core nears 100%)

---

## Your Test: Single-Flow Ceiling (Azure D64s_v3)

The `test_retransmit_threshold.sh` script runs this scenario:

```csv
test_name,target_gbps,achieved_gbps,retransmits,retrans_per_gbps
p01_b05g,5.0,?,?,?
p01_b10g,10.0,?,?,?
p01_b15g,15.0,?,?,?
p01_b20g,20.0,?,?,?
p01_b25g,25.0,?,?,?
p01_b30g,30.0,?,?,?
```

You'll fill in the `?` with actual results from your Azure cluster.

---

## Step 1: Deploy Cluster

```bash
cd /home/itiagrawal/Projects/iperf3-test

# Deploy with enhanced telemetry (cloud-init now includes retransmit tracking)
./deploy/deploy.sh
```

**What the new cloud-init does:**
- Installs: `tcpdump`, `net-tools`, `mtr`, `bmon` (network observability tools)
- Enables: TCP statistics, SACK, DSACK, FACK (retransmit visibility)
- Creates: `/opt/benchmark/collect_stats.sh` (real-time retransmit collector)
- Persists: Tuning in `/etc/sysctl.d/98-benchmark.conf`

Expected time: **5-7 minutes**

---

## Step 2: SSH to Nodes

After deployment completes, you'll have:

```bash
# Extract IPs from CLUSTER_INFO.txt (created by deploy.sh)
cat deploy/CLUSTER_INFO.txt

# SSH to receiver (where iperf3 server runs)
ssh azureuser@<RECEIVER_PUBLIC_IP>

# SSH to sender (in another terminal)
ssh azureuser@<SENDER_PUBLIC_IP>
```

---

## Step 3: Start iperf3 Server (Receiver Terminal)

```bash
./scripts/start_server.sh --port 5201
```

**Output:**
```
[2026-06-24T...] [INFO] Starting iperf3 server on port 5201
```

---

## Step 4: Run Retransmit Threshold Test (Sender Terminal)

```bash
# Get receiver private IP
RECEIVER_IP=10.0.1.5  # or from cloud-init output

# Run the test
./scripts/test_retransmit_threshold.sh --server-ip $RECEIVER_IP
```

**What it does:**
1. Runs 6 tests from `scenarios/single_flow_ceiling.csv`
2. For each test, captures:
   - Target bandwidth
   - Achieved bandwidth
   - TCP retransmits from iperf3 JSON
   - Retransmits per Gbps ratio
3. Writes summary to `results/retransmit_analysis/retransmit_summary.csv`

**Expected runtime:** ~3 minutes (30 seconds × 6 tests)

---

## Step 5: Analyze Results

### View Summary

```bash
cat results/retransmit_analysis/retransmit_summary.csv | column -t -s','
```

### Example Output (Hypothetical Azure D64s_v3)

```
test_name  target_gbps  achieved_gbps  retransmits  retrans_per_gbps
p01_b05g   5.0          5.0            0            0.0
p01_b10g   10.0         10.0           50           5.0
p01_b15g   15.0         15.0           180          12.0
p01_b20g   20.0         20.0           450          22.5
p01_b25g   25.0         22.5           890          39.6         ← CPU ceiling (achieved < target)
p01_b30g   30.0         22.5           950          42.2         ← Plateau
```

### How to Interpret

**1. Where retransmits start increasing:**
- **p01_b05g (0 retrans)** — Healthy
- **p01_b10g (50 retrans)** — Small queueing, acceptable
- **p01_b15g (180 retrans)** — ← **Threshold crossing** (~12 retrans/Gbps)
- **p01_b20g (450 retrans)** — Contention increasing
- **p01_b25g (890 retrans)** — **Per-core ceiling** (throughput plateaus at ~22.5 Gbps)

**2. Per-CPU capacity:**
- Your ceiling ≈ **22.5 Gbps per core**
- Reference setup ≈ **11.2 Gbps per core** (half yours = better NIC or tuning)

**3. Retransmit ratio progression:**
- `0–10 Gbps`: Ratio < 5 (ideal)
- `10–20 Gbps`: Ratio 5–20 (acceptable, some queueing)
- `20+ Gbps`: Ratio > 30 (CPU bottleneck, not network)

---

## Step 6: Compare to Baseline

Create a comparison:

```bash
echo "=== Your Results vs Reference ==="
echo ""
echo "REFERENCE (Different Setup):"
echo "  1 Gbps:  0 retrans (0/Gbps)"
echo "  10 Gbps: 124 retrans (12.4/Gbps)"
echo "  Max:     11.2 Gbps, 228 retrans (20.4/Gbps)"
echo ""
echo "YOUR RESULTS (Azure D64s_v3):"
cat results/retransmit_analysis/retransmit_summary.csv | tail -n 3
```

---

## Understanding Enhanced Telemetry (cloud-init additions)

### New Tools Installed

| Tool | Purpose |
|------|---------|
| `tcpdump` | Packet capture for deep packet analysis |
| `net-tools` | `netstat`, `ifconfig` for detailed NIC stats |
| `mtr` | Combines ping + traceroute for path analysis |
| `bmon` | Real-time bandwidth monitor |
| `iotop` | I/O wait analysis (check if disk causing latency) |

### New Kernel Tuning

```bash
# View applied tuning
cat /etc/sysctl.d/98-benchmark.conf

# Enable TCP retransmit tracking
net.ipv4.tcp_retries1=3    # First retransmit timeout (exponential backoff)
net.ipv4.tcp_retries2=15   # Final retransmit timeout
net.ipv4.tcp_sack=1        # Selective ACKs (see which packets were lost)
net.ipv4.tcp_dsack=1       # D-SACK (duplicate SACK, retrans detection)
```

### Real-Time Retransmit Monitoring (on receiver)

```bash
# In one terminal on receiver: collect live retransmit stats
/opt/benchmark/collect_stats.sh results/ 1

# In another terminal: watch iperf3 traffic
watch -n 1 'grep -E "tcp|TCP" /proc/net/netstat | head -5'

# Or use bmon (interactive):
bmon
```

---

## Key Metrics to Track

### 1. Retransmit Onset

Where do retransmits first appear? Compare:
- **Your setup:** First retransmits at X Gbps
- **Reference:** First retransmits at 10 Gbps

If yours: *Earlier* → More sensitive NIC queueing
If yours: *Later* → Better buffer tuning or NIC

### 2. Retransmit Slope

Rate of increase as bandwidth grows:
- Steep slope → CPU becoming bottleneck
- Flat slope → Network healthy, CPU not maxed

### 3. Per-Core Ceiling

The throughput where achieved < target:
- **Reference:** 11.2 Gbps
- **Your ceiling:** Should be 20–25 Gbps on Azure Accelerated Networking

---

## Troubleshooting

### No Retransmits at Any Level

**Possible causes:**
- Link layer issue (check with `ethtool`)
- Generous RX buffer (good for throughput, may mask congestion)
- Test duration too short (TCP CC hasn't kicked in)

**Fix:**
```bash
# Increase buffer to see natural queueing
./scripts/run_client_once.sh --server-ip $IP -l 1M -b 30000M -t 60
```

### High Retransmits Even at Low Bandwidth

**Possible causes:**
- Network packet loss (not CPU/queue related)
- TCP window scaling issue

**Fix:**
```bash
# Check TCP window scaling
cat /proc/sys/net/ipv4/tcp_window_scaling  # Should be 1

# Check actual RTT
ping -c 1 $SERVER_IP  # Should be < 1ms
```

### Throughput Plateaus Early (< 20 Gbps)

**Likely:** CPU pinned to single core
**Fix:** Check if all CPUs active:
```bash
while true; do ps aux | grep iperf; sleep 1; done  # Look for CPU %
```

---

## Next Steps After Results

1. **Compare multi-flow:** Run `tcp_sweep.csv` to see if multi-flow achieves scaling
2. **Measure latency impact:** Run netperf during high-bandwidth test
3. **Optimize tuning:** Adjust `-l` (buffer) or test with different protocols
4. **Document baseline:** Store results for future regression testing

---

## File References

- Test script: `scripts/test_retransmit_threshold.sh`
- Scenario: `scenarios/single_flow_ceiling.csv`
- Results: `results/retransmit_analysis/retransmit_summary.csv`
- Enhanced cloud-init: `deploy/cloud-init.sh` (includes telemetry helpers)
- Telemetry scripts: `/opt/benchmark/` (on deployed VMs)

---

## Example Command Sequence (Full Flow)

```bash
# 1. Deploy
cd /home/itiagrawal/Projects/iperf3-test
./deploy/deploy.sh

# 2. Get IPs
cat deploy/CLUSTER_INFO.txt | grep -E "Receiver|Sender"

# 3. SSH Receiver
ssh azureuser@<REC_PUBLIC> "./scripts/start_server.sh --port 5201"

# 4. SSH Sender (new terminal)
ssh azureuser@<SEND_PUBLIC>
cd /home/itiagrawal/Projects/iperf3-test
./scripts/test_retransmit_threshold.sh --server-ip 10.0.1.5

# 5. Analyze
cat results/retransmit_analysis/retransmit_summary.csv | column -t -s','
```

---

## Your Goal

By end of this: **Find the exact throughput where retransmits begin and compare to reference setup.**

This tells you:
- Your per-core network capacity
- Whether your Azure VM's NIC is as good as reference
- Where to tune for better performance
- Baseline for multi-flow scaling expectations
