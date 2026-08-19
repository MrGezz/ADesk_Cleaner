<#
.SYNOPSIS
    Uninstalls selected Adobe products on Windows - you choose which ones - by
    driving Adobe's own HyperDrive uninstaller, and removes only the residue
    that belongs to the products actually removed.

.DESCRIPTION
    Discovers every Adobe product registered on the machine, classifies each one
    as an APPLICATION or a SHARED COMPONENT, lets you pick what to remove, and
    then invokes the vendor's registered uninstall command verbatim. Every
    destructive step is discovery-driven and evidence-gated: nothing is removed
    on the strength of a name alone.

    THE CENTRAL ADOBE FACT, and the reason this script shares almost no code
    with the Autodesk uninstallers in this repo:

        AN ADOBE CREATIVE CLOUD PRODUCT IS NOT AN MSI. There is no ProductCode,
        no cached .msi, no msiexec route, and nothing in
        HKLM:\SOFTWARE\Classes\Installer\Products. Every product delegates to a
        single shared broker:

            "...\Common Files\Adobe\Adobe Desktop Common\HDBox\Uninstaller.exe"
              --uninstall=1 --sapCode=PHSP --productVersion=26.6.1
              --productPlatform=win64 --productAdobeCode={PHSP-26.6.1-64-ADBE...}
              --productName="Photoshop" --mode=1

        The four-letter --sapCode is the product's real identity. This script
        selects on it, reports on it, and takes it from the registry - it never
        reconstructs that command line, because --productAdobeCode is a
        per-product literal whose ADBEADBE padding length varies with the SAP
        code and version string and cannot be derived.

    Six Adobe-specific traps this script is built around:

    1. THE PRODUCTS ARE INVISIBLE TO A NORMAL REGISTRY SWEEP. Verified on this
       platform: all 12 Adobe rows live in the 32-bit view
       (HKLM:\SOFTWARE\WOW6432Node\...\Uninstall) - including the win64
       applications - and the native 64-bit hive holds ZERO. Worse, 9 of the 12
       carry NO DisplayName value at all; they are hidden from Add/Remove
       Programs by having no name rather than by SystemComponent=1. A sweep
       filtered on "DisplayName -like '*Adobe*'" finds two products and silently
       leaves ten installed. This script keys on Publisher and on the
       UninstallString's own --sapCode, and synthesizes a label from
       --productName when DisplayName is absent.

    2. EXIT CODE 130 IS A REFUSAL, NOT A FAILURE. The HyperDrive engine
       refcounts shared components: asked to remove one that another installed
       product still references, it returns 130 and correctly declines. This
       machine's own C:\ProgramData\Adobe\Installer\Summary.htm already records
       a 130 from a previous attempt. A script that treats non-zero as failure
       and escalates to deleting the files by hand destroys a runtime that the
       surviving applications still need - the same hazard as removing
       RealDWG Shared out from under Revit. 130 is reported here as
       "skipped, still referenced" and counted as success.

    3. THE EXIT CODE IS NOT THE AUTHORITY; THE REGISTRY IS. Uninstaller.exe is a
       thin shim that hands the real work to HDPIM.dll and, when Creative Cloud
       Desktop is present, to a GUI over a named pipe - so the process can
       return before, or independently of, the outcome. Every product is
       therefore verified by re-reading its uninstall key afterwards. Key gone =
       removed, whatever the code said; key still present = not removed,
       whatever the code said.

    4. INSTALLLOCATION IS A SHARED PARENT, AND DELETING IT DESTROYS THE
       UNINSTALLER. Verified on this platform: seven of the twelve rows declare
       an InstallLocation of "C:\Program Files (x86)\Common Files\Adobe" or its
       64-bit twin - not a per-product folder. That first path is the directory
       that CONTAINS Adobe Desktop Common\HDBox\Uninstaller.exe. A cleanup loop
       that deletes each removed row's InstallLocation would, on Camera Raw,
       delete the tool needed to remove everything else. This script never
       derives a deletion target from InstallLocation.

    5. THE APPLICATIONS BLOCK THEIR OWN UNINSTALL, DELIBERATELY. Photoshop and
       Illustrator are declared in Adobe's conflicting-process metadata with
       forceKillAllowed="false" - Adobe's engine will refuse rather than kill
       them, because the user may have unsaved work. Running the uninstall with
       them open produces an opaque failure. This script pre-flights for them
       and stops with a list, and only closes them when you pass -StopAdobe,
       which asks each window to close before forcing it.

    6. FILE ATTRIBUTION BY CompanyName IS UNSAFE IN BOTH DIRECTIONS HERE.
       Measured across 645 binaries under the Adobe roots on this platform:
       "Adobe" is spelled EIGHT different ways ("Adobe", "Adobe Inc.",
       "Adobe Inc" with no period, "Adobe Systems Incorporated", "Adobe, Inc.",
       "Adobe " with a trailing space, "Adobe.", "Adobe Systems, Incorporated"),
       114 files carry no CompanyName at all - including CoreSync.exe and
       CCXProcess.exe, the two most visible background processes - and 57 DLLs
       inside Adobe Illustrator 2025 report "Autodesk, Inc." because Illustrator
       ships AutoCAD's ObjectDBX libraries. In a repo that also ships Autodesk
       uninstallers, that cuts both ways. Residual removal here is authorized by
       PATH CONTAINMENT under a verified Adobe root, never by a per-file vendor
       string.

    Removal order, which is not negotiable:

        1. Census and classification   (nothing is mutated)
        2. Selection                   (-Product / -All / interactive menu)
        3. Running-application guard   (Adobe refuses to kill these itself)
        4. Capture Adobe's own install/uninstall metadata into the log folder
        5. Applications, one at a time, each verified against the registry
        6. Shared components           (opt-in; 130 is the expected answer
                                        while any application survives)
        7. Per-product residual folders of the products actually removed
        8. Vendor-wide residue         (only once NO Adobe row remains)
        9. Shell extensions / COM      (opt-in)
       10. Residual registry           (opt-in)

    Re-runnability is a design requirement, not a nicety. Shared components stay
    refcounted until the last application referencing them is gone, so removing
    one application of two legitimately leaves shared runtimes in place. Re-run
    the script after removing the last one to reclaim them. Every step is
    idempotent and treats "already gone" as success.

.PARAMETER Product
    Which products to uninstall. Accepts SAP codes (PHSP, ILST, ACRO), display
    names or fragments ("Photoshop", "Illustrator 2025"), case-insensitively,
    and any mixture. Each value must match exactly one discovered product or the
    run aborts with the list of valid choices - an ambiguous or unknown selector
    is never resolved by guessing.

    Omit it, and with -All absent you get an interactive numbered menu of the
    applications found. Omit it under -Force and the run aborts rather than
    assume you meant everything.

.PARAMETER All
    Uninstall every discovered Adobe APPLICATION. Shared components are still
    excluded unless -IncludeSharedComponents is also passed. This is the
    unattended equivalent of choosing "A" at the menu.

.PARAMETER IncludeSharedComponents
    Also attempt the shared runtimes and support packages - Camera Raw, CoreSync,
    CCX Process, the colour-profile bundles, UXP WebView Support and the like.
    Off by default.

    These are refcounted by Adobe's engine, so this is safe rather than
    dangerous: a component another product still needs answers 130 and is left
    alone. It is off by default only because attempting them while any
    application survives is normally a no-op that fills the log with refusals.
    Pass it on the final pass, after the last Adobe application is gone.

.PARAMETER RemoveUserData
    Opt-in. Also delete Adobe user data: %APPDATA%\Adobe, %LOCALAPPDATA%\Adobe,
    %APPDATA%\..\LocalLow\Adobe and C:\ProgramData\Adobe\CameraRaw.

    Note what this contains. On this platform ProgramData\Adobe\CameraRaw alone
    is 2.24 GB and holds the Settings and SaveOptions folders - user-authored
    Camera Raw presets - alongside the shipped camera and lens profiles.
    Roaming\Adobe holds Illustrator and Photoshop workspaces, actions, brushes
    and installed fonts. None of it is reinstalled by reinstalling the product.

    Separately, and regardless of this switch: Adobe's own uninstall workflow
    sets deleteUserPreferences=true internally, and exposes no flag to turn that
    off. Application preferences are discarded by the vendor uninstaller itself.

.PARAMETER RemoveShellExtensions
    Opt-in. Remove the Explorer integration Adobe's CoreSync registers: the
    context-menu handlers and the icon-overlay identifiers.

    These do not carry the word "Adobe" anywhere. They are registered as
    "AccExt" and as three overlay entries whose value names begin with THREE
    LEADING SPACES (" AccExtIco1" and siblings, a sort-priority hack). Every
    candidate is resolved through its CLSID to the DLL path on disk and removed
    only when that path lies under an Adobe root - never by the handler name.
    Explorer holds CoreSync_x64.dll open, so the DLL itself is left for the
    residual sweep or the next reboot.

.PARAMETER RemoveResidualFiles
    After a successful uninstall, delete what the vendor uninstaller left behind:
    the removed products' own program folders and Start Menu shortcuts, and -
    only once NO Adobe product remains registered - the vendor-wide plumbing
    under Common Files\Adobe and ProgramData\Adobe. Default: $true.

    A runtime guard permits a deletion only under a path carrying an Adobe
    segment, and refuses drive roots, top-level system containers and any path
    with fewer than three segments.

.PARAMETER RemoveResidualRegistry
    Opt-in. Also delete the configuration keys HKLM:\SOFTWARE\Adobe,
    HKLM:\SOFTWARE\WOW6432Node\Adobe and HKCU:\SOFTWARE\Adobe, plus the App
    Paths entries and the adobe+ilst / adobe+phxs URL protocol handlers.
    Off by default, and skipped entirely while any Adobe product is still
    registered.

.PARAMETER StopAdobe
    Close running Adobe applications before uninstalling. Each window is asked
    to close first and only forced after it declines, because Adobe's own engine
    refuses to force-kill Photoshop and Illustrator precisely to protect unsaved
    work. Without this switch the script stops and lists what is running.

.PARAMETER ListOnly
    Run the full census, print every discovered product with its SAP code and
    classification, and exit. Performs no changes. This is the safety gate; run
    it first, and use its SAP codes as -Product arguments.

.PARAMETER Force
    Fully non-interactive: skips the per-item Read-Host prompts AND suppresses
    PowerShell's built-in ShouldProcess confirmation. Requires -Product or -All,
    because there is no menu to answer.

.PARAMETER LogPath
    Full path for the transcript log. Defaults to
    %TEMP%\Uninstall-Adobe_<timestamp>.log

.EXAMPLE
    # Preview everything that would be removed, change nothing. Start here -
    # the SAP codes it prints are what -Product takes:
    powershell -ExecutionPolicy Bypass -File .\Uninstall-Adobe.ps1 -ListOnly

.EXAMPLE
    # Interactive: pick products from a numbered menu, prompt before each step:
    powershell -ExecutionPolicy Bypass -File .\Uninstall-Adobe.ps1

.EXAMPLE
    # Remove one product by SAP code, unattended:
    powershell -ExecutionPolicy Bypass -File .\Uninstall-Adobe.ps1 -Product PHSP -StopAdobe -Force

.EXAMPLE
    # Two products by name; -Product matches display names as well as SAP codes:
    powershell -ExecutionPolicy Bypass -File .\Uninstall-Adobe.ps1 -Product Photoshop,Illustrator -StopAdobe -Force

.EXAMPLE
    # Every application, then re-run to reclaim the shared runtimes that were
    # still refcounted during the first pass:
    powershell -ExecutionPolicy Bypass -File .\Uninstall-Adobe.ps1 -All -StopAdobe -Force
    powershell -ExecutionPolicy Bypass -File .\Uninstall-Adobe.ps1 -All -IncludeSharedComponents -Force

.EXAMPLE
    # Full wipe including user presets, workspaces and the Camera Raw library:
    powershell -ExecutionPolicy Bypass -File .\Uninstall-Adobe.ps1 -All -IncludeSharedComponents -RemoveUserData -RemoveShellExtensions -RemoveResidualRegistry -StopAdobe -Force

