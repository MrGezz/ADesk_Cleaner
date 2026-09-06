@echo off
setlocal

:: Clear-RevitCache.cmd - launcher for Clear-RevitCache.ps1, which must sit next to this file.
::
:: Runs the script in Windows PowerShell 5.1 with the execution policy bypassed
:: for this process only, forwarding every argument unchanged:
::
::     Clear-RevitCache.cmd -ListOnly
::
:: No elevation. Run it AS the user whose caches you want cleared - elevated as
:: a different account, it clears that account caches instead.
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

set "SCRIPT=%~dp0Clear-RevitCache.ps1"
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
:: CMDCMDLINE is a DYNAMIC variable: cmd synthesises it rather than
:: keeping it in the environment block, so the substring transform
:: !cmdcmdline:/c=! returns the value UNMODIFIED and the comparison was
:: always equal - this pause never fired in any launcher. Copy it into a
:: real variable first, which the transform does apply to. Delayed
:: expansion is still used for the comparison so an "&" or a quote in the
:: launch path cannot be parsed as a command.
set "LAUNCHLINE=%cmdcmdline%"
setlocal EnableDelayedExpansion
if not "!LAUNCHLINE:/c=!"=="!LAUNCHLINE!" pause

exit /b %RC%
