<#
.SYNOPSIS
    Unelevated regression test for Clean-AudioDevices.ps1: the endpoint and
    per-app classifiers, the key-path guard, the command-line prologue, and the
    pure helpers of the -Clean and -Restore runs. Never touches a real audio key.

.DESCRIPTION
    Lifts every function out of the script under test by AST, so the script's
    main block never runs, and drives the pure functions with synthetic records.
    Sections that need a child process or the real registry say so in their
    heading; they only ever read real state, and they write only under
    HKCU\Software\IczAudioTest and %LOCALAPPDATA%\IczAudio*, which the finally
    block removes.

    The classifier decides which audio endpoints get deleted from a key that
    Administrators cannot normally delete, so the test that guards it has to be
    shown able to fail: -ExpectDefective swaps in a classifier that removes every
    not-present endpoint regardless of bus or container. The run must then FAIL
    on the removable-bus, external, unknown-bus and malformed cases.

.PARAMETER ScriptPath
    The script under test. Defaults to scripts\windows\Clean-AudioDevices.ps1
    relative to the repository root.

.PARAMETER ExpectDefective
    Prove-it-can-fail mode: replaces Get-AudioEndpointVerdict with a defective
    one. A correct harness exits 1 in this mode.

.EXAMPLE
    .\tests\Test-AudioEndpointClassifier.ps1
    Exit code 0 = every assertion holds.

.EXAMPLE
    .\tests\Test-AudioEndpointClassifier.ps1 -ExpectDefective
    Must exit 1: proves the classifier assertions can fail.

.NOTES
    Windows PowerShell 5.1 or PowerShell 7. No elevation.
#>
# The lifted functions read harness variables through dynamic scoping, which the
# analyzer cannot see.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '')]
[CmdletBinding()]
param(
    [string]$ScriptPath,
    [switch]$ExpectDefective
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# --- locate the script under test -------------------------------------------
if (-not $ScriptPath) { $ScriptPath = Join-Path $PSScriptRoot '..\scripts\windows\Clean-AudioDevices.ps1' }
if (-not (Test-Path -LiteralPath $ScriptPath)) {
    Write-Output "Cannot find the script under test: $ScriptPath. Pass -ScriptPath."
    exit 2
}
$ScriptPath = (Resolve-Path -LiteralPath $ScriptPath).ProviderPath
Write-Output "script under test : $ScriptPath"
Write-Output "mode              : $(if ($ExpectDefective) { 'EXPECT DEFECTIVE (prove the harness can fail)' } else { 'classifier must hold' })"

# --- assertion plumbing ------------------------------------------------------
# Each check is a scriptblock evaluated inside try/catch, so a function that
# does not exist yet, or one that throws, is a FAIL rather than the end of the run.
$script:Pass = 0
$script:Fail = 0
function Check {
    param([string]$What, [scriptblock]$Condition)
    $checkOk = $false; $checkErr = $null
    try { $checkOk = [bool](& $Condition) } catch { $checkErr = $_.Exception.Message }
    $ok = $checkOk; $err = $checkErr
    if ($ok) { $script:Pass++; Write-Output "  [PASS] $What" }
    else {
        $script:Fail++
        if ($err) { Write-Output "  [FAIL] $What  ($err)" } else { Write-Output "  [FAIL] $What" }
    }
}
function Section { param([string]$Title) Write-Output ''; Write-Output $Title }
# Every scratch key or folder a section creates is registered here first.
$script:Cleanup = [System.Collections.Generic.List[string]]::new()

# --- lift the functions out of the script under test ------------------------
$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$tokens, [ref]$errors)
if ($errors.Count) { Write-Output "script under test does not parse: $($errors[0].Message)"; exit 2 }
$funcs = @($ast.EndBlock.Statements | Where-Object { $_ -is [System.Management.Automation.Language.FunctionDefinitionAst] })
Write-Output ("functions lifted  : {0}" -f $funcs.Count)
if ($funcs.Count) { . ([scriptblock]::Create((($funcs | ForEach-Object { $_.Extent.Text }) -join "`r`n"))) }

if ($ExpectDefective) {
    # The defect this harness exists to catch: deciding on the state alone.
    function Get-AudioEndpointVerdict {
        param($Record, $Context)
        if ($null -ne $Record -and $null -ne $Record.State -and (([int64]$Record.State) -band 0xF) -eq 4) {
            return [pscustomobject]@{ Action = 'Remove'; Label = 'defective'; Reason = 'not present' }
        }
        [pscustomobject]@{ Action = 'Keep'; Label = 'live'; Reason = 'defective classifier' }
    }
}

# --- fixtures ----------------------------------------------------------------
$Internal = '{00000000-0000-0000-FFFF-FFFFFFFFFFFF}'
$KsAudio  = '{6994ad04-93ef-11d0-a3cc-00a0c9223196}'
$E = "\\?\hdaudio#a#$KsAudio\topo00"
$L = "\\?\hdaudio#a#$KsAudio\topo01"
$G = "\\?\hdaudio#a#$KsAudio\topo09"
$RenderRoot = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio'
$SampleGuid = '{e12c921b-73dd-465e-92fd-9994fdd194b6}'

function New-Rec {
    param([hashtable]$Over = @{})
    $r = [ordered]@{
        Flow = 'Render'; Guid = '{00000000-0000-0000-0000-000000000001}'
        KeyPath = "$RenderRoot\Render\{00000000-0000-0000-0000-000000000001}"
        State = [uint32]4; Name = 'Speakers'; InterfaceName = 'Realtek(R) Audio'
        ParentId = 'HDAUDIO\FUNC_01&VEN_10EC\5&0&0001'; ParentExists = $true; ParentBus = 'HDAUDIO'
        ParentContainerId = $Internal; InterfaceRefs = @(); SwdId = $null
    }
    foreach ($k in $Over.Keys) { $r[$k] = $Over[$k] }
    [pscustomobject]$r
}
function New-AppRec {
    param([hashtable]$Over = @{})
    $r = [ordered]@{ Name = '1027dac7_0'; Value = $null; ValueCount = 1; SubKeyCount = 0; SubKeyNames = @(); SubKeyShapeOk = $true; Bus = $null; HardwareId = $null }
    foreach ($k in $Over.Keys) { $r[$k] = $Over[$k] }
    [pscustomobject]$r
}
function Vd { param([string]$A, [string]$L) [pscustomobject]@{ Action = $A; Label = $L; Reason = 'fixture' } }

$ctx = $null; $ctxUnknown = $null
try {
    $liveRec    = New-Rec @{ State = [uint32]1; Guid = '{00000000-0000-0000-0000-000000000002}'; InterfaceRefs = @($L) }
    $ctx        = New-AudioClassifierContext -Records @($liveRec) -EnabledInterfaces @($E, $L)
    $ctxUnknown = New-AudioClassifierContext -Records @($liveRec) -EnabledInterfaces $null
}
catch { $script:Fail++; Write-Output "  [FAIL] fixture contexts ($($_.Exception.Message))" }
function V {
    param($R, $C)
    if ($null -eq $C) { $C = $ctx }
    Get-AudioEndpointVerdict -Record $R -Context $C
}

