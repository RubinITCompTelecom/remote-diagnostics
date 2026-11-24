<#
  Test-GuiCallParity.ps1 - the window must start the same script with the same arguments as the
  Run-*.bat launcher given the same answers (docs\gui-architecture.md, section 1).

  Every tool script is replaced by a stub that records "<file>::<arg>|<arg>|..." to a trace file. The REAL
  Run-*.bat files are copied next to the stubs and run (with NUL as stdin, so their final pause returns).
  Gui.Core is driven headless with the same answers and its command is run through the GUI's own pump.
  Declared differences (and only these) are removed before comparing, and asserted separately:
    -NoFullDump  the window answers the full-dump question with a switch instead of the prompt
    -StopFile    the window's "Stop and save" for the print watch
  Run-CheckCameraAndStartup.bat elevates and asks R/F/A with CHOICE, so its copy has the elevation block
  removed and CHOICE replaced by "errorlevel 1" (= R); the lines that build the command are untouched.
  No admin, no network. Windows PowerShell 5.1, pure ASCII, no BOM.
#>
. (Join-Path $PSScriptRoot 'GuiTestLib.ps1')

$root = New-TestDir 'parity'
$trace = Join-Path $root 'trace.txt'
[Environment]::SetEnvironmentVariable('RDGUI_TRACE', $trace)
$stub = @'
$parts = @([IO.Path]::GetFileName($PSCommandPath)) + @($args | ForEach-Object { [string]$_ })
[IO.File]::AppendAllText([Environment]::GetEnvironmentVariable('RDGUI_TRACE'), ($parts[0] + '::' + (($parts | Select-Object -Skip 1) -join '|')) + "`r`n")
'@
$catalog = Get-GuiCatalog
$enabled = @($catalog.Tools | Where-Object { $_.Enabled })
foreach ($t in $enabled) {
    # an older dated copy and a plain copy too: the newest dated one must win, in the .bat and in the GUI
    foreach ($n in ($t.Script + '.v2026-01-01.9.ps1'), ($t.Script + '.v2026-11-15.1.ps1'), ($t.Script + '.ps1')) { Write-AsciiFile (Join-Path $root $n) $stub }
    if (-not $t.Launcher) { continue }   # revert-remote-diag has no launcher
    $bat = [IO.File]::ReadAllText((Join-Path $DiagRoot $t.Launcher))
    if ($bat -match 'net session') {
        # launchers that elevate themselves (camera, enable-remote-diag): the test copy has the elevation block removed
        $bat = [regex]::Replace($bat, '(?s)net session >nul 2>&1\r?\nif %errorlevel% neq 0 \(.*?\r?\n\)\r?\n', '')
        Check ($bat -notmatch 'RunAs' -and $bat -notmatch 'net session') ($t.Launcher + ' copy: elevation block removed for the test')
    }
    if ($t.Launcher -eq 'Run-CheckCameraAndStartup.bat') {
        $bat = $bat.Replace('choice /c RFA /n /m "Choose R, F or A: "', 'cmd /c exit /b 1')
        Check ($bat -notmatch 'choice ') 'camera launcher copy: CHOICE removed for the test'
    }
    Write-AsciiFile (Join-Path $root $t.Launcher) $bat
}

function Get-Trace {
    if (-not (Test-Path -LiteralPath $trace)) { return '' }
    $t = ([IO.File]::ReadAllText($trace)).Trim()
    Remove-Item -LiteralPath $trace -Force
    return $t
}

function Invoke-Bat {
    param([string]$Launcher, [string]$ArgText)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'cmd.exe'
    $psi.Arguments = '/d /c ""' + (Join-Path $root $Launcher) + '" ' + $ArgText + '"'
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true
    $p = [Diagnostics.Process]::Start($psi)
    $p.StandardInput.Close()
    $null = $p.StandardOutput.ReadToEnd()
    if (-not $p.WaitForExit(60000)) { $p.Kill(); throw ('bat timed out: ' + $Launcher) }
    return (Get-Trace)
}

function Invoke-Gui {
    param([string]$ToolId, [hashtable]$Values, [string]$StopFile = '')
    $tool = Get-GuiTool -Id $ToolId -Catalog $catalog
    $v = Get-GuiDefaultValues $tool
    if ($Values) { foreach ($k in $Values.Keys) { $v[$k] = $Values[$k] } }
    Check (@(Test-GuiToolValues -Tool $tool -Values $v).Count -eq 0) ($ToolId + ': values are valid')
    $call = Get-GuiToolCall -Tool $tool -ToolRoot $root -Values $v -StopFile $StopFile
    $null = Invoke-ChildToEnd -ScriptPath $call.ScriptPath -ArgumentList $call.Args
    return (Get-Trace)
}

