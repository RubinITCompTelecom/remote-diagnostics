<#
  Test-GuiWindow.ps1 - window smoke test (docs\gui-architecture.md, section 9 item 6). Loads the XAML,
  finds every named control, runs the self-test in both themes, opens the start screen at a compact
  size (910x480 = 1366x768 at 150%) and a roomy one, then runs one STUB tool end to end through the
  real window and its timer (an unknown no-newline prompt included). Test hooks work only because this
  window is not elevated - asserted statically below. -RenderDir saves PNGs to look at.
  No admin, no network. Windows PowerShell 5.1, pure ASCII, no BOM.
#>
param([string]$RenderDir = '')
. (Join-Path $PSScriptRoot 'GuiTestLib.ps1')
if (([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    # Test hooks exist only in a NON-elevated window (by design), so every stub run below would wait for a click.
    Write-Host 'Test-GuiWindow: run this from a NON-elevated PowerShell (the window''s test hooks are off when elevated).' -ForegroundColor Red; exit 2
}

$gui = @(Get-ChildItem -LiteralPath $GuiDir -Filter 'Start-RemoteDiagGui.v*.ps1' | Sort-Object Name -Descending)[0].FullName
$ps = Join-Path $PSHOME 'powershell.exe'
function Invoke-Window {
    param([string[]]$Extra)
    $out = & $ps -NoProfile -STA -ExecutionPolicy Bypass -File $gui -AllowNotElevated @Extra 2>&1
    return [pscustomobject]@{ Code = $LASTEXITCODE; Text = (@($out) -join "`n") }
}
function Read-Result { param([string]$Path) if (Test-Path -LiteralPath $Path) { return ([IO.File]::ReadAllText($Path) | ConvertFrom-Json) }; return $null }
$tmp = New-TestDir 'window'

Write-Host 'Load and self-test' -ForegroundColor Cyan
$r = Invoke-Window @('-LoadOnly'); Check ($r.Code -eq 0 -and $r.Text -match 'LOAD_OK') ('every named control found: ' + $r.Text)
foreach ($th in 'Light', 'Dark') {
    $r = Invoke-Window @('-SelfTest', '-Theme', $th)
    Check ($r.Code -eq 0 -and $r.Text -match ('SELFTEST_OK .*theme=' + $th + ' dpi=per-monitor v2')) ($th + ' theme: tokens complete, dialog builds, per-monitor DPI v2 (' + $r.Text.Trim() + ')')
}

Write-Host 'Start screen, compact and roomy' -ForegroundColor Cyan
$enabled = @((Get-GuiCatalog).Tools | Where-Object { $_.Enabled }).Count
foreach ($case in @(@{ Size = '910x480'; Compact = $true; Cols = 1; Console = 88 }, @{ Size = '1120x760'; Compact = $false; Cols = 2; Console = 170 })) {
    $rp = Join-Path $tmp ('start-' + $case.Size + '.json')
    $extra = @('-ResultPath', $rp, '-TestSize', $case.Size)
    if ($RenderDir) { $extra += @('-RenderPng', (Join-Path $RenderDir ('start-' + $case.Size + '.png')), '-RenderScale', '1.5') }
    $null = Invoke-Window $extra
    $s = Read-Result $rp
    Check ($null -ne $s) ($case.Size + ': window opened and wrote its state')
    if (-not $s) { continue }
    Check ($s.Cards -eq @((Get-GuiCatalog).Tools).Count -and $s.EnabledCards -eq $enabled -and $enabled -eq 9) ($case.Size + ': one card per tool (' + $s.Cards + '), ' + $s.EnabledCards + ' offered (all 9)')
    Check ($s.Columns -eq $case.Cols) ($case.Size + ': ' + $case.Cols + ' column(s) of cards')
    Check ([bool]$s.CompactWidth -eq $case.Compact -and [bool]$s.CompactHeight -eq $case.Compact) ($case.Size + ': compact layout = ' + $case.Compact)
    Check ([math]::Abs($s.ConsoleHeight - $case.Console) -lt 1) ($case.Size + ': console height ' + $s.ConsoleHeight)
    Check ($s.WindowWidth -le [int]($case.Size.Split('x')[0]) -and $s.WindowHeight -le [int]($case.Size.Split('x')[1])) ($case.Size + ': fits (' + $s.WindowWidth + 'x' + $s.WindowHeight + ')')
    Check ($s.StartPanelVisible -and -not $s.RunPanelVisible) ($case.Size + ': start panel shown, nothing runs on its own')
    Check (($s.Links -join ' ') -eq 'https://rubinit.net/ https://pupontech.com/') ($case.Size + ': footer links')
    Check ($s.Info -match 'Elevated: NO') ($case.Size + ': header says whether the window is elevated')
}

Write-Host 'A stub tool, end to end through the window' -ForegroundColor Cyan
$root = Join-Path $tmp 'tools'; $null = New-Item -ItemType Directory -Path $root
$outDir = Join-Path $tmp 'PC_LOCAL_out'
$stub = @"
Write-Host ('ARGS=' + (`$args -join ' '))
Write-Host 'Something odd that waits: ' -NoNewline
`$a = Read-Host
Write-Host ('GOT=[' + `$a + ']')
New-Item -ItemType Directory -Path '$outDir' -Force | Out-Null
[IO.File]::WriteAllText('$outDir\StartupAndTasks.txt', "REVIEW LIST (things worth a glance - an inventory, not a verdict):``r``n  * Task X runs as SYSTEM``r``n``r``nrest")
[IO.File]::WriteAllText('$outDir.zip', 'PK')
Write-Host ' Done!'
Write-Host ' Saved to: $outDir'
Write-Host ' >>> COPY THIS FILE OFF THE MACHINE: $outDir.zip'
"@
Write-AsciiFile (Join-Path $root 'pull-local-logs.v2026-11-15.1.ps1') $stub
$rp = Join-Path $tmp 'run.json'
$extra = @('-ToolRoot', $root, '-ResultPath', $rp, '-AutoTool', 'PullLocal', '-TestValues', '{"Hours":"24","FullDump":true}', '-TestSize', '910x480')
if ($RenderDir) { $extra += @('-RenderPng', (Join-Path $RenderDir 'result-910x480.png'), '-RenderScale', '1.5') }
$sw = [Diagnostics.Stopwatch]::StartNew()
$null = Invoke-Window $extra
$s = Read-Result $rp
Check ($null -ne $s) ('the run finished and the window closed itself (' + [int]$sw.Elapsed.TotalSeconds + ' s)')
if ($s) {
    Check ($s.ConsoleText -match 'ARGS=-Hours 24 -IncludeFullDump') 'the window passed the technician''s values as arguments'
    Check ($s.ConsoleText -match 'GOT=\[\]' -and $s.ConsoleText -match 'sent an empty line') 'unknown no-newline prompt: after 5 s quiet the box appears; closing it (test = X) sends an empty line'
    Check ($s.Banner -eq 'Finished.' -and -not $s.Failed) 'banner: Finished.'
    Check ($s.ResultFolder -eq $outDir) 'result: the output folder the script printed'
    Check ((@($s.ResultTexts) -join "`n") -match 'Task X runs as SYSTEM') 'result: the REVIEW LIST as the script wrote it'
    Check ((@($s.ResultTexts) -join "`n") -match 'not available \(file not found\)') 'result: a REVIEW file the script did not write says not available'
}

Write-Host 'A stub remote pull: user name and password through the window' -ForegroundColor Cyan
$rOut = Join-Path $tmp 'PC9_remote_out'
$rStub = @'
Write-Host ('ARGS=' + ($args -join ' '))
Write-Host 'Username: ' -NoNewline
$u = Read-Host
Write-Host 'Password: ' -NoNewline
$p = [Console]::In.ReadLine()
Write-Host ''
Write-Host ('USER=[' + $u + '] PWLEN=' + $p.Length)
New-Item -ItemType Directory -Path '@@OUT@@' -Force | Out-Null
[IO.File]::WriteAllText('@@OUT@@.zip', 'PK')
[IO.File]::WriteAllText('@@OUT@@.log', 'log')
Write-Host ' Saved to: @@OUT@@'
Write-Host ' Zipped copy (handy for forwarding/attaching): @@OUT@@.zip'
Write-Host 'Full run log saved to: @@OUT@@.log'
'@
Write-AsciiFile (Join-Path $root 'pull-remote-logs.v2026-11-15.1.ps1') $rStub.Replace('@@OUT@@', $rOut)
$rp = Join-Path $tmp 'remote.json'
$secret = 'Pa55w0rd!'
# Windows PowerShell 5.1 strips the quotes of a JSON argument unless they are escaped for the child's command line.
$json = ('{"ComputerName":"PC9","Username":"PC9\\Admin","Password":"' + $secret + '","Hours":"24"}').Replace('"', '\"')
$null = Invoke-Window @('-ToolRoot', $root, '-ResultPath', $rp, '-AutoTool', 'PullRemote', '-TestValues', $json, '-TestSize', '910x480')
$s = Read-Result $rp
Check ($null -ne $s) 'the remote pull finished and the window closed itself'
if ($s) {
    $argLine = [regex]::Match($s.ConsoleText, '(?m)^ARGS=.*$').Value
    Check ($argLine -match '^ARGS=-ComputerName PC9 -Hours 24 -NoFullDump\s*$') ('the arguments carry the computer name only [' + $argLine.Trim() + ']')
    Check ($s.ConsoleText -match 'USER=\[PC9\\Admin\] PWLEN=' + $secret.Length + '(\D|$)') 'the stub got the user name and a password of the right length'
    Check (-not $s.ConsoleText.Contains($secret) -and $s.ConsoleText -notmatch 'Pa55') 'the password text is nowhere in the console'
    Check ($s.ConsoleText.Contains('[GUI sent the password (not shown)]')) 'the console says only that a password was sent'
    Check ($s.Banner -eq 'Finished.' -and -not $s.Failed -and $s.ResultFolder -eq $rOut) 'banner: Finished., output folder found'
}

Write-Host 'A remote pull whose steps all FAIL (wrong password) is not shown as Finished.' -ForegroundColor Cyan
$fOut = Join-Path $tmp 'PC8_failed_out'
$fStub = @'
Write-Host 'Username: ' -NoNewline
$u = Read-Host
Write-Host 'Password: ' -NoNewline
$p = [Console]::In.ReadLine()
Write-Host ''
New-Item -ItemType Directory -Path '@@OUT@@' -Force | Out-Null
Write-Host '  Checking log availability on target...' -NoNewline
Write-Host ' FAILED'
Write-Host '  Pulling events (last 24 hours)...' -NoNewline
Write-Host ' FAILED'
Write-Host ' Saved to: @@OUT@@'
'@
Write-AsciiFile (Join-Path $root 'pull-remote-logs.v2026-11-15.1.ps1') $fStub.Replace('@@OUT@@', $fOut)
$rp = Join-Path $tmp 'failed.json'
$json = '{"ComputerName":"PC8","Username":"PC8\\Admin","Password":"wrong","Hours":"24"}'.Replace('"', '\"')
$null = Invoke-Window @('-ToolRoot', $root, '-ResultPath', $rp, '-AutoTool', 'PullRemote', '-TestValues', $json, '-TestSize', '910x480')
$s = Read-Result $rp
Check ($null -ne $s) 'the failed-step run finished and the window closed itself'
if ($s) {
    Check ($s.Banner -match '^The pull finished, but a step failed' -and $s.Banner -match 'Checking log availability on target\.\.\. FAILED' -and $s.Banner -match '\(2 in all\)') ('banner is a warning that names the first failed step [' + $s.Banner + ']')
    Check ($s.Banner -ne 'Finished.' -and -not $s.Failed -and $s.ResultFolder -eq $fOut) 'not the green Finished., and the output folder is still offered'
}

Write-Host 'A password the console code page cannot carry is refused before anything starts' -ForegroundColor Cyan
$marker2 = Join-Path $tmp 'remote-ran.txt'
Write-AsciiFile (Join-Path $root 'pull-remote-logs.v2026-11-15.1.ps1') ("[IO.File]::WriteAllText('" + $marker2 + "', 'ran')")
$rp = Join-Path $tmp 'cjk.json'
$cjk = [string][char]0x4E2D + [char]0x6587
$json = ('{"ComputerName":"PC7","Username":"PC7\\Admin","Password":"' + $cjk + '","Hours":"24"}').Replace('"', '\"')
$null = Invoke-Window @('-ToolRoot', $root, '-ResultPath', $rp, '-AutoTool', 'PullRemote', '-TestValues', $json, '-TestSize', '910x480')
$s = Read-Result $rp
Check ($null -ne $s) 'the window closed itself after refusing to start'
Check (-not (Test-Path -LiteralPath $marker2)) 'the script was NOT started'
if ($s) { Check ($s.Banner -match 'code page' -and $s.Banner -match 'Nothing was started' -and -not $s.Banner.Contains($cjk)) ('banner explains why and never repeats the password [' + $s.Banner + ']') }

Write-Host 'A tool that changes this PC never runs from a test window' -ForegroundColor Cyan
$marker = Join-Path $tmp 'enable-ran.txt'
Write-AsciiFile (Join-Path $root 'enable-remote-diag.v2026-11-15.1.ps1') ("[IO.File]::WriteAllText('" + $marker + "', 'ran')`nWrite-Host 'Full log saved to: x'")
$rp = Join-Path $tmp 'enable.json'
$null = Invoke-Window @('-ToolRoot', $root, '-ResultPath', $rp, '-AutoTool', 'EnableRemote', '-TestSize', '910x480')
$s = Read-Result $rp
Check ($null -ne $s) 'the window closed itself after the confirmation was not given'
Check (-not (Test-Path -LiteralPath $marker)) 'the ChangesPC script did NOT run (the confirmation counts as closed with the X)'
if ($s) { Check ($s.Banner -match '^Not run' -and $s.ConsoleText -match 'Not run: the confirmation was not given') ('banner says it was not run [' + $s.Banner + ']') }

Write-Host 'Stop button: ends a read-only tool and what it started' -ForegroundColor Cyan
Write-AsciiFile (Join-Path $root 'pull-local-logs.v2026-11-16.9.ps1') "Write-Host 'STARTED'`nStart-Sleep -Seconds 90`nWrite-Host 'AFTER-SLEEP'"
$rp = Join-Path $tmp 'stop.json'
$sw = [Diagnostics.Stopwatch]::StartNew()
$null = Invoke-Window @('-ToolRoot', $root, '-ResultPath', $rp, '-AutoTool', 'PullLocal', '-TestStopAfter', '3', '-TestSize', '910x480')
$s = Read-Result $rp
Check ($null -ne $s -and $sw.Elapsed.TotalSeconds -lt 60) ('the window stopped the tool and closed long before its 90 s sleep ended (' + [int]$sw.Elapsed.TotalSeconds + ' s)')
if ($s) {
    Check ($s.ConsoleText -match 'STARTED' -and $s.ConsoleText -notmatch 'AFTER-SLEEP') 'the tool was cut off: it never reached its last line'
    Check ($s.ConsoleText -match 'Stop requested by you') 'the console says who stopped it'
    Check ($s.Banner -match '^Stopped at your request' -and $s.Banner -match 'nothing was changed') ('the banner says stopped, not failed or finished [' + $s.Banner + ']')
}
Start-Sleep -Seconds 1
$left = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -like '*pull-local-logs.v2026-11-16.9.ps1*' })
Check ($left.Count -eq 0) 'no leftover powershell.exe from the stopped tool'
$srcCheck = [IO.File]::ReadAllText($gui)
Check ($srcCheck.Contains('BtnStop.Visibility = $(if ($On -and $script:Tool.Kind -ne ''ChangesPC'')')) 'Stop is shown for read-only tools only; a tool that changes the PC is never cut off half way'
Check ($srcCheck.Contains('$script:Tool.Kind -eq ''ChangesPC'') { return }')) 'Stop-RunningTool itself refuses a ChangesPC tool'

Write-Host 'House rules for the test hooks' -ForegroundColor Cyan
$src = [IO.File]::ReadAllText($gui)
Check ($src.Contains('$script:TestHooks = (-not $isAdmin) -and [bool]$ResultPath')) 'test hooks exist only in a NON-elevated window'
Check ($src.Contains("if (-not `$script:TestHooks) { `$AutoTool = ''; `$TestValues = ''; `$TestSize = ''; `$TestStopAfter = 0; `$RenderPng = ''; `$RenderScale = 1.0 }")) 'every hook is cleared in an elevated window'
Check ($src -notmatch 'Runspace|Start-Job|Register-ObjectEvent|BeginInvoke\(\[System\.Windows\.Threading\.DispatcherPriority\]::Background') 'no runspaces, jobs or object events'
Check ($src -notmatch '-NonInteractive') 'no -NonInteractive (it makes Read-Host throw in the tools)'

Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
Complete-Test 'Test-GuiWindow'
