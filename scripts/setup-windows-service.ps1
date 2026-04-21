# NanoClaw Windows Service Setup
# Runs NanoClaw as a Windows service via WSL2 with auto-restart on reboot and Windows Update

$ErrorActionPreference = "Stop"

$service_name = "NanoClaw"
$service_display = "NanoClaw - Personal Claude Assistant"
$wsl_user = "nanoclaw"
$wsl_home = "/home/$wsl_user"
$project_root = "$wsl_home/nanoclaw"
$nssm_path = "C:\tools\nssm"
$startup_script = "C:\nanoclaw-startup.sh"

Write-Host "========== NanoClaw Windows Service Setup ==========" -ForegroundColor Cyan
Write-Host ""

# Step 1: Disable Windows Update auto-restart
Write-Host "Step 1: Disabling Windows Update auto-restart..." -ForegroundColor Yellow
try {
    $gp_path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU"
    if (-not (Test-Path $gp_path)) {
        New-Item -Path $gp_path -Force | Out-Null
    }
    Set-ItemProperty -Path $gp_path -Name "NoAutoRebootWithLoggedOnUsers" -Value 1 -Force
    Set-ItemProperty -Path $gp_path -Name "AUOptions" -Value 2 -Force
    Write-Host "[OK] Windows Update auto-restart disabled" -ForegroundColor Green
} catch {
    Write-Host "[WARN] Could not disable Windows Update (may require admin): $_" -ForegroundColor Yellow
}

Write-Host ""

# Step 2: Create WSL user if needed
Write-Host "Step 2: Setting up WSL2 user..." -ForegroundColor Yellow
$wsl_check = wsl -u root id -u nanoclaw 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "  Creating WSL user: $wsl_user"
    wsl -u root useradd -m -s /bin/bash nanoclaw
    if ($LASTEXITCODE -eq 0) {
        Write-Host "[OK] WSL user created"
    } else {
        Write-Host "[WARN] Could not create WSL user (may already exist)"
    }
} else {
    Write-Host "[OK] WSL user already exists"
}

Write-Host ""

# Step 3: Download NSSM with retries
Write-Host "Step 3: Downloading NSSM service manager..." -ForegroundColor Yellow

# Create tools directory
if (-not (Test-Path $nssm_path)) {
    New-Item -ItemType Directory -Path $nssm_path | Out-Null
}

$nssm_version = "2.24-101-g897c7f7"
$nssm_zip = "$nssm_path\nssm.zip"
$nssm_exe = $null
$download_success = $false

# Try primary source first with retries
$primary_url = "https://nssm.cc/download/nssm-$nssm_version.zip"
for ($attempt = 1; $attempt -le 3; $attempt++) {
    try {
        Write-Host "  Attempt $attempt/3: Downloading from nssm.cc..."
        Invoke-WebRequest -Uri $primary_url -OutFile $nssm_zip -TimeoutSec 30 -ErrorAction Stop
        $download_success = $true
        Write-Host "[OK] NSSM downloaded from primary source"
        break
    } catch {
        if ($attempt -eq 3) {
            Write-Host "  Primary source unavailable, trying backup..."
        } else {
            Write-Host "  Attempt failed: $($_.Exception.Message). Retrying in 5 seconds..."
            Start-Sleep -Seconds 5
        }
    }
}

# Try backup source if primary failed
if (-not $download_success) {
    $backup_urls = @(
        "https://github.com/nssm-cc/nssm/releases/download/2.24-101-g897c7f7/nssm-2.24-101-g897c7f7.zip",
        "https://files.nssm.cc/nssm-2.24-101-g897c7f7.zip"
    )

    foreach ($url in $backup_urls) {
        try {
            Write-Host "  Trying backup source: $url"
            Invoke-WebRequest -Uri $url -OutFile $nssm_zip -TimeoutSec 30 -ErrorAction Stop
            $download_success = $true
            Write-Host "[OK] NSSM downloaded from backup source"
            break
        } catch {
            Write-Host "  Backup source failed: $($_.Exception.Message)"
        }
    }
}

if (-not $download_success) {
    Write-Host ""
    Write-Host "[FALLBACK] NSSM download failed. Will use WSL systemd instead." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Configure the systemd service in WSL:" -ForegroundColor Cyan
    Write-Host "  wsl sudo systemctl start nanoclaw"
    Write-Host "  wsl sudo systemctl enable nanoclaw"
    Write-Host ""
    Write-Host "And add to Task Scheduler to start WSL on boot:" -ForegroundColor Cyan
    Write-Host "  New-ScheduledTaskAction -Execute 'wsl' -Argument '-u root systemctl start nanoclaw'"
    exit 1
}

