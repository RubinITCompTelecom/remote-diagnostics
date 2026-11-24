<#
.SYNOPSIS
  Why is the EFI System Partition (ESP) full, and who filled it - Windows, HP, or both?

.DESCRIPTION
  READ-ONLY. Mounts the ESP on a spare drive letter, inventories every file, attributes each
  one to an owner (Windows boot files / HP / firmware capsule staging / other vendor / unknown),
  hashes files to find duplicate payloads, buckets writes by month, and pulls the context that
  usually explains growth (BIOS + firmware devices, HP software, Secure Boot servicing state,
  Windows Update firmware events). Ends with a verdict that says which side the evidence points to.

  It never deletes or modifies anything on the ESP. It unmounts the letter it mounted on exit.

  Needs admin (self-elevates). PowerShell 5.1 compatible, pure ASCII. Windows only - an ESP
  inspection has no Linux equivalent here (on WSL2 run it via powershell.exe on the host).

  Output: console + EspReport_<PC>_<timestamp>.txt and .csv (full file list) in -OutDir
  (default: the logged-in user's Desktop).

.PARAMETER OutDir   Where to write the report/CSV.
.PARAMETER NoHash   Skip SHA-256 duplicate detection.
.PARAMETER Top      How many largest files to list (default 25).
#>
[CmdletBinding()]
param(
    [string]$OutDir,
    [switch]$NoHash,
    [int]$Top = 25
)

$ScriptVersion = '2026-10-25.1'
$ErrorActionPreference = 'Continue'

# ---- elevation -------------------------------------------------------------------------
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
$isAdmin = ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host 'Not elevated - relaunching as administrator...'
    if ($PSCommandPath) {
        $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit', '-File', ('"{0}"' -f $PSCommandPath))
        if ($NoHash) { $a += '-NoHash' }
        if ($OutDir) { $a += @('-OutDir', ('"{0}"' -f $OutDir)) }
        if ($Top -ne 25) { $a += @('-Top', "$Top") }
        Start-Process powershell.exe -Verb RunAs -ArgumentList $a
    }
    exit
}

# ---- output plumbing -------------------------------------------------------------------
$script:R = New-Object System.Collections.Generic.List[string]
function W([string]$s = '') { $script:R.Add($s); Write-Host $s }
function Sec([string]$s) { W ''; W ('=' * 78); W $s; W ('=' * 78) }
function T($obj) {
    $t = ($obj | Format-Table -AutoSize | Out-String -Width 220).TrimEnd()
    if ($t) { W $t }
}
function Fmt([double]$b) {
    if ($b -ge 1MB) { return ('{0:N1} MB' -f ($b / 1MB)) }
    if ($b -ge 1KB) { return ('{0:N1} KB' -f ($b / 1KB)) }
    return ('{0} B' -f [int]$b)
}
function Try-Events($filter, $max) {
    try { return @(Get-WinEvent -FilterHashtable $filter -MaxEvents $max -ErrorAction Stop) } catch { return @() }
}

if (-not $OutDir) {
    $OutDir = [Environment]::GetFolderPath('Desktop')
    if (-not $OutDir -or -not (Test-Path -LiteralPath $OutDir)) { $OutDir = Join-Path $env:PUBLIC 'Desktop' }
    if (-not (Test-Path -LiteralPath $OutDir)) { $OutDir = $env:TEMP }
}
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$reportPath = Join-Path $OutDir ("EspReport_{0}_{1}.txt" -f $env:COMPUTERNAME, $stamp)
$csvPath = Join-Path $OutDir ("EspReport_{0}_{1}.csv" -f $env:COMPUTERNAME, $stamp)

