# Remote Diagnostics window - architecture

Status (2026-11-15, window `v2026-11-15.1`): **phases 0 to 3 are built.** Phase 3 (remote pull with a
password, Enable / Revert remote diagnostics, Switch printer) is tested against stubs, and the remote pull
was run for real against a non-existent host, which proves the password path. Nothing has been accepted on
a real client PC. The password decision is section 8 (option A).

Modelled on `screenconnect-cleanup/docs/14-gui-architecture.md` (the ScreenConnect Cleanup window).
Where this file says "docs/14" it means that document.

---

## 1. The one rule

**The window is a front end, not an engine.** It starts the same `.ps1` the `Run-*.bat` launcher
starts, in its own child `powershell.exe -File`, with the same arguments, and shows what the script
printed and wrote. It contains no event-log, dump, network, print, ESP or persistence logic. If a
feature needs engine logic, the change goes into the script (additive, interactive behaviour
unchanged, a new dated version) and the window calls it.

## 2. Decisions (G1-G8 of docs/14, carried over)

| # | Decision |
|---|---|
| G1 | PowerShell 5.1 + WPF, XAML loaded at run time with `XamlReader`. No EXE, no NuGet. Pure ASCII, no BOM, CRLF (kept by `.gitattributes`). |
| G2 | `Run-RemoteDiagGui.bat` elevates **once** (`--elevation-attempted`), `%~dp0` captured before delayed expansion, then `powershell -STA -File gui\Start-RemoteDiagGui.v*.ps1` (newest dated copy). Never `-NonInteractive`. No battery check or keep-awake (nothing here needs them). |
| G3 | Each run is a child `powershell.exe -NoProfile -ExecutionPolicy Bypass -File <script> <args>`: `UseShellExecute=false`, `CreateNoWindow=true`, stdout / stderr / stdin redirected. |
| G4 | One UI thread, one `DispatcherTimer` (250 ms). No runspaces, jobs or `Register-ObjectEvent`. One pending `ReadAsync` per stream: characters, not lines, so `-NoNewline` prompts show. |
| G5 | Prompts stay in the scripts. The window prefers parameters; an answer is written to stdin only from the technician's own click or typing. Closing a box sends the script's default, never yes. |
| G6 | The output folder is the only source of truth. The window's console log (`%TEMP%\RemoteDiagGui\<tool>_<time>.log`) is display only. |
| G7 | The eight `Run-*.bat` files are unchanged and remain the fallback. |
| G8 | One child at a time. The window never stops a tool on a timer; it shows elapsed time and "no output for N minutes" as information. |

## 3. Spike results (phase 0, 2026-11-15, Windows 11 26300, Hebrew locale, code page 862, NOT elevated)

| Spike | Answer | Evidence |
|---|---|---|
| S1 stdin answer reaches `Read-Host` in a redirected 5.1 child | **Yes** on OEM code pages (862, 437). On 65001 the first character arrives as a byte order mark ("yes1" read as 7 characters) until the window switches the console to 437 (`Set-GuiConsoleEncoding`, same fix as docs/14 12.3). Note: a redirected `Read-Host` **echoes the line it read** to stdout. | `tests\gui\Test-GuiPromptHandling.ps1` on own / 437 / 65001 |
| S1b `Read-Host '<text>'` shows its text | **No** under redirected stdin (same as docs/14 12.3). Every prompt the window answers must be printed with `Write-Host ... -NoNewline`; `Test-GuiPromptContract.ps1` enforces it. | spike `child.ps1` Q2 |
| S2 `Read-Host -AsSecureString` reads a line from redirected stdin | **NO. It hangs** (still waiting after 30 s; the line written to stdin is never consumed). The remote pull's password prompt therefore cannot be answered by the window as the script was written. Resolved in phase 3 by option A (section 8). | spike `child2.ps1 -Mode secure` |
| S2b alternative: `[Console]::In.ReadLine()` + `SecureString.AppendChar` | **Yes**, password and blank password both arrive intact and are NOT echoed (unlike `Read-Host`). This is option A in section 8. | spike `child2.ps1 -Mode readline`; `Test-GuiPromptHandling.ps1` (secret) |
| S3 a `-NoNewline` prompt is visible within one tick | **Yes** (seen 1.1-1.5 s after start, which is PowerShell start-up). | `Test-GuiPromptHandling.ps1` |
| S4 WPF window from **elevated** `powershell -STA` | **Not proven.** This PC's session is not elevated; the window was opened non-elevated only (`Test-GuiWindow.ps1`). Owner check, section 9. | - |
| Extra: `Start-GuiChild` with no arguments | The ScreenConnect core's `@($ArgumentList).Count` throws under StrictMode when no argument list is given (non-terminating; the child still starts). Fixed in this copy (`$ArgumentList.Length`). ScreenConnect always passes arguments, so it is not hit there. | spike `drive.ps1` |

