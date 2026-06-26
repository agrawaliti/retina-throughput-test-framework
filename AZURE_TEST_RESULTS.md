# Azure iperf3 Benchmark Results

## Test Summary

**Date:** June 24, 2026  
**Infrastructure:** Standard_D64s_v3 VMs (64 vCPUs, 256GB RAM, Accelerated Networking enabled)  
**Test Type:** Single-flow TCP throughput with bandwidth capping  
**Network:** Azure VNet 10.0.0.0/16, Private IPs 10.0.1.4↔10.0.1.5  

---

## Raw Results

| Test | Target | Achieved | Retransmits | Retrans/Gbps | Status |
|------|--------|----------|-------------|--------------|--------|
| p01_b05g | 5 Gbps | 5.00 Gbps | 12,860 | 2572.10 | ✓ |
| p01_b10g | 10 Gbps | 10.00 Gbps | 23,726 | 2372.68 | ✓ |
| p01_b15g | 15 Gbps | 14.34 Gbps | 20,984 | 1462.90 | ✓ |
| p01_b20g | 20 Gbps | 12.86 Gbps | 20,481 | 1592.34 | ✓ |
| p01_b25g | 25 Gbps | 13.87 Gbps | 26,398 | 1903.12 | ✓ |
| p01_b30g | 30 Gbps | 13.27 Gbps | 19,537 | 1472.57 | ✓ |

---

## Key Findings

### 1. **Throughput Ceiling: ~14 Gbps**
- Single flow achieves ~14 Gbps sustained throughput
- This represents approximately **20% utilization** of Accelerated Networking (theoretical 25-30 Gbps)
- Performance plateaus above 15 Gbps bandwidth cap
- Achieved throughput: **5.0, 10.0, 14.3, 12.9, 13.9, 13.3 Gbps**

### 2. **Retransmit Behavior**
- **CRITICAL:** Retransmits present at ALL bandwidth levels (even 5 Gbps)
- Baseline reference showed 0 retransmits at 1 Gbps ❌
- This Azure setup shows **non-zero retransmits from the start**

#### Retransmit Progression:
| Bandwidth | Retransmits | Rate (retrans/Gbps) | Trend |
|-----------|-------------|---------------------|-------|
| 5 Gbps | 12,860 | 2572 | **SPIKE** ⬆️ |
| 10 Gbps | 23,726 | 2373 | High plateau |
| 15 Gbps | 20,984 | 1463 | **Improving** ⬇️ |
| 20 Gbps | 20,481 | 1592 | Slight decline |
| 25 Gbps | 26,398 | 1903 | Spike again ⬆️ |
| 30 Gbps | 19,537 | 1473 | Stabilized ⬇️ |

### 3. **Comparison to Reference Baseline**

