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

4. **Run the portable multi-core reuseport benchmark**
  ```bash
  ./scripts/run_reuseport_ab.sh --active-cores 32
  ```
  This auto-selects two Linux worker nodes, shapes a sustained cross-core workload
  around 32 active data-plane cores, and writes a profile JSON describing the
  chosen nodes, flows, listeners, workers, and runtime thread counts.

## Documentation

- [Overview](docs/00-overview.md) - Framework architecture and concepts
- [Single Flow Ceiling Analysis](docs/01-single-flow-ceiling.md) - Per-CPU throughput limits
- [Retransmit Analysis](docs/02-binary-search-retransmit-onset.md) - Queue saturation detection
- [Retina Observability](docs/04-retina-observability.md) - Ring buffer and telemetry capture
- [Netperf Guide](NETPERF_README.md) - Latency testing details
- [Hardware Notes](HARDWARE_NOTES.md) - System configuration reference

## Results

Test results are timestamped and stored in the `results/` directory with JSON and CSV formats for easy analysis and plotting.

## Reuseport A/B Benchmark

Use `scripts/run_reuseport_ab.sh` when you want a workload that stresses many RX
queues and user-space consumers under sustained cross-core traffic instead of a
single iperf3 flow.

Default shaping rules:
- Targets `32` active data-plane cores when available
- Uses `8` long-lived flows per active core
- Sets receiver listeners to the active-core count
- Sets receiver workers to `4x` the active-core count
- Derives client pod count and per-pod connections from the target core count

Useful flags:

```bash
./scripts/run_reuseport_ab.sh \
  --node-label agentpool=bench \
  --active-cores 32 \
  --flows-per-core 8
```

If the selected nodes expose fewer than 32 allocatable CPUs, the script scales the
workload down to the largest portable shape both nodes can sustain and records the
effective values in the run profile.

## Retina Buffer Mode Comparison (AKS)

This repo also measures Retina packetparser overhead and compares its two
kernel-to-userspace transfer mechanisms (**perf-array** vs **ring-buffer**) on
32-core AKS nodes, reproducing the analysis from
[Who Will Observe the Observability?](https://blog.zmalik.dev/p/who-will-observe-the-observability).

### 1. Provision benchmark cluster(s)

```bash
# Azure CNI Overlay, 2x Standard_D32s_v3 benchmark nodes (taint workload=benchmark)
RESOURCE_GROUP=retina-bench-baseline-rg CLUSTER_NAME=retina-bench-baseline \
  bash deploy/create_aks_benchmark_cluster.sh
```

See [deploy/create_aks_benchmark_cluster.sh](deploy/create_aks_benchmark_cluster.sh)
for all tunables (VM size, node count, network plugin/mode/dataplane).

### 2. Install Retina in Advanced Mode (packetparser + adv_* metrics)

```bash
VERSION=v1.2.2
helm upgrade --install retina oci://ghcr.io/microsoft/retina/charts/retina \
  --version $VERSION --namespace kube-system --create-namespace \
  --set image.tag=$VERSION --set operator.tag=$VERSION --set image.pullPolicy=Always \
  --set operator.enabled=true --set operator.enableRetinaEndpoint=true \
  --set enabledPlugin_linux="\[dropreason\,packetforward\,linuxutil\,dns\,packetparser\]" \
  --set enablePodLevel=true --set enableAnnotations=true \
  --set packetParserRingBuffer=enabled            # omit or =disabled for perf-array
kubectl annotate namespace default retina.sh=observe --overwrite
```

Advanced metrics appear under the `networkobservability_adv_*` prefix
(`adv_forward_count`, `adv_forward_bytes`, `adv_tcpflags_count`,
`adv_node_apiserver_latency`, etc.). Verify with:

```bash
kubectl get --raw "/api/v1/namespaces/kube-system/pods/<retina-pod>:10093/proxy/metrics" \
  | grep '^networkobservability_adv_'
```

### 3. Run the buffer crossover sweep

```bash
# Sweeps payload sizes across a perf-array cluster and a ring-buffer cluster,
# comparing receiver-side median throughput + Retina CPU + connection errors.
PAYLOAD_SIZES="512 1024 2048 4096 8192 16384" CONNECTIONS=165 DURATION=120s \
  ./scripts/run_buffer_crossover_sweep.sh
```

Results are written to `results/buffer_crossover/<id>_sweep_summary.csv`. See
[scripts/run_buffer_crossover_sweep.sh](scripts/run_buffer_crossover_sweep.sh)
for the full methodology header.

**Key finding:** packetparser overhead scales with **packets/second**, not
bandwidth. The synchronous TC-BPF parse runs in RX softirq on every packet, so
small payloads (high packet rate) incur large overhead while large payloads are
nearly free. The perf-array vs ring-buffer choice mostly matters when Retina's
userspace reader is CPU-constrained (throttled), which is the regime the blog
documented.

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
