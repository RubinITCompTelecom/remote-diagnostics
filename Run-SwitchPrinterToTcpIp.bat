@echo off
rem Launcher: runs the newest Switch-PrinterToTcpIp.v*.ps1 next to this file.
rem Arguments pass through, e.g.: Run-SwitchPrinterToTcpIp.bat -IpAddress 192.168.0.50 -DryRun
set "TARGET="
for /f "delims=" %%F in ('dir /b /o-n "%~dp0Switch-PrinterToTcpIp.v*.ps1" 2^>nul') do (
    if not defined TARGET set "TARGET=%~dp0%%F"
)
if not defined TARGET (
    echo Switch-PrinterToTcpIp.v*.ps1 not found next to this file.
    pause
    exit /b 1
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%TARGET%" %*
pause
