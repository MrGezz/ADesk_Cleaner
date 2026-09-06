@echo off
setlocal enabledelayedexpansion
cd /d "%~dp0"
title Startup Apps - audit and clean
color 0B

REM ============================================================
REM  Clean-StartupApps.cmd - the front door for Clean-StartupApps.ps1,
REM  which must sit next to this file.
REM
REM  TWO WAYS IN.
REM   - With arguments it is a plain launcher and forwards them
REM     unchanged, so everything README.md documents still works:
REM         Clean-StartupApps.cmd -ListOnly
REM         Clean-StartupApps.cmd -Disable Discord,jusched
REM         Clean-StartupApps.cmd -RemoveOptional -WhatIf
REM   - With NO arguments it asks what to do, shows a summary, and
REM     waits for confirmation before anything happens.
REM
REM  Style note, inherited from run_pipeline.cmd: every read of a
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
REM  Elevation. This script does NOT self-elevate, because the useful
REM  half of its work is per-user: the HKCU Run key, your own Startup
REM  folder and the packaged app startup tasks are all yours to
REM  change. Only the machine-wide surfaces - the HKLM Run keys, the
REM  all-users Startup folder and scheduled tasks - need administrator
REM  rights, so the menu offers elevation rather than forcing it.
REM ============================================================

set "SCRIPT=%~dp0Clean-StartupApps.ps1"
if not exist "%SCRIPT%" (
    echo Cannot find "%SCRIPT%" - keep this launcher next to the script.
    pause
    exit /b 1
)

set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"

REM  Arguments given: behave exactly as the plain launcher did.
if not "%~1"=="" goto passthrough


:menu
cls
echo ============================================================
echo   STARTUP APPS - AUDIT AND CLEAN
echo ============================================================
echo.
echo   Everything that launches itself when you sign in, across all
echo   four mechanisms Task Manager flattens into one list, with what
echo   each entry actually is and what turning it off costs you.
echo.
echo ------------------------------------------------------------
echo  What would you like to do?
echo ------------------------------------------------------------
echo   [1] Census only - list everything, change nothing
echo       The safe first run. Needs no elevation.
echo   [2] Disable entries I name - they stay in the list, greyed out
echo   [3] Disable every OPTIONAL entry - launchers, updaters, tray
echo       icons. KEEP and REVIEW entries are never touched.
echo   [4] REMOVE every OPTIONAL entry - deletes the value or the
echo       shortcut so the row disappears. Reversible from the backup.
echo   [5] Remove ORPHAN entries - startup rows whose target program
echo       is already uninstalled.
echo   [6] Restore from a backup file - undo an earlier run.
echo.
REM  Branch BEFORE any assignment, and test descending. Option 1 is the
REM  fall-through, so it is the only one that may assign here.
choice /C 123456 /N /M "Select [1-6]: "
if errorlevel 6 goto act_restore
if errorlevel 5 goto act_orphans
if errorlevel 4 goto act_removeopt
if errorlevel 3 goto act_disableopt
if errorlevel 2 goto act_names
set "PSARGS=-ListOnly"
set "PSLIST=,'-ListOnly'"
set "S_ACTION=Census only - nothing will be changed"
set "CHANGES=0"
goto opt_tasks

:act_names
echo.
echo ------------------------------------------------------------
echo  Which entries?
echo ------------------------------------------------------------
echo   Type one or more names separated by commas. A name is matched
echo   against the entry name, the executable and the application, so
echo   Discord and Update.exe both find the same row.
echo   Example:  Discord,jusched,iTunesHelper
set /p "NAMES=Names: "
REM  Quoting a list is normal Windows habit, and "Copy as path" always
REM  quotes - but the quotes would survive into -Disable ""a,b"" and the
REM  script would then match nothing.
if defined NAMES set NAMES=!NAMES:"=!
if not defined NAMES goto menu
set "PSARGS=-Disable !NAMES!"
set "PSLIST=,'-Disable','!NAMES!'"
set "S_ACTION=Disable: !NAMES!"
set "CHANGES=1"
goto opt_tasks

:act_disableopt
set "PSARGS=-DisableOptional"
set "PSLIST=,'-DisableOptional'"
set "S_ACTION=Disable every OPTIONAL entry"
set "CHANGES=1"
goto opt_tasks

:act_removeopt
set "PSARGS=-RemoveOptional"
set "PSLIST=,'-RemoveOptional'"
set "S_ACTION=REMOVE every OPTIONAL entry"
set "CHANGES=1"
goto opt_tasks

:act_orphans
set "PSARGS=-RemoveOrphans"
set "PSLIST=,'-RemoveOrphans'"
set "S_ACTION=Remove ORPHAN entries"
set "CHANGES=1"
goto opt_tasks

