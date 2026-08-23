<#
.SYNOPSIS
    Removes the bloat from a Windows 10/11 installation - pre-installed apps,
    telemetry, tips and ads, the AI features, Bing in search, Widgets - as a
    census-first, backup-first, revertible run.

.DESCRIPTION
    Windows ships with a layer of things that exist for Microsoft's benefit
    rather than yours: diagnostic data collection, "suggested" apps that install
    themselves, ads in Settings and on the lock screen, Bing and Copilot wired
    into the search box, Recall, Widgets, and forty-odd Store apps you never
    asked for. This script takes that layer off, in the same shape as the other
    scripts in this repository:

      * A CENSUS first. Every tweak in the catalogue is read back from the
        registry and reported as APPLIED, PENDING (with the values that would
        change) or N/A (wrong Windows build), and every app on the removal list
        is reported as installed or absent. -ListOnly stops there, and needs
        no elevation.
      * A BACKUP before any change. Every registry value this run is about to
        write is captured first - whether it existed, its type, its data - to
        a JSON file whose path is printed. -Restore <file> puts every value
        back exactly as it was, including deleting the ones that did not exist.
        Apps are not restored by -Restore; they come back from the Store.
      * Evidence-gated. A tweak that is already applied is skipped, a tweak
        whose Windows build is out of range is skipped, an app that is not
        installed is skipped. The run says so in each case.
      * Logged, previewable with -WhatIf, exit-coded.

    The catalogue is DATA, not code: one entry per tweak, each a list of
    registry operations plus an optional post-step (disable the telemetry
    scheduled tasks, remove the Copilot or Widgets packages). The registry
    values were cross-referenced against the Regfiles shipped with
    Raphire/Win11Debloat (MIT), which is the most widely used tool of this kind
    and whose defaults are the basis of the Recommended set here.

    POLICIES. A handful of tweaks have no per-user setting and can only be
    applied as a local machine or user POLICY (keys under ...\Policies\...).
    Those are the ones that make Windows and Edge show "Some settings are
    managed by your organization". Every such tweak is tagged POLICY in the
    census so you know which ones they are before you apply them, and
    -Restore removes them again.

    WHAT IS NOT HERE, ON PURPOSE:

      * Microsoft Edge is never removed. Removing it also removes the only
        browser in Windows Sandbox, breaks apps that embed WebView2 through
        it, and comes back on the next cumulative update anyway.
      * The Microsoft Store and the Xbox identity/TCUI/speech components are
        never removed: the Store cannot be reinstalled in any supported way,
        and the Xbox components are dependencies of games and of the Store.
      * Windows Terminal is never removed (it may be the window you are in).
      * OneDrive is removed only with -IncludeOneDrive; its uninstaller leaves
        the user's files in place but the sync relationship is gone.
      * No Start-menu layout replacement, no Sysprep/default-profile mode, no
        other-user mode. This script changes the machine (HKLM) and the user
        who ran it (HKCU), and says so.

.PARAMETER ListOnly
    Census only: report the state of every tweak and the presence of every
    listed app, change nothing. Needs no elevation.

.PARAMETER Tweak
    Apply exactly these tweak IDs (comma-separated or an array), instead of the
    Recommended set. IDs are the names shown in the census, e.g.
    DisableTelemetry, DisableCopilot, ShowKnownFileExt.

.PARAMETER SkipTweak
    Tweak IDs to leave out of whatever selection is in force.

.PARAMETER Group
    Add every tweak in these groups to the selection, whether Recommended or
    not: Privacy, AI, Search, Taskbar, Explorer, System, Gaming, Update,
    Appearance.

.PARAMETER RemoveApps
    Remove the apps on the list. Default $true; the default list is the
    Recommended app selection (the discontinued Bing apps, Clipchamp, Cortana,
    Dev Home, Feedback Hub, the games, the third-party sponsored apps and so
    on - the census prints it). Set $false to apply tweaks only.

.PARAMETER Apps
    Remove exactly these Appx package names instead of the default list. A
    name on the protected list (Store, Edge, Terminal, Xbox identity/TCUI,
    speech-to-text) is refused even here.

.PARAMETER KeepApps
    Names to leave installed, whatever list is in force.

.PARAMETER IncludeGamingApps
    Also remove the Xbox app and the two Game Bar overlay packages. Off by
    default because some PC games need them to launch.

.PARAMETER IncludeOneDrive
    Also uninstall the OneDrive client (via winget). Off by default.

.PARAMETER CreateRestorePoint
    Create a System Restore point before changing anything. Skipped when one
    was created in the last 24 hours (Windows refuses anyway).

.PARAMETER NoExplorerRestart
    Do not restart Explorer at the end. Most taskbar and Explorer tweaks are
    not visible until Explorer restarts or you sign out.

.PARAMETER Restore
    Path of a backup JSON written by an earlier run. Every value in it is put
    back exactly as captured, and nothing else is done.

.PARAMETER Force
    Non-interactive: skip the confirmation prompt. -Force does NOT suppress
    PowerShell's own ShouldProcess confirmation; add -Confirm:$false for a
    genuinely unattended run (see the README note on -File vs -Command).

.PARAMETER LogPath
    Transcript path. Defaults to a timestamped file under %TEMP%.

.PARAMETER BackupPath
    Directory for the registry backup JSON. Defaults to
    %ProgramData%\ADesk_Cleaner.

.PARAMETER TargetSid
    Internal. The SID of the user whose HKCU is being changed. Set
    automatically before self-elevation and relayed across the UAC boundary,
    so that elevating through a different administrator account still changes
    the invoking user's settings, not the administrator's.

.EXAMPLE
    .\Remove-WindowsBloat.ps1 -ListOnly

    The recommended first run: what would change, and what is already done.

.EXAMPLE
    .\Remove-WindowsBloat.ps1

    The Recommended set: tweaks and apps, after a confirmation prompt.

.EXAMPLE
    .\Remove-WindowsBloat.ps1 -Group Privacy,AI -RemoveApps:$false

    Every privacy and AI tweak, no app removal. (-RemoveApps:$false needs the
    -Command form; see the README.)

.EXAMPLE
    .\Remove-WindowsBloat.ps1 -Tweak DisableTelemetry,DisableBing -Force -Confirm:$false

    Two tweaks, unattended.

.EXAMPLE
    .\Remove-WindowsBloat.ps1 -Restore "C:\ProgramData\ADesk_Cleaner\WindowsBloat-backup_20260823_091500.json"

    Put every registry value from that run back the way it was.

.NOTES
    Exit codes (shared with the other scripts in this repository):

      0   Success (including "declined at the prompt")
      3   Partial failure - one or more values or apps could not be changed
      2   Nothing to do - every selected tweak is already applied and no
          selected app is installed
      1   Aborted (elevation cancelled, invalid -LogPath, -Restore file
          missing, unknown tweak or group name)

    Sign out and back in after a run; Explorer is restarted for you but the
    Settings app and the Start menu read several of these values at sign-in.
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [switch]$ListOnly,
    [string[]]$Tweak,
    [string[]]$SkipTweak,
    [string[]]$Group,
    [bool]$RemoveApps = $true,
    [string[]]$Apps,
    [string[]]$KeepApps,
    [switch]$IncludeGamingApps,
    [switch]$IncludeOneDrive,
    [switch]$CreateRestorePoint,
    [switch]$NoExplorerRestart,
    [string]$Restore,
    [switch]$Force,
    [string]$LogPath,
    [string]$BackupPath,
    [string]$TargetSid
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ($Force) { $ConfirmPreference = 'None' }

