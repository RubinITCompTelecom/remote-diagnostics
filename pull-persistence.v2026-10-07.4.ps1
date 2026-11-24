<#
  pull-persistence.v2026-10-07.4.ps1
  READ-ONLY with respect to the system: nothing is changed, disabled, deleted or run.
  (It only WRITES its own output folder on the Desktop. The per-user registry section
  temporarily loads other users' NTUSER.DAT hives read-only and unloads them again.)

  v4 changes vs v3: elevation is detected from the token's integrity level (whoami /groups)
  instead of IsInRole (which reported False on a machine where the Security log and
  System32\Tasks were readable); loading other users' hives is ATTEMPTED regardless and
  failures are reported per user; header label fixed.

  v3 changes vs v2: Run/RunOnce and other autostart keys are now read from EVERY
  user's registry hive (v2 only saw the logged-in user's HKCU), hidden-scheduled-task
  check (System32\Tasks vs Task Scheduler vs TaskCache SD values), recent logon /
  RDP events, task-referenced .bat/.cmd files captured as samples.

  Lists everything on this PC that can make a script run by itself, and captures
  the evidence needed to judge a suspicious one BEFORE anyone cleans it up:
    - scheduled tasks (+ full XML export of every task that launches a script host
      or runs from an odd location, + Task Scheduler registration events)
    - Run/RunOnce, Startup folders, services, WMI subscriptions
    - live script-host / LOLBin processes with command lines and parent
    - script files in user areas, Public, Program Files, ProgramData, with SHA256
    - copies of small suspicious scripts (samples\) so they survive AV/cleanup
    - Defender detections WITH threat names, exclusions, quarantine history
    - local accounts, remote-access tools, hosts file, PowerShell history

  v2 changes vs v1: report is UTF-8 (v1 was UTF-16), task XML export, process
  command lines, Public + Program Files scanned, sample capture, Defender threat
  names/exclusions, Task Scheduler event 106/140/141, noise filtering.

  Run on the target PC, ELEVATED for full coverage:
    powershell -NoProfile -ExecutionPolicy Bypass -File "<full path>\pull-persistence.v2026-10-07.4.ps1"
  Switches: -NoSamples   do not copy suspicious script files into the output
            -OutRoot X   output parent folder (default: Desktop)
            -LogonDays N days of logon/RDP events to report (default 14)
  Output: <OutRoot>\Persistence_<PC>_<timestamp>\   (report.txt + CSVs + task_xml\ + samples\)
#>
param(
    [string]$OutRoot = [Environment]::GetFolderPath('Desktop'),
    [switch]$NoSamples,
    [int]$LogonDays = 14
)

$ErrorActionPreference = 'Continue'
$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$out   = Join-Path $OutRoot ("Persistence_{0}_{1}" -f $env:COMPUTERNAME, $stamp)
New-Item -ItemType Directory -Force -Path $out | Out-Null
$report = Join-Path $out 'report.txt'
[IO.File]::WriteAllText($report, '', (New-Object Text.UTF8Encoding($true)))

function Log($s)      { Write-Host $s; Add-Content -LiteralPath $report -Value $s -Encoding UTF8 }
function Section($t)  { Log ""; Log "===== $t =====" }
function Emit($o)     { $s = ($o | Out-String -Width 250).TrimEnd(); if ($s) { Log $s } else { Log '(none)' } }
function Csv($o,$name){
    $p = Join-Path $out $name
    if ($null -ne $o -and @($o).Count -gt 0) { @($o) | Export-Csv -LiteralPath $p -NoTypeInformation -Encoding UTF8 }
    else { [IO.File]::WriteAllText($p, '', (New-Object Text.UTF8Encoding($true))) }
}
function Safe-Name($n){ ($n -replace '[\\/:*?"<>|]', '_') }

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole('Administrator')
$isHigh  = $false; try { $isHigh = [bool]((& whoami.exe /groups 2>$null) -match 'S-1-16-(12288|16384)') } catch {}   # High / System integrity
$isAdmin = ($isAdmin -or $isHigh)
Log "Persistence pull v4 - $env:COMPUTERNAME - $(Get-Date) - elevated (admin/high integrity): $isAdmin"
if (-not $isAdmin) { Log "NOTE: NOT elevated - Defender detail, other users' hives, some tasks and event logs may be missing. Re-run as administrator." }

