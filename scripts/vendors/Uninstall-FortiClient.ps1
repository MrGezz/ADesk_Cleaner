<#
.SYNOPSIS
    Uninstalls Fortinet FortiClient on Windows and removes the network-stack
    residue the MSI leaves behind - orphaned kernel drivers, driver-store
    packages, the virtual adapter devnodes, firewall rules and config hives -
    without touching another vendor's driver package.

.DESCRIPTION
    Discovers FortiClient from the Windows "Uninstall" registry hives, runs the
    vendor MSI silently, then removes what the MSI orphans. Every destructive
    step is discovery-driven and evidence-gated: nothing is removed on the
    strength of a name alone.

    THE CENTRAL FORTICLIENT FACT, and the reason this is not a name-matching
    cleanup loop:

        A FortiClient install is mostly NETWORK-STACK PLUMBING, not files.
        It registers an NDIS lightweight filter bound into every adapter, two
        virtual miniport adapters with PnP devnodes, up to six kernel drivers,
        and three driver-store packages. Those are removed by identity
        (binary CompanyName, INF file content, PnP service binding) and in a
        fixed order. Removed by name, or in the wrong order, they take the
        machine's networking with them.

    Four FortiClient-specific traps this script is built around:

    1. OEM INF NUMBERS ARE RECYCLED, AND THIS MACHINE PROVES IT. The 'ftsvnic'
       service's DisplayName reads "@oem45.inf,%VER_ADAPTER_STR%;Fortinet SSL
       VPN Virtual Ethernet Adapter" - but C:\Windows\INF\oem45.inf is NVIDIA's
       nvhda.inf (Azalia/HDMI audio). Windows reclaimed the oem slot after the
       original Fortinet package was uninstalled, and the stale service key kept
       pointing at the number. "pnputil /delete-driver oem45.inf /uninstall"
       would remove the NVIDIA audio driver. This script NEVER derives an INF
       name from a registry string; it resolves driver packages only by reading
       the INF FILE CONTENT under C:\Windows\INF and confirming Fortinet
       provenance, then re-verifies immediately before deleting.

    2. THE SERVICE NAME IS NOT THE DRIVER NAME, AND THREE SERVICES HAVE NO
       "FORTI" IN THEM. Verified on this platform: FortiFW loads FortiFW2.sys,
       fortisniff loads fortisniff2.sys - and 'ft_vnic', 'ftsvnic' and 'pppop'
       (a Fortinet-provided "PPPoP WAN Adapter") contain no 'forti' substring at
       all. A registry sweep filtered on the service KEY NAME silently misses
       all three. Discovery here walks every service's ImagePath, resolves it to
       a real file, and attributes it by the binary's CompanyName.

    3. THE NDIS LIGHTWEIGHT FILTER IS THE ONE THAT BREAKS NETWORKING.
       FortiFilter is Class=NetService, Start=1 (SYSTEM_START), and is bound and
       Enabled on every adapter on the machine. "sc.exe delete FortiFilter", or
       deleting FortiFilter.sys, while those bindings exist leaves the NDIS
       binding database referencing a filter that no longer exists - which can
       leave adapters unable to bind TCP/IP after reboot. It is removed ONLY via
       the driver package, ALWAYS last among driver operations, and always
       followed by a reboot before any file deletion.

    4. THE BLUNT NETWORK INSTRUMENTS ARE REFUSED OUTRIGHT. "netsh winsock reset"
       and "netsh wfp reset" appear in most published FortiClient removal
       recipes. Verified on this platform: there is no Fortinet Winsock LSP (the
       catalog is entirely Microsoft providers) and Fortinet's WFP callouts are
       owned by its own drivers, which unregister them on unload. Both commands
       are therefore pure downside - they drop every socket, wipe ALL
       third-party and Windows Firewall filtering state, and force a reboot.
       Neither is issued. For the same reason the script never writes to the
       Credential Providers key: FortiCredentialProvider2.dll ships on disk but
       is NOT registered there, and a speculative prune of that key can remove
       PasswordProvider and make the machine unloggable.

    Removal order, which is not negotiable:

        1. Census and preview       (nothing is mutated)
        2. Active VPN tunnel guard  (a tunnel being up aborts the run)
        3. Stop the FA_Scheduler service, then the processes it respawns
        4. MSI uninstall            (the vendor path; it owns the bulk)
        5. Re-census                (what did the MSI actually orphan?)
        6. PnP devnodes, then driver packages, NetService/LWF package LAST
        7. Orphaned service keys that no surviving package owns
        8. Firewall rules and shortcuts
        9. Residual files           (needs a reboot first; re-run to finish)
       10. Residual registry hives  (opt-in)

    Reboot-awareness is built in rather than bolted on. Loaded kernel drivers
    hold their .sys files open until the machine restarts, so a first run
    removes registrations and reports what is pending; re-running the script
    after the reboot completes the file sweep. Every step is idempotent and
    treats "already gone" as success.

.PARAMETER RemoveDrivers
    Remove Fortinet kernel drivers, driver-store packages and virtual adapter
    devnodes that survive the MSI. Default: $true - this is the reason the
    script exists, because the MSI routinely leaves them behind. Driver packages
    are resolved by INF content, never by a registry-supplied oemNN name.

.PARAMETER IncludeLegacyPppop
    Also remove the Fortinet-provided "PPPoP WAN Adapter" (service 'pppop',
    pppop64.sys, a 2016-vintage Net-class package with the Legacy attribute).
    Off by default. It predates FortiClient 6.0.6, its name contains no 'forti',
    and it may belong to a different Fortinet product that is still wanted - so
    it is reported but never removed silently.

.PARAMETER RemoveFirewallRules
    Remove the inbound Windows Firewall allow-rules FortiClient registers.
    Default: $true. Rules are matched by their Fortinet group name and by
    application filters whose program path resolves under a discovered Fortinet
    install root - never by a loose name search.

.PARAMETER RemoveResidualFiles
    After a successful uninstall, delete leftover Fortinet program folders,
    Start Menu entries, the all-users desktop shortcut, and the orphaned
    driver .sys files. Default: $true. A runtime guard permits directory
    deletion only under a path carrying a Fortinet segment, and permits a .sys
    deletion only when the file's own CompanyName says Fortinet.

.PARAMETER RemoveResidualRegistry
    Opt-in. Also delete the configuration hives HKLM:\SOFTWARE\Fortinet,
    HKCU:\SOFTWARE\Fortinet and the per-SID SOFTWARE\Fortinet keys of every
    LOADED user hive. Off by default.

    Note what this contains: saved SSL-VPN credentials (DPAPI blobs under
    ...\Sslvpn\Tunnels\<name>\DATA1 with SavePass=1), the configured gateway
    address, and the encrypted EMS endpoint identity under FA_ESNAC. Removing
    them is usually the point - but this script never reads, logs, echoes or
    backs up those values, and deliberately performs no registry export.

.PARAMETER StopFortiClient
    Terminate running FortiClient processes and stop the FA_Scheduler service
    before uninstalling. Without this switch the script aborts when FortiClient
    is running, because an MSI uninstall with live processes schedules file
    replacement on reboot and leaves the residual sweep looking at locked files.

.PARAMETER SkipTunnelGuard
    Proceed even when a Fortinet virtual adapter is reporting Up. Default: off.
    The guard exists because tearing down the VPN daemon or the virtual miniport
    mid-tunnel can strand routes and black-hole the default gateway - which on a
    remotely-reached machine is unrecoverable.

.PARAMETER ListOnly
    Run the full census and print everything that would be removed, then exit.
    Performs no changes. This is the safety gate; run it first.

.PARAMETER Force
    Fully non-interactive: skips the per-item Read-Host prompts AND suppresses
    PowerShell's built-in ShouldProcess confirmation.

.PARAMETER LogPath
    Full path for the transcript log. Defaults to
    %TEMP%\Uninstall-FortiClient_<timestamp>.log

.EXAMPLE
    # Preview everything that would be removed, change nothing:
    powershell -ExecutionPolicy Bypass -File .\Uninstall-FortiClient.ps1 -ListOnly

.EXAMPLE
    # Interactive removal, prompting before each step:
    powershell -ExecutionPolicy Bypass -File .\Uninstall-FortiClient.ps1 -StopFortiClient

.EXAMPLE
    # Fully unattended, including the config hives and saved VPN credentials:
    powershell -ExecutionPolicy Bypass -File .\Uninstall-FortiClient.ps1 -StopFortiClient -RemoveResidualRegistry -Force

.EXAMPLE
    # Second pass after the reboot, to sweep the files the kernel was holding:
    powershell -ExecutionPolicy Bypass -File .\Uninstall-FortiClient.ps1 -Force

.EXAMPLE
    # Also remove the legacy 2016 Fortinet PPPoP WAN Adapter package:
    powershell -ExecutionPolicy Bypass -File .\Uninstall-FortiClient.ps1 -IncludeLegacyPppop -StopFortiClient

.EXAMPLE
    # Turning OFF one of the [bool] parameters needs -Command, not -File.
    # powershell.exe -File passes every argument as a literal string, and a
    # [bool] parameter rejects the string "$false" outright. Measured: no -File
    # form works - not :$false, not :0. This is the only shape that binds:
    powershell -ExecutionPolicy Bypass -Command "& '.\Uninstall-FortiClient.ps1' -RemoveDrivers:$false -StopFortiClient"

