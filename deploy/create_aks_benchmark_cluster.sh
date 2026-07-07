#!/usr/bin/env bash
set -euo pipefail

SUBSCRIPTION_ID="${AZURE_SUBSCRIPTION_ID:-$(az account show --query id -o tsv)}"
SUBSCRIPTION_NAME="${AZURE_SUBSCRIPTION_NAME:-$(az account show --query name -o tsv)}"
LOCATION="${LOCATION:-westus2}"
RESOURCE_GROUP="${RESOURCE_GROUP:-retina-throughput-overlay-rg}"
CLUSTER_NAME="${CLUSTER_NAME:-retina-throughput-overlay}"
KUBERNETES_VERSION="${KUBERNETES_VERSION:-}"

SYSTEM_POOL_NAME="${SYSTEM_POOL_NAME:-system}"
SYSTEM_VM_SIZE="${SYSTEM_VM_SIZE:-Standard_D4ds_v5}"
SYSTEM_NODE_COUNT="${SYSTEM_NODE_COUNT:-1}"

BENCH_POOL_NAME="${BENCH_POOL_NAME:-bench32}"
BENCH_VM_SIZE="${BENCH_VM_SIZE:-Standard_D32s_v3}"
BENCH_NODE_COUNT="${BENCH_NODE_COUNT:-2}"
BENCH_NODE_OSDISK_TYPE="${BENCH_NODE_OSDISK_TYPE:-Ephemeral}"

NETWORK_PLUGIN="${NETWORK_PLUGIN:-azure}"
NETWORK_PLUGIN_MODE="${NETWORK_PLUGIN_MODE:-overlay}"
NETWORK_DATAPLANE="${NETWORK_DATAPLANE:-}"
LOAD_BALANCER_SKU="${LOAD_BALANCER_SKU:-standard}"
OS_SKU="${OS_SKU:-AzureLinux}"

ENABLE_MONITORING="${ENABLE_MONITORING:-false}"
ENABLE_AZURE_POLICY="${ENABLE_AZURE_POLICY:-true}"
ENABLE_WORKLOAD_IDENTITY="${ENABLE_WORKLOAD_IDENTITY:-true}"
ENABLE_OIDC_ISSUER="${ENABLE_OIDC_ISSUER:-true}"

TAGS=(
  purpose=retina-throughput-benchmark
  workload=reuseport-cross-core
  hardware-profile=32-core-benchmark-pool
)

log() {
  local level="$1"
  shift
  printf '[%s] [%s] %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$level" "$*"
}

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    log ERROR "Required command not found: $cmd"
    exit 1
  fi
}

bool_flag() {
  local value="$1"
  local flag="$2"
  if [[ "$value" == "true" ]]; then
    printf '%s\n' "$flag"
  fi
}

join_by_comma() {
  local IFS=,
  printf '%s' "$*"
}

for cmd in az jq; do
  require_cmd "$cmd"
done

log INFO "Subscription: $SUBSCRIPTION_NAME ($SUBSCRIPTION_ID)"
log INFO "Location: $LOCATION"
log INFO "Resource group: $RESOURCE_GROUP"
log INFO "Cluster name: $CLUSTER_NAME"
log INFO "System pool: $SYSTEM_POOL_NAME $SYSTEM_VM_SIZE x$SYSTEM_NODE_COUNT"
log INFO "Benchmark pool: $BENCH_POOL_NAME $BENCH_VM_SIZE x$BENCH_NODE_COUNT"

az account set --subscription "$SUBSCRIPTION_ID"

log INFO "Creating resource group if needed"
az group create \
  --name "$RESOURCE_GROUP" \
  --location "$LOCATION" \
  --tags "${TAGS[@]}" \
  --output none

create_args=(
  aks create
  --resource-group "$RESOURCE_GROUP"
  --name "$CLUSTER_NAME"
  --location "$LOCATION"
  --tier Standard
  --nodepool-name "$SYSTEM_POOL_NAME"
  --node-count "$SYSTEM_NODE_COUNT"
  --node-vm-size "$SYSTEM_VM_SIZE"
  --vm-set-type VirtualMachineScaleSets
  --load-balancer-sku "$LOAD_BALANCER_SKU"
  --network-plugin "$NETWORK_PLUGIN"
  --network-plugin-mode "$NETWORK_PLUGIN_MODE"
  --os-sku "$OS_SKU"
  --enable-managed-identity
  --generate-ssh-keys
  --tags "${TAGS[@]}"
)

if [[ -n "$NETWORK_DATAPLANE" ]]; then
  create_args+=(--network-dataplane "$NETWORK_DATAPLANE")
fi

if [[ -n "$KUBERNETES_VERSION" ]]; then
  create_args+=(--kubernetes-version "$KUBERNETES_VERSION")
fi

oidc_flag="$(bool_flag "$ENABLE_OIDC_ISSUER" --enable-oidc-issuer || true)"
wi_flag="$(bool_flag "$ENABLE_WORKLOAD_IDENTITY" --enable-workload-identity || true)"
addons=()
if [[ "$ENABLE_MONITORING" == "true" ]]; then
  addons+=(monitoring)
fi
if [[ "$ENABLE_AZURE_POLICY" == "true" ]]; then
  addons+=(azure-policy)
fi

for flag in "$oidc_flag" "$wi_flag"; do
  if [[ -n "$flag" ]]; then
    create_args+=("$flag")
  fi
done
if (( ${#addons[@]} > 0 )); then
  create_args+=(--enable-addons "$(join_by_comma "${addons[@]}")")
fi

log INFO "Creating AKS cluster control plane and system pool"
az "${create_args[@]}" --output table

log INFO "Adding dedicated benchmark node pool"
az aks nodepool add \
  --resource-group "$RESOURCE_GROUP" \
  --cluster-name "$CLUSTER_NAME" \
  --name "$BENCH_POOL_NAME" \
  --mode User \
  --node-count "$BENCH_NODE_COUNT" \
  --node-vm-size "$BENCH_VM_SIZE" \
  --os-sku "$OS_SKU" \
  --node-osdisk-type "$BENCH_NODE_OSDISK_TYPE" \
  --labels workload=benchmark benchmark-role=traffic perf-test-retina=enabled \
  --node-taints workload=benchmark:NoSchedule \
  --max-pods 250 \
  --output table

log INFO "Fetching kubeconfig"
az aks get-credentials \
  --resource-group "$RESOURCE_GROUP" \
  --name "$CLUSTER_NAME" \
  --overwrite-existing

log INFO "Cluster created. Summary:"
az aks show \
  --resource-group "$RESOURCE_GROUP" \
  --name "$CLUSTER_NAME" \
  --query '{name:name,location:location,kubernetesVersion:kubernetesVersion,powerState:powerState.code,nodeResourceGroup:nodeResourceGroup,networkPlugin:networkProfile.networkPlugin,networkPluginMode:networkProfile.networkPluginMode,networkDataplane:networkProfile.networkDataplane}' \
  --output json | jq .

log INFO "Node pools:"
az aks nodepool list \
  --resource-group "$RESOURCE_GROUP" \
  --cluster-name "$CLUSTER_NAME" \
  --query '[].{name:name,mode:mode,count:count,vmSize:vmSize,osSKU:osSKU,nodeTaints:nodeTaints,nodeLabels:nodeLabels}' \
  --output table

log INFO "Ready to benchmark. Next commands:"
log INFO "  kubectl config current-context"
log INFO "  kubectl get nodes -L agentpool,workload,benchmark-role"
log INFO "  ./scripts/run_reuseport_ab.sh --node-label workload=benchmark --active-cores 32"