# ---------------------------------------------------------------- 1. TASKS
Section 'SCHEDULED TASKS (all non-Microsoft-path tasks)'
$allTasks = Get-ScheduledTask -ErrorAction SilentlyContinue
function Task-Run($t) { (($t.Actions | ForEach-Object { "$($_.Execute) $($_.Arguments)".Trim() }) -join ' | ') }
$tasks = $allTasks | Where-Object { $_.TaskPath -notlike '\Microsoft\*' } | ForEach-Object {
    $i = $_ | Get-ScheduledTaskInfo -ErrorAction SilentlyContinue
    [pscustomobject]@{
        Name = $_.TaskName; Path = $_.TaskPath; State = $_.State; RunAs = $_.Principal.UserId
        Author = $_.Author; Created = $_.Date
        Triggers = (($_.Triggers | ForEach-Object { $_.CimClass.CimClassName -replace 'MSFT_Task|Trigger','' }) -join ',')
        Run = (Task-Run $_); LastRun = $i.LastRunTime; LastResult = $i.LastTaskResult; NextRun = $i.NextRunTime
    }
}
Csv $tasks 'scheduled_tasks.csv'
Emit ($tasks | Format-List)

Section 'FLAGGED TASKS (script host / LOLBin / odd location, ANY path) - full XML saved to task_xml\'
$pat   = 'wscript|cscript|mshta|powershell|pwsh|rundll32|regsvr32|bitsadmin|certutil|\.vbs|\.vbe|\.ps1|\.js\b|\.jse|\.wsf|\.hta|AppData|\\Temp\\|\\Users\\Public|ProgramData'
# tasks under \Microsoft\ are mostly OS noise: only flag them for script hosts / user-writable paths
$patMs = 'wscript|cscript|mshta|powershell|pwsh|\.vbs|\.vbe|\.ps1|\.js\b|\.jse|\.wsf|\.hta|AppData|\\Temp\\|\\Users\\Public'
$flagged = $allTasks | Where-Object { if ($_.TaskPath -like '\Microsoft\*') { (Task-Run $_) -match $patMs } else { (Task-Run $_) -match $pat } }
$xmlDir = Join-Path $out 'task_xml'; New-Item -ItemType Directory -Force -Path $xmlDir | Out-Null
$flagRows = foreach ($t in $flagged) {
    try { Export-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath | Out-File -LiteralPath (Join-Path $xmlDir ((Safe-Name ($t.TaskPath + $t.TaskName)) + '.xml')) -Encoding UTF8 } catch {}
    [pscustomobject]@{ Name = $t.TaskName; Path = $t.TaskPath; State = $t.State; RunAs = $t.Principal.UserId; Author = $t.Author; Created = $t.Date; Run = (Task-Run $t) }
}
Csv $flagRows 'flagged_tasks.csv'
Emit ($flagRows | Format-List)

Section 'TASK SCHEDULER REGISTRATION EVENTS (106 = task registered, 140 = updated, 141 = deleted)'
try {
    $ev = Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-TaskScheduler/Operational'; Id = 106,140,141 } -MaxEvents 400 -ErrorAction Stop |
          Select-Object TimeCreated, Id, @{n='Detail';e={ ($_.Message -replace '\s+',' ') }}
    Csv $ev 'task_events.csv'
    Emit ($ev | Where-Object { $_.Detail -notmatch 'Microsoft\\|Google|OneDrive|Adobe|Dell|Edge' } | Format-Table -AutoSize -Wrap)
    Log '(all events in task_events.csv; if empty/missing the operational log may be disabled)'
} catch { Log "Could not read Task Scheduler log: $($_.Exception.Message)" }

# ---------------------------------------------------------------- 2. RUN KEYS
Section 'REGISTRY RUN / RUNONCE / WINLOGON-SHELL (machine-wide + the CURRENT user only - see per-user section below)'
$runKeys = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run','HKLM:\Software\Microsoft\Windows\CurrentVersion\RunOnce',
           'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run','HKCU:\Software\Microsoft\Windows\CurrentVersion\Run',
           'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce'
