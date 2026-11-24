<#
.SYNOPSIS
  Why do devices (Wi-Fi, Bluetooth, USB, touchpad, keyboard, camera, sound, docks...) stop
  working after a Windows PC wakes from sleep or hibernate?

.DESCRIPTION
  READ-ONLY. Changes nothing on the PC. Collects in one run:

    1. Sleep type (S3 sleep vs Modern Standby S0), hibernate / fast startup state, BIOS age.
    2. Sleep / wake history for the last -Days days (Kernel-Power 42/107/506/507,
       Power-Troubleshooter 1 with the wake source) and FAILED resumes (Kernel-Power 41 or
       EventLog 6008 right after the PC went to sleep).
    3. Wake correlation: every error/warning in the System log, Kernel-PnP/Configuration
       (device "had a problem starting") and WLAN-AutoConfig logs, grouped by source, with how
       many happened in the first -WindowMinutes minutes after a wake versus at other times.
       A source that fires mostly right after waking is the prime suspect.
    4. Devices that are in an error state RIGHT NOW (Device Manager yellow-bang codes 10/43/45...).
    5. Power-saving that switches devices off: "Allow the computer to turn off this device to
       save power" per device, network-adapter power management, USB selective suspend,
       PCI Express link-state power management, wireless adapter power saving.
    6. Driver versions/dates for the device classes that usually break on wake.
    7. powercfg /lastwake, wake-armed devices, and the Windows sleep-study HTML report.

  Optional live SLEEP TEST (-SleepTest, or answer Y to the question at the start): takes a
  snapshot of every device, you put the PC to sleep (or hibernate) and wake it, press Enter,
  and it lists exactly which devices vanished or went into an error state across that wake,
  plus every device event logged since the snapshot.

  Ends with a REVIEW LIST of what looks wrong and the usual fix for each, written at the TOP
  of the report. Fixes are suggestions for the technician to run by hand - never applied.

  Needs admin (self-elevates). PowerShell 5.1 compatible, pure ASCII. Windows only by nature
  (on WSL2, run it with powershell.exe on the Windows host).

  Output folder: WakeDeviceCheck_<PC>_<timestamp> on the Desktop of the user logged in at the
  machine (not the elevating admin's), containing WakeReport.txt, WakeEvents.csv and the
  sleep-study / power report HTML - and the same folder zipped next to it
  (WakeDeviceCheck_<PC>_<timestamp>.zip) as the one file to send back.

.PARAMETER Days            How many days of event history to read (default 14, max 60).
.PARAMETER WindowMinutes   How long after each wake counts as "after wake" (default 5).
.PARAMETER SleepTest       Run the live before/after sleep test without asking.
.PARAMETER NoPrompt        Never ask anything (for remote command windows / Splashtop command line).
.PARAMETER NoPowerReport   Skip the powercfg sleep-study HTML report.
.PARAMETER OutDir          Where to create the output folder.
#>
[CmdletBinding()]
param(
    [ValidateRange(1, 60)][int]$Days = 14,
    [ValidateRange(1, 60)][int]$WindowMinutes = 5,
    [switch]$SleepTest,
    [switch]$NoPrompt,
    [switch]$NoPowerReport,
    [string]$OutDir
)

$ScriptVersion = '2026-11-16.2'
$ErrorActionPreference = 'Continue'

# ---- elevation -------------------------------------------------------------------------
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
$isAdmin = ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host 'Not elevated - relaunching as administrator...'
    if ($PSCommandPath) {
        $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit', '-File', ('"{0}"' -f $PSCommandPath),
               '-Days', "$Days", '-WindowMinutes', "$WindowMinutes")
        if ($SleepTest) { $a += '-SleepTest' }
        if ($NoPrompt) { $a += '-NoPrompt' }
        if ($NoPowerReport) { $a += '-NoPowerReport' }
        if ($OutDir) { $a += @('-OutDir', ('"{0}"' -f $OutDir)) }
        Start-Process powershell.exe -Verb RunAs -ArgumentList $a
    }
    exit
}

# ---- output plumbing -------------------------------------------------------------------
$script:R = New-Object System.Collections.Generic.List[string]
$script:Review = New-Object System.Collections.Generic.List[string]
function W([string]$s = '') { $script:R.Add($s); Write-Host $s }
function Sec([string]$s) { W ''; W ('=' * 78); W $s; W ('=' * 78) }
function T($obj) {
    $t = ($obj | Format-Table -AutoSize -Wrap | Out-String -Width 220).TrimEnd()
    if ($t) { W $t } else { W '  (none)' }
}
function Flag([string]$s) { [void]$script:Review.Add($s) }
function Try-Events($filter, [int]$max = 20000) {
    try { return @(Get-WinEvent -FilterHashtable $filter -MaxEvents $max -ErrorAction Stop) } catch { return @() }
}
function Short([string]$s, [int]$n = 140) {
    if (-not $s) { return '' }
    $s = ($s -replace '\s+', ' ').Trim()
    if ($s.Length -gt $n) { return $s.Substring(0, $n) + '...' }
    return $s
}
function PCfg([string]$a) {
    # cmd /c so powercfg's stderr comes back as plain text (PS 5.1 wraps native stderr in error records).
    return (& cmd.exe /c "powercfg.exe $a 2>&1" | Out-String).TrimEnd()
}
function Can-Ask {
    if ($NoPrompt) { return $false }
    try { return ([Environment]::UserInteractive -and $Host.Name -eq 'ConsoleHost') } catch { return $false }
}

