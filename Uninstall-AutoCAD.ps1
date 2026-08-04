<#
.SYNOPSIS
    Uninstalls an Autodesk AutoCAD product (any year) and its orphaned add-ins on
    Windows, preserving shared and cross-version Autodesk components.

.DESCRIPTION
    Discovers the installed AutoCAD product family for the target year
    (-ProductYear, default 2026) by reading the Windows "Uninstall" registry
    hives (64-bit, 32-bit/WOW6432Node, and per-user), then runs each
    vendor-registered uninstaller silently, in dependency order.

    AutoCAD registers as a FAMILY of entries per year, not a single product:

        Autodesk AutoCAD <year>.<n> Update   ODIS patch bundle
        Autodesk AutoCAD <year> - <lang>     ODIS bundle wrapper (the orchestrator)
        AutoCAD <year> - <lang>              MSI child, hidden (SystemComponent=1)
        ACAD Private                         MSI child, hidden (SystemComponent=1)

    The last two carry NO UninstallString and NO QuietUninstallString at all, so
    msiexec against their product code is the only route. "ACAD Private" is the
    hard case: its display name contains neither the word "AutoCAD" nor a year,
    and EVERY installed AutoCAD year registers one under that identical name.
    It is therefore matched by InstallLocation (under the target year's install
    root), and the whole target list is de-duplicated by product code rather
    than by display name - de-duplicating by name would collapse every year's
    "ACAD Private" into one arbitrary entry.

    Removal order is explicit: update bundles, then add-ins/extras, then the
    ODIS bundle wrapper, then any MSI children still registered. The ODIS
    wrapper normally removes its own MSI children, so those usually report
    1605 ("not installed") by the time they are reached, which is treated as
    success.

    Scope is deliberately conservative: the core AutoCAD <year> application is
    always removed; with -IncludeAddins (default on) every product whose name
    references AutoCAD AND the target year is also removed. Shared and
    cross-version components are ALWAYS preserved because other Autodesk
    products depend on them - notably RealDWG Shared <year>, which carries a
    year in its name but is consumed by Revit, Navisworks and Inventor.

    AutoCAD toolsets and AutoCAD-based siblings (Architecture, Mechanical,
    Electrical, MEP, Map 3D, Plant 3D, Raster Design, Civil 3D, Advance Steel,
    AutoCAD LT) are never swept. In addition, a pre-flight guard ABORTS the run
    when a product that genuinely shares the base install tree or release key
    (the toolsets proper, and Civil 3D) is installed against the target year,
    because removing base AutoCAD may leave it non-functional. Whether Autodesk's
    ODIS reference counting unwinds that case cleanly has NOT been verified, so
    the script stops and lets the operator decide rather than assuming either
    way. Residue belonging to a toolset (e.g. ...\Autodesk\MEP <year>) is out of
    scope for this script - uninstall the toolset with its own uninstaller.
    AutoCAD LT and Advance Steel ship
    their own private AutoCAD and therefore do not trip the guard, and neither
    does an add-in for another host whose name merely mentions a toolset (for
    example "Advance Steel Extension for Autodesk Revit"). Override with
    -IgnoreToolsetGuard.

    Resolution order for each product's uninstall command:
        1. msiexec /x "<cached LocalPackage>.msi" /qn /norestart
        2. msiexec /x {ProductCode} /qn /norestart
        3. msiexec /x {ProductCode} ... with a directory-property override
        4. QuietUninstallString (vendor-provided silent command)
        5. UninstallString (run directly; --silent attempted for ODIS EXE
           uninstallers, with the exact vendor command kept as an auto fallback)

.PARAMETER ProductYear
    Four-digit AutoCAD release year to target (e.g. 2023, 2024, 2025, 2026).
    Default: 2026. Everything - the core product match, the orphaned-add-in
    sweep, the residual folders, the residual path guard, and the self-elevation
    relaunch - is scoped to this year.

    NOTE: AutoCAD's internal RELEASE number is not a function of the year
    (2025 = R25.0, 2026 = R25.1, 2027 = R26.0). The release is resolved from the
    registry at runtime and never computed; where it cannot be proven, the
    release-scoped registry cleanup is skipped rather than guessed.

.PARAMETER IncludeAddins
    Also remove every product whose name references AutoCAD and the target year
    - object enablers, language packs, extensions - which are orphaned once the
    core application is gone. Default: $true. Disable with -IncludeAddins:$false.
    Cross-version and shared components (RealDWG Shared, Shared Components,
    ObjectDBX, Content Catalog, licensing, version-neutral companion apps) are
    always preserved, as are AutoCAD toolsets/verticals.

.PARAMETER RemoveResidualFiles
    After a successful uninstall, delete leftover AutoCAD <year>-specific
    folders (per-user settings/profiles, machine settings, and any residual
    AutoCAD <year> program folder). Default: $true. Disable with
    -RemoveResidualFiles:$false. A runtime guard only permits deletion of paths
    under an Autodesk tree that reference AutoCAD and the target year; shared
    Autodesk trees are never removed.

.PARAMETER RemoveResidualRegistry
    Also delete the release-scoped profile keys
    HKCU/HKLM:\SOFTWARE\Autodesk\AutoCAD\R<release>. Default: $false (opt-in),
    because these keys carry the RELEASE number and no year: deleting the wrong
    one destroys a different AutoCAD version's profiles. Only ever acts when the
    release-to-year mapping was proven from the registry and no other product
    still claims that release.

.PARAMETER IncludeMaterialLibraries
    Opt in to also remove Material Library packages matching the target year.
    Default: $false - material libraries are shared across Autodesk products.

.PARAMETER NeutralizeBrokenCustomActions
    When an MSI uninstall attempt exits 1603 and its verbose log shows
    "Internal Error 2753" (a custom action sourced from an installed file whose
    component registration is damaged), copy the cached package from
    C:\Windows\Installer to %TEMP%, condition the named action out ('0' =
    never run) in the COPY, recache it, and retry the uninstall. The protected
    cache is never modified in place (recent Windows builds refuse writes there
    even elevated). Default: $true. Disable with
    -NeutralizeBrokenCustomActions:$false.

    This is not inherited by analogy: the AutoCAD core package carries the same
    file-sourced custom action family (type 3217,
    _560A25DD.D5955B9C_A4DD_4C11_97BD_AB88FAFFCD9E) that produced the 2753 on
    Revit, so the same remediation applies.

.PARAMETER StopAutoCAD
    If AutoCAD processes belonging to the TARGET YEAR are running, terminate
    them before uninstalling. Processes belonging to other AutoCAD years are
    identified by executable path and are never touched. Without this switch the
    script aborts when a target-year process is running (safer default).

.PARAMETER IgnoreToolsetGuard
    Proceed even when an AutoCAD toolset that shares the base install tree or
    release key (Architecture, Mechanical, Electrical, MEP, Map 3D, Plant 3D,
    P&ID, Raster Design, Civil 3D) is installed against the target year.
    Removing base AutoCAD in that state orphans the toolset; use only when that
    is intended. -ListOnly always previews rather than aborting.

.PARAMETER ListOnly
    Discover and print matching products, then exit. Performs no changes.
    Equivalent to a dry run.

.PARAMETER Force
    Fully non-interactive: skips the per-product Read-Host prompt AND suppresses
    PowerShell's built-in ShouldProcess "Are you sure?" confirmation (this script
    is ConfirmImpact=High, which would otherwise prompt even under -Force).

.PARAMETER LogPath
    Full path for the transcript log. Defaults to
    %TEMP%\Uninstall-AutoCAD<year>_<timestamp>.log

.EXAMPLE
    # Preview what would be removed for the default year (2026), no changes:
    powershell -ExecutionPolicy Bypass -File .\Uninstall-AutoCAD.ps1 -ListOnly

.EXAMPLE
    # Uninstall AutoCAD 2024 + its add-ins + residual files, prompting each step:
    powershell -ExecutionPolicy Bypass -File .\Uninstall-AutoCAD.ps1 -ProductYear 2024

.EXAMPLE
    # Fully unattended and silent for AutoCAD 2025, close AutoCAD if open:
    powershell -ExecutionPolicy Bypass -File .\Uninstall-AutoCAD.ps1 -ProductYear 2025 -StopAutoCAD -Force

.EXAMPLE
    # Core product only (skip add-ins and residual cleanup):
    powershell -ExecutionPolicy Bypass -File .\Uninstall-AutoCAD.ps1 -ProductYear 2026 -IncludeAddins:$false -RemoveResidualFiles:$false

.EXAMPLE
    # Full wipe including the release-scoped profile keys:
    powershell -ExecutionPolicy Bypass -File .\Uninstall-AutoCAD.ps1 -ProductYear 2026 -RemoveResidualRegistry:$true -Force

.NOTES
    Requires an elevated (Administrator) session; the script self-elevates.
    Exit code 0 = success, 3010 = success (reboot required), 3 = partial failure,
    2 = nothing found, 1 = aborted.
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [ValidatePattern('^\d{4}$')]
    [string]$ProductYear       = '2026',
    [bool]$IncludeAddins       = $true,
    [bool]$IncludeMaterialLibraries = $false,
    [bool]$RemoveResidualFiles = $true,
    [bool]$RemoveResidualRegistry = $false,
    [bool]$NeutralizeBrokenCustomActions = $true,
    [switch]$StopAutoCAD,
    [switch]$IgnoreToolsetGuard,
    [switch]$ListOnly,
    [switch]$Force,
    [string]$LogPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# -Force implies fully non-interactive: suppress PowerShell's own ShouldProcess
# confirmation (ConfirmImpact=High would otherwise prompt "Are you sure?" for
# every product even under -Force).
if ($Force) { $ConfirmPreference = 'None' }

