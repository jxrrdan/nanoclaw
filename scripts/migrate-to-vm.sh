#!/bin/bash
set -euo pipefail

# Migrate from AKS to cheap Linux VM on Azure
# Deletes the AKS resource group and creates a new Standard_B1s VM

echo "╔════════════════════════════════════════════════════════════════╗"
echo "║  NanoClaw: AKS → VM Migration Script                          ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""

# Configuration
OLD_RG="nanoclaw-rg"
NEW_RG="nanoclaw-rg"
LOCATION="uksouth"
VM_NAME="nanoclaw-vm"
VM_SKU="Standard_B1s"
IMAGE="UbuntuLTS"
NSG_NAME="nanoclaw-nsg"
VNET_NAME="nanoclaw-vnet"
SUBNET_NAME="default"
NIC_NAME="nanoclaw-nic"
PIP_NAME="nanoclaw-pip"

echo "Configuration:"
echo "  Old resource group: $OLD_RG"
echo "  New resource group: $NEW_RG"
echo "  Location: $LOCATION"
echo "  VM SKU: $VM_SKU (approx £5/month)"
echo "  Disk: 20GB"
echo "  OS: Ubuntu 22.04 LTS"
echo ""

# === DELETION ===
echo "⚠️  DELETION PHASE"
echo "This will permanently delete:"
echo "  - Resource group: $OLD_RG"
echo "  - AKS cluster and all resources"
echo "  - All data in the cluster"
echo ""
read -p "Type 'yes' to confirm deletion: " confirm
if [[ "$confirm" != "yes" ]]; then
  echo "Aborted."
  exit 0
fi

echo ""
echo "Deleting resource group '$OLD_RG'..."
az group delete --name "$OLD_RG" --yes --no-wait
echo "Deletion initiated (runs in background)."
echo ""
echo "Waiting for deletion to complete (this takes 5-10 minutes)..."
az group wait --deleted --name "$OLD_RG" 2>/dev/null || true
echo "✅ Resource group deleted."
echo ""

# === CREATION ===
echo "🔨 CREATION PHASE"
echo "Creating new resource group and VM..."
echo ""

# Create resource group
echo "Creating resource group: $NEW_RG"
az group create --name "$NEW_RG" --location "$LOCATION" > /dev/null
echo "✅ Resource group created"

# Create virtual network
echo "Creating virtual network: $VNET_NAME"
az network vnet create \
  --resource-group "$NEW_RG" \
  --name "$VNET_NAME" \
  --address-prefix 10.0.0.0/16 \
  --subnet-name "$SUBNET_NAME" \
  --subnet-prefix 10.0.0.0/24 > /dev/null
echo "✅ Virtual network created"

# Create network security group
echo "Creating network security group: $NSG_NAME"
az network nsg create \
  --resource-group "$NEW_RG" \
  --name "$NSG_NAME" > /dev/null
# Allow SSH
az network nsg rule create \
  --resource-group "$NEW_RG" \
  --nsg-name "$NSG_NAME" \
  --name AllowSSH \
  --priority 1000 \
  --source-address-prefixes '*' \
  --source-port-ranges '*' \
  --destination-address-prefixes '*' \
  --destination-port-ranges 22 \
  --access Allow \
  --protocol Tcp > /dev/null
echo "✅ Network security group created (SSH enabled)"

# Create public IP
echo "Creating public IP: $PIP_NAME"
az network public-ip create \
  --resource-group "$NEW_RG" \
  --name "$PIP_NAME" \
  --sku Standard \
  --allocation-method Static > /dev/null
echo "✅ Public IP created"

# Get public IP address
PUBLIC_IP=$(az network public-ip show \
  --resource-group "$NEW_RG" \
  --name "$PIP_NAME" \
  --query ipAddress \
  --output tsv)
echo "   IP: $PUBLIC_IP"

# Create network interface
echo "Creating network interface: $NIC_NAME"
az network nic create \
  --resource-group "$NEW_RG" \
  --name "$NIC_NAME" \
  --vnet-name "$VNET_NAME" \
  --subnet "$SUBNET_NAME" \
  --network-security-group "$NSG_NAME" \
  --public-ip-address "$PIP_NAME" > /dev/null
echo "✅ Network interface created"

# Create VM
echo "Creating VM: $VM_NAME (this takes 2-3 minutes)"
az vm create \
  --resource-group "$NEW_RG" \
  --name "$VM_NAME" \
  --nics "$NIC_NAME" \
  --size "$VM_SKU" \
  --image "$IMAGE" \
  --admin-username azureuser \
  --generate-ssh-keys \
  --os-disk-size-gb 20 \
  --os-disk-name "${VM_NAME}-osdisk" \
  --output none
echo "✅ VM created"

# Assign system-managed identity
echo "Assigning system-managed identity to VM"
az vm identity assign \
  --resource-group "$NEW_RG" \
  --name "$VM_NAME" > /dev/null
echo "✅ Managed identity assigned"

# Wait for VM to be ready
echo "Waiting for VM to be SSH-ready..."
sleep 10
for i in {1..30}; do
  if timeout 2 bash -c "echo > /dev/tcp/$PUBLIC_IP/22" 2>/dev/null; then
    echo "✅ VM is SSH-ready"
    break
  fi
  echo "  Attempt $i/30..."
  sleep 5
done

echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║  ✅ Migration Complete!                                       ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""
echo "New VM Details:"
echo "  Resource Group: $NEW_RG"
echo "  VM Name: $VM_NAME"
echo "  SKU: $VM_SKU (approx £5/month)"
echo "  Disk: 20GB"
echo "  Public IP: $PUBLIC_IP"
echo "  SSH User: azureuser"
echo "  Location: $LOCATION"
echo ""
echo "Next steps:"
echo ""
echo "1. Update the Ansible inventory:"
echo "   cd nanoclaw"
echo "   cp ansible/inventory.example.ini ansible/inventory.ini"
echo "   # Edit inventory.ini and replace YOUR_VM_IP with: $PUBLIC_IP"
echo ""
echo "2. Run the Ansible playbook:"
echo "   ansible-playbook -i ansible/inventory.ini ansible/playbook.yml"
echo ""
echo "3. Store secrets in Key Vault:"
echo "   az keyvault secret set --vault-name nanoclaw-kv \\"
echo "     --name CLAUDE-CODE-OAUTH-TOKEN --value \"<token>\""
echo "   az keyvault secret set --vault-name nanoclaw-kv \\"
echo "     --name ANTHROPIC-API-KEY --value \"sk-ant-...\""
echo ""
echo "4. SSH into the VM to verify:"
echo "   ssh azureuser@$PUBLIC_IP"
echo "   sudo journalctl -u nanoclaw -f"
echo ""
