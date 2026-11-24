@echo off
setlocal enabledelayedexpansion

:: ============================================================================
:: Pull-BootFailureLogs.bat
::
:: Run from a Command Prompt in WinRE/WinPE on a machine that WON'T boot
:: normally (Advanced Startup -> Troubleshoot -> Command Prompt on the
:: machine's own recovery, or a bootable WinPE USB). Pure CMD/batch, no
:: PowerShell needed, so it works on minimal PE images.
::
:: Gathers every log that actually mattered in real boot-failure cases:
:: Startup Repair (SRT) logs, the boot log, CBS/DISM log,
:: Windows Setup logs, offline event logs, BCD, disk layout -- into one
:: timestamped folder on the PE drive itself. Also turns boot logging ON for
:: the next boot attempt, since ntbtlog.txt (which log had loaded
:: successfully) is what actually solved case 3 -- if it doesn't exist yet,
:: this script can't create it retroactively, only make sure it exists after
:: the NEXT attempt.
:: ============================================================================

:: --- CONFIG: the drive letter your bootable PE USB always mounts as ---------
:: Change this one line if your PE stick uses a different letter. Everything
:: this script collects goes here, and this letter is also EXCLUDED when
:: hunting for the broken Windows install below, so the two can never be
:: confused for each other even if they end up numerically close.
set PE_DRIVE=P
:: ------------------------------------------------------------------------

echo ============================================
echo   Boot-Failure Log Collector (WinPE/WinRE)
echo ============================================
echo   PE drive (this script's home, logs go here): %PE_DRIVE%:
echo.

:: --- Find the broken OS's drive letter ---
:: Scans C: through N:, skipping %PE_DRIVE% on purpose -- PE media (whether
:: it's this USB or the machine's own recovery ramdisk) has its own Windows
:: folder structure too, so "does \Windows\System32\config\SYSTEM exist" on
:: its own isn't enough to tell PE apart from the real broken install. Naming
:: the PE drive explicitly and skipping it is what actually does that.
set OSDRIVE=
for %%D in (C D E F G H I J K L M N) do (
    if /i not "%%D"=="%PE_DRIVE%" (
        if exist %%D:\Windows\System32\config\SYSTEM (
            if not defined OSDRIVE set OSDRIVE=%%D
        )
    )
)

if not defined OSDRIVE (
    echo Could not auto-detect a Windows install ^(checked C: through N:, skipping %PE_DRIVE%:^).
    set /p OSDRIVE=Type just the drive letter of the broken OS, like C, then press Enter:
)

echo Using OS drive ^(the broken install^): %OSDRIVE%:
echo.

:: --- Output folder, timestamped, always on the PE drive regardless of where
::     this script itself was launched from ---
for /f "tokens=2 delims==" %%I in ('wmic os get localdatetime /value 2^>nul ^| find "="') do set DT=%%I
if not defined DT (
    set STAMP=run
) else (
    set STAMP=%DT:~0,8%_%DT:~8,6%
)
set OUT=%PE_DRIVE%:\BootFailureLogs_%STAMP%
mkdir "%OUT%" 2>nul
set STATUS=%OUT%\CollectionStatus.txt
echo Boot-Failure Log Collection > "%STATUS%"
echo PE drive: %PE_DRIVE%: >> "%STATUS%"
echo OS drive detected as: %OSDRIVE%: >> "%STATUS%"
echo Collected: %DATE% %TIME% >> "%STATUS%"
echo. >> "%STATUS%"

echo Output folder: %OUT%
echo.

:: --- 1. Startup Repair (SRT) logs -- the single most useful folder in real cases ---
echo [1/8] Startup Repair (SRT) logs...
if exist "%OSDRIVE%:\Windows\System32\LogFiles\Srt" (
    robocopy "%OSDRIVE%:\Windows\System32\LogFiles\Srt" "%OUT%\Srt" /E /R:1 /W:1 >nul 2>&1
    echo [OK]   Srt folder copied >> "%STATUS%"
) else (
    echo [MISS] Srt folder not found -- no automatic Startup Repair has run yet >> "%STATUS%"
)

:: --- 2. Boot log: copy if it exists, and turn boot logging ON for next attempt either way ---
echo [2/8] Boot log (ntbtlog.txt)...
if exist "%OSDRIVE%:\Windows\ntbtlog.txt" (
    copy /y "%OSDRIVE%:\Windows\ntbtlog.txt" "%OUT%\ntbtlog.txt" >nul 2>&1
    echo [OK]   ntbtlog.txt copied ^(boot logging was already on^) >> "%STATUS%"
) else (
    echo [MISS] ntbtlog.txt not found -- boot logging wasn't on for the failures so far >> "%STATUS%"
)
bcdedit /set {default} bootlog yes >nul 2>&1
if !errorlevel! equ 0 (
    echo [OK]   Boot logging turned ON for the NEXT boot attempt >> "%STATUS%"
    echo        --^> If it still won't boot: boot it, come back into this same PE, >> "%STATUS%"
    echo        --^> and re-run this script to pick up the new ntbtlog.txt. >> "%STATUS%"
) else (
    echo [FAIL] Could not set bootlog via 'bcdedit /set {default}' -- if this is a USB PE >> "%STATUS%"
    echo        pointed at an external drive rather than the machine's own recovery, try: >> "%STATUS%"
    echo        bcdedit /store %OSDRIVE%:\boot\BCD /set {default} bootlog yes >> "%STATUS%"
)

:: --- 3. CBS.log (main servicing log -- separate from the SRT-specific DISM repair logs) ---
echo [3/8] CBS.log...
if exist "%OSDRIVE%:\Windows\Logs\CBS\CBS.log" (
    copy /y "%OSDRIVE%:\Windows\Logs\CBS\CBS.log" "%OUT%\CBS.log" >nul 2>&1
    echo [OK]   CBS.log copied ^(can be large -- grep for "Error" / your HRESULT^) >> "%STATUS%"
) else (
    echo [MISS] CBS.log not found >> "%STATUS%"
)

:: --- 4. Windows Setup / in-place-upgrade logs (Panther) ---
echo [4/8] Windows Setup (Panther) logs...
if exist "%OSDRIVE%:\Windows\Panther" (
    robocopy "%OSDRIVE%:\Windows\Panther" "%OUT%\Panther" *.log *.xml /E /R:1 /W:1 >nul 2>&1
    echo [OK]   Windows\Panther copied >> "%STATUS%"
) else (
    echo [MISS] Windows\Panther not found >> "%STATUS%"
)
if exist "%OSDRIVE%:\$WINDOWS.~BT\Sources\Panther" (
    robocopy "%OSDRIVE%:\$WINDOWS.~BT\Sources\Panther" "%OUT%\Panther_InPlaceUpgrade" *.log *.xml /E /R:1 /W:1 >nul 2>&1
    echo [OK]   In-place-upgrade Panther logs copied ^(a failed/in-progress upgrade was present^) >> "%STATUS%"
) else (
    echo [MISS] No in-place-upgrade Panther folder ^(none was in progress, or already cleaned up^) >> "%STATUS%"
)

:: --- 5. Offline event logs (raw .evtx -- open in Event Viewer or analyze on another machine) ---
echo [5/8] Offline event logs...
mkdir "%OUT%\EventLogs" 2>nul
if exist "%OSDRIVE%:\Windows\System32\winevt\Logs\System.evtx" (
    copy /y "%OSDRIVE%:\Windows\System32\winevt\Logs\System.evtx" "%OUT%\EventLogs\System.evtx" >nul 2>&1
    echo [OK]   System.evtx copied >> "%STATUS%"
) else (
    echo [MISS] System.evtx not found >> "%STATUS%"
)
if exist "%OSDRIVE%:\Windows\System32\winevt\Logs\Application.evtx" (
    copy /y "%OSDRIVE%:\Windows\System32\winevt\Logs\Application.evtx" "%OUT%\EventLogs\Application.evtx" >nul 2>&1
    echo [OK]   Application.evtx copied >> "%STATUS%"
) else (
    echo [MISS] Application.evtx not found >> "%STATUS%"
)

:: --- 6. BCD dump ---
echo [6/8] Boot Configuration Data...
bcdedit /enum all > "%OUT%\bcdinfo.txt" 2>&1
echo [OK]   bcdedit /enum all captured >> "%STATUS%"

:: --- 7. Disk / partition layout ---
echo [7/8] Disk layout...
(
    echo list disk
    echo list volume
    echo list partition
    echo exit
) > "%TEMP%\diskpart_script.txt"
diskpart /s "%TEMP%\diskpart_script.txt" > "%OUT%\disklayout.txt" 2>&1
del "%TEMP%\diskpart_script.txt" >nul 2>&1
echo [OK]   diskpart layout captured >> "%STATUS%"

:: --- 8. Basic drive health (best-effort -- wmic is deprecated/absent on some newer PE images) ---
echo [8/8] Drive health (best-effort)...
wmic diskdrive get model,serialnumber,status,size > "%OUT%\drive_health.txt" 2>nul
if exist "%OUT%\drive_health.txt" (
    echo [OK]   wmic drive health captured -- Status should say "OK" >> "%STATUS%"
) else (
    echo [MISS] wmic not available on this PE image -- skipped >> "%STATUS%"
)

echo.
echo ============================================
echo   Done. Everything is in:
echo   %OUT%
echo ============================================
echo.
echo Read CollectionStatus.txt first -- it says what was found vs. missing.
echo If boot logging was just turned on and ntbtlog.txt was missing, try
echo booting the machine again, then come back and re-run this script.
echo.
pause
