# NanoClaw Service Wrapper for Windows
# This script is called by NSSM to start/stop NanoClaw in WSL2
# Handles WSL initialization, process management, and logging

param(
    [Parameter(Mandatory=$false)]
    [string]$Action = "start"
)

$ErrorActionPreference = "Continue"
$wsl_user = "nanoclaw"
$project_root = "/home/nanoclaw/nanoclaw"
$log_file = "C:\ProgramData\nanoclaw\service.log"

# Ensure log directory exists
$log_dir = Split-Path $log_file
if (-not (Test-Path $log_dir)) {
    New-Item -ItemType Directory -Path $log_dir -Force | Out-Null
}

function Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$timestamp - $Message" | Tee-Object -FilePath $log_file -Append
}

function Start-NanoClaw {
    Log "Starting NanoClaw service..."

    # Check if WSL is running
    $wsl_running = wsl -e test -d /home 2>$null
    if ($LASTEXITCODE -ne 0) {
        Log "ERROR: WSL2 not responsive. Attempting restart..."
        wsl --shutdown 2>$null
        Start-Sleep -Seconds 2
        Log "WSL restarted"
    }

    # Start the service in WSL (detached so this script doesn't block)
    Log "Starting npm process in WSL..."
    $proc = Start-Process -FilePath "wsl" `
        -ArgumentList "-u $wsl_user -d $project_root npm run start" `
        -NoNewWindow `
        -PassThru `
        -RedirectStandardOutput "$log_dir\nanoclaw-stdout.log" `
        -RedirectStandardError "$log_dir\nanoclaw-stderr.log"

    Log "Process started with PID: $($proc.Id)"
}

function Stop-NanoClaw {
    Log "Stopping NanoClaw service..."

    # Kill npm process in WSL
    wsl -u root pkill -f "npm run start" 2>$null || $true

    Log "Service stopped"
}

switch ($Action.ToLower()) {
    "start" {
        Start-NanoClaw
    }
    "stop" {
        Stop-NanoClaw
    }
    default {
        Log "Unknown action: $Action"
        exit 1
    }
}

Log "Action completed: $Action"
exit 0
