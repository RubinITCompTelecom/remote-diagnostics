<#
  Gui.Core.psm1 - the logic behind the Remote Diagnostics window. NO WPF TYPES HERE.

  The window is a front end, not an engine (gui\..\docs\gui-architecture.md, section 1). This module
    * turns gui\tools.json + the technician's inputs into the exact command line the Run-*.bat
      launcher would run (Resolve-GuiScript / Get-GuiToolCall),
    * starts ONE child powershell.exe at a time and pumps its output without blocking
      (Start-GuiChild / Update-GuiChild / Send-GuiAnswer / Send-GuiSecret), and
    * reads what the scripts printed and wrote (Get-GuiRunResult / Get-GuiReviewList).
  It contains no event-log, dump, network, print, ESP or persistence logic.

  COPIED FROM screenconnect-cleanup\gui\Gui.Core.psm1 (1.8.12-beta.1-offline.2, 2026-11-10) and kept
  in sync by hand: ConvertTo-GuiArg, Set/Restore-GuiConsoleEncoding, Start/Update/Stop-GuiChild,
  Add-GuiChildText, Receive-GuiChildStream, Send-GuiAnswer, the unknown-prompt rule. Differences on
  purpose: Start-GuiChild tolerates no arguments (the original's @($null).Count fails under
  StrictMode), Send-GuiSecret never logs, prompts come from tools.json and may be regexes.

  Tested headless by tests\gui\*. Windows PowerShell 5.1, pure ASCII, no BOM.
#>

Set-StrictMode -Version 2.0