.NOTES
    Requires an elevated (Administrator) session; the script self-elevates.
    Exit code 0 = success, 3010 = success (reboot required), 3 = partial failure,
    2 = nothing found, 1 = aborted.

    -IncludeLegacyPppop and -RemoveResidualRegistry are [switch] rather than
    [bool] specifically so that they bind under "powershell.exe -File", which is
    how every example in this repo is written. Pass them bare - "-Force" style -
    not as "-RemoveResidualRegistry:$true".

    Removing FortiClient stops the endpoint's EMS/FortiGate telemetry and
    deletes any saved SSL-VPN tunnel. It does NOT deregister the endpoint on the
    server side - only the administrator of that FortiGate/EMS can do that.

    This tool is not affiliated with or endorsed by Fortinet. "FortiClient" and
    "Fortinet" are trademarks of Fortinet, Inc.
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    # The two OPT-INS are [switch], not [bool], and that is deliberate:
    # "powershell.exe -File" passes every argument as a literal STRING, and a
    # [bool] parameter's argument transformation rejects the string "$true" with
    # "Boolean parameters accept only Boolean values and numbers". Measured: NO
    # -File form binds a [bool] - not :$true, not :1, not :0, not :true. Since
    # these are the two parameters an operator actually types, they must work
    # with the -File invocation every example in this repo uses.
    [switch]$IncludeLegacyPppop,
    [switch]$RemoveResidualRegistry,
    # These three stay [bool] because they default ON and are only ever passed to
    # turn a removal OFF, which is rare. Doing so needs the -Command form - see
    # the .NOTES block.
    [bool]$RemoveDrivers          = $true,
    [bool]$RemoveFirewallRules    = $true,
    [bool]$RemoveResidualFiles    = $true,
    [switch]$StopFortiClient,
    [switch]$SkipTunnelGuard,
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
# it throws under $ErrorActionPreference='Stop' - after the drivers have already
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

# Registry discovery. Publisher is the reliable axis: the DisplayName is a bare
# "FortiClient" on the full product but "FortiClient VPN" on the free VPN-only
# edition, and localized builds vary further.
$ProductNamePatterns = @('FortiClient*', 'Forticlient*')
$PublisherPattern    = '*Fortinet*'

# Process names verified unique to FortiClient. These may be matched by BARE
# NAME because nothing else on a Windows machine ships them.
$FortiOwnProcessNames = @(
    'FortiTray', 'FortiESNAC', 'FortiSettings', 'FortiSSLVPNdaemon',
    'FortiSSLVPNsys', 'FortiClient', 'FortiClientConsole', 'FortiClientSecurity',
    'FortiClient_Diagnostic_Tool', 'FortiScand', 'FortiProxy', 'fortifws',
    'FortiWad', 'FortiVPNSt', 'FortiAvatar', 'FortiElevate', 'FCWscD7',
    'FCConfig', 'FCDBLog', 'FCAuth', 'FCCOMInt', 'EPCUserAvatar'
)

# THESE NAMES COLLIDE. Every one of them exists inside the FortiClient folder,
# and every one of them is also a common name elsewhere: certutil.exe is a
# Windows system binary, scheduler.exe and ipsec.exe ship with unrelated
# products, and update_task.exe is generic. They are terminated ONLY when the
# running image resolves to a path under a discovered Fortinet root.
$PathScopedProcessNames = @(
    'scheduler', 'ipsec', 'vpcd', 'update_task', 'submitv', 'certutil'
)

# The user-mode service. Stopping it is what stops the tray and the ESNAC agent
# respawning: they are launched by this scheduler, NOT by a Run key, so a
# Run-key cleanup would leave them relaunching.
$SchedulerServiceName = 'FA_Scheduler'

# Directory roots that residual cleanup may consider. Every one is guarded by
# Test-Path at use, because on a given build most of them do not exist: verified
# on this platform, C:\ProgramData\Fortinet, C:\Program Files (x86)\Fortinet and
# the per-user AppData\Fortinet folders are all ABSENT, yet most published
# FortiClient scripts assume them and throw on the first one.
$CandidateRootNames = @('Fortinet')

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
    (@(${env:SystemRoot}, 'INF')              -join '\'),
    (@(${env:SystemDrive}, 'Users')           -join '\')
) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

# The Windows Firewall group FortiClient registers its rules under. Matched
# exactly; the individual rule NAMES are per-machine random GUIDs and must never
# be hardcoded.
$FirewallGroupName = 'FortiClient Network Services'

# MSI exit codes that count as success. 3010 is the EXPECTED result here, not a
# failure: boot-start NDIS drivers guarantee a reboot is required, and a script
# that treats non-zero as failure branches into aggressive manual cleanup on a
# perfectly healthy uninstall - which is the path that risks the network stack.
$MsiSuccessCodes = @(0, 1605, 3010)   # 1605 = "not installed" (already gone)

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
    # The relay itself goes through -Command (see below), which CAN bind [bool],
    # so the three [bool] parameters are forwarded by value. The switches use the
    # conditional-append form.
    $passArgs = @()
    $passArgs += ('-RemoveDrivers:${0}'       -f $RemoveDrivers)
    $passArgs += ('-RemoveFirewallRules:${0}' -f $RemoveFirewallRules)
    $passArgs += ('-RemoveResidualFiles:${0}' -f $RemoveResidualFiles)
    if ($IncludeLegacyPppop)     { $passArgs += '-IncludeLegacyPppop' }
    if ($RemoveResidualRegistry) { $passArgs += '-RemoveResidualRegistry' }
    if ($StopFortiClient) { $passArgs += '-StopFortiClient' }
    if ($SkipTunnelGuard) { $passArgs += '-SkipTunnelGuard' }
    if ($ListOnly)        { $passArgs += '-ListOnly' }
    if ($Force)           { $passArgs += '-Force' }

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
    $LogPath = Join-Path $env:TEMP "Uninstall-FortiClient_$stamp.log"
}
# -WhatIf:$false is deliberate. Start-Transcript is itself ShouldProcess-aware,
# so under -WhatIf it PREVIEWS instead of opening the log, and the run then ends
# by announcing "Log saved to: <path>" for a file that was never written.
try { Start-Transcript -Path $LogPath -Append -WhatIf:$false | Out-Null } catch { }

