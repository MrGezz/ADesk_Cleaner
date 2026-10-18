<#
.SYNOPSIS
    Regression test for errors the hub hits before its window shows: it must
    say what went wrong in a message box and exit non-zero, instead of
    vanishing.

.DESCRIPTION
    The hub runs with its console hidden. An error outside the event handlers
    - catalog.json missing or malformed, the XAML failing to load, a named
    element missing from it - used to end the script before the window
    showed: the error went to the hidden console and the process exited with
    code 1, so a double-click on Start-Hub.cmd did nothing at all.

    This test stages the hub three times in a throwaway folder under %TEMP%:

      catalog.json absent      no catalog.json beside the hub
      catalog.json malformed   a truncated catalog.json
      XAML element missing     this repository's catalog.json, and a hub copy
                               whose BtnCopy has been renamed in the XAML

    Each one is started the way Start-Hub.cmd starts it (-WindowStyle Hidden).
    A message box must then appear under the hub's process id, carry the
    error message and the line number of the statement that failed, and,
    once the box is closed through UI Automation, the hub must exit with a
    non-zero code. The messages are computed here rather than spelled in the
    test where they come from Windows (ConvertFrom-Json), so the check does not
    depend on the display language; the line numbers are read from the staged
    hub's own syntax tree.

    -SelfTest runs unattended, so it must never show a box: started on the
    absent catalogue with its output redirected, it has to exit on its own
    with code 1, with no window, and print the error on stdout.

    Nothing is run or deleted outside the staging folder, which is removed at
    the end.

    Run with -ExpectDefective against a pre-fix copy of the hub to prove this
    harness can fail: in that mode it passes only if every staged hub exits
    without showing anything.

.PARAMETER HubPath
    The hub script to test. Default: hub\Start-Hub.ps1 beside tests\. Any copy
    will do (for example one written by git show); it is staged on its own,
    and with this repository's catalog.json for the XAML case.

.PARAMETER ExpectDefective
    Prove-it-can-fail mode for a pre-fix copy: passes only if every staged
    hub exits without showing a window.

.PARAMETER TimeoutSec
    How long to wait for each message box and for each exit. Default 20.

.EXAMPLE
    .\tests\Test-HubStartupErrors.ps1
    Starts the hub four times, each for a few seconds. Exit code 0 = all
    assertions hold.

.EXAMPLE
    git show 436e69d:hub/Start-Hub.ps1 | Set-Content "$env:TEMP\Start-Hub.prefix.ps1" -Encoding ASCII
    .\tests\Test-HubStartupErrors.ps1 -HubPath "$env:TEMP\Start-Hub.prefix.ps1" -ExpectDefective
    Confirms the harness detects the original defect (the hub exits without a
    word).

.NOTES
    Windows PowerShell 5.1 (relaunches itself there from PowerShell 7). Needs a
    desktop session and no elevation. Opens and closes message boxes; do not
    click them while it runs.
#>
[CmdletBinding()]
param(
    [string]$HubPath,
    [switch]$ExpectDefective,
    [int]$TimeoutSec = 20
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2

$ps51 = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

# UI Automation is driven from Windows PowerShell 5.1, the same runtime as the hub.
if ($PSVersionTable.PSEdition -ne 'Desktop') {
    $fwd = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath, '-TimeoutSec', $TimeoutSec)
    if ($HubPath)         { $fwd += @('-HubPath', $HubPath) }
    if ($ExpectDefective) { $fwd += '-ExpectDefective' }
    & $ps51 @fwd
    exit $LASTEXITCODE
}

$repo = Split-Path -Parent $PSScriptRoot
if (-not $HubPath) { $HubPath = Join-Path $repo 'hub\Start-Hub.ps1' }
if (-not (Test-Path -LiteralPath $HubPath)) { Write-Output "Cannot find the hub '$HubPath'."; exit 2 }
$HubPath = (Resolve-Path -LiteralPath $HubPath).ProviderPath

Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
$AE    = [System.Windows.Automation.AutomationElement]
$Scope = [System.Windows.Automation.TreeScope]
$CT    = [System.Windows.Automation.ControlType]

Write-Output "hub  : $HubPath"
Write-Output "mode : $(if ($ExpectDefective) { 'EXPECT DEFECTIVE (prove the harness can fail)' } else { 'a start-up error must be shown in a message box and the hub must exit non-zero' })"

# --- assertion plumbing ------------------------------------------------------
$script:Pass = 0
$script:Fail = 0
function Assert {
    param([bool]$Condition, [string]$What)
    if ($Condition) { $script:Pass++; Write-Output "  [PASS] $What" }
    else            { $script:Fail++; Write-Output "  [FAIL] $What" }
}

function Wait-Until {
    param([scriptblock]$Condition, [int]$Seconds = $TimeoutSec)
    $deadline = (Get-Date).AddSeconds($Seconds)
    do {
        $r = & $Condition
        if ($r) { return $r }
        Start-Sleep -Milliseconds 200
    } while ((Get-Date) -lt $deadline)
    return $null
}