$runRows = foreach ($k in $runKeys) {
    $p = Get-ItemProperty -Path $k -ErrorAction SilentlyContinue
    if ($p) { $p.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' } | ForEach-Object { [pscustomobject]@{ Key = $k; Name = $_.Name; Value = $_.Value } } }
}
$wl = Get-ItemProperty 'HKLM:\Software\Microsoft\Windows NT\CurrentVersion\Winlogon' -ErrorAction SilentlyContinue
$runRows += [pscustomobject]@{ Key = 'Winlogon'; Name = 'Shell';    Value = $wl.Shell }
$runRows += [pscustomobject]@{ Key = 'Winlogon'; Name = 'Userinit'; Value = $wl.Userinit }
Csv $runRows 'run_keys.csv'
Emit ($runRows | Format-List)
Log '(Normal: Winlogon Shell = explorer.exe, Userinit = C:\Windows\system32\userinit.exe,)'

# ---------------------------------------------------------------- 2b. PER-USER HIVES
Section 'PER-USER AUTOSTART KEYS (EVERY profile; offline hives are loaded read-only then unloaded)'
if (-not $isAdmin) { Log 'NOTE: not detected as elevated - will still TRY to load other users'' hives; any that fail are listed at the end of this section.' }
$userKeys = @(
    'Software\Microsoft\Windows\CurrentVersion\Run',
    'Software\Microsoft\Windows\CurrentVersion\RunOnce',
    'Software\Microsoft\Windows\CurrentVersion\RunServices',
    'Software\Microsoft\Windows\CurrentVersion\Policies\Explorer\Run',
    'Software\Microsoft\Windows NT\CurrentVersion\Windows',      # Load / Run values
    'Software\Microsoft\Windows NT\CurrentVersion\Winlogon',     # per-user Shell override
    'Environment'                                                # UserInitMprLogonScript
)
$userVals = 'Load','Run','Shell','UserInitMprLogonScript'        # for the 3 non-Run keys only report these names
$profList = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'
$userRows = New-Object System.Collections.ArrayList
$hiveNote = New-Object System.Collections.ArrayList
Get-ChildItem $profList -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match '^S-1-5-21-' } | ForEach-Object {
    $sid  = $_.PSChildName
    $path = (Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue).ProfileImagePath
    $name = if ($path) { Split-Path $path -Leaf } else { $sid }
    $root = $null; $loadedByMe = $false; $tmp = $null
    if (Test-Path "Registry::HKEY_USERS\$sid") { $root = "Registry::HKEY_USERS\$sid" }
    elseif ($path -and (Test-Path -LiteralPath (Join-Path $path 'NTUSER.DAT'))) {
        $tmp = 'RIT_' + ($sid -replace '[^0-9]','')
        $null = & reg.exe load "HKU\$tmp" (Join-Path $path 'NTUSER.DAT') 2>&1
        if ($LASTEXITCODE -eq 0) { $root = "Registry::HKEY_USERS\$tmp"; $loadedByMe = $true }
        else { [void]$hiveNote.Add("could not load hive for $name ($sid) - " + $(if ($isAdmin) { 'in use or access denied' } else { 'needs an elevated run (right-click > Run as administrator)' })) }
    } else { [void]$hiveNote.Add("skipped $name ($sid): hive not loaded" + $(if (-not $isAdmin) { ' (and not elevated)' } else { ' and NTUSER.DAT not found' })) }
    if ($root) {
        foreach ($k in $userKeys) {
            $p = Get-ItemProperty -Path (Join-Path $root $k) -ErrorAction SilentlyContinue
            if (-not $p) { continue }
            $isRun = $k -match '\\Run(Once|Services)?$|Explorer\\Run$'
            foreach ($pr in ($p.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' })) {
                if (-not $isRun -and $userVals -notcontains $pr.Name) { continue }
                [void]$userRows.Add([pscustomobject]@{ User = $name; SID = $sid; Key = $k; Name = $pr.Name; Value = [string]$pr.Value })
            }
        }
    }
    if ($loadedByMe) {
        [gc]::Collect(); [gc]::WaitForPendingFinalizers(); Start-Sleep -Milliseconds 300
        $null = & reg.exe unload "HKU\$tmp" 2>&1
        if ($LASTEXITCODE -ne 0) { [void]$hiveNote.Add("WARNING: could not unload HKU\$tmp - it will release on reboot; harmless") }
    }
}
Csv $userRows 'user_autostart_keys.csv'
Emit ($userRows | Format-List)
foreach ($n in $hiveNote) { Log $n }
Log '(Per-user Run/RunOnce entries normally hold OneDrive, Edge/Teams autolaunch, etc. Anything pointing at wscript/powershell/Public/Temp/AppData script files is suspect.)'

# ---------------------------------------------------------------- 2c. HIDDEN TASKS
Section 'HIDDEN / UNREGISTERED SCHEDULED TASKS (files in System32\Tasks and TaskCache keys that Get-ScheduledTask does not show)'
try {
    $known = @{}; foreach ($t in $allTasks) { $known[(($t.TaskPath + $t.TaskName) -replace '^\\','').ToLower()] = $true }
    $taskRoot = "$env:SystemRoot\System32\Tasks"
    $files = Get-ChildItem -LiteralPath $taskRoot -Recurse -Force -File -ErrorAction Stop
    $orphans = foreach ($f in $files) {
        $rel = $f.FullName.Substring($taskRoot.Length).TrimStart('\')
        if (-not $known.ContainsKey($rel.ToLower())) { [pscustomobject]@{ Kind = 'file in Tasks\ but not listed by Task Scheduler'; Item = $rel; Modified = $f.LastWriteTime } }
    }
    Emit $orphans
    if (-not $orphans) { Log '(none: every file in System32\Tasks is a listed task)' }
} catch { Log "Could not read $env:SystemRoot\System32\Tasks (needs elevation): $($_.Exception.Message)" }
try {
    $tree = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\TaskCache\Tree'
    $noSd = Get-ChildItem $tree -Recurse -ErrorAction Stop | Where-Object { (Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue).PSObject.Properties.Name -contains 'Id' -and
                                                                               -not ((Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue).PSObject.Properties.Name -contains 'SD') } |
             ForEach-Object { [pscustomobject]@{ Kind = 'TaskCache entry WITHOUT Security Descriptor (hidden-task trick)'; Item = ($_.Name -replace '^.*\\Schedule\\TaskCache\\Tree\\','') } }
    Emit $noSd
    if (-not $noSd) { Log '(none: no TaskCache entries are missing their SD value)' }
} catch { Log "Could not read TaskCache: $($_.Exception.Message)" }

# ---------------------------------------------------------------- 3. STARTUP FOLDERS
Section 'STARTUP FOLDERS (desktop.ini is normal)'
$startDirs = @("$env:ProgramData\Microsoft\Windows\Start Menu\Programs\Startup")
$startDirs += Get-ChildItem 'C:\Users' -Directory -Force -ErrorAction SilentlyContinue | ForEach-Object { Join-Path $_.FullName 'AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup' }
$startRows = foreach ($d in $startDirs) { Get-ChildItem $d -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'desktop.ini' } | Select-Object FullName, Length, CreationTime, LastWriteTime }
Csv $startRows 'startup_folders.csv'
Emit $startRows

# ---------------------------------------------------------------- 4. SERVICES
Section 'SERVICES (running from outside System32)'
$svc = Get-CimInstance Win32_Service -ErrorAction SilentlyContinue | Where-Object { $_.PathName -and $_.PathName -notmatch 'system32|SysWOW64|Windows Defender|WindowsApps' } |
    Select-Object Name, DisplayName, State, StartMode, StartName, PathName
Csv $svc 'services.csv'
Emit ($svc | Format-List)

# ---------------------------------------------------------------- 5. WMI
Section 'WMI PERMANENT EVENT SUBSCRIPTIONS (only "SCM Event Log ..." is normal)'
Emit (Get-CimInstance -Namespace root\subscription -ClassName __EventConsumer -ErrorAction SilentlyContinue | Select-Object __CLASS, Name)
Emit (Get-CimInstance -Namespace root\subscription -ClassName __FilterToConsumerBinding -ErrorAction SilentlyContinue | Select-Object Filter, Consumer)

# ---------------------------------------------------------------- 6. LIVE PROCESSES
Section 'LIVE SCRIPT-HOST / LOLBIN PROCESSES (what is running RIGHT NOW)'
$procPat = 'wscript.exe|cscript.exe|mshta.exe|powershell.exe|pwsh.exe|rundll32.exe|regsvr32.exe|bitsadmin.exe|certutil.exe|AddInProcess32.exe|AddInProcess.exe|InstallUtil.exe|MSBuild.exe|RegAsm.exe|RegSvcs.exe|msiexec.exe'
$allProc = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue
$byId = @{}; foreach ($p in $allProc) { $byId[[int]$p.ProcessId] = $p }
$procs = $allProc | Where-Object { $_.Name -match "^($procPat)$" -and $_.ProcessId -ne $PID } | ForEach-Object {
    $owner = $null; try { $o = Invoke-CimMethod -InputObject $_ -MethodName GetOwner -ErrorAction Stop; $owner = "$($o.Domain)\$($o.User)" } catch {}
    $par = $byId[[int]$_.ParentProcessId]
    [pscustomobject]@{ PID = $_.ProcessId; Name = $_.Name; User = $owner; Started = $_.CreationDate; Parent = $(if ($par) { "$($par.Name) ($($par.ProcessId))" } else { "gone ($($_.ParentProcessId))" }); CommandLine = $_.CommandLine }
}
Csv $procs 'processes.csv'
Emit ($procs | Format-List)
Log '(AddInProcess32/MSBuild/RegAsm etc. running with NO command line, or under wscript/powershell, is a classic injection-loader sign)'

Section 'NETWORK CONNECTIONS owned by those processes'
try {
    $ids = @($procs | ForEach-Object { $_.PID })
    if ($ids.Count) { Emit (Get-NetTCPConnection -ErrorAction Stop | Where-Object { $ids -contains $_.OwningProcess -and $_.State -ne 'Listen' } |
        Select-Object OwningProcess, LocalPort, RemoteAddress, RemotePort, State) }
    else { Log '(no such processes)' }
} catch { Log "Could not read connections: $($_.Exception.Message)" }

# ---------------------------------------------------------------- 7. SCRIPT FILES
Section 'SCRIPT FILES (user areas, Public, Program Files, ProgramData, Temp) - noise filtered, SHA256 included'
$ext = '*.vbs','*.vbe','*.vb','*.ps1','*.js','*.jse','*.wsf','*.hta','*.bat','*.cmd'
$roots = @('C:\Users','C:\ProgramData','C:\Program Files','C:\Program Files (x86)','C:\Windows\Temp') | Where-Object { Test-Path $_ }
$noise = '\\(node_modules|\.git|Python\d+|site-packages|WindowsApps|Packages|npm-cache|chocolatey|Package Cache|OneDrive\\[\d\.]+\\WebAssets|Extensions|Edge\\User Data|Chrome\\Application|Microsoft\\Edge|Microsoft\\EdgeUpdate|Google\\Chrome|Windows Defender|Microsoft Office|Common Files\\Microsoft Shared|dotnet|Microsoft\.NET|Microsoft SDKs|Windows Kits|Dell\\|Brother|Malwarebytes|Splashtop|Adobe|Intel|Realtek|Waves|Microsoft Update Health Tools)\\'
$scripts = foreach ($r in $roots) {
    Get-ChildItem -Path $r -Include $ext -Recurse -Force -File -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch $noise -and $_.FullName -notmatch '^C:\\Users\\All Users\\' } |
        ForEach-Object {
            $h = $null; if ($_.Length -gt 0 -and $_.Length -lt 20MB) { try { $h = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256 -ErrorAction Stop).Hash } catch {} }
            [pscustomobject]@{ FullName = $_.FullName; Length = $_.Length; Created = $_.CreationTime; Modified = $_.LastWriteTime; SHA256 = $h }
        }
}
$scripts = @($scripts | Sort-Object Modified -Descending)
Csv $scripts 'script_files.csv'
Emit ($scripts | Select-Object -First 80 FullName, Length, Modified | Format-Table -AutoSize)
Log "($($scripts.Count) files after noise filter; full list with hashes in script_files.csv)"

