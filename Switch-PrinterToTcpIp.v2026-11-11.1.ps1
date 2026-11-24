<#
  Switch-PrinterToTcpIp  v2026-11-11.1

  Moves ONE print queue from a WSD network port (which stalls and errors) to a Standard TCP/IP
  port (raw 9100, SNMP status off) pointing at the printer's IP address. The queue keeps its NAME,
  so programs that print to it by name (Chek) need no change. Then restarts the Print Spooler and
  clears stuck spool files (this also clears jobs stuck on a PendingDeletion queue).
  Built for a client PC (2026-11-11): "Brother MFC-L6900DW series Printer (Copy 1)" on port
  WSD-9adcc79e-..., the 3rd job of a run went to Error and Chek froze waiting on it.

  Also LISTS other queues that are Offline or PendingDeletion. They are removed only with
  -RemoveStale, and then only after you answer y to each one by name. Unused WSD-* ports are removed
  the same way, after one y/N.

  Usage (Run-SwitchPrinterToTcpIp.bat, or):
    powershell -ExecutionPolicy Bypass -File Switch-PrinterToTcpIp.v2026-11-11.1.ps1 -IpAddress 192.168.0.xxx [-DryRun]
    ... [-QueueName "other queue"] [-RemoveStale] [-TestPage]
  Don't want to keep the "(Copy 1)" queue name? Add -NewName "Brother MFC-L6900DW": a fresh queue with
  that name (same driver) is created on the new port, and you are asked y/N before the old one is removed.
  Then make the new queue the default printer / select it in Chek.

  Get the printer's IP from its own screen or a printed network configuration page, and give it a
  fixed/reserved address in the router, or the port will point at the wrong place after a lease change.
  Undo: the log records the old port name; Set-Printer -Name "<queue>" -PortName "<old port>"
  (the old WSD port is only deleted if you use -RemoveStale and it is unused).
  Log: C:\ProgramData\RIT-PrinterCleanup\   PowerShell 5.1, pure ASCII, Windows only.
#>
[CmdletBinding()]
param(
    [string]$QueueName = 'Brother MFC-L6900DW series Printer (Copy 1)',
    [string]$IpAddress,
    [string]$NewName,
    [switch]$RemoveStale,
    [switch]$TestPage,
    [switch]$DryRun
)

$ScriptVersion = '2026-11-11.1'
$ErrorActionPreference = 'Stop'

# --- self-elevate -----------------------------------------------------------------------------
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$isAdmin = (New-Object Security.Principal.WindowsPrincipal $identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    $relaunch = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $PSCommandPath), '-QueueName', ('"{0}"' -f $QueueName))
    if ($IpAddress) { $relaunch += @('-IpAddress', ('"{0}"' -f $IpAddress)) }
    if ($NewName) { $relaunch += @('-NewName', ('"{0}"' -f $NewName)) }
    if ($RemoveStale) { $relaunch += '-RemoveStale' }
    if ($TestPage) { $relaunch += '-TestPage' }
    if ($DryRun) { $relaunch += '-DryRun' }
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $relaunch
    exit
}

# --- log --------------------------------------------------------------------------------------
$logDir = Join-Path $env:ProgramData 'RIT-PrinterCleanup'
if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$logFile = Join-Path $logDir ('tcpip-switch-{0}.log' -f (Get-Date -Format 'yyyy-MM-dd_HHmmss'))

function Write-Log {
    param([string]$Text, [string]$Color = 'Gray')
    Write-Host $Text -ForegroundColor $Color
    Add-Content -LiteralPath $logFile -Value $Text -Encoding UTF8
}

function Test-Tcp {
    param([string]$HostName, [int]$Port)
    $client = $null
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $iar = $client.BeginConnect($HostName, $Port, $null, $null)
        return [bool]($iar.AsyncWaitHandle.WaitOne(2000, $false) -and $client.Connected)
    } catch { return $false }
    finally { if ($client) { $client.Close() } }
}

Write-Log ('Switch-PrinterToTcpIp v{0}  {1}  {2}' -f $ScriptVersion, $env:COMPUTERNAME, (Get-Date -Format 'yyyy-MM-dd HH:mm')) 'Cyan'
if ($DryRun) { Write-Log 'DRY RUN - nothing will be changed.' 'Yellow' }

# --- the queue --------------------------------------------------------------------------------
$queue = Get-Printer -Name $QueueName -ErrorAction SilentlyContinue
if (-not $queue) {
    Write-Log ('Queue "{0}" not found. Queues on this PC:' -f $QueueName) 'Red'
    foreach ($p in Get-Printer) { Write-Log ('  {0}   [port {1}]' -f $p.Name, $p.PortName) }
    exit 1
}
$oldPort = $queue.PortName
Write-Log ('Queue : {0}' -f $queue.Name) 'White'
Write-Log ('Driver: {0}' -f $queue.DriverName)
Write-Log ('Port  : {0}   (status {1})' -f $oldPort, $queue.PrinterStatus)