# Resolve -LogPath to a ROOTED path immediately, before anything consumes it.
#
# A bare filename ("-LogPath acad.log") or a drive-relative one ("C:acad.log")
# has no parent directory, and the registry-backup step later does
# Join-Path (Split-Path -Parent $LogPath) ... - which throws on an empty parent
# and, under $ErrorActionPreference='Stop', ends the run AFTER every product was
# already removed: the summary never prints, the opted-in registry cleanup never
# happens, and a fully successful run reports exit 1 ("aborted").
#
# This runs BEFORE the self-elevation relaunch on purpose. The relay forwards
# -LogPath to the elevated child, whose working directory is NOT the operator's,
# so resolving afterwards would silently point at a different folder.
if (-not [string]::IsNullOrWhiteSpace($LogPath)) {
    try {
        $LogPath = [IO.Path]::GetFullPath(
            [IO.Path]::Combine((Get-Location).ProviderPath, $LogPath))
    }
    catch {
        Write-Host "Invalid -LogPath '$LogPath': $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
}

# --- Configuration --------------------------------------------------------
# $ProductYear is supplied by the -ProductYear parameter (default 2026) and
# scopes every match below.

# Core product family: always targeted.
#
# Deliberately anchored - "AutoCAD <year>*" and "Autodesk AutoCAD <year>*" with
# NO leading wildcard - so a toolset such as "Autodesk AutoCAD MEP 2026 - English"
# or "AutoCAD LT 2026" can never match: those carry a token between "AutoCAD"
# and the year. The single trailing wildcard covers both the language suffix
# ("- English", "- Deutsch", ...) and the update suffix (".1 Update").
$CorePatterns = @(
    "AutoCAD $ProductYear*",
    "Autodesk AutoCAD $ProductYear*"
)

# AutoCAD-adjacent products this script NEVER sweeps. Broad on purpose: being
# listed here only means "not a removal target", which is always the safe answer.
$ToolsetPatterns = @(
    '*AutoCAD Architecture*',
    '*AutoCAD Mechanical*',
    '*AutoCAD Electrical*',
    '*AutoCAD MEP*',
    '*AutoCAD Map 3D*',
    '*AutoCAD Plant 3D*',
    '*AutoCAD P&ID*',
    '*AutoCAD Raster Design*',
    '*AutoCAD LT*',
    '*Civil 3D*',
    '*Advance Steel*',
    '*Plant 3D*',
    '*Fabrication CADmep*',
    '*Fabrication ESTmep*',
    '*Fabrication CAMduct*'
)

# The STRICT subset that actually shares the base AutoCAD install tree or the
# base release key - the toolsets proper, which install into
# ...\Autodesk\AutoCAD <year>\<TOOLSET>\ and register against the same R<rel>.
# Only these trip the pre-flight guard, because only these are orphaned when
# base AutoCAD is removed.
#
# Deliberately NOT here: AutoCAD LT and Advance Steel ship their own private
# AutoCAD and survive the base product's removal, so flagging them would abort
# a perfectly safe run.
$SharedReleasePatterns = @(
    '*AutoCAD Architecture*',
    '*AutoCAD Mechanical*',
    '*AutoCAD Electrical*',
    '*AutoCAD MEP*',
    '*AutoCAD Map 3D*',
    '*AutoCAD Plant 3D*',
    '*AutoCAD P&ID*',
    '*AutoCAD Raster Design*',
    '*Civil 3D*'
)

# A display name that ALSO references a different Autodesk HOST describes an
# add-in for that host, not an AutoCAD toolset. Measured false positives this
# removes: "Advance Steel Server Registration for Revit Engine 2026" and
# "Autodesk Advance Steel Extension for Autodesk Revit 2025" - both Revit
# add-ins that would otherwise abort an AutoCAD uninstall at the guard.
$ForeignHostPatterns = @(
    '*Revit*',
    '*Navisworks*',
    '*Inventor*',
    '*3ds Max*',
    '*Maya*',
    '*Tekla*'
)

# Shared / cross-product components: NEVER touched in this mode.
#
# RealDWG Shared <year> and Shared Components <year> carry a YEAR in the name
# but are consumed by Revit, Navisworks and Inventor - the year filter alone
# does not protect them, so they are excluded by name.
$SharedExclusions = @(
    '*Shared Components*',
    '*RealDWG*',
    '*ObjectDBX*',
    '*Licensing*',
    '*License*',
    '*Desktop Licensing Service*',
    '*Genuine Service*',
    '*Identity Manager*',
    '*Autodesk Access*',
    '*Desktop App*',
    '*Autodesk Access Core*',
    '*Single Sign On*',
    '*ODIS*',
    '*AdODIS*',
    '*Autodesk Installer*',
    '*Content Catalog*',
    '*Interoperability Engine Manager*',
    '*Desktop Connector*',
    '*Autodesk App Manager*',
    '*Featured Apps*',
    '*Save to Web and Mobile*',
    '*Activity Insights*',
    '*Open in Desktop*',
    '*MCP Server*',
    '*Inventor Server*',
    '*Autodesk CER*',
    '*Geospatial Coordinate Systems*',
    '*TrueView*',
    '*TrueConvert*'
)

# Toolsets are excluded from the sweep by the same mechanism as shared
# components. The guard reports them separately; this keeps them out of the
# target list even when the guard is overridden.
$SharedExclusions += $ToolsetPatterns

# Lock shared material packages out dynamically if explicit sweep is off
if (-not $IncludeMaterialLibraries) {
    $SharedExclusions += '*Material Library*'
    $SharedExclusions += '*Advanced Material Library*'
}

# Default install root. The real roots are resolved from the registry at
# runtime (Resolve-AcadRelease); this is the fallback and the value used for
# residual cleanup when the product registration is already gone.
$DefaultAcadRoot = Join-Path ${env:ProgramFiles} "Autodesk\AutoCAD $ProductYear"

# AutoCAD <year>-specific residual folders removed only with
# -RemoveResidualFiles. Every entry carries the YEAR in the path itself, so
# folder cleanup never depends on resolving the release number. A runtime guard
# re-verifies each path before deletion.
$ResidualPaths = @(
    (Join-Path $env:APPDATA      "Autodesk\AutoCAD $ProductYear"),
    (Join-Path $env:LOCALAPPDATA "Autodesk\AutoCAD $ProductYear"),
    (Join-Path $env:ProgramData  "Autodesk\AutoCAD $ProductYear"),
    $DefaultAcadRoot
)

# Per-installation host processes that lock files under the install root.
# Shared Autodesk infrastructure (AdskLicensingService, AdskIdentityManager,
# AdskAccessCore, AdskAccessServiceHost, AdSSO) is deliberately ABSENT: those
# serve every Autodesk product on the machine and must keep running.
$AcadProcessNames = @(
    'acad',
    'accoreconsole',
    'AcWebBrowser',
    'AcQMod',
    'AcTranslators',
    'AcSignApply',
    'senddmp',
    'AdAppMgrSvc'
)

# Directory-property override, used only as the LAST msiexec attempt.
#
# On Revit this cleared a measured failure: that package's Type-51
# DIRCA_INSTALLDIR action rebuilt INSTALLDIR as a bare relative fragment and
# killed CostFinalize with 1314/1606. The AutoCAD packages inspected for this
# script do NOT carry DIRCA_INSTALLDIR, so here it is a GENERIC last resort
# rather than a targeted fix - kept because it costs nothing when unused, kept
# LAST because forcing directory properties on an uninstall can itself knock a
# component out of the action sequence and provoke 2753.
#
# NO trailing backslash before the closing quote (\" escapes the quote and
# mangles every argument after it); ROOTDRIVE stays unquoted (no spaces)
# because its value MUST end in a backslash.
$FallbackDirProps = ' ROOTDRIVE=C:\ INSTALLDIR="' + $DefaultAcadRoot + '"'

# --- Self-elevation -------------------------------------------------------
function Test-IsAdministrator {
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-IsAdministrator)) {
    Write-Host 'Elevation required. Relaunching as Administrator...' -ForegroundColor Yellow

    # Guard: self-elevation needs the script's own path. It is empty when the
    # script is dot-sourced or pasted into the console rather than run as a file.
    if ([string]::IsNullOrWhiteSpace($PSCommandPath)) {
        Write-Host 'Cannot self-elevate: script path is unknown. Run it with -File (not dot-sourced/pasted), or start an elevated PowerShell first.' -ForegroundColor Red
        exit 1
    }

    # Build the relaunch command line as a SINGLE string, not an array.
    # Start-Process re-quotes array elements in Windows PowerShell 5.1 and
    # mangles a script path that contains spaces (e.g. "E:\ICZ 2\Desktop\..."),
    # which silently breaks self-elevation. A single pre-quoted string is passed
    # to the child verbatim.
    $passArgs = @()
    $passArgs += ('-ProductYear {0}'          -f $ProductYear)
    $passArgs += ('-IncludeAddins:${0}'       -f $IncludeAddins)
    $passArgs += ('-IncludeMaterialLibraries:${0}' -f $IncludeMaterialLibraries)
    $passArgs += ('-RemoveResidualFiles:${0}' -f $RemoveResidualFiles)
    $passArgs += ('-RemoveResidualRegistry:${0}' -f $RemoveResidualRegistry)
    $passArgs += ('-NeutralizeBrokenCustomActions:${0}' -f $NeutralizeBrokenCustomActions)
    if ($StopAutoCAD)        { $passArgs += '-StopAutoCAD' }
    if ($IgnoreToolsetGuard) { $passArgs += '-IgnoreToolsetGuard' }
    if ($ListOnly)           { $passArgs += '-ListOnly' }
    if ($Force)              { $passArgs += '-Force' }

    # COMMON parameters live OUTSIDE param(), so a relay assembled from this
    # script's own parameter list silently drops them at the UAC boundary.
    #
    # For -WhatIf that is not cosmetic, it is catastrophic: the elevated child
    # starts WITHOUT -WhatIf, $PSCmdlet.ShouldProcess() returns $true, and a
    # command the user issued as a PREVIEW performs a real uninstall. Measured
    # on 2026-08-02: `-ProductYear 2026 -WhatIf -Force` removed a live AutoCAD
    # 2026 because -WhatIf stopped at the elevation boundary.
    if ($WhatIfPreference) { $passArgs += '-WhatIf' }
    if ($PSBoundParameters.ContainsKey('Confirm')) {
        $passArgs += ('-Confirm:${0}' -f [bool]$PSBoundParameters['Confirm'])
    }
    if ($VerbosePreference -eq 'Continue') { $passArgs += '-Verbose' }
    if ($DebugPreference   -eq 'Continue') { $passArgs += '-Debug' }
    if ($LogPath)            { $passArgs += ("-LogPath '{0}'" -f ($LogPath -replace "'", "''")) }

    # powershell.exe -File CANNOT bind [bool] parameters (nor -Switch:$false):
    # PS 5.1 passes every -File argument as a literal string and rejects it with
    # "Boolean parameters accept only Boolean values and numbers" (verified on
    # this machine for True / False / 1 / 0 / $false). The elevated child would
    # die at parameter binding BEFORE Start-Transcript - no log, elevation
    # "does nothing". Relaunch through -Command with a single-quoted
    # call-operator path instead: $true/$false literals then parse natively and
    # a spaced script path still survives as one argument. The trailing
    # "; exit $LASTEXITCODE" is required: in -Command mode an "exit N" inside
    # the invoked SCRIPT only sets $LASTEXITCODE - without re-exiting, the
    # child process collapses every non-zero script exit to 1 (verified:
    # exit 42 came back as 1 without it, 42 with it), destroying the
    # 0/2/3/3010 exit-code contract relayed by the non-elevated parent.
    $qPath   = $PSCommandPath -replace "'", "''"
    $cmdLine = '-NoProfile -ExecutionPolicy Bypass -Command "& ''{0}'' {1}; exit $LASTEXITCODE"' -f $qPath, ($passArgs -join ' ')

    # FAIL CLOSED. The elevation boundary is a SERIALIZATION boundary: anything
    # not explicitly written into $cmdLine does not exist in the privileged
    # child. A preview flag that fails to cross it turns a preview into a real
    # uninstall, so verify it is actually present in the bytes about to be
    # launched rather than trusting that the line above added it.
    if ($WhatIfPreference -and $cmdLine -notmatch '(?i)(?<=\s)-WhatIf(?=\s|;|")') {
        Write-Host 'Refusing to elevate: -WhatIf was requested but is not present in the elevated command line. Aborting rather than running a real uninstall under a preview flag.' -ForegroundColor Red
        exit 1
    }

    try {
        $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList $cmdLine -Verb RunAs -PassThru -Wait -ErrorAction Stop
    }
    catch {
        # Thrown when the user clicks No / cancels the UAC prompt, or UAC is blocked.
        Write-Host "Elevation was cancelled or blocked at the UAC prompt: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }

    # ExitCode can be null for ShellExecute (RunAs) launches; default to 0.
    $code = 0
    if ($proc -and $null -ne $proc.ExitCode) { $code = $proc.ExitCode }
    exit $code
}

# --- Logging --------------------------------------------------------------
if (-not $LogPath) {
    $stamp   = Get-Date -Format 'yyyyMMdd_HHmmss'
    $LogPath = Join-Path $env:TEMP "Uninstall-AutoCAD${ProductYear}_$stamp.log"
}
# -WhatIf:$false is deliberate. Start-Transcript is itself ShouldProcess-aware,
# so under -WhatIf it PREVIEWS instead of opening the log - and the run then
# ends by announcing "Log saved to: <path>" for a file that was never written
# (observed 2026-08-02). A preview you cannot review afterwards is the least
# useful kind, and the transcript is this script's own diagnostic output in
# %TEMP%, not a change to the machine being previewed. The header written below
# marks preview logs so one can never be mistaken for a real uninstall record.
try { Start-Transcript -Path $LogPath -Append -WhatIf:$false | Out-Null } catch { }

# Preload CimCmdlets while the preview flag is switched off in a child scope.
# Get-CimInstance (process check, further down) autoloads this module; if that
# happens mid -WhatIf run, the module's OWN top-level Set-Alias calls inherit
# $WhatIfPreference and spray 12 lines of "What if: Performing the operation
# Set Alias" into the middle of the report. Measured: 12 lines without this
# preload, 0 with it, Win32_Process still returning 400 rows either way.
& { $WhatIfPreference = $false; Import-Module CimCmdlets -ErrorAction SilentlyContinue }

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $ts = Get-Date -Format 'HH:mm:ss'
    $color = switch ($Level) {
        'WARN'  { 'Yellow' }
        'ERROR' { 'Red' }
        'OK'    { 'Green' }
        default { 'Gray' }
    }
    Write-Host ("[{0}] {1,-5} {2}" -f $ts, $Level, $Message) -ForegroundColor $color
}