.EXAMPLE
    # Turning OFF the one [bool] parameter needs -Command, not -File.
    # powershell.exe -File passes every argument as a literal string, and a
    # [bool] parameter rejects the string "$false" outright. Measured: no -File
    # form works - not :$false, not :0. This is the only shape that binds:
    powershell -ExecutionPolicy Bypass -Command "& '.\Uninstall-Adobe.ps1' -RemoveResidualFiles:$false -Product PHSP"

.NOTES
    Requires an elevated (Administrator) session; the script self-elevates.
    Exit code 0 = success, 3010 = success (reboot required), 3 = partial failure,
    2 = nothing found, 1 = aborted.

    Every switch is [switch] rather than [bool] specifically so that it binds
    under "powershell.exe -File", which is how every example in this repo is
    written. Pass them bare - "-Force" style - not as "-RemoveUserData:$true".

    THE ADOBE CREATIVE CLOUD CLEANER TOOL IS NEVER INVOKED, and this script will
    not download it. It is a blunt instrument that strips shared components other
    Adobe products still depend on. When the supported path fails, the script
    stops and points at Adobe's own log
    (Common Files\Adobe\Installers\Install.log, which is UTF-16LE) so you can
    decide whether to reach for it yourself.

    NO WINSOCK, WFP, HOSTS-FILE OR PDF-ASSOCIATION CHANGES ARE MADE. In
    particular the script never writes to HKCR\.pdf or to
    ...\Explorer\FileExts\.pdf\UserChoice: after a PDF handler is removed
    Windows falls back to the remaining registered handlers on its own, and
    hand-editing UserChoice is what leaves a machine with no working PDF
    association at all.

    Uninstalling does NOT deactivate your Adobe license or free a seat on a
    named-user plan. Sign out in the Creative Cloud desktop app first, or
    deactivate at account.adobe.com, if that is what you need.

    This tool is not affiliated with or endorsed by Adobe. "Adobe",
    "Photoshop", "Illustrator", "Acrobat", "Camera Raw" and "Creative Cloud" are
    trademarks of Adobe Inc.
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    # Selection. [string[]] binds fine under -File as a comma-separated list.
    [string[]]$Product,
    [switch]$All,
    [switch]$IncludeSharedComponents,
    # The OPT-INS are [switch], not [bool], and that is deliberate:
    # "powershell.exe -File" passes every argument as a literal STRING, and a
    # [bool] parameter's argument transformation rejects the string "$true" with
    # "Boolean parameters accept only Boolean values and numbers". Measured: NO
    # -File form binds a [bool] - not :$true, not :1, not :0, not :true. Since
    # these are the parameters an operator actually types, they must work with
    # the -File invocation every example in this repo uses.
    [switch]$RemoveUserData,
    [switch]$RemoveShellExtensions,
    [switch]$RemoveResidualRegistry,
    # This one stays [bool] because it defaults ON and is only ever passed to
    # turn a removal OFF, which is rare. Doing so needs the -Command form - see
    # the .NOTES block.
    [bool]$RemoveResidualFiles = $true,
    [switch]$StopAdobe,
    [switch]$ListOnly,
    [switch]$Force,
    [string]$LogPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# -Force implies fully non-interactive: suppress PowerShell's own ShouldProcess
# confirmation (ConfirmImpact=High would otherwise prompt "Are you sure?" for
# every item even under -Force).
if ($Force) { $ConfirmPreference = 'None' }

# Resolve -LogPath to a ROOTED path immediately, before anything consumes it.
# A bare filename has no parent directory, and any later Split-Path -Parent on
# it throws under $ErrorActionPreference='Stop' - after products have already
# been removed. This runs BEFORE self-elevation on purpose: the relay forwards
# -LogPath to the elevated child, whose working directory is not the operator's.
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

# Publisher is the reliable discovery axis. Verified on this platform: all 12
# Adobe rows carry Publisher='Adobe Inc.' while 9 of them carry no DisplayName
# at all, so a DisplayName filter finds a quarter of the footprint. The second
# route - an UninstallString that names the HyperDrive broker - catches a row
# whose Publisher is missing or has been rewritten by a repackager.
$PublisherPattern     = '*Adobe*'
$HdUninstallerPattern = '(?i)HDBox\\Uninstaller\.exe'

# SAP codes that are shared components rather than applications, used to
# CORROBORATE the structural classification below - never as the sole test, so a
# machine carrying a product not in this list still classifies correctly.
#   ACR  Camera Raw                     CCXP Creative Cloud Experience process
#   COSY CoreSync                       SEPS Substance 3D Viewer for Photoshop
#   UXPW UXP WebView Support            UNPP unlicensed-popup blocker
#   CORE/CORG/COCM/COPS  colour-profile bundles (not applications, despite
#                        being flagged visible in Adobe's own database)
$KnownSharedSapCodes = @(
    'ACR', 'CCXP', 'COSY', 'SEPS', 'UXPW', 'UNPP',
    'CORE', 'CORG', 'COCM', 'COPS',
    'LIBS', 'CCDA', 'KCCC', 'ADCH', 'AUDDEV', 'ACCC'
)

# SAP codes that may only be removed once a RUNTIME GUARD has cleared them.
# CCXP is here for a specific measured reason: its conflicting-process metadata
# claims node.exe, and Adobe's engine force-kills what it claims. On a developer
# workstation that is every unrelated Node process on the machine - measured at
# 36 on this one.
#
# It is GUARDED, NOT FORBIDDEN, and that distinction was learned the hard way.
# An earlier revision refused CCXP outright. That created a dead end: nothing
# else references CCXP, so refcounting never reclaims it either, so it stayed
# registered forever - and the vendor-wide sweep, which is gated on NO Adobe
# product remaining, could then never run. A machine whose Adobe applications
# were all gone was left with ~620 MB of shared plumbing that no invocation of
# this script could ever remove. A guard the operator can satisfy is correct;
# a refusal they cannot is a bug.
$GuardedSapCodes = @('CCXP')

# Application process names. These may be matched by BARE NAME because nothing
# else on a Windows machine ships them.
$AdobeOwnProcessNames = @(
    'Photoshop', 'Illustrator', 'InDesign', 'InCopy', 'AfterFX', 'Adobe Premiere Pro',
    'Adobe Media Encoder', 'Adobe Audition', 'Adobe Bridge', 'Bridge', 'Animate',
    'Dreamweaver', 'Adobe Lightroom', 'Lightroom', 'lightroom', 'Acrobat', 'AcroRd32',
    'AcroCEF', 'RdrCEF', 'Adobe Substance 3D Painter', 'Adobe Substance 3D Designer',
    'CCXProcess', 'CoreSync', 'AdobeIPCBroker', 'CRWindowsClientService',
    'AdobeNotificationClient', 'Creative Cloud', 'Adobe Desktop Service',
    'AdobeGCClient', 'AdobeGCInvoker', 'AGSService', 'AGMService',
    'Adobe Crash Processor', 'CRLogTransport', 'LogTransport2', 'AdobeUpdateService',
    'armsvc', 'Adobe CEF Helper'
)

# THESE NAMES COLLIDE and are terminated ONLY when the running image resolves to
# a path under a discovered Adobe root. node.exe is the one that matters: Adobe's
# CCXProcess embeds a Node runtime, and a bare-name kill would take every
# unrelated Node process on a developer's machine with it.
$PathScopedProcessNames = @(
    'node', 'uninstall', 'Setup', 'Set-up', 'HDHelper', 'setup'
)

# Applications Adobe's own engine declares forceKillAllowed="false" - it refuses
# to kill them rather than risk unsaved work, and the uninstall fails opaquely
# instead. Reported by name so the operator knows exactly what to close.
$BlockingProcessNames = @(
    'Photoshop', 'Illustrator', 'InDesign', 'InCopy', 'AfterFX', 'Bridge',
    'Adobe Bridge', 'Adobe Premiere Pro', 'Acrobat'
)

# Vendor directory roots residual cleanup may consider. Every one is guarded by
# Test-Path at use, because on a given machine most do not exist: verified on
# this platform, ProgramData\Adobe\SLStore, ProgramData\Adobe\ARM,
# ProgramData\Adobe\caps and the AdobeGCClient folder are all ABSENT, yet most
# published Adobe removal scripts assume them and throw on the first one.
$VendorRootNames = @('Adobe')

