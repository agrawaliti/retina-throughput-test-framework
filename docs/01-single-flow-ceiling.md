# Test 01: Single-Flow Per-Queue Ceiling

## Hypothesis

A single TCP flow is pinned to one NIC RSS queue → one CPU core handles all softirq
packet processing. The throughput ceiling is therefore a **per-CPU limit**, not a NIC
or link limit.

## Setup

| Item | Value |
|------|-------|
| Sender | `aks-sysd64-25644950-vmss000001` (10.224.0.33) |
| Receiver | `aks-sysd64-25644950-vmss000000` (10.224.0.4) |
| Pod networking | `hostNetwork: true` |
| Protocol | TCP, 1 flow (`-P 1`) |
| Block size | 64 KB (`-l 64K`) |
| Duration | 30 seconds |
| Date | 2026-06-24 |

## Results

| Test | Cap | Achieved | Retransmits | Sender CPU | Receiver CPU | Mean RTT |
|------|-----|----------|-------------|------------|--------------|----------|
| uncapped | none | **15.26 Gbps** | 14,697 | 75.9% | 96.0% | 278 µs |
| cap_10g | 10 Gbps | **10.00 Gbps** | 3,229 | 61.5% | 69.7% | 174 µs |
| cap_25g | 25 Gbps | **15.30 Gbps** | 13,238 | 79.6% | 94.6% | 238 µs |

## Key Findings

### 1. Single-flow ceiling is ~15.3 Gbps

Both the uncapped and 25G-capped runs hit the same wall at **~15.3 Gbps**. The 25G cap
was never reached — the per-queue CPU saturates before the bandwidth limit is hit.

### 2. Receiver is the bottleneck

| State | Receiver CPU | Sender CPU |
|-------|-------------|------------|
| At ceiling | ~94–96% | ~75–80% |

The receiver's single softirq CPU is the constraint. This is consistent with single-flow
RSS behavior: all packets of the flow hash to one queue, one CPU.

### 3. Retransmit count is proportional to CPU pressure

At 10G (well under ceiling), receiver CPU is 69.7% and retransmits are 3,229 — roughly
4–5x lower than at the ceiling. Retransmits grow as the CPU approaches saturation.

### 4. AKS (hostNetwork) matches bare-VM behavior

The uncapped ceiling result (~15.3 Gbps, ~14K retransmits) is consistent with the
earlier bare-VM benchmark (~14 Gbps, ~12–14K retransmits). The pod/container layer
introduces no measurable overhead.

## Interpretation

```
Single-flow ceiling on Standard_D64s_v3 (AKS, westus2):

  ~15.3 Gbps  ←  one RSS queue / one CPU softirq limit
  ~30 Gbps    ←  full VM NIC capacity (multi-flow)

  Utilization of NIC at single-flow ceiling: ~51%
```

The remaining ~15 Gbps of NIC capacity is accessible only by adding more flows
(each flow gets its own RSS queue assignment).

## Commands Used

```bash
# Receiver pod (server) — pinned to vmss000000 via nodeSelector
kubectl exec iperf3-receiver -- iperf3 -s -p 5201 --forceflush

# Sender — uncapped
kubectl exec iperf3-sender -- iperf3 -c 10.224.0.4 -p 5201 -t 30 -P 1 -l 64K --json

# Sender — 10G cap
kubectl exec iperf3-sender -- iperf3 -c 10.224.0.4 -p 5201 -t 30 -P 1 -l 64K -b 10G --json

# Sender — 25G cap
kubectl exec iperf3-sender -- iperf3 -c 10.224.0.4 -p 5201 -t 30 -P 1 -l 64K -b 25G --json
```
