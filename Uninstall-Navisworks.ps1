<#
.SYNOPSIS
    Uninstalls an Autodesk Navisworks edition (Manage / Simulate / Freedom, any
    year) on Windows while preserving the Navisworks EXPORTERS, shared Autodesk
    components, and every other Autodesk product.

.DESCRIPTION
    Discovers the installed Navisworks products for the target year
    (-ProductYear, default 2026) and edition (-Edition, default All) by reading
    the Windows "Uninstall" registry hives (64-bit, 32-bit/WOW6432Node and
    per-user), then runs each vendor-registered uninstaller silently.

    THE CENTRAL NAVISWORKS FACT, and the reason this is not a copy of
    Uninstall-Revit.ps1 with the word swapped:

        "Autodesk Navisworks Exporters <year>" is NOT part of the Navisworks
        application. It is a separate, licence-free product that installs INTO
        Revit, AutoCAD and 3ds Max, and it keeps producing NWC files after every
        Navisworks edition is removed. Verified by binary inspection: the Revit
        exporter (nwexportrevit.dll) imports no Navisworks core engine DLL
        (no lcnav, lcodcore, lcodapi) and carries zero references to
        Autodesk.Navisworks - the NWC writer is statically linked and its
        licence token ships beside it.

    A naive "Navisworks + <year>" name rule sweeps the exporters up with the
    application and silently kills NWC export from every Revit/AutoCAD/3ds Max
    on the machine. They are therefore excluded from the default scope by an
    explicit rule, exactly as RealDWG and Content Catalog are in the Revit
    script, and are only removed via -IncludeExporters.

    Three further Navisworks-specific traps this script is built around:

    1. LANGUAGE PACKS REGISTER "/I", NOT "/X". Each product ships 11 language
       packs whose registered UninstallString is "MsiExec.exe /I{GUID}" - the
       INSTALL/repair verb. Running it repairs the pack and never uninstalls it.
       This script synthesizes "/x {ProductCode}" from the registry KEY NAME and
       explicitly refuses any harvested "/I" command line.

    2. THE MAIN PRODUCT MSI HAS NO UNINSTALL STRING AT ALL. Like AutoCAD, each
       edition registers twice: an ODIS bundle wrapper and a hidden MSI child
       (SystemComponent=1, blank UninstallString). The child is a real installed
       MSI with a LocalPackage, so msiexec /x {GUID} works - but any filter that
       skips SystemComponent=1 or blank-UninstallString rows skips the actual
       product. De-duplicate by product code, never by display name: both rows
       carry the identical DisplayName.

    3. THE VERSION KEY IS NOT THE YEAR. Navisworks registers under
       ...\Autodesk\Navisworks <Edition>\<major>.0 where major = year - 2003
       (2023=20, 2026=23). Unlike AutoCAD's R25.1 there are no half-steps, but
       this script still PROVES the mapping by reading the "Product Name" value
       out of the registry rather than computing it, and skips version-scoped
       registry cleanup when it cannot be proven.

    Resolution order for each product's uninstall command:
        1. msiexec /x "<cached LocalPackage>.msi" /qn /norestart
        2. msiexec /x {ProductCode} /qn /norestart   (when WindowsInstaller = 1)
        3. msiexec /x {ProductCode} with a directory-property override
        4. QuietUninstallString (vendor-provided silent command)
        5. UninstallString (run directly; --silent attempted for ODIS EXE
           uninstallers, with the exact vendor command kept as an auto fallback)

.PARAMETER ProductYear
    Four-digit Navisworks release year to target (e.g. 2023, 2025, 2026).
    Default: 2026. Everything - the core match, the residual folders, the
    residual path guard, the version-key resolution and the self-elevation
    relaunch - is scoped to this year.

.PARAMETER Edition
    Which Navisworks edition(s) to target: All (default), Manage, Simulate or
    Freedom. All three can be installed side by side. Editions other than the
    selected one are never matched, never stopped, and never cleaned up.

.PARAMETER IncludeExporters
    ALSO remove "Autodesk Navisworks Exporters <year>" and its payload inside
    Revit / AutoCAD / 3ds Max. Off by default, and deliberately so - see the
    description. Turning this on BREAKS NWC EXPORT from those applications for
    that exporter year, which is a separate concern from whether Navisworks
    itself is installed. Note the exporter year tracks the NAVISWORKS release,
    not the host application: "Exporters 2023" is routinely kept on a machine
    with no Navisworks 2023 at all, to produce NWC files a 2023-era Navisworks
    can read. This is a [switch]: pass it bare, like -Force, not as
    -IncludeExporters:$true.

.PARAMETER IncludeCoordinationIssuesAddin
    Also remove "Autodesk Navisworks Coordination Issues Add-In" (the ACC/BIM
    360 issues plugin). Off by default. It carries NO year in its name and is
    genuinely cross-version - its payload folder holds v18 through v24 - so it
    is still in use while any other Navisworks year remains. When this is
    enabled the script re-censuses the machine after the uninstall and removes
    the add-in ONLY if no Navisworks edition of any year survives. This is a
    [switch]: pass it bare, like -Force, not as
    -IncludeCoordinationIssuesAddin:$true.

.PARAMETER IncludeMaterialLibraries
    Opt in to also removing Material Library packages matching the target year.
    Off by default because material libraries are shared across products. This
    is a [switch]: pass it bare, like -Force, not as
    -IncludeMaterialLibraries:$true.

.PARAMETER RemoveResidualFiles
    After a fully successful uninstall, delete leftover Navisworks <year>
    folders (per-user settings, machine-wide templates, caches, the program
    folder, Start Menu entries and the ODIS uninstaller stubs). Default: $true.
    Disable with -RemoveResidualFiles:$false, which needs the -Command form (see
    .NOTES). A runtime guard only permits deletion of paths under an Autodesk
    tree that reference Navisworks and the target year, and refuses the shared
    Common Files\Autodesk Shared tree outright.

.PARAMETER RemoveResidualRegistry
    Opt-in. Also delete the version-scoped keys
    HK{LM,CU}:\SOFTWARE\Autodesk\Navisworks <Edition>\<major>.0 and
    HKLM:\SOFTWARE\Autodesk\Navisworks API Runtime\<major>\<Edition>.
    Off by default. Only acts when the year-to-version mapping was PROVEN from
    the registry, and never touches the parent container key (which other
    Navisworks years and the Exporters register under). This is a [switch]: pass
    it bare, like -Force, not as -RemoveResidualRegistry:$true.

.PARAMETER NeutralizeBrokenCustomActions
    When an MSI uninstall attempt exits 1603 and its verbose log shows
    "Internal Error 2753", copy the cached package to %TEMP%, condition the
    named action out ('0' = never run) in the COPY, recache it with /fv and
    retry. Default: $true. Disable with -NeutralizeBrokenCustomActions:$false,
    which needs the -Command form (see .NOTES). See TROUBLESHOOTING.md.

.PARAMETER StopNavisworks
    If a Navisworks process belonging to the TARGET installation is running,
    terminate it before uninstalling. Processes are attributed by executable
    PATH, so another edition or year stays open. Without this switch the script
    aborts when a target process is running.

.PARAMETER ListOnly
    Discover and print matching products, then exit. Performs no changes.

.PARAMETER Force
    Fully non-interactive: skips the per-item Read-Host prompts AND suppresses
    PowerShell's built-in ShouldProcess confirmation.

.PARAMETER LogPath
    Full path for the transcript log. Defaults to
    %TEMP%\Uninstall-Navisworks<year>_<timestamp>.log

.EXAMPLE
    # Preview what would be removed for the default year (2026), no changes:
    powershell -ExecutionPolicy Bypass -File .\Uninstall-Navisworks.ps1 -ListOnly

.EXAMPLE
    # Uninstall Navisworks Manage 2026 only, prompting each step:
    powershell -ExecutionPolicy Bypass -File .\Uninstall-Navisworks.ps1 -ProductYear 2026 -Edition Manage

.EXAMPLE
    # Fully unattended for 2025, closing Navisworks if it is open:
    powershell -ExecutionPolicy Bypass -File .\Uninstall-Navisworks.ps1 -ProductYear 2025 -StopNavisworks -Force

.EXAMPLE
    # Also remove the NWC exporters - this breaks NWC export from Revit/AutoCAD/3ds Max:
    powershell -ExecutionPolicy Bypass -File .\Uninstall-Navisworks.ps1 -ProductYear 2026 -IncludeExporters

.EXAMPLE
    # Full wipe including the version-scoped profile keys (opt-in, bare switch):
    powershell -ExecutionPolicy Bypass -File .\Uninstall-Navisworks.ps1 -ProductYear 2026 -RemoveResidualRegistry -Force

.EXAMPLE
    # Turning OFF one of the [bool] parameters needs -Command, not -File.
    # powershell.exe -File passes every argument as a literal string, and a
    # [bool] parameter rejects the string "$false" outright. Measured: no -File
    # form works - not :$false, not :0. This is the only shape that binds:
    powershell -ExecutionPolicy Bypass -Command "& '.\Uninstall-Navisworks.ps1' -ProductYear 2026 -RemoveResidualFiles:$false"