Section 'C:\Users\Public (all contents - a favourite drop location)'
Emit (Get-ChildItem 'C:\Users\Public' -Recurse -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'desktop.ini' } | Select-Object FullName, Length, CreationTime, LastWriteTime)

Section 'Files named in flagged tasks - do they exist?'
foreach ($t in $flagged) {
    foreach ($a in $t.Actions) {
        $m = [regex]::Matches("$($a.Execute) $($a.Arguments)", '[A-Za-z]:\\[^"|<>]+?\.(vbs|vbe|ps1|js|jse|wsf|hta|bat|cmd|exe|dll)')
        foreach ($x in $m) {
            $p = [Environment]::ExpandEnvironmentVariables($x.Value.Trim())
            Log ("{0,-8} {1}   <- task '{2}'" -f $(if (Test-Path -LiteralPath $p) { 'EXISTS' } else { 'MISSING' }), $p, $t.TaskName)
        }
    }
}


# ---------------------------------------------------------------- 8. SAMPLES
if (-not $NoSamples) {
    Section 'SAMPLE CAPTURE (copies of suspicious small scripts -> samples\) - these are POTENTIAL MALWARE, do not double-click'
    $sampleDir = Join-Path $out 'samples'; New-Item -ItemType Directory -Force -Path $sampleDir | Out-Null
    $cand = New-Object System.Collections.ArrayList
    foreach ($s in $scripts) {
        if ($s.Length -gt 0 -and $s.Length -lt 1MB -and $s.FullName -match '\.(vbs|vbe|ps1|js|jse|wsf|hta)$' -and
            ($s.FullName -match '\\Users\\Public\\|\\Program Files\\MiniAntiVirus|\\AppData\\(Local|Roaming)\\Temp\\|\\Desktop\\|\\Downloads\\|\\Startup\\|\\ProgramData\\[^\\]+\.(vbs|vbe|ps1|js)$')) { [void]$cand.Add($s.FullName) }
    }
    foreach ($t in $flagged) { foreach ($a in $t.Actions) {
        foreach ($x in [regex]::Matches("$($a.Execute) $($a.Arguments)", '[A-Za-z]:\\[^"|<>]+?\.(vbs|vbe|ps1|js|jse|wsf|hta|bat|cmd)')) {
            $p = [Environment]::ExpandEnvironmentVariables($x.Value.Trim()); if (Test-Path -LiteralPath $p) { [void]$cand.Add($p) }
        } } }
    $n = 0
    foreach ($f in ($cand | Select-Object -Unique)) {
        # skip the screenconnect-cleanup toolkit, this tool's own files, and the owner's own MiniAntiVirus tool
        if ($f -match 'screenconnect-cleanup|pull-persistence|Run-PullPersistence|MiniAntiVirus') { continue }
        try { $n++; Copy-Item -LiteralPath $f -Destination (Join-Path $sampleDir ("{0:D3}_{1}.sample" -f $n, (Safe-Name (Split-Path $f -Leaf)))) -ErrorAction Stop; Log "copied: $f" } catch { Log "FAILED to copy $f : $($_.Exception.Message)" }
    }
    Log "$n sample(s) copied. Source paths are listed above; names in samples\ are numbered with a .sample extension so they cannot run."
}

