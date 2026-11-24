@echo off
rem ============================================================================
rem  Run-RemoteDiagGui.bat - the Remote Diagnostics WINDOW (docs\gui-architecture.md).
rem  One window to run the tools in this folder: pick a tool, set its options,
rem  Run, watch the live output, then open the output folder / zip.
rem  The window runs the SAME scripts the other Run-*.bat files run, with the same
rem  arguments, one at a time. Those Run-*.bat files are unchanged and remain the
rem  fallback.
rem
rem  Asks for administrator rights ONCE (never loops the prompt), then starts the
rem  newest gui\Start-RemoteDiagGui.v*.ps1 with -STA (WPF needs it). This console
rem  stays open behind the window on purpose: if the window cannot load, the error
rem  is readable here. Do not add -NonInteractive anywhere: it makes Read-Host
rem  throw in the tool scripts.
rem  Preamble copied from screenconnect-cleanup\START-HERE-GUI.bat (no battery or
rem  keep-awake step here). Pure ASCII, no BOM, CRLF.
rem ============================================================================

rem ---- Capture our own path/args BEFORE enabling delayed expansion --------
rem A folder name such as "remote-diagnostics (1)" breaks cmd because %~dp0 / %~f0
rem expand at PARSE time and the ( ) inside a ( ... ) block end it early.
rem Delayed expansion (!VAR!) is substituted at RUN time.
set "RDG_DP0=%~dp0"
set "RDG_F0=%~f0"
set "RDG_ARGS=%*"
setlocal EnableDelayedExpansion
title Remote Diagnostics (window)

set "RDG_ELEV_ATTEMPTED=0"
for %%A in (!RDG_ARGS!) do (
    if /i "%%~A"=="--elevation-attempted" set "RDG_ELEV_ATTEMPTED=1"
)

rem ---- Self-elevate: at most ONE UAC prompt, decided by the real admin token ---
rem The path travels via RDG_SELF so quotes in it cannot break the command line,
rem and --elevation-attempted stops a second prompt.
set "RDG_SELF=!RDG_F0!"
powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "if(([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){exit 0}else{exit 1}"
if errorlevel 1 (
    if "!RDG_ELEV_ATTEMPTED!"=="1" (
        echo.
        echo  [ERROR] This window is still not elevated after the UAC request, so
        echo          it will not ask again. Right-click Run-RemoteDiagGui.bat and
        echo          choose "Run as administrator", or use the other Run-*.bat files.
        pause
        exit /b 1
    )
    echo  Requesting administrator privileges...
    powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath ([Environment]::GetEnvironmentVariable('RDG_SELF')) -ArgumentList '--elevation-attempted' -Verb RunAs"
    if errorlevel 1 (
        echo.
        echo  [ERROR] Elevation could not be launched or was cancelled.
        echo          Re-run this file from an elevated command prompt.
        pause
        exit /b 1
    )
    exit /b
)
set "RDG_SELF="

rem ---- Newest gui\Start-RemoteDiagGui.v*.ps1 (dir /o-n = newest dated name first) ----
set "RDG_TARGET="
for /f "delims=" %%F in ('dir /b /o-n "!RDG_DP0!gui\Start-RemoteDiagGui.v*.ps1" 2^>nul') do (
    if not defined RDG_TARGET set "RDG_TARGET=!RDG_DP0!gui\%%F"
)
if not defined RDG_TARGET if exist "!RDG_DP0!gui\Start-RemoteDiagGui.ps1" set "RDG_TARGET=!RDG_DP0!gui\Start-RemoteDiagGui.ps1"
if not defined RDG_TARGET (
    echo [ERROR] gui\Start-RemoteDiagGui.v*.ps1 is missing next to this file.
    echo         Use the other Run-*.bat files instead.
    pause
    exit /b 1
)

rem pushd (not cd) so this also works from a UNC path.
pushd "!RDG_DP0!"
echo.
echo  Remote Diagnostics - opening the window. Leave this console open.
echo.
powershell -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File "!RDG_TARGET!"
set "RDG_RC=!errorlevel!"
popd
if not "!RDG_RC!"=="0" (
    echo.
    echo  [ERROR] The window ended with an error ^(exit !RDG_RC!^). Read the message above.
    echo          The other Run-*.bat files still work as before.
    pause
)
exit /b !RDG_RC!