:act_restore
echo.
echo ------------------------------------------------------------
echo  Restore from a backup
echo ------------------------------------------------------------
echo   Every run that changed anything printed the path of the JSON
echo   backup it wrote. Paste it here. They live in your TEMP folder,
echo   named StartupApps_yyyyMMdd_HHmmss.json
set /p "BACKUP=Backup file: "
if defined BACKUP set BACKUP=!BACKUP:"=!
if not defined BACKUP goto menu
set "PSARGS=-Restore "!BACKUP!""
set "PSLIST=,'-Restore','!BACKUP!'"
set "S_ACTION=Restore from !BACKUP!"
set "CHANGES=1"
REM  A restore is not a survey, and a preview of one is meaningless.
set "S_TASKS=not applicable"
set "S_PREVIEW=not applicable"
goto opt_elevate


:opt_tasks
echo.
echo ------------------------------------------------------------
echo  Logon scheduled tasks
echo ------------------------------------------------------------
echo   Task Manager does not show these, but they are a fourth way a
echo   program starts at sign-in. Including them makes the census
echo   longer and slower to gather.
choice /C YN /N /M "Include logon scheduled tasks?  [Y/N]: "
if errorlevel 2 goto tasks_no
set "PSARGS=!PSARGS! -IncludeScheduledTasks"
set "PSLIST=!PSLIST!,'-IncludeScheduledTasks'"
set "S_TASKS=YES"
goto opt_preview
:tasks_no
set "S_TASKS=no"

:opt_preview
if "!CHANGES!"=="0" set "S_PREVIEW=not applicable"
if "!CHANGES!"=="0" goto opt_elevate
echo.
echo ------------------------------------------------------------
echo  Preview first
echo ------------------------------------------------------------
echo   A preview prints the exact plan - every entry it would touch
echo   and why - then stops without changing anything. Strongly
echo   recommended before a REMOVE.
choice /C YN /N /M "Preview only, change nothing?  [Y/N]: "
if errorlevel 2 goto preview_no
set "PSARGS=!PSARGS! -WhatIf"
set "PSLIST=!PSLIST!,'-WhatIf'"
set "S_PREVIEW=YES - nothing will be changed"
goto opt_elevate
:preview_no
set "S_PREVIEW=no - changes will be applied"

:opt_elevate
echo.
echo ------------------------------------------------------------
echo  Administrator rights
echo ------------------------------------------------------------
echo   Your own startup entries need none. Elevation is only needed to
echo   CHANGE the machine-wide ones: the HKLM Run keys, the all-users
echo   Startup folder and scheduled tasks. Without it those rows are
echo   still listed, and the run says which ones it could not touch.
choice /C YN /N /M "Run elevated?  [Y/N]: "
if errorlevel 2 goto elev_no
set "ELEVATE=1"
set "S_ELEVATE=YES - a UAC prompt appears, and it runs in a new window"
goto summary
:elev_no
set "ELEVATE=0"
set "S_ELEVATE=no - per-user entries only"


:summary
cls
echo ============================================================
echo   SUMMARY
echo ============================================================
echo   Action ....................... !S_ACTION!
echo   Logon scheduled tasks ........ !S_TASKS!
echo   Preview only ................. !S_PREVIEW!
echo   Elevated ..................... !S_ELEVATE!
echo.
echo   Command ...................... Clean-StartupApps.ps1 !PSARGS!
echo ============================================================
echo.
choice /C YN /N /M "Does this look right? Y to run, N to choose again  [Y/N]: "
if errorlevel 2 goto menu

echo.
if "!ELEVATE!"=="1" goto run_elevated

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
REM  Each argument is its own single-quoted list element, so a name or a
REM  backup path containing spaces survives. -NoExit keeps the new window
REM  up; without it the results would flash past and be readable only in
REM  the transcript.
"%PS%" -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-NoExit','-File','%SCRIPT%'!PSLIST!)"
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
REM  Two things a launcher cannot do:
REM   - Bind a [bool] or a -Switch:$false. This uses powershell -File,
REM     which passes every argument as a literal string, so anything
REM     README.md marks "needs -Command" still has to be typed out
REM     against powershell.exe.
REM   - Know whether there is a console to return to. Started from
REM     Explorer it pauses so the output can be read; started from a
REM     prompt it returns the exit code without pausing.
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*
set "RC=%ERRORLEVEL%"

REM  CMDCMDLINE is a DYNAMIC variable: cmd synthesises it rather than
REM  keeping it in the environment block, so the substring transform
REM  !cmdcmdline:/c=! returns the value UNMODIFIED and the comparison was
REM  always equal - this pause never fired in any launcher. Copy it into a
REM  real variable first, which the transform does apply to. Delayed
REM  expansion is still used for the comparison so an "&" or a quote in
REM  the launch path cannot be parsed as a command.
set "LAUNCHLINE=%cmdcmdline%"
if not "!LAUNCHLINE:/c=!"=="!LAUNCHLINE!" pause

exit /b %RC%
