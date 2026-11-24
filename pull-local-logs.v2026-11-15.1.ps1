<#
  Run this ON the target machine itself - no credentials, no network access,
  no WinRM required at all. For when pull-remote-logs.ps1 can't reach the
  target: no password set on the account (Windows blocks blank-password
  accounts from network logon by default, regardless of what credential a
  remote script sends), enable-remote-diag.ps1 wasn't/can't be run there, or
  the machine simply isn't reachable over the network from where you are.

  ONE tool for the whole story: event logs, BSOD/unexpected-shutdown
  decoding, GPU/driver inventory, TDR settings, GPU-event correlation with
  crashes, crash dumps (Minidump + full LiveKernelReports tree), a live
  nvidia-smi snapshot if present, dxdiag's Display Devices section, Print
  Service diagnostics (spooler/driver errors + per-job history), and a live
  network-state snapshot (ipconfig, DNS, routing, hosts file, proxy, security
  software, SMB/file-share client state + SmbClient logs) - all in one run
  instead of needing separate tools for each.
  Also (2026-10-25): an EFI System Partition usage check (EspUsage.txt/.csv, admin only) - who filled it, Windows or HP.
  Also (2026-10-07): a LIGHT startup/scheduled-task inventory (StartupAndTasks.txt) - what starts by
  itself and which account things run as. The deep forensic version is pull-persistence.v*.ps1.
  (2026-09: merged in what were previously three separate scripts,
  pull-minidumps.ps1, capture-gpu-logs.ps1, and capture-network-state.ps1 -
  all three retired, this replaces them.)

  System/Application/PrintService event logs need no admin rights (the two
  SmbClient logs DO - non-elevated they're reported as unauthorized and
  skipped, everything else still pulls). GPU inventory/TDR settings/
  dxdiag/nvidia-smi and dump collection DO need admin - if this isn't run
  elevated, that whole section is skipped gracefully and event logs are
  pulled as normal either way. Run elevated to get everything.

  This window always stays open until you press Enter, and every run writes
  its output (folder, zip and run log) into a "RemoteDiagLogs" folder on the
  Desktop of the person actually LOGGED IN at the machine - even when this is
  run elevated via a different admin account than whoever is sitting there
  (that admin's own Desktop is where output used to land, which nobody could
  find). Falls back to the Public desktop, then C:\, and -OutRoot overrides all.

  v2026-11-15.1 (for the Remote Diagnostics window, gui\ - additive, interactive runs unchanged):
  -NoFullDump answers the full-memory-dump question with No without asking; when stdin is
  redirected (the window) the closing "Press Enter" wait and the automatic Explorer window are skipped.
#>

param(
    [int]$Hours,
    # Empty = auto: <Desktop of the user who is actually logged in>\RemoteDiagLogs
    # (resolved below by Get-InteractiveUserDesktop). NOT $env:USERPROFILE\Desktop -
    # when this is run elevated via a DIFFERENT admin credential than whoever is
    # logged in (the normal case on a client machine), $env:USERPROFILE is that
    # ADMIN's profile and the output lands where the person at the machine never
    # looks. Pass -OutRoot X to put it somewhere specific.
    [string]$OutRoot = "",
    # Also copy C:\Windows\MEMORY.DMP (full/kernel dump - can be several GB).
    # Without this switch you're prompted interactively instead, defaulting to
    # No - minidumps and GPU/TDR dumps are always collected regardless, since
    # those are small.
    [switch]$IncludeFullDump,
    # Answer the full-dump question with No without asking (the window passes this or -IncludeFullDump).
    [switch]$NoFullDump
)

$ErrorActionPreference = "Stop"

# Format every displayed/exported timestamp the same unambiguous way, regardless
# of this machine's regional settings. Without this, a target set to e.g. German
# locale exports "01.09.2026" (dd.MM.yyyy) which silently misparses as January 9
# on an en-US machine analyzing the CSV later - caught 2026-09-01 analyzing a
# German-locale machine's pull. yyyy-MM-dd is parsed consistently by [datetime]
# across cultures, so round-tripping through this format is always safe.
function Format-DT($d) { $d.ToString("yyyy-MM-dd HH:mm:ss", [System.Globalization.CultureInfo]::InvariantCulture) }

# How far back to pull: default 72 hours (3 days), maximum 168 (one week). Used by the interactive
# prompt AND the -Hours parameter, so "-Hours 168" and typing 168 behave the same. A bigger window just
# makes the pull slower and the zip larger - raise $PullMaxHours here if a longer window is ever needed.
# KEEP THIS BLOCK IDENTICAL IN pull-local-logs.ps1 AND pull-remote-logs.ps1.
$PullDefaultHours = 72
$PullMaxHours = 168
function Resolve-PullHours {
    param([int]$Requested = 0, [scriptblock]$Ask = { param($p) Read-Host $p })
    if ($Requested -ne 0) {
        if ($Requested -lt 1) { Write-Host "  -Hours must be 1 or more - using $PullDefaultHours." -ForegroundColor Yellow; return $PullDefaultHours }
        if ($Requested -gt $PullMaxHours) { Write-Host "  -Hours $Requested is above the maximum of $PullMaxHours (one week) - using $PullMaxHours." -ForegroundColor Yellow; return $PullMaxHours }
        return $Requested
    }
    for ($try = 1; $try -le 3; $try++) {
        $raw = $null
        try { $raw = & $Ask "How many hours back to pull? Press Enter for $PullDefaultHours (3 days), or type a number up to $PullMaxHours (168 = one week)" } catch { return $PullDefaultHours }
        $raw = "$raw".Trim()
        if ($raw -eq '') { return $PullDefaultHours }
        $n = 0
        if ([int]::TryParse($raw, [ref]$n) -and $n -ge 1) {
            if ($n -gt $PullMaxHours) { Write-Host "  $n is above the maximum of $PullMaxHours (one week) - using $PullMaxHours." -ForegroundColor Yellow; return $PullMaxHours }
            return $n
        }
        Write-Host "  Please type a whole number from 1 to $PullMaxHours (or just press Enter for $PullDefaultHours)." -ForegroundColor Yellow
    }
    Write-Host "  Not understood - using $PullDefaultHours hours." -ForegroundColor Yellow
    return $PullDefaultHours
}

function Get-InteractiveUserDesktop {
    # The Desktop folder of the person actually sitting at this machine - NOT necessarily the
    # account this script is running as. Run elevated via a DIFFERENT admin account (the usual
    # case on a client PC), $env:USERPROFILE and [Environment]::GetFolderPath('Desktop') both
    # point at that admin's profile, which the logged-in user never sees. So find who owns the
    # running Explorer shell instead, and read THAT user's real Desktop location (it honours
    # OneDrive "known folder" redirection). Returns a PSCustomObject (Path, Who) or $null.
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
        # Prefer the console user; otherwise the first real (non-session-0) Explorer owner.
        $pick = $cands | Where-Object { $consoleUser -and $_.Who -eq $consoleUser } | Select-Object -First 1
        if (-not $pick) { $pick = $cands | Where-Object { $_.Session -ne 0 } | Select-Object -First 1 }
        if (-not $pick) { return $null }

        $profile = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$($pick.Sid)" -ErrorAction Stop).ProfileImagePath
        $profile = [Environment]::ExpandEnvironmentVariables($profile)
        $desk = $null
        try {
            $k = [Microsoft.Win32.Registry]::Users.OpenSubKey("$($pick.Sid)\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders")
            if ($k) {
                $raw = $k.GetValue('Desktop', $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                if ($raw) {
                    $raw = $raw -replace '(?i)%USERPROFILE%', $profile
                    $desk = [Environment]::ExpandEnvironmentVariables($raw)
                    if ($desk -match '%' -or -not (Test-Path -LiteralPath $desk)) { $desk = $null }   # e.g. %OneDrive% only exists in THEIR session
                }
                $k.Close()
            }
        } catch {}
        if (-not $desk) { $desk = Join-Path $profile 'Desktop' }
        if (-not (Test-Path -LiteralPath $desk)) { return $null }
        return [pscustomobject]@{ Path = $desk; Who = $pick.Who }
    } catch { return $null }
}

