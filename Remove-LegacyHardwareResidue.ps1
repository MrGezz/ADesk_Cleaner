<#
.SYNOPSIS
    Removes the driver packages, services, startup entries, ghost devnodes and
    residual files left behind on a Windows installation that was carried across
    to NEW hardware - without touching a single driver the current hardware is
    actually using.

.DESCRIPTION
    When a Windows installation is migrated to a new motherboard (or restored
    from an image taken on a different machine), the old machine's platform
    stack does not uninstall itself. It goes dormant: services flip to Disabled
    or fail to start, devnodes become "not present" phantoms, and the driver
    packages stay in the driver store forever, where nothing will ever reclaim
    them. Meanwhile vendor scheduled tasks keep firing at logon against hardware
    that no longer exists.

    This script removes that residue for the two vendors that leave the most of
    it - ASUS (Armoury Crate / ROG / ASUS System Control Interface) and Intel
    (chipset, Management Engine, RST, graphics, Smart Sound audio, Dynamic
    Tuning) - plus the generic startup residue any migration leaves behind.

    THE CENTRAL FACT, and the reason this is not a name-matching delete loop:

        A DRIVER PACKAGE IS SAFE TO REMOVE ONLY IF NO CONNECTED DEVICE IS
        BOUND TO IT, AND THAT IS A QUESTION WITH AN EXACT ANSWER.

    "pnputil /enum-devices /connected /drivers" reports, in one call, every
    driver package bound to hardware that is present RIGHT NOW. That set is
    computed first, and it is the gate every removal passes through. Nothing is
    removed because its name contains "intel" or "asus"; things are removed
    because the machine itself reports that nothing is using them.

    Seven traps this script is built around, every one of them verified on a
    real migrated machine rather than assumed:

    1. "intel" AS A SUBSTRING MATCHES INBOX WINDOWS BOOT DRIVERS. On a machine
       with an AMD Ryzen CPU and no Intel silicon whatsoever, "intelpep"
       (Intel Power Engine Plug-in) and "IntelPMT" (Platform Monitoring
       Technology) are RUNNING, at Start=Boot. They ship with Windows, they are
       not OEM packages, and deleting them is a bugcheck. So are "intelide",
       "iaStorV" and "iaStorAVC" - all inbox. A service is only ever removed
       here when it is owned by a driver package that is itself being removed,
       or when its binary is provably vendor-signed AND provably orphaned.

    2. oemNN.inf NUMBERS ARE RECYCLED. Windows reclaims an oem slot after a
       package is removed and hands the same number to an unrelated vendor. A
       package name captured at census time and used at deletion time can point
       somewhere else entirely by then. Every package is therefore RE-VERIFIED
       against a freshly-read driver-store listing immediately before deletion:
       same published name, same original INF, same provider, still unbound. If
       any of the four has drifted, the deletion is refused, not retried.

    3. THE RECORDED UNINSTALL STRING FOR A BURN-REGISTERED MSI IS AN *INSTALL*
       VERB. Verified on this platform: four ASUS HAL products register their
       MSI child with "MsiExec.exe /I{guid}" - /I, not /X. Executing that
       string verbatim, which is what a naive uninstaller loop does, asks
       Windows Installer to INSTALL or repair the product. This script rewrites
       /I to /X and appends /qn /norestart, and never executes a recorded
       string it has not parsed.

    4. THE SAME PRODUCT IS REGISTERED TWICE, AS A BUNDLE AND AS ITS MSI CHILD.
       "ASUS Aac_GmAcc HAL", "Aac_NBDT", "Ambient" and "Mouse" each appear
       twice in the uninstall hives: once as a Burn bundle in the Package
       Cache, once as the MSI it installed. Removing the child first strands
       the bundle. The bundle is always run first; the MSI child is only
       touched if it survives, or if the bundle's cached installer is gone.

    5. REALTEK IS CURRENT HARDWARE HERE, NOT RESIDUE - EVEN WHEN THE INF SAYS
       ASUS. The current board's audio, 2.5GbE NIC and Wi-Fi are all Realtek,
       and Realtek is also the *provider* of an ASUS-laptop-specific Dolby APO
       extension ("hdx_asusext_dolby_dsp_wrap_rtkgen3p1_kd.inf"). Vendor
       attribution alone would either keep the ASUS extension or delete the
       live audio stack. The live-binding gate resolves it correctly without
       needing a special case.

    6. AN INSTALLSHIELD UNINSTALL NEEDS SOURCE MEDIA THAT THIS SCRIPT DELETED.
       Two ASUS SDK entries record an InstallSource under C:\Program Files\ASUS
       - inside the very tree being cleaned. Running setup.exe -removeonly
       against them blocks the whole run on a modal "Setup Needs The Next Disk
       ... layout.bin" dialog whose banner reads "configuring your new software
       INSTALLATION", and cancelling it returns -5006 (0x80030020) with the
       registration untouched. So the source is checked BEFORE launching
       anything, the uninstaller is never started when it cannot succeed, and
       the entry is removed by registration instead. Relatedly, the verdict on
       every uninstall is taken from the REGISTRY afterwards, not from the exit
       code: vendor uninstallers report success while leaving registrations
       behind, and failure after removing everything.

    7. A DESKTOP WITH GHOST BATTERY DEVNODES STILL BEHAVES LIKE A LAPTOP.
       Migrated-from-laptop installs keep phantom "Control Method Battery" and
       "AC Adapter" ACPI devnodes, which is why a desktop can surface battery
       UI and apply on-battery power policy branches. Those phantoms are
       removed under -Scope Power.

    THREE HARD REFUSALS, checked before anything is removed:

      * If the CURRENT baseboard manufacturer matches a vendor being swept, the
        entire vendor bucket is refused. You do not sweep ASUS on an ASUS
        board.
      * If the CURRENT CPU manufacturer is GenuineIntel, the Intel buckets
        (IntelChipset / Display / Audio / Power) are refused.
      * If a vendor has ANY driver package bound to a connected device, that
        vendor is LIVE on this machine and its whole bucket is refused,
        regardless of the other two checks.

    Each refusal is reported with its evidence and does not fail the run - the
    remaining buckets still process. Together they make this script safe to run
    on a machine it was not designed against, which a hardcoded package list
    would not be.

    Reboot-awareness is built in rather than bolted on. Loaded kernel drivers
    hold their .sys files open until restart, so a first run removes
    registrations and reports what is pending; re-running after the reboot
    completes the file sweep. Every step is idempotent and treats "already
    gone" as success.

.PARAMETER Scope
    Which buckets to process. Any combination of:

      Startup      Vendor scheduled tasks, Run-key entries and orphaned
                   StartupApproved flags left by uninstalled software.
      Asus         ASUS/ROG/Armoury Crate: programs, services, driver packages,
                   the AsIO3 legacy I/O driver, Appx HALs, folders, hives.
      IntelChipset Intel chipset platform: Management Engine, DAL, LMS, RST,
                   Serial IO, GNA, Bluetooth, Wi-Fi, PCH system packages.
      Display      Intel integrated graphics: iigd/igcc/cui packages, Graphics
                   Command Center data, shader cache, ghost display adapters.
      Audio        Intel Smart Sound Technology (cAVS), Display Audio, SST for
                   USB/Bluetooth, and vendor audio APO extensions.
      Power        Intel Dynamic Tuning + Innovation Platform Framework, and
                   phantom battery / AC adapter devnodes.
      All          Every bucket above. This is the default.

    Buckets are independent: -Scope Startup,Power is a valid, useful run.

.PARAMETER ListOnly
    Census only. Reports everything that WOULD be removed, per bucket, with
    sizes and the evidence behind each decision, and changes nothing. This is
    the recommended first run, and it needs no elevation to be useful.

.PARAMETER RemoveDriverPackages
    Remove orphaned driver-store packages with "pnputil /delete-driver". Default
    $true - the driver store is where the bulk of the reclaimable space is
    (the Intel graphics package alone is typically ~1 GB) and nothing else will
    ever reclaim it. Set $false to leave the driver store untouched while still
    cleaning services, tasks, programs and files.

.PARAMETER RemovePrograms
    Run the vendor uninstallers for products still registered in Add/Remove
    Programs. Default $true. Bundles run before their MSI children; recorded
    /I verbs are rewritten to /X.

.PARAMETER RemoveResidualFiles
    Delete the vendor directories that survive the uninstallers. Default $true.
    Every path is re-checked against Test-SafeResidualPath at the moment of
    deletion; nothing at a drive root, nothing at a bare well-known root, and
    nothing that is not on the discovered census.

.PARAMETER RemoveOrphanRegistrations
    Remove Add/Remove Programs registrations whose own uninstaller cannot
    possibly run - the uninstaller binary is gone, or its recorded InstallSource
    no longer exists. Default $true.

    This exists because of a specific, verified dead end. An InstallShield
    uninstall needs the original source media, and on a migrated machine that
    media lived inside the vendor folder tree this script removes. Launching it
    pops a modal "Setup Needs The Next Disk ... layout.bin" dialog that blocks
    the entire run; cancelling returns -5006 (0x80030020) and leaves the
    registration untouched, so the next run detects the same unclean machine and
    prompts again, forever. Such entries are detected up front, never launched,
    and removed by deleting the registration plus the cached installer folder.

    Set $false to leave them listed in Add/Remove Programs. A run that does so
    and finds any exits 3, because the machine is knowingly left unclean.

.PARAMETER RemoveResidualRegistry
    Also delete the vendor configuration hives (HKLM/HKCU SOFTWARE\ASUS,
    \ASUSTeK, \Intel subkeys owned by removed products). Opt-in, because these
    hold per-product settings and are read by nothing once the products are
    gone - but they are also the only record of what was configured.

.PARAMETER RemoveGhostDevices
    Remove "not present" phantom devnodes belonging to the swept vendors, and
    (under -Scope Power) phantom battery/AC-adapter nodes. Opt-in. Scoped
    strictly to devices whose driver package is being removed or whose hardware
    ID belongs to a swept vendor - this is NOT the "remove every hidden device"
    recipe, which also eats unplugged USB devices and Bluetooth pairings.

.PARAMETER Force
    Fully non-interactive: accept every prompt, and pass silent flags to vendor
    uninstallers that support them. Use for automation, and read the transcript
    rather than the exit code alone.

.PARAMETER LogPath
    Transcript path. Defaults to a timestamped file under %TEMP%.

.EXAMPLE
    .\Remove-LegacyHardwareResidue.ps1 -ListOnly

    The recommended first run. Full census, no changes, no elevation needed.

.EXAMPLE
    .\Remove-LegacyHardwareResidue.ps1 -Scope Startup

    Just stop the dead vendor tasks firing at every logon. Fast and reversible.

.EXAMPLE
    .\Remove-LegacyHardwareResidue.ps1 -WhatIf

    Full preview of the default All run, showing every command that would be
    issued.

.EXAMPLE
    .\Remove-LegacyHardwareResidue.ps1 -Scope Asus,Display -RemoveGhostDevices

    Remove the ASUS stack and the Intel graphics stack, including their phantom
    devnodes. This is where the ~3 GB is.

.EXAMPLE
    .\Remove-LegacyHardwareResidue.ps1 -Force -RemoveResidualRegistry

    Everything, non-interactive, including the vendor config hives.

