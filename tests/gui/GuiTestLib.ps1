<#
  GuiTestLib.ps1 - shared helpers for tests\gui\*. Dot-sourced. No admin, no network.
  Windows PowerShell 5.1, pure ASCII, no BOM.
#>
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$script:DiagRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$script:GuiDir = Join-Path $script:DiagRoot 'gui'
Import-Module (Join-Path $script:GuiDir 'Gui.Core.psm1') -Force
$script:Failures = New-Object System.Collections.ArrayList
$script:Passes = 0

function Check {
    param([bool]$Condition, [string]$Message)
    if ($Condition) { $script:Passes++; Write-Host ('  [pass] ' + $Message) -ForegroundColor Green }
    else { [void]$script:Failures.Add($Message); Write-Host ('  [FAIL] ' + $Message) -ForegroundColor Red }
}

function Complete-Test {
    param([string]$Name)
    Write-Host ''
    if ($script:Failures.Count -eq 0) { Write-Host ($Name + ': ' + $script:Passes + ' passed') -ForegroundColor Green; exit 0 }
    Write-Host ($Name + ': ' + $script:Failures.Count + ' FAILED, ' + $script:Passes + ' passed') -ForegroundColor Red
    exit 1
}

function New-TestDir {
    param([string]$Name)
    $d = Join-Path ([IO.Path]::GetTempPath()) ('rdgui-' + $Name + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $null = New-Item -ItemType Directory -Path $d -Force
    return $d
}

function Write-AsciiFile {
    param([string]$Path, [string]$Text)
    [IO.File]::WriteAllText($Path, $Text.Replace("`r`n", "`n").Replace("`n", "`r`n"), (New-Object System.Text.ASCIIEncoding))
}

function Invoke-ChildToEnd {
    # Runs a script through the GUI's own pump (Start-GuiChild / Update-GuiChild) until it exits.
    # -Answer: scriptblock($child) called every loop, to answer prompts the way the window would.
    param([string]$ScriptPath, [string[]]$ArgumentList, [scriptblock]$Answer, [int]$TimeoutSeconds = 60)
    $c = Start-GuiChild -ScriptPath $ScriptPath -ArgumentList $ArgumentList
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        $u = Update-GuiChild $c
        if ($u.Exited) { break }
        if ($Answer) { & $Answer $c }
        Start-Sleep -Milliseconds 50
    }
    if (-not $c.Finished) { Stop-GuiChild $c; throw ('timed out: ' + $ScriptPath) }
    return $c
}