# Lists may arrive as a real array (PowerShell prompt) or as ONE "a,b,c" string
# (powershell.exe -File, and therefore the .cmd launcher). Normalise both.
function ConvertTo-List {
    param($Value)
    if ($null -eq $Value) { return @() }
    return @($Value | ForEach-Object { [string]$_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}
# @() at the call site: a function that returns an empty array returns
# nothing, and under StrictMode a later .Count on that $null throws.
$Tweak     = @(ConvertTo-List $Tweak)
$SkipTweak = @(ConvertTo-List $SkipTweak)
$Group     = @(ConvertTo-List $Group)
$Apps      = @(ConvertTo-List $Apps)
$KeepApps  = @(ConvertTo-List $KeepApps)

# Resolve -LogPath to a ROOTED path before elevation: the elevated child's
# working directory is not the operator's.
if ([string]::IsNullOrWhiteSpace($LogPath)) {
    $LogPath = Join-Path $env:TEMP ("Remove-WindowsBloat_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))
}
else {
    try { $LogPath = [IO.Path]::GetFullPath([IO.Path]::Combine((Get-Location).ProviderPath, $LogPath)) }
    catch {
        Write-Host "Invalid -LogPath '$LogPath': $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
}
if ([string]::IsNullOrWhiteSpace($BackupPath)) {
    $BackupPath = Join-Path $env:ProgramData 'ADesk_Cleaner'
}
else {
    try { $BackupPath = [IO.Path]::GetFullPath([IO.Path]::Combine((Get-Location).ProviderPath, $BackupPath)) }
    catch {
        Write-Host "Invalid -BackupPath '$BackupPath': $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
}
if (-not [string]::IsNullOrWhiteSpace($Restore)) {
    try { $Restore = [IO.Path]::GetFullPath([IO.Path]::Combine((Get-Location).ProviderPath, $Restore)) }
    catch {
        Write-Host "Invalid -Restore path '$Restore': $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
    if (-not (Test-Path -LiteralPath $Restore)) {
        Write-Host "Restore file not found: $Restore" -ForegroundColor Red
        exit 1
    }
}

# The user whose HKCU we change. Captured BEFORE elevation, because after a UAC
# prompt answered with a different administrator account, HKCU is that
# administrator's hive and the invoking user's settings would be untouched.
$currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
if ([string]::IsNullOrWhiteSpace($TargetSid)) { $TargetSid = $currentSid }

# --- Self-elevation -------------------------------------------------------

function Test-IsAdministrator {
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not $ListOnly -and -not (Test-IsAdministrator)) {
    Write-Host 'Elevation required. Relaunching as Administrator...' -ForegroundColor Yellow

    if ([string]::IsNullOrWhiteSpace($PSCommandPath)) {
        Write-Host 'Cannot self-elevate: script path is unknown. Run it with -File, or start an elevated PowerShell first.' -ForegroundColor Red
        exit 1
    }

    # Relay through -Command as ONE string. -File cannot bind [bool]; the
    # list parameters are re-joined with commas and single-quoted.
    $q = { param($s) "'" + ([string]$s -replace "'", "''") + "'" }
    $passArgs = @()
    if ($Tweak.Count     -gt 0) { $passArgs += ('-Tweak {0}'     -f (& $q ($Tweak -join ','))) }
    if ($SkipTweak.Count -gt 0) { $passArgs += ('-SkipTweak {0}' -f (& $q ($SkipTweak -join ','))) }
    if ($Group.Count     -gt 0) { $passArgs += ('-Group {0}'     -f (& $q ($Group -join ','))) }
    if ($Apps.Count      -gt 0) { $passArgs += ('-Apps {0}'      -f (& $q ($Apps -join ','))) }
    if ($KeepApps.Count  -gt 0) { $passArgs += ('-KeepApps {0}'  -f (& $q ($KeepApps -join ','))) }
    $passArgs += ('-RemoveApps:${0}' -f $RemoveApps)
    if ($IncludeGamingApps)  { $passArgs += '-IncludeGamingApps' }
    if ($IncludeOneDrive)    { $passArgs += '-IncludeOneDrive' }
    if ($CreateRestorePoint) { $passArgs += '-CreateRestorePoint' }
    if ($NoExplorerRestart)  { $passArgs += '-NoExplorerRestart' }
    if ($Force)              { $passArgs += '-Force' }
    if (-not [string]::IsNullOrWhiteSpace($Restore)) { $passArgs += ('-Restore {0}' -f (& $q $Restore)) }
    $passArgs += ('-LogPath {0}'    -f (& $q $LogPath))
    $passArgs += ('-BackupPath {0}' -f (& $q $BackupPath))
    $passArgs += ('-TargetSid {0}'  -f (& $q $TargetSid))

    # COMMON parameters live OUTSIDE param() and must be relayed explicitly.
    if ($WhatIfPreference) { $passArgs += '-WhatIf' }
    if ($PSBoundParameters.ContainsKey('Confirm')) {
        $passArgs += ('-Confirm:${0}' -f [bool]$PSBoundParameters['Confirm'])
    }
    if ($VerbosePreference -eq 'Continue') { $passArgs += '-Verbose' }

    $qPath = $PSCommandPath -replace "'", "''"
    $inner = "& '{0}' {1}; exit `$LASTEXITCODE" -f $qPath, ($passArgs -join ' ')

    # FAIL CLOSED: a preview flag that does not cross the UAC boundary turns a
    # preview into a real run. Verify it is in the bytes about to be launched.
    if ($WhatIfPreference -and $inner -notmatch '(?i)(?<=\s)-WhatIf(?=\s|;|")') {
        Write-Host 'Refusing to elevate: -WhatIf was requested but is not present in the elevated command line.' -ForegroundColor Red
        exit 1
    }

    $psExe = (Get-Process -Id $PID).Path
    if ([string]::IsNullOrWhiteSpace($psExe)) { $psExe = 'powershell.exe' }
    try {
        $p = Start-Process -FilePath $psExe `
                           -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $inner) `
                           -Verb RunAs -Wait -PassThru
        $code = 0
        if ($p -and $null -ne $p.ExitCode) { $code = $p.ExitCode }
        exit $code
    }
    catch {
        Write-Host "Elevation was cancelled or failed: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
}

# --- Logging --------------------------------------------------------------

try {
    $logDir = Split-Path -Parent $LogPath
    if ($logDir -and -not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    # Start-Transcript is ShouldProcess-aware; under -WhatIf it would preview
    # instead of opening the log. The transcript is this script's own output.
    Start-Transcript -Path $LogPath -Append -WhatIf:$false | Out-Null
    $script:TranscriptStarted = $true
}
catch {
    Write-Host "Could not start transcript at '$LogPath': $($_.Exception.Message)" -ForegroundColor Yellow
    $script:TranscriptStarted = $false
}

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $color = switch ($Level) {
        'OK'     { 'Green' }
        'WARN'   { 'Yellow' }
        'ERROR'  { 'Red' }
        'POLICY' { 'Magenta' }
        'HEAD'   { 'Cyan' }
        default  { 'Gray' }
    }
    Write-Host ("[{0:HH:mm:ss}] {1,-6} {2}" -f (Get-Date), $Level, $Message) -ForegroundColor $color
}

function Write-Section {
    param([string]$Title)
    Write-Log ''
    Write-Log ('=' * 72) 'HEAD'
    Write-Log $Title 'HEAD'
    Write-Log ('=' * 72) 'HEAD'
}

function Stop-Run {
    param([int]$Code)
    if ($script:TranscriptStarted) { try { Stop-Transcript | Out-Null } catch { } }
    exit $Code
}

# --- Environment ----------------------------------------------------------

# Read the build from the registry rather than [Environment]::OSVersion, which
# Windows PowerShell reports through a compatibility shim on some hosts.
$script:Build = 0
try {
    $cv = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
    $script:Build = [int]$cv.CurrentBuildNumber
}
catch { }

# HKCU ops are written to the TARGET user's hive, which is HKCU only when the
# elevated process runs as that same user.
$script:SameUser = ($currentSid -eq $TargetSid)

function Resolve-RegPath {
    param([string]$Hive, [string]$Key)
    switch ($Hive) {
        'HKLM'  { return "HKLM:\$Key" }
        'HKCR'  { return "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Classes\$Key" }
        'HKU20' { return "Registry::HKEY_USERS\S-1-5-20\$Key" }
        'HKCU'  {
            if ($script:SameUser) { return "HKCU:\$Key" }
            # Another account answered UAC: address the invoking user's hive by
            # SID. Per-user Classes live in the separate <SID>_Classes hive.
            if ($Key -match '^(?i)Software\\Classes\\(.+)$') {
                return "Registry::HKEY_USERS\${TargetSid}_Classes\$($Matches[1])"
            }
            return "Registry::HKEY_USERS\$TargetSid\$Key"
        }
    }
    throw "Unknown hive '$Hive'"
}

# --- Registry primitives --------------------------------------------------

# The value name '' is the key's (Default) value.
function Get-RegValueState {
    param([string]$Path, [string]$Name)
    $state = [pscustomobject]@{ KeyExists = $false; Exists = $false; Kind = ''; Value = $null }
    $key = $null
    try { $key = Get-Item -LiteralPath $Path -ErrorAction Stop } catch { return $state }
    if ($null -eq $key) { return $state }
    $state.KeyExists = $true
    try {
        $names = @($key.GetValueNames())
        if ($names -contains $Name) {
            $state.Exists = $true
            $state.Kind   = [string]$key.GetValueKind($Name)
            $state.Value  = $key.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        }
    }
    catch { }
    finally { if ($key) { $key.Close() } }
    return $state
}

function Test-RegValueEquals {
    param($State, [string]$Kind, $Value)
    if (-not $State.Exists) { return $false }
    # A value of the wrong TYPE (a String where a DWord is expected) is "not
    # equal", never an exception: the cast below throws on it.
    try {
        switch ($Kind) {
            'DWord'        { return ([int64]$State.Value -eq [int64]$Value) }
            'String'       { return ([string]$State.Value -eq [string]$Value) }
            'ExpandString' { return ([string]$State.Value -eq [string]$Value) }
            'Binary'       {
                $a = @([byte[]]$State.Value); $b = @([byte[]]$Value)
                if ($a.Count -ne $b.Count) { return $false }
                for ($i = 0; $i -lt $a.Count; $i++) { if ($a[$i] -ne $b[$i]) { return $false } }
                return $true
            }
        }
    }
    catch { return $false }
    return $false
}

function Set-RegValue {
    param([string]$Path, [string]$Name, [string]$Kind, $Value)
    if (-not (Test-Path -LiteralPath $Path)) { New-Item -Path $Path -Force -ErrorAction Stop | Out-Null }
    $propName = if ($Name -eq '') { '(default)' } else { $Name }
    New-ItemProperty -LiteralPath $Path -Name $propName -Value $Value -PropertyType $Kind -Force -ErrorAction Stop | Out-Null
}

function Remove-RegValue {
    param([string]$Path, [string]$Name)
    $propName = if ($Name -eq '') { '(default)' } else { $Name }
    Remove-ItemProperty -LiteralPath $Path -Name $propName -Force -ErrorAction Stop
}

# --- The catalogue --------------------------------------------------------

function New-Op {
    param(
        [string]$Hive, [string]$Key, [string]$Name = '', [string]$Kind = 'DWord', $Value = $null,
        [switch]$Delete, [switch]$DeleteKey
    )
    [pscustomobject]@{
        Hive = $Hive; Key = $Key; Name = $Name; Kind = $Kind; Value = $Value
        Delete = [bool]$Delete; DeleteKey = [bool]$DeleteKey
    }
}

function New-Tweak {
    param(
        [string]$Id, [string]$Group, [string]$Title, [switch]$Default, [switch]$Policy,
        [int]$MinBuild = 0, [int]$MaxBuild = 0, [object[]]$Ops = @(), [string]$Post = '',
        [string]$RequireKey = '', [string]$Note = ''
    )
    [pscustomobject]@{
        Id = $Id; Group = $Group; Title = $Title; Default = [bool]$Default; Policy = [bool]$Policy
        MinBuild = $MinBuild; MaxBuild = $MaxBuild; Ops = @($Ops); Post = $Post
        RequireKey = $RequireKey; Note = $Note
    }
}

$CDM = 'Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
$ADV = 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
$EDGEPOL = 'SOFTWARE\Policies\Microsoft\Edge'

$Catalogue = @(
    # ---- Privacy -----------------------------------------------------------
    (New-Tweak -Id 'DisableTelemetry' -Group 'Privacy' -Default -Policy `
        -Title 'Disable telemetry, diagnostic data, activity history, app-launch tracking and targeted ads' `
        -Post 'TelemetryTasks' -Ops @(
        (New-Op HKCU 'Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo' 'Enabled' 'DWord' 0),
        (New-Op HKCU 'Software\Microsoft\Windows\CurrentVersion\Privacy' 'TailoredExperiencesWithDiagnosticDataEnabled' 'DWord' 0),
        (New-Op HKCU 'Software\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy' 'HasAccepted' 'DWord' 0),
        (New-Op HKCU 'Software\Microsoft\Input\TIPC' 'Enabled' 'DWord' 0),
        (New-Op HKCU 'Software\Microsoft\InputPersonalization' 'RestrictImplicitInkCollection' 'DWord' 1),
        (New-Op HKCU 'Software\Microsoft\InputPersonalization' 'RestrictImplicitTextCollection' 'DWord' 1),
        (New-Op HKCU 'Software\Microsoft\InputPersonalization\TrainedDataStore' 'HarvestContacts' 'DWord' 0),
        (New-Op HKCU 'Software\Microsoft\Personalization\Settings' 'AcceptedPrivacyPolicy' 'DWord' 0),
        (New-Op HKLM 'SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection' 'AllowTelemetry' 'DWord' 0),
        (New-Op HKCU $ADV 'Start_TrackProgs' 'DWord' 0),
        (New-Op HKLM 'SOFTWARE\Policies\Microsoft\Windows\System' 'PublishUserActivities' 'DWord' 0),
        (New-Op HKCU 'SOFTWARE\Microsoft\Siuf\Rules' 'NumberOfSIUFInPeriod' 'DWord' 0),
        (New-Op HKCU 'SOFTWARE\Microsoft\Siuf\Rules' 'PeriodInNanoSeconds' -Delete),
        (New-Op HKLM $EDGEPOL 'PersonalizationReportingEnabled' 'DWord' 0),
        (New-Op HKLM $EDGEPOL 'DiagnosticData' 'DWord' 0)
    )),
    (New-Tweak -Id 'DisableSuggestions' -Group 'Privacy' -Default `
        -Title 'Disable tips, tricks, suggested content, suggested-app auto-install and sync-provider ads' -Ops @(
        (New-Op HKCU $CDM 'SubscribedContent-310093Enabled' 'DWord' 0),
        (New-Op HKCU $CDM 'SubscribedContent-338388Enabled' 'DWord' 0),
        (New-Op HKCU $CDM 'SystemPaneSuggestionsEnabled' 'DWord' 0),
        (New-Op HKCU $ADV 'Start_IrisRecommendations' 'DWord' 0),
        (New-Op HKCU $CDM 'SubscribedContent-338389Enabled' 'DWord' 0),
        (New-Op HKCU $CDM 'SoftLandingEnabled' 'DWord' 0),
        (New-Op HKCU $CDM 'SubscribedContent-338393Enabled' 'DWord' 0),
        (New-Op HKCU $CDM 'SubscribedContent-353694Enabled' 'DWord' 0),
        (New-Op HKCU $CDM 'SubscribedContent-353696Enabled' 'DWord' 0),
        (New-Op HKCU $CDM 'SubscribedContent-353698Enabled' 'DWord' 0),
        (New-Op HKCU 'Software\Microsoft\Windows\CurrentVersion\SystemSettings\AccountNotifications' 'EnableAccountNotifications' 'DWord' 0),
        (New-Op HKCU 'SOFTWARE\Microsoft\Windows\CurrentVersion\UserProfileEngagement' 'ScoobeSystemSettingEnabled' 'DWord' 0),
        (New-Op HKCU $ADV 'ShowSyncProviderNotifications' 'DWord' 0),
        (New-Op HKCU $CDM 'SilentInstalledAppsEnabled' 'DWord' 0),
        (New-Op HKCU 'Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\Windows.SystemToast.Suggested' 'Enabled' 'DWord' 0),
        (New-Op HKCU 'Software\Microsoft\Windows\CurrentVersion\Mobility' 'OptedIn' 'DWord' 0),
        (New-Op HKCU $ADV 'Start_AccountNotifications' 'DWord' 0),
        (New-Op HKCU 'SOFTWARE\Microsoft\Windows\CurrentVersion\Notifications\Settings\Windows.SystemToast.BackupReminder' 'Enabled' 'DWord' 0)
    )),
    (New-Tweak -Id 'DisableEdgeAds' -Group 'Privacy' -Default -Policy `
        -Title 'Disable ads, recommendations, the MSN feed and the shopping assistant in Microsoft Edge' -Ops @(
        (New-Op HKLM $EDGEPOL 'NewTabPageContentEnabled' 'DWord' 0),
        (New-Op HKLM $EDGEPOL 'NewTabPageHideDefaultTopSites' 'DWord' 1),
        (New-Op HKLM $EDGEPOL 'EdgeShoppingAssistantEnabled' 'DWord' 0),
        (New-Op HKLM $EDGEPOL 'TabServicesEnabled' 'DWord' 0),
        (New-Op HKLM $EDGEPOL 'AlternateErrorPagesEnabled' 'DWord' 0),
        (New-Op HKLM $EDGEPOL 'UserFeedbackAllowed' 'DWord' 0),
        (New-Op HKLM $EDGEPOL 'ShowRecommendationsEnabled' 'DWord' 0),
        (New-Op HKLM $EDGEPOL 'WalletDonationEnabled' 'DWord' 0),
        (New-Op HKLM $EDGEPOL 'HideFirstRunExperience' 'DWord' 0),
        (New-Op HKLM $EDGEPOL 'DefaultBrowserSettingEnabled' 'DWord' 0),
        (New-Op HKLM $EDGEPOL 'DefaultBrowserSettingsCampaignEnabled' 'DWord' 0),
        (New-Op HKLM $EDGEPOL 'SpotlightExperiencesAndRecommendationsEnabled' 'DWord' 0),
        (New-Op HKLM $EDGEPOL 'ShowAcrobatSubscriptionButton' 'DWord' 0)
    )),
    (New-Tweak -Id 'DisableSettings365Ads' -Group 'Privacy' -Policy -MinBuild 22000 `
        -Title 'Hide the Microsoft 365 ads on the Settings Home page' -Ops @(
        (New-Op HKLM 'SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableConsumerAccountStateContent' 'DWord' 1)
    )),
    (New-Tweak -Id 'DisableLockscreenTips' -Group 'Privacy' `
        -Title 'Disable tips, tricks and fun facts on the lock screen' -Ops @(
        (New-Op HKCU $CDM 'SubscribedContent-338387Enabled' 'DWord' 0),
        (New-Op HKCU $CDM 'RotatingLockScreenOverlayEnabled' 'DWord' 0)
    )),
    (New-Tweak -Id 'DisableDesktopSpotlight' -Group 'Privacy' -Policy `
        -Title 'Disable Windows Spotlight for the desktop background' -Ops @(
        (New-Op HKCU 'Software\Policies\Microsoft\Windows\CloudContent' 'DisableSpotlightCollectionOnDesktop' 'DWord' 1),
        (New-Op HKCU 'Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\NewStartPanel' '{2cc5ca98-6485-489a-920e-b3e88a6ccce3}' -Delete)
    )),
    (New-Tweak -Id 'DisableLocationServices' -Group 'Privacy' -Policy `
        -Title 'Turn off Location Services and deny apps your location' -Ops @(
        (New-Op HKLM 'SOFTWARE\Policies\Microsoft\Windows\LocationAndSensors' 'DisableLocation' 'DWord' 1)
    )),
    (New-Tweak -Id 'DisableFindMyDevice' -Group 'Privacy' -Policy `
        -Title 'Turn off Find My Device location reporting' -Ops @(
        (New-Op HKLM 'SOFTWARE\Policies\Microsoft\FindMyDevice' 'AllowFindMyDevice' 'DWord' 0)
    )),

    # ---- AI ----------------------------------------------------------------
    (New-Tweak -Id 'DisableCopilot' -Group 'AI' -Default -Policy -MinBuild 22621 `
        -Title 'Disable and remove Microsoft Copilot' -Post 'CopilotApps' -Ops @(
        (New-Op HKCU $ADV 'ShowCopilotButton' 'DWord' 0),
        (New-Op HKCU 'Software\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' 'DWord' 1),
        (New-Op HKLM 'SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' 'DWord' 1)
    )),
    (New-Tweak -Id 'DisableRecall' -Group 'AI' -Default -Policy -MinBuild 22621 `
        -Title 'Disable Windows Recall snapshots' -Ops @(
        (New-Op HKCU 'Software\Policies\Microsoft\Windows\WindowsAI' 'DisableAIDataAnalysis' 'DWord' 1),
        (New-Op HKLM 'SOFTWARE\Policies\Microsoft\Windows\WindowsAI' 'DisableAIDataAnalysis' 'DWord' 1),
        (New-Op HKLM 'SOFTWARE\Policies\Microsoft\Windows\WindowsAI' 'AllowRecallEnablement' 'DWord' 0),
        (New-Op HKLM 'SOFTWARE\Policies\Microsoft\Windows\WindowsAI' 'TurnOffSavingSnapshots' 'DWord' 1)
    )),
    (New-Tweak -Id 'DisableClickToDo' -Group 'AI' -Default -Policy -MinBuild 22621 `
        -Title 'Disable Click To Do (AI text and image analysis)' -Ops @(
        (New-Op HKCU 'Software\Policies\Microsoft\Windows\WindowsAI' 'DisableClickToDo' 'DWord' 1),
        (New-Op HKLM 'SOFTWARE\Policies\Microsoft\Windows\WindowsAI' 'DisableClickToDo' 'DWord' 1)
    )),
    (New-Tweak -Id 'DisableAISvcAutoStart' -Group 'AI' -Default -MinBuild 22621 `
        -Title 'Set the Windows AI Fabric service (WSAIFabricSvc) to manual start' `
        -RequireKey 'HKLM:\SYSTEM\CurrentControlSet\Services\WSAIFabricSvc' -Ops @(
        (New-Op HKLM 'SYSTEM\CurrentControlSet\Services\WSAIFabricSvc' 'Start' 'DWord' 3)
    )),
    (New-Tweak -Id 'DisableEdgeAI' -Group 'AI' -Policy -MinBuild 22621 `
        -Title 'Disable Copilot and the AI features in Microsoft Edge' -Ops @(
        (New-Op HKLM $EDGEPOL 'CopilotCDPPageContext' 'DWord' 0),
        (New-Op HKLM $EDGEPOL 'CopilotPageContext' 'DWord' 0),
        (New-Op HKLM $EDGEPOL 'HubsSidebarEnabled' 'DWord' 0),
        (New-Op HKLM $EDGEPOL 'EdgeEntraCopilotPageContext' 'DWord' 0),
        (New-Op HKLM $EDGEPOL 'EdgeHistoryAISearchEnabled' 'DWord' 0),
        (New-Op HKLM $EDGEPOL 'ComposeInlineEnabled' 'DWord' 0),
        (New-Op HKLM $EDGEPOL 'GenAILocalFoundationalModelSettings' 'DWord' 1),
        (New-Op HKLM $EDGEPOL 'NewTabPageBingChatEnabled' 'DWord' 0)
    )),
    (New-Tweak -Id 'DisablePaintAI' -Group 'AI' -Policy -MinBuild 22621 `
        -Title 'Disable the AI features in Paint' -Ops @(
        (New-Op HKLM 'SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Paint' 'DisableCocreator' 'DWord' 1),
        (New-Op HKLM 'SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Paint' 'DisableGenerativeFill' 'DWord' 1),
        (New-Op HKLM 'SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Paint' 'DisableImageCreator' 'DWord' 1),
        (New-Op HKLM 'SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Paint' 'DisableGenerativeErase' 'DWord' 1),
        (New-Op HKLM 'SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Paint' 'DisableRemoveBackground' 'DWord' 1)
    )),
    (New-Tweak -Id 'DisableNotepadAI' -Group 'AI' -Policy -MinBuild 22621 `
        -Title 'Disable the AI features in Notepad' -Ops @(
        (New-Op HKLM 'SOFTWARE\Policies\WindowsNotepad' 'DisableAIFeatures' 'DWord' 1)
    )),

    # ---- Search ------------------------------------------------------------
    (New-Tweak -Id 'DisableBing' -Group 'Search' -Default -Policy `
        -Title 'Disable Bing web results, Bing AI and Cortana in Windows search' -Post 'BingApp' -Ops @(
        (New-Op HKCU 'Software\Policies\Microsoft\Windows\Explorer' 'DisableSearchBoxSuggestions' 'DWord' 1),
        (New-Op HKLM 'SOFTWARE\Policies\Microsoft\Windows\Windows Search' 'AllowCortana' 'DWord' 0),
        (New-Op HKLM 'SOFTWARE\Policies\Microsoft\Windows\Windows Search' 'CortanaConsent' 'DWord' 0)
    )),
    (New-Tweak -Id 'DisableSearchHighlights' -Group 'Search' -MinBuild 22000 `
        -Title 'Disable Search Highlights (branded and trending content in the search box)' -Ops @(
        (New-Op HKCU 'Software\Microsoft\Windows\CurrentVersion\SearchSettings' 'IsDynamicSearchBoxEnabled' 'DWord' 0)
    )),
    (New-Tweak -Id 'DisableSearchHistory' -Group 'Search' `
        -Title 'Disable local search history' -Ops @(
        (New-Op HKCU 'Software\Microsoft\Windows\CurrentVersion\SearchSettings' 'IsDeviceSearchHistoryEnabled' 'DWord' 0)
    )),

    # ---- Taskbar and Start ---------------------------------------------------
    (New-Tweak -Id 'DisableWidgets' -Group 'Taskbar' -Default -MinBuild 22000 `
        -Title 'Disable Widgets on the taskbar and lock screen (removes the three Widgets packages)' -Post 'WidgetsApps'),
    (New-Tweak -Id 'HideChat' -Group 'Taskbar' -Default -MaxBuild 22621 `
        -Title 'Hide the Chat / Meet Now icon on the taskbar' -Ops @(
        (New-Op HKCU $ADV 'TaskbarMn' 'DWord' 0),
        (New-Op HKCU 'Software\Microsoft\Windows\CurrentVersion\Policies\Explorer' 'HideSCAMeetNow' 'DWord' 1)
    )),
    (New-Tweak -Id 'DisableStartRecommended' -Group 'Taskbar' -Policy -MinBuild 22621 `
        -Title 'Hide the Recommended section in the Start menu' -Ops @(
        (New-Op HKCU 'SOFTWARE\Policies\Microsoft\Windows\Explorer' 'HideRecommendedSection' 'DWord' 1)
    )),
    (New-Tweak -Id 'DisableStartPhoneLink' -Group 'Taskbar' -MinBuild 22621 `
        -Title 'Hide the Phone Link panel in the Start menu' -Ops @(
        (New-Op HKCU 'Software\Microsoft\Windows\CurrentVersion\Start\Companions\Microsoft.YourPhone_8wekyb3d8bbwe' 'IsEnabled' 'DWord' 0)
    )),
    (New-Tweak -Id 'TaskbarAlignLeft' -Group 'Taskbar' -MinBuild 22000 `
        -Title 'Align the taskbar to the left' -Ops @((New-Op HKCU $ADV 'TaskbarAl' 'DWord' 0))),
    (New-Tweak -Id 'HideTaskview' -Group 'Taskbar' -MinBuild 22000 `
        -Title 'Hide the Task View button' -Ops @((New-Op HKCU $ADV 'ShowTaskViewButton' 'DWord' 0))),
    (New-Tweak -Id 'HideSearchTb' -Group 'Taskbar' -MinBuild 22000 `
        -Title 'Hide the search box from the taskbar' -Ops @(
        (New-Op HKCU 'Software\Microsoft\Windows\CurrentVersion\Search' 'SearchboxTaskbarMode' 'DWord' 0)
    )),
    (New-Tweak -Id 'ShowSearchIconTb' -Group 'Taskbar' -MinBuild 22000 `
        -Title 'Show only the search icon on the taskbar' -Ops @(
        (New-Op HKCU 'Software\Microsoft\Windows\CurrentVersion\Search' 'SearchboxTaskbarMode' 'DWord' 1)
    )),
    (New-Tweak -Id 'EnableEndTask' -Group 'Taskbar' -MinBuild 22631 `
        -Title 'Add End Task to the taskbar right-click menu' -Ops @(
        (New-Op HKCU "$ADV\TaskbarDeveloperSettings" 'TaskbarEndTask' 'DWord' 1)
    )),

    # ---- Explorer ----------------------------------------------------------
    (New-Tweak -Id 'ShowKnownFileExt' -Group 'Explorer' -Default `
        -Title 'Show file extensions for known file types' -Ops @((New-Op HKCU $ADV 'HideFileExt' 'DWord' 0))),
    (New-Tweak -Id 'Hide3dObjects' -Group 'Explorer' -Default -MaxBuild 21999 `
        -Title 'Hide the 3D Objects folder under This PC' -Ops @(
        (New-Op HKLM 'SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\MyComputer\NameSpace\{0DB7E03F-FC29-4DC6-9020-FF41B59E513A}' -DeleteKey),
        (New-Op HKLM 'SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Explorer\MyComputer\NameSpace\{0DB7E03F-FC29-4DC6-9020-FF41B59E513A}' -DeleteKey)
    )),
    (New-Tweak -Id 'ShowHiddenFolders' -Group 'Explorer' `
        -Title 'Show hidden files, folders and drives' -Ops @((New-Op HKCU $ADV 'Hidden' 'DWord' 1))),
    (New-Tweak -Id 'ExplorerToThisPC' -Group 'Explorer' `
        -Title 'Open File Explorer to This PC' -Ops @((New-Op HKCU $ADV 'LaunchTo' 'DWord' 1))),
    (New-Tweak -Id 'HideHome' -Group 'Explorer' -MinBuild 22000 `
        -Title 'Hide Home from the Explorer navigation pane (adds a Show Home toggle to Folder Options)' -Ops @(
        (New-Op HKCU 'Software\Classes\CLSID\{f874310e-b6b7-47dc-bc84-b9e6b38f5903}' '' 'String' 'CLSID_MSGraphHomeFolder'),
        (New-Op HKCU 'Software\Classes\CLSID\{f874310e-b6b7-47dc-bc84-b9e6b38f5903}' 'System.IsPinnedToNameSpaceTree' 'DWord' 0),
        (New-Op HKLM 'SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced\NavPane\ShowHome' 'CheckedValue' 'DWord' 1),
        (New-Op HKLM 'SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced\NavPane\ShowHome' 'DefaultValue' 'DWord' 0),
        (New-Op HKLM 'SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced\NavPane\ShowHome' 'HKeyRoot' 'DWord' 0x80000001),
        (New-Op HKLM 'SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced\NavPane\ShowHome' 'Id' 'DWord' 13),
        (New-Op HKLM 'SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced\NavPane\ShowHome' 'RegPath' 'String' 'Software\Classes\CLSID\{f874310e-b6b7-47dc-bc84-b9e6b38f5903}'),
        (New-Op HKLM 'SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced\NavPane\ShowHome' 'Text' 'String' 'Show Home'),
        (New-Op HKLM 'SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced\NavPane\ShowHome' 'Type' 'String' 'checkbox'),
        (New-Op HKLM 'SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced\NavPane\ShowHome' 'UncheckedValue' 'DWord' 0),
        (New-Op HKLM 'SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced\NavPane\ShowHome' 'ValueName' 'String' 'System.IsPinnedToNameSpaceTree')
    )),
    (New-Tweak -Id 'HideGallery' -Group 'Explorer' -MinBuild 22000 `
        -Title 'Hide Gallery from the Explorer navigation pane (adds a Show Gallery toggle to Folder Options)' -Ops @(
        (New-Op HKCU 'Software\Classes\CLSID\{e88865ea-0e1c-4e20-9aa6-edcd0212c87c}' 'System.IsPinnedToNameSpaceTree' 'DWord' 0),
        (New-Op HKLM 'SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced\NavPane\ShowGallery' 'CheckedValue' 'DWord' 1),
        (New-Op HKLM 'SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced\NavPane\ShowGallery' 'DefaultValue' 'DWord' 0),
        (New-Op HKLM 'SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced\NavPane\ShowGallery' 'HKeyRoot' 'DWord' 0x80000001),
        (New-Op HKLM 'SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced\NavPane\ShowGallery' 'Id' 'DWord' 13),
        (New-Op HKLM 'SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced\NavPane\ShowGallery' 'RegPath' 'String' 'Software\Classes\CLSID\{e88865ea-0e1c-4e20-9aa6-edcd0212c87c}'),
        (New-Op HKLM 'SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced\NavPane\ShowGallery' 'Text' 'String' 'Show Gallery'),
        (New-Op HKLM 'SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced\NavPane\ShowGallery' 'Type' 'String' 'checkbox'),
        (New-Op HKLM 'SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced\NavPane\ShowGallery' 'UncheckedValue' 'DWord' 0),
        (New-Op HKLM 'SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced\NavPane\ShowGallery' 'ValueName' 'String' 'System.IsPinnedToNameSpaceTree')
    )),
    (New-Tweak -Id 'RevertContextMenu' -Group 'Explorer' -MinBuild 22000 `
        -Title 'Use the classic Windows 10 right-click menu' -Ops @(
        (New-Op HKCU 'Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32' '' 'String' '')
    )),

    # ---- System ------------------------------------------------------------
    (New-Tweak -Id 'DisableDragTray' -Group 'System' -Default -MinBuild 26200 `
        -Title 'Disable the Drag Tray that appears when dragging files' -Ops @(
        (New-Op HKCU 'Software\Microsoft\Windows\CurrentVersion\CDP' 'DragTrayEnabled' 'DWord' 0)
    )),
    (New-Tweak -Id 'DisableMouseAcceleration' -Group 'System' `
        -Title 'Disable Enhance Pointer Precision (mouse acceleration); takes effect after sign-in' -Ops @(
        (New-Op HKCU 'Control Panel\Mouse' 'MouseSpeed' 'String' '0'),
        (New-Op HKCU 'Control Panel\Mouse' 'MouseThreshold1' 'String' '0'),
        (New-Op HKCU 'Control Panel\Mouse' 'MouseThreshold2' 'String' '0')
    )),
    (New-Tweak -Id 'DisableStickyKeys' -Group 'System' -MinBuild 26100 `
        -Title 'Disable the Sticky Keys shortcut (Shift five times)' -Ops @(
        (New-Op HKCU 'Control Panel\Accessibility\StickyKeys' 'Flags' 'String' '506')
    )),
    (New-Tweak -Id 'DisableFastStartup' -Group 'System' `
        -Title 'Disable Fast Startup (full shutdown every time)' -Ops @(
        (New-Op HKLM 'SYSTEM\CurrentControlSet\Control\Session Manager\Power' 'HiberbootEnabled' 'DWord' 0)
    )),
    (New-Tweak -Id 'DisableStorageSense' -Group 'System' -MinBuild 22000 `
        -Title 'Disable Storage Sense automatic cleanup' -Ops @(
        (New-Op HKCU 'SOFTWARE\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy' '01' 'DWord' 0)
    )),
    (New-Tweak -Id 'DisableModernStandbyNetworking' -Group 'System' -Policy -MinBuild 22000 `
        -Title 'Disconnect from the network during Modern Standby (laptops)' -Ops @(
        (New-Op HKLM 'SOFTWARE\Policies\Microsoft\Power\PowerSettings\f15576e8-98b7-4186-b944-eafa664402d9' 'ACSettingIndex' 'DWord' 0),
        (New-Op HKLM 'SOFTWARE\Policies\Microsoft\Power\PowerSettings\f15576e8-98b7-4186-b944-eafa664402d9' 'DCSettingIndex' 'DWord' 0)
    )),
    (New-Tweak -Id 'DisableSettingsHome' -Group 'System' -Policy -MinBuild 22000 `
        -Title 'Hide the Settings Home page (Settings opens to System)' -Ops @(
        (New-Op HKLM 'SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer' 'SettingsPageVisibility' 'String' 'hide:home')
    )),
    (New-Tweak -Id 'DisableNotifications' -Group 'System' `
        -Title 'Disable all toast notifications from apps and other senders' -Ops @(
        (New-Op HKCU 'Software\Microsoft\Windows\CurrentVersion\PushNotifications' 'ToastEnabled' 'DWord' 0)
    )),

    # ---- Gaming ------------------------------------------------------------
    (New-Tweak -Id 'DisableDVR' -Group 'Gaming' -Policy `
        -Title 'Disable Xbox game/screen recording (Game DVR)' -Ops @(
        (New-Op HKCU 'System\GameConfigStore' 'GameDVR_Enabled' 'DWord' 0),
        (New-Op HKCU 'SOFTWARE\Microsoft\Windows\CurrentVersion\GameDVR' 'AppCaptureEnabled' 'DWord' 0),
        (New-Op HKLM 'SOFTWARE\Policies\Microsoft\Windows\GameDVR' 'AllowGameDVR' 'DWord' 0)
    )),
    (New-Tweak -Id 'DisableGameBarIntegration' -Group 'Gaming' `
        -Title 'Disable Game Bar integration and the ms-gamebar pop-ups' -Ops @(
        (New-Op HKCU 'SOFTWARE\Microsoft\GameBar' 'UseNexusForGameBarEnabled' 'DWord' 0),
        (New-Op HKCR 'ms-gamebar' '' 'String' 'URL:ms-gamebar'),
        (New-Op HKCR 'ms-gamebar' 'URL Protocol' 'String' ''),
        (New-Op HKCR 'ms-gamebar' 'NoOpenWith' 'String' ''),
        (New-Op HKCR 'ms-gamebar\shell\open\command' '' 'String' '%SystemRoot%/System32/systray.exe'),
        (New-Op HKCR 'ms-gamebarservices' '' 'String' 'URL:ms-gamebarservices'),
        (New-Op HKCR 'ms-gamebarservices' 'URL Protocol' 'String' ''),
        (New-Op HKCR 'ms-gamebarservices' 'NoOpenWith' 'String' ''),
        (New-Op HKCR 'ms-gamebarservices\shell\open\command' '' 'String' '%SystemRoot%/System32/systray.exe')
    )),

    # ---- Windows Update ------------------------------------------------------
    (New-Tweak -Id 'DisableUpdateASAP' -Group 'Update' `
        -Title 'Turn off "Get the latest updates as soon as they are available"' -Ops @(
        (New-Op HKLM 'SOFTWARE\Microsoft\WindowsUpdate\UX\Settings' 'IsContinuousInnovationOptedIn' 'DWord' 0)
    )),
    (New-Tweak -Id 'PreventUpdateAutoReboot' -Group 'Update' -Policy `
        -Title 'Prevent automatic restarts after updates while a user is signed in' -Ops @(
        (New-Op HKLM 'SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' 'NoAutoRebootWithLoggedOnUsers' 'DWord' 1)
    )),
    (New-Tweak -Id 'DisableDeliveryOptimization' -Group 'Update' `
        -Title 'Stop sharing downloaded updates with other PCs (Delivery Optimization)' -Ops @(
        (New-Op HKU20 'Software\Microsoft\Windows\CurrentVersion\DeliveryOptimization\Settings' 'DownloadMode' 'DWord' 0)
    )),
    (New-Tweak -Id 'DisableDeviceAutoAppDownload' -Group 'Update' -Policy `
        -Title 'Stop Windows Update silently installing device companion apps' -Ops @(
        (New-Op HKLM 'SOFTWARE\Policies\Microsoft\Windows\Device Metadata' 'PreventDeviceMetadataFromNetwork' 'DWord' 1)
    )),

    # ---- Appearance --------------------------------------------------------
    (New-Tweak -Id 'EnableDarkMode' -Group 'Appearance' `
        -Title 'Dark mode for system and apps' -Ops @(
        (New-Op HKCU 'SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'AppsUseLightTheme' 'DWord' 0),
        (New-Op HKCU 'SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'SystemUsesLightTheme' 'DWord' 0)
    )),
    (New-Tweak -Id 'DisableTransparency' -Group 'Appearance' `
        -Title 'Disable transparency effects' -Ops @(
        (New-Op HKCU 'Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'EnableTransparency' 'DWord' 0)
    )),
    (New-Tweak -Id 'DisableAnimations' -Group 'Appearance' `
        -Title 'Disable animations and visual effects' -Ops @(
        (New-Op HKCU 'Control Panel\Desktop' 'UserPreferencesMask' 'Binary' ([byte[]](0x90, 0x12, 0x07, 0x80, 0x10, 0x00, 0x00, 0x00)))
    ))
)

$ValidGroups = @($Catalogue | ForEach-Object { $_.Group } | Select-Object -Unique)

# Telemetry scheduled tasks: the Customer Experience Improvement Program and the
# compatibility appraiser. Disabled (not deleted) so -Restore-free reversal is
# a matter of Enable-ScheduledTask.
$TelemetryTasks = @(
    @{ Path = '\Microsoft\Windows\Application Experience\';                 Name = 'Microsoft Compatibility Appraiser' },
    @{ Path = '\Microsoft\Windows\Application Experience\';                 Name = 'Microsoft Compatibility Appraiser Exp' },
    @{ Path = '\Microsoft\Windows\Application Experience\';                 Name = 'ProgramDataUpdater' },
    @{ Path = '\Microsoft\Windows\Application Experience\';                 Name = 'StartupAppTask' },
    @{ Path = '\Microsoft\Windows\Customer Experience Improvement Program\'; Name = 'Consolidator' },
    @{ Path = '\Microsoft\Windows\Customer Experience Improvement Program\'; Name = 'UsbCeip' },
    @{ Path = '\Microsoft\Windows\DiskDiagnostic\';                         Name = 'Microsoft-Windows-DiskDiagnosticDataCollector' },
    @{ Path = '\Microsoft\Windows\Autochk\';                                Name = 'Proxy' }
)

# --- The app list ---------------------------------------------------------
#
# Package family NAMES (the part before the version), matched as *name*. The
# Recommended list is Win11Debloat's default selection: discontinued and
# superseded Microsoft apps, the Bing apps, Copilot, the sponsored third-party
# apps and games that OEM images and Windows itself pre-install.
$RecommendedApps = @(
    # Microsoft
    @{ Id = 'Microsoft.3DBuilder';                       Name = '3D Builder' },
    @{ Id = 'Microsoft.Microsoft3DViewer';               Name = '3D Viewer' },
    @{ Id = 'Microsoft.WindowsAlarms';                   Name = 'Alarms & Clock' },
    @{ Id = 'Microsoft.BingFinance';                     Name = 'Bing Finance' },
    @{ Id = 'Microsoft.BingFoodAndDrink';                Name = 'Bing Food And Drink' },
    @{ Id = 'Microsoft.BingHealthAndFitness';            Name = 'Bing Health And Fitness' },
    @{ Id = 'Microsoft.BingNews';                        Name = 'Bing News' },
    @{ Id = 'Microsoft.BingSports';                      Name = 'Bing Sports' },
    @{ Id = 'Microsoft.BingTranslator';                  Name = 'Bing Translator' },
    @{ Id = 'Microsoft.BingTravel';                      Name = 'Bing Travel' },
    @{ Id = 'Microsoft.BingWeather';                     Name = 'Bing Weather' },
    @{ Id = 'Clipchamp.Clipchamp';                       Name = 'Clipchamp' },
    @{ Id = 'Microsoft.Windows.AIHub';                   Name = 'Copilot+ AI Hub' },
    @{ Id = 'Microsoft.549981C3F5F10';                   Name = 'Cortana' },
    @{ Id = 'Microsoft.Windows.DevHome';                 Name = 'Dev Home' },
    @{ Id = 'MicrosoftCorporationII.MicrosoftFamily';    Name = 'Family Safety' },
    @{ Id = 'Microsoft.WindowsFeedbackHub';              Name = 'Feedback Hub' },
    @{ Id = 'Microsoft.Getstarted';                      Name = 'Get Started' },
    @{ Id = 'Microsoft.Messaging';                       Name = 'Messaging' },
    @{ Id = 'Microsoft.MicrosoftJournal';                Name = 'Microsoft Journal' },
    @{ Id = 'Microsoft.News';                            Name = 'Microsoft News' },
    @{ Id = 'Microsoft.PCManager';                       Name = 'Microsoft PC Manager' },
    @{ Id = 'MSTeams';                                   Name = 'Microsoft Teams (New)' },
    @{ Id = 'MicrosoftTeams';                            Name = 'Microsoft Teams (Old)' },
    @{ Id = 'Microsoft.Todos';                           Name = 'Microsoft To Do' },
    @{ Id = 'Microsoft.MixedReality.Portal';             Name = 'Mixed Reality Portal' },
    @{ Id = 'Microsoft.ZuneVideo';                       Name = 'Movies & TV' },
    @{ Id = 'Microsoft.NetworkSpeedTest';                Name = 'Network Speed Test' },
    @{ Id = 'Microsoft.MicrosoftOfficeHub';              Name = 'Office Hub' },
    @{ Id = 'Microsoft.OneConnect';                      Name = 'One Connect' },
    @{ Id = 'Microsoft.Office.OneNote';                  Name = 'OneNote (UWP)' },
    @{ Id = 'Microsoft.PowerAutomateDesktop';            Name = 'Power Automate' },
    @{ Id = 'Microsoft.MicrosoftPowerBIForWindows';      Name = 'Power BI' },
    @{ Id = 'Microsoft.Print3D';                         Name = 'Print 3D' },
    @{ Id = 'MicrosoftCorporationII.QuickAssist';        Name = 'Quick Assist' },
    @{ Id = 'Microsoft.SkypeApp';                        Name = 'Skype (UWP)' },
    @{ Id = 'Microsoft.MicrosoftSolitaireCollection';    Name = 'Solitaire Collection' },
    @{ Id = 'Microsoft.WindowsSoundRecorder';            Name = 'Sound Recorder' },
    @{ Id = 'Microsoft.MicrosoftStickyNotes';            Name = 'Sticky Notes' },
    @{ Id = 'Microsoft.Office.Sway';                     Name = 'Sway' },
    @{ Id = 'Microsoft.WindowsMaps';                     Name = 'Windows Maps' },
    @{ Id = 'Microsoft.XboxApp';                         Name = 'Xbox Console Companion' },
    # Third-party sponsored apps and games
    @{ Id = 'ACGMediaPlayer';                            Name = 'ACG Media Player' },
    @{ Id = 'ActiproSoftwareLLC';                        Name = 'Actipro Software' },
    @{ Id = 'AdobeSystemsIncorporated.AdobePhotoshopExpress'; Name = 'Adobe Photoshop Express' },
    @{ Id = 'Amazon.com.Amazon';                         Name = 'Amazon' },
    @{ Id = 'Asphalt8Airborne';                          Name = 'Asphalt 8' },
    @{ Id = 'AutodeskSketchBook';                        Name = 'Autodesk SketchBook' },
    @{ Id = 'king.com.BubbleWitch3Saga';                 Name = 'Bubble Witch 3' },
    @{ Id = 'CaesarsSlotsFreeCasino';                    Name = 'Caesars Slots' },
    @{ Id = 'king.com.CandyCrushSaga';                   Name = 'Candy Crush Saga' },
    @{ Id = 'king.com.CandyCrushSodaSaga';               Name = 'Candy Crush Soda' },
    @{ Id = 'COOKINGFEVER';                              Name = 'Cooking Fever' },
    @{ Id = 'CyberLinkMediaSuiteEssentials';             Name = 'CyberLink Media Suite' },
    @{ Id = 'DisneyMagicKingdoms';                       Name = 'Disney Magic Kingdoms' },
    @{ Id = 'Disney.37853FC22B2CE';                      Name = 'Disney+' },
    @{ Id = 'DrawboardPDF';                              Name = 'Drawboard PDF' },
    @{ Id = 'Duolingo-LearnLanguagesforFree';            Name = 'Duolingo' },
    @{ Id = 'EclipseManager';                            Name = 'Eclipse Manager' },
    @{ Id = 'FACEBOOK.FACEBOOK';                         Name = 'Facebook' },
    @{ Id = 'FarmVille2CountryEscape';                   Name = 'FarmVille 2' },
    @{ Id = 'Flipboard';                                 Name = 'Flipboard' },
    @{ Id = 'HiddenCity';                                Name = 'Hidden City' },
    @{ Id = 'HULULLC.HULUPLUS';                          Name = 'Hulu' },
    @{ Id = 'iHeartRadio';                               Name = 'iHeartRadio' },
    @{ Id = 'Facebook.Instagram';                        Name = 'Instagram' },
    @{ Id = 'LinkedInforWindows';                        Name = 'LinkedIn' },
    @{ Id = 'Sidia.LiveWallpaper';                       Name = 'Live Wallpaper' },
    @{ Id = 'MarchofEmpires';                            Name = 'March of Empires' },
    @{ Id = 'Microsoft.Copilot';                         Name = 'Microsoft Copilot (Store app)' },
    @{ Id = '4DF9E0F8.Netflix';                          Name = 'Netflix' },
    @{ Id = 'NYTCrossword';                              Name = 'NYT Crossword' },
    @{ Id = 'OneCalendar';                               Name = 'One Calendar' },
    @{ Id = 'PandoraMediaInc';                           Name = 'Pandora' },
    @{ Id = 'PhototasticCollage';                        Name = 'Phototastic Collage' },
    @{ Id = 'PicsArt-PhotoStudio';                       Name = 'PicsArt' },
    @{ Id = 'PolarrPhotoEditorAcademicEdition';          Name = 'Polarr Photo Editor' },
    @{ Id = 'AmazonVideo.PrimeVideo';                    Name = 'Prime Video' },
    @{ Id = 'flaregamesGmbH.RoyalRevolt';                Name = 'Royal Revolt' },
    @{ Id = 'SlingTV';                                   Name = 'Sling TV' },
    @{ Id = 'SpotifyAB.SpotifyMusic';                    Name = 'Spotify' },
    @{ Id = 'BytedancePte.Ltd.TikTok';                   Name = 'TikTok' },
    @{ Id = 'TuneInRadio';                               Name = 'TuneIn Radio' },
    @{ Id = 'WinZipUniversal';                           Name = 'WinZip' }
)

$GamingApps = @(
    @{ Id = 'Microsoft.GamingApp';         Name = 'Xbox app' },
    @{ Id = 'Microsoft.XboxGameOverlay';   Name = 'Xbox Game Overlay' },
    @{ Id = 'Microsoft.XboxGamingOverlay'; Name = 'Xbox Gaming Overlay (Game Bar)' }
)

# Removed through winget rather than Appx: the Store-distributed Copilot and
# the OneDrive client register there, not as removable Appx packages.
$WingetApps = @{
    'XP9CXNGPPJ97XX'     = 'Microsoft Copilot'
    'Microsoft.OneDrive' = 'OneDrive'
}

# Never removed, whatever list is in force.
$ProtectedApps = @(
    'Microsoft.WindowsStore', 'Microsoft.StorePurchaseApp', 'Microsoft.XboxSpeechToTextOverlay',
    'Microsoft.Xbox.TCUI', 'Microsoft.XboxIdentityProvider', 'Microsoft.Edge', 'XPFFTQ037JWMHS',
    'Microsoft.WindowsTerminal', 'Microsoft.DesktopAppInstaller', 'Microsoft.VCLibs', 'Microsoft.NET',
    'Microsoft.UI.Xaml', 'Microsoft.WindowsAppRuntime', 'Microsoft.SecHealthUI', 'Microsoft.Windows.ShellExperienceHost',
    'Microsoft.Windows.StartMenuExperienceHost', 'Microsoft.Windows.Search', 'Microsoft.AAD.BrokerPlugin',
    'Microsoft.AccountsControl', 'Microsoft.LockApp', 'Microsoft.Win32WebViewHost', 'MicrosoftWindows.Client'
)

# --- Tweak state ----------------------------------------------------------

function Get-TweakApplicability {
    param($T)
    if ($T.MinBuild -gt 0 -and $script:Build -gt 0 -and $script:Build -lt $T.MinBuild) { return "needs build $($T.MinBuild)+" }
    if ($T.MaxBuild -gt 0 -and $script:Build -gt 0 -and $script:Build -gt $T.MaxBuild) { return "Windows 10 only (build <= $($T.MaxBuild))" }
    if ($T.RequireKey -and -not (Test-Path -LiteralPath $T.RequireKey)) { return "key absent: $($T.RequireKey)" }
    return ''
}

# Returns @{ Applied = bool; Pending = @(op descriptions) }
function Get-TweakState {
    param($T)
    $pending = @()
    foreach ($op in $T.Ops) {
        $path = Resolve-RegPath $op.Hive $op.Key
        if ($op.DeleteKey) {
            if (Test-Path -LiteralPath $path) { $pending += "delete key $path" }
            continue
        }
        $st = Get-RegValueState -Path $path -Name $op.Name
        $label = if ($op.Name -eq '') { '(default)' } else { $op.Name }
        if ($op.Delete) {
            if ($st.Exists) { $pending += "delete $path\$label" }
            continue
        }
        if (-not (Test-RegValueEquals -State $st -Kind $op.Kind -Value $op.Value)) {
            $was = if ($st.Exists) { "$($st.Kind)=$(ConvertTo-Display $st.Value)" } else { 'absent' }
            $pending += ("{0}\{1}: {2} -> {3}={4}" -f $path, $label, $was, $op.Kind, (ConvertTo-Display $op.Value))
        }
    }
    switch ($T.Post) {
        'WidgetsApps' { foreach ($a in (Get-InstalledMatches -Ids @('Microsoft.StartExperiencesApp', 'MicrosoftWindows.Client.WebExperience', 'Microsoft.WidgetsPlatformRuntime'))) { $pending += "remove package $a" } }
        'CopilotApps' { foreach ($a in (Get-InstalledMatches -Ids @('Microsoft.Copilot'))) { $pending += "remove package $a" } }
        'BingApp'     { foreach ($a in (Get-InstalledMatches -Ids @('Microsoft.BingSearch'))) { $pending += "remove package $a" } }
    }
    return @{ Applied = ($pending.Count -eq 0); Pending = $pending }
}

function ConvertTo-Display {
    param($Value)
    if ($null -eq $Value) { return 'null' }
    if ($Value -is [byte[]]) { return (($Value | ForEach-Object { '{0:x2}' -f $_ }) -join ',') }
    return [string]$Value
}

# --- Apps -----------------------------------------------------------------

$script:AppxCache = $null
$script:ProvCache = $null
$script:AppxAllUsers = $false

function Get-AppxInventory {
    if ($null -ne $script:AppxCache) { return }
    $script:AppxCache = @()
    try {
        $script:AppxCache = @(Get-AppxPackage -AllUsers -ErrorAction Stop)
        $script:AppxAllUsers = $true
    }
    catch {
        # -AllUsers needs elevation; in an unelevated -ListOnly fall back to
        # the current user and say so.
        try { $script:AppxCache = @(Get-AppxPackage -ErrorAction Stop) } catch { }
        $script:AppxAllUsers = $false
    }
    $script:ProvCache = @()
    try { $script:ProvCache = @(Get-AppxProvisionedPackage -Online -ErrorAction Stop) } catch { }
}

# Installed package names (any user) or provisioned names that match an ID.
function Get-InstalledMatches {
    param([string[]]$Ids)
    Get-AppxInventory
    $out = @()
    foreach ($id in $Ids) {
        foreach ($p in $script:AppxCache) {
            if ($p.Name -like "*$id*" -and $out -notcontains $p.Name) { $out += $p.Name }
        }
        foreach ($p in $script:ProvCache) {
            $n = [string]$p.DisplayName
            if ($n -like "*$id*" -and $out -notcontains $n) { $out += $n }
        }
    }
    return $out
}

function Test-WingetInstalled {
    param([string]$Id)
    $w = Get-Command winget -ErrorAction SilentlyContinue
    if (-not $w) { return $false }
    try {
        $r = & winget list --id $Id --exact --accept-source-agreements --disable-interactivity 2>$null
        return ([string]($r -join "`n") -match [regex]::Escape($Id))
    }
    catch { return $false }
}

function Remove-AppById {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param([string]$Id, [string]$Display)
    Get-AppxInventory
    $ok = $true
    $matched = @($script:AppxCache | Where-Object { $_.Name -like "*$Id*" })
    foreach ($p in $matched) {
        if ($PSCmdlet.ShouldProcess($p.PackageFullName, 'Remove Appx package')) {
            try {
                if ($script:AppxAllUsers) { Remove-AppxPackage -Package $p.PackageFullName -AllUsers -ErrorAction Stop }
                else                      { Remove-AppxPackage -Package $p.PackageFullName -ErrorAction Stop }
                Write-Log "    removed $($p.PackageFullName)" 'OK'
            }
            catch {
                Write-Log "    FAILED $($p.PackageFullName): $($_.Exception.Message)" 'ERROR'
                $ok = $false
            }
        }
    }
    $prov = @($script:ProvCache | Where-Object { [string]$_.DisplayName -like "*$Id*" })
    foreach ($p in $prov) {
        if ($PSCmdlet.ShouldProcess($p.PackageName, 'Remove provisioned package')) {
            try {
                $provArgs = @{ Online = $true; PackageName = $p.PackageName; ErrorAction = 'Stop' }
                if ((Get-Command Remove-AppxProvisionedPackage).Parameters.ContainsKey('AllUsers')) { $provArgs.AllUsers = $true }
                Remove-AppxProvisionedPackage @provArgs | Out-Null
                Write-Log "    de-provisioned $($p.PackageName)" 'OK'
            }
            catch {
                Write-Log "    FAILED to de-provision $($p.PackageName): $($_.Exception.Message)" 'ERROR'
                $ok = $false
            }
        }
    }
    if ($matched.Count -eq 0 -and $prov.Count -eq 0) { Write-Log "    $Display ($Id): not installed." }
    return $ok
}

function Remove-WingetApp {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param([string]$Id, [string]$Display)
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Log "    $Display ($Id): winget is not available; skipped." 'WARN'
        return $true
    }
    if (-not (Test-WingetInstalled $Id)) { Write-Log "    $Display ($Id): not installed."; return $true }
    if ($PSCmdlet.ShouldProcess("$Display ($Id)", 'winget uninstall')) {
        & winget uninstall --id $Id --exact --accept-source-agreements --disable-interactivity --silent 2>&1 | Out-Null
        if (Test-WingetInstalled $Id) {
            Write-Log "    FAILED: $Display is still installed after winget uninstall." 'ERROR'
            return $false
        }
        Write-Log "    removed $Display via winget" 'OK'
    }
    return $true
}

# --- Backup and restore ---------------------------------------------------

$script:Backup = @()

function Add-BackupEntry {
    param($Op, [string]$Path)
    if ($Op.DeleteKey) {
        $exists = Test-Path -LiteralPath $Path
        $def = $null
        if ($exists) { try { $def = (Get-Item -LiteralPath $Path).GetValue('') } catch { } }
        $script:Backup += [pscustomobject]@{ Path = $Path; Name = ''; IsKey = $true; KeyExisted = $exists; Existed = $exists; Kind = 'String'; Value = $def }
        return
    }
    $st = Get-RegValueState -Path $Path -Name $Op.Name
    $val = $st.Value
    if ($st.Exists -and $st.Kind -eq 'Binary') { $val = @([byte[]]$st.Value | ForEach-Object { [int]$_ }) }
    $script:Backup += [pscustomobject]@{
        Path = $Path; Name = $Op.Name; IsKey = $false; KeyExisted = $st.KeyExists; Existed = $st.Exists; Kind = $st.Kind; Value = $val
    }
}

function Save-Backup {
    if ($script:Backup.Count -eq 0) { return $null }
    if (-not (Test-Path -LiteralPath $BackupPath)) { New-Item -ItemType Directory -Path $BackupPath -Force | Out-Null }
    $file = Join-Path $BackupPath ("WindowsBloat-backup_{0:yyyyMMdd_HHmmss}.json" -f (Get-Date))
    $doc = [pscustomobject]@{
        Created   = (Get-Date).ToString('o')
        Machine   = $env:COMPUTERNAME
        TargetSid = $TargetSid
        Build     = $script:Build
        Entries   = $script:Backup
    }
    $doc | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $file -Encoding UTF8
    return $file
}

function Restore-FromBackup {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param([string]$File)
    $doc = Get-Content -LiteralPath $File -Raw | ConvertFrom-Json
    $entries = @($doc.Entries)
    Write-Log ("Restoring {0} value(s) captured {1} on {2}" -f $entries.Count, $doc.Created, $doc.Machine)
    $failed = 0
    foreach ($e in $entries) {
        $label = if ($e.IsKey) { $e.Path } else { "$($e.Path)\$(if ($e.Name -eq '') { '(default)' } else { $e.Name })" }
        if (-not $PSCmdlet.ShouldProcess($label, 'Restore')) { continue }
        try {
            if ($e.IsKey) {
                if ($e.KeyExisted) {
                    if (-not (Test-Path -LiteralPath $e.Path)) { New-Item -Path $e.Path -Force | Out-Null }
                    if ($null -ne $e.Value) { Set-RegValue -Path $e.Path -Name '' -Kind 'String' -Value $e.Value }
                    Write-Log "  recreated key $($e.Path)" 'OK'
                }
                elseif (Test-Path -LiteralPath $e.Path) {
                    Remove-Item -LiteralPath $e.Path -Recurse -Force
                    Write-Log "  removed key $($e.Path)" 'OK'
                }
                continue
            }
            if ($e.Existed) {
                $val = $e.Value
                if ($e.Kind -eq 'Binary') { $val = [byte[]]@($e.Value | ForEach-Object { [byte]$_ }) }
                if ($e.Kind -eq 'DWord')  { $val = [int64]$e.Value }
                Set-RegValue -Path $e.Path -Name $e.Name -Kind $e.Kind -Value $val
                Write-Log "  restored $label = $(ConvertTo-Display $e.Value)" 'OK'
            }
            else {
                $st = Get-RegValueState -Path $e.Path -Name $e.Name
                if ($st.Exists) {
                    Remove-RegValue -Path $e.Path -Name $e.Name
                    Write-Log "  removed $label (did not exist before)" 'OK'
                }
                else { Write-Log "  $label already absent." }
                # A key this run created for the value is left behind if it is
                # now empty; an empty key has no effect and deleting it on the
                # strength of a backup entry alone is not worth the risk.
            }
        }
        catch {
            Write-Log "  FAILED ${label}: $($_.Exception.Message)" 'ERROR'
            $failed++
        }
    }
    return $failed
}

# ==========================================================================
#  RESTORE MODE
# ==========================================================================

if (-not [string]::IsNullOrWhiteSpace($Restore)) {
    Write-Section 'RESTORE'
    Write-Log "Backup file: $Restore"
    $failed = Restore-FromBackup -File $Restore
    Write-Section 'SUMMARY'
    if ($WhatIfPreference) { Write-Log 'Preview run: nothing was changed.' 'OK'; Stop-Run 0 }
    if ($failed -gt 0) { Write-Log "Restore completed with $failed failure(s)." 'WARN'; Stop-Run 3 }
    Write-Log 'Restore complete. Sign out and back in for every value to take effect.' 'OK'
    Stop-Run 0
}

# ==========================================================================
#  SELECTION
# ==========================================================================

if ($WhatIfPreference) { Write-Log '*** PREVIEW (-WhatIf): nothing will be changed. ***' 'WARN' }
if ($ListOnly)         { Write-Log '*** LIST ONLY: census only, nothing will be changed. ***' 'WARN' }
Write-Log "Windows bloat removal started. Log: $LogPath"
Write-Log ("Windows build {0}; target user SID {1}{2}" -f $script:Build, $TargetSid, $(if ($script:SameUser) { '' } else { ' (different from the elevated account; HKCU is addressed by SID)' }))

foreach ($id in ($Tweak + $SkipTweak)) {
    if (-not ($Catalogue | Where-Object { $_.Id -ieq $id })) {
        Write-Log ("Unknown tweak '{0}'. Known IDs: {1}" -f $id, (($Catalogue | ForEach-Object { $_.Id }) -join ', ')) 'ERROR'
        Stop-Run 1
    }
}
foreach ($g in $Group) {
    if ($ValidGroups -notcontains $g) {
        Write-Log ("Unknown group '{0}'. Groups: {1}" -f $g, ($ValidGroups -join ', ')) 'ERROR'
        Stop-Run 1
    }
}

$selectedIds = @()
if ($Tweak.Count -gt 0) { $selectedIds = @($Catalogue | Where-Object { $Tweak -icontains $_.Id } | ForEach-Object { $_.Id }) }
else                    { $selectedIds = @($Catalogue | Where-Object { $_.Default } | ForEach-Object { $_.Id }) }
foreach ($g in $Group) {
    foreach ($t in ($Catalogue | Where-Object { $_.Group -ieq $g })) {
        if ($selectedIds -notcontains $t.Id) { $selectedIds += $t.Id }
    }
}
$selectedIds = @($selectedIds | Where-Object { $SkipTweak -inotcontains $_ })

# Apps
$appList = @()
if ($RemoveApps) {
    if ($Apps.Count -gt 0) { $appList = @($Apps | ForEach-Object { @{ Id = $_; Name = $_ } }) }
    else                   { $appList = @($RecommendedApps) }
    if ($IncludeGamingApps) { $appList += $GamingApps }
    $appList = @($appList | Where-Object { $KeepApps -inotcontains $_.Id })
    foreach ($a in @($appList)) {
        foreach ($p in $ProtectedApps) {
            if ($a.Id -ieq $p) {
                Write-Log ("REFUSE {0}: on the protected list; never removed." -f $a.Id) 'WARN'
            }
        }
    }
    $appList = @($appList | Where-Object { $id = $_.Id; -not ($ProtectedApps | Where-Object { $_ -ieq $id }) })
}
$wingetList = @()
if ($RemoveApps -and (($Apps.Count -eq 0) -or ($Apps -icontains 'XP9CXNGPPJ97XX'))) {
    if ($selectedIds -contains 'DisableCopilot' -or $Apps -icontains 'XP9CXNGPPJ97XX') { $wingetList += 'XP9CXNGPPJ97XX' }
}
if ($IncludeOneDrive) { $wingetList += 'Microsoft.OneDrive' }

# ==========================================================================
#  CENSUS
# ==========================================================================

Write-Section 'TWEAKS'
$plan = @()          # tweaks to apply
$applied = 0; $na = 0
foreach ($t in $Catalogue) {
    $sel = ($selectedIds -contains $t.Id)
    $mark = if ($sel) { '*' } else { ' ' }
    $why = Get-TweakApplicability $t
    $tag = if ($t.Policy) { ' [POLICY]' } else { '' }
    if ($why) {
        Write-Log ("  {0} {1,-30} N/A      {2}{3} - {4}" -f $mark, $t.Id, $t.Title, $tag, $why)
        if ($sel) { $na++ }
        continue
    }
    $state = Get-TweakState $t
    if ($state.Applied) {
        Write-Log ("  {0} {1,-30} APPLIED  {2}{3}" -f $mark, $t.Id, $t.Title, $tag) $(if ($sel) { 'OK' } else { 'INFO' })
        if ($sel) { $applied++ }
    }
    else {
        $lvl = if (-not $sel) { 'INFO' } elseif ($t.Policy) { 'POLICY' } else { 'WARN' }
        Write-Log ("  {0} {1,-30} PENDING  {2}{3}" -f $mark, $t.Id, $t.Title, $tag) $lvl
        if ($sel) {
            foreach ($p in $state.Pending) { Write-Log ("        {0}" -f $p) }
            $plan += $t
        }
    }
}
Write-Log ''
Write-Log ("Selected: {0}  to apply: {1}  already applied: {2}  not applicable: {3}   (* = selected)" -f $selectedIds.Count, $plan.Count, $applied, $na)
if (@($plan | Where-Object { $_.Policy }).Count -gt 0) {
    Write-Log 'POLICY tweaks write under ...\Policies\... and make Windows/Edge show "managed by your organization". -Restore removes them.' 'POLICY'
}

Write-Section 'APPS'
$appPlan = @()
if (-not $RemoveApps) { Write-Log 'App removal is off (-RemoveApps:$false).' }
else {
    Get-AppxInventory
    if (-not $script:AppxAllUsers) { Write-Log 'Not elevated: app inventory covers the current user only. The real run sees every user.' 'WARN' }
    foreach ($a in $appList) {
        $hits = @(Get-InstalledMatches -Ids @($a.Id))
        if ($hits.Count -gt 0) {
            Write-Log ("  INSTALLED  {0,-45} {1}" -f $a.Name, ($hits -join ', ')) 'WARN'
            $appPlan += $a
        }
    }
    foreach ($w in $wingetList) {
        if (Test-WingetInstalled $w) {
            Write-Log ("  INSTALLED  {0,-45} via winget ({1})" -f $WingetApps[$w], $w) 'WARN'
            $appPlan += @{ Id = $w; Name = $WingetApps[$w]; Winget = $true }
        }
    }
    Write-Log ("Apps on the list: {0}  installed: {1}" -f ($appList.Count + $wingetList.Count), $appPlan.Count)
}

if ($plan.Count -eq 0 -and $appPlan.Count -eq 0) {
    Write-Section 'SUMMARY'
    Write-Log 'Nothing to do: every selected tweak is already applied and no selected app is installed.' 'OK'
    Stop-Run 2
}
if ($ListOnly) {
    Write-Log ''
    Write-Log 'ListOnly: stopping here. Re-run without -ListOnly to act on this census.' 'OK'
    Stop-Run 0
}

# ==========================================================================
#  ACT
# ==========================================================================

if (-not $Force -and -not $WhatIfPreference) {
    Write-Log ''
    Write-Log 'Review the census above. This is the last stop before changes are made.' 'WARN'
    $answer = Read-Host 'Proceed? [y/N]'
    if ($answer -notmatch '^(y|yes)$') {
        Write-Log 'Declined at the prompt. Nothing was changed.' 'WARN'
        Stop-Run 0
    }
}

$script:AnyFailed = $false

if ($CreateRestorePoint -and -not $WhatIfPreference) {
    Write-Section 'RESTORE POINT'
    try {
        Enable-ComputerRestore -Drive $env:SystemDrive -ErrorAction SilentlyContinue
        Checkpoint-Computer -Description 'Remove-WindowsBloat' -RestorePointType 'MODIFY_SETTINGS' -ErrorAction Stop
        Write-Log 'Restore point created.' 'OK'
    }
    catch {
        # Windows refuses a second restore point within 24 hours; that is not
        # a failure of this run.
        Write-Log "Restore point not created: $($_.Exception.Message)" 'WARN'
    }
}

# --- 1. Back up every value about to be written ---------------------------

if ($plan.Count -gt 0) {
    Write-Section 'BACKUP'
    foreach ($t in $plan) {
        foreach ($op in $t.Ops) { Add-BackupEntry -Op $op -Path (Resolve-RegPath $op.Hive $op.Key) }
    }
    if ($WhatIfPreference) {
        Write-Log ("Would capture {0} value(s) to a backup under {1}" -f $script:Backup.Count, $BackupPath)
    }
    else {
        $file = Save-Backup
        if ($file) { Write-Log "Captured $($script:Backup.Count) value(s) to $file" 'OK'; Write-Log "Revert with:  .\Remove-WindowsBloat.ps1 -Restore `"$file`"" }
    }
}

# --- 2. Tweaks ------------------------------------------------------------

$hkcuTouched = $false
if ($plan.Count -gt 0) {
    Write-Section 'APPLY TWEAKS'
    foreach ($t in $plan) {
        Write-Log ("{0}: {1}" -f $t.Id, $t.Title) $(if ($t.Policy) { 'POLICY' } else { 'INFO' })
        foreach ($op in $t.Ops) {
            $path  = Resolve-RegPath $op.Hive $op.Key
            $label = if ($op.Name -eq '') { "$path\(default)" } else { "$path\$($op.Name)" }
            try {
                if ($op.DeleteKey) {
                    if (-not (Test-Path -LiteralPath $path)) { continue }
                    if ($PSCmdlet.ShouldProcess($path, 'Delete key')) {
                        Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop
                        Write-Log "    deleted key $path" 'OK'
                    }
                    continue
                }
                if ($op.Delete) {
                    $st = Get-RegValueState -Path $path -Name $op.Name
                    if (-not $st.Exists) { continue }
                    if ($PSCmdlet.ShouldProcess($label, 'Delete value')) {
                        Remove-RegValue -Path $path -Name $op.Name
                        Write-Log "    deleted $label" 'OK'
                    }
                    continue
                }
                $st = Get-RegValueState -Path $path -Name $op.Name
                if (Test-RegValueEquals -State $st -Kind $op.Kind -Value $op.Value) { continue }
                if ($PSCmdlet.ShouldProcess($label, "Set $($op.Kind) $(ConvertTo-Display $op.Value)")) {
                    Set-RegValue -Path $path -Name $op.Name -Kind $op.Kind -Value $op.Value
                    Write-Log ("    {0} = {1}" -f $label, (ConvertTo-Display $op.Value)) 'OK'
                    if ($op.Hive -eq 'HKCU') { $hkcuTouched = $true }
                }
            }
            catch {
                Write-Log "    FAILED ${label}: $($_.Exception.Message)" 'ERROR'
                $script:AnyFailed = $true
            }
        }

        switch ($t.Post) {
            'TelemetryTasks' {
                foreach ($task in $TelemetryTasks) {
                    $obj = Get-ScheduledTask -TaskPath $task.Path -TaskName $task.Name -ErrorAction SilentlyContinue
                    if (-not $obj) { continue }
                    if ($obj.State -eq 'Disabled') { continue }
                    if ($PSCmdlet.ShouldProcess("$($task.Path)$($task.Name)", 'Disable scheduled task')) {
                        try { Disable-ScheduledTask -TaskPath $task.Path -TaskName $task.Name -ErrorAction Stop | Out-Null; Write-Log "    disabled task $($task.Path)$($task.Name)" 'OK' }
                        catch { Write-Log "    FAILED to disable task $($task.Name): $($_.Exception.Message)" 'ERROR'; $script:AnyFailed = $true }
                    }
                }
            }
            'WidgetsApps' {
                if (-not $WhatIfPreference) { Get-Process -Name '*Widget*' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue }
                foreach ($id in @('Microsoft.StartExperiencesApp', 'MicrosoftWindows.Client.WebExperience', 'Microsoft.WidgetsPlatformRuntime')) {
                    if (-not (Remove-AppById -Id $id -Display $id)) { $script:AnyFailed = $true }
                }
            }
            'CopilotApps' { if (-not (Remove-AppById -Id 'Microsoft.Copilot' -Display 'Microsoft Copilot')) { $script:AnyFailed = $true } }
            'BingApp'     { if (-not (Remove-AppById -Id 'Microsoft.BingSearch' -Display 'Web Search from Microsoft Bing')) { $script:AnyFailed = $true } }
        }
    }
}

# --- 3. Apps --------------------------------------------------------------

if ($appPlan.Count -gt 0) {
    Write-Section 'REMOVE APPS'
    foreach ($a in $appPlan) {
        Write-Log ("  {0} ({1})" -f $a.Name, $a.Id)
        $isWinget = ($a.ContainsKey('Winget') -and $a.Winget)
        $ok = if ($isWinget) { Remove-WingetApp -Id $a.Id -Display $a.Name } else { Remove-AppById -Id $a.Id -Display $a.Name }
        if (-not $ok) { $script:AnyFailed = $true }
    }
}

# --- 4. Explorer ----------------------------------------------------------

if ($hkcuTouched -and -not $NoExplorerRestart -and -not $WhatIfPreference) {
    Write-Section 'EXPLORER'
    if ($script:SameUser) {
        if ($PSCmdlet.ShouldProcess('explorer.exe', 'Restart')) {
            try {
                Get-Process -Name explorer -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 2
                if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) { Start-Process explorer.exe }
                Write-Log 'Explorer restarted.' 'OK'
            }
            catch { Write-Log "Could not restart Explorer: $($_.Exception.Message)" 'WARN' }
        }
    }
    else {
        Write-Log 'Elevated as a different account: not restarting the invoking user''s Explorer. Sign out and back in.' 'WARN'
    }
}

# ==========================================================================
#  SUMMARY
# ==========================================================================

Write-Section 'SUMMARY'
if ($WhatIfPreference) { Write-Log 'Preview run: nothing was changed.' 'OK'; Stop-Run 0 }
if ($script:AnyFailed) { Write-Log 'Completed with one or more failures. Review the log above.' 'WARN'; Write-Log "Log written to: $LogPath"; Stop-Run 3 }
Write-Log 'Completed successfully. Sign out and back in for every change to take effect.' 'OK'
Write-Log "Log written to: $LogPath"
Stop-Run 0
