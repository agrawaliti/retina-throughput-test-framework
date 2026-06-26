# Hardware Notes: Standard_D64s_v3 vs. Original Target

## Original Target (AMD EPYC 9V74, not available in current quota)
- **CPU**: 160 vCPUs (AMD EPYC 9V74)
- **NUMA**: 5 nodes × 32 CPUs
- **L3 Cache**: 640 MB
- **NIC**: 100 Gbps Mellanox mlx5 (31 RX queues)
- **Memory**: 640 GB
- **Use case**: High-end network benchmark with sophisticated RSS/IRQ pinning

## Actual Deployment: Standard_D64s_v3
- **CPU**: 64 vCPUs (Intel Xeon Platinum, 3rd Gen)
- **NUMA**: 2 nodes × 32 CPUs
- **L3 Cache**: 96 MB per core (total ~6 GB for node)
- **NIC**: Azure Accelerated Networking (SR-IOV, ~25 Gbps single flow, up to 30+ Gbps multi-flow)
- **Memory**: 256 GB
- **Disk Cache**: 576 GB local SSD

## NIC Capability Trade-offs
- Mellanox mlx5 (original): 100 Gbps, 31 RX queues, advanced offload
- Azure Accel Net (actual): ~25-30 Gbps sustained, SR-IOV virtio, 8-16 RX queues typical
- **Impact**: Lower absolute throughput ceiling, but still sufficient to stress test packet handling, queue distribution, softirq load

## Cache Hierarchy
- Original: More aggressive L3 cache (640 MB), larger NUMA overhead
- Actual: Smaller L3 per-core but modern Cascade Lake pipeline is efficient
- **Impact**: Latency profiles differ; GRO/coalescing behavior will show different patterns

## Testing Implications

### Still Valid
- iperf3 parameter sweep: -b, -P, -l, -t
- Parallel flow distribution across queues
- Retransmit tracking
- Softirq/interrupt counting
- CPU utilization per flow

### Different Baselines
- Expected throughput ~25-30 Gbps (not 100 Gbps)
- Fewer RX queues (~8 vs 31) = coarser flow distribution
- Smaller L3 cache = different GRO coalescence sweet spots
- 64 cores per node instead of 160 = different per-core contention

### Recommendations
1. **Bandwidth targets**: Use -b 5000M, 10000M, 15000M, 20000M, 25000M (vs original 10G/20G/40G)
2. **Parallel flows**: -P 8, 16 align better with queue count
3. **Buffer sizes**: Same -l range (16K, 64K, 128K, 256K) still valid
4. **Metrics**: Retransmits % will be higher under equivalent load due to lower throughput ceiling

## Next Steps
- Run baseline single-flow test to confirm max throughput
- Adjust scenario sweep -b targets downward
- Correlate softirq counts with lower absolute throughput
