# NanoClaw: AKS to VM Migration Script (PowerShell)
# Deletes the AKS resource group and creates a new Standard_B1s VM

$ErrorActionPreference = "Stop"

# Configuration
$oldRg = "nanoclaw-rg"
$newRg = "nanoclaw-rg"
$location = "uksouth"
$vmName = "nanoclaw-vm"
$vmSku = "Standard_B1s"
$image = "UbuntuLTS"
$nsgName = "nanoclaw-nsg"
$vnetName = "nanoclaw-vnet"
$subnetName = "default"
$nicName = "nanoclaw-nic"
$pipName = "nanoclaw-pip"

Write-Host ""
Write-Host "========== NanoClaw: AKS to VM Migration Script (PowerShell) ==========" -ForegroundColor Cyan
Write-Host ""

Write-Host "Configuration:" -ForegroundColor Yellow
Write-Host "  Old resource group: $oldRg"
Write-Host "  New resource group: $newRg"
Write-Host "  Location: $location"
Write-Host "  VM SKU: $vmSku (approx GBP 5/month)"
Write-Host "  Disk: 20GB"
Write-Host "  OS: Ubuntu 22.04 LTS"
Write-Host ""

# === DELETION ===
Write-Host "WARNING: DELETION PHASE" -ForegroundColor Red
Write-Host "This will permanently delete:" -ForegroundColor Red
Write-Host "  - Resource group: $oldRg" -ForegroundColor Red
Write-Host "  - AKS cluster and all resources" -ForegroundColor Red
Write-Host "  - All data in the cluster" -ForegroundColor Red
Write-Host ""

$confirm = Read-Host "Type 'yes' to confirm deletion"
if ($confirm -ne "yes") {
    Write-Host "Aborted."
    exit 0
}

Write-Host ""
Write-Host "Deleting resource group '$oldRg'..." -ForegroundColor Yellow
az group delete --name $oldRg --yes --no-wait
Write-Host "Deletion initiated (runs in background)."
Write-Host ""

Write-Host "Waiting for deletion to complete (this takes 5-10 minutes)..." -ForegroundColor Yellow
$deleted = $false
for ($i = 0; $i -lt 120; $i++) {
    $exists = az group exists --name $oldRg
    if ($exists -eq "false") {
        $deleted = $true
        break
    }
    Start-Sleep -Seconds 5
}

if ($deleted) {
    Write-Host "[OK] Resource group deleted."
} else {
    Write-Host "[INFO] Deletion still in progress (running in background). Continuing..."
}
Write-Host ""

# === CREATION ===
Write-Host "CREATION PHASE" -ForegroundColor Green
Write-Host "Creating new resource group and VM..." -ForegroundColor Green
Write-Host ""

# Create resource group
Write-Host "Creating resource group: $newRg"
az group create --name $newRg --location $location | Out-Null
Write-Host "[OK] Resource group created"

