#Requires -RunAsAdministrator
<#
  Run this ON the target machine, in an elevated PowerShell window,
  to undo everything enable-remote-diag.ps1 turned on.
  (Also runs automatically 48h after enable, via a scheduled task.)
#>

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

# If running from the self-contained copy, clean up the ProgramData staging folder
if ($PSCommandPath -like "$env:ProgramData\RemoteDiag\*") {
    Start-Sleep -Seconds 1
    Remove-Item -Path "$env:ProgramData\RemoteDiag" -Recurse -Force -ErrorAction SilentlyContinue
}