if ($WhatIfPreference) {
    Write-Log '*** PREVIEW (-WhatIf): nothing will be uninstalled or deleted. ***' 'WARN'
}
Write-Log "AutoCAD $ProductYear uninstall started. Log: $LogPath"
Write-Log ("Mode: {0}{1}{2}{3}{4}{5}" -f `
    $(if ($WhatIfPreference) { 'PREVIEW ' } else { '' }),
    $(if ($ListOnly) { 'ListOnly ' } else { 'Uninstall ' }),
    $(if ($IncludeAddins) { '+Add-ins ' } else { 'CoreOnly ' }),
    $(if ($RemoveResidualFiles) { '+Residual ' } else { '' }),
    $(if ($RemoveResidualRegistry) { '+Registry ' } else { '' }),
    $(if ($Force) { 'Force' } else { 'Interactive' }))

# --- Product discovery ----------------------------------------------------
# StrictMode-safe property reader: returns the value or $null, never throws
# when the registry key lacks the requested value.
function Get-Prop {
    param($Obj, [string]$Name)
    # $Obj is $null whenever Get-ItemProperty was handed a registry key that has
    # ZERO values - which is normal for container keys such as
    # ...\AutoCAD\R25.1\ACAD-9101 and ...\InstalledProducts. Dereferencing
    # .PSObject on $null is a terminating error under StrictMode, so this must
    # be checked before the lookup, not after.
    if ($null -eq $Obj) { return $null }
    $p = $Obj.PSObject.Properties[$Name]
    if ($null -ne $p) { return $p.Value }
    return $null
}

# Registry DWORDs can be absent, empty, or non-numeric. [int]'' throws; this
# never does.
function ConvertTo-IntOrZero {
    param($Value)
    if ($null -eq $Value) { return 0 }
    $n = 0
    if ([int]::TryParse([string]$Value, [ref]$n)) { return $n }
    return 0
}

function Get-InstalledPrograms {
    $hives = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    foreach ($hive in $hives) {
        if (-not (Test-Path $hive)) { continue }
        Get-ChildItem -Path $hive -ErrorAction SilentlyContinue | ForEach-Object {
            $props = $null
            try { $props = Get-ItemProperty -Path $_.PsPath -ErrorAction Stop } catch { return }
            $dn = Get-Prop $props 'DisplayName'
            if ([string]::IsNullOrWhiteSpace($dn)) { return }
            [pscustomobject]@{
                DisplayName          = $dn
                DisplayVersion       = Get-Prop $props 'DisplayVersion'
                Publisher            = Get-Prop $props 'Publisher'
                UninstallString      = Get-Prop $props 'UninstallString'
                QuietUninstallString = Get-Prop $props 'QuietUninstallString'
                WindowsInstaller     = ConvertTo-IntOrZero (Get-Prop $props 'WindowsInstaller')
                SystemComponent      = ConvertTo-IntOrZero (Get-Prop $props 'SystemComponent')
                InstallLocation      = Get-Prop $props 'InstallLocation'
                ParentKeyName        = Get-Prop $props 'ParentKeyName'
                KeyName              = $_.PSChildName
                RegistryPath         = $_.PsPath
            }
        }
    }
}

function Test-MatchesAny {
    param([string]$Value, [string[]]$Patterns)
    foreach ($p in $Patterns) { if ($Value -like $p) { return $true } }
    return $false
}

# Normalize a directory path for comparison: trim trailing separators, collapse
# doubled separators (Autodesk writes "C:\Program Files\Autodesk\\Foo\" in some
# registrations), and lower-case it.
function Get-ComparablePath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    $p = $Path.Trim().Trim('"')
    $p = $p -replace '\\{2,}', '\'
    return $p.TrimEnd('\', '/').ToLowerInvariant()
}

function Test-PathUnderAny {
    param([string]$Path, [string[]]$Roots)
    $c = Get-ComparablePath $Path
    if ([string]::IsNullOrWhiteSpace($c)) { return $false }
    foreach ($r in $Roots) {
        $cr = Get-ComparablePath $r
        if ([string]::IsNullOrWhiteSpace($cr)) { continue }
        if ($c -eq $cr -or $c.StartsWith($cr + '\')) { return $true }
    }
    return $false
}

# --- AutoCAD release resolution -------------------------------------------
# THE central AutoCAD fact: the internal release number is NOT a function of the
# year. Measured on this platform: 2025 = R25.0, 2026 = R25.1, 2027 = R26.0.
# Two years can share a major version, and the mapping has no arithmetic form.
#
# So the release is READ from HKLM:\SOFTWARE\Autodesk\AutoCAD\R<rel>\<PRODKEY>,
# where each product key carries ProductNameGlob ("AutoCAD 2026"), UPIRELEASE
# ("2026"), ProductName ("AutoCAD 2026 - English") and Location. Nothing is
# computed, and when nothing proves the mapping the caller skips every
# release-scoped operation instead of guessing.
#
# Returns $null when the target year has no release registration.
function Resolve-AcadRelease {
    param(
        [string]$Year,
        [string]$HiveRoot = 'HKLM:\SOFTWARE\Autodesk\AutoCAD'
    )

    $root = $HiveRoot
    if (-not (Test-Path -LiteralPath $root)) { return $null }

    # NOT named $matches: that is a PowerShell AUTOMATIC variable, rewritten to a
    # hashtable by every successful -match/-notmatch in this scope. The -notmatch
    # on the release-container name below would silently replace the accumulator
    # mid-loop and the next += fails with "A hash table can only be added to
    # another hash table."
    $found = @()
    foreach ($rel in @(Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) {
        # Release containers look like "R25.1". Anything else is not a release.
        if ($rel.PSChildName -notmatch '^R\d+\.\d+$') { continue }

        foreach ($prod in @(Get-ChildItem -LiteralPath $rel.PSPath -ErrorAction SilentlyContinue)) {
            $p = $null
            try { $p = Get-ItemProperty -LiteralPath $prod.PsPath -ErrorAction Stop } catch { continue }

            $glob    = [string](Get-Prop $p 'ProductNameGlob')
            $upi     = [string](Get-Prop $p 'UPIRELEASE')
            $name    = [string](Get-Prop $p 'ProductName')
            $loc     = [string](Get-Prop $p 'Location')
            if ([string]::IsNullOrWhiteSpace($loc)) { $loc = [string](Get-Prop $p 'AcadLocation') }

            # Year evidence, strongest first. UPIRELEASE and ProductNameGlob are
            # explicit; ProductName is the human string and is accepted only
            # when it names base AutoCAD for this year (so a toolset sharing the
            # release cannot masquerade as the base product).
            $isYear = $false
            if ($upi -eq $Year)                        { $isYear = $true }
            elseif ($glob -eq "AutoCAD $Year")         { $isYear = $true }
            elseif ($name -like "AutoCAD $Year - *" -or $name -eq "AutoCAD $Year") { $isYear = $true }
            if (-not $isYear) { continue }

            $found += [pscustomobject]@{
                Release      = $rel.PSChildName
                ProductKey   = $prod.PSChildName
                ProductName  = $name
                Location     = $loc
                RegistryPath = $prod.PsPath
            }
        }
    }

    if ($found.Count -eq 0) { return $null }

    $releases = @($found | Select-Object -ExpandProperty Release -Unique)
    if ($releases.Count -gt 1) {
        # Two different releases both claiming the same year is not a state this
        # script will act on: a release-scoped delete would be a coin toss.
        Write-Log ("AutoCAD $Year maps to MORE THAN ONE release ({0}) - release-scoped operations will be skipped." -f ($releases -join ', ')) 'WARN'
        return $null
    }

    $roots = @($found |
        ForEach-Object { $_.Location } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        ForEach-Object { $_.Trim().TrimEnd('\') } |
        Select-Object -Unique)

    return [pscustomobject]@{
        Release     = $releases[0]
        Year        = $Year
        ProductKeys = @($found | Select-Object -ExpandProperty ProductKey -Unique)
        Roots       = $roots
        Products    = $found
    }
}

# Census of everything registered under a release. Two independent signals:
#   - InstalledProducts\<TOKEN> subkey NAMES (the toolset census; base AutoCAD
#     alone registers exactly "ACAD")
#   - sibling ACAD-<id>:<lcid> product keys whose <id> differs from the target's
#     (a DIFFERENT LCID is only a language pack of the same product and is NOT
#     a toolset, so ids are compared without the locale suffix)
#
# -HiveRoot exists so the detector can be exercised against a throwaway test
# hive: on a machine with only base AutoCAD installed this function can only
# ever be observed returning "nothing found", and a guard that has never been
# seen firing is not a proven guard.
function Get-ReleaseCoTenants {
    param(
        [string]$Release,
        [string[]]$OwnProductKeys,
        [string]$HiveRoot = 'HKLM:\SOFTWARE\Autodesk\AutoCAD'
    )

    $result = [pscustomobject]@{
        InstalledProductTokens = @()
        ForeignProductKeys     = @()
    }
    if ([string]::IsNullOrWhiteSpace($Release)) { return $result }

    $relPath = Join-Path $HiveRoot $Release
    if (-not (Test-Path -LiteralPath $relPath)) { return $result }

    $ipPath = Join-Path $relPath 'InstalledProducts'
    if (Test-Path -LiteralPath $ipPath) {
        $result.InstalledProductTokens = @(
            Get-ChildItem -LiteralPath $ipPath -ErrorAction SilentlyContinue |
                Select-Object -ExpandProperty PSChildName
        )
    }

    # Strip the ":<lcid>" suffix so language packs of the same product collapse.
    $ownIds = @($OwnProductKeys | ForEach-Object { ($_ -split ':')[0] } | Select-Object -Unique)
    $result.ForeignProductKeys = @(
        Get-ChildItem -LiteralPath $relPath -ErrorAction SilentlyContinue |
            Where-Object { $_.PSChildName -match '^ACAD-' } |
            Where-Object { $ownIds -notcontains ($_.PSChildName -split ':')[0] } |
            Select-Object -ExpandProperty PSChildName
    )
    return $result
}

$release = Resolve-AcadRelease -Year $ProductYear
if ($release) {
    Write-Log ("Resolved AutoCAD {0} -> release {1} (product key(s): {2})" -f `
        $ProductYear, $release.Release, ($release.ProductKeys -join ', ')) 'OK'
    if ($release.Roots.Count -gt 0) {
        Write-Log ("Install root(s): {0}" -f ($release.Roots -join '; '))
    }
}
else {
    Write-Log "No AutoCAD $ProductYear release registration found under HKLM:\SOFTWARE\Autodesk\AutoCAD. Release-scoped operations will be skipped (the release number is never guessed)." 'WARN'
}

