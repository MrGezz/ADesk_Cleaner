<#
.SYNOPSIS
    Elevated regression test for the registry mechanism of Clean-AudioDevices.ps1,
    run against a scratch replica of the locked MMDevices Render tree - never
    against a real audio endpoint.

.DESCRIPTION
    Builds HKLM\SOFTWARE\IczAudioMechanismTest\Render\{11111111-...} with
    Properties and FxProperties subkeys, gives every replica key the real
    MMDevices Render key's owner (SYSTEM) and access rules, and proves:

      - the replica really is locked (a plain Remove-Item is denied);
      - Remove-RegistryTreeBackupSemantics deletes it without changing any ACL;
      - Save-/Restore-AudioRegistryHive bring back the values, the owner and the
        DACL byte for byte;
      - a restore refuses to overwrite an existing key;
      - the deleter refuses anything that is not an endpoint key or this test root;
      - Backup-AudioTargets writes a verifiable backup (once that task lands).

    -ExpectDefective restores with "reg import" of the .reg export instead - the
    route the design rejected. A correct harness exits 1 in that mode.

.PARAMETER ScriptPath
    The script under test. Defaults to scripts\windows\Clean-AudioDevices.ps1.

.PARAMETER ExpectDefective
    Prove-it-can-fail mode (see above).

.PARAMETER CleanupOnly
    Only remove a replica left behind by an interrupted run.

.NOTES
    Must run elevated; exits 2 otherwise. Windows PowerShell 5.1.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '')]
[CmdletBinding()]
param(
    [string]$ScriptPath,
    [switch]$ExpectDefective,
    [switch]$CleanupOnly
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Output 'Run this test elevated: it builds a scratch key under HKLM\SOFTWARE.'
    exit 2
}

if (-not $ScriptPath) { $ScriptPath = Join-Path $PSScriptRoot '..\scripts\windows\Clean-AudioDevices.ps1' }
if (-not (Test-Path -LiteralPath $ScriptPath)) { Write-Output "Cannot find the script under test: $ScriptPath"; exit 2 }
$ScriptPath = (Resolve-Path -LiteralPath $ScriptPath).ProviderPath
Write-Output "script under test : $ScriptPath"
Write-Output "mode              : $(if ($ExpectDefective) { 'EXPECT DEFECTIVE (prove the harness can fail)' } elseif ($CleanupOnly) { 'cleanup only' } else { 'mechanism must hold' })"

$script:Pass = 0
$script:Fail = 0
function Check {
    param([string]$What, [scriptblock]$Condition)
    $checkOk = $false; $checkErr = $null
    try { $checkOk = [bool](& $Condition) } catch { $checkErr = $_.Exception.Message }
    if ($checkOk) { $script:Pass++; Write-Output "  [PASS] $What" }
    else {
        $script:Fail++
        if ($checkErr) { Write-Output "  [FAIL] $What  ($checkErr)" } else { Write-Output "  [FAIL] $What" }
    }
}
function Section { param([string]$Title) Write-Output ''; Write-Output $Title }

$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$tokens, [ref]$errors)
if ($errors.Count) { Write-Output "script under test does not parse: $($errors[0].Message)"; exit 2 }
$funcs = @($ast.EndBlock.Statements | Where-Object { $_ -is [System.Management.Automation.Language.FunctionDefinitionAst] })
Write-Output ("functions lifted  : {0}" -f $funcs.Count)
if ($funcs.Count) { . ([scriptblock]::Create((($funcs | ForEach-Object { $_.Extent.Text }) -join "`r`n"))) }

# --- replica layout ----------------------------------------------------------
$Root     = 'SOFTWARE\IczAudioMechanismTest'
$Render   = "$Root\Render"
$EpGuid   = '{11111111-2222-3333-4444-555555555555}'
$Ep       = "$Render\$EpGuid"
$RealRenderSub = 'SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\Render'
$Work     = Join-Path $env:LOCALAPPDATA 'IczAudioMechanism'
$AdminSid = 'S-1-5-32-544'

