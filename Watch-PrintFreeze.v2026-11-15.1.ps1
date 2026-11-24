<#
  Watch-PrintFreeze  v2026-11-15.1

  Run this on the PC BEFORE starting the print job that freezes, leave the window open, and let the
  job stall. Every 2 seconds it records, but only when something CHANGES:
    - the Print Spooler (running / pid change = it crashed and restarted)
    - Chek.exe (running, responding or "Not Responding")
    - each real printer's status and every job in its queue: status, pages printed / total, size
    - whether the printer's network port answers (TCP 9100 / 631 / 80), checked every 10 seconds
  When you press Ctrl+C (or the time runs out) it also saves, for the watched period only:
    - Print Service Admin + Operational events (Operational is switched ON by this script),
      spooler crashes/restarts (System 7031/7034), app crashes/hangs (Application 1000/1002)
    - the Windows Error Reporting files for any spoolsv / Chek crash or hang (these list the
      DLL that was loaded when it died)
  Everything lands in C:\ProgramData\RIT-PrintWatch\  - send that folder back.

  Usage: Run-WatchPrintFreeze.bat   (or: -File Watch-PrintFreeze.v2026-11-15.1.ps1 [-Minutes 120])
  -StopFile <path> (2026-11-15, for the Remote Diagnostics window, gui\): when that file appears the watch
  stops and saves exactly as after Ctrl+C. A window cannot send Ctrl+C to a hidden child, and killing it
  would skip the save. Without -StopFile nothing changes.
  PowerShell 5.1, pure ASCII, Windows only. Read-only apart from switching on the Operational log.
#>
[CmdletBinding()]
param(
    [int]$Minutes = 120,
    [int]$IntervalSec = 2,
    [string]$AppName = 'Chek',
    [string]$SkipPrinters = 'PDF|XPS|OneNote|Fax|PaperPort|Snagit',
    [string]$StopFile = ''
)

$ScriptVersion = '2026-11-15.1'
$ErrorActionPreference = 'Continue'

# --- self-elevate -----------------------------------------------------------------------------
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$isAdmin = (New-Object Security.Principal.WindowsPrincipal $identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    $relaunch = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $PSCommandPath),
        '-Minutes', $Minutes, '-IntervalSec', $IntervalSec, '-AppName', ('"{0}"' -f $AppName))
    if ($StopFile) { $relaunch += @('-StopFile', ('"{0}"' -f $StopFile)) }
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $relaunch
    exit
}

$outDir = Join-Path $env:ProgramData 'RIT-PrintWatch'
if (-not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
$stamp = Get-Date -Format 'yyyy-MM-dd_HHmmss'
$logFile = Join-Path $outDir ('printwatch-{0}.log' -f $stamp)
$startTime = Get-Date

function Write-Log {
    param([string]$Text)
    $line = '{0} {1}' -f (Get-Date -Format 'HH:mm:ss'), $Text
    Write-Host $line
    Add-Content -LiteralPath $logFile -Value $line -Encoding UTF8
}

$last = @{}
function Note-Change {
    param([string]$Key, [string]$Value)
    if ($last[$Key] -ne $Value) {
        $last[$Key] = $Value
        Write-Log ('{0}: {1}' -f $Key, $Value)
    }
}

function Test-Tcp {
    param([string]$HostName, [int]$Port)
    $client = $null
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $iar = $client.BeginConnect($HostName, $Port, $null, $null)
        $ok = $iar.AsyncWaitHandle.WaitOne(1000, $false) -and $client.Connected
        return [bool]$ok
    } catch { return $false }
    finally { if ($client) { $client.Close() } }
}

& wevtutil.exe sl 'Microsoft-Windows-PrintService/Operational' /e:true | Out-Null

Write-Log ('Watch-PrintFreeze v{0} on {1}. Watching for {2} min. Start the print job now. Ctrl+C to stop and save.' -f $ScriptVersion, $env:COMPUTERNAME, $Minutes)
Write-Log ('Tip: when it stalls, note the clock time, and (if the app shows Not Responding) Task Manager > right-click {0} > Create dump file.' -f $AppName)