# Roots that may NEVER be handed to Remove-Item, no matter what the census says.
# Built by string join rather than Join-Path, which throws on a null -Path when
# an environment variable is undefined on a given SKU.
$ForbiddenResidualRoots = @(
    ${env:ProgramFiles},
    ${env:ProgramFiles(x86)},
    ${env:ProgramData},
    ${env:SystemRoot},
    (@(${env:ProgramFiles},      'Common Files') -join '\'),
    (@(${env:ProgramFiles(x86)}, 'Common Files') -join '\'),
    (@(${env:SystemRoot}, 'System32')            -join '\'),
    (@(${env:SystemDrive}, 'Users')              -join '\')
) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

# HyperDrive uninstaller exit codes.
#   0   success
#   130 the product is a shared component another installed product still
#       references. A REFUSAL, and the expected answer while any application
#       survives - never escalated to a manual delete.
$HdSuccessCodes    = @(0)
$HdStillReferenced = 130

# MSI exit codes that count as success, for the Acrobat/Reader route only.
# 1605 = "not installed" (already gone), 3010 = success, reboot required.
$MsiSuccessCodes = @(0, 1605, 3010)

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

    # An interactive menu cannot survive the UAC boundary usefully - the elevated
    # child owns a different console window, and on some configurations the
    # operator never sees it. Refuse early with an actionable instruction rather
    # than launching a child that silently waits for input nobody can give.
    if (-not $ListOnly -and -not $All -and (-not $Product -or $Product.Count -eq 0)) {
        Write-Host 'Refusing to elevate into an interactive menu: the elevated child gets its own console and you may never see the prompt.' -ForegroundColor Red
        Write-Host 'Run -ListOnly first to see the SAP codes, then re-run with -Product <CODE> or -All. Or start an elevated PowerShell and run this script there.' -ForegroundColor Yellow
        exit 1
    }

    # Build the relaunch command line as a SINGLE string, not an array.
    # Start-Process re-quotes array elements in Windows PowerShell 5.1 and
    # mangles a script path that contains spaces, which silently breaks
    # self-elevation.
    $passArgs = @()
    $passArgs += ('-RemoveResidualFiles:${0}' -f $RemoveResidualFiles)
    if ($Product -and $Product.Count -gt 0) {
        $quoted = @($Product | ForEach-Object { "'" + ($_ -replace "'", "''") + "'" })
        $passArgs += ('-Product ' + ($quoted -join ','))
    }
    if ($All)                     { $passArgs += '-All' }
    if ($IncludeSharedComponents) { $passArgs += '-IncludeSharedComponents' }
    if ($RemoveUserData)          { $passArgs += '-RemoveUserData' }
    if ($RemoveShellExtensions)   { $passArgs += '-RemoveShellExtensions' }
    if ($RemoveResidualRegistry)  { $passArgs += '-RemoveResidualRegistry' }
    if ($StopAdobe)               { $passArgs += '-StopAdobe' }
    if ($ListOnly)                { $passArgs += '-ListOnly' }
    if ($Force)                   { $passArgs += '-Force' }

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
    $LogPath = Join-Path $env:TEMP "Uninstall-Adobe_$stamp.log"
}
# -WhatIf:$false is deliberate. Start-Transcript is itself ShouldProcess-aware,
# so under -WhatIf it PREVIEWS instead of opening the log, and the run then ends
# by announcing "Log saved to: <path>" for a file that was never written.
try { Start-Transcript -Path $LogPath -Append -WhatIf:$false | Out-Null } catch { }

# Preload CimCmdlets while the preview flag is switched off in a child scope.
# The service and process checks autoload this module; if that happens mid
# -WhatIf run, the module's own top-level Set-Alias calls inherit
# $WhatIfPreference and spray "What if: Performing the operation Set Alias"
# lines into the middle of the report.
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
Write-Log "Adobe uninstall started. Log: $LogPath"
Write-Log ("Mode: {0}{1}{2}{3}{4}{5}" -f `
    $(if ($WhatIfPreference) { 'PREVIEW ' } else { '' }),
    $(if ($ListOnly) { 'ListOnly ' } else { 'Uninstall ' }),
    $(if ($IncludeSharedComponents) { '+Shared ' } else { '' }),
    $(if ($RemoveResidualFiles) { '+Residual ' } else { '' }),
    $(if ($RemoveUserData) { '+UserData ' } else { '' }),
    $(if ($Force) { 'Force' } else { 'Interactive' }))

if ($RemoveUserData) {
    Write-Log 'NOTE: -RemoveUserData deletes Adobe user data - Camera Raw presets, Illustrator/Photoshop workspaces, actions, brushes and installed fonts. None of it is restored by reinstalling the product.' 'WARN'
}

# EVERY native command in this script goes through this, never through a bare
# "& reg.exe ... 2>&1". In Windows PowerShell 5.1, redirecting a native
# command's stderr with 2>&1 while $ErrorActionPreference is 'Stop' promotes any
# stderr line to a TERMINATING NativeCommandError. Both reg.exe and the Adobe
# binaries write ordinary informational text to stderr, so a bare call would
# abort the run mid-removal. The preference is lowered in FUNCTION scope (it
# does not leak back out) and the exit code is returned for the caller.
function Invoke-NativeCommand {
    param([string]$FilePath, [string[]]$Arguments)

    $ErrorActionPreference = 'Continue'
    $out  = @()
    $code = -1
    try {
        $out  = & $FilePath @Arguments 2>&1
        $code = $LASTEXITCODE
    }
    catch {
        Write-Log "      $FilePath could not be started: $($_.Exception.Message)" 'WARN'
        return [pscustomobject]@{ ExitCode = -1; Output = @() }
    }
    foreach ($line in $out) {
        $t = [string]$line
        if (-not [string]::IsNullOrWhiteSpace($t)) { Write-Log "      $t" }
    }
    return [pscustomobject]@{ ExitCode = $code; Output = $out }
}

# --- Shared primitives ----------------------------------------------------
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

# StrictMode-safe recursive size, in bytes. Returns 0, never throws.
#
# THE IDIOM THIS REPLACES IS A TRAP. Measure-Object emits NOTHING when its input
# is empty - not a zero-valued object - so the everyday
# "(Get-ChildItem -Recurse -File | Measure-Object -Property Length -Sum).Sum"
# dereferences $null and throws PropertyNotFoundException under StrictMode the
# moment it meets an EMPTY folder. Measured: that is precisely what left an empty
# legacy metadata folder undeleted, because the throw happened before its
# Remove-Item and a surrounding catch swallowed it - a silent, size-dependent
# failure that only ever bites on the empty case.
#
# Adobe ships empty folders in the normal course of business: verified on this
# platform, "Common Files\Adobe\Adobe Unlicensed Pop-up Blocker" contains zero
# files and "Common Files\Adobe\SLCache" is completely empty.
function Get-PathSize {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return 0 }
    if (-not (Test-Path -LiteralPath $Path)) { return 0 }
    $measured = $null
    try {
        $measured = Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue |
            Measure-Object -Property Length -Sum
    }
    catch { return 0 }
    if ($null -eq $measured) { return 0 }
    $sum = Get-Prop $measured 'Sum'
    if ($null -eq $sum) { return 0 }
    return [long]$sum
}

# Normalize a directory path for comparison: trim quotes and trailing
# separators, collapse doubled separators, lower-case it.
function Get-ComparablePath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    $p = $Path.Trim().Trim('"')

    # 8.3 SHORT NAMES MUST BE EXPANDED BEFORE ANY COMPARISON. %TEMP% on this
    # platform is "C:\Users\ICECRE~1\AppData\Local\Temp" while Get-ChildItem
    # reports "C:\Users\IceCreamAssasin\...", so two references to the SAME file
    # compare unequal as strings. Measured: that silently defeated the guard
    # protecting the in-progress transcript from the log-retention sweep - a
    # protection that appeared to work and did nothing.
    #
    # [IO.Path]::GetFullPath expands 8.3 components; Resolve-Path and
    # Scripting.FileSystemObject both return the short form unchanged and are no
    # use here. It is applied only to rooted filesystem paths - a registry
    # PSPath must never be handed to it - and any failure falls through to the
    # unexpanded string rather than throwing.
    if ($p -match '^[a-zA-Z]:\\' -or $p -match '^\\\\[^\\]') {
        try { $p = [IO.Path]::GetFullPath($p) } catch { }
    }

    # Collapse doubled separators, but preserve a leading UNC "\\" - stripping it
    # turns \\server\share into a bogus local path \server\share.
    $prefix = ''
    if ($p.StartsWith('\\')) { $prefix = '\\'; $p = $p.Substring(2) }
    $p = $p -replace '\\{2,}', '\'

    return ($prefix + $p).TrimEnd('\', '/').ToLowerInvariant()
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

# Enumerate real user profile directories. C:\Users is FULL of reparse points -
# verified on this platform, "IcZ" is a symbolic link to the one real profile,
# "All Users" is a symbolic link to C:\ProgramData and "Default User" is a
# junction to Default. A per-profile loop that does not filter these walks into
# ProgramData under an Adobe-shaped path and processes the same profile twice.
function Get-RealUserProfileDirectories {
    $userRoot = Join-Path ${env:SystemDrive} 'Users'
    if (-not (Test-Path -LiteralPath $userRoot)) { return @() }
    return @(Get-ChildItem -LiteralPath $userRoot -Directory -Force -ErrorAction SilentlyContinue |
        Where-Object { -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) })
}

# --- Product discovery ----------------------------------------------------
# NOT the repo's shared Get-InstalledPrograms. That helper discards every row
# with no DisplayName, which on this platform is 9 of the 12 Adobe rows - it
# would report Photoshop, Illustrator and UXP WebView Support and silently miss
# Camera Raw, CoreSync, the colour bundles and the rest. This variant keeps
# nameless rows and synthesizes a label from the uninstall command's own
# --productName argument.
function Get-AdobeProducts {
    $hives = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
    )

    foreach ($hive in $hives) {
        if (-not (Test-Path $hive)) { continue }

        # Per-hive counts are logged by the caller. Distinguishing "enumerated
        # successfully, found none" from "enumeration failed" matters: a
        # 64-bit-only view returns zero Adobe rows on a machine that is full of
        # them, and reporting that as "nothing installed" is the single most
        # likely way this script does nothing while appearing to succeed.
        Get-ChildItem -Path $hive -ErrorAction SilentlyContinue | ForEach-Object {
            $props = $null
            try { $props = Get-ItemProperty -LiteralPath $_.PsPath -ErrorAction Stop } catch { return }

            $displayName = Get-Prop $props 'DisplayName'
            $publisher   = Get-Prop $props 'Publisher'
            $uninstall   = Get-Prop $props 'UninstallString'

            # Two independent attribution routes, OR-ed. Publisher is the strong
            # one and is present on every Adobe row measured here; the broker
            # path catches a row whose Publisher a repackager stripped.
            $isAdobe = $false
            if ((-not [string]::IsNullOrWhiteSpace($publisher)) -and ($publisher -like $PublisherPattern)) { $isAdobe = $true }
            if ((-not $isAdobe) -and (-not [string]::IsNullOrWhiteSpace($uninstall)) -and ($uninstall -match $HdUninstallerPattern)) { $isAdobe = $true }
            if (-not $isAdobe) { return }

            # Parse the HyperDrive argument grammar. These are read for IDENTITY
            # and REPORTING only - the command line itself is replayed verbatim,
            # never rebuilt, because --productAdobeCode is a per-product literal
            # whose padding cannot be derived.
            $sapCode     = ''
            $prodVersion = ''
            $prodName    = ''
            $platform    = ''
            if (-not [string]::IsNullOrWhiteSpace($uninstall)) {
                $m = [regex]::Match($uninstall, '(?i)--sapCode=([^\s"]+)')
                if ($m.Success) { $sapCode = $m.Groups[1].Value }
                $m = [regex]::Match($uninstall, '(?i)--productVersion=([^\s"]+)')
                if ($m.Success) { $prodVersion = $m.Groups[1].Value }
                $m = [regex]::Match($uninstall, '(?i)--productPlatform=([^\s"]+)')
                if ($m.Success) { $platform = $m.Groups[1].Value }
                # --productName is quoted when it contains spaces and bare when
                # it does not; both forms occur in the same registry.
                $m = [regex]::Match($uninstall, '(?i)--productName="([^"]*)"')
                if (-not $m.Success) { $m = [regex]::Match($uninstall, '(?i)--productName=([^\s"]+)') }
                if ($m.Success) { $prodName = $m.Groups[1].Value }
            }

            # The label an operator sees. DisplayName when there is one, then the
            # vendor's own --productName, then the registry key name - which is
            # SAP-code shaped (PHSP_26_6_1) and still identifies the product.
            $label = $displayName
            if ([string]::IsNullOrWhiteSpace($label)) { $label = $prodName }
            if ([string]::IsNullOrWhiteSpace($label)) { $label = $_.PSChildName }

            # Route. Adobe CC products go through the HyperDrive broker; Acrobat
            # and Reader are genuine MSI products and keep the msiexec path.
            $route = 'Unknown'
            if ((-not [string]::IsNullOrWhiteSpace($uninstall)) -and ($uninstall -match $HdUninstallerPattern)) {
                $route = 'HyperDrive'
            }
            elseif ($_.PSChildName -match '^\{[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\}$') {
                $route = 'Msi'
            }

            [pscustomobject]@{
                Label                = $label
                DisplayName          = $displayName
                DisplayVersion       = Get-Prop $props 'DisplayVersion'
                Publisher            = $publisher
                SapCode              = $sapCode
                ProductVersion       = $prodVersion
                ProductName          = $prodName
                Platform             = $platform
                Route                = $route
                UninstallString      = $uninstall
                QuietUninstallString = Get-Prop $props 'QuietUninstallString'
                InstallLocation      = Get-Prop $props 'InstallLocation'
                KeyName              = $_.PSChildName
                RegistryPath         = $_.PsPath
                Hive                 = $hive
            }
        }
    }
}

# Classification decides what -All targets and what needs -IncludeSharedComponents.
#
# The STRUCTURAL test is primary and works on any machine: a product is an
# APPLICATION when it owns a dedicated install directory. A shared component's
# InstallLocation points at a shared parent - verified here, seven of twelve rows
# declare "...\Common Files\Adobe", which is a container for everything, not a
# product folder. The known-SAP list only corroborates.
function Get-ProductClass {
    param($P)

    if ($P.SapCode -and ($KnownSharedSapCodes -contains $P.SapCode.ToUpperInvariant())) { return 'Shared' }

    # An MSI-route Adobe product on this machine means Acrobat or Reader, which
    # are applications by definition - they are not refcounted by HyperDrive.
    if ($P.Route -eq 'Msi') { return 'Application' }

    $loc = $P.InstallLocation
    if ([string]::IsNullOrWhiteSpace($loc)) {
        # No install location at all. A row with a real DisplayName is almost
        # certainly a product an operator recognizes; a nameless one is
        # plumbing. Nameless rows are the shared components on this platform.
        if ([string]::IsNullOrWhiteSpace($P.DisplayName)) { return 'Shared' }
        return 'Application'
    }

    $c = Get-ComparablePath $loc
    # Any "Common Files" ancestry means a shared parent, not a product folder.
    if ($c -match '(?i)\\common files\\') { return 'Shared' }
    foreach ($r in $ForbiddenResidualRoots) {
        if ($c -eq (Get-ComparablePath $r)) { return 'Shared' }
    }
    if ([string]::IsNullOrWhiteSpace($P.DisplayName)) { return 'Shared' }
    return 'Application'
}

$allAdobe = @(Get-AdobeProducts)

# Per-hive counts, logged so an empty census is diagnosable rather than
# mysterious. A run that finds nothing in WOW6432Node on a machine with Adobe
# installed is looking at the wrong registry view, not at a clean machine.
foreach ($h in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
                 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
                 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall')) {
    $n = @($allAdobe | Where-Object { $_.Hive -eq $h }).Count
    Write-Log ("    {0,-4} Adobe row(s) in {1}" -f $n, $h)
}

# De-duplicate by registry key name, never by display name: nine rows here share
# the same (absent) DisplayName and would collapse into one arbitrary entry.
$allAdobe = @($allAdobe | Group-Object KeyName | ForEach-Object { $_.Group[0] })

foreach ($p in $allAdobe) {
    Add-Member -InputObject $p -NotePropertyName 'Class' -NotePropertyValue (Get-ProductClass $p) -Force
}

$applications = @($allAdobe | Where-Object { $_.Class -eq 'Application' } | Sort-Object Label)
$sharedParts  = @($allAdobe | Where-Object { $_.Class -eq 'Shared' }      | Sort-Object Label)

if ($allAdobe.Count -gt 0) {
    Write-Log "Found $($allAdobe.Count) registered Adobe product(s): $($applications.Count) application(s), $($sharedParts.Count) shared component(s)." 'OK'
    if ($applications.Count -gt 0) {
        Write-Log 'Applications:'
        $applications | ForEach-Object {
            Write-Log ("    {0,-6} {1,-42} {2,-12} [{3}]" -f `
                $(if ($_.SapCode) { $_.SapCode } else { '-' }),
                $_.Label,
                $(if ($_.DisplayVersion) { $_.DisplayVersion } elseif ($_.ProductVersion) { $_.ProductVersion } else { '' }),
                $_.Route)
        }
    }
    if ($sharedParts.Count -gt 0) {
        Write-Log 'Shared components (refcounted by Adobe; need -IncludeSharedComponents):'
        $sharedParts | ForEach-Object {
            Write-Log ("    {0,-6} {1,-42} {2,-12} {3}" -f `
                $(if ($_.SapCode) { $_.SapCode } else { '-' }),
                $_.Label,
                $(if ($_.DisplayVersion) { $_.DisplayVersion } elseif ($_.ProductVersion) { $_.ProductVersion } else { '' }),
                $(if ($_.SapCode -and ($GuardedSapCodes -contains $_.SapCode.ToUpperInvariant())) { '[needs the node.exe guard]' } else { '' }))
        }
    }
}
else {
    Write-Log 'No Adobe product is registered in the uninstall hives.'
}

# --- Adobe install roots --------------------------------------------------
# Roots are resolved from conventional locations that actually exist, NOT from
# InstallLocation. Trap 4: seven of twelve rows declare a shared Common Files
# parent, and one of them is the directory holding the uninstaller itself.
function Get-AdobeRoots {
    $roots = @()
    foreach ($base in @(${env:ProgramFiles}, ${env:ProgramFiles(x86)}, ${env:ProgramData})) {
        if ([string]::IsNullOrWhiteSpace($base)) { continue }
        foreach ($name in $VendorRootNames) {
            foreach ($candidate in @((Join-Path $base $name), (Join-Path $base (Join-Path 'Common Files' $name)))) {
                if (Test-Path -LiteralPath $candidate) { $roots += $candidate }
            }
        }
    }
    return @($roots | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
}

# A discovery ROOT is every bit as dangerous as a deletion TARGET: it is the sole
# attribution route for the path-scoped Stop-Process list. A root of "C:" would
# match everything and attribute every running process on the machine to Adobe.
function Test-SafeScopeRoot {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    $full = $Path.Trim().Trim('"').TrimEnd('\')
    if ($full -match '^[a-zA-Z]:\\?$')   { return $false }   # C:\ scopes the whole drive
    if (($full -split '\\').Count -lt 3) { return $false }   # C:\Program Files
    foreach ($r in $ForbiddenResidualRoots) {
        if ((Get-ComparablePath $full) -eq (Get-ComparablePath $r)) { return $false }
    }
    return ($full -match '(?i)\\Adobe($|\\)')
}

$AdobeRoots = @(Get-AdobeRoots | Where-Object {
    if (Test-SafeScopeRoot $_) { $true }
    else {
        Write-Log "Discarding unsafe Adobe root '$_': it is a drive root, a top-level system container, or does not name the vendor." 'WARN'
        $false
    }
})
if ($AdobeRoots.Count -gt 0) {
    Write-Log 'Adobe roots on disk:'
    $AdobeRoots | ForEach-Object { Write-Log "    - $_" }
}

# --- Prior-failure disclosure ---------------------------------------------
# Adobe writes the outcome of the last install/uninstall workflow here. A
# previous 130 means the engine already refused something, and the operator
# should know before this run starts rather than after it reports the same code.
$adobeSummary = Join-Path ${env:ProgramData} 'Adobe\Installer\Summary.htm'
if (Test-Path -LiteralPath $adobeSummary) {
    try {
        $sumTxt = [System.IO.File]::ReadAllText($adobeSummary)
        $mErr = [regex]::Match($sumTxt, '(?i)error code (\d+)')
        if ($mErr.Success) {
            Write-Log "Adobe's own installer summary records a previous failure (error code $($mErr.Groups[1].Value)) at $adobeSummary. That is expected if a shared component was refused before; treat a repeat of the same code as normal." 'WARN'
        }
    }
    catch { }
}

# Adobe's authoritative log, for the operator to read when something fails.
# It is UTF-16LE - opening it as UTF-8 yields interleaved nulls and looks corrupt.
$AdobeInstallLog = Join-Path ${env:ProgramFiles(x86)} 'Common Files\Adobe\Installers\Install.log'

# --- Residual location assembly -------------------------------------------
# Per-product folders, keyed to the product. Only the folders of products this
# run ACTUALLY removes are ever considered, which is why this is a function of
# the product rather than a flat list.
function Get-ProductResidualPaths {
    param($P)
    $paths = @()

    # A product folder named after the product, under each Adobe root. Derived
    # from the label rather than from InstallLocation, and Test-Path'd at use.
    $names = @()
    if (-not [string]::IsNullOrWhiteSpace($P.DisplayName)) { $names += $P.DisplayName }
    if (-not [string]::IsNullOrWhiteSpace($P.ProductName)) {
        $names += $P.ProductName
        $names += ('Adobe ' + $P.ProductName)
    }

    foreach ($base in @(${env:ProgramFiles}, ${env:ProgramFiles(x86)})) {
        if ([string]::IsNullOrWhiteSpace($base)) { continue }
        $adobeDir = Join-Path $base 'Adobe'
        if (-not (Test-Path -LiteralPath $adobeDir)) { continue }
        foreach ($n in @($names | Select-Object -Unique)) {
            $c = Join-Path $adobeDir $n
            if (Test-Path -LiteralPath $c) { $paths += $c }
        }
    }

    # InstallLocation is used ONLY when it is a dedicated product folder - never
    # when it resolves to a shared Common Files parent. See trap 4.
    $loc = $P.InstallLocation
    if (-not [string]::IsNullOrWhiteSpace($loc)) {
        $c = Get-ComparablePath $loc
        $isShared = ($c -match '(?i)\\common files\\?$' -or $c -match '(?i)\\common files\\adobe$')
        foreach ($r in $ForbiddenResidualRoots) {
            if ($c -eq (Get-ComparablePath $r)) { $isShared = $true }
        }
        if ((-not $isShared) -and (Test-Path -LiteralPath $loc) -and ($c -match '(?i)\\adobe\\')) {
            $paths += $loc.Trim().Trim('"').TrimEnd('\')
        }
    }

    return @($paths | Select-Object -Unique)
}

# Vendor-wide plumbing. Only ever consumed once NO Adobe product remains
# registered, because every one of these is shared by all Adobe products.
function Get-VendorResidualPaths {
    $paths = @()
    foreach ($base in @(${env:ProgramFiles}, ${env:ProgramFiles(x86)})) {
        if ([string]::IsNullOrWhiteSpace($base)) { continue }
        $paths += (Join-Path $base 'Adobe')
        $paths += (Join-Path $base 'Common Files\Adobe')
    }
    if (-not [string]::IsNullOrWhiteSpace(${env:ProgramData})) {
        $paths += (Join-Path ${env:ProgramData} 'Adobe\Installer')
    }
    return @($paths | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
}

# User data. Behind -RemoveUserData only, and enumerated over REAL profile
# directories - C:\Users is full of reparse points that would otherwise be
# followed into ProgramData and into the same profile twice.
function Get-UserDataResidualPaths {
    $paths = @()
    if (-not [string]::IsNullOrWhiteSpace(${env:ProgramData})) {
        $paths += (Join-Path ${env:ProgramData} 'Adobe\CameraRaw')
    }
    foreach ($profile in (Get-RealUserProfileDirectories)) {
        foreach ($leaf in @('AppData\Local\Adobe', 'AppData\Roaming\Adobe', 'AppData\LocalLow\Adobe')) {
            $paths += (Join-Path $profile.FullName $leaf)
        }
    }
    return @($paths | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
}

# Start Menu shortcuts, validated by TARGET rather than by filename. Verified on
# this platform: there is no "Start Menu\Programs\Adobe" folder at all - the
# shortcuts are loose .lnk files sitting beside the Autodesk folders this repo's
# other scripts own, so a recursive delete at the Programs level is catastrophic
# and a filename glob is nearly as bad.
function Get-AdobeShortcuts {
    param([string[]]$Roots)
    if ($Roots.Count -eq 0) { return @() }

    $dirs = @()
    if (-not [string]::IsNullOrWhiteSpace(${env:ProgramData})) {
        $dirs += (Join-Path ${env:ProgramData} 'Microsoft\Windows\Start Menu\Programs')
    }
    if (-not [string]::IsNullOrWhiteSpace(${env:PUBLIC})) {
        $dirs += (Join-Path ${env:PUBLIC} 'Desktop')
    }
    foreach ($profile in (Get-RealUserProfileDirectories)) {
        $dirs += (Join-Path $profile.FullName 'AppData\Roaming\Microsoft\Windows\Start Menu\Programs')
        $dirs += (Join-Path $profile.FullName 'Desktop')
    }

    $shell = $null
    try { $shell = New-Object -ComObject WScript.Shell } catch { return @() }

    $found = @()
    foreach ($d in @($dirs | Select-Object -Unique)) {
        if ([string]::IsNullOrWhiteSpace($d) -or -not (Test-Path -LiteralPath $d)) { continue }
        Get-ChildItem -LiteralPath $d -Filter '*.lnk' -File -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
            $target = ''
            try { $target = ($shell.CreateShortcut($_.FullName)).TargetPath } catch { return }
            if ([string]::IsNullOrWhiteSpace($target)) { return }
            if (Test-PathUnderAny -Path $target -Roots $Roots) {
                $found += [pscustomobject]@{ Path = $_.FullName; Target = $target }
            }
        }
    }
    return $found
}

# --- ListOnly -------------------------------------------------------------
if ($ListOnly) {
    if ($applications.Count -gt 0) {
        Write-Log ''
        Write-Log 'Pass any of these to -Product (SAP code or a name fragment):'
        $applications | ForEach-Object {
            Write-Log ("    -Product {0,-6}   {1}" -f $(if ($_.SapCode) { $_.SapCode } else { '"' + $_.Label + '"' }), $_.Label)
        }
    }

    $shortcuts = @(Get-AdobeShortcuts -Roots $AdobeRoots)
    if ($shortcuts.Count -gt 0) {
        Write-Log 'Shortcuts that would be removed (matched by target, not by name):'
        $shortcuts | ForEach-Object { Write-Log "    - $($_.Path)  ->  $($_.Target)" }
    }

    if ($RemoveUserData) {
        $ud = @(Get-UserDataResidualPaths | Where-Object { Test-Path -LiteralPath $_ })
        if ($ud.Count -gt 0) {
            Write-Log 'User data that would be removed (-RemoveUserData):' 'WARN'
            $ud | ForEach-Object {
                $size = 0
                $size = Get-PathSize $_
                Write-Log ("    - {0}  ({1:N0} MB)" -f $_, ($size / 1MB))
            }
        }
    }

    Write-Log ''
    Write-Log 'Preview only - nothing was changed.' 'OK'
    if ($allAdobe.Count -eq 0) {
        Write-Log 'Nothing to remove: no Adobe product is registered.' 'OK'
    }
    Write-Log "Log saved to: $LogPath"
    try { Stop-Transcript | Out-Null } catch { }
    exit 0
}

# --- Nothing-to-do gate ---------------------------------------------------
# Registration state is not the whole story. After a successful pass every
# census above can be empty BY CONSTRUCTION, and that is precisely the run that
# should sweep the folders left behind - so residue is consulted before
# declaring there is nothing to do.
$residualPresent = $false
if ($RemoveResidualFiles) {
    $residualPresent = @(Get-VendorResidualPaths | Where-Object { Test-Path -LiteralPath $_ }).Count -gt 0
}
if (-not $residualPresent -and $RemoveUserData) {
    $residualPresent = @(Get-UserDataResidualPaths | Where-Object { Test-Path -LiteralPath $_ }).Count -gt 0
}

if ($allAdobe.Count -eq 0 -and -not $residualPresent) {
    Write-Log 'Nothing to remove: no Adobe product is registered and no Adobe residue was found.' 'OK'
    Write-Log "Log saved to: $LogPath"
    try { Stop-Transcript | Out-Null } catch { }
    exit 2
}

# --- Selection ------------------------------------------------------------
# Resolve one -Product token against the census. A token must match EXACTLY one
# product: an ambiguous or unknown selector aborts rather than being guessed at,
# because guessing here uninstalls the wrong application.
function Resolve-ProductSelector {
    param([string]$Token, $Candidates)

    $t = $Token.Trim()
    if ([string]::IsNullOrWhiteSpace($t)) { return @() }

    # 1. Exact SAP code. The strongest and the documented form.
    $bySap = @($Candidates | Where-Object { $_.SapCode -and ($_.SapCode -eq $t.ToUpperInvariant()) })
    if ($bySap.Count -gt 0) { return $bySap }

    # 2. Exact registry key name, for the nameless rows.
    $byKey = @($Candidates | Where-Object { $_.KeyName -eq $t })
    if ($byKey.Count -gt 0) { return $byKey }

    # 3. Exact label, case-insensitive.
    $byLabel = @($Candidates | Where-Object { $_.Label -and ($_.Label -eq $t) })
    if ($byLabel.Count -gt 0) { return $byLabel }

    # 4. Substring of the label or the vendor's product name. -like with the
    #    token WILDCARD-ESCAPED: an operator typing a name containing [ or ] must
    #    not have it interpreted as a character class.
    $escaped = [System.Management.Automation.WildcardPattern]::Escape($t)
    return @($Candidates | Where-Object {
        ($_.Label -and ($_.Label -like "*$escaped*")) -or
        ($_.ProductName -and ($_.ProductName -like "*$escaped*"))
    })
}

# The pool a selector may resolve against. Shared components are only selectable
# when the operator has asked for them, so "-Product Core" cannot accidentally
# resolve to a colour-profile bundle.
$selectionPool = @($applications)
if ($IncludeSharedComponents) {
    # Guarded codes ARE selectable. Their guard runs at removal time, where the
    # operator can actually satisfy it - filtering them out here is exactly what
    # created the dead end described at $GuardedSapCodes.
    $selectionPool += @($sharedParts)
}

$targets = @()

if ($Product -and $Product.Count -gt 0) {
    # "powershell.exe -File" DOES NOT SPLIT A COMMA-SEPARATED VALUE INTO AN ARRAY.
    # Measured: under -File, "-Product Photoshop,Illustrator" binds $Product to a
    # SINGLE string "Photoshop,Illustrator" - which matches no product and aborts
    # the run. Under -Command the same text binds as two elements. This is the
    # same -File literal-string limitation that stops a [bool] parameter binding,
    # and since every example in this repo is written with -File, the script has
    # to do the splitting itself rather than document a workaround.
    #
    # A whole-token match is tried FIRST, so a product whose real name contains a
    # comma is still selectable and is never split out from under the operator.
    $productTokens = @()
    foreach ($raw in $Product) {
        if ([string]::IsNullOrWhiteSpace($raw)) { continue }
        if ($raw -notmatch ',') { $productTokens += $raw.Trim(); continue }
        if (@(Resolve-ProductSelector -Token $raw.Trim() -Candidates $selectionPool).Count -eq 1) {
            $productTokens += $raw.Trim()
            continue
        }
        $productTokens += @($raw -split ',' | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }

    $bad = $false
    foreach ($token in $productTokens) {
        $matched = @(Resolve-ProductSelector -Token $token -Candidates $selectionPool)

        if ($matched.Count -eq 0) {
            # Distinguish "does not exist" from "exists but is not selectable in
            # this mode". Reporting a shared component as "no match" sends the
            # operator hunting for a typo that is not there.
            $why = ''
            $elsewhere = @(Resolve-ProductSelector -Token $token -Candidates $allAdobe)
            if ($elsewhere.Count -ge 1) {
                if (-not $IncludeSharedComponents) {
                    $why = " It is installed, but it is a shared component and shared components are not selectable by default. Add -IncludeSharedComponents to target it."
                }
            }
            Write-Log "No selectable Adobe product matches '-Product $token'.$why" 'ERROR'
            $bad = $true
            continue
        }
        if ($matched.Count -gt 1) {
            Write-Log "'-Product $token' is ambiguous and matches $($matched.Count) products:" 'ERROR'
            $matched | ForEach-Object { Write-Log "    $($_.SapCode)  $($_.Label)" 'ERROR' }
            Write-Log '    Re-run with the SAP code, which is unique.' 'ERROR'
            $bad = $true
            continue
        }
        $targets += $matched[0]
    }

    if ($bad) {
        Write-Log 'Selectable products:' 'WARN'
        $selectionPool | ForEach-Object { Write-Log ("    {0,-6}  {1}" -f $(if ($_.SapCode) { $_.SapCode } else { '-' }), $_.Label) 'WARN' }
        if (-not $IncludeSharedComponents -and $sharedParts.Count -gt 0) {
            Write-Log "    ($($sharedParts.Count) shared component(s) are hidden from selection; pass -IncludeSharedComponents to target them.)" 'WARN'
        }
        Write-Log "Log saved to: $LogPath"
        try { Stop-Transcript | Out-Null } catch { }
        exit 1
    }
}
elseif ($All) {
    $targets = @($selectionPool)
}
else {
    # Interactive menu - the default when no selector was given. This is the
    # "choose what to uninstall" path, and it refuses to run under -Force
    # because there would be nobody to answer it.
    if ($Force) {
        Write-Log '-Force requires an explicit selection: pass -Product <CODE> or -All. Refusing to assume you meant every Adobe product.' 'ERROR'
        Write-Log "Log saved to: $LogPath"
        try { Stop-Transcript | Out-Null } catch { }
        exit 1
    }
    if ($selectionPool.Count -eq 0) {
        Write-Log 'No selectable Adobe application was found.' 'WARN'
        if ($sharedParts.Count -gt 0) {
            Write-Log "Only shared components remain ($($sharedParts.Count)). Re-run with -IncludeSharedComponents to target them." 'WARN'
        }
        Write-Log "Log saved to: $LogPath"
        try { Stop-Transcript | Out-Null } catch { }
        exit 2
    }

    Write-Log ''
    Write-Host '  Select the Adobe product(s) to uninstall:' -ForegroundColor Cyan
    Write-Host ''
    for ($i = 0; $i -lt $selectionPool.Count; $i++) {
        $p = $selectionPool[$i]
        Write-Host ("    [{0,2}]  {1,-6}  {2,-42} {3}" -f `
            ($i + 1),
            $(if ($p.SapCode) { $p.SapCode } else { '-' }),
            $p.Label,
            $(if ($p.DisplayVersion) { $p.DisplayVersion } elseif ($p.ProductVersion) { $p.ProductVersion } else { '' })) -ForegroundColor White
    }
    Write-Host ''
    Write-Host '    [ A]  All of the above' -ForegroundColor White
    Write-Host '    [ Q]  Quit, change nothing' -ForegroundColor White
    Write-Host ''

    $answer = Read-Host 'Enter numbers separated by commas (e.g. 1,3), or A / Q'
    $answer = $answer.Trim()

    if ($answer -match '^(?i)(q|quit|n|no)$' -or [string]::IsNullOrWhiteSpace($answer)) {
        Write-Log 'Aborted at the selection menu; nothing was changed.' 'WARN'
        Write-Log "Log saved to: $LogPath"
        try { Stop-Transcript | Out-Null } catch { }
        exit 1
    }
    if ($answer -match '^(?i)(a|all)$') {
        $targets = @($selectionPool)
    }
    else {
        $bad = $false
        foreach ($tok in ($answer -split '[,\s]+')) {
            if ([string]::IsNullOrWhiteSpace($tok)) { continue }
            $n = 0
            if (-not [int]::TryParse($tok, [ref]$n) -or $n -lt 1 -or $n -gt $selectionPool.Count) {
                Write-Log "'$tok' is not one of the listed numbers." 'ERROR'
                $bad = $true
                continue
            }
            $targets += $selectionPool[$n - 1]
        }
        if ($bad) {
            Write-Log 'Aborted: the selection contained an entry that is not on the menu. Nothing was changed.' 'ERROR'
            Write-Log "Log saved to: $LogPath"
            try { Stop-Transcript | Out-Null } catch { }
            exit 1
        }
    }
}

# De-duplicate: an operator may name the same product by SAP code and by name.
$targets = @($targets | Group-Object KeyName | ForEach-Object { $_.Group[0] })

if ($targets.Count -eq 0) {
    Write-Log 'Nothing selected; no changes made.' 'WARN'
    Write-Log "Log saved to: $LogPath"
    try { Stop-Transcript | Out-Null } catch { }
    exit 2
}

# Ordering: applications first, then shared components. A shared component asked
# for while an application that references it is still installed answers 130 and
# is left alone - correct, but pointless, so doing the applications first gives
# the refcount a chance to reach zero within the same run.
$targets = @($targets | Sort-Object -Property @{ Expression = { if ($_.Class -eq 'Application') { 0 } else { 1 } } }, @{ Expression = 'Label' })

Write-Log ''
Write-Log "Selected for removal ($($targets.Count)):" 'OK'
$targets | ForEach-Object {
    Write-Log ("    {0,-6}  {1,-42} [{2}]" -f $(if ($_.SapCode) { $_.SapCode } else { '-' }), $_.Label, $_.Class)
}

# Adobe's engine discards application preferences on uninstall and exposes no
# flag to prevent it. Say so before anything is removed, not after.
Write-Log 'Adobe''s uninstaller discards application preferences (workspaces, actions, brushes, presets) as part of its own workflow. There is no vendor flag to keep them.' 'WARN'

# --- Running-application guard --------------------------------------------
function Get-AdobeProcesses {
    param([string[]]$Roots)
    Get-Process -ErrorAction SilentlyContinue | ForEach-Object {
        $path = $null
        # .Path throws for protected and other-user processes, so it is read
        # inside its own try/catch rather than guarded by a preference variable.
        try { $path = $_.Path } catch { }

        $nameIsOwn    = ($AdobeOwnProcessNames   -contains $_.ProcessName)
        $nameIsScoped = ($PathScopedProcessNames -contains $_.ProcessName)
        $inScope = $false
        if ((-not [string]::IsNullOrWhiteSpace($path)) -and $Roots.Count -gt 0) {
            $inScope = Test-PathUnderAny -Path $path -Roots $Roots
        }

        # A path-scoped name counts ONLY when its image really is under an Adobe
        # root. node.exe is the reason: Adobe embeds a Node runtime, and a
        # bare-name match would claim every unrelated Node process running.
        if (-not ($nameIsOwn -or ($nameIsScoped -and $inScope) -or $inScope)) { return }

        [pscustomobject]@{
            Process   = $_
            Name      = $_.ProcessName
            Path      = $path
            InScope   = $inScope
            NameIsOwn = $nameIsOwn
            IsBlocking = ($BlockingProcessNames -contains $_.ProcessName)
        }
    }
}

$adobeProcs = @(Get-AdobeProcesses -Roots $AdobeRoots | Where-Object { $_.InScope -or $_.NameIsOwn })

if ($adobeProcs.Count -gt 0) {
    Write-Log ''
    Write-Log "Adobe processes running ($($adobeProcs.Count)):" 'WARN'
    $adobeProcs | ForEach-Object {
        Write-Log ("    {0} (PID {1}) {2}{3}" -f `
            $_.Name,
            $_.Process.Id,
            $(if ($_.Path) { $_.Path } else { '[path unavailable]' }),
            $(if ($_.IsBlocking) { '   [blocks the uninstall]' } else { '' }))
    }

    if (-not $StopAdobe) {
        $blocking = @($adobeProcs | Where-Object { $_.IsBlocking })
        if ($blocking.Count -gt 0) {
            Write-Log 'Adobe''s own uninstaller declares these applications non-killable and will REFUSE rather than close them, because you may have unsaved work. Save and close them, or re-run with -StopAdobe.' 'ERROR'
        }
        else {
            Write-Log 'Adobe background processes are running. Re-run with -StopAdobe, or close them first. Uninstalling with live processes leaves locked files and a half-finished removal.' 'ERROR'
        }
        Write-Log "Log saved to: $LogPath"
        try { Stop-Transcript | Out-Null } catch { }
        exit 1
    }

    # -StopAdobe: ask before forcing. Adobe declines to force-kill these
    # precisely because of unsaved work, so a graceful close is attempted first
    # and only a process that ignores it is terminated.
    foreach ($p in $adobeProcs) {
        if (-not $PSCmdlet.ShouldProcess("$($p.Name) (PID $($p.Process.Id))", 'Stop process')) { continue }
        try {
            $closed = $false
            if ($p.Process.MainWindowHandle -ne 0) {
                $null = $p.Process.CloseMainWindow()
                $closed = $p.Process.WaitForExit(10000)
            }
            if (-not $closed) {
                Stop-Process -Id $p.Process.Id -Force -ErrorAction Stop
                Write-Log "    terminated $($p.Name) (PID $($p.Process.Id))"
            }
            else {
                Write-Log "    closed $($p.Name) (PID $($p.Process.Id))"
            }
        }
        catch {
            Write-Log "      could not stop: $($_.Exception.Message)" 'WARN'
        }
    }
    if (-not $WhatIfPreference) { Start-Sleep -Seconds 3 }
}

# --- Log retention ---------------------------------------------------------
# This script's own artifacts accumulate in %TEMP% and nothing else ever cleans
# them: measured on this machine, 42 transcripts plus 2 metadata captures
# (14.5 MB) after a single afternoon of runs, and each real run adds ~7 MB.
#
# Only artifacts THIS SCRIPT created are ever considered, matched by a strict
# anchored pattern rather than a glob - %TEMP% is full of other tools' files and
# a loose "Uninstall*" sweep there would be indefensible. The run in progress is
# passed in explicitly and never touched. Every deletion is logged, so the
# pruning is auditable instead of silent.
function Remove-StaleRunArtifacts {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([string]$Directory, [int]$Keep = 5, [string[]]$ProtectPaths = @())

    if ([string]::IsNullOrWhiteSpace($Directory) -or -not (Test-Path -LiteralPath $Directory)) { return 0 }

    # Two shapes: the current paired naming, and the legacy independently-stamped
    # capture folder an earlier revision of this script produced.
    $patterns = @(
        '^Uninstall-Adobe_(\d{8}_\d{6})\.log$',
        '^Uninstall-Adobe_(\d{8}_\d{6})_metadata$',
        '^AdobeInstallMetadata_(\d{8}_\d{6})$'
    )

    $items = @(Get-ChildItem -LiteralPath $Directory -Force -ErrorAction SilentlyContinue | ForEach-Object {
        foreach ($pat in $patterns) {
            $m = [regex]::Match($_.Name, $pat)
            if ($m.Success) {
                [pscustomobject]@{ Item = $_; Stamp = $m.Groups[1].Value }
                break
            }
        }
    })
    if ($items.Count -eq 0) { return 0 }

    $protect = @($ProtectPaths | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        ForEach-Object { Get-ComparablePath $_ })

    # Group by run stamp so a transcript and its capture folder age out together,
    # newest stamp first. Sorting the STAMP text is correct here: yyyyMMdd_HHmmss
    # sorts identically as a string and as a date, and unlike LastWriteTime it is
    # not perturbed by a later run touching an older folder.
    $stale = @($items | ForEach-Object { $_.Stamp } | Select-Object -Unique |
        Sort-Object -Descending | Select-Object -Skip $Keep)
    if ($stale.Count -eq 0) { return 0 }

    $freed   = 0
    $removed = 0
    foreach ($entry in @($items | Where-Object { $stale -contains $_.Stamp })) {
        $it = $entry.Item
        if ($protect -contains (Get-ComparablePath $it.FullName)) { continue }
        if (-not $PSCmdlet.ShouldProcess($it.FullName, 'Remove stale run artifact')) { continue }
        try {
            $size = 0
            if ($it.PSIsContainer) {
                $size = Get-PathSize $it.FullName
                Remove-Item -LiteralPath $it.FullName -Recurse -Force -ErrorAction Stop
            }
            else {
                $size = $it.Length
                Remove-Item -LiteralPath $it.FullName -Force -ErrorAction Stop
            }
            $freed += $size
            $removed++
        }
        catch { }
    }

    if ($removed -gt 0) {
        Write-Log ("Pruned {0} artifact(s) from {1} older run(s) of this script in {2}, freeing {3:N1} MB. The {4} most recent runs are kept." -f `
            $removed, $stale.Count, $Directory, ($freed / 1MB), $Keep)
    }
    return $removed
}

# --- Capture Adobe's own metadata before anything is removed ---------------
# Installers\uninstallXml, repairXml and ProgramData\Adobe\Installer\Summary.htm
# are the only on-disk record of what was installed. They live inside trees this
# script may later delete, so they are copied to the log folder FIRST.
if (-not $WhatIfPreference) {
    try {
        $logDir = Split-Path -Parent $LogPath
        # NAMED FROM THE LOG FILE, not from a second Get-Date call. Stamping it
        # independently produced a folder whose timestamp differed from its own
        # log by a couple of seconds (..._022909.log beside ..._022911\), so
        # after a few runs there was no way to tell which capture belonged to
        # which run. One run now produces exactly one identifiable pair.
        $backupDir = Join-Path $logDir ([IO.Path]::GetFileNameWithoutExtension($LogPath) + '_metadata')
        $sources   = @(
            (Join-Path ${env:ProgramFiles(x86)} 'Common Files\Adobe\Installers'),
            (Join-Path ${env:ProgramData} 'Adobe\Installer')
        ) | Where-Object { (-not [string]::IsNullOrWhiteSpace($_)) -and (Test-Path -LiteralPath $_) }

        if ($sources.Count -gt 0) {
            $null = New-Item -ItemType Directory -Path $backupDir -Force -ErrorAction Stop
            foreach ($s in $sources) {
                $dest = Join-Path $backupDir (Split-Path -Leaf $s)
                Copy-Item -LiteralPath $s -Destination $dest -Recurse -Force -ErrorAction SilentlyContinue
            }
            $capSize = 0
            $capSize = Get-PathSize $backupDir
            # Report the size. This capture is ~7 MB per run and it accumulates;
            # a silent copy is how %TEMP% quietly fills up.
            Write-Log ("Captured Adobe install metadata ({0:N1} MB) to: {1}" -f ($capSize / 1MB), $backupDir) 'OK'
        }

        $null = Remove-StaleRunArtifacts -Directory $logDir -Keep 5 -ProtectPaths @($LogPath, $backupDir)
    }
    catch {
        # Never fatal. This is a courtesy copy, not a prerequisite.
        Write-Log "Could not capture Adobe install metadata: $($_.Exception.Message)" 'WARN'
    }
}

# --- Uninstall ------------------------------------------------------------
$failures     = 0
$skipped      = 0
$stillRefd    = 0
$rebootNeeded = $false
$removed      = @()

# Split a registered UninstallString into an executable and its argument string.
# Deliberately NOT routed through cmd /c or a -Command string: the argument list
# contains braces, quotes and '=' characters that a second parser would mangle.
function Split-UninstallCommand {
    param([string]$Command)
    if ([string]::IsNullOrWhiteSpace($Command)) { return $null }
    $c = $Command.Trim()

    if ($c.StartsWith('"')) {
        $end = $c.IndexOf('"', 1)
        if ($end -gt 1) {
            return [pscustomobject]@{
                FilePath  = $c.Substring(1, $end - 1)
                Arguments = $c.Substring($end + 1).Trim()
            }
        }
    }

    $m = [regex]::Match($c, '(?i)^(.*?\.exe)(?:\s+(.*))?$')
    if ($m.Success) {
        return [pscustomobject]@{
            FilePath  = $m.Groups[1].Value.Trim()
            Arguments = $m.Groups[2].Value.Trim()
        }
    }
    return $null
}

# THE AUTHORITY. Uninstaller.exe is a shim that can hand off to another process,
# so its exit code describes the handoff, not necessarily the outcome. The
# registry key is the fact: gone means removed, present means not removed.
function Test-ProductStillRegistered {
    param($P)
    return (Test-Path -LiteralPath $P.RegistryPath)
}

# THE ITERATOR IS $target, NOT $product, AND THAT IS NOT A STYLE CHOICE.
# PowerShell variable names are CASE-INSENSITIVE, so a loop variable named
# $product IS the [string[]]$Product parameter - and a parameter's type
# constraint OUTLIVES the parameter binding. Assigning a [pscustomobject] to it
# does not rebind the name; it COERCES the object to a string array. Measured:
# inside "foreach ($product in $targets)", $product.GetType() is String[], every
# property access fails with "The property 'Label' cannot be found on this
# object", and under StrictMode that is terminating - after selection has already
# succeeded and the run has announced what it is about to remove. Any loop
# variable in this script must therefore avoid every param() name.
foreach ($target in $targets) {
    Write-Log ''
    Write-Log ("--- {0}  [{1}]  {2}" -f $target.Label, $(if ($target.SapCode) { $target.SapCode } else { '-' }), $target.Route)

    # THE NODE.EXE GUARD. CCXP's conflicting-process metadata claims node.exe,
    # and Adobe's engine force-kills what it claims - so removing it while
    # unrelated Node processes are running would terminate them without warning.
    # This is a guard the operator can satisfy, not a refusal: closing the Node
    # processes (or rebooting) clears it, and the component then removes cleanly.
    if ($target.SapCode -and ($GuardedSapCodes -contains $target.SapCode.ToUpperInvariant())) {
        $foreignNode = @(Get-Process -Name 'node' -ErrorAction SilentlyContinue | Where-Object {
            $p = $null
            try { $p = $_.Path } catch { }
            # A Node process we cannot attribute is treated as foreign: the cost
            # of being wrong is killing somebody's build, not leaving a stale
            # registry key.
            [string]::IsNullOrWhiteSpace($p) -or -not (Test-PathUnderAny -Path $p -Roots $AdobeRoots)
        })

        if ($foreignNode.Count -gt 0) {
            Write-Log "Skipping $($target.SapCode): $($foreignNode.Count) node.exe process(es) are running that do not belong to Adobe. Adobe's engine claims node.exe as a conflicting process for this component and force-kills what it claims, so removing it now would terminate them without warning." 'WARN'

            # Report them GROUPED BY PARENT, not as a wall of PIDs. A bare list of
            # 36 identical "node.exe (PID nnnn)" lines is unactionable - the
            # operator cannot tell what would die. The parent is the useful fact:
            # measured on this machine the list was 11 children of claude.exe (an
            # editor session and its language servers) and 20 of cmd.exe, i.e.
            # the operator's entire toolchain, none of it obviously "node".
            $parents = @{}
            foreach ($n in $foreignNode) {
                $pname = 'unknown'
                try {
                    $ci = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId=$($n.Id)" -ErrorAction Stop
                    $pp = Get-Prop $ci 'ParentProcessId'
                    if ($pp) {
                        $par = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId=$pp" -ErrorAction SilentlyContinue
                        $pn = Get-Prop $par 'Name'
                        if (-not [string]::IsNullOrWhiteSpace($pn)) { $pname = $pn }
                    }
                }
                catch { }
                if (-not $parents.ContainsKey($pname)) { $parents[$pname] = 0 }
                $parents[$pname]++
            }
            foreach ($k in @($parents.Keys | Sort-Object { -$parents[$_] })) {
                Write-Log ("    {0,3} x node.exe launched by {1}" -f $parents[$k], $k) 'WARN'
            }

            Write-Log '    These are almost certainly your own tooling, not Adobe''s. The reliable fix is to REBOOT and re-run this script before starting your editor or terminal, rather than hunting individual PIDs.' 'WARN'
            $skipped++
            continue
        }
        Write-Log "No foreign node.exe is running; the $($target.SapCode) guard is clear." 'OK'
    }

    if ([string]::IsNullOrWhiteSpace($target.UninstallString)) {
        Write-Log "Skipping $($target.Label): the registry row carries no UninstallString, so there is no vendor-supported removal route. Remove it from Settings > Apps, or reinstall and retry." 'WARN'
        $skipped++
        continue
    }

    if (-not $Force -and -not $WhatIfPreference) {
        $answer = Read-Host "Uninstall '$($target.Label)'? [Y/N]"
        if ($answer -notmatch '^(y|yes)$') {
            Write-Log "Skipped by user: $($target.Label)" 'WARN'
            $skipped++
            continue
        }
    }

    if (-not $PSCmdlet.ShouldProcess($target.Label, 'Uninstall')) {
        # A real decline ("No"/"No to All"), not a -WhatIf preview: the product
        # stays installed and must suppress residual cleanup.
        if (-not $WhatIfPreference) { $skipped++ }
        continue
    }

    $code = $null

    if ($target.Route -eq 'Msi') {
        # Acrobat / Reader. A genuine MSI product, and the only Adobe route that
        # takes a ProductCode. The registered UninstallString has no /qn, so it
        # is supplied explicitly - running the harvested string verbatim opens an
        # interactive dialog and blocks forever under -Force.
        $stamp   = Get-Date -Format 'yyyyMMdd_HHmmss'
        $vlog    = Join-Path $env:TEMP ("MSIVerbose_{0}_{1}.log" -f ($target.KeyName -replace '[{}]', ''), $stamp)
        $msiArgs = @('/x', $target.KeyName, '/qn', '/norestart', 'REBOOT=ReallySuppress', '/l*v', ('"' + $vlog + '"'))

        Write-Log "Uninstalling via msiexec ($($target.KeyName))..."
        Write-Log "    verbose log: $vlog"
        try {
            $rc = Start-Process -FilePath 'msiexec.exe' -ArgumentList $msiArgs -Wait -PassThru -ErrorAction Stop
            $code = 0
            if ($rc -and $null -ne $rc.ExitCode) { $code = $rc.ExitCode }
        }
        catch {
            Write-Log "msiexec could not be started: $($_.Exception.Message)" 'ERROR'
            $failures++
            continue
        }

        if ($MsiSuccessCodes -contains $code) {
            if ($code -eq 3010) { $rebootNeeded = $true }
        }
        else {
            Write-Log "msiexec returned $code for $($target.Label). Review $vlog" 'ERROR'
        }
    }
    else {
        # HyperDrive. The command line is replayed VERBATIM - --productAdobeCode
        # is a per-product literal whose ADBEADBE padding cannot be derived, and
        # no silent flag exists to add. Uninstaller.exe parses only 11 switches
        # and --mode is not one of them; it is consumed downstream by HDPIM.dll.
        $cmd = Split-UninstallCommand $target.UninstallString
        if ($null -eq $cmd -or [string]::IsNullOrWhiteSpace($cmd.FilePath)) {
            Write-Log "Could not parse the UninstallString for $($target.Label): $($target.UninstallString)" 'ERROR'
            $failures++
            continue
        }

        if (-not (Test-Path -LiteralPath $cmd.FilePath)) {
            Write-Log "The registered uninstaller does not exist: $($cmd.FilePath)" 'ERROR'
            Write-Log '    Adobe''s broker lives under Common Files\Adobe\Adobe Desktop Common. If an earlier cleanup deleted that folder, no Adobe product on this machine can be uninstalled through the supported path any more - reinstall the Creative Cloud desktop app to restore it.' 'ERROR'
            $failures++
            continue
        }

        # Confirm the binary is Adobe's before running it. Cheap, and it is the
        # difference between running the vendor's uninstaller and running
        # whatever now occupies that path.
        try {
            $vi = (Get-Item -LiteralPath $cmd.FilePath -ErrorAction Stop).VersionInfo
            $cn = $vi.CompanyName
            if ([string]::IsNullOrWhiteSpace($cn) -or $cn -notmatch '(?i)adobe') {
                Write-Log "REFUSING to run $($cmd.FilePath): its version resource does not identify Adobe (CompanyName='$cn')." 'ERROR'
                $failures++
                continue
            }
        }
        catch {
            Write-Log "Could not read the version resource of $($cmd.FilePath): $($_.Exception.Message)" 'ERROR'
            $failures++
            continue
        }

        Write-Log "Running Adobe's uninstaller for $($target.Label)..."
        Write-Log "    $($cmd.FilePath) $($cmd.Arguments)"
        try {
            $rc = Start-Process -FilePath $cmd.FilePath -ArgumentList $cmd.Arguments -Wait -PassThru -ErrorAction Stop
            $code = 0
            if ($rc -and $null -ne $rc.ExitCode) { $code = $rc.ExitCode }
        }
        catch {
            Write-Log "Adobe's uninstaller could not be started: $($_.Exception.Message)" 'ERROR'
            $failures++
            continue
        }
    }

    # --- Verify against the registry, not against the exit code -------------
    if ($WhatIfPreference) { continue }

    Start-Sleep -Seconds 2
    $stillThere = Test-ProductStillRegistered -P $target

    if (-not $stillThere) {
        Write-Log ("Removed {0} (exit {1})." -f $target.Label, $code) 'OK'
        $removed += $target
        continue
    }

    # Still registered. 130 is the engine declining to remove a shared component
    # another product still references - the expected answer, and success in the
    # sense that matters: nothing was broken and nothing needs retrying now.
    if ($target.Route -ne 'Msi' -and $code -eq $HdStillReferenced) {
        Write-Log "$($target.Label) is still referenced by another installed Adobe product, so Adobe's engine declined to remove it (exit 130). This is expected. Re-run after removing the applications that use it." 'WARN'
        $stillRefd++
        continue
    }

    if ($MsiSuccessCodes -contains $code -or $HdSuccessCodes -contains $code) {
        # The vendor claimed success but the key survives. Trust the registry.
        Write-Log "$($target.Label) reported exit $code but its uninstall key still exists at $($target.RegistryPath). Treating it as NOT removed." 'ERROR'
    }
    else {
        Write-Log "Uninstall FAILED for $($target.Label) with exit code $code, and its uninstall key still exists." 'ERROR'
    }
    if (Test-Path -LiteralPath $AdobeInstallLog) {
        Write-Log "    Adobe's own log has the detail: $AdobeInstallLog  (it is UTF-16LE - open it with Get-Content -Encoding Unicode)" 'WARN'
    }
    $failures++
}

# --- Residual file cleanup ------------------------------------------------
# Hard safety guard. Four refusals, each of which logs before returning $false.
function Test-SafeResidualPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }

    $full = $Path.Trim().Trim('"').TrimEnd('\')

    if ($full -match '^[a-zA-Z]:\\?$') {
        Write-Log "Refusing drive root: $full" 'WARN'
        return $false
    }
    if (($full -split '\\').Count -lt 3) {
        Write-Log "Refusing path with too few segments: $full" 'WARN'
        return $false
    }
    # An exact match on a forbidden root is refused; a path UNDER one is fine,
    # which is the whole point (C:\Program Files\Adobe is under C:\Program Files).
    foreach ($r in $ForbiddenResidualRoots) {
        if ((Get-ComparablePath $full) -eq (Get-ComparablePath $r)) {
            Write-Log "Refusing protected system root: $full" 'WARN'
            return $false
        }
    }
    # The path must NAME the vendor. This is what stops a mis-assembled residual
    # list from ever pointing at somebody else's folder.
    if ($full -notmatch '(?i)\\Adobe($|\\)') {
        Write-Log "Refusing path that does not name Adobe: $full" 'WARN'
        return $false
    }
    return $true
}

