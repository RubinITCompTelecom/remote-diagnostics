@echo off
rem Launcher for Check-WakeDevices.v*.ps1 - picks the newest dated copy next to this file.
rem Why do devices stop working after sleep / hibernate? READ-ONLY report; self-elevates (the
rem report then runs in a second, administrator window) and asks whether to do a live sleep test.
rem Options pass straight through, e.g.:  Run-CheckWakeDevices.bat -SleepTest -Days 30
rem Keep this folder somewhere every account can read (e.g. C:\RemoteDiag), not a user's
rem Downloads/Desktop - the elevated window may run as a different account.
setlocal
set "TARGET="
for /f "delims=" %%F in ('dir /b /o-n "%~dp0Check-WakeDevices.v*.ps1" 2^>nul') do (
    if not defined TARGET set "TARGET=%~dp0%%F"
)
if not defined TARGET if exist "%~dp0Check-WakeDevices.ps1" set "TARGET=%~dp0Check-WakeDevices.ps1"
if not defined TARGET (
    echo Check-WakeDevices script not found next to this launcher.
    pause
    exit /b 1
)
rem pushd (not cd) so this also works when launched from a UNC path.
pushd "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%TARGET%" %*
set RC=%errorlevel%
popd

echo.
echo ----------------------------------------------------------------
echo Launcher finished. Script run: %TARGET%
echo PowerShell exit code: %RC%
echo If an administrator window opened, the report is in that window and in a
echo WakeDeviceCheck_... folder on the Desktop.
echo ----------------------------------------------------------------
pause
