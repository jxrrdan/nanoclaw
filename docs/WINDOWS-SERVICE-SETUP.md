# Running NanoClaw as a Windows Service

This guide walks you through setting up NanoClaw as a persistent Windows service on a Windows Server that auto-starts on boot and survives Windows Update restarts.

## Prerequisites

- Windows Server 2019 or later (or Windows 10/11 Pro)
- WSL2 (Windows Subsystem for Linux 2) installed and initialized
- Ubuntu distribution in WSL2 with Node.js 22 installed
- Administrator access to PowerShell

## Quick Start

### 1. Run the Setup Script

Open PowerShell as Administrator and run:

```powershell
cd C:\path\to\nanoclaw
.\scripts\setup-windows-service.ps1
```

This script will:
- Disable Windows Update auto-restart
- Configure WSL2 with a `nanoclaw` user
- Download and install NSSM (service manager)
- Register NanoClaw as a Windows service
- Enable auto-start on boot

### 2. Configure Credentials

Inside WSL, edit your `.env` file with the Claude Code OAuth token and Anthropic API key:

```bash
wsl
cd ~/nanoclaw
nano .env
```

Add or update these lines:

```bash
# Option A: Direct credentials (simple)
CLAUDE_CODE_OAUTH_TOKEN=<your token from ~/.claude/.credentials.json>
ANTHROPIC_API_KEY=sk-ant-...

# Option B: Azure Key Vault (recommended for security)
AZURE_KEYVAULT_URL=https://your-vault.vault.azure.net/
```

**To get your Claude Code OAuth token:**

```bash
# On any machine with claude-cli authenticated
cat ~/.claude/.credentials.json | jq '.authToken'
```

Copy this token into the WSL `.env` file.

### 3. Start the Service

```powershell
Start-Service -Name "NanoClaw"
```

Verify it's running:

```powershell
Get-Service -Name "NanoClaw"
```

Output should show `Status: Running`.

### 4. Check Logs

View the service startup log:

```powershell
Get-Content 'C:\ProgramData\nanoclaw\service.log' -Tail 50 -Wait
```

View the npm output:

```bash
wsl tail -f ~/nanoclaw/logs/messages.log
```

## How It Works

### Architecture

```
Windows
  ↓
NSSM (service manager)
  ↓
PowerShell wrapper (nanoclaw-windows-service-wrapper.ps1)
  ↓
WSL2 (Ubuntu)
  ↓
NanoClaw (Node.js process)
```

### Credential Handling

1. **Direct .env (simplest)**: Credentials stored in WSL's `.env` file
2. **Azure Key Vault**: Recommended for cloud-based security
   - Requires `AZURE_KEYVAULT_URL` in `.env`
   - NanoClaw fetches secrets at startup via Managed Identity

### Service Behavior

- **Auto-start on boot**: Service starts automatically when Windows boots
- **Auto-restart on crash**: If NanoClaw crashes, NSSM restarts it within 5 seconds
- **Windows Update handling**: Script disables auto-restart so you control timing
- **Manual restarts**: Use `Restart-Service NanoClaw` to restart anytime

## Common Tasks

### Check Service Status

```powershell
Get-Service -Name "NanoClaw"
```

### Restart the Service

```powershell
Restart-Service -Name "NanoClaw"
```

### Stop the Service

```powershell
Stop-Service -Name "NanoClaw"
```

### View Live Logs

```powershell
# Windows service wrapper logs
Get-Content 'C:\ProgramData\nanoclaw\service.log' -Tail 100 -Wait

# Or from WSL
wsl tail -f ~/nanoclaw/logs/messages.log
```

### Check Service Configuration

```powershell
$nssm_exe = "C:\tools\nssm\nssm.exe"  # Or path from setup script output
& $nssm_exe get NanoClaw
```

## Troubleshooting

### Service won't start

1. Check the wrapper log: `C:\ProgramData\nanoclaw\service.log`
2. Verify WSL2 is responsive:
   ```powershell
   wsl -e pwd
   ```
3. Check .env file permissions in WSL:
   ```bash
   wsl ls -la ~/nanoclaw/.env
   ```

### WSL seems frozen

Restart WSL:

```powershell
wsl --shutdown
wsl -e pwd  # This will auto-restart WSL
```