# --- the IP -----------------------------------------------------------------------------------
if (-not $IpAddress) {
    Write-Host 'Printer IP address (from its screen or a printed network page): ' -ForegroundColor Yellow -NoNewline
    $IpAddress = (Read-Host).Trim()
}
$parsed = $null
if (($IpAddress -notmatch '^\d{1,3}(\.\d{1,3}){3}$') -or (-not [System.Net.IPAddress]::TryParse($IpAddress, [ref]$parsed))) {
    Write-Log ('"{0}" is not a valid IPv4 address.' -f $IpAddress) 'Red'
    exit 1
}
$portName = 'IP_{0}' -f $IpAddress

$reachable = Test-Tcp $IpAddress 9100
if ($reachable) {
    Write-Log ('{0} answers on TCP 9100 (raw printing).' -f $IpAddress) 'Green'
} else {
    Write-Log ('WARNING: {0} does NOT answer on TCP 9100. Wrong IP, printer off, or raw/9100 printing disabled.' -f $IpAddress) 'Yellow'
    if (-not $DryRun) {
        Write-Host 'Switch the queue to this port anyway? (y/N): ' -ForegroundColor Yellow -NoNewline
        if ((Read-Host).Trim() -ne 'y') { Write-Log 'Cancelled - nothing changed.' 'Yellow'; exit 1 }
    }
}

Write-Log ''
if ($NewName) {
    if ($NewName -eq $queue.Name) { Write-Log '-NewName is the same as -QueueName; leave -NewName out to just repoint that queue.' 'Red'; exit 1 }
    Write-Log ('Plan: create port {0} (raw 9100, SNMP status off), restart the spooler and clear stuck jobs, then create a NEW queue "{1}" (driver "{2}") on that port. "{3}" is left alone until you say y to removing it.' -f $portName, $NewName, $queue.DriverName, $queue.Name) 'White'
} else {
    Write-Log ('Plan: create port {0} (raw 9100, SNMP status off), point "{1}" at it, restart the spooler and clear stuck jobs.' -f $portName, $queue.Name) 'White'
}
if ($DryRun) { Write-Log 'Dry run - stopping before any change.'; }

if (-not $DryRun) {
    # --- port ---------------------------------------------------------------------------------
    if (-not (Get-PrinterPort -Name $portName -ErrorAction SilentlyContinue)) {
        Add-PrinterPort -Name $portName -PrinterHostAddress $IpAddress
        Write-Log ('created port {0}' -f $portName) 'Green'
    } else {
        Write-Log ('port {0} already exists - reusing it' -f $portName)
    }
    try {
        $cim = Get-CimInstance -ClassName Win32_TCPIPPrinterPort -Filter ("Name='{0}'" -f $portName)
        if ($cim -and $cim.SNMPEnabled) { Set-CimInstance -InputObject $cim -Property @{ SNMPEnabled = $false } }
        $cim = Get-CimInstance -ClassName Win32_TCPIPPrinterPort -Filter ("Name='{0}'" -f $portName)
        Write-Log ('port settings: protocol {0}, port {1}, SNMP status enabled = {2}' -f $cim.Protocol, $cim.PortNumber, $cim.SNMPEnabled)
        if ($cim.SNMPEnabled) { Write-Log 'Could not turn SNMP off - untick "SNMP Status Enabled" in the port''s Configure Port window by hand.' 'Yellow' }
    } catch {
        Write-Log ('Could not check/set SNMP: {0}. Untick "SNMP Status Enabled" in the port''s Configure Port window by hand.' -f $_.Exception.Message) 'Yellow'
    }

    # --- repoint the queue ----------------------------------------------------------------------
    if (-not $NewName) {
        Set-Printer -Name $queue.Name -PortName $portName
        Write-Log ('queue "{0}": port {1} -> {2}' -f $queue.Name, $oldPort, $portName) 'Green'
    }

    # --- spooler reset --------------------------------------------------------------------------
    try {
        Stop-Service -Name Spooler -Force
        $spoolDir = Join-Path $env:SystemRoot 'System32\spool\PRINTERS'
        $stuck = @(Get-ChildItem -LiteralPath $spoolDir -File -ErrorAction SilentlyContinue)
        $stuck | Remove-Item -Force -ErrorAction SilentlyContinue
        Start-Service -Name Spooler
        Write-Log ('spooler restarted, {0} stuck spool file(s) cleared' -f $stuck.Count) 'Green'
    } catch {
        Write-Log ('Spooler reset problem: {0}' -f $_.Exception.Message) 'Red'
        try { Start-Service -Name Spooler } catch { }
    }
    Start-Sleep -Seconds 3

    if ($NewName) {
        if (Get-Printer -Name $NewName -ErrorAction SilentlyContinue) {
            Write-Log ('A queue named "{0}" still exists (probably stuck in PendingDeletion). Reboot and run again, or choose another -NewName. No new queue was created.' -f $NewName) 'Red'
            exit 2
        }
        Add-Printer -Name $NewName -DriverName $queue.DriverName -PortName $portName
        Write-Log ('created queue "{0}" on {1} with driver "{2}"' -f $NewName, $portName, $queue.DriverName) 'Green'
        $checkName = $NewName
    } else {
        $checkName = $queue.Name
    }
    $check = Get-Printer -Name $checkName
    if ($check.PortName -eq $portName) { Write-Log ('VERIFIED: "{0}" is now on {1} (status {2}).' -f $check.Name, $check.PortName, $check.PrinterStatus) 'Green' }
    else { Write-Log ('NOT VERIFIED: queue is on {0}, expected {1}.' -f $check.PortName, $portName) 'Red' }

    if ($NewName) {
        Write-Log ('Next for Chek: make "{0}" the default printer and, if Chek has its own printer setting, select it there.' -f $NewName) 'White'
        Write-Host ('Remove the old queue "{0}" now? (y/N): ' -f $queue.Name) -ForegroundColor Yellow -NoNewline
        if ((Read-Host).Trim() -eq 'y') {
            try { Remove-Printer -Name $queue.Name; Write-Log ('removed old queue "{0}"' -f $queue.Name) 'Green' }
            catch { Write-Log ('FAILED to remove old queue: {0}' -f $_.Exception.Message) 'Red' }
        } else { Write-Log ('kept old queue "{0}"' -f $queue.Name) }
    }
}

