# iperf3 & Netperf Two-Node Benchmark Framework

This workspace provides a reproducible benchmark harness for measuring both **throughput** (iperf3) and **latency** (netperf) on your cluster:

- Receiver node: `vmss000000` (runs iperf3 server + netperf server; instrumented node)
- Sender node: `vmss000001` (runs iperf3 client + netperf client)

## Testbed Profile

- SKU: identical on both nodes
- CPU: 160 vCPUs (AMD EPYC 9V74)
- NUMA: 5 nodes x 32 CPUs
- L3 cache: 640 MB
- NIC: 100 Gbps Mellanox `mlx5`, 31 RX queues

## What This Framework Covers

### iperf3: Throughput Testing
- Bandwidth shaping (`-b`) for fixed target rates
- Parallel flow fanout (`-P`) to spread flows across RSS queues
- Write buffer tuning (`-l`) to affect packet rate and GRO behavior
- Duration control (`-t`)
- **Retransmit tracking** from iperf3 JSON output
- Optional receiver telemetry snapshots (`/proc/softirqs`, `/proc/interrupts`, `ethtool`)
- Optional `perf record` capture with `perf script` and flamegraph output
- Optional `bpftool` snapshots of loaded programs, maps, links, and net attachments

### Retransmit Threshold Analysis
- Find the throughput where TCP retransmits begin (NIC queue saturation)
- Measure per-CPU network capacity ceiling
- Compare against baseline (provided reference data)
- Single-flow bandwidth sweep from 5–30 Gbps
- Enhanced telemetry on VMs for packet-level visibility

### netperf: Latency Testing (Request-Response RTT)
- TCP_RR mode: measures round-trip latency of small request-response exchanges
- Configurable request/response sizes
- Reports percentile latencies (P50, P90, P99) + transactions per second
- Multi-flow parallel testing to see contention effects
- Complementary to iperf3: shows latency under load, tail latency behavior

## Files

### iperf3 (Throughput)
- `scripts/start_server.sh`: Start iperf3 server on receiver
- `scripts/run_client_once.sh`: Run one test and log JSON + CSV summary
- `scripts/run_sweep.sh`: Execute a scenario matrix from CSV
- `scripts/capture_receiver_telemetry.sh`: Capture receiver-side telemetry snapshots
- `scenarios/tcp_sweep.csv`: Example TCP throughput test matrix (multi-flow)
- `scenarios/single_flow_ceiling.csv`: Single-flow bandwidth sweep (per-queue CPU ceiling)

### netperf (Latency)
- `scripts/start_netperf_server.sh`: Start netperf server on receiver
- `scripts/run_netperf_once.sh`: Run one latency test and log results
- `scripts/run_netperf_sweep.sh`: Execute a latency scenario matrix from CSV
- `scenarios/netperf_sweep.csv`: Example TCP_RR latency test matrix

### Documentation
- `README.md`: This file
- `HARDWARE_NOTES.md`: Hardware profile and implications
- `NETPERF_README.md`: Detailed netperf guide + latency analysis
- `SINGLE_FLOW_README.md`: Single-flow CPU ceiling testing + per-queue analysis
- `docs/ringbuf-capture.md`: Retina ring buffer benchmark + CPU flamegraph capture guide

## Prerequisites

Install at minimum:

```bash
sudo apt-get update
sudo apt-get install -y iperf3 netperf ethtool jq numactl
```

- `iperf3`: throughput testing
- `netperf`: latency testing (includes `netperf` and `netserver`)
- `jq`: optional, for automatic result extraction

## Retina Three-Mode Repro (Baseline vs Perf-Array vs Ringbuf)

Use this when you want a single command that anyone can run to reproduce and compare:
- Baseline (Retina excluded)
- Perf-array mode (Retina on, `packetParserRingBuffer: disabled`)
- Ringbuf mode (Retina on, `packetParserRingBuffer: enabled`)

### One Command

```bash
cd /home/itiagrawal/Projects/iperf3-test
./scripts/run_reuseport_three_modes.sh \
  --client-pods 4 \
  --connections-per-pod 8 \
  --duration 10s \
  --listeners 16 \
  --workers 64
```

### What it does concretely

1. Forces Retina DaemonSet scheduling via `perf-test-retina=enabled` label.
2. Sets `packetParserRingBuffer: disabled`, restarts Retina, runs `run_reuseport_ab.sh`.
3. Sets `packetParserRingBuffer: enabled`, restarts Retina, runs `run_reuseport_ab.sh` again.
4. Produces a single consolidated comparison in text, CSV, and JSON.

### Ringbuf Capture Run

If you want the ringbuf pass plus receiver-side capture artifacts in one command, use:

```bash
cd /home/itiagrawal/Projects/iperf3-test
./scripts/run_ringbuf_capture.sh \
  --nic <NIC_NAME> \
  --client-pods 4 \
  --connections-per-pod 8 \
  --duration 10s \
  --listeners 16 \
  --workers 64 \
  --capture-duration 30 \
  --capture-interval 1
```

That command runs the ringbuf benchmark and then captures:
- `perf.data`
- `perf.script.txt`
- `flamegraph.svg` when flamegraph tools are available
- `bpftool` snapshots of `prog`, `map`, `link`, and `net`

Results are written under `results/ringbuf_capture/<RUN_ID>/`.

### Output artifacts

Each run creates a timestamped directory:

```text
results/reuseport_three_modes/<RUN_ID>/
  perf_array/
  ringbuf/
  three_mode_summary.txt
  three_mode_summary.csv
  three_mode_summary.json
```

The CSV is easy to share/plot and has exactly the three modes:

```csv
mode,baseline_gbps,retina_gbps,drop_vs_canonical_baseline_pct
baseline,15.20,15.20,0.0
perf-array,15.20,8.21,46.0
ringbuf,15.20,14.93,1.8
```

Note: `baseline_gbps` is pinned to the perf-array pass baseline as the canonical baseline for side-by-side comparison.

## 1) Start Receiver Server (vmss000000)

```bash
cd /home/itiagrawal/Projects/iperf3-test
chmod +x scripts/*.sh
./scripts/start_server.sh --port 5201
```

Optional one-shot mode:

```bash
./scripts/start_server.sh --port 5201 --one-off
```

## 2) Run a Single Client Test (vmss000001)

```bash
cd /home/itiagrawal/Projects/iperf3-test
./scripts/run_client_once.sh \
  --server-ip <RECEIVER_IP> \
  --port 5201 \
  --test-name p31_b80g_l128k_t30 \
  --bandwidth 80000M \
  --parallel 31 \
  --length 128K \
  --duration 30 \
  --protocol tcp
```

Outputs:

- JSON: `results/client/<timestamp>_<test_name>.json`
- Summary CSV: `results/client/summary.csv`

## 3) Run a Multi-Flow Sweep (vmss000001)

Edit `scenarios/tcp_sweep.csv` to define your matrix, then run:

```bash
./scripts/run_sweep.sh --server-ip <RECEIVER_IP> --scenario scenarios/tcp_sweep.csv
```

CSV columns are:

```text
test_name,bandwidth,parallel,length,duration,protocol
```

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