$outRootNote = "the -OutRoot you passed"
if (-not $OutRoot) {
    $iud = Get-InteractiveUserDesktop
    if ($iud) {
        $OutRoot = Join-Path $iud.Path "RemoteDiagLogs"
        $outRootNote = "the Desktop of $($iud.Who), who is logged in at this machine"
    } else {
        # Nobody's Explorer found (nobody logged in, or not readable) - the Public desktop is
        # merged onto every account's desktop, so it is still somewhere findable.
        $OutRoot = "$env:PUBLIC\Desktop\RemoteDiagLogs"
        $outRootNote = "the Public desktop (could not tell who is logged in)"
        if (-not (Test-Path -LiteralPath "$env:PUBLIC\Desktop")) { $OutRoot = "C:\RemoteDiagLogs"; $outRootNote = "C:\" }
    }
}
Write-Host "Output goes to: $OutRoot" -ForegroundColor Cyan
Write-Host "  ($outRootNote)" -ForegroundColor Cyan

# Create $OutRoot up front (even before the transcript starts) so the transcript
# and the eventual zip can both live alongside the run folder in the same place -
# see the $OutRoot param comment for why this isn't $env:USERPROFILE\Desktop.
try { New-Item -Path $OutRoot -ItemType Directory -Force -ErrorAction Stop | Out-Null } catch {}
$transcriptPath = Join-Path $OutRoot "pull-local-logs_$(Get-Date -Format 'yyyy-MM-dd_HHmmss').log"
try { Start-Transcript -Path $transcriptPath -Force | Out-Null } catch {}

try {
    Clear-Host
    Write-Host "=================================================" -ForegroundColor Cyan
    Write-Host "   Local Diagnostic Puller" -ForegroundColor Cyan
    Write-Host "   (event logs, BSODs, GPU/TDR, print, network, crash dumps - runs right here)" -ForegroundColor Cyan
    Write-Host "=================================================" -ForegroundColor Cyan
    Write-Host ""

    $ComputerName = $env:COMPUTERNAME

    # --- How far back? ---
    $Hours = Resolve-PullHours -Requested $Hours
    $startTime = (Get-Date).AddHours(-$Hours)

    # Read events one at a time via the low-level .NET reader instead of
    # Get-WinEvent's own pipeline - same reasoning as pull-remote-logs.ps1:
    # Get-WinEvent -FilterHashtable eagerly formats every record's message as
    # it enumerates, and if even one record's provider has a missing/
    # mismatched message-resource DLL, it throws and the ENTIRE query comes
    # back empty, discarding good records along with the one bad one. This
    # can happen locally too (rarer, but possible), so use the same safe
    # reader here rather than assuming local reads are immune.
    function Get-LocalEventsSafe {
        param([string]$LogName, [datetime]$StartTime)

        $isoTime = $StartTime.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffffffZ")
        $xpath = "*[System[TimeCreated[@SystemTime>='$isoTime']]]"
        $query = New-Object System.Diagnostics.Eventing.Reader.EventLogQuery($LogName, [System.Diagnostics.Eventing.Reader.PathType]::LogName, $xpath)

        $reader = New-Object System.Diagnostics.Eventing.Reader.EventLogReader($query)
        $results = @()
        $skipped = 0
        try {
            $rec = $reader.ReadEvent()
            while ($null -ne $rec) {
                try {
                    $msg = $null
                    try { $msg = $rec.FormatDescription() } catch { $msg = "[message text unavailable: $($_.Exception.Message)]"; $skipped++ }
                    $level = $null
                    try { $level = $rec.LevelDisplayName } catch { $level = "Level$($rec.Level)" }
                    $results += [PSCustomObject]@{
                        TimeCreated      = if ($rec.TimeCreated) { Format-DT $rec.TimeCreated } else { "" }
                        LevelDisplayName = $level
                        Id               = $rec.Id
                        ProviderName     = $rec.ProviderName
                        Message          = $msg
                    }
                } finally {
                    $rec.Dispose()
                }
                $rec = $reader.ReadEvent()
            }
        } finally {
            $reader.Dispose()
        }
        [PSCustomObject]@{ Events = $results; SkippedMessageCount = $skipped }
    }

    $isAdminForDumps = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

    # Print Service has TWO logs: PrintService/Admin (spooler/driver-level
    # errors, enabled by default) and PrintService/Operational (per-job detail
    # - job submitted/spooled/printed/deleted - which Windows leaves DISABLED
    # by default). Without this, print troubleshooting has no job-level trail
    # at all, only whatever leaked into System/Application. Turn Operational on
    # here (needs admin) so it's capturing before the rest of the pull runs.
    $printAdminLog = "Microsoft-Windows-PrintService/Admin"
    $printOperationalLog = "Microsoft-Windows-PrintService/Operational"
    Write-Host "`n--- Print Service log ---" -ForegroundColor DarkCyan
    $printOpNote = $null
    try {
        $printOpInfo = Get-WinEvent -ListLog $printOperationalLog -ErrorAction Stop
        if (-not $printOpInfo.IsEnabled) {
            if ($isAdminForDumps) {
                try {
                    $printCfg = New-Object System.Diagnostics.Eventing.Reader.EventLogConfiguration($printOperationalLog)
                    $printCfg.IsEnabled = $true
                    $printCfg.SaveChanges()
                    Write-Host "  Was disabled (Windows default for this log) - enabled it now." -ForegroundColor Yellow
                    Write-Host "  Only events from this moment forward are captured - if this pull doesn't show the print failure, reproduce it now and re-run." -ForegroundColor Yellow
                    $printOpNote = "Was disabled (Windows default) - enabled by this run. Only events from the moment of enabling forward are captured; if nothing useful shows up below, reproduce the print job and re-run."
                } catch {
                    Write-Host "  Disabled, and could not enable it: $($_.Exception.Message)" -ForegroundColor Yellow
                    $printOpNote = "Disabled (Windows default), and this run could not enable it: $($_.Exception.Message)"
                }
            } else {
                Write-Host "  Disabled (Windows default) and this run isn't elevated - re-run as Administrator to enable it and capture per-job print detail." -ForegroundColor Yellow
                $printOpNote = "Disabled (Windows default) - re-run elevated to enable it and capture per-job print detail (this log doesn't turn itself on)."
            }
        } else {
            Write-Host "  Already enabled." -ForegroundColor Green
        }
    } catch {
        Write-Host "  Could not check: $($_.Exception.Message)" -ForegroundColor Yellow
        $printOpNote = "Could not check/enable: $($_.Exception.Message)"
    }

    # --- Pull the logs ---
    $stamp = Get-Date -Format "yyyy-MM-dd_HHmm"
    $outDir = Join-Path $OutRoot "$ComputerName`_LOCAL_$stamp"
    New-Item -Path $outDir -ItemType Directory -Force | Out-Null

    # KEEP THIS LIST IDENTICAL TO pull-remote-logs.ps1's $logs. The two tools are meant to
    # give the exact same story whether you're standing at the machine or pulling it over
    # the network - never add a log to one without adding it to the other in the same edit.
    # The two SmbClient channels hold the SMB client's actual reason for a failed share
    # connection (name not resolved, guest logon rejected, signing/auth failure...) - the
    # plain System log only shows the aftermath (e.g. mrxsmb "Delayed Write Failed").
    $smbConnectivityLog = "Microsoft-Windows-SmbClient/Connectivity"
    $smbSecurityLog = "Microsoft-Windows-SmbClient/Security"
    $logs = @("System", "Application", $printAdminLog, $printOperationalLog, $smbConnectivityLog, $smbSecurityLog)
    $allEvents = @()
    $pullStatus = @()

    foreach ($log in $logs) {
        $safeLogName = $log -replace '[\\/]', '_'
        Write-Host "`n--- $log log ---" -ForegroundColor DarkCyan

        Write-Host "  Checking log availability..." -NoNewline
        $logInfo = $null
        $logInfoError = $null
        try {
            $logInfo = Get-WinEvent -ListLog $log -ErrorAction Stop
            Write-Host " OK (enabled=$($logInfo.IsEnabled), records currently on this machine=$($logInfo.RecordCount))" -ForegroundColor Green
        } catch {
            $logInfoError = "$($_.Exception.GetType().FullName): $($_.Exception.Message)"
            Write-Host " FAILED" -ForegroundColor Red
            Write-Host "  $logInfoError" -ForegroundColor Red
        }

        Write-Host "  Pulling events (last $Hours hours)..." -NoNewline
        $pullError = $null
        $pullErrorType = $null
        $eventCount = 0
        try {
            $pullResult = Get-LocalEventsSafe -LogName $log -StartTime $startTime
            $events = $pullResult.Events

            if ($events.Count -gt 0) {
                $events | Export-Csv -Path (Join-Path $outDir "$safeLogName.csv") -NoTypeInformation -Encoding UTF8
                $allEvents += $events | Select-Object @{N='Log';E={$log}}, TimeCreated, LevelDisplayName, Id, ProviderName, Message
            }
            $eventCount = $events.Count
            Write-Host " $eventCount events -> $safeLogName.csv" -ForegroundColor Green
            if ($pullResult.SkippedMessageCount -gt 0) {
                Write-Host "  NOTE: $($pullResult.SkippedMessageCount) record(s) had unrenderable message text (missing/mismatched provider resource DLL) - kept the record with a placeholder instead of dropping it or the rest of the batch." -ForegroundColor Yellow
            }
            if ($eventCount -eq 0 -and $logInfo -and $logInfo.RecordCount -gt 0) {
                Write-Host "  NOTE: this machine reports $($logInfo.RecordCount) total records in this log, just none in the last $Hours hours. Try a longer -Hours window if you expected events here." -ForegroundColor Yellow
            }
        } catch {
            $pullErrorType = $_.Exception.GetType().FullName
            $pullError = $_.Exception.Message
            Write-Host " FAILED" -ForegroundColor Red
            Write-Host "  [$pullErrorType]" -ForegroundColor Red
            Write-Host "  $pullError" -ForegroundColor Red
            if ($pullError -match "being cleared|log file is corrupt") {
                Write-Host "  -> This log may have just been cleared or is corrupt." -ForegroundColor Red
            }
        }

        $pullStatus += [PSCustomObject]@{
            Log               = $log
            TargetEnabled     = if ($logInfo) { $logInfo.IsEnabled } else { "unknown" }
            TargetRecordCount = if ($logInfo) { $logInfo.RecordCount } else { "unknown" }
            ListLogError      = $logInfoError
            EventsPulled      = $eventCount
            PullErrorType     = $pullErrorType
            PullError         = $pullError
        }
    }

    # --- GPU/driver inventory, TDR settings, crash dumps, live GPU tools ---
    # This whole section needs admin (reading dump files, some registry keys);
    # event log collection above works without it, so a non-elevated run still
    # gets the core story, just not this deeper layer.
    Write-Host "`n--- GPU / crash dump artifacts ---" -ForegroundColor DarkCyan
    $gpuInfoLines = @()
    $tdrLines = @()
    $dumpConfigNote = "not checked (not elevated)"
    $minidumpCount = 0; $minidumpSizeMB = 0
    $liveKernelCount = 0; $liveKernelSizeMB = 0; $liveKernelSkipped = @()
    $werQueueFolders = @()
    $fullDumpIncluded = $false; $fullDumpSizeGB = 0; $fullDumpFound = $false
    $nvSmiNote = ""
    $dxDiagNote = ""
    $maxCopyMB = 50   # per-file cap for LiveKernelReports (which can contain larger files than plain Minidump) - bigger files are noted, not copied

    if (-not $isAdminForDumps) {
        Write-Host "  Skipped - this whole section needs admin rights (event logs above don't)." -ForegroundColor Yellow
        Write-Host "  Re-run elevated (right-click > Run as Administrator) for GPU/dump artifacts." -ForegroundColor Yellow
    } else {
        # GPU hardware / driver inventory
        Write-Host "  Capturing GPU hardware/driver inventory..." -NoNewline
        try {
            $gpus = Get-CimInstance -ClassName Win32_VideoController -ErrorAction Stop
            foreach ($g in $gpus) {
                $driverDate = "unknown"
                if ($g.DriverDate) {
                    try { $driverDate = ([Management.ManagementDateTimeConverter]::ToDateTime($g.DriverDate)).ToString("yyyy-MM-dd") }
                    catch { $driverDate = "$($g.DriverDate)" }
                }
                $vramMB = if ($g.AdapterRAM) { [Math]::Round($g.AdapterRAM / 1MB) } else { "unknown" }
                $gpuInfoLines += "Name:             $($g.Name)"
                $gpuInfoLines += "Driver version:   $($g.DriverVersion)"
                $gpuInfoLines += "Driver date:      $driverDate"
                $gpuInfoLines += "Video processor:  $($g.VideoProcessor)"
                $gpuInfoLines += "VRAM (reported):  $vramMB MB (WMI under-reports VRAM on many cards above ~4GB - a known WMI limitation, not a real card spec)"
                $gpuInfoLines += "PNP Device ID:    $($g.PNPDeviceID)"
                $gpuInfoLines += "Status:           $($g.Status)"
                $gpuInfoLines += ""
            }
            Write-Host " found $($gpus.Count) adapter(s)" -ForegroundColor Green
        } catch {
            $gpuInfoLines += "FAILED to query GPU inventory: $($_.Exception.Message)"
            Write-Host " FAILED" -ForegroundColor Red
        }

        # TDR (Timeout Detection & Recovery) registry settings
        Write-Host "  Checking TDR registry settings..." -NoNewline
        try {
            $tdrPath = "HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers"
            if (Test-Path $tdrPath) {
                $tdr = Get-ItemProperty -Path $tdrPath -ErrorAction SilentlyContinue
                $tdrLines += "TdrLevel:      $(if ($null -ne $tdr.TdrLevel) { $tdr.TdrLevel } else { '(not set - OS default: 3, full recovery)' })"
                $tdrLines += "TdrDelay:      $(if ($null -ne $tdr.TdrDelay) { "$($tdr.TdrDelay) sec" } else { '(not set - OS default: 2 sec)' })"
                $tdrLines += "TdrDdiDelay:   $(if ($null -ne $tdr.TdrDdiDelay) { "$($tdr.TdrDdiDelay) sec" } else { '(not set)' })"
                $tdrLines += "TdrLimitTime:  $(if ($null -ne $tdr.TdrLimitTime) { $tdr.TdrLimitTime } else { '(not set)' })"
                $tdrLines += "TdrLimitCount: $(if ($null -ne $tdr.TdrLimitCount) { $tdr.TdrLimitCount } else { '(not set)' })"
            } else {
                $tdrLines += "GraphicsDrivers registry key not found - all TDR settings at OS defaults (TdrLevel=3, TdrDelay=2s)."
            }
            Write-Host " done" -ForegroundColor Green
        } catch {
            $tdrLines += "FAILED to read TDR settings: $($_.Exception.Message)"
            Write-Host " FAILED" -ForegroundColor Red
        }

        # Dump type configuration - so an empty Minidump folder isn't mistaken
        # for "no crashes" when dumps are simply disabled on this machine.
        try {
            $crashControl = Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl" -ErrorAction Stop
            $dumpTypeNames = @{0='None (dumps disabled)';1='Complete memory dump';2='Kernel memory dump';3='Small memory dump (minidump)';7='Automatic memory dump'}
            $dumpConfigNote = if ($dumpTypeNames.ContainsKey([int]$crashControl.CrashDumpEnabled)) { $dumpTypeNames[[int]$crashControl.CrashDumpEnabled] } else { "Unknown ($($crashControl.CrashDumpEnabled))" }
            Write-Host "  Dump type configured on this machine: $dumpConfigNote" -ForegroundColor Cyan
        } catch { $dumpConfigNote = "Could not read CrashControl registry key" }

        # Minidumps - small (~256KB-2MB each), always safe to grab.
        $minidumpSrc = "$env:SystemRoot\Minidump"
        $minidumpFiles = if (Test-Path $minidumpSrc) { Get-ChildItem $minidumpSrc -Filter *.dmp -ErrorAction SilentlyContinue } else { @() }
        if ($minidumpFiles.Count -gt 0) {
            $dumpOutDir = Join-Path $outDir "Minidumps"
            New-Item -Path $dumpOutDir -ItemType Directory -Force | Out-Null
            Copy-Item -Path $minidumpFiles.FullName -Destination $dumpOutDir -Force -ErrorAction SilentlyContinue
            $minidumpCount = $minidumpFiles.Count
            $minidumpSizeMB = [math]::Round(($minidumpFiles | Measure-Object Length -Sum).Sum/1MB,1)
            Write-Host "  Minidumps: $minidumpCount copied ($minidumpSizeMB MB) -> Minidumps\" -ForegroundColor Green
        } else {
            Write-Host "  Minidumps: none found in $minidumpSrc" -ForegroundColor Yellow
        }

        # Full LiveKernelReports tree (not just WATCHDOG) - covers TDR/GPU
        # watchdog dumps plus any other subsystem's live-kernel crash reports.
        # Per-file size cap since this tree can hold larger files than plain
        # Minidump; anything over the cap is noted instead of copied.
        $liveKernelSrc = "$env:SystemRoot\LiveKernelReports"
        $liveKernelFiles = if (Test-Path $liveKernelSrc) { Get-ChildItem $liveKernelSrc -Recurse -File -ErrorAction SilentlyContinue } else { @() }
        if ($liveKernelFiles.Count -gt 0) {
            $liveKernelOutDir = Join-Path $outDir "GPU_TDR_Dumps"
            New-Item -Path $liveKernelOutDir -ItemType Directory -Force | Out-Null
            foreach ($f in $liveKernelFiles) {
                $sizeMB = [Math]::Round($f.Length / 1MB, 2)
                if ($sizeMB -le $maxCopyMB) {
                    Copy-Item -Path $f.FullName -Destination (Join-Path $liveKernelOutDir $f.Name) -Force -ErrorAction SilentlyContinue
                    $liveKernelCount++
                    $liveKernelSizeMB += $sizeMB
                } else {
                    $liveKernelSkipped += "$($f.Name) ($sizeMB MB > $maxCopyMB MB cap) - grab by hand from $($f.FullName) if needed"
                }
            }
            $liveKernelSizeMB = [math]::Round($liveKernelSizeMB, 1)
            Write-Host "  GPU/TDR (LiveKernelReports) dumps: $liveKernelCount copied ($liveKernelSizeMB MB) -> GPU_TDR_Dumps\$(if ($liveKernelSkipped.Count -gt 0) { ", $($liveKernelSkipped.Count) skipped (too large)" })" -ForegroundColor Green
        } else {
            Write-Host "  GPU/TDR dumps: none found (no graphics-driver-timeout or other live-kernel crashes recorded)" -ForegroundColor Yellow
        }

        # WER ReportQueue folders matching GPU/kernel-relevant names (metadata only)
        $werQueuePath = "$env:ProgramData\Microsoft\Windows\WER\ReportQueue"
        try {
            if (Test-Path $werQueuePath) {
                $werQueueFolders = Get-ChildItem -Path $werQueuePath -Directory -ErrorAction Stop |
                    Where-Object { $_.Name -match 'Kernel_|Display|nvlddmkm|dxgkrnl|amdkmdap' }
            }
            Write-Host "  WER ReportQueue: $($werQueueFolders.Count) matching folder(s) (metadata only, not copied)" -ForegroundColor Green
        } catch {
            Write-Host "  WER ReportQueue: FAILED - $($_.Exception.Message)" -ForegroundColor Yellow
        }

        # Full memory dump - opt-in, can be several GB. Only the most recent
        # crash, and overwritten by the next one, so ask before including it.
        $memDumpPath = "$env:SystemRoot\MEMORY.DMP"
        if (Test-Path $memDumpPath) {
            $fullDumpFound = $true
            $fullDumpSizeGB = [math]::Round((Get-Item $memDumpPath).Length/1GB,2)
            Write-Host "  Full memory dump found: $fullDumpSizeGB GB" -ForegroundColor Yellow
            $doInclude = [bool]$IncludeFullDump
            if (-not $doInclude -and -not $NoFullDump) {
                $ans = Read-Host "  Include the full memory dump too? Adds $fullDumpSizeGB GB and takes longer to copy/zip [y/N]"
                $doInclude = ($ans -match '^[Yy]')
            }
            if ($doInclude) {
                Write-Host "  Copying full memory dump (this may take a while)..." -NoNewline
                Copy-Item -Path $memDumpPath -Destination $outDir -Force -ErrorAction SilentlyContinue
                $fullDumpIncluded = $true
                Write-Host " done" -ForegroundColor Green
            } else {
                Write-Host "  Skipped - still at $memDumpPath on this machine if needed later." -ForegroundColor Yellow
            }
        } else {
            Write-Host "  No full memory dump present (normal if dump type above is minidump-only)." -ForegroundColor Yellow
        }

        # Live NVIDIA state, if this is an NVIDIA card
        Write-Host "  Looking for nvidia-smi (live NVIDIA GPU state)..." -NoNewline
        $nvSmiCmd = Get-Command nvidia-smi.exe -ErrorAction SilentlyContinue
        if (-not $nvSmiCmd) {
            $candidate = "$env:SystemRoot\System32\nvidia-smi.exe"
            if (Test-Path $candidate) { $nvSmiCmd = Get-Item $candidate }
        }
        if ($nvSmiCmd) {
            try {
                $nvPath = if ($nvSmiCmd.Source) { $nvSmiCmd.Source } else { $nvSmiCmd.FullName }
                $nvOut = & $nvPath -q 2>&1
                $nvOut | Set-Content -Path (Join-Path $outDir "NvidiaSmi.txt") -Encoding UTF8
                Write-Host " found, captured full query -> NvidiaSmi.txt" -ForegroundColor Green
                $nvSmiNote = "nvidia-smi captured (NvidiaSmi.txt) - check Temperature, Clocks Throttle Reasons, and ECC Errors there for current GPU health."
            } catch {
                Write-Host " found but failed to run: $($_.Exception.Message)" -ForegroundColor Yellow
                $nvSmiNote = "nvidia-smi was found but failed to run: $($_.Exception.Message)"
            }
        } else {
            Write-Host " not found (not an NVIDIA GPU, or drivers were installed without it)" -ForegroundColor Yellow
            $nvSmiNote = "nvidia-smi not found - either not an NVIDIA GPU, or the driver package didn't include it."
        }

        # dxdiag Display Devices section
        Write-Host "  Running dxdiag (Display Devices section)..." -NoNewline
        try {
            $dxTemp = Join-Path $env:TEMP "dxdiag_$stamp.txt"
            Start-Process -FilePath "dxdiag.exe" -ArgumentList "/t `"$dxTemp`"" -Wait -WindowStyle Hidden
            Start-Sleep -Seconds 1
            if (Test-Path $dxTemp) {
                Copy-Item -Path $dxTemp -Destination (Join-Path $outDir "DxDiag_Full.txt") -Force
                $dxContent = Get-Content -Path $dxTemp -Raw
                $displaySections = [regex]::Matches($dxContent, '(?ms)^-{2,}\s*\r?\nDisplay Devices\s*\r?\n-{2,}\s*\r?\n.*?(?=^-{2,}\s*\r?\n\S.*\r?\n-{2,}|\z)')
                if ($displaySections.Count -gt 0) {
                    ($displaySections | ForEach-Object { $_.Value }) -join "`n`n" | Set-Content -Path (Join-Path $outDir "DxDiag_Display.txt") -Encoding UTF8
                    Write-Host " done -> DxDiag_Display.txt (+ full DxDiag_Full.txt)" -ForegroundColor Green
                    $dxDiagNote = "dxdiag captured - see DxDiag_Display.txt for driver version/date/WHQL status and any Notes dxdiag itself flagged."
                } else {
                    Write-Host " ran, but couldn't isolate the Display Devices section - see DxDiag_Full.txt" -ForegroundColor Yellow
                    $dxDiagNote = "dxdiag captured but the Display Devices section couldn't be auto-isolated - see DxDiag_Full.txt directly."
                }
            } else {
                Write-Host " FAILED (no output file produced)" -ForegroundColor Red
                $dxDiagNote = "dxdiag did not produce an output file."
            }
        } catch {
            Write-Host " FAILED: $($_.Exception.Message)" -ForegroundColor Red
            $dxDiagNote = "dxdiag failed to run: $($_.Exception.Message)"
        }
    }

    # Persist the per-log diagnostic detail regardless of what happened above,
    # so "why is a log missing" is always answerable from the output folder.
    $statusPath = Join-Path $outDir "LogPullStatus.txt"
    $statusLines = @("Log Pull Status (local)", "=======================", "Computer: $ComputerName   Window: $(Format-DT $startTime) to $(Format-DT (Get-Date))", "")
    foreach ($s in $pullStatus) {
        $statusLines += "[$($s.Log)]"
        $statusLines += "  Log enabled:              $($s.TargetEnabled)"
        $statusLines += "  Total records:            $($s.TargetRecordCount)"
        if ($s.ListLogError) { $statusLines += "  ListLog check error:     $($s.ListLogError)" }
        $statusLines += "  Events pulled in window: $($s.EventsPulled)"
        if ($s.PullError) {
            $statusLines += "  Pull error type:         $($s.PullErrorType)"
            $statusLines += "  Pull error:              $($s.PullError)"
        }
        $statusLines += ""
    }
    $statusLines -join "`n" | Set-Content -Path $statusPath -Encoding UTF8

    if ($allEvents.Count -eq 0) {
        Write-Host "`nNo events retrieved - nothing to save. See LogPullStatus.txt for why." -ForegroundColor Yellow
        exit 1
    }

    # --- BSOD / unexpected-shutdown analysis ---
    Write-Host "`nChecking for BSODs and unexpected shutdowns..." -NoNewline

    $bugcheckNames = @{
        '0x1'   = 'APC_INDEX_MISMATCH'
        '0xa'   = 'IRQL_NOT_LESS_OR_EQUAL (often a bad/incompatible driver)'
        '0x19'  = 'BAD_POOL_HEADER (memory corruption, often a driver)'
        '0x1a'  = 'MEMORY_MANAGEMENT (often faulty RAM)'
        '0x1e'  = 'KMODE_EXCEPTION_NOT_HANDLED (driver or hardware)'
        '0x3b'  = 'SYSTEM_SERVICE_EXCEPTION (often a driver)'
        '0x44'  = 'MULTIPLE_IRP_COMPLETE_REQUESTS (driver bug)'
        '0x4e'  = 'PFN_LIST_CORRUPT (often faulty RAM)'
        '0x50'  = 'PAGE_FAULT_IN_NONPAGED_AREA (driver or faulty RAM)'
        '0x7e'  = 'SYSTEM_THREAD_EXCEPTION_NOT_HANDLED (driver or hardware)'
        '0x8e'  = 'KERNEL_MODE_EXCEPTION_NOT_HANDLED (driver or hardware)'
        '0x9f'  = 'DRIVER_POWER_STATE_FAILURE (driver, often around sleep/wake)'
        '0xa0'  = 'INTERNAL_POWER_ERROR'
        '0xc2'  = 'BAD_POOL_CALLER (driver bug)'
        '0xd1'  = 'DRIVER_IRQL_NOT_LESS_OR_EQUAL (bad driver, often network/storage)'
        '0xef'  = 'CRITICAL_PROCESS_DIED'
        '0x116' = 'VIDEO_TDR_FAILURE (graphics driver/GPU)'
        '0x117' = 'VIDEO_TDR_TIMEOUT_DETECTED (graphics driver/GPU, timed out during recovery)'
        '0x119' = 'VIDEO_SCHEDULER_INTERNAL_ERROR (graphics driver/GPU)'
        '0x10e' = 'VIDEO_MEMORY_MANAGEMENT_INTERNAL (graphics driver/GPU)'
        '0x141' = 'VIDEO_HUNG_DISPLAY_DRIVER_THREAD (graphics driver/GPU)'
        '0x124' = 'WHEA_UNCORRECTABLE_ERROR (hardware: CPU, RAM, or PSU/thermal)'
        '0x133' = 'DPC_WATCHDOG_VIOLATION (often a stuck driver, sometimes storage)'
        '0x139' = 'KERNEL_SECURITY_CHECK_FAILURE (corruption or driver bug)'
        '0x1000007e' = 'SYSTEM_THREAD_EXCEPTION_NOT_HANDLED (driver or hardware)'
    }

    # Windows always zero-pads bugcheck codes to 8 hex digits (e.g. 0x00000116), but the
    # table above uses unpadded keys (0x116) for readability - normalize before lookup or
    # every code silently misses and falls through to "Unknown code".
    function Get-NormalizedBugcheckCode([string]$code) {
        if ($code -match '^0x0*([0-9a-fA-F]+)$') { return "0x$($matches[1].ToLower())" }
        return $code.ToLower()
    }

    $bsodEvents = $allEvents | Where-Object { $_.Log -eq 'System' -and $_.Id -eq '1001' -and $_.ProviderName -match 'WER-SystemErrorReporting' }
    $abruptShutdowns = $allEvents | Where-Object { $_.Log -eq 'System' -and $_.Id -eq '41' -and $_.ProviderName -match 'Kernel-Power' }
    # A second, separate event Windows logs for the same bugcheck - often names the faulting
    # driver by file name outright ("Possibly related driver: nvlddmkm.sys"), which the 1001
    # event above never includes. Free, high-value signal - worth surfacing when it's there.
    $relatedDriverEvents = $allEvents | Where-Object { $_.Log -eq 'System' -and $_.Id -eq '1019' -and $_.ProviderName -match 'WER-SystemErrorReporting' }

    $bsodRows = @(foreach ($b in $bsodEvents) {
        $code = $null; $params = $null; $dumpPath = $null
        if ($b.Message -match 'bugcheck was:\s*(0x[0-9a-fA-F]+)\s*\(([^)]*)\)') {
            $code = $matches[1]; $params = $matches[2]
        }
        if ($b.Message -match 'dump was saved in:\s*([^\r\n]+?)\.?\s*$') { $dumpPath = $matches[1] }
        $friendly = if ($code -and $bugcheckNames.ContainsKey((Get-NormalizedBugcheckCode $code))) { $bugcheckNames[(Get-NormalizedBugcheckCode $code)] } elseif ($code) { "Unknown code - look up $code at learn.microsoft.com/windows-hardware/drivers/debugger/bug-check-code-reference2" } else { "(could not parse bugcheck code from event text)" }

        $bt = [datetime]$b.TimeCreated
        $relatedDriver = $null
        $rd = $relatedDriverEvents | Where-Object { [Math]::Abs((([datetime]$_.TimeCreated) - $bt).TotalMinutes) -le 2 } | Select-Object -First 1
        if ($rd -and $rd.Message -match 'Possibly related driver:\s*([^\.\r\n]+\.\w+)') { $relatedDriver = $matches[1] }

        [PSCustomObject]@{
            TimeCreated = $b.TimeCreated
            BugcheckCode = $code
            Parameters   = $params
            Meaning      = $friendly
            DumpFile     = $dumpPath
            RelatedDriver = $relatedDriver
        }
    })

    $unexplained = @(foreach ($u in $abruptShutdowns) {
        $t = [datetime]$u.TimeCreated
        $match = $bsodEvents | Where-Object { [Math]::Abs((([datetime]$_.TimeCreated) - $t).TotalMinutes) -le 5 }
        if (-not $match) {
            [PSCustomObject]@{ TimeCreated = $u.TimeCreated; Note = "Unexpected shutdown with NO matching bugcheck - not a Windows-detected crash. Likely power loss, a hard freeze someone had to hold-the-button on, or a thermal/PSU cutout." }
        }
    })

    if ($bsodEvents.Count -eq 0 -and $abruptShutdowns.Count -eq 0) {
        Write-Host " none found" -ForegroundColor Green
    } else {
        Write-Host " found $($bsodEvents.Count) BSOD(s), $($abruptShutdowns.Count) unexpected shutdown(s)" -ForegroundColor Red
    }

    if ($pullStatus | Where-Object { $_.Log -eq 'System' -and $_.EventsPulled -eq 0 }) {
        Write-Host " NOTE: System log had 0 events pulled - BSOD check above has nothing to work with, it is NOT a confirmed clean result. See LogPullStatus.txt." -ForegroundColor Red
    }

    $bsodReportPath = Join-Path $outDir "BSOD_Report.txt"
    $bsodReportLines = @()
    $bsodReportLines += "BSOD / Unexpected Shutdown Report (local pull)"
    $bsodReportLines += "==============================================="
    $bsodReportLines += "Computer: $ComputerName    Window: $(Format-DT $startTime) to $(Format-DT (Get-Date))"
    $bsodReportLines += ""
    if ($pullStatus | Where-Object { $_.Log -eq 'System' -and $_.EventsPulled -eq 0 }) {
        $bsodReportLines += "WARNING: 0 System log events were pulled for this window - see LogPullStatus.txt for why."
        $bsodReportLines += "The results below are NOT a confirmed clean bill of health, they're an empty search."
        $bsodReportLines += ""
    }
    if ($bsodRows) {
        $bsodReportLines += "--- Bugchecks (actual BSODs) ---"
        foreach ($r in $bsodRows) {
            $bsodReportLines += "$($r.TimeCreated)  Code: $($r.BugcheckCode)  Params: $($r.Parameters)"
            $bsodReportLines += "  Meaning: $($r.Meaning)"
            if ($r.RelatedDriver) { $bsodReportLines += "  Windows names the likely faulting driver: $($r.RelatedDriver)" }
            if ($r.DumpFile) { $bsodReportLines += "  Dump file on this machine: $($r.DumpFile)" }
            $bsodReportLines += ""
        }
    } else {
        $bsodReportLines += "No bugchecks (BSODs) found in this window."
        $bsodReportLines += ""
    }
    if ($unexplained) {
        $bsodReportLines += "--- Unexplained abrupt shutdowns (no bugcheck logged) ---"
        foreach ($u in $unexplained) { $bsodReportLines += "$($u.TimeCreated)  $($u.Note)" }
    } else {
        $bsodReportLines += "No unexplained abrupt shutdowns found in this window."
    }
    $bsodReportLines -join "`n" | Set-Content -Path $bsodReportPath -Encoding UTF8

    # --- GPU event correlation report (reuses $allEvents - no second query needed) ---
    Write-Host "Building GPU correlation report..." -NoNewline
    $gpuProviders = @('nvlddmkm', 'amdkmdap', 'amdkmdag', 'amdkmdag64', 'igfx', 'igfxn', 'Display', 'Microsoft-Windows-DxgKrnl')
    $gpuOnlyEvents = $allEvents | Where-Object { $_.Log -eq 'System' -and $gpuProviders -contains $_.ProviderName }
    $werAppEvents = $allEvents | Where-Object { $_.Log -eq 'Application' -and $_.Id -eq '1001' -and $_.ProviderName -match 'Windows Error Reporting' }

    $eventMeanings = @{
        'nvlddmkm|13'  = 'TDR: NVIDIA display driver stopped responding and recovered (timeout)'
        'nvlddmkm|14'  = 'NVIDIA kernel-mode driver error (message text often unrenderable locally - the event itself still means a driver-level fault occurred)'
        'amdkmdap|3'   = 'AMD display driver TDR event'
        'amdkmdag|3'   = 'AMD display driver TDR event'
        'Display|4101' = 'TDR: display driver stopped responding and has recovered'
    }

    $gpuReportLines = @()
    $gpuReportLines += "GPU / Display Crash Report (local pull)"
    $gpuReportLines += "========================================"
    $gpuReportLines += "Computer: $ComputerName    Window: $(Format-DT $startTime) to $(Format-DT (Get-Date))"
    $gpuReportLines += ""
    $gpuReportLines += "--- GPU hardware / driver inventory ---"
    $gpuReportLines += $(if ($gpuInfoLines.Count -gt 0) { $gpuInfoLines } else { "(not collected - not elevated)" })
    $gpuReportLines += "--- TDR (Timeout Detection & Recovery) registry settings ---"
    $gpuReportLines += $(if ($tdrLines.Count -gt 0) { $tdrLines } else { "(not collected - not elevated)" })
    $gpuReportLines += ""

    $gpuReportLines += "--- GPU/display driver events in System log ($($gpuOnlyEvents.Count) found) ---"
    if ($gpuOnlyEvents.Count -gt 0) {
        foreach ($e in ($gpuOnlyEvents | Sort-Object TimeCreated)) {
            $key = "$($e.ProviderName)|$($e.Id)"
            $meaning = if ($eventMeanings.ContainsKey($key)) { $eventMeanings[$key] } else { "(see raw message in System.csv)" }
            $line = "$($e.TimeCreated)  [$($e.LevelDisplayName)] $($e.ProviderName) (Id $($e.Id)) - $meaning"
            $gt = [datetime]$e.TimeCreated
            $nextCrash = $abruptShutdowns | Where-Object { ([datetime]$_.TimeCreated) -ge $gt } | Sort-Object TimeCreated | Select-Object -First 1
            if ($nextCrash) {
                $gap = ([datetime]$nextCrash.TimeCreated) - $gt
                if ($gap.TotalHours -le 6) {
                    $line += " -> followed by an unclean shutdown at $($nextCrash.TimeCreated) ($([Math]::Round($gap.TotalMinutes, 1)) min later)"
                }
            }
            $gpuReportLines += $line
        }
    } else {
        $gpuReportLines += "None found in this window."
    }
    $gpuReportLines += ""

    $gpuReportLines += "--- Windows Error Reporting entries, Application log Id 1001 (non-fatal watchdog/TDR reports): $($werAppEvents.Count) found ---"
    foreach ($w in ($werAppEvents | Sort-Object TimeCreated)) {
        $code = $null
        if ($w.Message -match 'bugcheck was:\s*(0x[0-9a-fA-F]+)') { $code = $matches[1] }
        $subsystem = $null
        if ($w.Message -match 'LiveKernelReports\\([A-Za-z0-9_]+)\\') { $subsystem = $matches[1] }

        $gpuReportLines += "$($w.TimeCreated):"
        if ($code) {
            $friendly = if ($bugcheckNames.ContainsKey((Get-NormalizedBugcheckCode $code))) { $bugcheckNames[(Get-NormalizedBugcheckCode $code)] } else { "code $code - see learn.microsoft.com/windows-hardware/drivers/debugger/bug-check-code-reference2" }
            $gpuReportLines += "  Bugcheck $code - $friendly"
        }
        if ($subsystem) {
            $gpuRelated = $subsystem -match 'DISPLAY|GRAPHICS|DXGKRNL|NVLDDMKM|AMDKMDAP'
            $gpuReportLines += "  LiveKernelReports subsystem: $subsystem $(if ($gpuRelated) { '(GPU-related)' } else { '(not GPU-related)' })"
        }
        if (-not $code -and -not $subsystem) { $gpuReportLines += "  (could not classify - see Application.csv for the raw message)" }
    }
    $gpuReportLines += ""

    $gpuReportLines += "--- Crash dump artifacts ---"
    $gpuReportLines += "Minidump: $minidumpCount file(s) copied ($minidumpSizeMB MB)"
    $gpuReportLines += "LiveKernelReports (GPU/TDR): $liveKernelCount file(s) copied ($liveKernelSizeMB MB)"
    foreach ($skip in $liveKernelSkipped) { $gpuReportLines += "  SKIPPED: $skip" }
    $gpuReportLines += $(if ($fullDumpIncluded) { "Full memory dump: included ($fullDumpSizeGB GB)" } elseif ($fullDumpFound) { "Full memory dump: found but not included ($fullDumpSizeGB GB) - re-run with -IncludeFullDump to grab it" } else { "Full memory dump: not present" })
    $gpuReportLines += "WER ReportQueue folders matching Kernel/Display/nvlddmkm/dxgkrnl/amdkmdap: $($werQueueFolders.Count)"
    foreach ($wf in $werQueueFolders) { $gpuReportLines += "  $($wf.LastWriteTime)  $($wf.Name)" }
    $gpuReportLines += ""

    $gpuReportLines += "--- Live GPU tools ---"
    $gpuReportLines += $(if ($nvSmiNote) { $nvSmiNote } else { "(not checked - not elevated)" })
    $gpuReportLines += $(if ($dxDiagNote) { $dxDiagNote } else { "(not checked - not elevated)" })
    $gpuReportLines += ""

    $gpuReportLines -join "`n" | Set-Content -Path (Join-Path $outDir "GPU_Report.txt") -Encoding UTF8
    Write-Host " done -> GPU_Report.txt" -ForegroundColor Green

    # --- Print Service report (reuses $allEvents - no second query needed) ---
    Write-Host "Building print diagnostic report..." -NoNewline
    $printAdminEvents = $allEvents | Where-Object { $_.Log -eq $printAdminLog }
    $printOpEvents = $allEvents | Where-Object { $_.Log -eq $printOperationalLog }
    $printEvents = $printAdminEvents + $printOpEvents
    $printErrorsWarnings = $printEvents | Where-Object { $_.LevelDisplayName -in @('Error', 'Warning', 'Critical') }
    # Id 307 = "Document N was printed on <printer>..." - the standard per-job
    # completion event in PrintService/Operational, used the same way by
    # Windows' own print-auditing guidance. Other IDs (305 spooled, 306
    # deleted, etc.) are left to the raw CSV rather than guessed at here.
    $printJobsCompleted = $printOpEvents | Where-Object { $_.Id -eq '307' }

    $printReportLines = @()
    $printReportLines += "Print Service Report (local pull)"
    $printReportLines += "===================================="
    $printReportLines += "Computer: $ComputerName    Window: $(Format-DT $startTime) to $(Format-DT (Get-Date))"
    $printReportLines += ""
    $printReportLines += "PrintService/Admin log:       $($printAdminEvents.Count) events pulled"
    $printReportLines += "PrintService/Operational log: $($printOpEvents.Count) events pulled"
    if ($printOpNote) { $printReportLines += "  NOTE: $printOpNote" }
    $printReportLines += ""
    $printReportLines += "--- Errors / Warnings ($($printErrorsWarnings.Count) found) ---"
    if ($printErrorsWarnings.Count -gt 0) {
        foreach ($p in ($printErrorsWarnings | Sort-Object TimeCreated)) {
            $printReportLines += "$($p.TimeCreated)  [$($p.LevelDisplayName)] $($p.Log) (Id $($p.Id))"
            $printReportLines += "  $($p.Message -replace '\r?\n', ' ')"
        }
    } else {
        $printReportLines += "None found in this window."
    }
    $printReportLines += ""
    $printReportLines += "--- Completed print jobs, Operational log Id 307 ($($printJobsCompleted.Count) found) ---"
    if ($printJobsCompleted.Count -gt 0) {
        foreach ($j in ($printJobsCompleted | Sort-Object TimeCreated)) {
            $printReportLines += "$($j.TimeCreated)  $($j.Message -replace '\r?\n', ' ')"
        }
    } else {
        $printReportLines += "None found in this window (either nothing was printed, or the Operational log wasn't capturing yet - see note above)."
    }
    $printReportLines += ""
    $printReportLines += "Full raw detail (every field, every event) is in PrintService_Admin.csv and PrintService_Operational.csv."

    $printReportLines -join "`n" | Set-Content -Path (Join-Path $outDir "Print_Report.txt") -Encoding UTF8
    Write-Host " done -> Print_Report.txt" -ForegroundColor Green

    # --- Network state (ipconfig, DNS, routing, hosts file, proxy, security software) ---
    # Ported from the retired capture-network-state.ps1 (2026-09) - most valuable when
    # pulled WHILE a network problem is still happening (this is live state that
    # disappears on reboot), but costs nothing to capture every run and needs no admin.
    Write-Host "`n--- Network state ---" -ForegroundColor DarkCyan
    $netSb = New-Object System.Text.StringBuilder
    function Add-NetSection($title, $content) {
        [void]$netSb.AppendLine("`n" + ("=" * 70))
        [void]$netSb.AppendLine($title)
        [void]$netSb.AppendLine("=" * 70)
        [void]$netSb.AppendLine(($content | Out-String))
    }

    # Keywords for spotting VPN/filter/firewall/EDR/AV software by process name, install
    # entry, ISP/org name, or certificate subject - grouped by category so it's easy to
    # extend when a new case turns up a product this list doesn't catch yet.
    $securityKeywords = @(
        'crowdstrike', 'falcon', 'mcafee', 'huntress', 'sentinelone', 'sentinel one', 'sophos',
        'carbonblack', 'carbon black', 'cylance', 'cybereason', 'tanium', 'deep instinct',
        'harfanglab', 'qualys', 'rapid7', 'malwarebytes', 'webroot', 'bitdefender', 'kaspersky',
        'avast', 'avg', 'f-secure', 'trendmicro', 'trend micro', 'symantec', 'norton', 'eset',
        'nod32', 'windows defender atp', 'microsoft defender for endpoint', 'cortex xdr',
        'palo alto',
        'opendns', 'umbrella', 'dnsfilter', 'cleanbrowsing', 'netfree', 'techloq', 'circle',
        'net nanny', 'covenant eyes', 'x3watch', 'k9 web',
        'vpn', 'proxy', 'firewall', 'fortinet', 'forticlient', 'checkpoint', 'check point',
        'globalprotect', 'pulse secure', 'anyconnect', 'sonicwall', 'cyberoam', 'zscaler',
        'forcepoint', 'barracuda', 'watchguard', 'netlimiter', 'pihole', 'adguard',
        'nordvpn', 'expressvpn', 'openvpn', 'wireguard', 'tailscale'
    ) -join '|'

    # Public IP + owning ISP/org (2026-09, added after a real case: a filtered-ISP
    # connection [Netfree] was serving the WRONG version of its own root certificate,
    # producing a plain browser "Not Secure" warning that looked like a generic cert
    # problem - the fix was obvious once someone thought to check the ISP, but nobody did
    # until well into the troubleshooting. Checking this up front turns "wild goose chase"
    # into "oh, it's a filtered connection - go check that root cert" in one step.
    # Uses PLAIN HTTP (not HTTPS) on purpose: if a broken/wrong filtering certificate is
    # exactly the problem, an HTTPS call here could fail for the same reason and prove
    # nothing - HTTP has no TLS trust to break.
    $ispFlagNote = $null
    Write-Host "  Looking up public IP and owning ISP/org (flags known content-filtering providers)..." -NoNewline
    try {
        $ipInfo = Invoke-RestMethod -Uri "http://ip-api.com/json/?fields=query,isp,org,as,country,city" -TimeoutSec 8 -ErrorAction Stop
        $ispSummary = "Public IP: $($ipInfo.query)`nISP:       $($ipInfo.isp)`nOrg:       $($ipInfo.org)`nAS:        $($ipInfo.as)`nLocation:  $($ipInfo.city), $($ipInfo.country)"
        $ispMatchText = "$($ipInfo.isp) $($ipInfo.org)"
        if ($ispMatchText -match $securityKeywords) {
            $ispFlagNote = "FLAG: this machine's public IP ($($ipInfo.query)) belongs to '$($ipInfo.isp)' / '$($ipInfo.org)' - a name matching a known content-filtering/VPN/security provider keyword ('$($matches[0])'). Filtered ISPs (e.g. Netfree) intercept HTTPS and re-sign it with their own root certificate - a browser 'Not Secure' warning is the classic symptom of that certificate being missing, expired, or the wrong version on THIS machine. Check the client's installed root certificates by hand (we don't manage that store on client machines the way we do on our own rental fleet, so there's nothing reliable to auto-check here)."
            $ispSummary += "`n`n$ispFlagNote"
            Write-Host " done - FLAGGED (matches '$($matches[0])')" -ForegroundColor Yellow
        } else {
            Write-Host " done" -ForegroundColor Green
        }
        Add-NetSection "Public IP / ISP lookup (via ip-api.com, plain HTTP - works even if HTTPS cert trust is broken)" $ispSummary
    } catch {
        Write-Host " FAILED: $($_.Exception.Message)" -ForegroundColor Yellow
        Add-NetSection "Public IP / ISP lookup (via ip-api.com, plain HTTP)" "FAILED: $($_.Exception.Message) (no external connectivity, or this lookup service is unreachable/blocked)"
    }

    Write-Host "  Capturing IP configuration..." -NoNewline
    Add-NetSection "ipconfig /all" (ipconfig /all)
    Write-Host " done" -ForegroundColor Green

    Write-Host "  Capturing network adapter status..." -NoNewline
    Add-NetSection "Get-NetAdapter" (Get-NetAdapter -ErrorAction SilentlyContinue | Format-Table Name, InterfaceDescription, Status, LinkSpeed, MacAddress -AutoSize)
    Write-Host " done" -ForegroundColor Green

    Write-Host "  Capturing network connection profile (Public/Private/connectivity)..." -NoNewline
    Add-NetSection "Get-NetConnectionProfile" (Get-NetConnectionProfile -ErrorAction SilentlyContinue | Format-List)
    Write-Host " done" -ForegroundColor Green

    Write-Host "  Capturing DNS server config..." -NoNewline
    Add-NetSection "Get-DnsClientServerAddress" (Get-DnsClientServerAddress -ErrorAction SilentlyContinue | Format-Table InterfaceAlias, AddressFamily, ServerAddresses -AutoSize)
    Write-Host " done" -ForegroundColor Green

    Write-Host "  Capturing DNS resolver cache..." -NoNewline
    Add-NetSection "Get-DnsClientCache" (Get-DnsClientCache -ErrorAction SilentlyContinue | Format-Table Entry, Name, Data, Status -AutoSize)
    Write-Host " done" -ForegroundColor Green

    Write-Host "  Capturing routing table..." -NoNewline
    Add-NetSection "Get-NetRoute (IPv4)" (Get-NetRoute -AddressFamily IPv4 -ErrorAction SilentlyContinue | Format-Table DestinationPrefix, NextHop, InterfaceAlias, RouteMetric -AutoSize)
    Write-Host " done" -ForegroundColor Green

    Write-Host "  Capturing ARP table..." -NoNewline
    Add-NetSection "arp -a" (arp -a)
    Write-Host " done" -ForegroundColor Green

    Write-Host "  Testing raw IP reachability (8.8.8.8, bypasses DNS)..." -NoNewline
    Add-NetSection "Ping 8.8.8.8 (raw IP - tests link/routing without DNS)" (Test-Connection -ComputerName 8.8.8.8 -Count 3 -ErrorAction SilentlyContinue | Format-Table)
    Write-Host " done" -ForegroundColor Green

    Write-Host "  Testing DNS resolution (google.com, cloudflare.com, microsoft.com)..." -NoNewline
    $dnsTest = foreach ($d in @("google.com", "cloudflare.com", "microsoft.com")) {
        try { "$d -> " + ((Resolve-DnsName $d -ErrorAction Stop | Select-Object -First 1 -ExpandProperty IPAddress)) }
        catch { "$d -> FAILED: $($_.Exception.Message)" }
    }
    Add-NetSection "DNS resolution test" $dnsTest
    Write-Host " done" -ForegroundColor Green

    Write-Host "  Checking hosts file for blocked/redirected domains..." -NoNewline
    $hostsPath = "$env:SystemRoot\System32\drivers\etc\hosts"
    $hostsActive = Get-Content $hostsPath -ErrorAction SilentlyContinue | Where-Object { $_.Trim() -and -not $_.Trim().StartsWith("#") }
    if ($hostsActive) {
        Add-NetSection "Hosts file - active entries ($hostsPath)" ($hostsActive -join "`n")
    } else {
        Add-NetSection "Hosts file - active entries ($hostsPath)" "(no active entries - only comments/blank lines, or file is default)"
    }
    Write-Host " done" -ForegroundColor Green

    Write-Host "  Checking proxy settings..." -NoNewline
    Add-NetSection "Proxy settings" (@(
        "netsh winhttp show proxy:"
        (netsh winhttp show proxy | Out-String)
        "Internet Settings registry:"
        (Get-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings" -ErrorAction SilentlyContinue | Select-Object ProxyEnable, ProxyServer, AutoConfigURL | Format-List | Out-String)
    ))
    Write-Host " done" -ForegroundColor Green

    Write-Host "  Capturing active TCP connections (watching for local proxy/VPN intercepts)..." -NoNewline
    Add-NetSection "Get-NetTCPConnection (established + listening)" (Get-NetTCPConnection -ErrorAction SilentlyContinue | Where-Object { $_.State -in @("Established", "Listen") } | Sort-Object LocalPort | Format-Table LocalAddress, LocalPort, RemoteAddress, RemotePort, State, OwningProcess -AutoSize)
    Write-Host " done" -ForegroundColor Green

    # --- SMB / file-share analysis, computed from the logs already pulled (no second query).
    # Done BEFORE the live capture below so the servers the client actually talked to (named
    # in its own SMB events) can be reachability-tested even when nothing is mapped right now.
    $smbEvents = @($allEvents | Where-Object { $_.Log -match 'SmbClient' -or ($_.Log -eq 'System' -and $_.ProviderName -match '^(mrxsmb|srv|srv2|srvnet|mup|NetBT|Microsoft-Windows-SMBServer)') })
    $smbConn = @($smbEvents | Where-Object { $_.Log -match 'Connectivity' })
    $smbAnalysis = @()

    # interface index -> adapter name, learned from the SMB client's own "added a TCP/IP transport interface" events
    $ifNames = @{}
    foreach ($e in ($smbConn | Where-Object { "$($_.Id)" -eq '30810' })) {
        if ($e.Message -match '(?s)Name:\s*(.+?)\s*InterfaceIndex:\s*0x([0-9A-Fa-f]+)') {
            $ifNames[[Convert]::ToInt32($matches[2], 16)] = ($matches[1] -replace '[\u200E\u200F]', '').Trim()
        }
    }

    $dnsFails = @($smbConn | Where-Object { "$($_.Id)" -eq '30800' })
    if ($dnsFails.Count -gt 0) {
        $smbAnalysis += "Name-resolution failures (30800): $($dnsFails.Count) - the client could not resolve a server NAME (DNS/WINS lookup failed):"
        foreach ($g in ($dnsFails | Group-Object { if ($_.Message -match 'Server name:\s*\\*(\S+)') { $matches[1] } } | Sort-Object Count -Descending)) {
            $gt = @($g.Group | Sort-Object TimeCreated)
            $smbAnalysis += "    $($g.Name): $($g.Count)x (first $($gt[0].TimeCreated), last $($gt[-1].TimeCreated))"
        }
    }

    $disc = @($smbConn | Where-Object { "$($_.Id)" -eq '30804' } | Sort-Object { [datetime]$_.TimeCreated })
    if ($disc.Count -gt 0) {
        $smbAnalysis += "Connection drops (30804 'a network connection was disconnected'): $($disc.Count), first $($disc[0].TimeCreated), last $($disc[-1].TimeCreated)"
        foreach ($g in ($disc | Group-Object { $a = ''; $i = ''; if ($_.Message -match 'Server name:\s*\\*(\S+)') { $a = $matches[1] }; if ($_.Message -match 'InterfaceId:\s*(\d+)') { $i = [int]$matches[1] }; "$a via interface $i$(if ($i -ne '' -and $ifNames.ContainsKey($i)) { " ($($ifNames[$i]))" })" } | Sort-Object Count -Descending)) {
            $smbAnalysis += "    $($g.Name): $($g.Count)x"
        }
        if ($disc.Count -ge 5) {
            $dTimes = @($disc | ForEach-Object { [datetime]$_.TimeCreated })
            $gaps = @(for ($k = 1; $k -lt $dTimes.Count; $k++) { [Math]::Round(($dTimes[$k] - $dTimes[$k - 1]).TotalSeconds) })
            $sortedGaps = @($gaps | Sort-Object)
            $median = $sortedGaps[[int][Math]::Floor($sortedGaps.Count / 2)]
            if ($median -ge 5) {
                $near = @($gaps | Where-Object { [Math]::Abs($_ - $median) -le [Math]::Max(3, $median * 0.1) }).Count
                if ($near / $gaps.Count -ge 0.6) {
                    $smbAnalysis += "    PATTERN: drops repeat about every $median s ($near of $($gaps.Count) gaps within tolerance) - something is periodically killing the connection; this is not a one-off network blip."
                }
            }
        }
    }
    $lostSessions = @($smbConn | Where-Object { "$($_.Id)" -eq '30805' })
    if ($lostSessions.Count -gt 0) { $smbAnalysis += "Sessions lost (30805): $($lostSessions.Count)" }
    $lostShares = @($smbConn | Where-Object { "$($_.Id)" -eq '30807' })
    if ($lostShares.Count -gt 0) {
        $shareGroups = @($lostShares | ForEach-Object { if ($_.Message -match 'Share name:\s*(\S+)') { $matches[1] } } | Group-Object | Sort-Object Count -Descending)
        $smbAnalysis += "Shares whose connection was lost (30807): " + (($shareGroups | ForEach-Object { "$($_.Name) ($($_.Count)x)" }) -join ', ')
    }
    $delayedWrites = @($smbEvents | Where-Object { $_.Log -eq 'System' -and $_.ProviderName -match 'mrxsmb' -and "$($_.Id)" -eq '139' })
    if ($delayedWrites.Count -gt 0) {
        $dwFiles = @($delayedWrites | ForEach-Object { if ($_.Message -match 'for the file (.+?);') { $matches[1] } } | Group-Object | Sort-Object Count -Descending)
        $smbAnalysis += "Files with 'Delayed Write Failed' (data lost): " + (($dwFiles | ForEach-Object { "$($_.Name) ($($_.Count)x)" }) -join ', ')
    }
    $smbEventServers = @()
    foreach ($e in $smbConn) {
        foreach ($m in [regex]::Matches($e.Message, 'Server name:\s*\\*([A-Za-z0-9._-]+)')) { $smbEventServers += $m.Groups[1].Value }
        foreach ($m in [regex]::Matches($e.Message, 'Server (?:socket )?address:\s*(\d{1,3}(?:\.\d{1,3}){3})')) { $smbEventServers += $m.Groups[1].Value }
    }
    $smbEventServers = @($smbEventServers | Where-Object { $_ -and $_ -ne 'localhost' -and $_ -notmatch '^127\.' } | Group-Object | Sort-Object Count -Descending | Select-Object -First 8 -ExpandProperty Name)

    # SMB / file-share client state (2026-10, added after a NAS share [JB Superlog's
    # \jbclock folder on \\gvaot-server\Haim] that kept dropping from a new Windows 11 PC -
    # the pull had no SMB visibility at all, so the real cause couldn't be read from it).
    Write-Host "  Capturing SMB/file-share client state (config, SMB1, mappings, connections, credentials, reachability)..." -NoNewline
    Add-NetSection "SMB client configuration (Get-SmbClientConfiguration) - RequireSecuritySignature and EnableInsecureGuestLogons are the usual suspects when a NAS share works from older PCs but not a current Windows 11" (Get-SmbClientConfiguration -ErrorAction SilentlyContinue | Format-List)
    $smb1Start = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\mrxsmb10" -ErrorAction SilentlyContinue).Start
    Add-NetSection "SMB1 client driver (mrxsmb10)" $(if ($null -eq $smb1Start) { "Not installed - this PC cannot speak SMB1, so a NAS/device that ONLY offers SMB1 will fail to connect." } elseif ($smb1Start -eq 4) { "Installed but DISABLED (Start=4)." } else { "Installed and enabled (Start=$smb1Start)." })
    Add-NetSection "Mapped drives / SMB mappings (Get-SmbMapping + net use) - PER-USER: this is the view of the account running this script; if elevated as a different admin than whoever normally uses the PC, these are the ADMIN's mappings, not theirs" (@(
        (Get-SmbMapping -ErrorAction SilentlyContinue | Format-Table LocalPath, RemotePath, Status -AutoSize | Out-String)
        (net use | Out-String)
    ))
    Add-NetSection "Active SMB connections (Get-SmbConnection)" (Get-SmbConnection -ErrorAction SilentlyContinue | Format-Table ServerName, ShareName, UserName, Dialect -AutoSize)
    Add-NetSection "Stored credentials (cmdkey /list) - targets and usernames only, never passwords; PER-USER like the mappings above" (cmdkey /list | Out-String)
    # Servers to test = mapped drives + active connections + stored-credential targets + every
    # server the SMB client's own events name (so a pull taken with nothing mapped still tests
    # the real server). A stale stored credential pointing at a dead address shows up here too.
    $smbServers = @()
    $smbServers += @(Get-SmbMapping -ErrorAction SilentlyContinue | ForEach-Object { if ($_.RemotePath -match '^\\\\([^\\]+)\\') { $matches[1] } })
    $smbServers += @(Get-SmbConnection -ErrorAction SilentlyContinue | ForEach-Object { $_.ServerName })
    $smbServers += @(cmdkey /list | ForEach-Object { if ($_ -match 'Target:\s*(?:Domain|LegacyGeneric):target=([A-Za-z0-9._-]+)\s*$') { $matches[1] } })
    $smbServers += $smbEventServers
    $smbServers = @($smbServers | Where-Object { $_ -and $_ -ne 'localhost' -and $_ -notmatch '^127\.' } | Select-Object -Unique | Select-Object -First 10)
    $smbReach = if ($smbServers.Count -eq 0) {
        "No mapped drives, connections, stored credentials or SMB events naming a server, so nothing to test automatically. To test a specific NAS by hand:  Test-NetConnection <ip-or-name> -Port 445"
    } else {
        $hostsEntries = @()
        try { $hostsEntries = @(Get-Content "$env:SystemRoot\System32\drivers\etc\hosts" -ErrorAction Stop | ForEach-Object { $l = ($_ -replace '#.*', '').Trim(); if ($l) { $t = $l -split '\s+'; if ($t.Count -ge 2) { [PSCustomObject]@{ Ip = $t[0]; Names = @($t[1..($t.Count-1)] | ForEach-Object { $_.ToLower() }) } } } }) } catch {}
        foreach ($srv in $smbServers) {
            $isIp = $srv -match '^\d{1,3}(\.\d{1,3}){3}$'
            $parts = @()
            if (-not $isIp) {
                $dnsOnly = try { (Resolve-DnsName $srv -DnsOnly -Type A -ErrorAction Stop | Where-Object { $_.IPAddress } | Select-Object -First 1 -ExpandProperty IPAddress) } catch { $null }
                $winRes = try { ([System.Net.Dns]::GetHostAddresses($srv) | Where-Object { $_.AddressFamily -eq 'InterNetwork' } | Select-Object -First 1).IPAddressToString } catch { $null }
                $parts += "DNS-only: $(if ($dnsOnly) { $dnsOnly } else { 'FAILED' })"
                $parts += "Windows resolver (DNS + LLMNR/NetBIOS): $(if ($winRes) { $winRes } else { 'FAILED' })"
                $hostsHit = @($hostsEntries | Where-Object { $_.Names -contains $srv.ToLower() } | Select-Object -First 1)
                $parts += "hosts file: $(if ($hostsHit) { $hostsHit[0].Ip } else { 'no entry' })"
                $via = if ($hostsHit) { 'hosts file' } elseif ($dnsOnly) { 'DNS' } elseif ($winRes) { 'NetBIOS/LLMNR (fragile - add a hosts entry or a DNS record)' } else { 'nothing - name does not resolve' }
                $parts += "name answered by: $via"
            }
            $png = @(Test-Connection -ComputerName $srv -Count 2 -ErrorAction SilentlyContinue)
            $parts += "ping: $(if ($png.Count -gt 0) { "$($png.Count)/2 replies, avg $([Math]::Round(($png | Measure-Object ResponseTime -Average).Average)) ms" } else { 'no reply' })"
            $ok = $false; $ms = $null
            try { $sw = [Diagnostics.Stopwatch]::StartNew(); $tc = New-Object System.Net.Sockets.TcpClient; $iar = $tc.BeginConnect($srv, 445, $null, $null); $ok = $iar.AsyncWaitHandle.WaitOne(3000) -and $tc.Connected; $sw.Stop(); $ms = $sw.ElapsedMilliseconds; $tc.Close() } catch {}
            $parts += "TCP 445: $(if ($ok) { "reachable ($ms ms)" } else { 'NOT reachable within 3s' })"
            "$srv -> " + ($parts -join ' | ')
        }
    }
    Add-NetSection "SMB server reachability (every server from mappings, connections, stored credentials and the SMB event log; each name shows DNS-only vs Windows resolver vs hosts-file entry, and which one actually answered - a name answered only by NetBIOS/LLMNR is fragile)" $smbReach
    Write-Host " done" -ForegroundColor Green

    Write-Host "  Capturing running processes (highlighting VPN/filter/security-sounding ones)..." -NoNewline
    $allProcs = Get-Process | Sort-Object Name | Select-Object Name, Id, Company
    Add-NetSection "All running processes" ($allProcs | Format-Table -AutoSize)
    $suspectProcs = $allProcs | Where-Object { $_.Name -match $securityKeywords -or $_.Company -match $securityKeywords }
    Add-NetSection "Processes matching VPN/filter/security keywords" ($suspectProcs | Format-Table -AutoSize)
    Write-Host " done" -ForegroundColor Green

    Write-Host "  Capturing installed security/VPN/filtering software..." -NoNewline
    $uninstallKeys = @(
        "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )
    $installedSecurity = Get-ItemProperty $uninstallKeys -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -match $securityKeywords -or $_.Publisher -match $securityKeywords } |
        Select-Object DisplayName, DisplayVersion, Publisher, InstallDate
    Add-NetSection "Installed software matching VPN/filter/security keywords" ($installedSecurity | Format-Table -AutoSize)
    Write-Host " done" -ForegroundColor Green

    # SMB / file-share section (analysis computed above, from the logs already pulled). Placed
    # right under the ISP flag so a share problem is the next thing anyone reads. Lists only
    # Error/Warning events - the Information ones ("connection established", transport added)
    # are routine and previously buried the real failures.
    $smbEventLines = @("SMB / file-share events ($($smbEvents.Count) found) - SmbClient channels = the client's own reason for a failed share connection; System mrxsmb/Mup/NetBT = the aftermath")
    if ($smbAnalysis.Count -gt 0) {
        $smbEventLines += "ANALYSIS (computed from the events below):"
        $smbEventLines += ($smbAnalysis | ForEach-Object { "  $_" })
    } else {
        $smbEventLines += "ANALYSIS: no name-resolution failures, drops, lost sessions/shares or delayed-write failures found in the SMB logs for this window."
    }
    $smbEventsListed = @($smbEvents | Where-Object { $_.LevelDisplayName -in @('Error', 'Warning', 'Critical') })
    $smbEventLines += "(listing only the $($smbEventsListed.Count) Error/Warning events; $($smbEvents.Count - $smbEventsListed.Count) routine Information events omitted - they are in the raw CSVs)"
    foreach ($s in ($pullStatus | Where-Object { $_.Log -match 'SmbClient' })) {
        $smbEventLines += "  [$($s.Log)] enabled: $($s.TargetEnabled), total records on machine: $($s.TargetRecordCount), events in this window: $($s.EventsPulled)$(if ($s.PullError -or $s.ListLogError) { ", ERROR: $(if ($s.PullError) { $s.PullError } else { $s.ListLogError })$(if (("$($s.PullError)$($s.ListLogError)") -match 'unauthorized') { ' -> these channels need admin rights: re-run elevated (Run as administrator)' })" })"
    }
    foreach ($e in ($smbEventsListed | Sort-Object TimeCreated | Select-Object -First 60)) {
        $hint = ""
        if ($e.Log -match 'Connectivity' -and $e.Id -eq '30800') { $hint = " <- server name could not be resolved by DNS" }
        if ($e.Log -match 'Security' -and $e.Id -eq '31017') { $hint = " <- insecure guest logon was rejected (client refuses guest/unauthenticated access)" }
        $msg = ($e.Message -replace '\r?\n', ' ')
        if ($msg.Length -gt 300) { $msg = $msg.Substring(0, 300) + '...' }
        $smbEventLines += "$($e.TimeCreated)  [$($e.LevelDisplayName)] $($e.Log) (Id $($e.Id))$hint - $msg"
    }
    if ($smbEventsListed.Count -gt 60) { $smbEventLines += "... $($smbEventsListed.Count - 60) more - see the raw CSVs." }
    $smbEventSection = "`n" + ("=" * 70) + "`n" + ($smbEventLines -join "`n") + "`n"

    # Put the ISP flag (if any) at the very top of the file, above every other section -
    # this is the single highest-value line in the whole report when it fires, and
    # shouldn't depend on someone scrolling to find it.
    $networkStateContent = $(if ($ispFlagNote) { "$ispFlagNote`n" } else { "" }) + $smbEventSection + $netSb.ToString()
    $networkStateContent | Set-Content -Path (Join-Path $outDir "NetworkState.txt") -Encoding UTF8
    Write-Host "  Network state captured -> NetworkState.txt" -ForegroundColor Green

    # --- Light startup / scheduled-task inventory -> StartupAndTasks.txt (added 2026-10-07) ---
    # ======================================================================
    # LIGHT STARTUP / SCHEDULED-TASK INVENTORY  (read-only, a few seconds)
    # KEEP THIS BLOCK IDENTICAL IN pull-local-logs.ps1 AND pull-remote-logs.ps1.
    # The remote tool runs the very same block on the target via Invoke-Command.
    #
    # An INVENTORY, not a malware scan and not a verdict: a listed item is normal until
    # shown otherwise. Its main job in a plain troubleshooting pull is to answer "what
    # starts by itself here, and WHICH ACCOUNT does it run as" (tasks, services,
    # processes). Deliberately NOT in here - they are slower and/or sensitive and live in
    # pull-persistence.v*.ps1: file hashing, copying script samples, PowerShell history,
    # loading other users' registry hives, task XML export, hidden-task detection,
    # Security-log logon history.
    # Returns an object: Text (the report), Flags (one line per thing worth a glance),
    # Counts (numbers for SUMMARY.txt).
    # ======================================================================
    $startupInventoryBlock = {
        $ErrorActionPreference = 'SilentlyContinue'
        $sb    = New-Object System.Text.StringBuilder
        $flags = New-Object System.Collections.ArrayList
        $cnt   = @{ TasksNonMs = 0; TasksFlagged = 0; RunEntries = 0; Services = 0; ServicesAsUser = 0; ScriptHosts = 0; WmiSubs = 0; Detections = 0; Exclusions = 0; RemoteTools = 0; Admins = 0 }

        function Sec($t)  { [void]$sb.AppendLine(''); [void]$sb.AppendLine(('=' * 70)); [void]$sb.AppendLine($t); [void]$sb.AppendLine(('=' * 70)) }
        function Put($s)  { [void]$sb.AppendLine([string]$s) }
        function Trunc($s, $n) { $s = [string]$s; if ($s.Length -gt $n) { $s.Substring(0, $n) + '...' } else { $s } }
        function FD($d)   { if ($d -and ([datetime]$d).Year -gt 1999) { ([datetime]$d).ToString('yyyy-MM-dd HH:mm', [Globalization.CultureInfo]::InvariantCulture) } else { 'never' } }
        function Hex($n)  { '0x{0:X8}' -f ([int64]$n -band 0xFFFFFFFF) }

        $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        if (-not $isAdmin) { try { $isAdmin = [bool]((& whoami.exe /groups 2>$null) -match 'S-1-16-(12288|16384)') } catch {} }
        Put "Startup / scheduled-task inventory (light) - $env:COMPUTERNAME - $(FD (Get-Date)) - elevated: $isAdmin"
        Put "An inventory, not a verdict - an item is normal until shown otherwise. [REVIEW] = launches a script host / LOLBin, or runs from AppData/Temp/Public, or runs as a user account."
        Put "For a suspected infection run pull-persistence.v*.ps1 (hashes, script samples, every user's autostart keys, hidden tasks, PowerShell history, logon history)."
        if (-not $isAdmin) { Put "NOTE: not elevated - Defender exclusions/detections, some services/tasks and other users' details may be missing. Re-run as administrator." }

        # ---------------------------------------------------------------- 1. TASKS
        $patFlag = 'wscript|cscript|mshta|powershell|pwsh|rundll32|regsvr32|bitsadmin|certutil|\.vbs|\.vbe|\.jse?\b|\.ps1|\.wsf|\.hta|\\AppData\\|\\Temp\\|\\Users\\Public'
        $patMs   = 'wscript|cscript|mshta|\.vbs|\.vbe|\.jse?\b|\.wsf|\.hta|\\AppData\\|\\Temp\\|\\Users\\Public'
        function TaskRun($t) { $r = (($t.Actions | ForEach-Object { ("$($_.Execute) $($_.Arguments)").Trim() }) -join ' | '); if ($r) { $r } else { '(no command - COM handler)' } }
        $allTasks = @(Get-ScheduledTask -ErrorAction SilentlyContinue)
        $userTasks = @($allTasks | Where-Object { $_.TaskPath -notlike '\Microsoft\*' })
        $cnt.TasksNonMs = $userTasks.Count
        Sec "SCHEDULED TASKS outside \Microsoft\ ($($userTasks.Count) of $($allTasks.Count) total) - name, who it runs as, what it runs"
        $taskLines = foreach ($t in ($userTasks | Sort-Object TaskPath, TaskName | Select-Object -First 120)) {
            $i   = $t | Get-ScheduledTaskInfo -ErrorAction SilentlyContinue
            $run = TaskRun $t
            $rev = ($run -match $patFlag)
            if ($rev) { $cnt.TasksFlagged++ }
            $trg = (($t.Triggers | ForEach-Object { $_.CimClass.CimClassName -replace 'MSFT_Task|Trigger', '' }) -join ',')
            "{0}{1}{2}  [{3}]  as {4}  triggers: {5}  last: {6} ({7})`r`n      run: {8}" -f $(if ($rev) { '[REVIEW] ' } else { '' }), $t.TaskPath, $t.TaskName, $t.State, $t.Principal.UserId, $(if ($trg) { $trg } else { '-' }), (FD $i.LastRunTime), (Hex $i.LastTaskResult), (Trunc $run 260)
        }
        if ($taskLines) { Put ($taskLines -join "`r`n") } else { Put '(none)' }
        if ($userTasks.Count -gt 120) { Put "... $($userTasks.Count - 120) more not shown." }
        if ($cnt.TasksFlagged -gt 0) { [void]$flags.Add("$($cnt.TasksFlagged) scheduled task(s) outside \Microsoft\ launch a script host or run from AppData/Temp/Public (marked [REVIEW] in the tasks section).") }

        $msOdd = @($allTasks | Where-Object { $_.TaskPath -like '\Microsoft\*' -and (TaskRun $_) -match $patMs })
        Sec "TASKS UNDER \Microsoft\ that launch a script host or run from a user-writable path (legit OS tasks almost never do)"
        if ($msOdd.Count -gt 0) {
            Put (($msOdd | Select-Object -First 30 | ForEach-Object { "[REVIEW] $($_.TaskPath)$($_.TaskName)  as $($_.Principal.UserId)`r`n      run: $(Trunc (TaskRun $_) 260)" }) -join "`r`n")
            [void]$flags.Add("$($msOdd.Count) task(s) under \Microsoft\ launch a script host or a user-writable path.")
        } else { Put '(none)' }

        # ---------------------------------------------------------------- 2. AUTOSTART KEYS / FOLDERS
        Sec 'RUN / RUNONCE KEYS (machine-wide + every user hive that is currently LOADED; unloaded profiles are not read here) and Winlogon'
        $keys = New-Object System.Collections.ArrayList
        foreach ($p in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run', 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\RunOnce', 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer\Run') {
            [void]$keys.Add([pscustomobject]@{ Who = 'machine'; Path = $p })
        }
        foreach ($h in @(Get-ChildItem Registry::HKEY_USERS -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match '^S-1-5-21-[\d-]+$' })) {
            $who = $h.PSChildName
            try { $who = (New-Object Security.Principal.SecurityIdentifier $h.PSChildName).Translate([Security.Principal.NTAccount]).Value } catch {}
            foreach ($k in 'Run', 'RunOnce') { [void]$keys.Add([pscustomobject]@{ Who = $who; Path = "Registry::HKEY_USERS\$($h.PSChildName)\SOFTWARE\Microsoft\Windows\CurrentVersion\$k" }) }
        }
        $runLines = foreach ($k in $keys) {
            $item = Get-ItemProperty -LiteralPath $k.Path -ErrorAction SilentlyContinue
            if (-not $item) { continue }
            foreach ($prop in ($item.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS(Path|ParentPath|ChildName|Drive|Provider)$' })) {
                $cnt.RunEntries++
                "{0}  {1}\{2}  =  {3}" -f $k.Who, ($k.Path -replace '^Registry::HKEY_USERS\\S-[\d-]+\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\', 'HKU\...\' -replace '^HKLM:\\SOFTWARE\\(WOW6432Node\\)?Microsoft\\Windows\\CurrentVersion\\', 'HKLM\...\'), $prop.Name, (Trunc $prop.Value 240)
            }
        }
        if ($runLines) { Put ($runLines -join "`r`n") } else { Put '(no Run/RunOnce entries)' }
        $wl = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -ErrorAction SilentlyContinue
        if ($wl) {
            Put "Winlogon Shell    = $($wl.Shell)"
            Put "Winlogon Userinit = $($wl.Userinit)"
            if ($wl.Shell -and $wl.Shell -ne 'explorer.exe') { [void]$flags.Add("Winlogon Shell is '$($wl.Shell)' (default is explorer.exe).") }
            if ($wl.Userinit -and $wl.Userinit -notmatch '(?i)^C:\\Windows\\system32\\userinit\.exe,?$') { [void]$flags.Add("Winlogon Userinit is '$($wl.Userinit)' (default is C:\Windows\system32\userinit.exe,).") }
        }

        Sec 'STARTUP FOLDERS (all users + every profile that can be read; desktop.ini is normal)'
        $sfDirs = @("$env:ProgramData\Microsoft\Windows\Start Menu\Programs\Startup") + @(Get-ChildItem 'C:\Users' -Directory -Force -ErrorAction SilentlyContinue | ForEach-Object { Join-Path $_.FullName 'AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup' })
        $sh = $null; try { $sh = New-Object -ComObject WScript.Shell } catch {}
        $sfLines = foreach ($d in $sfDirs) {
            foreach ($f in @(Get-ChildItem -LiteralPath $d -Force -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'desktop.ini' })) {
                $tgt = ''; if ($sh -and $f.Extension -eq '.lnk') { try { $s = $sh.CreateShortcut($f.FullName); $tgt = "  -> $($s.TargetPath) $($s.Arguments)".TrimEnd() } catch {} }
                "{0}  ({1:yyyy-MM-dd}){2}" -f $f.FullName, $f.LastWriteTime, $tgt
            }
        }
        if ($sfLines) { Put ($sfLines -join "`r`n") } else { Put '(none)' }

        # ---------------------------------------------------------------- 3. SERVICES
        Sec 'SERVICES running outside \Windows\ and not Microsoft-pathed - state, start mode, and the ACCOUNT each runs as'
        $svcAll = @(Get-CimInstance Win32_Service -ErrorAction SilentlyContinue | Where-Object { $_.PathName -and $_.PathName -notmatch '(?i)^"?[A-Z]:\\Windows\\' -and $_.PathName -notmatch '(?i)\\Microsoft[^\\]*\\|\\Windows Defender\\|\\WindowsApps\\' })
        $cnt.Services = $svcAll.Count
        $sysAcct = '(?i)^(LocalSystem|NT AUTHORITY\\(LocalService|NetworkService|System)|NT SERVICE\\.*)$'
        $svcLines = foreach ($s in ($svcAll | Sort-Object @{ e = { $_.StartName -match $sysAcct } }, Name | Select-Object -First 100)) {
            $asUser = ($s.StartName -and $s.StartName -notmatch $sysAcct)
            if ($asUser) { $cnt.ServicesAsUser++ }
            "{0}{1} ({2})  [{3}/{4}]  as {5}`r`n      {6}" -f $(if ($asUser) { '[REVIEW] ' } else { '' }), $s.Name, (Trunc $s.DisplayName 60), $s.State, $s.StartMode, $s.StartName, (Trunc $s.PathName 220)
        }
        if ($svcLines) { Put ($svcLines -join "`r`n") } else { Put '(none)' }
        if ($svcAll.Count -gt 100) { Put "... $($svcAll.Count - 100) more not shown." }
        if ($cnt.ServicesAsUser -gt 0) { [void]$flags.Add("$($cnt.ServicesAsUser) non-Windows service(s) run as a named user account rather than LocalSystem/LocalService/NetworkService (marked [REVIEW]).") }

        # ---------------------------------------------------------------- 4. PROCESSES + WHO THEY RUN AS
        $self = @([int]$PID); try { $pp = (Get-CimInstance Win32_Process -Filter "ProcessId=$PID" -ErrorAction Stop).ParentProcessId; if ($pp) { $self += [int]$pp } } catch {}
        $procs = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
        $byId = @{}; foreach ($p in $procs) { $byId[[int]$p.ProcessId] = $p }
        function Owner($p) { try { $o = Invoke-CimMethod -InputObject $p -MethodName GetOwner -ErrorAction Stop; if ($o.User) { "$($o.Domain)\$($o.User)" } else { '?' } } catch { '?' } }

        Sec 'RUNNING NOW: non-Windows programs and the ACCOUNT each runs as (this is what answers "is the app running as the user I think it is?")'
        $np = @($procs | Where-Object { $_.ExecutablePath -and $_.ExecutablePath -notmatch '(?i)^[A-Z]:\\Windows\\|\\WindowsApps\\|\\Windows Defender\\|\\ProgramData\\Microsoft\\' -and $self -notcontains [int]$_.ProcessId } | Select-Object -First 250)
        $npRows = foreach ($p in $np) { [pscustomobject]@{ Name = $p.Name; Owner = (Owner $p); Path = $p.ExecutablePath } }
        $npLines = foreach ($g in ($npRows | Group-Object Owner, Name, Path | Sort-Object { $_.Group[0].Owner }, { $_.Group[0].Name })) {
            $r = $g.Group[0]; "{0}  as {1}{2}`r`n      {3}" -f $r.Name, $r.Owner, $(if ($g.Count -gt 1) { "  (x$($g.Count))" } else { '' }), $r.Path
        }
        if ($npLines) { Put ($npLines -join "`r`n") } else { Put '(none - or process details not readable without elevation)' }

        Sec 'RUNNING NOW: script hosts / LOLBins with command line and parent (this script and its own launcher excluded)'
        $hostPat = '^(wscript|cscript|mshta|powershell|pwsh|rundll32|regsvr32|bitsadmin|certutil|msbuild|installutil|cmstp|wmic)\.exe$'
        $sp = @($procs | Where-Object { $_.Name -match $hostPat -and $self -notcontains [int]$_.ProcessId })
        $cnt.ScriptHosts = $sp.Count
        $spLines = foreach ($p in ($sp | Select-Object -First 40)) {
            $par = $byId[[int]$p.ParentProcessId]
            "{0} (pid {1}) as {2}, parent: {3}`r`n      {4}" -f $p.Name, $p.ProcessId, (Owner $p), $(if ($par) { "$($par.Name) (pid $($par.ProcessId))" } else { "pid $($p.ParentProcessId) (gone)" }), (Trunc $p.CommandLine 300)
        }
        if ($spLines) { Put ($spLines -join "`r`n") } else { Put '(none)' }
        if ($sp.Count -gt 0) { [void]$flags.Add("$($sp.Count) script-host/LOLBin process(es) running right now (see the command lines; many are normal - Splashtop, RMM and installer helpers use them).") }

        # ---------------------------------------------------------------- 5. WMI SUBSCRIPTIONS
        Sec 'WMI PERMANENT EVENT SUBSCRIPTIONS (only "SCM Event Log ..." is normal)'
        $wf = @(Get-CimInstance -Namespace 'root\subscription' -ClassName __EventFilter -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch '^SCM Event Log' })
        $wc = @(Get-CimInstance -Namespace 'root\subscription' -ClassName __EventConsumer -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch '^SCM Event Log' })
        $cnt.WmiSubs = $wf.Count + $wc.Count
        if ($cnt.WmiSubs -gt 0) {
            Put (($wf | ForEach-Object { "filter:   $($_.Name)  query: $(Trunc $_.Query 200)" }) -join "`r`n")
            Put (($wc | ForEach-Object { "consumer: $($_.Name)  ($($_.CimClass.CimClassName))  $(Trunc ("$($_.CommandLineTemplate) $($_.ExecutablePath) $($_.ScriptText)") 200)" }) -join "`r`n")
            [void]$flags.Add("$($cnt.WmiSubs) non-default WMI event filter/consumer object(s) - a classic hiding place; see the WMI section.")
        } else { Put '(none)' }

        # ---------------------------------------------------------------- 6. DEFENDER / AV
        Sec 'ANTIVIRUS PRODUCTS (Security Center) and Defender status'
        $av = @(Get-CimInstance -Namespace 'root\SecurityCenter2' -ClassName AntiVirusProduct -ErrorAction SilentlyContinue)
        if ($av.Count -gt 0) { Put (($av | ForEach-Object { "$($_.displayName)" }) -join '; ') } else { Put '(none reported - or not readable here)' }
        try { $ms = Get-MpComputerStatus -ErrorAction Stop; Put "Defender: service enabled $($ms.AMServiceEnabled), real-time protection $($ms.RealTimeProtectionEnabled), signatures updated $(FD $ms.AntivirusSignatureLastUpdated)" } catch { Put "Defender status not available: $($_.Exception.Message)" }

        Sec 'DEFENDER THREAT DETECTIONS (with names, most recent first)'
        try {
            $thr = @{}; Get-MpThreat -ErrorAction SilentlyContinue | ForEach-Object { $thr[[int64]$_.ThreatID] = $_.ThreatName }
            $det = @(Get-MpThreatDetection -ErrorAction Stop | Sort-Object InitialDetectionTime -Descending)
            $cnt.Detections = $det.Count
            if ($det.Count -gt 0) {
                Put (($det | Select-Object -First 15 | ForEach-Object { "{0}  {1}  {2}  action ok: {3}`r`n      {4}" -f (FD $_.InitialDetectionTime), $(if ($thr.ContainsKey([int64]$_.ThreatID)) { $thr[[int64]$_.ThreatID] } else { "threat id $($_.ThreatID)" }), $_.ProcessName, $_.ActionSuccess, (Trunc (($_.Resources | Select-Object -First 2) -join ' ; ') 220) }) -join "`r`n")
                if ($det.Count -gt 15) { Put "... $($det.Count - 15) older detections not shown." }
                [void]$flags.Add("Defender has $($det.Count) recorded threat detection(s) - see the detections section for names and dates.")
            } else { Put '(none recorded)' }
        } catch { Put "Defender detections not available: $($_.Exception.Message)" }

        Sec 'DEFENDER EXCLUSIONS (malware often adds these)'
        try {
            $mp = Get-MpPreference -ErrorAction Stop
            $ex = @(@($mp.ExclusionPath) + @($mp.ExclusionProcess) + @($mp.ExclusionExtension) | Where-Object { $_ })
            if (($ex -join ' ') -match 'Must be an administrator') { Put 'hidden - not elevated (Windows only shows exclusions to administrators)' }
            else {
                $cnt.Exclusions = $ex.Count
                Put "paths:      $(@($mp.ExclusionPath) -join '; ')"
                Put "processes:  $(@($mp.ExclusionProcess) -join '; ')"
                Put "extensions: $(@($mp.ExclusionExtension) -join '; ')"
                if ($ex.Count -gt 0) { [void]$flags.Add("Defender has $($ex.Count) exclusion(s) (paths/processes/extensions it does not scan) - confirm each is expected.") }
            }
        } catch { Put "Defender preferences not available: $($_.Exception.Message)" }

        # ---------------------------------------------------------------- 7. ACCOUNTS
        Sec 'LOCAL USERS'
        $lu = @(Get-LocalUser -ErrorAction SilentlyContinue)
        if ($lu.Count -gt 0) {
            Put (($lu | ForEach-Object { "{0}  enabled: {1}  password required: {2}  last logon: {3}  password set: {4}" -f $_.Name, $_.Enabled, $_.PasswordRequired, (FD $_.LastLogon), (FD $_.PasswordLastSet) }) -join "`r`n")
            $nopw = @($lu | Where-Object { $_.Enabled -and -not $_.PasswordRequired })
            if ($nopw.Count -gt 0) { [void]$flags.Add("Enabled local account(s) that do not require a password: $(($nopw | ForEach-Object { $_.Name }) -join ', ') (also blocks network logon by default - relevant to remote pulls and share access).") }
        } else { Put '(not readable)' }
        Sec 'LOCAL ADMINISTRATORS (looked up by SID, so it works on any Windows language)'
        $adm = @(Get-LocalGroupMember -SID 'S-1-5-32-544' -ErrorAction SilentlyContinue)
        if ($adm.Count -eq 0) { try { $gn = (New-Object Security.Principal.SecurityIdentifier 'S-1-5-32-544').Translate([Security.Principal.NTAccount]).Value.Split('\')[1]; $adm = @(& net.exe localgroup $gn 2>$null | Where-Object { $_ -and $_ -notmatch '^(Alias name|Comment|Members|---|The command)' } | ForEach-Object { [pscustomobject]@{ Name = $_.Trim(); ObjectClass = '?' } }) } catch {} }
        $cnt.Admins = $adm.Count
        if ($adm.Count -gt 0) { Put (($adm | ForEach-Object { "$($_.Name)  ($($_.ObjectClass))" }) -join "`r`n") } else { Put '(not readable)' }

        # ---------------------------------------------------------------- 8. REMOTE-ACCESS TOOLS
        Sec 'REMOTE-ACCESS / RMM TOOLS (installed programs, services, running processes). Note which of these your own team uses.'
        $rat = 'anydesk|teamviewer|splashtop|screenconnect|connectwise|rustdesk|ultravnc|tightvnc|realvnc|vnc server|logmein|atera|ninjarmm|ninja rmm|kaseya|datto|radmin|remote utilities|chrome remote|zoho assist|supremo|meshagent|mesh agent|dwservice|action1|syncro|n-able|bomgar|beyondtrust|gotomypc|nomachine|aeroadmin|ammyy|litemanager|domotz|parsec'
        $found = New-Object System.Collections.ArrayList
        foreach ($u in @(Get-ItemProperty 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -match $rat })) { [void]$found.Add("installed: $($u.DisplayName) $($u.DisplayVersion)  ($($u.Publisher))") }
        foreach ($s in @(Get-CimInstance Win32_Service -ErrorAction SilentlyContinue | Where-Object { "$($_.Name) $($_.DisplayName) $($_.PathName)" -match $rat })) { [void]$found.Add("service:   $($s.DisplayName) [$($s.State)/$($s.StartMode)] as $($s.StartName)") }
        foreach ($g in @($procs | Where-Object { $_.Name -match $rat } | Group-Object Name)) { [void]$found.Add("running:   $($g.Name) (x$($g.Count))") }
        $found = @($found | Select-Object -Unique)
        $cnt.RemoteTools = $found.Count
        if ($found.Count -gt 0) { Put ($found -join "`r`n") } else { Put '(none found)' }
        $nonSplash = @($found | Where-Object { $_ -notmatch '(?i)splashtop' })
        if ($nonSplash.Count -gt 0) { [void]$flags.Add("Remote-access/RMM software other than Splashtop is present: $((($nonSplash | ForEach-Object { ($_ -replace '^(installed|service|running):\s*', '') -replace '\s{2,}.*$', '' } | Select-Object -Unique) -join '; ')) - confirm it is expected.") }

        [pscustomobject]@{ Text = $sb.ToString(); Flags = @($flags); Counts = [pscustomobject]$cnt }
    }

    $startupInv = $null
    Write-Host "  Capturing startup items / scheduled tasks / services / Defender (light inventory)..." -NoNewline
    try {
        $startupInv = & $startupInventoryBlock
        $startupHeader = $(if ($startupInv.Flags.Count -gt 0) { "REVIEW LIST (things worth a glance - an inventory, not a verdict):`r`n" + (($startupInv.Flags | ForEach-Object { "  * $_" }) -join "`r`n") + "`r`n`r`n" } else { "REVIEW LIST: nothing flagged.`r`n`r`n" })
        ($startupHeader + $startupInv.Text) | Set-Content -Path (Join-Path $outDir "StartupAndTasks.txt") -Encoding UTF8
        if ($startupInv.Flags.Count -gt 0) { Write-Host " done - $($startupInv.Flags.Count) item(s) flagged for review" -ForegroundColor Yellow } else { Write-Host " done" -ForegroundColor Green }
    } catch {
        Write-Host " FAILED: $($_.Exception.Message)" -ForegroundColor Yellow
        "Could not capture the startup inventory: $($_.Exception.Message)" | Set-Content -Path (Join-Path $outDir "StartupAndTasks.txt") -Encoding UTF8
    }

    # ======================================================================
    # PRINT QUEUE + SPOOLER CRASH AUDIT  (read-only, no admin needed, a few seconds)
    # KEEP THIS BLOCK IDENTICAL IN pull-local-logs.ps1 AND pull-remote-logs.ps1.
    # The remote tool runs the very same block on the target via Invoke-Command.
    # Added 2026-11-11 after a client PC (check printing froze on a Brother queue that sat
    # on a WSD port; the first pull could not show the port type). Lists every queue with its
    # port type / host / SNMP flag / status, flags the usual suspects, and summarises spooler
    # crashes + restarts since $Since. Returns Text (the report) and Flags (one line each).
    # ======================================================================
    $printQueueAuditBlock = {
        param($Since)
        $ErrorActionPreference = 'SilentlyContinue'
        $sb    = New-Object System.Text.StringBuilder
        $flags = New-Object System.Collections.ArrayList
        function Put([string]$t) { [void]$sb.AppendLine($t) }

        Put 'Print queues (name | status | driver | port | port type | host | SNMP)'
        Put ('-' * 70)
        $ports = @{}
        foreach ($p in @(Get-PrinterPort)) { $ports[$p.Name] = $p }
        $tcp = @{}
        foreach ($t in @(Get-CimInstance -ClassName Win32_TCPIPPrinterPort)) { $tcp[$t.Name] = $t }
        $queues = @(Get-Printer)
        if ($queues.Count -eq 0) { Put '(no print queues found)' }
        foreach ($q in $queues) {
            $port = $ports[$q.PortName]
            $type = 'Other'; $hostAddr = ''; $snmp = ''
            if ($q.PortName -like 'WSD-*') { $type = 'WSD' }
            elseif ($q.PortName -match '^(USB|DOT4|BTH)') { $type = 'USB/local' }
            elseif ($q.PortName -match '^(LPT|COM)\d') { $type = 'LPT/COM' }
            elseif ($q.PortName -match '^(PORTPROMPT|FILE|nul)') { $type = 'File/none' }
            elseif ($tcp.ContainsKey($q.PortName)) {
                $type = 'TCP/IP'; $hostAddr = [string]$tcp[$q.PortName].HostAddress; $snmp = $(if ($tcp[$q.PortName].SNMPEnabled) { 'on' } else { 'off' })
            } elseif ($port -and $port.PrinterHostAddress) { $type = 'TCP/IP'; $hostAddr = [string]$port.PrinterHostAddress }
            elseif ($q.PortName -match '^\\') { $type = 'Shared (UNC)' }
            Put ("{0} | {1} | {2} | {3} | {4} | {5} | {6}" -f $q.Name, $q.PrinterStatus, $q.DriverName, $q.PortName, $type, $hostAddr, $snmp)
            $junk = $q.Name -match 'PDF|XPS|OneNote|Fax|PaperPort|Snagit|Universal Print'
            if ($junk) { continue }
            if ($type -eq 'WSD') { [void]$flags.Add("Queue '$($q.Name)' is on a WSD port ($($q.PortName)) - WSD can stall or stop answering; a Standard TCP/IP port (raw 9100, SNMP off) is the usual fix.") }
            if ("$($q.PrinterStatus)" -match 'PendingDeletion') { [void]$flags.Add("Queue '$($q.Name)' is stuck in PendingDeletion (often a stuck job or a driver in use) - clear the spool folder / reboot before re-adding it.") }
            if ($type -eq 'TCP/IP' -and $snmp -eq 'on') { [void]$flags.Add("Queue '$($q.Name)' uses a TCP/IP port with SNMP status on - if the printer ignores SNMP, Windows reports it Offline; SNMP off is safer.") }
            if ("$($q.PrinterStatus)" -match 'Offline|Error') { [void]$flags.Add("Queue '$($q.Name)' status is $($q.PrinterStatus).") }
        }
        $names = @($queues | ForEach-Object { $_.Name })
        $copies = @($names | Where-Object { $_ -match '\(Copy \d+\)$' })
        if ($copies.Count -gt 0) { [void]$flags.Add("Duplicate-looking queues ('(Copy N)'): $($copies -join '; ') - check which one the app actually prints to.") }

        Put ''
        Put 'Jobs currently in queues'
        Put ('-' * 70)
        $jobCount = 0
        foreach ($q in $queues) {
            foreach ($j in @(Get-PrintJob -PrinterName $q.Name)) {
                $jobCount++
                Put ("{0} | job {1} | {2} | {3} | {4} bytes" -f $q.Name, $j.Id, $j.JobStatus, $j.DocumentName, $j.Size)
                if ($j.Size -gt 5MB) { [void]$flags.Add("Job $($j.Id) in '$($q.Name)' is $([math]::Round($j.Size/1MB,1)) MB ($($j.JobStatus)) - a huge job can block everything behind it.") }
            }
        }
        if ($jobCount -eq 0) { Put '(none)' }

        Put ''
        Put "Spooler crashes / restarts since $Since"
        Put ('-' * 70)
        $crash = @(Get-WinEvent -FilterHashtable @{ LogName = 'Application'; Id = 1000, 1002; StartTime = $Since } | Where-Object { $_.Message -match 'spoolsv' })
        $scm   = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = 7031, 7034; StartTime = $Since } | Where-Object { $_.Message -match 'Print Spooler' })
        foreach ($e in ($crash | Sort-Object TimeCreated)) {
            $mod = ''; $exc = ''
            if ($e.Message -match 'Faulting module name:\s*([^,\r\n]+)') { $mod = $Matches[1] }
            if ($e.Message -match 'Exception code:\s*(\S+)') { $exc = $Matches[1] }
            Put ("{0}  Application Id {1}  spoolsv.exe  faulting module: {2}  exception: {3}" -f $e.TimeCreated, $e.Id, $(if ($mod) { $mod } else { '(not shown)' }), $(if ($exc) { $exc } else { '?' }))
        }
        foreach ($e in ($scm | Sort-Object TimeCreated)) { Put ("{0}  System Id {1}  Print Spooler service ended unexpectedly" -f $e.TimeCreated, $e.Id) }
        if (($crash.Count + $scm.Count) -eq 0) { Put '(none in this window)' }
        else {
            $mods = @($crash | ForEach-Object { if ($_.Message -match 'Faulting module name:\s*([^,\r\n]+)') { $Matches[1] } } | Group-Object | Sort-Object Count -Descending | ForEach-Object { "$($_.Name) x$($_.Count)" })
            [void]$flags.Add("Print Spooler crashed/restarted $($crash.Count + $scm.Count) time(s) since $Since$(if ($mods) { " (faulting module: $($mods -join ', '))" }) - a print driver or port monitor is the usual cause; check what was being added/discovered at those times.")
        }
        [pscustomobject]@{ Text = $sb.ToString(); Flags = @($flags); Counts = [pscustomobject]@{ Queues = $queues.Count; Crashes = ($crash.Count + $scm.Count) } }
    }

    $printAudit = $null
    Write-Host "  Auditing print queues / ports / spooler crashes..." -NoNewline
    try {
        $printAudit = & $printQueueAuditBlock $startTime
        $printHeader = $(if ($printAudit.Flags.Count -gt 0) { "REVIEW LIST (things worth a glance - an inventory, not a verdict):`r`n" + (($printAudit.Flags | ForEach-Object { "  * $_" }) -join "`r`n") + "`r`n`r`n" } else { "REVIEW LIST: nothing flagged.`r`n`r`n" })
        ($printHeader + $printAudit.Text) | Set-Content -Path (Join-Path $outDir "PrintQueues.txt") -Encoding UTF8
        if ($printAudit.Flags.Count -gt 0) { Write-Host " done -> PrintQueues.txt - $($printAudit.Flags.Count) item(s) flagged for review" -ForegroundColor Yellow } else { Write-Host " done -> PrintQueues.txt" -ForegroundColor Green }
    } catch {
        Write-Host " FAILED: $($_.Exception.Message)" -ForegroundColor Yellow
        "Could not audit the print queues: $($_.Exception.Message)" | Set-Content -Path (Join-Path $outDir "PrintQueues.txt") -Encoding UTF8
    }

    # --- ESP (EFI System Partition) usage check -> EspUsage.txt / EspUsage.csv (added 2026-10-25) ---
    # ======================================================================
    # ESP (EFI SYSTEM PARTITION) USAGE CHECK  (read-only, needs admin, a few seconds)
    # KEEP THIS BLOCK IDENTICAL IN pull-local-logs.ps1 AND pull-remote-logs.ps1.
    # The remote tool runs the very same block on the target via Invoke-Command.
    # Derived from Check-EspUsage.v2026-10-25.1.ps1 (the standalone tool, same folder) -
    # if you fix the analysis in one, mirror it in the other.
    #
    # Mounts the ESP on a spare drive letter (mountvol /S), inventories every file, says who
    # owns each (Windows / HP / firmware capsule / other / unknown), finds duplicate payloads,
    # buckets writes by month, adds BIOS / firmware / Secure Boot context, and ends with a
    # verdict (Windows, HP, both, or just too small). Changes NOTHING on the ESP; the letter
    # is unmounted again in a finally block. Not elevated = skipped with a note.
    # Returns: Text (report), Rows (one per file, for the CSV), Flags, Summary.
    # ======================================================================
    $espUsageBlock = {
        param([bool]$NoHash = $false, [int]$Top = 15, [string]$RootOverride = '')
        $ErrorActionPreference = 'SilentlyContinue'
        $sb    = New-Object System.Text.StringBuilder
        $flags = New-Object System.Collections.ArrayList
        function W([string]$s = '') { [void]$sb.AppendLine($s) }
        function Sec([string]$s) { W ''; W ('=' * 70); W $s; W ('=' * 70) }
        function T($obj) { $t = ($obj | Format-Table -AutoSize | Out-String -Width 200).TrimEnd(); if ($t) { W $t } }
        function Fmt([double]$b) {
            if ($b -ge 1MB) { return ('{0:N1} MB' -f ($b / 1MB)) }
            if ($b -ge 1KB) { return ('{0:N1} KB' -f ($b / 1KB)) }
            return ('{0} B' -f [int]$b)
        }
        function Try-Events($filter, $max) { try { return @(Get-WinEvent -FilterHashtable $filter -MaxEvents $max -ErrorAction Stop) } catch { return @() } }

        function Get-Owner([string]$rel) {
            $p = $rel.Split('\')
            $l = $rel.ToLowerInvariant()
            $dirParts = @()
            if ($p.Count -gt 1) { $dirParts = $p[0..($p.Count - 2)] }
            $kind3 = if ($dirParts.Count -eq 0) { '(root files)' } else { ($dirParts[0..([Math]::Min($dirParts.Count, 3) - 1)] -join '\') }
            if ($l -like 'efi\updatecapsule*') { return [pscustomobject]@{ Bucket = 'Capsule'; Kind = 'EFI\UpdateCapsule' } }
            if (($p.Count -ge 2 -and $p[0] -ieq 'EFI' -and $p[1] -match '^hp') -or $p[0] -match '^hp') { return [pscustomobject]@{ Bucket = 'HP'; Kind = $kind3 } }
            if ($l -like 'efi\microsoft\boot\fonts*') { return [pscustomobject]@{ Bucket = 'Windows'; Kind = 'Boot fonts' } }
            if ($l -like 'efi\microsoft\boot\resources*') { return [pscustomobject]@{ Bucket = 'Windows'; Kind = 'Boot resources' } }
            if ($l -like 'efi\microsoft\recovery*') { return [pscustomobject]@{ Bucket = 'Windows'; Kind = 'WinRE/recovery BCD' } }
            if ($p.Count -ge 5 -and $p[0] -ieq 'EFI' -and $p[1] -ieq 'Microsoft' -and $p[2] -ieq 'Boot' -and $p[3] -match '^[a-z]{2,3}-[a-z0-9]{2,8}(-[a-z0-9]+)?$') { return [pscustomobject]@{ Bucket = 'Windows'; Kind = 'Boot language folders (xx-XX)' } }
            if ($l -like 'efi\microsoft\boot*') { return [pscustomobject]@{ Bucket = 'Windows'; Kind = 'Boot manager / BCD' } }
            if ($l -like 'efi\microsoft*') { return [pscustomobject]@{ Bucket = 'Windows'; Kind = 'EFI\Microsoft (other)' } }
            if ($l -like 'efi\boot*') { return [pscustomobject]@{ Bucket = 'Windows'; Kind = 'EFI\Boot fallback loader' } }
            if ($p.Count -ge 2 -and $p[0] -ieq 'EFI') { return [pscustomobject]@{ Bucket = 'Other'; Kind = ('EFI\' + $p[1]) } }
            return [pscustomobject]@{ Bucket = 'Unknown'; Kind = $kind3 }
        }

        $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        if (-not $isAdmin) { try { $isAdmin = [bool]((& whoami.exe /groups 2>$null) -match 'S-1-16-(12288|16384)') } catch {} }
        W "ESP usage check - $env:COMPUTERNAME - $((Get-Date).ToString('yyyy-MM-dd HH:mm', [Globalization.CultureInfo]::InvariantCulture)) - elevated: $isAdmin"
        if (-not $isAdmin -and -not $RootOverride) {
            W 'SKIPPED: this needs administrator rights (it mounts the EFI System Partition read-only on a spare drive letter). Re-run elevated (Run as administrator).'
            return [pscustomobject]@{ Text = $sb.ToString(); Rows = @(); Flags = @(); Summary = [pscustomobject]@{ Ran = $false; Call = 'skipped (not elevated)'; TotalMB = 0; FreeMB = 0; UsedPct = 0 } }
        }

        $espGuid = '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'
        $letter = $null; $weMounted = $false
        $rowsOut = @(); $summary = [pscustomobject]@{ Ran = $false; Call = 'not run'; TotalMB = 0; FreeMB = 0; UsedPct = 0 }
        try {
            $espParts = @()
            if ($RootOverride) {
                $root = $RootOverride.TrimEnd('\') + '\'
                $letter = ($root.Substring(0, 1))
            } else {
                $espParts = @(Get-Partition -ErrorAction SilentlyContinue | Where-Object { $_.GptType -eq $espGuid })
                if (-not $espParts) { throw 'No GPT EFI System Partition found (legacy BIOS/MBR install?). Nothing to inspect.' }
                $already = $espParts | Where-Object { [string]$_.DriveLetter -match '^[A-Za-z]$' } | Select-Object -First 1
                if ($already) {
                    $letter = [string]$already.DriveLetter
                } else {
                    $used = @([IO.DriveInfo]::GetDrives() | ForEach-Object { $_.Name.Substring(0, 1).ToUpper() })
                    $letter = ([char[]]'ZYXWVUTSRQPONMLKJIHGFED' | Where-Object { $used -notcontains [string]$_ } | Select-Object -First 1)
                    if (-not $letter) { throw 'No free drive letter to mount the ESP on.' }
                    $letter = [string]$letter
                    $mv = & mountvol.exe "${letter}:" /S 2>&1
                    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath "${letter}:\")) { throw "mountvol /S failed: $mv" }
                    $weMounted = $true
                }
                $root = "${letter}:\"
            }

            # ---- 1. partition + capacity
            Sec 'ESP 1. PARTITION AND CAPACITY'
            $di = New-Object IO.DriveInfo($letter)
            $total = [double]$di.TotalSize; $free = [double]$di.AvailableFreeSpace; $usedFs = $total - $free
            W ("ESP mounted at {0}  filesystem {1}" -f $root, $di.DriveFormat)
            W ("Total {0}   Used {1} ({2:N0}%)   FREE {3}" -f (Fmt $total), (Fmt $usedFs), (100 * $usedFs / $total), (Fmt $free))
            foreach ($ep in $espParts) {
                $parts = Get-Partition -DiskNumber $ep.DiskNumber | Sort-Object Offset
                W ''
                W ("Disk {0} layout (an ESP can only grow into free/shrinkable space right after it):" -f $ep.DiskNumber)
                T ($parts | Select-Object PartitionNumber, Type, @{n = 'Size'; e = { Fmt $_.Size } }, @{n = 'OffsetMB'; e = { [int]($_.Offset / 1MB) } })
            }

            # ---- 2. inventory
            Sec 'ESP 2. FILE INVENTORY'
            $gcErr = @()
            $raw = @(Get-ChildItem -LiteralPath $root -Recurse -Force -File -ErrorAction SilentlyContinue -ErrorVariable gcErr)
            $files = foreach ($f in $raw) {
                $rel = $f.FullName.Substring($root.Length)
                $o = Get-Owner $rel
                [pscustomobject]@{
                    Rel = $rel; Length = [double]$f.Length; LastWrite = $f.LastWriteTime; Bucket = $o.Bucket; Kind = $o.Kind
                    Leftover = [bool]($f.Name -match '\.(bak|old|tmp|bkp|prev)$|\.log\d*$|~$|\.efi\.(bak|old|tmp|prev|\d+)$'); Hash = ''
                }
            }
            $files = @($files)
            $sum = ($files | Measure-Object Length -Sum).Sum; if (-not $sum) { $sum = 0 }
            W ("{0} files, {1} total file bytes. Filesystem says {2} used; difference {3} = FAT cluster slack + directory metadata." -f $files.Count, (Fmt $sum), (Fmt $usedFs), (Fmt ($usedFs - $sum)))
            if ($gcErr.Count) { W ("({0} paths could not be read - totals may be slightly low)" -f $gcErr.Count) }
            W ''
            W 'Bytes by owner:'
            T ($files | Group-Object Bucket | ForEach-Object { $s = ($_.Group | Measure-Object Length -Sum).Sum; [pscustomobject]@{ Owner = $_.Name; Files = $_.Count; Size = Fmt $s; Bytes = $s; Pct = $(if ($sum) { '{0:N0}%' -f (100 * $s / $sum) } else { '-' }) } } | Sort-Object Bytes -Descending | Select-Object Owner, Files, Size, Pct)
            W ''
            W 'Bytes by folder / kind:'
            T ($files | Group-Object Bucket, Kind | ForEach-Object { $s = ($_.Group | Measure-Object Length -Sum).Sum; [pscustomobject]@{ Owner = $_.Group[0].Bucket; Where = $_.Group[0].Kind; Files = $_.Count; Size = Fmt $s; Bytes = $s } } | Sort-Object Bytes -Descending | Select-Object Owner, Where, Files, Size)
            W ''
            W ("Largest {0} files:" -f $Top)
            T ($files | Sort-Object Length -Descending | Select-Object -First $Top @{n = 'Size'; e = { Fmt $_.Length } }, Bucket, @{n = 'Modified'; e = { $_.LastWrite.ToString('yyyy-MM-dd') } }, Rel)
            $left = @($files | Where-Object { $_.Leftover })
            W ''
            if ($left.Count) {
                W ("Leftover-looking files (.bak/.old/.tmp/.log/.efi.bak): {0} files, {1}" -f $left.Count, (Fmt (($left | Measure-Object Length -Sum).Sum)))
                T ($left | Sort-Object Length -Descending | Select-Object -First 15 @{n = 'Size'; e = { Fmt $_.Length } }, Bucket, Rel)
            } else { W 'Leftover-looking files: none.' }

            # ---- 3. duplicates
            Sec 'ESP 3. DUPLICATE PAYLOADS (same SHA-256 stored more than once)'
            $dupGroups = @(); $dupWaste = 0
            if ($NoHash) { W 'Skipped (NoHash).' } else {
                foreach ($f in ($files | Where-Object { $_.Length -ge 64KB })) {
                    try { $f.Hash = (Get-FileHash -LiteralPath (Join-Path $root $f.Rel) -Algorithm SHA256 -ErrorAction SilentlyContinue).Hash } catch { }
                }
                $dupGroups = @($files | Where-Object { $_.Hash } | Group-Object Hash | Where-Object { $_.Count -gt 1 })
                if ($dupGroups.Count) {
                    foreach ($g in $dupGroups) {
                        $dupWaste += ($g.Count - 1) * $g.Group[0].Length
                        W ("{0} copies x {1}  ({2} wasted)  owners: {3}" -f $g.Count, (Fmt $g.Group[0].Length), (Fmt (($g.Count - 1) * $g.Group[0].Length)), (($g.Group | Select-Object -ExpandProperty Bucket -Unique) -join ','))
                        foreach ($m in $g.Group) { W ("    {0}   [{1}]" -f $m.Rel, $m.LastWrite.ToString('yyyy-MM-dd')) }
                    }
                    W ("Total reclaimable by dedupe alone: {0}" -f (Fmt $dupWaste))
                } else { W 'No duplicate files >= 64 KB.' }
            }

            # ---- 4. timeline
            Sec 'ESP 4. WHEN WAS IT WRITTEN (last-write month x owner)'
            T ($files | Group-Object { $_.LastWrite.ToString('yyyy-MM') } | Sort-Object Name | ForEach-Object {
                    $g = $_.Group
                    $row = [ordered]@{ Month = $_.Name; Files = $_.Count; Size = Fmt (($g | Measure-Object Length -Sum).Sum) }
                    foreach ($b in 'Windows', 'HP', 'Capsule', 'Other', 'Unknown') { $s = ($g | Where-Object { $_.Bucket -eq $b } | Measure-Object Length -Sum).Sum; $row[$b] = $(if ($s) { Fmt $s } else { '-' }) }
                    [pscustomobject]$row })
            W ''
            W 'Newest 12 files:'
            T ($files | Sort-Object LastWrite -Descending | Select-Object -First 12 @{n = 'Modified'; e = { $_.LastWrite.ToString('yyyy-MM-dd HH:mm') } }, Bucket, @{n = 'Size'; e = { Fmt $_.Length } }, Rel)

            # ---- 5. context
            Sec 'ESP 5. SYSTEM CONTEXT (BIOS, firmware devices, HP software, Secure Boot servicing)'
            $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
            $bios = Get-CimInstance Win32_BIOS -ErrorAction SilentlyContinue
            $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
            $isHP = ($cs.Manufacturer -match 'HP|Hewlett')
            W ("Machine : {0} {1}   (HP-branded: {2})" -f $cs.Manufacturer, $cs.Model, $isHP)
            W ("BIOS    : {0}  version {1}  build date {2}" -f $bios.Manufacturer, $bios.SMBIOSBIOSVersion, $(if ($bios.ReleaseDate) { $bios.ReleaseDate.ToString('yyyy-MM-dd') } else { '?' }))
            W ("Windows : {0}  build {1}  installed {2}" -f $os.Caption, $os.BuildNumber, $(if ($os.InstallDate) { $os.InstallDate.ToString('yyyy-MM-dd') } else { '?' }))
            try { W ("Secure Boot enabled: {0}" -f (Confirm-SecureBootUEFI -ErrorAction Stop)) } catch { W 'Secure Boot state: unavailable' }
            foreach ($k in 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot', 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\Servicing') {
                $pv = Get-ItemProperty -LiteralPath $k -ErrorAction SilentlyContinue
                if ($pv) {
                    $props = $pv.PSObject.Properties | Where-Object { $_.Name -match 'AvailableUpdates|UEFICA2023|Capable|Status|Error' } | ForEach-Object { '{0}={1}' -f $_.Name, $_.Value }
                    if ($props) { W ("{0}: {1}" -f $k.Replace('HKLM:\SYSTEM\CurrentControlSet\Control\', ''), ($props -join '  ')) }
                }
            }
            $espBm = Join-Path $root 'EFI\Microsoft\Boot\bootmgfw.efi'
            $osBm = Join-Path $env:SystemRoot 'Boot\EFI\bootmgfw.efi'
            $bmEsp = $null; $bmOs = $null
            if (Test-Path -LiteralPath $espBm) { $bmEsp = (Get-Item -LiteralPath $espBm).VersionInfo.FileVersion }
            if (Test-Path -LiteralPath $osBm) { $bmOs = (Get-Item -LiteralPath $osBm).VersionInfo.FileVersion }
            W ("bootmgfw.efi version: on ESP = {0}   in C:\Windows\Boot\EFI = {1}" -f $bmEsp, $bmOs)
            W ''
            W 'Firmware devices Windows manages (updates arrive via Windows Update as capsules staged through the ESP):'
            # Get-PnpDevice (~1 s). The standalone tool uses Win32_PnPSignedDriver, which takes ~50 s per call.
            $fw = @(Get-PnpDevice -Class Firmware -ErrorAction SilentlyContinue | ForEach-Object {
                    $h = @{}
                    foreach ($x in @(Get-PnpDeviceProperty -InstanceId $_.InstanceId -KeyName 'DEVPKEY_Device_DriverVersion', 'DEVPKEY_Device_DriverDate', 'DEVPKEY_Device_Manufacturer' -ErrorAction SilentlyContinue)) { $h[$x.KeyName] = $x.Data }
                    [pscustomobject]@{ DeviceName = $_.FriendlyName; Manufacturer = $h['DEVPKEY_Device_Manufacturer']; DriverVersion = $h['DEVPKEY_Device_DriverVersion']; DriverDate = $(if ($h['DEVPKEY_Device_DriverDate']) { ([datetime]$h['DEVPKEY_Device_DriverDate']).ToString('yyyy-MM-dd') }) }
                })
            if ($fw.Count) { T $fw } else { W '  (none reported)' }
            W ''
            W 'HP software that touches firmware / BIOS / recovery:'
            $swKeys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
            $hpSw = @(Get-ItemProperty $swKeys -ErrorAction SilentlyContinue | Where-Object {
                    $_.DisplayName -match '^HP .*(Support Assistant|Client Management|Image Assistant|Sure|Cloud Recovery|BIOS|Firmware|System Event|Notifications|Wolf)|HP Connection Optimizer|HP Smart' -or
                    $_.DisplayName -match 'HP Recovery|HP Documentation|HPSA' } | Select-Object DisplayName, DisplayVersion | Sort-Object DisplayName -Unique)
            if ($hpSw.Count) { T $hpSw } else { W '  (none found)' }
            $hpSvc = @(Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^HP|^hp' -or $_.DisplayName -match '^HP ' } | Select-Object Name, Status, StartType)
            if ($hpSvc.Count) { W ''; W 'HP services:'; T $hpSvc }
            W ''
            W 'Recent cumulative/servicing updates:'
            try { T (Get-HotFix -ErrorAction Stop | Sort-Object InstalledOn -Descending | Select-Object -First 8 HotFixID, Description, InstalledOn) } catch { W '  (Get-HotFix unavailable)' }
            W ''
            W 'Windows Update firmware / boot related events (System log, WindowsUpdateClient 19=installed 20=failed):'
            $wu = @(Try-Events @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WindowsUpdateClient'; Id = 19, 20 } 600 | Where-Object { $_.Message -match 'firmware|BIOS|\bHP\b|Secure Boot|System Firmware' } | Select-Object -First 15)
            if ($wu.Count) {
                foreach ($e in $wu) { $ml = @($e.Message -split "`r?`n"); W ("  {0}  id {1}  {2}" -f $e.TimeCreated.ToString('yyyy-MM-dd'), $e.Id, (($ml[0..([Math]::Min(1, $ml.Count - 1))]) -join ' ')) }
            } else { W '  (none)' }
            W ''
            W 'Secure Boot servicing events (TPM-WMI 10xx/17xx/18xx = DB/boot-manager update attempts):'
            $tw = @(Try-Events @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-TPM-WMI' } 300)
            if ($tw.Count) {
                $tw | Group-Object Id | Sort-Object Name | ForEach-Object {
                    $first = $_.Group[0]
                    W ("  id {0} x{1}  latest {2}  {3}" -f $_.Name, $_.Count, $first.TimeCreated.ToString('yyyy-MM-dd'), (($first.Message -split "`r?`n")[0]))
                }
            } else { W '  (none)' }

            # ---- 6. verdict
            Sec 'ESP 6. VERDICT - WINDOWS, HP, OR BOTH?'
            function Bk([string]$n) { $x = ($files | Where-Object { $_.Bucket -eq $n } | Measure-Object Length -Sum).Sum; if ($x) { [double]$x } else { 0.0 } }
            $winB = Bk 'Windows'; $hpB = Bk 'HP'; $capB = Bk 'Capsule'; $othB = Bk 'Other'; $unkB = Bk 'Unknown'
            $localeFiles = @($files | Where-Object { $_.Kind -eq 'Boot language folders (xx-XX)' })
            $localeDirs = @($localeFiles | ForEach-Object { $_.Rel.Split('\')[3] } | Select-Object -Unique)
            $hpDupes = @($dupGroups | Where-Object { ($_.Group | Where-Object { $_.Bucket -in 'HP', 'Capsule' }).Count -gt 1 })
            $hpBigMonths = @($files | Where-Object { $_.Bucket -eq 'HP' -and $_.Length -ge 1MB } | ForEach-Object { $_.LastWrite.ToString('yyyy-MM') } | Select-Object -Unique)
            $hpEv = New-Object System.Collections.Generic.List[string]
            $winEv = New-Object System.Collections.Generic.List[string]
            $envEv = New-Object System.Collections.Generic.List[string]
            if ($usedFs -gt 0 -and ($hpB / $usedFs) -ge 0.30) { $hpEv.Add(("HP-owned files are {0} = {1:N0}% of the used space." -f (Fmt $hpB), (100 * $hpB / $usedFs))) }
            if ($hpDupes.Count) { $hpEv.Add(("{0} identical HP/capsule payload(s) stored more than once - HP's updater is re-staging without removing the old copy." -f $hpDupes.Count)) }
            if ($hpBigMonths.Count -gt 1) { $hpEv.Add(("HP payloads >= 1 MB written in {0} different months ({1}) and none were cleaned up - old BIOS/firmware generations are accumulating." -f $hpBigMonths.Count, ($hpBigMonths -join ', '))) }
            if ($capB -gt 0) { $hpEv.Add(("{0} sits in EFI\UpdateCapsule. Firmware is supposed to consume AND delete it on the next boot; a leftover means the firmware did not clean up (vendor/firmware side), or the flash failed and Windows keeps re-staging it (check the failed id 20 events above - that would make it both)." -f (Fmt $capB))) }
            if ($localeDirs.Count -gt 30 -and $winB -gt 70MB) { $winEv.Add(("{0} boot language folders ({1}) - bcdboot copies every locale by default; that is stock Windows behaviour and is never pruned." -f $localeDirs.Count, (Fmt (($localeFiles | Measure-Object Length -Sum).Sum)))) }
            if ($winB -gt 70MB) { $winEv.Add(("Windows-owned files total {0}; a normal Windows ESP is roughly 30-60 MB, so Windows alone is heavier than expected." -f (Fmt $winB))) }
            if ($left.Count -and (($left | Where-Object { $_.Bucket -eq 'Windows' }).Count)) { $winEv.Add(("{0} leftover .bak/.old/.log-style files under Windows folders (servicing residue)." -f ($left | Where-Object { $_.Bucket -eq 'Windows' }).Count)) }
            if ($bmEsp -and $bmOs -and $bmEsp -ne $bmOs) { $winEv.Add(("ESP boot manager ({0}) differs from the OS copy ({1}) - boot-manager servicing is pending/failed, which retries and needs free ESP space." -f $bmEsp, $bmOs)) }
            if ($total -le 105MB -and $free -lt 30MB) { $envEv.Add(("ESP is only {0}. Modern HP firmware payloads + Windows resources + the Secure Boot boot-manager update do not fit comfortably in 100 MB - the partition is undersized for current needs (OEM imaging/Windows Setup sizing choice)." -f (Fmt $total))) }
            if ($free -lt 15MB) { $envEv.Add(("Only {0} free - below roughly 15 MB, Windows servicing and Secure Boot boot-manager updates start failing." -f (Fmt $free))) }
            foreach ($pair in @(@('HP-side evidence', $hpEv), @('Windows-side evidence', $winEv), @('Sizing / environment', $envEv))) {
                W ''
                W $pair[0]
                if ($pair[1].Count) { foreach ($x in $pair[1]) { W ("  - " + $x) } } else { W '  - none' }
            }
            $pressure = ($free -lt 30MB); $hpFlag = $hpEv.Count -gt 0; $winFlag = $winEv.Count -gt 0
            W ''
            if (-not $pressure -and -not $hpFlag) { $call = ('NOT UNDER PRESSURE - {0} free of {1}. Re-run when the ESP is actually full (or on the affected machine).' -f (Fmt $free), (Fmt $total)) }
            elseif ($hpFlag -and $winFlag) { $call = 'BOTH - HP leaves firmware payloads behind AND Windows contributes its own bloat/residue.' }
            elseif ($hpFlag) { $call = 'HP-SIDE - the space is going to HP staging/firmware files; Windows files look normal.' }
            elseif ($winFlag) { $call = 'WINDOWS-SIDE - HP footprint is small; the growth is Windows boot resources/servicing.' }
            else { $call = 'NEITHER AS A BUG - contents look normal; the partition is simply too small for its normal contents.' }
            W ("LIKELY ATTRIBUTION: " + $call)
            W ("Breakdown: Windows {0} | HP {1} | Capsule {2} | Other {3} | Unknown {4} | of {5} partition" -f (Fmt $winB), (Fmt $hpB), (Fmt $capB), (Fmt $othB), (Fmt $unkB), (Fmt $total))
            W ''
            W 'Caveats: ownership is path-based (heuristic). "Windows" files are expected content, not necessarily a bug -'
            W 'a bug needs growth that should not happen (duplicates, repeated generations, leftovers). To pin the cause'
            W 'to one event, run this before and after a BIOS update / cumulative update and diff the two CSVs.'
            W 'This check changed nothing on the ESP. Nothing is cleaned up - decide what to remove from the evidence above.'

            if ($pressure) { [void]$flags.Add(("EFI System Partition is nearly full: {0} free of {1}. {2}" -f (Fmt $free), (Fmt $total), $call)) }
            elseif ($hpFlag -or $winFlag) { [void]$flags.Add(("EFI System Partition: {0}" -f $call)) }

            $rowsOut = @($files | ForEach-Object { [pscustomobject]@{ Rel = $_.Rel; Bucket = $_.Bucket; Kind = $_.Kind; Length = [int64]$_.Length; LastWrite = $_.LastWrite.ToString('yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture); Leftover = $_.Leftover; Hash = $_.Hash } })
            $summary = [pscustomobject]@{ Ran = $true; Call = $call; TotalMB = [math]::Round($total / 1MB, 1); FreeMB = [math]::Round($free / 1MB, 1); UsedPct = [math]::Round(100 * $usedFs / $total, 0) }
        }
        catch {
            W ("ERROR: {0}" -f $_.Exception.Message)
            $summary = [pscustomobject]@{ Ran = $false; Call = ("error: {0}" -f $_.Exception.Message); TotalMB = 0; FreeMB = 0; UsedPct = 0 }
        }
        finally {
            if ($weMounted -and $letter) { & mountvol.exe "${letter}:" /D 2>&1 | Out-Null; W ("Unmounted {0}:" -f $letter) }
        }
        [pscustomobject]@{ Text = $sb.ToString(); Rows = $rowsOut; Flags = @($flags); Summary = $summary }
    }

    $espUsage = $null
    Write-Host "  Checking EFI System Partition usage (needs admin)..." -NoNewline
    try {
        $espUsage = & $espUsageBlock
        $espHeader = $(if ($espUsage.Flags.Count -gt 0) { "REVIEW: " + (($espUsage.Flags | ForEach-Object { $_ }) -join " | ") + "`r`n`r`n" } else { "" })
        ($espHeader + $espUsage.Text) | Set-Content -Path (Join-Path $outDir "EspUsage.txt") -Encoding UTF8
        if (@($espUsage.Rows).Count -gt 0) { @($espUsage.Rows) | Export-Csv -LiteralPath (Join-Path $outDir "EspUsage.csv") -NoTypeInformation -Encoding UTF8 }
        if (-not $espUsage.Summary.Ran) { Write-Host " $($espUsage.Summary.Call) - see EspUsage.txt" -ForegroundColor Yellow }
        elseif ($espUsage.Flags.Count -gt 0) { Write-Host " done - $($espUsage.Summary.FreeMB) MB free of $($espUsage.Summary.TotalMB) MB, flagged for review" -ForegroundColor Yellow }
        else { Write-Host " done - $($espUsage.Summary.FreeMB) MB free of $($espUsage.Summary.TotalMB) MB" -ForegroundColor Green }
    } catch {
        Write-Host " FAILED: $($_.Exception.Message)" -ForegroundColor Yellow
        "Could not run the ESP usage check: $($_.Exception.Message)" | Set-Content -Path (Join-Path $outDir "EspUsage.txt") -Encoding UTF8
    }

    # --- Friendly summary ---
    $summaryPath = Join-Path $outDir "SUMMARY.txt"
    $errorsAndWarnings = $allEvents | Where-Object { $_.LevelDisplayName -in @("Error", "Warning", "Critical") }
    $topProviders = $errorsAndWarnings | Group-Object ProviderName | Sort-Object Count -Descending | Select-Object -First 10
    $topIds = $errorsAndWarnings | Group-Object Log, Id | Sort-Object Count -Descending | Select-Object -First 10

    $logGapNote = if ($pullStatus | Where-Object { $_.EventsPulled -eq 0 -or $_.PullError }) {
        "`nWARNING: one or more logs came back empty or failed to pull - see LogPullStatus.txt before trusting any 'clean' result above.`n"
    } else { "" }

    $summary = @"
Local Diagnostic Summary
=========================
Computer:     $ComputerName (pulled locally - no network/credentials used)
Time range:   $(Format-DT $startTime)  to  $(Format-DT (Get-Date))
Pulled:       $(Format-DT (Get-Date))
$logGapNote
Total events:            $($allEvents.Count)
Errors/Warnings/Critical: $($errorsAndWarnings.Count)

BSODs (bugchecks) found:            $($bsodEvents.Count)
Unexplained abrupt shutdowns found: $($unexplained.Count)
(see BSOD_Report.txt for details)

GPU/display driver events found:    $($gpuOnlyEvents.Count)
(see GPU_Report.txt for details, including correlation with crash timing)

Print Service events found: $($printEvents.Count) ($($printErrorsWarnings.Count) errors/warnings, $($printJobsCompleted.Count) completed jobs)
(see Print_Report.txt for details)
$(if ($ispFlagNote) { "`n$ispFlagNote`n" })
$(if ($startupInv) { "`nStartup / scheduled tasks (light inventory - see StartupAndTasks.txt): $($startupInv.Counts.TasksNonMs) tasks outside \Microsoft\ ($($startupInv.Counts.TasksFlagged) flagged), $($startupInv.Counts.RunEntries) Run/RunOnce entries, $($startupInv.Counts.Services) non-Windows services ($($startupInv.Counts.ServicesAsUser) run as a user account), $($startupInv.Counts.ScriptHosts) script-host processes running, $($startupInv.Counts.WmiSubs) WMI subscriptions, Defender detections: $($startupInv.Counts.Detections), exclusions: $($startupInv.Counts.Exclusions), remote-access tools: $($startupInv.Counts.RemoteTools), local admins: $($startupInv.Counts.Admins)$(if ($startupInv.Flags.Count -gt 0) { "`n  Worth a glance:`n" + (($startupInv.Flags | ForEach-Object { "    * $_" }) -join "`n") })" })$(if ($espUsage -and $espUsage.Summary.Ran) { "`nEFI System Partition (see EspUsage.txt): $($espUsage.Summary.FreeMB) MB free of $($espUsage.Summary.TotalMB) MB ($($espUsage.Summary.UsedPct)% used) - $($espUsage.Summary.Call)" } elseif ($espUsage) { "`nEFI System Partition check (see EspUsage.txt): $($espUsage.Summary.Call)" })
Crash dump / GPU artifacts:
  Dump type configured on this machine: $dumpConfigNote
  Minidumps collected:  $minidumpCount ($minidumpSizeMB MB)$(if ($minidumpCount -gt 0) { " - see Minidumps\" })
  GPU/TDR dumps found:  $liveKernelCount ($liveKernelSizeMB MB)$(if ($liveKernelCount -gt 0) { " - see GPU_TDR_Dumps\" })
  Full memory dump:     $(if ($fullDumpIncluded) { "included ($fullDumpSizeGB GB) - MEMORY.DMP" } elseif ($fullDumpFound) { "found but not included ($fullDumpSizeGB GB) - re-run with -IncludeFullDump to grab it" } else { "not present on this machine" })

Top noisy providers (Errors/Warnings):
$(($topProviders | ForEach-Object { "  {0,5}  {1}" -f $_.Count, $_.Name }) -join "`n")

Top recurring Event IDs (Errors/Warnings):
$(($topIds | ForEach-Object { "  {0,5}  {1}" -f $_.Count, $_.Name }) -join "`n")

Files in this folder:
  System.csv         - full System log for the window above (if any events were pulled)
  Application.csv    - full Application log for the window above (if any events were pulled)
  SUMMARY.txt         - this file
  BSOD_Report.txt    - bugcheck codes + unexplained abrupt shutdowns, decoded
  GPU_Report.txt     - GPU/driver inventory, TDR settings, GPU events correlated with crash timing
  PrintService_Admin.csv / PrintService_Operational.csv - raw Print Service logs (Admin =
                       spooler/driver-level errors; Operational = per-job detail, off by
                       default - Print_Report.txt says whether it was enabled for this run)
  Print_Report.txt   - print errors/warnings + completed-job history, decoded
  PrintQueues.txt    - every print queue with its port type (WSD / TCP/IP / USB), host, SNMP flag and status,
                       jobs sitting in queues, and Print Spooler crashes/restarts, with a REVIEW LIST on top
  LogPullStatus.txt  - per-log diagnostic detail: was each log reachable, how many records
                       does this machine report, and the exact error if a pull failed/came back empty
  Minidumps\         - crash minidumps, if any were found and admin rights were available
  GPU_TDR_Dumps\     - LiveKernelReports crash dumps (GPU/TDR and other subsystems), if any were found
  MEMORY.DMP         - full memory dump, only present if you chose to include it
  NvidiaSmi.txt      - live NVIDIA GPU state, only present on NVIDIA systems
  DxDiag_Display.txt / DxDiag_Full.txt - dxdiag output, only present if admin rights were available
  NetworkState.txt   - live network snapshot: public IP + owning ISP/org (flagged if it matches
                       a known content-filtering/VPN provider - see the note at the top of the
                       file if so), SMB/file-share events with an automatic ANALYSIS (name-
                       resolution failures, connection-drop cadence, shares lost, which adapter
                       dropped) + client config (signing, guest logons, SMB1), mapped drives,
                       stored credentials and reachability of every server those name,
                       ipconfig, adapters, DNS config/cache/test, routing/ARP tables, hosts file,
                       proxy settings, active TCP connections, and any running/installed software
                       matching VPN/filter/security keywords - most useful when captured WHILE a
                       network problem is still happening
  StartupAndTasks.txt - light startup inventory: scheduled tasks (+ the account each runs
                       as), Run/RunOnce keys, startup folders, non-Windows services (+ their
                       logon account), running non-Windows programs and WHICH ACCOUNT they run
                       as, script-host processes, WMI subscriptions, Defender detections and
                       exclusions, local users/admins, remote-access tools. An inventory, not
                       a verdict - a REVIEW LIST at the top says what is worth a glance. For a
                       suspected infection use pull-persistence.v*.ps1 (the deep version).
  EspUsage.txt / EspUsage.csv - EFI System Partition check (needs admin): capacity, every file
                       by owner (Windows / HP / firmware capsule / other), duplicate payloads,
                       write timeline, BIOS + Secure Boot servicing context, and a verdict on
                       WHO filled it (Windows, HP, both, or just too small). Read-only.
  Microsoft-Windows-SmbClient_Connectivity.csv / ..._Security.csv - raw SMB client logs
                       (written only if the machine has events in the window)

Next step: copy the zip file (same name as this folder, .zip) off the machine (USB, NAS
share, etc.) and send it over - this was pulled locally, so nothing has left this machine yet.
"@

    $summary | Set-Content -Path $summaryPath -Encoding UTF8

    # Zip the whole output folder right alongside the transcript in $OutRoot - one
    # unmistakable file instead of a folder nested a level down, which is easy to miss
    # when copying files off a machine you don't normally use (2026-08-20: exactly this
    # happened - only the loose transcript got grabbed, not the real output).
    $zipPath = Join-Path $OutRoot "$(Split-Path $outDir -Leaf).zip"
    try {
        Compress-Archive -Path "$outDir\*" -DestinationPath $zipPath -Force
    } catch {
        Write-Host "Could not create zip (the folder itself is still fully saved at $outDir): $($_.Exception.Message)" -ForegroundColor Yellow
        $zipPath = $null
    }

    # --- Wrap up ---
    Write-Host ""
    Write-Host "=================================================" -ForegroundColor Cyan
    Write-Host " Done!" -ForegroundColor Green
    Write-Host " Saved to: $outDir" -ForegroundColor Cyan
    Write-Host " Total events: $($allEvents.Count)   Errors/Warnings: $($errorsAndWarnings.Count)" -ForegroundColor Cyan
    if ($bsodEvents.Count -gt 0 -or $unexplained.Count -gt 0) {
        Write-Host " BSODs: $($bsodEvents.Count)   Unexplained abrupt shutdowns: $($unexplained.Count)  -> see BSOD_Report.txt" -ForegroundColor Red
    } else {
        Write-Host " BSODs: 0   Unexplained abrupt shutdowns: 0" -ForegroundColor Cyan
    }
    Write-Host " GPU events: $($gpuOnlyEvents.Count)  -> see GPU_Report.txt" -ForegroundColor Cyan
    Write-Host " Print events: $($printEvents.Count) ($($printErrorsWarnings.Count) errors/warnings)  -> see Print_Report.txt" -ForegroundColor Cyan
    Write-Host " Network state captured -> see NetworkState.txt" -ForegroundColor Cyan
    if ($printAudit) { Write-Host " Print queue audit -> see PrintQueues.txt$(if ($printAudit.Flags.Count -gt 0) { " ($($printAudit.Flags.Count) item(s) flagged for review)" })" -ForegroundColor $(if ($printAudit.Flags.Count -gt 0) { 'Yellow' } else { 'Cyan' }) }
    if ($startupInv) { Write-Host " Startup inventory captured -> see StartupAndTasks.txt$(if ($startupInv.Flags.Count -gt 0) { " ($($startupInv.Flags.Count) item(s) flagged for review)" })" -ForegroundColor $(if ($startupInv.Flags.Count -gt 0) { 'Yellow' } else { 'Cyan' }) }
    if ($espUsage) { Write-Host " EFI System Partition check -> see EspUsage.txt$(if ($espUsage.Summary.Ran) { " ($($espUsage.Summary.FreeMB) MB free of $($espUsage.Summary.TotalMB) MB)" } else { " ($($espUsage.Summary.Call))" })" -ForegroundColor $(if ($espUsage.Summary.Ran -and $espUsage.Flags.Count -gt 0) { 'Yellow' } else { 'Cyan' }) }
    if ($ispFlagNote) {
        Write-Host ""
        Write-Host " >>> FLAG: connection is via a possible content-filtering ISP - see NetworkState.txt" -ForegroundColor Yellow
    }
    if ($pullStatus | Where-Object { $_.EventsPulled -eq 0 -or $_.PullError }) {
        Write-Host " One or more logs came back empty/failed - see LogPullStatus.txt" -ForegroundColor Red
    }
    Write-Host " Minidumps: $minidumpCount   GPU/TDR dumps: $liveKernelCount   Full dump: $(if ($fullDumpIncluded) {'included'} elseif ($fullDumpFound) {'found, not included'} else {'none'})" -ForegroundColor Cyan
    if ($zipPath) {
        Write-Host ""
        Write-Host " >>> COPY THIS FILE OFF THE MACHINE: $zipPath" -ForegroundColor Yellow
        Write-Host " (in $OutRoot - $outRootNote - next to this transcript, grab that one file)" -ForegroundColor Yellow
    } else {
        Write-Host " This was pulled locally - copy the folder off this machine (USB/NAS) to share it." -ForegroundColor Yellow
    }
    Write-Host "=================================================" -ForegroundColor Cyan
    Write-Host ""
    if (-not [Console]::IsInputRedirected) {
        Write-Host "Opening the folder now..."
        Invoke-Item $outDir
    }
}
catch {
    Write-Host "`n=================================================" -ForegroundColor Red
    Write-Host " ERROR - something went wrong:" -ForegroundColor Red
    Write-Host " [$($_.Exception.GetType().FullName)]" -ForegroundColor Red
    Write-Host " $($_.Exception.Message)" -ForegroundColor Red
    Write-Host " (at line $($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.Line.Trim()))" -ForegroundColor Red
    Write-Host "=================================================" -ForegroundColor Red
}
finally {
    try { Stop-Transcript | Out-Null } catch {}
    Write-Host "`nFull run log saved to: $transcriptPath" -ForegroundColor Cyan
    Write-Host "If anything looks wrong, send that log file here and I'll take a look."
    if (-not [Console]::IsInputRedirected) { Write-Host "`nPress Enter to close this window..." }
    if (-not [Console]::IsInputRedirected) { Read-Host | Out-Null }
}