## 4. Prompts: what the window does with each `Read-Host`

`tools.json` lists, per tool, the prompts the window answers (`Prompts`) and every other `Read-Host`
with the reason it is never reached (`AllowedReadHost`). `Test-GuiPromptContract.ps1` fails on a
`Read-Host` that is in neither list.

| Script | `Read-Host` | How the window handles it |
|---|---|---|
| `pull-local-logs` | hours back | never reached: the window always passes `-Hours` (default 72, 1-168) |
| `pull-local-logs` | include full MEMORY.DMP? [y/N] | never reached. **Decision: always pass an explicit answer.** Ticked -> `-IncludeFullDump`; unticked -> the new `-NoFullDump` switch (added in `pull-local-logs.v2026-11-15.1`, additive). Chosen over answering stdin because that prompt is a `Read-Host '<text>'` (invisible, S1b) |
| `pull-local-logs` | final "Press Enter to close" | skipped when `[Console]::IsInputRedirected` (v2026-11-15.1); the automatic `Invoke-Item` of the output folder is skipped the same way, so nothing opens on its own. Interactive runs are unchanged |
| `pull-remote-logs` | ComputerName prompt | never reached: the window always passes `-ComputerName` |
| `pull-remote-logs` | Username prompt | the window sends the username from its box when `Username: ` appears (printed with `Write-Host -NoNewline`, v2026-11-15.1) |
| `pull-remote-logs` | Password prompt | the window sends the password from its password box with `Send-GuiSecret` when `Password: ` appears. Under redirected input the script reads it with `[Console]::In.ReadLine()` into a SecureString (`Read-Host -AsSecureString` hangs). Never shown, logged, stored, or on a command line, file or environment variable. The box is cleared after sending |
| `pull-remote-logs` | include full MEMORY.DMP? [y/N] | never reached: full dump handled as for the local pull (`-IncludeFullDump` or `-NoFullDump`) |
| `pull-remote-logs` | final "Press Enter to close" | skipped under redirected input; no automatic Explorer window |
| `enable-remote-diag` | two closing "Press Enter" waits | skipped under redirected input (`enable-remote-diag.v2026-11-15.1`). Interactive runs unchanged |
| `revert-remote-diag` | none | no prompts; the window runs it as is |
| `Switch-PrinterToTcpIp` | IP address prompt | never reached: the window always passes `-IpAddress` |
| `Switch-PrinterToTcpIp` | the four y/N questions | printed with `Write-Host -NoNewline` and shown as Yes / No boxes; X = No |
| `Check-CameraAndStartup` | fix y/N questions | never reached: the window offers the report only (the launcher's R); F and A stay in the .bat |
| `pull-persistence`, `Check-EspUsage`, `Watch-PrintFreeze` | none | - |
| any | an unfinished line, quiet 5 s, matching no row | the generic "The tool is waiting for an answer" box (docs/14 4.3 rule 4). X sends an empty line; "This is not a question" quiets it for 60 s. A complete line never triggers it |

`Watch-PrintFreeze` stops with Ctrl+C, which a window cannot send to a hidden child, and killing it would
skip its save step. `Watch-PrintFreeze.v2026-11-15.1` adds `-StopFile <path>` (additive): the window's
**Stop and save** button creates that file and the watch ends exactly as after Ctrl+C.

## 5. Files

```text
Run-RemoteDiagGui.bat                 launcher (G2), beside the other Run-*.bat
gui/
  Start-RemoteDiagGui.v<date>.<N>.ps1 the window and its timer (dated: versioning convention)
  Gui.Core.psm1                       NO System.Windows.* types: catalog, command lines, process pump,
                                      prompts, result readers. Tested headless
  MainWindow.xaml                     the window; tokens and styles copied from the ScreenConnect window
  tools.json                          the tool catalog as data
tests/gui/                            the six tests below (+ GuiTestLib.ps1)
docs/gui-architecture.md              this file
```

Copied from the ScreenConnect GUI (2026-11-10) and kept in sync by hand - each file says so at the top:
the process pump, console-encoding fix, argument quoting, unknown-prompt rule (`Gui.Core.psm1`); the
`Window.Resources` block verbatim (`MainWindow.xaml`); DPI v2, theme, dialog primitive, console, banner,
fit-to-screen / compact layout, footer, unhandled-exception handler (`Start-RemoteDiagGui`).

Size after Phase 3 review: 1,754 physical lines including comments/data (core 411, window 665,
XAML 430, catalog 160, launcher 88), plus tests. Above the approximate 1,000-1,500 target, below
the 2,500 stop-and-recheck threshold. Diagnostic logic remains in the tool scripts.

## 6. Window

- **Header**: "Remote Diagnostics v<window version>", PC name, elevated yes/no, the scripts folder.
- **Start panel**: one card per tool from `tools.json`: a badge in words (READ-ONLY / CHANGES THIS PC /
  RUNS UNTIL STOPPED), the title and one sentence. All nine tools are offered. A tool that is switched
  off in `tools.json` is greyed with the reason.
- **Confirmation**: a tool that changes the PC (Enable, Revert, Switch printer) asks Yes / No before it
  runs. Read-only tools start on Run. Nothing is started without a click.
- **Run panel**: status card (title, badge, elapsed clock, progress), banner, the result (after a run),
  the notice for the tool, its inputs as normal controls, Run / Run again, **Stop** (read-only tools while they run) and Stop and save (print watch).
- **Result**: the output folder, zip and files the script printed, each checked on disk ("not found on
  disk" otherwise), Open folder / Open ... location, and the REVIEW block at the top of
  `StartupAndTasks.txt`, `PrintQueues.txt` and `EspUsage.txt` exactly as written, or "not available".
  A run is "failed" on a non-zero exit code **or** the script's own error banner (the pull scripts exit 0
  after an error). No verdicts.
- **Console**: live output, Copy, Open log.
- **Closing**: idle - closes. While a tool that changes the PC runs the window refuses to close; closing a read-only run asks before stopping it. No tool is stopped on a
  timer. **Stop** (a button next to Run, and "Stop the tool" in the "waiting for an answer" box) asks, then ends the tool and everything
  it started; the banner says "Stopped at your request" (not failed). It is shown for read-only tools only: a tool that changes the PC is never cut off
  half way, its way out is the confirmation's Cancel and the Yes/No boxes' No. For the print watch, Stop discards (no save step): use **Stop and save**
  to keep its events and crash reports. Test hook: `-TestStopAfter <seconds>`.
- **Fits the screen**: opens at 1120x760 or the work area, whichever is smaller. Below 1000 wide the
  cards go to one column; below 660 high the console shrinks to 88 and the margins tighten.
  Per-monitor DPI v2, light and dark tokens, footer links opened only when clicked.
- Test hooks (`-ResultPath`, `-AutoTool`, `-TestValues`, `-TestSize`, `-RenderPng`) are honoured only in a
  window that is NOT elevated; the launcher always elevates.

## 7. What must not be built

A second copy of any diagnostic logic; runspaces or background PowerShell; an EXE, installer,
auto-update or settings database; a stored credential, or a password on a command line, in a file or
in an environment variable; timeouts that kill a tool; changes to the existing `Run-*.bat` files.

## 8. Phase 3 - decision: option A (owner, 2026-11-15)

`pull-remote-logs` reads the password with `Read-Host -AsSecureString`, which hangs under redirected
stdin (spike S2). The owner chose **option A**. Options B (visible console for the pull) and C (keep the
pull in the .bat) were not taken.

What was implemented:

- `pull-remote-logs.v2026-11-15.1.ps1` (additive; interactive use unchanged):
  - `-NoFullDump` switch: answers the full-dump question with No without asking.
  - Under `[Console]::IsInputRedirected`: prints `Username: ` and `Password: ` with `Write-Host -NoNewline`,
    and reads the password with `[Console]::In.ReadLine()` into a SecureString (spike S2b: works, blank
    works, no echo).
  - Skips the closing "Press Enter" wait and the automatic Explorer window under redirected input.
- `enable-remote-diag.v2026-11-15.1.ps1`: skips its two closing "Press Enter" waits under redirected input.
- `revert-remote-diag.ps1`: unchanged (no prompts).
- Window:
  - A password box. The password goes to the script's input only (`Send-GuiSecret`). It is never shown,
    logged, stored, or put on a command line, in a file or in an environment variable. The box is cleared
    after sending.
  - "Enable remote diagnostics" (changes the PC; auto-reverts after 48 h) and a separate "Revert
    remote diagnostics now" card (runs `revert-remote-diag.ps1`).
  - "Switch printer WSD -> TCP/IP": a printer drop-down, IP, optional new name, RemoveStale / TestPage /
    DryRun. The script's y/N questions show as Yes / No boxes (X = No).
  - Every tool that changes the PC asks for confirmation before it runs. The window refuses to close
    while a tool that changes the PC runs.

Known risk: the password exists as a plain .NET string for a short time in both processes (the password
box read and the stdin line). It is never on a command line, in a file or in an environment variable.

## 9. Tests (`tests\gui\`)

| Test | What it proves |
|---|---|
| `Test-GuiCallParity.ps1` | every offered tool: the REAL launcher (copied next to stub scripts) and the window's core make the same call, after removing the two declared differences (`-NoFullDump`, `-StopFile`); the newest dated script wins in both; plain-name fallback |
| `Test-GuiPromptContract.ps1` | every argument is a parameter of the script; every line the window reads is still printed; every `Read-Host` is answered or listed as never reached |
| `Test-GuiPromptHandling.ps1` | real child processes on own / 437 / 65001: `-NoNewline` prompt seen, y/N default on X, unknown-prompt box only after 5 s, quiet complete lines never, a secret never logged. `-Real` also runs the real `pull-local-logs` end to end |
| `Test-GuiResultReaders.ps1` | REVIEW readers and run results on complete, empty, truncated and missing fixtures; input validation |
| `Test-GuiHouseRules.ps1` | parse, ASCII, no BOM, CRLF; core has no WPF types; the launcher's preamble |
| `Test-GuiWindow.ps1` | XAML loads with every named control; self-test in light and dark; start screen at 910x480 (compact) and 1120x760; a stub tool end to end through the real window; test hooks only when not elevated |

**Only the owner can test, on a real PC:** the UAC relaunch of `Run-RemoteDiagGui.bat` (one prompt)
and the window opening elevated (S4); each read-only tool once from the window on a client PC
(persistence and ESP elevated, the print watch with Stop and save); a 125% and a 150% scaled laptop;
Windows 10; a PC set to "UTF-8 for worldwide language support"; a Hebrew-locale PC elevated; and:

- Enable remote diagnostics on a test PC, then run a remote pull from another PC with a blank-password
  account, and again with a password.
- Revert remote diagnostics now.
- Switch a printer on a real WSD queue. Try DryRun first.

## 10. Final review (2026-11-15)

All six suites pass on Windows PowerShell 5.1: house rules 58, prompt contract 136, result readers 29,
call parity 62, prompt handling 39 (13 each on own / 437 / 65001), window 47: **379 checks**.
A separate real remote-pull check against a nonexistent host passed 14 checks with a password and a
blank password: prompts answered, clean unreachable-host failure, secret absent from output and transcript.
UAC/elevated WPF, real client actions and the platform/scaling matrix in section 9 remain untested.
Run Test-GuiWindow from a non-elevated shell; it exits 2 when elevated because test hooks are disabled.

Review fixes:

- Catalog Warnings patterns read the pull scripts' failed-step lines. WarningText explains the amber
  incomplete-output banner; a zero exit code no longer hides a failed collection step.
- Catalog Cancel recognises the printer script's explicit cancellation. A real Failure still wins.
- Test-GuiTextEncodable verifies username and password survive the console input encoding before a
  child starts; unsupported characters are refused without displaying the secret. Use the console launcher.
- Closing dialogs set InDialog so the timer cannot answer another prompt behind the dialog.
- Test windows close when validation or confirmation prevents a child from starting.
