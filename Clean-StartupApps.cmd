@echo off
setlocal

:: Clean-StartupApps.cmd - launcher for Clean-StartupApps.ps1, which must sit next to this file.
::
:: Runs the script in Windows PowerShell 5.1 with the execution policy bypassed
:: for this process only, forwarding every argument unchanged:
::
::     Clean-StartupApps.cmd
::     Clean-StartupApps.cmd -Disable Discord,jusched,iTunesHelper
::     Clean-StartupApps.cmd -DisableOptional -WhatIf
::
:: With no arguments it runs a CENSUS: every startup entry, what it actually is,
:: and what turning it off would cost you. Nothing is changed.
::
:: Elevation. Unlike the other scripts here, this one does NOT self-elevate,
:: because the useful half of its work is per-user and needs no elevation at
:: all: the HKCU Run key, your own Startup folder and the packaged app startup
:: tasks are all yours to change. Only the machine-wide surfaces - the HKLM Run
:: keys, the all-users Startup folder and scheduled tasks - need administrator
:: rights, and the run reports plainly which rows it could not touch. To act on
:: those too, right-click this file and choose "Run as administrator".
::
:: Two things a launcher cannot do:
::   - Bind a [bool] or a -Switch:$false. This uses powershell -File, which
::     passes every argument as a literal string, so anything README.md marks
::     "needs -Command" still has to be typed out against powershell.exe.
::   - Know whether there is a console to return to. Started from Explorer it
::     pauses at the end so the output can be read; started from a cmd prompt
::     it returns the script's exit code without pausing. (PowerShell runs
::     .cmd files through "cmd /c", which looks like Explorer - expect the
::     pause there too.)

set "SCRIPT=%~dp0Clean-StartupApps.ps1"
if not exist "%SCRIPT%" (
    echo Cannot find "%SCRIPT%" - keep this launcher next to the script.
    exit /b 1
)

"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*
set "RC=%ERRORLEVEL%"

:: cmdcmdline carries "/c" only when this file was launched directly rather
:: than typed at a prompt. Built-in substitution rather than find.exe, so it
:: cannot be hijacked by a Unix find earlier on PATH; delayed expansion keeps
:: any "&" or quotes in the launch path from being parsed as commands.
setlocal EnableDelayedExpansion
if not "!cmdcmdline:/c=!"=="!cmdcmdline!" pause

exit /b %RC%