function Find-HubWindow {
    param([int]$ProcessId)
    $c = New-Object System.Windows.Automation.AndCondition(
        (New-Object System.Windows.Automation.PropertyCondition($AE::ProcessIdProperty, $ProcessId)),
        (New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, $CT::Window)))
    $AE::RootElement.FindFirst($Scope::Children, $c)
}

# A message box is a Win32 dialog. Without the Win32 client-side providers the
# managed UI Automation client reports its children as bare Panes, with no
# patterns, so they are found by window class as well as by control type.
function Find-All {
    param($Root, $ControlType, [string]$ClassName)
    $c = New-Object System.Windows.Automation.OrCondition(
        (New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, $ControlType)),
        (New-Object System.Windows.Automation.PropertyCondition($AE::ClassNameProperty, $ClassName)))
    @($Root.FindAll($Scope::Descendants, $c))
}

# WindowPattern.Close is offered either way; a box with only OK takes it as OK.
function Close-Box {
    param($Box)
    $p = $null
    if ($Box.TryGetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern, [ref]$p)) { $p.Close(); return }
    foreach ($b in @(Find-All $Box $CT::Button 'Button')) {
        if ($b.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$p)) { $p.Invoke(); return }
    }
}

# Message text arrives with its line breaks; compare on single spaces.
function Format-Flat { param([string]$Text) ($Text -replace '\s+', ' ').Trim() }

# The line of the first statement in function $Function that $Predicate picks.
function Get-StatementLine {
    param([string]$Path, [string]$Function, [scriptblock]$Predicate)
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null)
    $fn = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Function }, $true)
    if (-not $fn) { throw "no function $Function in $Path" }
    $hit = $fn.Body.Find($Predicate, $true)
    if (-not $hit) { throw "the statement looked for is not in $Function" }
    $hit.Extent.StartLineNumber
}

# --- the hub must at least parse: a parse error is the one thing it cannot report
Write-Output ''
Write-Output 'Source'
$parseErrors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($HubPath, [ref]$null, [ref]$parseErrors)
if (-not $ExpectDefective) { Assert (@($parseErrors).Count -eq 0) "the hub parses ($(@($parseErrors).Count) error(s))" }

