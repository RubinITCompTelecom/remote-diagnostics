<#
  Test-GuiHouseRules.ps1 - every file of the window parses, is pure ASCII with no BOM and uses CRLF;
  the launcher keeps the pieces that were paid for (docs\gui-architecture.md 4.1); the scripts changed
  for the window still pass the parse check. Nothing is run. Windows PowerShell 5.1, pure ASCII, no BOM.
#>
. (Join-Path $PSScriptRoot 'GuiTestLib.ps1')

$files = @(Get-ChildItem -LiteralPath $GuiDir -File) + @(Get-ChildItem -LiteralPath $PSScriptRoot -File) + @(Get-Item -LiteralPath (Join-Path $DiagRoot 'Run-RemoteDiagGui.bat'))
Write-Host 'ASCII, no BOM, CRLF' -ForegroundColor Cyan
foreach ($f in $files) {
    $b = [IO.File]::ReadAllBytes($f.FullName)
    Check (-not ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)) ($f.Name + ': no BOM')
    Check (@($b | Where-Object { $_ -gt 127 }).Count -eq 0) ($f.Name + ': pure ASCII')
    $lf = 0; $crlf = 0
    for ($i = 0; $i -lt $b.Length; $i++) { if ($b[$i] -eq 10) { if ($i -gt 0 -and $b[$i - 1] -eq 13) { $crlf++ } else { $lf++ } } }
    Check ($lf -eq 0 -and $crlf -gt 0) ($f.Name + ': CRLF line endings (' + $crlf + ' CRLF, ' + $lf + ' bare LF)')
}

Write-Host 'Parse' -ForegroundColor Cyan
$scripts = @($files | Where-Object { $_.Extension -in '.ps1', '.psm1' }) + @(Get-ChildItem -LiteralPath $DiagRoot -Filter '*.v2026-11-15.*.ps1')
foreach ($f in $scripts) {
    $tokens = $null; $errs = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errs)
    Check (@($errs).Count -eq 0) ($f.Name + ': parses' + $(if (@($errs).Count) { ' - ' + $errs[0].Message } else { '' }))
}
foreach ($f in @($files | Where-Object { $_.Extension -in '.xaml', '.json' })) {
    $ok = $true
    try { if ($f.Extension -eq '.xaml') { [xml]$null = [IO.File]::ReadAllText($f.FullName) } else { $null = [IO.File]::ReadAllText($f.FullName) | ConvertFrom-Json } } catch { $ok = $false }
    Check $ok ($f.Name + ': well-formed')
}

Write-Host 'Core has no WPF types' -ForegroundColor Cyan
$core = [IO.File]::ReadAllText((Join-Path $GuiDir 'Gui.Core.psm1'))
Check ($core -notmatch 'System\.Windows\.(Controls|Media|Window|Markup|Threading|MessageBox)') 'Gui.Core.psm1 references no System.Windows.* type'

Write-Host 'Launcher' -ForegroundColor Cyan
$bat = [IO.File]::ReadAllText((Join-Path $DiagRoot 'Run-RemoteDiagGui.bat'))
$capture = $bat.IndexOf('set "RDG_DP0=%~dp0"'); $delayed = $bat.IndexOf('setlocal EnableDelayedExpansion')
Check ($capture -ge 0 -and $delayed -gt $capture) '%~dp0 is captured before delayed expansion'
Check ($bat.Contains('--elevation-attempted') -and $bat.Contains('if "!RDG_ELEV_ATTEMPTED!"=="1" (')) 'elevates once, never loops the prompt'
Check ($bat.Contains('dir /b /o-n "!RDG_DP0!gui\Start-RemoteDiagGui.v*.ps1"')) 'auto-detects the newest dated window script'
Check ($bat -match 'powershell -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File "!RDG_TARGET!"') 'starts the window with -STA'
Check (@(($bat -split "`r?`n") | Where-Object { $_ -notmatch '^\s*rem ' -and $_ -match '-NonInteractive' }).Count -eq 0) 'no -NonInteractive outside comments'
$others = @(Get-ChildItem -LiteralPath $DiagRoot -Filter 'Run-*.bat' | Where-Object { $_.Name -ne 'Run-RemoteDiagGui.bat' })
Check ($others.Count -ge 8) ('the eight original Run-*.bat launchers are still there (' + $others.Count + ')')
Complete-Test 'Test-GuiHouseRules'