$seenJobs = @{}
$tick = 0
try {
    $end = $startTime.AddMinutes($Minutes)
    while ((Get-Date) -lt $end) {
        if ($StopFile -and (Test-Path -LiteralPath $StopFile)) { Write-Log 'Stop requested (stop file).'; break }
        $sp = Get-Process -Name spoolsv -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($sp) { Note-Change 'spooler' ('running, pid {0}' -f $sp.Id) } else { Note-Change 'spooler' 'NOT RUNNING' }

        $app = Get-Process -Name $AppName -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($app) { Note-Change $AppName ('running, responding={0}' -f $app.Responding) } else { Note-Change $AppName 'not running' }

        $nowJobs = @{}
        $printers = @(Get-Printer -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch $SkipPrinters })
        foreach ($p in $printers) {
            Note-Change ('printer [{0}]' -f $p.Name) ([string]$p.PrinterStatus)
            foreach ($j in @(Get-PrintJob -PrinterName $p.Name -ErrorAction SilentlyContinue)) {
                $key = '{0} job {1} "{2}"' -f $p.Name, $j.Id, $j.DocumentName
                $nowJobs[$key] = $true
                $seenJobs[$key] = $true
                Note-Change $key ('{0}  pages {1}/{2}  {3} bytes' -f $j.JobStatus, $j.PagesPrinted, $j.TotalPages, $j.Size)
            }
            if ($tick % 5 -eq 0) {
                $port = Get-PrinterPort -Name $p.PortName -ErrorAction SilentlyContinue
                if ($port -and $port.PrinterHostAddress) {
                    $h = $port.PrinterHostAddress
                    $reach = @()
                    foreach ($pt in 9100, 631, 80) { if (Test-Tcp $h $pt) { $reach += $pt } }
                    Note-Change ('network {0} ({1})' -f $p.Name, $h) ('answering on ports: ' + $(if ($reach.Count) { $reach -join ',' } else { 'NONE' }))
                }
            }
        }
        foreach ($k in @($seenJobs.Keys)) {
            if (-not $nowJobs.ContainsKey($k)) { Write-Log ('JOB LEFT QUEUE: {0}' -f $k); $seenJobs.Remove($k); $last.Remove($k) }
        }
        $tick++
        Start-Sleep -Seconds $IntervalSec
    }
}
finally {
    Write-Log 'Stopping - saving events and crash reports...'
    $since = $startTime.AddMinutes(-1)
    $evFile = Join-Path $outDir ('events-{0}.txt' -f $stamp)
    $queries = @(
        @{ LogName = 'Microsoft-Windows-PrintService/Admin' },
        @{ LogName = 'Microsoft-Windows-PrintService/Operational' },
        @{ LogName = 'System'; ProviderName = 'Service Control Manager'; Id = 7031, 7034 },
        @{ LogName = 'Application'; Id = 1000, 1002 }
    )
    foreach ($q in $queries) {
        $q['StartTime'] = $since
        Add-Content -LiteralPath $evFile -Value ('=== {0} ===' -f $q['LogName']) -Encoding UTF8
        $events = @(Get-WinEvent -FilterHashtable $q -ErrorAction SilentlyContinue | Sort-Object TimeCreated)
        if ($events.Count -eq 0) { Add-Content -LiteralPath $evFile -Value '(none)' -Encoding UTF8 }
        foreach ($e in $events) {
            $msg = ($e.Message -replace '\s+', ' ')
            Add-Content -LiteralPath $evFile -Value ('{0} [{1}] Id {2} {3}: {4}' -f $e.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss'), $e.LevelDisplayName, $e.Id, $e.ProviderName, $msg) -Encoding UTF8
        }
    }
    $werRoots = @((Join-Path $env:ProgramData 'Microsoft\Windows\WER\ReportQueue'), (Join-Path $env:ProgramData 'Microsoft\Windows\WER\ReportArchive'))
    foreach ($root in $werRoots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        $dirs = Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -ge $since -and $_.Name -match ('spoolsv|{0}' -f $AppName) }
        foreach ($d in $dirs) {
            $dest = Join-Path $outDir ('wer-{0}' -f $d.Name)
            New-Item -ItemType Directory -Path $dest -Force | Out-Null
            Get-ChildItem -LiteralPath $d.FullName -File -ErrorAction SilentlyContinue | Where-Object { $_.Length -lt 50MB } |
                Copy-Item -Destination $dest -Force -ErrorAction SilentlyContinue
            Write-Log ('saved crash report: {0}' -f $d.Name)
        }
    }
    Write-Log ('Done. Send the whole folder: {0}' -f $outDir)
}
