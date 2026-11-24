@echo off
REM Double-click launcher for pull-local-logs.ps1.
REM Must sit in the SAME FOLDER as pull-local-logs.ps1.
REM Run this ON the target machine itself - no admin, no credentials, no
REM network access needed at all. Use this when pull-remote-logs.ps1 can't
REM reach the target (no password on the account, WinRM not set up, no
REM network path from your machine) - just bypasses the execution policy for
REM this run so double-clicking actually executes it instead of opening it
REM in Notepad.
REM
REM Optional: pass the look-back window from a command prompt, e.g.  Run-PullLocalLogs.bat -Hours 168
REM (default 72 hours; the maximum is 168 = one week). Double-clicking just asks.
REM
REM Picks the newest pull-local-logs.v<date>.<N>.ps1 next to it (dir /o-n
REM sorts date-stamped versions correctly as plain text), falling back to
REM the older un-versioned pull-local-logs.ps1 if no versioned copy is
REM present yet - so this keeps working through the transition either way.

set "TARGET="
for /f "delims=" %%F in ('dir /b /o-n "%~dp0pull-local-logs.v*.ps1" 2^>nul') do (
    if not defined TARGET set "TARGET=%~dp0%%F"
)
if not defined TARGET if exist "%~dp0pull-local-logs.ps1" set "TARGET=%~dp0pull-local-logs.ps1"

if not defined TARGET (
    echo Could not find pull-local-logs.v*.ps1 or pull-local-logs.ps1 in this folder:
    echo   %~dp0
    pause
    exit /b 1
)

REM pushd (not cd) so this also works when launched from a UNC path - it maps a
REM temporary drive letter instead of failing with "UNC paths are not supported".
pushd "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%TARGET%" %*
set RC=%errorlevel%
popd

REM ALWAYS pause, success or failure, so the window can never vanish before the
REM output (or the reason it failed) can be read.
echo.
echo ----------------------------------------------------------------
echo Launcher finished. Script run: %TARGET%
echo PowerShell exit code: %RC%
if %RC% neq 0 echo That is not 0 - scroll up for the error text.
echo ----------------------------------------------------------------
pause