# ---------------------------------------------------------------- 9. DEFENDER
Section 'DEFENDER THREAT DETECTIONS (with names)'
try {
    $threats = @{}; Get-MpThreat -ErrorAction SilentlyContinue | ForEach-Object { $threats[[int64]$_.ThreatID] = $_ }
    $det = Get-MpThreatDetection -ErrorAction Stop | Sort-Object InitialDetectionTime -Descending | ForEach-Object {
        $th = $threats[[int64]$_.ThreatID]
        [pscustomobject]@{ Time = $_.InitialDetectionTime; ThreatID = $_.ThreatID; ThreatName = $(if ($th) { $th.ThreatName } else { '(name not in cache)' }); Process = $_.ProcessName; Resources = ($_.Resources -join '; '); ActionSuccess = $_.ActionSuccess; User = $_.DomainUser }
    }
    Csv $det 'defender_detections.csv'
    Emit ($det | Select-Object -First 40 | Format-List)
} catch { Log "Defender query failed (is Defender the active AV? elevated?): $($_.Exception.Message)" }
Section 'DEFENDER EXCLUSIONS (malware often adds these)'
try { $mp = Get-MpPreference -ErrorAction Stop; Emit ([pscustomobject]@{ ExclusionPath = ($mp.ExclusionPath -join '; '); ExclusionProcess = ($mp.ExclusionProcess -join '; '); ExclusionExtension = ($mp.ExclusionExtension -join '; '); DisableRealtimeMonitoring = $mp.DisableRealtimeMonitoring }) } catch { Log "n/a: $($_.Exception.Message)" }
Section 'ACTIVE ANTIVIRUS PRODUCTS (Security Center)'
Emit (Get-CimInstance -Namespace root\SecurityCenter2 -ClassName AntiVirusProduct -ErrorAction SilentlyContinue | Select-Object displayName, productState)

