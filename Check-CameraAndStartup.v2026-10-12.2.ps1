<#
  Check-CameraAndStartup  v2026-10-12.2
  Run on the target PC itself, as Administrator (Run-CheckCameraAndStartup.bat self-elevates).

  Default            : READ-ONLY report. Changes nothing.
  -Fix               : after the report, offers the camera fixes one by one (each asks y/N; -Yes skips the asks):
                         1 Fast Startup off          4 remove ghost camera/VID_5986 entries
                         2 USB selective suspend off 5 re-scan hardware
                         3 "allow PC to turn off this device" off for camera + USB hubs
  -Repair            : also runs DISM /RestoreHealth + sfc /scannow (slow, 10-30 min)
  Output: CameraAndStartup_<PC>_<date>.txt on the current user's Desktop.
  PowerShell 5.1 compatible, pure ASCII.
#>
param([switch]$Fix, [switch]$Repair, [switch]$Yes)
$ErrorActionPreference = 'SilentlyContinue'
$out = Join-Path ([Environment]::GetFolderPath('Desktop')) ("CameraAndStartup_{0}_{1}.txt" -f $env:COMPUTERNAME, (Get-Date -Format 'yyyy-MM-dd_HHmm'))
$sb = New-Object System.Text.StringBuilder
function W([string]$t) { [void]$sb.AppendLine($t); Write-Host $t }
function H([string]$t) { W ''; W ('=' * 70); W $t; W ('=' * 70) }
function T($o) { if ($o) { ($o | Format-Table -AutoSize -Wrap | Out-String -Width 220).TrimEnd() | ForEach-Object { W $_ } } else { W '(none)' } }
function Ask([string]$q) { if ($Yes) { return $true }; $a = Read-Host "$q [y/N]"; return ($a -match '^(y|yes)$') }

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
W "Camera + startup check v2026-10-12.2  $(Get-Date)   PC: $env:COMPUTERNAME   Admin: $isAdmin   Fix: $Fix   Repair: $Repair"
if (-not $isAdmin) { W 'WARNING: not elevated - some results (Defender, other users) incomplete and fixes will fail.' }

# ================================================================= CAMERA
H 'CAMERA 1: devices in Camera / Image classes (incl. NOT present)'
T (Get-PnpDevice -Class Camera, Image -ErrorAction SilentlyContinue | Select-Object Status, Class, Present, ConfigManagerErrorCode, FriendlyName, InstanceId)

H 'CAMERA 2: ThinkPad camera VID_5986 - present or ghost?'
$usb = @(Get-PnpDevice -PresentOnly:$false -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -match 'VID_5986' })
T ($usb | Select-Object Status, Class, Present, ConfigManagerErrorCode, FriendlyName, InstanceId)
foreach ($d in $usb) {
    $p = Get-PnpDeviceProperty -InstanceId $d.InstanceId -KeyName 'DEVPKEY_Device_ProblemCode','DEVPKEY_Device_ProblemStatus','DEVPKEY_Device_LastArrivalDate','DEVPKEY_Device_LastRemovalDate','DEVPKEY_Device_DriverVersion','DEVPKEY_Device_DriverInfPath' -ErrorAction SilentlyContinue
    W ("  {0}" -f $d.InstanceId)
    foreach ($x in $p) { W ("     {0} = {1}" -f $x.KeyName, $x.Data) }
}
$camPresent = [bool]($usb | Where-Object Present)
if (-not $camPresent) { W '>> VID_5986 is NOT on the USB bus right now. (It works in Linux, so hardware/BIOS are fine: this is Windows power/enumeration/driver state.)' }

H 'CAMERA 3: present devices with a problem status'
T (Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object { $_.Status -ne 'OK' -and $_.Status -ne 'Unknown' } | Select-Object Status, Class, ConfigManagerErrorCode, FriendlyName, InstanceId)

H 'CAMERA 4: Windows camera privacy / policy / services'
foreach ($k in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\webcam',
               'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\webcam') {
    W ("{0} -> Value = {1}" -f $k, (Get-ItemProperty $k).Value)
}
W ("Policy AllowCamera = {0}   LetAppsAccessCamera = {1}" -f (Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Camera').AllowCamera, (Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy').LetAppsAccessCamera)
T (Get-Service FrameServer, FrameServerMonitor -ErrorAction SilentlyContinue | Select-Object Name, Status, StartType)

H 'CAMERA 5: driver details (camera, USB hubs/controllers, AMD chipset) - for matching against Lenovo downloads'
$drv = Get-CimInstance Win32_PnPSignedDriver | Where-Object { $_.DeviceID -match 'VID_5986' -or $_.DeviceClass -in 'CAMERA','IMAGE' -or $_.DeviceName -match 'USB (Root )?Hub|xHCI|USB 3|AMD.*(USB|PSP|GPIO|SMBus|I2C|PCI|SFH|Sensor)' }
T ($drv | Select-Object DeviceName, Manufacturer, DriverVersion, @{n='DriverDate'; e={ $_.DriverDate.ToString('yyyy-MM-dd') }}, InfName | Sort-Object DeviceName)
$bios = Get-CimInstance Win32_BIOS; $cs = Get-CimInstance Win32_ComputerSystem
W ("Model: {0} {1}   BIOS: {2} ({3})" -f $cs.Manufacturer, $cs.Model, $bios.SMBIOSBIOSVersion, $bios.ReleaseDate)
W 'Lenovo apps installed (Vantage / Vision / System Update):'
T (Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'Lenovo' } | Select-Object Name, Version)

