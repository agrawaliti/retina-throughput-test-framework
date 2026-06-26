# Test 03: Retransmit Root-Cause — Bursting vs. Pacing

## Hypothesis

The high retransmit counts observed (thousands at 5–15 Gbps) are not caused by
actual packet loss in the network, but by **TCP microbursting** — the sender emits
large bursts of 64 KB segments faster than the receiver's single CPU can ACK them,
triggering spurious RTOs.

The fix: add `--fq-rate` to use the Linux `fq` (Fair Queueing) packet scheduler,
which **paces** the traffic at the wire rate instead of bursting.

## Setup

| Item | Value |
|------|-------|
| Infrastructure | Two Standard_D64s_v3 VMs (bare VM, pre-AKS cluster) |
| Sender IP | 10.0.1.4 |
| Receiver IP | 10.0.1.5 |
| Protocol | TCP, 1 flow, 64 KB block, 30 sec |
| Conditions tested | Default (no pacing) vs. `--fq-rate` pacing |

## Results

### Without pacing (default iperf3 burst behavior)

| Cap | Achieved | Retransmits | Retrans/Gbps |
|-----|----------|-------------|--------------|
| 5 Gbps | 5.00 Gbps | **11,520** | 2,304 |
| 10 Gbps | 10.00 Gbps | **23,270** | 2,327 |

### With `--fq-rate` pacing (fq scheduler, paced at cap rate)

| Cap | Achieved | Retransmits | Retrans/Gbps |
|-----|----------|-------------|--------------|
| 5 Gbps | 5.00 Gbps | **108** | 21.6 |
| 10 Gbps | 10.00 Gbps | **22** | 2.2 |

### Reduction factor

| Cap | Without pacing | With pacing | Reduction |
|-----|---------------|-------------|-----------|
| 5 Gbps | 11,520 | 108 | **~107x fewer** |
| 10 Gbps | 23,270 | 22 | **~1,058x fewer** |

## Key Findings

### 1. Pacing reduces retransmits by 100–1000x

Adding `--fq-rate` at 10 Gbps brought retransmits from 23,270 down to **22** — a
1,058x reduction with **identical throughput**. This is the single most impactful
finding of the entire study.

### 2. Microbursting, not network loss, is the root cause

Without pacing, iperf3 sends 64 KB segments as fast as the kernel allows, creating
bursts that overwhelm the receiver's softirq processing for brief moments. The
receiver's NIC queue fills, packets are delayed, TCP RTOs fire, and segments are
retransmitted even though the network itself dropped nothing.

With `--fq-rate`, the kernel's `fq` qdisc paces output at the exact target rate,
spacing packets evenly and eliminating the burst:

```
Without pacing:  [burst 64KB][burst 64KB][burst 64KB] → RTO → retransmit
With fq pacing:  [pkt]...[pkt]...[pkt]...[pkt] → smooth → no RTO
```

### 3. The Azure network fabric is not the problem

The near-zero retransmits under pacing confirm the Azure VNet fabric (same-subnet,
same-region) has essentially **zero drop rate** at these speeds. The fabric can
sustain 10 Gbps single-flow cleanly when the sender does not burst.

### 4. Practical implication

Applications sending large bulk transfers (ML training, file copy, checkpoint sync)
should use the OS packet scheduler (`tc qdisc fq`) or paced send paths to avoid
triggering spurious TCP retransmits.

## How fq Pacing Works

```
Without fq:
  Sender kernel → socket buffer → NIC TX ring → wire
  (all data flushed as fast as NIC can accept, ~line rate bursts)

With fq + --fq-rate:
  Sender kernel → socket buffer → fq qdisc (paced at X Gbps) → NIC TX ring → wire
  (fq schedules packet departure times; inter-packet gap = 1 / rate)
```

The `--fq-rate` flag in iperf3 sets `SO_MAX_PACING_RATE` on the socket, which
instructs the fq scheduler to pace that flow specifically.

## Commands Used

```bash
# Without pacing (baseline)
iperf3 -c 10.0.1.5 -p 5201 -t 30 -P 1 -l 64K -b 5G --json
iperf3 -c 10.0.1.5 -p 5201 -t 30 -P 1 -l 64K -b 10G --json

# With fq pacing (at the same cap rate)
iperf3 -c 10.0.1.5 -p 5201 -t 30 -P 1 -l 64K -b 5G --fq-rate 5G --json
iperf3 -c 10.0.1.5 -p 5201 -t 30 -P 1 -l 64K -b 10G --fq-rate 10G --json
```