# Extract NSSM
Write-Host "  Extracting NSSM..."
Expand-Archive -Path $nssm_zip -DestinationPath $nssm_path -Force

# Find nssm.exe (may be in a subdirectory)
$nssm_exe = Get-ChildItem -Recurse "$nssm_path\nssm.exe" -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName

if (-not $nssm_exe) {
    Write-Host "[ERROR] NSSM executable not found after extraction" -ForegroundColor Red
    exit 1
}

Write-Host "[OK] NSSM ready at: $nssm_exe"
Write-Host ""

# Step 4: Create startup script for WSL
Write-Host "Step 4: Creating WSL startup script..." -ForegroundColor Yellow

$startup_content = @"
#!/bin/bash
# NanoClaw startup script for WSL2

cd $project_root

# Ensure Node.js is available
if ! command -v node &> /dev/null; then
    echo "ERROR: Node.js not found in WSL"
    exit 1
fi

# Start NanoClaw
npm run start >> /var/log/nanoclaw.log 2>&1
"@

Set-Content -Path $startup_script -Value $startup_content -Encoding ASCII
Write-Host "[OK] Startup script created at: $startup_script"
Write-Host ""

# Step 5: Create Windows service via NSSM
Write-Host "Step 5: Registering Windows service..." -ForegroundColor Yellow

# Check if service already exists
$service_exists = Get-Service -Name $service_name -ErrorAction SilentlyContinue
if ($service_exists) {
    Write-Host "  Service already exists, removing old service..."
    & $nssm_exe remove $service_name confirm
}

# Use the wrapper script to manage the service
$wrapper_script = Split-Path $MyInvocation.MyCommand.Path | Join-Path -ChildPath "nanoclaw-windows-service-wrapper.ps1"
if (-not (Test-Path $wrapper_script)) {
    Write-Host "[ERROR] Wrapper script not found at: $wrapper_script" -ForegroundColor Red
    Write-Host "Ensure nanoclaw-windows-service-wrapper.ps1 is in the same directory as this script." -ForegroundColor Red
    exit 1
}

# Install service with the wrapper PowerShell script
& $nssm_exe install $service_name "powershell.exe" "-NoProfile -ExecutionPolicy Bypass -File `"$wrapper_script`" -Action start"

if ($LASTEXITCODE -ne 0) {
    Write-Host "[ERROR] Failed to install service" -ForegroundColor Red
    exit 1
}

Write-Host "[OK] Service installed"

# Configure service to auto-start
& $nssm_exe set $service_name Start SERVICE_AUTO_START
Write-Host "[OK] Service set to auto-start"

# Set service to restart on failure (if it crashes)
& $nssm_exe set $service_name AppRestartDelay 5000
Write-Host "[OK] Service will auto-restart if it crashes"

# Set stop action to call the wrapper with stop parameter
& $nssm_exe set $service_name AppExit Default Exit
& $nssm_exe set $service_name AppStop "powershell.exe" "-NoProfile -ExecutionPolicy Bypass -File `"$wrapper_script`" -Action stop"
Write-Host "[OK] Service stop action configured"

Write-Host ""
Write-Host "========== Setup Complete ==========" -ForegroundColor Green
Write-Host ""
Write-Host "Service created: $service_display" -ForegroundColor Cyan
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Yellow
Write-Host ""
Write-Host "1. In WSL, ensure your NanoClaw .env file includes the authentication secrets."
Write-Host "   Edit: $project_root/.env"
Write-Host ""
Write-Host "   For local-only (no Azure Key Vault):"
Write-Host "     CLAUDE_CODE_OAUTH_TOKEN=<your token>"
Write-Host "     ANTHROPIC_API_KEY=sk-ant-..."
Write-Host ""
Write-Host "   Or configure Azure Key Vault:"
Write-Host "     AZURE_KEYVAULT_URL=https://your-vault.vault.azure.net/"
Write-Host ""
Write-Host "2. Start the service:"
Write-Host "   Start-Service -Name '$service_name'"
Write-Host ""
Write-Host "3. Check service status:"
Write-Host "   Get-Service -Name '$service_name'"
Write-Host ""
Write-Host "4. View service logs:"
Write-Host "   Get-Content 'C:\ProgramData\nanoclaw\service.log' -Tail 50 -Wait"
Write-Host ""
Write-Host "5. Stop the service:"
Write-Host "   Stop-Service -Name '$service_name'"
Write-Host ""
Write-Host "6. Remove the service (if needed):"
Write-Host "   & '$nssm_exe' remove '$service_name' confirm"
Write-Host ""
