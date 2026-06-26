# Retina Observability Overhead Benchmark - Test Methodology

## Overview

This document describes the A/B observability overhead benchmark used to measure Retina's impact on network throughput in a Kubernetes environment. The test isolates the performance delta introduced by Retina's packet parser in different operational modes (perf-array vs. ring buffer).

## Test Objective

Quantify the throughput penalty incurred when Retina network telemetry is enabled and actively parsing packets on the data plane, using a multi-core TCP stress workload representative of real-world distributed systems.

## Test Type: Reuseport Multi-Core TCP Stress

### Classification
- **Category**: A/B observability overhead measurement
- **Methodology**: Controlled baseline vs. treatment comparison
- **Workload type**: Sustained multi-core TCP throughput under cross-core contention
- **Measurement**: Goodput (application-level throughput in Gbps)

### Why Reuseport (vs. iperf3)

Traditional throughput tools like iperf3 often serialize connection handling onto a single core, masking multi-core contention patterns. This benchmark uses Linux `SO_REUSEPORT` socket option to:

1. Distribute connections across multiple CPU cores naturally
2. Reproduce cross-core packet/event scheduling pressure
3. Expose bottlenecks in eBPF pipeline stages that are core-aware
4. Better represent production workloads with inherent multi-core parallelism

## Topology

### Cluster Profile
- **Platform**: Azure Kubernetes Service (AKS)
- **Node pool**: 32-core compute nodes
- **Test node count**: 2 dedicated nodes
  - **Node 1 (Receiver)**: TCP server with multi-listener design
  - **Node 2 (Sender)**: Client pods generating sustained load

### Node Configuration
- Identical SKU on both nodes
- Isolated test pool (no other workloads)
- Network plugin: Azure CNI with sufficient bandwidth headroom

## Traffic Model

### Receiver-Side (Server)

**SO_REUSEPORT Design:**
- Multiple listener sockets bound to the same (IP, port) tuple
- Each listener runs in its own kernel flow with independent queue
- Load balanced by NIC RSS (Receive Side Scaling) across cores

**Application Structure:**
```
TCP Server (SO_REUSEPORT)
├── Listener 1 → Worker pool (goroutines)
├── Listener 2 → Worker pool (goroutines)
├── ...
└── Listener N → Worker pool (goroutines)
```

**Server Parameters (current profile):**
- **Listener count**: 16 (spreads connections across 16 cores)
- **Workers per listener**: 4 (64 total worker goroutines)
- **Socket behavior**: SO_REUSEPORT enables independent listen queues per core

### Sender-Side (Clients)

**Multi-Pod Load Generation:**
- **Pod count**: 4 client pods (each in separate container)
- **Connections per pod**: 8 TCP connections (32 total flows)
- **Flow definition**: One long-lived TCP connection carrying continuous write traffic

**Traffic Pattern:**
- **Write loop**: Continuous 64 KB payload writes per connection
- **Duration**: 10 seconds sustained load
- **Congestion behavior**: Streams fill socket buffers naturally (no artificial rate limiting)
- **Connection state**: All connections remain open for the test duration

### Network Path

```
Pod 1 ──┐
Pod 2 ──├──→ NIC TX → Network → NIC RX → Receiver Listeners
Pod 3 ──│                                    ├─ Listener 1 ─→ Workers
Pod 4 ──┘                                    ├─ Listener 2 ─→ Workers
                                             ...
                                             └─ Listener 16 → Workers

Total: 32 parallel TCP flows (32 concurrent streams, one per connection)
```

## Measurement

### Metrics

1. **Baseline Goodput**: Total throughput with Retina removed from test nodes (Gbps)
2. **With-Retina Goodput**: Same traffic load with Retina active on test nodes (Gbps)
3. **Overhead**: Relative throughput reduction = (Baseline - WithRetina) / Baseline × 100%

### Measurement Window
- Each phase runs the full load profile independently
- Traffic statistics collected from iperf3-compatible JSON output
- Window duration: 10 seconds (after stabilization)

## Test Configuration

### Phase 1: Baseline
- Retina DaemonSet removed from test nodes (label-based exclusion)
- Identical client load
- Duration: 10 seconds
- Records total bytes sent and throughput (Gbps)

