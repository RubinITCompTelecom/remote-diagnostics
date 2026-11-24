<#
  Test-GuiResultReaders.ps1 - the result panel's readers against fixture output folders: complete,
  empty, truncated, missing (docs\gui-architecture.md, section 6). They must show what the scripts
  wrote and say "not available" otherwise - never guess, never add a verdict.
  No admin, no network. Windows PowerShell 5.1, pure ASCII, no BOM.
#>
. (Join-Path $PSScriptRoot 'GuiTestLib.ps1')

$root = New-TestDir 'readers'
$full = Join-Path $root 'PC1_LOCAL_2026-11-15_1200'; $null = New-Item -ItemType Directory -Path $full
$empty = Join-Path $root 'empty'; $null = New-Item -ItemType Directory -Path $empty
$cut = Join-Path $root 'cut'; $null = New-Item -ItemType Directory -Path $cut
$zip = $full + '.zip'; Write-AsciiFile $zip 'PK'

Write-AsciiFile (Join-Path $full 'StartupAndTasks.txt') "REVIEW LIST (things worth a glance - an inventory, not a verdict):`n  * Task \Evil runs wscript.exe as SYSTEM`n  * Run key Updater -> C:\Users\Public\u.vbs`n`n===== SCHEDULED TASKS =====`nlots more"
Write-AsciiFile (Join-Path $full 'PrintQueues.txt') "REVIEW LIST: nothing flagged.`n`n===== QUEUES =====`n"
Write-AsciiFile (Join-Path $full 'EspUsage.txt') "REVIEW: ESP 92% used | 3 duplicate HP capsules`n`nESP report..."
Write-AsciiFile (Join-Path $empty 'StartupAndTasks.txt') ''
Write-AsciiFile (Join-Path $empty 'EspUsage.txt') "ESP check skipped: not elevated`n"
Write-AsciiFile (Join-Path $cut 'StartupAndTasks.txt') "REVIEW LIST (things worth a glance - an inventory, not a verdict):`n  * Task \A runs"

Write-Host 'REVIEW LIST reader' -ForegroundColor Cyan
$r = Get-GuiReviewList -Folder $full -FileName 'StartupAndTasks.txt'
Check ($r.Available -and $r.Text -match 'Evil' -and $r.Text -match 'Updater' -and $r.Text -notmatch 'SCHEDULED TASKS') 'complete: the REVIEW block only, as written'
$r = Get-GuiReviewList -Folder $full -FileName 'PrintQueues.txt'
Check ($r.Available -and $r.Text -eq 'REVIEW LIST: nothing flagged.') 'nothing flagged: the script''s own words'
$r = Get-GuiReviewList -Folder $full -FileName 'EspUsage.txt'
Check ($r.Available -and $r.Text -match '^REVIEW: ESP 92% used') 'EspUsage: the one-line REVIEW header'
$r = Get-GuiReviewList -Folder $empty -FileName 'StartupAndTasks.txt'
Check (-not $r.Available -and $r.Text -match 'not available \(file is empty\)') 'empty file -> not available'
$r = Get-GuiReviewList -Folder $empty -FileName 'EspUsage.txt'
Check ($r.Available -and $r.Text -match 'no REVIEW line') 'no REVIEW header -> says so, adds nothing'
$r = Get-GuiReviewList -Folder $empty -FileName 'PrintQueues.txt'
Check (-not $r.Available -and $r.Text -match 'file not found') 'missing file -> not available'
$r = Get-GuiReviewList -Folder $cut -FileName 'StartupAndTasks.txt'
Check ($r.Available -and $r.Text -match 'Task \\A runs' -and $r.Text -match 'may be incomplete') 'truncated (half-written) -> what is there, marked as possibly incomplete'
$r = Get-GuiReviewList -Folder '' -FileName 'StartupAndTasks.txt'
Check (-not $r.Available) 'no output folder at all -> not available'

