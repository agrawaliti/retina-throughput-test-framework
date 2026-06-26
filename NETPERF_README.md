# Netperf Integration: Request-Response Latency Testing

## Overview

This document describes the **netperf TCP_RR (Request-Response)** latency testing capability, which complements **iperf3** throughput testing.

| Tool | Metric | Mode | What It Measures |
|------|--------|------|------------------|
| **iperf3** | Throughput (Gbps, Mbps) | Bulk data transfer | How fast can data flow one-way? |
| **netperf** | Latency (milliseconds) | Request-response echo | How long does a round-trip take? |

---

## What Is Netperf TCP_RR?

In **TCP_RR mode**, netperf measures the latency of small request-response exchanges:

1. **Client sends** a small request (configurable size, default 1 byte)
2. **Server echoes** a response (configurable size, default 1 byte)
3. **Client measures** the round-trip time (RTT)
4. **Repeat** thousands of times
5. **Report** latency percentiles: P50, P90, P99, plus min/max/mean

### Example Flow
```
Time:     0ms    1ms    2ms    3ms
Client:   [REQ]→ ←[RSP]  [REQ]→ ←[RSP]  ...
RTT:          1ms          1ms          (microseconds to milliseconds)
```

### Why It Matters
- **Throughput alone doesn't tell the story**: High throughput with poor latency = jittery, unpredictable network
- **Latency distribution matters**: P99 latency tells you worst-case user experience
- **Complements iperf3**: While iperf3 saturates links, netperf shows latency under load

---

## Scripts & Usage

### 1. Start Netperf Server (Receiver)

```bash
# On receiver node (vmss000000)
./scripts/start_netperf_server.sh [--port 12865]
```

**Output:**
```
[2026-06-24T...] [INFO] Starting netperf server on port 12865
[2026-06-24T...] [INFO] Server log: results/netperf_server/netperf_server_....log
```

The server runs in foreground; Ctrl+C to stop.

### 2. Run Single Latency Test (Sender)

```bash
# On sender node (vmss000001)
./scripts/run_netperf_once.sh \
  --server-ip <receiver_private_ip> \
  --test-name "my_test" \
  -P 1 \
  -n 10000
```

**Parameters:**
- `--server-ip` — Receiver IP (required)
- `-p, --port` — Server port (default: 12865)
- `-r, --req-size` — Request size in bytes (default: 1)
- `-s, --resp-size` — Response size in bytes (default: 1)
- `-n, --num-trans` — Number of transactions (default: 10000)
- `-P, --parallel` — Number of parallel instances (default: 1)
- `--test-name` — Label for results (default: single_run)

**Output:**
```
results/netperf_client/2026-06-24T...json
results/netperf_client/2026-06-24T...txt
results/netperf_client/summary.csv (appended)
```

**Example Result CSV Row:**
```csv
2026-06-24T12:34:56Z, p08_1b, sender-vm, 10.0.1.5, 12865, 1, 1, 10000, 8, 5000.0, 0.100, 2.500, 0.235, 0.200, 0.500, 2.000, results/netperf_...json
```

### 3. Run Full Test Sweep

```bash
# Run all scenarios from CSV matrix
./scripts/run_netperf_sweep.sh \
  --server-ip <receiver_private_ip> \
  --scenario scenarios/netperf_sweep.csv
```

**Parameters:**
- `--server-ip` — Receiver IP (required)
- `--scenario` — CSV file defining test matrix (required)
- `--skip-failed` — Continue if a test fails (default: stop on first failure)

**Output:** Per-test results + aggregated `summary.csv`

---

## Scenario Matrix Format

File: `scenarios/netperf_sweep.csv`

```csv
test_name,port,req_size,resp_size,num_trans,parallel
rr_single_1b,12865,1,1,10000,1
rr_single_64b,12865,64,64,10000,1
rr_parallel8_1b,12865,1,1,10000,8
```

**Columns:**
- `test_name` — Unique identifier (e.g., `p08_1b`)
- `port` — Netperf server port
- `req_size` — Request payload size (bytes)
- `resp_size` — Response payload size (bytes)
- `num_trans` — Transaction count (higher = more stable percentiles)
- `parallel` — Number of parallel instances

---

## Interpreting Results

### Latency Percentiles

```
P50 = 0.100 ms    (50% of requests faster than this)
P90 = 0.500 ms    (90% of requests faster than this)
P99 = 2.000 ms    (99% of requests faster than this → "tail latency")
```

### Throughput (Transactions Per Second)

- Single flow: typically 5K–15K TPS on Azure Standard_D64s_v3
- Multi-flow: ~5K–8K TPS per parallel instance (decreases with contention)

### Key Metrics for Network Quality

