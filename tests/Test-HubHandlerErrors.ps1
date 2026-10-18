<#
.SYNOPSIS
    Regression test for errors inside the hub's event handlers: the window must
    stay open and say what went wrong, instead of vanishing.

.DESCRIPTION
    The hub runs with its console hidden. An exception thrown in a click or
    selection handler used to escape ShowDialog() and end the script, so the
    window simply disappeared - and under the hub's $ErrorActionPreference =
    'Stop' any error a cmdlet in a handler writes is such an exception.

    This test provokes a real one: it stages the hub in a throwaway folder
    under %TEMP% with no README.md beside it (hub\Start-Hub.ps1, this
    repository's hub\catalog.json and scripts\utility\Clean-Directory.ps1),
    starts it the way Start-Hub.cmd does, and clicks "Open README" through UI
    Automation. Start-Process then fails inside the click handler.

    The hub must still be running afterwards, its window still open, and the
    status bar must name the button and carry the error message (computed by
    running the same failing Start-Process here, so the check does not depend
    on the Windows display language). A search must then still re-read the
    selected script, and a second click must be reported the same way.

    A static check runs first: every Add_* handler in the hub's source must be
    a single Invoke-Handler call, and the hub must register a
    Dispatcher.UnhandledException handler as the net for anything that reaches
    the message loop anyway.

    Nothing is run or deleted: Clean-Directory is only read by the hub's form,
    and the staging folder is removed at the end.

    Run with -ExpectDefective against a pre-fix copy of the hub to prove this
    harness can fail: in that mode it passes only if the handlers are
    unguarded and the click closes the hub.

.PARAMETER HubPath
    The hub script to test. Default: hub\Start-Hub.ps1 beside tests\. Any copy
    will do (for example one written by git show); it is staged together with
    this repository's catalog.json and Clean-Directory.ps1.

.PARAMETER ExpectDefective
    Prove-it-can-fail mode for a pre-fix copy: passes only if the handlers are
    unguarded and the click closes the hub.

.PARAMETER TimeoutSec
    How long to wait for the hub window and for each click's outcome.
    Default 20.

.EXAMPLE
    .\tests\Test-HubHandlerErrors.ps1
    Opens the hub for about ten seconds and clicks "Open README" twice.
    Exit code 0 = all assertions hold.

.EXAMPLE
    git show a78f375:hub/Start-Hub.ps1 | Set-Content "$env:TEMP\Start-Hub.prefix.ps1" -Encoding ASCII
    .\tests\Test-HubHandlerErrors.ps1 -HubPath "$env:TEMP\Start-Hub.prefix.ps1" -ExpectDefective
    Confirms the harness detects the original defect (the click closes the hub).

.NOTES
    Windows PowerShell 5.1 (relaunches itself there from PowerShell 7). Needs a
    desktop session and no elevation. Opens and closes a visible window; do not
    type into it while it runs.
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

Write-Output "hub  : $HubPath"
Write-Output "mode : $(if ($ExpectDefective) { 'EXPECT DEFECTIVE (prove the harness can fail)' } else { 'a handler error must be reported and the window must stay open' })"

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
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)
    return $null
}

function Find-ById {
    param($Root, [string]$Id)
    $Root.FindFirst($Scope::Descendants, (New-Object System.Windows.Automation.PropertyCondition($AE::AutomationIdProperty, $Id)))
}

# $null once the window is gone, rather than an ElementNotAvailableException.
function Get-ElementText {
    param($Root, [string]$Id)
    try { $e = Find-ById $Root $Id; if ($e) { return $e.Current.Name } } catch { }
    $null
}

function Find-HubWindow {
    param([int]$ProcessId)
    $c = New-Object System.Windows.Automation.AndCondition(
        (New-Object System.Windows.Automation.PropertyCondition($AE::ProcessIdProperty, $ProcessId)),
        (New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, [System.Windows.Automation.ControlType]::Window)))
    $AE::RootElement.FindFirst($Scope::Children, $c)
}

# --- static: every handler goes through Invoke-Handler -----------------------
Write-Output ''
Write-Output 'Source'
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($HubPath, [ref]$null, [ref]$parseErrors)
$adds = @($ast.FindAll({
    param($n)
    $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
    $n.Member -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
    $n.Member.Value -like 'Add_*'
}, $true))
$net = @($adds | Where-Object { $_.Member.Value -eq 'Add_UnhandledException' })
$handlers = @($adds | Where-Object { $_.Member.Value -ne 'Add_UnhandledException' })
$unguarded = @($handlers | Where-Object {
    $guarded = $false
    $a = @($_.Arguments)
    if ($a.Count -eq 1 -and $a[0] -is [System.Management.Automation.Language.ScriptBlockExpressionAst]) {
        $st = @($a[0].ScriptBlock.EndBlock.Statements)
        if ($st.Count -eq 1 -and $st[0] -is [System.Management.Automation.Language.PipelineAst]) {
            $el = @($st[0].PipelineElements)
            $guarded = ($el.Count -eq 1 -and $el[0] -is [System.Management.Automation.Language.CommandAst] -and $el[0].GetCommandName() -eq 'Invoke-Handler')
        }
    }
    -not $guarded
})
foreach ($u in $unguarded) { Write-Output ("    unguarded: line {0}: {1}" -f $u.Extent.StartLineNumber, $u.Member.Value) }
$allGuarded = ($handlers.Count -gt 0 -and $unguarded.Count -eq 0 -and $net.Count -ge 1)
if ($ExpectDefective) {
    Assert (-not $allGuarded) "the hub's handlers are unguarded ($($unguarded.Count) of $($handlers.Count); net registered: $($net.Count)) (defect present)"
} else {
    Assert (@($parseErrors).Count -eq 0) "the hub parses ($(@($parseErrors).Count) error(s))"
    Assert ($handlers.Count -gt 0 -and $unguarded.Count -eq 0) "every Add_* handler is one Invoke-Handler call ($($handlers.Count) handlers, $($unguarded.Count) unguarded)"
    Assert ($net.Count -ge 1) 'a Dispatcher.UnhandledException handler is registered'
}