# ---- ownership classifier --------------------------------------------------------------
function Get-Owner([string]$rel) {
    $p = $rel.Split('\')
    $l = $rel.ToLowerInvariant()
    $dirParts = @()
    if ($p.Count -gt 1) { $dirParts = $p[0..($p.Count - 2)] }
    $kind3 = if ($dirParts.Count -eq 0) { '(root files)' } else { ($dirParts[0..([Math]::Min($dirParts.Count, 3) - 1)] -join '\') }

    if ($l -like 'efi\updatecapsule*') { return [pscustomobject]@{ Bucket = 'Capsule'; Kind = 'EFI\UpdateCapsule' } }
    # HP: EFI\HP\*, root HPFWUPDREC / HP* folders (HP BIOS-update + recovery staging)
    if (($p.Count -ge 2 -and $p[0] -ieq 'EFI' -and $p[1] -match '^hp') -or $p[0] -match '^hp') {
        return [pscustomobject]@{ Bucket = 'HP'; Kind = $kind3 }
    }
    if ($l -like 'efi\microsoft\boot\fonts*') { return [pscustomobject]@{ Bucket = 'Windows'; Kind = 'Boot fonts' } }
    if ($l -like 'efi\microsoft\boot\resources*') { return [pscustomobject]@{ Bucket = 'Windows'; Kind = 'Boot resources' } }
    if ($l -like 'efi\microsoft\recovery*') { return [pscustomobject]@{ Bucket = 'Windows'; Kind = 'WinRE/recovery BCD' } }
    if ($p.Count -ge 5 -and $p[0] -ieq 'EFI' -and $p[1] -ieq 'Microsoft' -and $p[2] -ieq 'Boot' -and
        $p[3] -match '^[a-z]{2,3}-[a-z0-9]{2,8}(-[a-z0-9]+)?$') {
        return [pscustomobject]@{ Bucket = 'Windows'; Kind = 'Boot language folders (xx-XX)' }
    }
    if ($l -like 'efi\microsoft\boot*') { return [pscustomobject]@{ Bucket = 'Windows'; Kind = 'Boot manager / BCD' } }
    if ($l -like 'efi\microsoft*') { return [pscustomobject]@{ Bucket = 'Windows'; Kind = 'EFI\Microsoft (other)' } }
    if ($l -like 'efi\boot*') { return [pscustomobject]@{ Bucket = 'Windows'; Kind = 'EFI\Boot fallback loader' } }
    if ($p.Count -ge 2 -and $p[0] -ieq 'EFI') { return [pscustomobject]@{ Bucket = 'Other'; Kind = ('EFI\' + $p[1]) } }
    return [pscustomobject]@{ Bucket = 'Unknown'; Kind = $kind3 }
}

# ---- mount the ESP ---------------------------------------------------------------------
$espGuid = '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'
$letter = $null
$weMounted = $false

try {
    W "ESP usage check v$ScriptVersion   $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')   host: $env:COMPUTERNAME"

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

    # ---- 1. partition + capacity -------------------------------------------------------
    Sec '1. PARTITION AND CAPACITY'
    $di = New-Object IO.DriveInfo($letter)
    $total = [double]$di.TotalSize
    $free = [double]$di.AvailableFreeSpace
    $usedFs = $total - $free
    W ("ESP mounted at {0}  filesystem {1}" -f $root, $di.DriveFormat)
    W ("Total {0}   Used {1} ({2:N0}%)   FREE {3}" -f (Fmt $total), (Fmt $usedFs), (100 * $usedFs / $total), (Fmt $free))
    foreach ($ep in $espParts) {
        $parts = Get-Partition -DiskNumber $ep.DiskNumber | Sort-Object Offset
        W ''
        W ("Disk {0} layout (an ESP can only grow into free/shrinkable space right after it):" -f $ep.DiskNumber)
        T ($parts | Select-Object PartitionNumber, Type, @{n = 'Size'; e = { Fmt $_.Size } }, @{n = 'OffsetMB'; e = { [int]($_.Offset / 1MB) } })
    }

    # ---- 2. inventory ------------------------------------------------------------------
    Sec '2. FILE INVENTORY'
    $gcErr = @()
    $raw = @(Get-ChildItem -LiteralPath $root -Recurse -Force -File -ErrorAction SilentlyContinue -ErrorVariable gcErr)
    $files = foreach ($f in $raw) {
        $rel = $f.FullName.Substring($root.Length)
        $o = Get-Owner $rel
        [pscustomobject]@{
            Rel       = $rel
            Length    = [double]$f.Length
            LastWrite = $f.LastWriteTime
            Bucket    = $o.Bucket
            Kind      = $o.Kind
            Leftover  = [bool]($f.Name -match '\.(bak|old|tmp|bkp|prev)$|\.log\d*$|~$|\.efi\.(bak|old|tmp|prev|\d+)$')
            Hash      = ''
        }
    }
    $files = @($files)
    $sum = ($files | Measure-Object Length -Sum).Sum
    if (-not $sum) { $sum = 0 }
    W ("{0} files, {1} total file bytes. Filesystem says {2} used; difference {3} = FAT cluster slack + directory metadata." -f $files.Count, (Fmt $sum), (Fmt $usedFs), (Fmt ($usedFs - $sum)))
    if ($gcErr.Count) { W ("({0} paths could not be read - totals may be slightly low)" -f $gcErr.Count) }

    W ''
    W 'Bytes by owner:'
    $byBucket = $files | Group-Object Bucket | ForEach-Object {
        $s = ($_.Group | Measure-Object Length -Sum).Sum
        [pscustomobject]@{ Owner = $_.Name; Files = $_.Count; Size = Fmt $s; Bytes = $s; Pct = if ($sum) { '{0:N0}%' -f (100 * $s / $sum) } else { '-' } }
    } | Sort-Object Bytes -Descending
    T ($byBucket | Select-Object Owner, Files, Size, Pct)

    W ''
    W 'Bytes by folder / kind:'
    $byKind = $files | Group-Object Bucket, Kind | ForEach-Object {
        $s = ($_.Group | Measure-Object Length -Sum).Sum
        [pscustomobject]@{ Owner = $_.Group[0].Bucket; Where = $_.Group[0].Kind; Files = $_.Count; Size = Fmt $s; Bytes = $s }
    } | Sort-Object Bytes -Descending
    T ($byKind | Select-Object Owner, Where, Files, Size)

    W ''
    W ("Largest {0} files:" -f $Top)
    T ($files | Sort-Object Length -Descending | Select-Object -First $Top @{n = 'Size'; e = { Fmt $_.Length } }, Bucket, @{n = 'Modified'; e = { $_.LastWrite.ToString('yyyy-MM-dd') } }, Rel)

    $left = @($files | Where-Object { $_.Leftover })
    W ''
    if ($left.Count) {
        W ("Leftover-looking files (.bak/.old/.tmp/.log/.efi.bak): {0} files, {1}" -f $left.Count, (Fmt (($left | Measure-Object Length -Sum).Sum)))
        T ($left | Sort-Object Length -Descending | Select-Object -First 15 @{n = 'Size'; e = { Fmt $_.Length } }, Bucket, Rel)
    } else {
        W 'Leftover-looking files: none.'
    }

    # ---- 3. duplicates -----------------------------------------------------------------
    Sec '3. DUPLICATE PAYLOADS (same SHA-256 stored more than once)'
    $dupGroups = @()
    $dupWaste = 0
    if ($NoHash) {
        W 'Skipped (-NoHash).'
    } else {
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
        } else {
            W 'No duplicate files >= 64 KB.'
        }
    }

    # ---- 4. timeline -------------------------------------------------------------------
    Sec '4. WHEN WAS IT WRITTEN (last-write month x owner)'
    $months = $files | Group-Object { $_.LastWrite.ToString('yyyy-MM') } | Sort-Object Name | ForEach-Object {
        $g = $_.Group
        $row = [ordered]@{ Month = $_.Name; Files = $_.Count; Size = Fmt (($g | Measure-Object Length -Sum).Sum) }
        foreach ($b in 'Windows', 'HP', 'Capsule', 'Other', 'Unknown') {
            $s = ($g | Where-Object { $_.Bucket -eq $b } | Measure-Object Length -Sum).Sum
            $row[$b] = if ($s) { Fmt $s } else { '-' }
        }
        [pscustomobject]$row
    }
    T $months
    W ''
    W 'Newest 12 files:'
    T ($files | Sort-Object LastWrite -Descending | Select-Object -First 12 @{n = 'Modified'; e = { $_.LastWrite.ToString('yyyy-MM-dd HH:mm') } }, Bucket, @{n = 'Size'; e = { Fmt $_.Length } }, Rel)

    # ---- 5. system context -------------------------------------------------------------
    Sec '5. SYSTEM CONTEXT'
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
    $fw = @(Get-CimInstance Win32_PnPSignedDriver -ErrorAction SilentlyContinue | Where-Object { $_.DeviceClass -eq 'FIRMWARE' })
    if ($fw.Count) { T ($fw | Select-Object DeviceName, Manufacturer, DriverVersion, @{n = 'DriverDate'; e = { if ($_.DriverDate) { $_.DriverDate.ToString('yyyy-MM-dd') } } }) } else { W '  (none reported)' }

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
    $wu = @(Try-Events @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WindowsUpdateClient'; Id = 19, 20 } 600 |
            Where-Object { $_.Message -match 'firmware|BIOS|\bHP\b|Secure Boot|System Firmware' } | Select-Object -First 15)
    if ($wu.Count) {
        foreach ($e in $wu) { W ("  {0}  id {1}  {2}" -f $e.TimeCreated.ToString('yyyy-MM-dd'), $e.Id, (($e.Message -split "`r?`n")[0..([Math]::Min(1, ($e.Message -split "`r?`n").Count - 1))] -join ' ')) }
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

    # ---- 6. verdict --------------------------------------------------------------------
    Sec '6. VERDICT - WINDOWS, HP, OR BOTH?'
    function Bk([string]$n) { $x = ($files | Where-Object { $_.Bucket -eq $n } | Measure-Object Length -Sum).Sum; if ($x) { [double]$x } else { 0.0 } }
    $winB = Bk 'Windows'; $hpB = Bk 'HP'; $capB = Bk 'Capsule'; $othB = Bk 'Other'; $unkB = Bk 'Unknown'
    $localeFiles = @($files | Where-Object { $_.Kind -eq 'Boot language folders (xx-XX)' })
    $localeDirs = @($localeFiles | ForEach-Object { $_.Rel.Split('\')[3] } | Select-Object -Unique)
    $hpDupes = @($dupGroups | Where-Object { ($_.Group | Where-Object { $_.Bucket -in 'HP', 'Capsule' }).Count -gt 1 })
    $hpBigMonths = @($files | Where-Object { $_.Bucket -eq 'HP' -and $_.Length -ge 1MB } | ForEach-Object { $_.LastWrite.ToString('yyyy-MM') } | Select-Object -Unique)

    $hpEv = New-Object System.Collections.Generic.List[string]
    $winEv = New-Object System.Collections.Generic.List[string]
    $envEv = New-Object System.Collections.Generic.List[string]

    # HP side
    if ($usedFs -gt 0 -and ($hpB / $usedFs) -ge 0.30) { $hpEv.Add(("HP-owned files are {0} = {1:N0}% of the used space." -f (Fmt $hpB), (100 * $hpB / $usedFs))) }
    if ($hpDupes.Count) { $hpEv.Add(("{0} identical HP/capsule payload(s) stored more than once - HP's updater is re-staging without removing the old copy." -f $hpDupes.Count)) }
    if ($hpBigMonths.Count -gt 1) { $hpEv.Add(("HP payloads >= 1 MB written in {0} different months ({1}) and none were cleaned up - old BIOS/firmware generations are accumulating." -f $hpBigMonths.Count, ($hpBigMonths -join ', '))) }
    if ($capB -gt 0) { $hpEv.Add(("{0} sits in EFI\UpdateCapsule. Firmware is supposed to consume AND delete it on the next boot; a leftover means the firmware did not clean up (vendor/firmware side), or the flash failed and Windows keeps re-staging it (check the failed id 20 events above - that would make it both)." -f (Fmt $capB))) }

    # Windows side
    if ($localeDirs.Count -gt 30 -and $winB -gt 70MB) { $winEv.Add(("{0} boot language folders ({1}) - bcdboot copies every locale by default; that is stock Windows behaviour and is never pruned." -f $localeDirs.Count, (Fmt (($localeFiles | Measure-Object Length -Sum).Sum)))) }
    if ($winB -gt 70MB) { $winEv.Add(("Windows-owned files total {0}; a normal Windows ESP is roughly 30-60 MB, so Windows alone is heavier than expected." -f (Fmt $winB))) }
    if ($left.Count -and (($left | Where-Object { $_.Bucket -eq 'Windows' }).Count)) { $winEv.Add(("{0} leftover .bak/.old/.log-style files under Windows folders (servicing residue)." -f ($left | Where-Object { $_.Bucket -eq 'Windows' }).Count)) }
    if ($bmEsp -and $bmOs -and $bmEsp -ne $bmOs) { $winEv.Add(("ESP boot manager ({0}) differs from the OS copy ({1}) - boot-manager servicing is pending/failed, which retries and needs free ESP space." -f $bmEsp, $bmOs)) }

    # Environment / sizing
    if ($total -le 105MB -and $free -lt 30MB) { $envEv.Add(("ESP is only {0}. Modern HP firmware payloads + Windows resources + the Secure Boot boot-manager update do not fit comfortably in 100 MB - the partition is undersized for current needs (OEM imaging/Windows Setup sizing choice)." -f (Fmt $total))) }
    if ($free -lt 15MB) { $envEv.Add(("Only {0} free - below roughly 15 MB, Windows servicing and Secure Boot boot-manager updates start failing." -f (Fmt $free))) }

    foreach ($pair in @(@('HP-side evidence', $hpEv), @('Windows-side evidence', $winEv), @('Sizing / environment', $envEv))) {
        W ''
        W $pair[0]
        if ($pair[1].Count) { foreach ($x in $pair[1]) { W ("  - " + $x) } } else { W '  - none' }
    }

    $pressure = ($free -lt 30MB)
    $hpFlag = $hpEv.Count -gt 0
    $winFlag = $winEv.Count -gt 0
    W ''
    if (-not $pressure -and -not $hpFlag) {
        $call = ('NOT UNDER PRESSURE - {0} free of {1}. Re-run when the ESP is actually full (or on the affected machine).' -f (Fmt $free), (Fmt $total))
    } elseif ($hpFlag -and $winFlag) {
        $call = 'BOTH - HP leaves firmware payloads behind AND Windows contributes its own bloat/residue.'
    } elseif ($hpFlag) {
        $call = 'HP-SIDE - the space is going to HP staging/firmware files; Windows files look normal.'
    } elseif ($winFlag) {
        $call = 'WINDOWS-SIDE - HP footprint is small; the growth is Windows boot resources/servicing.'
    } else {
        $call = 'NEITHER AS A BUG - contents look normal; the partition is simply too small for its normal contents.'
    }
    W ("LIKELY ATTRIBUTION: " + $call)
    W ("Breakdown: Windows {0} | HP {1} | Capsule {2} | Other {3} | Unknown {4} | of {5} partition" -f (Fmt $winB), (Fmt $hpB), (Fmt $capB), (Fmt $othB), (Fmt $unkB), (Fmt $total))
    W ''
    W 'Caveats: ownership is path-based (heuristic). "Windows" files are expected content, not necessarily a bug -'
    W 'a bug needs growth that should not happen (duplicates, repeated generations, leftovers). To pin the cause'
    W 'to one event, run this before and after a BIOS update / cumulative update and diff the two CSVs.'
    W 'This script changed nothing. Nothing is cleaned up - decide what to remove from the evidence above.'

    # ---- save --------------------------------------------------------------------------
    $files | Select-Object Rel, Bucket, Kind, Length, LastWrite, Leftover, Hash | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding UTF8
    Set-Content -LiteralPath $reportPath -Value $script:R -Encoding UTF8
    W ''
    W ("Report: {0}" -f $reportPath)
    W ("CSV   : {0}" -f $csvPath)
}
catch {
    Write-Host ("ERROR: {0}" -f $_.Exception.Message) -ForegroundColor Red
}
finally {
    if ($weMounted -and $letter) {
        & mountvol.exe "${letter}:" /D 2>&1 | Out-Null
        Write-Host ("Unmounted {0}:" -f $letter)
    }
}
