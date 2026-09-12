@echo off
setlocal

:: Start-Hub.cmd - opens the ADesk Cleaner hub (hub\Start-Hub.ps1): one window
:: to find, read about, preview and run every script in this repository.
::
:: Starts Windows PowerShell 5.1 with the execution policy bypassed for this
:: process only, single-threaded apartment (WPF needs it), console hidden (the
:: hub is a window; the console is not needed). Every script the hub starts gets
:: its OWN console window, so its output and its prompts are visible there.
::
:: Elevation: none needed to open the hub. Each script is started elevated or
:: not from inside the hub - the "Run elevated" box - so you never have to
:: right-click anything.

set "SCRIPT=%~dp0hub\Start-Hub.ps1"
if not exist "%SCRIPT%" (
    echo Cannot find "%SCRIPT%" - keep this launcher at the repository root, beside hub\.
    pause
    exit /b 1
)

start "" "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%SCRIPT%"
exit /b 0