function Get-InteractiveUserDesktop {
    # Desktop of the person actually logged in at the machine (owner of explorer.exe), not the
    # elevating admin's. Same logic as pull-local-logs. Returns (Path, Who) or $null.
    try {
        $consoleUser = $null
        try { $consoleUser = (Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).UserName } catch {}
        $cands = @()
        foreach ($p in @(Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" -ErrorAction Stop)) {
            $o   = Invoke-CimMethod -InputObject $p -MethodName GetOwner    -ErrorAction SilentlyContinue
            $sid = Invoke-CimMethod -InputObject $p -MethodName GetOwnerSid -ErrorAction SilentlyContinue
            if ($o -and $o.User -and $sid -and $sid.Sid) {
                $cands += [pscustomobject]@{ Who = "$($o.Domain)\$($o.User)"; Sid = $sid.Sid; Session = [int]$p.SessionId }
            }
        }
        if ($cands.Count -eq 0) { return $null }
        $pick = $cands | Where-Object { $consoleUser -and $_.Who -eq $consoleUser } | Select-Object -First 1
        if (-not $pick) { $pick = $cands | Where-Object { $_.Session -ne 0 } | Select-Object -First 1 }
        if (-not $pick) { return $null }
        $prof = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$($pick.Sid)" -ErrorAction Stop).ProfileImagePath
        $prof = [Environment]::ExpandEnvironmentVariables($prof)
        $desk = $null
        try {
            $k = [Microsoft.Win32.Registry]::Users.OpenSubKey("$($pick.Sid)\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders")
            if ($k) {
                $raw = $k.GetValue('Desktop', $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                if ($raw) {
                    $raw = $raw -replace '(?i)%USERPROFILE%', $prof
                    $desk = [Environment]::ExpandEnvironmentVariables($raw)
                    if ($desk -match '%' -or -not (Test-Path -LiteralPath $desk)) { $desk = $null }
                }
                $k.Close()
            }
        } catch {}
        if (-not $desk) { $desk = Join-Path $prof 'Desktop' }
        if (-not (Test-Path -LiteralPath $desk)) { return $null }
        return [pscustomobject]@{ Path = $desk; Who = $pick.Who }
    } catch { return $null }
}

if (-not $OutDir) {
    $iud = Get-InteractiveUserDesktop
    if ($iud) { $OutDir = $iud.Path }
    elseif (Test-Path -LiteralPath "$env:PUBLIC\Desktop") { $OutDir = "$env:PUBLIC\Desktop" }
    else { $OutDir = 'C:\' }
}
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$Folder = Join-Path $OutDir ("WakeDeviceCheck_{0}_{1}" -f $env:COMPUTERNAME, $stamp)
New-Item -ItemType Directory -Path $Folder -Force | Out-Null
$reportPath = Join-Path $Folder 'WakeReport.txt'
$csvPath = Join-Path $Folder 'WakeEvents.csv'

# Device Manager problem codes that matter here.
$ProblemText = @{
    1 = 'not configured correctly'; 3 = 'driver may be corrupted / low memory'; 10 = 'device cannot start (code 10)'
    12 = 'not enough free resources'; 14 = 'needs restart'; 18 = 'reinstall drivers'; 19 = 'registry config damaged'
    21 = 'being removed'; 22 = 'disabled'; 24 = 'not present / not working (code 24)'; 28 = 'no driver installed'
    29 = 'disabled by firmware'; 31 = 'driver not loaded (code 31)'; 32 = 'driver service disabled'
    37 = 'driver failed to initialise'; 39 = 'driver corrupt or missing'; 43 = 'device reported a problem and was stopped (code 43)'
    45 = 'not connected (code 45)'; 47 = 'safe-removal prepared'; 48 = 'driver blocked'; 52 = 'driver not signed'
}
# Device classes that typically fail after wake.
$VirtualRx = 'VPN|TAP|Virtual|Miniport|Offload|Debug|AnyConnect|Fortinet|Check Point|Sophos|Hyper-V|VMware|VirtualBox|Loopback'
$WakeClasses = @('USB', 'HIDClass', 'Keyboard', 'Mouse', 'Net', 'Bluetooth', 'Camera', 'Image', 'Media',
                 'AudioEndpoint', 'Display', 'Biometric', 'Ports', 'SmartCardReader', 'Sensor', 'System')

$runStart = Get-Date
$doSleepTest = [bool]$SleepTest
if (-not $doSleepTest -and (Can-Ask)) {
    Write-Host ''
    Write-Host 'Do you also want a LIVE sleep test? (you put the PC to sleep, wake it, and this' -ForegroundColor Cyan
    Write-Host 'script shows exactly which devices broke across that wake)' -ForegroundColor Cyan
    Write-Host 'Run the sleep test? [y/N] ' -NoNewline
    try { $ans = Read-Host } catch { $ans = '' }
    if ($ans -match '^(y|yes)$') { $doSleepTest = $true }
}

function Get-DeviceSnapshot {
    $h = @{}
    foreach ($d in @(Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue)) {
        if (-not $d.PNPDeviceID) { continue }
        $h[$d.PNPDeviceID] = [pscustomobject]@{
            Id = $d.PNPDeviceID; Name = $d.Name; Class = $d.PNPClass
            Code = [int]$d.ConfigManagerErrorCode; Status = $d.Status
        }
    }
    return $h
}

# ---- optional live sleep test ------------------------------------------------------------
$sleepTestLines = New-Object System.Collections.Generic.List[string]
if ($doSleepTest) {
    $before = Get-DeviceSnapshot
    $testStart = Get-Date
    Write-Host ''
    Write-Host ("Snapshot taken: {0} devices." -f $before.Count) -ForegroundColor Green
    Write-Host 'NOW: put the PC to sleep (Start > Power > Sleep, or close the lid), or Hibernate if'
    Write-Host 'that is the case that fails. Wait at least 30 seconds, wake it, sign in, try the'
    Write-Host 'device that stops working, then come back here and press Enter.'
    if (Can-Ask) { try { [void](Read-Host 'Press Enter after the PC has slept and woken') } catch {} }
    Start-Sleep -Seconds 5
    $after = Get-DeviceSnapshot
    $wokeEv = @(Try-Events @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-Power'; Id = 107, 507; StartTime = $testStart } 50)
    $wokeEv += @(Try-Events @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Power-Troubleshooter'; Id = 1; StartTime = $testStart } 50)
    if ($wokeEv.Count -eq 0) {
        [void]$sleepTestLines.Add('WARNING: no sleep/wake was logged since the snapshot - the test may not have slept the PC.')
    } else {
        [void]$sleepTestLines.Add(("Wake logged at: {0}" -f (($wokeEv | Sort-Object TimeCreated | Select-Object -Last 1).TimeCreated)))
    }
    $gone = @(); $broke = @(); $fixed = @(); $new = @()
    foreach ($k in $before.Keys) {
        $b = $before[$k]
        if (-not $after.ContainsKey($k)) { $gone += $b; continue }
        $a = $after[$k]
        if ($b.Code -eq 0 -and $a.Code -ne 0) { $broke += [pscustomobject]@{ Name = $a.Name; Class = $a.Class; Code = $a.Code; Meaning = $ProblemText[$a.Code]; Id = $k } }
        elseif ($b.Code -ne 0 -and $a.Code -eq 0) { $fixed += $a }
    }
    foreach ($k in $after.Keys) { if (-not $before.ContainsKey($k)) { $new += $after[$k] } }
    [void]$sleepTestLines.Add(("Devices before: {0}  after: {1}" -f $before.Count, $after.Count))
    $script:SleepGone = $gone; $script:SleepBroke = $broke; $script:SleepNew = $new; $script:SleepFixed = $fixed
    $script:SleepTestStart = $testStart
    if ($gone.Count) { Flag ("SLEEP TEST: {0} device(s) DISAPPEARED across the wake: {1}" -f $gone.Count, (($gone | Select-Object -First 6 | ForEach-Object { $_.Name }) -join '; ')) }
    if ($broke.Count) { Flag ("SLEEP TEST: {0} device(s) went into an ERROR state after the wake: {1}" -f $broke.Count, (($broke | ForEach-Object { "$($_.Name) [code $($_.Code)]" }) -join '; ')) }
    if (-not $gone.Count -and -not $broke.Count -and $wokeEv.Count) { Flag 'SLEEP TEST: every device was still present and OK after the wake (problem may be intermittent, or inside the driver without a Device Manager error - check the wake-correlated events below).' }
}

# ==========================================================================================
W ("Wake / device check  v{0}   PC: {1}   run: {2}" -f $ScriptVersion, $env:COMPUTERNAME, (Get-Date -Format 'yyyy-MM-dd HH:mm'))
W ("History window: last {0} days; 'after wake' = first {1} min after each wake." -f $Days, $WindowMinutes)
$script:R.Add('@@REVIEW@@')   # replaced by the review list at the end (file only)

# ---- 1. system / sleep type --------------------------------------------------------------
Sec '1. SYSTEM, SLEEP TYPE, HIBERNATE / FAST STARTUP'
try {
    $cs = Get-CimInstance Win32_ComputerSystem
    $bios = Get-CimInstance Win32_BIOS
    $os = Get-CimInstance Win32_OperatingSystem
    W ("Model: {0} {1}" -f $cs.Manufacturer, $cs.Model)
    W ("OS:    {0} build {1}" -f $os.Caption, $os.BuildNumber)
    $biosDate = $bios.ReleaseDate
    W ("BIOS:  {0}  released {1}" -f $bios.SMBIOSBIOSVersion, $(if ($biosDate) { $biosDate.ToString('yyyy-MM-dd') } else { '?' }))
    if ($biosDate -and $biosDate -lt (Get-Date).AddYears(-2)) {
        Flag ("BIOS/UEFI is from {0} (over 2 years old). Sleep/wake bugs are very often fixed in BIOS + chipset updates - check {1}'s support site." -f $biosDate.ToString('yyyy-MM-dd'), $cs.Manufacturer)
    }
} catch { W "  could not read system info: $_" }

$pa = PCfg '/a'
W ''
W 'powercfg /a (sleep states available on this PC):'
W ($pa.TrimEnd())
$modernStandby = $pa -match 'Standby \(S0 Low Power Idle\)' -and ($pa -split 'not available')[0] -match 'S0 Low Power Idle'
if ($modernStandby) {
    W ''
    W '=> This PC uses MODERN STANDBY (S0). "Sleep" keeps the PC half-on and devices are powered down'
    W '   individually, so a driver that handles that badly breaks on wake. The sleep-study report'
    W '   (section 7) shows which components kept it awake or failed to go to low power.'
}
$pwr = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' -ErrorAction SilentlyContinue
$sm  = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -ErrorAction SilentlyContinue
W ''
W ("Hibernate available:      {0}" -f [bool](($pa -split 'not available')[0] -match 'Hibernate'))
W ("Fast startup (Hiberboot): {0}" -f $(if ($sm -and $null -ne $sm.HiberbootEnabled) { [bool]$sm.HiberbootEnabled } else { '(default = on)' }))
if ($pwr -and $null -ne $pwr.PlatformAoAcOverride) { W ("PlatformAoAcOverride:    {0}  (0 = Modern Standby forced OFF by registry)" -f $pwr.PlatformAoAcOverride) }
if (-not $sm -or $null -eq $sm.HiberbootEnabled -or $sm.HiberbootEnabled -eq 1) {
    Flag 'Fast startup is ON: a "shut down" is really a hibernate, so drivers are never fully reloaded. If devices also fail after a shut-down/power-on (not just sleep), test with fast startup off: powercfg /h off  OR  Control Panel > Power Options > Choose what the power buttons do.'
}

# ---- 2. sleep / wake history ---------------------------------------------------------------
Sec '2. SLEEP / WAKE HISTORY'
$since = (Get-Date).AddDays(-$Days)
$kp = @(Try-Events @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-Power'; Id = 41, 42, 107, 506, 507; StartTime = $since })
$pt = @(Try-Events @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Power-Troubleshooter'; Id = 1; StartTime = $since })
$ev6008 = @(Try-Events @{ LogName = 'System'; ProviderName = 'EventLog'; Id = 6008; StartTime = $since })
$kb27 = @(Try-Events @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-Boot'; Id = 27; StartTime = $since })

$cntSleep = @($kp | Where-Object { $_.Id -eq 42 }).Count
$cntHib = 0
foreach ($e in @($kp | Where-Object { $_.Id -eq 42 })) { try { if ([int]$e.Properties[1].Value -eq 5) { $cntHib++ } } catch {} }
W ("Went to sleep (Kernel-Power 42): {0}   of which hibernate: {1}" -f $cntSleep, $cntHib)
W ("Resumed (Kernel-Power 107):      {0}" -f @($kp | Where-Object { $_.Id -eq 107 }).Count)
W ("Modern Standby enter/exit (506/507): {0} / {1}" -f @($kp | Where-Object { $_.Id -eq 506 }).Count, @($kp | Where-Object { $_.Id -eq 507 }).Count)
W ("Power-Troubleshooter wake records: {0}" -f $pt.Count)

# Build a merged list of wake moments.
$wakeTimes = New-Object System.Collections.Generic.List[datetime]
foreach ($e in (@($kp | Where-Object { $_.Id -in 107, 507 }) + $pt | Sort-Object TimeCreated)) {
    if ($wakeTimes.Count -eq 0 -or ($e.TimeCreated - $wakeTimes[$wakeTimes.Count - 1]).TotalSeconds -gt 120) { [void]$wakeTimes.Add($e.TimeCreated) }
}
W ("Distinct wake moments: {0}" -f $wakeTimes.Count)

if ($pt.Count) {
    W ''
    W 'Last 15 wakes with their wake source (Power-Troubleshooter):'
    $rows = foreach ($e in ($pt | Sort-Object TimeCreated -Descending | Select-Object -First 15)) {
        $src = ''; $slept = ''
        if ($e.Message -match 'Wake Source:\s*(.+)') { $src = $matches[1].Trim() }
        if ($e.Message -match 'Sleep Time:\s*(.+)') { $slept = $matches[1].Trim() }
        [pscustomobject]@{ Woke = $e.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss'); SleptAt = Short $slept 30; WakeSource = Short $src 70 }
    }
    T $rows
}

# Failed resumes: a 41 / 6008 whose previous Kernel-Power event was "entering sleep".
$failed = @()
$timeline = @($kp | Sort-Object TimeCreated)
foreach ($crash in (@($kp | Where-Object { $_.Id -eq 41 }) + $ev6008)) {
    $prev = $timeline | Where-Object { $_.TimeCreated -lt $crash.TimeCreated.AddSeconds(-1) -and $_.Id -ne 41 } | Select-Object -Last 1
    if ($prev -and $prev.Id -in 42, 506) {
        $failed += [pscustomobject]@{ When = $crash.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss'); Event = "$($crash.ProviderName -replace 'Microsoft-Windows-','') $($crash.Id)"; WentToSleep = $prev.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss') }
    }
}
W ''
W 'Failed resumes (PC rebooted/lost power while asleep instead of waking):'
T $failed
if ($failed.Count) { Flag ("{0} FAILED RESUME(S): the PC went to sleep and came back with a hard reboot (Kernel-Power 41 / 6008) instead of a wake. That is a firmware/driver hang on resume - BIOS + chipset + graphics updates first; run pull-local-logs for the crash dumps." -f $failed.Count) }
if ($kb27.Count) {
    $hibResume = @($kb27 | Where-Object { try { [int]$_.Properties[0].Value -eq 2 } catch { $false } }).Count
    W ("Boots that were a resume from hibernate (Kernel-Boot 27 type 2): {0}" -f $hibResume)
}

# ---- 3. wake correlation -------------------------------------------------------------------
Sec ("3. WHAT GOES WRONG RIGHT AFTER A WAKE (first {0} min)" -f $WindowMinutes)
$sysErr = @(Try-Events @{ LogName = 'System'; Level = 1, 2, 3; StartTime = $since })
$pnp411 = @(Try-Events @{ LogName = 'Microsoft-Windows-Kernel-PnP/Configuration'; Id = 411, 441, 442; StartTime = $since })
$wlan = @(Try-Events @{ LogName = 'Microsoft-Windows-WLAN-AutoConfig/Operational'; Id = 8003, 11004, 11005, 11010, 12013; StartTime = $since })
$all = @($sysErr + $pnp411 + $wlan | Sort-Object TimeCreated)
# Kernel-Power's own sleep bookkeeping is not a device problem.
$all = @($all | Where-Object { -not ($_.ProviderName -eq 'Microsoft-Windows-Kernel-Power' -and $_.Id -in 42, 107, 506, 507, 172, 566) })

$wArr = $wakeTimes.ToArray()
function Is-AfterWake([datetime]$t) {
    foreach ($w in $wArr) {
        $d = ($t - $w).TotalSeconds
        if ($d -ge -30 -and $d -le ($WindowMinutes * 60)) { return $true }
    }
    return $false
}
$csvRows = New-Object System.Collections.Generic.List[object]
$groups = @{}
foreach ($e in $all) {
    $aw = Is-AfterWake $e.TimeCreated
    $msg = ''
    try { $msg = $e.Message } catch {}
    $prov = $e.ProviderName -replace '^Microsoft-Windows-', ''
    $key = "$prov $($e.Id)"
    if ($e.Id -eq 411 -and $msg -match 'Device\s+(\S+)\s+had a problem') { $key = "Kernel-PnP 411 " + ($matches[1] -replace '\\[^\\]*$', '') }
    if (-not $groups.ContainsKey($key)) { $groups[$key] = [pscustomobject]@{ Source = $key; AfterWake = 0; Total = 0; Last = $e.TimeCreated; Sample = (Short $msg 150) } }
    $g = $groups[$key]; $g.Total++; if ($aw) { $g.AfterWake++ }
    if ($e.TimeCreated -gt $g.Last) { $g.Last = $e.TimeCreated }
    [void]$csvRows.Add([pscustomobject]@{ Time = $e.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss'); AfterWake = $aw; Log = $e.LogName; Source = $e.ProviderName; Id = $e.Id; Level = $e.LevelDisplayName; Message = (Short $msg 600) })
}
$csvRows | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding UTF8
$suspects = @($groups.Values | Where-Object { $_.AfterWake -ge 2 -and ($_.AfterWake / [double]$_.Total) -ge 0.5 } | Sort-Object AfterWake -Descending)
W ("Errors/warnings read: {0} (full list in WakeEvents.csv)" -f $all.Count)
W ''
W 'PRIME SUSPECTS - sources that fire mostly in the minutes after a wake:'
T ($suspects | Select-Object -First 20 Source, AfterWake, Total, @{ n = 'Last'; e = { $_.Last.ToString('MM-dd HH:mm') } }, Sample)
foreach ($s in ($suspects | Select-Object -First 5)) {
    Flag ("Wake-correlated: '{0}' - {1} of its {2} errors/warnings came within {3} min of a wake. Example: {4}" -f $s.Source, $s.AfterWake, $s.Total, $WindowMinutes, (Short $s.Sample 110))
}
W ''
W 'Other sources that also appear after wakes (less clear-cut):'
T (@($groups.Values | Where-Object { $_.AfterWake -ge 1 -and $suspects -notcontains $_ } | Sort-Object AfterWake -Descending | Select-Object -First 15 Source, AfterWake, Total, Sample))

# ---- 4. devices in error now ------------------------------------------------------------------
Sec '4. DEVICES WITH A PROBLEM RIGHT NOW (Device Manager)'
$pnpAll = @(Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue)
$bad = @($pnpAll | Where-Object { $_.ConfigManagerErrorCode -ne 0 -and $_.ConfigManagerErrorCode -ne 22 })
T ($bad | Select-Object Name, PNPClass, @{ n = 'Code'; e = { $_.ConfigManagerErrorCode } }, @{ n = 'Meaning'; e = { $ProblemText[[int]$_.ConfigManagerErrorCode] } }, PNPDeviceID)
foreach ($b in $bad) {
    if ($b.ConfigManagerErrorCode -in 10, 31, 37, 43, 45, 24) {
        Flag ("Device in error now: {0} [{1}] code {2} - {3}. If this is the device that dies after sleep: disable+enable it in Device Manager to confirm, then update/roll back its driver." -f $b.Name, $b.PNPClass, $b.ConfigManagerErrorCode, $ProblemText[[int]$b.ConfigManagerErrorCode])
    }
}
$disabled = @($pnpAll | Where-Object { $_.ConfigManagerErrorCode -eq 22 })
if ($disabled.Count) { W ''; W 'Disabled devices (code 22 - someone turned these off):'; T ($disabled | Select-Object Name, PNPClass) }

# ---- 5. power saving that switches devices off ---------------------------------------------
Sec '5. POWER SAVING THAT CAN SWITCH DEVICES OFF'
$byId = @{}
foreach ($d in $pnpAll) { if ($d.PNPDeviceID) { $byId[$d.PNPDeviceID.ToUpperInvariant()] = $d } }
$psRows = @()
try {
    foreach ($m in @(Get-CimInstance -Namespace root\wmi -ClassName MSPower_DeviceEnable -ErrorAction Stop)) {
        $pid0 = ($m.InstanceName -replace '_\d+$', '').ToUpperInvariant()
        $d = $byId[$pid0]
        if (-not $d) { continue }
        if ($WakeClasses -notcontains $d.PNPClass) { continue }
        if ($d.Name -match $VirtualRx) { continue }
        $psRows += [pscustomobject]@{ Device = $d.Name; Class = $d.PNPClass; MayTurnOff = [bool]$m.Enable }
    }
} catch { W "  could not read MSPower_DeviceEnable: $_" }
W '"Allow the computer to turn off this device to save power" (Device Manager > Power Management tab):'
T ($psRows | Sort-Object Class, Device)
$onRows = @($psRows | Where-Object { $_.MayTurnOff -and $_.Class -in 'USB', 'HIDClass', 'Net', 'Bluetooth', 'Keyboard', 'Mouse' })
if ($onRows.Count) {
    Flag ("{0} USB hub / HID / network / Bluetooth device(s) are allowed to be switched off to save power (e.g. {1}). Test: untick 'Allow the computer to turn off this device' on the failing device AND its USB Root Hub / hub in Device Manager > Power Management." -f $onRows.Count, (($onRows | Select-Object -First 4 | ForEach-Object { $_.Device }) -join '; '))
}

W ''
W 'Network adapters - power management:'
try {
    $napm = @(Get-NetAdapter -Physical -ErrorAction Stop | ForEach-Object {
        $p = Get-NetAdapterPowerManagement -Name $_.Name -ErrorAction SilentlyContinue
        [pscustomobject]@{ Adapter = $_.Name; Desc = $_.InterfaceDescription; Status = $_.Status; Driver = "$($_.DriverVersion) ($($_.DriverDate))"
            AllowTurnOff = $(if ($p) { $p.AllowComputerToTurnOffDevice } else { '?' }); SelectiveSuspend = $(if ($p) { $p.SelectiveSuspend } else { '?' }) }
    })
    T $napm
    foreach ($n in $napm) { if ("$($n.AllowTurnOff)" -eq 'Enabled') { Flag ("Network adapter '{0}' ({1}) may be switched off to save power. If Wi-Fi/Ethernet is the thing that dies after sleep: Device Manager > adapter > Power Management > untick, or  Set-NetAdapterPowerManagement -Name '{0}' -AllowComputerToTurnOffDevice Disabled" -f $n.Adapter, $n.Desc) } }
} catch { W "  could not read network adapters: $_" }

function Get-PowerSetting([string]$sub, [string]$setting) {
    $o = (& powercfg.exe /q SCHEME_CURRENT $sub $setting 2>$null | Out-String)
    $ac = $null; $dc = $null
    if ($o -match 'Current AC Power Setting Index:\s*0x([0-9a-fA-F]+)') { $ac = [Convert]::ToInt32($matches[1], 16) }
    if ($o -match 'Current DC Power Setting Index:\s*0x([0-9a-fA-F]+)') { $dc = [Convert]::ToInt32($matches[1], 16) }
    return [pscustomobject]@{ AC = $ac; DC = $dc }
}
$usbSS = Get-PowerSetting '2a737441-1930-4402-8d77-b2bebba308a3' '48e6b7a6-50f5-4782-a5d4-53bb8f07e226'
$aspm  = Get-PowerSetting '501a4d13-42af-4429-9fd1-a8218c268e20' 'ee12f906-d277-404b-b6da-e5fa1a576df5'
$wifiP = Get-PowerSetting '19cbb8fa-5279-450e-9fac-8a3d5fedd0c1' '12bbebe6-58d6-4636-95bb-3217ef867c1a'
$aspmTxt = @{ 0 = 'Off'; 1 = 'Moderate'; 2 = 'Maximum savings' }
$wifiTxt = @{ 0 = 'Max performance'; 1 = 'Low saving'; 2 = 'Medium saving'; 3 = 'Max saving' }
W ''
W 'Active power plan settings (plugged in / on battery):'
W ("  USB selective suspend:             {0} / {1}" -f $(if ($null -eq $usbSS.AC) { 'hidden' } elseif ($usbSS.AC) { 'Enabled' } else { 'Disabled' }), $(if ($null -eq $usbSS.DC) { 'hidden' } elseif ($usbSS.DC) { 'Enabled' } else { 'Disabled' }))
W ("  PCI Express link state power mgmt: {0} / {1}" -f $(if ($null -eq $aspm.AC) { 'hidden' } else { $aspmTxt[$aspm.AC] }), $(if ($null -eq $aspm.DC) { 'hidden' } else { $aspmTxt[$aspm.DC] }))
W ("  Wireless adapter power saving:     {0} / {1}" -f $(if ($null -eq $wifiP.AC) { 'hidden' } else { $wifiTxt[$wifiP.AC] }), $(if ($null -eq $wifiP.DC) { 'hidden' } else { $wifiTxt[$wifiP.DC] }))
W ("  (powercfg /getactivescheme: {0})" -f ((& powercfg.exe /getactivescheme 2>$null | Out-String).Trim()))
if ($usbSS.AC -eq 1 -or $usbSS.DC -eq 1) {
    Flag 'USB selective suspend is ENABLED. If USB devices / docks / touchpad / webcam die after wake, test with it off: Power Options > Change plan settings > Advanced > USB settings > USB selective suspend = Disabled  (or: powercfg /setacvalueindex SCHEME_CURRENT 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 0, same with /setdcvalueindex, then powercfg /setactive SCHEME_CURRENT).'
}
if ($aspm.AC -eq 2 -or $aspm.DC -eq 2) { Flag 'PCI Express link state power management is on MAXIMUM savings. Wi-Fi cards and NVMe/Thunderbolt controllers on PCIe sometimes fail to come back - test with it Off (Power Options > Advanced > PCI Express).' }
if ($wifiP.DC -eq 3) { Flag 'Wireless adapter power saving on battery is MAX SAVING - a common cause of Wi-Fi not reconnecting after wake on battery. Test with Maximum Performance.' }

# ---- 6. drivers ----------------------------------------------------------------------------
Sec '6. DRIVERS FOR THE DEVICES THAT USUALLY BREAK ON WAKE'
$drv = @()
try {
    $drv = @(Get-CimInstance Win32_PnPSignedDriver -ErrorAction Stop | Where-Object {
        $_.DeviceName -and (
            ($_.DeviceClass -ne 'NET' -or $_.DeviceName -notmatch $VirtualRx) -and $_.DeviceClass -in 'NET', 'BLUETOOTH', 'HIDCLASS', 'KEYBOARD', 'MOUSE', 'DISPLAY', 'CAMERA', 'IMAGE', 'MEDIA', 'BIOMETRIC' -or
            ($_.DeviceClass -eq 'USB' -and $_.DeviceName -match 'Host Controller|Root Hub|Hub|Thunderbolt|USB4') -or
            ($_.DeviceClass -eq 'SYSTEM' -and $_.DeviceName -match 'Serial IO|I2C|GPIO|Chipset|Management Engine|Thunderbolt|Dynamic Tuning|PMC|SMBus'))
    } | Sort-Object DeviceClass, DeviceName -Unique)
} catch { W "  could not read drivers: $_" }
$drvRows = foreach ($d in $drv) {
    $dd = $null
    try { if ($d.DriverDate) { $dd = [datetime]$d.DriverDate } } catch {}
    [pscustomobject]@{ Class = $d.DeviceClass; Device = (Short $d.DeviceName 60); Provider = (Short $d.DriverProviderName 22); Version = $d.DriverVersion; Date = $(if ($dd) { $dd.ToString('yyyy-MM-dd') } else { '' }); _d = $dd }
}
T ($drvRows | Select-Object Class, Device, Provider, Version, Date)
$oldDrv = @($drvRows | Where-Object { $_.Device -notmatch $VirtualRx -and $_._d -and $_._d -lt (Get-Date).AddYears(-3) -and $_.Provider -notmatch '^Microsoft' -and $_.Class -in 'NET', 'BLUETOOTH', 'DISPLAY', 'SYSTEM', 'CAMERA', 'MEDIA' })
if ($oldDrv.Count) { Flag ("{0} vendor driver(s) for wake-sensitive devices are over 3 years old: {1}. Get current Wi-Fi/Bluetooth/chipset/graphics/audio drivers from the laptop maker." -f $oldDrv.Count, (($oldDrv | Select-Object -First 5 | ForEach-Object { "$($_.Device) ($($_.Date))" }) -join '; ')) }
$msWifi = @($drvRows | Where-Object { $_.Class -eq 'NET' -and $_.Provider -match '^Microsoft' -and $_.Device -match 'Wi-?Fi|Wireless|802\.11|WLAN' })
if ($msWifi.Count) { Flag ("Wi-Fi adapter uses a generic Microsoft driver ({0}). Install the vendor (Intel/Realtek/MediaTek/Qualcomm) driver - the inbox ones handle sleep worst." -f (($msWifi | ForEach-Object { $_.Device }) -join '; ')) }

# ---- 7. powercfg wake info + sleep study ---------------------------------------------------
Sec '7. POWERCFG: LAST WAKE, WAKE-ARMED DEVICES, SLEEP STUDY'
W 'powercfg /lastwake:'
W (PCfg '/lastwake')
W ''
W 'Devices allowed to WAKE the PC (powercfg /devicequery wake_armed):'
W (PCfg '/devicequery wake_armed')
W ''
W 'Active wake timers / requests (powercfg /waketimers, /requests):'
W (PCfg '/waketimers')
W (PCfg '/requests')
if (-not $NoPowerReport) {
    $ss = Join-Path $Folder 'SleepStudy.html'
    $o = PCfg ('/sleepstudy /output "{0}" /duration {1}' -f $ss, [Math]::Min($Days, 28))
    if (Test-Path -LiteralPath $ss) { W ''; W "Sleep-study report saved: $ss" }
    else {
        $spr = Join-Path $Folder 'SystemPowerReport.html'
        $o2 = PCfg ('/systempowerreport /output "{0}"' -f $spr)
        if (Test-Path -LiteralPath $spr) { W ''; W "System power report saved: $spr" }
        else { W ''; W ("Sleep-study report not available on this PC: {0} {1}" -f (Short $o 120), (Short $o2 120)) }
    }
    if ($modernStandby) { W 'Open it and look at each "Modern Standby" session: the top offenders and any device marked as not entering low power are the suspects.' }
}

# ---- sleep test results ---------------------------------------------------------------------
if ($doSleepTest) {
    Sec '8. LIVE SLEEP TEST RESULT'
    foreach ($l in $sleepTestLines) { W $l }
    W ''
    W 'Devices that DISAPPEARED across the wake:'
    T ($script:SleepGone | Select-Object Name, Class, Id)
    W ''
    W 'Devices that went into an ERROR state across the wake:'
    T $script:SleepBroke
    W ''
    W 'Devices that appeared new after the wake (re-enumerated - can be normal for USB):'
    T ($script:SleepNew | Select-Object Name, Class, Code)
    W ''
    W 'Device / driver events logged since the snapshot:'
    $tEv = @($csvRows | Where-Object { [datetime]$_.Time -ge $script:SleepTestStart })
    T ($tEv | Select-Object Time, Source, Id, @{ n = 'Message'; e = { Short $_.Message 110 } })
}

# ---- review list at the top ---------------------------------------------------------------
$rv = New-Object System.Collections.Generic.List[string]
[void]$rv.Add('')
[void]$rv.Add('REVIEW LIST (what looks wrong, most important first; nothing was changed on this PC)')
[void]$rv.Add('-' * 78)
if ($script:Review.Count -eq 0) { [void]$rv.Add('  Nothing stands out. Re-run with the live sleep test (-SleepTest) right when the problem happens.') }
$i = 0
foreach ($f in $script:Review) { $i++; [void]$rv.Add(("{0,2}. {1}" -f $i, $f)) }
[void]$rv.Add('-' * 78)
[void]$rv.Add('Generic fixes, in the order to try: (1) BIOS + chipset + the failing device''s driver from the')
[void]$rv.Add('laptop maker; (2) untick "Allow the computer to turn off this device" on the device and its')
[void]$rv.Add('USB hub; (3) USB selective suspend / PCIe link power / Wi-Fi power saving off; (4) fast startup off;')
[void]$rv.Add('(5) Modern Standby PCs: if all else fails, disable it (reg PlatformAoAcOverride=0) to fall back to S3 sleep, if the BIOS supports S3.')
$idx = $script:R.IndexOf('@@REVIEW@@')
$script:R.RemoveAt($idx)
$script:R.InsertRange($idx, $rv)

Set-Content -LiteralPath $reportPath -Value $script:R -Encoding UTF8
Write-Host ''
Write-Host ('=' * 78) -ForegroundColor Cyan
foreach ($l in $rv) { Write-Host $l -ForegroundColor Yellow }
Write-Host ''
Write-Host "Report folder: $Folder" -ForegroundColor Green
Write-Host '  WakeReport.txt   - the full report (review list at the top)'
Write-Host '  WakeEvents.csv   - every error/warning read, with an AfterWake column'
Write-Host '  SleepStudy.html  - Windows'' own sleep report (if this PC supports it)'

# ---- zip the folder so it is one file to send ----------------------------------------------
$zipPath = "$Folder.zip"
try {
    if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
    Compress-Archive -Path (Join-Path $Folder '*') -DestinationPath $zipPath -CompressionLevel Optimal -ErrorAction Stop
    Write-Host ''
    Write-Host "ZIP to send: $zipPath  ($([Math]::Round((Get-Item -LiteralPath $zipPath).Length / 1MB, 1)) MB)" -ForegroundColor Green
} catch {
    Write-Host ''
    Write-Host "Could not create the zip ($($_.Exception.Message)) - send the folder instead." -ForegroundColor Yellow
}
