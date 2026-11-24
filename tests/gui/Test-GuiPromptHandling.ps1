<#
  Test-GuiPromptHandling.ps1 - prompts through REAL child processes and the GUI's own pump, on the
  console's own code page, on 437 and on 65001 (the window switches 65001 to 437 for its lifetime -
  docs\gui-architecture.md 3, spike S1c). Covers: a -NoNewline prompt is seen at once; a known y/N
  prompt closed with the window X sends the script's default (never yes); an unknown unfinished line
  becomes the generic box only after 5 s of quiet; a quiet COMPLETE line never does; "not a question"
  quiets it; a secret is written to stdin but never shown or logged.
  -Real also runs the real pull-local-logs (newest dated copy, -Hours 1, into a temp folder, not
  elevated) to prove it ends by itself under redirected stdin and prints the lines the window reads.
  No admin, no network. Windows PowerShell 5.1, pure ASCII, no BOM.
#>
param([switch]$Real, [int]$CodePage = 0)
. (Join-Path $PSScriptRoot 'GuiTestLib.ps1')

if ($CodePage -eq 0) {
    # Re-run this file once per code page in a fresh process (the console code page is per process tree).
    $codes = @()
    foreach ($cp in 'own', 437, 65001) {
        $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath, '-CodePage', $(if ($cp -eq 'own') { '-1' } else { [string]$cp }))
        if ($Real -and $cp -eq 'own') { $a += '-Real' }
        & (Join-Path $PSHOME 'powershell.exe') @a
        $codes += $LASTEXITCODE
    }
    if (@($codes | Where-Object { $_ -ne 0 }).Count -gt 0) { Write-Host 'Test-GuiPromptHandling: FAILED on at least one code page' -ForegroundColor Red; exit 1 }
    Write-Host 'Test-GuiPromptHandling: all code pages passed' -ForegroundColor Green; exit 0
}
if ($CodePage -gt 0) { $e = [Text.Encoding]::GetEncoding($CodePage); [Console]::InputEncoding = $e; [Console]::OutputEncoding = $e }
$saved = Set-GuiConsoleEncoding
Write-Host ('=== code page ' + $(if ($CodePage -gt 0) { $CodePage } else { 'own' }) + ' -> window uses ' + [Console]::InputEncoding.CodePage) -ForegroundColor Cyan

$dir = New-TestDir 'prompts'
$child = Join-Path $dir 'child.ps1'
Write-AsciiFile $child @'
param([string]$Mode)
switch ($Mode) {
  'yn'      { Write-Host 'Remove queue "Sample Queue (Copy 1)"? (y/N): ' -NoNewline; $a = Read-Host; Write-Host ('ANSWER=[' + $a + '] len=' + $a.Length) }
  'unknown' { Write-Host 'Pick a colour: ' -NoNewline; $a = Read-Host; Write-Host ('ANSWER=[' + $a + '] len=' + $a.Length) }
  'quiet'   { Write-Host 'Working on something slow...'; Start-Sleep -Seconds 7; Write-Host 'Checking the next thing...' -NoNewline; Start-Sleep -Seconds 7; Write-Host ' done' }
  'secret'  { Write-Host 'Password: ' -NoNewline; $l = [Console]::In.ReadLine(); Write-Host ''; Write-Host ('LEN=' + $l.Length + ' OK=' + ($l -ceq 'Pa55 w0rd!')) }
}
'@
$tool = [pscustomobject]@{ Id = 'T'; Prompts = @([pscustomobject]@{ Id = 'RemoveQueue'; Regex = '^Remove queue ".+"\? \(y/N\):$'; Accept = 'y'; Default = 'n' }) }

# known y/N prompt, closed with the window X -> the default
$seenAfter = $null; $sw = [Diagnostics.Stopwatch]::StartNew()
$c = Invoke-ChildToEnd -ScriptPath $child -ArgumentList @('-Mode', 'yn') -Answer {
    param($c)
    $pp = Get-GuiPendingPrompt -Child $c -Tool $tool
    if ($pp) { if ($null -eq $script:seenAfter) { $script:seenAfter = $sw.ElapsedMilliseconds }; Check ($pp.Kind -eq 'Known') 'y/N prompt recognised from the catalog pattern'; Send-GuiAnswer -Child $c -Text $pp.Prompt.Default }
}
$all = @($c.AllLines) -join "`n"
Check ($all -match 'ANSWER=\[n\] len=1') ('window X on a y/N question sends the default n, read cleanly (no byte order mark): ' + (@($c.AllLines | Where-Object { $_ -like 'ANSWER*' }) -join ''))
Check ($null -ne $script:seenAfter -and $script:seenAfter -lt 10000) ('the -NoNewline prompt was visible to the pump (' + $script:seenAfter + ' ms after start, including PowerShell start-up)')