function Remove-Replica {
    if (-not (Test-Path -LiteralPath "HKLM:\$Root")) { return }
    $r = $null
    try { $r = Remove-RegistryTreeBackupSemantics -SubKey $Root } catch { Write-Output "  cleanup error: $($_.Exception.Message)" }
    # A replica that never got its locked ACL (the fixture failed part-way) is
    # still deletable the ordinary way.
    if (Test-Path -LiteralPath "HKLM:\$Root") {
        try { Remove-Item -LiteralPath "HKLM:\$Root" -Recurse -Force -ErrorAction Stop } catch { Write-Output "  plain cleanup: $($_.Exception.Message)" }
    }
    if (Test-Path -LiteralPath "HKLM:\$Root") {
        Write-Output "  CLEANUP FAILED: HKLM\$Root is still there. Rerun this test with -CleanupOnly."
    }
}
if ($CleanupOnly) { Remove-Replica; exit 0 }

# Windows PowerShell 5.1's Get-Acl -LiteralPath reports "Cannot find path" for
# EVERY registry key, existing or not, so security is read through .NET.
function Get-KeySecurity {
    param([string]$Sub)
    $k = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($Sub, [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadSubTree, [Security.AccessControl.RegistryRights]::ReadPermissions)
    if ($null -eq $k) { throw "HKLM\$Sub does not exist" }
    try { return $k.GetAccessControl() } finally { $k.Close() }
}
function Get-Sddl { param([string]$Sub) (Get-KeySecurity $Sub).Sddl }
function Export-Text {
    param([string]$Sub, [string]$File)
    $r = Invoke-NativeCommand -FilePath 'reg.exe' -Arguments @('export', "HKLM\$Sub", $File, '/y')
    if ($r.Code -ne 0) { throw "reg export HKLM\$Sub failed ($($r.Code)): $($r.Output)" }
    [IO.File]::ReadAllBytes($File)
}
function Test-BytesEqual { param([byte[]]$A, [byte[]]$B) $null -ne $A -and $null -ne $B -and $A.Length -eq $B.Length -and -not (Compare-Object $A $B -SyncWindow 0) }

# Owner SYSTEM, and the real Render key's access rules made explicit and
# protected on the replica Render, so every replica child inherits exactly what
# a real endpoint key inherits: Administrators get SetValue + ReadKey only.
function New-Replica {
    New-Item -Path "HKLM:\$Ep\Properties" -Force | Out-Null
    New-Item -Path "HKLM:\$Ep\FxProperties" -Force | Out-Null
    $p = "HKLM:\$Ep\Properties"
    New-ItemProperty -LiteralPath $p -Name '{a45c254e-df1c-4efd-8020-67d146a850e0},2' -PropertyType String -Value 'Speakers' | Out-Null
    New-ItemProperty -LiteralPath $p -Name 't_dword' -PropertyType DWord -Value 4 | Out-Null
    New-ItemProperty -LiteralPath $p -Name 't_bin' -PropertyType Binary -Value ([byte[]](1..8)) | Out-Null
    New-ItemProperty -LiteralPath $p -Name 't_multi' -PropertyType MultiString -Value @('a', 'b') | Out-Null
    New-ItemProperty -LiteralPath "HKLM:\$Ep\FxProperties" -Name 't_fx' -PropertyType Binary -Value ([byte[]](1..16)) | Out-Null

    if (-not (Enable-AudioPrivileges)) { throw 'could not enable SeBackupPrivilege + SeRestorePrivilege' }
    $system = New-Object Security.Principal.SecurityIdentifier('S-1-5-18')
    foreach ($sub in "$Ep\FxProperties", "$Ep\Properties", $Ep) {
        $k = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($sub, [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree, [Security.AccessControl.RegistryRights]::TakeOwnership)
        $acl = $k.GetAccessControl([Security.AccessControl.AccessControlSections]::None)
        $acl.SetOwner($system); $k.SetAccessControl($acl); $k.Close()
    }
    # The real key's ACEs are all inherited (ID). Strip the ID flag so they
    # become explicit, and protect the replica Render from SOFTWARE's ACEs.
    $access = (Get-KeySecurity $RealRenderSub).GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]::Access)
    $aces = [regex]::Matches($access, '\([^)]*\)') | ForEach-Object {
        $parts = $_.Value.Trim('(', ')').Split(';')
        $parts[1] = $parts[1] -replace 'ID', ''
        '(' + ($parts -join ';') + ')'
    }
    $sec = New-Object Security.AccessControl.RegistrySecurity
    $sec.SetSecurityDescriptorSddlForm('D:P' + ($aces -join ''), [Security.AccessControl.AccessControlSections]::Access)
    $k = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($Render, [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree, [Security.AccessControl.RegistryRights]::ChangePermissions)
    $k.SetAccessControl($sec); $k.Close()
}

try {
    Remove-Replica
    if (Test-Path -LiteralPath $Work) { Remove-Item -LiteralPath $Work -Recurse -Force }
    New-Item -ItemType Directory -Path $Work -Force | Out-Null

    Section '1. Fixture:'
    $built = $false
    try { New-Replica; $built = $true } catch { Write-Output "  (fixture: $($_.Exception.Message))" }
    Check 'replica built' { $built }
    Check 'replica endpoint owned by SYSTEM' { (Get-KeySecurity $Ep).GetOwner([Security.Principal.SecurityIdentifier]).Value -eq 'S-1-5-18' }
    Check 'Administrators hold no Delete right on the replica endpoint' {
        $rules = @((Get-KeySecurity $Ep).GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]) |
                   Where-Object { $_.IdentityReference.Value -eq $AdminSid -and $_.AccessControlType -eq 'Allow' })
        $rules.Count -gt 0 -and -not ($rules | Where-Object { ([int]$_.RegistryRights -band 0x10000) -ne 0 })
    }
    Check 'a plain Remove-Item is denied (the replica is really locked)' {
        $denied = $false
        try { Remove-Item -LiteralPath "HKLM:\$Ep" -Recurse -Force -ErrorAction Stop } catch { $denied = $true }
        $denied -and (Test-Path -LiteralPath "HKLM:\$Ep")
    }

    Section '2. Delete with backup semantics:'
    $snap = @{}
    foreach ($s in $Ep, "$Ep\Properties", "$Ep\FxProperties", $Render) { try { $snap[$s] = Get-Sddl $s } catch { $snap[$s] = $null } }
    $exportA = $null
    try { $exportA = Export-Text -Sub $Ep -File (Join-Path $Work 'A.reg') } catch { Write-Output "  (export: $($_.Exception.Message))" }
    $hive = Join-Path $Work 'endpoint.hiv'
    Check 'Save-AudioRegistryHive writes a non-empty hive' { (Save-AudioRegistryHive -SubKey $Ep -File $hive) -and (Get-Item -LiteralPath $hive).Length -gt 0 }
    $del = $null
    try { $del = Remove-RegistryTreeBackupSemantics -SubKey $Ep } catch { Write-Output "  (delete: $($_.Exception.Message))" }
    Check 'Remove-RegistryTreeBackupSemantics reports Ok' { $null -ne $del -and $del.Ok }
    Check 'the endpoint key is gone' { -not (Test-Path -LiteralPath "HKLM:\$Ep") }
    Check 'no ACL changed: replica Render SDDL unchanged' { $null -ne $snap[$Render] -and (Get-Sddl $Render) -eq $snap[$Render] }

    Section '3. Restore from the hive:'
    if ($ExpectDefective) {
        $imp = Invoke-NativeCommand -FilePath 'reg.exe' -Arguments @('import', (Join-Path $Work 'A.reg'))
        Write-Output "  (reg import exited $($imp.Code): $($imp.Output))"
        $res = [pscustomobject]@{ Ok = ($imp.Code -eq 0); Message = "reg import exited $($imp.Code)" }
    }
    else {
        $res = $null
        try { $res = Restore-AudioRegistryHive -SubKey $Ep -File $hive } catch { Write-Output "  (restore: $($_.Exception.Message))" }
    }
    Check 'restore reports Ok' { $null -ne $res -and $res.Ok }
    Check 'values and subkeys byte-identical (reg export A = B)' { Test-BytesEqual $exportA (Export-Text -Sub $Ep -File (Join-Path $Work 'B.reg')) }
    foreach ($s in $Ep, "$Ep\Properties", "$Ep\FxProperties") {
        Check "owner + DACL restored exactly: $($s.Substring($Render.Length + 1))" { $null -ne $snap[$s] -and (Get-Sddl $s) -eq $snap[$s] }
    }
    $again = $null
    try { $again = Restore-AudioRegistryHive -SubKey $Ep -File $hive } catch { Write-Output "  (restore again: $($_.Exception.Message))" }
    Check 'a second restore refuses: key exists' { $null -ne $again -and -not $again.Ok -and $again.Message -match 'exists' }

    Section '5. Endpoint backup (folder with a space and an apostrophe):'
    $bk = Join-Path $env:TEMP "Icz Audio O'Backup"
    $bkWhatIf = Join-Path $env:TEMP "Icz Audio O'WhatIf"
    foreach ($d in $bk, $bkWhatIf) { if (Test-Path -LiteralPath $d) { Remove-Item -LiteralPath $d -Recurse -Force } }
    $replicaRec = [pscustomobject]@{ Flow = 'Render'; Guid = $EpGuid; KeyPath = "HKLM:\$Ep"; Name = 'Speakers'; InterfaceName = 'Replica'; ParentId = $null }
    $bkMan = $null
    try { $bkMan = Backup-AudioTargets -Endpoints @($replicaRec) -AppSettings @() -Folder $bk -TargetSid 'S-1-5-21-0' -AppRootKey 'HKEY_USERS\S-1-5-21-0\x' -Devnodes @() }
    catch { Write-Output "  (backup: $($_.Exception.Message))" }
    Check 'hive and export written for the locked replica' {
        (Get-Item -LiteralPath (Join-Path $bk "endpoints\Render_$EpGuid.hiv")).Length -gt 0 -and (Get-Item -LiteralPath (Join-Path $bk "endpoints\Render_$EpGuid.reg")).Length -gt 0
    }
    Check 'Test-AudioBackup: no problems' { $null -ne $bkMan -and @(Test-AudioBackup -Folder $bk -Manifest $bkMan).Count -eq 0 }
    Check 'Test-AudioBackup: a truncated endpoint export is reported by name' {
        [IO.File]::WriteAllBytes((Join-Path $bk "endpoints\Render_$EpGuid.reg"), [byte[]](1..10))
        (@(Test-AudioBackup -Folder $bk -Manifest $bkMan) -join ' ') -match [regex]::Escape("Render_$EpGuid.reg")
    }
    Check '-WhatIf creates no backup folder' {
        [void](Backup-AudioTargets -Endpoints @($replicaRec) -AppSettings @() -Folder $bkWhatIf -TargetSid 'S-1-5-21-0' -AppRootKey 'x' -Devnodes @() -WhatIf)
        -not (Test-Path -LiteralPath $bkWhatIf)
    }
    foreach ($d in $bk, $bkWhatIf) { if (Test-Path -LiteralPath $d) { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue } }

    Section '4. The deleter refuses anything else:'
    foreach ($bad in 'SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\Render', 'SOFTWARE\Microsoft') {
        Check "refuses $bad and leaves it" {
            $r = Remove-RegistryTreeBackupSemantics -SubKey $bad
            -not $r.Ok -and (Test-Path -LiteralPath "HKLM:\$bad")
        }
    }
}
finally {
    Remove-Replica
    if (Test-Path -LiteralPath $Work) { Remove-Item -LiteralPath $Work -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Output ''
Write-Output ("RESULT: {0} passed, {1} failed" -f $script:Pass, $script:Fail)
if ($script:Fail -gt 0) { exit 1 }
exit 0
