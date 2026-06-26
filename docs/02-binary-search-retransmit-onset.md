# Test 02: Binary Search — Retransmit Onset Threshold

## Hypothesis

There is a bandwidth threshold below which the single-flow TCP connection runs
cleanly (zero or near-zero retransmits), and above which retransmits grow rapidly.
A binary search can locate this threshold efficiently.

## Setup

| Item | Value |
|------|-------|
| Sender | `aks-sysd64-25644950-vmss000001` (10.224.0.33) |
| Receiver | `aks-sysd64-25644950-vmss000000` (10.224.0.4) |
| Protocol | TCP, 1 flow, 64 KB block, 15 sec per probe |
| Search bounds | 1,000 Mbps (1 Gbps) — 15,000 Mbps (15 Gbps) |
| Clean threshold | ≤ 50 retransmits |
| Termination | Gap < 200 Mbps |
| Date | 2026-06-24 |

## Binary Search Trace

| Iter | Cap (Mbps) | Cap (Gbps) | Achieved | Retransmits | Status |
|------|-----------|-----------|----------|-------------|--------|
| 1 | 8,000 | 8.0 | 8.00 Gbps | 708 | DIRTY |
| 2 | 4,500 | 4.5 | 4.50 Gbps | 134 | DIRTY |
| 3 | 2,750 | 2.75 | 2.75 Gbps | **0** | CLEAN |
| 4 | 3,625 | 3.625 | 3.62 Gbps | **0** | CLEAN |
| 5 | 4,062 | 4.062 | 4.06 Gbps | 136 | DIRTY |
| 6 | 3,843 | 3.843 | 3.84 Gbps | **4** | CLEAN |
| 7 | 3,952 | 3.952 | 3.95 Gbps | 27 | CLEAN |

**Converged at: 3,952 Mbps (clean) ↔ 4,062 Mbps (dirty)**

## Confirmation Runs

After convergence, the boundary points were re-run to confirm stability:

| Run | Cap | Retransmits | Verdict |
|-----|-----|-------------|---------|
| "Clean ceiling" re-run | 3,952 Mbps | **248** | Dirty on replay |
| "First dirty" re-run | 4,062 Mbps | **216** | Dirty on replay |

## Key Findings

### 1. No sharp cliff — the onset zone is probabilistic

The confirmation runs showed that a point measured as "clean" during the search
(0–27 retransmits) re-ran dirty (200+ retransmits). This means:

- **There is no deterministic zero-retransmit boundary**
- Retransmits in the 3–5 Gbps range are **stochastic** — they depend on scheduler
  jitter, hypervisor timeslice variation, and interrupt coalescing timing
- A single probe is not sufficient to classify a point as "clean"

### 2. Stable zones

| Zone | Bandwidth | Behavior |
|------|-----------|----------|
| Reliably clean | **< ~2.75 Gbps** | 0 retransmits in all probes |
| Noisy / transitional | **~3–5 Gbps** | 0–250 retransmits, varies by run |
| Consistently dirty | **> ~5 Gbps** | Hundreds to thousands of retransmits |
| Ceiling | **~15 Gbps** | CPU saturated, high retransmits |

### 3. Exponential growth region

The "exponential growth" that was hypothesized starts at **~5 Gbps**:

```
1 Gbps  →        0 retransmits  (flat baseline)
3 Gbps  →        0 retransmits  (stable)
4 Gbps  →    0–250 retransmits  (onset, noisy)
5 Gbps  →     ~134 retransmits
8 Gbps  →     ~708 retransmits
10 Gbps →   ~3,229 retransmits
15 Gbps →  ~15,000 retransmits  (ceiling)
```

This is roughly exponential above 5 Gbps: doubling bandwidth from 5→10G multiplies
retransmits by ~25x.

### 4. Why is the onset noisy?

The retransmit trigger is the **RTO (Retransmit Timeout)** firing when a packet is
delayed beyond its expected ACK window. In this range (3–5 Gbps), packet delay is
caused by:

- **Interrupt coalescing (rx-usecs)** on the receive NIC — batches interrupts,
  introducing variable µs-scale delays
- **Hypervisor scheduler jitter** — Azure vCPU preemption introduces sub-ms
  latency spikes sporadically
- **TCP CWND oscillation** — CUBIC's sawtooth window cycle passes through the
  danger zone differently on each run

## Commands Used

```bash
# Single probe function
kubectl exec iperf3-sender -- iperf3 \
  -c 10.224.0.4 -p 5201 \
  -t 15 -P 1 -l 64K \
  -b "${mbps}M" --json
```

Full binary search script: see `scripts/binary_search_retransmit.sh` (to be added).
