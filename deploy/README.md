# Two-Node iperf3 Benchmark Cluster Deployment

## Overview

This deployment creates a two-node iperf3 benchmark cluster on Azure:
- **Receiver Node** (vmss000000): Runs iperf3 server, instrumented for telemetry
- **Sender Node** (vmss000001): Runs iperf3 client, generates traffic

## Hardware Configuration

### VM SKU: Standard_D64s_v3
- **vCPUs**: 64 (Intel Xeon Platinum, 3rd Gen Cascade Lake)
- **Memory**: 256 GB
- **Local Disk**: 576 GB SSD
- **NUMA**: 2 nodes × 32 CPUs
- **Network**: Azure Accelerated Networking (SR-IOV)
  - ~25–30 Gbps sustained throughput
  - 8–16 RX queues (vs 31 on original benchmark)
  - Lower overhead than Mellanox but sufficient for packet handling studies

### NIC Notes
- **Accelerated Networking enabled** on both VMs
- Provides hardware TSO/RSC offload
- Lower queue count than original 100 Gbps Mellanox setup
- Tuned for smaller parallel flow tests (-P 8, 16 vs -P 31)

## Files Structure

```
deploy/
  ├── main.bicep              # Azure Bicep infrastructure template
  ├── cloud-init.sh           # VM bootstrap script (installs iperf3, ethtool, etc.)
  ├── deploy.sh               # Orchestration script (runs Bicep deployment)
  └── README.md               # This file

../
  ├── scripts/                # iperf3 test runner scripts
  ├── scenarios/tcp_sweep.csv # Test matrix definition
  ├── HARDWARE_NOTES.md       # Detailed hardware implications
  └── CLUSTER_INFO.txt        # Generated after successful deployment
```

## Deployment Process

### Prerequisites
- Azure CLI (`az`) installed and authenticated
- SSH key at `~/.ssh/id_rsa.pub` (auto-generated if missing)
- Sufficient quota in westus2 for 2× Standard_D64s_v3 VMs (128 vCPUs needed, currently available)

### Run Deployment

```bash
cd /home/itiagrawal/Projects/iperf3-test/deploy
chmod +x deploy.sh
./deploy.sh
```

**Optional environment overrides:**
```bash
LOCATION=eastus RESOURCE_PREFIX=iperf3-test ./deploy.sh
```

### What the Script Does

1. **Validates prerequisites** (az CLI, SSH key)
2. **Generates SSH keypair** if missing
3. **Creates Bicep parameters** from environment
4. **Deploys via `az deployment sub create`**:
   - Resource group
   - Virtual network (10.0.0.0/16)
   - Subnet (10.0.1.0/24)
   - Network security group (allows SSH, iperf3 port 5201)
   - 2× Public IPs
   - 2× Network interfaces (with accelerated networking)
   - 2× Standard_D64s_v3 VMs (Ubuntu 24.04 LTS)
5. **Monitors deployment** (polls every 15s until complete)
6. **Outputs connectivity info**:
   - Public/private IPs
   - SSH commands
   - Saved to `CLUSTER_INFO.txt`

## Post-Deployment

After successful deployment, file `CLUSTER_INFO.txt` contains:

```
RECEIVER_PUBLIC_IP=<ip>
RECEIVER_PRIVATE_IP=<ip>
SENDER_PUBLIC_IP=<ip>
SENDER_PRIVATE_IP=<ip>

ssh azureuser@<RECEIVER_PUBLIC_IP>
```

### Quick Start

1. **SSH to receiver:**
   ```bash
   ssh azureuser@<RECEIVER_PUBLIC_IP>
   ```

2. **Start iperf3 server on receiver:**
   ```bash
   iperf3 -s -p 5201
   ```

3. **From your local machine, SSH to sender:**
   ```bash
   ssh azureuser@<SENDER_PUBLIC_IP>
   ```

4. **Run a single test:**
   ```bash
   iperf3 -c <RECEIVER_PRIVATE_IP> -p 5201 -P 8 -l 128K -t 30 --json
   ```

5. **Or run the full sweep:**
   ```bash
   cd /home/itiagrawal/Projects/iperf3-test
   ./scripts/run_sweep.sh --server-ip <RECEIVER_PRIVATE_IP> \
     --scenario scenarios/tcp_sweep.csv
   ```

## Cleanup

To delete the entire cluster and resource group:

```bash
RESOURCE_GROUP=$(grep "^$RESOURCE_PREFIX-rg" ~/.azure/deployment.txt 2>/dev/null || echo "iperf3-rg")
az group delete --name "$RESOURCE_GROUP" --yes
```

Or via Azure portal: Search for resource group and delete.

## Cost

- **2× Standard_D64s_v3**: ~$6–7/hour each (on-demand, shared core billing)
- **2× Public IPs**: Free (under limit)
- **Storage**: ~50 GB total (negligible)
- **Estimate**: ~$12–14/hour for both VMs

## Troubleshooting

### Deployment Fails
- Check subscription quota: `az vm list-usage -l westus2 --query "[?contains(name.localizedValue, 'Dv3')]"`
- Check authentication: `az account show`

### SSH Connection Refused
- Allow 1–2 minutes for cloud-init to complete
- Check NSG: `az network nsg rule list --resource-group iperf3-rg --nsg-name iperf3-nsg -o table`

### iperf3 Not Found
- SSH and run: `sudo apt-get update && sudo apt-get install -y iperf3`

## References

- [Azure Accelerated Networking](https://learn.microsoft.com/en-us/azure/virtual-network/accelerated-networking-overview)
- [iperf3 Documentation](https://iperf.fr/)
- [Dv3 Series VMs](https://learn.microsoft.com/en-us/azure/virtual-machines/dv3-dsv3-series)