.NOTES
    Requires an elevated (Administrator) session; the script self-elevates.
    Exit code 0 = success, 3010 = success (reboot required), 3 = partial failure,
    2 = nothing found, 1 = aborted.

    -IncludeExporters, -IncludeCoordinationIssuesAddin, -IncludeMaterialLibraries
    and -RemoveResidualRegistry are [switch] rather than [bool] specifically so
    that they bind under "powershell.exe -File", which is how every example in
    this repo is written. Pass them bare - "-Force" style - not as
    "-IncludeExporters:$true".
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [ValidatePattern('^\d{4}$')]
    [string]$ProductYear       = '2026',
    [ValidateSet('All', 'Manage', 'Simulate', 'Freedom')]
    [string]$Edition           = 'All',
    # The OPT-INS are [switch], not [bool], and that is deliberate:
    # "powershell.exe -File" passes every argument as a literal STRING, and a
    # [bool] parameter's argument transformation rejects the string "$true" with
    # "Boolean parameters accept only Boolean values and numbers". Measured: NO
    # -File form binds a [bool] - not :$true, not :1, not :0, not :true. Since
    # these are the parameters an operator actually types, they must work with
    # the -File invocation every example in this repo uses.
    [switch]$IncludeExporters,
    [switch]$IncludeCoordinationIssuesAddin,
    [switch]$IncludeMaterialLibraries,
    # These two stay [bool] because they default ON and are only ever passed to
    # turn a removal OFF, which is rare. Doing so needs the -Command form - see
    # the .NOTES block.
    [bool]$RemoveResidualFiles = $true,
    [switch]$RemoveResidualRegistry,
    [bool]$NeutralizeBrokenCustomActions = $true,
    [switch]$StopNavisworks,
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
# A bare filename has no parent directory, and any later Split-Path -Parent on
# it throws under $ErrorActionPreference='Stop' - after every product has
# already been removed. This runs BEFORE self-elevation on purpose: the relay
# forwards -LogPath to the elevated child, whose working directory is not the
# operator's.
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
# $ProductYear and $Edition scope every match below.

# The edition token sits BETWEEN "Navisworks" and the year:
# "Autodesk Navisworks Manage 2026", never "Autodesk Navisworks 2026 Manage".
# A pattern of "Autodesk Navisworks <year>" matches NOTHING.
$EditionTokens = if ($Edition -eq 'All') { @('Manage', 'Simulate', 'Freedom') } else { @($Edition) }

# Core product family: always targeted.
#
# The single trailing wildcard is what picks up the 11 language packs, whose
# names are the base string plus a localized suffix with NO consistent
# separator ("... 2026 - English Language Pack" but also
# "... 2026 <Korean text> - <Korean text>(Korean)" with no " - " at all).
# Anchored with no leading wildcard so "Navisworks Exporters" can never match.
#
# The reversed "<year> <edition>" form is included because the Start Menu folder
# on this platform is "Autodesk Navisworks 2026 Exporters - 64 bit" - evidence
# Autodesk has shipped the year-first order elsewhere, and the display names for
# releases before 2023 could not be confirmed. It costs nothing and the
# exclusions below still protect the exporters.
$CorePatterns = @()
foreach ($tok in $EditionTokens) {
    $CorePatterns += "Autodesk Navisworks $tok $ProductYear*"
    $CorePatterns += "Navisworks $tok $ProductYear*"
    $CorePatterns += "Autodesk Navisworks $ProductYear $tok*"
}

# Navisworks-NAMED products that are NOT the Navisworks application. Every one
# of these matches a naive "*Navisworks*" rule and none of them should die with
# the application.
$NavisworksAdjacentPatterns = @(
    '*Navisworks Exporters*',      # the NWC exporters - see .DESCRIPTION
    '*Coordination Issues*',       # cross-version ACC issues add-in, no year
    '*Publish NWC*',               # ACC publish add-in living inside Revit
    '*NWC Publish*'                # ...and its other two word orders
)

# Shared / cross-product components: NEVER touched in this mode.
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
    '*Single Sign On*',
    '*AdSSO*',
    '*ODIS*',
    '*AdODIS*',
    '*Autodesk Installer*',
    '*Content Catalog*',
    '*Interoperability Engine Manager*',
    '*Desktop Connector*',
    '*Autodesk CER*'
)

# The exporters and the other Navisworks-adjacent products are excluded unless
# explicitly opted in. -IncludeCoordinationIssuesAddin is handled separately
# (post-uninstall census) rather than by unlocking the pattern here, because its
# removal is conditional on no Navisworks edition of ANY year remaining.
if (-not $IncludeExporters) {
    $SharedExclusions += '*Navisworks Exporters*'
}
$SharedExclusions += '*Coordination Issues*'
$SharedExclusions += '*Publish NWC*'
$SharedExclusions += '*NWC Publish*'

if (-not $IncludeMaterialLibraries) {
    $SharedExclusions += '*Material Library*'
    $SharedExclusions += '*Advanced Material Library*'
}