# unknown prompt: only after 5 s quiet, then X = empty line
$script:firstUnknown = $null; $start = Get-Date
$c = Invoke-ChildToEnd -ScriptPath $child -ArgumentList @('-Mode', 'unknown') -Answer {
    param($c)
    $pp = Get-GuiPendingPrompt -Child $c -Tool $tool
    if ($pp) { $script:firstUnknown = ((Get-Date) - $c.LastOutputUtc.ToLocalTime()).TotalSeconds; Check ($pp.Kind -eq 'Unknown' -and $pp.Text -eq 'Pick a colour:') 'unknown unfinished line -> generic box with the tail text'; Send-GuiAnswer -Child $c -Text '' }
}
Check ($null -ne $script:firstUnknown -and $script:firstUnknown -ge 5) ('generic box only after 5 s of quiet (' + [math]::Round([double]$script:firstUnknown, 1) + ' s)')
Check ((@($c.AllLines) -join "`n") -match 'ANSWER=\[\] len=0') 'closing the generic box sends an empty line'

# "not a question" keeps it away
$c = Start-GuiChild -ScriptPath $child -ArgumentList @('-Mode', 'unknown')
$t0 = Get-Date; $pp = $null
while (-not $pp -and ((Get-Date) - $t0).TotalSeconds -lt 20) { $null = Update-GuiChild $c; $pp = Get-GuiPendingPrompt -Child $c -Tool $tool; Start-Sleep -Milliseconds 100 }
Check ($pp -and $pp.Kind -eq 'Unknown') 'still waiting -> the box'
Set-GuiPromptDismissed -Child $c -Text $pp.Text
Check ($null -eq (Get-GuiPendingPrompt -Child $c -Tool $tool)) '"This is not a question" quiets it'
Check ($null -ne (Get-GuiPendingPrompt -Child $c -Tool $tool -RepeatSeconds 0)) '... and it comes back after the repeat time if the tool is still waiting'
Send-GuiAnswer -Child $c -Text 'blue'
$t0 = Get-Date; while (-not (Update-GuiChild $c).Exited -and ((Get-Date) - $t0).TotalSeconds -lt 15) { Start-Sleep -Milliseconds 100 }
Check ((@($c.AllLines) -join "`n") -match 'ANSWER=\[blue\]') 'a typed answer from the box reaches the tool'
Stop-GuiChild $c

# a quiet COMPLETE line is never a question
$script:falseBox = $false
$null = Invoke-ChildToEnd -ScriptPath $child -ArgumentList @('-Mode', 'quiet') -Answer { param($c) if (Get-GuiPendingPrompt -Child $c -Tool $tool) { $script:falseBox = $true } }
Check (-not $script:falseBox) 'a long quiet step never shows the question box: neither a complete line nor an unfinished "..." progress line'

# a secret: on stdin, never in the console lines
$c = Invoke-ChildToEnd -ScriptPath $child -ArgumentList @('-Mode', 'secret') -Answer { param($c) if (([string]$c.Tail).Trim() -eq 'Password:') { Send-GuiSecret -Child $c -Text 'Pa55 w0rd!' } }
$all = @($c.AllLines) -join "`n"
Check ($all -match 'LEN=10 OK=True') 'the secret reached the child intact'
Check ($all -notmatch 'Pa55') 'the secret appears nowhere in the console lines or the log'

