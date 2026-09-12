<#
.SYNOPSIS
    Regression test for the deletion fences in Uninstall-PyRevit-Complete.ps1 -
    the extension fence, the drive fence and the marker fence - run against a
    throwaway fixture, never against the real machine.

.DESCRIPTION
    Builds a pyRevit-shaped fixture under %TEMP%: a clone, the config folder with
    its default Extensions folder, the CLI install folder, an unverified folder
    under the profile, and - on a SECOND drive letter created with subst - a user
    extension workspace registered in pyRevit_config.ini plus a second clone.
    Points every environment root the script reads (%APPDATA%, %LOCALAPPDATA%,
    %PROGRAMDATA%, %USERPROFILE%, %TEMP%, %PROGRAMFILES%) at the fixture, lifts
    the script's functions out by AST so its MAIN block never runs, and asserts
    what may and may not be deleted - including REAL deletions inside the fixture.

    The defect this guards against: pyRevit_config.ini's "userextensions" entry
    pointed at the user's extension workspace on another drive; its path
    contained "pyrevit", the INI reader took it for a clone, and phase 5 deleted
    it. Run with -ExpectDefective against a pre-fix copy of the script to prove
    this harness can fail: it passes in that mode only if the old code WOULD have
    deleted the workspace.

.PARAMETER ScriptPath
    The script under test. Defaults to scripts\autodesk\Uninstall-PyRevit-Complete.ps1
    relative to the repository root, falling back to a copy beside the repo root.

.PARAMETER ExpectDefective
    Prove-it-can-fail mode for a pre-fix copy: passes only if that copy would
    have swept the registered user extension workspace.

.EXAMPLE
    .\tests\Test-PyRevitFences.ps1
    Runs the fences against the shipped script. Exit code 0 = all assertions hold.

.EXAMPLE
    git show 33c76bd:Uninstall-PyRevit-Complete.ps1 > $env:TEMP\old.ps1
    .\tests\Test-PyRevitFences.ps1 -ScriptPath $env:TEMP\old.ps1 -ExpectDefective
    Confirms the harness detects the original defect.

.NOTES
    Windows PowerShell 5.1. subst needs no elevation. The fixture and the
    substituted drive letter are removed in the finally block.