# Install roots used to attribute the un-named MSI children ("ACAD Private") and
# to scope the running-process guard. Registry-resolved roots first, the
# conventional path as a fallback so a run after partial removal still works.
$AcadRoots = @()
if ($release) { $AcadRoots += $release.Roots }
$AcadRoots += $DefaultAcadRoot
$AcadRoots = @($AcadRoots | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)

# Fold the REGISTRY-RESOLVED roots into the residual list, which up to here knew
# only $DefaultAcadRoot under %ProgramFiles%. AutoCAD is routinely installed off
# the system drive when the system SSD is small, and the roots for that case are
# already in hand - line ~742 above even LOGS them ("Install root(s):
# D:\Autodesk\AutoCAD 2026"). Without this the multi-gigabyte program folder
# survived a full run in silence, and -ListOnly reported "No AutoCAD <year>
# residual folders found" for a folder sitting right there. Test-SafeResidualPath
# still vets every entry at deletion time, so a root that carries no 'Autodesk'
# segment is refused rather than deleted.
#
# @()-wrapped: a union that collapses to a single string turns any later '+='
# into string concatenation instead of an array append.
$ResidualPaths = @(@($ResidualPaths) + @($AcadRoots) | Select-Object -Unique)

$all = @(Get-InstalledPrograms |
    Where-Object { $_.Publisher -like '*Autodesk*' -or $_.DisplayName -like '*AutoCAD*' })

# --- Toolset / vertical guard ---------------------------------------------
# Removing base AutoCAD while a toolset is installed against the same year or
# release orphans the toolset: Civil 3D installs INTO ...\AutoCAD <year>\, and
# every vertical binds to the base release key. This has no Revit analogue and
# is the one pre-flight abort in the script.
$toolsetHits = @($all | Where-Object {
    (Test-MatchesAny -Value $_.DisplayName -Patterns $SharedReleasePatterns) -and
    -not (Test-MatchesAny -Value $_.DisplayName -Patterns $ForeignHostPatterns) -and
    ($_.DisplayName -like "*$ProductYear*")
})

$coTenants = $null
if ($release) {
    $coTenants = Get-ReleaseCoTenants -Release $release.Release -OwnProductKeys $release.ProductKeys
}

$foreignTokens = @()
if ($coTenants) {
    $foreignTokens = @($coTenants.InstalledProductTokens | Where-Object { $_ -ne 'ACAD' })
}

$guardTripped = ($toolsetHits.Count -gt 0) -or ($foreignTokens.Count -gt 0) -or
                ($coTenants -and $coTenants.ForeignProductKeys.Count -gt 0)

if ($guardTripped) {
    Write-Log '---------------------------------------------' 'WARN'
    Write-Log "TOOLSET GUARD: another AutoCAD-based product shares AutoCAD $ProductYear." 'WARN'
    foreach ($t in $toolsetHits) {
        Write-Log ("    installed product : {0}  [{1}]" -f $t.DisplayName, $t.DisplayVersion) 'WARN'
    }
    foreach ($t in $foreignTokens) {
        Write-Log ("    release tenant    : {0}\InstalledProducts\{1}" -f $release.Release, $t) 'WARN'
    }
    if ($coTenants) {
        foreach ($t in $coTenants.ForeignProductKeys) {
            Write-Log ("    release product   : {0}\{1}" -f $release.Release, $t) 'WARN'
        }
    }
    # Deliberately an observation, not an assertion. ODIS maintains reference
    # counts across bundles and MAY unwind this correctly; that has not been
    # verified here. Refusing costs a re-run with a switch, being wrong costs a
    # broken toolset - so the script stops and lets the operator decide.
    Write-Log 'The product(s) above share this AutoCAD release. Removing base AutoCAD may leave them non-functional.' 'WARN'
    if (-not $IgnoreToolsetGuard -and -not $ListOnly) {
        Write-Log 'Aborting. Uninstall the toolset first, or re-run with -IgnoreToolsetGuard.' 'ERROR'
        try { Stop-Transcript | Out-Null } catch { }
        exit 1
    }
    Write-Log $(if ($ListOnly) { 'ListOnly - continuing to preview.' } else { '-IgnoreToolsetGuard specified - continuing anyway.' }) 'WARN'
    Write-Log '---------------------------------------------' 'WARN'
}

# --- Target selection -----------------------------------------------------
# Core family is always targeted. With -IncludeAddins, ALSO sweep every product
# whose name references AutoCAD AND the target year - object enablers, language
# packs and extensions that install as separate products and are orphaned once
# the core application is gone.
#
# "ACAD Private" is matched separately, by InstallLocation: its display name
# contains neither "AutoCAD" nor a year, so no name rule can reach it, and every
# installed year registers one under that identical name.
$targets = @(
    $all |
    Where-Object {
        $name = $_.DisplayName

        $isCore = Test-MatchesAny -Value $name -Patterns $CorePatterns

        # Deliberately NOT matching a bare \bDWG\b: that is a FILE FORMAT token,
        # not a product relationship. It reaches "Autodesk DWG TrueView <year>"
        # and "DWG TrueConvert" - independent free products that ship their own
        # installers and have no dependency on AutoCAD being present.
        $isAcadYear = $IncludeAddins -and
                      ($name -match '(?i)\bAutoCAD\b|\bACAD\b') -and
                      ($name -like "*$ProductYear*")

        # Hidden MSI child attributed by install location rather than by name.
        # Gated on WindowsInstaller so only real MSI registrations qualify.
        $isPrivateChild = ($_.WindowsInstaller -eq 1) -and
                          (Test-PathUnderAny -Path $_.InstallLocation -Roots $AcadRoots)

        $isMaterialYear = $IncludeMaterialLibraries -and
                          ($name -match '(?i)Material Library') -and
                          ($name -like "*$ProductYear*")

        $isCore -or $isAcadYear -or $isPrivateChild -or $isMaterialYear
    } |
    Where-Object { -not (Test-MatchesAny -Value $_.DisplayName -Patterns $SharedExclusions) } |
    Where-Object { $_.DisplayName -notmatch '\d{4}\s*-\s*\d{4}' }
)

# De-duplicate by PRODUCT CODE, never by display name.
#
# Every installed AutoCAD year registers a hidden MSI child called exactly
# "ACAD Private"; a Sort-Object DisplayName -Unique would collapse all of them
# into one arbitrary entry and could route an uninstall at the wrong year.
$seenKeys = @{}
$targets = @($targets | Where-Object {
    if ($seenKeys.ContainsKey($_.KeyName)) { return $false }
    $seenKeys[$_.KeyName] = $true
    return $true
})

# --- Removal order --------------------------------------------------------
# AutoCAD's family has real dependencies, so order is explicit rather than
# alphabetical:
#   1 update bundles   - patches ON the base; removing them first returns the
#                        base to the state its own uninstaller expects and
#                        leaves no orphaned ARP entry behind
#   2 add-ins / extras - depend on the base; remove while the base still exists
#                        so their uninstall custom actions can still resolve it
#   3 ODIS bundle      - the orchestrator for the core product
#   4 MSI children     - normally already removed by step 3, so these usually
#                        report 1605 ("not installed"), which counts as success
function Get-RemovalRank {
    param($Product)

    $isMsi  = ($Product.WindowsInstaller -eq 1)
    $name   = $Product.DisplayName
    $parent = [string]$Product.ParentKeyName

    if ($name -match '(?i)\b(update|hotfix|service pack)\b' -or
        -not [string]::IsNullOrWhiteSpace($parent)) { return 1 }

    if ($isMsi) { return 4 }

    if (Test-MatchesAny -Value $name -Patterns $CorePatterns) { return 3 }

    return 2
}

$targets = @($targets |
    Select-Object *, @{ Name = 'Rank'; Expression = { Get-RemovalRank -Product $_ } } |
    Sort-Object Rank, DisplayName)

if ($targets.Count -eq 0) {
    Write-Log "No Autodesk AutoCAD $ProductYear products found in the uninstall registry." 'WARN'
    if ($all.Count -gt 0) {
        Write-Log 'Autodesk/AutoCAD entries present on this machine (for reference):'
        $all | Sort-Object DisplayName -Unique | ForEach-Object { Write-Log "    - $($_.DisplayName)" }
    }
    try { Stop-Transcript | Out-Null } catch { }
    exit 2
}

Write-Log "Matched $($targets.Count) product(s) for removal, in this order:" 'OK'
$targets | ForEach-Object {
    $tag = switch ($_.Rank) { 1 { 'update ' } 2 { 'add-in ' } 3 { 'core   ' } default { 'msi    ' } }
    $hid = if ($_.SystemComponent -eq 1) { '  (hidden from Add/Remove Programs)' } else { '' }
    Write-Log ("    {0}{1}  [{2}]  {3}{4}" -f $tag, $_.DisplayName, $_.DisplayVersion, $_.KeyName, $hid)
}

# The per-user entries in $ResidualPaths come from the ELEVATED process's
# environment. When self-elevation crossed accounts (UAC asked for admin
# CREDENTIALS rather than consent, i.e. the signed-in user is not a local admin -
# standard corporate configuration, and how a technician runs this on someone
# else's machine), %APPDATA% is the ADMINISTRATOR's profile and the real user's
# AutoCAD profiles, toolbars and plotter settings are never reached. Report it
# rather than silently cleaning the wrong profile and calling the run a success.
$invokingUser = $null
try { $invokingUser = (Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).UserName } catch { }
if ($invokingUser) {
    $shortName = ($invokingUser -split '\\')[-1]
    if ($shortName -and $env:USERNAME -and $shortName -ne $env:USERNAME) {
        Write-Log "Elevated as '$env:USERNAME' but the signed-in user is '$shortName'. Per-user residual folders under %APPDATA%/%LOCALAPPDATA% will be cleaned for '$env:USERNAME' ONLY - '$shortName' keeps their AutoCAD profile. Re-run from that account to clear it." 'WARN'
    }
}

if ($ListOnly) {
    if ($RemoveResidualFiles) {
        $existing = @($ResidualPaths | Where-Object { $_ -and (Test-Path -LiteralPath $_) })
        if ($existing.Count -gt 0) {
            Write-Log 'Residual folders that would be removed:'
            $existing | ForEach-Object { Write-Log "    - $_" }
        }
        else {
            Write-Log "No AutoCAD $ProductYear residual folders found."
        }
    }
    if ($RemoveResidualRegistry) {
        if ($release) {
            foreach ($h in 'HKCU', 'HKLM') {
                $k = "${h}:\SOFTWARE\Autodesk\AutoCAD\$($release.Release)"
                if (Test-Path -LiteralPath $k) { Write-Log "Residual registry key that would be removed: $k" }
            }
        }
        else {
            Write-Log 'Residual registry cleanup requested but the release could not be resolved - it would be skipped.' 'WARN'
        }
    }
    Write-Log 'ListOnly specified - no changes made.' 'OK'
    try { Stop-Transcript | Out-Null } catch { }
    exit 0
}

