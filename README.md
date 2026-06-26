# Retina Throughput Test Framework

A reproducible benchmark harness for measuring network throughput and latency using **iperf3** and **netperf**. Includes support for Retina network telemetry and ring buffer analysis.

## Features

### Throughput Testing (iperf3)
- Bandwidth shaping with configurable target rates
- Parallel flow fanout for multi-core testing
- Retransmit tracking and analysis
- Optional telemetry capture (softirqs, interrupts, ethtool stats)
- Performance profiling with `perf` and flamegraph support

### Latency Testing (netperf)
- TCP request-response (TCP_RR) benchmarks
- Percentile latency reporting (P50, P90, P99)
- Multi-flow parallel testing
- Throughput/latency correlation analysis

### Retransmit Analysis
- Detect TCP retransmit thresholds
- Identify NIC queue saturation points
- Per-CPU network capacity measurements

## Quick Start

### Prerequisites

```bash
sudo apt-get update
sudo apt-get install -y iperf3 netperf ethtool jq
```

### Basic Usage

1. **Start receiver (server node)**
   ```bash
   chmod +x scripts/*.sh
   ./scripts/start_server.sh --port 5201
   ```

2. **Run client test (client node)**
   ```bash
   ./scripts/run_client_once.sh \
     --server-ip <RECEIVER_IP> \
     --port 5201 \
     --bandwidth 50000M \
     --parallel 8 \
     --duration 30
   ```

3. **Run scenario sweep**
   ```bash
   ./scripts/run_sweep.sh --server-ip <RECEIVER_IP> --scenario scenarios/tcp_sweep.csv
   ```

## Documentation

- [Overview](docs/00-overview.md) - Framework architecture and concepts
- [Single Flow Ceiling Analysis](docs/01-single-flow-ceiling.md) - Per-CPU throughput limits
- [Retransmit Analysis](docs/02-binary-search-retransmit-onset.md) - Queue saturation detection
- [Retina Observability](docs/04-retina-observability.md) - Ring buffer and telemetry capture
- [Netperf Guide](NETPERF_README.md) - Latency testing details
- [Hardware Notes](HARDWARE_NOTES.md) - System configuration reference

## Results

Test results are timestamped and stored in the `results/` directory with JSON and CSV formats for easy analysis and plotting.

## 3b) Run a Single-Flow Ceiling Test (vmss000001)

To measure **per-queue per-CPU throughput ceiling**, run the single-flow scenario:

```bash
./scripts/run_sweep.sh --server-ip <RECEIVER_IP> --scenario scenarios/single_flow_ceiling.csv
```

This tests one TCP connection at bandwidth levels from 5 Gbps to 30 Gbps to find where one CPU core hits its throughput limit. Results show:
- Achieved throughput at each bandwidth target
- Point where throughput plateaus (CPU ceiling)
- Retransmit progression as load increases

See [SINGLE_FLOW_README.md](SINGLE_FLOW_README.md) for detailed interpretation and per-queue analysis.

## 3c) Retransmit Threshold Analysis (vmss000001)

To find **where TCP retransmits start increasing** (NIC queue saturation threshold):

```bash
./scripts/test_retransmit_threshold.sh --server-ip <RECEIVER_IP>
```

Or use the interactive quickstart:

```bash
./quickstart_retransmit_test.sh
```

This runs the single-flow sweep and captures:
- **Where retransmits start** (e.g., "at 15 Gbps, 180 retransmits appear")
- **Per-core throughput ceiling** (e.g., "plateau at 22.5 Gbps")
- **Retransmit ratio progression** (retransmits per Gbps)
- **Comparison to baseline data** (reference setup)

Results go to: `results/retransmit_analysis/retransmit_summary.csv`

### Reference Data (Your Baseline)
Compare your results to this reference from a different setup:

| Config | Throughput | Retransmits |
|--------|-----------|-------------|
| 1 Gbps cap | 1.0 Gbps | 0 |
| 10 Gbps cap | 10.0 Gbps | 124 |
| Uncapped | 11.2 Gbps | 228 |

Your Azure setup should show higher throughput ceiling (~20–25 Gbps) than reference (~11 Gbps).

See [RETRANSMIT_ANALYSIS.md](RETRANSMIT_ANALYSIS.md) for detailed interpretation and troubleshooting.

## 4) Capture Receiver Telemetry (vmss000000)

Find NIC name (usually one of the Mellanox interfaces):

```bash
ip -br link
```

