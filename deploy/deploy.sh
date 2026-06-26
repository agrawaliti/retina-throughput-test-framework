#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
DEPLOY_DIR="$SCRIPT_DIR"

# Configuration
SUBSCRIPTION_ID="${AZURE_SUBSCRIPTION_ID:-18153b17-4e27-4b58-863e-f8105b8892a2}"
LOCATION="${LOCATION:-westus2}"
RESOURCE_PREFIX="${RESOURCE_PREFIX:-iperf3}"
VM_SIZE="${VM_SIZE:-Standard_D64s_v3}"
ADMIN_USER="${ADMIN_USER:-azureuser}"
ENVIRONMENT="${ENVIRONMENT:-bench}"

log() {
  local level="$1"
  shift
  printf '[%s] [%s] %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$level" "$*" >&2
}

error_exit() {
  log ERROR "$@"
  exit 1
}

log INFO "=== iperf3 Cluster Deployment Script ==="
log INFO "Subscription: $SUBSCRIPTION_ID"
log INFO "Location: $LOCATION"
log INFO "Resource Prefix: $RESOURCE_PREFIX"
log INFO "VM Size: $VM_SIZE"
log INFO "Admin User: $ADMIN_USER"

# Check prerequisites
for cmd in az ssh-keygen; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    error_exit "Required command not found: $cmd"
  fi
done

# Set subscription
log INFO "Setting subscription context..."
az account set --subscription "$SUBSCRIPTION_ID"

# Check if SSH key exists, if not generate
SSH_KEY_PATH="${HOME}/.ssh/id_rsa"
SSH_PUB_PATH="${HOME}/.ssh/id_rsa.pub"
if [[ ! -f "$SSH_PUB_PATH" ]]; then
  log INFO "Generating SSH keypair..."
  ssh-keygen -t rsa -b 4096 -f "$SSH_KEY_PATH" -N "" -C "iperf3-bench@$(hostname)"
else
  log INFO "Using existing SSH key: $SSH_PUB_PATH"
fi

# Read SSH public key
SSH_PUB_KEY=$(cat "$SSH_PUB_PATH")

# Validate template file exists
if [[ ! -f "$DEPLOY_DIR/main.bicep" ]]; then
  error_exit "Bicep template not found: $DEPLOY_DIR/main.bicep"
fi

if [[ ! -f "$DEPLOY_DIR/cloud-init.sh" ]]; then
  error_exit "cloud-init script not found: $DEPLOY_DIR/cloud-init.sh"
fi

log INFO "Bicep template: $DEPLOY_DIR/main.bicep"
log INFO "cloud-init script: $DEPLOY_DIR/cloud-init.sh"

# Create parameters file for deployment
PARAMS_FILE="/tmp/iperf3_deploy_params.json"
log INFO "Creating parameters file: $PARAMS_FILE"
cat > "$PARAMS_FILE" <<EOF
{
  "\$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#",
  "contentVersion": "1.0.0.0",
  "parameters": {
    "location": {
      "value": "$LOCATION"
    },
    "resourcePrefix": {
      "value": "$RESOURCE_PREFIX"
    },
    "vmSize": {
      "value": "$VM_SIZE"
    },
    "adminUsername": {
      "value": "$ADMIN_USER"
    },
    "adminPublicKey": {
      "value": "$SSH_PUB_KEY"
    },
    "environment": {
      "value": "$ENVIRONMENT"
    }
  }
}
EOF

# Deploy using Bicep
DEPLOYMENT_NAME="${RESOURCE_PREFIX}-deploy-$(date -u +%Y%m%dT%H%M%SZ)"
RG_NAME="${RESOURCE_PREFIX}-rg"

log INFO "Creating resource group: $RG_NAME"
az group create \
  --name "$RG_NAME" \
  --location "$LOCATION" \
  --tags purpose=iperf3-benchmark environment="$ENVIRONMENT" \
  -o none

log INFO "Starting deployment: $DEPLOYMENT_NAME"

az deployment group create \
  --name "$DEPLOYMENT_NAME" \
  --resource-group "$RG_NAME" \
  --template-file "$DEPLOY_DIR/main.bicep" \
  --parameters "@$PARAMS_FILE" \
  --query 'properties.outputs' \
  -o json | tee "/tmp/iperf3_deploy_outputs.json"

log INFO "Deployment created, waiting for completion..."

