@echo off
rem Self-elevating launcher; runs the newest Check-CameraAndStartup.v*.ps1 next to it.
net session >nul 2>&1
if %errorlevel% neq 0 (
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)
set "TARGET="
for /f "delims=" %%F in ('dir /b /o-n "%~dp0Check-CameraAndStartup.v*.ps1" 2^>nul') do (
    if not defined TARGET set "TARGET=%~dp0%%F"
)
if not defined TARGET if exist "%~dp0Check-CameraAndStartup.ps1" set "TARGET=%~dp0Check-CameraAndStartup.ps1"
if not defined TARGET (
    echo Check-CameraAndStartup script not found next to this launcher.
    pause
    exit /b 1
)
echo.
echo   R = report only (changes nothing)
echo   F = report + offer camera fixes one by one (asks y/N each)
echo   A = report + fixes + DISM/sfc repair (slow)
echo.
choice /c RFA /n /m "Choose R, F or A: "
set "ARGS="
if errorlevel 3 (set "ARGS=-Fix -Repair") else if errorlevel 2 (set "ARGS=-Fix")
powershell -NoProfile -ExecutionPolicy Bypass -File "%TARGET%" %ARGS%
echo.
echo Done. Report saved on the Desktop.
pause