Capture telemetry during/around an iperf run:

```bash
./scripts/capture_receiver_telemetry.sh --nic <NIC_NAME> --duration 30 --interval 1 --tag p31_b80g
```

To include kernel profiling and BPF state snapshots:

```bash
./scripts/capture_receiver_telemetry.sh \
  --nic <NIC_NAME> \
  --duration 30 \
  --interval 1 \
  --tag p31_b80g_perf \
  --perf-record \
  --bpftool-snapshot
```

Optional flags:
- `--perf-record`: records kernel and userspace stacks during the capture window
- `--perf-frequency <n>`: sample frequency, default `99`
- `--perf-callgraph dwarf|fp`: call graph mode for stack capture
- `--no-flamegraph`: skip SVG flamegraph generation
- `--bpftool-snapshot`: capture `bpftool prog/map/link/net show` snapshots before and after the run

If flamegraph helper scripts are installed (`stackcollapse-perf.pl` and `flamegraph.pl` or `FLAMEGRAPH_DIR` is set), the capture will also write `flamegraph.svg`.

This creates snapshot files under `results/receiver_telemetry/<timestamp>_<tag>/`.

---

## 5) Netperf: Measure Latency (Request-Response RTT)

Unlike iperf3 which measures throughput, netperf TCP_RR mode measures the round-trip latency of small request-response exchanges. This complements throughput testing by showing latency behavior and tail latency percentiles.

### Start Netperf Server (vmss000000)

```bash
./scripts/start_netperf_server.sh --port 12865
```

### Run Single Latency Test (vmss000001)

```bash
./scripts/run_netperf_once.sh \
  --server-ip <RECEIVER_IP> \
  --test-name "rr_single_1b" \
  -n 10000 \
  -P 1
```

Outputs latency percentiles (P50, P90, P99) and transactions/sec to:
- `results/netperf_client/summary.csv`

### Run Full Latency Sweep (vmss000001)

Edit `scenarios/netperf_sweep.csv` to define your test matrix, then run:

```bash
./scripts/run_netperf_sweep.sh --server-ip <RECEIVER_IP> --scenario scenarios/netperf_sweep.csv
```

See [NETPERF_README.md](NETPERF_README.md) for detailed latency interpretation and multi-flow analysis.

---

## Suggested Execution Pattern

**Per-Queue CPU Ceiling (Single-Flow Baseline):**
1. On receiver, start iperf3 server: `./scripts/start_server.sh`
2. On sender, run single-flow sweep: `./scripts/run_sweep.sh --server-ip <IP> --scenario scenarios/single_flow_ceiling.csv`
3. Record per-CPU throughput ceiling from `results/client/summary.csv`
4. This establishes baseline CPU capacity; use for multi-flow scaling analysis

**Baseline Latency (Idle Network):**
1. On receiver, start netperf server: `./scripts/start_netperf_server.sh`
2. On sender, run netperf sweep: `./scripts/run_netperf_sweep.sh --server-ip <IP> --scenario scenarios/netperf_sweep.csv`
3. Record baseline latencies from `results/netperf_client/summary.csv`

**Multi-Flow Throughput Testing:**
1. On receiver, start iperf3 server: `./scripts/start_server.sh`
2. On receiver (optional), capture telemetry: `./scripts/capture_receiver_telemetry.sh --nic <NIC> --duration 30`
3. On sender, run multi-flow sweep: `./scripts/run_sweep.sh --server-ip <IP> --scenario scenarios/tcp_sweep.csv`
4. Review throughput results from `results/client/summary.csv` and compare to single-flow ceiling

**Latency Under Load:**
1. On receiver, start both servers: iperf3 and netperf
2. On sender, run iperf3 for sustained load: `./scripts/run_client_once.sh --server-ip <IP> --bandwidth 25000M --duration 60` (one terminal)
3. On sender (parallel), run netperf sweep: `./scripts/run_netperf_sweep.sh --server-ip <IP> --scenario scenarios/netperf_sweep.csv` (another terminal)
4. Compare idle latencies vs. loaded latencies to identify contention effects

## Notes for Your Hardware

- `-P 31` is a good starting point to map to 31 RX queues.
- Explore `-l` values like `16K`, `64K`, `128K`, `256K` to observe packet-rate and GRO effects.
- For target-rate tests below line rate, use `-b` to hold load constant.
- If you need true saturation studies, include tests without `-b` and compare retransmits/CPU behavior.
