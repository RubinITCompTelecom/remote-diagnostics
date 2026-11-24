@echo off
rem Launcher: runs the newest Watch-PrintFreeze.v*.ps1 next to this file. Extra arguments (-Minutes 180) pass through.
set "TARGET="
for /f "delims=" %%F in ('dir /b /o-n "%~dp0Watch-PrintFreeze.v*.ps1" 2^>nul') do (
    if not defined TARGET set "TARGET=%~dp0%%F"
)
if not defined TARGET (
    echo Watch-PrintFreeze.v*.ps1 not found next to this file.
    pause
    exit /b 1
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%TARGET%" %*
pause
