<#
.SYNOPSIS
    Removes pyRevit and pyRevit CLI completely - clones, Revit add-in manifests,
    Windows "installed programs" registrations, Start Menu entries and PATH
    entries - by running the shipped Inno Setup uninstallers first, then
    sweeping what they leave behind, then verifying. Never touches your own
    extensions, and never leaves the system drive unless told to.

.DESCRIPTION
    Runs each registered unins000.exe so the Windows registration is retired
    cleanly instead of orphaned (deleting the folder first is what makes the
    pyRevit installer complain about a leftover installation), then sweeps the
    clone, config, cache and CLI folders, the add-in manifests, the registry
    footprint and the PATH entries, and re-scans everything for a CLEAN /
    NOT CLEAN verdict.

    Three fences decide what the sweep may delete. All three live inside the
    deletion function, not at the call sites, so no caller can bypass them:

      Extension fence  Any folder listed under "userextensions" in
                       pyRevit_config.ini, any folder named *.extension or
                       *.lib, and any folder that directly contains such
                       folders, is a user extension area. It is NEVER deleted,
                       whatever its name and wherever it sits. The default
                       %APPDATA%\pyRevit\Extensions folder stays in place too
                       (pyRevit's own uninstaller leaves it alone) unless
                       -RemoveExtensions is given, which backs it up to the
                       Desktop first.
      Drive fence      Outside pyRevit's own footprint roots, nothing on a drive
                       other than %SystemDrive% is deleted unless
                       -IncludeOtherDrives is given - and even then only a
                       verified pyRevit clone (a folder holding bin\ and
                       pyrevitlib\), never an extension area.
      Marker fence     Outside the footprint roots (%APPDATA%, %LOCALAPPDATA%,
                       %LOCALAPPDATA%\Programs, %PROGRAMDATA%, %PROGRAMFILES%,
                       %ProgramFiles(x86)%, %TEMP%) a folder is only deleted
                       when it is a verified clone. "C:\pyRevit-notes" is
                       reported and left alone.

    Everything the fences preserve is listed in the log and excluded from the
    verdict, so a run that deliberately left things in place still ends CLEAN.

    Close Revit first. Elevation is OPTIONAL - pyRevit's default installers are
    per-user. Elevate only if you used the *_admin_signed.exe installer or have
    anything under %PROGRAMDATA% / %PROGRAMFILES%. The script does not
    self-elevate; it reports what it skipped.

.PARAMETER DryRun
    Report every intended change and modify nothing. Aliased to -WhatIf.

.PARAMETER Force
    Skip the confirmation prompt before stopping Revit. Unsaved Revit work is
    lost.

.PARAMETER KeepCli
    Leave pyRevit CLI installed: its registration, its install folder, its
    Start Menu shortcut and its PATH entry. For replacing a stale clone with
    the CLI you manage clones with.

.PARAMETER RemoveExtensions
    Also remove the default extension folders (%APPDATA%\pyRevit\Extensions and
    %PROGRAMDATA%\pyRevit\Extensions), after backing them up to a timestamped
    folder on the Desktop. Without this switch they stay in place and the rest
    of the config folder is removed around them. Extension folders registered
    by path in pyRevit_config.ini are preserved regardless of this switch.

.PARAMETER IncludeOtherDrives
    Also remove verified pyRevit clones that sit on a drive other than
    %SystemDrive%, found through pyRevit_config.ini or the Windows uninstall
    registry. Extension areas are never removed, on any drive.

.EXAMPLE
    .\Uninstall-PyRevit-Complete.ps1 -DryRun
    Preview: lists every folder, registration and PATH entry it would touch,
    and everything the fences would preserve.

.EXAMPLE
    .\Uninstall-PyRevit-Complete.ps1 -Force
    Unattended full removal.

.EXAMPLE
    .\Uninstall-PyRevit-Complete.ps1 -KeepCli
    Replace a stale clone: the CLI stays, and so do your extensions.

.EXAMPLE
    .\Uninstall-PyRevit-Complete.ps1 -Force -RemoveExtensions
    Wipe everything including the default Extensions folder (backed up to the
    Desktop first). Paths registered in pyRevit_config.ini still stay.

.NOTES
    Exit code 1 when you decline to stop Revit; a NOT CLEAN verdict is reported
    in the output, not in the exit code.
    Log: %TEMP%\pyrevit_uninstall_<timestamp>.log
#>

[CmdletBinding()]
param(
    [Alias('WhatIf')]
    [switch]$DryRun,            # show what would happen, change nothing

    [switch]$Force,             # no confirmation prompts

    [switch]$KeepCli,           # leave pyRevit CLI installed: registration, files AND PATH

    [switch]$RemoveExtensions,  # back up %APPDATA%\pyRevit\Extensions to the Desktop, then remove it

    [switch]$IncludeOtherDrives # sweep verified clones on drives other than %SystemDrive%
)

$ErrorActionPreference = 'Continue'
$script:LogPath  = Join-Path $env:TEMP ("pyrevit_uninstall_{0}.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
$script:Failures = [System.Collections.Generic.List[string]]::new()
# Install root(s) of the CLI, snapshotted in phase 3 from the same registration
# objects the -KeepCli guard tests, and everything -KeepCli deliberately left
# behind so phase 9 can report it as intentional instead of as a leftover.
$script:CliRoots = @()
$script:CliKept  = [System.Collections.Generic.List[string]]::new()
# Fences. Protected = paths this run must never delete: every user extension
# root registered in pyRevit_config.ini, plus the default Extensions folders
# unless -RemoveExtensions. Preserved = every path a fence or a switch left in
# place during this run, so phase 9 can list them as intentional and keep them
# out of the verdict.
$script:SystemDrive = "$env:SystemDrive".TrimEnd('\')
$script:Protected   = [System.Collections.Generic.List[string]]::new()
$script:Preserved   = [System.Collections.Generic.List[string]]::new()
# The two folders pyRevit itself treats as the default extension location. Not
# installer-owned - the user puts things there, and pyRevit's own uninstaller
# leaves them alone - so they stay unless -RemoveExtensions asks for the
# backup-then-delete in phase 2.
$script:DefaultExtRoots = @("$env:APPDATA\pyRevit\Extensions", "$env:PROGRAMDATA\pyRevit\Extensions")

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

    # Every fence lives HERE, not at the call sites. The containment guard used
    # to be applied only by the discovery functions' globs, plus the robocopy
    # branch below - so the Remove-Item and rd paths were ungated, and a new call
    # site would reach "-Recurse -Force" with no check at all. One of the inputs
    # comes out of a user-editable INI, and that is exactly how a user extension
    # workspace on another drive was once deleted: its path contained "pyrevit",
    # so the one substring test that existed let it through. Phase 5 evaluates
    # the same fences first in order to REPORT its decisions; this is the check
    # that enforces them.
    $verdict = Test-DeletionAllowed -Path $trimmed
    if (-not $verdict.Allowed) {
        Write-Log "refusing to delete ($($verdict.Reason)): $Path" 'ERROR'
        $script:Failures.Add("guard: $Path")
        return
    }

    # A protected subtree INSIDE this path - the default Extensions folder, or a
    # user extension root someone placed inside the config folder - is carved
    # out: the siblings go one by one and it stays standing. A sibling the fences
    # refuse on the way down is kept as well, out loud, rather than failed: this
    # loop is a policy path, not a caller that got a path wrong.
    $inside = @(Get-ProtectedInside -Path $trimmed)
    if ($inside.Count -gt 0) {
        foreach ($p in $inside) { Write-Log "carving out protected subtree: $p" 'WARN' }
        foreach ($child in @(Get-ChildItem -LiteralPath $trimmed -Force -ErrorAction SilentlyContinue)) {
            $c = $child.FullName.TrimEnd('\')
            if (Test-IsProtectedPath $c) {
                Write-Log "kept (protected): $c" 'WARN'
                Add-Preserved $c
                continue
            }
            if ($child.PSIsContainer) {
                $cv = Test-DeletionAllowed -Path $c
                if (-not $cv.Allowed) {
                    Write-Log "kept [$($cv.Class)] - $($cv.Reason): $c" 'WARN'
                    Add-Preserved $c
                    continue
                }
                Remove-Tree $c $Why
                continue
            }
            if ($DryRun) { Write-Log "would remove: $c" 'DRY'; continue }
            try {
                Remove-Item -LiteralPath $c -Force -ErrorAction Stop
                Write-Log "removed: $c" 'OK'
            } catch {
                Write-Log "FAILED to remove: $c" 'ERROR'
                $script:Failures.Add("path: $c")
            }
        }
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

# --- pyRevit_config.ini, read by SECTION and KEY ------------------------------
# The two keys that matter:
#   [environment] clones         = {"master":"C:\\...\\pyRevit-Master"}  -> clone candidates
#   [core]        userextensions = ["D:\\Dev\\MyExtensions"]             -> PROTECTED
# The previous reader scanned every line for anything shaped like a path and
# treated every hit as a clone, so it could not tell the two apart. A user
# extension workspace whose path happened to contain "pyrevit" - on another
# drive - was deleted as if it were a clone. This function exists so that can
# never recur: the value is classified by the key it belongs to, and only the
# two keys above are consulted at all.
function ConvertFrom-IniPathList {
    param([string]$Value)
    $out = [System.Collections.Generic.List[string]]::new()
    if ([string]::IsNullOrWhiteSpace($Value)) { return $out }
    foreach ($m in [regex]::Matches($Value, '[A-Za-z]:\\{1,2}[^"'',;\]\}\r\n]+')) {
        $p = ($m.Value -replace '\\\\','\').TrimEnd('\','"',' ')
        if ($p -and -not $out.Contains($p)) { $out.Add($p) }
    }
    $out
}

function Get-PyRevitConfig {
    $inis = @(
        "$env:APPDATA\pyRevit\pyRevit_config.ini"
        "$env:PROGRAMDATA\pyRevit\pyRevit_config.ini"
    )
    $files  = [System.Collections.Generic.List[string]]::new()
    $clones = [System.Collections.Generic.List[string]]::new()
    $exts   = [System.Collections.Generic.List[string]]::new()
    foreach ($ini in $inis) {
        if (-not (Test-Path -LiteralPath $ini)) { continue }
        $files.Add($ini)
        $section = ''
        foreach ($line in @(Get-Content -LiteralPath $ini -ErrorAction SilentlyContinue)) {
            $l = "$line".Trim()
            if ($l -match '^\[(.+)\]$') { $section = $Matches[1].Trim(); continue }
            if ($l -notmatch '^([^=]+?)\s*=\s*(.*)$') { continue }
            $key = $Matches[1].Trim()
            $val = $Matches[2]
            if ($section -ieq 'environment' -and $key -ieq 'clones') {
                foreach ($p in (ConvertFrom-IniPathList $val)) { if (-not $clones.Contains($p)) { $clones.Add($p) } }
            } elseif ($section -ieq 'core' -and $key -ieq 'userextensions') {
                foreach ($p in (ConvertFrom-IniPathList $val)) { if (-not $exts.Contains($p)) { $exts.Add($p) } }
            }
        }
    }
    [pscustomobject]@{ Files = @($files); Clones = @($clones); UserExtensions = @($exts) }
}

# --- Fences -------------------------------------------------------------------

# 8.3 short names and long names of the same folder compare unequal as strings:
# %TEMP% is often "C:\Users\ICECRE~1\..." while Get-ChildItem hands back
# "C:\Users\IceCreamAssasin\...". Every path that crosses a fence is normalised
# to the long form first, when it exists on disk, so a protected root written
# one way still protects a candidate discovered the other way.
function Get-NormalizedPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $Path }
    $t = $Path.Trim().Trim('"').TrimEnd('\')
    if ($t -match '~\d') {
        try {
            $item = Get-Item -LiteralPath $t -Force -ErrorAction Stop
            if ($item.FullName) { $t = $item.FullName.TrimEnd('\') }
        } catch { }
    }
    $t
}

function Add-Protected {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    $t = Get-NormalizedPath $Path
    if ($t.Length -lt 2) { return }
    if (-not ($script:Protected | Where-Object { $_.Equals($t, [StringComparison]::OrdinalIgnoreCase) })) {
        $script:Protected.Add($t)
    }
}

function Add-Preserved {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    $t = Get-NormalizedPath $Path
    if (-not ($script:Preserved | Where-Object { $_.Equals($t, [StringComparison]::OrdinalIgnoreCase) })) {
        $script:Preserved.Add($t)
    }
}

# Is this path one of the protected roots, or inside one? StartsWith with a
# trailing backslash rather than -like: a path may legitimately contain '[',
# which -like would read as a wildcard, and "D:\Ext" must not match "D:\Ext2".
function Test-IsProtectedPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    $t = Get-NormalizedPath $Path
    foreach ($p in @($script:Protected)) {
        if ($t.Equals($p, [StringComparison]::OrdinalIgnoreCase) -or
            $t.StartsWith($p + '\', [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

# Every protected root that sits INSIDE the given path.
function Get-ProtectedInside {
    param([string]$Path)
    $t = Get-NormalizedPath $Path
    @($script:Protected | Where-Object { $_.StartsWith($t + '\', [StringComparison]::OrdinalIgnoreCase) })
}

function Test-IsPreservedPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    $t = Get-NormalizedPath $Path
    foreach ($p in @($script:Preserved)) {
        if ($t.Equals($p, [StringComparison]::OrdinalIgnoreCase) -or
            $t.StartsWith($p + '\', [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

# A folder that still exists only because something preserved sits inside it -
# %APPDATA%\pyRevit around a kept Extensions folder - is not a leftover either.
function Test-HasPreservedInside {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    $t = Get-NormalizedPath $Path
    foreach ($p in @($script:Preserved)) {
        if ($p.StartsWith($t + '\', [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

# The places pyRevit and its installers write to on their own. Anything named
# pyRevit under one of these is pyRevit's footprint wherever Windows has put the
# profile - a redirected %APPDATA% on D: is still %APPDATA% - so the drive fence
# does not apply here. %USERPROFILE% and the drive root are deliberately NOT in
# this list: they are searched, but a hit there has to prove itself a clone.
function Get-FootprintRoots {
    @(
        $env:APPDATA
        $env:LOCALAPPDATA
        "$env:LOCALAPPDATA\Programs"
        $env:PROGRAMDATA
        $env:PROGRAMFILES
        ${env:ProgramFiles(x86)}
        $env:TEMP
    ) | Where-Object { $_ } | ForEach-Object { Get-NormalizedPath $_ } | Select-Object -Unique
}

# What IS this path?
#   Clone       - a pyRevit clone: holds pyrevitlib\ plus bin\ or a pyRevitfile.
#   Extensions  - a user extension area: the folder is *.extension / *.lib, or
#                 directly contains such folders. Never deleted.
#   CliInstall  - the pyRevit CLI's install folder.
#   Footprint   - anything else under a footprint root (config, caches, temp).
#   Unverified  - anything else anywhere else. Reported, never deleted.
# Clone is tested before Extensions on purpose: a clone's own extensions\ folder
# holds *.extension children, and the clone root is what the sweep is looking at.
function Get-PyRevitPathClass {
    param([string]$Path)
    $t = Get-NormalizedPath $Path
    $leaf = Split-Path -Path $t -Leaf
    if (Test-Path -LiteralPath $t -PathType Container) {
        if ($leaf -imatch '\.(extension|lib)$') { return 'Extensions' }
        $kids    = @(Get-ChildItem -LiteralPath $t -Directory -Force -ErrorAction SilentlyContinue)
        $hasLib  = @($kids | Where-Object { $_.Name -ieq 'pyrevitlib' }).Count -gt 0
        $hasBin  = @($kids | Where-Object { $_.Name -ieq 'bin' }).Count -gt 0
        $hasFile = Test-Path -LiteralPath (Join-Path $t 'pyRevitfile') -PathType Leaf
        if ($hasLib -and ($hasBin -or $hasFile)) { return 'Clone' }
        if (@($kids | Where-Object { $_.Name -imatch '\.(extension|lib)$' }).Count -gt 0) { return 'Extensions' }
    }
    if (Test-IsCliPath $t) { return 'CliInstall' }
    foreach ($root in @(Get-FootprintRoots)) {
        if ($t.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) { return 'Footprint' }
    }
    return 'Unverified'
}

# The decision every deletion goes through. Returns Allowed, the reason, and
# the classification so phase 5 can say out loud what it is leaving alone and
# why. Cheapest fence first.
function Test-DeletionAllowed {
    param([string]$Path)
    $t = Get-NormalizedPath $Path

    # Name fence: some path SEGMENT must name pyRevit. "...\pyRevit\Extensions\x"
    # is in scope through its second segment; "C:\Users\me\Projects" is not.
    $segments = @($t -split '\\')
    if (@($segments | Where-Object { $_ -imatch 'pyrevit' }).Count -eq 0) {
        return [pscustomobject]@{ Allowed = $false; Class = 'Unverified'; Reason = 'no path segment names pyRevit' }
    }

    # Extension fence.
    if (Test-IsProtectedPath $t) {
        return [pscustomobject]@{ Allowed = $false; Class = 'Extensions'; Reason = 'protected user extension path - registered in pyRevit_config.ini, or the default Extensions folder' }
    }
    $class = Get-PyRevitPathClass $t
    if ($class -eq 'Extensions') {
        return [pscustomobject]@{ Allowed = $false; Class = $class; Reason = 'user extension area - *.extension and *.lib folders are never deleted' }
    }

    # pyRevit's own footprint is in scope on whatever drive the profile lives.
    if ($class -eq 'Footprint') {
        return [pscustomobject]@{ Allowed = $true; Class = $class; Reason = 'pyRevit footprint' }
    }

    # Drive fence, for everything that is NOT under a footprint root.
    $root = ([IO.Path]::GetPathRoot($t)).TrimEnd('\')
    if (-not $root.Equals($script:SystemDrive, [StringComparison]::OrdinalIgnoreCase)) {
        if (-not $IncludeOtherDrives) {
            return [pscustomobject]@{ Allowed = $false; Class = $class; Reason = "outside $script:SystemDrive - pass -IncludeOtherDrives to remove verified clones on other drives" }
        }
        if ($class -notin @('Clone','CliInstall')) {
            return [pscustomobject]@{ Allowed = $false; Class = $class; Reason = "outside $script:SystemDrive and not a verified pyRevit clone" }
        }
    }

    # Marker fence.
    if ($class -eq 'Unverified') {
        return [pscustomobject]@{ Allowed = $false; Class = $class; Reason = 'outside the pyRevit footprint roots and not a verified clone (no bin\ + pyrevitlib\)' }
    }

    [pscustomobject]@{ Allowed = $true; Class = $class; Reason = "verified $class" }
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
    $add = {
        param([string]$p)
        $n = Get-NormalizedPath $p
        if ($n -and -not ($found | Where-Object { $_.Equals($n, [StringComparison]::OrdinalIgnoreCase) })) { $found.Add($n) }
    }
    foreach ($parent in $parents) {
        if (-not (Test-Path -LiteralPath $parent)) { continue }
        Get-ChildItem -LiteralPath $parent -Directory -Filter '*pyrevit*' -Force -ErrorAction SilentlyContinue |
            ForEach-Object { & $add $_.FullName }
    }
    # Clone candidates pyRevit itself knows about: the clones in its INI and the
    # InstallLocation of every non-CLI registration. Custom install directories
    # cannot hide - but a candidate is only that; every one of them still has to
    # pass the fences before phase 5 deletes it. The INI's userextensions key is
    # deliberately NOT a source here: those paths are protected, not swept.
    foreach ($p in @((Get-PyRevitConfig).Clones)) {
        if (Test-Path -LiteralPath $p -PathType Container) { & $add $p }
    }
    foreach ($r in @(Get-PyRevitRegistrations)) {
        if ($r.IsCli) { continue }
        $loc = "$($r.Location)".Trim().Trim('"').TrimEnd('\')
        # An InstallLocation whose LEAF is not pyRevit-named is a parent directory,
        # not an install root (the ODIS trap: "C:\Program Files\Autodesk").
        if (-not $loc -or (($loc -split '\\')[-1] -inotmatch 'pyrevit')) { continue }
        if (Test-Path -LiteralPath $loc -PathType Container) { & $add $loc }
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

# --- Fences: what this run will never delete ----------------------------------
# Built before any phase runs and before the INI is deleted in phase 5, from the
# INI itself. Printed first so a -DryRun states what it would preserve.
Write-Section 'Fences'
$script:Config = Get-PyRevitConfig
foreach ($ini in $script:Config.Files) { Write-Log "config read: $ini" }
foreach ($p in $script:Config.UserExtensions) {
    Add-Protected $p
    Write-Log "PROTECTED - user extension path registered in pyRevit_config.ini: $p" 'WARN'
}
if ($RemoveExtensions) {
    Write-Log 'default Extensions folders WILL be backed up and removed (-RemoveExtensions)' 'WARN'
} else {
    foreach ($e in $script:DefaultExtRoots) {
        Add-Protected $e
        Write-Log "PROTECTED - default extension folder (pass -RemoveExtensions to back it up and remove it): $e"
    }
}
if ($script:Config.UserExtensions.Count -eq 0) { Write-Log 'no user extension paths registered in pyRevit_config.ini; *.extension folders are still never deleted' }
if ($IncludeOtherDrives) {
    Write-Log "drive fence: verified clones on drives other than $script:SystemDrive WILL be removed (-IncludeOtherDrives)" 'WARN'
} else {
    Write-Log "drive fence: only $script:SystemDrive is swept; anything found on another drive is reported and left in place"
}

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
$extFound = @($script:DefaultExtRoots | Where-Object { Test-Path -LiteralPath $_ } |
    Where-Object { @(Get-ChildItem -LiteralPath $_ -Force -ErrorAction SilentlyContinue).Count -gt 0 })

if (-not $extFound) {
    Write-Log 'no populated default extensions folder found'
} elseif (-not $RemoveExtensions) {
    foreach ($e in $extFound) {
        Write-Log "extensions present - KEPT in place (pass -RemoveExtensions to back up and remove): $e" 'WARN'
        Get-ChildItem -LiteralPath $e -Directory -Force -ErrorAction SilentlyContinue |
            ForEach-Object { Write-Log "    - $($_.Name)" }
    }
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
    # -RemoveExtensions: the default Extensions folder goes with the config
    # folder it sits in, and the backup above is the recovery path. Extension
    # folders registered BY PATH in pyRevit_config.ini are a different matter:
    # they are protected unconditionally and never need a backup.
    Write-Log 'NOTE: -RemoveExtensions - the default Extensions folder is removed with the config folder.' 'WARN'
    Write-Log '      Restore from the backup above after reinstalling.' 'WARN'
}
if ($script:Config.UserExtensions.Count -gt 0) {
    Write-Log 'extension paths registered in pyRevit_config.ini are protected and stay where they are:'
    foreach ($p in $script:Config.UserExtensions) { Write-Log "    - $p" }
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
    # Report the fence decision here, out loud, so a -DryRun shows what stays
    # and why. Remove-Tree re-evaluates the same fences before touching anything.
    $verdict = Test-DeletionAllowed -Path $f
    if (-not $verdict.Allowed) {
        Write-Log "left in place [$($verdict.Class)] - $($verdict.Reason): $f" 'WARN'
        Add-Preserved $f
        continue
    }
    if (-not (Test-IsAdmin)) {
        if ($f -like "$env:PROGRAMDATA*" -or $f -like "$env:PROGRAMFILES*" -or $f -like "${env:ProgramFiles(x86)}*") {
            Write-Log "skipping (needs elevation): $f" 'WARN'
            $script:Failures.Add("needs-admin: $f")
            continue
        }
    }
    Remove-Tree $f $verdict.Class
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
# Same treatment for what the fences left standing: listed as intentional and
# excluded from the verdict. Printed in -DryRun as well.
if ($script:Preserved.Count -gt 0) {
    Write-Log 'left in place on purpose (extension areas, other drives, unverified folders):' 'WARN'
    foreach ($p in $script:Preserved) { Write-Log "    - $p" 'WARN' }
}
if ($DryRun) {
    Write-Log 'skipped (dry run)' 'DRY'
} else {
    # A folder counts as a leftover only if this run would have been ALLOWED to
    # delete it: -KeepCli exclusions, fence refusals and anything preserved by
    # the carve-out are intentional, not leftovers.
    $remFolders = @(Get-PyRevitFolders | Where-Object {
        -not ($KeepCli -and (Test-IsCliPath $_)) -and
        -not (Test-IsPreservedPath $_) -and
        -not (Test-HasPreservedInside $_) -and
        (Test-DeletionAllowed -Path $_).Allowed })
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
        $kept = @()
        if ($script:CliKept.Count -gt 0)   { $kept += 'the pyRevit CLI that -KeepCli was told to keep' }
        if ($script:Preserved.Count -gt 0) { $kept += ('the {0} item(s) deliberately left in place (listed above)' -f $script:Preserved.Count) }
        if ($kept.Count -gt 0) {
            Write-Log ('CLEAN - nothing remains except {0}.' -f ($kept -join ' and ')) 'OK'
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