Write-Host 'Run result from the printed lines' -ForegroundColor Cyan
$tool = Get-GuiTool 'PullLocal'
$lines = @('=================', ' Done!', (' Saved to: ' + $full), (' >>> COPY THIS FILE OFF THE MACHINE: ' + $zip), '', ('Full run log saved to: ' + (Join-Path $root 'missing.log')))
$res = Get-GuiRunResult -Tool $tool -Lines $lines -ExitCode 0
Check (-not $res.Failed -and $res.Folder -eq $full) 'complete: folder found and exists'
Check (@($res.Items | Where-Object { $_.Kind -eq 'Zip' -and $_.Exists }).Count -eq 1) 'complete: zip found and exists'
Check (@($res.Items | Where-Object { $_.Kind -eq 'Log' -and -not $_.Exists }).Count -eq 1) 'a path the script printed but that is not on disk is reported as missing'
$res = Get-GuiRunResult -Tool $tool -Lines @('', ' ERROR - something went wrong:', ' boom', 'Full run log saved to: x') -ExitCode 0
Check ($res.Failed -and $res.Folder -eq '') 'the script''s own error banner = failed, even with exit code 0 (the pull scripts exit 0 after an error)'
$res = Get-GuiRunResult -Tool $tool -Lines @() -ExitCode 1
Check ($res.Failed -and @($res.Items).Count -eq 0) 'no output and exit 1 -> failed, nothing to show'
$res = Get-GuiRunResult -Tool $tool -Lines @((' Saved to: ' + (Join-Path $root 'gone'))) -ExitCode 0
Check ($res.Folder -eq '') 'a folder that does not exist is never offered as the output folder'
$res = Get-GuiRunResult -Tool (Get-GuiTool 'PrintWatch') -Lines @(('12:00:01 Done. Send the whole folder: ' + $full)) -ExitCode 0
Check ($res.Folder -eq $full) 'print watch: the time-stamped "Done" line'
$res = Get-GuiRunResult -Tool (Get-GuiTool 'Esp') -Lines @('ERROR: Access denied') -ExitCode 0
Check ($res.Failed) 'ESP: its own ERROR line = failed'

Write-Host 'Failed steps and cancels (the scripts exit 0 / 1 without an error banner)' -ForegroundColor Cyan
$remote = Get-GuiTool 'PullRemote'
$bad = @((' Saved to: ' + $full), '--- System log ---', '  Checking log availability on target... FAILED', '  Pulling events (last 72 hours)... FAILED', '  Pulling events (last 72 hours)... FAILED', '  Establishing session for file transfer... FAILED')
$res = Get-GuiRunResult -Tool $remote -Lines $bad -ExitCode 0
Check (-not $res.Failed -and @($res.Warnings).Count -eq 3) 'remote pull, every step FAILED (wrong password), exit 0 -> not an error banner but 3 distinct warnings (duplicates merged)'
Check (@($res.Warnings)[0] -eq 'Checking log availability on target... FAILED') 'the warning is the script''s own line'
$res = Get-GuiRunResult -Tool $remote -Lines @((' Saved to: ' + $full), '  Pulling events (last 72 hours)... 143 events -> System.csv', '  Checking log availability on target... OK (enabled=True, records currently on target=9)') -ExitCode 0
Check (@($res.Warnings).Count -eq 0 -and -not $res.Failed) 'a healthy pull has no warnings'
$res = Get-GuiRunResult -Tool $tool -Lines @('  Checking log availability... FAILED', '  Pulling events (last 1 hours)... FAILED') -ExitCode 0
Check (@($res.Warnings).Count -eq 2) 'local pull: both failed-step lines are warnings'
$sw = Get-GuiTool 'SwitchPrinter'
$res = Get-GuiRunResult -Tool $sw -Lines @('WARNING: 10.0.0.9 does NOT answer on TCP 9100.', 'Cancelled - nothing changed.') -ExitCode 1
Check ($res.Cancelled -and -not $res.Failed) 'printer switch cancelled at the technician''s own No (exit 1) is a cancel, not an error'
$res = Get-GuiRunResult -Tool $sw -Lines @('Queue "X" not found. Queues on this PC:') -ExitCode 1
Check ($res.Failed -and -not $res.Cancelled) 'printer switch: queue not found, exit 1 -> still an error'

Write-Host 'Text that has to cross the console code page' -ForegroundColor Cyan
$hebrew = [string]([char]0x05E9) + [char]0x05DC + [char]0x05D5 + [char]0x05DD
$savedIn = $null; $changed = $false
try { $savedIn = [Console]::InputEncoding; [Console]::InputEncoding = [Text.Encoding]::GetEncoding(437); $changed = $true } catch { }
if ($changed) {
    Check (Test-GuiTextEncodable 'Pa55 w0rd!') 'ASCII password passes on code page 437'
    Check (Test-GuiTextEncodable '') 'blank password passes'
    Check (-not (Test-GuiTextEncodable $hebrew)) 'a Hebrew password is refused on 437 (it would arrive as ????)'
    try { [Console]::InputEncoding = $savedIn } catch { }
} else { Write-Host '  (no console: encoding check skipped)' -ForegroundColor Yellow }

Write-Host 'Inputs' -ForegroundColor Cyan
$v = Get-GuiDefaultValues $tool
$v['Hours'] = '0'; Check (@(Test-GuiToolValues $tool $v).Count -eq 1) 'hours 0 refused'
$v['Hours'] = '169'; Check (@(Test-GuiToolValues $tool $v).Count -eq 1) 'hours 169 refused'
$v['Hours'] = 'abc'; Check (@(Test-GuiToolValues $tool $v).Count -eq 1) 'hours text refused'
$v['Hours'] = ' 168 '; $v['OutRoot'] = 'relative\dir'; Check (@(Test-GuiToolValues $tool $v).Count -eq 1) 'relative output folder refused, 168 accepted'

Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
Complete-Test 'Test-GuiResultReaders'
