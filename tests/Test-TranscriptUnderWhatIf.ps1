<#
.SYNOPSIS
    Regression test for checklist item 4: a script run with -WhatIf must still
    write the log it announces.

.DESCRIPTION
    Start-Transcript is ShouldProcess-aware. Called without -WhatIf:$false it
    inherits the script's -WhatIf, only previews, and the run then announces a
    log path for a file that was never written.

    Two halves, both run by default:

    Static - every Start-Transcript call in every script under scripts\ is
    found in the parsed AST and must carry -WhatIf:$false.

    Live - the scripts that run unelevated with -ListOnly (Clean-StartupApps,
    Remove-LegacyHardwareResidue, Remove-WindowsBloat) are started in a fresh
    Windows PowerShell 5.1 with -ListOnly -WhatIf. Every log path the run
    announces must exist, must have been written during this run, and must be
    a PowerShell transcript. The five uninstallers always self-elevate, so
    only the static half covers them.

    -ListOnly keeps the live half read-only even if a script's ShouldProcess
    gating ever regressed. The transcript opens before any mode is dispatched,
    so the mode does not change what is tested.

    Run with -ExpectDefective against a pre-fix copy of a script to prove this
    harness can fail: in that mode it passes only if the copy's Start-Transcript
    lacks -WhatIf:$false and its announced log is missing.

.PARAMETER ScriptPath
    One or more scripts to test instead of the defaults, as an array or one
    comma-separated string (the form -File can pass). The static half checks
    each one. The live half runs each one named like a default live script, or
    every one when -ScriptArgs is given.

.PARAMETER ScriptArgs
    Arguments for the live run of -ScriptPath; -WhatIf is always appended.
    Default: -ListOnly.

.PARAMETER ExpectDefective
    Prove-it-can-fail mode for a pre-fix copy: passes only if the defect
    reproduces in both halves.

.EXAMPLE
    .\tests\Test-TranscriptUnderWhatIf.ps1
    Static check over scripts\, live check of the three unelevated scripts.
    Exit code 0 = all assertions hold.

.EXAMPLE
    git show c6cd2bc:scripts/windows/Clean-StartupApps.ps1 > $env:TEMP\Clean-StartupApps.ps1
    .\tests\Test-TranscriptUnderWhatIf.ps1 -ScriptPath $env:TEMP\Clean-StartupApps.ps1 -ExpectDefective
    Confirms the harness detects the original defect. Keep the file name: the
    live half picks its scripts by name.

.NOTES
    Runs under Windows PowerShell 5.1 or PowerShell 7; the scripts under test
    always run in Windows PowerShell 5.1. Needs no elevation. The logs a
    passing live run creates in %TEMP% are removed afterwards.
#>
[CmdletBinding()]
param(
    [string[]]$ScriptPath,
    [string[]]$ScriptArgs,
    [switch]$ExpectDefective
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2

$LiveNames = @('Clean-StartupApps.ps1', 'Remove-LegacyHardwareResidue.ps1', 'Remove-WindowsBloat.ps1')

# --- locate the scripts under test ------------------------------------------
# -File cannot bind an array: "a","b" arrives as one string, so split it here.
$ScriptPath = @($ScriptPath | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim().Trim('"') } | Where-Object { $_ })
if ($ScriptPath) {
    foreach ($p in $ScriptPath) {
        if (-not (Test-Path -LiteralPath $p)) { Write-Output "Cannot find the script under test '$p'."; exit 2 }
    }
    $staticTargets = @($ScriptPath | ForEach-Object { (Resolve-Path -LiteralPath $_).ProviderPath })
    $liveTargets = @($staticTargets | Where-Object { $ScriptArgs -or ($LiveNames -contains (Split-Path $_ -Leaf)) })
}
else {
    $scriptsRoot = Join-Path $PSScriptRoot '..\scripts'
    if (-not (Test-Path -LiteralPath $scriptsRoot)) { Write-Output "Cannot find scripts\ beside tests\. Pass -ScriptPath."; exit 2 }
    $staticTargets = @(Get-ChildItem -LiteralPath $scriptsRoot -Recurse -File -Filter *.ps1 | ForEach-Object { $_.FullName })
    $liveTargets = @($staticTargets | Where-Object { $LiveNames -contains (Split-Path $_ -Leaf) })
}
if (-not $ScriptArgs) { $ScriptArgs = @('-ListOnly') }

Write-Output "mode : $(if ($ExpectDefective) { 'EXPECT DEFECTIVE (prove the harness can fail)' } else { 'every announced log must be written' })"

# --- assertion plumbing ------------------------------------------------------
$script:Pass = 0
$script:Fail = 0
function Assert {
    param([bool]$Condition, [string]$What)
    if ($Condition) { $script:Pass++; Write-Output "  [PASS] $What" }
    else            { $script:Fail++; Write-Output "  [FAIL] $What" }
}