H 'CAMERA 6: power settings that make Windows drop USB devices on sleep/wake'
W ("Fast Startup (HiberbootEnabled) = {0}   [1 = ON, keeps bad device state across 'shutdown']" -f (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power').HiberbootEnabled)
W 'USB selective suspend, active power scheme:'
(powercfg /query SCHEME_CURRENT 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 2>&1) | ForEach-Object { W "   $_" }
W '"Allow the computer to turn off this device" (MSPower_DeviceEnable) for camera + USB hubs:'
$pm = Get-CimInstance -Namespace root\wmi -ClassName MSPower_DeviceEnable | Where-Object { $_.InstanceName -match 'VID_5986|ROOT_HUB|USB\\VID_' -or $_.InstanceName -match 'HUB' }
T ($pm | Select-Object InstanceName, Enable)

H 'CAMERA 7: camera / USB / UMDF events, last 7 days'
$ev = Get-WinEvent -FilterHashtable @{ LogName = 'System'; StartTime = (Get-Date).AddDays(-7) } -ErrorAction SilentlyContinue |
      Where-Object { $_.Message -match 'VID_5986|VID: 0x5986|usbvideo|camera|WUDFRd' }
T ($ev | Select-Object -First 30 TimeCreated, Id, ProviderName, @{n='Msg'; e={ ($_.Message -replace '\s+', ' ').Substring(0, [Math]::Min(150, $_.Message.Length)) }})

# ================================================================= STARTUP
H 'STARTUP 1: Windows build / Insider channel'
$os = Get-CimInstance Win32_OperatingSystem
W ("{0}  build {1}  installed {2}" -f $os.Caption, $os.BuildNumber, $os.InstallDate)
W ("Insider BranchName = {0}   (blank/absent = normal release channel)" -f (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\WindowsSelfHost\Applicability').BranchName)

H 'STARTUP 2: Defender status, detections, exclusions'
$mp = Get-MpComputerStatus
if ($mp) { W ("RealTime={0}  SigUpdated={1}  LastQuickScan={2}  LastFullScan={3}" -f $mp.RealTimeProtectionEnabled, $mp.AntispywareSignatureLastUpdated, $mp.QuickScanEndTime, $mp.FullScanEndTime) }
T (Get-MpThreatDetection | Select-Object -First 15 InitialDetectionTime, ThreatID, ProcessName, Resources)
$pref = Get-MpPreference
W 'Exclusion paths:'; T ($pref.ExclusionPath | ForEach-Object { [pscustomobject]@{ Path = $_ } })
W 'Exclusion processes:'; T ($pref.ExclusionProcess | ForEach-Object { [pscustomobject]@{ Process = $_ } })

H 'STARTUP 3: non-Microsoft scheduled tasks (with run-as account)'
$tasks = Get-ScheduledTask | Where-Object { $_.TaskPath -notmatch '^\\Microsoft\\' -and $_.State -ne 'Disabled' }
T ($tasks | Select-Object TaskName, TaskPath, State, @{n='RunAs'; e={ $_.Principal.UserId }}, @{n='Action'; e={ (($_.Actions | ForEach-Object { "$($_.Execute) $($_.Arguments)" }) -join ' ; ') }})

H 'STARTUP 4: Run / RunOnce keys and startup folders'
foreach ($k in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run',
               'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce', 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run', 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce') {
    $props = (Get-ItemProperty $k -ErrorAction SilentlyContinue).PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' }
    foreach ($p in $props) { W ("{0}  {1} = {2}" -f $k.Replace('HKLM:\SOFTWARE\', 'HKLM\').Replace('HKCU:\SOFTWARE\', 'HKCU\'), $p.Name, $p.Value) }
}
T (Get-ChildItem "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\Startup", "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup" -File -ErrorAction SilentlyContinue | Select-Object FullName, LastWriteTime)

H 'STARTUP 5: auto-start services outside Windows/Microsoft paths'
T (Get-CimInstance Win32_Service | Where-Object { $_.StartMode -eq 'Auto' -and $_.PathName -and $_.PathName -notmatch 'Windows\\System32|Windows\\SysWOW64|Windows Defender|WindowsApps|Microsoft\\EdgeUpdate|Microsoft Shared' } | Select-Object Name, State, StartName, PathName)

H 'STARTUP 6: remote-access / VPN tools (running or installed)'
$pat = 'anydesk|teamviewer|splashtop|screenconnect|connectwise|rustdesk|logmein|ultravnc|tightvnc|realvnc|atera|ninja|meshagent|zoho|supremo|dwservice|chrome remote|parsec|ngrok|tailscale|zerotier|openvpn|wireguard'
T (Get-CimInstance Win32_Process | Where-Object { $_.Name -match $pat -or $_.ExecutablePath -match $pat } | Select-Object Name, ProcessId, ExecutablePath)
$inst = foreach ($k in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*') { Get-ItemProperty $k -ErrorAction SilentlyContinue }
T ($inst | Where-Object { $_.DisplayName -match $pat } | Select-Object DisplayName, DisplayVersion, Publisher, InstallDate)

H 'STARTUP 7: local admins, accounts, listening ports + owners, outbound connections'
T (Get-LocalGroupMember -Group 'Administrators' | Select-Object Name, ObjectClass, PrincipalSource)
T (Get-LocalUser | Select-Object Name, Enabled, LastLogon, PasswordLastSet)
$procs = @{}; Get-Process | ForEach-Object { $procs[$_.Id] = $_.ProcessName }
T (Get-NetTCPConnection -State Listen | Sort-Object LocalPort | Select-Object LocalAddress, LocalPort, @{n='Process'; e={ $procs[[int]$_.OwningProcess] }})
T (Get-NetTCPConnection -State Established | Where-Object { $_.RemoteAddress -notmatch '^(127\.|::1)' } | Select-Object RemoteAddress, RemotePort, @{n='Process'; e={ $procs[[int]$_.OwningProcess] }})

# ================================================================= FIXES
if ($Fix -or $Repair) {
    H 'FIXES'
    if (-not $isAdmin) { W 'Not elevated - skipping all fixes.'; $Fix = $false; $Repair = $false }
}
if ($Fix) {
    if (Ask 'Fix 1: turn Fast Startup OFF (hibernate itself stays available)?') {
        Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -Name HiberbootEnabled -Value 0 -Type DWord
        W 'Fix 1 done: HiberbootEnabled = 0'
    }
    if (Ask 'Fix 2: turn USB selective suspend OFF (plugged in + battery, active power plan)?') {
        powercfg /setacvalueindex SCHEME_CURRENT 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 0 | Out-Null
        powercfg /setdcvalueindex SCHEME_CURRENT 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 0 | Out-Null
        powercfg /setactive SCHEME_CURRENT | Out-Null
        W 'Fix 2 done: USB selective suspend disabled'
    }
    if (Ask 'Fix 3: turn OFF "allow the computer to turn off this device" for the camera and USB hubs?') {
        $n = 0
        foreach ($i in (Get-CimInstance -Namespace root\wmi -ClassName MSPower_DeviceEnable | Where-Object { $_.InstanceName -match 'VID_5986|ROOT_HUB|HUB' })) {
            if ($i.Enable) { Set-CimInstance -InputObject $i -Property @{ Enable = $false } -ErrorAction SilentlyContinue; $n++ }
        }
        W "Fix 3 done: $n device(s) changed"
    }
    $ghosts = @($usb | Where-Object { -not $_.Present })
    if ($ghosts.Count -gt 0 -and (Ask ("Fix 4: remove {0} ghost (not-present) VID_5986 entr(ies) so Windows re-detects the camera cleanly?" -f $ghosts.Count))) {
        foreach ($g in $ghosts) { W ("  removing {0}" -f $g.InstanceId); (pnputil /remove-device "$($g.InstanceId)" 2>&1) | ForEach-Object { W "     $_" } }
    }
    if (Ask 'Fix 5: re-scan hardware now?') {
        (pnputil /scan-devices 2>&1) | ForEach-Object { W "   $_" }
        Start-Sleep 5
        W 'After scan, VID_5986 present: '
        T (Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -match 'VID_5986' } | Select-Object Status, Class, FriendlyName, InstanceId)
    }
}
if ($Repair) {
    if (Ask 'Repair: run DISM /RestoreHealth then sfc /scannow (slow)?') {
        W 'DISM...'; (DISM /Online /Cleanup-Image /RestoreHealth 2>&1) | ForEach-Object { W "   $_" }
        W 'sfc...';  (sfc /scannow 2>&1) | ForEach-Object { W ($_ -replace "`0", '') }
    }
}

H 'WHAT TO DO NEXT'
W '  1. If fixes were applied: do a FULL shutdown (not restart), wait 30s, power on, test the Camera app.'
W '  2. Still no camera: install from Lenovo support for the 20XK - camera driver, AMD chipset/USB drivers, latest BIOS (versions are listed in CAMERA 5).'
W '  3. Still no camera: in-place repair install from a RELEASE Windows 11 ISO (this PC is on preview build 26300).'
W '  4. Send this .txt back for review.'
W ''
W "Saved: $out"
[IO.File]::WriteAllText($out, $sb.ToString(), (New-Object System.Text.UTF8Encoding($true)))