function ConvertTo-GuiArg {
    # One value -> one command-line token, quoted the way CommandLineToArgvW expects. Never via cmd.exe.
    param([AllowEmptyString()][AllowNull()][string]$Value)
    if ($null -eq $Value -or $Value -eq '') { return '""' }
    if ($Value -notmatch '[\s"]') { return $Value }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    $backslashes = 0
    foreach ($ch in $Value.ToCharArray()) {
        if ($ch -eq [char]'\') { $backslashes++; continue }
        if ($ch -eq [char]'"') { [void]$sb.Append([string]('\' * ($backslashes * 2 + 1))); [void]$sb.Append('"'); $backslashes = 0; continue }
        if ($backslashes -gt 0) { [void]$sb.Append([string]('\' * $backslashes)); $backslashes = 0 }
        [void]$sb.Append($ch)
    }
    if ($backslashes -gt 0) { [void]$sb.Append([string]('\' * ($backslashes * 2))) }
    [void]$sb.Append('"')
    return $sb.ToString()
}

function ConvertTo-GuiArgString {
    param([string[]]$Values)
    if (-not $Values) { return '' }
    return ((@($Values) | ForEach-Object { ConvertTo-GuiArg $_ }) -join ' ')
}

function Get-GuiProp {
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    if ($Object -is [System.Collections.IDictionary]) { if ($Object.Contains($Name)) { return $Object[$Name] }; return $Default }
    $p = $Object.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $Default
}

# ---- catalog ------------------------------------------------------------------------------------

function Get-GuiCatalog {
    param([string]$Path = (Join-Path $PSScriptRoot 'tools.json'))
    return ([IO.File]::ReadAllText($Path) | ConvertFrom-Json)
}

function Get-GuiTool {
    param([Parameter(Mandatory = $true)][string]$Id, $Catalog)
    if (-not $Catalog) { $Catalog = Get-GuiCatalog }
    foreach ($t in @($Catalog.Tools)) { if ($t.Id -eq $Id) { return $t } }
    throw ('Unknown tool: ' + $Id)
}

function Resolve-GuiScript {
    # Same choice as every Run-*.bat: the newest <Name>.v*.ps1 by name (dir /b /o-n), else <Name>.ps1.
    param([Parameter(Mandatory = $true)][string]$ToolRoot, [Parameter(Mandatory = $true)][string]$Name)
    $dated = @(Get-ChildItem -LiteralPath $ToolRoot -Filter ($Name + '.v*.ps1') -File -ErrorAction SilentlyContinue |
            Sort-Object -Property Name -Descending)
    if ($dated.Count -gt 0) { return $dated[0].FullName }
    $plain = Join-Path $ToolRoot ($Name + '.ps1')
    if (Test-Path -LiteralPath $plain -PathType Leaf) { return $plain }
    return $null
}

function Get-GuiDefaultValues {
    param($Tool)
    $v = @{}
    foreach ($i in @($Tool.Inputs)) { $v[[string]$i.Id] = (Get-GuiProp $i 'Default' $null) }
    return $v
}

function Test-GuiToolValues {
    # Returns a list of problems (empty = fine). The script validates again itself; this only keeps
    # obviously wrong values from reaching it.
    param($Tool, [hashtable]$Values)
    $errors = @()
    foreach ($i in @($Tool.Inputs)) {
        $val = $Values[[string]$i.Id]
        $label = [string]$i.Label
        if ([bool](Get-GuiProp $i 'Required' $false) -and [string]::IsNullOrWhiteSpace([string]$val) -and $i.Type -ne 'Password') { $errors += ($label + ': required.') }
        if ($i.Type -eq 'Int') {
            $n = 0
            if (-not [int]::TryParse(([string]$val).Trim(), [ref]$n)) { $errors += ($label + ': type a whole number.'); continue }
            if ($n -lt [int]$i.Min -or $n -gt [int]$i.Max) { $errors += ($label + ': must be from ' + $i.Min + ' to ' + $i.Max + '.') }
        }
        if ($i.Type -eq 'Folder' -and -not [string]::IsNullOrWhiteSpace([string]$val) -and -not [IO.Path]::IsPathRooted(([string]$val).Trim())) {
            $errors += ($label + ': give a full path such as C:\Temp, or leave it empty.')
        }
        $pat = [string](Get-GuiProp $i 'Pattern' '')
        if ($pat -and -not [string]::IsNullOrWhiteSpace([string]$val) -and ([string]$val).Trim() -notmatch $pat) { $errors += ($label + ': ' + [string](Get-GuiProp $i 'PatternText' 'not valid.')) }
    }
    return $errors
}

function Get-GuiToolCall {
    # The script and the argument list for a tool, from the technician's values. Exactly what the
    # launcher passes through (%*) when given the same answers as arguments. Stdin inputs (a user name,
    # a password) never appear here. -StopFile is added only for a tool that declares it.
    param([Parameter(Mandatory = $true)]$Tool, [Parameter(Mandatory = $true)][string]$ToolRoot, [hashtable]$Values, [string]$StopFile = '')
    if (-not $Values) { $Values = Get-GuiDefaultValues $Tool }
    $script = Resolve-GuiScript -ToolRoot $ToolRoot -Name ([string]$Tool.Script)
    $out = New-Object System.Collections.ArrayList
    foreach ($i in @($Tool.Inputs)) {
        if ([bool](Get-GuiProp $i 'Stdin' $false)) { continue }
        $val = $Values[[string]$i.Id]
        $default = Get-GuiProp $i 'Default' $null
        $omit = [bool](Get-GuiProp $i 'OmitWhenDefault' $false)
        switch ([string]$i.Type) {
            'Bool' {
                if ([bool]$val) { [void]$out.Add([string]$i.Arg) }
                else { $f = [string](Get-GuiProp $i 'ArgWhenFalse' ''); if ($f) { [void]$out.Add($f) } }
            }
            'Int' {
                $n = [int]([string]$val).Trim()
                if ($omit -and $n -eq [int]$default) { continue }
                [void]$out.Add([string]$i.Arg); [void]$out.Add([string]$n)
            }
            default {
                $s = ([string]$val).Trim()
                if ($s -eq '' -or ($omit -and $s -eq [string]$default)) { continue }
                [void]$out.Add([string]$i.Arg); [void]$out.Add($s)
            }
        }
    }
    if ($StopFile -and [bool](Get-GuiProp $Tool 'StopFile' $false)) { [void]$out.Add('-StopFile'); [void]$out.Add($StopFile) }
    return [pscustomobject]@{ ScriptPath = $script; Args = @($out.ToArray()) }
}

function Get-GuiMemoryDumpInfo {
    # Display only: is there a C:\Windows\MEMORY.DMP and how big is it (the full-dump tick box shows it).
    param([string]$Path = (Join-Path $env:SystemRoot 'MEMORY.DMP'))
    try {
        $f = Get-Item -LiteralPath $Path -ErrorAction Stop
        return [pscustomobject]@{ Exists = $true; SizeGB = [math]::Round($f.Length / 1GB, 2) }
    } catch { return [pscustomobject]@{ Exists = $false; SizeGB = 0 } }
}

# ---- console encoding (docs\gui-architecture.md 3: a 65001 console corrupts redirected stdin) -----

function Set-GuiConsoleEncoding {
    $saved = [pscustomobject]@{ In = $null; Out = $null; Changed = $false }
    try {
        $saved.In = [Console]::InputEncoding
        $saved.Out = [Console]::OutputEncoding
        if ($saved.In.CodePage -eq 65001 -or $saved.Out.CodePage -eq 65001) {
            $e = [Text.Encoding]::GetEncoding(437)
            [Console]::InputEncoding = $e
            [Console]::OutputEncoding = $e
            $saved.Changed = $true
        }
    } catch { }
    return $saved
}

function Restore-GuiConsoleEncoding {
    param($Saved)
    if ($Saved -and $Saved.Changed) { try { [Console]::InputEncoding = $Saved.In; [Console]::OutputEncoding = $Saved.Out } catch { } }
}

# ---- one child process at a time ----------------------------------------------------------------

function Start-GuiChild {
    param([Parameter(Mandatory = $true)][string]$ScriptPath, [string[]]$ArgumentList, [string]$WorkingDirectory)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = (Join-Path $PSHOME 'powershell.exe')
    $argText = '-NoProfile -ExecutionPolicy Bypass -File ' + (ConvertTo-GuiArg $ScriptPath)
    if ($ArgumentList -and $ArgumentList.Length -gt 0) { $argText += ' ' + (ConvertTo-GuiArgString $ArgumentList) }
    $psi.Arguments = $argText
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardInput = $true
    $enc = [Console]::OutputEncoding
    $psi.StandardOutputEncoding = $enc
    $psi.StandardErrorEncoding = $enc
    if ($WorkingDirectory -and (Test-Path -LiteralPath $WorkingDirectory)) { $psi.WorkingDirectory = $WorkingDirectory }
    $p = [System.Diagnostics.Process]::Start($psi)
    $outBuf = New-Object char[] 4096
    $errBuf = New-Object char[] 4096
    $now = (Get-Date).ToUniversalTime()
    return [pscustomobject]@{
        Process = $p; CommandLine = ($psi.FileName + ' ' + $argText)
        OutBuf = $outBuf; ErrBuf = $errBuf
        OutTask = $p.StandardOutput.ReadAsync($outBuf, 0, $outBuf.Length)
        ErrTask = $p.StandardError.ReadAsync($errBuf, 0, $errBuf.Length)
        OutEof = $false; ErrEof = $false; Tail = ''; ErrTail = ''
        PendingLines = (New-Object System.Collections.ArrayList)
        AllLines = (New-Object System.Collections.ArrayList)
        StartedUtc = $now; LastOutputUtc = $now; ExitedUtc = $null
        DismissedTail = ''; DismissedUtc = $null; AnsweredTail = ''; Finished = $false; ExitCode = $null
    }
}

function Add-GuiChildText {
    param($Child, [string]$Text, [bool]$IsError)
    if ([string]::IsNullOrEmpty($Text)) { return }
    $Text = $Text.Replace([string][char]0xFEFF, '').Replace("`r`n", "`n").Replace("`r", "`n")
    $Child.LastOutputUtc = (Get-Date).ToUniversalTime()
    $prefix = ''
    if ($IsError) { $combined = $Child.ErrTail + $Text; $prefix = '[stderr] ' } else { $combined = $Child.Tail + $Text }
    $parts = $combined.Split([char]"`n")
    for ($i = 0; $i -lt $parts.Length - 1; $i++) { [void]$Child.PendingLines.Add($prefix + $parts[$i]); [void]$Child.AllLines.Add($prefix + $parts[$i]) }
    if ($IsError) { $Child.ErrTail = $parts[$parts.Length - 1] } else { $Child.Tail = $parts[$parts.Length - 1] }
}

function Receive-GuiChildStream {
    param($Child, [bool]$IsError)
    if ($IsError) { $task = $Child.ErrTask; $buf = $Child.ErrBuf; $reader = $Child.Process.StandardError; $eof = $Child.ErrEof }
    else { $task = $Child.OutTask; $buf = $Child.OutBuf; $reader = $Child.Process.StandardOutput; $eof = $Child.OutEof }
    while ((-not $eof) -and $task.IsCompleted) {
        $n = 0
        if (-not $task.IsFaulted -and -not $task.IsCanceled) { $n = $task.Result }
        if ($n -le 0) { $eof = $true; break }
        Add-GuiChildText -Child $Child -Text (New-Object string -ArgumentList @(, $buf[0..($n - 1)])) -IsError $IsError
        $task = $reader.ReadAsync($buf, 0, $buf.Length)
    }
    if ($IsError) { $Child.ErrTask = $task; $Child.ErrEof = $eof } else { $Child.OutTask = $task; $Child.OutEof = $eof }
}

function Update-GuiChild {
    # Call from the UI timer. Never blocks. Returns the new complete lines and, once the process has
    # exited and its output is drained (or 1.5 s after exit), Exited = $true and the exit code.
    param($Child)
    Receive-GuiChildStream -Child $Child -IsError $false
    Receive-GuiChildStream -Child $Child -IsError $true
    $exited = $false
    if ($Child.Process.HasExited) {
        if (-not $Child.ExitedUtc) { $Child.ExitedUtc = (Get-Date).ToUniversalTime() }
        $grace = ((Get-Date).ToUniversalTime() - $Child.ExitedUtc).TotalMilliseconds
        if (($Child.OutEof -and $Child.ErrEof) -or $grace -gt 1500) { $exited = $true }
    }
    if ($exited -and -not $Child.Finished) {
        if ($Child.Tail -ne '') { [void]$Child.PendingLines.Add($Child.Tail); [void]$Child.AllLines.Add($Child.Tail); $Child.Tail = '' }
        if ($Child.ErrTail -ne '') { [void]$Child.PendingLines.Add('[stderr] ' + $Child.ErrTail); [void]$Child.AllLines.Add('[stderr] ' + $Child.ErrTail); $Child.ErrTail = '' }
        $Child.Finished = $true
        $Child.ExitCode = [int]$Child.Process.ExitCode
    }
    $lines = @($Child.PendingLines.ToArray())
    $Child.PendingLines.Clear()
    return [pscustomobject]@{ Lines = $lines; Exited = $Child.Finished; ExitCode = $Child.ExitCode }
}

function Write-GuiStdin {
    param($Child, [string]$Text)
    $bytes = [Console]::InputEncoding.GetBytes($Text + "`r`n")
    $s = $Child.Process.StandardInput.BaseStream
    $s.Write($bytes, 0, $bytes.Length)
    $s.Flush()
    [Array]::Clear($bytes, 0, $bytes.Length)
    $Child.AnsweredTail = $Child.Tail
    $Child.Tail = ''
    $Child.LastOutputUtc = (Get-Date).ToUniversalTime()
}

function Send-GuiAnswer {
    # One answer line, as RAW BYTES in the console's code page (no byte order mark). Logged in the console.
    param($Child, [AllowEmptyString()][string]$Text)
    Write-GuiStdin -Child $Child -Text $Text
    $shown = $(if ($Text -eq '') { '(empty line)' } else { $Text })
    [void]$Child.PendingLines.Add('[GUI sent answer: ' + $shown + ']')
    [void]$Child.AllLines.Add('[GUI sent answer: ' + $shown + ']')
}

function Send-GuiSecret {
    # A password line: written to stdin only, never shown, logged or kept. The caller clears its copy.
    param($Child, [AllowEmptyString()][string]$Text)
    Write-GuiStdin -Child $Child -Text $Text
    [void]$Child.PendingLines.Add('[GUI sent the password (not shown)]')
    [void]$Child.AllLines.Add('[GUI sent the password (not shown)]')
}

function Test-GuiTextEncodable {
    # Can this text reach the child through the console's input code page unchanged? A character the code
    # page does not have would arrive as "?" - a password that silently fails. Checked BEFORE a run.
    param([AllowEmptyString()][AllowNull()][string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return $true }
    $enc = [Console]::InputEncoding
    $bytes = $enc.GetBytes($Text)
    $back = $enc.GetString($bytes)
    [Array]::Clear($bytes, 0, $bytes.Length)
    return ($back -ceq $Text)
}

function Stop-GuiChild {
    # Ends a running tool and its whole tree. Never called on a timer.
    param($Child)
    if (-not $Child -or $Child.Process.HasExited) { return }
    try { & taskkill.exe /PID $Child.Process.Id /T /F | Out-Null } catch { try { $Child.Process.Kill() } catch { } }
}

# ---- prompts --------------------------------------------------------------------------------------

function Test-GuiPromptMatch {
    param($Prompt, [string]$Text)
    $rx = [string](Get-GuiProp $Prompt 'Regex' '')
    if ($rx) { return [regex]::IsMatch($Text, $rx) }
    return ($Text -ceq [string]$Prompt.Text)
}

function Get-GuiPendingPrompt {
    # Looks at the UNFINISHED output line (prompts are printed with Write-Host -NoNewline). A known prompt
    # of this tool matches its catalog row at once. Any other unfinished line that stays quiet for
    # -QuietSeconds becomes the generic "the tool is waiting for an answer" box. Complete lines never do,
    # so a long quiet step does not look like a question. "Not a question" quiets it for -RepeatSeconds.
    param($Child, $Tool, [int]$QuietSeconds = 5, [int]$RepeatSeconds = 60)
    if ($Child.Finished) { return $null }
    $t = ([string]$Child.Tail).Trim()
    if ($t -eq '') { return $null }
    foreach ($p in @(Get-GuiProp $Tool 'Prompts' @())) {
        if (Test-GuiPromptMatch -Prompt $p -Text $t) { return [pscustomobject]@{ Kind = 'Known'; Prompt = $p; Text = $t } }
    }
    # A progress line ("Checking for BSODs...") is printed -NoNewline before slow work: never a question.
    # Every real prompt ends with ':' or '?' (Test-GuiPromptContract.ps1 holds the scripts to that).
    if ($t.EndsWith('...')) { return $null }
    $now = (Get-Date).ToUniversalTime()
    if (($now - $Child.LastOutputUtc).TotalSeconds -lt $QuietSeconds) { return $null }
    if ($Child.DismissedTail -eq $t -and $Child.DismissedUtc -and ($now - $Child.DismissedUtc).TotalSeconds -lt $RepeatSeconds) { return $null }
    return [pscustomobject]@{ Kind = 'Unknown'; Prompt = $null; Text = $t }
}

function Set-GuiPromptDismissed {
    param($Child, [string]$Text)
    $Child.DismissedTail = $Text
    $Child.DismissedUtc = (Get-Date).ToUniversalTime()
}

# ---- results (read-only; a missing or half-written file is "not available") ------------------------

function Get-GuiRunResult {
    # What the script said it wrote (Results patterns in tools.json), checked against the disk.
    # Exit code non-zero, or the script's own error banner, is a failure. Nothing here is a verdict.
    param($Tool, [string[]]$Lines, $ExitCode)
    $items = New-Object System.Collections.ArrayList
    foreach ($r in @(Get-GuiProp $Tool 'Results' @())) {
        foreach ($l in @($Lines)) {
            $m = [regex]::Match([string]$l, [string]$r.Pattern)
            if (-not $m.Success) { continue }
            $path = $m.Groups['v'].Value.Trim()
            $exists = $false
            try { $exists = Test-Path -LiteralPath $path } catch { }
            [void]$items.Add([pscustomobject]@{ Kind = [string]$r.Kind; Path = $path; Exists = [bool]$exists })
        }
    }
    $failed = ($null -ne $ExitCode -and [int]$ExitCode -ne 0)
    # Cancel: a line that says the technician's own "no" ended the tool (a non-zero exit code by design).
    $cancelled = $false
    $cx = Get-GuiProp $Tool 'Cancel' $null
    if ($cx) { foreach ($l in @($Lines)) { if ([regex]::IsMatch([string]$l, [string]$cx.Pattern)) { $cancelled = $true } } }
    if ($cancelled) { $failed = $false }
    $fail = Get-GuiProp $Tool 'Failure' $null
    if ($fail) { foreach ($l in @($Lines)) { if ([regex]::IsMatch([string]$l, [string]$fail.Pattern)) { $failed = $true; $cancelled = $false } } }
    # Warnings: step lines that ended in FAILED. The pull scripts exit 0 and print no error banner when a
    # step fails (wrong password: every log "FAILED"), so a plain "Finished." would be a false all-clear.
    $warnings = New-Object System.Collections.ArrayList
    foreach ($w in @(Get-GuiProp $Tool 'Warnings' @())) {
        foreach ($l in @($Lines)) {
            if ([regex]::IsMatch([string]$l, [string]$w.Pattern)) { $t = ([string]$l).Trim(); if (-not $warnings.Contains($t)) { [void]$warnings.Add($t) } }
        }
    }
    $folder = @($items | Where-Object { $_.Kind -eq 'Folder' -and $_.Exists } | Select-Object -Last 1)
    return [pscustomobject]@{
        Failed = $failed; Cancelled = $cancelled; Warnings = @($warnings.ToArray()); ExitCode = $ExitCode; Items = @($items.ToArray())
        Folder = $(if ($folder.Count -gt 0) { $folder[0].Path } else { '' })
    }
}

function Get-GuiReviewList {
    # The REVIEW block a pull script writes at the top of StartupAndTasks.txt / PrintQueues.txt /
    # EspUsage.txt, as plain text. Shown exactly as written; the GUI adds no verdict.
    param([string]$Folder, [string]$FileName, [int]$MaxLines = 40)
    $path = $(if ($Folder) { Join-Path $Folder $FileName } else { '' })
    $na = { param($why) [pscustomobject]@{ File = $FileName; Available = $false; Text = ('not available (' + $why + ')') } }
    if (-not $path -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { return (& $na 'file not found') }
    $text = ''
    try { $text = [IO.File]::ReadAllText($path) } catch { return (& $na ('could not be read: ' + $_.Exception.Message)) }
    $text = $text.Replace([string][char]0xFEFF, '')
    if ([string]::IsNullOrWhiteSpace($text)) { return (& $na 'file is empty') }
    $lines = @($text -split "`r?`n")
    if ($lines[0] -notmatch '^REVIEW') { return [pscustomobject]@{ File = $FileName; Available = $true; Text = '(no REVIEW line at the top of this file)' } }
    $block = @()
    foreach ($l in $lines) { if ($l.Trim() -eq '') { break }; $block += $l }
    $more = ''
    if ($block.Count -gt $MaxLines) { $more = "`r`n... (" + ($block.Count - $MaxLines) + ' more lines in the file)'; $block = $block[0..($MaxLines - 1)] }
    if ($block.Count -eq $lines.Count) { $more += "`r`n(the file ends here - it may be incomplete)" }
    return [pscustomobject]@{ File = $FileName; Available = $true; Text = (($block -join "`r`n") + $more) }
}

Export-ModuleMember -Function `
    ConvertTo-GuiArg, ConvertTo-GuiArgString, Get-GuiProp, Get-GuiCatalog, Get-GuiTool, Resolve-GuiScript, `
    Get-GuiDefaultValues, Test-GuiToolValues, Get-GuiToolCall, Get-GuiMemoryDumpInfo, `
    Set-GuiConsoleEncoding, Restore-GuiConsoleEncoding, `
    Start-GuiChild, Update-GuiChild, Send-GuiAnswer, Send-GuiSecret, Test-GuiTextEncodable, Stop-GuiChild, `
    Test-GuiPromptMatch, Get-GuiPendingPrompt, Set-GuiPromptDismissed, Get-GuiRunResult, Get-GuiReviewList
