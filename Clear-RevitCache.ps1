<#
.SYNOPSIS
    Clears Autodesk Revit's per-user caches (any year) - accelerator cache, web
    caches, interprocess queues and journal history - and, opt-in, the cloud
    collaboration cache and the Home screen's Recent models page.

.DESCRIPTION
    Discovers which Revit years are present by reading the per-user data roots
    under %LOCALAPPDATA%\Autodesk\Revit, then clears a fixed, named catalogue of
    cache locations. Nothing is matched by wildcard: a folder is only emptied if
    it appears in the catalogue, so a future Revit release that adds a new
    subfolder gets it REPORTED as "left alone" rather than silently deleted.

    Default scope is limited to caches that hold no user work:

        Journals                  trimmed to the newest -KeepJournals sessions
        CefCache                  Revit Home / embedded browser cache
        WebBrowserControl         WebView2 cache (EBWebView)
        Product Feedback\CefCache feedback panel browser cache
        PacCache                  Personal Accelerator cloud-model cache (shared)
        interprocess              stale session queues (shared)

    Three locations are OPT-IN because they are not free to lose:

        CollaborationCache   -IncludeCollaborationCache
            The local copy of every cloud-workshared (BIM 360 / ACC) model.
            Changes you have not synced live HERE and nowhere else - deleting
            this folder with unsynced work in it destroys that work. Sync and
            close every cloud model first. Everything synced is re-downloaded
            on next open, which is slow but lossless.

        Recent models page   -ClearRecentFiles
            The Home screen's Recent list. Two stores, cleared together: the
            thumbnails in %APPDATA%\...\RecentFileCache, and the list itself,
            which lives in Revit.ini under [Recent File List]. Revit.ini is
            edited surgically - only the FileN= and ConfigN= lines go, every
            other setting is preserved - and backed up first.

        %LOCALAPPDATA%\Autodesk\CER   -IncludeErrorReports
            Crash dumps from EVERY Autodesk product, not just Revit. They are
            the evidence Autodesk support asks for after a crash.

    No elevation required - every path is under the current user's profile.
    Run it as the user whose caches you want cleared; running it elevated as a
    different account clears THAT account's caches instead.

.PARAMETER ProductYear
    Four-digit Revit release year to target, or 'All' (default) for every year
    found on the machine. Shared caches (PacCache, interprocess, CER) are not
    year-scoped and are cleared on any run that reaches them.

.PARAMETER KeepJournals
    Number of the most recent journal sessions to keep per year. Default: 10.
    Use 0 to clear them all. Journals are Revit's own crash/command log - they
    are what Autodesk support asks for, and Revit's recovery tooling replays
    them - so this trims rather than empties. A session is kept or dropped as a
    unit: journal.0083.txt, its .worker1.log, its .dmp and its .abbrev all go
    together.

.PARAMETER IncludeCollaborationCache
    Opt in to also clear the cloud model collaboration cache for the targeted
    year(s). UNSYNCED WORK LIVES HERE. Sync and close every cloud model first.
    Combine with -OlderThanDays to purge only projects you have not touched
    recently. This is a [switch]: pass it bare, like -Force.

.PARAMETER ClearRecentFiles
    Opt in to also empty the Home screen's Recent models page for the targeted
    year(s) - both the thumbnail cache and the [Recent File List] entries in
    Revit.ini. Revit rewrites Revit.ini when it exits, so this only sticks with
    Revit closed, which the process guard already enforces. No model is touched;
    only the shortcut list to them. This is a [switch].

.PARAMETER IncludeErrorReports
    Opt in to also clear %LOCALAPPDATA%\Autodesk\CER, the shared Autodesk crash
    dump store. Not Revit-specific - this discards crash evidence for AutoCAD,
    Navisworks and every other Autodesk product too. This is a [switch].

.PARAMETER OlderThanDays
    Only clear cache entries whose last write time is older than N days.
    Default: 0 (no age filter). Applied per top-level entry - per project folder
    in the collaboration cache, per journal session, per cache subfolder
    elsewhere. This is the practical safety valve for the collaboration cache:
    a project you have not opened in 30 days is one you have already synced.

.PARAMETER StopRevit
    Terminate Revit.exe and RevitAccelerator.exe before clearing. Without it,
    the script aborts when Revit is running, and skips only the caches a still
    running process holds open.

.PARAMETER ListOnly
    Discover and print every cache entry with its size and age, then exit.
    Performs no changes. Run this first.

.PARAMETER Force
    Fully non-interactive: skips the per-location prompt and the typed
    confirmation the collaboration cache would otherwise require.

.PARAMETER LogPath
    Full path for the log. Defaults to
    %TEMP%\Clear-RevitCache_<timestamp>.log

.EXAMPLE
    # Preview every cache on the machine with sizes - changes nothing:
    powershell -ExecutionPolicy Bypass -File .\Clear-RevitCache.ps1 -ListOnly

.EXAMPLE
    # Clear the safe caches for every year, prompting per location:
    powershell -ExecutionPolicy Bypass -File .\Clear-RevitCache.ps1

.EXAMPLE
    # One year, unattended, closing Revit and the accelerator if they are open:
    powershell -ExecutionPolicy Bypass -File .\Clear-RevitCache.ps1 -ProductYear 2026 -StopRevit -Force

.EXAMPLE
    # Empty the Home screen's Recent models page as well:
    powershell -ExecutionPolicy Bypass -File .\Clear-RevitCache.ps1 -ClearRecentFiles

.EXAMPLE
    # ALSO clear cloud models - only projects untouched for 30+ days.
    # Sync and close every cloud model before running this:
    powershell -ExecutionPolicy Bypass -File .\Clear-RevitCache.ps1 -IncludeCollaborationCache -OlderThanDays 30