function Remove-ResidualFiles {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([string[]]$Paths)

    $count = 0
    foreach ($path in $Paths) {
        if (-not (Test-Path -LiteralPath $path)) { continue }
        if (-not (Test-SafeResidualPath $path)) { continue }

        if (-not $Force -and -not $WhatIfPreference) {
            $answer = Read-Host "Delete residual location '$path'? [Y/N]"
            if ($answer -notmatch '^(y|yes)$') {
                Write-Log "Skipped residual: $path" 'WARN'
                continue
            }
        }
        if (-not $PSCmdlet.ShouldProcess($path, 'Remove residual location')) { continue }

        try {
            Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop
            Write-Log "    removed $path"
            $count++
        }
        catch {
            # Expected while Explorer holds CoreSync_x64.dll, or an Adobe
            # background process restarted. A retry-later, not a failure -
            # treating it as fatal would abort the run after registrations are
            # already gone.
            Write-Log "    could not remove (may need a reboot): $path - $($_.Exception.Message)" 'WARN'
            $script:rebootNeeded = $true
        }
    }
    return $count
}

# --- Residual registry cleanup --------------------------------------------
function Remove-ResidualRegistryKeys {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()

    $count = 0
    $keys = @(
        'HKLM:\SOFTWARE\Adobe',
        'HKLM:\SOFTWARE\WOW6432Node\Adobe',
        'HKCU:\SOFTWARE\Adobe'
    )

    # App Paths, in BOTH registry views. Verified on this platform: Illustrator
    # and Photoshop each register in the 64-bit AND the 32-bit view, so a
    # single-view cleanup leaves Win+R resolving to a deleted binary.
    foreach ($view in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths',
                        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths')) {
        if (-not (Test-Path $view)) { continue }
        Get-ChildItem -Path $view -ErrorAction SilentlyContinue | ForEach-Object {
            $props = $null
            try { $props = Get-ItemProperty -LiteralPath $_.PsPath -ErrorAction Stop } catch { return }
            $default = Get-Prop $props '(default)'
            # Authorize on the PATH the entry points at, never on the key name.
            if ((-not [string]::IsNullOrWhiteSpace($default)) -and ($default -match '(?i)\\Adobe\\')) {
                $keys += $_.PsPath
            }
        }
    }

    # The URL protocol handlers Adobe registers. Named with a '+', which is not a
    # PowerShell wildcard but is easy to mis-glob, so they are addressed literally.
    foreach ($proto in @('adobe+ilst', 'adobe+phxs', 'adobe+ind', 'adobe+aem')) {
        $k = "HKLM:\SOFTWARE\Classes\$proto"
        if (Test-Path -LiteralPath $k) { $keys += $k }
    }

    foreach ($k in @($keys | Select-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $k)) { continue }

        # Shape guard: only ever a key that names Adobe, never a parent.
        if ($k -notmatch '(?i)(\\Adobe$|\\adobe\+|App Paths\\)') {
            Write-Log "Refusing unexpected registry key shape: $k" 'WARN'
            continue
        }

        if (-not $Force -and -not $WhatIfPreference) {
            $answer = Read-Host "Delete registry key '$k'? [Y/N]"
            if ($answer -notmatch '^(y|yes)$') {
                Write-Log "Skipped registry key: $k" 'WARN'
                continue
            }
        }
        if (-not $PSCmdlet.ShouldProcess($k, 'Remove registry key')) { continue }

        try {
            Remove-Item -LiteralPath $k -Recurse -Force -ErrorAction Stop
            Write-Log "    removed $k"
            $count++
        }
        catch {
            Write-Log "    could not remove $k : $($_.Exception.Message)" 'WARN'
        }
    }
    return $count
}