# --- stage the hub with no README.md beside it -------------------------------
$work = Join-Path $env:TEMP ('hub-handler-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path (Join-Path $work 'hub'), (Join-Path $work 'scripts\utility') -Force | Out-Null
$stagedHub = Join-Path $work 'hub\Start-Hub.ps1'
Copy-Item -LiteralPath $HubPath -Destination $stagedHub
Copy-Item -LiteralPath (Join-Path $repo 'hub\catalog.json') -Destination (Join-Path $work 'hub')
Copy-Item -LiteralPath (Join-Path $repo 'scripts\utility\Clean-Directory.ps1') -Destination (Join-Path $work 'scripts\utility')
$readme = Join-Path $work 'README.md'

# The message the hub has to show: the same call, failing the same way, here.
$expected = $null
try { Start-Process -FilePath $readme } catch { $expected = $_.Exception.Message }
if (-not $expected) { Write-Output 'Start-Process on a missing file did not fail here; cannot provoke the error.'; exit 2 }
Write-Output "    expected error: $expected"

# --- drive the hub -----------------------------------------------------------
$hub = $null
try {
    $hubArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-WindowStyle', 'Hidden', '-File', ('"{0}"' -f $stagedHub))
    $hub = Start-Process -FilePath $ps51 -ArgumentList $hubArgs -PassThru
    [void]$hub.Handle   # keep a handle so HasExited and ExitCode stay readable
    $win = Wait-Until { Find-HubWindow $hub.Id }
    Assert ($null -ne $win) "the staged hub window opened (pid $($hub.Id))"
    if (-not $win) { throw 'no hub window' }

    $search = (Find-ById $win 'TxtSearch').GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
    $search.SetValue('Clean a directory')
    $picked = Wait-Until { (Get-ElementText $win 'TxtStatus') -like '*Clean-Directory.ps1*parameter(s) read*' } -Seconds 10
    Assert ([bool]$picked) "searching selects Clean-Directory and the status bar says so"

    # --- first click ---
    Write-Output ''
    Write-Output 'Open README, no README.md beside the hub'
    $btn = Find-ById $win 'BtnReadme'
    $btn.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    [void](Wait-Until { $hub.HasExited -or "$(Get-ElementText $win 'TxtStatus')".Contains($expected) })
    Start-Sleep -Seconds 2   # a hub that is going to die has done so by now
    $status = Get-ElementText $win 'TxtStatus'
    Write-Output "    hub running: $(-not $hub.HasExited)$(if ($hub.HasExited) { "  (exit code $($hub.ExitCode))" })"
    Write-Output "    status bar : $status"
    if ($ExpectDefective) {
        Assert $hub.HasExited 'the click closed the hub (defect present)'
    } else {
        Assert (-not $hub.HasExited) 'the hub is still running after the error'
        Assert ($null -ne (Find-HubWindow $hub.Id)) 'its window is still open'
        Assert ("$status" -like '*Open README*' -and "$status".Contains($expected)) 'the status bar names the button and carries the error message'
    }

    if (-not $ExpectDefective -and -not $hub.HasExited) {
        # --- still working ---
        Write-Output ''
        Write-Output 'After the error'
        $search.SetValue('Clean a director')
        $again = Wait-Until { (Get-ElementText $win 'TxtStatus') -like '*Clean-Directory.ps1*parameter(s) read*' } -Seconds 10
        Assert ([bool]$again) 'a new search still re-reads the selected script'

        # --- second click ---
        $btn.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
        $second = Wait-Until { $hub.HasExited -or "$(Get-ElementText $win 'TxtStatus')".Contains($expected) }
        Start-Sleep -Seconds 1
        Write-Output "    status bar : $(Get-ElementText $win 'TxtStatus')"
        Assert ([bool]$second -and -not $hub.HasExited) 'a second click is reported the same way and the hub keeps running'
    }
}
catch {
    Assert $false "harness error: $($_.Exception.Message)"
}
finally {
    if ($hub -and -not $hub.HasExited) { Stop-Process -Id $hub.Id -Force -ErrorAction SilentlyContinue }
    if ($hub) { [void]$hub.WaitForExit(5000) }
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output ''
Write-Output ("RESULT: {0} passed, {1} failed" -f $script:Pass, $script:Fail)
if ($script:Fail -gt 0) { exit 1 }
exit 0
