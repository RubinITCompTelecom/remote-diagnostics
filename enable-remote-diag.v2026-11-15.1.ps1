<#
  Run this ON the target machine, in an elevated PowerShell window.
  Enables remote Event Log + PowerShell remoting access for diagnostics,
  and schedules an automatic revert 48 hours from now in case anyone forgets.

  Manual early revert: run revert-remote-diag.ps1 (or just re-run this
  folder's copy at $env:ProgramData\RemoteDiag\revert-remote-diag.ps1).

  This window always stays open until you press Enter, whether it succeeds,
  fails, or errors out - so you can always see what happened.

  v2026-11-15.1 (for the Remote Diagnostics window, gui\ - additive, interactive runs unchanged):
  when stdin is redirected (the window) the "Press Enter to close" waits are skipped.
#>

# --- Log everything shown in this window to a file, so if something fails
#     you can send the file over instead of copying text off the screen.
#     Uses the Public desktop, not $env:USERPROFILE\Desktop - this is almost
#     always run elevated via a separate admin credential from whoever is
#     actually logged in, and $env:USERPROFILE would resolve to that admin's
#     own profile instead of anywhere the logged-in user could find it. ---
$logPath = "$env:PUBLIC\Desktop\enable-remote-diag_$(Get-Date -Format 'yyyy-MM-dd_HHmmss').log"
try { Start-Transcript -Path $logPath -Force | Out-Null } catch {}

# --- Elevation check (done manually instead of #Requires, so we control the
#     message and can still pause before closing if it's not elevated) ---
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "ERROR: This script must be run as Administrator." -ForegroundColor Red
    Write-Host "Right-click the file > 'Run with PowerShell' from an elevated prompt," -ForegroundColor Red
    Write-Host "or open PowerShell as Administrator first, then run this script." -ForegroundColor Red
    try { Stop-Transcript | Out-Null } catch {}
    Write-Host "`nLog saved to: $logPath" -ForegroundColor Cyan
    if (-not [Console]::IsInputRedirected) { Write-Host "`nPress Enter to close this window..." }
    if (-not [Console]::IsInputRedirected) { Read-Host | Out-Null }
    exit 1
}