# Preload CimCmdlets while the preview flag is switched off in a child scope.
# The service and adapter checks autoload this module; if that happens mid
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
Write-Log "FortiClient uninstall started. Log: $LogPath"
Write-Log ("Mode: {0}{1}{2}{3}{4}{5}" -f `
    $(if ($WhatIfPreference) { 'PREVIEW ' } else { '' }),
    $(if ($ListOnly) { 'ListOnly ' } else { 'Uninstall ' }),
    $(if ($RemoveDrivers) { '+Drivers ' } else { 'DriversKept ' }),
    $(if ($RemoveResidualFiles) { '+Residual ' } else { '' }),
    $(if ($RemoveResidualRegistry) { '+Registry ' } else { '' }),
    $(if ($Force) { 'Force' } else { 'Interactive' }))

if ($RemoveResidualRegistry) {
    Write-Log 'NOTE: -RemoveResidualRegistry deletes the Fortinet config hives, which hold the saved SSL-VPN tunnel and its stored credentials. Nothing from those keys is read, logged or backed up.' 'WARN'
}

# EVERY native command in this script goes through this, never through a bare
# "& pnputil.exe ... 2>&1". In Windows PowerShell 5.1, redirecting a native
# command's stderr with 2>&1 while $ErrorActionPreference is 'Stop' promotes any
# stderr line to a TERMINATING NativeCommandError. Both pnputil and sc.exe write
# ordinary informational text to stderr, so a bare call would abort the run in
# the middle of driver removal - service registrations already deleted, NDIS
# bindings not yet cleaned, which is the worst state this script can leave.
# The preference is lowered in FUNCTION scope (it does not leak back out) and
# the exit code is returned for the caller to branch on.
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
            try { $props = Get-ItemProperty -LiteralPath $_.PsPath -ErrorAction Stop } catch { return }
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
# separators, collapse doubled separators, lower-case it.
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

$allPrograms = @(Get-InstalledPrograms)
# Publisher CORROBORATES the name; it must never select on its own. With -or,
# every Fortinet-published row on the machine - FortiEDR Collector, FortiExplorer,
# a FortiSIEM agent - would be handed to msiexec /x below, turning this into an
# "uninstall every Fortinet product" script. Both DisplayName variants that exist
# in practice ("FortiClient" and "FortiClient VPN") already match FortiClient*,
# so -and costs no real coverage. A row with no Publisher at all is still
# accepted, because some repackaged installers omit it.
$products = @($allPrograms | Where-Object {
    (Test-MatchesAny $_.DisplayName $ProductNamePatterns) -and
    ([string]::IsNullOrWhiteSpace($_.Publisher) -or ($_.Publisher -like $PublisherPattern))
})

# De-duplicate by product code, never by display name: a machine carrying both
# FortiClient and FortiClient VPN registers two rows whose DisplayName can be
# identical after a partial upgrade.
$products = @($products | Group-Object KeyName | ForEach-Object { $_.Group[0] })

if ($products.Count -gt 0) {
    Write-Log "Found $($products.Count) registered Fortinet product(s):" 'OK'
    $products | ForEach-Object {
        Write-Log ("    {0}  [{1}]  {2}" -f $_.DisplayName, $_.DisplayVersion, $_.KeyName)
    }
}
else {
    Write-Log 'No Fortinet product is registered in the uninstall hives.'
}

# --- Fortinet artifact census ---------------------------------------------
# Everything below is discovered by IDENTITY, not by name. The census runs
# before and after the MSI so the script can report what the vendor uninstaller
# actually orphaned rather than assuming.

# Resolve a service ImagePath to a real file path. Four forms occur in the wild
# and all four are present on a FortiClient box:
#   "C:\Program Files\Fortinet\FortiClient\scheduler.exe"   quoted absolute
#   \SystemRoot\system32\DRIVERS\FortiFilter.sys            SystemRoot-relative
#   system32\drivers\fortiapd.sys                           bare relative
#   \??\C:\...                                              NT object path
function Resolve-ServiceImagePath {
    param([string]$ImagePath)
    if ([string]::IsNullOrWhiteSpace($ImagePath)) { return $null }
    $p = $ImagePath.Trim()

    if ($p.StartsWith('"')) {
        $end = $p.IndexOf('"', 1)
        if ($end -gt 1) { $p = $p.Substring(1, $end - 1) }
        else            { $p = $p.Trim('"') }
    }
    else {
        # Strip any arguments that follow the image name.
        $m = [regex]::Match($p, '(?i)^(.*?\.(?:sys|exe))(?:\s|$)')
        if ($m.Success) { $p = $m.Groups[1].Value }
    }

    $p = $p -replace '(?i)^\\\?\?\\', ''
    $p = $p -replace '(?i)^\\SystemRoot\\', ($env:SystemRoot + '\')
    $p = $p -replace '(?i)^%SystemRoot%\\', ($env:SystemRoot + '\')

    if ($p -notmatch '^[a-zA-Z]:\\' -and $p -notmatch '^\\\\') {
        $p = Join-Path $env:SystemRoot $p
    }
    return $p
}

# THE ATTRIBUTION PRIMITIVE. A file belongs to Fortinet when its own version
# resource says so - not when its name starts with "forti". This is what catches
# ftvnic.sys ("Fortinet Corporation"), ftsvnic.sys ("Fortinet Inc.") and
# pppop64.sys ("Fortinet Inc."), none of which a forti* glob would find.
function Test-FortinetBinary {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    try {
        $item = Get-Item -LiteralPath $Path -ErrorAction Stop
        $cn = $item.VersionInfo.CompanyName
        if ((-not [string]::IsNullOrWhiteSpace($cn)) -and $cn -match '(?i)fortinet') { return $true }
    }
    catch { }
    return $false
}

# Service census by ImagePath, NOT by key name. Filtering the Services hive on
# 'forti' returns six services on this platform and silently omits ft_vnic,
# ftsvnic and pppop - all three of which are real Fortinet drivers.
function Get-FortinetServices {
    param([string[]]$Roots)
    $svcRoot = 'HKLM:\SYSTEM\CurrentControlSet\Services'
    if (-not (Test-Path $svcRoot)) { return }

    Get-ChildItem -Path $svcRoot -ErrorAction SilentlyContinue | ForEach-Object {
        $props = $null
        try { $props = Get-ItemProperty -LiteralPath $_.PsPath -ErrorAction Stop } catch { return }

        $image    = Get-Prop $props 'ImagePath'
        $resolved = Resolve-ServiceImagePath $image
        if ([string]::IsNullOrWhiteSpace($resolved)) { return }

        # Two independent attribution routes. The binary's CompanyName is the
        # strong one; the install-root containment catches a Fortinet binary
        # whose version resource is missing or unreadable.
        $isFortinet = (Test-FortinetBinary $resolved)
        if (-not $isFortinet -and $Roots.Count -gt 0) {
            $isFortinet = Test-PathUnderAny -Path $resolved -Roots $Roots
        }
        if (-not $isFortinet) { return }

        $live = $null
        try { $live = Get-Service -Name $_.PSChildName -ErrorAction Stop } catch { }

        [pscustomobject]@{
            Name        = $_.PSChildName
            DisplayName = Get-Prop $props 'DisplayName'
            Type        = ConvertTo-IntOrZero (Get-Prop $props 'Type')
            Start       = ConvertTo-IntOrZero (Get-Prop $props 'Start')
            ImagePath   = $image
            BinaryPath  = $resolved
            BinaryFound = (Test-Path -LiteralPath $resolved)
            Status      = $(if ($live) { [string]$live.Status } else { 'Unknown' })
            IsDriver    = ((ConvertTo-IntOrZero (Get-Prop $props 'Type')) -in 1, 2)
            RegistryPath = $_.PsPath
        }
    }
}

# DRIVER PACKAGE RESOLUTION - THE SINGLE MOST DANGEROUS LOOKUP IN THIS SCRIPT.
#
# Resolution is by INF FILE CONTENT ONLY. It is never by an oemNN.inf name read
# out of a service DisplayName, and never by pnputil's localized field labels
# (which are translated on non-English Windows and would silently match nothing,
# or worse, match the wrong block).
#
# Verified on this platform: scanning C:\Windows\INF\oem*.inf for Fortinet
# provenance and filtering pnputil /enum-drivers on Provider Name agree exactly
# - both return oem59.inf, oem95.inf and oem173.inf. oem45.inf, which the
# ftsvnic service DisplayName points at, appears in NEITHER: it is NVIDIA's
# nvhda.inf, and deleting it removes the machine's HDMI audio driver.
# PROVENANCE, NOT MERE MENTION. The Provider= directive in [Version] is the INF's
# own statement of ownership; a copyright comment or a [Strings] interop note that
# happens to say "Fortinet" is not. A bare substring test would accept a third
# party's INF whose only Fortinet reference is a comment like
# "; do not install alongside Fortinet FortiClient - filter ordering conflict",
# and then hand it to pnputil /delete-driver /uninstall, which also force-removes
# every device bound to that package. Indirect %TOKEN% values are resolved through
# the strings table, because that is how all three real Fortinet INFs write it
# (Provider = %FTNT% and Provider = %VER_PROVIDER_NAME_STR%).
function Get-InfProviderName {
    param([string[]]$Text)
    $line = @($Text | Where-Object { $_ -match '(?i)^\s*Provider\s*=' } | Select-Object -First 1)
    if ($line.Count -eq 0) { return '' }
    $v = ([regex]::Match($line[0], '(?i)^\s*Provider\s*=\s*(.+?)\s*(?:;.*)?$')).Groups[1].Value
    if ($v -match '^%(.+)%$') {
        $tok = $matches[1]
        $s = @($Text | Where-Object { $_ -match ('(?i)^\s*' + [regex]::Escape($tok) + '\s*=') } | Select-Object -First 1)
        if ($s.Count -gt 0) {
            $v = ([regex]::Match($s[0], '(?i)=\s*"?([^";]+)"?')).Groups[1].Value
        }
    }
    return $v.Trim()
}

function Get-FortinetDriverPackages {
    $infDir = Join-Path $env:SystemRoot 'INF'
    if (-not (Test-Path -LiteralPath $infDir)) { return }

    Get-ChildItem -Path $infDir -Filter 'oem*.inf' -File -ErrorAction SilentlyContinue | ForEach-Object {
        # ReadAllLines, not Get-Content: in PS 5.1 Get-Content wraps every line
        # in a PSObject carrying PSPath/PSParentPath/ReadCount note properties.
        # The driver store here is ~149 oem*.inf / 9.1 MB / 164k lines, and all
        # but a handful are discarded one line below - so that decoration was
        # seconds per pass, on a function called three times per run. Both
        # consumers below take a plain string[] identically.
        $text = $null
        try { $text = [System.IO.File]::ReadAllLines($_.FullName) } catch { return }
        if ($null -eq $text) { return }

        # Gate on the Provider directive, not on a substring anywhere in the file.
        if ((Get-InfProviderName $text) -notmatch '(?i)^Fortinet\b') { return }

        # Class= is an INF keyword with a fixed, non-localized value set, so this
        # test is safe on any Windows language. NetService is the NDIS
        # lightweight-filter class - the one that must be removed LAST.
        $classLines = @($text | Where-Object { $_ -match '(?i)^\s*Class\s*=' })
        $class = ''
        if ($classLines.Count -gt 0) {
            $cm = [regex]::Match($classLines[0], '(?i)^\s*Class\s*=\s*(\S+)')
            if ($cm.Success) { $class = $cm.Groups[1].Value }
        }

        [pscustomobject]@{
            PublishedName = $_.Name
            InfPath       = $_.FullName
            Class         = $class
            IsNetService  = ($class -match '(?i)^NetService$')
            # Tested against the WHOLE file, not against the Fortinet-matching
            # lines: in the real pppop.inf the vendor token and the driver name
            # never share a line (its two Fortinet lines are the [Strings]
            # entries, and 41 other lines say pppop), so a co-occurrence test
            # returns False and the -IncludeLegacyPppop opt-out never engages.
            IsLegacyPppop = (@($text | Where-Object { $_ -match '(?i)pppop' }).Count -gt 0)
        }
    }
}

# Re-verify a driver package immediately before deleting it. The census could
# have been taken minutes ago; oem numbering is mutable; and this is the call
# that, given a wrong argument, uninstalls somebody else's hardware.
function Test-FortinetInfStillValid {
    param([string]$InfPath)
    if ([string]::IsNullOrWhiteSpace($InfPath)) { return $false }
    if (-not (Test-Path -LiteralPath $InfPath)) { return $false }
    try {
        $text = [System.IO.File]::ReadAllLines($InfPath)
        return ((Get-InfProviderName $text) -match '(?i)^Fortinet\b')
    }
    catch { return $false }
}

# PnP devnodes are resolved by their SERVICE binding at runtime. ROOT\NET\000N
# instance IDs are POSITIONAL - they renumber as root-enumerated devices come
# and go, and Hyper-V's ROOT\VMS_VSMP and Microsoft's ROOT\KDNIC live in the same
# namespace - so a hardcoded ROOT\NET\0001 on another machine could remove an
# unrelated virtual NIC.
function Get-FortinetPnpDevices {
    param([string[]]$ServiceNames)
    if (-not (Get-Command Get-PnpDevice -ErrorAction SilentlyContinue)) { return }
    $devices = $null
    try { $devices = @(Get-PnpDevice -ErrorAction Stop) } catch { return }
    if ($null -eq $devices) { return }

    foreach ($svc in $ServiceNames) {
        $match = @($devices | Where-Object {
            (-not [string]::IsNullOrWhiteSpace($_.Service)) -and ($_.Service -eq $svc)
        })
        if ($match.Count -eq 0) { continue }
        foreach ($d in $match) {
            [pscustomobject]@{
                InstanceId   = $d.InstanceId
                FriendlyName = $d.FriendlyName
                Service      = $d.Service
                Status       = $d.Status
                Class        = $d.Class
                Ambiguous    = ($match.Count -gt 1)
            }
        }
    }
}

function Get-FortinetFirewallRules {
    param([string[]]$Roots)
    if (-not (Get-Command Get-NetFirewallRule -ErrorAction SilentlyContinue)) { return }

    $byGroup = @()
    try {
        $byGroup = @(Get-NetFirewallRule -Group $FirewallGroupName -ErrorAction SilentlyContinue)
    }
    catch { }

    # Second, independent route: rules whose application filter names a program
    # under a discovered Fortinet root. This catches a renamed or regrouped rule
    # without ever matching on a loose 'forti' substring, which would sweep up
    # unrelated rules a user may have authored.
    $byProgram = @()
    if ($Roots.Count -gt 0 -and (Get-Command Get-NetFirewallApplicationFilter -ErrorAction SilentlyContinue)) {
        try {
            $byProgram = @(Get-NetFirewallApplicationFilter -ErrorAction SilentlyContinue |
                Where-Object {
                    (-not [string]::IsNullOrWhiteSpace($_.Program)) -and
                    (Test-PathUnderAny -Path $_.Program -Roots $Roots)
                } |
                ForEach-Object {
                    try { $_ | Get-NetFirewallRule -ErrorAction Stop } catch { }
                })
        }
        catch { }
    }

    @($byGroup + $byProgram) | Where-Object { $null -ne $_ } |
        Group-Object -Property Name | ForEach-Object { $_.Group[0] }
}

# Install roots, resolved from the registry rather than hardcoded. INSTALLDIR is
# read BEFORE anything deletes the hive that holds it.
function Get-FortinetRoots {
    param($Products)
    $roots = @()

    foreach ($key in @('HKLM:\SOFTWARE\Fortinet\FortiClient', 'HKLM:\SOFTWARE\WOW6432Node\Fortinet\FortiClient')) {
        if (-not (Test-Path $key)) { continue }
        $props = $null
        try { $props = Get-ItemProperty -Path $key -ErrorAction Stop } catch { continue }
        $dir = Get-Prop $props 'INSTALLDIR'
        if (-not [string]::IsNullOrWhiteSpace($dir)) { $roots += $dir }
    }

    foreach ($p in $Products) {
        if (-not [string]::IsNullOrWhiteSpace($p.InstallLocation)) { $roots += $p.InstallLocation }
    }

    # Conventional locations, added only when they actually exist. Verified on
    # this platform: of these, only C:\Program Files\Fortinet is present.
    foreach ($base in @(${env:ProgramFiles}, ${env:ProgramFiles(x86)}, ${env:ProgramData})) {
        if ([string]::IsNullOrWhiteSpace($base)) { continue }
        foreach ($name in $CandidateRootNames) {
            $candidate = Join-Path $base $name
            if (Test-Path -LiteralPath $candidate) { $roots += $candidate }
        }
    }

    # Normalize to the Fortinet PARENT folder, not the FortiClient subfolder:
    # INSTALLDIR points at ...\Fortinet\FortiClient\, and cleanup wants the
    # whole vendor tree. @( ) wraps the entire pipeline - with a single root,
    # Select-Object -Unique emits a bare string and a later '+=' would become
    # string concatenation.
    $normalized = @($roots | ForEach-Object {
        $c = $_.Trim().Trim('"').TrimEnd('\')
        if ($c -match '(?i)^(.*\\Fortinet)\\FortiClient$') { $matches[1] } else { $c }
    } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)

    return $normalized
}

# A discovery ROOT is every bit as dangerous as a deletion TARGET: it is the sole
# attribution route for Stop-Process, sc.exe delete and pnputil /remove-device.
# INSTALLDIR and InstallLocation are vendor-authored and routinely malformed - a
# bare drive root, or "C:\Program Files" when the MSI's directory property was
# never set. Measured: with a root of "C:", Test-PathUnderAny matches everything,
# and 183 of this machine's 360 running processes - explorer.exe, lsass.exe,
# svchost.exe - would be attributed to FortiClient and terminated. So roots get
# the same refusals Test-SafeResidualPath applies to Remove-Item targets.
function Test-SafeScopeRoot {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    $full = $Path.Trim().Trim('"').TrimEnd('\')
    if ($full -match '^[a-zA-Z]:\\?$')   { return $false }   # C:\ scopes the whole drive
    if (($full -split '\\').Count -lt 3) { return $false }   # C:\Program Files
    foreach ($r in $ForbiddenResidualRoots) {
        if ((Get-ComparablePath $full) -eq (Get-ComparablePath $r)) { return $false }
    }
    # BOTH spellings are accepted. "FortiClient" does not contain the substring
    # "Fortinet" (Forti+Client vs Forti+net), so a Fortinet-only test would
    # silently discard a custom-directory install such as D:\Apps\FortiClient and
    # quietly degrade process and service discovery to nothing.
    return (($full -match '(?i)\\Fortinet($|\\)') -or ($full -match '(?i)\\FortiClient($|\\)'))
}

$FortinetRoots = @(Get-FortinetRoots -Products $products | Where-Object {
    if (Test-SafeScopeRoot $_) { $true }
    else {
        Write-Log "Discarding unsafe Fortinet install root '$_': it is a drive root, a top-level system container, or does not name the vendor. Scoping process, service and devnode removal to it would attribute unrelated software to Fortinet." 'WARN'
        $false
    }
})
if ($FortinetRoots.Count -gt 0) {
    Write-Log 'Fortinet install roots:'
    $FortinetRoots | ForEach-Object { Write-Log "    - $_" }
}

$services  = @(Get-FortinetServices -Roots $FortinetRoots)
$packages  = @(Get-FortinetDriverPackages)
$pnpDevs   = @(Get-FortinetPnpDevices -ServiceNames @($services | Where-Object { $_.IsDriver } | ForEach-Object { $_.Name }))
$fwRules   = @(Get-FortinetFirewallRules -Roots $FortinetRoots)

if ($services.Count -gt 0) {
    Write-Log "Fortinet services and drivers ($($services.Count)):" 'OK'
    $services | Sort-Object -Property @{ Expression = 'IsDriver' }, @{ Expression = 'Name' } | ForEach-Object {
        Write-Log ("    {0,-14} {1,-8} start={2} {3} -> {4}" -f `
            $_.Name,
            $_.Status,
            $_.Start,
            $(if ($_.IsDriver) { '[driver]' } else { '[service]' }),
            $_.BinaryPath)
    }
}

