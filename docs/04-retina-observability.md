# Test 04: Retina Observability Setup

## Purpose

Install [Retina](https://github.com/microsoft/retina) on the benchmark AKS cluster
to provide per-packet, per-flow network observability during iperf3 tests. This allows
correlating iperf3 retransmit events with kernel-level drop reasons, packet forwarding
counters, and TCP flow data.

## Installation

### Version

**v1.2.2** (stable Linux release)

> Note: The GitHub API `/releases/latest` endpoint returned a Windows RC
> (`v0.0.33-windows-rc.3`) which caused `ErrImagePull`. The correct stable release
> was fetched by filtering pre-releases and Windows tags from the releases list.

### Helm install command

```bash
VERSION=v1.2.2

helm upgrade --install retina oci://ghcr.io/microsoft/retina/charts/retina \
    --version $VERSION \
    --namespace kube-system \
    --set image.tag=$VERSION \
    --set operator.tag=$VERSION \
    --set logLevel=info \
    --set operator.enabled=true \
    --set enabledPlugin_linux="\[dropreason\,packetforward\,linuxutil\,dns\,packetparser\]"
```

### Plugins enabled

| Plugin | What it captures |
|--------|-----------------|
| `dropreason` | Kernel drop reason (iptables, conntrack, queue full, etc.) |
| `packetforward` | Total forwarded packet/byte counts per direction |
| `linuxutil` | `/proc/net` stats: retransmits, errors, drops, socket buffers |
| `dns` | DNS query and response telemetry |
| `packetparser` | Per-packet: TCP flags, flow direction, inter-packet latency |

### DaemonSet status after install

```
NAME                 READY   STATUS    RESTARTS   AGE    NODE
retina-agent-h2sz2   1/1     Running   0          ~1m    vmss000000 (receiver)
retina-agent-97k52   1/1     Running   0          ~1m    vmss000001 (sender)
```

Both agents are `Running` with `1/1` containers ready.

## Using Retina During Tests

### Query drop reasons on receiver during iperf3

```bash
# Port-forward the Retina metrics endpoint from the receiver agent
kubectl port-forward -n kube-system \
  $(kubectl get pod -n kube-system -l app.kubernetes.io/name=retina \
    --field-selector spec.nodeName=aks-sysd64-25644950-vmss000000 -o name) \
  9090:9090 &

# Scrape metrics
curl -s http://localhost:9090/metrics | grep -E 'drop|retransmit|forward'
```

### Watch packetparser flow data

```bash
kubectl logs -n kube-system \
  $(kubectl get pod -n kube-system -l app.kubernetes.io/name=retina \
    --field-selector spec.nodeName=aks-sysd64-25644950-vmss000000 -o name) \
  --follow | grep -i "tcp\|retransmit\|drop"
```

### Key metrics to watch during iperf3 tests

| Metric | Meaning |
|--------|---------|
| `networkobservability_drop_count` | Packets dropped in kernel, broken down by reason |
| `networkobservability_forward_count` | Packets forwarded through the NIC |
| `networkobservability_tcp_retransmit_count` | TCP retransmit events seen in kernel |
| `networkobservability_dns_request_total` | DNS traffic (should be near zero during iperf3) |

## Upgrade / Reinstall

```bash
# Get latest stable Linux version
VERSION=$(curl -sL "https://api.github.com/repos/microsoft/retina/releases" | \
  jq -r '[.[] | select(.prerelease==false and (.tag_name | test("windows") | not)) | .tag_name] | first')

helm upgrade retina oci://ghcr.io/microsoft/retina/charts/retina \
    --version $VERSION --namespace kube-system \
    --reuse-values \
    --set image.tag=$VERSION \
    --set operator.tag=$VERSION
```

## Uninstall

```bash
helm uninstall retina -n kube-system
```