function Remove-Declared {
    param([string]$Trace)
    $head, $rest = $Trace -split '::', 2
    $keep = @(); $skipNext = $false
    foreach ($a in @($rest -split '\|')) {
        if ($skipNext) { $skipNext = $false; continue }
        if ($a -eq '-NoFullDump') { continue }
        if ($a -eq '-StopFile') { $skipNext = $true; continue }
        if ($a -ne '') { $keep += $a }
    }
    return ($head + '::' + ($keep -join '|'))
}

function Compare-Call {
    param([string]$Name, [string]$Launcher, [string]$BatArgs, [string]$ToolId, [hashtable]$Values, [string]$StopFile = '')
    $b = Invoke-Bat $Launcher $BatArgs
    $g = Invoke-Gui $ToolId $Values $StopFile
    Check ($b -like '*.v2026-11-15.1.ps1::*') ($Name + ': the launcher ran the newest dated copy (' + ($b -split '::')[0] + ')')
    Check ((Remove-Declared $g) -ceq $b) ($Name + ': same call  bat=[' + $b + ']  gui=[' + $g + ']')
    return $g
}

Write-Host 'Pull logs from THIS PC' -ForegroundColor Cyan
$g = Compare-Call 'PullLocal 72 + dump' 'Run-PullLocalLogs.bat' '-Hours 72 -IncludeFullDump' 'PullLocal' @{ Hours = 72; FullDump = $true }
Check ($g -notmatch 'NoFullDump') 'PullLocal: ticked dump -> no -NoFullDump'
$g = Compare-Call 'PullLocal 168 + folder with spaces' 'Run-PullLocalLogs.bat' '-Hours 168 -OutRoot "C:\Diag Out (1)"' 'PullLocal' @{ Hours = '168'; OutRoot = 'C:\Diag Out (1)' }
Check ($g -match '\|-NoFullDump(\||$)') 'PullLocal: unticked dump -> -NoFullDump (declared difference: the prompt is never reached)'
$g = Invoke-Gui 'PullLocal' @{}
Check ($g -match '::-Hours\|72\|-NoFullDump$') 'PullLocal: defaults always pass -Hours 72, so the hours prompt is never reached'

Write-Host 'Deep persistence inventory' -ForegroundColor Cyan
$null = Compare-Call 'Persistence defaults' 'Run-PullPersistence.bat' '' 'Persistence' @{}
$g = Invoke-Gui 'Persistence' @{ NoSamples = $true; LogonDays = 30; OutRoot = 'D:\Cases' }
Check ($g -match '::-OutRoot\|D:\\Cases\|-NoSamples\|-LogonDays\|30$') ('Persistence: options map to the script''s own switches (the launcher has no way to pass them) [' + $g + ']')

Write-Host 'EFI partition usage / camera (report only)' -ForegroundColor Cyan
$null = Compare-Call 'Esp' 'Run-CheckEspUsage.bat' '' 'Esp' @{}
$null = Compare-Call 'Camera R' 'Run-CheckCameraAndStartup.bat' '' 'Camera' @{}

Write-Host 'Watch a print freeze' -ForegroundColor Cyan
$null = Compare-Call 'PrintWatch defaults' 'Run-WatchPrintFreeze.bat' '' 'PrintWatch' @{}
$g = Compare-Call 'PrintWatch 30 min Notepad + stop file' 'Run-WatchPrintFreeze.bat' '-Minutes 30 -AppName Notepad' 'PrintWatch' @{ Minutes = 30; AppName = 'Notepad' } 'C:\T\stop.flag'
Check ($g -match '\|-StopFile\|C:\\T\\stop\.flag$') 'PrintWatch: -StopFile added by the window only (declared difference)'

