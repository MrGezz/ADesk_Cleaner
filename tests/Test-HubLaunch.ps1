<#
.SYNOPSIS
    Regression test for the hub's Preview and Run buttons: a click must start
    the script in its own console, Preview must change nothing, and Run must
    really clean.

.DESCRIPTION
    Drives the real hub window through UI Automation, the way a person does:
    starts hub\Start-Hub.ps1, types "Clean a directory" into the search box,
    points -RootPath at a throwaway folder under %TEMP% holding two *.bak
    files, a __pycache__ folder and two files that must survive, leaves "Run
    elevated" unticked, and clicks the buttons.

    Preview - a new powershell.exe must appear as a child of the hub within
    the timeout, its command line must name Clean-Directory.ps1, the fixture
    and -WhatIf, the fixture must be untouched, and the console must end with
    exit code 0 once Enter is sent to it.

    Run - a second child must appear without -WhatIf; "YES" is typed into its
    console (WriteConsoleInput through AttachConsole, from a helper process so
    this one keeps its own console), and the *.bak files and __pycache__ must
    then be gone while the two keepers remain, exit code 0.

    Nothing outside the fixture is touched: Clean-Directory only ever sees the
    fixture path, and the fixture is removed at the end.

    Run with -ExpectDefective against a pre-fix copy of the hub to prove this
    harness can fail: in that mode it passes only if neither click starts a
    console.

.PARAMETER HubPath
    The hub to drive. Default: hub\Start-Hub.ps1 beside tests\. A copy must sit
    in a folder named hub with catalog.json beside it and
    scripts\utility\Clean-Directory.ps1 one level up, as in the repository.

.PARAMETER ExpectDefective
    Prove-it-can-fail mode for a pre-fix copy: passes only if no click starts
    a console.

.PARAMETER TimeoutSec
    How long to wait for the hub window, for each console to appear and for
    each cleanup to finish. Default 20.

.EXAMPLE
    .\tests\Test-HubLaunch.ps1
    Opens the hub for about half a minute, clicks Preview then Run.
    Exit code 0 = all assertions hold.

.EXAMPLE
    $d = Join-Path $env:TEMP 'hub-prefix'
    New-Item -ItemType Directory "$d\hub", "$d\scripts\utility" -Force | Out-Null
    git show 0552317:hub/Start-Hub.ps1 | Set-Content "$d\hub\Start-Hub.ps1" -Encoding ASCII
    Copy-Item hub\catalog.json "$d\hub"; Copy-Item scripts\utility\Clean-Directory.ps1 "$d\scripts\utility"
    .\tests\Test-HubLaunch.ps1 -HubPath "$d\hub\Start-Hub.ps1" -ExpectDefective
    Confirms the harness detects the original defect (the buttons start nothing).

.NOTES
    Windows PowerShell 5.1 (relaunches itself there from PowerShell 7). Needs a
    desktop session and no elevation. Opens and closes visible windows; do not
    type into them while it runs.
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
    if ($HubPath)        { $fwd += @('-HubPath', $HubPath) }
    if ($ExpectDefective) { $fwd += '-ExpectDefective' }
    & $ps51 @fwd
    exit $LASTEXITCODE
}

if (-not $HubPath) { $HubPath = Join-Path $PSScriptRoot '..\hub\Start-Hub.ps1' }
if (-not (Test-Path -LiteralPath $HubPath)) { Write-Output "Cannot find the hub '$HubPath'."; exit 2 }
$HubPath = (Resolve-Path -LiteralPath $HubPath).ProviderPath

Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
$AE    = [System.Windows.Automation.AutomationElement]
$Scope = [System.Windows.Automation.TreeScope]

Write-Output "hub  : $HubPath"
Write-Output "mode : $(if ($ExpectDefective) { 'EXPECT DEFECTIVE (prove the harness can fail)' } else { 'Preview and Run must start the script and Run must clean' })"

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

function Get-ChildConsoles {
    param([int]$ParentId)
    @(Get-CimInstance Win32_Process -Filter "ParentProcessId = $ParentId AND Name = 'powershell.exe'")
}