# Create virtual network
Write-Host "Creating virtual network: $vnetName"
az network vnet create `
  --resource-group $newRg `
  --name $vnetName `
  --address-prefix 10.0.0.0/16 `
  --subnet-name $subnetName `
  --subnet-prefix 10.0.0.0/24 | Out-Null
Write-Host "[OK] Virtual network created"

# Create network security group
Write-Host "Creating network security group: $nsgName"
az network nsg create `
  --resource-group $newRg `
  --name $nsgName | Out-Null

# Allow SSH
az network nsg rule create `
  --resource-group $newRg `
  --nsg-name $nsgName `
  --name AllowSSH `
  --priority 1000 `
  --source-address-prefixes '*' `
  --source-port-ranges '*' `
  --destination-address-prefixes '*' `
  --destination-port-ranges 22 `
  --access Allow `
  --protocol Tcp | Out-Null
Write-Host "[OK] Network security group created (SSH enabled)"

# Create public IP
Write-Host "Creating public IP: $pipName"
az network public-ip create `
  --resource-group $newRg `
  --name $pipName `
  --sku Standard `
  --allocation-method Static | Out-Null
Write-Host "[OK] Public IP created"

# Get public IP address
$publicIp = az network public-ip show `
  --resource-group $newRg `
  --name $pipName `
  --query ipAddress `
  --output tsv
Write-Host "   IP: $publicIp"

# Create network interface
Write-Host "Creating network interface: $nicName"
az network nic create `
  --resource-group $newRg `
  --name $nicName `
  --vnet-name $vnetName `
  --subnet $subnetName `
  --network-security-group $nsgName `
  --public-ip-address $pipName | Out-Null
Write-Host "[OK] Network interface created"

# Create VM
Write-Host "Creating VM: $vmName (this takes 2-3 minutes)"
az vm create `
  --resource-group $newRg `
  --name $vmName `
  --nics $nicName `
  --size $vmSku `
  --image $image `
  --admin-username azureuser `
  --generate-ssh-keys `
  --os-disk-size-gb 20 `
  --os-disk-name "$vmName-osdisk" `
  --output none
Write-Host "[OK] VM created"

# Assign system-managed identity
Write-Host "Assigning system-managed identity to VM"
az vm identity assign `
  --resource-group $newRg `
  --name $vmName | Out-Null
Write-Host "[OK] Managed identity assigned"

# Wait for VM to be ready
Write-Host "Waiting for VM to be SSH-ready..."
Start-Sleep -Seconds 10
$sshReady = $false
for ($i = 1; $i -le 30; $i++) {
    try {
        $tcpClient = New-Object System.Net.Sockets.TcpClient
        $connect = $tcpClient.BeginConnect($publicIp, 22, $null, $null)
        $wait = $connect.AsyncWaitHandle.WaitOne(2000, $false)
        if ($wait) {
            $tcpClient.EndConnect($connect)
            $tcpClient.Close()
            $sshReady = $true
            break
        }
    } catch {
        # Connection failed, continue
    }
    Write-Host "  Attempt $i/30..."
    Start-Sleep -Seconds 5
}

if ($sshReady) {
    Write-Host "[OK] VM is SSH-ready"
} else {
    Write-Host "[WARN] VM may still be starting up. Check manually with: ssh azureuser@$publicIp"
}

Write-Host ""
Write-Host "========== MIGRATION COMPLETE ==========" -ForegroundColor Green
Write-Host ""

Write-Host "New VM Details:" -ForegroundColor Cyan
Write-Host "  Resource Group: $newRg"
Write-Host "  VM Name: $vmName"
Write-Host "  SKU: $vmSku (approx GBP 5/month)"
Write-Host "  Disk: 20GB"
Write-Host "  Public IP: $publicIp"
Write-Host "  SSH User: azureuser"
Write-Host "  Location: $location"
Write-Host ""

Write-Host "Next steps:" -ForegroundColor Yellow
Write-Host ""
Write-Host "1. Update the Ansible inventory:"
Write-Host "   cd nanoclaw"
Write-Host "   Copy-Item ansible\inventory.example.ini ansible\inventory.ini"
Write-Host "   # Edit inventory.ini and replace YOUR_VM_IP with: $publicIp"
Write-Host ""
Write-Host "2. Run the Ansible playbook:"
Write-Host "   ansible-playbook -i ansible\inventory.ini ansible\playbook.yml"
Write-Host ""
Write-Host "3. Store secrets in Key Vault:"
Write-Host "   az keyvault secret set --vault-name nanoclaw-kv --name CLAUDE-CODE-OAUTH-TOKEN --value '<token>'"
Write-Host "   az keyvault secret set --vault-name nanoclaw-kv --name ANTHROPIC-API-KEY --value 'sk-ant-...'"
Write-Host ""
Write-Host "4. SSH into the VM to verify:"
Write-Host "   ssh azureuser@$publicIp"
Write-Host "   sudo journalctl -u nanoclaw -f"
Write-Host ""