# --- Shell extension / COM cleanup ----------------------------------------
# Adobe's CoreSync registers Explorer integration under names that contain no
# vendor string at all - "AccExt" for the context menu, and three icon-overlay
# entries whose value names begin with THREE LEADING SPACES as a sort-priority
# hack. Every candidate is resolved through its CLSID to a DLL path and removed
# only when that path lies under an Adobe root.
function Remove-AdobeShellExtensions {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([string[]]$Roots)

    if ($Roots.Count -eq 0) {
        Write-Log 'Skipping shell-extension cleanup: no Adobe root was discovered, so no CLSID can be attributed.' 'WARN'
        return 0
    }

    $count = 0

    # Resolve a CLSID to the file that implements it.
    function Get-ClsidServerPath {
        param([string]$Clsid)
        foreach ($view in @('HKLM:\SOFTWARE\Classes\CLSID', 'HKLM:\SOFTWARE\Classes\WOW6432Node\CLSID')) {
            foreach ($server in @('InprocServer32', 'LocalServer32')) {
                $k = "$view\$Clsid\$server"
                if (-not (Test-Path -LiteralPath $k)) { continue }
                $props = $null
                try { $props = Get-ItemProperty -LiteralPath $k -ErrorAction Stop } catch { continue }
                $v = Get-Prop $props '(default)'
                if (-not [string]::IsNullOrWhiteSpace($v)) { return ($v.Trim().Trim('"')) }
            }
        }
        return ''
    }

    # Context-menu handlers. The '*' is a LITERAL key name in the Classes hive,
    # not a wildcard - without -LiteralPath, PowerShell expands it and walks the
    # entire Classes tree, which hangs for minutes.
    $ctxRoots = @(
        'HKLM:\SOFTWARE\Classes\*\shellex\ContextMenuHandlers',
        'HKLM:\SOFTWARE\Classes\Folder\shellex\ContextMenuHandlers',
        'HKLM:\SOFTWARE\Classes\Directory\shellex\ContextMenuHandlers',
        'HKLM:\SOFTWARE\Classes\Directory\Background\shellex\ContextMenuHandlers'
    )
    foreach ($root in $ctxRoots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue | ForEach-Object {
            $props = $null
            try { $props = Get-ItemProperty -LiteralPath $_.PsPath -ErrorAction Stop } catch { return }
            $clsid = Get-Prop $props '(default)'
            if ([string]::IsNullOrWhiteSpace($clsid) -or $clsid -notmatch '^\{[0-9A-Fa-f\-]{36}\}$') { return }

            $server = Get-ClsidServerPath -Clsid $clsid
            if ([string]::IsNullOrWhiteSpace($server)) { return }
            if (-not (Test-PathUnderAny -Path $server -Roots $Roots)) { return }

            Write-Log ("    handler '{0}' -> {1} -> {2}" -f $_.PSChildName, $clsid, $server)
            if (-not $PSCmdlet.ShouldProcess($_.PsPath, 'Remove shell extension registration')) { return }
            try {
                Remove-Item -LiteralPath $_.PsPath -Recurse -Force -ErrorAction Stop
                Write-Log "    removed context-menu handler $($_.PSChildName)"
                $script:shellRemoved++
            }
            catch { Write-Log "    could not remove $($_.PsPath): $($_.Exception.Message)" 'WARN' }
        }
    }

    # Icon overlay identifiers. The VALUE NAMES carry leading spaces - the
    # literal names are " AccExtIco1" and siblings, length 13 not 10 - so they
    # are matched on the resolved CLSID path and deleted using the exact
    # PSChildName the enumeration returned, never a name typed by hand.
    $overlayRoot = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\ShellIconOverlayIdentifiers'
    if (Test-Path -LiteralPath $overlayRoot) {
        Get-ChildItem -LiteralPath $overlayRoot -ErrorAction SilentlyContinue | ForEach-Object {
            $props = $null
            try { $props = Get-ItemProperty -LiteralPath $_.PsPath -ErrorAction Stop } catch { return }
            $clsid = Get-Prop $props '(default)'
            if ([string]::IsNullOrWhiteSpace($clsid) -or $clsid -notmatch '^\{[0-9A-Fa-f\-]{36}\}$') { return }

            $server = Get-ClsidServerPath -Clsid $clsid
            if ([string]::IsNullOrWhiteSpace($server)) { return }
            if (-not (Test-PathUnderAny -Path $server -Roots $Roots)) { return }

            # The bracketed name makes a leading-space no-op visible in the log.
            Write-Log ("    overlay '[{0}]' (len {1}) -> {2}" -f $_.PSChildName, $_.PSChildName.Length, $server)
            if (-not $PSCmdlet.ShouldProcess($_.PsPath, 'Remove icon overlay identifier')) { return }
            try {
                Remove-Item -LiteralPath $_.PsPath -Recurse -Force -ErrorAction Stop
                Write-Log "    removed icon overlay [$($_.PSChildName)]"
                $script:shellRemoved++
            }
            catch { Write-Log "    could not remove $($_.PsPath): $($_.Exception.Message)" 'WARN' }
        }
    }

    return $script:shellRemoved
}