# --- other queues that look stale -------------------------------------------------------------
$stale = @(Get-Printer | Where-Object {
        $_.Name -ne $queue.Name -and $_.Name -ne $NewName -and $_.Name -notmatch 'PDF|XPS|OneNote|Fax' -and
        (([string]$_.PrinterStatus -eq 'Offline') -or ([string]$_.PrinterStatus -eq 'PendingDeletion')) })
Write-Log ''
Write-Log ('Other queues that are Offline or PendingDeletion ({0}):' -f $stale.Count) 'White'
foreach ($s in $stale) { Write-Log ('  {0}   [{1}]  port {2}' -f $s.Name, $s.PrinterStatus, $s.PortName) }
if ($stale.Count -gt 0 -and -not $RemoveStale) {
    Write-Log 'Not removed (add -RemoveStale to be asked about each). An Offline queue may just be a printer that is switched off today.'
}
if ($RemoveStale -and -not $DryRun) {
    foreach ($s in $stale) {
        Write-Host ('Remove queue "{0}"? (y/N): ' -f $s.Name) -ForegroundColor Yellow -NoNewline
        if ((Read-Host).Trim() -eq 'y') {
            try { Remove-Printer -Name $s.Name; Write-Log ('  removed {0}' -f $s.Name) 'Green' }
            catch { Write-Log ('  FAILED {0}: {1}' -f $s.Name, $_.Exception.Message) 'Red' }
        } else { Write-Log ('  kept {0}' -f $s.Name) }
    }
    $used = @(Get-Printer | ForEach-Object { $_.PortName })
    $orphans = @(Get-PrinterPort | Where-Object { $_.Name -like 'WSD-*' -and ($used -notcontains $_.Name) })
    Write-Log ('Unused WSD ports ({0}):' -f $orphans.Count) 'White'
    foreach ($o in $orphans) { Write-Log ('  {0}' -f $o.Name) }
    if ($orphans.Count -gt 0) {
        Write-Host 'Remove these unused WSD ports? (y/N): ' -ForegroundColor Yellow -NoNewline
        if ((Read-Host).Trim() -eq 'y') {
            foreach ($o in $orphans) {
                try { Remove-PrinterPort -Name $o.Name; Write-Log ('  removed port {0}' -f $o.Name) 'Green' }
                catch { Write-Log ('  FAILED port {0}: {1}' -f $o.Name, $_.Exception.Message) 'Red' }
            }
        }
    }
}

# --- optional test page -----------------------------------------------------------------------
if ($TestPage -and -not $DryRun) {
    try {
        $testName = $(if ($NewName) { $NewName } else { $queue.Name })
        $wp = Get-CimInstance -ClassName Win32_Printer -Filter ("Name='{0}'" -f $testName)
        Invoke-CimMethod -InputObject $wp -MethodName PrintTestPage | Out-Null
        Write-Log 'test page sent' -Color Green
    } catch { Write-Log ('Test page failed: {0}' -f $_.Exception.Message) 'Red' }
}

Write-Log ''
Write-Log ('Next: print from Chek, then run Run-WatchPrintFreeze.bat again while it prints. Old port was {0}.' -f $oldPort) 'White'
Write-Log ('Log: {0}' -f $logFile)
