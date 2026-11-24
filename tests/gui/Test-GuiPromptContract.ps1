<#
  Test-GuiPromptContract.ps1 - the window depends on text the scripts print and on the parameters they
  take (gui\tools.json). If a script is reworded, this test fails instead of a window hanging on a
  client PC (docs\gui-architecture.md, section 4).

  For every tool the window offers, against the script the launcher would pick:
    1. each input's argument is a parameter of the script;
    2. each Results / Failure line the window reads is still printed;
    3. each prompt the window answers is still printed with Write-Host -NoNewline (Read-Host '<text>'
       is invisible under redirected stdin - spike S1b) and its pattern matches that text;
    4. EVERY Read-Host in the script is either one of those prompts or listed in AllowedReadHost with
       the reason the window never reaches it. A new Read-Host fails here until someone decides.
  Nothing is run. Windows PowerShell 5.1, pure ASCII, no BOM.
#>
. (Join-Path $PSScriptRoot 'GuiTestLib.ps1')

$catalog = Get-GuiCatalog
foreach ($t in @($catalog.Tools)) {
    if (-not $t.Enabled) {
        Check ([bool](Get-GuiProp $t 'DisabledWhy' '')) ($t.Id + ': not offered yet, and says why')
        continue
    }
    Write-Host ($t.Id + ' (' + $t.Script + ')') -ForegroundColor Cyan
    $path = Resolve-GuiScript -ToolRoot $DiagRoot -Name $t.Script
    Check ($null -ne $path) ($t.Id + ': script found')
    if (-not $path) { continue }
    $text = [IO.File]::ReadAllText($path)
    $lines = @($text -split "`r?`n")
    # Lines inside a <# ... #> block are documentation, not code: they may mention Read-Host and
    # -NoNewline (the pull-remote-logs header does) without printing or reading anything.
    $inBlock = New-Object 'bool[]' $lines.Count
    $open = $false
    for ($n = 0; $n -lt $lines.Count; $n++) {
        $tl = $lines[$n].Trim()
        if (-not $open -and $tl.StartsWith('<#')) { $open = $true }
        $inBlock[$n] = $open
        if ($open -and $tl.EndsWith('#>')) { $open = $false }
    }
    $codeLines = @(for ($n = 0; $n -lt $lines.Count; $n++) { if (-not $inBlock[$n]) { $lines[$n] } })

    foreach ($i in @($t.Inputs)) {
        foreach ($a in @([string](Get-GuiProp $i 'Arg' ''), [string](Get-GuiProp $i 'ArgWhenFalse' '')) | Where-Object { $_ }) {
            Check ([regex]::IsMatch($text, '\$' + [regex]::Escape($a.TrimStart('-')) + '\b')) ($t.Id + ': parameter ' + $a + ' exists')
        }
    }
    if ([bool](Get-GuiProp $t 'StopFile' $false)) { Check ($text -match '\[string\]\$StopFile') ($t.Id + ': parameter -StopFile exists') }

    $reads = @(Get-GuiProp $t 'Results' @())
    $f = Get-GuiProp $t 'Failure' $null
    if ($f) { $reads += $f }
    foreach ($w in @(Get-GuiProp $t 'Warnings' @())) { $reads += $w }
    $cx = Get-GuiProp $t 'Cancel' $null
    if ($cx) { $reads += $cx }
    foreach ($r in $reads) { Check ($text.Contains([string]$r.Source)) ($t.Id + ': still prints "' + $r.Source + '"') }

    foreach ($p in @($t.Prompts)) {
        $src = [string]$p.Source
        $hit = @($lines | Where-Object { $_.Contains($src) -and $_ -match 'Write-Host' -and $_ -match '-NoNewline' })
        Check ($hit.Count -ge 1) ($t.Id + ': prompt "' + $src + '" is printed with Write-Host -NoNewline')
        $sample = ($src -replace '\{0\}', 'Sample Queue (Copy 1)').Trim()
        Check (Test-GuiPromptMatch -Prompt $p -Text $sample) ($t.Id + ': prompt pattern matches "' + $sample + '"')
    }

    foreach ($l in @($codeLines | Where-Object { $_ -match 'Write-Host' -and $_ -match '-NoNewline' -and -not $_.TrimStart().StartsWith('#') })) {
        $isPrompt = $false
        foreach ($p in @($t.Prompts)) { if ($l.Contains([string]$p.Source)) { $isPrompt = $true } }
        Check ($isPrompt -or $l -match '\.\.\.[`n ]*["'']') ($t.Id + ': -NoNewline text is a catalog prompt or a progress line ending in "...": ' + $l.Trim())
    }

    for ($n = 0; $n -lt $lines.Count; $n++) {
        $l = $lines[$n]
        if ($l -notmatch 'Read-Host' -or $l.TrimStart().StartsWith('#') -or $inBlock[$n]) { continue }
        $prev = $(if ($n -gt 0) { $lines[$n - 1] } else { '' })
        $ok = $false
        foreach ($p in @($t.Prompts)) { if ($l.Contains([string]$p.Source) -or $prev.Contains([string]$p.Source)) { $ok = $true } }
        foreach ($a in @($t.AllowedReadHost)) { if ($l.Contains([string]$a.Contains)) { $ok = $true } }
        Check $ok ($t.Id + ': Read-Host at line ' + ($n + 1) + ' is answered or never reached: ' + $l.Trim())
    }
}
Complete-Test 'Test-GuiPromptContract'