# --- Running-process guard ------------------------------------------------
# Scoped to the TARGET YEAR by executable path. Several AutoCAD years coexist
# routinely on one machine, so a blanket "kill every acad.exe" would close a
# drawing the user has open in a version this run is not touching.
# Discovery is PATH-FIRST, name-second. Any process running from under the
# resolved install root belongs to this year's AutoCAD whatever it is called -
# which covers the binaries a fixed list always misses (AcBlockIndexPipeline,
# Das.Local, the CER helper, and whatever a future release adds) and needs no
# maintenance. $AcadProcessNames then adds the known hosts that can live
# OUTSIDE the install root.
function Get-AutoCadProcesses {
    param([string[]]$Roots)

    $wanted = @($AcadProcessNames | ForEach-Object { $_.ToLowerInvariant() })
    $rows = @()

    # Win32_Process is preferred because the script always runs ELEVATED by this
    # point, and elevation is exactly what makes ExecutablePath readable for
    # processes in other sessions. (Get-Process .Path does not throw for an
    # inaccessible process - it yields $null - so the fallback below is about
    # missing PATHS, not about exceptions.)
    $cim = $null
    try { $cim = @(Get-CimInstance -ClassName Win32_Process -ErrorAction Stop) } catch { $cim = $null }

    if ($null -ne $cim) {
        foreach ($p in $cim) {
            $base = [IO.Path]::GetFileNameWithoutExtension([string]$p.Name)
            $path = [string]$p.ExecutablePath
            $byPath = Test-PathUnderAny -Path $path -Roots $Roots
            $byName = $wanted -contains $base.ToLowerInvariant()
            if (-not ($byPath -or $byName)) { continue }
            $rows += [pscustomobject]@{
                Name = $base
                Id   = [int]$p.ProcessId
                Path = $path
            }
        }
        return $rows
    }

    # Fallback: Get-Process, which can only be queried by name, so the
    # path-first sweep is unavailable here. Reading .Path is still wrapped:
    # it returns $null when the path cannot be resolved, and the wrapper keeps
    # any future provider exception from aborting an $ErrorActionPreference
    # = 'Stop' run.
    Write-Log 'Win32_Process query failed; falling back to Get-Process (name-only; processes outside the known name list will not be seen).' 'WARN'
    foreach ($n in $AcadProcessNames) {
        foreach ($p in @(Get-Process -Name $n -ErrorAction SilentlyContinue)) {
            $path = $null
            try { $path = $p.Path } catch { $path = $null }
            $rows += [pscustomobject]@{ Name = $p.Name; Id = $p.Id; Path = [string]$path }
        }
    }
    return $rows
}

$acadProcs   = @(Get-AutoCadProcesses -Roots $AcadRoots)
$inScope     = @($acadProcs | Where-Object { Test-PathUnderAny -Path $_.Path -Roots $AcadRoots })
$unattributed = @($acadProcs | Where-Object {
    [string]::IsNullOrWhiteSpace($_.Path) -and
    -not (Test-PathUnderAny -Path $_.Path -Roots $AcadRoots)
})
$otherYears  = @($acadProcs | Where-Object {
    -not [string]::IsNullOrWhiteSpace($_.Path) -and
    -not (Test-PathUnderAny -Path $_.Path -Roots $AcadRoots)
})

foreach ($p in $otherYears) {
    Write-Log ("Leaving running process alone (not AutoCAD $ProductYear): {0} (pid {1}) {2}" -f $p.Name, $p.Id, $p.Path)
}
foreach ($p in $unattributed) {
    Write-Log ("Running process '{0}' (pid {1}) has no resolvable path - NOT terminated, cannot prove it belongs to AutoCAD $ProductYear. It may lock files during uninstall." -f $p.Name, $p.Id) 'WARN'
}

if ($inScope.Count -gt 0) {
    if ($StopAutoCAD) {
        Write-Log "Terminating $($inScope.Count) AutoCAD $ProductYear process(es). Unsaved drawings in them will be lost." 'WARN'
        foreach ($p in $inScope) {
            Write-Log ("    stopping {0} (pid {1})" -f $p.Name, $p.Id) 'WARN'
            Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
        }
        Start-Sleep -Seconds 3
    }
    else {
        Write-Log "AutoCAD $ProductYear is running:" 'ERROR'
        foreach ($p in $inScope) {
            Write-Log ("    {0} (pid {1}) {2}" -f $p.Name, $p.Id, $p.Path) 'ERROR'
        }
        Write-Log 'Save your work and close it, or re-run with -StopAutoCAD. Aborting.' 'ERROR'
        try { Stop-Transcript | Out-Null } catch { }
        exit 1
    }
}

# --- Uninstall command resolution -----------------------------------------
# Split a registry command line into executable + argument string WITHOUT
# routing through cmd.exe. cmd mangles an unquoted, space-containing path such
# as  C:\Program Files\Autodesk\AdODIS\V1\Installer.exe  (it reads the exe as
# "C:\Program"), which is exactly what produces a generic "exit 1" on
# Autodesk's ODIS uninstaller. Start-Process quotes -FilePath correctly.
function Split-Command {
    param([string]$CommandLine)
    $cl = $CommandLine.Trim()

    # Quoted executable: take whatever is between the first pair of quotes.
    if ($cl.StartsWith('"')) {
        $end = $cl.IndexOf('"', 1)
        if ($end -lt 1) { return [pscustomobject]@{ File = $cl.Trim('"'); Args = '' } }
        return [pscustomobject]@{
            File = $cl.Substring(1, $end - 1)
            Args = $cl.Substring($end + 1).Trim()
        }
    }

    # Unquoted: split on the first '.exe' token so spaced paths survive intact.
    $m = [regex]::Match($cl, '(?i)^(.*?\.exe)(?:\s+(.*))?$')
    if ($m.Success) {
        return [pscustomobject]@{
            File = $m.Groups[1].Value.Trim()
            Args = $m.Groups[2].Value.Trim()
        }
    }

    # Last resort: split on the first space.
    $sp = $cl.IndexOf(' ')
    if ($sp -lt 0) { return [pscustomobject]@{ File = $cl; Args = '' } }
    return [pscustomobject]@{ File = $cl.Substring(0, $sp); Args = $cl.Substring($sp + 1).Trim() }
}

# Resolves the locally CACHED .msi for a given ProductCode via the Windows
# Installer COM API (MSI "LocalPackage" property). Uninstalling from this
# literal file path bypasses SourceList/network-source resolution entirely -
# the fix for "Error 1606: Could not access network location <share>\" during
# /x, which the caller otherwise only sees wrapped as a generic exit 1603
# (visible instead in the per-product MSI*.LOG next to %TEMP%).
function Get-MsiLocalPackage {
    param([string]$ProductCode)
    # Pre-initialize: if New-Object throws, the finally block would otherwise
    # reference an undefined variable and itself throw under StrictMode Latest.
    $installer = $null
    try {
        $installer = New-Object -ComObject WindowsInstaller.Installer
        # INSTALLPROPERTY_LOCALPACKAGE = "LocalPackage"
        $local = $installer.ProductInfo($ProductCode, 'LocalPackage')
        if (-not [string]::IsNullOrWhiteSpace($local) -and (Test-Path -LiteralPath $local)) {
            return $local
        }
    }
    catch {
        Write-Log "LocalPackage lookup failed for $ProductCode`: $($_.Exception.Message)" 'WARN'
    }
    finally {
        if ($installer) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($installer) }
    }
    return $null
}

# Squished (registry-form) GUID for a ProductCode, e.g.
# {28B89EEF-9101-0409-2102-CF3F3A09B77D} -> FEE98B82...  (block-reversed hex,
# no braces/dashes). Windows Installer keys its UserData/Installer\Products
# registrations under this form, not the plain ProductCode.
function Get-MsiSquishedGuid {
    param([string]$ProductCode)
    if ($ProductCode -notmatch '^\{([0-9a-fA-F\-]{36})\}$') { return $null }
    $raw = $Matches[1] -replace '-'
    $parts = @(
        $raw.Substring(0,8), $raw.Substring(8,4), $raw.Substring(12,4),
        $raw.Substring(16,2), $raw.Substring(18,2), $raw.Substring(20,2),
        $raw.Substring(22,2), $raw.Substring(24,2), $raw.Substring(26,2),
        $raw.Substring(28,2), $raw.Substring(30,2)
    )
    return ($parts | ForEach-Object { $c = $_.ToCharArray(); [array]::Reverse($c); -join $c }) -join ''
}

# Diagnostic-only: dump every SourceList value that could be feeding a 1606
# concatenation, so the log shows the ACTUAL bad entry instead of just the
# symptom. Runs BEFORE the purge below so the two can be compared.
function Show-MsiSourceListDump {
    param([string]$ProductCode)
    $squished = Get-MsiSquishedGuid -ProductCode $ProductCode
    if (-not $squished) { return }
    $roots = @(
        "HKLM:\SOFTWARE\Classes\Installer\Products\$squished\SourceList",
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData\S-1-5-18\Products\$squished\SourceList"
    )
    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        Write-Log "SourceList dump: $root" 'WARN'
        try {
            $props = Get-ItemProperty -LiteralPath $root -ErrorAction SilentlyContinue
            foreach ($n in @('PackageName','LastUsedSource')) {
                $v = Get-Prop $props $n
                if ($v) { Write-Log "    $n = $v" 'WARN' }
            }
        } catch { }
        foreach ($sub in 'Net','URL','Media') {
            $subPath = Join-Path $root $sub
            if (-not (Test-Path -LiteralPath $subPath)) { continue }
            try {
                $sp = Get-ItemProperty -LiteralPath $subPath -ErrorAction SilentlyContinue
                $sp.PSObject.Properties |
                    Where-Object { $_.Name -notmatch '^PS' } |
                    ForEach-Object { Write-Log "    $sub\$($_.Name) = $($_.Value)" 'WARN' }
            } catch { }
        }
    }
}

# Purge and rewrite the product's SourceList registry entries so msiexec has
# nothing dangling left to concatenate against. This is the standard,
# Microsoft-documented remediation for a stale/relative SourceList entry
# (post-migration, moved/deleted deployment shares) - registry-level, not COM,
# so it cannot silently no-op the way SourceListClearAll's late-bound
# InvokeMember call can. Also rewrites PackageName to the LOCAL cached .msi
# basename (when known) so any later PackageName+LastUsedSource concatenation
# resolves to a real local file.
function Clear-MsiSourceListRegistry {
    param([string]$ProductCode, [string]$LocalPackagePath)
    $squished = Get-MsiSquishedGuid -ProductCode $ProductCode
    if (-not $squished) { return }
    $roots = @(
        "HKLM:\SOFTWARE\Classes\Installer\Products\$squished\SourceList",
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData\S-1-5-18\Products\$squished\SourceList"
    )
    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        foreach ($sub in 'Net','URL') {
            $subPath = Join-Path $root $sub
            if (Test-Path -LiteralPath $subPath) {
                try {
                    Remove-Item -LiteralPath $subPath -Recurse -Force -ErrorAction Stop
                    Write-Log "Removed stale $sub entries under $root" 'OK'
                } catch {
                    Write-Log "Could not remove $subPath : $($_.Exception.Message)" 'WARN'
                }
            }
        }
        try {
            if (Get-ItemProperty -LiteralPath $root -Name 'LastUsedSource' -ErrorAction SilentlyContinue) {
                Remove-ItemProperty -LiteralPath $root -Name 'LastUsedSource' -ErrorAction SilentlyContinue
                Write-Log "Cleared LastUsedSource under $root" 'OK'
            }
        } catch { }
        if ($LocalPackagePath -and (Test-Path -LiteralPath $LocalPackagePath)) {
            try {
                Set-ItemProperty -LiteralPath $root -Name 'PackageName' `
                    -Value (Split-Path -Leaf $LocalPackagePath) -ErrorAction Stop
                Write-Log "Rewrote PackageName -> $(Split-Path -Leaf $LocalPackagePath) under $root" 'OK'
            } catch {
                Write-Log "Could not rewrite PackageName under $root : $($_.Exception.Message)" 'WARN'
            }
        }
    }
}

# Repairs a missing/relative InstallLocation in the Windows Installer UserData
# cache, which can feed a 1606 during maintenance.
function Repair-MsiUserDataCache {
    param([string]$ProductCode, [string]$InstallRoot)
    $squished = Get-MsiSquishedGuid -ProductCode $ProductCode
    if (-not $squished) { return }
    if ([string]::IsNullOrWhiteSpace($InstallRoot)) { return }

    $msiHive = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData\S-1-5-18\Products\$squished\InstallProperties"

    if (Test-Path -LiteralPath $msiHive) {
        try {
            $il = Get-ItemProperty -Path $msiHive -Name 'InstallLocation' -ErrorAction SilentlyContinue
            if ($null -eq $il -or [string]::IsNullOrWhiteSpace($il.InstallLocation) -or $il.InstallLocation -notmatch '^([a-zA-Z]:[\\/]|\\\\)') {
                $fixPath = $InstallRoot.TrimEnd('\') + '\'
                Set-ItemProperty -LiteralPath $msiHive -Name 'InstallLocation' -Value $fixPath -ErrorAction Stop
                Write-Log "Patched internal MSI cache location to bypass Error 1606:`n      New: $fixPath" 'WARN'
            }
        } catch {
            Write-Log "Failed patching native cache InstallLocation: $($_.Exception.Message)" 'WARN'
        }
    }
}