# Paths that are NEVER residual candidates regardless of what the name rules
# say. Common Files\Autodesk Shared is the dangerous one: it is on the machine
# PATH and each "RealDWG Shared <year>" inside it contains nwcore.dll, whose
# VersionInfo reads ProductName "Autodesk Navisworks". Anything matching on the
# string "Navisworks" inside that tree would select DLLs that Revit, Inventor
# and Civil 3D depend on.
#
# Built by string join rather than Join-Path: Join-Path throws on a null -Path,
# and ${env:ProgramFiles(x86)} is absent on a 32-bit host - which would abort
# the whole script at configuration time under $ErrorActionPreference='Stop'.
$ForbiddenResidualRoots = @(
    (@(${env:ProgramFiles},      'Common Files\Autodesk Shared') -join '\'),
    (@(${env:ProgramFiles(x86)}, 'Common Files\Autodesk Shared') -join '\'),
    (@(${env:ProgramFiles},      'Autodesk\AdODIS')              -join '\'),
    (@(${env:ProgramData},       'Autodesk\ODIS')                -join '\')
) | Where-Object { $_ -notmatch '^\\' }

# Executables that are unique to the Navisworks APPLICATION and may be matched
# by bare name. Verified: exactly one copy each across Program Files and
# Program Files (x86). Roamer.exe is the main application - the name is
# historic, there is no Navisworks.exe, and all three editions use it.
$NavisworksOwnProcessNames = @(
    'Roamer', 'FileToolsGUI', 'FileTools2GUI', 'FiletoolsTaskRunner'
)

# Executables that live inside the Navisworks folder but are NOT unique to it.
# These may only ever be matched by full PATH. Measured copies machine-wide:
# upi 13-20, senddmp 13-17, AdPreviewGenerator 6, OptionsEditor 3 (two of which
# belong to the Exporters this script preserves), AppManager 12 (eleven of which
# are the shared Autodesk App Manager bundle used by AutoCAD).
$PathScopedProcessNames = @(
    'OptionsEditor', 'AppManager', 'upi', 'senddmp', 'AdPreviewGenerator'
)

# Host applications whose files the EXPORTERS live inside. Never terminated -
# only reported - and only relevant when -IncludeExporters is on, because a
# locked DLL turns a delete into a silent no-op.
$ExporterHostProcessNames = @('Revit', 'RevitWorker', 'acad', '3dsmax')

# Directory-property override, shared by the MSI-PropsOverride attempt and the
# 2753 patched-copy retry. Generic last resort here rather than a targeted fix:
# the Navisworks packages inspected do not carry the DIRCA_INSTALLDIR action
# that made this the specific remedy for Revit's error 1606. No trailing
# backslash before the closing quote (\" escapes the quote and mangles every
# argument after it); ROOTDRIVE stays unquoted because its value MUST end in a
# backslash.
$FallbackDirProps = ' ROOTDRIVE=C:\'

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
    # mangles a script path that contains spaces, which silently breaks
    # self-elevation.
    $passArgs = @()
    $passArgs += ('-ProductYear {0}'      -f $ProductYear)
    $passArgs += ('-Edition {0}'          -f $Edition)
    $passArgs += ('-RemoveResidualFiles:${0}' -f $RemoveResidualFiles)
    $passArgs += ('-NeutralizeBrokenCustomActions:${0}' -f $NeutralizeBrokenCustomActions)
    if ($IncludeExporters)               { $passArgs += '-IncludeExporters' }
    if ($IncludeCoordinationIssuesAddin) { $passArgs += '-IncludeCoordinationIssuesAddin' }
    if ($IncludeMaterialLibraries)       { $passArgs += '-IncludeMaterialLibraries' }
    if ($RemoveResidualRegistry)         { $passArgs += '-RemoveResidualRegistry' }
    if ($StopNavisworks) { $passArgs += '-StopNavisworks' }
    if ($ListOnly)       { $passArgs += '-ListOnly' }
    if ($Force)          { $passArgs += '-Force' }

    # COMMON parameters live OUTSIDE param(), so a relay assembled from this
    # script's own parameter list silently drops them at the UAC boundary.
    # For -WhatIf that is catastrophic, not cosmetic: the elevated child would
    # start WITHOUT -WhatIf, ShouldProcess would return $true, and a command the
    # operator issued as a PREVIEW would perform a real uninstall.
    if ($WhatIfPreference) { $passArgs += '-WhatIf' }
    if ($PSBoundParameters.ContainsKey('Confirm')) {
        $passArgs += ('-Confirm:${0}' -f [bool]$PSBoundParameters['Confirm'])
    }
    if ($VerbosePreference -eq 'Continue') { $passArgs += '-Verbose' }
    if ($DebugPreference   -eq 'Continue') { $passArgs += '-Debug' }
    if ($LogPath)          { $passArgs += ("-LogPath '{0}'" -f ($LogPath -replace "'", "''")) }

    # powershell.exe -File CANNOT bind [bool] parameters (nor -Switch:$false):
    # PS 5.1 passes every -File argument as a literal string and rejects it with
    # "Boolean parameters accept only Boolean values and numbers". The elevated
    # child would die at parameter binding BEFORE Start-Transcript - no log,
    # elevation "does nothing". Relaunch through -Command with a single-quoted
    # call-operator path instead. The trailing "; exit $LASTEXITCODE" is
    # required: in -Command mode an "exit N" inside the invoked SCRIPT only sets
    # $LASTEXITCODE, and the child collapses every non-zero script exit to 1,
    # destroying the 0/2/3/3010 exit-code contract.
    $qPath   = $PSCommandPath -replace "'", "''"
    $cmdLine = '-NoProfile -ExecutionPolicy Bypass -Command "& ''{0}'' {1}; exit $LASTEXITCODE"' -f $qPath, ($passArgs -join ' ')

    # FAIL CLOSED. The elevation boundary is a SERIALIZATION boundary: anything
    # not explicitly written into $cmdLine does not exist in the privileged
    # child. Verify the preview flag is actually present in the bytes about to
    # be launched rather than trusting that the line above added it.
    if ($WhatIfPreference -and $cmdLine -notmatch '(?i)(?<=\s)-WhatIf(?=\s|;|")') {
        Write-Host 'Refusing to elevate: -WhatIf was requested but is not present in the elevated command line. Aborting rather than running a real uninstall under a preview flag.' -ForegroundColor Red
        exit 1
    }

    try {
        $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList $cmdLine -Verb RunAs -PassThru -Wait -ErrorAction Stop
    }
    catch {
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
    $LogPath = Join-Path $env:TEMP "Uninstall-Navisworks${ProductYear}_$stamp.log"
}
# -WhatIf:$false is deliberate. Start-Transcript is itself ShouldProcess-aware,
# so under -WhatIf it PREVIEWS instead of opening the log, and the run then ends
# by announcing "Log saved to: <path>" for a file that was never written.
try { Start-Transcript -Path $LogPath -Append -WhatIf:$false | Out-Null } catch { }

# Preload CimCmdlets while the preview flag is switched off in a child scope.
# The process check autoloads this module; if that happens mid -WhatIf run, the
# module's own top-level Set-Alias calls inherit $WhatIfPreference and spray
# "What if: Performing the operation Set Alias" lines into the middle of the report.
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
Write-Log "Navisworks $ProductYear ($Edition) uninstall started. Log: $LogPath"
Write-Log ("Mode: {0}{1}{2}{3}{4}{5}" -f `
    $(if ($WhatIfPreference) { 'PREVIEW ' } else { '' }),
    $(if ($ListOnly) { 'ListOnly ' } else { 'Uninstall ' }),
    $(if ($IncludeExporters) { '+EXPORTERS ' } else { 'ExportersKept ' }),
    $(if ($RemoveResidualFiles) { '+Residual ' } else { '' }),
    $(if ($RemoveResidualRegistry) { '+Registry ' } else { '' }),
    $(if ($Force) { 'Force' } else { 'Interactive' }))

if ($IncludeExporters) {
    Write-Log 'WARNING: -IncludeExporters removes the NWC exporters. NWC export from Revit, AutoCAD and 3ds Max will stop working for this exporter year.' 'WARN'
}

# --- Product discovery ----------------------------------------------------
# StrictMode-safe property reader: returns the value or $null, never throws
# when the registry key lacks the requested value.
function Get-Prop {
    param($Obj, [string]$Name)
    # $Obj is $null whenever Get-ItemProperty was handed a registry key that has
    # ZERO values - normal for container keys. Dereferencing .PSObject on $null
    # is a terminating error under StrictMode, so this must be checked BEFORE
    # the lookup, not after.
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

# Normalize a directory path for comparison: trim quotes and trailing
# separators, collapse doubled separators (Autodesk writes
# "C:\Program Files\Autodesk\\Foo\" in some registrations), lower-case it.
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

# --- Navisworks version resolution ----------------------------------------
# Navisworks registers under ...\Autodesk\Navisworks <Edition>\<major>.0, where
# major = year - 2003 (2023=20, 2024=21, 2025=22, 2026=23, 2027=24). Unlike
# AutoCAD's R25.0/R25.1 there are no half-steps, and the segment is ALWAYS
# "<major>.0" even when the product's DisplayVersion has advanced past it
# (Navisworks Manage 2026 is 23.2.1444.96 but registers under 23.0).
#
# The arithmetic is safe here in a way it is not for AutoCAD - but this still
# READS the mapping rather than computing it, for the same reason the AutoCAD
# script does: a version-scoped registry delete against a guessed key wipes a
# different release's user profile. The arithmetic is kept only as a cross-check.
#
# Three traps this walks around, all measured:
#   1. "Navisworks API Runtime" is a sibling under the same parent, and its
#      version segment is a BARE major ("23", no ".0"). Excluded here and
#      handled separately.
#   2. "Navisworks Exporters" is a MULTI-YEAR container: 20.0 (2023) and 23.0
#      (2026) coexist under it. It is never an edition and never a target.
#   3. Most children of the version key are not product tokens (CadManagerControl,
#      en-US, Extensions, Install, Location). Only one carries "Product Name",
#      and its name is inconsistently cased between products (NAVMAN-1 for
#      Manage, exporters-1 for Exporters). So the token is DISCOVERED by asking
#      which child has a "Product Name" value - never pattern-matched by name.
function Resolve-NavisworksInstalls {
    param(
        [string]$Year,
        [string[]]$Editions,
        [string]$HiveRoot = 'HKLM:\SOFTWARE\Autodesk'
    )

    $found = @()
    if (-not (Test-Path -LiteralPath $HiveRoot)) { return $found }

    foreach ($ed in $Editions) {
        $brandKey = Join-Path $HiveRoot "Navisworks $ed"
        if (-not (Test-Path -LiteralPath $brandKey)) { continue }

        foreach ($verKey in @(Get-ChildItem -LiteralPath $brandKey -ErrorAction SilentlyContinue)) {
            # Only "<major>.0" containers. This also rejects the bare-major
            # shape used by Navisworks API Runtime if the loop ever reaches it.
            #
            # [regex]::Match rather than -notmatch: $Matches is only guaranteed
            # populated by -match, and reading an unset $Matches is a terminating
            # error under Set-StrictMode -Version Latest.
            $mVer = [regex]::Match($verKey.PSChildName, '^(\d+)\.0$')
            if (-not $mVer.Success) { continue }
            $major = [int]$mVer.Groups[1].Value

            # Find the child that actually carries a "Product Name" value.
            $token       = $null
            $productName = $null
            foreach ($child in @(Get-ChildItem -LiteralPath $verKey.PSPath -ErrorAction SilentlyContinue)) {
                $cp = $null
                try { $cp = Get-ItemProperty -LiteralPath $child.PSPath -ErrorAction Stop } catch { continue }
                $pn = Get-Prop $cp 'Product Name'
                if (-not [string]::IsNullOrWhiteSpace($pn)) {
                    $token       = $child.PSChildName
                    $productName = $pn
                    break
                }
            }

            if ([string]::IsNullOrWhiteSpace($productName)) {
                Write-Log "Version key '$($verKey.PSChildName)' under 'Navisworks $ed' carries no Product Name - year cannot be proven, skipping it." 'WARN'
                continue
            }

            # Prove the year by reading it out of the product name, then
            # cross-check against the arithmetic. A mismatch means the machine
            # does not match the model, so nothing version-scoped is trusted.
            $mYear = [regex]::Match($productName, '(\d{4})')
            if (-not $mYear.Success) {
                Write-Log "Product Name '$productName' carries no four-digit year - skipping version-scoped resolution." 'WARN'
                continue
            }
            $provenYear = $mYear.Groups[1].Value
            $computed   = $major + 2003
            if ([int]$provenYear -ne $computed) {
                Write-Log "Version mismatch under 'Navisworks $ed\$($verKey.PSChildName)': Product Name says $provenYear, key implies $computed. Skipping version-scoped operations for it." 'WARN'
                continue
            }
            if ($provenYear -ne $Year) { continue }

            # Location\Path is authoritative for the install root. Read the
            # value named "Path" specifically - the sibling values "Project Path"
            # and "Site Path" live under the same key and are normally empty.
            $installRoot = $null
            $locKey = Join-Path $verKey.PSPath 'Location'
            if (Test-Path -LiteralPath $locKey) {
                $lp = $null
                try { $lp = Get-ItemProperty -LiteralPath $locKey -ErrorAction Stop } catch { }
                $installRoot = Get-Prop $lp 'Path'
            }
            # Fallback: the hidden MSI child's InstallLocation. Deliberately NOT
            # the ODIS wrapper's, whose InstallLocation is the PARENT directory
            # "C:\Program Files\Autodesk" - using that as a scope root would
            # path-match every Autodesk product on the machine.
            if ([string]::IsNullOrWhiteSpace($installRoot)) {
                $tk = $null
                try { $tk = Get-ItemProperty -LiteralPath (Join-Path $verKey.PSPath $token) -ErrorAction Stop } catch { }
                $installRoot = Get-Prop $tk 'Installation Location'
            }

            $productCode = $null
            $tk2 = $null
            try { $tk2 = Get-ItemProperty -LiteralPath (Join-Path $verKey.PSPath $token) -ErrorAction Stop } catch { }
            $productCode = Get-Prop $tk2 'Product Code'

            $found += [pscustomobject]@{
                Edition      = $ed
                Major        = $major
                VersionKey   = $verKey.PSChildName
                Year         = $provenYear
                ProductName  = $productName
                ProductToken = $token
                ProductCode  = $productCode
                InstallRoot  = $installRoot
                HklmKeyPath  = $verKey.PSPath
            }
        }
    }
    return $found
}

$installs = @(Resolve-NavisworksInstalls -Year $ProductYear -Editions $EditionTokens)
if ($installs.Count -gt 0) {
    foreach ($i in $installs) {
        Write-Log ("Resolved: {0} -> version key {1} (proven from '{2}')" -f $i.Edition, $i.VersionKey, $i.ProductName) 'OK'
        if (-not [string]::IsNullOrWhiteSpace($i.InstallRoot)) {
            Write-Log ("    Install root: {0}" -f $i.InstallRoot)
        }
    }
}
else {
    Write-Log "No Navisworks $ProductYear version key proven under HKLM:\SOFTWARE\Autodesk. Version-scoped registry cleanup will be skipped." 'WARN'
}

# Scope roots for process attribution and residual cleanup. The registry Path
# value already ends in a backslash; -like treats backslash literally (the
# PowerShell escape character is a backtick), so "$root\*" would become
# "...2026\\*" and match nothing. TrimEnd before appending.
#
# The @() must wrap the ENTIRE pipeline including Select-Object -Unique. With a
# single install, -Unique emits a bare string, and the "+=" below would then be
# STRING CONCATENATION rather than an array append - silently producing one
# glued-together path that matches nothing.
$NavisRoots = @(
    $installs | ForEach-Object { $_.InstallRoot } |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
    ForEach-Object { $_.TrimEnd('\', '/') } |
    Select-Object -Unique
)

# Conventional fallback so a machine whose registry no longer proves the
# version still gets its program folder scanned.
foreach ($tok in $EditionTokens) {
    $conv = Join-Path ${env:ProgramFiles} "Autodesk\Navisworks $tok $ProductYear"
    if ($NavisRoots -notcontains $conv) { $NavisRoots += $conv }
}
$NavisRoots = @($NavisRoots | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)

$all = @(Get-InstalledPrograms |
    Where-Object { $_.Publisher -like '*Autodesk*' -or $_.DisplayName -like '*Navisworks*' })

$targets = @(
    $all |
    Where-Object { Test-MatchesAny -Value $_.DisplayName -Patterns $CorePatterns } |
    Where-Object { -not (Test-MatchesAny -Value $_.DisplayName -Patterns $SharedExclusions) } |
    Where-Object { $_.DisplayName -notmatch '\d{4}\s*[-\u2013]\s*\d{4}' }
)

# With -IncludeExporters, the exporter family is a SECOND product family rather
# than part of the core match - its display names ("Autodesk Navisworks
# Exporters <year>") do not contain an edition token and so never match
# $CorePatterns.
if ($IncludeExporters) {
    $exporterPatterns = @(
        "Autodesk Navisworks Exporters $ProductYear*",
        "Navisworks Exporters $ProductYear*",
        "Autodesk Navisworks $ProductYear Exporters*"
    )
    $targets += @(
        $all |
        Where-Object { Test-MatchesAny -Value $_.DisplayName -Patterns $exporterPatterns } |
        Where-Object { $_.DisplayName -notmatch '\d{4}\s*[-\u2013]\s*\d{4}' }
    )
}

# De-duplicate by PRODUCT CODE, never by display name. Both the ODIS bundle
# wrapper and the hidden MSI child carry the identical DisplayName
# "Autodesk Navisworks Manage <year>" but are different product codes and both
# must be processed; conversely a name-keyed de-dup would collapse them and
# leave one registered.
$seenKeys = @{}
$targets = @(
    $targets | ForEach-Object {
        $k = ('{0}|{1}' -f $_.KeyName, $_.RegistryPath).ToLowerInvariant()
        if (-not $seenKeys.ContainsKey($k)) { $seenKeys[$k] = $true; $_ }
    }
)

if ($targets.Count -eq 0) {
    Write-Log "No Autodesk Navisworks $ProductYear ($Edition) products found in the uninstall registry." 'WARN'
    if ($all.Count -gt 0) {
        Write-Log 'Autodesk/Navisworks entries present on this machine (for reference):'
        $all | Sort-Object DisplayName -Unique | ForEach-Object { Write-Log "    - $($_.DisplayName)" }
    }
    try { Stop-Transcript | Out-Null } catch { }
    exit 2
}

# --- Removal order --------------------------------------------------------
# Mirrors the AutoCAD script's proven ordering, with one Navisworks difference:
# update bundles DO NOT register in the uninstall hive at all. On this platform
# "Navisworks Manage 2026 Update 1/2" exist only as %ProgramData%\Autodesk\
# Uninstallers\<name> folders holding AdskUninstallHelper.exe. Rank 0 is kept
# anyway because finding one costs nothing and other machines are unproven.
function Get-RemovalRank {
    param($Product)
    $n = $Product.DisplayName
    if ($n -like '*Update*') { return 0 }  # patches on the base

    # The ODIS bundle wrapper is identified by its uninstall COMMAND, and this
    # test must run BEFORE the GUID heuristic below. Measured on this platform
    # the wrapper's own product code is {71168559-1BF3-326F-...}: its third GUID
    # group is non-zero, so the LCID heuristic would misfile the orchestrator as
    # a language pack and run it first, defeating the ordering entirely.
    if (-not [string]::IsNullOrWhiteSpace($Product.UninstallString) -and
        $Product.UninstallString -match '(?i)AdODIS|installer\.exe') { return 2 }

    if ($n -match '(?i)Language Pack|\u8a9e\u8a00|\uc5b8\uc5b4') { return 1 }  # localized children
    # Language packs whose localized suffix is in a script the pattern above
    # does not name: they are MSI rows whose product code differs from the core
    # only in the third GUID group (the LCID), the core using -0000-.
    if ($Product.WindowsInstaller -eq 1 -and $Product.KeyName -match '^\{[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-(?!0000)[0-9A-Fa-f]{4}-') { return 1 }

    # Hidden MSI children: SystemComponent=1 with NO UninstallString at all
    # (verified: {991DDDE2-5DF8-0000-...} has neither Uninstall nor
    # QuietUninstallString). msiexec /x synthesized from the key name is the
    # only route, which is why a filter on blank UninstallString would skip the
    # actual product.
    return 3
}

$targets = @($targets |
    Select-Object *, @{ Name = 'Rank'; Expression = { Get-RemovalRank -Product $_ } } |
    Sort-Object Rank, DisplayName)

Write-Log "Matched $($targets.Count) product(s) for removal:" 'OK'
$targets | ForEach-Object {
    Write-Log ("    [{0}] {1}  [{2}]  {3}" -f $_.Rank, $_.DisplayName, $_.DisplayVersion, $_.KeyName)
}

# --- Residual path assembly ----------------------------------------------
# %APPDATA%\Autodesk\Navisworks <year> and %LOCALAPPDATA%\Autodesk\Navisworks
# <year> carry NO edition token and are created by ANY year-N Navisworks
# component - INCLUDING the Exporters. Verified: %LOCALAPPDATA%\Autodesk\
# Navisworks 2023\LocalCache exists on a machine with no Navisworks 2023
# application but with Navisworks Exporters 2023 installed. So "no edition
# installed for year N" does NOT imply "safe to purge year N caches"; they are
# only claimed when the exporters for that year are going too.
$exportersStillPresent = @(
    $all | Where-Object { $_.DisplayName -like "*Navisworks Exporters*" -and $_.DisplayName -like "*$ProductYear*" }
).Count -gt 0

$ResidualPaths = @()
foreach ($tok in $EditionTokens) {
    $ResidualPaths += (Join-Path $env:APPDATA        "Autodesk\Navisworks $tok $ProductYear")
    $ResidualPaths += (Join-Path ${env:ProgramData}  "Autodesk\Navisworks $tok $ProductYear")
    $ResidualPaths += (Join-Path ${env:ProgramData}  "Autodesk\Uninstallers\Autodesk Navisworks $tok $ProductYear")
    $ResidualPaths += (Join-Path ${env:ProgramData}  "Microsoft\Windows\Start Menu\Programs\Autodesk Navisworks $tok $ProductYear")
}

# The registry-resolved install root(s), not just the conventional
# %ProgramFiles% path: a non-default install directory would otherwise survive
# -RemoveResidualFiles untouched and unreported.
$ResidualPaths += $NavisRoots

if ($exportersStillPresent -and -not $IncludeExporters) {
    Write-Log "Navisworks Exporters $ProductYear is installed and being preserved - the edition-less cache folders (%APPDATA%/%LOCALAPPDATA%\Autodesk\Navisworks $ProductYear) belong to it too and will be kept." 'WARN'
}
else {
    $ResidualPaths += (Join-Path $env:APPDATA      "Autodesk\Navisworks $ProductYear")
    $ResidualPaths += (Join-Path $env:LOCALAPPDATA "Autodesk\Navisworks $ProductYear")
}

if ($IncludeExporters) {
    $ResidualPaths += (Join-Path ${env:ProgramFiles} "Autodesk\Navisworks Exporters $ProductYear")
    $ResidualPaths += (Join-Path ${env:ProgramData}  "Autodesk\Uninstallers\Autodesk Navisworks Exporters $ProductYear")
    $ResidualPaths += (Join-Path ${env:ProgramData}  "Microsoft\Windows\Start Menu\Programs\Autodesk Navisworks $ProductYear Exporters - 64 bit")
    # Exporter payload inside the host applications. The bundle folder name is
    # NOT stable across years - Revit 2026 uses
    # "Revit_Navisworks_Exporter.Addin.bundle" while Revit 2023 uses
    # "revit_exporter.Addin.bundle", which carries no Navisworks token at all -
    # so these are discovered rather than assumed.
    foreach ($pluginRoot in @(
            (Join-Path ${env:ProgramData}  'Autodesk\ApplicationPlugins'),
            (Join-Path ${env:ProgramFiles} 'Autodesk\ApplicationPlugins'))) {
        if (-not (Test-Path -LiteralPath $pluginRoot)) { continue }
        $ResidualPaths += @(
            Get-ChildItem -LiteralPath $pluginRoot -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like "*Navisworks_Exporter_$ProductYear*" -or $_.Name -like "*exporter_$ProductYear*" } |
            ForEach-Object { $_.FullName }
        )
    }
}

$ResidualPaths = @($ResidualPaths | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)

# The per-user paths above come from the ELEVATED process's environment. When
# self-elevation crossed accounts (UAC asked for admin CREDENTIALS rather than
# consent, i.e. the signed-in user is not a local admin), %APPDATA% is the
# ADMINISTRATOR's profile and the real user's Navisworks data is never reached.
# Report it rather than silently cleaning the wrong profile.
$invokingUser = $null
try { $invokingUser = (Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).UserName } catch { }
if ($invokingUser) {
    $shortName = ($invokingUser -split '\\')[-1]
    if ($shortName -and $env:USERNAME -and $shortName -ne $env:USERNAME) {
        Write-Log "Elevated as '$env:USERNAME' but the signed-in user is '$shortName'. Per-user residual folders under %APPDATA%/%LOCALAPPDATA% will be cleaned for '$env:USERNAME' ONLY - '$shortName' keeps their Navisworks profile. Re-run from that account to clear it." 'WARN'
    }
}

if ($ListOnly) {
    if ($RemoveResidualFiles) {
        $existing = @($ResidualPaths | Where-Object { $_ -and (Test-Path -LiteralPath $_) })
        if ($existing.Count -gt 0) {
            Write-Log 'Residual locations that would be removed:'
            $existing | ForEach-Object { Write-Log "    - $_" }
        }
        else {
            Write-Log "No Navisworks $ProductYear residual folders found."
        }
    }
    if ($RemoveResidualRegistry -and $installs.Count -gt 0) {
        Write-Log 'Registry keys that would be removed:'
        foreach ($i in $installs) {
            Write-Log "    - HKLM:\SOFTWARE\Autodesk\Navisworks $($i.Edition)\$($i.VersionKey)"
            Write-Log "    - HKCU:\SOFTWARE\Autodesk\Navisworks $($i.Edition)\$($i.VersionKey)"
            Write-Log "    - HKLM:\SOFTWARE\Autodesk\Navisworks API Runtime\$($i.Major)\Navisworks $($i.Edition)"
        }
    }
    Write-Log 'ListOnly specified - no changes made.' 'OK'
    try { Stop-Transcript | Out-Null } catch { }
    exit 0
}

# --- Running-process guard ------------------------------------------------
# Attribution is by executable PATH, so another Navisworks edition or year stays
# open, and the shared helpers that merely live inside the folder are never
# matched by name.
function Get-NavisworksProcesses {
    param([string[]]$Roots)

    $result = @()
    $names  = @($NavisworksOwnProcessNames + $PathScopedProcessNames)
    foreach ($p in @(Get-Process -ErrorAction SilentlyContinue)) {
        $pname = $null
        try { $pname = $p.ProcessName } catch { continue }
        if (-not $pname) { continue }
        if ($names -notcontains $pname) { continue }

        # Reading .Path throws for protected, elevated or other-user processes.
        # Guard per process so one inaccessible entry cannot abort the sweep.
        $path = $null
        try { $path = $p.Path } catch { $path = $null }

        $inScope = $false
        if (-not [string]::IsNullOrWhiteSpace($path)) {
            $inScope = Test-PathUnderAny -Path $path -Roots $Roots
        }

        $result += [pscustomobject]@{
            Process     = $p
            Name        = $pname
            Path        = $path
            InScope     = $inScope
            NameIsOwn   = ($NavisworksOwnProcessNames -contains $pname)
        }
    }
    return $result
}

$navProcs = @(Get-NavisworksProcesses -Roots $NavisRoots)
# A process is in scope when its path proves it, OR when its NAME is one of the
# four verified-unique Navisworks executables and no path could be read.
$inScope      = @($navProcs | Where-Object { $_.InScope -or ($_.NameIsOwn -and -not $_.Path) })
$unattributed = @($navProcs | Where-Object { -not $_.InScope -and -not $_.NameIsOwn -and -not $_.Path })
$otherScope   = @($navProcs | Where-Object { -not $_.InScope -and $_.Path })

foreach ($o in $otherScope) {
    Write-Log "Leaving running process alone (outside the target installation): $($o.Name) - $($o.Path)"
}
foreach ($u in $unattributed) {
    Write-Log "Running process '$($u.Name)' has no resolvable path and cannot be proven to belong to the target installation - it will NOT be terminated." 'WARN'
}

if ($inScope.Count -gt 0) {
    if ($StopNavisworks) {
        Write-Log "Terminating $($inScope.Count) target Navisworks process(es)." 'WARN'
        foreach ($t in $inScope) {
            Write-Log "    - $($t.Name) $(if ($t.Path) { "($($t.Path))" })"
            try { $t.Process | Stop-Process -Force -ErrorAction Stop } catch {
                Write-Log "      could not terminate: $($_.Exception.Message)" 'WARN'
            }
        }
        Start-Sleep -Seconds 3
    }
    else {
        Write-Log 'Navisworks is running. Close it or re-run with -StopNavisworks. Aborting.' 'ERROR'
        foreach ($t in $inScope) { Write-Log "    - $($t.Name) $(if ($t.Path) { "($($t.Path))" })" 'ERROR' }
        try { Stop-Transcript | Out-Null } catch { }
        exit 1
    }
}

# The exporters live INSIDE Revit/AutoCAD/3ds Max. Only relevant when they are
# being removed: a locked DLL turns Remove-Item into a silent no-op. Reported,
# never terminated - these are the user's authoring applications.
if ($IncludeExporters) {
    $hosts = @(Get-Process -ErrorAction SilentlyContinue |
        Where-Object { $ExporterHostProcessNames -contains $_.ProcessName })
    if ($hosts.Count -gt 0) {
        Write-Log "Exporter host application(s) are running: $(($hosts | ForEach-Object { $_.ProcessName } | Select-Object -Unique) -join ', '). Close them or the exporter payload may fail to delete." 'WARN'
    }
}

# --- Uninstall command resolution -----------------------------------------
# Split a registry command line into executable + argument string WITHOUT
# routing through cmd.exe. cmd mangles an unquoted, space-containing path such
# as C:\Program Files\Autodesk\AdODIS\V1\installer.exe (it reads the exe as
# "C:\Program"), which is exactly what produces a generic "exit 1" on Autodesk's
# ODIS uninstaller. Start-Process quotes -FilePath correctly.
function Split-Command {
    param([string]$CommandLine)
    $cl = $CommandLine.Trim()

    if ($cl.StartsWith('"')) {
        $end = $cl.IndexOf('"', 1)
        if ($end -lt 1) { return [pscustomobject]@{ File = $cl.Trim('"'); Args = '' } }
        return [pscustomobject]@{
            File = $cl.Substring(1, $end - 1)
            Args = $cl.Substring($end + 1).Trim()
        }
    }

    $m = [regex]::Match($cl, '(?i)^(.*?\.exe)(?:\s+(.*))?$')
    if ($m.Success) {
        return [pscustomobject]@{
            File = $m.Groups[1].Value.Trim()
            Args = $m.Groups[2].Value.Trim()
        }
    }

    $sp = $cl.IndexOf(' ')
    if ($sp -lt 0) { return [pscustomobject]@{ File = $cl; Args = '' } }
    return [pscustomobject]@{ File = $cl.Substring(0, $sp); Args = $cl.Substring($sp + 1).Trim() }
}

# Resolves the locally CACHED .msi for a ProductCode via the Windows Installer
# COM API. Uninstalling from this literal path bypasses SourceList/network-source
# resolution entirely - the fix for "Error 1606: Could not access network
# location" during /x, which the caller otherwise only sees as a generic 1603.
function Get-MsiLocalPackage {
    param([string]$ProductCode)
    # Pre-initialize: if New-Object throws, the finally block would otherwise
    # reference an undefined variable and itself throw under StrictMode.
    $installer = $null
    try {
        $installer = New-Object -ComObject WindowsInstaller.Installer
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

# Squished (registry-form) GUID for a ProductCode: block-reversed hex, no braces
# or dashes. Windows Installer keys its UserData/Installer\Products
# registrations under this form, not the plain ProductCode.
function Get-MsiSquishedGuid {
    param([string]$ProductCode)
    if ($ProductCode -notmatch '^\{([0-9a-fA-F\-]{36})\}$') { return $null }
    $raw = $matches[1] -replace '-'
    $parts = @(
        $raw.Substring(0,8), $raw.Substring(8,4), $raw.Substring(12,4),
        $raw.Substring(16,2), $raw.Substring(18,2), $raw.Substring(20,2),
        $raw.Substring(22,2), $raw.Substring(24,2), $raw.Substring(26,2),
        $raw.Substring(28,2), $raw.Substring(30,2)
    )
    return ($parts | ForEach-Object { $c = $_.ToCharArray(); [array]::Reverse($c); -join $c }) -join ''
}

# Diagnostic-only: dump every SourceList value that could feed a 1606
# concatenation, so the log shows the ACTUAL bad entry, not just the symptom.
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
                if ($null -ne $sp) {
                    $sp.PSObject.Properties |
                        Where-Object { $_.Name -notmatch '^PS' } |
                        ForEach-Object { Write-Log "    $sub\$($_.Name) = $($_.Value)" 'WARN' }
                }
            } catch { }
        }
    }
}

# Purge and rewrite the product's SourceList registry entries so msiexec has
# nothing dangling left to concatenate against - the Microsoft-documented
# remediation for a stale SourceList entry. Registry-level, not COM, so it
# cannot silently no-op the way a late-bound SourceListClearAll can.
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

# Best-effort COM SourceList clear. Failure here never blocks the uninstall -
# Clear-MsiSourceListRegistry is the guaranteed path.
function Clear-MsiSourceList {
    param([string]$ProductCode)
    $installer = $null
    try {
        $installer = New-Object -ComObject WindowsInstaller.Installer
        $installer.GetType().InvokeMember(
            'SourceListClearAll', 'InvokeMethod', $null, $installer,
            @($ProductCode, '', 7)) | Out-Null
        Write-Log "Cleared stale SourceList for $ProductCode" 'INFO'
    }
    catch { }
    finally {
        if ($installer) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($installer) }
    }
}

# Repairs a blank/relative InstallLocation in the MSI UserData cache, which can
# feed an Error 1606 during costing.
#
# DELIBERATELY scoped to ONE product code and given the CALLER's own install
# root. The Revit script applies its equivalent to every matched MSI and stamps
# the core program folder into unrelated add-ins' registrations; passing the
# root in per product keeps that from happening here.
function Repair-MsiUserDataCache {
    param([string]$ProductCode, [string]$InstallRoot)
    if ([string]::IsNullOrWhiteSpace($InstallRoot)) { return }
    $squished = Get-MsiSquishedGuid -ProductCode $ProductCode
    if (-not $squished) { return }

    $msiHive = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData\S-1-5-18\Products\$squished\InstallProperties"
    if (-not (Test-Path -LiteralPath $msiHive)) { return }
    try {
        $il = Get-ItemProperty -Path $msiHive -Name 'InstallLocation' -ErrorAction SilentlyContinue
        $cur = Get-Prop $il 'InstallLocation'
        if ([string]::IsNullOrWhiteSpace($cur) -or $cur -notmatch '^([a-zA-Z]:[\\/]|\\\\)') {
            $fixPath = $InstallRoot.TrimEnd('\') + '\'
            Set-ItemProperty -LiteralPath $msiHive -Name 'InstallLocation' -Value $fixPath -ErrorAction Stop
            Write-Log "Patched MSI cache InstallLocation for $ProductCode`:`n      New: $fixPath" 'WARN'
        }
    }
    catch {
        Write-Log "Failed patching native cache InstallLocation: $($_.Exception.Message)" 'WARN'
    }
}

# Surgical Error-2753 remediation. "Internal Error 2753" means a custom action
# sourced from an INSTALLED FILE has a damaged component registration, and the
# whole uninstall aborts even though every other action would succeed. The
# cached package in C:\Windows\Installer cannot be edited in place (current
# Windows builds refuse transacted opens there even elevated), so this copies it
# to %TEMP%, conditions the named action out ('0' = never run) in the COPY, and
# returns the copy's path for the caller to recache and retry from.
function Repair-MsiBrokenCustomAction {
    param([string]$ProductCode, [string]$VerboseLog, [string]$PatchedMsi)

    if ([string]::IsNullOrWhiteSpace($VerboseLog) -or -not (Test-Path -LiteralPath $VerboseLog)) { return $null }
    if (-not (Select-String -Path $VerboseLog -Pattern 'Error 2753' -Quiet)) { return $null }

    $fail = Select-String -Path $VerboseLog -Pattern 'Action ended .*?: (.+)\. Return value 3\.' |
        Where-Object { $_.Matches[0].Groups[1].Value -ne 'INSTALL' } |
        Select-Object -First 1
    if (-not $fail) { return $null }
    $action = $fail.Matches[0].Groups[1].Value
    if ($action -match "'") { return $null }   # never build WI-SQL from an apostrophed name

    if (-not [string]::IsNullOrWhiteSpace($PatchedMsi) -and (Test-Path -LiteralPath $PatchedMsi)) {
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
        # during the /fv repair, source resolution probes SOURCEDIR +
        # <registered PackageName> and fails 2203/1316 otherwise. A per-run
        # subfolder keeps the name without colliding in %TEMP%.
        $patchDir = Join-Path $env:TEMP ('NavisCleanerPatch_' + $stamp)
        $target   = Join-Path $patchDir ([IO.Path]::GetFileName($localMsi))
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
        # 1 = msiOpenDatabaseModeTransact. DIRECT dispatch first: reflection
        # InvokeMember on Installer.OpenDatabase throws DISP_E_TYPEMISMATCH on
        # this PS 5.1 host where direct dispatch succeeds on identical arguments.
        $db = $null
        try { $db = $installer.OpenDatabase($target, 1) } catch { }
        if ($null -eq $db) {
            $db = $installer.GetType().InvokeMember('OpenDatabase', 'InvokeMethod', $null, $installer, @($target, 1))
        }
        # EVERY void COM call below is [void]-cast: direct-dispatch void methods
        # emit $null into the function's OUTPUT STREAM in PS 5.1, so without the
        # casts this function returns an ARRAY (nulls + path). Interpolating that
        # array space-joins it, msiexec receives /x "    C:\...msi", resolves it
        # as RELATIVE and fails 1619.
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
        # open in THIS process, and the immediately-following msiexec then fails
        # 1619 (0x80030020 STG_E_SHAREVIOLATION).
        foreach ($o in @($rec, $view1, $view2, $db, $installer)) {
            if ($null -ne $o) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($o) }
        }
        [GC]::Collect(); [GC]::WaitForPendingFinalizers(); [GC]::Collect()
    }
}

# Build an ordered list of uninstall attempts. If one fails the caller falls
# through to the next.
function Get-UninstallCandidates {
    param($Product)
    $list = @()

    if ($Product.WindowsInstaller -eq 1 -and $Product.KeyName -match '^\{[0-9A-Fa-f\-]{36}\}$') {

        $vlogBase = Join-Path $env:TEMP ("MSIVerbose_{0}_{1}" -f `
            ($Product.KeyName -replace '[{}]',''), (Get-Date -Format 'yyyyMMdd_HHmmss'))
        $vlogMsiLocalPath = $vlogBase + '_LocalPackage.log'
        $vlogMsiPath      = $vlogBase + '_MSI.log'
        $vlogMsiPropsPath = $vlogBase + '_PropsOverride.log'
        $vlogMsiLocal = ' /L*V "' + $vlogMsiLocalPath + '"'
        $vlogMsi      = ' /L*V "' + $vlogMsiPath + '"'
        $vlogMsiProps = ' /L*V "' + $vlogMsiPropsPath + '"'

        $localMsi = Get-MsiLocalPackage -ProductCode $Product.KeyName

        # UNCONDITIONAL: a 1606 concatenation happens off the ProductCode's
        # registered SourceList regardless of whether /x targets the bare
        # ProductCode or a LocalPackage path, so this runs before EVERY attempt.
        Show-MsiSourceListDump -ProductCode $Product.KeyName
        Clear-MsiSourceList -ProductCode $Product.KeyName
        Clear-MsiSourceListRegistry -ProductCode $Product.KeyName -LocalPackagePath $localMsi

        if ($localMsi) {
            $list += [pscustomobject]@{ File = 'msiexec.exe'; Args = "/x `"$localMsi`" /qn /norestart$vlogMsiLocal"; Kind = 'MSI-LocalPackage'; Vlog = $vlogMsiLocalPath }
        }

        $list += [pscustomobject]@{ File = 'msiexec.exe'; Args = "/x $($Product.KeyName) /qn /norestart$vlogMsi"; Kind = 'MSI'; Vlog = $vlogMsiPath }
        # Property-override attempt LAST: forcing directory properties on an
        # uninstall of an already-registered product can flip a component
        # condition out of the action sequence, which is what 2753 means.
        $list += [pscustomobject]@{ File = 'msiexec.exe'; Args = "/x $($Product.KeyName) /qn /norestart$FallbackDirProps$vlogMsiProps"; Kind = 'MSI-PropsOverride'; Vlog = $vlogMsiPropsPath }
    }

    # Vendor-provided silent command. Preferred for the NSIS-registered
    # Coordination Issues add-in, whose plain UninstallString has no /S and
    # would hang an unattended run on an interactive dialog.
    if (-not [string]::IsNullOrWhiteSpace($Product.QuietUninstallString)) {
        $s = Split-Command $Product.QuietUninstallString
        $list += [pscustomobject]@{ File = $s.File; Args = $s.Args; Kind = 'Quiet'; Vlog = $null }
    }

    if (-not [string]::IsNullOrWhiteSpace($Product.UninstallString)) {
        $raw = $Product.UninstallString
        if ($raw -match '(?i)msiexec') {
            # THE NAVISWORKS LANGUAGE-PACK TRAP. All 11 language packs per
            # product register UninstallString = "MsiExec.exe /I{GUID}" - the
            # INSTALL/repair verb. Running it verbatim REPAIRS the pack and
            # never uninstalls it, and the run then reports success. Coerce
            # /I -> /X; if the coercion cannot be proven (no GUID to anchor on)
            # the candidate is DROPPED rather than run, because the MSI branch
            # above has already synthesized a correct /x from the key name.
            $coerced = $raw -replace '(?i)/I(\s*\{[0-9A-Fa-f\-]{36}\})', '/X$1'
            if ($coerced -match '(?i)(^|\s)/I(\s|\{)') {
                Write-Log "Dropping '$($Product.DisplayName)' UninstallString: it carries the /I (install) verb and could not be coerced to /X - it would repair, not uninstall." 'WARN'
            }
            else {
                $raw = $coerced
                if ($raw -notmatch '(?i)/qn|/quiet') { $raw = "$raw /qn" }
                if ($raw -notmatch '(?i)/norestart') { $raw = "$raw /norestart" }
                $s = Split-Command $raw
                $list += [pscustomobject]@{ File = $s.File; Args = $s.Args; Kind = 'Fallback'; Vlog = $null }
            }
        }
        else {
            $s = Split-Command $raw
            if ($s.Args -notmatch '(?i)(^|\s)(--silent|-silent|/silent|/S|-q|/q)(\s|$)') {
                $list += [pscustomobject]@{ File = $s.File; Args = ($s.Args + ' --silent').Trim(); Kind = 'Silent'; Vlog = $null }
            }
            $list += [pscustomobject]@{ File = $s.File; Args = $s.Args; Kind = 'Fallback'; Vlog = $null }
        }
    }

    # De-duplicate, collapsing msiexec variants that target the same GUID. Only
    # plain "/x {guid}" invocations are GUID-collapsed: a candidate carrying
    # PROPERTY=value overrides is a functionally different command, and keying
    # it by GUID alone would silently delete MSI-PropsOverride from the list.
    $seen = @{}
    $unique = @()
    foreach ($c in $list) {
        $norm = ('{0} {1}' -f $c.File, $c.Args).ToLowerInvariant()
        $guid = [regex]::Match($norm, '\{[0-9a-f\-]{36}\}')
        if ($norm -match 'msiexec' -and $guid.Success -and $norm -notmatch '\s\w+=') { $key = 'msi:' + $guid.Value }
        else { $key = $norm }
        if (-not $seen.ContainsKey($key)) { $seen[$key] = $true; $unique += $c }
    }
    # Plain 'return $unique', NOT ',$unique'. The unary-comma wrapper double-nests
    # the array so the caller's foreach iterates once over the whole array,
    # collapsing all candidates into one object with array-valued properties ->
    # Start-Process gets an array for -FilePath and throws.
    return $unique
}

# --- Execution ------------------------------------------------------------
$successCodes = @(0, 1605, 3010)   # 1605 = "not installed" (already gone)
$rebootNeeded = $false
$failures     = 0
# Declines are tracked separately from failures. A product the operator skipped
# is still INSTALLED, so residual cleanup must not run against it - but it is
# not a failure either, and conflating the two would report exit 3 for a
# deliberate choice.
$skipped      = 0

foreach ($product in $targets) {

    # Gated on $WhatIfPreference as well as -Force: under -WhatIf the run has
    # already announced that nothing will be removed, and prompting there both
    # makes a preview interactive and lets a "No" silently drop the product from
    # the preview it was supposed to be showing.
    if (-not $Force -and -not $WhatIfPreference) {
        $answer = Read-Host "Uninstall '$($product.DisplayName)'? [Y/N]"
        if ($answer -notmatch '^(y|yes)$') {
            Write-Log "Skipped by user: $($product.DisplayName)" 'WARN'
            $skipped++
            continue
        }
    }

    if (-not $PSCmdlet.ShouldProcess($product.DisplayName, 'Uninstall')) {
        # A real decline ("No"/"No to All"), not a -WhatIf preview: the product
        # stays installed and must suppress residual cleanup.
        if (-not $WhatIfPreference) { $skipped++ }
        continue
    }

    # Consent first, registry surgery second: the SourceList dump/purge inside
    # Get-UninstallCandidates and the UserData patch below both WRITE to the
    # machine, so they must sit after the Read-Host / ShouldProcess gates.
    if ($product.WindowsInstaller -eq 1) {
        # Only the product's OWN install root, and only when this product is the
        # edition core rather than a language pack or add-in.
        $ownRoot = @($installs | Where-Object {
            $_.ProductCode -and $_.ProductCode -eq $product.KeyName
        } | ForEach-Object { $_.InstallRoot } | Select-Object -First 1)
        if ($ownRoot.Count -gt 0) {
            Repair-MsiUserDataCache -ProductCode $product.KeyName -InstallRoot $ownRoot[0]
        }
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
        # Bounded retry loop per method: a 1603 whose verbose log shows Internal
        # Error 2753 gets the broken custom action neutralized in a patched copy
        # and the uninstall retried from the recached package. Each attempt can
        # only surface one broken file-sourced action at a time, hence the loop.
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
                    # Defense in depth against output-stream pollution: keep only
                    # the last non-empty string (the returned path).
                    $patch = @($patch | Where-Object { $_ -is [string] -and -not [string]::IsNullOrWhiteSpace($_) }) |
                        Select-Object -Last 1
                    if ($patch) {
                        $caRepairs++
                        $patchedMsi = $patch
                        # Maintenance mode IGNORES the package path argument's
                        # tables - "Package we're running from ==>" is always the
                        # REGISTERED cache - so /x "<patched>.msi" never sees the
                        # neutralized condition. The supported route is a RECACHE
                        # repair: msiexec /fv <patched> replaces the registered
                        # cached package with ours (PackageCode unchanged), then a
                        # normal product-code /x runs from it.
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

# --- Coordination Issues add-in (conditional) -----------------------------
# Removed ONLY when no Navisworks edition of ANY year survives: it carries no
# year in its name and its payload folder holds v18 through v24, so it is
# genuinely still in use while another Navisworks remains.
if ($IncludeCoordinationIssuesAddin -and $failures -eq 0 -and $skipped -eq 0) {
    $remaining = @(Get-InstalledPrograms | Where-Object {
        $_.DisplayName -like '*Navisworks*' -and
        ($_.DisplayName -like '*Manage*' -or $_.DisplayName -like '*Simulate*' -or $_.DisplayName -like '*Freedom*')
    })
    if ($remaining.Count -gt 0) {
        Write-Log "Keeping the Coordination Issues add-in: $($remaining.Count) Navisworks edition entr(ies) still installed." 'WARN'
        $remaining | Sort-Object DisplayName -Unique | ForEach-Object { Write-Log "    - $($_.DisplayName)" }
    }
    else {
        $cia = @(Get-InstalledPrograms | Where-Object { $_.DisplayName -like '*Navisworks Coordination Issues*' })
        foreach ($c in $cia) {
            if (-not $PSCmdlet.ShouldProcess($c.DisplayName, 'Uninstall')) { continue }
            $cands = @(Get-UninstallCandidates -Product $c)
            $gone  = $false
            foreach ($cmd in $cands) {
                Write-Log "Uninstalling '$($c.DisplayName)' via $($cmd.Kind): $($cmd.File) $($cmd.Args)"
                try {
                    $p = if ([string]::IsNullOrWhiteSpace($cmd.Args)) {
                        Start-Process -FilePath $cmd.File -Wait -PassThru -WindowStyle Hidden
                    } else {
                        Start-Process -FilePath $cmd.File -ArgumentList $cmd.Args -Wait -PassThru -WindowStyle Hidden
                    }
                    if ($successCodes -contains $p.ExitCode) {
                        Write-Log "Removed '$($c.DisplayName)' (exit $($p.ExitCode))." 'OK'
                        $gone = $true
                        break
                    }
                }
                catch { Write-Log "Method '$($cmd.Kind)' threw: $($_.Exception.Message)" 'WARN' }
            }
            if (-not $gone) {
                Write-Log "Could not remove '$($c.DisplayName)'." 'ERROR'
                $failures++
            }
        }
    }
}

# --- Residual file cleanup ------------------------------------------------
# Hard safety guard. A path must:
#   - sit under a directory segment beginning with "Autodesk" (this admits the
#     Start Menu folder "...\Programs\Autodesk Navisworks Manage 2026", which
#     has no "\Autodesk\" segment of its own),
#   - reference Navisworks or a known exporter payload alias,
#   - contain the target year somewhere in the FULL path (the year often comes
#     from a parent directory, e.g. ...\Revit\Addins\2026\<bundle>),
#   - not be a drive root or a two-segment path,
#   - not sit under a forbidden shared root.
function Test-SafeResidualPath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    $full = $Path.TrimEnd('\', '/')

    # Drive root or one segment below it: never.
    if ($full -match '^[a-zA-Z]:\\?$') { return $false }
    if (($full -split '\\').Count -lt 3) { return $false }

    if (Test-PathUnderAny -Path $full -Roots $ForbiddenResidualRoots) {
        Write-Log "Refusing shared Autodesk tree: $full" 'WARN'
        return $false
    }

    if ($full -notmatch '(?i)\\Autodesk') {
        Write-Log "Refusing residual path outside an Autodesk tree: $full" 'WARN'
        return $false
    }

    $namesNavisworks = ($full -match '(?i)Navisworks') -or
                       ($full -match '(?i)nwexportrevit|revit_exporter|max_exporter')
    if (-not $namesNavisworks) {
        Write-Log "Refusing residual path that does not reference Navisworks: $full" 'WARN'
        return $false
    }

    if ($full -notmatch $ProductYear) {
        Write-Log "Refusing non-$ProductYear residual path: $full" 'WARN'
        return $false
    }

    # The exporters are preserved unless explicitly opted in, and their payload
    # is the single most damaging thing this script could delete by accident.
    if (-not $IncludeExporters -and $full -match '(?i)Navisworks Exporters|nwexportrevit|revit_exporter|max_exporter|Navisworks_Exporter') {
        Write-Log "Refusing exporter-owned path (use -IncludeExporters to remove it): $full" 'WARN'
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
        if (-not (Test-SafeResidualPath -Path $path)) { continue }

        # %APPDATA%\Autodesk\Navisworks <Edition> <year> holds USER-AUTHORED
        # content that no reinstall recreates: custom clash tests, property
        # sets, appearance profiles, avatars, workspaces. Say so explicitly
        # rather than calling it a "residual folder".
        $isUserContent = $path -like "$env:APPDATA*" -or $path -like "$([Environment]::GetFolderPath('CommonApplicationData'))*"
        if ($isUserContent -and $path -match '(?i)Navisworks (Manage|Simulate|Freedom)') {
            Write-Log "NOTE: '$path' contains authored content (custom clash tests, property sets, appearance profiles, workspaces) that a reinstall does NOT recreate." 'WARN'
        }

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
# Opt-in and doubly gated: the version key must have been PROVEN from the
# registry, and only the "<major>.0" leaf is ever removed. The parent container
# ("Navisworks Manage", "Navisworks API Runtime") is shared with other years and
# other SKUs and is never touched.
function Remove-ResidualRegistryKeys {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param($Installs)

    $removed = 0
    foreach ($i in $Installs) {
        $keys = @(
            "HKLM:\SOFTWARE\Autodesk\Navisworks $($i.Edition)\$($i.VersionKey)",
            "HKCU:\SOFTWARE\Autodesk\Navisworks $($i.Edition)\$($i.VersionKey)",
            "HKLM:\SOFTWARE\Autodesk\Navisworks API Runtime\$($i.Major)\Navisworks $($i.Edition)"
        )
        foreach ($k in $keys) {
            if (-not (Test-Path -LiteralPath $k)) { continue }

            # Shape guard: refuse anything that is not a version leaf under a
            # Navisworks brand key, and refuse the Exporters tree outright.
            if ($k -match '(?i)Navisworks Exporters') {
                Write-Log "Refusing exporter-owned registry key: $k" 'WARN'
                continue
            }
            if ($k -notmatch '(?i)\\Autodesk\\Navisworks [A-Za-z ]+\\(\d+\.0|\d+\\Navisworks [A-Za-z]+)$') {
                Write-Log "Refusing unexpected registry key shape: $k" 'WARN'
                continue
            }

            if (-not $Force -and -not $WhatIfPreference) {
                $answer = Read-Host "Delete registry key '$k'? [Y/N]"
                if ($answer -notmatch '^(y|yes)$') {
                    Write-Log "Kept registry key: $k" 'WARN'
                    continue
                }
            }

            if ($PSCmdlet.ShouldProcess($k, 'Remove registry key')) {
                try {
                    Remove-Item -LiteralPath $k -Recurse -Force -ErrorAction Stop
                    Write-Log "Deleted registry key: $k" 'OK'
                    $removed++
                }
                catch {
                    Write-Log "Failed to delete '$k': $($_.Exception.Message)" 'ERROR'
                }
            }
        }
    }
    return $removed
}

# Both warnings are gated on cleanup actually having been ASKED for. Announcing
# "Skipping residual cleanup" to an operator who ran -RemoveResidualFiles:$false
# and never passed -RemoveResidualRegistry describes a step that was never
# scheduled, and sends them hunting for a failure that is really just their own
# command line.
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
        Write-Log "Scanning for Navisworks $ProductYear residual locations..."
        $null = Remove-ResidualFiles -Paths $ResidualPaths
    }
    if ($RemoveResidualRegistry) {
        if ($installs.Count -eq 0) {
            Write-Log 'Registry cleanup requested but no version key was proven from the registry - skipping rather than guessing.' 'WARN'
        }
        else {
            Write-Log 'Removing version-scoped registry keys...'
            $null = Remove-ResidualRegistryKeys -Installs $installs
        }
    }
}

# --- Summary --------------------------------------------------------------
Write-Log '---------------------------------------------'
if ($failures -eq 0) {
    if ($skipped -gt 0) {
        Write-Log "Completed with $skipped product(s) declined and still installed." 'WARN'
    }
    else {
        Write-Log 'Completed. Shared Autodesk components were preserved.' 'OK'
    }
    if (-not $IncludeExporters) {
        Write-Log 'Navisworks Exporters were preserved - NWC export from Revit/AutoCAD/3ds Max still works.' 'OK'
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