# --- the fixture -------------------------------------------------------------
$work    = Join-Path $env:TEMP ('hub-launch-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
# A space in the path, as in most real project folders: the value travels
# single-quoted inside -Command "...", and a quoting slip shows up here first.
$fixture = Join-Path $work 'my project'
New-Item -ItemType Directory -Path (Join-Path $fixture 'sub\__pycache__') -Force | Out-Null
$junk    = @((Join-Path $fixture 'a.bak'), (Join-Path $fixture 'sub\b.bak'), (Join-Path $fixture 'sub\__pycache__\m.cpython-312.pyc'))
$keepers = @((Join-Path $fixture 'keep.txt'), (Join-Path $fixture 'sub\keep.py'))
foreach ($f in $junk + $keepers) { Set-Content -LiteralPath $f -Value 'x' -Encoding ASCII }
$pycache = Join-Path $fixture 'sub\__pycache__'

# Types a line into another process's console. Runs in its own process: a
# process can be attached to one console at a time, and this one keeps its own.
$typer = Join-Path $work 'Send-ConsoleLine.ps1'
Set-Content -LiteralPath $typer -Encoding ASCII -Value @'
param([int]$TargetPid, [string]$Line = '')
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class ConIn {
    [StructLayout(LayoutKind.Explicit, CharSet = CharSet.Unicode)]
    public struct INPUT_RECORD {
        [FieldOffset(0)]  public ushort EventType;
        [FieldOffset(4)]  public int    bKeyDown;
        [FieldOffset(8)]  public ushort wRepeatCount;
        [FieldOffset(10)] public ushort wVirtualKeyCode;
        [FieldOffset(12)] public ushort wVirtualScanCode;
        [FieldOffset(14)] public char   UnicodeChar;
        [FieldOffset(16)] public uint   dwControlKeyState;
    }
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool FreeConsole();
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool AttachConsole(uint pid);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern IntPtr CreateFileW(string name, uint access, uint share, IntPtr sa, uint disposition, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool WriteConsoleInputW(IntPtr h, INPUT_RECORD[] records, uint count, out uint written);
    public static int Send(uint pid, string text) {
        FreeConsole();
        if (!AttachConsole(pid)) return 10;
        IntPtr h = CreateFileW("CONIN$", 0xC0000000, 3, IntPtr.Zero, 3, 0, IntPtr.Zero);
        if (h == new IntPtr(-1)) return 11;
        INPUT_RECORD[] recs = new INPUT_RECORD[text.Length * 2];
        for (int i = 0; i < text.Length; i++) {
            char c = text[i];
            ushort vk = (ushort)(c == '\r' ? 0x0D : char.ToUpperInvariant(c));
            for (int k = 0; k < 2; k++) {
                INPUT_RECORD r = new INPUT_RECORD();
                r.EventType = 1; r.bKeyDown = (k == 0) ? 1 : 0; r.wRepeatCount = 1;
                r.wVirtualKeyCode = vk; r.UnicodeChar = c;
                recs[i * 2 + k] = r;
            }
        }
        uint written;
        bool ok = WriteConsoleInputW(h, recs, (uint)recs.Length, out written);
        CloseHandle(h);
        FreeConsole();
        return (ok && written == recs.Length) ? 0 : 12;
    }
}
"@
exit ([ConIn]::Send([uint32]$TargetPid, $Line + "`r"))
'@

function Send-ConsoleLine {
    param([int]$TargetPid, [string]$Line = '')
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $typer), '-TargetPid', $TargetPid)
    if ($Line) { $a += @('-Line', $Line) }
    (Start-Process -FilePath $ps51 -ArgumentList $a -WindowStyle Hidden -Wait -PassThru).ExitCode
}

# Clicks a button; reports the console it started (Started = $false if none)
# and what the hub's status bar said afterwards.
function Invoke-HubButton {
    param($Window, [int]$HubId, [string]$ButtonId)
    $before = @(Get-ChildConsoles $HubId | ForEach-Object { $_.ProcessId })
    $out = [pscustomobject]@{ Started = $false; Id = 0; CommandLine = ''; Process = $null; Status = '' }
    $btn = Find-ById $Window $ButtonId
    if (-not $btn) { $out.Status = "(no $ButtonId button)"; return $out }
    $btn.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    $child = Wait-Until { @(Get-ChildConsoles $HubId | Where-Object { $before -notcontains $_.ProcessId }) | Select-Object -First 1 }
    $status = Find-ById $Window 'TxtStatus'
    if ($status) { $out.Status = $status.Current.Name }
    if (-not $child) { return $out }
    $out.Started = $true
    $out.Id = [int]$child.ProcessId
    $out.CommandLine = "$($child.CommandLine)"
    $out.Process = Get-Process -Id $child.ProcessId -ErrorAction SilentlyContinue
    if ($out.Process) { [void]$out.Process.Handle }   # keep a handle so ExitCode is readable after it exits
    $out
}

function Close-Console {
    param($Console)
    $typed = Send-ConsoleLine -TargetPid $Console.Id
    $exited = $false
    if ($Console.Process) { $exited = $Console.Process.WaitForExit($TimeoutSec * 1000) }
    [pscustomobject]@{ Typed = $typed; Exited = $exited; ExitCode = $(if ($exited) { $Console.Process.ExitCode } else { $null }) }
}