# --- stage the three broken hubs ---------------------------------------------
$work = Join-Path $env:TEMP ('hub-startup-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $work -Force | Out-Null
# %TEMP% can be an 8.3 path; the hub names catalog.json by its $PSScriptRoot,
# which is the long form, and so does Get-Item.
$work = (Get-Item -LiteralPath $work).FullName
$isThrow    = { param($n) $n -is [System.Management.Automation.Language.ThrowStatementAst] }
$isFromJson = { param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'ConvertFrom-Json' }

function New-Stage {
    param([string]$Name)
    $hubDir = Join-Path (Join-Path $work $Name) 'hub'
    New-Item -ItemType Directory -Path $hubDir -Force | Out-Null
    $staged = Join-Path $hubDir 'Start-Hub.ps1'
    Copy-Item -LiteralPath $HubPath -Destination $staged
    $staged
}

$cases = @()
$hub = $null
try {
    # catalog.json absent
    $h = New-Stage 'absent'
    $cat = Join-Path (Split-Path -Parent $h) 'catalog.json'
    $cases += [pscustomobject]@{
        Name = 'catalog.json absent'; Hub = $h
        Message = "catalog.json not found beside the hub: $cat"
        Line = (Get-StatementLine $h 'Get-Catalog' $isThrow)
    }

    # catalog.json malformed: the message is whatever ConvertFrom-Json says here
    $h = New-Stage 'malformed'
    $cat = Join-Path (Split-Path -Parent $h) 'catalog.json'
    [IO.File]::WriteAllText($cat, '{ "title": "ADesk Cleaner", "scripts": [ ')
    $msg = $null
    try { $null = Get-Content -LiteralPath $cat -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $msg = $_.Exception.Message }
    if (-not $msg) { throw 'the truncated catalog.json parsed here; cannot provoke the error' }
    $cases += [pscustomobject]@{
        Name = 'catalog.json malformed'; Hub = $h; Message = $msg
        Line = (Get-StatementLine $h 'Get-Catalog' $isFromJson)
    }

    # XAML element missing: a valid catalogue, BtnCopy renamed in the staged hub's XAML
    $h = New-Stage 'xaml'
    Copy-Item -LiteralPath (Join-Path $repo 'hub\catalog.json') -Destination (Split-Path -Parent $h)
    $src = [IO.File]::ReadAllText($h)
    $renamed = $src.Replace('x:Name="BtnCopy"', 'x:Name="BtnCopyGone"')
    if ($renamed -eq $src) { throw 'x:Name="BtnCopy" is not in the hub; cannot provoke the error' }
    [IO.File]::WriteAllText($h, $renamed, (New-Object System.Text.UTF8Encoding($false)))
    $cases += [pscustomobject]@{
        Name = 'XAML element missing'; Hub = $h; Message = 'XAML element missing: BtnCopy'
        Line = (Get-StatementLine $h 'Initialize-Window' $isThrow)
    }

    # --- start each one the way Start-Hub.cmd does ----------------------------
    foreach ($c in $cases) {
        Write-Output ''
        Write-Output $c.Name
        Write-Output "    expected: $($c.Message) (line $($c.Line))"
        $hubArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-WindowStyle', 'Hidden', '-File', ('"{0}"' -f $c.Hub))
        $hub = Start-Process -FilePath $ps51 -ArgumentList $hubArgs -PassThru
        [void]$hub.Handle   # keep a handle so HasExited and ExitCode stay readable
        $box = Wait-Until { if ($hub.HasExited) { 'exited' } else { Find-HubWindow $hub.Id } }

        if ($ExpectDefective) {
            [void]$hub.WaitForExit($TimeoutSec * 1000)
            Assert ("$box" -eq 'exited' -and $hub.HasExited) "the hub exited without showing a window (exit code $(if ($hub.HasExited) { $hub.ExitCode } else { 'none' })) (defect present)"
        } else {
            $isBox = ($box -is [System.Windows.Automation.AutomationElement])
            $class = $(if ($isBox) { $box.Current.ClassName } else { '' })
            $text = ''
            if ($isBox) {
                # The window exists a moment before its text and button do.
                [void](Wait-Until { @(Find-All $box $CT::Text 'Static').Count -gt 0 -and @(Find-All $box $CT::Button 'Button').Count -gt 0 } -Seconds 10)
                $text = Format-Flat ((Find-All $box $CT::Text 'Static' | ForEach-Object { $_.Current.Name }) -join ' ')
            }
            Write-Output "    window    : $(if ($isBox) { "[$class] $($box.Current.Name)" } else { "none ($box)" })"
            Write-Output "    box text  : $text"
            Assert ($isBox -and $class -eq '#32770') "a message box opened under the hub's pid ($($hub.Id))"
            Assert ($text.Contains((Format-Flat $c.Message))) 'it carries the error message'
            Assert ($text -match ('\bline {0}\b' -f $c.Line)) "it gives the line number ($($c.Line))"
            if ($isBox) { Close-Box $box }
            $exited = $hub.WaitForExit($TimeoutSec * 1000)
            Assert ($isBox -and $exited -and $hub.ExitCode -ne 0) "closing it ends the hub with a non-zero exit code ($(if ($exited) { $hub.ExitCode } else { 'still running' }))"
        }
        if (-not $hub.HasExited) { Stop-Process -Id $hub.Id -Force -ErrorAction SilentlyContinue; [void]$hub.WaitForExit(5000) }
        $hub = $null
    }

    # --- -SelfTest: unattended, so no box -------------------------------------
    Write-Output ''
    Write-Output '-SelfTest on the absent catalogue'
    $c = $cases[0]
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName  = $ps51
    $psi.Arguments = ('-NoProfile -ExecutionPolicy Bypass -STA -File "{0}" -SelfTest' -f $c.Hub)
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow  = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $hub = [System.Diagnostics.Process]::Start($psi)
    $outTask = $hub.StandardOutput.ReadToEndAsync()
    $errTask = $hub.StandardError.ReadToEndAsync()
    $seen = Wait-Until { if ($hub.HasExited) { 'exited' } else { Find-HubWindow $hub.Id } }
    $exited = $hub.WaitForExit(2000)
    $windowSeen = ($seen -is [System.Windows.Automation.AutomationElement])
    if (-not $exited) { Stop-Process -Id $hub.Id -Force -ErrorAction SilentlyContinue; [void]$hub.WaitForExit(5000) }
    $stdout = $outTask.Result
    $stderr = $errTask.Result
    Write-Output "    exit code : $(if ($exited) { $hub.ExitCode } else { 'killed' })"
    Write-Output "    stdout    : $(Format-Flat $stdout)"
    Write-Output "    stderr    : $(Format-Flat $stderr)"
    Assert ($exited -and -not $windowSeen -and $hub.ExitCode -eq 1) '-SelfTest exits by itself with code 1 and shows no window'
    if (-not $ExpectDefective) {
        $flat = Format-Flat $stdout
        Assert ($flat -like '*SELFTEST FAILED*' -and $flat.Contains((Format-Flat $c.Message)) -and $flat -match ('\bline {0}\b' -f $c.Line)) '-SelfTest prints the error and its line on stdout'
    }
    $hub = $null
}
catch {
    Assert $false "harness error: $($_.Exception.Message)"
}
finally {
    if ($hub -and -not $hub.HasExited) { Stop-Process -Id $hub.Id -Force -ErrorAction SilentlyContinue; [void]$hub.WaitForExit(5000) }
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output ''
Write-Output ("RESULT: {0} passed, {1} failed" -f $script:Pass, $script:Fail)
if ($script:Fail -gt 0) { exit 1 }
exit 0
