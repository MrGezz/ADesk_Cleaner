@echo off
setlocal

:: Uninstall-PyRevit-Complete.cmd - launcher for Uninstall-PyRevit-Complete.ps1, which must sit next to this file.
::
:: Runs the script in Windows PowerShell 5.1 with the execution policy bypassed
:: for this process only, forwarding every argument unchanged:
::
::     Uninstall-PyRevit-Complete.cmd -DryRun
::
:: Elevation is optional and the script does not self-elevate. Run it as the
:: user who installed pyRevit; only a machine-wide install (*_admin_signed.exe)
:: needs an elevated prompt - right-click this file and choose "Run as
:: administrator" for that one.
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

set "SCRIPT=%~dp0Uninstall-PyRevit-Complete.ps1"
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
