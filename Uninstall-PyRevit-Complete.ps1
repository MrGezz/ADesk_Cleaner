# =============================================================================
# Uninstall-PyRevit-Complete.ps1
#
# Full removal of pyRevit + pyRevit CLI: runs the shipped Inno Setup
# uninstallers first (so Windows' "installed programs" registration is
# retired cleanly), then sweeps whatever they leave behind, then verifies.
#
# Close Revit first. Elevation is OPTIONAL - pyRevit's default install is
# per-user. Elevate only if you used the *_admin_signed.exe installer or
# have anything under %PROGRAMDATA% / %PROGRAMFILES%.
# =============================================================================

[CmdletBinding()]
param(
    [Alias('WhatIf')]
    [switch]$DryRun,            # show what would happen, change nothing

    [switch]$Force,             # no confirmation prompts

    [switch]$KeepCli            # leave pyRevit CLI installed: registration, files AND PATH
)

$ErrorActionPreference = 'Continue'
$script:LogPath  = Join-Path $env:TEMP ("pyrevit_uninstall_{0}.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
$script:Failures = [System.Collections.Generic.List[string]]::new()
# Install root(s) of the CLI, snapshotted in phase 3 from the same registration
# objects the -KeepCli guard tests, and everything -KeepCli deliberately left
# behind so phase 9 can report it as intentional instead of as a leftover.
$script:CliRoots = @()
$script:CliKept  = [System.Collections.Generic.List[string]]::new()

# -----------------------------------------------------------------------------
# Infrastructure
# -----------------------------------------------------------------------------

function Write-Log {
    param([string]$Message, [ValidateSet('INFO','WARN','ERROR','OK','DRY')][string]$Level = 'INFO')
    $line = "{0} | {1,-5} | {2}" -f (Get-Date -Format 'HH:mm:ss'), $Level, $Message
    switch ($Level) {
        'WARN'  { Write-Host $line -ForegroundColor Yellow }
        'ERROR' { Write-Host $line -ForegroundColor Red }
        'OK'    { Write-Host $line -ForegroundColor Green }
        'DRY'   { Write-Host $line -ForegroundColor Cyan }
        default { Write-Host $line }
    }
    Add-Content -LiteralPath $script:LogPath -Value $line -Encoding utf8
}

function Write-Section {
    param([string]$Title)
    Write-Host ''
    Write-Log ("---- {0} " -f $Title).PadRight(72,'-')
}

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $id).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Deletion that survives read-only attributes and >260-char paths.
# Windows PowerShell 5.1's Remove-Item is not long-path aware even when
# LongPathsEnabled=1, and pyRevit clones nest deeply under site-packages.
function Remove-Tree {
    param([string]$Path, [string]$Why = '')

    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    if (-not (Test-Path -LiteralPath $Path)) { return }

    $trimmed = $Path.TrimEnd('\')
    if ($trimmed.Length -le 3 -or $trimmed -notmatch '\\') {
        Write-Log "refusing to delete drive root or bare path: $Path" 'ERROR'
        return
    }

    # Containment belongs HERE, not at the call sites. It used to be applied only
    # by the discovery functions' globs, plus the robocopy branch below - so the
    # Remove-Item and rd paths were ungated, and a new call site would reach
    # "-Recurse -Force" with no check at all. One of the current inputs comes out
    # of a user-editable INI. Both existing call sites already satisfy this, so
    # it changes nothing today and refuses the mistake tomorrow.
    if ($trimmed -inotmatch 'pyrevit') {
        Write-Log "refusing to delete a path that does not name pyRevit: $Path" 'ERROR'
        $script:Failures.Add("guard: $Path")
        return
    }

    $label = $Path
    if ($Why) { $label = "$Path   ($Why)" }

    if ($DryRun) { Write-Log "would remove: $label" 'DRY'; return }

    try {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
    } catch {
        # git clones ship read-only objects and Inno ships hidden/system files,
        # but Remove-Item -Force already clears both - so attrib only earns its
        # recursive walk, and its process spawn, once that has actually failed.
        # A pyRevit clone is 40-80k files; paying for it up front cost that walk
        # on every delete in phases 5 and 6.
        if (Test-Path -LiteralPath $Path -PathType Container) {
            & attrib.exe -r -s -h "$trimmed\*" /s /d 2>$null | Out-Null
        }
        # fallback 1: cmd's rd, which tolerates some paths Remove-Item won't
        & cmd.exe /c rd /s /q "$trimmed" 2>$null | Out-Null
        # fallback 2: robocopy-mirror an empty dir over it (long-path safe).
        # /MIR empties the target; the function-level guard above is what keeps
        # it away from anything the globs matched loosely.
        if (Test-Path -LiteralPath $Path) {
            $empty = Join-Path $env:TEMP ("_pyrv_empty_{0}" -f $PID)
            New-Item -ItemType Directory -Path $empty -Force | Out-Null
            & robocopy.exe $empty "$trimmed" /MIR /NJH /NJS /NP /NFL /NDL 2>$null | Out-Null
            & cmd.exe /c rd /s /q "$trimmed" 2>$null | Out-Null
            Remove-Item -LiteralPath $empty -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    if (Test-Path -LiteralPath $Path) {
        Write-Log "FAILED to remove: $label" 'ERROR'
        $script:Failures.Add("path: $Path")
    } else {
        Write-Log "removed: $label" 'OK'
    }
}

function Remove-RegKey {
    param([string]$Path, [string]$Why = '')
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $label = $Path
    if ($Why) { $label = "$Path   ($Why)" }

    if ($DryRun) { Write-Log "would remove reg key: $label" 'DRY'; return }
    try {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
        Write-Log "removed reg key: $label" 'OK'
    } catch {
        Write-Log "FAILED to remove reg key $label : $($_.Exception.Message)" 'ERROR'
        $script:Failures.Add("reg: $Path")
    }
}

# -----------------------------------------------------------------------------
# Discovery
# -----------------------------------------------------------------------------

# Every place Windows records an installed program, across both bitnesses
# and both scopes. pyRevit's default installers register per-user (HKCU).
$UninstallRoots = @(
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
)

# --- "Is this the CLI rather than pyRevit itself?" - one definition ----------
# -KeepCli has to answer this in five places: the registration guard (phases 3
# and 7), the folder sweep (5), the Start Menu sweep (6), the PATH edit (8) and
# the verdict (9). It used to be answered only in phase 3, so a -KeepCli run left
# the CLI REGISTERED while phase 5 deleted its install folder and phase 8 dropped
# its PATH entry - manufacturing exactly the orphaned registration this script
# exists to repair (README: deleting the install folder without running
# unins000.exe ORPHANS that registry key). These two tests are the single source
# of truth; nothing below re-decides "is this the CLI" on its own.
function Test-IsCliName {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    return ($Value -imatch 'pyrevit\s*cli')
}

# Folder / PATH-segment form of the same question. The name test alone already
# covers the documented default location - %LOCALAPPDATA%\Programs\pyRevit CLI,
# confirmed on 6.4.0 and hard-coded as a CLI probe candidate below - while
# $script:CliRoots adds the InstallLocation the CLI's own registration reports,
# so a CLI whose path carries no "pyRevit CLI" token is protected too.
function Test-IsCliPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }

    # PATH is read raw so REG_EXPAND_SZ survives, which means a segment can still
    # be "%LOCALAPPDATA%\Programs\pyRevit CLI\bin". Test both forms.
    $forms    = @($Path.Trim().Trim('"'))
    $expanded = [Environment]::ExpandEnvironmentVariables($forms[0])
    if ($expanded -ne $forms[0]) { $forms += $expanded }

    foreach ($f in $forms) {
        if (Test-IsCliName $f) { return $true }
        $t = $f.TrimEnd('\')
        foreach ($root in @($script:CliRoots)) {
            if (-not $root) { continue }
            # StartsWith rather than -like: an install path may legitimately
            # contain '[', which -like would read as a wildcard.
            if ($t.Equals($root, [StringComparison]::OrdinalIgnoreCase) -or
                $t.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) { return $true }
        }
    }
    return $false
}

function Get-PyRevitRegistrations {
    foreach ($root in $UninstallRoots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue | ForEach-Object {
            $key = $_
            $p = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction SilentlyContinue
            $hit = ($key.PSChildName -imatch 'pyrevit') -or
                   ($p.DisplayName   -imatch 'pyrevit') -or
                   ($p.Publisher     -imatch 'pyrevit') -or
                   ($p.InstallLocation -imatch 'pyrevit')
            if ($hit) {
                $isCli = (Test-IsCliName $p.DisplayName) -or (Test-IsCliName $p.InstallLocation)
                [pscustomobject]@{
                    RegPath   = $key.PSPath
                    Pretty    = ($key.PSPath -replace '^.*Registry::','')
                    Name      = $p.DisplayName
                    Version   = $p.DisplayVersion
                    Location  = $p.InstallLocation
                    UninStr   = $p.UninstallString
                    QuietStr  = $p.QuietUninstallString
                    IsCli     = $isCli
                }
            }
        }
    }
}

# Clone locations recorded in pyRevit_config.ini - catches custom install
# directories that a fixed folder list would never find.
function Get-ConfiguredClonePaths {
    $inis = @(
        "$env:APPDATA\pyRevit\pyRevit_config.ini"
        "$env:PROGRAMDATA\pyRevit\pyRevit_config.ini"
    )
    $found = [System.Collections.Generic.List[string]]::new()
    foreach ($ini in $inis) {
        if (-not (Test-Path -LiteralPath $ini)) { continue }
        foreach ($line in (Get-Content -LiteralPath $ini -ErrorAction SilentlyContinue)) {
            foreach ($m in [regex]::Matches($line, '[A-Za-z]:\\{1,2}[^"'',;\]\r\n]+')) {
                $p = ($m.Value -replace '\\\\','\').TrimEnd('\','"',' ')
                if ($p -imatch 'pyrevit' -and (Test-Path -LiteralPath $p -PathType Container)) {
                    if (-not $found.Contains($p)) { $found.Add($p) }
                }
            }
        }
    }
    $found
}

function Get-PyRevitFolders {
    $parents = @(
        $env:APPDATA
        $env:LOCALAPPDATA
        "$env:LOCALAPPDATA\Programs"          # <-- pyRevit CLI 5.x/6.x lands here
        $env:PROGRAMDATA
        $env:PROGRAMFILES
        ${env:ProgramFiles(x86)}
        $env:USERPROFILE
        $env:TEMP
        "$env:SystemDrive\"
    ) | Where-Object { $_ } | Select-Object -Unique

    $found = [System.Collections.Generic.List[string]]::new()
    foreach ($parent in $parents) {
        if (-not (Test-Path -LiteralPath $parent)) { continue }
        Get-ChildItem -LiteralPath $parent -Directory -Filter '*pyrevit*' -Force -ErrorAction SilentlyContinue |
            ForEach-Object { if (-not $found.Contains($_.FullName)) { $found.Add($_.FullName) } }
    }
    foreach ($p in (Get-ConfiguredClonePaths)) {
        if (-not $found.Contains($p)) { $found.Add($p) }
    }
    $found
}

function Get-PyRevitAddinFiles {
    $roots = @(
        "$env:APPDATA\Autodesk\Revit\Addins"
        "$env:PROGRAMDATA\Autodesk\Revit\Addins"
        "$env:PROGRAMDATA\Autodesk\ApplicationPlugins"
        "$env:APPDATA\Autodesk\ApplicationPlugins"
    )
    Get-ChildItem -LiteralPath "$env:PROGRAMFILES\Autodesk" -Directory -Filter 'Revit*' -ErrorAction SilentlyContinue |
        ForEach-Object { $roots += (Join-Path $_.FullName 'AddIns') }

    $found = [System.Collections.Generic.List[string]]::new()
    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        Get-ChildItem -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -imatch 'pyrevit' } |
            ForEach-Object { if (-not $found.Contains($_.FullName)) { $found.Add($_.FullName) } }
    }
    $found
}

# -----------------------------------------------------------------------------
# PATH cleanup that preserves REG_EXPAND_SZ and never rewrites needlessly
# -----------------------------------------------------------------------------

function Remove-PyRevitFromPath {
    param([ValidateSet('User','Machine')][string]$Scope)

    $keyPath = if ($Scope -eq 'User') { 'HKCU:\Environment' }
               else { 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment' }

    if (-not (Test-Path -LiteralPath $keyPath)) { return }
    if ($Scope -eq 'Machine' -and -not (Test-IsAdmin)) {
        Write-Log 'Machine PATH: NOT CHECKED (needs elevation)' 'WARN'
        return
    }

    $key = Get-Item -LiteralPath $keyPath
    # DoNotExpandEnvironmentNames is the whole point: reading the *expanded*
    # value and writing it back bakes %SystemRoot% into a literal path and
    # downgrades REG_EXPAND_SZ to REG_SZ. That is how PATHs get corrupted.
    $raw = $key.GetValue('Path', $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    if (-not $raw) { return }
    $kind = $key.GetValueKind('Path')

    $parts = $raw -split ';'
    $hits  = @($parts | Where-Object { $_ -imatch 'pyrevit' })

    # -KeepCli protects the CLI's own bin entry for the same reason phase 3
    # leaves its registration alone: a CLI that is still installed and still
    # registered but no longer resolves on PATH has not been "kept", it has been
    # broken - and the operator asked for it precisely so they could keep driving
    # clones with it.
    $cliKeep = @($hits | Where-Object { $KeepCli -and (Test-IsCliPath $_) })
    $dropped = @($hits | Where-Object { $cliKeep -notcontains $_ })
    $keep    = @($parts | Where-Object { $dropped -notcontains $_ })

    foreach ($k in $cliKeep) {
        Write-Log "$Scope PATH entry kept (-KeepCli, belongs to pyRevit CLI): $k" 'WARN'
        $script:CliKept.Add("$Scope PATH: $k")
    }

    if ($dropped.Count -eq 0) {
        if ($cliKeep.Count -eq 0) { Write-Log "$Scope PATH: no pyRevit entries" }
        else { Write-Log "$Scope PATH: only pyRevit CLI entries present - nothing to remove" }
        return
    }
    foreach ($d in $dropped) { Write-Log "$Scope PATH entry to drop: $d" }

    if ($DryRun) { Write-Log "would rewrite $Scope PATH (kind $kind, empty segments preserved)" 'DRY'; return }

    try {
        # Set-ItemProperty with the original kind; empty segments are kept as-is
        Set-ItemProperty -LiteralPath $keyPath -Name 'Path' -Value ($keep -join ';') -Type $kind -Force -ErrorAction Stop
        Write-Log "cleaned $Scope PATH (kind preserved: $kind)" 'OK'
    } catch {
        Write-Log "FAILED to clean $Scope PATH : $($_.Exception.Message)" 'ERROR'
        $script:Failures.Add("$Scope PATH")
    }
}

function Publish-EnvironmentChange {
    if ($DryRun) { return }
    if (-not ('PyRvEnvBroadcast' -as [type])) {
        Add-Type -Namespace '' -Name 'PyRvEnvBroadcast' -MemberDefinition @'
[DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, UIntPtr wParam,
    string lParam, uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
'@ -ErrorAction SilentlyContinue
    }
    try {
        $r = [UIntPtr]::Zero
        [PyRvEnvBroadcast]::SendMessageTimeout([IntPtr]0xffff, 0x1A, [UIntPtr]::Zero, 'Environment', 2, 3000, [ref]$r) | Out-Null
        Write-Log 'broadcast WM_SETTINGCHANGE (open apps pick up new PATH)'
    } catch { }
}

# =============================================================================
# MAIN
# =============================================================================

Write-Log '=== pyRevit complete uninstall ==='
Write-Log "log: $script:LogPath"
if ($DryRun) { Write-Log 'DRY RUN - nothing will be modified' 'WARN' }
if (Test-IsAdmin) { Write-Log 'running elevated (machine-wide scopes included)' }
else { Write-Log 'running unelevated - HKLM / ProgramData / ProgramFiles will be skipped' 'WARN' }

# --- 0. Revit must not be running ------------------------------------------
Write-Section '0. Host applications'
$procNames = @('Revit','pyrevit','pyrevit-telemetryserver','pyrevit-doctor')
$live = Get-Process -Name $procNames -ErrorAction SilentlyContinue
if ($live) {
    foreach ($p in $live) { Write-Log "running: $($p.ProcessName) (pid $($p.Id))" 'WARN' }
    if ($DryRun) {
        Write-Log 'would stop the processes above' 'DRY'
    } else {
        $go = $Force
        if (-not $go) {
            $ans = Read-Host 'Stop these processes now? Unsaved Revit work will be LOST. (y/N)'
            $go = ($ans -eq 'y')
        }
        if (-not $go) { Write-Log 'aborted - close Revit and re-run' 'ERROR'; exit 1 }
        $live | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 3
    }
} else {
    Write-Log 'no Revit / pyRevit processes running'
}

# --- 1. Let the CLI detach itself while it still exists ---------------------
# Correct verbs, verified against `pyrevit --help`:
#   revits killall | detach --all | clones forget --all | caches clear --all
# ("clear all" and "clone --all" are NOT commands - they just print usage.)
Write-Section '1. Graceful detach via pyRevit CLI'
$cliExe = $null
$cliCandidates = @(
    (Get-Command pyrevit.exe -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source)
    "$env:LOCALAPPDATA\Programs\pyRevit CLI\bin\pyrevit.exe"
    "$env:APPDATA\pyRevit-Master\bin\pyrevit.exe"
    "$env:PROGRAMFILES\pyRevit CLI\bin\pyrevit.exe"
) | Where-Object { $_ }
foreach ($c in $cliCandidates) { if (Test-Path -LiteralPath $c) { $cliExe = $c; break } }

if (-not $cliExe) {
    Write-Log 'pyrevit.exe not found - skipping graceful detach'
} elseif ($DryRun) {
    Write-Log "would run: `"$cliExe`" revits killall / detach --all / clones forget --all / caches clear --all" 'DRY'
} else {
    Write-Log "using CLI: $cliExe"
    $cliArgs = @(
        @('revits','killall'),
        @('detach','--all'),
        @('clones','forget','--all'),
        @('caches','clear','--all')
    )
    foreach ($a in $cliArgs) {
        Write-Log ("  > pyrevit {0}" -f ($a -join ' '))
        $out = & $cliExe @a 2>&1
        # A usage dump means the verb was rejected - surface that instead of
        # logging 40 lines of help text as if it succeeded.
        if ($out -match 'Usage: pyrevit COMMAND') {
            Write-Log ("    rejected by CLI: 'pyrevit {0}' is not valid on this version" -f ($a -join ' ')) 'WARN'
        } else {
            $out | Where-Object { "$_".Trim() } | Select-Object -First 8 |
                ForEach-Object { Write-Log "    $_" }
        }
    }
}

# --- 2. Back up extensions before anything is deleted ----------------------
Write-Section '2. User extensions'
$extRoots = @("$env:APPDATA\pyRevit\Extensions", "$env:PROGRAMDATA\pyRevit\Extensions")
$extFound = @($extRoots | Where-Object { Test-Path -LiteralPath $_ } |
    Where-Object { @(Get-ChildItem -LiteralPath $_ -Force -ErrorAction SilentlyContinue).Count -gt 0 })

if (-not $extFound) {
    Write-Log 'no populated extensions folder found'
} else {
    $backup = Join-Path ([Environment]::GetFolderPath('Desktop')) ("pyRevit_Extensions_Backup_{0}" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
    foreach ($e in $extFound) {
        Write-Log "extensions present: $e" 'WARN'
        Get-ChildItem -LiteralPath $e -Directory -Force -ErrorAction SilentlyContinue |
            ForEach-Object { Write-Log "    - $($_.Name)" }
    }
    if ($DryRun) {
        Write-Log "would back up the above to: $backup" 'DRY'
    } else {
        New-Item -ItemType Directory -Path $backup -Force | Out-Null
        foreach ($e in $extFound) {
            $dest = Join-Path $backup ((Split-Path (Split-Path $e -Parent) -Leaf) + '_Extensions')
            Copy-Item -LiteralPath $e -Destination $dest -Recurse -Force -ErrorAction SilentlyContinue
        }
        Write-Log "backed up extensions to: $backup" 'OK'
    }
    # These sit inside the clone directory, so a full uninstall always takes
    # them. The backup above is the recovery path - there is no switch to
    # preserve them in place without leaving the clone itself behind.
    Write-Log 'NOTE: extensions live inside the clone dir and WILL be deleted with it.' 'WARN'
    Write-Log '      Restore from the backup above after reinstalling.' 'WARN'
}

# --- 3. Run the shipped Inno Setup uninstallers -----------------------------
# This is the step the original script skipped. Deleting the install folder
# without running unins000.exe orphans the Apps & Features registration, and
# the pyRevit installer then reports a leftover installation.
Write-Section '3. Registered pyRevit installations'
$regs = @(Get-PyRevitRegistrations)
# Snapshot the CLI's install root from the SAME objects the -KeepCli guard below
# tests, and do it before any uninstaller runs, so phases 5/8/9 preserve exactly
# what phase 3 preserved instead of re-deriving it from a machine that has since
# changed underneath them.
if ($KeepCli) {
    $script:CliRoots = @($regs | Where-Object { $_.IsCli } |
        ForEach-Object { "$($_.Location)".Trim().Trim('"').TrimEnd('\') } |
        # An InstallLocation whose LEAF is not itself pyRevit-named is a parent
        # directory, not an install root - the trap the Navisworks script hit
        # with ODIS wrappers registering "C:\Program Files\Autodesk". Accepting
        # "...\Programs" here would protect every clone installed beside the CLI
        # and let phase 9 call the run CLEAN with pyRevit still on disk.
        Where-Object { $_ -and (($_ -split '\\')[-1] -imatch 'pyrevit') } |
        Select-Object -Unique)
}
if (-not $regs) {
    Write-Log 'no pyRevit entries in the Windows uninstall registry'
} else {
    foreach ($r in $regs) {
        Write-Log ("found: {0} {1}" -f $r.Name, $r.Version)
        Write-Log ("       location : {0}" -f $r.Location)
        Write-Log ("       reg key  : {0}" -f $r.Pretty)
    }
}

foreach ($r in $regs) {
    if ($r.IsCli -and $KeepCli) {
        Write-Log "skipping (-KeepCli): $($r.Name)" 'WARN'
        $script:CliKept.Add("registration: $($r.Name)")
        continue
    }

    $cmd = $r.QuietStr
    if (-not $cmd) { $cmd = $r.UninStr }

    # Extract just the executable. Install paths contain spaces
    # ("...\Programs\pyRevit CLI\unins000.exe"), so a whitespace-delimited
    # split would truncate the path - honour the quoting instead.
    $exe = ''
    if ($cmd) {
        $c = $cmd.Trim()
        if ($c.StartsWith('"')) {
            $close = $c.IndexOf('"', 1)
            if ($close -gt 1) { $exe = $c.Substring(1, $close - 1) }
        } else {
            $exe = ($c -replace '\s+[/-][^\\]*$','').Trim()   # strip trailing switches
        }
    }

    if (-not $exe -or -not (Test-Path -LiteralPath $exe)) {
        Write-Log "uninstaller missing for '$($r.Name)' - registration is orphaned, will drop the key" 'WARN'
        Remove-RegKey $r.RegPath "orphaned registration: $($r.Name)"
        continue
    }

    if ($DryRun) { Write-Log "would run: `"$exe`" /VERYSILENT /SUPPRESSMSGBOXES /NORESTART" 'DRY'; continue }

    Write-Log "running uninstaller: $exe"
    try {
        Start-Process -FilePath $exe -ArgumentList '/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART' -Wait -ErrorAction Stop
    } catch {
        Write-Log "could not launch uninstaller: $($_.Exception.Message)" 'WARN'
    }
    # Inno relaunches itself from %TEMP% (_iu*.tmp) and the first process exits
    # immediately, so -Wait alone is not enough. Poll until the key is gone.
    $deadline = (Get-Date).AddSeconds(120)
    while ((Test-Path -LiteralPath $r.RegPath) -and (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 750
    }
    if (Test-Path -LiteralPath $r.RegPath) {
        Write-Log "uninstaller did not retire '$($r.Name)' within 120s - removing key directly" 'WARN'
        Remove-RegKey $r.RegPath "stale registration: $($r.Name)"
    } else {
        Write-Log "uninstalled: $($r.Name)" 'OK'
    }
}

# --- 4. Revit .addin manifests and loader DLLs ------------------------------
Write-Section '4. Revit add-in manifests'
$addins = @(Get-PyRevitAddinFiles)
if (-not $addins) { Write-Log 'no pyRevit add-in manifests found' }
foreach ($a in $addins) {
    if ($DryRun) { Write-Log "would remove: $a" 'DRY'; continue }
    try {
        Remove-Item -LiteralPath $a -Force -Recurse -ErrorAction Stop
        Write-Log "removed: $a" 'OK'
    } catch {
        Write-Log "FAILED to remove $a : $($_.Exception.Message)" 'ERROR'
        $script:Failures.Add("addin: $a")
    }
}

# --- 5. Leftover folders ----------------------------------------------------
Write-Section '5. Leftover folders'
$folders = @(Get-PyRevitFolders)
if (-not $folders) { Write-Log 'no pyRevit folders remain' }
foreach ($f in $folders) {
    # The '*pyrevit*' glob over %LOCALAPPDATA%\Programs returns 'pyRevit CLI' -
    # the CLI's own install folder, holding the unins000.exe that phase 3 was
    # told not to run. Deleting it here is what turned -KeepCli into "keep the
    # registration, destroy the product".
    if ($KeepCli -and (Test-IsCliPath $f)) {
        Write-Log "keeping (-KeepCli, pyRevit CLI install folder): $f" 'WARN'
        $script:CliKept.Add("folder: $f")
        continue
    }
    if (-not (Test-IsAdmin)) {
        if ($f -like "$env:PROGRAMDATA*" -or $f -like "$env:PROGRAMFILES*" -or $f -like "${env:ProgramFiles(x86)}*") {
            Write-Log "skipping (needs elevation): $f" 'WARN'
            $script:Failures.Add("needs-admin: $f")
            continue
        }
    }
    Remove-Tree $f
}

# --- 6. Start Menu shortcuts ------------------------------------------------
Write-Section '6. Start Menu shortcuts'
$menuRoots = @(
    "$env:APPDATA\Microsoft\Windows\Start Menu\Programs"
    "$env:PROGRAMDATA\Microsoft\Windows\Start Menu\Programs"
)
$shortcuts = @()
foreach ($m in $menuRoots) {
    if (-not (Test-Path -LiteralPath $m)) { continue }
    $shortcuts += @(Get-ChildItem -LiteralPath $m -Recurse -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -imatch 'pyrevit' })
}
if (-not $shortcuts) { Write-Log 'no pyRevit Start Menu entries' }
foreach ($s in $shortcuts) {
    # Same guard as phase 5, for the same reason: a kept CLI keeps its shortcut.
    if ($KeepCli -and (Test-IsCliPath $s.FullName)) {
        Write-Log "keeping (-KeepCli, pyRevit CLI shortcut): $($s.FullName)" 'WARN'
        $script:CliKept.Add("start menu: $($s.FullName)")
        continue
    }
    Remove-Tree $s.FullName 'start menu'
}

# --- 7. Remaining registry footprint ---------------------------------------
Write-Section '7. Registry footprint'
$regPaths = @(
    'HKCU:\Software\pyRevitLabs'
    'HKCU:\Software\pyRevit'
    'HKLM:\SOFTWARE\pyRevitLabs'
    'HKLM:\SOFTWARE\pyRevit'
    'HKLM:\SOFTWARE\WOW6432Node\pyRevitLabs'
    'HKLM:\SOFTWARE\WOW6432Node\pyRevit'
)
$any = $false
foreach ($rp in $regPaths) {
    if (Test-Path -LiteralPath $rp) { $any = $true; Remove-RegKey $rp }
}
# Any registration that survived step 3
foreach ($r in (Get-PyRevitRegistrations)) {
    if ($r.IsCli -and $KeepCli) { continue }
    $any = $true
    Remove-RegKey $r.RegPath "leftover registration: $($r.Name)"
}
if (-not $any) { Write-Log 'no pyRevit registry keys remain' }

# --- 8. PATH ----------------------------------------------------------------
Write-Section '8. PATH environment variable'
Remove-PyRevitFromPath -Scope User
Remove-PyRevitFromPath -Scope Machine
Publish-EnvironmentChange

# --- 9. Verify --------------------------------------------------------------
Write-Section '9. Verification'
# -KeepCli leaves the CLI's registration, install folder, shortcut and PATH entry
# behind on purpose, so they are reported here as kept and excluded from the
# verdict below. Counting them would end every -KeepCli run in NOT CLEAN and bury
# any genuine leftover in that noise. Printed outside the -DryRun branch so a
# preview run states what it would preserve too.
if ($KeepCli) {
    if ($script:CliKept.Count -gt 0) {
        Write-Log 'kept by -KeepCli (pyRevit CLI stays installed, registered and on PATH):' 'WARN'
        foreach ($k in $script:CliKept) { Write-Log "    - $k" 'WARN' }
    } else {
        Write-Log '-KeepCli was specified but no pyRevit CLI was found to keep' 'WARN'
    }
}
if ($DryRun) {
    Write-Log 'skipped (dry run)' 'DRY'
} else {
    $remFolders = @(Get-PyRevitFolders | Where-Object { -not ($KeepCli -and (Test-IsCliPath $_)) })
    $remAddins  = @(Get-PyRevitAddinFiles)
    $remRegs    = @(Get-PyRevitRegistrations | Where-Object { -not ($_.IsCli -and $KeepCli) })
    $remPath    = @()
    foreach ($sc in @('User','Machine')) {
        $kp = if ($sc -eq 'User') { 'HKCU:\Environment' } else { 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment' }
        if (Test-Path -LiteralPath $kp) {
            $v = (Get-Item -LiteralPath $kp).GetValue('Path', $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            if ($v) { $remPath += @(($v -split ';') |
                Where-Object { $_ -imatch 'pyrevit' -and -not ($KeepCli -and (Test-IsCliPath $_)) } |
                ForEach-Object { "$sc PATH: $_" }) }
        }
    }

    foreach ($x in $remRegs)    { Write-Log "STILL REGISTERED: $($x.Name) -> $($x.Pretty)" 'ERROR' }
    foreach ($x in $remFolders) { Write-Log "STILL PRESENT: $x" 'ERROR' }
    foreach ($x in $remAddins)  { Write-Log "STILL PRESENT: $x" 'ERROR' }
    foreach ($x in $remPath)    { Write-Log "STILL PRESENT: $x" 'ERROR' }

    $clean = ($remFolders.Count + $remAddins.Count + $remRegs.Count + $remPath.Count) -eq 0
    Write-Host ''
    if ($clean -and $script:Failures.Count -eq 0) {
        if ($script:CliKept.Count -gt 0) {
            Write-Log 'CLEAN - nothing remains except the pyRevit CLI that -KeepCli was told to keep.' 'OK'
        } else {
            Write-Log 'CLEAN - no pyRevit files, registrations, or PATH entries remain.' 'OK'
        }
        Write-Log 'Reinstalling should no longer report a leftover installation.' 'OK'
    } else {
        Write-Log 'NOT CLEAN - items above still exist.' 'ERROR'
        if (-not (Test-IsAdmin) -and ($script:Failures | Where-Object { $_ -like 'needs-admin:*' })) {
            Write-Log 'Re-run from an elevated PowerShell to clear machine-wide items.' 'WARN'
        }
    }
}

Write-Host ''
Write-Log "log written to: $script:LogPath"
if ($DryRun) { Write-Log 'DRY RUN - re-run without -DryRun to apply.' 'WARN' }