# --- drive the hub -----------------------------------------------------------
$hub = $null
$consoles = @()
try {
    $hubArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-WindowStyle', 'Hidden', '-File', ('"{0}"' -f $HubPath))
    $hub = Start-Process -FilePath $ps51 -ArgumentList $hubArgs -PassThru
    $win = Wait-Until {
        $c = New-Object System.Windows.Automation.AndCondition(
            (New-Object System.Windows.Automation.PropertyCondition($AE::ProcessIdProperty, $hub.Id)),
            (New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, [System.Windows.Automation.ControlType]::Window)))
        $AE::RootElement.FindFirst($Scope::Children, $c)
    }
    Assert ($null -ne $win) "the hub window opened (pid $($hub.Id))"
    if (-not $win) { throw 'no hub window' }

    $search = Find-ById $win 'TxtSearch'
    $search.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue('Clean a directory')
    $picked = Wait-Until { $n = Find-ById $win 'TxtName'; if ($n -and $n.Current.Name -eq 'Clean a directory') { $n } }
    Assert ($null -ne $picked) 'searching selects "Clean a directory"'
    if (-not $picked) { throw 'script not selected' }

    $editCond = New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, [System.Windows.Automation.ControlType]::Edit)
    $params = @($win.FindAll($Scope::Descendants, $editCond) | Where-Object { $_.Current.AutomationId -notin 'TxtSearch', 'TxtCommand' })
    Assert ($params.Count -eq 1) "the form has one text field (-RootPath); found $($params.Count)"
    $params[0].GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue($fixture)

    $elev = (Find-ById $win 'ChkElevated').GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)
    if ($elev.Current.ToggleState -ne 'Off') { $elev.Toggle() }

    $cmdBox = Find-ById $win 'TxtCommand'
    $shown = Wait-Until { $v = $cmdBox.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value; if ($v -like "*$fixture*") { $v } } -Seconds 5
    Assert ($null -ne $shown) 'the command line shown names the fixture'

    # --- Preview ---
    Write-Output ''
    Write-Output 'Preview'
    $p = Invoke-HubButton -Window $win -HubId $hub.Id -ButtonId 'BtnPreview'
    Write-Output "    status bar: $($p.Status)"
    if ($p.Started) { $consoles += $p }
    if ($ExpectDefective) {
        Assert (-not $p.Started) 'Preview started no console (defect present)'
    } else {
        Assert $p.Started 'Preview started a console'
        if ($p.Started) {
            Assert ($p.CommandLine -like '*Clean-Directory.ps1*' -and $p.CommandLine -like "*$fixture*" -and $p.CommandLine -match '-WhatIf\b') 'its command line names the script, the fixture and -WhatIf'
            Start-Sleep -Seconds 3
            $gone = @($junk + $keepers | Where-Object { -not (Test-Path -LiteralPath $_) })
            Assert ($gone.Count -eq 0) "Preview deleted nothing ($($gone.Count) file(s) missing)"
            $c = Close-Console $p
            Assert ($c.Typed -eq 0 -and $c.Exited -and $c.ExitCode -eq 0) "Preview console closed on Enter with exit code 0 (typed=$($c.Typed) exited=$($c.Exited) code=$($c.ExitCode))"
        }
    }

    # --- Run ---
    Write-Output ''
    Write-Output 'Run'
    $r = Invoke-HubButton -Window $win -HubId $hub.Id -ButtonId 'BtnRun'
    Write-Output "    status bar: $($r.Status)"
    if ($r.Started) { $consoles += $r }
    if ($ExpectDefective) {
        Assert (-not $r.Started) 'Run started no console (defect present)'
        $left = @($junk | Where-Object { Test-Path -LiteralPath $_ })
        Assert ($left.Count -eq $junk.Count) 'Run cleaned nothing (defect present)'
    } else {
        Assert $r.Started 'Run started a console'
        if ($r.Started) {
            Assert ($r.CommandLine -like '*Clean-Directory.ps1*' -and $r.CommandLine -like "*$fixture*" -and $r.CommandLine -notmatch '-WhatIf\b') 'its command line names the script and the fixture, without -WhatIf'
            Start-Sleep -Seconds 2
            $typed = Send-ConsoleLine -TargetPid $r.Id -Line 'YES'
            Assert ($typed -eq 0) "typed YES into the Run console (helper exit $typed)"
            $cleaned = Wait-Until { -not (@($junk | Where-Object { Test-Path -LiteralPath $_ }).Count) -and -not (Test-Path -LiteralPath $pycache) }
            Assert ([bool]$cleaned) 'Run deleted both *.bak files and the __pycache__ folder'
            $kept = @($keepers | Where-Object { Test-Path -LiteralPath $_ })
            Assert ($kept.Count -eq $keepers.Count) "Run kept the other files ($($kept.Count) of $($keepers.Count))"
            $c = Close-Console $r
            Assert ($c.Typed -eq 0 -and $c.Exited -and $c.ExitCode -eq 0) "Run console closed on Enter with exit code 0 (typed=$($c.Typed) exited=$($c.Exited) code=$($c.ExitCode))"
        }
    }
}
catch {
    Assert $false "harness error: $($_.Exception.Message)"
}
finally {
    foreach ($c in $consoles) { Stop-Process -Id $c.Id -Force -ErrorAction SilentlyContinue }
    if ($hub) {
        foreach ($k in @(Get-ChildConsoles $hub.Id)) { Stop-Process -Id $k.ProcessId -Force -ErrorAction SilentlyContinue }
        Stop-Process -Id $hub.Id -Force -ErrorAction SilentlyContinue
    }
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output ''
Write-Output ("RESULT: {0} passed, {1} failed" -f $script:Pass, $script:Fail)
if ($script:Fail -gt 0) { exit 1 }
exit 0