#>
# The script's parameters and script-scope state are assigned here and read by
# the functions lifted out of it (dynamic scoping), which the analyzer cannot see.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '')]
[CmdletBinding()]
param(
    [string]$ScriptPath,
    [switch]$ExpectDefective
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2

# --- locate the script under test -------------------------------------------
if (-not $ScriptPath) {
    $candidates = @(
        (Join-Path $PSScriptRoot '..\scripts\autodesk\Uninstall-PyRevit-Complete.ps1'),
        (Join-Path $PSScriptRoot '..\Uninstall-PyRevit-Complete.ps1')
    )
    $ScriptPath = $candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
}
if (-not $ScriptPath -or -not (Test-Path -LiteralPath $ScriptPath)) {
    Write-Output "Cannot find the script under test (tried scripts\autodesk and the repo root). Pass -ScriptPath."
    exit 2
}
$ScriptPath = (Resolve-Path -LiteralPath $ScriptPath).ProviderPath
Write-Output "script under test : $ScriptPath"
Write-Output "mode              : $(if ($ExpectDefective) { 'EXPECT DEFECTIVE (prove the harness can fail)' } else { 'fences must hold' })"

# --- assertion plumbing ------------------------------------------------------
$script:Pass = 0
$script:Fail = 0
function Assert {
    param([bool]$Condition, [string]$What)
    if ($Condition) { $script:Pass++; Write-Output "  [PASS] $What" }
    else            { $script:Fail++; Write-Output "  [FAIL] $What" }
}
function New-Dir  { param([string]$P) New-Item -ItemType Directory -Path $P -Force | Out-Null; $P }
function New-Stub { param([string]$P) New-Item -ItemType File -Path $P -Force -Value 'x' | Out-Null; $P }

# --- fixture -----------------------------------------------------------------
$realEnv = @{}
foreach ($n in 'APPDATA','LOCALAPPDATA','PROGRAMDATA','USERPROFILE','TEMP','TMP','PROGRAMFILES','ProgramFiles(x86)') {
    $realEnv[$n] = [Environment]::GetEnvironmentVariable($n, 'Process')
}
# Under %LOCALAPPDATA%, not %TEMP%: TEMP is frequently an 8.3 short name
# (C:\Users\ICECRE~1\...) and the assertions compare paths as strings.
$fx     = Join-Path $realEnv['LOCALAPPDATA'] ("pyrv_fence_test_{0}" -f $PID)
$letter = $null

try {
    if (Test-Path -LiteralPath $fx) { Remove-Item -LiteralPath $fx -Recurse -Force }
    New-Item -ItemType Directory -Path $fx -Force | Out-Null
    $fx = (Get-Item -LiteralPath $fx).FullName.TrimEnd('\')
    $roaming = New-Dir (Join-Path $fx 'Roaming')
    $local   = New-Dir (Join-Path $fx 'Local')
    $pdata   = New-Dir (Join-Path $fx 'ProgramData')
    $prof    = New-Dir (Join-Path $fx 'profile')
    $temp    = New-Dir (Join-Path $fx 'Temp')
    $pf      = New-Dir (Join-Path $fx 'PF')
    $pf86    = New-Dir (Join-Path $fx 'PF86')
    $other   = New-Dir (Join-Path $fx 'other')

    # A second drive letter for the "other drive" cases.
    $used = @(Get-PSDrive -PSProvider FileSystem | ForEach-Object { $_.Name })
    $letter = 'ZYXWVUTSRQPONMLKJIHG'.ToCharArray() |
        Where-Object { $used -notcontains "$_" -and -not (Test-Path -LiteralPath "$($_):\") } |
        Select-Object -First 1
    if (-not $letter) { throw 'no free drive letter for subst' }
    & subst.exe "$($letter):" $other | Out-Null
    if (-not (Test-Path -LiteralPath "$($letter):\")) { throw "subst $($letter): failed" }
    $otherDrive = "$($letter):"
    Write-Output "fixture           : $fx"
    Write-Output "other drive       : $otherDrive -> $other"

    # pyRevit's own footprint on the "system" side.
    $cfgDir    = New-Dir (Join-Path $roaming 'pyRevit')
    $defExt    = New-Dir (Join-Path $cfgDir  'Extensions')
    $mineExt   = New-Dir (Join-Path $defExt  'Mine.extension')
    New-Stub (Join-Path $mineExt 'lib\mine.py') | Out-Null
    $master    = New-Dir (Join-Path $roaming 'pyRevit-Master')
    New-Stub (Join-Path $master 'bin\pyrevit.exe')                  | Out-Null
    New-Stub (Join-Path $master 'pyrevitlib\pyrevit\__init__.py')   | Out-Null
    New-Stub (Join-Path $master 'extensions\pyRevitCore.extension\x') | Out-Null
    New-Stub (Join-Path $master 'pyRevitfile')                      | Out-Null
    $cache     = New-Dir (Join-Path $local 'pyRevit')
    New-Stub (Join-Path $cache 'cache\x') | Out-Null
    $cli       = New-Dir (Join-Path $local 'Programs\pyRevit CLI')
    New-Stub (Join-Path $cli 'bin\pyrevit.exe') | Out-Null
    $notes     = New-Dir (Join-Path $prof 'pyRevit-notes')
    New-Stub (Join-Path $notes 'readme.txt') | Out-Null
    $noName    = New-Dir (Join-Path $prof 'Documents')
    $tmpDir    = New-Dir (Join-Path $temp 'pyrevit_tmp')
    New-Stub (Join-Path $tmpDir 'x') | Out-Null

    # The other drive: the registered extension workspace (the folder that was
    # destroyed) and a clone the user manages with the CLI.
    $wsRel     = 'Dev\IcZ PyRevit\Workspace'
    $wsReal    = New-Dir (Join-Path $other $wsRel)
    New-Stub (Join-Path $wsReal 'IcZ.extension\lib\tool.py') | Out-Null
    New-Stub (Join-Path $wsReal 'notes.md') | Out-Null
    $workspace = Join-Path $otherDrive $wsRel
    $cloneReal = New-Dir (Join-Path $other 'pyRevit-Clone')
    New-Stub (Join-Path $cloneReal 'bin\pyrevit.exe') | Out-Null
    New-Stub (Join-Path $cloneReal 'pyrevitlib\pyrevit\__init__.py') | Out-Null
    $clone2    = Join-Path $otherDrive 'pyRevit-Clone'

    # pyRevit_config.ini exactly as the CLI writes it (JSON values, doubled backslashes).
    $j = { param($p) $p -replace '\\','\\' }
    $ini = @(
        '[environment]'
        ('clones = {{"master":"{0}","dev":"{1}"}}' -f (& $j $master), (& $j $clone2))
        ''
        '[core]'
        'checkupdates = false'
        ('userextensions = ["{0}"]' -f (& $j $workspace))
        'user_locale = "en_us"'
        ''
        '[telemetry]'
        'telemetry_file_dir = ""'
    ) -join "`r`n"
    Set-Content -LiteralPath (Join-Path $cfgDir 'pyRevit_config.ini') -Value $ini -Encoding ASCII

    # Point the environment at the fixture.
    [Environment]::SetEnvironmentVariable('APPDATA',           $roaming, 'Process')
    [Environment]::SetEnvironmentVariable('LOCALAPPDATA',      $local,   'Process')
    [Environment]::SetEnvironmentVariable('PROGRAMDATA',       $pdata,   'Process')
    [Environment]::SetEnvironmentVariable('USERPROFILE',       $prof,    'Process')
    [Environment]::SetEnvironmentVariable('TEMP',              $temp,    'Process')
    [Environment]::SetEnvironmentVariable('TMP',               $temp,    'Process')
    [Environment]::SetEnvironmentVariable('PROGRAMFILES',      $pf,      'Process')
    [Environment]::SetEnvironmentVariable('ProgramFiles(x86)', $pf86,    'Process')

    # --- lift the functions out of the script under test ---------------------
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw "script under test does not parse: $($errors[0].Message)" }
    $funcs = @($ast.EndBlock.Statements | Where-Object { $_ -is [System.Management.Automation.Language.FunctionDefinitionAst] })
    Write-Output ("functions lifted  : {0}" -f $funcs.Count)

    # Script-scope state the functions expect. These mirror the script's own
    # top-of-file assignments; the parameters become plain variables.
    $DryRun             = $false
    $Force              = $true
    $KeepCli            = $false
    $RemoveExtensions   = $false
    $IncludeOtherDrives = $false
    $script:LogPath     = Join-Path $fx 'test.log'
    $script:Failures    = [System.Collections.Generic.List[string]]::new()
    $script:CliRoots    = @()
    $script:CliKept     = [System.Collections.Generic.List[string]]::new()
    $script:SystemDrive = "$env:SystemDrive".TrimEnd('\')
    $script:Protected   = [System.Collections.Generic.List[string]]::new()
    $script:Preserved   = [System.Collections.Generic.List[string]]::new()
    $script:DefaultExtRoots = @("$env:APPDATA\pyRevit\Extensions", "$env:PROGRAMDATA\pyRevit\Extensions")
    $UninstallRoots     = @()

    . ([scriptblock]::Create((($funcs | ForEach-Object { $_.Extent.Text }) -join "`r`n")))
    # The fixture has no registry. Everything else the functions touch is on disk.
    function Get-PyRevitRegistrations { @() }
    # Keep the script's console chatter out of the test output; the log file still gets it.
    function Write-Host { param([Parameter(ValueFromRemainingArguments)]$Rest, $ForegroundColor) }

    function Test-LogHas { param([string]$Pattern) (Get-Content -LiteralPath $script:LogPath -ErrorAction SilentlyContinue) -match $Pattern }

    if ($ExpectDefective) {
        # --- prove the harness can fail: the pre-fix code must exhibit the defect
        Write-Output ''
        Write-Output 'Baseline behaviour (the defect must reproduce for this run to PASS):'
        $DryRun = $true
        $found = @(Get-PyRevitFolders)
        Assert ($found -icontains $workspace) "pre-fix discovery lists the registered extension workspace as a folder to sweep: $workspace"
        Remove-Tree $workspace
        Assert (Test-LogHas ('would remove: ' + [regex]::Escape($workspace))) 'pre-fix Remove-Tree would have deleted it (dry run logged "would remove")'
        Assert (-not (Get-Command Test-DeletionAllowed -ErrorAction SilentlyContinue)) 'pre-fix copy has no Test-DeletionAllowed (this really is the old code)'
    } else {
        # --- 1. config is read by key, not by shape ------------------------------
        Write-Output ''
        Write-Output '1. pyRevit_config.ini is read by section and key:'
        $cfg = Get-PyRevitConfig
        Assert (@($cfg.UserExtensions) -icontains $workspace) "userextensions -> UserExtensions: $workspace"
        Assert (@($cfg.Clones) -icontains $master)            "clones.master -> Clones: $master"
        Assert (@($cfg.Clones) -icontains $clone2)            "clones.dev -> Clones: $clone2"
        Assert (@($cfg.Clones) -inotcontains $workspace)      'the workspace is NOT a clone candidate'

        # --- 2. classification ---------------------------------------------------
        Write-Output ''
        Write-Output '2. Paths are classified by content and location:'
        Assert ((Get-PyRevitPathClass $master)  -eq 'Clone')      "clone root (bin + pyrevitlib + pyRevitfile) -> Clone"
        Assert ((Get-PyRevitPathClass $clone2)  -eq 'Clone')      "clone on $otherDrive (bin + pyrevitlib) -> Clone"
        Assert ((Get-PyRevitPathClass $workspace) -eq 'Extensions') 'workspace holding IcZ.extension -> Extensions'
        Assert ((Get-PyRevitPathClass $mineExt) -eq 'Extensions') '*.extension folder itself -> Extensions'
        Assert ((Get-PyRevitPathClass $defExt)  -eq 'Extensions') 'default Extensions folder (holds *.extension) -> Extensions'
        Assert ((Get-PyRevitPathClass $cfgDir)  -eq 'Footprint')  'config folder under %APPDATA% -> Footprint'
        Assert ((Get-PyRevitPathClass $cache)   -eq 'Footprint')  'cache folder under %LOCALAPPDATA% -> Footprint'
        Assert ((Get-PyRevitPathClass $cli)     -eq 'CliInstall') 'pyRevit CLI install folder -> CliInstall'
        Assert ((Get-PyRevitPathClass $notes)   -eq 'Unverified') 'pyRevit-notes under the profile (no markers) -> Unverified'

        # --- 3. the fences -------------------------------------------------------
        Write-Output ''
        Write-Output '3. Test-DeletionAllowed (protection built the way MAIN builds it):'
        foreach ($p in $cfg.UserExtensions)     { Add-Protected $p }
        foreach ($e in $script:DefaultExtRoots) { Add-Protected $e }
        Assert (-not (Test-DeletionAllowed -Path $workspace).Allowed) 'registered workspace: REFUSED'
        Assert (-not (Test-DeletionAllowed -Path (Join-Path $workspace 'IcZ.extension')).Allowed) 'folder inside the workspace: REFUSED'
        Assert (-not (Test-DeletionAllowed -Path $defExt).Allowed)    'default Extensions folder without -RemoveExtensions: REFUSED'
        Assert (-not (Test-DeletionAllowed -Path $clone2).Allowed)    "clone on $otherDrive without -IncludeOtherDrives: REFUSED (drive fence)"
        Assert (-not (Test-DeletionAllowed -Path $notes).Allowed)     'unverified folder under the profile: REFUSED (marker fence)'
        Assert (-not (Test-DeletionAllowed -Path $noName).Allowed)    'path with no pyRevit segment: REFUSED (name fence)'
        Assert ((Test-DeletionAllowed -Path $master).Allowed)         'clone under %APPDATA%: allowed'
        Assert ((Test-DeletionAllowed -Path $cfgDir).Allowed)         'config folder: allowed (carve-out will keep Extensions)'
        Assert ((Test-DeletionAllowed -Path $cache).Allowed)          'cache folder: allowed'
        Assert ((Test-DeletionAllowed -Path $tmpDir).Allowed)         '%TEMP%\pyrevit_tmp: allowed'
        $IncludeOtherDrives = $true
        Assert ((Test-DeletionAllowed -Path $clone2).Allowed)         "clone on $otherDrive WITH -IncludeOtherDrives: allowed"
        Assert (-not (Test-DeletionAllowed -Path $workspace).Allowed) 'registered workspace WITH -IncludeOtherDrives: still REFUSED'
        $IncludeOtherDrives = $false

        # --- 4. discovery never proposes the workspace ---------------------------
        Write-Output ''
        Write-Output '4. Get-PyRevitFolders:'
        $found = @(Get-PyRevitFolders)
        Assert ($found -inotcontains $workspace) 'does NOT list the registered workspace'
        Assert ($found -icontains $master)       'lists the clone'
        Assert ($found -icontains $clone2)       "lists the $otherDrive clone as a CANDIDATE (the fence decides)"
        Assert ($found -icontains $cache)        'lists the cache folder'
        Assert ($found -icontains $notes)        'lists pyRevit-notes as a candidate (the fence decides)'

        # --- 5. real deletions inside the fixture --------------------------------
        Write-Output ''
        Write-Output '5. Remove-Tree for real (DryRun off), inside the fixture:'
        $DryRun = $false
        Remove-Tree $workspace
        Assert (Test-Path -LiteralPath (Join-Path $workspace 'IcZ.extension\lib\tool.py')) 'workspace on the other drive survives Remove-Tree'
        Assert (@($script:Failures | Where-Object { $_ -like 'guard:*' }).Count -ge 1) 'and the refusal is recorded as a guard failure'
        Remove-Tree $notes
        Assert (Test-Path -LiteralPath (Join-Path $notes 'readme.txt')) 'pyRevit-notes survives Remove-Tree'
        Remove-Tree $clone2
        Assert (Test-Path -LiteralPath (Join-Path $clone2 'pyrevitlib')) "clone on $otherDrive survives without -IncludeOtherDrives"
        Remove-Tree $cfgDir
        Assert (-not (Test-Path -LiteralPath (Join-Path $cfgDir 'pyRevit_config.ini'))) 'config folder: pyRevit_config.ini removed'
        Assert (Test-Path -LiteralPath (Join-Path $mineExt 'lib\mine.py'))           'config folder: Extensions\Mine.extension carved out and kept'
        Assert (Test-IsPreservedPath $defExt)                                          'the kept Extensions folder is recorded as preserved'
        Remove-Tree $master
        Assert (-not (Test-Path -LiteralPath $master)) 'clone under %APPDATA% removed'
        Remove-Tree $cache
        Assert (-not (Test-Path -LiteralPath $cache))  'cache folder removed'
        $IncludeOtherDrives = $true
        Remove-Tree $clone2
        Assert (-not (Test-Path -LiteralPath $clone2)) "clone on $otherDrive removed WITH -IncludeOtherDrives"
        Remove-Tree $workspace
        Assert (Test-Path -LiteralPath (Join-Path $workspace 'IcZ.extension\lib\tool.py')) 'workspace still survives WITH -IncludeOtherDrives'
        $IncludeOtherDrives = $false

        # --- 6. the verdict does not count what was kept on purpose --------------
        Write-Output ''
        Write-Output '6. Phase-9 leftover filter after the sweep:'
        Add-Preserved $notes
        $left = @(Get-PyRevitFolders | Where-Object {
            -not ($KeepCli -and (Test-IsCliPath $_)) -and
            -not (Test-IsPreservedPath $_) -and
            -not (Test-HasPreservedInside $_) -and
            (Test-DeletionAllowed -Path $_).Allowed })
        # The CLI folder and %TEMP%\pyrevit_tmp were never swept in this test, so
        # they are the only legitimate leftovers.
        $unexpected = @($left | Where-Object { $_ -ine $cli -and $_ -ine $tmpDir })
        Assert ($unexpected.Count -eq 0) ("no unexpected leftovers (got: {0})" -f ($(if ($unexpected) { $unexpected -join '; ' } else { 'none' })))
        Assert ($left -inotcontains $cfgDir) 'config folder (kept only for its Extensions) is not a leftover'
        Assert ($left -inotcontains $notes)  'pyRevit-notes (preserved) is not a leftover'
    }
}
finally {
    foreach ($n in $realEnv.Keys) { [Environment]::SetEnvironmentVariable($n, $realEnv[$n], 'Process') }
    if ($letter) { & subst.exe "$($letter):" /D 2>$null | Out-Null }
    if (Test-Path -LiteralPath $fx) { Remove-Item -LiteralPath $fx -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Output ''
Write-Output ("RESULT: {0} passed, {1} failed" -f $script:Pass, $script:Fail)
if ($script:Fail -gt 0) { exit 1 }
exit 0