# --- static: every Start-Transcript call carries -WhatIf:$false --------------
function Test-WhatIfOff {
    param([Management.Automation.Language.CommandAst]$Call)
    foreach ($e in $Call.CommandElements) {
        if ($e -is [Management.Automation.Language.CommandParameterAst] -and
            $e.ParameterName -eq 'WhatIf' -and
            $e.Argument -is [Management.Automation.Language.VariableExpressionAst] -and
            $e.Argument.VariablePath.UserPath -eq 'false') { return $true }
    }
    return $false
}

Write-Output ''
Write-Output 'Static: Start-Transcript calls'
$withTranscript = @()
foreach ($path in $staticTargets) {
    $leaf = Split-Path $path -Leaf
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { Assert $false "$leaf parses ($($errors.Count) errors)"; continue }
    $calls = @($ast.FindAll({
        param($n)
        $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Start-Transcript'
    }, $true))
    if (-not $calls.Count) {
        if ($ExpectDefective) { Assert $false "$leaf has a Start-Transcript call to be defective" }
        continue
    }
    $withTranscript += $path
    foreach ($c in $calls) {
        $where = '{0}:{1}' -f $leaf, $c.Extent.StartLineNumber
        if ($ExpectDefective) { Assert (-not (Test-WhatIfOff $c)) "$where lacks -WhatIf:`$false (defect present)" }
        else                  { Assert (Test-WhatIfOff $c) "$where carries -WhatIf:`$false" }
    }
}

# --- live: the announced log exists after a -WhatIf run ----------------------
$ps51 = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$probe = & {
    $ErrorActionPreference = 'Continue'
    & $ps51 -NoProfile -Command @'
$p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
'{0}|{1}|{2}' -f $PSVersionTable.PSVersion, $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator), ((Get-Command Start-Transcript).Parameters.Keys -contains 'WhatIf')
'@ 2>$null
}
$psVer, $elevated, $stWhatIf = ([string]($probe | Select-Object -Last 1)).Split('|')

Write-Output ''
Write-Output "Live: child is Windows PowerShell $psVer, elevated=$elevated, Start-Transcript has -WhatIf=$stWhatIf"
foreach ($path in $withTranscript) {
    if ($liveTargets -notcontains $path) {
        Write-Output "  [SKIP] $(Split-Path $path -Leaf): static only (not an unelevated -ListOnly script; pass -ScriptArgs to run it live)"
    }
}

$created = @()
try {
    foreach ($path in $liveTargets) {
        $leaf = Split-Path $path -Leaf
        Write-Output ''
        Write-Output "  $leaf $($ScriptArgs -join ' ') -WhatIf"
        $started = Get-Date
        # The child's stderr is folded into the output for diagnosis; under
        # 'Stop' Windows PowerShell would turn the first stderr line into a
        # terminating error.
        $out = & {
            $ErrorActionPreference = 'Continue'
            & $ps51 -NoProfile -ExecutionPolicy Bypass -File $path @ScriptArgs '-WhatIf' 2>&1 | ForEach-Object { "$_" }
        }
        Write-Output "    exit code $LASTEXITCODE"
        foreach ($l in @($out | Where-Object { $_ -match 'What if:.*Start-Transcript' })) {
            Write-Output "    preview: $($l.Trim())"
        }

        $announced = @($out | ForEach-Object {
            if ($_ -match 'Log(?: written to)?:\s+(.+\.log)\s*$') { $Matches[1].Trim() }
        } | Sort-Object -Unique)
        Assert ($announced.Count -gt 0) "$leaf announced a log path"
        if (-not $announced.Count) {
            Write-Output '    last lines of output:'
            $out | Select-Object -Last 15 | ForEach-Object { Write-Output "      $_" }
            continue
        }

        foreach ($log in $announced) {
            $exists = Test-Path -LiteralPath $log
            if ($ExpectDefective) {
                Assert (-not $exists) "$leaf announced $log and never wrote it (defect present)"
                continue
            }
            if (-not $exists) { Assert $false "$leaf wrote its announced log $log"; continue }
            $fi = Get-Item -LiteralPath $log
            $isTranscript = (Get-Content -LiteralPath $log -TotalCount 3 | Out-String) -match 'PowerShell transcript start'
            $fresh = $fi.LastWriteTime -ge $started.AddSeconds(-1)
            Assert ($isTranscript -and $fresh) ("{0} wrote its announced log {1} ({2} bytes, transcript={3}, written this run={4})" -f $leaf, $log, $fi.Length, $isTranscript, $fresh)
            if ($isTranscript -and $fresh) { $created += $log }
        }
    }
}
finally {
    foreach ($log in $created) { Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue }
}

Write-Output ''
Write-Output ("RESULT: {0} passed, {1} failed" -f $script:Pass, $script:Fail)
if ($script:Fail -gt 0) { exit 1 }
exit 0