| Metric | Good | Acceptable | Poor |
|--------|------|-----------|------|
| **P50 latency** | <0.5 ms | 0.5–2 ms | >2 ms |
| **P99 latency** | <2 ms | 2–10 ms | >10 ms |
| **TPS per flow** | >10K | 5K–10K | <5K |
| **Jitter (P99–P50)** | <1 ms | 1–5 ms | >5 ms |

---

## Comparing With Iperf3

### Typical Test Sequence

1. **First: Run netperf sweep** to establish baseline latency (idle network)
   ```bash
   ./scripts/run_netperf_sweep.sh --server-ip 10.0.1.5 --scenario scenarios/netperf_sweep.csv
   ```

2. **Second: Run iperf3 sweep** to measure throughput (bulk transfer)
   ```bash
   ./scripts/run_sweep.sh --server-ip 10.0.1.5 --scenario scenarios/tcp_sweep.csv
   ```

3. **Third: Run iperf3 + netperf in parallel** to see how latency degrades under load
   - One terminal: `iperf3 -s -c <ip> -t 60` (60 second bulk transfer)
   - Other terminal: `run_netperf_sweep.sh --server-ip 10.0.1.5 --scenario scenarios/netperf_sweep.csv` (simultaneous latency test)
   - **Result**: Shows if high throughput destroys latency (tail latency degradation)

### Example Correlation

```
Idle netperf P99:     0.500 ms
iperf3 bulk transfer: 25 Gbps
Concurrent netperf P99: 5.000 ms  ← 10× worse under load!
```

This indicates **NIC queue saturation** or **softirq congestion** — a key finding for network optimization.

---

## Multi-Flow Testing

### Run Parallel Instances

Netperf supports multiple parallel request-response flows:

```bash
./scripts/run_netperf_once.sh \
  --server-ip 10.0.1.5 \
  -P 8 \
  -n 10000
```

This spawns **8 netperf instances** on separate TCP connections, each measuring independent RTT.

**Behavior:**
- Each instance measures its own RTT
- Reported throughput = sum of all instances (TPS)
- Latencies usually increase per-flow as system load increases
- Useful to see **queue contention effects**

---

## Azure Hardware Notes (Standard_D64s_v3)

### Netperf Performance Characteristics

- **Max RTT (no congestion)**: ~0.1–0.3 ms
- **Typical P50 (idle)**: 0.15–0.20 ms
- **Typical P99 (idle)**: 0.50–1.00 ms
- **Max TPS (single flow)**: ~15K–20K TPS
- **Degradation under iperf3 load**: 2–10× increase in P99 latency

### Factors Affecting Latency

1. **TCP buffer tuning** (in cloud-init)
   - Large buffers → Higher throughput, potentially higher latency
   - Small buffers → Lower latency, throughput may suffer

2. **Network queue depth**
   - Azure SR-IOV NIC: 8–16 RX queues
   - Saturation → queuing delay → tail latency spike

3. **CPU frequency scaling**
   - `turbostat` can show CPU state during test
   - Disabled by default on Azure VMs for consistency

---

## Troubleshooting

### Netperf Command Not Found
```bash
# On both nodes
sudo apt-get install -y netperf
```

### Cannot Connect to Server
```bash
# Verify netserver is running on receiver
ps aux | grep netserver

# Test firewall
sudo ss -tlnp | grep 12865

# Check NSG (Azure CLI)
az network nsg rule list --resource-group iperf3-rg --nsg-name iperf3-nsg -o table
```

### High Jitter / Unstable Latencies
- Increase `-n` (transaction count) to smooth outliers
- Use `netstat -s` to check packet drops: `RcvPkts`, `RetransPkts`
- Run on idle network first (no background traffic)

### Low TPS Numbers
- Normal for high-latency paths (WAN vs. LAN)
- Verify you're using private IPs: `--server-ip 10.0.1.x` not public IP
- Check `/proc/interrupts` for softirq storm (indicates CPU bottleneck)

---

## File Structure

```
iperf3-test/
├── scripts/
│   ├── start_netperf_server.sh    # Launch netserver
│   ├── run_netperf_once.sh        # Single latency test
│   ├── run_netperf_sweep.sh       # Sweep runner
│   └── ...
├── scenarios/
│   ├── netperf_sweep.csv          # Latency test matrix
│   └── tcp_sweep.csv              # Throughput test matrix
├── results/
│   ├── netperf_client/
│   │   ├── summary.csv            # Aggregated latency results
│   │   └── 2026-06-24T...json     # Per-test output
│   └── client/                    # (iperf3 results)
└── NETPERF_README.md              # This file
```

---

## References

- [Netperf Documentation](https://hewlettpackard.github.io/netperf/)
- [TCP_RR Mode](https://hewlettpackard.github.io/netperf/doc_section2.html#TCP_RR)
- [Performance Analysis Tips](https://hewlettpackard.github.io/netperf/doc_section4.html)
