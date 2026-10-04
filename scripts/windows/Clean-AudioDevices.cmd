@echo off
setlocal enabledelayedexpansion
cd /d "%~dp0"
title Audio devices - clean the Sound settings list
color 0B

REM ============================================================
REM  Clean-AudioDevices.cmd - the front door for Clean-AudioDevices.ps1,
REM  which must sit next to this file.
REM
REM  TWO WAYS IN.
REM   - With arguments it is a plain launcher and forwards them
REM     unchanged, so everything README.md documents still works:
REM         Clean-AudioDevices.cmd -ListOnly
REM         Clean-AudioDevices.cmd -Clean -WhatIf
REM         Clean-AudioDevices.cmd -Clean -KeepExposedPorts
REM   - With NO arguments it asks what to do, shows a summary, and
REM     waits for confirmation before anything happens.
REM
REM  Style note, inherited from Clean-StartupApps.cmd: every read of a
REM  variable set earlier uses !VAR!, and the control flow is kept
REM  flat with labels instead of nested ( ) blocks. %VAR% is
REM  substituted when a block is PARSED, before the block has run,
REM  which silently drops values assigned inside the same block.
REM
REM  Two traps around "choice", both silent:
REM   - "if errorlevel N" means N OR HIGHER, so the tests must run in
REM     DESCENDING order.
REM   - a successful "set" resets ERRORLEVEL to 0, so the branching
REM     has to happen BEFORE the first assignment.
REM
REM  Elevation. The census needs none, so option 1 runs here. Every
REM  other option changes keys only SYSTEM and the audio services may
REM  normally touch, so it always runs elevated, in a new window that
REM  stays open when it finishes.
REM ============================================================

set "SCRIPT=%~dp0Clean-AudioDevices.ps1"
if not exist "%SCRIPT%" (
    echo Cannot find "%SCRIPT%" - keep this launcher next to the script.
    pause
    exit /b 1
)

set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"