Write-Host 'Pull logs from ANOTHER PC (user name and password never on the command line)' -ForegroundColor Cyan
$g = Compare-Call 'PullRemote 24 h + dump' 'Run-PullRemoteLogs.bat' '-ComputerName PC1 -Hours 24 -IncludeFullDump' 'PullRemote' @{ ComputerName = 'PC1'; Username = '.\Admin'; Password = 'Pa55 w0rd!'; Hours = '24'; FullDump = $true }
Check ($g -notmatch 'Admin' -and $g -notmatch 'Pa55') 'PullRemote: the user name and the password are NOT in the arguments'
$g = Invoke-Gui 'PullRemote' @{ ComputerName = '10.0.0.53'; Username = '.\Admin'; Password = 'x'; OutRoot = 'D:\Logs Out' }
Check ($g -match '::-ComputerName\|10\.0\.0\.53\|-Hours\|72\|-NoFullDump\|-OutRoot\|D:\\Logs Out$') ('PullRemote: defaults pass -Hours 72 and -NoFullDump, so no question is left [' + $g + ']')
Check (@(Test-GuiToolValues -Tool (Get-GuiTool PullRemote $catalog) -Values @{ ComputerName = 'PC1'; Username = 'u'; Hours = 72; FullDump = $false; OutRoot = '' }).Count -eq 0) 'PullRemote: a blank password is allowed'
Check (@(Test-GuiToolValues -Tool (Get-GuiTool PullRemote $catalog) -Values @{ ComputerName = ''; Username = ''; Hours = 72; FullDump = $false; OutRoot = '' }).Count -eq 2) 'PullRemote: computer name and user name are required'

Write-Host 'Enable / revert remote diagnostics, switch printer (stubs only: they change the PC)' -ForegroundColor Cyan
$null = Compare-Call 'EnableRemote' 'Run-EnableRemoteDiag.bat' '' 'EnableRemote' @{}
$g = Invoke-Gui 'RevertRemote' @{}
Check ($g -like 'revert-remote-diag*.ps1::') ('RevertRemote: the window runs revert-remote-diag with no arguments [' + $g + ']')
$null = Compare-Call 'SwitchPrinter dry run' 'Run-SwitchPrinterToTcpIp.bat' '-QueueName "Q (Copy 1)" -IpAddress 10.0.0.9 -DryRun' 'SwitchPrinter' @{ QueueName = 'Q (Copy 1)'; IpAddress = '10.0.0.9'; DryRun = $true }
$g = Invoke-Gui 'SwitchPrinter' @{ QueueName = 'Q'; IpAddress = '10.0.0.9'; NewName = 'Q TCP'; RemoveStale = $true; TestPage = $true }
Check ($g -match '::-QueueName\|Q\|-IpAddress\|10\.0\.0\.9\|-NewName\|Q TCP\|-RemoveStale\|-TestPage$') ('SwitchPrinter: every option maps to the script''s own switch [' + $g + ']')
Check (@(Test-GuiToolValues -Tool (Get-GuiTool SwitchPrinter $catalog) -Values @{ QueueName = 'Q'; IpAddress = '10.0.0'; NewName = ''; RemoveStale = $false; TestPage = $false; DryRun = $false }).Count -eq 1) 'SwitchPrinter: an IP address that is not four numbers is refused'

Write-Host 'Script resolution' -ForegroundColor Cyan
$plainOnly = New-TestDir 'plain'
Write-AsciiFile (Join-Path $plainOnly 'pull-local-logs.ps1') $stub
Check ((Split-Path -Leaf (Resolve-GuiScript -ToolRoot $plainOnly -Name 'pull-local-logs')) -eq 'pull-local-logs.ps1') 'no dated copy -> falls back to the plain name, like the launchers'
Check ($null -eq (Resolve-GuiScript -ToolRoot $plainOnly -Name 'Check-EspUsage')) 'missing script -> $null (the window then refuses to run it)'
$real = Get-GuiTool 'PullLocal' $catalog
Check ((Split-Path -Leaf (Resolve-GuiScript -ToolRoot $DiagRoot -Name $real.Script)) -eq ((Get-ChildItem -LiteralPath $DiagRoot -Filter 'pull-local-logs.v*.ps1' | Sort-Object Name -Descending)[0].Name)) 'real folder: picks the newest pull-local-logs.v*.ps1'
foreach ($t in @($catalog.Tools)) { Check ($null -ne (Resolve-GuiScript -ToolRoot $DiagRoot -Name $t.Script)) ($t.Id + ': a script named ' + $t.Script + ' exists in the real folder') }

Remove-Item -LiteralPath $root, $plainOnly -Recurse -Force -ErrorAction SilentlyContinue
Complete-Test 'Test-GuiCallParity'