try {
    Write-Host "=== Enabling remote diagnostic access ===" -ForegroundColor Cyan

    # 1. Enable PowerShell Remoting (WinRM) - covers Invoke-Command / Enter-PSSession
    Write-Host "`n[1/7] Enabling PS Remoting (WinRM)..."
    Enable-PSRemoting -Force -SkipNetworkProfileCheck

    # 2. Enable the built-in firewall rule group for remote Event Log reading
    Write-Host "[2/7] Enabling Remote Event Log Management firewall rules..."
    Enable-NetFirewallRule -DisplayGroup "Remote Event Log Management"

    # 3. Make sure Remote Registry service is running (used by remote eventlog RPC)
    Write-Host "[3/7] Starting Remote Registry service..."
    Set-Service -Name RemoteRegistry -StartupType Manual
    Start-Service -Name RemoteRegistry

    # 4. Workgroup-only fix: local admin accounts get UAC-filtered on remote connections
    #    unless this is set. Domain-joined machines don't need it.
    $inDomain = (Get-CimInstance Win32_ComputerSystem).PartOfDomain
    if (-not $inDomain) {
        Write-Host "[4/7] Workgroup machine detected - adjusting LocalAccountTokenFilterPolicy..."
        New-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" `
            -Name "LocalAccountTokenFilterPolicy" -Value 1 -PropertyType DWord -Force | Out-Null
    } else {
        Write-Host "[4/7] Domain-joined - skipping LocalAccountTokenFilterPolicy (not needed)."
    }

    # 5. Allow blank-password local accounts to authenticate over the network for
    #    this diagnostic session. By default Windows' LimitBlankPasswordUse policy
    #    restricts any local account with NO password to console-only logon - it
    #    refuses that account for RPC/SMB/WinRM entirely, regardless of what
    #    credential pull-remote-logs.ps1 sends. This is the actual, sole cause of
    #    "target has no password, remote pull won't connect" - not a bug in the
    #    puller script, and not fixable from the calling side. Setting this to 0
    #    is a no-op for any account that already has a real password.
    Write-Host "[5/7] Allowing blank-password local accounts to authenticate over the network..."
    New-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa" `
        -Name "LimitBlankPasswordUse" -Value 0 -PropertyType DWord -Force | Out-Null

    # 6. Stage a self-contained copy of the revert script so the scheduled task
    #    can find it regardless of where this script was originally run from.
    Write-Host "[6/7] Staging revert script to $env:ProgramData\RemoteDiag ..."
    $stageDir = "$env:ProgramData\RemoteDiag"
    New-Item -Path $stageDir -ItemType Directory -Force | Out-Null
    $revertPath = Join-Path $stageDir "revert-remote-diag.ps1"

    @'
#Requires -RunAsAdministrator
Write-Host "=== Reverting remote diagnostic access ===" -ForegroundColor Cyan

Write-Host "`n[1/6] Disabling Remote Event Log Management firewall rules..."
Disable-NetFirewallRule -DisplayGroup "Remote Event Log Management" -ErrorAction SilentlyContinue

Write-Host "[2/6] Stopping and resetting Remote Registry service to Disabled..."
Stop-Service -Name RemoteRegistry -ErrorAction SilentlyContinue
Set-Service -Name RemoteRegistry -StartupType Disabled -ErrorAction SilentlyContinue

Write-Host "[3/6] Removing LocalAccountTokenFilterPolicy (if it was set)..."
Remove-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" `
    -Name "LocalAccountTokenFilterPolicy" -ErrorAction SilentlyContinue

Write-Host "[4/6] Restoring blank-password network-logon restriction (LimitBlankPasswordUse)..."
Remove-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa" `
    -Name "LimitBlankPasswordUse" -ErrorAction SilentlyContinue

Write-Host "[5/6] Disabling PS Remoting (WinRM)..."
Disable-PSRemoting -Force -ErrorAction SilentlyContinue
Stop-Service WinRM -ErrorAction SilentlyContinue
Set-Service WinRM -StartupType Manual -ErrorAction SilentlyContinue

Write-Host "[6/6] Cleaning up the auto-revert scheduled task..."
Unregister-ScheduledTask -TaskName "RemoteDiagAutoRevert" -Confirm:$false -ErrorAction SilentlyContinue

Write-Host "`n=== Done - remote diagnostic access closed ===" -ForegroundColor Green

Start-Sleep -Seconds 1
Remove-Item -Path "$env:ProgramData\RemoteDiag" -Recurse -Force -ErrorAction SilentlyContinue
'@ | Set-Content -Path $revertPath -Encoding UTF8

    # 7. Schedule the automatic revert 48 hours from now (runs as SYSTEM so it
    #    fires even if nobody is logged in; StartWhenAvailable catches up if the
    #    machine is off/asleep right at the 48h mark).
    Write-Host "[7/7] Scheduling automatic revert for 48 hours from now..."
    Unregister-ScheduledTask -TaskName "RemoteDiagAutoRevert" -Confirm:$false -ErrorAction SilentlyContinue

    $action    = New-ScheduledTaskAction -Execute "powershell.exe" `
        -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$revertPath`""
    $trigger   = New-ScheduledTaskTrigger -Once -At (Get-Date).AddHours(48)
    $principal = New-ScheduledTaskPrincipal -UserId "NT AUTHORITY\SYSTEM" -LogonType ServiceAccount -RunLevel Highest
    $settings  = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries

    Register-ScheduledTask -TaskName "RemoteDiagAutoRevert" -Action $action -Trigger $trigger `
        -Principal $principal -Settings $settings -Description "Auto-reverts remote diagnostic access enabled by enable-remote-diag.ps1" | Out-Null

    Write-Host "`n=== Done ===" -ForegroundColor Green
    $ip = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.InterfaceAlias -notmatch 'Loopback' -and $_.IPAddress -notlike '169.*' } | Select-Object -First 1).IPAddress
    $name = $env:COMPUTERNAME
    $revertTime = (Get-Date).AddHours(48)
    $admins = Get-LocalGroupMember -Group "Administrators" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name

    Write-Host ""
    Write-Host "=========================================================" -ForegroundColor Yellow
    Write-Host " Computer name:  $name" -ForegroundColor Yellow
    Write-Host " IP address:     $ip" -ForegroundColor Yellow
    Write-Host " Auto-revert at: $revertTime" -ForegroundColor Yellow
    Write-Host " Local admin accounts (use one of these to connect):" -ForegroundColor Yellow
    if ($admins) {
        foreach ($a in $admins) { Write-Host "   - $a" -ForegroundColor Yellow }
    } else {
        Write-Host "   (couldn't enumerate - check manually with Get-LocalGroupMember Administrators)" -ForegroundColor Yellow
    }
    Write-Host "=========================================================" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "From the other machine, connect with one of the accounts above, e.g.:"
    Write-Host "  Get-WinEvent -ComputerName $ip -LogName System -MaxEvents 50 -Credential (Get-Credential)"
    Write-Host ""
    Write-Host "Blank-password accounts now work over the network too (LimitBlankPasswordUse relaxed" -ForegroundColor Yellow
    Write-Host "for this window) - if one of the accounts above has no password, just leave the" -ForegroundColor Yellow
    Write-Host "password field empty in pull-remote-logs.ps1, no need to set a temporary password." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "To revert early: run $revertPath (elevated) - this also cancels the scheduled auto-revert."
}
catch {
    Write-Host "`n=================================================" -ForegroundColor Red
    Write-Host " ERROR - something went wrong:" -ForegroundColor Red
    Write-Host " $($_.Exception.Message)" -ForegroundColor Red
    Write-Host " (at line $($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.Line.Trim()))" -ForegroundColor Red
    Write-Host "=================================================" -ForegroundColor Red
}
finally {
    try { Stop-Transcript | Out-Null } catch {}
    Write-Host "`nFull log saved to: $logPath" -ForegroundColor Cyan
    Write-Host "If anything failed, send that log file here and I'll take a look."
    if (-not [Console]::IsInputRedirected) { Write-Host "`nPress Enter to close this window..." }
    if (-not [Console]::IsInputRedirected) { Read-Host | Out-Null }
}