.EXAMPLE
    # Keep only the 3 newest journal sessions per year:
    powershell -ExecutionPolicy Bypass -File .\Clear-RevitCache.ps1 -KeepJournals 3 -Force

.NOTES
    No elevation required. Exit code 0 = success, 3 = partial failure (one or
    more deletions failed), 2 = nothing to clear, 1 = aborted.

    The opt-ins are [switch] rather than [bool] so they bind under
    "powershell.exe -File", which is how every example in this repo is written.
    Pass them bare - "-Force" style - not as "-ClearRecentFiles:$true".
    powershell.exe -File passes every argument as a literal STRING, and a [bool]
    parameter rejects the string "$true" outright.
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [ValidatePattern('^(All|\d{4})$')]
    [string]$ProductYear = 'All',

    [ValidateRange(0, 10000)]
    [int]$KeepJournals = 10,

    # The opt-ins are [switch], not [bool], so they bind under -File. See .NOTES.
    [switch]$IncludeCollaborationCache,
    [switch]$ClearRecentFiles,
    [switch]$IncludeErrorReports,

    [ValidateRange(0, 36500)]
    [int]$OlderThanDays = 0,

    [switch]$StopRevit,
    [switch]$ListOnly,
    [switch]$Force,
    [string]$LogPath
)

$ErrorActionPreference = 'Continue'
Set-StrictMode -Version Latest

if ($Force) { $ConfirmPreference = 'None' }