# Surgical Error-2753 remediation. "Internal Error 2753. <key>" means a custom
# action sourced from an INSTALLED FILE (CustomAction base type 17/18/21/22)
# whose component registration is damaged - Windows Installer cannot resolve
# the file, and the whole uninstall aborts even though every other action would
# succeed. The cached package in C:\Windows\Installer CANNOT be edited in
# place: current Windows builds ACL it against writes even from an elevated
# admin (observed: transacted OpenDatabase fails on build 26200). So this copies
# the cached .msi to %TEMP%, sets the named action's InstallExecuteSequence
# Condition to '0' (= never run) in the COPY, and returns the patched copy's
# path - the caller recaches and retries from it. Path-based maintenance is
# accepted because the PackageCode is unchanged, and the rest of the uninstall
# runs normally with full component cleanup and rollback, unlike the Microsoft
# troubleshooter's force-removal, which just rips the registration. On repeat
# calls pass -PatchedMsi so later neutralizations accumulate in the SAME copy.
#
# The AutoCAD core package carries the same file-sourced custom action family
# that produced this on Revit (type 3217,
# _560A25DD.D5955B9C_A4DD_4C11_97BD_AB88FAFFCD9E), so this is directly relevant
# here and not merely inherited.
#
# Returns the patched copy's path, or $null if there was nothing to do.
function Repair-MsiBrokenCustomAction {
    param([string]$ProductCode, [string]$VerboseLog, [string]$PatchedMsi)

    if ([string]::IsNullOrWhiteSpace($VerboseLog) -or -not (Test-Path -LiteralPath $VerboseLog)) { return $null }
    if (-not (Select-String -Path $VerboseLog -Pattern 'Error 2753' -Quiet)) { return $null }

    # The action that aborted: first non-INSTALL "Return value 3" line.
    $fail = Select-String -Path $VerboseLog -Pattern 'Action ended .*?: (.+)\. Return value 3\.' |
        Where-Object { $_.Matches[0].Groups[1].Value -ne 'INSTALL' } |
        Select-Object -First 1
    if (-not $fail) { return $null }
    $action = $fail.Matches[0].Groups[1].Value
    if ($action -match "'") { return $null }   # never build WI-SQL from an apostrophed name

    if (-not [string]::IsNullOrWhiteSpace($PatchedMsi) -and (Test-Path -LiteralPath $PatchedMsi)) {
        # Accumulate into the existing patched copy.
        $target = $PatchedMsi
    }
    else {
        $localMsi = Get-MsiLocalPackage -ProductCode $ProductCode
        if (-not $localMsi) {
            Write-Log "2753 on '$action' but no cached package found for $ProductCode - cannot neutralize." 'WARN'
            return $null
        }
        $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
        # The patched copy MUST keep the registered package's exact file name:
        # during the /fv repair, source resolution probes
        # SOURCEDIR + <registered PackageName> and fails 2203/1316 ('Error
        # determining package source type') when the copy is renamed.
        # A per-run subfolder keeps the name without colliding in %TEMP%.
        $patchDir = Join-Path $env:TEMP ('AutoCadCleanerPatch_' + $stamp)
        $target   = Join-Path $patchDir ([IO.Path]::GetFileName($localMsi))
        # Pristine snapshot of the registered cached package: the recache step
        # (/fv) REPLACES the cache with the patched copy, so keep an unmodified
        # original for manual rollback.
        $pristine = Join-Path $env:TEMP ('{0}_pristine_{1}.msi' -f `
            [IO.Path]::GetFileNameWithoutExtension($localMsi), $stamp)
        try {
            if (-not (Test-Path -LiteralPath $patchDir)) {
                $null = New-Item -ItemType Directory -Path $patchDir -Force -ErrorAction Stop
            }
            Copy-Item -LiteralPath $localMsi -Destination $pristine -Force -ErrorAction Stop
            Copy-Item -LiteralPath $localMsi -Destination $target -Force -ErrorAction Stop
            Write-Log "Pristine cached-package backup: $pristine" 'INFO'
        }
        catch {
            Write-Log "Cannot copy cached package to %TEMP% ($($_.Exception.Message)) - cannot neutralize." 'ERROR'
            return $null
        }
    }

    $installer = $null; $db = $null; $view1 = $null; $view2 = $null; $rec = $null
    try {
        $installer = New-Object -ComObject WindowsInstaller.Installer
        # 1 = msiOpenDatabaseModeTransact. DIRECT dispatch: reflection
        # InvokeMember on Installer.OpenDatabase throws DISP_E_TYPEMISMATCH on
        # this PS 5.1 host (observed live: direct $installer.OpenDatabase()
        # succeeds where InvokeMember fails on the identical arguments), so
        # try direct first and keep InvokeMember only as a fallback.
        $db = $null
        try { $db = $installer.OpenDatabase($target, 1) } catch { }
        if ($null -eq $db) {
            $db = $installer.GetType().InvokeMember('OpenDatabase', 'InvokeMethod', $null, $installer, @($target, 1))
        }
        # EVERY void COM call below is [void]-cast: direct-dispatch void
        # methods emit $null into the function's OUTPUT STREAM in PS 5.1, so
        # without the casts this function returns an ARRAY (nulls + path).
        # String-interpolating that array space-joins it, msiexec receives
        # /x "    C:\...patched.msi", resolves it as RELATIVE (CWD prepended,
        # note 2203) and fails 1619. Never return bare COM call results from an
        # advanced function.
        $view1 = $db.OpenView("SELECT ``Action`` FROM ``InstallExecuteSequence`` WHERE ``Action`` = '$action'")
        [void]$view1.Execute()
        $rec = $view1.Fetch()
        if ($null -eq $rec) {
            Write-Log "Action '$action' not present in InstallExecuteSequence - cannot neutralize." 'WARN'
            return $null
        }
        [void]$view1.Close()
        $view2 = $db.OpenView("UPDATE ``InstallExecuteSequence`` SET ``Condition`` = '0' WHERE ``Action`` = '$action'")
        [void]$view2.Execute()
        [void]$view2.Close()
        [void]$db.Commit()
        Write-Log "Neutralized broken custom action '$action' (Error 2753) in patched copy: $target" 'OK'
        return $target
    }
    catch {
        Write-Log "Failed to neutralize '$action' in ${target}: $($_.Exception.Message)" 'ERROR'
        return $null
    }
    finally {
        # Release EVERY wrapper - including the SELECT view and its fetched
        # Record - then force a GC. Any un-finalized RCW keeps the .msi handle
        # open in THIS process, and the immediately-following msiexec then
        # fails 1619 (note 2203 / 0x80030020 STG_E_SHAREVIOLATION). Verified
        # live: exclusive reopen fails before this block's GC, succeeds after.
        foreach ($o in @($rec, $view1, $view2, $db, $installer)) {
            if ($null -ne $o) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($o) }
        }
        [GC]::Collect(); [GC]::WaitForPendingFinalizers(); [GC]::Collect()
    }
}

# Clears a stale SourceList (a trigger for the 1606 network-location error) so
# any LATER msiexec call against the bare ProductCode no longer tries to reach
# the dead network share. Best-effort; failure here never blocks the uninstall.
function Clear-MsiSourceList {
    param([string]$ProductCode)
    # Pre-initialize for the finally block - see Get-MsiLocalPackage.
    $installer = $null
    try {
        $installer = New-Object -ComObject WindowsInstaller.Installer
        # MsiSourceListClearAllEx via the Installer.SourceListClearAll method
        # (context 7 = MSIINSTALLCONTEXT_ALL, options 4 = MSICODE_PRODUCT).
        $installer.GetType().InvokeMember(
            'SourceListClearAll', 'InvokeMethod', $null, $installer,
            @($ProductCode, '', 7)) | Out-Null
        Write-Log "Cleared stale SourceList for $ProductCode" 'INFO'
    }
    catch {
        # Non-fatal - not every Windows Installer version exposes this verb,
        # and late-bound automation calls can fail to marshal silently.
        # Clear-MsiSourceListRegistry (called separately, unconditionally,
        # below) is the guaranteed path and does not depend on this succeeding.
    }
    finally {
        if ($installer) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($installer) }
    }
}

# Build an ordered list of uninstall attempts. If one method fails the caller
# falls through to the next.
function Get-UninstallCandidates {
    param($Product)
    $list = @()

    # 1) MSI, preferring the LOCALLY CACHED .msi over the bare product code.
    #    Uninstalling by ProductCode makes Windows Installer re-validate the
    #    ORIGINAL install source (SourceList) before it will proceed; if that
    #    was a network share that's now gone, MSI aborts with
    #    "Error 1606: Could not access network location ...", surfaced to the
    #    caller only as a generic exit 1603. Uninstalling from the cached
    #    LocalPackage path skips that source-resolution step entirely.
    #
    #    This branch is the ONLY route for the two hidden AutoCAD MSI children
    #    ("AutoCAD <year> - <lang>" and "ACAD Private"): both register with an
    #    EMPTY UninstallString and an EMPTY QuietUninstallString, so branches
    #    2 and 3 below produce nothing at all for them.
    if ($Product.WindowsInstaller -eq 1 -and $Product.KeyName -match '^\{[0-9A-Fa-f\-]{36}\}$') {

        # LAST-RESORT ONLY property override - do NOT inject this into the
        # primary attempts. Forcing INSTALLDIR/ROOTDRIVE on an uninstall of an
        # already-registered product can change a component/directory
        # CONDITION evaluation from what it was at install time, knocking a
        # component (and any File its CustomAction/Binary table references)
        # out of the action sequence - which is precisely what
        # "Error 2753: The File '[2]' is not marked for installation" means.
        # See the $FallbackDirProps comment in the configuration section.
        $fallBackProps = $FallbackDirProps

        # Verbose MSI log (separate from the terse system-default MSI*.LOG in
        # %TEMP%) - the terse log gives us the error CODE only; this gives us
        # the actual Action/Component/File sequence around the failure, which
        # is what we need to diagnose 2753 with certainty instead of guessing.
        # One verbose log PER ATTEMPT: /L*V truncates on open, so a shared
        # filename means the second attempt silently overwrites the first
        # attempt's evidence.
        $vlogBase = Join-Path $env:TEMP ("MSIVerbose_{0}_{1}" -f `
            ($Product.KeyName -replace '[{}]',''), (Get-Date -Format 'yyyyMMdd_HHmmss'))
        $vlogMsiLocalPath = $vlogBase + '_LocalPackage.log'
        $vlogMsiPath      = $vlogBase + '_MSI.log'
        $vlogMsiPropsPath = $vlogBase + '_PropsOverride.log'
        $vlogMsiLocal = ' /L*V "' + $vlogMsiLocalPath + '"'
        $vlogMsi      = ' /L*V "' + $vlogMsiPath + '"'
        $vlogMsiProps = ' /L*V "' + $vlogMsiPropsPath + '"'

        $localMsi = Get-MsiLocalPackage -ProductCode $Product.KeyName

        # UNCONDITIONAL - the 1606 concatenation happens off the ProductCode's
        # registered SourceList regardless of whether /x targets the bare
        # ProductCode or the LocalPackage file path, so this must run before
        # EVERY attempt, not only when LocalPackage lookup fails.
        Show-MsiSourceListDump -ProductCode $Product.KeyName
        Clear-MsiSourceList -ProductCode $Product.KeyName
        Clear-MsiSourceListRegistry -ProductCode $Product.KeyName -LocalPackagePath $localMsi

        if ($localMsi) {
            $list += [pscustomobject]@{ File = 'msiexec.exe'; Args = "/x `"$localMsi`" /qn /norestart$vlogMsiLocal"; Kind = 'MSI-LocalPackage'; Vlog = $vlogMsiLocalPath }
        }

        $list += [pscustomobject]@{ File = 'msiexec.exe'; Args = "/x $($Product.KeyName) /qn /norestart$vlogMsi"; Kind = 'MSI'; Vlog = $vlogMsiPath }
        # Property-override attempt, LAST - see comment above.
        $list += [pscustomobject]@{ File = 'msiexec.exe'; Args = "/x $($Product.KeyName) /qn /norestart$fallBackProps$vlogMsiProps"; Kind = 'MSI-PropsOverride'; Vlog = $vlogMsiPropsPath }
    }

    # 2) Vendor-provided silent command.
    if (-not [string]::IsNullOrWhiteSpace($Product.QuietUninstallString)) {
        $s = Split-Command $Product.QuietUninstallString
        $list += [pscustomobject]@{ File = $s.File; Args = $s.Args; Kind = 'Quiet'; Vlog = $null }
    }

    # 3) Raw UninstallString. For msiexec, coerce /I->/X and add silent flags.
    #    For an EXE uninstaller (the Autodesk ODIS Installer.exe that owns every
    #    "Autodesk AutoCAD <year>" bundle and update), try a silent variant
    #    first, then the exact vendor string as a guaranteed fallback so a wrong
    #    silent flag can never block the uninstall.
    if (-not [string]::IsNullOrWhiteSpace($Product.UninstallString)) {
        $raw = $Product.UninstallString
        if ($raw -match '(?i)msiexec') {
            $raw = $raw -replace '(?i)/I(\{[0-9A-Fa-f\-]{36}\})', '/X$1'
            if ($raw -notmatch '(?i)/qn|/quiet') { $raw = "$raw /qn" }
            if ($raw -notmatch '(?i)/norestart') { $raw = "$raw /norestart" }
            $s = Split-Command $raw
            $list += [pscustomobject]@{ File = $s.File; Args = $s.Args; Kind = 'Fallback'; Vlog = $null }
        }
        else {
            $s = Split-Command $raw
            if ($s.Args -notmatch '(?i)(^|\s)(--silent|-silent|/silent|-q|/q)(\s|$)') {
                $list += [pscustomobject]@{ File = $s.File; Args = ($s.Args + ' --silent').Trim(); Kind = 'Silent'; Vlog = $null }
            }
            $list += [pscustomobject]@{ File = $s.File; Args = $s.Args; Kind = 'Fallback'; Vlog = $null }
        }
    }

    # De-duplicate, collapsing msiexec variants that target the same GUID
    # (e.g. "msiexec.exe /x {g}" and "MsiExec.exe /X{g}") into a single attempt.
    $seen = @{}
    $unique = @()
    foreach ($c in $list) {
        $norm = ('{0} {1}' -f $c.File, $c.Args).ToLowerInvariant()
        $guid = [regex]::Match($norm, '\{[0-9a-f\-]{36}\}')
        # GUID-collapse ONLY plain "/x {guid}" invocations. A candidate that
        # carries PROPERTY=value overrides is functionally different: keying it
        # by GUID alone silently deletes MSI-PropsOverride from the attempt
        # list, so the workaround never fires.
        if ($norm -match 'msiexec' -and $guid.Success -and $norm -notmatch '\s\w+=') { $key = 'msi:' + $guid.Value }
        else { $key = $norm }
        if (-not $seen.ContainsKey($key)) { $seen[$key] = $true; $unique += $c }
    }
    # NOTE: plain 'return $unique' (NOT ',$unique'). The unary-comma wrapper
    # double-nests the array so the caller's foreach iterates once over the
    # whole array, collapsing all candidates into one object with array-valued
    # properties -> Start-Process gets an array for -FilePath and throws.
    return $unique
}

# --- Execution ------------------------------------------------------------
$successCodes = @(0, 1605, 3010)   # 1605 = "not installed" (already gone) -> treat as non-fatal
$rebootNeeded = $false
$failures     = 0
# Declines are tracked separately from failures. A product the operator skipped
# is still INSTALLED, so residual cleanup must not run against it - but it is
# not a failure either, and conflating the two would report exit 3 for a
# deliberate choice.
$skipped      = 0

foreach ($product in $targets) {

    # The ODIS bundle wrapper removes its own MSI children, so by the time the
    # rank-4 entries are reached their registrations are usually gone. Re-check
    # rather than firing msiexec at a product code that no longer exists.
    if (-not (Test-Path -LiteralPath $product.RegistryPath)) {
        Write-Log "Already removed by an earlier step: $($product.DisplayName)" 'OK'
        continue
    }

    # Gated on $WhatIfPreference as well as -Force, matching the two residual
    # prompts further down. Under -WhatIf the run has already announced that
    # nothing will be removed, and prompting there both makes a preview
    # interactive and lets a "No" - the natural answer to a question asked
    # during a preview - silently drop the product from the preview it was
    # supposed to be showing.
    if (-not $Force -and -not $WhatIfPreference) {
        $answer = Read-Host "Uninstall '$($product.DisplayName)'? [Y/N]"
        if ($answer -notmatch '^(y|yes)$') {
            Write-Log "Skipped by user: $($product.DisplayName)" 'WARN'
            $skipped++
            continue
        }
    }

    if (-not $PSCmdlet.ShouldProcess($product.DisplayName, 'Uninstall')) {
        # A real decline ("No"/"No to All" at the ConfirmImpact=High prompt), not
        # a -WhatIf preview: the product stays installed and must suppress
        # residual cleanup, which would otherwise delete the files out from under
        # a still-registered AutoCAD.
        if (-not $WhatIfPreference) { $skipped++ }
        continue
    }

    # Consent first, registry surgery second. Repair-MsiUserDataCache and the
    # SourceList dump/purge inside Get-UninstallCandidates all WRITE to the
    # machine; running them before Read-Host/ShouldProcess would mutate state
    # even when the answer was No or the run was -WhatIf.
    if ($product.WindowsInstaller -eq 1) {
        $repairRoot = $product.InstallLocation
        if ([string]::IsNullOrWhiteSpace($repairRoot)) { $repairRoot = $AcadRoots[0] }
        Repair-MsiUserDataCache -ProductCode $product.KeyName -InstallRoot $repairRoot
    }

    $candidates = @(Get-UninstallCandidates -Product $product)
    if ($candidates.Count -eq 0) {
        Write-Log "No usable uninstall command for '$($product.DisplayName)'. Skipping." 'ERROR'
        $failures++
        continue
    }

    $removed  = $false
    $lastCode = $null
    foreach ($cmd in $candidates) {
        # Bounded retry loop per method: a 1603 whose verbose log shows
        # Internal Error 2753 gets the broken custom action neutralized in a
        # patched %TEMP% copy of the cached package, and the uninstall is
        # retried FROM that copy. Each attempt can only surface one broken
        # file-sourced action at a time, hence the loop; 5 is far above
        # anything seen in practice.
        $caRepairs  = 0
        $patchedMsi = $null
        while ($true) {
            Write-Log "Uninstalling '$($product.DisplayName)' via $($cmd.Kind): $($cmd.File) $($cmd.Args)"
            try {
                if ([string]::IsNullOrWhiteSpace($cmd.Args)) {
                    $proc = Start-Process -FilePath $cmd.File -Wait -PassThru -WindowStyle Hidden
                }
                else {
                    $proc = Start-Process -FilePath $cmd.File -ArgumentList $cmd.Args -Wait -PassThru -WindowStyle Hidden
                }
                $lastCode = $proc.ExitCode
                if ($successCodes -contains $lastCode) {
                    if ($lastCode -eq 3010) { $rebootNeeded = $true }
                    Write-Log "Removed '$($product.DisplayName)' (exit $lastCode via $($cmd.Kind))." 'OK'
                    $removed = $true
                    break
                }
                if ($lastCode -eq 1603 -and $NeutralizeBrokenCustomActions -and $caRepairs -lt 5 -and
                    $cmd.Kind -like 'MSI*' -and $cmd.Vlog) {
                    $patch = Repair-MsiBrokenCustomAction -ProductCode $product.KeyName `
                        -VerboseLog $cmd.Vlog -PatchedMsi $patchedMsi
                    # Defense in depth against output-stream pollution: keep
                    # only the last non-empty string (the returned path).
                    $patch = @($patch | Where-Object { $_ -is [string] -and -not [string]::IsNullOrWhiteSpace($_) }) |
                        Select-Object -Last 1
                    if ($patch) {
                        $caRepairs++
                        $patchedMsi = $patch
                        # Maintenance mode IGNORES the package path argument's
                        # tables: "Package we're running from ==>" is always
                        # the REGISTERED cache, so /x "<patched>.msi" never
                        # sees the neutralized condition. The supported route
                        # is a RECACHE repair - msiexec /fv <patched> replaces
                        # the registered cached package with ours (PackageCode
                        # unchanged) - then a normal product-code /x runs from
                        # it. The /fv carries the same directory-property
                        # override because repair costing hits the same
                        # directory custom actions.
                        $recacheVlog = $cmd.Vlog -replace '\.log$', ('_recache{0}.log' -f $caRepairs)
                        $recacheArgs = "/fv `"$patchedMsi`" /qn /norestart$FallbackDirProps" + ' /L*V "' + $recacheVlog + '"'
                        Write-Log "Recaching patched package: msiexec.exe $recacheArgs"
                        $rc = Start-Process -FilePath 'msiexec.exe' -ArgumentList $recacheArgs -Wait -PassThru -WindowStyle Hidden
                        if ($rc.ExitCode -notin 0, 3010) {
                            Write-Log "Recache (/fv) failed with exit $($rc.ExitCode) - cannot apply the 2753 fix. See $recacheVlog" 'ERROR'
                            break
                        }
                        if ($rc.ExitCode -eq 3010) { $rebootNeeded = $true }
                        Write-Log 'Recache OK - registered cache now carries the neutralized action.' 'OK'
                        $retryVlog = $cmd.Vlog -replace '\.log$', ('_recached{0}.log' -f $caRepairs)
                        $cmd = [pscustomobject]@{
                            File = 'msiexec.exe'
                            Args = "/x $($product.KeyName) /qn /norestart$FallbackDirProps" + ' /L*V "' + $retryVlog + '"'
                            Kind = 'MSI-Recached'
                            Vlog = $retryVlog
                        }
                        Write-Log "Retrying by product code from the recached package (repair $caRepairs of 5)." 'WARN'
                        continue
                    }
                }
                Write-Log "Method '$($cmd.Kind)' returned exit $lastCode; trying next method if available." 'WARN'
            }
            catch {
                Write-Log "Method '$($cmd.Kind)' threw: $($_.Exception.Message)" 'WARN'
            }
            break
        }
        if ($removed) { break }
    }

    if (-not $removed) {
        Write-Log "All uninstall methods failed for '$($product.DisplayName)' (last exit $lastCode)." 'ERROR'
        Write-Log "  QuietUninstallString: $($product.QuietUninstallString)"
        Write-Log "  UninstallString:      $($product.UninstallString)"
        $failures++
    }
}

# --- Residual file cleanup ------------------------------------------------
# The deletion guard, kept separate so it can be tested on its own.
#
# Segment-exact, NOT substring. A substring test ("does the path contain
# 'Autodesk' and 'AutoCAD' and the year?") passes for paths it should never
# accept - C:\Backup\Autodesk-AutoCAD-2026-archive is one, and so is anything a
# future caller assembles by string concatenation. The guard is the safety net,
# so it must hold even when the caller is wrong; matching whole path SEGMENTS is
# what makes that true.
#
# Returns $true only when EVERY condition holds.
function Test-SafeResidualPath {
    param([string]$Path, [string]$Year)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }

    # Reject anything that is not rooted and absolute - a relative path would be
    # resolved against the current directory, which is not ours to delete from.
    if ($Path -notmatch '^[a-zA-Z]:\\') {
        Write-Log "Refusing residual path (not an absolute local path): $Path" 'WARN'
        return $false
    }

    $segs = @(($Path -replace '/', '\') -split '\\' | Where-Object { $_ -ne '' })

    # Locate both segments with PowerShell's -eq, which is case-INSENSITIVE and
    # therefore agrees with how Windows compares path components.
    #
    # [array]::IndexOf must NOT be used here: it is case-SENSITIVE, so it
    # disagrees with -contains. That mismatch made the guard reject a perfectly
    # valid lower-cased path (c:\users\...\autodesk\autocad 2026) while its own
    # -contains test had just accepted it.
    $iAutodesk = -1
    $iYear     = -1
    for ($i = 0; $i -lt $segs.Count; $i++) {
        if ($iAutodesk -lt 0 -and $segs[$i] -eq 'Autodesk')        { $iAutodesk = $i }
        if ($iYear     -lt 0 -and $segs[$i] -eq "AutoCAD $Year")   { $iYear     = $i }
    }

    if ($iAutodesk -lt 0) {
        Write-Log "Refusing residual path (no 'Autodesk' path segment): $Path" 'WARN'
        return $false
    }
    if ($iYear -lt 0) {
        Write-Log "Refusing residual path (no 'AutoCAD $Year' path segment): $Path" 'WARN'
        return $false
    }
    # The AutoCAD <year> segment must sit BELOW the Autodesk segment, so a path
    # like C:\AutoCAD 2026\Autodesk\... cannot qualify.
    if ($iYear -lt ($iAutodesk + 1)) {
        Write-Log "Refusing residual path ('AutoCAD $Year' is not below 'Autodesk'): $Path" 'WARN'
        return $false
    }
    # Never a drive root or a two-segment path.
    if ($segs.Count -lt 3) {
        Write-Log "Refusing residual path (too shallow): $Path" 'WARN'
        return $false
    }

    # REPARSE POINTS. %APPDATA% and %LOCALAPPDATA% are exactly the roots that
    # OneDrive Known Folder Move and enterprise folder redirection turn into
    # junctions. Remove-Item -Recurse -Force across a junction can delete the
    # TARGET's contents - i.e. redirected user data outside the Autodesk tree
    # entirely. Refuse rather than follow.
    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            Write-Log "Refusing residual path (it is a junction/symlink; deleting through it could destroy the target): $Path" 'WARN'
            return $false
        }
    }
    catch {
        Write-Log "Refusing residual path (cannot inspect it): $Path - $($_.Exception.Message)" 'WARN'
        return $false
    }

    return $true
}

function Remove-ResidualFiles {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([string[]]$Paths)

    $removed = 0
    foreach ($path in $Paths) {
        if ([string]::IsNullOrWhiteSpace($path)) { continue }
        if (-not (Test-Path -LiteralPath $path)) { continue }

        if (-not (Test-SafeResidualPath -Path $path -Year $ProductYear)) { continue }

        if (-not $Force -and -not $WhatIfPreference) {
            $answer = Read-Host "Delete residual folder '$path'? [Y/N]"
            if ($answer -notmatch '^(y|yes)$') {
                Write-Log "Kept residual folder: $path" 'WARN'
                continue
            }
        }

        if ($PSCmdlet.ShouldProcess($path, 'Remove residual folder')) {
            try {
                Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop
                Write-Log "Deleted residual folder: $path" 'OK'
                $removed++
            }
            catch {
                Write-Log "Failed to delete '$path': $($_.Exception.Message)" 'ERROR'
            }
        }
    }
    return $removed
}

# --- Residual registry cleanup --------------------------------------------
# Opt-in (-RemoveResidualRegistry) and the highest-risk operation in the
# script, because HKCU/HKLM:\SOFTWARE\Autodesk\AutoCAD\R<release> carries the
# RELEASE and no year at all: deleting the wrong one wipes a different AutoCAD
# version's profiles, toolbars and plotter settings.
#
# Preconditions, all required:
#   - the release was RESOLVED from the registry for this exact year
#     (never computed - see Resolve-AcadRelease)
#   - the key path matches ...\Autodesk\AutoCAD\R<n>.<n> exactly
#   - no product key under that release still claims a DIFFERENT year
function Remove-ResidualRegistryKeys {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([string]$Release, [string]$Year, [bool]$CoTenantsPresent)

    $removed = 0

    # The pre-flight census is the ONLY reliable co-tenant signal at this point.
    #
    # The post-uninstall re-census below reads HKLM ...\AutoCAD\R<rel>, but on a
    # successful run the AutoCAD uninstaller has usually just deleted that key -
    # so Test-Path fails, the loop never executes, and the check silently passes.
    # It is also year-scoped: a co-installed Civil 3D 2026 carries the SAME year,
    # so it would clear the check even when the key is present.
    #
    # HKCU ...\AutoCAD\R<rel> is where profiles, toolbars and plotter settings
    # live, and a co-tenant's live under the same release container. Deleting it
    # while a toolset is installed destroys that toolset's user configuration.
    if ($CoTenantsPresent) {
        Write-Log "Residual registry cleanup SKIPPED: another product shares release $Release, and its profiles live under the same key. Remove that product first, or delete the key by hand." 'WARN'
        return 0
    }

    if ([string]::IsNullOrWhiteSpace($Release)) {
        Write-Log 'Residual registry cleanup skipped: the release could not be resolved from the registry.' 'WARN'
        return 0
    }
    if ($Release -notmatch '^R\d+\.\d+$') {
        Write-Log "Residual registry cleanup skipped: '$Release' is not a release container name." 'WARN'
        return 0
    }

    # Re-census AFTER the uninstalls: anything still registered under this
    # release that names a different year means the key is not ours to delete.
    $relPath = "HKLM:\SOFTWARE\Autodesk\AutoCAD\$Release"
    if (Test-Path -LiteralPath $relPath) {
        foreach ($prod in @(Get-ChildItem -LiteralPath $relPath -ErrorAction SilentlyContinue)) {
            $p = $null
            try { $p = Get-ItemProperty -LiteralPath $prod.PsPath -ErrorAction Stop } catch { continue }
            $upi  = [string](Get-Prop $p 'UPIRELEASE')
            $glob = [string](Get-Prop $p 'ProductNameGlob')
            $name = [string](Get-Prop $p 'ProductName')
            $other = ($upi  -and $upi  -ne $Year) -or
                     ($glob -and $glob -notlike "*$Year*") -or
                     ($name -and $name -notlike "*$Year*")
            if ($other) {
                Write-Log ("Residual registry cleanup refused: {0}\{1} still claims '{2}' (not {3})." -f `
                    $Release, $prod.PSChildName, ($name, $glob, $upi | Where-Object { $_ } | Select-Object -First 1), $Year) 'WARN'
                return 0
            }
        }
    }

    foreach ($hive in 'HKCU', 'HKLM') {
        $key = "${hive}:\SOFTWARE\Autodesk\AutoCAD\$Release"
        if (-not (Test-Path -LiteralPath $key)) { continue }

        if (-not $Force -and -not $WhatIfPreference) {
            $answer = Read-Host "Delete residual registry key '$key'? [Y/N]"
            if ($answer -notmatch '^(y|yes)$') {
                Write-Log "Kept residual registry key: $key" 'WARN'
                continue
            }
        }

        if ($PSCmdlet.ShouldProcess($key, 'Remove residual registry key')) {
            # Irreversible operation: export first, and do NOT delete if the
            # backup did not actually land. A .reg file the user can double-click
            # is the whole rollback story for this tier.
            $regPath = $key -replace '^([A-Za-z]+):\\', '$1\'
            # $LogPath is rooted by now, but this is the last irreversible step
            # in the script - an empty parent here would throw outside the try
            # below and kill a run whose uninstalls all succeeded.
            $backupDir = Split-Path -Parent $LogPath
            if ([string]::IsNullOrWhiteSpace($backupDir)) { $backupDir = $env:TEMP }
            $backup = Join-Path $backupDir `
                ('AutoCAD{0}_{1}_{2}.reg' -f $ProductYear, $Release, $hive)
            $exported = $false
            try {
                $null = & reg.exe export $regPath $backup /y 2>&1
                $exported = (Test-Path -LiteralPath $backup) -and ((Get-Item -LiteralPath $backup).Length -gt 0)
            }
            catch { $exported = $false }

            if (-not $exported) {
                Write-Log "Refusing to delete '$key': the registry backup could not be written to $backup." 'ERROR'
                continue
            }
            Write-Log "Registry backup written: $backup (double-click to restore)" 'OK'

            try {
                Remove-Item -LiteralPath $key -Recurse -Force -ErrorAction Stop
                Write-Log "Deleted residual registry key: $key" 'OK'
                $removed++
            }
            catch {
                Write-Log "Failed to delete '$key': $($_.Exception.Message)" 'ERROR'
            }
        }
    }
    return $removed
}

if ($failures -gt 0) {
    if ($RemoveResidualFiles -or $RemoveResidualRegistry) {
        Write-Log 'Skipping residual cleanup because one or more products failed to uninstall. Re-run after the uninstall succeeds.' 'WARN'
    }
}
elseif ($skipped -gt 0) {
    if ($RemoveResidualFiles -or $RemoveResidualRegistry) {
        Write-Log "Skipping residual cleanup because $skipped product(s) were declined and are still installed. Deleting their files would leave a registered product with no files." 'WARN'
    }
}
else {
    if ($RemoveResidualFiles) {
        Write-Log "Scanning for AutoCAD $ProductYear residual folders..."
        $null = Remove-ResidualFiles -Paths $ResidualPaths
    }
    if ($RemoveResidualRegistry) {
        Write-Log "Scanning for AutoCAD $ProductYear residual registry keys..."
        $rel = if ($release) { $release.Release } else { '' }
        $null = Remove-ResidualRegistryKeys -Release $rel -Year $ProductYear `
                    -CoTenantsPresent $guardTripped
    }
}

# --- Summary --------------------------------------------------------------
Write-Log '---------------------------------------------'
if ($failures -eq 0) {
    if ($WhatIfPreference) {
        Write-Log 'Preview complete. NOTHING was uninstalled, deleted or modified.' 'OK'
        Write-Log 'Re-run the same command without -WhatIf to perform the removal.'
    }
    elseif ($skipped -gt 0) {
        # A declined product is still installed and still registered, so this run
        # did not do what its command line asked. "Completed." here would tell an
        # operator - and anything scraping this log - that AutoCAD is gone when it
        # is sitting untouched in Add/Remove Programs.
        Write-Log "Completed with $skipped product(s) declined and still installed." 'WARN'
    }
    else {
        Write-Log 'Completed. Shared Autodesk components were preserved.' 'OK'
    }
    if ($rebootNeeded) { Write-Log 'A reboot is recommended to finalize removal.' 'WARN' }
}
else {
    Write-Log "Completed with $failures failure(s). Review the log: $LogPath" 'ERROR'
}
Write-Log "Log saved to: $LogPath"

try { Stop-Transcript | Out-Null } catch { }

if ($failures -gt 0) { exit 3 }
elseif ($rebootNeeded) { exit 3010 }
else { exit 0 }
