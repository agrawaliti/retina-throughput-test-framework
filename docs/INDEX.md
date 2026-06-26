# Azure Network Benchmark — Documentation Index

**Date:** 2026-06-24  
**Cluster:** `iperf3-aks-d64sv3` (westus2)  
**VM Size:** `Standard_D64s_v3` — 64 vCPUs, 256 GB RAM, Accelerated Networking  

---

## Documents

| # | File | Summary |
|---|------|---------|
| 0 | [00-overview.md](00-overview.md) | Cluster details, node roles, test methodology, what "single flow" means |
| 1 | [01-single-flow-ceiling.md](01-single-flow-ceiling.md) | Per-queue throughput ceiling: **~15.3 Gbps**, receiver CPU saturates first |
| 2 | [02-binary-search-retransmit-onset.md](02-binary-search-retransmit-onset.md) | Binary search to find retransmit onset; result: **stochastic zone 3–5 Gbps** |
| 3 | [03-retransmit-root-cause.md](03-retransmit-root-cause.md) | Root cause: **TCP microbursting**, not network loss; fq pacing reduces retransmits 100–1000x |
| 4 | [04-retina-observability.md](04-retina-observability.md) | Retina v1.2.2 install; plugins: dropreason, packetparser, linuxutil, dns, packetforward |

---

## Top-Level Findings

### Finding 1: Single-flow ceiling is ~15 Gbps (one CPU)

A single TCP connection saturates **one NIC RSS queue → one CPU core** via softirq.
On `Standard_D64s_v3`, this ceiling is **~15.3 Gbps**. The remaining ~15 Gbps of the
VM's 30 Gbps NIC capacity requires multiple parallel flows.

### Finding 2: Retransmit onset is in a noisy zone (~3–5 Gbps)

There is no sharp cliff. Below ~2.75 Gbps: reliably zero retransmits. Above ~5 Gbps:
hundreds to thousands per test. Between 3–5 Gbps: stochastic — the same bandwidth
cap can produce 0 or 250 retransmits on back-to-back runs due to hypervisor jitter
and interrupt coalescing timing.

### Finding 3: Root cause is microbursting, not network loss

With default iperf3 settings at 10 Gbps: **23,270 retransmits**.  
With `--fq-rate 10G` pacing at the same 10 Gbps: **22 retransmits**.

The Azure VNet fabric itself has near-zero drop rate. The retransmits are caused by
the sender emitting 64 KB segment bursts faster than the receiver's single softirq
CPU can process ACKs, triggering spurious TCP RTOs.

### Finding 4: AKS hostNetwork = bare-VM equivalent performance

iperf3 pods with `hostNetwork: true` match bare-VM benchmark results identically.
No measurable overhead from the Kubernetes/CNI layer for raw TCP throughput tests.

---

## Retransmit Reference Table

| Bandwidth | Mode | Retransmits | Source |
|-----------|------|-------------|--------|
| 1 Gbps | default | 0 | VM benchmark |
| 2.75 Gbps | default | 0 | binary search |
| 5 Gbps | default | ~11,520–12,860 | VM + AKS |
| 5 Gbps | fq-paced | **108** | VM pacing test |
| 10 Gbps | default | ~23,270–23,726 | VM + AKS |
| 10 Gbps | fq-paced | **22** | VM pacing test |
| 10 Gbps | AKS cap | 3,229 | AKS single-flow |
| 15 Gbps (uncapped) | default | ~14,697–15,260 | AKS single-flow |

---

## Cluster Quick Reference

```bash
# Switch to benchmark cluster
kubectl config use-context iperf3-aks-d64sv3

# Check nodes
kubectl get nodes -o wide

# Check iperf3 pods
kubectl get pods -o wide

# Check Retina agents
kubectl get pods -n kube-system -l app.kubernetes.io/name=retina -o wide
```

---

## Raw Data

Raw iperf3 JSON outputs from the bare-VM benchmark sweep are in `results_azure/`:

```
results_azure/
├── 20260624T141413Z_p01_b05g.json   5 Gbps test
├── 20260624T141443Z_p01_b10g.json   10 Gbps test
├── 20260624T141513Z_p01_b15g.json   15 Gbps test
├── 20260624T141543Z_p01_b20g.json   20 Gbps test
├── 20260624T141613Z_p01_b25g.json   25 Gbps test
├── 20260624T141643Z_p01_b30g.json   30 Gbps test
└── retransmit_summary.csv           summary table
```
