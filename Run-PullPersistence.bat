@echo off
rem Launcher for pull-persistence.v*.ps1 - picks the newest dated version next to this file.
rem Read-only. Double-click on the target PC (right-click > Run as administrator for full coverage).
pushd "%~dp0"
set "TARGET="
for /f "delims=" %%F in ('dir /b /o-n "%~dp0pull-persistence.v*.ps1" 2^>nul') do (
    if not defined TARGET set "TARGET=%~dp0%%F"
)
if not defined TARGET if exist "%~dp0pull-persistence.ps1" set "TARGET=%~dp0pull-persistence.ps1"
if not defined TARGET (
    echo No pull-persistence script found next to this launcher.
    goto :done
)
echo Running %TARGET%
powershell -NoProfile -ExecutionPolicy Bypass -File "%TARGET%"
echo.
echo Exit code: %ERRORLEVEL%
:done
popd
pause
