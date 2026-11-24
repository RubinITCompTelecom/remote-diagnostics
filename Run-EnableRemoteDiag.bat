@echo off
REM Double-click launcher for enable-remote-diag.ps1.
REM Must sit in the SAME FOLDER as enable-remote-diag.ps1.
REM Self-elevates (this script needs admin), then runs the .ps1 with the
REM execution policy bypassed for just this one run - no permanent change
REM to the machine's PowerShell settings, no admin action needed to set it
REM up. Only fails if execution policy is locked by Group Policy, which
REM no per-machine trick can get around.
REM
REM Picks the newest enable-remote-diag.v<date>.<N>.ps1 next to it (dir /o-n
REM sorts date-stamped versions correctly as plain text), falling back to
REM the older un-versioned enable-remote-diag.ps1 if no versioned copy is
REM present yet - so this keeps working through the transition either way.

set "TARGET="
for /f "delims=" %%F in ('dir /b /o-n "%~dp0enable-remote-diag.v*.ps1" 2^>nul') do (
    if not defined TARGET set "TARGET=%~dp0%%F"
)
if not defined TARGET if exist "%~dp0enable-remote-diag.ps1" set "TARGET=%~dp0enable-remote-diag.ps1"

if not defined TARGET (
    echo Could not find enable-remote-diag.v*.ps1 or enable-remote-diag.ps1 in this folder:
    echo   %~dp0
    pause
    exit /b 1
)

net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting administrator privileges...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

REM pushd (not cd) so this also works when launched from a UNC path - it maps a
REM temporary drive letter instead of failing with "UNC paths are not supported".
pushd "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%TARGET%"
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