# ---------------------------------------------------------------- 10. ACCOUNTS / REMOTE TOOLS / MISC
Section "LOGON ACTIVITY, last $LogonDays days (4624 types 2=console 7=unlock 10=RDP; needs elevation)"
try {
    $since = (Get-Date).AddDays(-$LogonDays)
    $lg = Get-WinEvent -FilterHashtable @{ LogName = 'Security'; Id = 4624; StartTime = $since } -ErrorAction Stop | ForEach-Object {
        $x = [xml]$_.ToXml(); $d = @{}; foreach ($i in $x.Event.EventData.Data) { $d[$i.Name] = $i.'#text' }
        if (@('2','7','10','11') -contains $d.LogonType) { [pscustomobject]@{ Time = $_.TimeCreated; Type = $d.LogonType; User = $d.TargetUserName; IP = $d.IpAddress; Process = $d.ProcessName } }
    }
    Csv $lg 'logons.csv'
    Log 'Summary (count by user / type / source IP):'
    Emit ($lg | Group-Object User, Type, IP | Sort-Object Count -Descending | Select-Object Count, Name | Format-Table -AutoSize)
    Log 'Every type-10 (RDP) logon:'
    Emit ($lg | Where-Object Type -eq '10' | Format-Table -AutoSize)
} catch { Log "Could not read Security log (needs elevation, or no events): $($_.Exception.Message)" }
try {
    Section 'RDP INBOUND AUTH (1149) / SESSION EVENTS (21,22,24,25)'
    $r1 = Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-TerminalServices-RemoteConnectionManager/Operational'; Id = 1149; StartTime = $since } -ErrorAction SilentlyContinue | Select-Object TimeCreated, Id, @{n='Detail';e={ ($_.Message -replace '\s+',' ') }}
    $r2 = Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-TerminalServices-LocalSessionManager/Operational'; Id = 21,22,24,25; StartTime = $since } -ErrorAction SilentlyContinue | Select-Object TimeCreated, Id, @{n='Detail';e={ ($_.Message -replace '\s+',' ') }}
    Emit $r1; Emit $r2
} catch { Log "RDP logs unreadable: $($_.Exception.Message)" }