if ($packages.Count -gt 0) {
    Write-Log "Fortinet driver-store packages ($($packages.Count)):" 'OK'
    $packages | ForEach-Object {
        Write-Log ("    {0}  class={1}{2}{3}" -f `
            $_.PublishedName,
            $(if ($_.Class) { $_.Class } else { '?' }),
            $(if ($_.IsNetService) { '  [NDIS filter - removed LAST]' } else { '' }),
            $(if ((-not $IncludeLegacyPppop) -and $_.IsLegacyPppop) { '  [legacy PPPoP - KEPT]' } else { '' }))
    }
}

if ($pnpDevs.Count -gt 0) {
    Write-Log "Fortinet PnP devices ($($pnpDevs.Count)):" 'OK'
    $pnpDevs | ForEach-Object {
        Write-Log ("    {0}  [{1}]  service={2}  status={3}" -f $_.FriendlyName, $_.InstanceId, $_.Service, $_.Status)
    }
}

if ($fwRules.Count -gt 0) {
    Write-Log "Windows Firewall rules ($($fwRules.Count)) in group '$FirewallGroupName'."
}

# EMS / telemetry registration state. Reported so the operator knows what the
# removal actually severs. The identity values in this key (fctuid, user,
# full_user_name) are encrypted and are NEVER read, logged or exported here.
$emsKey = 'HKLM:\SOFTWARE\Fortinet\FortiClient\FA_ESNAC'
if (Test-Path $emsKey) {
    $emsProps = $null
    try { $emsProps = Get-ItemProperty -Path $emsKey -ErrorAction Stop } catch { }
    if ((ConvertTo-IntOrZero (Get-Prop $emsProps 'enabled')) -eq 1) {
        Write-Log 'This endpoint is registered to a FortiClient EMS / FortiGate (ESNAC telemetry enabled). Removal stops its keepalives and deletes the local registration. It does NOT deregister the endpoint server-side - only that controller''s administrator can do that.' 'WARN'
    }
}

# Residual locations. Assembled now, reported under -ListOnly, consumed at the
# end - and every single one is Test-Path'd at use.
$ResidualPaths = @()
# The vendor parent (...\Fortinet) is the SCOPING root for process and firewall
# attribution, NOT a deletion target: sibling Fortinet products install beside
# FortiClient underneath it, and Remove-Item -Recurse there would take them with
# it. Queue only FortiClient's own folder. A root that is ALREADY the product
# folder (a non-default INSTALLDIR the normalization left alone) is queued whole.
# The parent itself is swept later, and only if it ends up empty.
foreach ($r in $FortinetRoots) {
    if ($r -match '(?i)\\Fortinet$') {
        foreach ($leaf in @('FortiClient', 'FortiClient VPN')) {
            $c = Join-Path $r $leaf
            if (Test-Path -LiteralPath $c) { $ResidualPaths += $c }
        }
    }
    else {
        $ResidualPaths += $r
    }
}
foreach ($base in @(${env:ProgramData})) {
    if ([string]::IsNullOrWhiteSpace($base)) { continue }
    $ResidualPaths += (Join-Path $base 'Microsoft\Windows\Start Menu\Programs\FortiClient')
}
if (-not [string]::IsNullOrWhiteSpace(${env:PUBLIC})) {
    $ResidualPaths += (Join-Path ${env:PUBLIC} 'Desktop\FortiClient.lnk')
}
# Per-user AppData. Verified absent on this platform for every profile, which is
# exactly why each one is probed rather than assumed.
$userRoot = Join-Path ${env:SystemDrive} 'Users'
if (Test-Path -LiteralPath $userRoot) {
    Get-ChildItem -Path $userRoot -Directory -Force -ErrorAction SilentlyContinue | ForEach-Object {
        foreach ($leaf in @('AppData\Local\Fortinet', 'AppData\Roaming\Fortinet', 'AppData\LocalLow\Fortinet')) {
            $ResidualPaths += (Join-Path $_.FullName $leaf)
        }
    }
}
$ResidualPaths = @($ResidualPaths | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)

if ($ListOnly) {
    $existing = @($ResidualPaths | Where-Object { Test-Path -LiteralPath $_ })
    if ($existing.Count -gt 0) {
        Write-Log 'Residual locations that would be removed:'
        $existing | ForEach-Object { Write-Log "    - $_" }
    }

    # Mirrors the -IncludeLegacyPppop guards in the real run, so the preview never
    # promises a removal the actual run refuses to perform.
    $orphanSys = @($services | Where-Object {
        $_.IsDriver -and $_.BinaryFound -and ($IncludeLegacyPppop -or $_.Name -ne 'pppop')
    })
    if ($orphanSys.Count -gt 0) {
        Write-Log 'Driver files that would be removed after the reboot:'
        $orphanSys | ForEach-Object { Write-Log "    - $($_.BinaryPath)" }
    }

    $keptLegacy = @($services | Where-Object {
        $_.IsDriver -and $_.BinaryFound -and -not $IncludeLegacyPppop -and $_.Name -eq 'pppop'
    })
    if ($keptLegacy.Count -gt 0) {
        Write-Log 'Legacy Fortinet driver file(s) that would be KEPT. Pass -IncludeLegacyPppop to remove:' 'WARN'
        $keptLegacy | ForEach-Object { Write-Log "    - $($_.BinaryPath)" }
    }

    if ($RemoveResidualRegistry) {
        Write-Log 'Registry hives that would be removed:'
        foreach ($k in @('HKLM:\SOFTWARE\Fortinet', 'HKLM:\SOFTWARE\WOW6432Node\Fortinet', 'HKCU:\SOFTWARE\Fortinet')) {
            if (Test-Path $k) { Write-Log "    - $k" }
        }
    }

    # Includes the residue, so the preview and the real run agree on what
    # "nothing to remove" means - the real run's exit-2 gate does the same.
    if ($products.Count -eq 0 -and $services.Count -eq 0 -and $packages.Count -eq 0 -and
        $fwRules.Count -eq 0 -and $existing.Count -eq 0 -and $orphanSys.Count -eq 0) {
        Write-Log 'Nothing to remove: no Fortinet product, service, driver, package or residual file found.' 'OK'
    }
    Write-Log "Log saved to: $LogPath"
    try { Stop-Transcript | Out-Null } catch { }
    exit 0
}

# Registration state is not the whole story. After a successful first pass and a
# reboot, every census above is empty BY CONSTRUCTION - the MSI took the product
# row, sc.exe took the service keys, pnputil took the oemNN.inf, and the firewall
# rules are gone. That is precisely the run that is supposed to sweep the .sys
# files the kernel was holding and the folders left behind, so the residue has to
# be consulted before declaring there is nothing to do. Without this, the
# documented "re-run after the reboot" second pass exits 2 and does nothing.
$residualPresent = $false
if ($RemoveResidualFiles) {
    $residualPresent = @($ResidualPaths | Where-Object { Test-Path -LiteralPath $_ }).Count -gt 0
    if (-not $residualPresent) {
        # Same predicate and the same pppop exclusion as the real sweep, so a
        # machine that deliberately KEEPS pppop64.sys does not report residue
        # forever and re-run a full no-op pass on every invocation.
        $driverDirProbe = Join-Path $env:SystemRoot 'System32\drivers'
        if (Test-Path -LiteralPath $driverDirProbe) {
            $residualPresent = @(Get-ChildItem -Path $driverDirProbe -Filter '*.sys' -File -ErrorAction SilentlyContinue |
                Where-Object {
                    ($IncludeLegacyPppop -or $_.Name -notmatch '(?i)^pppop') -and (Test-FortinetBinary $_.FullName)
                }).Count -gt 0
        }
    }
}
if (-not $residualPresent -and $RemoveResidualRegistry) {
    foreach ($k in @('HKLM:\SOFTWARE\Fortinet', 'HKLM:\SOFTWARE\WOW6432Node\Fortinet', 'HKCU:\SOFTWARE\Fortinet')) {
        if (Test-Path $k) { $residualPresent = $true; break }
    }
}

if ($products.Count -eq 0 -and $services.Count -eq 0 -and $packages.Count -eq 0 -and $fwRules.Count -eq 0 -and
    -not $residualPresent) {
    Write-Log 'Nothing to remove: no Fortinet product, service, driver, package or residual file found.' 'OK'
    Write-Log "Log saved to: $LogPath"
    try { Stop-Transcript | Out-Null } catch { }
    exit 2
}

# --- Running-process guard ------------------------------------------------
# Attribution is by PATH for the colliding names and by NAME only for the ones
# verified unique to FortiClient. A process whose path cannot be read (protected
# or another user's) is killed only when its name is in the verified-own list.
function Get-FortiClientProcesses {
    param([string[]]$Roots)
    Get-Process -ErrorAction SilentlyContinue | ForEach-Object {
        $path = $null
        # .Path throws for protected and other-user processes, so it is read
        # inside its own try/catch rather than guarded by a preference variable.
        try { $path = $_.Path } catch { }

        $nameIsOwn = ($FortiOwnProcessNames -contains $_.ProcessName)
        $nameIsScoped = ($PathScopedProcessNames -contains $_.ProcessName)
        $inScope = $false
        if ((-not [string]::IsNullOrWhiteSpace($path)) -and $Roots.Count -gt 0) {
            $inScope = Test-PathUnderAny -Path $path -Roots $Roots
        }

        if (-not ($nameIsOwn -or ($nameIsScoped -and $inScope) -or $inScope)) { return }

        [pscustomobject]@{
            Process   = $_
            Name      = $_.ProcessName
            Path      = $path
            InScope   = $inScope
            NameIsOwn = $nameIsOwn
        }
    }
}

# An active tunnel is the one state in which tearing this stack down can strand
# routes and black-hole the default gateway.
if (-not $SkipTunnelGuard -and (Get-Command Get-NetAdapter -ErrorAction SilentlyContinue)) {
    $upTunnels = @()
    try {
        $upTunnels = @(Get-NetAdapter -IncludeHidden -ErrorAction SilentlyContinue |
            Where-Object {
                (-not [string]::IsNullOrWhiteSpace($_.InterfaceDescription)) -and
                ($_.InterfaceDescription -match '(?i)fortinet') -and
                ($_.Status -eq 'Up')
            })
    }
    catch { }
    if ($upTunnels.Count -gt 0) {
        $upTunnels | ForEach-Object { Write-Log "Fortinet adapter is UP: $($_.Name) - $($_.InterfaceDescription)" 'ERROR' }
        Write-Log 'A Fortinet virtual adapter is active, which usually means a VPN tunnel is connected. Disconnect it first, or re-run with -SkipTunnelGuard.' 'ERROR'
        Write-Log "Log saved to: $LogPath"
        try { Stop-Transcript | Out-Null } catch { }
        exit 1
    }
}

$fortiProcs = @(Get-FortiClientProcesses -Roots $FortinetRoots)
# A name in $FortiOwnProcessNames is verified unique to FortiClient, so it counts
# whether or not its path resolves under a discovered root. Requiring "-and not
# $_.Path" as well meant that a FortiTray.exe whose path WAS readable but sat
# outside the discovered roots - the normal case when neither INSTALLDIR nor
# InstallLocation is registered, so $FortinetRoots is empty - was silently
# dropped, and the running-process guard passed with FortiClient still running.
$inScope    = @($fortiProcs | Where-Object { $_.InScope -or $_.NameIsOwn })

if ($inScope.Count -gt 0) {
    Write-Log "FortiClient processes running ($($inScope.Count)):" 'WARN'
    $inScope | ForEach-Object {
        Write-Log ("    {0} (PID {1}) {2}" -f $_.Name, $_.Process.Id, $(if ($_.Path) { $_.Path } else { '[path unavailable]' }))
    }

    if (-not $StopFortiClient) {
        Write-Log 'FortiClient is running. Re-run with -StopFortiClient, or close it first. Uninstalling with live processes leaves locked files and a half-finished removal.' 'ERROR'
        Write-Log "Log saved to: $LogPath"
        try { Stop-Transcript | Out-Null } catch { }
        exit 1
    }

    # ORDER MATTERS. FA_Scheduler is the parent launcher for the tray, the ESNAC
    # agent and the VPN daemon; killing a child first just gets it restarted and
    # the loop never converges. Stop the service, THEN kill what remains.
    if (Get-Service -Name $SchedulerServiceName -ErrorAction SilentlyContinue) {
        if ($PSCmdlet.ShouldProcess($SchedulerServiceName, 'Stop service')) {
            try {
                Stop-Service -Name $SchedulerServiceName -Force -ErrorAction Stop
                $svc = Get-Service -Name $SchedulerServiceName -ErrorAction SilentlyContinue
                if ($svc) { $svc.WaitForStatus('Stopped', '00:01:00') }
                Write-Log "Stopped service $SchedulerServiceName." 'OK'
            }
            catch {
                Write-Log "Could not stop $SchedulerServiceName : $($_.Exception.Message)" 'WARN'
            }
        }
    }

    foreach ($p in $inScope) {
        if (-not $PSCmdlet.ShouldProcess("$($p.Name) (PID $($p.Process.Id))", 'Stop process')) { continue }
        try {
            Stop-Process -Id $p.Process.Id -Force -ErrorAction Stop
            Write-Log "    terminated $($p.Name) (PID $($p.Process.Id))"
        }
        catch {
            Write-Log "      could not terminate: $($_.Exception.Message)" 'WARN'
        }
    }
    if (-not $WhatIfPreference) { Start-Sleep -Seconds 3 }
}

# --- MSI uninstall --------------------------------------------------------
$failures     = 0
$skipped      = 0
$rebootNeeded = $false
$pendingFiles = 0

foreach ($product in $products) {
    # msiexec /x takes a ProductCode. A non-MSI row's KeyName is a bare string,
    # for which msiexec returns 1619 - not in $MsiSuccessCodes - which trips
    # $failures++ and then aborts the ENTIRE driver phase after the real
    # FortiClient MSI has already run. Deliberately NOT also testing
    # WindowsInstaller -eq 1: measured on this machine, 83 of 668 GUID-keyed
    # uninstall rows carry no WindowsInstaller value at all, so that test would
    # silently skip genuine MSI products. The key name is the authoritative form.
    if ($product.KeyName -notmatch '^\{[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\}$') {
        Write-Log "Skipping $($product.DisplayName): registry key '$($product.KeyName)' is not an MSI ProductCode. Uninstall it with its own UninstallString." 'WARN'
        $skipped++
        continue
    }

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

    # The registered UninstallString is "MsiExec.exe /X{GUID}" with an EMPTY
    # QuietUninstallString, so /qn must be supplied explicitly - running the
    # harvested string verbatim opens an interactive dialog and blocks forever
    # under -Force. The product code is taken from the registry KEY NAME, which
    # is the authoritative form.
    $stamp    = Get-Date -Format 'yyyyMMdd_HHmmss'
    $vlog     = Join-Path $env:TEMP ("MSIVerbose_{0}_{1}.log" -f ($product.KeyName -replace '[{}]', ''), $stamp)
    $msiArgs  = @('/x', $product.KeyName, '/qn', '/norestart', 'REBOOT=ReallySuppress', '/l*v', ('"' + $vlog + '"'))

    Write-Log "Uninstalling $($product.DisplayName) ($($product.KeyName))..."
    Write-Log "    verbose log: $vlog"

    $rc = $null
    try {
        $rc = Start-Process -FilePath 'msiexec.exe' -ArgumentList $msiArgs -Wait -PassThru -ErrorAction Stop
    }
    catch {
        Write-Log "msiexec could not be started: $($_.Exception.Message)" 'ERROR'
        $failures++
        continue
    }

    $code = 0
    if ($rc -and $null -ne $rc.ExitCode) { $code = $rc.ExitCode }

    if ($MsiSuccessCodes -contains $code) {
        if ($code -eq 3010) { $rebootNeeded = $true }
        Write-Log ("Uninstalled {0} (exit {1}{2})." -f $product.DisplayName, $code, $(if ($code -eq 3010) { ', reboot required' } elseif ($code -eq 1605) { ', already gone' } else { '' })) 'OK'
    }
    else {
        # 1603 on FortiClient is usually a live process or an EMS-side uninstall
        # lock, not a broken package - and the verbose log names which.
        Write-Log "Uninstall FAILED for $($product.DisplayName) with exit code $code. Review $vlog" 'ERROR'
        if ($code -eq 1603) {
            Write-Log '    1603 here is normally a still-running FortiClient process or an EMS-enforced uninstall lock. Check the verbose log for "uninstall" and "password".' 'WARN'
        }
        $failures++
    }
}

# --- Driver package removal -----------------------------------------------
# Re-census AFTER the MSI: the question is not what FortiClient installed, it is
# what the vendor uninstaller orphaned.
# $skipped is in the gate as well as $failures. A declined product is still
# INSTALLED, and this phase contains two operations with no per-item prompt of
# their own - "sc.exe delete FA_Scheduler" and the firewall-rule removal - so
# without it, answering N to "Uninstall FortiClient?" still stripped the service
# and the firewall rules off a fully working installation.
if ($RemoveDrivers -and $failures -eq 0 -and $skipped -eq 0) {
    $services = @(Get-FortinetServices -Roots $FortinetRoots)
    $packages = @(Get-FortinetDriverPackages)
    $pnpDevs  = @(Get-FortinetPnpDevices -ServiceNames @($services | Where-Object { $_.IsDriver } | ForEach-Object { $_.Name }))

    # Order: devnodes first, then packages, NetService/LWF package last. A
    # package deleted while its devnode is still present either fails or leaves a
    # phantom device Windows re-enumerates as a problem device on every boot.
    foreach ($dev in $pnpDevs) {
        if ($dev.Ambiguous) {
            Write-Log "Refusing to remove device '$($dev.FriendlyName)': more than one devnode binds service '$($dev.Service)', so the target is ambiguous." 'WARN'
            continue
        }
        if (-not $IncludeLegacyPppop -and $dev.Service -eq 'pppop') {
            Write-Log "Keeping legacy device '$($dev.FriendlyName)' [$($dev.InstanceId)]. It is a separate 2016-vintage Fortinet package; pass -IncludeLegacyPppop to remove it." 'WARN'
            continue
        }
        if (-not $Force -and -not $WhatIfPreference) {
            $answer = Read-Host "Remove device '$($dev.FriendlyName)' [$($dev.InstanceId)]? [Y/N]"
            if ($answer -notmatch '^(y|yes)$') { Write-Log "Skipped device: $($dev.InstanceId)" 'WARN'; continue }
        }
        if (-not $PSCmdlet.ShouldProcess($dev.InstanceId, 'Remove PnP device')) { continue }

        $rcDev = Invoke-NativeCommand -FilePath 'pnputil.exe' -Arguments @('/remove-device', $dev.InstanceId)
        # 3010 = ERROR_SUCCESS_REBOOT_REQUIRED: the devnode WAS removed, the
        # teardown just completes on restart. Success, not failure.
        if ($rcDev.ExitCode -eq 0 -or $rcDev.ExitCode -eq 3010) {
            Write-Log ("Removed device {0} ({1}){2}." -f $dev.InstanceId, $dev.FriendlyName, $(if ($rcDev.ExitCode -eq 3010) { ' - reboot required to finalize' } else { '' })) 'OK'
            if ($rcDev.ExitCode -eq 3010) { $rebootNeeded = $true }
        }
        else {
            # Not fatal: /delete-driver /uninstall removes devices using the
            # package on current Windows builds, and older pnputil takes a
            # different switch form.
            Write-Log "pnputil /remove-device returned $($rcDev.ExitCode) for $($dev.InstanceId); the driver package removal below normally covers it." 'WARN'
        }
    }

    # NetService LAST. Sorting on the INF's own Class= keyword rather than on a
    # remembered name keeps this correct if Fortinet renames the package.
    $ordered = @($packages | Sort-Object -Property @{ Expression = { [int]$_.IsNetService } }, @{ Expression = 'PublishedName' })

    foreach ($pkg in $ordered) {
        if (-not $IncludeLegacyPppop -and $pkg.IsLegacyPppop) {
            Write-Log "Keeping legacy driver package $($pkg.PublishedName) (Fortinet PPPoP WAN Adapter). Pass -IncludeLegacyPppop to remove it." 'WARN'
            continue
        }

        # THE GUARD THAT MATTERS. Re-read the INF and confirm Fortinet
        # provenance in the seconds before deleting it. oemNN numbering is
        # recycled by Windows: this machine's ftsvnic service still names
        # oem45.inf, which now belongs to NVIDIA. Never trust a remembered
        # number; trust the file.
        if (-not (Test-FortinetInfStillValid -InfPath $pkg.InfPath)) {
            Write-Log "REFUSING to delete driver package $($pkg.PublishedName): $($pkg.InfPath) no longer reads as a Fortinet INF. oem numbers are recycled by Windows and this one now belongs to another vendor." 'ERROR'
            continue
        }

        if ($pkg.IsNetService) {
            Write-Log "Removing the NDIS filter package $($pkg.PublishedName) - this briefly unbinds every network adapter." 'WARN'
        }

        if (-not $Force -and -not $WhatIfPreference) {
            $answer = Read-Host "Delete driver package '$($pkg.PublishedName)' ($($pkg.InfPath))? [Y/N]"
            if ($answer -notmatch '^(y|yes)$') { Write-Log "Skipped package: $($pkg.PublishedName)" 'WARN'; continue }
        }
        if (-not $PSCmdlet.ShouldProcess($pkg.PublishedName, 'Delete driver package')) { continue }

        $rcPkg = Invoke-NativeCommand -FilePath 'pnputil.exe' -Arguments @('/delete-driver', $pkg.PublishedName, '/uninstall')
        # 3010 = ERROR_SUCCESS_REBOOT_REQUIRED. pnputil returns it when the package
        # WAS removed but the unbind/unload only completes on restart - the
        # EXPECTED result for the Class=NetService filter, not a failure. Treating
        # it as one aborted firewall and residual cleanup and returned exit 3 on a
        # completely healthy removal.
        if ($rcPkg.ExitCode -eq 0 -or $rcPkg.ExitCode -eq 3010) {
            Write-Log ("Deleted driver package {0}{1}." -f $pkg.PublishedName, $(if ($rcPkg.ExitCode -eq 3010) { ' (reboot required)' } else { '' })) 'OK'
            $rebootNeeded = $true
        }
        else {
            # Deliberately NOT retried with /force. Forcing the NetService
            # package out while it is still bound to live adapters is the exact
            # sequence that leaves the NDIS binding database pointing at a
            # filter that no longer exists.
            Write-Log "pnputil /delete-driver returned $($rcPkg.ExitCode) for $($pkg.PublishedName). Reboot and re-run; do NOT force it while the filter is still bound." 'WARN'
            $failures++
        }
    }

    # --- Orphaned service removal -----------------------------------------
    # Whatever service keys survive the package removal have no driver package
    # backing them - ftsvnic on this machine is exactly that, a leftover from an
    # older FortiClient whose package is long gone. Deleting the SERVICE KEY is
    # safe and is what stops the boot loader referencing a missing binary; the
    # FILE is left for the post-reboot sweep, because the reverse order is what
    # risks a boot-time driver error.
    $services = @(Get-FortinetServices -Roots $FortinetRoots)

    # A service key is only "orphaned" if no surviving driver package still owns
    # it. If the NetService/LWF package failed to delete, was refused by the INF
    # re-check, or was declined at the prompt, FortiFilter is STILL BOUND into
    # every adapter - and "sc.exe delete FortiFilter" here would be precisely the
    # operation .DESCRIPTION trap 3 forbids, performed by hand. Re-enumerate what
    # actually survived rather than assuming the package loop emptied the field.
    $survivingPackages  = @(Get-FortinetDriverPackages)
    $netServiceSurvived = (@($survivingPackages | Where-Object { $_.IsNetService }).Count -gt 0)
    if ($netServiceSurvived) {
        Write-Log 'A Fortinet NetService/LWF driver package survived removal, so its NDIS bindings are still live. Skipping the orphaned-driver-service sweep: deleting a service key by hand while the filter is still bound is what leaves the binding database pointing at a filter that no longer exists. Reboot and re-run to finish.' 'WARN'
    }

    foreach ($svc in @($services | Where-Object { $_.IsDriver })) {
        if ($netServiceSurvived) { continue }
        if (-not $IncludeLegacyPppop -and $svc.Name -eq 'pppop') {
            Write-Log "Keeping legacy service '$($svc.Name)' (Fortinet PPPoP WAN Adapter)." 'WARN'
            continue
        }
        if (-not $Force -and -not $WhatIfPreference) {
            $answer = Read-Host "Delete orphaned driver service '$($svc.Name)' ($($svc.BinaryPath))? [Y/N]"
            if ($answer -notmatch '^(y|yes)$') { Write-Log "Skipped service: $($svc.Name)" 'WARN'; continue }
        }
        if (-not $PSCmdlet.ShouldProcess($svc.Name, 'Delete driver service')) { continue }

        # sc.exe, never 'sc' - in PowerShell 'sc' is an alias for Set-Content,
        # so a bare "sc delete FortiFW" silently tries to WRITE A FILE.
        $null = Invoke-NativeCommand -FilePath 'sc.exe' -Arguments @('stop', $svc.Name)
        $rcSvc = Invoke-NativeCommand -FilePath 'sc.exe' -Arguments @('delete', $svc.Name)
        # 1060 = "service does not exist", i.e. the MSI already took it. That is
        # success on a re-run, not a failure.
        if ($rcSvc.ExitCode -eq 0 -or $rcSvc.ExitCode -eq 1060) {
            Write-Log "Deleted driver service $($svc.Name)." 'OK'
            # 1060 = the key was already gone; nothing changed, so no reboot is owed.
            if ($rcSvc.ExitCode -eq 0) { $rebootNeeded = $true }
        }
        else {
            # The service key SURVIVES. $failures++ is not bookkeeping: it is what
            # makes the residual sweep skip this run, so the .sys that this
            # still-registered key points at is NOT deleted out from under it -
            # the exact reverse order the ordering comment above forbids.
            Write-Log "sc.exe delete returned $($rcSvc.ExitCode) for $($svc.Name); the service key survives, so its binary is deliberately left in place. Reboot and re-run." 'ERROR'
            $failures++
        }
    }

    # The user-mode service, if the MSI left it behind.
    if (Get-Service -Name $SchedulerServiceName -ErrorAction SilentlyContinue) {
        if ($PSCmdlet.ShouldProcess($SchedulerServiceName, 'Delete service')) {
            $rcSch = Invoke-NativeCommand -FilePath 'sc.exe' -Arguments @('delete', $SchedulerServiceName)
            if ($rcSch.ExitCode -eq 0 -or $rcSch.ExitCode -eq 1060) {
                Write-Log "Deleted service $SchedulerServiceName." 'OK'
            }
            else {
                Write-Log "sc.exe delete returned $($rcSch.ExitCode) for $SchedulerServiceName; the service is still registered." 'ERROR'
                $failures++
            }
        }
    }
}
elseif ($RemoveDrivers -and ($failures -gt 0 -or $skipped -gt 0)) {
    Write-Log 'Skipping driver removal because the product uninstall did not complete (it failed, or was declined and is still installed). Removing drivers under a half-uninstalled product is how a machine loses its network stack.' 'WARN'
}
elseif (-not $RemoveDrivers) {
    Write-Log 'Skipping driver removal (-RemoveDrivers:$false). Driver packages, devnodes and service keys are left registered.' 'WARN'
}

# --- Firewall rules -------------------------------------------------------
if ($RemoveFirewallRules -and $failures -eq 0 -and $skipped -eq 0) {
    $fwRules   = @(Get-FortinetFirewallRules -Roots $FortinetRoots)
    $fwRemoved = 0
    foreach ($rule in $fwRules) {
        if (-not $PSCmdlet.ShouldProcess($rule.DisplayName, 'Remove firewall rule')) { continue }
        try {
            # -InputObject binds the harvested rule directly. -Name treats its
            # argument as a WILDCARD PATTERN, so a rule whose name contains a
            # bracket or other metacharacter would match nothing - or a set.
            Remove-NetFirewallRule -InputObject $rule -ErrorAction Stop
            Write-Log "Removed firewall rule: $($rule.DisplayName)"
            $fwRemoved++
        }
        catch {
            # WARN, never $failures++. $failures gates the residual sweep and the
            # exit code, and an inert leftover allow-rule - or one a concurrent
            # policy refresh already removed - is no reason to withhold the file
            # and registry cleanup or to report exit 3.
            Write-Log "Could not remove firewall rule '$($rule.DisplayName)': $($_.Exception.Message)" 'WARN'
        }
    }
    # Report what was actually removed, never the census size: a preview, a
    # declined confirmation and a policy-sourced rule that refuses deletion all
    # leave the rule in place, and all three used to be reported as success.
    if ($fwRemoved -gt 0) {
        Write-Log "Removed $fwRemoved of $($fwRules.Count) Fortinet firewall rule(s)." 'OK'
    }
    elseif ($fwRules.Count -gt 0 -and -not $WhatIfPreference) {
        Write-Log "No firewall rule was removed ($($fwRules.Count) matched)." 'WARN'
    }
}
elseif ($RemoveFirewallRules -and $skipped -gt 0) {
    Write-Log "Skipping firewall rule removal because $skipped product(s) were declined and are still installed." 'WARN'
}

# --- Residual file cleanup ------------------------------------------------
# Hard safety guard. Five refusals, each of which logs before returning $false.
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
    # which is the whole point (C:\Program Files\Fortinet is under
    # C:\Program Files). The containment test therefore runs against the roots
    # themselves, comparing for equality only.
    foreach ($r in $ForbiddenResidualRoots) {
        if ((Get-ComparablePath $full) -eq (Get-ComparablePath $r)) {
            Write-Log "Refusing protected system root: $full" 'WARN'
            return $false
        }
    }
    # The path must NAME the vendor. This is what stops a mis-assembled residual
    # list from ever pointing at somebody else's folder.
    if ($full -notmatch '(?i)\\Fortinet($|\\)' -and $full -notmatch '(?i)\\FortiClient($|\\|\.lnk$)') {
        Write-Log "Refusing path that does not name Fortinet: $full" 'WARN'
        return $false
    }
    return $true
}

# Driver .sys files live in System32\drivers, which carries no Fortinet path
# segment, so they cannot go through Test-SafeResidualPath. Their guard is the
# stronger one available: the file's own version resource must say Fortinet at
# the moment of deletion.
function Remove-FortinetDriverFile {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return 0 }
    if (-not (Test-Path -LiteralPath $Path)) { return 0 }

    if (-not (Test-FortinetBinary $Path)) {
        Write-Log "Refusing to delete $Path : its version resource does not identify Fortinet." 'WARN'
        return 0
    }
    if (-not $PSCmdlet.ShouldProcess($Path, 'Remove driver file')) { return 0 }

    try {
        Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
        Write-Log "    removed $Path"
        return 1
    }
    catch {
        # Expected before a reboot: the driver is still loaded in kernel memory.
        # This is a retry-later, not a failure - treating it as fatal here would
        # abort the run after the service registrations are already gone.
        Write-Log "    still locked (needs reboot): $Path" 'WARN'
        return 0
    }
}

function Remove-ResidualFiles {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([string[]]$Paths)

    $removed = 0
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
            $removed++
        }
        catch {
            Write-Log "    could not remove $path : $($_.Exception.Message)" 'WARN'
        }
    }
    return $removed
}

# --- Residual registry cleanup --------------------------------------------
function Remove-ResidualRegistryKeys {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()

    $removed = 0
    $keys = @('HKLM:\SOFTWARE\Fortinet', 'HKLM:\SOFTWARE\WOW6432Node\Fortinet', 'HKCU:\SOFTWARE\Fortinet')

    # Every LOADED user hive. Unloaded profiles are deliberately left alone:
    # 'reg load' without a guaranteed unload can corrupt or permanently lock a
    # profile, and the leftovers are inert configuration.
    $hku = @()
    try { $hku = @(Get-ChildItem -Path 'Registry::HKEY_USERS' -ErrorAction SilentlyContinue) } catch { }
    foreach ($sid in $hku) {
        if ($sid.PSChildName -match '_Classes$') { continue }
        $candidate = "Registry::HKEY_USERS\$($sid.PSChildName)\SOFTWARE\Fortinet"
        if (Test-Path $candidate) { $keys += $candidate }
    }

    foreach ($k in @($keys | Select-Object -Unique)) {
        if (-not (Test-Path $k)) { continue }

        # Shape guard: only ever a key literally named Fortinet, never a parent.
        if ($k -notmatch '(?i)\\Fortinet$') {
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
            Remove-Item -Path $k -Recurse -Force -ErrorAction Stop
            Write-Log "    removed $k"
            $removed++
        }
        catch {
            Write-Log "    could not remove $k : $($_.Exception.Message)" 'WARN'
        }
    }
    return $removed
}

if ($failures -gt 0) {
    if ($RemoveResidualFiles -or $RemoveResidualRegistry) {
        Write-Log 'Skipping residual cleanup because the uninstall did not complete. Re-run after it succeeds.' 'WARN'
    }
}
elseif ($skipped -gt 0) {
    if ($RemoveResidualFiles -or $RemoveResidualRegistry) {
        Write-Log "Skipping residual cleanup because $skipped product(s) were declined and are still installed. Deleting their files would leave a registered product with no files." 'WARN'
    }
}
else {
    if ($RemoveResidualFiles) {
        Write-Log 'Scanning for Fortinet residual locations...'
        $null = Remove-ResidualFiles -Paths $ResidualPaths

        # Now, and only now, the vendor parent - and only if it came out empty.
        # Empty is the sole safe condition: anything still inside it belongs to a
        # different Fortinet product that was never in scope.
        foreach ($r in @($FortinetRoots | Where-Object { $_ -match '(?i)\\Fortinet$' })) {
            if ((Test-Path -LiteralPath $r) -and
                -not (Get-ChildItem -LiteralPath $r -Force -ErrorAction SilentlyContinue)) {
                $null = Remove-ResidualFiles -Paths @($r)
            }
        }

        # A driver FILE may only be deleted once NO service key still resolves to
        # it. Deleting a .sys out from under a live registration is the reverse of
        # the order enforced above, and for a SYSTEM_START filter it is a
        # boot-time driver load failure. That single test covers -RemoveDrivers
        # being off, every declined prompt, and an sc.exe delete that failed or
        # only marked the key for deletion pending reboot.
        if (-not $RemoveDrivers) {
            Write-Log 'Skipping the driver-file sweep: -RemoveDrivers:$false leaves the driver service keys registered, so their .sys files must stay on disk.' 'WARN'
        }
        else {
            $stillRegistered = @(Get-FortinetServices -Roots $FortinetRoots |
                Where-Object { $_.IsDriver -and $_.BinaryFound } |
                ForEach-Object { Get-ComparablePath $_.BinaryPath })

            $stillHeld = 0
            $driverDir = Join-Path $env:SystemRoot 'System32\drivers'
            if (Test-Path -LiteralPath $driverDir) {
                Get-ChildItem -Path $driverDir -Filter '*.sys' -File -ErrorAction SilentlyContinue |
                    Where-Object { Test-FortinetBinary $_.FullName } | ForEach-Object {
                        if (-not $IncludeLegacyPppop -and $_.Name -match '(?i)^pppop') { return }
                        if ($stillRegistered -contains (Get-ComparablePath $_.FullName)) {
                            Write-Log "Keeping $($_.FullName): a driver service is still registered against it. Reboot and re-run to finish." 'WARN'
                            if (-not $WhatIfPreference) { $stillHeld++ }
                            return
                        }
                        if ((Remove-FortinetDriverFile -Path $_.FullName) -eq 0 -and (Test-Path -LiteralPath $_.FullName)) {
                            # A 0 under -WhatIf means ShouldProcess PREVIEWED the
                            # delete, not that the kernel is holding the file. A
                            # preview must not manufacture a reboot requirement
                            # or a 3010 exit code.
                            if (-not $WhatIfPreference) { $stillHeld++ }
                        }
                    }
            }
            $pendingFiles = $stillHeld
            if ($stillHeld -gt 0) { $rebootNeeded = $true }
        }
    }

    if ($RemoveResidualRegistry) {
        Write-Log 'Removing Fortinet configuration hives...'
        $null = Remove-ResidualRegistryKeys
    }
}

# --- Summary --------------------------------------------------------------
Write-Log '---------------------------------------------'
if ($failures -eq 0) {
    if ($skipped -gt 0) {
        Write-Log "Completed with $skipped item(s) declined and still installed." 'WARN'
    }
    else {
        Write-Log 'Completed. No Winsock or WFP reset was issued, and the Credential Providers key was not touched.' 'OK'
    }
    if ($pendingFiles -gt 0) {
        Write-Log "$pendingFiles Fortinet driver file(s) are still loaded in the kernel and could not be deleted. Reboot, then re-run this script to finish the sweep." 'WARN'
    }
    if ($rebootNeeded) { Write-Log 'A reboot is REQUIRED to finalize removal and rebind the network stack.' 'WARN' }
}
else {
    Write-Log "Completed with $failures failure(s). Review the log: $LogPath" 'ERROR'
}
Write-Log "Log saved to: $LogPath"

try { Stop-Transcript | Out-Null } catch { }

if ($failures -gt 0) { exit 3 }
elseif ($rebootNeeded) { exit 3010 }
else { exit 0 }