# Monitor deployment
DEPLOYMENT_STATE=$(az deployment group show \
  --name "$DEPLOYMENT_NAME" \
  --resource-group "$RG_NAME" \
  --query 'properties.provisioningState' \
  -o tsv)

while [[ "$DEPLOYMENT_STATE" == "Running" ]]; do
  sleep 15
  DEPLOYMENT_STATE=$(az deployment group show \
    --name "$DEPLOYMENT_NAME" \
    --resource-group "$RG_NAME" \
    --query 'properties.provisioningState' \
    -o tsv)
  log INFO "Deployment state: $DEPLOYMENT_STATE"
done

if [[ "$DEPLOYMENT_STATE" != "Succeeded" ]]; then
  error_exit "Deployment failed with state: $DEPLOYMENT_STATE"
fi

log INFO "Deployment succeeded!"

# Extract outputs
OUTPUTS=$(cat "/tmp/iperf3_deploy_outputs.json")
RECEIVER_VM=$(echo "$OUTPUTS" | jq -r '.receiverVMName.value')
SENDER_VM=$(echo "$OUTPUTS" | jq -r '.senderVMName.value')
RECEIVER_PIP=$(echo "$OUTPUTS" | jq -r '.receiverPublicIP.value')
SENDER_PIP=$(echo "$OUTPUTS" | jq -r '.senderPublicIP.value')
RECEIVER_PRIV=$(echo "$OUTPUTS" | jq -r '.receiverPrivateIP.value')
SENDER_PRIV=$(echo "$OUTPUTS" | jq -r '.senderPrivateIP.value')

log INFO "Deployment complete!"
log INFO ""
log INFO "=== Cluster Information ==="
log INFO "Resource Group: $RG_NAME"
log INFO ""
log INFO "Receiver Node (vmss000000)"
log INFO "  Hostname: $RECEIVER_VM"
log INFO "  Public IP: $RECEIVER_PIP"
log INFO "  Private IP: $RECEIVER_PRIV"
log INFO "  SSH: ssh $ADMIN_USER@$RECEIVER_PIP"
log INFO ""
log INFO "Sender Node (vmss000001)"
log INFO "  Hostname: $SENDER_VM"
log INFO "  Public IP: $SENDER_PIP"
log INFO "  Private IP: $SENDER_PRIV"
log INFO "  SSH: ssh $ADMIN_USER@$SENDER_PIP"
log INFO ""

# Save connection info
CONNFILE="$PROJECT_ROOT/CLUSTER_INFO.txt"
cat > "$CONNFILE" <<EOF
# iperf3 Benchmark Cluster
# Deployed: $(date -u)

## Resource Group
$RG_NAME

## Receiver Node (iperf3 server)
RECEIVER_HOST=$RECEIVER_VM
RECEIVER_PUBLIC_IP=$RECEIVER_PIP
RECEIVER_PRIVATE_IP=$RECEIVER_PRIV

## Sender Node (iperf3 client)
SENDER_HOST=$SENDER_VM
SENDER_PUBLIC_IP=$SENDER_PIP
SENDER_PRIVATE_IP=$SENDER_PRIV

## Quick Connection Commands
# SSH to receiver (via public IP)
ssh $ADMIN_USER@$RECEIVER_PIP

# SSH to sender (via public IP)
ssh $ADMIN_USER@$SENDER_PIP

# Start iperf3 server on receiver
ssh $ADMIN_USER@$RECEIVER_PIP "iperf3 -s -p 5201"

# Run single test from sender to receiver (via private IP)
ssh $ADMIN_USER@$SENDER_PIP "iperf3 -c $RECEIVER_PRIV -p 5201 -P 8 -l 128K -t 30 --json"
EOF

log INFO "Cluster information saved to: $CONNFILE"
cat "$CONNFILE" | tee >> /dev/stderr

log INFO ""
log INFO "Next steps:"
log INFO "1. SSH to receiver: ssh $ADMIN_USER@$RECEIVER_PIP"
log INFO "2. Start iperf3 server: iperf3 -s -p 5201"
log INFO "3. SSH to sender: ssh $ADMIN_USER@$SENDER_PIP"
log INFO "4. Run iperf3 tests from scenarios/tcp_sweep.csv"
log INFO "   e.g., ./scripts/run_sweep.sh --server-ip $RECEIVER_PRIV --scenario scenarios/tcp_sweep.csv"
log INFO ""
log INFO "Full connectivity info in: $CONNFILE"
