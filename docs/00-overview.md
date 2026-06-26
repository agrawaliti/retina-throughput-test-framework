# Benchmark Overview

## Goal

Measure single-flow TCP throughput and retransmit behavior on Azure AKS nodes using
`Standard_D64s_v3` VMs with Accelerated Networking enabled. The core question:

> **What is the per-CPU-queue throughput ceiling, and at what bandwidth do retransmits appear?**

---

## Infrastructure

| Property | Value |
|----------|-------|
| Subscription | Azure Network Agent - Standalone Test (`37deca37-c375-4a14-b90a-043849bd2bf1`) |
| Resource Group | `iperf3-aks-rg` |
| Cluster Name | `iperf3-aks-d64sv3` |
| Region | `westus2` |
| Kubernetes Version | 1.34 |
| Node VM Size | `Standard_D64s_v3` |
| vCPUs per node | 64 |
| RAM per node | 256 GB |
| Network | Azure CNI, Accelerated Networking (SR-IOV) enabled |
| Node Resource Group | `MC_iperf3-aks-rg_iperf3-aks-d64sv3_westus2` |

---

## Node Roles

| Node | VMSS Instance | Internal IP | Role |
|------|--------------|-------------|------|
| `aks-sysd64-25644950-vmss000000` | vmss000000 | `10.224.0.4` | **Receiver** — runs iperf3 server; all NIC queue CPUs, softirq, and packet processing measured here |
| `aks-sysd64-25644950-vmss000001` | vmss000001 | `10.224.0.33` | **Sender** — runs iperf3 client; generates traffic toward the receiver |

Node labels applied:
```
role=receiver, perf-role=iperf3-receiver   (vmss000000)
role=sender,   perf-role=iperf3-sender     (vmss000001)
```

---

## Observability Stack

**Retina v1.2.2** installed via Helm into `kube-system`, running as a DaemonSet on both nodes.

Plugins enabled:
- `dropreason` — why packets are dropped
- `packetforward` — forwarded packet counts
- `linuxutil` — kernel networking stats
- `dns` — DNS query/response telemetry
- `packetparser` — per-packet flow direction, TCP flags, latency

---

## Test Methodology

### What is a "single flow"?

One TCP connection (`-P 1` in iperf3) between sender and receiver.

Because there is only **one TCP 4-tuple** (src IP, src port, dst IP, dst port), the NIC's
RSS (Receive Side Scaling) hash always produces the same value → all packets land on
**one NIC queue** → serviced by **one CPU core** via softirq.

This means the test measures the **single-CPU queue throughput ceiling**, not the total
VM network capacity.

### iperf3 parameters

| Parameter | Value | Reason |
|-----------|-------|--------|
| `-P 1` | 1 stream | Single flow → single RSS queue → single CPU |
| `-l 64K` | 64 KB send buffer | Matches prior VM test for comparability |
| `-t 30` | 30 seconds | Steady-state measurement window |
| `--json` | JSON output | Structured parsing of retransmits, CPU, RTT |
| `-b Xg` | Variable cap | Sweep or target specific rates |
| `hostNetwork: true` | Pod networking | Bypass CNI overlay; test raw node NIC performance |

### What single flow does NOT test

- Multi-queue NIC parallelism (needs `-P 8+`)
- Cross-NUMA bandwidth
- Total VM network ceiling (requires multiple parallel flows)

---

## Test Series Conducted

| Doc | Test | Purpose |
|-----|------|---------|
| [01-single-flow-ceiling.md](01-single-flow-ceiling.md) | Uncapped + 10G + 25G cap | Establish per-queue throughput ceiling |
| [02-binary-search-retransmit-onset.md](02-binary-search-retransmit-onset.md) | Binary search 1G–15G | Find bandwidth where retransmits first appear |
| [03-retransmit-root-cause.md](03-retransmit-root-cause.md) | fq-rate pacing experiments | Root-cause: bursting vs. pacing |
| [04-retina-observability.md](04-retina-observability.md) | Retina setup | Per-packet observability layer |