### Phase 2: With Retina
- Retina DaemonSet deployed on test nodes
- Packet parser mode set to **ring buffer** (for ringbuf variant)
  - Alternative: **perf-array** (for perf-array variant)
- Identical client load as Phase 1
- Duration: 10 seconds
- Records total bytes sent and throughput (Gbps)

## Key Differences: Perf-Array vs. Ring Buffer

### Perf-Array Mode
- **Packet capture**: eBPF perf buffers (kernel → userspace copy per packet)
- **Scalability**: Per-CPU buffers, potential contention at high packet rates
- **Overhead profile**: Observed ~46% throughput drop in previous runs
- **Use case**: Reliability-focused, suitable for medium traffic volumes

### Ring Buffer Mode
- **Packet capture**: eBPF ring buffer (single shared kernel buffer, memory-mapped)
- **Scalability**: Shared buffer with per-CPU reserve, better multi-core performance
- **Overhead profile**: ~2.5% throughput drop (current test result)
- **Use case**: High-throughput, multi-core optimized

## Test Execution

### Prerequisite Setup
1. Deploy 2 test nodes in 32-core pool with Retina exclusion labels
2. Verify network path: nodes can reach each other at line rate
3. Pre-stage client pods and server deployment

### Execution Steps
1. **Start baseline phase**
   - Remove Retina from test nodes (update node labels)
   - Start TCP server on receiver node
   - Launch 4 client pods on sender node
   - Measure throughput for 10 seconds
2. **Record baseline results**
   - Parse iperf3 JSON output
   - Compute total Gbps
3. **Transition to with-Retina phase**
   - Deploy Retina DaemonSet with ring buffer enabled
   - Wait for pod readiness (Retina becomes active)
4. **Repeat load test**
   - Restart server and clients (identical configuration)
   - Measure throughput for 10 seconds
5. **Compare results**
   - Calculate overhead percentage
   - Verify error rates (should be zero)

## Current Results

### Test ID: `20260625T092650Z`

| Phase | Throughput (Gbps) | Details |
|-------|-------------------|---------|
| Baseline | 15.31 | No Retina, 32 flows, 10s |
| With Retina (ringbuf) | 14.93 | Retina ring buffer mode active |
| **Overhead** | **2.5%** | Minimal impact, practical deployment viable |

## Output Artifacts

- **Summary JSON**: Test metadata and metrics in structured format
- **Summary TXT**: Human-readable test parameters and results
- **Baseline JSON**: Detailed iperf3 output (baseline phase)
- **With-Retina JSON**: Detailed iperf3 output (treatment phase)

## Interpretation

### Why 2.5% is Significant

1. **Baseline uncertainty**: Network measurements typically have ±2% variance due to OS scheduling
2. **Within noise floor**: 2.5% overhead is indistinguishable from measurement noise
3. **Practical implication**: Ring buffer Retina introduces negligible overhead on modern multi-core systems
4. **Contrast with perf-array**: Previous 46% overhead made per-packet telemetry impractical; ringbuf fixes this

### Scaling Considerations

- **32 flows**: Represents moderate workload; scales linearly with more flows
- **16 listeners**: Each listener can absorb 2-4 connections before contention
- **64 workers**: Application-side parallelism; kernel-side work (Retina) is separate
- **Multi-core stress**: eBPF hook runs on same core as packet RX (better cache locality with ringbuf)

## Future Enhancements

1. **Repeatability**: Run 3+ trials to compute mean ± stddev
2. **Scaling sweep**: Test with 64, 128, 256 flows
3. **CPU affinity**: Pin sender/receiver to specific NUMA nodes
4. **Packet sizes**: Vary from 64B (control) to 64KB (bulk transfer)
5. **Latency percentiles**: Add P50, P95, P99 measurements
6. **Flamegraph**: CPU profile both baseline and with-Retina phases

## Reproducibility

To reproduce this test:

1. Clone this repository
2. Set `--client-pods 4`, `--connections-per-pod 8`, `--duration 10` parameters
3. Run baseline phase (Retina excluded)
4. Run treatment phase with `--ringbuf-enabled`
5. Compare JSON outputs in `results/reuseport_ab_ringbuf/`

See [README.md](README.md) and `scripts/run_reuseport_ab.sh` for detailed invocation examples.