$script:LogPath = if ($LogPath) { $LogPath } else {
    Join-Path $env:TEMP ("Clear-RevitCache_{0}.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
}
try {
    $logDir = Split-Path -Parent $script:LogPath
    if ($logDir -and -not (Test-Path -LiteralPath $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }
} catch {
    Write-Host "Invalid -LogPath: $script:LogPath" -ForegroundColor Red
    exit 1
}

$script:Failures     = [System.Collections.Generic.List[string]]::new()
$script:BytesFreed   = [long]0
$script:ItemsRemoved = 0
# Process names found running that hold a cache open. Populated by the process
# guard; consulted by the catalogue's HeldBy field. The guard never needs to
# know which cache that is.
$script:LockedBy     = [System.Collections.Generic.HashSet[string]]::new(
                           [StringComparer]::OrdinalIgnoreCase)
# Locations the catalogue actually resolved this run. Deletion is authorised
# against these and nothing else - see Register-AuthorisedRoot.
$script:AuthorisedRoots = [System.Collections.Generic.HashSet[string]]::new(
                           [StringComparer]::OrdinalIgnoreCase)
# Cutoff for -OlderThanDays, resolved once. $null means "no age filter".
$script:AgeCutoff    = if ($OlderThanDays -gt 0) { (Get-Date).AddDays(-$OlderThanDays) } else { $null }

# --- Roots ----------------------------------------------------------------
$LocalRevit   = Join-Path $env:LOCALAPPDATA 'Autodesk\Revit'
$LocalAdsk    = Join-Path $env:LOCALAPPDATA 'Autodesk'
$RoamingRevit = Join-Path $env:APPDATA      'Autodesk\Revit'

# -----------------------------------------------------------------------------
# Cache catalogue
#
# Nothing outside this catalogue is ever deleted, and every behaviour that used
# to be a special case in the engine is a field here instead. Adding a cache
# means adding a row, not editing the engine.
#
#   Name      display label (prose - never used as a dispatch key)
#   Rel       path relative to the year root
#   Path      absolute path (shared caches)
#   Root      'Local' (%LOCALAPPDATA%) or 'Roaming' (%APPDATA%). Default Local.
#   Mode      which enumerator produces this entry's units of work
#   OptIn     name of the switch that must be passed; validated at startup
#   Risky     holds work that exists nowhere else - forces a typed confirmation
#   Resolver  function resolving a relocated path (-Year/-DefaultPath)
#   HeldBy    process name that locks it; skipped while that process runs
#   Why       one line the operator reads before answering the prompt
#
# Mode 'Contents' empties a container but keeps the container itself - Revit
# recreates the contents on demand but assumes the folder exists.
# -----------------------------------------------------------------------------
$YearCaches = @(
    @{ Name  = 'Journals'
       Rel   = 'Journals'
       Mode  = 'Journals'
       Why   = "keeps the newest $KeepJournals session(s)" }

    @{ Name  = 'CefCache'
       Rel   = 'CefCache'
       Mode  = 'Contents'
       Why   = 'Revit Home / embedded browser cache; may force a re-sign-in' }

    @{ Name  = 'WebBrowserControl'
       Rel   = 'WebBrowserControl'
       Mode  = 'Contents'
       Why   = 'WebView2 (EBWebView) cache; may force a re-sign-in' }

    @{ Name  = 'Product Feedback cache'
       Rel   = 'Product Feedback\CefCache'
       Mode  = 'Contents'
       Why   = 'feedback panel browser cache' }

    @{ Name  = 'CollaborationCache'
       Rel   = 'CollaborationCache'
       Mode  = 'Projects'
       OptIn = 'IncludeCollaborationCache'
       Risky = $true
       Resolver = 'Resolve-CollaborationCacheRoot'
       Why   = 'LOCAL COPY OF CLOUD MODELS - unsynced work lives here' }

    # The Home screen's Recent page is two stores that must go together, or the
    # page comes back half-populated: the thumbnails, and the list itself.
    @{ Name  = 'Recent models thumbnails'
       Rel   = 'RecentFileCache'
       Root  = 'Roaming'
       Mode  = 'Contents'
       OptIn = 'ClearRecentFiles'
       Why   = 'Home screen Recent page card images' }

    @{ Name  = 'Recent models list'
       Rel   = 'Revit.ini'
       Root  = 'Roaming'
       Mode  = 'RecentList'
       OptIn = 'ClearRecentFiles'
       Why   = 'Home screen Recent page entries, inside Revit.ini' }
)

# Shared across every Revit year - cleared once per run, not per year.
$SharedCaches = @(
    @{ Name  = 'PacCache'
       Path  = Join-Path $LocalRevit 'PacCache'
       Mode  = 'Contents'
       HeldBy = 'RevitAccelerator'
       Why   = 'Personal Accelerator cloud-model cache; rebuilt on demand' }

    @{ Name  = 'interprocess'
       Path  = Join-Path $LocalRevit 'interprocess'
       Mode  = 'Contents'
       Why   = 'stale session queues from previous Revit runs' }

    @{ Name  = 'CER (all Autodesk products)'
       Path  = Join-Path $LocalAdsk 'CER'
       Mode  = 'Contents'
       OptIn = 'IncludeErrorReports'
       Why   = 'crash dumps for EVERY Autodesk product, not just Revit' }
)

# Every opt-in switch, resolved once. A catalogue entry naming a key that is not
# here is a typo, and a typo used to mean "silently never clears, even when the
# user passes the switch" - so it is a startup error instead.
$OptInSwitches = @{
    IncludeCollaborationCache = [bool]$IncludeCollaborationCache
    ClearRecentFiles          = [bool]$ClearRecentFiles
    IncludeErrorReports       = [bool]$IncludeErrorReports
}

# Year-root entries that are deliberately NOT cache. Listed so the "left alone"
# report can say WHY rather than flagging them as unclassified.
$NotCache = @{
    'Revit Personal Accelerator' = 'accelerator config (config.json), not cache'
}

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

function Format-Bytes {
    param([long]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0,8:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0,8:N1} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0,8:N1} KB' -f ($Bytes / 1KB)) }
    return ('{0,8} B ' -f $Bytes)
}

# Sum a property across a collection that may legitimately be empty.
# Measure-Object -Property returns NOTHING (not a zero) for an empty pipeline,
# and Set-StrictMode turns the resulting null dereference into a hard failure.
function Get-SumOf {
    param($Items, [string]$Property)
    $items = @($Items)
    if ($items.Count -eq 0) { return [long]0 }
    $sum = $items | Measure-Object -Property $Property -Sum
    if ($null -eq $sum -or $null -eq $sum.Sum) { return [long]0 }
    return [long]$sum.Sum
}

function Get-TreeSize {
    param([string]$Path)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if (-not $item) { return [long]0 }
    if ($item -is [System.IO.FileInfo]) { return [long]$item.Length }
    return Get-SumOf (Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue) 'Length'
}

# The age filter, asked BEFORE anything expensive happens. Measuring a cache
# entry means walking its whole tree, so filtering afterwards meant walking all
# 22 GB of a collaboration cache to report on the 20% of it that survived.
function Test-PassesAgeFilter {
    param([datetime]$LastWriteTime)
    if ($null -eq $script:AgeCutoff) { return $true }
    return ($LastWriteTime -lt $script:AgeCutoff)
}

# Nothing is deleted unless it sits strictly inside a location the catalogue
# itself resolved. Authorisation is therefore DERIVED from the catalogue rather
# than restated here - an earlier version hardcoded the three default roots, and
# that quietly broke the relocation resolver: with the collaboration cache moved
# by registry to another drive, the run would preview it, prompt for the typed
# YES, then refuse every single delete and exit 3.
#
# Registering a root does not make it safe on its own. A root has to clear the
# invariants below first, because it can come from a registry value that Revit -
# or a person - wrote.
function Register-AuthorisedRoot {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    try { $full = [System.IO.Path]::GetFullPath($Path).TrimEnd('\') } catch { return $false }

    # Absolute, and never a drive root: "C:\" would authorise the whole disk.
    if ($full -notmatch '^([a-zA-Z]:\\|\\\\)') { return $false }
    if ($full.Length -le 3 -or $full -notmatch '\\') { return $false }

    # Never the Windows or Program Files trees, whatever a registry value says.
    foreach ($forbidden in @($env:SystemRoot, $env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if ([string]::IsNullOrWhiteSpace($forbidden)) { continue }
        $f = [System.IO.Path]::GetFullPath($forbidden).TrimEnd('\')
        if ($full.Equals($f, 'OrdinalIgnoreCase') -or $full.StartsWith($f + '\', 'OrdinalIgnoreCase')) {
            Write-Log "refusing to authorise a system location as a cache root: $full" 'ERROR'
            return $false
        }
    }

    [void]$script:AuthorisedRoots.Add($full)
    return $true
}

# Belt and braces on top of the catalogue: the catalogue decides what to clear,
# this refuses to be wrong. A path must sit STRICTLY BELOW an authorised root,
# so neither a root itself nor anything beside it can ever be the target.
function Test-SafeCachePath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    try { $full = [System.IO.Path]::GetFullPath($Path).TrimEnd('\') } catch { return $false }
    if ($full.Length -le 3 -or $full -notmatch '\\') { return $false }

    foreach ($root in $script:AuthorisedRoots) {
        if ($full.StartsWith($root + '\', 'OrdinalIgnoreCase')) { return $true }
    }
    return $false
}

# Deletion that survives read-only attributes and >260-char paths. Windows
# PowerShell 5.1's Remove-Item is not long-path aware even with
# LongPathsEnabled=1, and the collaboration cache nests
# <account>\<project>\<model>_backup\... deep enough to hit it routinely.
# Returns the bytes it freed. -KnownBytes avoids re-walking a tree the caller
# has already measured; on a 22 GB collaboration cache that walk is not free.
function Remove-CacheItem {
    param([string]$Path, [string]$Label, [long]$KnownBytes = -1)

    if (-not (Test-Path -LiteralPath $Path)) { return [long]0 }

    if (-not (Test-SafeCachePath $Path)) {
        Write-Log "REFUSED (failed safety guard): $Path" 'ERROR'
        $script:Failures.Add("guard: $Path")
        return [long]0
    }

    # Gate first: under -WhatIf this must cost nothing at all.
    if (-not $PSCmdlet.ShouldProcess($Path, 'Delete')) { return [long]0 }

    $size = if ($KnownBytes -ge 0) { $KnownBytes } else { Get-TreeSize $Path }
    $trimmed = $Path.TrimEnd('\')

    try {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
    } catch {
        # Remove-Item -Force already handles read-only and hidden items, so
        # attrib only earns its recursive walk once that has actually failed.
        if (Test-Path -LiteralPath $Path -PathType Container) {
            & attrib.exe -r -s -h "$trimmed\*" /s /d 2>$null | Out-Null
        }
        # fallback 1: cmd's rd, which tolerates some paths Remove-Item won't
        & cmd.exe /c rd /s /q "$trimmed" 2>$null | Out-Null
        # fallback 2: robocopy-mirror an empty dir over it (long-path safe).
        # /MIR empties its target, so it stays gated on the same guard.
        if ((Test-Path -LiteralPath $Path) -and (Test-SafeCachePath $Path)) {
            $empty = Join-Path $env:TEMP ("_rvcache_empty_{0}" -f $PID)
            New-Item -ItemType Directory -Path $empty -Force | Out-Null
            & robocopy.exe $empty "$trimmed" /MIR /NJH /NJS /NP /NFL /NDL 2>$null | Out-Null
            & cmd.exe /c rd /s /q "$trimmed" 2>$null | Out-Null
            Remove-Item -LiteralPath $empty -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    if (Test-Path -LiteralPath $Path) {
        Write-Log "FAILED to remove: $Label" 'ERROR'
        $script:Failures.Add("path: $Path")
        return [long]0
    }

    $script:ItemsRemoved++
    $script:BytesFreed += $size
    return $size
}

function Confirm-Action {
    param([string]$Prompt)
    if ($Force) { return $true }
    $answer = Read-Host "$Prompt [y/N]"
    return ($answer -match '^(y|yes)$')
}

# -----------------------------------------------------------------------------
# Revit.ini - the Recent models list
# -----------------------------------------------------------------------------

# Revit.ini is UTF-16 LE with a BOM. Rewriting it as UTF-8 or ANSI corrupts
# every Revit setting in the file, so the original encoding is detected from the
# BOM and handed straight back to the writer.
function Get-IniEncoding {
    param([string]$Path)
    $bom = New-Object byte[] 3
    $stream = [System.IO.File]::OpenRead($Path)
    try { [void]$stream.Read($bom, 0, 3) } finally { $stream.Dispose() }

    if ($bom[0] -eq 0xFF -and $bom[1] -eq 0xFE) { return New-Object System.Text.UnicodeEncoding($false, $true) }
    if ($bom[0] -eq 0xFE -and $bom[1] -eq 0xFF) { return New-Object System.Text.UnicodeEncoding($true,  $true) }
    if ($bom[0] -eq 0xEF -and $bom[1] -eq 0xBB -and $bom[2] -eq 0xBF) { return New-Object System.Text.UTF8Encoding($true) }
    return [System.Text.Encoding]::Default
}

# The keys that make up the Recent page, per INI section. ConfigN in
# [Recent Workset List] is the per-recent-file workset memory - it is keyed to
# the FileN indices, so leaving it behind orphans it against a list that is gone.
$RecentIniSections = @{
    '[Recent File List]'    = '^\s*File\d+\s*='
    '[Recent Workset List]' = '^\s*Config\d+\s*='
}

# Returns the line indices that make up the Recent page, without touching them.
function Get-RecentIniLines {
    param([string[]]$Lines)

    $hits    = [System.Collections.Generic.List[int]]::new()
    $pattern = $null
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        $trimmed = $Lines[$i].Trim()
        if ($trimmed -match '^\[.*\]$') {
            # A new section header always ends the previous section, so a stray
            # FileN= elsewhere in the file can never be picked up.
            $pattern = if ($RecentIniSections.ContainsKey($trimmed)) { $RecentIniSections[$trimmed] } else { $null }
            continue
        }
        if ($pattern -and $Lines[$i] -match $pattern) { $hits.Add($i) }
    }
    return $hits
}

# Removes those lines and writes the file back byte-compatibly, keeping the
# section headers (Revit repopulates them) and every unrelated setting.
function Clear-RecentFileList {
    param([string]$Path, [int[]]$LineIndices)

    if ((Split-Path -Leaf $Path) -ne 'Revit.ini') {
        Write-Log "REFUSED (not Revit.ini): $Path" 'ERROR'
        $script:Failures.Add("ini: $Path")
        return
    }
    if (-not $PSCmdlet.ShouldProcess($Path, "Clear $($LineIndices.Count) Recent page entr(y/ies)")) { return }

    try {
        $encoding = Get-IniEncoding $Path
        $lines    = [System.IO.File]::ReadAllLines($Path, $encoding)

        # Back up before touching a file that holds every Revit setting.
        $backup = "$Path.{0}.bak" -f (Get-Date -Format 'yyyyMMdd_HHmmss')
        Copy-Item -LiteralPath $Path -Destination $backup -Force -ErrorAction Stop

        $drop = [System.Collections.Generic.HashSet[int]]::new([int[]]$LineIndices)
        $kept = for ($i = 0; $i -lt $lines.Count; $i++) { if (-not $drop.Contains($i)) { $lines[$i] } }

        [System.IO.File]::WriteAllLines($Path, [string[]]$kept, $encoding)
        $script:ItemsRemoved += $LineIndices.Count
        Write-Log ("cleared {0} Recent page entr(y/ies) from Revit.ini (backup: {1})" -f $LineIndices.Count, (Split-Path -Leaf $backup)) 'OK'
    } catch {
        Write-Log "FAILED to edit $Path : $($_.Exception.Message)" 'ERROR'
        $script:Failures.Add("ini: $Path")
    }
}

# -----------------------------------------------------------------------------
# Discovery
# -----------------------------------------------------------------------------

# Years are read off disk, never assumed. A machine can hold data for a year
# whose Revit is long uninstalled - that cache is exactly what you want gone.
function Get-RevitYears {
    if (-not (Test-Path -LiteralPath $LocalRevit)) { return @() }
    $years = Get-ChildItem -LiteralPath $LocalRevit -Directory -Force -ErrorAction SilentlyContinue |
             Where-Object { $_.Name -match '^Autodesk Revit (\d{4})$' } |
             ForEach-Object { $Matches[1] }
    $years = @($years | Sort-Object -Unique)
    if ($ProductYear -ne 'All') { $years = @($years | Where-Object { $_ -eq $ProductYear }) }
    return $years
}

# Revit lets the collaboration cache be relocated. The override is a registry
# value under the year's key whose name contains "CollaborationCache"; on a
# default install it does not exist at all. Look for it rather than assuming
# either way, so a relocated cache is cleared where it actually lives and the
# default path is never cleared out from under a relocated one.
function Resolve-CollaborationCacheRoot {
    param([string]$Year, [string]$DefaultPath)

    $keys = @(
        "HKCU:\SOFTWARE\Autodesk\Revit\Autodesk Revit $Year",
        "HKCU:\SOFTWARE\Autodesk\Revit\Autodesk Revit $Year\Revit"
    )
    foreach ($key in $keys) {
        if (-not (Test-Path -LiteralPath $key)) { continue }
        $props = Get-ItemProperty -LiteralPath $key -ErrorAction SilentlyContinue
        if (-not $props) { continue }
        foreach ($p in $props.PSObject.Properties) {
            if ($p.Name -like 'PS*') { continue }
            if ($p.Name -notlike '*CollaborationCache*') { continue }
            $value = [string]$p.Value
            if ([string]::IsNullOrWhiteSpace($value)) { continue }
            $expanded = [Environment]::ExpandEnvironmentVariables($value)
            Write-Log "$Year : collaboration cache relocated by registry to $expanded" 'WARN'
            return $expanded
        }
    }
    return $DefaultPath
}

# --- Entry enumerators ------------------------------------------------------
# Every mode returns the SAME shape, so nothing downstream has to ask which mode
# produced an entry:
#     Label          what to print
#     Bytes          size, measured once, here
#     LastWriteTime  for the age filter and the report
#     Paths          filesystem paths to delete (empty for an in-place edit)
#     IniLines       line indices to strip (RecentList only)

function New-CacheEntry {
    param([string]$Label, [long]$Bytes, [datetime]$LastWriteTime, [string[]]$Paths, [int[]]$IniLines = @())
    [pscustomobject]@{
        Label         = $Label
        Bytes         = $Bytes
        LastWriteTime = $LastWriteTime
        Paths         = $Paths
        IniLines      = $IniLines
    }
}

# Top-level children of a container - the unit is one child.
function Get-ContentsEntries {
    param([string]$Path)
    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($item in @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue)) {
        if (-not (Test-PassesAgeFilter $item.LastWriteTime)) { continue }
        # A file entry already carries its own size; only directories need a walk.
        $bytes = if ($item -is [System.IO.FileInfo]) { [long]$item.Length } else { Get-TreeSize $item.FullName }
        $out.Add((New-CacheEntry -Label $item.Name -Bytes $bytes -LastWriteTime $item.LastWriteTime -Paths @($item.FullName)))
    }
    return $out
}

# <account>\<project> - one unit per project, so -OlderThanDays can spare a
# project you are still working in.
function Get-ProjectEntries {
    param([string]$Path)
    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($account in @(Get-ChildItem -LiteralPath $Path -Directory -Force -ErrorAction SilentlyContinue)) {
        $projects = @(Get-ChildItem -LiteralPath $account.FullName -Directory -Force -ErrorAction SilentlyContinue)
        if ($projects.Count -eq 0) { $projects = @($account) }
        foreach ($p in $projects) {
            if (-not (Test-PassesAgeFilter $p.LastWriteTime)) { continue }
            $out.Add((New-CacheEntry -Label $p.Name -Bytes (Get-TreeSize $p.FullName) -LastWriteTime $p.LastWriteTime -Paths @($p.FullName)))
        }
    }
    return $out
}

# Journal sessions, grouped by number. Every file Revit writes for a session
# starts "journal.NNNN." - the .txt, its .worker1.log, its crash .dmp and its
# .abbrev - so the group is the unit that gets kept or dropped. A file that
# does not match the pattern is not a journal and is left alone.
function Get-JournalEntries {
    param([string]$Path)

    $sessions = @{}
    foreach ($f in @(Get-ChildItem -LiteralPath $Path -File -Force -ErrorAction SilentlyContinue)) {
        if ($f.Name -notmatch '^journal\.(\d+)\.') { continue }
        $id = $Matches[1]
        if (-not $sessions.ContainsKey($id)) {
            $sessions[$id] = [pscustomobject]@{
                Paths = [System.Collections.Generic.List[string]]::new()
                Bytes = [long]0
                Last  = [datetime]'1900-01-01'
            }
        }
        $s = $sessions[$id]
        $s.Paths.Add($f.FullName)
        $s.Bytes += $f.Length
        if ($f.LastWriteTime -gt $s.Last) { $s.Last = $f.LastWriteTime }
    }

    $ordered = @($sessions.GetEnumerator() | Sort-Object { $_.Value.Last })
    # Keep the newest N; the rest are candidates. Sorted oldest-first, so
    # dropping the tail keeps exactly the newest KeepJournals.
    if ($KeepJournals -ge $ordered.Count) { return @() }
    $drop = $ordered[0..($ordered.Count - $KeepJournals - 1)]

    return @($drop |
        Where-Object { Test-PassesAgeFilter $_.Value.Last } |
        ForEach-Object {
            New-CacheEntry -Label "journal.$($_.Key).*" -Bytes $_.Value.Bytes `
                           -LastWriteTime $_.Value.Last -Paths $_.Value.Paths.ToArray()
        })
}

# The Recent page list inside Revit.ini. One entry for the whole edit: the file
# is rewritten once, not once per line. Bytes stay 0 - this reclaims no disk
# space, and claiming otherwise would misreport the run's total.
function Get-RecentListEntries {
    param([string]$Path)
    $encoding = Get-IniEncoding $Path
    $lines    = [System.IO.File]::ReadAllLines($Path, $encoding)
    $hits     = @(Get-RecentIniLines -Lines $lines)
    if ($hits.Count -eq 0) { return @() }

    $ini = Get-Item -LiteralPath $Path -Force
    if (-not (Test-PassesAgeFilter $ini.LastWriteTime)) { return @() }
    return @(New-CacheEntry -Label ("{0} entr(y/ies) in Revit.ini" -f $hits.Count) -Bytes 0 `
                            -LastWriteTime $ini.LastWriteTime -Paths @() -IniLines $hits)
}

function Get-CacheEntriesFor {
    param([string]$Mode, [string]$Path)
    switch ($Mode) {
        'Contents'   { return @(Get-ContentsEntries   -Path $Path) }
        'Projects'   { return @(Get-ProjectEntries    -Path $Path) }
        'Journals'   { return @(Get-JournalEntries    -Path $Path) }
        'RecentList' { return @(Get-RecentListEntries -Path $Path) }
        # Fail closed. The old default arm meant "empty the whole container",
        # so a typo'd Mode silently got the most destructive behaviour there is.
        default      { throw "Cache catalogue error: unknown Mode '$Mode' for $Path" }
    }
}

# -----------------------------------------------------------------------------
# Process guard
# -----------------------------------------------------------------------------

function Invoke-ProcessGuard {
    Write-Section 'Running processes'

    # Revit itself is the one process that aborts the run - it rewrites the very
    # files being cleared. Everything else is read off the catalogue's HeldBy
    # fields, so a row naming a new helper process is actually honoured instead
    # of silently never matching.
    $holders = @($YearCaches + $SharedCaches |
                 Where-Object { $_.ContainsKey('HeldBy') } |
                 ForEach-Object { $_.HeldBy } |
                 Sort-Object -Unique)

    $revit = @(Get-Process -Name 'Revit' -ErrorAction SilentlyContinue)
    $held  = @($holders | ForEach-Object { Get-Process -Name $_ -ErrorAction SilentlyContinue })

    if ($revit.Count -eq 0 -and $held.Count -eq 0) {
        Write-Log 'Revit is not running.' 'OK'
        return $true
    }

    foreach ($p in $revit) { Write-Log "Revit.exe is running (PID $($p.Id))" 'WARN' }
    foreach ($p in $held)  { Write-Log "$($p.ProcessName).exe is running (PID $($p.Id)) - holds a cache open" 'WARN' }

    if ($ListOnly) { return $true }

    if (-not $StopRevit) {
        if ($revit.Count -gt 0) {
            Write-Log 'Close Revit first, or re-run with -StopRevit. Aborting.' 'ERROR'
            return $false
        }
        # A holder alone is not worth aborting over - these are background
        # helpers with no unsaved state. Skip only the cache each one locks.
        foreach ($p in $held) { [void]$script:LockedBy.Add($p.ProcessName) }
        return $true
    }

    foreach ($p in ($revit + $held)) {
        if ($PSCmdlet.ShouldProcess("$($p.ProcessName) (PID $($p.Id))", 'Stop process')) {
            try {
                Stop-Process -Id $p.Id -Force -ErrorAction Stop
                Write-Log "stopped $($p.ProcessName) (PID $($p.Id))" 'OK'
            } catch {
                Write-Log "could not stop $($p.ProcessName) (PID $($p.Id)): $($_.Exception.Message)" 'ERROR'
                if ($p.ProcessName -eq 'Revit') { return $false }
                [void]$script:LockedBy.Add($p.ProcessName)
            }
        }
    }
    Start-Sleep -Seconds 2
    return $true
}

# -----------------------------------------------------------------------------
# Target building
# -----------------------------------------------------------------------------

# Resolves a catalogue row to its path for one year (or once, if shared).
# Returns $null when the row does not apply to this machine.
function Resolve-CachePath {
    param([hashtable]$Def, [string]$Year)

    if ($Def.ContainsKey('Path')) { return $Def.Path }

    $root = if ($Def.ContainsKey('Root') -and $Def.Root -eq 'Roaming') { $RoamingRevit } else { $LocalRevit }
    $path = Join-Path (Join-Path $root "Autodesk Revit $Year") $Def.Rel

    if ($Def.ContainsKey('Resolver')) { $path = & $Def.Resolver -Year $Year -DefaultPath $path }
    return $path
}

function Get-Targets {
    param([string[]]$Years)

    $targets = [System.Collections.Generic.List[object]]::new()

    # One row + one year (or $null for a shared row) -> zero or one target.
    $rows = @()
    foreach ($def in $YearCaches)   { foreach ($y in $Years) { $rows += ,@($def, $y) } }
    foreach ($def in $SharedCaches) { $rows += ,@($def, $null) }

    foreach ($row in $rows) {
        $def  = $row[0]
        $year = $row[1]

        if ($def.ContainsKey('OptIn')) {
            if (-not $OptInSwitches.ContainsKey($def.OptIn)) {
                throw "Cache catalogue error: '$($def.Name)' names unknown opt-in switch '$($def.OptIn)'"
            }
            if (-not $OptInSwitches[$def.OptIn]) { continue }
        }
        if ($def.ContainsKey('HeldBy') -and $script:LockedBy.Contains($def.HeldBy)) {
            Write-Log "skipping $($def.Name): $($def.HeldBy).exe is holding it open" 'WARN'
            continue
        }

        $path = Resolve-CachePath -Def $def -Year $year
        if (-not (Test-Path -LiteralPath $path)) { continue }

        # Resolving a row is what authorises deletion beneath it. A row whose
        # path fails the invariants is dropped rather than half-processed.
        $container = if ($def.Mode -eq 'RecentList') { Split-Path -Parent $path } else { $path }
        if (-not (Register-AuthorisedRoot $container)) {
            Write-Log "skipping $($def.Name): $container is not a location this script may clear" 'WARN'
            continue
        }

        # The age filter is applied inside the enumerators, before they measure.
        $entries = @(Get-CacheEntriesFor -Mode $def.Mode -Path $path)
        if ($entries.Count -eq 0) { continue }

        $targets.Add([pscustomobject]@{
            Name    = if ($year) { "$year $($def.Name)" } else { $def.Name }
            Path    = $path
            Mode    = $def.Mode
            Why     = $def.Why
            Risky   = ($def.ContainsKey('Risky') -and $def.Risky)
            Entries = @($entries | Sort-Object LastWriteTime)
            Bytes   = Get-SumOf $entries 'Bytes'
        })
    }

    return @($targets)
}

# An opt-in cache that exists but was not asked for is reported with its switch,
# derived from the catalogue rather than restated - so the next opt-in row added
# shows up here for free instead of silently going missing.
function Show-OptInAvailable {
    param([string[]]$Years)

    $rows = @()
    foreach ($def in $YearCaches)   { foreach ($y in $Years) { $rows += ,@($def, $y) } }
    foreach ($def in $SharedCaches) { $rows += ,@($def, $null) }

    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($row in $rows) {
        $def = $row[0]
        if (-not $def.ContainsKey('OptIn'))        { continue }
        if ($OptInSwitches[$def.OptIn])            { continue }

        $path = Resolve-CachePath -Def $def -Year $row[1]
        if (-not (Test-Path -LiteralPath $path))   { continue }
        if (-not $seen.Add($path))                 { continue }

        $prefix = if ($row[1]) { "$($row[1]) " } else { '' }
        $label  = "{0}{1} - NOT in scope; add -{2}" -f $prefix, $def.Name, $def.OptIn

        # Sizing means walking the tree, and the collaboration cache is routinely
        # the largest thing on the disk. Pay for that in the preview, which is
        # where the number informs a decision - not on every action run. An
        # in-place edit reclaims no space, so quoting a size for it would be a
        # lie dressed up as a number.
        if ($ListOnly -and $def.Mode -ne 'RecentList') {
            $size = Get-TreeSize $path
            if ($size -eq 0) { continue }
            Write-Log ("{0}  {1}" -f (Format-Bytes $size), $label) 'WARN'
        } else {
            Write-Log ("            {0}" -f $label) 'WARN'
        }
    }
}

# Anything under a year root that the catalogue does not name. Reported, never
# touched - that is how a new Revit release's new subfolder stays safe. Scoped
# to the LOCAL tree, where caches live; the roaming tree is settings.
function Show-Unclassified {
    param([string[]]$Years)

    $known = @($YearCaches |
               Where-Object { -not ($_.ContainsKey('Root') -and $_.Root -eq 'Roaming') } |
               ForEach-Object { ($_.Rel -split '\\')[0] })

    foreach ($year in $Years) {
        $yearRoot = Join-Path $LocalRevit "Autodesk Revit $year"
        if (-not (Test-Path -LiteralPath $yearRoot)) { continue }

        foreach ($item in @(Get-ChildItem -LiteralPath $yearRoot -Force -ErrorAction SilentlyContinue)) {
            if ($known -contains $item.Name) { continue }
            $why = if ($NotCache.ContainsKey($item.Name)) { $NotCache[$item.Name] } else { 'not in the cache catalogue' }
            Write-Log ("  left alone: {0}\{1}   ({2})" -f "Autodesk Revit $year", $item.Name, $why)
        }
    }

    $sharedNames = @($SharedCaches | ForEach-Object { Split-Path -Leaf $_.Path })
    foreach ($item in @(Get-ChildItem -LiteralPath $LocalRevit -Force -ErrorAction SilentlyContinue)) {
        if ($item.Name -match '^Autodesk Revit \d{4}$') { continue }
        if ($sharedNames -contains $item.Name) { continue }
        $why = if ($NotCache.ContainsKey($item.Name)) { $NotCache[$item.Name] } else { 'not in the cache catalogue' }
        Write-Log ("  left alone: {0}   ({1})" -f $item.Name, $why)
    }
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

Write-Host ''
Write-Log "Clear-RevitCache - user $env:USERNAME - target year(s): $ProductYear"
Write-Log "Log: $script:LogPath"
if ($OlderThanDays -gt 0) { Write-Log "Age filter: only entries older than $OlderThanDays day(s)" }
if ($ListOnly)            { Write-Log 'ListOnly: no changes will be made.' 'DRY' }

if (-not (Test-Path -LiteralPath $LocalRevit)) {
    Write-Log "No Revit data found at $LocalRevit - nothing to clear." 'WARN'
    exit 2
}

$years = @(Get-RevitYears)
if ($years.Count -eq 0) {
    if ($ProductYear -ne 'All') {
        Write-Log "No Revit $ProductYear data found under $LocalRevit." 'WARN'
    } else {
        Write-Log "No per-year Revit data found under $LocalRevit." 'WARN'
    }
    exit 2
}
Write-Log ("Revit years with cached data: {0}" -f ($years -join ', '))

if (-not (Invoke-ProcessGuard)) { exit 1 }

Write-Section 'Cache locations'
$targets = @(Get-Targets -Years $years)

if ($targets.Count -eq 0) {
    if ($OlderThanDays -gt 0) {
        Write-Log "Nothing to clear - no cache entry is older than $OlderThanDays day(s)." 'OK'
    } else {
        Write-Log 'Nothing to clear - every cache in scope is already empty.' 'OK'
    }
    Write-Section 'Not touched'
    Show-OptInAvailable -Years $years
    Show-Unclassified   -Years $years
    exit 2
}

$totalBytes = Get-SumOf $targets 'Bytes'

foreach ($t in $targets) {
    $flag = if ($t.Risky) { '  <-- HOLDS UNSYNCED WORK' } else { '' }
    Write-Log ("{0}  {1,-34} {2,4} item(s)  {3}{4}" -f (Format-Bytes $t.Bytes), $t.Name, $t.Entries.Count, $t.Path, $flag)
    Write-Log ("            {0}" -f $t.Why)

    if ($t.Risky -or $ListOnly) {
        # A risky target is listed in full - deciding whether to purge a cloud
        # model is exactly the decision that needs every row. Everything else is
        # capped, or a year with 50 journal sessions buries the summary.
        $cap = if ($t.Risky) { $t.Entries.Count } else { 12 }
        foreach ($e in ($t.Entries | Select-Object -First $cap)) {
            $age = [int]((Get-Date) - $e.LastWriteTime).TotalDays
            Write-Log ("            {0}  {1,-40} last written {2} day(s) ago" -f (Format-Bytes $e.Bytes), $e.Label, $age)
        }
        if ($t.Entries.Count -gt $cap) {
            Write-Log ("            ... and {0} more of the same kind" -f ($t.Entries.Count - $cap))
        }
    }
}

Write-Section 'Not touched'
Show-OptInAvailable -Years $years
Show-Unclassified   -Years $years

Write-Host ''
Write-Log ("Total reclaimable: {0} across {1} location(s)" -f (Format-Bytes $totalBytes).Trim(), $targets.Count)

if ($ListOnly) {
    Write-Host ''
    Write-Log 'ListOnly: nothing was changed. Re-run without -ListOnly to clear.' 'DRY'
    exit 0
}

# --- The collaboration cache gets its own gate ------------------------------
$risky = @($targets | Where-Object { $_.Risky })
if ($risky.Count -gt 0 -and -not $Force) {
    Write-Host ''
    Write-Log 'The collaboration cache holds your LOCAL copy of cloud models.' 'WARN'
    Write-Log 'Anything not synced to BIM 360 / ACC exists ONLY here and will be lost.' 'WARN'
    Write-Log 'Synced models are re-downloaded on next open - slow, but lossless.' 'WARN'
    $answer = Read-Host 'Type YES to confirm every cloud model listed above is synced and closed'
    if ($answer -ne 'YES') {
        Write-Log 'Not confirmed - skipping the collaboration cache.' 'WARN'
        $targets = @($targets | Where-Object { -not $_.Risky })
        if ($targets.Count -eq 0) { Write-Log 'Nothing left to do.' 'WARN'; exit 0 }
    }
}

# --- Clear ------------------------------------------------------------------
Write-Section 'Clearing'

foreach ($t in $targets) {
    if (-not (Confirm-Action ("Clear {0} ({1} item(s), {2})?" -f $t.Name, $t.Entries.Count, (Format-Bytes $t.Bytes).Trim()))) {
        Write-Log "skipped by user: $($t.Name)" 'WARN'
        continue
    }

    foreach ($e in $t.Entries) {
        # Mode decides BOTH how an entry was enumerated and what is done to it.
        # Enumeration already fails closed on an unknown mode; so does this, or
        # the next mode added would silently inherit "delete it all".
        switch ($t.Mode) {
            'RecentList' {
                Clear-RecentFileList -Path $t.Path -LineIndices $e.IniLines
            }
            { @('Contents','Projects','Journals') -contains $_ } {
                # One operation for all three - the enumerators normalised the
                # shape, so nothing here needs to know which one produced it.
                $freed = [long]0
                foreach ($p in $e.Paths) {
                    $known = if ($e.Paths.Count -eq 1) { $e.Bytes } else { -1 }
                    $freed += Remove-CacheItem -Path $p -Label $p -KnownBytes $known
                }
                if ($freed -gt 0) {
                    Write-Log ("cleared {0} ({1})" -f $e.Label, (Format-Bytes $freed).Trim()) 'OK'
                }
            }
            default { throw "Cache catalogue error: no clearing action for Mode '$($t.Mode)' ($($t.Name))" }
        }
    }
}

# --- Summary ----------------------------------------------------------------
Write-Section 'Summary'
Write-Log ("Removed {0} item(s), freed {1}" -f $script:ItemsRemoved, (Format-Bytes $script:BytesFreed).Trim())
Write-Log "Log written to $script:LogPath"

if ($script:Failures.Count -gt 0) {
    Write-Log ("{0} item(s) could not be removed:" -f $script:Failures.Count) 'ERROR'
    foreach ($f in $script:Failures) { Write-Log "  $f" 'ERROR' }
    Write-Log 'Usually a file still open - close Revit and re-run.' 'WARN'
    exit 3
}

Write-Log 'Cache cleared.' 'OK'
exit 0
