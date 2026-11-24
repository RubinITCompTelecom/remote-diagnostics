@echo off
rem Launcher for Check-EspUsage.v*.ps1 - picks the newest dated copy next to this file.
rem The script self-elevates (it opens a second, administrator window with the report) and is
rem read-only: it mounts the ESP on a spare drive letter and unmounts it on exit.
rem Keep this folder somewhere every account can read (e.g. C:\RemoteDiag), not a user's
rem Downloads/Desktop - the elevated window runs as a different account.
setlocal
set "TARGET="
for /f "delims=" %%F in ('dir /b /o-n "%~dp0Check-EspUsage.v*.ps1" 2^>nul') do (
    if not defined TARGET set "TARGET=%~dp0%%F"
)
if not defined TARGET if exist "%~dp0Check-EspUsage.ps1" set "TARGET=%~dp0Check-EspUsage.ps1"
if not defined TARGET (
    echo Check-EspUsage script not found next to this launcher.
    pause
    exit /b 1
)
rem pushd (not cd) so this also works when launched from a UNC path.
pushd "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%TARGET%" %*
set RC=%errorlevel%
popd

rem ALWAYS pause so this window can never vanish before the output (or the reason it failed) is read.
echo.
echo ----------------------------------------------------------------
echo Launcher finished. Script run: %TARGET%
echo PowerShell exit code: %RC%
echo If an administrator window opened, the report is in that window and on the Desktop.
echo ----------------------------------------------------------------
pause