Section 'LOCAL USERS / ADMINS'
Emit (Get-LocalUser -ErrorAction SilentlyContinue | Select-Object Name, Enabled, LastLogon, PasswordLastSet, Description)
Emit (Get-LocalGroupMember -Group 'Administrators' -ErrorAction SilentlyContinue | Select-Object Name, ObjectClass)
Section 'REMOTE-ACCESS TOOLS (installed programs / services)'
$rpat = 'AnyDesk|TeamViewer|Splashtop|ScreenConnect|ConnectWise|RustDesk|UltraVNC|TightVNC|RealVNC|LogMeIn|Ammyy|Supremo|Chrome Remote|Atera|NetSupport|RemotePC|Radmin|DWService|MeshAgent|ZohoAssist|Zoho Assist|Action1|Level\.io|Datto|Kaseya|N-able|Syncro|Pulseway'
$prog = Get-ItemProperty 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*','HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName -match $rpat } | Select-Object DisplayName, DisplayVersion, InstallDate, Publisher
Emit ($prog | Format-Table -AutoSize)
Emit (Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.Name -match $rpat -or $_.DisplayName -match $rpat } | Select-Object Name, DisplayName, Status, StartType)

Section 'HOSTS FILE (non-comment lines)'
Emit (Get-Content "$env:SystemRoot\System32\drivers\etc\hosts" -ErrorAction SilentlyContinue | Where-Object { $_ -and $_ -notmatch '^\s*#' })

Section 'POWERSHELL HISTORY (PSReadLine, every profile, last 60 lines each)'
Get-ChildItem 'C:\Users' -Directory -Force -ErrorAction SilentlyContinue | ForEach-Object {
    $h = Join-Path $_.FullName 'AppData\Roaming\Microsoft\Windows\PowerShell\PSReadLine\ConsoleHost_history.txt'
    if (Test-Path -LiteralPath $h) { Log "--- $h"; Emit (Get-Content -LiteralPath $h -Tail 60 -ErrorAction SilentlyContinue) }
}

Section 'DONE'
Log "Output folder: $out"
Log "Send the whole folder (zip it) for analysis. samples\ may trigger antivirus - zip with a password (e.g. 'infected') if needed."