**Reference Setup** (from user's data):
```
1 Gbps cap   → 0 retransmits (uncorrelated)
10 Gbps cap  → 124 retransmits
Uncapped     → 11.2 Gbps max, 228 retransmits
```

**Azure Setup** (this run):
```
5 Gbps cap   → 12,860 retransmits (103x MORE than ref @ 10G!)
10 Gbps cap  → 23,726 retransmits (191x MORE than ref @ 10G!)
14 Gbps max  → ~20K retransmits (88x MORE than ref uncapped!)
```

**Ratio:** Azure shows **~100-200x higher retransmit rate** than reference 🚨

---

## Analysis & Interpretation

### Why so many retransmits on Azure?

#### Hypothesis 1: **TCP Window Scaling / Buffer Tuning**
- Azure's cloud-init applies aggressive TCP tuning: `rmem_max/wmem_max=134MB`, `netdev_max_backlog=5000`
- This may create **buffer misalignment** or cause aggressive ACK coalescing
- Window scaling could mismatch between sender/receiver

#### Hypothesis 2: **NIC Driver / Accelerated Networking Behavior**
- Azure Accelerated Networking (SR-IOV backed) may have **different packet loss or flow control**
- Single-flow throughput ceiling at 14 Gbps suggests **per-queue saturation** or **interrupt coalescing**
- RSS (Receive Side Scaling) may be routing all traffic to one queue despite multi-flow setup

#### Hypothesis 3: **MTU / Segmentation Issues**
- MTU on Azure typically 1500 bytes
- Large packet buffer (64KB from scenario) combined with bandwidth caps may trigger **retransmits during TSO (TCP Segmentation Offload)**
- Window size mismatch causing sender to retransmit "out of order" segments

#### Hypothesis 4: **Timing / Clock Skew**
- Both VMs on same Azure infrastructure = synchronized clocks ✓
- But TCP retransmit timers may be sensitive to hypervisor scheduling
- 30-second test duration may catch OS scheduling artifacts

---

## Per-Core Analysis (Single Flow → Single Queue)

Given:
- **1 flow = 1 RSS queue = 1 CPU core** (by design)
- 64 vCPU Standard_D64s_v3 = 2 NUMA nodes (32 CPUs each)
- Accelerated Networking peak ~30 Gbps total = **~468 Mbps per CPU** (simplified)

**Single-core ceiling in this test: 14 Gbps / 1 flow ≈ CPU saturation threshold**

This is **plausible but high** compared to reference (11.2 Gbps), suggesting:
- ✓ Accelerated Networking driver efficiency on D64s
- ✗ OR retransmits are inflating the counter without actual lost packets

---

## Network Path Analysis

### Sender Configuration:
- Private IP: 10.0.1.4
- MSS: inferred from received packets
- Buffer: 64 KB (from scenarios/single_flow_ceiling.csv)
- Parallel: 1 flow

### Receiver Configuration:
- Private IP: 10.0.1.5  
- Server port: 5201
- Mode: single connection accept

### Network:
- VNet: 10.0.0.0/16
- Subnet: 10.0.1.0/24 (same subnet = no gateway traversal)
- Latency: <1ms expected (same region, direct connection)

**No inter-region routing, no WAN effects.** This is pure **intra-region VLAN performance**.

---

## Recommendations for Next Steps

### 1. **Reduce System Noise**
   ```bash
   # Disable TCP timestamps (may reduce retransmits)
   echo "net.ipv4.tcp_timestamps=0" | sudo tee -a /etc/sysctl.d/99-disable-timestamps.conf
   
   # Reduce NIC interrupt coalescing
   ethtool -C eth0 rx-usecs 0 rx-frames 0
   
   # Pin process to CPU core
   taskset -c 0 ./scripts/test_retransmit_threshold.sh
   ```

### 2. **Compare Against Raw iperf3** (no bandwidth cap)
   - Remove `-b` flag to see uncapped ceiling
   - Compare "uncapped Gbps" vs "uncapped retransmits"
   - Expected: closer to ~11-14 Gbps with potentially lower retrans

### 3. **Test with TCP_NODELAY**
   - iperf3 default: enables TCP_NODELAY
   - Verify this isn't causing aggressive retransmit timers

### 4. **Run Multi-Flow Test**
   - Baseline (reference) used multi-flow (implicit from results)
   - Re-run `scenarios/tcp_sweep.csv` (8-31 parallel flows)
   - Multi-flow throughput scaling: expected ~200+ Gbps (way beyond 30G cap)
   - Compare retrans ratios: per-flow vs total

### 5. **Latency Measurements**
   - Run `netperf` TCP_RR for latency baseline
   - High retransmit rates should correlate with latency spikes
   - P99 latency should show tail behavior

---

## Conclusion

✅ **Infrastructure works:** Single flow sustains ~14 Gbps  
⚠️ **Unexpected behavior:** Massive retransmit counts at all bandwidth levels  
❓ **Root cause:** Likely **tuning/driver/MTU mismatch** not fundamental network issue  

**Next action:** Run counter-tests (uncapped, multi-flow, latency) to isolate cause.

---

## Raw Data Files

All results stored in: `results/retransmit_analysis/`

- `retransmit_summary.csv` — Summary table
- `20260624T141413Z_p01_b05g.json` — Full iperf3 output (5 Gbps)
- `20260624T141443Z_p01_b10g.json` — Full iperf3 output (10 Gbps)
- ... (4 more JSON files)