try {
    # --- 1. endpoint state -------------------------------------------------------
    Section '1. Endpoint state (low 4 bits of DeviceState):'
    foreach ($s in 1, 2, 8, 0x10000001, 0x10000008) {
        Check ("state 0x{0:X} -> Keep live" -f $s) { (V (New-Rec @{ State = [uint32]$s })).Label -eq 'live' }
    }
    foreach ($s in $null, 0, 3, 0x10) {
        Check "state '$s' -> Keep malformed" { (V (New-Rec @{ State = $s })).Label -eq 'malformed' }
    }
    Check 'null record -> Keep malformed' { (Get-AudioEndpointVerdict -Record $null -Context $ctx).Label -eq 'malformed' }
    Check 'high bits are ignored: 0x20000004 is not present' { (V (New-Rec @{ State = [uint32]0x20000004 })).Action -eq 'Remove' }

    # --- 2. parent ---------------------------------------------------------------
    Section '2. Parent device:'
    Check 'no parent link -> Keep malformed' { (V (New-Rec @{ ParentId = $null })).Label -eq 'malformed' }
    Check 'parent gone (even on USB) -> Remove orphaned' { (V (New-Rec @{ ParentExists = $false; ParentBus = 'USB' })).Label -eq 'orphaned' }
    Check 'orphaned survives unknown interfaces' { (V (New-Rec @{ ParentExists = $false }) $ctxUnknown).Label -eq 'orphaned' }
    foreach ($b in 'USB', 'BTHENUM', 'BTHHFENUM', 'BTHLEDEVICE', 'ROOT', 'SW', 'SWD', 'root') {
        Check "$b parent exists -> Keep removable-not-connected" { (V (New-Rec @{ ParentBus = $b })).Label -eq 'removable-not-connected' }
    }
    foreach ($b in 'FOO', $null) {
        Check "bus '$b' -> Keep unknown-bus" { (V (New-Rec @{ ParentBus = $b })).Label -eq 'unknown-bus' }
    }
    foreach ($c in '{8A2E1D3C-0000-4000-8000-000000000000}', $null) {
        Check "container '$c' -> Keep external-not-connected" { (V (New-Rec @{ ParentContainerId = $c })).Label -eq 'external-not-connected' }
    }
    Check 'internal container in lower case is internal' { (V (New-Rec @{ ParentContainerId = $Internal.ToLower() })).Action -eq 'Remove' }

    # --- 3. labels on a fixed-bus internal parent -----------------------------
    Section '3. Labels (fixed bus, internal parent):'
    Check 'no refs -> Remove no-interface-recorded' { (V (New-Rec @{ InterfaceRefs = @() })).Label -eq 'no-interface-recorded' }
    Check 'enabled, unheld -> Remove port-still-exposed' { (V (New-Rec @{ InterfaceRefs = @($E) })).Label -eq 'port-still-exposed' }
    Check 'held by a live endpoint -> Remove duplicate' { (V (New-Rec @{ InterfaceRefs = @($L) })).Label -eq 'duplicate' }
    Check 'not enabled, unheld -> Remove interface-gone' { (V (New-Rec @{ InterfaceRefs = @($G) })).Label -eq 'interface-gone' }
    Check 'ref comparison ignores case' { (V (New-Rec @{ InterfaceRefs = @($E.ToUpper()) })).Label -eq 'port-still-exposed' }
    Check 'unknown enabled set -> Remove unknown' { (V (New-Rec @{ InterfaceRefs = @($E) }) $ctxUnknown).Label -eq 'unknown' }
    Check 'every fixed/internal not-present label is Remove' { (V (New-Rec @{ InterfaceRefs = @($G) })).Action -eq 'Remove' }
    Check 'verdict carries a reason' { -not [string]::IsNullOrWhiteSpace((V (New-Rec @{ ParentExists = $false })).Reason) }
    # Measured on the first live run: Realtek's multi-jack endpoints record no
    # interface, yet the driver still exposes them and Windows rebuilt all ten.
    # The ones built by the generic driver stayed gone. The driver name tells them apart.
    Check 'no refs, built by the current driver -> port-still-exposed' { (V (New-Rec @{ InterfaceRefs = @(); InterfaceName = 'Realtek(R) Audio'; ParentName = 'realtek(r) audio' })).Label -eq 'port-still-exposed' }
    Check 'no refs, built by another driver -> no-interface-recorded' { (V (New-Rec @{ InterfaceRefs = @(); InterfaceName = 'High Definition Audio Device'; ParentName = 'Realtek(R) Audio' })).Label -eq 'no-interface-recorded' }
    Check 'no refs, parent name unknown -> no-interface-recorded' { (V (New-Rec @{ InterfaceRefs = @(); InterfaceName = 'Realtek(R) Audio'; ParentName = $null })).Label -eq 'no-interface-recorded' }
    Check 'resource string resolves to its text' { (ConvertFrom-PnpResourceString '@oem17.inf,%ExtendedFriendlyName%;Realtek(R) Audio') -ceq 'Realtek(R) Audio' }
    Check 'plain string is returned as is' { (ConvertFrom-PnpResourceString 'Realtek High Definition Audio') -ceq 'Realtek High Definition Audio' }
    Check 'null resource string -> null' { $null -eq (ConvertFrom-PnpResourceString $null) }

    # --- 4. selection ------------------------------------------------------------
    Section '4. Selection (-KeepExposedPorts):'
    Check 'exposed kept with -KeepExposedPorts' { -not (Test-AudioRemovalSelected (Vd 'Remove' 'port-still-exposed') -KeepExposedPorts) }
    Check 'unknown kept with -KeepExposedPorts' { -not (Test-AudioRemovalSelected (Vd 'Remove' 'unknown') -KeepExposedPorts) }
    Check 'duplicate still selected with -KeepExposedPorts' { Test-AudioRemovalSelected (Vd 'Remove' 'duplicate') -KeepExposedPorts }
    Check 'exposed selected by default' { Test-AudioRemovalSelected (Vd 'Remove' 'port-still-exposed') }
    Check 'Keep is never selected' { -not (Test-AudioRemovalSelected (Vd 'Keep' 'live')) }
    Check 'null verdict is never selected' { -not (Test-AudioRemovalSelected $null) }

    # --- 5. key-path guard -------------------------------------------------------
    Section '5. Endpoint key-path guard:'
    # Loop variables must not reuse Check's own names ($What, $Condition,
    # $checkOk, $checkErr): the scriptblock runs inside Check and would see them.
    foreach ($goodPath in "$RenderRoot\Render\$SampleGuid", "$RenderRoot\Capture\$SampleGuid", "$RenderRoot\Render\$($SampleGuid.ToUpper())") {
        Check "accepts $goodPath" { Test-AudioEndpointKeyPath -Path $goodPath }
    }
    $refused = @(
        "$RenderRoot\Render", $RenderRoot, "$RenderRoot\Render\$SampleGuid\Properties", "$RenderRoot\Render\$SampleGuid\",
        "$RenderRoot\Render\e12c921b-73dd-465e-92fd-9994fdd194b6", "HKLM:\SOFTWARE\IczAudioMechanismTest\Render\$SampleGuid",
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\Render\$SampleGuid", "$RenderRoot\Other\$SampleGuid", '')
    foreach ($bad in $refused) { Check "refuses '$bad'" { -not (Test-AudioEndpointKeyPath -Path $bad) } }
    Check 'refuses $null' { -not (Test-AudioEndpointKeyPath -Path $null) }

    # --- 6. per-app settings ---------------------------------------------------
    Section '6. Per-app settings:'
    $vB = '{2}.\\?\hdaudio#func_01&ven_10de&dev_009d&subsys_10431adc&rev_1001#{6994ad04-93ef-11d0-a3cc-00a0c9223196}\topo01/00010001|#%b{A9EF3FD9-4240-455E-A4D5-F2B3301887B2}'
    Check 'parses bus + hardware id' {
        $p = ConvertFrom-AppAudioDevicePath $vB
        $p.Bus -eq 'hdaudio' -and $p.HardwareId -eq 'func_01&ven_10de&dev_009d&subsys_10431adc&rev_1001'
    }
    Check 'parse lower-cases' { (ConvertFrom-AppAudioDevicePath $vB.ToUpper().Replace('{2}.\\?\', '{2}.\\?\')).Bus -ceq 'hdaudio' }
    foreach ($bad in $null, '', 'garbage', '{2}.SWD\x') {
        Check "unparseable '$bad' -> null" { $null -eq (ConvertFrom-AppAudioDevicePath $bad) }
    }
    $present = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    [void]$present.Add('HDAUDIO\FUNC_01&VEN_10EC&DEV_0897&SUBSYS_1458A194&REV_1005')
    $cases = @(
        @{ W = 'A: present hdaudio -> Keep hardware-present'; Rec = (New-AppRec @{ Value = "{2}.\\?\hdaudio#func_01&ven_10ec&dev_0897&subsys_1458a194&rev_1005#$KsAudio\rtmicintopo/00010001|\Device\HarddiskVolume3\x.exe" }); Label = 'hardware-present'; Action = 'Keep' }
        @{ W = 'B: absent hdaudio -> Remove hardware-gone'; Rec = (New-AppRec @{ Value = $vB }); Label = 'hardware-gone'; Action = 'Remove' }
        @{ W = 'C: absent intelaudio -> Remove hardware-gone'; Rec = (New-AppRec @{ Value = "{2}.\\?\intelaudio#func_01&ven_10ec&dev_0285&subsys_10431c92&rev_1000#$KsAudio\rtmicinssttopo/00010001|#%b{A9EF3FD9-4240-455E-A4D5-F2B3301887B2}" }); Label = 'hardware-gone'; Action = 'Remove' }
        @{ W = 'D: usb -> Keep not-fixed-bus'; Rec = (New-AppRec @{ Value = "{2}.\\?\usb#vid_2207&pid_a007&mi_02#$KsAudio\x/00010001|app.exe" }); Label = 'not-fixed-bus'; Action = 'Keep' }
        @{ W = 'E: bthenum -> Keep not-fixed-bus'; Rec = (New-AppRec @{ Value = "{2}.\\?\bthenum#{0000110b-0000-1000-8000-00805f9b34fb}_vid&000105d6_pid&000a#$KsAudio\x|app.exe" }); Label = 'not-fixed-bus'; Action = 'Keep' }
        @{ W = 'F: two values -> Keep unexpected-shape'; Rec = (New-AppRec @{ Value = $vB; ValueCount = 2 }); Label = 'unexpected-shape'; Action = 'Keep' }
        @{ W = 'G: an unknown subkey -> Keep unexpected-shape'; Rec = (New-AppRec @{ Value = $vB; SubKeyCount = 1; SubKeyNames = @('{00000000-1111-2222-3333-444444444444}') }); Label = 'unexpected-shape'; Action = 'Keep' }
        @{ W = 'G2: the volume subkey -> still Remove hardware-gone'; Rec = (New-AppRec @{ Value = $vB; SubKeyCount = 1; SubKeyNames = @('{219ed5a0-9cbf-4f3a-b927-37c9e5c5f14f}') }); Label = 'hardware-gone'; Action = 'Remove' }
        @{ W = 'G3: the volume subkey with nested keys or odd values -> Keep unexpected-shape'; Rec = (New-AppRec @{ Value = $vB; SubKeyCount = 1; SubKeyNames = @('{219ED5A0-9CBF-4F3A-B927-37C9E5C5F14F}'); SubKeyShapeOk = $false }); Label = 'unexpected-shape'; Action = 'Keep' }
        @{ W = 'G4: two subkeys -> Keep unexpected-shape'; Rec = (New-AppRec @{ Value = $vB; SubKeyCount = 2; SubKeyNames = @('{219ED5A0-9CBF-4F3A-B927-37C9E5C5F14F}', 'x') }); Label = 'unexpected-shape'; Action = 'Keep' }
        @{ W = 'H: garbage -> Keep unparseable'; Rec = (New-AppRec @{ Value = 'garbage' }); Label = 'unparseable'; Action = 'Keep' }
        @{ W = 'I: no value -> Keep unexpected-shape'; Rec = (New-AppRec @{ Value = $null }); Label = 'unexpected-shape'; Action = 'Keep' }
    )
    foreach ($c in $cases) {
        Check $c.W {
            $v = Get-AppAudioSettingVerdict -Record $c.Rec -PresentPrefixes $present
            $v.Label -eq $c.Label -and $v.Action -eq $c.Action
        }
    }
    Check 'null record -> Keep unexpected-shape' { (Get-AppAudioSettingVerdict -Record $null -PresentPrefixes $present).Action -eq 'Keep' }

    # --- 7. Get-Prop / bus class ----------------------------------------------
    Section '7. Helpers:'
    Check 'Get-Prop on $null -> $null' { $null -eq (Get-Prop -Obj $null -Name 'x') }
    Check 'Get-Prop on a missing property -> $null' { $null -eq (Get-Prop -Obj ([pscustomobject]@{ a = 1 }) -Name 'b') }
    Check 'Get-Prop reads a property' { (Get-Prop -Obj ([pscustomobject]@{ a = 1 }) -Name 'a') -eq 1 }
    Check 'bus class HDAUDIO -> Fixed' { (Get-AudioBusClass -Bus 'hdaudio') -eq 'Fixed' }
    Check 'bus class BTHLEDevice -> Removable' { (Get-AudioBusClass -Bus 'BTHLEDevice') -eq 'Removable' }
    Check 'bus class $null -> Unknown' { (Get-AudioBusClass -Bus $null) -eq 'Unknown' }

    # --- 8. CLI, pure --------------------------------------------------------
    Section '8. Command line (pure):'
    Check '-Clean + -Restore refused' { (Get-AudioCleanerModeError -Clean $true -Restore 'x' -ListOnly $false -KeepExposedPorts $false -SkipAppSettings $false) -match 'together' }
    Check '-ListOnly + -Clean refused' { [bool](Get-AudioCleanerModeError -Clean $true -Restore '' -ListOnly $true -KeepExposedPorts $false -SkipAppSettings $false) }
    Check '-ListOnly + -Restore refused' { [bool](Get-AudioCleanerModeError -Clean $false -Restore 'x' -ListOnly $true -KeepExposedPorts $false -SkipAppSettings $false) }
    Check '-KeepExposedPorts alone refused' { (Get-AudioCleanerModeError -Clean $false -Restore '' -ListOnly $false -KeepExposedPorts $true -SkipAppSettings $false) -match '-Clean' }
    Check '-SkipAppSettings alone refused' { (Get-AudioCleanerModeError -Clean $false -Restore '' -ListOnly $false -KeepExposedPorts $false -SkipAppSettings $true) -match '-Clean' }
    Check 'valid combination -> no error' { $null -eq (Get-AudioCleanerModeError -Clean $true -Restore '' -ListOnly $false -KeepExposedPorts $true -SkipAppSettings $true) }
    Check 'no switches -> no error' { $null -eq (Get-AudioCleanerModeError -Clean $false -Restore '' -ListOnly $false -KeepExposedPorts $false -SkipAppSettings $false) }
    Check 'single quote doubled' { (ConvertTo-PsSingleQuoted "O'Brien") -ceq "'O''Brien'" }

    $sp = "C:\Users\O'Brien\My Scripts\Clean-AudioDevices.ps1"
    $relay = $null; $cmd = ''
    try {
        $relay = @(Get-AudioRelayArguments -Bound @{ Clean = $true; BackupPath = "C:\Users\O'Brien\My Backups"; TargetSid = 'S-1-5-21-1'; Confirm = $false } -WhatIfRequested $true -VerboseRequested $false)
        $cmd = New-AudioElevationCommand -ScriptPath $sp -RelayArguments $relay
    }
    catch { Write-Output "  (relay fixture: $($_.Exception.Message))" }
    Check 'script path single-quoted, apostrophe doubled' { $cmd.StartsWith("& 'C:\Users\O''Brien\My Scripts\Clean-AudioDevices.ps1' ") }
    Check 'ends with ; exit $LASTEXITCODE' { $cmd.EndsWith('; exit $LASTEXITCODE') }
    Check 'backup path relayed and quoted' { $cmd -like "*-BackupPath 'C:\Users\O''Brien\My Backups'*" }
    Check 'TargetSid relayed' { $cmd -like "*-TargetSid 'S-1-5-21-1'*" }
    Check '-Clean relayed' { $cmd -match '(?<=\s)-Clean(?=\s)' }
    Check '-Confirm:$false relayed' { $cmd -like '*-Confirm:$false*' }
    Check 'unbound switches not relayed' { $cmd -ne '' -and $cmd -notmatch '-KeepExposedPorts|-SkipAppSettings|-Force' }
    Check '-WhatIf present when requested' { Test-WhatIfRelayed -Command $cmd -WhatIfRequested $true }
    Check 'missing -WhatIf detected' { -not (Test-WhatIfRelayed -Command ($cmd -replace ' -WhatIf', '') -WhatIfRequested $true) }
    Check 'not requested -> relayed is vacuously true' { Test-WhatIfRelayed -Command '& x' -WhatIfRequested $false }
    Check '-WhatIf not relayed when not requested' {
        $c2 = New-AudioElevationCommand -ScriptPath $sp -RelayArguments @(Get-AudioRelayArguments -Bound @{ Clean = $true } -WhatIfRequested $false -VerboseRequested $false)
        $c2 -notmatch '-WhatIf'
    }

    # --- 10. native-layer guards (pure) ---------------------------------------
    Section '10. Registry mechanism guards (pure):'
    Check 'native layer compiles under this host' { Initialize-IczAudioNative; [bool]('IczAudioNative' -as [type]) }
    Check 'HKLM:\ path -> subkey' { (ConvertTo-HklmSubKey -Path "$RenderRoot\Render\$SampleGuid") -eq "SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\Render\$SampleGuid" }
    Check 'HKCU:\ path -> null' { $null -eq (ConvertTo-HklmSubKey -Path 'HKCU:\Software\x') }
    Check 'empty path -> null' { $null -eq (ConvertTo-HklmSubKey -Path '') }
    $mmSub = 'SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio'
    foreach ($goodSub in "$mmSub\Render\$SampleGuid", "$mmSub\Capture\$SampleGuid", 'SOFTWARE\IczAudioMechanismTest', 'SOFTWARE\IczAudioMechanismTest\Render\{11111111-2222-3333-4444-555555555555}') {
        Check "mechanism root accepts $goodSub" { Test-AudioMechanismRoot -SubKey $goodSub }
    }
    foreach ($badSub in "$mmSub\Render", $mmSub, "$mmSub\Render\$SampleGuid\Properties", 'SOFTWARE\Microsoft', 'SOFTWARE\IczAudioMechanismTestX', 'SOFTWARE\IczAudioMechanismTest\', '', 'SYSTEM\CurrentControlSet') {
        Check "mechanism root refuses '$badSub'" { -not (Test-AudioMechanismRoot -SubKey $badSub) }
    }

    Check 'render SWD id' { (Get-SwdInstanceId -Flow 'Render' -Guid '{0051f3f7-b063-42ca-a16a-6be175be56d8}') -eq 'SWD\MMDEVAPI\{0.0.0.00000000}.{0051f3f7-b063-42ca-a16a-6be175be56d8}' }
    Check 'capture SWD id' { (Get-SwdInstanceId -Flow 'Capture' -Guid '{dcc07c43-9dfe-4e6a-9411-fe2ae0b9543e}') -eq 'SWD\MMDEVAPI\{0.0.1.00000000}.{dcc07c43-9dfe-4e6a-9411-fe2ae0b9543e}' }
    Check 'bad flow -> null' { $null -eq (Get-SwdInstanceId -Flow 'Other' -Guid '{dcc07c43-9dfe-4e6a-9411-fe2ae0b9543e}') }
    Check 'bad guid -> null' { $null -eq (Get-SwdInstanceId -Flow 'Render' -Guid 'x\..\y') }

    # --- 13. the -Clean run: pure helpers and guarded actors (stubbed) ----------
    Section '13. Clean run (pure helpers; actors with stubbed registry):'
    Check 'only running dependents are restarted' {
        (@(Get-AudioServicesToRestart -Dependents @([pscustomobject]@{ Name = 'Audiosrv'; Status = 'Running' }, [pscustomobject]@{ Name = 'midisrv'; Status = 'Stopped' })) -join ',') -eq 'Audiosrv'
    }
    Check 'no dependents -> nothing to restart' { @(Get-AudioServicesToRestart -Dependents @()).Count -eq 0 }
    $gR  = '{00000000-0000-0000-0000-0000000000a1}'; $gK = '{00000000-0000-0000-0000-0000000000a2}'
    $removedR = New-Rec @{ Guid = $gR; InterfaceRefs = @($E); ParentId = 'HDAUDIO\P\1'; Name = 'Digital Output' }
    $keptK    = New-Rec @{ Guid = $gK; State = [uint32]1; InterfaceRefs = @($L) }
    $n1 = New-Rec @{ Guid = '{00000000-0000-0000-0000-0000000000b1}'; InterfaceRefs = @($E.ToUpper()) }
    $n2 = New-Rec @{ Guid = '{00000000-0000-0000-0000-0000000000b2}'; InterfaceRefs = @($G); ParentId = 'HDAUDIO\Q\1'; Name = 'Other' }
    $n3 = New-Rec @{ Guid = '{00000000-0000-0000-0000-0000000000b3}'; InterfaceRefs = @(); ParentId = 'HDAUDIO\P\1'; Name = 'Digital Output' }
    Check 'a new id on a removed endpoint''s interface is a rebuild' { $f = @(Find-RebuiltAudioEndpoint -Removed @($removedR) -BeforeGuids @($gR, $gK) -After @($keptK, $n1)); $f.Count -eq 1 -and $f[0].Guid -eq $n1.Guid }
    Check 'an unrelated new endpoint is not a rebuild' { @(Find-RebuiltAudioEndpoint -Removed @($removedR) -BeforeGuids @($gR, $gK) -After @($keptK, $n2)).Count -eq 0 }
    Check 'same flow + parent + name is a rebuild' { @(Find-RebuiltAudioEndpoint -Removed @($removedR) -BeforeGuids @($gR, $gK) -After @($keptK, $n3)).Count -eq 1 }
    Check 'an id that existed before is never a rebuild' { @(Find-RebuiltAudioEndpoint -Removed @($removedR) -BeforeGuids @($gR, $gK, $n1.Guid) -After @($n1)).Count -eq 0 }
    Check 'outcome: clean run has no problems' { @(Get-AudioOutcomeProblems -RemovedGuids @($gR) -Kept @($keptK) -After @($keptK)).Count -eq 0 }
    Check 'outcome: a removed id still present is a problem' { @(Get-AudioOutcomeProblems -RemovedGuids @($gR) -Kept @($keptK) -After @($keptK, $removedR)).Count -eq 1 }
    Check 'outcome: a kept endpoint gone is a problem' { @(Get-AudioOutcomeProblems -RemovedGuids @($gR) -Kept @($keptK) -After @()).Count -eq 1 }
    Check 'outcome: an active endpoint no longer active is a problem' { @(Get-AudioOutcomeProblems -RemovedGuids @() -Kept @($keptK) -After @((New-Rec @{ Guid = $gK; State = [uint32]8 }))).Count -eq 1 }

    # Review Focus 1: a device that reconnects between census and deletion.
    # The stubs live in a child scope, so they shadow the real functions only here.
    & {
        $script:DeleteCalls = 0
        function Get-AudioEndpointRecord { param($Flow, $Guid) New-Rec @{ Guid = $Guid; Flow = $Flow; State = [uint32]8 } }
        function Remove-RegistryTreeBackupSemantics { param($SubKey) $script:DeleteCalls++; [pscustomobject]@{ Ok = $true; Code = 0; Message = 'stub' } }
        $target = New-Rec @{ Guid = $SampleGuid; KeyPath = "$RenderRoot\Render\$SampleGuid"; InterfaceRefs = @($G) }
        Check 'reconnected since census -> Skipped, nothing deleted' {
            $r = Remove-AudioEndpointKey -Record $target -Context $ctx
            $r.Result -eq 'Skipped' -and $r.Reason -like 'changed since census*' -and $script:DeleteCalls -eq 0
        }
        Check 'a key path outside MMDevices -> Refused, nothing deleted' {
            $r = Remove-AudioEndpointKey -Record (New-Rec @{ Guid = $SampleGuid; KeyPath = "HKLM:\SOFTWARE\IczAudioMechanismTest\Render\$SampleGuid" }) -Context $ctx
            $r.Result -eq 'Refused' -and $script:DeleteCalls -eq 0
        }
        Check 'a KeyPath that disagrees with Flow/Guid -> Refused' {
            $r = Remove-AudioEndpointKey -Record (New-Rec @{ Guid = '{00000000-0000-0000-0000-000000000009}'; KeyPath = "$RenderRoot\Render\$SampleGuid" }) -Context $ctx
            $r.Result -eq 'Refused' -and $script:DeleteCalls -eq 0
        }
    }
    # Review Focus 4: the target user's hive is not loaded.
    Check 'hive not loaded -> per-app setting Skipped, no throw' {
        $r = Remove-AppAudioSetting -Record (New-AppRec @{ Value = $vB }) -TargetSid 'S-1-5-21-0-0-0-9999' -PresentPrefixes $present
        $r.Result -eq 'Skipped' -and $r.Reason -match 'hive not loaded'
    }
    Check 'a per-app name with a backslash -> Refused' {
        $r = Remove-AppAudioSetting -Record (New-AppRec @{ Name = '..\x'; Value = $vB }) -TargetSid ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value) -PresentPrefixes $present
        $r.Result -eq 'Refused'
    }

    # --- 14. -Restore: manifest checks and per-app restore -----------------------
    Section '14. Restore (manifest checks; per-app restore into the HKCU scratch key):'
    $mDir = Join-Path $env:LOCALAPPDATA 'IczAudioManifestTest'
    $script:Cleanup.Add($mDir)
    $mmEp = "SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\Render\$SampleGuid"
    function New-TestManifest {
        param([hashtable]$Over = @{}, [hashtable]$EpOver = @{})
        if (Test-Path -LiteralPath $mDir) { Remove-Item -LiteralPath $mDir -Recurse -Force }
        New-Item -ItemType Directory -Path (Join-Path $mDir 'endpoints') -Force | Out-Null
        [IO.File]::WriteAllBytes((Join-Path $mDir "endpoints\Render_$SampleGuid.hiv"), [byte[]](1..16))
        [IO.File]::WriteAllBytes((Join-Path $mDir "endpoints\Render_$SampleGuid.reg"), [byte[]](1..16))
        $ep = [ordered]@{ Flow = 'Render'; Guid = $SampleGuid; SubKey = $mmEp; Name = 'x'; InterfaceName = 'y'; ParentId = 'p'; Label = 'orphaned'
                          Hive = "endpoints\Render_$SampleGuid.hiv"; Reg = "endpoints\Render_$SampleGuid.reg" }
        foreach ($k in $EpOver.Keys) { $ep[$k] = $EpOver[$k] }
        $m = [ordered]@{ Version = 1; Script = 'Clean-AudioDevices.ps1'; Computer = $env:COMPUTERNAME; TargetSid = 'S-1-5-21-0'; Created = 'now'
                         Endpoints = @([pscustomobject]$ep)
                         AppSettings = [pscustomobject]@{ RootKey = 'HKEY_USERS\S-1-5-21-0\Software\Microsoft\Internet Explorer\LowRegistry\Audio\PolicyConfig\PropertyStore'; File = 'appsettings.reg'; Entries = @() }
                         Devnodes = @() }
        foreach ($k in $Over.Keys) { $m[$k] = $Over[$k] }
        $p = Join-Path $mDir 'manifest.json'
        [IO.File]::WriteAllText($p, ([pscustomobject]$m | ConvertTo-Json -Depth 8))
        $p
    }
    function Get-ReadError { param([string]$P) try { [void](Read-AudioManifest -Path $P); '' } catch { $_.Exception.Message } }
    Check 'a valid manifest reads' { $m = Read-AudioManifest -Path (New-TestManifest); @($m.Endpoints).Count -eq 1 }
    Check 'another computer -> refused' { (Get-ReadError (New-TestManifest @{ Computer = 'NOT-THIS-PC' })) -match 'another computer' }
    Check 'unsupported version -> refused' { (Get-ReadError (New-TestManifest @{ Version = 2 })) -match 'unsupported manifest version' }
    Check 'a hive path escaping the folder -> refused' { (Get-ReadError (New-TestManifest -EpOver @{ Hive = '..\..\evil.hiv' })) -match 'outside the backup folder' }
    Check 'a missing hive file -> refused' {
        $p = New-TestManifest; Remove-Item -LiteralPath (Join-Path $mDir "endpoints\Render_$SampleGuid.hiv")
        (Get-ReadError $p) -match 'missing backup file'
    }
    Check 'a key that is not an audio endpoint -> refused' { (Get-ReadError (New-TestManifest -EpOver @{ SubKey = 'SOFTWARE\Microsoft' })) -match 'not an audio endpoint' }
    # The manifest is written as UTF-8 without a BOM; Windows PowerShell 5.1's
    # Get-Content reads such a file as ANSI unless told otherwise.
    Check 'a non-ASCII per-app value survives the manifest round-trip' {
        $nonAscii = 'C:\Users\J' + [char]0x00F6 + 'rg\' + [char]0x00AE + '.exe'
        $p = New-TestManifest -EpOver @{ Name = ('Intel' + [char]0x00AE) }
        $m = Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json
        $m.AppSettings = [pscustomobject]@{ RootKey = 'HKEY_USERS\S-1-5-21-0\Software\Microsoft\Internet Explorer\LowRegistry\Audio\PolicyConfig\PropertyStore'; File = 'appsettings.reg'
                                            Entries = @([pscustomobject]@{ Name = 'cccc0001_0'; Value = $nonAscii; Sub = @() }) }
        [IO.File]::WriteAllText($p, ($m | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
        $back = Read-AudioManifest -Path $p
        @($back.AppSettings.Entries)[0].Value -ceq $nonAscii -and @($back.Endpoints)[0].Name -ceq ('Intel' + [char]0x00AE)
    }

    # Measured on the live round trip: after the services restart, the endpoint
    # builder discards a restored endpoint whose port a newer (rebuilt) endpoint
    # already holds. That is Windows' choice, not a failed restore.
    $epA = [pscustomobject]@{ SubKey = 'a'; Name = 'restored, kept by Windows' }
    $epB = [pscustomobject]@{ SubKey = 'b'; Name = 'restored, discarded by Windows' }
    $epC = [pscustomobject]@{ SubKey = 'c'; Name = 'restore reported Ok but key missing before restart' }
    $epD = [pscustomobject]@{ SubKey = 'd'; Name = 'exists now' }
    $epE = [pscustomobject]@{ SubKey = 'e'; Name = 'restore failed' }
    $outcome = $null
    try {
        $outcome = Get-AudioRestoreOutcome -Results @(
            [pscustomobject]@{ Endpoint = $epA; Ok = $true;  Message = 'restored'; PresentBeforeRestart = $true }
            [pscustomobject]@{ Endpoint = $epB; Ok = $true;  Message = 'restored'; PresentBeforeRestart = $true }
            [pscustomobject]@{ Endpoint = $epC; Ok = $true;  Message = 'restored'; PresentBeforeRestart = $false }
            [pscustomobject]@{ Endpoint = $epD; Ok = $false; Message = 'key exists: HKLM\d'; PresentBeforeRestart = $true }
            [pscustomobject]@{ Endpoint = $epE; Ok = $false; Message = 'restore of HKLM\e failed: error 5'; PresentBeforeRestart = $false }
        ) -PresentAfter @('a', 'c', 'd')
    }
    catch { Write-Output "  (restore outcome: $($_.Exception.Message))" }
    Check 'restored and still there -> Restored' { $null -ne $outcome -and @($outcome.Restored | ForEach-Object { $_.SubKey }) -join ',' -eq 'a' }
    Check 'restored, then discarded by Windows after the restart -> Discarded, not a failure' { @($outcome.Discarded | ForEach-Object { $_.SubKey }) -join ',' -eq 'b' }
    Check 'missing before the restart, or a failed restore -> Failed' { (@($outcome.Failed | ForEach-Object { $_.SubKey }) | Sort-Object) -join ',' -eq 'c,e' }
    Check 'key exists -> Skipped' { @($outcome.Skipped | ForEach-Object { $_.SubKey }) -join ',' -eq 'd' }

    $volKey = '{219ED5A0-9CBF-4F3A-B927-37C9E5C5F14F}'
    $rRoot = 'HKCU:\Software\IczAudioTest\RestoreStore'
    $script:Cleanup.Add('HKCU:\Software\IczAudioTest')
    $restoreOut = $null
    try {
        New-Item -Path "$rRoot\bbbb0001_0" -Force | Out-Null
        Set-Item -LiteralPath "$rRoot\bbbb0001_0" -Value 'existing'
        $entries = @(
            [pscustomobject]@{ Name = 'bbbb0001_0'; Value = 'old'; Sub = @() }
            [pscustomobject]@{ Name = 'bbbb0002_0'; Value = $vB; Sub = @(
                [pscustomobject]@{ Key = $volKey; Name = '3'; Kind = 'Binary'; Data = [Convert]::ToBase64String([byte[]](9, 8, 7)) },
                [pscustomobject]@{ Key = $volKey; Name = '4'; Kind = 'DWord'; Data = -2 },
                [pscustomobject]@{ Key = $volKey; Name = '5'; Kind = 'String'; Data = 's' }) }
        )
        $restoreOut = Restore-AppAudioSettings -Entries $entries -RootKey $rRoot
    }
    catch { Write-Output "  (per-app restore: $($_.Exception.Message))" }
    Check 'restores the missing entry, skips the existing one' { $null -ne $restoreOut -and $restoreOut.Restored -eq 1 -and $restoreOut.Skipped -eq 1 }
    Check 'an existing entry is left untouched' { $null -ne $restoreOut -and (Get-Item -LiteralPath "$rRoot\bbbb0001_0").GetValue('') -ceq 'existing' }
    Check 'the restored default value is exact' { (Get-Item -LiteralPath "$rRoot\bbbb0002_0").GetValue('') -ceq $vB }
    Check 'the restored subkey values are exact' {
        $sk = Get-Item -LiteralPath "$rRoot\bbbb0002_0\$volKey"
        -not (Compare-Object ([byte[]]$sk.GetValue('3')) ([byte[]](9, 8, 7)) -SyncWindow 0) -and $sk.GetValue('4') -eq -2 -and $sk.GetValue('5') -ceq 's' -and
        $sk.GetValueKind('3') -eq 'Binary' -and $sk.GetValueKind('4') -eq 'DWord'
    }

    # --- 12. per-app backup round-trip (HKCU scratch) ---------------------------
    Section '12. Per-app backup (HKCU scratch key, folder with a space and an apostrophe):'
    Check 'reg literal escapes \ and "' { (ConvertTo-RegSzLiteral 'a\b"c') -ceq 'a\\b\"c' }
    $scratchRoot = 'HKCU:\Software\IczAudioTest'
    $scratchReg  = 'HKEY_CURRENT_USER\Software\IczAudioTest\PropertyStore'
    $appDir = Join-Path $env:LOCALAPPDATA "Icz Audio O'Test"
    $script:Cleanup.Add($scratchRoot); $script:Cleanup.Add($appDir)
    $volKey = '{219ED5A0-9CBF-4F3A-B927-37C9E5C5F14F}'
    $appRecs = @(
        (New-AppRec @{ Name = 'aaaa0001_0'; Value = $vB })
        (New-AppRec @{ Name = 'aaaa0002_0'; Value = 'C:\Program Files\x "y".exe'; SubKeyCount = 1; SubKeyNames = @($volKey)
                       SubValues = @([pscustomobject]@{ Key = $volKey; Name = '3'; Kind = 'Binary'; Data = [byte[]](0, 1, 254, 255) },
                                     [pscustomobject]@{ Key = $volKey; Name = '4'; Kind = 'DWord'; Data = -2 },
                                     [pscustomobject]@{ Key = $volKey; Name = '5'; Kind = 'String'; Data = 'v\"w' }) })
    )
    $exportOk = $false
    try {
        New-Item -ItemType Directory -Path $appDir -Force | Out-Null
        Export-AppAudioSettingReg -Records $appRecs -RootKey $scratchReg -Path (Join-Path $appDir 'app.reg')
        $imp = Invoke-NativeCommand -FilePath 'reg.exe' -Arguments @('import', (Join-Path $appDir 'app.reg'))
        $exportOk = ($imp.Code -eq 0)
        if (-not $exportOk) { Write-Output "  (reg import: $($imp.Output))" }
    }
    catch { Write-Output "  (export: $($_.Exception.Message))" }
    Check 'generated .reg imports cleanly' { $exportOk }
    Check 'default value 1 round-trips' { (Get-Item -LiteralPath "$scratchRoot\PropertyStore\aaaa0001_0").GetValue('') -ceq $vB }
    Check 'default value 2 (quotes, backslashes) round-trips' { (Get-Item -LiteralPath "$scratchRoot\PropertyStore\aaaa0002_0").GetValue('') -ceq 'C:\Program Files\x "y".exe' }
    Check 'subkey binary round-trips' { -not (Compare-Object ([byte[]](Get-Item -LiteralPath "$scratchRoot\PropertyStore\aaaa0002_0\$volKey").GetValue('3')) ([byte[]](0, 1, 254, 255)) -SyncWindow 0) }
    Check 'subkey dword round-trips (negative as unsigned)' { (Get-Item -LiteralPath "$scratchRoot\PropertyStore\aaaa0002_0\$volKey").GetValue('4') -eq -2 }
    Check 'subkey string round-trips' { (Get-Item -LiteralPath "$scratchRoot\PropertyStore\aaaa0002_0\$volKey").GetValue('5') -ceq 'v\"w' }

    $bkDir = Join-Path $env:LOCALAPPDATA "Icz Audio O'Backup"
    $script:Cleanup.Add($bkDir)
    $whatIfDir = Join-Path $env:LOCALAPPDATA "Icz Audio O'WhatIf"
    $script:Cleanup.Add($whatIfDir)
    $man = $null
    try { $man = Backup-AudioTargets -Endpoints @() -AppSettings $appRecs -Folder $bkDir -TargetSid 'S-1-5-21-0' -AppRootKey $scratchReg -Devnodes @('SWD\MMDEVAPI\x') }
    catch { Write-Output "  (backup: $($_.Exception.Message))" }
    Check 'backup writes manifest.json and appsettings.reg' { (Test-Path -LiteralPath (Join-Path $bkDir 'manifest.json')) -and (Test-Path -LiteralPath (Join-Path $bkDir 'appsettings.reg')) }
    Check 'manifest records version, computer, sid, entries, devnodes' {
        $m = Get-Content -LiteralPath (Join-Path $bkDir 'manifest.json') -Raw | ConvertFrom-Json
        $m.Version -eq 1 -and $m.Computer -eq $env:COMPUTERNAME -and $m.TargetSid -eq 'S-1-5-21-0' -and @($m.AppSettings.Entries).Count -eq 2 -and @($m.Devnodes).Count -eq 1
    }
    Check 'manifest keeps the subkey values (binary as base64)' {
        $m = Get-Content -LiteralPath (Join-Path $bkDir 'manifest.json') -Raw | ConvertFrom-Json
        $sub = @(@($m.AppSettings.Entries | Where-Object { $_.Name -eq 'aaaa0002_0' })[0].Sub)
        $sub.Count -eq 3 -and ($sub | Where-Object { $_.Name -eq '3' }).Data -eq [Convert]::ToBase64String([byte[]](0, 1, 254, 255))
    }
    Check 'Test-AudioBackup: a good backup has no problems' { @(Test-AudioBackup -Folder $bkDir -Manifest $man).Count -eq 0 }
    Check 'Test-AudioBackup: a truncated appsettings.reg is reported by name' {
        [IO.File]::WriteAllBytes((Join-Path $bkDir 'appsettings.reg'), [byte[]](1..10))
        $p = @(Test-AudioBackup -Folder $bkDir -Manifest $man)
        $p.Count -ge 1 -and ($p -join ' ') -match 'appsettings\.reg'
    }
    Check 'a second backup into a folder that holds a manifest is refused' {
        $refused = $false
        try { [void](Backup-AudioTargets -Endpoints @() -AppSettings $appRecs -Folder $bkDir -TargetSid 'S-1-5-21-0' -AppRootKey $scratchReg -Devnodes @()) } catch { $refused = $_.Exception.Message -match 'already' }
        $refused
    }
    Check '-WhatIf writes nothing and still returns the manifest' {
        $wm = Backup-AudioTargets -Endpoints @() -AppSettings $appRecs -Folder $whatIfDir -TargetSid 'S-1-5-21-0' -AppRootKey $scratchReg -Devnodes @() -WhatIf
        -not (Test-Path -LiteralPath $whatIfDir) -and @($wm.AppSettings.Entries).Count -eq 2
    }

    # --- 15. launcher quoting ----------------------------------------------------
    # The elevated run builds a PowerShell list of single-quoted strings inside
    # cmd. A path with an apostrophe (C:\Users\O'Brien\...) ends the string early
    # unless the apostrophe is doubled first.
    Section '15. Launcher (elevated command line quoting):'
    $cmdPath = Join-Path (Split-Path -Parent $ScriptPath) 'Clean-AudioDevices.cmd'
    Check 'cmd doubles an apostrophe with !VAR:''=''''!' {
        $o = & cmd.exe /v:on /c "set `"X=O'Brien`"& echo !X:'=''!"
        ([string]$o).Trim() -ceq "O''Brien"
    }
    Check 'no raw %SCRIPT% or !MANIFEST! inside single quotes in the launcher' {
        $lines = @(Get-Content -LiteralPath $cmdPath | Where-Object { $_ -notmatch '^\s*REM' })
        $lines.Count -gt 0 -and @($lines | Where-Object { $_ -match "'%SCRIPT%'|'!SCRIPT!'|'!MANIFEST!'" }).Count -eq 0
    }
    Check 'the launcher builds apostrophe-doubled copies of both paths' {
        $text = Get-Content -LiteralPath $cmdPath -Raw
        $text -match [regex]::Escape("set `"SCRIPTQ=!SCRIPT:'=''!`"") -and $text -match [regex]::Escape("set `"MANIFESTQ=!MANIFEST:'=''!`"")
    }

    # --- 11. live census, read-only ---------------------------------------------
    # The expected counts are this machine's, measured when the cleaner was
    # designed. Anywhere else the section only checks shapes.
    Section '11. Live census (read-only):'
    $designMachine = 'ICECREAMASSASIN'
    $census = $null
    try { $census = Get-AudioCensus -TargetSid ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value) } catch { Write-Output "  (census: $($_.Exception.Message))" }
    Check 'census returns endpoints' { $null -ne $census -and @($census.Endpoints).Count -gt 0 }
    Check 'every endpoint has a verdict and a record with a KeyPath' { @($census.Endpoints | Where-Object { $null -eq $_.Verdict -or [string]::IsNullOrEmpty($_.Record.KeyPath) }).Count -eq 0 }
    Check 'enabled interfaces were read (no unknown labels)' { $null -ne $census.Context.Enabled -and @($census.Endpoints | Where-Object { $_.Verdict.Label -eq 'unknown' }).Count -eq 0 }
    Check 'enabled interfaces match pnputil /enum-interfaces /enabled' {
        $mine = @(Get-EnabledAudioInterface)
        $pn = @(& pnputil.exe /enum-interfaces /class '{6994ad04-93ef-11d0-a3cc-00a0c9223196}' /enabled 2>$null |
                Where-Object { $_ -match '^\s*Interface Path:\s*(.+)$' } | ForEach-Object { $Matches[1].Trim().ToLowerInvariant() })
        $pn.Count -gt 0 -and -not (Compare-Object ($mine | Sort-Object -Unique) ($pn | Sort-Object -Unique))
    }
    Check 'no per-app Remove on a USB or Bluetooth device' { @($census.AppSettings | Where-Object { $_.Verdict.Action -eq 'Remove' -and $_.Record.Value -match '^\{\d+\}\.\\\\\?\\(usb|bthenum|bthhfenum|bthledevice|root)#' }).Count -eq 0 }
    Check 'every per-app Remove is hdaudio or intelaudio' { @($census.AppSettings | Where-Object { $_.Verdict.Action -eq 'Remove' -and $_.Record.Value -notmatch '^\{\d+\}\.\\\\\?\\(hdaudio|intelaudio)#' }).Count -eq 0 }
    if ($env:COMPUTERNAME -ne $designMachine) {
        Write-Output "  [SKIP] exact counts belong to $designMachine; this is $env:COMPUTERNAME"
    }
    else {
        $byLabel = @{}
        if ($null -ne $census) { foreach ($e in @($census.Endpoints)) { $byLabel[$e.Verdict.Label] = 1 + [int]$byLabel[$e.Verdict.Label] } }
        # This machine after its first clean: the 20 live endpoints, and the 16
        # ports its drivers still expose, which Windows rebuilt (AMD HDMI x4,
        # NVIDIA x2, Realtek multi-jack x10) - every one labelled as such. (Before
        # the clean it was 62: orphaned 6, interface-gone 11, duplicate 3,
        # no-interface-recorded 15, port-still-exposed 7, live 20; 333 per-app
        # entries and 3 ghost devnodes.)
        foreach ($want in @(@('live', 20), @('port-still-exposed', 16))) {
            Check "label $($want[0]) = $($want[1])" { [int]$byLabel[$want[0]] -eq $want[1] }
        }
        Check 'no other label is present' { @($byLabel.Keys | Where-Object { @('live', 'port-still-exposed') -notcontains $_ }).Count -eq 0 }
        Check 'every Active endpoint is kept' { @($census.Endpoints | Where-Object { ((([int64]$_.Record.State) -band 0xF) -eq 1) -and $_.Verdict.Action -ne 'Keep' }).Count -eq 0 }
        # The 11 endpoints that were active before the first clean (both monitor
        # endpoints, every Sonar channel, Stereo Mix) must all still exist and be
        # kept. How many are active right now depends on what is plugged in.
        $activeBefore = @('{8dcb37ce-1f49-4c48-88a3-b461794bdfdc}', '{ce7af1ef-1e7c-4e03-9d87-15400b24dfd0}', '{f669b5b2-2781-4d51-8aa7-bef65a9ebfc7}',
                          '{98697f70-2402-4257-b097-e53050490b82}', '{a16a644a-db5d-4766-ac45-ab7857b1d71c}', '{bc855137-8916-4ebd-a07a-5b5a48260fdf}',
                          '{22450a3e-ef55-467f-bb79-b46b6963007a}', '{cd7039ce-08ec-413b-bba8-a10d23472bc6}', '{c3a037cc-ea92-4495-ac19-b0d63017c439}',
                          '{7618e9f3-cc64-4897-b3b6-a81702e9cf4c}', '{dcc07c43-9dfe-4e6a-9411-fe2ae0b9543e}')
        Check 'the 11 endpoints active before the clean all still exist and are kept as live' {
            $live = @($census.Endpoints | Where-Object { $_.Verdict.Label -eq 'live' } | ForEach-Object { ([string]$_.Record.Guid).ToLowerInvariant() })
            @($activeBefore | Where-Object { $live -notcontains $_ }).Count -eq 0
        }
        Check 'no dead per-app entry is left' { @($census.AppSettings | Where-Object { $_.Verdict.Action -eq 'Remove' }).Count -eq 0 }
        Check 'no per-app entry is unexpected-shape on this machine' { @($census.AppSettings | Where-Object { $_.Verdict.Label -eq 'unexpected-shape' }).Count -eq 0 }
        Check 'no ghost devnode is left' { @($census.GhostDevnodes).Count -eq 0 }
    }

    # --- 9. CLI, child process -------------------------------------------------
    # Each case must be refused BEFORE elevation. The message is asserted as well
    # as the exit code, because a declined UAC prompt would also exit 1.
    Section '9. Command line (child process, refused before elevation):'
    function Invoke-Child {
        param([string]$Exe, [string]$Arguments, [int]$TimeoutSec = 60)
        $psi = [System.Diagnostics.ProcessStartInfo]::new($Exe, $Arguments)
        $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
        $psi.WorkingDirectory = $env:TEMP
        $p = [System.Diagnostics.Process]::Start($psi)
        $o = $p.StandardOutput.ReadToEndAsync(); $e = $p.StandardError.ReadToEndAsync()
        if (-not $p.WaitForExit($TimeoutSec * 1000)) {
            try { $p.Kill() } catch { Write-Output "  (could not kill child: $($_.Exception.Message))" }
            return [pscustomobject]@{ Code = -1; Text = 'TIMEOUT' }
        }
        $p.WaitForExit()
        [pscustomobject]@{ Code = $p.ExitCode; Text = ($o.Result + $e.Result) }
    }
    $ps64 = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $ps32 = Join-Path $env:SystemRoot 'SysWOW64\WindowsPowerShell\v1.0\powershell.exe'
    $childCases = @(
        @{ Exe = $ps64; Args = '-Clean -Restore x.json'; Want = 'together' }
        @{ Exe = $ps64; Args = '-ListOnly -Clean'; Want = '-ListOnly' }
        @{ Exe = $ps64; Args = '-KeepExposedPorts'; Want = '-Clean' }
        @{ Exe = $ps64; Args = '-Restore .\no-such-manifest.json'; Want = 'not found' }
        @{ Exe = $ps32; Args = '-ListOnly'; Want = '64-bit' }
    )
    foreach ($cc in $childCases) {
        if (-not (Test-Path -LiteralPath $cc.Exe)) { Write-Output "  [SKIP] $($cc.Exe) not present"; continue }
        $r = Invoke-Child -Exe $cc.Exe -Arguments ("-NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`" " + $cc.Args)
        $label = "$(Split-Path (Split-Path (Split-Path $cc.Exe))) $($cc.Args) -> exit 1, says '$($cc.Want)'"
        Check $label { $r.Code -eq 1 -and $r.Text -match [regex]::Escape($cc.Want) }
    }
}
finally {
    # Only the exact paths this run created; nothing is removed by name pattern.
    foreach ($p in $script:Cleanup) {
        if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Write-Output ''
Write-Output ("RESULT: {0} passed, {1} failed" -f $script:Pass, $script:Fail)
if ($script:Fail -gt 0) { exit 1 }
exit 0