REM  The elevated run passes paths to PowerShell as single-quoted strings,
REM  where an apostrophe (C:\Users\O'Brien\...) would end the string early.
REM  These copies have every apostrophe doubled, PowerShell's own escape.
set "SCRIPTQ=!SCRIPT:'=''!"

REM  Arguments given: behave as a plain launcher.
if not "%~1"=="" goto passthrough


:menu
cls
echo ============================================================
echo   AUDIO DEVICES - CLEAN THE SOUND SETTINGS LIST
echo ============================================================
echo.
echo   Settings ^> Sound ^> All sound devices lists every audio endpoint
echo   Windows ever built. This removes the ones whose hardware or
echo   driver is gone, and never touches a device that is connected,
echo   unplugged or disabled by you.
echo.
echo ------------------------------------------------------------
echo  What would you like to do?
echo ------------------------------------------------------------
echo   [1] Census only - list every endpoint and what it is, change
echo       nothing. The safe first run. Needs no elevation.
echo   [2] Clean - remove every not-present endpoint the rules select,
echo       its ghost devnode, and dead per-app audio settings.
echo       Everything is backed up first.
echo   [3] Clean, but keep the ports your current drivers still expose
echo       (Windows would only rebuild those under a new id).
echo   [4] Restore from a backup manifest - undo an earlier clean.
echo.
REM  Branch BEFORE any assignment, and test descending. Option 1 is the
REM  fall-through, so it is the only one that may assign here.
choice /C 1234 /N /M "Select [1-4]: "
if errorlevel 4 goto act_restore
if errorlevel 3 goto act_keep
if errorlevel 2 goto act_clean
set "PSARGS=-ListOnly"
set "PSLIST=,'-ListOnly'"
set "S_ACTION=Census only - nothing will be changed"
set "S_APPS=not applicable"
set "S_PREVIEW=not applicable"
set "S_ELEVATE=no - runs in this window"
set "CHANGES=0"
goto summary

:act_clean
set "PSARGS=-Clean"
set "PSLIST=,'-Clean'"
set "S_ACTION=Clean - remove every selected endpoint"
goto opt_apps

:act_keep
set "PSARGS=-Clean -KeepExposedPorts"
set "PSLIST=,'-Clean','-KeepExposedPorts'"
set "S_ACTION=Clean - keep the ports the drivers still expose"
goto opt_apps

:act_restore
echo.
echo ------------------------------------------------------------
echo  Restore from a backup
echo ------------------------------------------------------------
echo   Every clean printed the path of the manifest it wrote. Paste it
echo   here. Backups live in your TEMP folder, in folders named
echo   AudioDevices_yyyyMMdd_HHmmss, each holding a manifest.json
set /p "MANIFEST=Manifest file: "
REM  "Copy as path" always quotes; the quotes would survive into the
REM  argument and the script would find no such file.
if defined MANIFEST set MANIFEST=!MANIFEST:"=!
if not defined MANIFEST goto menu
set "MANIFESTQ=!MANIFEST:'=''!"
set "PSARGS=-Restore "!MANIFEST!""
set "PSLIST=,'-Restore','!MANIFESTQ!'"
set "S_ACTION=Restore from !MANIFEST!"
set "S_APPS=not applicable"
set "S_PREVIEW=not applicable"
goto elevated


:opt_apps
echo.
echo ------------------------------------------------------------
echo  Per-app audio settings
echo ------------------------------------------------------------
echo   Windows remembers each app's volume and chosen device per
echo   audio device. Entries for built-in hardware that is gone are
echo   invisible clutter. USB and Bluetooth entries are always kept.
choice /C YN /N /M "Remove the dead per-app settings too?  [Y/N]: "
if errorlevel 2 goto apps_no
set "S_APPS=YES - dead entries are removed"
goto opt_preview
:apps_no
set "PSARGS=!PSARGS! -SkipAppSettings"
set "PSLIST=!PSLIST!,'-SkipAppSettings'"
set "S_APPS=no - left alone"

:opt_preview
echo.
echo ------------------------------------------------------------
echo  Preview first
echo ------------------------------------------------------------
echo   A preview prints the exact plan - every endpoint, devnode and
echo   setting it would remove - then stops without changing anything.
choice /C YN /N /M "Preview only, change nothing?  [Y/N]: "
if errorlevel 2 goto preview_no
set "PSARGS=!PSARGS! -WhatIf"
set "PSLIST=!PSLIST!,'-WhatIf'"
set "S_PREVIEW=YES - nothing will be changed"
goto elevated
:preview_no
set "S_PREVIEW=no - changes will be applied"

:elevated
set "S_ELEVATE=YES - a UAC prompt appears, and it runs in a new window"
set "CHANGES=1"


:summary
cls
echo ============================================================
echo   SUMMARY
echo ============================================================
echo   Action ....................... !S_ACTION!
echo   Per-app settings ............. !S_APPS!
echo   Preview only ................. !S_PREVIEW!
echo   Elevated ..................... !S_ELEVATE!
echo.
echo   Command ...................... Clean-AudioDevices.ps1 !PSARGS!
echo ============================================================
echo.
choice /C YN /N /M "Does this look right? Y to run, N to choose again  [Y/N]: "
if errorlevel 2 goto menu

echo.
if "!CHANGES!"=="1" goto run_elevated

echo ============================================================
echo  Running
echo ============================================================
echo.
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" !PSARGS!
set "RC=!ERRORLEVEL!"
goto done

:run_elevated
echo ============================================================
echo  Running elevated - answer the UAC prompt
echo ============================================================
echo.
echo The elevated window stays open when it finishes, because its
echo output is not shared with this one.
REM  Each argument is its own single-quoted list element, so a manifest
REM  path containing spaces survives. -NoExit keeps the new window up;
REM  without it the results would flash past and be readable only in
REM  the transcript.
"%PS%" -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-NoExit','-File','!SCRIPTQ!'!PSLIST!)"
set "RC=!ERRORLEVEL!"

:done
echo.
echo ============================================================
echo  Finished. Exit code !RC!
echo ============================================================
pause
exit /b !RC!


:passthrough
REM  Arguments were given, so this is the plain launcher: forward them
REM  unchanged and return the script's exit code.
REM
REM  It cannot know whether there is a console to return to. Started
REM  from Explorer it pauses so the output can be read; started from a
REM  prompt it returns the exit code without pausing.
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*
set "RC=%ERRORLEVEL%"

REM  CMDCMDLINE is a DYNAMIC variable: cmd synthesises it rather than
REM  keeping it in the environment block, so the substring transform
REM  !cmdcmdline:/c=! returns the value UNMODIFIED and the comparison is
REM  always equal. Copy it into a real variable first, which the
REM  transform does apply to. Delayed expansion is still used for the
REM  comparison so an "&" or a quote in the launch path cannot be parsed
REM  as a command.
set "LAUNCHLINE=%cmdcmdline%"
if not "!LAUNCHLINE:/c=!"=="!LAUNCHLINE!" pause

exit /b %RC%
