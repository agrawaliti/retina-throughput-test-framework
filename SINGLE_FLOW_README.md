# Single-Flow Per-Queue Ceiling Testing

## Concept: One Flow = One Queue = One CPU

### Flow Definition
A **flow** is a single network connection identified by:
- Source IP
- Destination IP  
- Source port
- Destination port
- Protocol (TCP/UDP)

### NIC Queue Assignment (RSS — Receive Side Scaling)
The NIC's RSS algorithm distributes incoming packets to queues based on the flow tuple:
- **One flow** → Always arrives at the **same RX queue** → Processed by the **same CPU core**
- **N flows** → Distributed across **N different RX queues** (ideally) → Processed by **N different CPU cores**

### Single-Flow Test Purpose
Measure the **maximum throughput one CPU core can sustain** by running a single TCP connection with varying bandwidth targets. This reveals:
- CPU ceiling (at what bandwidth does one core hit 100%?)
- Per-core capacity limits
- Scaling characteristics (is it linear or does it plateau?)

---

## Test Scenario: `single_flow_ceiling.csv`

This scenario runs a single TCP connection at different bandwidth levels, three times each for averaging:

```csv
test_name,bandwidth,parallel,length,duration,protocol,repeat
p01_b05g,5000M,1,64K,30,tcp,1
p01_b10g,10000M,1,64K,30,tcp,1
p01_b15g,15000M,1,64K,30,tcp,1
p01_b20g,20000M,1,64K,30,tcp,1
p01_b25g,25000M,1,64K,30,tcp,1
p01_b30g,30000M,1,64K,30,tcp,1
```

**Key Parameters:**
- `parallel=1` — One TCP connection (one flow)
- `bandwidth` — Target rate; ranges from 5 Gbps to 30 Gbps to find the ceiling
- `length=64K` — Standard write buffer
- `duration=30` — Enough time to reach steady state
- `repeat=1` — Run each once; can increase for stability

---

## Expected Results

On Azure Standard_D64s_v3 (64 vCPUs, 2 NUMA nodes):

| Bandwidth Target | Likely Outcome | CPU% (One Core) | Bottleneck |
|---|---|---|---|
| 5 Gbps | Achieved | ~25% | Network not saturated |
| 10 Gbps | Achieved | ~50% | Network not saturated |
| 15 Gbps | Achieved or close | ~75% | CPU approaching limit |
| 20 Gbps | Achieved or throttled | ~85–95% | CPU ceiling approaching |
| 25+ Gbps | Throttled to ~20–22 Gbps | ~100% | **CPU at ceiling** |

**Interpretation:**
- If 25 Gbps target yields ~22 Gbps actual, that's the **per-core ceiling**
- Retransmit count should stay low if network is healthy
- If high retransmits appear at high bandwidth, that's queueing congestion (NIC RX queue full)

---

## How To Run

### 1. Create the Scenario File

File: `scenarios/single_flow_ceiling.csv`

```csv
test_name,bandwidth,parallel,length,duration,protocol
p01_b05g,5000M,1,64K,30,tcp
p01_b10g,10000M,1,64K,30,tcp
p01_b15g,15000M,1,64K,30,tcp
p01_b20g,20000M,1,64K,30,tcp
p01_b25g,25000M,1,64K,30,tcp
p01_b30g,30000M,1,64K,30,tcp
```

### 2. On Receiver Node: Start iperf3 Server

```bash
./scripts/start_server.sh --port 5201
```

### 3. On Sender Node: Run Single-Flow Sweep

```bash
./scripts/run_sweep.sh \
  --server-ip <RECEIVER_PRIVATE_IP> \
  --scenario scenarios/single_flow_ceiling.csv
```

Output goes to `results/client/summary.csv` with columns:
- `timestamp` — When test ran
- `test_name` — e.g., `p01_b25g`
- `throughput_gbps` — Actual achieved bandwidth
- `retransmits` — Packet retransmissions (should be 0–low if healthy)
- `cpu_percent` — CPU usage on sender (if available)
- `results_file` — Path to JSON output

### 4. Monitor During Test (Optional)

On receiver node, in another terminal, watch per-CPU usage:

```bash
watch -n 1 'ps aux | head -20 && echo "---" && top -bn1 | grep -E "^%Cpu"'
```

Or use `htop` for per-CPU visibility:
```bash
htop -u root  # Find iperf3 process
```

---

## Analyzing Results

### Summary CSV Analysis

```bash
# View summary
cat results/client/summary.csv | column -t -s,

# Extract just throughput progression
cat results/client/summary.csv | cut -d, -f1,2,6,7 | column -t -s,
```

### Expected Pattern

```
test_name    achieved_gbps    retransmits    cpu_percent
p01_b05g     5.0              0              ~25
p01_b10g     10.0             0              ~50
p01_b15g     15.0             0              ~75
p01_b20g     20.0             0–10           ~85
p01_b25g     22.0             10–50          ~100  ← CPU ceiling!
p01_b30g     22.0             50–100         ~100  ← Throttled
```

**Key Indicators:**
1. **Throughput plateaus** → CPU-bound (one core at 100%)
2. **Retransmits increase** as bandwidth increases → NIC queue congestion
3. **Achieved vs. Target diverge** → One core can't push more data

---

## What Single-Flow Tells You

### Baseline Understanding
- **Per-core throughput ceiling** on your VM (typically 20–25 Gbps on Azure Accelerated Networking)
- **CPU efficiency** at various load levels
- **When retransmits start** (sign of queue saturation)

### Comparison with Multi-Flow
- Single flow: 22 Gbps / 1 core = **22 Gbps per core**
- Multi-flow: 8 flows × 2.5 Gbps/flow = **20 Gbps total** (underutilized)
  - Why? Load not balanced; some queues may get fewer packets

### Findings to Look For
- **Retransmits at high bandwidth** → NIC RX queue too small for traffic spike
- **CPU < 100%** but throughput low → Possible NUMA affinity issue
- **Steady retransmit rate** → Acceptable; TCP congestion control at work
- **Jumping retransmits** → Sign of queue overflow or packet loss

---

## Next Steps

### After Single-Flow Testing
1. **Document the per-core ceiling** (e.g., "22 Gbps per CPU")
2. **Calculate multi-flow scaling** → Expected throughput with N flows
3. **Run multi-flow sweep** with `scenarios/tcp_sweep.csv` to validate scaling
4. **Compare latency** using netperf during single-flow high-bandwidth test

### Advanced Investigation
If you want to see which CPU core is handling the flow:
```bash
# On receiver, during test
watch -n 1 'ps -p $(pgrep iperf3) -L'  # Shows CPU affinity
```

Or track softirq distribution:
```bash
cat /proc/softirqs | grep NET_RX  # Before test
# ... run test ...
cat /proc/softirqs | grep NET_RX  # After test → Diff shows packet processing
```

---

## File Structure

```
scenarios/
├── single_flow_ceiling.csv      ← NEW: Single-flow bandwidth sweep
├── tcp_sweep.csv                ← Existing: Multi-flow sweep
└── netperf_sweep.csv            ← Existing: Latency tests
```

You can create `single_flow_ceiling.csv` now and run tests, or combine with existing scenarios in a single orchestration script.