.NOTES
    Exit codes (shared with the other uninstallers in this repository):

      0     Success
      3010  Success, reboot required (loaded drivers pending file deletion)
      3     Partial failure - one or more removals did not complete
      2     Nothing matched; no changes made
      1     Aborted (elevation cancelled, invalid -LogPath, all buckets refused)

    Run -ListOnly first. Run it again after the reboot to finish the file
    sweep; the second pass is fast and usually reports only "already gone".
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [ValidateSet('Startup', 'Asus', 'IntelChipset', 'Display', 'Audio', 'Power', 'All')]
    [string[]]$Scope = @('All'),

    [switch]$ListOnly,

    [bool]$RemoveDriverPackages = $true,
    [bool]$RemovePrograms       = $true,
    [bool]$RemoveResidualFiles  = $true,
    [bool]$RemoveOrphanRegistrations = $true,

    [switch]$RemoveResidualRegistry,
    [switch]$RemoveGhostDevices,
    [switch]$Force,

    [string]$LogPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# -Force implies fully non-interactive: suppress PowerShell's own ShouldProcess
# confirmation (ConfirmImpact=High would otherwise prompt for every item).
if ($Force) { $ConfirmPreference = 'None' }

# Resolve -LogPath to a ROOTED path immediately, before anything consumes it.
# A bare filename has no parent directory, and any later Split-Path -Parent on
# it throws under $ErrorActionPreference='Stop' - after the drivers have already
# been removed. This runs BEFORE self-elevation on purpose: the relay forwards
# -LogPath to the elevated child, whose working directory is not the operator's.
if ([string]::IsNullOrWhiteSpace($LogPath)) {
    $LogPath = Join-Path $env:TEMP ("LegacyHardwareResidue_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))
}
else {
    try {
        $LogPath = [IO.Path]::GetFullPath(
            [IO.Path]::Combine((Get-Location).ProviderPath, $LogPath))
    }
    catch {
        Write-Host "Invalid -LogPath '$LogPath': $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
}

if ($Scope -contains 'All') {
    $Scope = @('Startup', 'Asus', 'IntelChipset', 'Display', 'Audio', 'Power')
}

# --- Configuration --------------------------------------------------------

# The vendors this script knows how to attribute residue to. Provider strings
# are matched against the driver store's "Provider Name" field, which is the
# vendor's own spelling and is NOT consistent: ASUS ships packages under
# "ASUSTeK Computer Inc.", "ASUSTek COMPUTER INC." and "ASUSTek Computer Inc."
# simultaneously. Matched case-insensitively on the stem only.
$VendorProfiles = @(
    [pscustomobject]@{
        Vendor          = 'Asus'
        ProviderPattern = '^asus'
        # Baseboard/system manufacturer strings that mean "this IS the current
        # machine's vendor" and must refuse the sweep.
        ChassisPattern  = 'asus'
        CpuPattern      = $null
        ServiceNames    = @(
            'ArmouryCrateControlInterface', 'ArmouryCrateDownloadTool', 'asus', 'asusm',
            'AsusAppService', 'AsusCertService', 'AsusNumPadService', 'ASUSOptimization',
            'AsusROGLSLService', 'ASUSSoftwareManager', 'ASUSSwitch', 'ASUSSystemAnalysis',
            'ASUSSystemDiagnosis', 'Asusgio3', 'AsusKeyboard', 'AsusNumpadPTP', 'AsusSAIO',
            'ATKWMIACPIIO', 'ROGKB', 'ROGMS'
        )
        TaskPaths       = @('\ASUS\')
        Roots           = @(
            'C:\Program Files\ASUS',
            'C:\Program Files (x86)\ASUS',
            'C:\ProgramData\ASUS',
            'C:\Program Files\ASUSTeK',
            'C:\Program Files (x86)\ASUSTeK',
            'C:\ProgramData\ASUSTeK',
            'C:\Windows\System32\ASUSACCI'
        )
        UserRoots       = @('ASUS', 'ASUSTeK')
        RegistryKeys    = @(
            'HKLM:\SOFTWARE\ASUS', 'HKLM:\SOFTWARE\WOW6432Node\ASUS', 'HKCU:\SOFTWARE\ASUS',
            'HKLM:\SOFTWARE\ASUSTeK', 'HKLM:\SOFTWARE\WOW6432Node\ASUSTeK', 'HKCU:\SOFTWARE\ASUSTeK'
        )
        ProgramPattern  = '^(asus|armoury|aura|rog|anime|aac_)'
        AppxPattern     = '^(asus|armoury|myasus|rog)'
    },
    [pscustomobject]@{
        Vendor          = 'Intel'
        # \b is load-bearing. A bare '^intel' also matches "IntelliTrace
        # Profiler Proxy", "WinRT Intellisense Desktop" and every other
        # Microsoft Intellisense package registered in the uninstall hives -
        # all of which would then be handed to an Intel uninstaller loop.
        # "Intel" and "Intel(R) Corporation" both satisfy '^intel\b';
        # "Intellisense" does not, because 'l' followed by 'l' is not a word
        # boundary.
        ProviderPattern = '^intel\b'
        ChassisPattern  = $null
        # An Intel CPU means the Intel platform stack is current hardware.
        CpuPattern      = 'GenuineIntel'
        ServiceNames    = @(
            'cphs', 'cplspcon', 'dptftcs', 'HfcDisableService', 'iaStorAfsService',
            'igccservice', 'igfxCUIService2.0.0.0', 'Intel(R) Platform License Manager Service',
            'Intel(R) TPM Provisioning Service', 'IntelAudioService', 'ipfsvc', 'jhi_service',
            'LMS', 'PIEServiceNew', 'RstMwService', 'WMIRegistrationService'
        )
        TaskPaths       = @('\Intel\')
        Roots           = @(
            'C:\Program Files\Intel',
            'C:\Program Files (x86)\Intel',
            'C:\ProgramData\Intel',
            'C:\Intel',
            'C:\Windows\System32\cAVS'
        )
        UserRoots       = @('Intel')
        RegistryKeys    = @(
            'HKLM:\SOFTWARE\Intel\Display', 'HKLM:\SOFTWARE\Intel\KMD', 'HKLM:\SOFTWARE\Intel\PSIS',
            'HKLM:\SOFTWARE\WOW6432Node\Intel\IRST', 'HKLM:\SOFTWARE\WOW6432Node\Intel\PSIS',
            'HKCU:\SOFTWARE\Intel\Display'
        )
        ProgramPattern  = '^intel\b'
        AppxPattern     = '^intel\b'
    }
)

# Bucket routing. This decides WHICH -Scope a discovered package belongs to; it
# NEVER decides whether the package may be removed. That authority belongs to
# the live-binding gate alone, which is why an unrecognised package still routes
# somewhere sane rather than being silently skipped or silently deleted.
$BucketInfHints = [ordered]@{
    Display = @(
        'iigd_dch', 'iigd_ext', 'igcc_dch', 'cui_dch', 'oemextension', 'msdk',
        'detectionverificationdrv', 'igdlh'
    )
    Audio   = @(
        'intcaudiobus', 'intcoed', 'intcdaud', 'intcusb', 'intcbtau', 'intcsdw',
        'intcsdwbus', 'intcdmic', 'intcsst', 'mshdadac', 'hdbusext',
        'hdxsstasus', 'hdx_asusext', 'dolby'
    )
    Power   = @(
        'dtt_sw', 'dtt_ext', 'iccwdt', 'ipf_cpu', 'ipf_acpi', 'ipf_uf',
        'lpsystemthermal', 'thermal', 'intelpmax'
    )
}

# Driver classes that route to a bucket when no INF hint matched.
$BucketClassHints = [ordered]@{
    Display = @('Display')
    Audio   = @('MEDIA', 'AudioProcessingObject', 'AudioEndpoint')
    Power   = @('Battery')
}

# Driver classes that must NEVER be swept regardless of provider or binding.
# A package in one of these classes that appears orphaned is far more likely to
# be a mis-read than a genuine leftover, and the blast radius is the machine.
# Note what is deliberately ABSENT: 'System'. Most of the residue this script
# exists to remove (asussci2.inf, heci.inf, the PCH system packages) is class
# System, so forbidding it would defeat the script.
$ForbiddenDriverClasses = @(
    'Volume', 'VolumeSnapshot', 'DiskDrive', 'Computer', 'Processor', 'HDC'
)

# Classes that are ALLOWED but flagged loudly in the census. A storage-adapter
# package that looks orphaned usually is - Intel RST on an AMD board cannot be
# doing anything - but it is the one category where being wrong costs you the
# boot volume, so the operator gets told rather than surprised.
$CautionDriverClasses = @('SCSIAdapter', 'Net')

# Kernel-mode services that are INBOX WINDOWS COMPONENTS despite their vendor
# names. Every one of these is present on machines that have never seen the
# vendor's hardware, several run at Start=Boot, and removing any is a bugcheck
# or an unbootable machine. Checked by exact name, case-insensitively.
$InboxVendorNamedServices = @(
    'intelpep', 'IntelPMT', 'intelppm', 'intelide', 'intelpmax', 'iaStorV',
    'iaStorAVC', 'iaStorAC', 'ICCWDT', 'stornvme', 'nvmedisk', 'iagpio', 'iai2c',
    'iaLPSSi_GPIO', 'iaLPSSi_I2C', 'iaLPSS2i_GPIO2', 'iaLPSS2i_I2C',
    'iaLPSS2i_GPIO2_BXT_P', 'iaLPSS2i_GPIO2_CNL', 'iaLPSS2i_GPIO2_GLK',
    'iaLPSS2i_I2C_BXT_P', 'iaLPSS2i_I2C_CNL', 'iaLPSS2i_I2C_GLK',
    'iaLPSS2_GPIO2', 'iaLPSS2_GPIO2_ADL', 'iaLPSS2_I2C_ADL', 'IntcAudioBus',
    'IntcOED', 'MEIx64', 'IntelGNA', 'ibtusb', 'Netwtw14'
)

# Roots that may NEVER be handed to Remove-Item, no matter what the census says.
# Built by string join rather than Join-Path, which throws on a null -Path when
# an environment variable is undefined on a given SKU.
$ForbiddenResidualRoots = @(
    ${env:ProgramFiles},
    ${env:ProgramFiles(x86)},
    ${env:ProgramData},
    ${env:SystemRoot},
    (@(${env:SystemRoot}, 'System32')         -join '\'),
    (@(${env:SystemRoot}, 'System32\drivers') -join '\'),
    (@(${env:SystemRoot}, 'System32\DriverStore') -join '\'),
    (@(${env:SystemRoot}, 'INF')              -join '\'),
    (@(${env:SystemDrive}, 'Users')           -join '\'),
    ${env:SystemDrive},
    ${env:LOCALAPPDATA},
    ${env:APPDATA}
) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

# Phantom ACPI devnodes that make a desktop behave like a laptop. Matched on the
# hardware ID stem, which is stable across vendors.
$LaptopPhantomDeviceIds = @('ACPI\PNP0C0A', 'ACPI\ACPI0003')

# --- Self-elevation -------------------------------------------------------
function Test-IsAdministrator {
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# -ListOnly is deliberately usable unelevated: the census reads registry hives,
# the driver store and the PnP tree, all of which are world-readable. Forcing a
# UAC prompt to answer "what would you remove?" is the fastest way to make an
# operator skip the preview step, which is the one step that matters.
if (-not $ListOnly -and -not (Test-IsAdministrator)) {
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
    # self-elevation. The relay goes through -Command, which CAN bind [bool],
    # so the three [bool] parameters are forwarded by value; the switches use
    # the conditional-append form.
    $passArgs = @()
    $passArgs += ('-Scope {0}' -f (($Scope | ForEach-Object { "'$_'" }) -join ','))
    $passArgs += ('-RemoveDriverPackages:${0}' -f $RemoveDriverPackages)
    $passArgs += ('-RemovePrograms:${0}'       -f $RemovePrograms)
    $passArgs += ('-RemoveResidualFiles:${0}'  -f $RemoveResidualFiles)
    $passArgs += ('-RemoveOrphanRegistrations:${0}' -f $RemoveOrphanRegistrations)
    if ($RemoveResidualRegistry) { $passArgs += '-RemoveResidualRegistry' }
    if ($RemoveGhostDevices)     { $passArgs += '-RemoveGhostDevices' }
    if ($Force)                  { $passArgs += '-Force' }

    # COMMON parameters live OUTSIDE param(), so a relay assembled from this
    # script's own parameter list silently drops them at the UAC boundary.
    if ($WhatIfPreference)      { $passArgs += '-WhatIf' }
    if ($VerbosePreference -eq 'Continue') { $passArgs += '-Verbose' }
    $passArgs += ("-LogPath '{0}'" -f $LogPath)

    $inner = "& '{0}' {1}; exit `$LASTEXITCODE" -f $PSCommandPath, ($passArgs -join ' ')
    $psExe = (Get-Process -Id $PID).Path
    if ([string]::IsNullOrWhiteSpace($psExe)) { $psExe = 'powershell.exe' }

    try {
        $p = Start-Process -FilePath $psExe `
                           -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $inner) `
                           -Verb RunAs -Wait -PassThru
        exit $p.ExitCode
    }
    catch {
        Write-Host "Elevation was cancelled or failed: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
}

# --- Logging --------------------------------------------------------------
try {
    $logDir = Split-Path -Parent $LogPath
    if ($logDir -and -not (Test-Path $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }
    Start-Transcript -Path $LogPath -Append | Out-Null
    $script:TranscriptStarted = $true
}
catch {
    Write-Host "Could not start transcript at '$LogPath': $($_.Exception.Message)" -ForegroundColor Yellow
    $script:TranscriptStarted = $false
}

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $ts = Get-Date -Format 'HH:mm:ss'
    $color = switch ($Level) {
        'WARN'   { 'Yellow' }
        'ERROR'  { 'Red' }
        'OK'     { 'Green' }
        'REFUSE' { 'Magenta' }
        'HEAD'   { 'Cyan' }
        default  { 'Gray' }
    }
    Write-Host ("[{0}] {1,-6} {2}" -f $ts, $Level, $Message) -ForegroundColor $color
}

function Write-Section {
    param([string]$Title)
    Write-Host ''
    Write-Log ('=' * 72) 'HEAD'
    Write-Log $Title 'HEAD'
    Write-Log ('=' * 72) 'HEAD'
}

# EVERY native command in this script goes through this, never through a bare
# "& pnputil.exe ... 2>&1". In Windows PowerShell 5.1, redirecting a native
# command's stderr with 2>&1 while $ErrorActionPreference is 'Stop' promotes any
# stderr line to a TERMINATING NativeCommandError. Both pnputil and sc.exe write
# ordinary informational text to stderr, so a bare call would abort the run in
# the middle of driver removal - registrations already deleted, files not yet
# cleaned, which is the worst state this script can leave. The preference is
# lowered in FUNCTION scope (it does not leak back out) and the exit code is
# returned for the caller to branch on.
function Invoke-NativeCommand {
    param([string]$FilePath, [string[]]$Arguments, [switch]$Quiet)

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
    if (-not $Quiet) {
        foreach ($line in $out) {
            $t = [string]$line
            if (-not [string]::IsNullOrWhiteSpace($t)) { Write-Log "      $t" }
        }
    }
    return [pscustomobject]@{ ExitCode = $code; Output = $out }
}

# --- StrictMode-safe helpers ----------------------------------------------

# Returns the value or $null, never throws when the registry key lacks the
# requested value. $Obj is $null whenever Get-ItemProperty was handed a registry
# key that has ZERO values - normal for container keys - and dereferencing
# .PSObject on $null is a terminating error under StrictMode, so this must be
# checked BEFORE the lookup, not after.
function Get-Prop {
    param($Obj, [string]$Name)
    if ($null -eq $Obj) { return $null }
    $p = $Obj.PSObject.Properties[$Name]
    if ($null -ne $p) { return $p.Value }
    return $null
}

function ConvertTo-IntOrZero {
    param($Value)
    if ($null -eq $Value) { return 0 }
    $n = 0
    if ([int]::TryParse([string]$Value, [ref]$n)) { return $n }
    return 0
}

# Normalize a directory path for comparison: trim quotes and trailing
# separators, collapse doubled separators, lower-case it.
function Get-ComparablePath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    $p = $Path.Trim().Trim('"')
    $p = $p -replace '\\{2,}', '\'
    return $p.TrimEnd('\', '/').ToLowerInvariant()
}

function Get-FolderSizeMB {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return 0 }
    try {
        $sum = (Get-ChildItem -LiteralPath $Path -Recurse -Force -File -ErrorAction SilentlyContinue |
                Measure-Object -Property Length -Sum).Sum
        if ($null -eq $sum) { return 0 }
        return [math]::Round($sum / 1MB, 1)
    }
    catch { return 0 }
}

# --- Machine identity -----------------------------------------------------

function Get-MachineIdentity {
    $board = $null; $sys = $null; $cpu = $null
    try { $board = Get-CimInstance Win32_BaseBoard -ErrorAction Stop } catch { }
    try { $sys   = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop } catch { }
    try { $cpu   = Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -First 1 } catch { }

    [pscustomobject]@{
        BoardManufacturer  = if ($board) { [string]$board.Manufacturer } else { '' }
        BoardProduct       = if ($board) { [string]$board.Product } else { '' }
        SystemManufacturer = if ($sys)   { [string]$sys.Manufacturer } else { '' }
        SystemModel        = if ($sys)   { [string]$sys.Model } else { '' }
        CpuName            = if ($cpu)   { [string]$cpu.Name } else { '' }
        CpuManufacturer    = if ($cpu)   { [string]$cpu.Manufacturer } else { '' }
    }
}

# --- Driver store ---------------------------------------------------------

# Parse "pnputil /enum-drivers" into objects. The output is stanza-based and
# LOCALIZED: field labels differ on a non-English Windows. The published name is
# therefore matched structurally, on the stable "oemNN.inf" shape rather than on
# the label in front of it; the other three fields do use English labels and
# degrade to empty strings when they do not match.
#
# That degradation is safe in exactly one direction, which is why it is
# acceptable: an empty Provider matches no vendor pattern, so the package is
# never selected for removal. A localized Windows under-collects here. It does
# not over-collect.
function Get-DriverPackages {
    $res = Invoke-NativeCommand -FilePath 'pnputil.exe' -Arguments @('/enum-drivers') -Quiet
    if ($res.ExitCode -ne 0 -and $res.Output.Count -eq 0) {
        Write-Log 'pnputil /enum-drivers returned nothing; driver-store work will be skipped.' 'WARN'
        return @()
    }
    $text = ($res.Output | ForEach-Object { [string]$_ }) -join "`n"

    $packages = @()
    foreach ($stanza in ($text -split "`n\s*`n")) {
        $pub = [regex]::Match($stanza, '(?im)^\s*[^:\r\n]*:\s*(oem\d+\.inf)\s*$')
        if (-not $pub.Success) { continue }

        $orig = [regex]::Match($stanza, '(?im)^\s*Original Name:\s*(\S+)\s*$')
        $prov = [regex]::Match($stanza, '(?im)^\s*Provider Name:\s*(.+?)\s*$')
        $cls  = [regex]::Match($stanza, '(?im)^\s*Class Name:\s*(.+?)\s*$')
        $ver  = [regex]::Match($stanza, '(?im)^\s*Driver Version:\s*(.+?)\s*$')

        $packages += [pscustomobject]@{
            Published = $pub.Groups[1].Value.ToLowerInvariant()
            Original  = if ($orig.Success) { $orig.Groups[1].Value.ToLowerInvariant() } else { '' }
            Provider  = if ($prov.Success) { $prov.Groups[1].Value.Trim() } else { '' }
            Class     = if ($cls.Success)  { $cls.Groups[1].Value.Trim() } else { '' }
            Version   = if ($ver.Success)  { $ver.Groups[1].Value.Trim() } else { '' }
        }
    }
    return $packages
}

# THE SAFETY GATE. One call returns every driver package bound to a device that
# is present and started right now. Anything in this set is load-bearing and is
# never removed, whatever its name or provider says.
#
# This function FAILS CLOSED. If the binding map cannot be computed, it returns
# Reliable=$false and the caller disables driver-store removal entirely. An
# empty binding map is indistinguishable from "nothing is in use", and acting on
# that reading would authorise deleting every driver on the machine - so an
# empty result is treated as a broken gate, not as permission.
function Get-LiveDriverPackageNames {
    $set = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)

    $res  = Invoke-NativeCommand -FilePath 'pnputil.exe' `
                                 -Arguments @('/enum-devices', '/connected', '/drivers') -Quiet
    $text = ($res.Output | ForEach-Object { [string]$_ }) -join "`n"
    foreach ($m in [regex]::Matches($text, '(?i)\b(oem\d+\.inf)\b')) {
        [void]$set.Add($m.Groups[1].Value.ToLowerInvariant())
    }
    if ($set.Count -gt 0) {
        return [pscustomobject]@{ Names = $set; Reliable = $true; Source = 'pnputil /enum-devices /connected /drivers' }
    }

    # Fallback for Windows builds where that pnputil verb is unavailable (it
    # arrived in Windows 10 1903). Two bulk calls and an in-memory join - NOT a
    # per-device Get-PnpDeviceProperty loop, which takes minutes on a machine
    # with a few hundred devnodes and is the reason this path is written out
    # rather than reached for first.
    Write-Log 'pnputil binding map was empty; falling back to Win32_PnPSignedDriver.' 'WARN'
    try {
        $present = @{}
        Get-PnpDevice -ErrorAction Stop |
            Where-Object { $_.Status -eq 'OK' } |
            ForEach-Object { $present[[string]$_.InstanceId] = $true }

        Get-CimInstance Win32_PnPSignedDriver -ErrorAction Stop |
            Where-Object { $_.DeviceID -and $_.InfName -like 'oem*' } |
            ForEach-Object {
                if ($present.ContainsKey([string]$_.DeviceID)) {
                    [void]$set.Add(([string]$_.InfName).ToLowerInvariant())
                }
            }
    }
    catch {
        Write-Log "Binding-map fallback failed: $($_.Exception.Message)" 'ERROR'
        return [pscustomobject]@{ Names = $set; Reliable = $false; Source = 'unavailable' }
    }

    if ($set.Count -eq 0) {
        return [pscustomobject]@{ Names = $set; Reliable = $false; Source = 'empty' }
    }
    return [pscustomobject]@{ Names = $set; Reliable = $true; Source = 'Win32_PnPSignedDriver' }
}

# Route a package to a -Scope bucket. Hints first (specific), class second
# (general), vendor default last.
function Get-PackageBucket {
    param($Package, [string]$Vendor)

    foreach ($bucket in $BucketInfHints.Keys) {
        foreach ($hint in $BucketInfHints[$bucket]) {
            if ($Package.Original -like "*$hint*") { return $bucket }
        }
    }
    foreach ($bucket in $BucketClassHints.Keys) {
        if ($BucketClassHints[$bucket] -contains $Package.Class) { return $bucket }
    }
    if ($Vendor -eq 'Asus') { return 'Asus' }
    return 'IntelChipset'
}

# Re-verify a package immediately before deletion. oemNN slots are recycled, so
# a name captured at census time can point at another vendor's package by the
# time we act on it. All four facts must still hold, or the deletion is refused.
function Test-PackageStillRemovable {
    param($Package, $FreshPackages, $LiveNames)

    $now = $FreshPackages | Where-Object { $_.Published -eq $Package.Published }
    if (-not $now) {
        Write-Log "      SKIP $($Package.Published): no longer in the driver store (already removed)." 'INFO'
        return $false
    }
    if ($now.Original -ne $Package.Original) {
        Write-Log "      REFUSE $($Package.Published): INF changed '$($Package.Original)' -> '$($now.Original)'. The oem slot was recycled." 'REFUSE'
        return $false
    }
    if ($now.Provider -ne $Package.Provider) {
        Write-Log "      REFUSE $($Package.Published): provider changed '$($Package.Provider)' -> '$($now.Provider)'." 'REFUSE'
        return $false
    }
    if ($LiveNames.Contains($Package.Published)) {
        Write-Log "      REFUSE $($Package.Published) ($($Package.Original)): now bound to a connected device." 'REFUSE'
        return $false
    }
    if ($ForbiddenDriverClasses -contains $Package.Class) {
        Write-Log "      REFUSE $($Package.Published): class '$($Package.Class)' is never swept." 'REFUSE'
        return $false
    }
    return $true
}

# --- Services -------------------------------------------------------------

function Resolve-ServiceImagePath {
    param([string]$ImagePath)
    if ([string]::IsNullOrWhiteSpace($ImagePath)) { return '' }
    $p = $ImagePath.Trim()
    $p = $p -replace '^\\\?\?\\', ''
    $p = $p -replace '^"([^"]+)".*$', '$1'
    if ($p -match '^\\SystemRoot\\') { $p = $p -replace '^\\SystemRoot\\', ($env:SystemRoot + '\') }
    elseif ($p -match '^system32\\') { $p = $env:SystemRoot + '\' + $p }
    elseif ($p -match '^\\Windows\\') { $p = $env:SystemDrive + $p }
    # Strip trailing command-line arguments from an unquoted path.
    if ($p -notmatch '^"') { $p = ($p -split '\s+(?=[-/])')[0] }
    return $p.Trim().Trim('"')
}

function Get-BinaryCompany {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    try {
        $vi = [Diagnostics.FileVersionInfo]::GetVersionInfo($Path)
        $c = $vi.CompanyName
        if ($null -eq $c) { return '' }
        return [string]$c
    }
    catch { return '' }
}

# Discover the vendor's services with EVIDENCE, not just names. Each result
# carries why it was selected, and whether it is safe to delete.
function Get-VendorServices {
    param($VendorProfile, $RemovablePackageDirs)

    $results = @()
    $svcRoot = 'HKLM:\SYSTEM\CurrentControlSet\Services'
    if (-not (Test-Path $svcRoot)) { return $results }

    foreach ($key in (Get-ChildItem -Path $svcRoot -ErrorAction SilentlyContinue)) {
        $name = $key.PSChildName

        # TRAP 1: inbox Windows components with vendor names. Exact-match veto,
        # checked before any other consideration.
        if ($InboxVendorNamedServices -contains $name) { continue }

        $props = $null
        try { $props = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction Stop } catch { continue }

        $img   = [string](Get-Prop $props 'ImagePath')
        $disp  = [string](Get-Prop $props 'DisplayName')
        $start = ConvertTo-IntOrZero (Get-Prop $props 'Start')
        $file  = Resolve-ServiceImagePath $img

        $onList  = ($VendorProfile.ServiceNames -contains $name)
        $company = Get-BinaryCompany $file
        $byCo    = ($company -and ($company -match $VendorProfile.ProviderPattern))
        $cmp     = Get-ComparablePath $file
        $inPkg   = $false
        foreach ($d in $RemovablePackageDirs) {
            if ($cmp -and $cmp.StartsWith((Get-ComparablePath $d))) { $inPkg = $true; break }
        }

        if (-not ($onList -or $byCo -or $inPkg)) { continue }

        # A service whose binary is gone is an orphan registration: nothing can
        # start it, and it is safe to delete without stopping anything.
        $missing = (-not [string]::IsNullOrWhiteSpace($file)) -and (-not (Test-Path -LiteralPath $file))

        $evidence = @()
        if ($onList)  { $evidence += 'name on vendor list' }
        if ($byCo)    { $evidence += "binary CompanyName='$company'" }
        if ($inPkg)   { $evidence += 'binary inside a removable driver package' }
        if ($missing) { $evidence += 'binary MISSING (orphan registration)' }

        $live = $null
        try { $live = Get-Service -Name $name -ErrorAction Stop } catch { }

        $results += [pscustomobject]@{
            Name       = $name
            Display    = $disp
            ImagePath  = $img
            File       = $file
            StartValue = $start
            Status     = if ($live) { [string]$live.Status } else { 'Absent' }
            Missing    = $missing
            InPackage  = $inPkg
            Evidence   = ($evidence -join '; ')
        }
    }
    return $results
}

# --- Startup --------------------------------------------------------------

function Get-VendorScheduledTasks {
    param($VendorProfile)
    $out = @()
    foreach ($path in $VendorProfile.TaskPaths) {
        $tasks = $null
        try { $tasks = Get-ScheduledTask -TaskPath $path -ErrorAction Stop } catch { continue }
        foreach ($t in $tasks) {
            $actions = @()
            $anyMissing = $false
            foreach ($a in $t.Actions) {
                $exe = ''
                try { $exe = [string]$a.Execute } catch { }
                if ($exe) {
                    $clean = $exe.Trim().Trim('"')
                    $actions += $clean
                    if (-not (Test-Path -LiteralPath $clean)) { $anyMissing = $true }
                }
            }
            $out += [pscustomobject]@{
                TaskPath   = $t.TaskPath
                TaskName   = $t.TaskName
                State      = [string]$t.State
                Actions    = ($actions -join '; ')
                ExeMissing = $anyMissing
            }
        }
    }
    return $out
}

# StartupApproved holds the enabled/disabled flag that Task Manager's Startup
# tab shows. Entries survive the uninstall of the program they describe, and
# then sit in the list forever as ghosts with no command behind them. Matching
# is by NAME against the live Run values and Startup folder contents, so this
# finds orphans from any vendor - which is the point: migration leaves these
# behind for everything, not just ASUS and Intel.
function Get-OrphanStartupApprovals {
    $runNames = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($k in @(
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\RunOnce')) {
        if (-not (Test-Path $k)) { continue }
        $p = $null
        try { $p = Get-ItemProperty -LiteralPath $k -ErrorAction Stop } catch { continue }
        if ($null -eq $p) { continue }
        foreach ($prop in $p.PSObject.Properties) {
            if ($prop.Name -notlike 'PS*') { [void]$runNames.Add($prop.Name) }
        }
    }

    foreach ($d in @(
        (Join-Path $env:APPDATA     'Microsoft\Windows\Start Menu\Programs\Startup'),
        (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\Startup'))) {
        if (-not (Test-Path -LiteralPath $d)) { continue }
        Get-ChildItem -LiteralPath $d -Force -ErrorAction SilentlyContinue |
            ForEach-Object { [void]$runNames.Add($_.Name) }
    }

    $out = @()
    foreach ($k in @(
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run32',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run32',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder')) {
        if (-not (Test-Path $k)) { continue }
        $p = $null
        try { $p = Get-ItemProperty -LiteralPath $k -ErrorAction Stop } catch { continue }
        if ($null -eq $p) { continue }
        foreach ($prop in $p.PSObject.Properties) {
            if ($prop.Name -like 'PS*') { continue }
            if ($runNames.Contains($prop.Name)) { continue }
            $out += [pscustomobject]@{ Key = $k; ValueName = $prop.Name }
        }
    }
    return $out
}

# Resolve the executable a Run-key command actually launches.
#
# THIS IS NOT THE SAME PROBLEM AS A SERVICE ImagePath, and using the service
# resolver here produces a FALSE "target missing" on any entry that passes a
# bare argument. Verified: Autodesk's Desktop Connector registers
#
#     C:\Program Files\Autodesk\...\DesktopConnector.Applications.Tray.exe StartType:Auto
#
# - unquoted path, unquoted argument, and the argument has no leading dash or
# slash to split on. Treating the whole string as a path finds no file and
# condemns a perfectly healthy entry.
#
# Windows resolves unquoted commands by trying successively longer prefixes
# until one names a real file. This reproduces that, and FAILS SAFE: when no
# prefix resolves and no executable extension is present at all, it returns
# $null, which the caller reads as "unknown", never as "dead".
function Resolve-RunCommandTarget {
    param([string]$Command)

    if ([string]::IsNullOrWhiteSpace($Command)) { return $null }
    $c = $Command.Trim()

    # A quoted target is unambiguous by construction.
    if ($c -match '^\s*"([^"]+)"') { return $Matches[1] }

    $c = [Environment]::ExpandEnvironmentVariables($c)

    # Every position where an executable extension ends at a token boundary is a
    # candidate split point. The first one that names a real file wins.
    $extPattern = '(?i)\.(exe|com|bat|cmd|scr|pif)(?=\s|$)'
    $matches1 = [regex]::Matches($c, $extPattern)
    foreach ($m in $matches1) {
        $cand = $c.Substring(0, $m.Index + $m.Length)
        if (Test-Path -LiteralPath $cand) { return $cand }
    }

    # Nothing resolved. Report the first candidate so the caller can say
    # "missing" about a concrete path rather than about the whole command line.
    if ($matches1.Count -gt 0) {
        return $c.Substring(0, $matches1[0].Index + $matches1[0].Length)
    }
    return $null
}

# Run-key entries whose target file no longer exists, or that belong to a swept
# vendor. Discovery-driven: nothing is assumed to be present, and an entry whose
# target cannot be resolved is left strictly alone.
function Get-DeadRunEntries {
    param($VendorPatterns)
    $out = @()
    foreach ($k in @(
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run')) {
        if (-not (Test-Path $k)) { continue }
        $p = $null
        try { $p = Get-ItemProperty -LiteralPath $k -ErrorAction Stop } catch { continue }
        if ($null -eq $p) { continue }
        foreach ($prop in $p.PSObject.Properties) {
            if ($prop.Name -like 'PS*') { continue }
            $cmd = [string]$prop.Value
            $exe = Resolve-RunCommandTarget $cmd

            $isVendor = $false
            foreach ($pat in $VendorPatterns) {
                # Unanchored here: the vendor's name is in the PATH, not
                # necessarily at the start of the value name.
                if ("$($prop.Name) $cmd" -match ($pat -replace '^\^', '')) { $isVendor = $true; break }
            }

            # Dead ONLY when a concrete target was resolved and it is absent.
            # $exe of $null means "could not tell", which is never dead.
            $dead = ($null -ne $exe) -and (-not (Test-Path -LiteralPath $exe))

            if ($dead -or $isVendor) {
                $out += [pscustomobject]@{
                    Key       = $k
                    ValueName = $prop.Name
                    Command   = $cmd
                    Target    = $exe
                    Dead      = $dead
                    Vendor    = $isVendor
                }
            }
        }
    }
    return $out
}

# --- Programs -------------------------------------------------------------

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
            try { $props = Get-ItemProperty -LiteralPath $_.PsPath -ErrorAction Stop } catch { return }
            [pscustomobject]@{
                DisplayName          = [string](Get-Prop $props 'DisplayName')
                DisplayVersion       = [string](Get-Prop $props 'DisplayVersion')
                Publisher            = [string](Get-Prop $props 'Publisher')
                UninstallString      = [string](Get-Prop $props 'UninstallString')
                QuietUninstallString = [string](Get-Prop $props 'QuietUninstallString')
                WindowsInstaller     = ConvertTo-IntOrZero (Get-Prop $props 'WindowsInstaller')
                SystemComponent      = ConvertTo-IntOrZero (Get-Prop $props 'SystemComponent')
                BundleCachePath      = [string](Get-Prop $props 'BundleCachePath')
                InstallSource        = [string](Get-Prop $props 'InstallSource')
                KeyName              = $_.PSChildName
                RegistryPath         = $_.PsPath
            }
        }
    }
}

# TRAP 3 and TRAP 4 live here. Classify each registered product so the caller
# knows (a) how to invoke its uninstaller correctly and (b) what order to do it
# in. A product with NO DisplayName is invisible in Add/Remove Programs and is
# exactly the kind of thing left behind - it is included, identified by its
# InstallShield setup.ini product name where one exists.
function Get-VendorPrograms {
    param($VendorProfile)

    $all = @(Get-InstalledPrograms)
    $matched = @()
    foreach ($p in $all) {
        # PUBLISHER IS THE AUTHORITY HERE, NOT DisplayName. Two reasons, both
        # verified on a real migrated machine:
        #
        #   * The entries most worth removing have NO DisplayName at all. Two
        #     ASUS SDK products register with a blank name, which makes them
        #     invisible in Add/Remove Programs and unfindable by any
        #     name-driven sweep. Their Publisher is populated.
        #   * DisplayName matching produces false positives that an uninstaller
        #     loop would happily execute. "IntelliTraceProfilerProxy" and
        #     eighteen "WinRT Intellisense ..." packages all begin with the
        #     letters i-n-t-e-l and are published by MICROSOFT. Handing those
        #     to an Intel cleanup is how a cleanup script uninstalls Visual
        #     Studio components.
        #
        # A blank Publisher is the only case where a name decides anything.
        $pub  = [string]$p.Publisher
        $name = [string]$p.DisplayName
        $isVendor = $false
        if (-not [string]::IsNullOrWhiteSpace($pub)) {
            $isVendor = ($pub -match $VendorProfile.ProviderPattern)
        }
        elseif (-not [string]::IsNullOrWhiteSpace($name)) {
            $isVendor = ($name -match $VendorProfile.ProgramPattern)
        }
        if (-not $isVendor) { continue }

        $kind = 'Msi'
        $cmd  = $null
        $uargs = @()

        $us = $p.UninstallString
        if ([string]::IsNullOrWhiteSpace($us)) { continue }

        if ($us -match '(?i)Package Cache\\\{[^}]+\}\\.+\.exe') {
            # Burn bundle. Its own /uninstall removes the MSI child too, so this
            # must run FIRST and the child must not be touched until it has.
            $kind = 'Bundle'
            $cmd  = ($us -replace '(?i)^\s*"?([^"]+\.exe)"?.*$', '$1')
            $uargs = @('/uninstall', '/norestart')
            if ($Force) { $uargs += '/quiet' } else { $uargs += '/passive' }
        }
        elseif ($us -match '(?i)msiexec') {
            # TRAP 3: the recorded verb is frequently /I (install), not /X.
            # Never execute the recorded string; rebuild it from the GUID.
            $guid = [regex]::Match($us, '(\{[0-9A-Fa-f-]{36}\})')
            if (-not $guid.Success) { continue }
            $kind = 'Msi'
            $cmd  = 'msiexec.exe'
            $uargs = @('/X', $guid.Groups[1].Value, '/qn', '/norestart')
        }
        elseif ($us -match '(?i)InstallShield Installation Information') {
            $kind = 'InstallShield'
            $cmd  = ($us -replace '(?i)^\s*"?([^"]+\.exe)"?.*$', '$1')
            $uargs = @('-runfromtemp', '-removeonly')
            if ($Force) { $uargs += '-s' }
            # These entries usually have no DisplayName. Recover the real product
            # name from the cached setup.ini so the operator knows what it is.
            if ([string]::IsNullOrWhiteSpace($name)) {
                $ini = Join-Path (Split-Path -Parent $cmd) 'setup.ini'
                if (Test-Path -LiteralPath $ini) {
                    $m = Select-String -LiteralPath $ini -Pattern '^\s*Product\s*=\s*(.+)$' -ErrorAction SilentlyContinue |
                         Select-Object -First 1
                    if ($m) { $name = "$($m.Matches[0].Groups[1].Value.Trim()) (no DisplayName)" }
                }
            }
        }
        else {
            $kind = 'Exe'
            $cmd  = ($us -replace '(?i)^\s*"?([^"]+\.exe)"?.*$', '$1')
            $uargs = @()
            if (-not [string]::IsNullOrWhiteSpace($p.QuietUninstallString)) {
                $cmd  = ($p.QuietUninstallString -replace '(?i)^\s*"?([^"]+\.exe)"?.*$', '$1')
                $uargs = @()
            }
        }

        if ([string]::IsNullOrWhiteSpace($name)) { $name = "(unnamed) $($p.KeyName)" }

        # TRAP 7: AN INSTALLSHIELD UNINSTALL NEEDS THE ORIGINAL SOURCE MEDIA,
        # AND ON A MIGRATED MACHINE THAT MEDIA IS INSIDE THE FOLDER TREE THIS
        # SCRIPT JUST DELETED.
        #
        # Verified on this platform. Two ASUS SDK entries record:
        #
        #   InstallSource = C:\Program Files\ASUS\ACOnePackageTemp\ZipTemp\2.01.56\
        #   InstallSource = C:\Program Files\ASUS\RLSDownload\ROG CHAKRAM CORE\...
        #
        # Running setup.exe -removeonly against either pops a MODAL, BLOCKING
        # "Setup Needs The Next Disk - please insert disk 1 that contains the
        # file layout.bin" dialog, with the banner reading "configuring your new
        # software INSTALLATION". Cancelling it returns -5006 (0x80030020) and
        # leaves the registration exactly where it was, so the next run finds it
        # again and prompts again, forever. Feeding it a layout.bin risks the
        # install path rather than the remove path.
        #
        # So the source is checked FIRST and the uninstaller is never launched
        # when it cannot possibly succeed. The entry is reclassified as an
        # orphan registration and removed by deleting the registration and the
        # cached installer folder, which is the only reachable outcome.
        $srcPath   = [string]$p.InstallSource
        $srcExists = $true
        if (-not [string]::IsNullOrWhiteSpace($srcPath)) {
            $srcExists = Test-Path -LiteralPath $srcPath
        }
        $reachable = $true
        $unreachableReason = ''
        if ($kind -eq 'InstallShield' -and -not $srcExists) {
            $reachable = $false
            $unreachableReason = "InstallSource '$srcPath' no longer exists; setup.exe would block on a 'needs the next disk' prompt"
        }
        elseif ($kind -ne 'Msi' -and -not [string]::IsNullOrWhiteSpace($cmd) -and
                -not (Test-Path -LiteralPath $cmd)) {
            $reachable = $false
            $unreachableReason = "uninstaller '$cmd' is missing"
        }

        # The InstallShield per-product cache folder, which is what has to go
        # with the registration. Derived from the uninstaller path, never guessed.
        $cacheDir = ''
        if ($kind -eq 'InstallShield' -and -not [string]::IsNullOrWhiteSpace($cmd)) {
            $cacheDir = Split-Path -Parent $cmd
        }

        $matched += [pscustomobject]@{
            Name              = $name
            Version           = $p.DisplayVersion
            Publisher         = $p.Publisher
            Kind              = $kind
            Command           = $cmd
            Arguments         = $uargs
            KeyName           = $p.KeyName
            RegistryPath      = $p.RegistryPath
            InstallSource     = $srcPath
            SourceExists      = $srcExists
            Reachable         = $reachable
            UnreachableReason = $unreachableReason
            CacheDir          = $cacheDir
            Raw               = $us
        }
    }

    # TRAP 4: bundles before their MSI children, InstallShield last (it is the
    # most likely to need a UI and the least likely to matter).
    $order = @{ 'Bundle' = 0; 'Exe' = 1; 'Msi' = 2; 'InstallShield' = 3 }
    return @($matched | Sort-Object @{ Expression = { $order[$_.Kind] } }, Name)
}

# --- Devices --------------------------------------------------------------

# Phantom devnodes for the swept vendors. Deliberately NOT the "remove every
# hidden device" recipe: that also removes unplugged USB devices, Bluetooth
# pairings and volume snapshots, which is how people lose working peripherals.
function Get-GhostDevices {
    param([string[]]$ProviderPatterns, [string[]]$ExtraHardwareIds, [switch]$IncludePhantomBattery)

    $out = @()
    $devices = @()
    try { $devices = @(Get-PnpDevice -ErrorAction Stop | Where-Object { $_.Status -ne 'OK' }) }
    catch { return $out }

    foreach ($d in $devices) {
        $keep = $false
        $why  = ''

        $mfg = ''
        try { $mfg = [string]$d.Manufacturer } catch { }

        foreach ($pat in $ProviderPatterns) {
            if ($mfg -match $pat)                  { $keep = $true; $why = "manufacturer '$mfg'"; break }
            if ([string]$d.FriendlyName -match $pat) { $keep = $true; $why = 'friendly name'; break }
        }
        if (-not $keep -and $IncludePhantomBattery) {
            foreach ($hid in $ExtraHardwareIds) {
                if ([string]$d.InstanceId -like "$hid*") {
                    $keep = $true; $why = 'phantom laptop power devnode'; break
                }
            }
        }
        if (-not $keep) { continue }

        $out += [pscustomobject]@{
            Status       = [string]$d.Status
            Class        = [string]$d.Class
            FriendlyName = [string]$d.FriendlyName
            InstanceId   = [string]$d.InstanceId
            Reason       = $why
        }
    }
    return $out
}

# --- Residual paths -------------------------------------------------------

# Nothing at a drive root, nothing at a bare well-known root, nothing shallower
# than two path segments below the drive. Re-checked at the moment of deletion,
# not only at census time.
function Test-SafeResidualPath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    $cmp = Get-ComparablePath $Path
    if ([string]::IsNullOrWhiteSpace($cmp)) { return $false }

    foreach ($f in $ForbiddenResidualRoots) {
        if ($cmp -eq (Get-ComparablePath $f)) { return $false }
    }

    try {
        $qual = Split-Path -Qualifier $Path -ErrorAction Stop
        if ((Get-ComparablePath $Path) -eq (Get-ComparablePath $qual)) { return $false }
    }
    catch { return $false }

    $segments = @($cmp -split '\\' | Where-Object { $_ -ne '' })
    if ($segments.Count -lt 2) { return $false }

    return $true
}

function Get-VendorRoots {
    param($VendorProfile)
    $out = @()
    foreach ($r in $VendorProfile.Roots) {
        if (Test-Path -LiteralPath $r) {
            $out += [pscustomobject]@{ Path = $r; SizeMB = (Get-FolderSizeMB $r) }
        }
    }
    # Per-user folders, for every profile on the machine - a migrated image
    # frequently has more than one.
    $userDirs = @()
    try {
        $userDirs = @(Get-ChildItem -LiteralPath (Join-Path $env:SystemDrive 'Users') -Directory -Force -ErrorAction Stop)
    }
    catch { }
    foreach ($u in $userDirs) {
        foreach ($leaf in $VendorProfile.UserRoots) {
            foreach ($mid in @('AppData\Local', 'AppData\Roaming')) {
                $p = Join-Path $u.FullName (Join-Path $mid $leaf)
                if (Test-Path -LiteralPath $p) {
                    $out += [pscustomobject]@{ Path = $p; SizeMB = (Get-FolderSizeMB $p) }
                }
            }
        }
    }
    return $out
}

# ==========================================================================
#  CENSUS
# ==========================================================================

$script:ExitCode      = 0
$script:AnyMatched    = $false
$script:AnyFailed     = $false
$script:RebootPending = $false

if ($WhatIfPreference) {
    Write-Log '*** PREVIEW (-WhatIf): nothing will be uninstalled or deleted. ***' 'WARN'
}
if ($ListOnly) {
    Write-Log '*** LIST ONLY: census only, nothing will be changed. ***' 'WARN'
}

Write-Log "Legacy hardware residue cleanup started. Log: $LogPath"
Write-Log ("Scope: {0}" -f ($Scope -join ', '))

$machine = Get-MachineIdentity
Write-Section 'CURRENT HARDWARE'
Write-Log ("Board  : {0} {1}" -f $machine.BoardManufacturer, $machine.BoardProduct)
Write-Log ("System : {0} {1}" -f $machine.SystemManufacturer, $machine.SystemModel)
Write-Log ("CPU    : {0} [{1}]" -f $machine.CpuName, $machine.CpuManufacturer)

Write-Section 'DRIVER STORE BINDING MAP'
$allPackages = @(Get-DriverPackages)
$liveInfo    = Get-LiveDriverPackageNames
$liveNames   = $liveInfo.Names
Write-Log ("Third-party driver packages in store : {0}" -f $allPackages.Count)
Write-Log ("...of which bound to connected devices: {0}  [source: {1}]" -f $liveNames.Count, $liveInfo.Source)

# FAIL CLOSED. Without a trustworthy binding map there is no way to tell a dead
# package from the one driving the boot disk, so the driver store is left alone
# and the rest of the run continues. This is a degraded run, not a failed one.
if (-not $liveInfo.Reliable) {
    Write-Log 'The driver-package binding map could not be computed. Driver-store removal is DISABLED for this run; services, tasks, programs and files will still be processed.' 'REFUSE'
    $RemoveDriverPackages = $false
}

# Which providers are actually load-bearing on this machine right now? This is
# the evidence behind the per-vendor refusal, and it is computed, not assumed.
$liveProviders = @{}
foreach ($pkg in $allPackages) {
    if ($liveNames.Contains($pkg.Published)) {
        if (-not $liveProviders.ContainsKey($pkg.Provider)) { $liveProviders[$pkg.Provider] = 0 }
        $liveProviders[$pkg.Provider]++
    }
}
Write-Log 'Providers with live bindings on this machine:'
foreach ($k in ($liveProviders.Keys | Sort-Object)) {
    Write-Log ("    {0,-42} {1} package(s)" -f $k, $liveProviders[$k])
}

# --- Per-vendor eligibility ----------------------------------------------

$eligibleVendors = @()
foreach ($vp in $VendorProfiles) {
    $refusals = @()

    if ($vp.ChassisPattern) {
        $chassis = "$($machine.BoardManufacturer) $($machine.SystemManufacturer)"
        if ($chassis -match $vp.ChassisPattern) {
            $refusals += "current board/system manufacturer is '$chassis'"
        }
    }
    if ($vp.CpuPattern -and $machine.CpuManufacturer -match $vp.CpuPattern) {
        $refusals += "current CPU is '$($machine.CpuManufacturer)'"
    }

    $liveCount = 0
    foreach ($k in $liveProviders.Keys) {
        if ($k -match $vp.ProviderPattern) { $liveCount += $liveProviders[$k] }
    }
    if ($liveCount -gt 0) {
        $refusals += "$liveCount driver package(s) are bound to connected devices"
    }

    if ($refusals.Count -gt 0) {
        Write-Log ("REFUSED vendor '{0}': {1}. This vendor's hardware is present on this machine." -f `
            $vp.Vendor, ($refusals -join '; ')) 'REFUSE'
        continue
    }

    Write-Log ("Vendor '{0}' is eligible: no chassis match, no CPU match, zero live driver bindings." -f $vp.Vendor) 'OK'
    $eligibleVendors += $vp
}

if ($eligibleVendors.Count -eq 0 -and ($Scope | Where-Object { $_ -ne 'Startup' }).Count -gt 0) {
    Write-Log 'Every vendor bucket was refused. Only -Scope Startup work (if requested) will run.' 'WARN'
}

# --- Build the removal plan ----------------------------------------------

$plan = [ordered]@{
    Packages = @()
    Services = @()
    Tasks    = @()
    Programs = @()
    Roots    = @()
    RegKeys  = @()
    Ghosts   = @()
    RunKeys  = @()
    Approvals= @()
    Appx     = @()
    Orphans  = @()
}

foreach ($vp in $eligibleVendors) {
    $vendorPkgs = @($allPackages | Where-Object {
        $_.Provider -match $vp.ProviderPattern -and -not $liveNames.Contains($_.Published)
    })
    foreach ($pkg in $vendorPkgs) {
        $bucket = Get-PackageBucket -Package $pkg -Vendor $vp.Vendor
        if ($Scope -notcontains $bucket) { continue }
        $plan.Packages += [pscustomobject]@{
            Vendor = $vp.Vendor; Bucket = $bucket; Package = $pkg
        }
    }

    # Directories backing the packages we intend to remove; used to attribute
    # services whose binaries live inside the driver store.
    $pkgDirs = @()
    $fileRepo = Join-Path $env:SystemRoot 'System32\DriverStore\FileRepository'
    if (Test-Path -LiteralPath $fileRepo) {
        foreach ($entry in $plan.Packages) {
            if ($entry.Vendor -ne $vp.Vendor) { continue }
            $stem = [IO.Path]::GetFileNameWithoutExtension($entry.Package.Original)
            if ([string]::IsNullOrWhiteSpace($stem)) { continue }
            Get-ChildItem -LiteralPath $fileRepo -Directory -Filter "$stem.inf_*" -ErrorAction SilentlyContinue |
                ForEach-Object { $pkgDirs += $_.FullName }
        }
    }

    # Vendor-owned buckets get services/roots/registry/programs. A run scoped to
    # a single cross-vendor bucket (-Scope Audio) still sweeps that bucket's
    # driver packages above, but deliberately does NOT tear down the vendor's
    # whole service and folder footprint - that belongs to the vendor's own
    # bucket, and asking for "audio" is not asking for that.
    $vendorBuckets = if ($vp.Vendor -eq 'Asus') { @('Asus') } else { @('IntelChipset', 'Display', 'Audio', 'Power') }
    $vendorInScope = @($Scope | Where-Object { $vendorBuckets -contains $_ }).Count -gt 0

    if ($vendorInScope) {
        foreach ($svc in (Get-VendorServices -VendorProfile $vp -RemovablePackageDirs $pkgDirs)) {
            $plan.Services += [pscustomobject]@{ Vendor = $vp.Vendor; Service = $svc }
        }
        foreach ($root in (Get-VendorRoots -VendorProfile $vp)) {
            $plan.Roots += [pscustomobject]@{ Vendor = $vp.Vendor; Root = $root }
        }
        foreach ($rk in $vp.RegistryKeys) {
            if (Test-Path $rk) { $plan.RegKeys += [pscustomobject]@{ Vendor = $vp.Vendor; Key = $rk } }
        }
        foreach ($prog in (Get-VendorPrograms -VendorProfile $vp)) {
            $plan.Programs += [pscustomobject]@{ Vendor = $vp.Vendor; Program = $prog }
        }
        try {
            Get-AppxPackage -ErrorAction Stop |
                Where-Object { $_.Name -match $vp.AppxPattern } |
                ForEach-Object { $plan.Appx += [pscustomobject]@{ Vendor = $vp.Vendor; Package = $_ } }
        }
        catch { }

        if ($RemoveGhostDevices) {
            $includeBattery = ($Scope -contains 'Power')
            foreach ($g in (Get-GhostDevices -ProviderPatterns @($vp.ProviderPattern) `
                                             -ExtraHardwareIds $LaptopPhantomDeviceIds `
                                             -IncludePhantomBattery:$includeBattery)) {
                $plan.Ghosts += [pscustomobject]@{ Vendor = $vp.Vendor; Device = $g }
            }
        }
    }

    # Vendor scheduled tasks are startup items AND vendor residue, so they are
    # collected under either scope. A task firing at every logon against absent
    # hardware is the single most visible symptom of a migrated install.
    if ($Scope -contains 'Startup' -or $vendorInScope) {
        foreach ($t in (Get-VendorScheduledTasks -VendorProfile $vp)) {
            $plan.Tasks += [pscustomobject]@{ Vendor = $vp.Vendor; Task = $t }
        }
    }
}

if ($Scope -contains 'Startup') {
    $patterns = @($VendorProfiles | ForEach-Object { $_.ProviderPattern })
    foreach ($r in (Get-DeadRunEntries -VendorPatterns $patterns)) {
        $plan.RunKeys += $r
    }
    foreach ($a in (Get-OrphanStartupApprovals)) {
        $plan.Approvals += $a
    }
}

# Deduplicate ghosts: a device can match more than one vendor pattern.
$plan.Ghosts = @($plan.Ghosts | Group-Object { $_.Device.InstanceId } | ForEach-Object { $_.Group[0] })

# ==========================================================================
#  REPORT
# ==========================================================================

Write-Section 'CENSUS'

$totalMB = 0
if ($plan.Packages.Count -gt 0) {
    Write-Log ("Orphaned driver packages: {0}" -f $plan.Packages.Count)
    $fileRepo = Join-Path $env:SystemRoot 'System32\DriverStore\FileRepository'

    # SIZE EACH DIRECTORY ONCE, GLOBALLY. The same INF is routinely published
    # under several oemNN numbers - on a real machine ibtusb.inf holds eleven
    # slots, iigd_dch.inf two - and the driver store backs them with a shared
    # set of "<stem>.inf_<arch>_<hash>" directories. Summing per package
    # multiplies the same ~1 GB graphics folder by its registration count and
    # reports four times the space that actually exists. This set makes the
    # first bucket to claim a directory the only one that counts it.
    $seenDirs = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)

    foreach ($grp in ($plan.Packages | Group-Object Bucket | Sort-Object Name)) {
        $grpMB = 0
        foreach ($e in $grp.Group) {
            $stem = [IO.Path]::GetFileNameWithoutExtension($e.Package.Original)
            if ($stem -and (Test-Path -LiteralPath $fileRepo)) {
                Get-ChildItem -LiteralPath $fileRepo -Directory -Filter "$stem.inf_*" -ErrorAction SilentlyContinue |
                    ForEach-Object {
                        if ($seenDirs.Add($_.FullName)) { $grpMB += (Get-FolderSizeMB $_.FullName) }
                    }
            }
        }
        $totalMB += $grpMB
        Write-Log ("  [{0,-12}] {1,3} package(s), {2,9:N1} MB" -f $grp.Name, $grp.Count, $grpMB)
        foreach ($e in ($grp.Group | Sort-Object { $_.Package.Original })) {
            $mark = ''
            $lvl  = 'INFO'
            if ($CautionDriverClasses -contains $e.Package.Class) {
                # Storage and network adapter packages are allowed through the
                # gate like any other, but they are the two categories where
                # being wrong costs the boot volume or the only NIC. Say so.
                $mark = "   <-- {0} class: verify this is not current hardware" -f $e.Package.Class
                $lvl  = 'WARN'
            }
            Write-Log ("      {0,-10} {1,-46} {2}{3}" -f `
                $e.Package.Published, $e.Package.Original, $e.Package.Provider, $mark) $lvl
        }
    }
    $script:AnyMatched = $true
}
else { Write-Log 'Orphaned driver packages: none.' }

if ($plan.Programs.Count -gt 0) {
    Write-Log ("Registered programs: {0}" -f $plan.Programs.Count)
    foreach ($e in $plan.Programs) {
        Write-Log ("      [{0,-13}] {1}" -f $e.Program.Kind, $e.Program.Name)
        if ($e.Program.Reachable) {
            Write-Log ("                      -> {0} {1}" -f $e.Program.Command, ($e.Program.Arguments -join ' '))
        }
        else {
            # Surfaced in the census, not discovered halfway through the run,
            # because the failure mode is a modal dialog that blocks everything.
            Write-Log ("                      -> NOT RUNNABLE: {0}" -f $e.Program.UnreachableReason) 'WARN'
            Write-Log  '                         will be removed as an orphan registration instead' 'WARN'
        }
    }
    $script:AnyMatched = $true
}

if ($plan.Services.Count -gt 0) {
    Write-Log ("Services / kernel drivers: {0}" -f $plan.Services.Count)
    foreach ($e in ($plan.Services | Sort-Object { $_.Service.Name })) {
        Write-Log ("      {0,-34} {1,-8} {2}" -f $e.Service.Name, $e.Service.Status, $e.Service.Evidence)
    }
    $script:AnyMatched = $true
}

if ($plan.Tasks.Count -gt 0) {
    Write-Log ("Scheduled tasks: {0}" -f $plan.Tasks.Count)
    foreach ($e in $plan.Tasks) {
        $flag = if ($e.Task.ExeMissing) { ' [target MISSING]' } else { '' }
        Write-Log ("      {0}{1} [{2}]{3}" -f $e.Task.TaskPath, $e.Task.TaskName, $e.Task.State, $flag)
    }
    $script:AnyMatched = $true
}

if ($plan.RunKeys.Count -gt 0) {
    Write-Log ("Run-key entries: {0}" -f $plan.RunKeys.Count)
    foreach ($e in $plan.RunKeys) {
        $why = if ($e.Dead) { 'target missing' } else { 'vendor match' }
        Write-Log ("      {0} :: {1}  ({2})" -f ($e.Key -replace '.*CurrentVersion\\', ''), $e.ValueName, $why)
        # Print the RESOLVED target, not the raw command. If the resolver ever
        # gets a command line wrong again, it is visible here before anything
        # is deleted rather than afterwards.
        Write-Log ("            target: {0}" -f $(if ($e.Target) { $e.Target } else { '(unresolved)' }))
    }
    $script:AnyMatched = $true
}

if ($plan.Approvals.Count -gt 0) {
    Write-Log ("Orphaned Task Manager startup flags: {0}" -f $plan.Approvals.Count)
    foreach ($e in $plan.Approvals) {
        Write-Log ("      {0} :: {1}" -f ($e.Key -replace '.*StartupApproved\\', ''), $e.ValueName)
    }
    $script:AnyMatched = $true
}

if ($plan.Appx.Count -gt 0) {
    Write-Log ("Appx packages: {0}" -f $plan.Appx.Count)
    foreach ($e in $plan.Appx) { Write-Log ("      {0}" -f $e.Package.PackageFullName) }
    $script:AnyMatched = $true
}

if ($plan.Ghosts.Count -gt 0) {
    Write-Log ("Phantom (not-present) devices: {0}" -f $plan.Ghosts.Count)
    foreach ($e in ($plan.Ghosts | Sort-Object { $_.Device.Class })) {
        Write-Log ("      [{0,-14}] {1,-46} ({2})" -f $e.Device.Class, $e.Device.FriendlyName, $e.Device.Reason)
    }
    $script:AnyMatched = $true
}
elseif (-not $RemoveGhostDevices) {
    Write-Log 'Phantom devices: not enumerated (-RemoveGhostDevices was not supplied).'
}

if ($plan.Roots.Count -gt 0) {
    $rootMB = ($plan.Roots | ForEach-Object { $_.Root.SizeMB } | Measure-Object -Sum).Sum
    if ($null -eq $rootMB) { $rootMB = 0 }
    $totalMB += $rootMB
    Write-Log ("Residual directories: {0}  ({1:N1} MB)" -f $plan.Roots.Count, $rootMB)
    foreach ($e in ($plan.Roots | Sort-Object { -$_.Root.SizeMB })) {
        Write-Log ("      {0,9:N1} MB  {1}" -f $e.Root.SizeMB, $e.Root.Path)
    }
    $script:AnyMatched = $true
}

if ($plan.RegKeys.Count -gt 0) {
    $note = if ($RemoveResidualRegistry) { '' } else { '  (not removed - pass -RemoveResidualRegistry)' }
    Write-Log ("Residual registry keys: {0}{1}" -f $plan.RegKeys.Count, $note)
    foreach ($e in $plan.RegKeys) { Write-Log ("      {0}" -f $e.Key) }
}

Write-Log ''
Write-Log ("ESTIMATED RECLAIMABLE: {0:N1} MB ({1:N2} GB)" -f $totalMB, ($totalMB / 1024)) 'OK'

if (-not $script:AnyMatched) {
    Write-Log 'Nothing matched. No changes were made.' 'OK'
    if ($script:TranscriptStarted) { try { Stop-Transcript | Out-Null } catch { } }
    exit 2
}

if ($ListOnly) {
    Write-Log 'ListOnly: stopping here. Re-run without -ListOnly to act on this census.' 'OK'
    if ($script:TranscriptStarted) { try { Stop-Transcript | Out-Null } catch { } }
    exit 0
}

# ==========================================================================
#  ACT
# ==========================================================================

if (-not $Force -and -not $WhatIfPreference) {
    Write-Log ''
    Write-Log 'Review the census above. This is the last stop before changes are made.' 'WARN'
    $answer = Read-Host 'Proceed? [y/N]'
    if ($answer -notmatch '^(y|yes)$') {
        Write-Log 'Aborted at operator request. Nothing was changed.' 'WARN'
        if ($script:TranscriptStarted) { try { Stop-Transcript | Out-Null } catch { } }
        exit 1
    }
}

# --- 1. Startup (first: it is the cheapest win and needs no reboot) -------

if ($plan.Tasks.Count -gt 0) {
    Write-Section 'SCHEDULED TASKS'
    foreach ($e in $plan.Tasks) {
        $full = "$($e.Task.TaskPath)$($e.Task.TaskName)"
        if ($PSCmdlet.ShouldProcess($full, 'Unregister scheduled task')) {
            try {
                if ($e.Task.State -eq 'Running') {
                    Stop-ScheduledTask -TaskPath $e.Task.TaskPath -TaskName $e.Task.TaskName -ErrorAction SilentlyContinue
                }
                Unregister-ScheduledTask -TaskPath $e.Task.TaskPath -TaskName $e.Task.TaskName -Confirm:$false -ErrorAction Stop
                Write-Log "  Removed task $full" 'OK'
            }
            catch {
                Write-Log "  FAILED to remove task ${full}: $($_.Exception.Message)" 'ERROR'
                $script:AnyFailed = $true
            }
        }
    }
}

if ($plan.RunKeys.Count -gt 0) {
    Write-Section 'RUN-KEY ENTRIES'
    foreach ($e in $plan.RunKeys) {
        $label = "$($e.Key) :: $($e.ValueName)"
        if ($PSCmdlet.ShouldProcess($label, 'Remove Run value')) {
            try {
                Remove-ItemProperty -LiteralPath $e.Key -Name $e.ValueName -Force -ErrorAction Stop
                Write-Log "  Removed $label" 'OK'
            }
            catch {
                Write-Log "  FAILED ${label}: $($_.Exception.Message)" 'ERROR'
                $script:AnyFailed = $true
            }
        }
    }
}

if ($plan.Approvals.Count -gt 0) {
    Write-Section 'ORPHANED STARTUP FLAGS'
    foreach ($e in $plan.Approvals) {
        $label = "$($e.Key) :: $($e.ValueName)"
        if ($PSCmdlet.ShouldProcess($label, 'Remove StartupApproved flag')) {
            try {
                Remove-ItemProperty -LiteralPath $e.Key -Name $e.ValueName -Force -ErrorAction Stop
                Write-Log "  Removed $label" 'OK'
            }
            catch {
                Write-Log "  FAILED ${label}: $($_.Exception.Message)" 'ERROR'
                $script:AnyFailed = $true
            }
        }
    }
}

# --- 2. Programs (the vendor's own uninstaller owns the bulk) ------------

if ($RemovePrograms -and $plan.Programs.Count -gt 0) {
    Write-Section 'VENDOR UNINSTALLERS'
    foreach ($e in $plan.Programs) {
        $prog = $e.Program

        # Re-read the hive: a bundle uninstall two iterations ago may already
        # have taken this MSI child with it (TRAP 4).
        if (-not (Test-Path $prog.RegistryPath)) {
            Write-Log "  SKIP $($prog.Name): already removed by an earlier uninstall." 'INFO'
            continue
        }
        if ([string]::IsNullOrWhiteSpace($prog.Command)) {
            Write-Log "  SKIP $($prog.Name): no usable uninstall command." 'WARN'
            $plan.Orphans += [pscustomobject]@{ Program = $prog; Reason = 'no uninstall command' }
            continue
        }

        # An uninstaller that cannot succeed is never launched. Launching it is
        # not a harmless attempt: an InstallShield setup.exe with missing source
        # media blocks the whole run on a modal dialog that nothing can answer.
        if (-not $prog.Reachable) {
            Write-Log "  SKIP $($prog.Name): $($prog.UnreachableReason)." 'WARN'
            Write-Log "         Reclassified as an orphan registration; it will be removed by registration instead." 'WARN'
            $plan.Orphans += [pscustomobject]@{ Program = $prog; Reason = $prog.UnreachableReason }
            continue
        }

        if ($PSCmdlet.ShouldProcess($prog.Name, "Uninstall ($($prog.Kind))")) {
            Write-Log "  Uninstalling $($prog.Name) [$($prog.Kind)]..."
            $r = Invoke-NativeCommand -FilePath $prog.Command -Arguments $prog.Arguments
            switch ($r.ExitCode) {
                0     { Write-Log "    Removed." 'OK' }
                1605  { Write-Log "    Already gone (1605)." 'OK' }
                3010  { Write-Log "    Removed; reboot required (3010)." 'OK'; $script:RebootPending = $true }
                1641  { Write-Log "    Removed; reboot initiated (1641)." 'OK'; $script:RebootPending = $true }
                default { Write-Log "    Uninstaller returned $($r.ExitCode)." 'WARN' }
            }

            # THE VERDICT IS THE REGISTRY, NOT THE EXIT CODE. Vendor uninstallers
            # report success while leaving their registration behind, and report
            # failure after removing everything. Ask the hive what actually
            # happened, and only then decide whether this run failed.
            if (Test-Path $prog.RegistryPath) {
                Write-Log "    Registration survived the uninstaller." 'WARN'
                $plan.Orphans += [pscustomobject]@{
                    Program = $prog
                    Reason  = "uninstaller exited $($r.ExitCode) but the registration is still present"
                }
            }
        }
    }
}

# --- 2b. Orphan registrations -------------------------------------------
#
# Entries that no vendor uninstaller can remove. Left alone they keep the
# product listed in Add/Remove Programs forever and make every later run of this
# script re-detect an "unclean" machine, which is the single most common reason
# a cleanup is declared finished when it is not.

if ($RemoveOrphanRegistrations -and $plan.Orphans.Count -gt 0) {
    Write-Section 'ORPHAN REGISTRATIONS'
    foreach ($o in $plan.Orphans) {
        $prog = $o.Program

        if (-not (Test-Path $prog.RegistryPath)) {
            Write-Log "  SKIP $($prog.Name): registration already gone." 'INFO'
            continue
        }

        Write-Log "  $($prog.Name)"
        Write-Log "      reason: $($o.Reason)"

        if ($PSCmdlet.ShouldProcess($prog.Name, 'Remove orphaned registration')) {
            try {
                Remove-Item -LiteralPath $prog.RegistryPath -Recurse -Force -ErrorAction Stop
                Write-Log "      Removed registration $($prog.KeyName)" 'OK'
            }
            catch {
                Write-Log "      FAILED to remove registration: $($_.Exception.Message)" 'ERROR'
                $script:AnyFailed = $true
                continue
            }
        }

        # The cached installer folder goes with it - but only when the folder
        # still looks like an InstallShield cache. A CacheDir that no longer
        # holds setup.exe or ISSetup.dll is not one, and is not deleted on the
        # strength of a path string alone.
        if (-not [string]::IsNullOrWhiteSpace($prog.CacheDir) -and (Test-Path -LiteralPath $prog.CacheDir)) {
            $looksRight = (Test-Path -LiteralPath (Join-Path $prog.CacheDir 'setup.exe')) -or
                          (Test-Path -LiteralPath (Join-Path $prog.CacheDir 'ISSetup.dll'))
            if (-not $looksRight) {
                Write-Log "      REFUSE $($prog.CacheDir): does not look like an InstallShield cache." 'REFUSE'
            }
            elseif (-not (Test-SafeResidualPath $prog.CacheDir)) {
                Write-Log "      REFUSE $($prog.CacheDir): fails the residual-path safety check." 'REFUSE'
            }
            elseif ($PSCmdlet.ShouldProcess($prog.CacheDir, 'Delete cached installer folder')) {
                try {
                    $mb = Get-FolderSizeMB $prog.CacheDir
                    Remove-Item -LiteralPath $prog.CacheDir -Recurse -Force -ErrorAction Stop
                    Write-Log ("      Deleted cache {0} ({1:N1} MB)" -f $prog.CacheDir, $mb) 'OK'
                }
                catch {
                    Write-Log "      Could not delete cache: $($_.Exception.Message)" 'WARN'
                }
            }
        }
    }
}
elseif ($plan.Orphans.Count -gt 0) {
    Write-Section 'ORPHAN REGISTRATIONS'
    Write-Log ("{0} registration(s) cannot be removed by their own uninstaller and were left in place (-RemoveOrphanRegistrations:`$false)." -f $plan.Orphans.Count) 'WARN'
    foreach ($o in $plan.Orphans) { Write-Log "      $($o.Program.Name) - $($o.Reason)" 'WARN' }
    $script:AnyFailed = $true
}

# --- 3. Services (stop, then delete; before the packages that own them) ---

if ($plan.Services.Count -gt 0) {
    Write-Section 'SERVICES AND KERNEL DRIVERS'
    foreach ($e in ($plan.Services | Sort-Object { $_.Service.StartValue } -Descending)) {
        $svc = $e.Service

        # Final veto, re-checked here and not only at census time.
        if ($InboxVendorNamedServices -contains $svc.Name) {
            Write-Log "  REFUSE $($svc.Name): inbox Windows component." 'REFUSE'
            continue
        }

        if ($PSCmdlet.ShouldProcess($svc.Name, 'Stop and delete service')) {
            if ($svc.Status -eq 'Running') {
                try {
                    Stop-Service -Name $svc.Name -Force -ErrorAction Stop
                    Write-Log "  Stopped $($svc.Name)."
                }
                catch {
                    # A boot/system-start kernel driver cannot be stopped while
                    # loaded. That is expected, not a failure: deleting the
                    # registration still works, and the file goes at reboot.
                    Write-Log "  $($svc.Name) could not be stopped (loaded driver); registration will still be removed, file after reboot." 'WARN'
                    $script:RebootPending = $true
                }
            }
            $r = Invoke-NativeCommand -FilePath 'sc.exe' -Arguments @('delete', $svc.Name) -Quiet
            if ($r.ExitCode -eq 0) { Write-Log "  Deleted service $($svc.Name)." 'OK' }
            elseif ($r.ExitCode -eq 1060) { Write-Log "  Service $($svc.Name) already absent." 'OK' }
            else {
                Write-Log "  FAILED to delete service $($svc.Name) (sc.exe $($r.ExitCode))." 'ERROR'
                $script:AnyFailed = $true
            }
        }
    }
}

# --- 4. Phantom devnodes (before their packages) -------------------------

if ($RemoveGhostDevices -and $plan.Ghosts.Count -gt 0) {
    Write-Section 'PHANTOM DEVICES'
    foreach ($e in $plan.Ghosts) {
        $d = $e.Device
        $label = "$($d.FriendlyName) [$($d.InstanceId)]"
        if ($PSCmdlet.ShouldProcess($label, 'Remove phantom devnode')) {
            $r = Invoke-NativeCommand -FilePath 'pnputil.exe' `
                                      -Arguments @('/remove-device', $d.InstanceId) -Quiet
            if ($r.ExitCode -eq 0) { Write-Log "  Removed $label" 'OK' }
            else {
                Write-Log "  Could not remove $label (pnputil $($r.ExitCode))." 'WARN'
            }
        }
    }
}

# --- 5. Driver packages (re-verified immediately before each deletion) ----

if ($RemoveDriverPackages -and $plan.Packages.Count -gt 0) {
    Write-Section 'DRIVER STORE PACKAGES'

    # TRAP 2: re-read the store NOW. Every earlier removal may have shuffled
    # oem numbering, and the census is minutes old by this point.
    Write-Log 'Re-reading the driver store before deletion (oem numbers are recycled)...'
    $freshPackages = @(Get-DriverPackages)
    $freshInfo     = Get-LiveDriverPackageNames
    $freshLive     = $freshInfo.Names

    # The gate is re-checked here, not trusted from census time. If it has gone
    # unreliable in the intervening minutes, nothing is deleted.
    if (-not $freshInfo.Reliable) {
        Write-Log 'Binding map is no longer reliable. Skipping all driver-store deletions.' 'REFUSE'
        $plan.Packages = @()
    }

    foreach ($e in $plan.Packages) {
        $pkg   = $e.Package
        $label = "$($pkg.Published) ($($pkg.Original), $($pkg.Provider))"

        if (-not (Test-PackageStillRemovable -Package $pkg -FreshPackages $freshPackages -LiveNames $freshLive)) {
            continue
        }

        if ($PSCmdlet.ShouldProcess($label, 'Delete driver package')) {
            $r = Invoke-NativeCommand -FilePath 'pnputil.exe' `
                                      -Arguments @('/delete-driver', $pkg.Published, '/uninstall') -Quiet
            if ($r.ExitCode -eq 0) {
                Write-Log "  Deleted $label" 'OK'
            }
            elseif ($r.ExitCode -eq 3010) {
                Write-Log "  Deleted $label (reboot required)" 'OK'
                $script:RebootPending = $true
            }
            else {
                # /force would rip the package off a live device. It is never
                # issued: if the package will not come out cleanly, something
                # is still using it and that is exactly what the gate exists
                # to protect.
                Write-Log "  Could not delete $label (pnputil $($r.ExitCode)). Not retried with /force by design." 'WARN'
                $script:AnyFailed = $true
            }
        }
    }
}

# --- 6. Appx --------------------------------------------------------------

if ($plan.Appx.Count -gt 0) {
    Write-Section 'APPX PACKAGES'
    foreach ($e in $plan.Appx) {
        $full = $e.Package.PackageFullName
        if ($PSCmdlet.ShouldProcess($full, 'Remove Appx package')) {
            try {
                Remove-AppxPackage -Package $full -AllUsers -ErrorAction Stop
                Write-Log "  Removed $full" 'OK'
            }
            catch {
                Write-Log "  FAILED to remove ${full}: $($_.Exception.Message)" 'WARN'
            }
        }
    }
}

# --- 7. Residual files ----------------------------------------------------

if ($RemoveResidualFiles -and $plan.Roots.Count -gt 0) {
    Write-Section 'RESIDUAL DIRECTORIES'
    foreach ($e in ($plan.Roots | Sort-Object { -$_.Root.SizeMB })) {
        $path = $e.Root.Path

        # Re-checked at the moment of deletion, not only at census time.
        if (-not (Test-SafeResidualPath $path)) {
            Write-Log "  REFUSE ${path}: fails the residual-path safety check." 'REFUSE'
            continue
        }
        if (-not (Test-Path -LiteralPath $path)) {
            Write-Log "  SKIP ${path}: already gone." 'INFO'
            continue
        }

        if ($PSCmdlet.ShouldProcess($path, 'Delete directory')) {
            try {
                Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop
                Write-Log ("  Deleted {0} ({1:N1} MB)" -f $path, $e.Root.SizeMB) 'OK'
            }
            catch {
                # Files held open by a still-loaded driver survive until reboot.
                # That is the expected first-run outcome, not a failure.
                Write-Log "  Partially removed $path (files in use). Re-run after a reboot to finish." 'WARN'
                $script:RebootPending = $true
            }
        }
    }
}

# --- 8. Residual registry (opt-in) ---------------------------------------

if ($RemoveResidualRegistry -and $plan.RegKeys.Count -gt 0) {
    Write-Section 'RESIDUAL REGISTRY'
    foreach ($e in $plan.RegKeys) {
        if ($PSCmdlet.ShouldProcess($e.Key, 'Delete registry key')) {
            try {
                Remove-Item -LiteralPath $e.Key -Recurse -Force -ErrorAction Stop
                Write-Log "  Deleted $($e.Key)" 'OK'
            }
            catch {
                Write-Log "  FAILED $($e.Key): $($_.Exception.Message)" 'WARN'
            }
        }
    }
}

# ==========================================================================
#  SUMMARY
# ==========================================================================

Write-Section 'SUMMARY'

if ($WhatIfPreference) {
    Write-Log 'Preview run: nothing was changed.' 'OK'
    $script:ExitCode = 0
}
elseif ($script:AnyFailed) {
    Write-Log 'Completed with one or more failures. Review the log above.' 'WARN'
    $script:ExitCode = 3
}
elseif ($script:RebootPending) {
    Write-Log 'Completed. A REBOOT IS REQUIRED to release loaded drivers.' 'OK'
    Write-Log 'Re-run this script after the reboot to finish the file sweep; the second pass is fast.' 'OK'
    $script:ExitCode = 3010
}
else {
    Write-Log 'Completed successfully.' 'OK'
    $script:ExitCode = 0
}

Write-Log "Log written to: $LogPath"
if ($script:TranscriptStarted) { try { Stop-Transcript | Out-Null } catch { } }
exit $script:ExitCode
