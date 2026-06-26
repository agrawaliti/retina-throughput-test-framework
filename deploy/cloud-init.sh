#!/bin/bash
set -euo pipefail

# Cloud-init script for iperf3/netperf benchmark nodes
# Installs required tools and prepares system for network performance testing

echo "=== Starting cloud-init for network benchmark node ==="

# Update system
apt-get update
apt-get upgrade -y

# Install essential tools
apt-get install -y \
  iperf3 \
  netperf \
  ethtool \
  numactl \
  jq \
  curl \
  wget \
  htop \
  sysstat \
  git \
  build-essential \
  linux-tools-generic \
  tcpdump \
  net-tools \
  mtr \
  bmon \
  iotop

echo "=== Installed packages ==="

# Enable sysstat
sed -i 's/ENABLED="false"/ENABLED="true"/' /etc/default/sysstat
systemctl restart sysstat

# Set up iperf3 and netperf auto-start for receiver nodes if needed
# (commented out; manual start recommended for benchmark control)
# systemctl enable iperf3

# Pre-create iperf3/netperf test directories
mkdir -p /mnt/iperf3-data/{server,client}
mkdir -p /mnt/netperf-data/{server,client}
chmod 755 /mnt/iperf3-data/{server,client} /mnt/netperf-data/{server,client}

# Tune system for network benchmarking
echo "=== Tuning system parameters ==="
sysctl -w net.core.rmem_max=134217728
sysctl -w net.core.wmem_max=134217728
sysctl -w net.ipv4.tcp_rmem="4096 87380 67108864"
sysctl -w net.ipv4.tcp_wmem="4096 65536 67108864"
sysctl -w net.core.netdev_max_backlog=5000

# Enable TCP statistics and monitoring
echo "=== Enabling TCP statistics ==="
sysctl -w net.ipv4.tcp_timestamps=1
sysctl -w net.ipv4.tcp_sack=1
sysctl -w net.ipv4.tcp_dsack=1
sysctl -w net.ipv4.tcp_fack=1

# Increase TCP retransmission visibility
sysctl -w net.ipv4.tcp_retries1=3
sysctl -w net.ipv4.tcp_retries2=15

# Disable TCP fast open for consistency (optional)
# sysctl -w net.ipv4.tcp_fastopen=0

# Save settings persistently
mkdir -p /etc/sysctl.d
cat > /etc/sysctl.d/98-benchmark.conf <<'SYSCTL_EOF'
# Network Benchmark Tuning
net.core.rmem_max=134217728
net.core.wmem_max=134217728
net.ipv4.tcp_rmem=4096 87380 67108864
net.ipv4.tcp_wmem=4096 65536 67108864
net.core.netdev_max_backlog=5000
net.ipv4.tcp_timestamps=1
net.ipv4.tcp_sack=1
net.ipv4.tcp_dsack=1
net.ipv4.tcp_fack=1
net.ipv4.tcp_retries1=3
net.ipv4.tcp_retries2=15
SYSCTL_EOF

sysctl -p /etc/sysctl.d/98-benchmark.conf

# Print system info
echo "=== System Information ==="
lscpu
echo ""
numactl --hardware
echo ""
ethtool -i eth0 2>/dev/null || true
echo ""

# Create telemetry collection helper script
echo "=== Setting up telemetry collection helpers ==="
mkdir -p /opt/benchmark
cat > /opt/benchmark/collect_stats.sh <<'STATS_EOF'
#!/bin/bash
# Real-time network statistics collector for retransmit analysis

OUTPUT_DIR="${1:-.}"
INTERVAL="${2:-1}"

mkdir -p "$OUTPUT_DIR"
STATS_FILE="$OUTPUT_DIR/netstat.csv"

# CSV header
echo "timestamp,tcp_retrans,tcp_recov,tcp_retrans_drop,tcp_segment_retrans,tcp_in_segs,tcp_out_segs,dropped_packets" > "$STATS_FILE"

echo "Collecting network statistics to $STATS_FILE (interval: ${INTERVAL}s)"
echo "Press Ctrl+C to stop"

while true; do
  TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  
  # Extract TCP retransmit counters from /proc/net/netstat
  STATS=$(cat /proc/net/netstat | awk '
    /TcpExt/ {
      if (NR == 2) {
        for (i=1; i<=NF; i++) header[i]=$i
      } else {
        for (i=1; i<=NF; i++) {
          if (header[i] == "RetransSegs") retrans = $i
          if (header[i] == "TCPLossReoorder") recov = $i
          if (header[i] == "TCPSackMerged") merged = $i
          if (header[i] == "InSegs") in_segs = $i
          if (header[i] == "OutSegs") out_segs = $i
        }
      }
    }
    /Ip/ {
      if (NR == 1) {
        for (i=1; i<=NF; i++) ip_header[i]=$i
      } else {
        for (i=1; i<=NF; i++) {
          if (ip_header[i] == "Drops") drops = $i
        }
      }
    }
    END {
      print retrans "," recov "," merged "," 0 "," in_segs "," out_segs "," drops
    }
  ')
  
  echo "$TS,$STATS" >> "$STATS_FILE"
  sleep "$INTERVAL"
done
STATS_EOF

chmod +x /opt/benchmark/collect_stats.sh

# Create iperf3 result parser script
cat > /opt/benchmark/parse_iperf_retrans.sh <<'PARSE_EOF'
#!/bin/bash
# Extract retransmits from iperf3 JSON results

JSON_FILE="$1"

if [[ ! -f "$JSON_FILE" ]]; then
  echo "Usage: $0 <iperf3_json_file>"
  exit 1
fi

echo "=== iperf3 Result Summary ==="
jq -r '
  "Throughput (Gbps): " + (.end.sum_sent.bits_per_second / 1000000000 | tostring) +
  "\nRetransmits: " + (.end.sum_sent.retransmits | tostring) +
  "\nSender CPU (%): " + (.end.sender_tcp_congestion_alg // "N/A" | tostring) +
  "\nPackets: " + (.end.sum_sent.packets | tostring) +
  "\nBytes: " + (.end.sum_sent.bytes | tostring)
' "$JSON_FILE"
PARSE_EOF

chmod +x /opt/benchmark/parse_iperf_retrans.sh

echo "=== cloud-init complete ==="