# --- Post-uninstall cleanup -----------------------------------------------
$shellRemoved = 0

if ($failures -gt 0) {
    if ($RemoveResidualFiles -or $RemoveResidualRegistry -or $RemoveUserData -or $RemoveShellExtensions) {
        Write-Log ''
        Write-Log 'Skipping residual cleanup because at least one uninstall did not complete. Re-run after it succeeds.' 'WARN'
    }
}
elseif ($skipped -gt 0 -and $removed.Count -eq 0) {
    if ($RemoveResidualFiles -or $RemoveResidualRegistry -or $RemoveUserData -or $RemoveShellExtensions) {
        Write-Log ''
        Write-Log "Skipping residual cleanup because $skipped product(s) were declined and are still installed. Deleting their files would leave a registered product with no files." 'WARN'
    }
}
else {
    # Re-census. The question now is not what was installed, it is what actually
    # survives - which decides whether the vendor-wide plumbing may be touched.
    $remaining = @(Get-AdobeProducts | Group-Object KeyName | ForEach-Object { $_.Group[0] })

    if ($RemoveResidualFiles -and $removed.Count -gt 0) {
        Write-Log ''
        Write-Log 'Removing residual locations of the products that were uninstalled...'

        # Per-product folders. Safe regardless of what else survives, because
        # each one belongs to a product that is now gone.
        foreach ($p in $removed) {
            $paths = @(Get-ProductResidualPaths -P $p | Where-Object { Test-Path -LiteralPath $_ })
            if ($paths.Count -eq 0) { continue }
            Write-Log "  $($p.Label):"
            $null = Remove-ResidualFiles -Paths $paths
        }

        # Shortcuts, matched by resolved target. The Start Menu here also holds
        # this repo's Autodesk products, so a filename glob is not acceptable.
        $shortcuts = @(Get-AdobeShortcuts -Roots $AdobeRoots)
        foreach ($s in $shortcuts) {
            if (-not (Test-Path -LiteralPath $s.Target)) {
                if (-not $PSCmdlet.ShouldProcess($s.Path, 'Remove orphaned shortcut')) { continue }
                try {
                    Remove-Item -LiteralPath $s.Path -Force -ErrorAction Stop
                    Write-Log "    removed orphaned shortcut $($s.Path)"
                }
                catch { Write-Log "    could not remove shortcut $($s.Path): $($_.Exception.Message)" 'WARN' }
            }
        }
    }

    # VENDOR-WIDE plumbing. Every path here is shared by all Adobe products, so
    # it is touched only once NO Adobe product remains registered. This is the
    # same discipline as the FortiClient script's "vendor parent only if empty".
    if ($RemoveResidualFiles) {
        if ($remaining.Count -gt 0) {
            Write-Log ''
            Write-Log "Keeping the shared Adobe plumbing (Common Files\Adobe, Adobe Desktop Common, ProgramData\Adobe): $($remaining.Count) Adobe product(s) are still registered and need it - including the uninstaller itself. Re-run once they are gone." 'WARN'
        }
        else {
            Write-Log ''
            Write-Log 'No Adobe product remains registered; sweeping the shared Adobe plumbing.'
            $vendorPaths = @(Get-VendorResidualPaths | Where-Object { Test-Path -LiteralPath $_ })

            # Report the Microsoft-signed payload separately. Common Files\Adobe
            # holds Adobe's PRIVATE copy of the Edge WebView2 runtime - measured
            # at 557 MB on this platform - and deleting it as "Adobe residue"
            # without saying so misrepresents what is being removed.
            foreach ($vp in $vendorPaths) {
                $edge = Join-Path $vp 'Microsoft'
                if (Test-Path -LiteralPath $edge) {
                    $sz = 0
                    $sz = Get-PathSize $edge
                    Write-Log ("    note: {0} contains {1:N0} MB of Microsoft-signed Edge WebView2 runtime. This is Adobe's private copy, not the system-wide one, and it goes with the folder." -f $edge, ($sz / 1MB)) 'WARN'
                }
            }

            $null = Remove-ResidualFiles -Paths $vendorPaths
        }
    }

    if ($RemoveUserData) {
        Write-Log ''
        Write-Log 'Removing Adobe user data (-RemoveUserData)...' 'WARN'
        $userPaths = @(Get-UserDataResidualPaths | Where-Object { Test-Path -LiteralPath $_ })
        foreach ($up in $userPaths) {
            $sz = 0
            $sz = Get-PathSize $up
            Write-Log ("    {0}  ({1:N0} MB)" -f $up, ($sz / 1MB))
        }
        $null = Remove-ResidualFiles -Paths $userPaths
    }

    if ($RemoveShellExtensions) {
        Write-Log ''
        Write-Log 'Removing Adobe Explorer integration (context-menu handlers and icon overlays)...'
        $null = Remove-AdobeShellExtensions -Roots $AdobeRoots
        if ($shellRemoved -gt 0) {
            Write-Log "Removed $shellRemoved Explorer registration(s). Explorer keeps the DLL loaded until it restarts, so the file itself may survive until the next sign-in." 'WARN'
        }
        else {
            Write-Log 'No Adobe-owned Explorer registration was found.' 'OK'
        }
    }

    if ($RemoveResidualRegistry) {
        Write-Log ''
        if ($remaining.Count -gt 0) {
            Write-Log "Skipping the Adobe configuration hives: $($remaining.Count) Adobe product(s) are still registered and use them." 'WARN'
        }
        else {
            Write-Log 'Removing Adobe configuration keys...'
            $null = Remove-ResidualRegistryKeys
        }
    }
}