if ($Real) {
    Write-Host 'Real pull-local-logs (newest dated copy), -Hours 1, not elevated, temp output' -ForegroundColor Cyan
    $tool = Get-GuiTool 'PullLocal'
    $out = Join-Path $dir 'real out'
    $v = Get-GuiDefaultValues $tool; $v['Hours'] = 1; $v['OutRoot'] = $out
    $call = Get-GuiToolCall -Tool $tool -ToolRoot $DiagRoot -Values $v
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $c = Invoke-ChildToEnd -ScriptPath $call.ScriptPath -ArgumentList $call.Args -TimeoutSeconds 900 -Answer { param($c) if (Get-GuiPendingPrompt -Child $c -Tool $tool -QuietSeconds 30) { $script:realPrompt = $c.Tail; Write-Host ('    left waiting on: [' + $c.Tail + ']') } }
    $res = Get-GuiRunResult -Tool $tool -Lines @($c.AllLines) -ExitCode $c.ExitCode
    Check (-not (Test-Path variable:script:realPrompt)) 'no question was left waiting (hours and full dump were passed as arguments)'
    Check ($c.Finished) ('ended by itself under redirected stdin in ' + [int]$sw.Elapsed.TotalSeconds + ' s (no "press Enter" wait)')
    Check (-not $res.Failed -and $res.Folder -like ($out + '*')) ('the window found the output folder: ' + $res.Folder)
    Check (@($res.Items | Where-Object { $_.Kind -eq 'Zip' -and $_.Exists }).Count -eq 1) 'the window found the zip'
    Check ((@($c.AllLines) -join "`n") -notmatch 'Opening the folder now') 'no Explorer window was opened by the script'
    $rl = Get-GuiReviewList -Folder $res.Folder -FileName 'StartupAndTasks.txt'
    Check ($rl.Available -and $rl.Text -match '^REVIEW') ('REVIEW LIST read from the real StartupAndTasks.txt')

    # The real pull-remote-logs against a host that does not exist: the username and password prompts are
    # answered exactly as the window answers them (FromInput = the typed input, Secret = Send-GuiSecret),
    # and the script must end by itself with "Could not reach" and a non-zero exit code.
    $rtool = Get-GuiTool 'PullRemote'
    foreach ($case in @(@{ Name = 'with a password'; Pw = 'Pa55 w0rd!'; Blank = $false }, @{ Name = 'blank password'; Pw = ''; Blank = $true })) {
        Write-Host ('Real pull-remote-logs, unreachable host, ' + $case.Name) -ForegroundColor Cyan
        $rout = Join-Path $dir ('remote out ' + [guid]::NewGuid().ToString('N').Substring(0, 6))
        $rv = Get-GuiDefaultValues $rtool
        $rv['ComputerName'] = 'rdgui-nohost.invalid'; $rv['Username'] = '.\rdgui-test'; $rv['Hours'] = 1; $rv['OutRoot'] = $rout
        $rpw = [string]$case.Pw
        $rcall = Get-GuiToolCall -Tool $rtool -ToolRoot $DiagRoot -Values $rv
        $script:rSeen = @{ User = 0; Pass = 0; Other = 0 }
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $rc = Invoke-ChildToEnd -ScriptPath $rcall.ScriptPath -ArgumentList $rcall.Args -TimeoutSeconds 240 -Answer {
            param($c)
            $pp = Get-GuiPendingPrompt -Child $c -Tool $rtool -QuietSeconds 30
            if (-not $pp) { return }
            if ($pp.Kind -ne 'Known') { $script:rSeen.Other++; return }
            switch ([string]$pp.Prompt.Kind) {
                'FromInput' { $script:rSeen.User++; Send-GuiAnswer -Child $c -Text ([string]$rv[[string]$pp.Prompt.Input]).Trim() }
                'Secret' { $script:rSeen.Pass++; Send-GuiSecret -Child $c -Text $rpw }
            }
        }
        $txt = @($rc.AllLines) -join "`n"
        Check ($script:rSeen.User -eq 1 -and $script:rSeen.Pass -eq 1) 'both prompts were seen once and answered from the catalog'
        Check ($script:rSeen.Other -eq 0) 'no unknown question box was needed'
        Check ($rc.Finished -and $rc.ExitCode -ne 0 -and $txt -match 'Could not reach') ('the script ended by itself with a failure in ' + [int]$sw.Elapsed.TotalSeconds + ' s (exit ' + $rc.ExitCode + ')')
        Check ($txt.Contains('[GUI sent the password (not shown)]')) 'the console shows only that a password was sent'
        Check (($txt -match 'Blank password entered') -eq $case.Blank) ('"Blank password entered" is ' + $(if ($case.Blank) { 'printed' } else { 'NOT printed' }))
        $tlog = @(Get-ChildItem -LiteralPath $rout -Filter 'pull-remote-logs_*.log' -ErrorAction SilentlyContinue)
        Check ($tlog.Count -eq 1) 'the script wrote its transcript log'
        if ($rpw) {
            Check (-not $txt.Contains($rpw)) 'the password appears nowhere in the console lines'
            $ttext = $(if ($tlog.Count -eq 1) { [IO.File]::ReadAllText($tlog[0].FullName) } else { '' })
            Check ($ttext.Length -gt 0 -and -not $ttext.Contains($rpw) -and -not $ttext.Contains('Pa55')) 'the password appears nowhere in the transcript log'
        }
    }
}

Restore-GuiConsoleEncoding $saved
Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
Complete-Test ('Test-GuiPromptHandling cp ' + $CodePage)