### NSSM download failed

The setup script tries multiple sources. If all fail:

1. Try running the setup script again later (nssm.cc may be temporarily down)
2. Manually download NSSM from [GitHub releases](https://github.com/nssm-cc/nssm/releases)
3. Extract to `C:\tools\nssm` and run the setup script again

### Service starts but NanoClaw exits immediately

1. Check .env file for syntax errors:
   ```bash
   wsl cat ~/nanoclaw/.env
   ```
2. Verify npm dependencies are installed:
   ```bash
   wsl cd ~/nanoclaw && npm ci
   ```
3. Check for missing Node.js in WSL:
   ```bash
   wsl node --version
   ```

### High CPU usage

If NanoClaw is consuming high CPU:

1. Check if container runners are spawning correctly:
   ```bash
   wsl ps aux | grep docker
   ```
2. Review NanoClaw logs for errors:
   ```bash
   wsl tail -f ~/nanoclaw/logs/messages.log
   ```

## Advanced Configuration

### Change Update Check Interval

Edit the main NanoClaw process (in WSL):

```bash
wsl nano ~/nanoclaw/.env
```

Add or modify:

```bash
SCHEDULED_MESSAGE_CHECK_INTERVAL_MS=300000  # Check every 5 minutes
```

### Use Azure Key Vault

Instead of storing credentials in `.env`, use Key Vault:

```bash
wsl
# In WSL, set the vault URL
echo "AZURE_KEYVAULT_URL=https://your-vault.vault.azure.net/" >> ~/nanoclaw/.env

# NanoClaw will fetch CLAUDE_CODE_OAUTH_TOKEN and ANTHROPIC_API_KEY from the vault
```

Requires:
- Vault created with `--enable-rbac-authorization true`
- VM/WSL service account has `Key Vault Secrets User` role
- Secrets stored with names: `CLAUDE-CODE-OAUTH-TOKEN` and `ANTHROPIC-API-KEY`

### Enable Service Logging

The wrapper script logs to `C:\ProgramData\nanoclaw\service.log`. To see more detail:

```powershell
$nssm_exe = "C:\tools\nssm\nssm.exe"
& $nssm_exe set NanoClaw AppStdout "C:\ProgramData\nanoclaw\stdout.log"
& $nssm_exe set NanoClaw AppStderr "C:\ProgramData\nanoclaw\stderr.log"
```

## Removing the Service

To remove NanoClaw as a Windows service:

```powershell
Stop-Service -Name "NanoClaw" -Force
$nssm_exe = "C:\tools\nssm\nssm.exe"
& $nssm_exe remove NanoClaw confirm
```

This does NOT delete the NanoClaw files in WSL, only removes the Windows service registration.

## Security Considerations

### Credentials in .env

The `.env` file in WSL is readable by the system. For better security:

1. **Use Azure Key Vault** (recommended)
   - Secrets managed by Azure, never stored on disk
   - Access controlled via Managed Identity and RBAC

2. **Restrict .env permissions**:
   ```bash
   wsl chmod 600 ~/nanoclaw/.env
   ```

3. **Avoid committing .env to git**:
   ```bash
   # Ensure .env is in .gitignore
   wsl echo ".env" >> ~/nanoclaw/.gitignore
   ```

### Service Account

The NSSM service runs as LocalSystem (Windows SYSTEM account), which has administrative privileges. This is necessary for:
- Spawning Docker containers
- Accessing WSL subsystem
- Network operations

If you need to restrict permissions, configure NSSM to run as a specific service account instead.

## Next Steps

1. **Verify operation**: Send a test message to see NanoClaw respond
2. **Configure channels**: Set up WhatsApp, Telegram, Slack, etc. to route messages to the local service
3. **Monitor performance**: Watch the logs during operation to ensure stable performance
4. **Plan backups**: Since this is on a local machine, consider backup strategy for the SQLite database

## Support

For issues with NanoClaw: See [README.md](../README.md) and [CONTRIBUTING.md](../CONTRIBUTING.md)

For issues with NSSM: See [NSSM documentation](https://nssm.cc/)

For WSL2 issues: See [WSL documentation](https://docs.microsoft.com/en-us/windows/wsl/)