# --- Summary --------------------------------------------------------------
Write-Log ''
Write-Log '---------------------------------------------'
if ($failures -eq 0) {
    if ($removed.Count -gt 0) {
        Write-Log "Removed $($removed.Count) Adobe product(s):" 'OK'
        $removed | ForEach-Object { Write-Log ("    {0,-6}  {1}" -f $(if ($_.SapCode) { $_.SapCode } else { '-' }), $_.Label) 'OK' }
    }
    if ($stillRefd -gt 0) {
        Write-Log "$stillRefd shared component(s) were left in place because another installed Adobe product still references them. That is Adobe's own refcounting, not an error. Remove the remaining applications, then re-run with -IncludeSharedComponents." 'WARN'
    }
    if ($skipped -gt 0) {
        Write-Log "Completed with $skipped item(s) declined or skipped and still installed." 'WARN'
    }
    if ($removed.Count -eq 0 -and $stillRefd -eq 0 -and $skipped -eq 0) {
        Write-Log 'Completed. Nothing required removal.' 'OK'
    }
    else {
        Write-Log 'Completed. No Creative Cloud Cleaner Tool was invoked, no PDF association was rewritten, and the hosts file was not touched.' 'OK'
    }
    if ($rebootNeeded) {
        Write-Log 'A reboot (or at least an Explorer restart) is needed to release files that were still open, then re-run to finish the sweep.' 'WARN'
    }
}
else {
    Write-Log "Completed with $failures failure(s). Review the log: $LogPath" 'ERROR'
    if (Test-Path -LiteralPath $AdobeInstallLog) {
        Write-Log "Adobe's own installer log has the detail: $AdobeInstallLog" 'ERROR'
        Write-Log '    It is UTF-16LE: Get-Content -Path "<path>" -Encoding Unicode -Tail 200' 'ERROR'
    }
}
Write-Log "Log saved to: $LogPath"

try { Stop-Transcript | Out-Null } catch { }

if ($failures -gt 0)   { exit 3 }
elseif ($rebootNeeded) { exit 3010 }
else                   { exit 0 }
