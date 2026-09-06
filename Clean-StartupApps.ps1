<#
.SYNOPSIS
    Audits and cleans everything that launches itself when you sign in - the
    Run keys, the Startup folders, the packaged StartupTasks and the logon
    scheduled tasks - and, for each one, says what it actually is.

.DESCRIPTION
    Task Manager's "Startup apps" tab shows you a file name and, if you are
    lucky, a publisher. It will happily tell you that "Update.exe" runs at
    logon and leave you to guess whose updater that is. It shows entries from
    four different mechanisms as one flat list, gives no reason for any of
    them, and offers exactly one verb: Disable.

    This script answers the question Task Manager does not. For every startup
    entry it resolves the real target, reads the binary's publisher and
    description, checks the Authenticode signature, and then IDENTIFIES the
    entry in plain English - including the generic-stub cases that make the
    list unreadable:

      * "Update.exe" in %LOCALAPPDATA%\<App>\ is a Squirrel updater stub. The
        script reads the --processStart argument and the parent folder and
        reports it as "<App>'s auto-updater, which launches <App>.exe".
      * A Startup-folder .lnk is resolved to its target and arguments, so
        "Send to OneNote.lnk" is reported as ONENOTEM.EXE /tsr from Office.
      * A packaged StartupTask is reported with its owning app, because the
        task id ("StartTerminalOnLoginTask") is not the app name.

    It then gives each entry a VERDICT with a reason:

      KEEP      Removing it degrades the machine - security UI, audio service.
                Never touched, even by -RemoveAll.
      OPTIONAL  A launcher, updater, tray icon or sync agent. The application
                still works when you start it yourself; disabling only costs
                you background updates or a notification icon.
      REVIEW    Unsigned, unknown publisher, or living somewhere user-writable.
                Worth a look before you decide.
      ORPHAN    The target no longer exists. The entry does nothing but slow
                sign-in. Safe to remove.

    Shape matches the rest of this repository:

      * A CENSUS first. -ListOnly (the default) changes nothing and needs no
        elevation for the per-user surfaces.
      * A BACKUP before any change, to a JSON file whose path is printed.
        -Restore <file> puts every value, shortcut and task state back.
      * DISABLE is preferred over REMOVE. Disabling writes the same
        StartupApproved bytes Task Manager writes, so the entry stays visible
        and reversible. -Remove deletes the registry value or shortcut, and
        is only offered for entries you name explicitly, or for orphans.
      * Logged, previewable with -WhatIf, exit-coded.

.PARAMETER ListOnly
    Census only. The default when no action switch is given. Reports every
    entry with its identity and verdict, and changes nothing.

.PARAMETER Disable
    Names of entries to disable. Matched case-insensitively against the entry
    name, the resolved executable's base name, and the identified application
    name, so -Disable Discord and -Disable Update.exe both hit the same row.

.PARAMETER Enable
    Names of entries to re-enable. Same matching as -Disable.

.PARAMETER Remove
    Names of entries to DELETE rather than disable. The registry value or the
    Startup-folder shortcut is backed up first. Packaged StartupTasks cannot
    be deleted - they are disabled instead, and the run says so.

.PARAMETER DisableOptional
    Disable every entry whose verdict is OPTIONAL. KEEP entries are untouched.
    REVIEW entries are untouched: they need a human.

.PARAMETER RemoveOrphans
    Delete every entry whose target no longer exists.

.PARAMETER IncludeScheduledTasks
    Also enumerate scheduled tasks with a logon trigger. Reported by default,
    and eligible for -Disable when this switch is present.

.PARAMETER Restore
    Path to a backup JSON written by an earlier run. Puts every value back.

.PARAMETER Force
    Skip the confirmation prompt.

.PARAMETER LogPath
    Where to write the transcript. Defaults to a timestamped file in %TEMP%.

.PARAMETER BackupPath
    Where to write the backup JSON. Defaults to a timestamped file in %TEMP%.

.EXAMPLE
    .\Clean-StartupApps.ps1
    Census. Shows every startup entry, what it is, and what it costs you.

.EXAMPLE
    .\Clean-StartupApps.ps1 -Disable Discord,jusched,iTunesHelper
    Turn off Discord's updater, the Java update scheduler and the iTunes
    helper. All three stay in the list and can be re-enabled.

.EXAMPLE
    .\Clean-StartupApps.ps1 -DisableOptional -WhatIf
    Show exactly what a "disable everything optional" run would change.

.EXAMPLE
    .\Clean-StartupApps.ps1 -RemoveOrphans
    Delete the startup entries whose targets are already gone.

.EXAMPLE
    .\Clean-StartupApps.ps1 -Restore "$env:TEMP\StartupApps_20260906_101500.json"
    Put everything back.

.NOTES
    Exit codes (shared with the other scripts in this repository):

      0   Success (including "declined at the prompt")
      3   Partial failure - one or more entries could not be changed
      2   Nothing to do - no selected entry needed changing
      1   Aborted (elevation cancelled, invalid -LogPath, -Restore file
          missing, no entry matched a name you passed)

    Machine-wide surfaces (HKLM Run, the common Startup folder, scheduled
    tasks) need elevation to CHANGE. Reading them does not, so the census is
    complete either way; the run tells you which rows it could not touch.
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [switch]$ListOnly,
    [string[]]$Disable,
    [string[]]$Enable,
    [string[]]$Remove,
    [switch]$DisableOptional,
    [switch]$RemoveOrphans,
    [switch]$IncludeScheduledTasks,
    [string]$Restore,
    [switch]$Force,
    [string]$LogPath,
    [string]$BackupPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ($Force) { $ConfirmPreference = 'None' }

# Lists may arrive as a real array (PowerShell prompt) or as ONE "a,b,c"
# string (powershell.exe -File, and therefore the .cmd launcher). Normalise
# both. @() at the call site: a function that returns an empty array returns
# nothing, and under StrictMode a later .Count on that $null throws.
function ConvertTo-List {
    param($Value)
    if ($null -eq $Value) { return @() }
    return @($Value | ForEach-Object { [string]$_ -split ',' } |
             ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

$Disable = @(ConvertTo-List $Disable)
$Enable  = @(ConvertTo-List $Enable)
$Remove  = @(ConvertTo-List $Remove)

$WantsChange = ($Disable.Count -or $Enable.Count -or $Remove.Count -or
                $DisableOptional -or $RemoveOrphans -or $Restore)
if (-not $WantsChange) { $ListOnly = $true }

# --- Paths ----------------------------------------------------------------
# Resolve to ROOTED paths immediately, before anything consumes them: the
# elevated child does not inherit the operator's working directory.
if ([string]::IsNullOrWhiteSpace($LogPath)) {
    $LogPath = Join-Path $env:TEMP ("StartupApps_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))
}
if ([string]::IsNullOrWhiteSpace($BackupPath)) {
    $BackupPath = Join-Path $env:TEMP ("StartupApps_{0:yyyyMMdd_HHmmss}.json" -f (Get-Date))
}
foreach ($n in 'LogPath', 'BackupPath') {
    $v = (Get-Variable -Name $n -ValueOnly)
    if (-not [IO.Path]::IsPathRooted($v)) {
        try {
            Set-Variable -Name $n -Value ([IO.Path]::GetFullPath(
                [IO.Path]::Combine((Get-Location).ProviderPath, $v)))
        }
        catch {
            Write-Host "Invalid -${n} '$v': $($_.Exception.Message)" -ForegroundColor Red
            exit 1
        }
    }
}

# --- Logging --------------------------------------------------------------
$script:TranscriptStarted = $false
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
}

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $stamp = Get-Date -Format 'HH:mm:ss'
    $colour = switch ($Level) {
        'OK'     { 'Green' }
        'WARN'   { 'Yellow' }
        'ERROR'  { 'Red' }
        'REFUSE' { 'Magenta' }
        'HEAD'   { 'Cyan' }
        default  { 'Gray' }
    }
    Write-Host "[$stamp] $($Level.PadRight(6)) $Message" -ForegroundColor $colour
}

function Write-Section {
    param([string]$Title)
    Write-Host ''
    Write-Log ('=' * 72) 'HEAD'
    Write-Log $Title 'HEAD'
    Write-Log ('=' * 72) 'HEAD'
}

function Stop-Run {
    param([int]$Code)
    if ($script:TranscriptStarted) { try { Stop-Transcript | Out-Null } catch { } }
    exit $Code
}

function Test-IsAdministrator {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]$id).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}
$script:IsAdmin = Test-IsAdministrator

# --- Safe path helpers ----------------------------------------------------
# Test-Path VALIDATES a path before it tests it: a string carrying a character
# that cannot occur in a path makes it THROW rather than return $false, and
# under $ErrorActionPreference='Stop' that ends the run. Everything here is
# second-hand - registry values, shortcut targets, task actions - so nothing
# reaches the filesystem except through these two.
function Test-PathChars {
    param([string]$Path)
    if ([string]::IsNullOrEmpty($Path)) { return $false }
    # .NET Framework's GetInvalidPathChars() lists " < > | and the control
    # characters; .NET Core trimmed the same call down to NUL alone. Spelling
    # the set out keeps 5.1 and 7 behaving identically.
    $bad = ([char[]]@('"', '<', '>', '|', '*', '?')) + [char[]](0..31)
    return ($Path.IndexOfAny($bad) -lt 0)
}

function Test-PathSafe {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    if (-not (Test-PathChars $Path)) { return $false }
    try { return [bool](Test-Path -LiteralPath $Path -ErrorAction Stop) }
    catch { return $false }
}

# Pull the executable out of a command line. Handles the quoted form, the
# unquoted-with-arguments form, and environment variables.
function Get-CommandTarget {
    param([string]$Command)
    if ([string]::IsNullOrWhiteSpace($Command)) { return '' }
    $c = $Command.Trim()

    if ($c.StartsWith('"')) {
        $close = $c.IndexOf('"', 1)
        if ($close -gt 1) { $c = $c.Substring(1, $close - 1) } else { $c = $c.Substring(1) }
    }
    elseif ($c -match '^(.*?\.(?:exe|com|bat|cmd|scr))(?:\s|$)') { $c = $Matches[1] }
    else { $c = ($c -split '\s+')[0] }

    $c = $c.Trim().Trim('"').Trim()
    if ($c -match '%\w+%') {
        try { $c = [Environment]::ExpandEnvironmentVariables($c) } catch { }
    }
    if (-not (Test-PathChars $c)) { return '' }
    return $c
}

function Get-BinaryFacts {
    param([string]$Path)
    $out = [pscustomobject]@{
        Exists = $false; Company = ''; Product = ''; Description = ''
        Signed = 'unknown'; Signer = ''
    }
    if (-not (Test-PathSafe $Path)) { return $out }
    $out.Exists = $true
    try {
        $vi = [Diagnostics.FileVersionInfo]::GetVersionInfo($Path)
        if ($vi.CompanyName)      { $out.Company     = ([string]$vi.CompanyName).Trim() }
        if ($vi.ProductName)      { $out.Product     = ([string]$vi.ProductName).Trim() }
        if ($vi.FileDescription)  { $out.Description = ([string]$vi.FileDescription).Trim() }
    }
    catch { }
    try {
        $sig = Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction Stop
        $out.Signed = [string]$sig.Status
        if ($sig.SignerCertificate) {
            $subject = [string]$sig.SignerCertificate.Subject
            if ($subject -match 'CN=([^,]+)') { $out.Signer = $Matches[1].Trim('"').Trim() }
        }
    }
    catch { }
    return $out
}

# --- The knowledge base ---------------------------------------------------
#
# What each well-known entry actually is, and what disabling it costs. Matched
# on the executable's base name, so it survives being installed anywhere.
# Verdict is the DEFAULT; the evidence gathered per machine can override it
# (a missing target always wins, and so does an unsigned binary).
#
#   Keep      = removing it degrades the machine
#   Optional  = a launcher, updater, tray icon or sync agent
#
$KnownEntries = @(
    # --- Windows components that earn their place --------------------------
    @{ Exe = 'SecurityHealthSystray.exe'; App = 'Windows Security';
       What = 'the Windows Security notification icon (Defender status in the tray)';
       Cost = 'you lose the tray icon and its alerts; Defender itself keeps running';
       Verdict = 'Keep' }
    @{ Exe = 'RtkAudUService64.exe'; App = 'Realtek HD Audio';
       What = 'the Realtek audio service that applies your jack, speaker and effects settings';
       Cost = 'jack-detection popups and audio effect settings stop working';
       Verdict = 'Keep' }
    @{ Exe = 'RAVBg64.exe'; App = 'Realtek HD Audio';
       What = 'the Realtek audio background component';
       Cost = 'audio effects settings may stop applying'; Verdict = 'Keep' }

    # --- Updaters and launcher stubs ---------------------------------------
    @{ Exe = 'Update.exe'; App = ''; Squirrel = $true;
       What = 'a Squirrel auto-updater stub - the app it belongs to is named by its folder and its --processStart argument';
       Cost = 'the app stops auto-updating in the background and no longer starts at logon; it still runs when you launch it';
       Verdict = 'Optional' }
    @{ Exe = 'jusched.exe'; App = 'Java';
       What = 'the Oracle Java Update Scheduler, which polls for new Java runtimes';
       Cost = 'Java stops nagging about updates - you update it yourself';
       Verdict = 'Optional' }
    @{ Exe = 'GoogleUpdate.exe'; App = 'Google Update';
       What = 'the Google updater for Chrome and other Google software';
       Cost = 'Chrome updates only when you open it'; Verdict = 'Optional' }
    @{ Exe = 'GenuineService.exe'; App = 'Autodesk Genuine Service';
       What = 'Autodesk''s licence-validation agent, which checks your Autodesk software is genuine';
       Cost = 'nothing for a licensed install; it re-registers itself when you next run an Autodesk installer';
       Verdict = 'Optional' }
    @{ Exe = 'AdskAccessServiceHost.exe'; App = 'Autodesk Access';
       What = 'the Autodesk Access update agent for Revit, AutoCAD and Civil 3D';
       Cost = 'Autodesk updates stop arriving automatically; Access still runs when opened';
       Verdict = 'Optional' }
    @{ Exe = 'AdskAccessService.exe'; App = 'Autodesk Access';
       What = 'the Autodesk Desktop Agent service launcher for Autodesk updates';
       Cost = 'Autodesk updates stop arriving automatically'; Verdict = 'Optional' }
    @{ Exe = 'AdskAccessCore.exe'; App = 'Autodesk Access';
       What = 'the Autodesk Access core process that backs the update UI';
       Cost = 'Autodesk updates stop arriving automatically'; Verdict = 'Optional' }

    # --- Tray icons and helpers --------------------------------------------
    @{ Exe = 'iTunesHelper.exe'; App = 'iTunes';
       What = 'the iTunes helper that watches for a connected iPhone or iPod and opens iTunes';
       Cost = 'iTunes no longer opens by itself when you plug in a device';
       Verdict = 'Optional' }
    @{ Exe = 'iCloudServices.exe'; App = 'iCloud';
       What = 'the iCloud for Windows sync host'; Cost = 'iCloud stops syncing until you open it';
       Verdict = 'Optional' }
    @{ Exe = 'iCloudDrive.exe'; App = 'iCloud';
       What = 'iCloud Drive file sync'; Cost = 'iCloud Drive stops syncing in the background';
       Verdict = 'Optional' }
    @{ Exe = 'iCloudPhotos.exe'; App = 'iCloud';
       What = 'iCloud Photo Library sync'; Cost = 'photos stop syncing in the background';
       Verdict = 'Optional' }
    @{ Exe = 'ApplePhotoStreams.exe'; App = 'iCloud';
       What = 'iCloud Photo Stream sync'; Cost = 'Photo Stream stops syncing';
       Verdict = 'Optional' }
    @{ Exe = 'AppleIEDAV.exe'; App = 'iCloud';
       What = 'iCloud bookmark sync for Internet Explorer - a dead browser on a supported OS';
       Cost = 'nothing on any current Windows install'; Verdict = 'Optional' }
    @{ Exe = 'lghub_system_tray.exe'; App = 'Logitech G HUB';
       What = 'the Logitech G HUB tray icon';
       Cost = 'the tray icon goes; per-device lighting and macro profiles applied by the G HUB SERVICE still work';
       Verdict = 'Optional' }
    @{ Exe = 'IDMan.exe'; App = 'Internet Download Manager';
       What = 'Internet Download Manager, which hooks browser downloads';
       Cost = 'downloads go back to the browser until you start IDM yourself';
       Verdict = 'Optional' }
    @{ Exe = 'steam.exe'; App = 'Steam';
       What = 'the Steam client';
       Cost = 'Steam no longer starts at logon; games launched from a desktop shortcut will start it';
       Verdict = 'Optional' }
    @{ Exe = 'AltServer.exe'; App = 'AltServer';
       What = 'AltStore''s desktop companion, which refreshes sideloaded iOS app signatures';
       Cost = 'sideloaded iOS apps stop being refreshed and will expire after 7 days';
       Verdict = 'Optional' }
    @{ Exe = 'DesktopConnector.Applications.Tray.exe'; App = 'Autodesk Desktop Connector';
       What = 'the Autodesk Desktop Connector tray agent, which syncs BIM 360 / ACC files to a local drive';
       Cost = 'your ACC/BIM 360 drive stops syncing until you start it - keep this if you work from ACC daily';
       Verdict = 'Review' }
    @{ Exe = 'RevitAccelerator.exe'; App = 'Personal Accelerator for Revit';
       What = 'Autodesk''s Personal Accelerator, which pre-caches Revit central models in the background';
       Cost = 'the first open of a workshared central model is slower; nothing breaks';
       Verdict = 'Optional' }
    @{ Exe = 'OneDrive.exe'; App = 'OneDrive';
       What = 'the OneDrive sync client';
       Cost = 'OneDrive stops syncing in the background - keep it if your Desktop or Documents are redirected there';
       Verdict = 'Review' }
    @{ Exe = 'msedge.exe'; App = 'Microsoft Edge';
       What = 'Edge''s auto-launch entry, which starts Edge in the background at logon to make it feel fast';
       Cost = 'nothing - Edge simply opens when you ask for it';
       Verdict = 'Optional' }
    @{ Exe = 'ONENOTEM.EXE'; App = 'OneNote 2016';
       What = 'the Office "Send to OneNote" tray tool, which provides the Win+S screen-clipping hotkey for OneNote 2016';
       Cost = 'the OneNote screen-clipping hotkey stops working; OneNote itself is unaffected';
       Verdict = 'Optional' }
    @{ Exe = 'unsloth-studio.exe'; App = 'Unsloth Studio';
       What = 'Unsloth Studio''s desktop app starting itself at logon';
       Cost = 'nothing - launch it when you need it'; Verdict = 'Optional' }
    @{ Exe = 'Spotify.exe'; App = 'Spotify';
       What = 'the Spotify desktop client'; Cost = 'nothing - launch it when you need it';
       Verdict = 'Optional' }
    @{ Exe = 'EpicGamesLauncher.exe'; App = 'Epic Games Launcher';
       What = 'the Epic Games launcher'; Cost = 'nothing - launch it when you need it';
       Verdict = 'Optional' }
    @{ Exe = 'Dropbox.exe'; App = 'Dropbox';
       What = 'the Dropbox sync client'; Cost = 'Dropbox stops syncing in the background';
       Verdict = 'Review' }
    @{ Exe = 'GoogleDriveFS.exe'; App = 'Google Drive';
       What = 'the Google Drive sync client'; Cost = 'Google Drive stops syncing in the background';
       Verdict = 'Review' }
    @{ Exe = 'Teams.exe'; App = 'Microsoft Teams';
       What = 'the Teams client starting itself at logon';
       Cost = 'you will not receive Teams notifications until you open it'; Verdict = 'Optional' }
    @{ Exe = 'NVIDIA Web Helper.exe'; App = 'NVIDIA GeForce Experience';
       What = 'the GeForce Experience web helper';
       Cost = 'GeForce Experience overlays and driver notifications stop'; Verdict = 'Optional' }
)

# Executable names that identify nothing on their own. When one of these turns
# up, the identity has to come from the folder, the command line and the
# version resource instead.
$GenericStubs = @(
    'update.exe', 'updater.exe', 'launcher.exe', 'setup.exe', 'stub.exe',
    'run.exe', 'app.exe', 'main.exe', 'host.exe', 'helper.exe', 'tray.exe',
    'service.exe', 'agent.exe', 'start.exe', 'bootstrap.exe', 'client.exe'
)

# Packaged (Store/MSIX) startup tasks: the task id is not the app name.
$KnownPackages = @{
    'Microsoft.WindowsTerminal'   = @{ App = 'Windows Terminal';
        What = 'Windows Terminal''s "launch on machine startup" task, declared in its app manifest';
        Cost = 'Terminal stops opening at logon'; Verdict = 'Optional' }
    'Microsoft.YourPhone'         = @{ App = 'Phone Link';
        What = 'Phone Link, which pairs your phone for messages, calls and photos';
        Cost = 'Phone Link stops receiving in the background'; Verdict = 'Optional' }
    'MicrosoftWindows.CrossDevice'= @{ App = 'Mobile devices (Cross Device)';
        What = 'the Cross Device service behind "Mobile devices" and Phone Link''s camera roll';
        Cost = 'phone integration stops working in the background'; Verdict = 'Optional' }
    'MSTeams'                     = @{ App = 'Microsoft Teams';
        What = 'the new Teams client''s startup task';
        Cost = 'no Teams notifications until you open it'; Verdict = 'Optional' }
    'Microsoft.GamingApp'         = @{ App = 'Xbox';
        What = 'the Xbox app''s startup task';
        Cost = 'nothing unless you use Xbox Game Pass installs'; Verdict = 'Optional' }
    'Microsoft.SkypeApp'          = @{ App = 'Skype';
        What = 'Skype''s startup task'; Cost = 'no Skype notifications until you open it';
        Verdict = 'Optional' }
    'Microsoft.Windows.Copilot'   = @{ App = 'Copilot';
        What = 'the Copilot startup task'; Cost = 'nothing'; Verdict = 'Optional' }
}

# --- Identification -------------------------------------------------------
function Resolve-Identity {
    param([string]$Name, [string]$Command, [string]$Target, $Facts)

    $base = ''
    if ($Target) { try { $base = [IO.Path]::GetFileName($Target) } catch { $base = '' } }

    $known = $null
    foreach ($k in $KnownEntries) {
        if ($base -and ($k.Exe -eq $base)) { $known = $k; break }
    }

    $app  = ''
    $what = ''
    $cost = ''
    $verdict = 'Review'

    if ($known) {
        $app     = [string]$known.App
        $what    = [string]$known.What
        $cost    = [string]$known.Cost
        $verdict = [string]$known.Verdict
    }

    # A generic stub tells you nothing. Recover the real identity from, in
    # order: the --processStart argument, the version resource, the parent
    # folder, the Authenticode signer, and finally the registry value name.
    $isGeneric = $base -and ($GenericStubs -contains $base.ToLowerInvariant())
    if ($isGeneric -or -not $app) {
        $guess = ''
        if ($Command -match '--processStart[= ]+"?([^"\s]+)"?') {
            $guess = [IO.Path]::GetFileNameWithoutExtension($Matches[1])
        }
        if (-not $guess -and $Facts.Product -and $Facts.Product -ne 'Update') { $guess = $Facts.Product }
        if (-not $guess -and $Target) {
            try {
                $parent = Split-Path -Parent $Target
                if ($parent) { $guess = Split-Path -Leaf $parent }
            }
            catch { }
        }
        if (-not $guess -and $Facts.Company) { $guess = $Facts.Company }
        if (-not $guess) { $guess = $Name }

        if ($isGeneric) {
            $app = $guess
            $isSquirrel = $known -and $known.ContainsKey('Squirrel') -and $known.Squirrel
            if ($isSquirrel) {
                # The whole point of this script: "Update.exe" names nothing.
                # Say whose updater it is and what it actually starts.
                $starts = ''
                if ($Command -match '--processStart[= ]+"?([^"\s]+)"?') { $starts = $Matches[1] }
                $what = "$guess's auto-updater stub (Squirrel)"
                if ($starts) { $what += ", which then launches $starts" }
                $cost = "$guess stops starting at logon and stops updating itself in the background; it still works when you launch it"
            }
            elseif (-not $what) {
                $what = "a generic '$base' stub belonging to $guess"
            }
            if (-not $cost) {
                $cost = "$guess stops starting and auto-updating at logon; it still runs when you launch it"
            }
            if ($verdict -eq 'Review') { $verdict = 'Optional' }
        }
        elseif (-not $app) {
            $app = $guess
        }
    }

    if (-not $what) {
        if ($Facts.Description) { $what = "$($Facts.Description)" }
        elseif ($Facts.Company) { $what = "a startup entry from $($Facts.Company)" }
        else { $what = 'an unrecognised startup entry' }
    }
    if (-not $cost) { $cost = 'unknown - identify it before disabling' }

    return [pscustomobject]@{ App = $app; What = $what; Cost = $cost; Verdict = $verdict }
}

# The evidence on this machine can override the catalogue's default verdict.
function Resolve-Verdict {
    param($Entry)
    # A packaged (Store/MSIX) startup task has no filesystem target by design -
    # Windows starts it through the app model, not a command line. Judging it on
    # a missing path would mark every Store app REVIEW.
    if ($Entry.Kind -eq 'Package') {
        if ($Entry.Identity.Verdict -eq 'Keep') { return @('Keep', 'a Windows component this machine needs') }
        return @('Optional', 'a Store app that starts itself at logon')
    }
    if (-not $Entry.Target) { return @('Review', 'no resolvable target in the command line') }
    if (-not $Entry.Facts.Exists) { return @('Orphan', 'the target file does not exist') }

    $v = $Entry.Identity.Verdict
    if ($v -eq 'Keep') { return @('Keep', 'a Windows or device component this machine needs') }

    $sig = [string]$Entry.Facts.Signed
    if ($sig -eq 'NotSigned') {
        return @('Review', 'the binary is not digitally signed')
    }
    if ($sig -notin @('Valid', 'UnknownError', 'unknown')) {
        return @('Review', "the signature is '$sig'")
    }
    if ($v -eq 'Review') { return @('Review', 'identified, but you should decide - it syncs or stores your data') }
    return @('Optional', 'a launcher, updater, tray icon or background helper')
}

# --- Enumeration ----------------------------------------------------------
$RunKeys = @(
    @{ Hive = 'HKCU'; Key = 'Software\Microsoft\Windows\CurrentVersion\Run';                  Approved = 'Run';   Elevated = $false }
    @{ Hive = 'HKCU'; Key = 'Software\Microsoft\Windows\CurrentVersion\RunOnce';              Approved = '';      Elevated = $false }
    @{ Hive = 'HKLM'; Key = 'Software\Microsoft\Windows\CurrentVersion\Run';                  Approved = 'Run';   Elevated = $true  }
    @{ Hive = 'HKLM'; Key = 'Software\Microsoft\Windows\CurrentVersion\RunOnce';              Approved = '';      Elevated = $true  }
    @{ Hive = 'HKLM'; Key = 'Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run';      Approved = 'Run32'; Elevated = $true  }
    @{ Hive = 'HKLM'; Key = 'Software\WOW6432Node\Microsoft\Windows\CurrentVersion\RunOnce';  Approved = '';      Elevated = $true  }
)

function Get-ApprovedState {
    param([string]$Hive, [string]$Approved, [string]$Name)
    if (-not $Approved) { return 'n/a' }
    $p = "${Hive}:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\$Approved"
    if (-not (Test-Path $p)) { return 'Enabled' }
    $v = $null
    try { $v = (Get-ItemProperty -LiteralPath $p -Name $Name -ErrorAction Stop).$Name } catch { return 'Enabled' }
    if ($v -is [byte[]] -and $v.Length -ge 1) {
        # Byte 0 is a flag word: bit 0 set means disabled. Task Manager writes
        # 02 00 .. for enabled and 03 00 .. plus a FILETIME for disabled.
        if (($v[0] -band 1) -eq 0) { return 'Enabled' } else { return 'Disabled' }
    }
    return 'Enabled'
}

function Get-RunEntries {
    $out = @()
    foreach ($r in $RunKeys) {
        $p = "$($r.Hive):\$($r.Key)"
        if (-not (Test-Path $p)) { continue }
        $it = $null
        try { $it = Get-ItemProperty -LiteralPath $p -ErrorAction Stop } catch { continue }
        if ($null -eq $it) { continue }
        foreach ($prop in $it.PSObject.Properties) {
            if ($prop.Name -like 'PS*') { continue }
            $cmd    = [string]$prop.Value
            $target = Get-CommandTarget $cmd
            $facts  = Get-BinaryFacts $target
            $ident  = Resolve-Identity $prop.Name $cmd $target $facts
            $out += [pscustomobject]@{
                Surface   = "$($r.Hive) $(if ($r.Key -like '*RunOnce') { 'RunOnce' } elseif ($r.Key -like '*WOW6432Node*') { 'Run (32-bit)' } else { 'Run' })"
                Kind      = 'Run'
                Name      = $prop.Name
                Command   = $cmd
                Target    = $target
                Facts     = $facts
                Identity  = $ident
                State     = (Get-ApprovedState $r.Hive $r.Approved $prop.Name)
                Hive      = $r.Hive
                Key       = $r.Key
                Approved  = $r.Approved
                NeedsAdmin= $r.Elevated
                Verdict   = ''
                Why       = ''
            }
        }
    }
    return @($out)
}

function Get-FolderEntries {
    $out = @()
    $folders = @(
        @{ Path = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup";     Hive = 'HKCU'; Elevated = $false; Label = 'Startup folder (user)' }
        @{ Path = "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\Startup"; Hive = 'HKLM'; Elevated = $true;  Label = 'Startup folder (all users)' }
    )
    $shell = $null
    try { $shell = New-Object -ComObject WScript.Shell } catch { }

    foreach ($f in $folders) {
        if (-not (Test-PathSafe $f.Path)) { continue }
        foreach ($file in (Get-ChildItem -LiteralPath $f.Path -File -ErrorAction SilentlyContinue)) {
            if ($file.Name -eq 'desktop.ini') { continue }
            $cmd = ''; $target = ''
            if ($file.Extension -eq '.lnk' -and $shell) {
                try {
                    $sc = $shell.CreateShortcut($file.FullName)
                    $target = [string]$sc.TargetPath
                    $cmd = if ($sc.Arguments) { "`"$target`" $($sc.Arguments)" } else { $target }
                }
                catch { }
            }
            if (-not $target) { $target = $file.FullName; $cmd = $file.FullName }
            $facts = Get-BinaryFacts $target
            $ident = Resolve-Identity $file.BaseName $cmd $target $facts
            $out += [pscustomobject]@{
                Surface   = $f.Label
                Kind      = 'Folder'
                Name      = $file.Name
                Command   = $cmd
                Target    = $target
                Facts     = $facts
                Identity  = $ident
                State     = (Get-ApprovedState $f.Hive 'StartupFolder' $file.Name)
                Hive      = $f.Hive
                Key       = $f.Path
                Approved  = 'StartupFolder'
                NeedsAdmin= $f.Elevated
                Verdict   = ''
                Why       = ''
            }
        }
    }
    return @($out)
}

function Get-PackagedEntries {
    $out = @()
    $base = 'HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\AppModel\SystemAppData'
    if (-not (Test-Path $base)) { return @($out) }

    foreach ($pkg in (Get-ChildItem -LiteralPath $base -ErrorAction SilentlyContinue)) {
        $pfn = $pkg.PSChildName
        # The family name is everything before the publisher hash.
        $family = $pfn
        $us = $pfn.LastIndexOf('_')
        if ($us -gt 0) { $family = $pfn.Substring(0, $us) }

        foreach ($task in (Get-ChildItem -LiteralPath $pkg.PSPath -ErrorAction SilentlyContinue)) {
            if ($task.PSChildName -eq 'Schemas') { continue }
            $state = $null
            try { $state = (Get-ItemProperty -LiteralPath $task.PSPath -Name State -ErrorAction Stop).State }
            catch { continue }
            if ($null -eq $state) { continue }

            # Windows.ApplicationModel.StartupTaskState:
            #   0 Disabled  1 DisabledByUser  2 Enabled
            #   3 DisabledByPolicy  4 EnabledByPolicy
            $label = switch ([int]$state) {
                0 { 'Disabled' }  1 { 'Disabled' }  2 { 'Enabled' }
                3 { 'Disabled (policy)' } 4 { 'Enabled (policy)' }
                default { "state $state" }
            }

            $meta = $null
            foreach ($k in $KnownPackages.Keys) { if ($family -eq $k) { $meta = $KnownPackages[$k]; break } }

            if ($meta) {
                $ident = [pscustomobject]@{ App = $meta.App; What = $meta.What; Cost = $meta.Cost; Verdict = $meta.Verdict }
            }
            else {
                $friendly = $family
                if ($friendly -match '\.([^.]+)$') { $friendly = $Matches[1] }
                $ident = [pscustomobject]@{
                    App = $friendly
                    What = "a packaged app startup task declared by $family"
                    Cost = "$friendly stops starting at logon; it still runs when you launch it"
                    Verdict = 'Optional'
                }
            }

            $out += [pscustomobject]@{
                Surface   = 'Packaged app (StartupTask)'
                Kind      = 'Package'
                Name      = $ident.App
                Command   = "$family :: $($task.PSChildName)"
                Target    = ''
                Facts     = [pscustomobject]@{ Exists = $true; Company = ''; Product = ''; Description = ''; Signed = 'Valid'; Signer = '' }
                Identity  = $ident
                State     = $label
                Hive      = 'HKCU'
                Key       = $task.PSPath
                Approved  = ''
                NeedsAdmin= $false
                Verdict   = ''
                Why       = ''
            }
        }
    }
    return @($out)
}

function Get-LogonTaskEntries {
    $out = @()
    if (-not (Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue)) { return @($out) }
    $tasks = @()
    try { $tasks = @(Get-ScheduledTask -ErrorAction Stop) } catch { return @($out) }

    foreach ($t in $tasks) {
        $hasLogon = $false
        try { foreach ($trg in $t.Triggers) { if ($trg.CimClass.CimClassName -eq 'MSFT_TaskLogonTrigger') { $hasLogon = $true; break } } }
        catch { }
        if (-not $hasLogon) { continue }
        if ($t.TaskPath -like '\Microsoft\Windows\*') { continue }   # inbox maintenance, not user bloat

        $exe = ''
        try { foreach ($a in $t.Actions) { if ($a.PSObject.Properties['Execute'] -and $a.Execute) { $exe = [string]$a.Execute; break } } }
        catch { }
        $target = Get-CommandTarget $exe
        $facts  = Get-BinaryFacts $target
        $ident  = Resolve-Identity $t.TaskName $exe $target $facts

        $out += [pscustomobject]@{
            Surface   = 'Scheduled task (at logon)'
            Kind      = 'Task'
            Name      = $t.TaskName
            Command   = $exe
            Target    = $target
            Facts     = $facts
            Identity  = $ident
            State     = $(if ([string]$t.State -eq 'Disabled') { 'Disabled' } else { 'Enabled' })
            Hive      = ''
            Key       = $t.TaskPath
            Approved  = ''
            NeedsAdmin= $true
            Verdict   = ''
            Why       = ''
        }
    }
    return @($out)
}

# --- Backup ---------------------------------------------------------------
$script:Backup = @()

function Add-BackupEntry {
    param($Entry, [string]$Action, $Before)
    $script:Backup += [pscustomobject]@{
        Kind = $Entry.Kind; Surface = $Entry.Surface; Name = $Entry.Name
        Hive = $Entry.Hive; Key = $Entry.Key; Approved = $Entry.Approved
        Command = $Entry.Command; Action = $Action; Before = $Before
    }
}

function Save-Backup {
    if (-not $script:Backup.Count) { return }
    try {
        $dir = Split-Path -Parent $BackupPath
        if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $script:Backup | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $BackupPath -Encoding UTF8
        Write-Log "Backup written to: $BackupPath" 'OK'
    }
    catch { Write-Log "Could not write backup: $($_.Exception.Message)" 'ERROR' }
}

# --- Mutation -------------------------------------------------------------
function Set-ApprovedState {
    param([string]$Hive, [string]$Approved, [string]$Name, [bool]$EnabledState)
    if (-not $Approved) { return $false }
    $p = "${Hive}:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\$Approved"
    if (-not (Test-Path $p)) { New-Item -Path $p -Force | Out-Null }
    if ($EnabledState) {
        $bytes = [byte[]](2,0,0,0, 0,0,0,0, 0,0,0,0)
    }
    else {
        $ft = [BitConverter]::GetBytes((Get-Date).ToFileTime())
        $bytes = [byte[]](@(3,0,0,0) + $ft)
    }
    Set-ItemProperty -LiteralPath $p -Name $Name -Value $bytes -Type Binary -Force
    return $true
}

function Set-EntryState {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param($Entry, [bool]$EnabledState)
    $verb = if ($EnabledState) { 'Enable' } else { 'Disable' }
    if (-not $PSCmdlet.ShouldProcess("$($Entry.Name) [$($Entry.Surface)]", $verb)) { return 'skipped' }

    if ($Entry.NeedsAdmin -and -not $script:IsAdmin) {
        Write-Log "  REFUSE $($Entry.Name): $($Entry.Surface) needs an elevated run." 'REFUSE'
        return 'refused'
    }

    try {
        switch ($Entry.Kind) {
            'Package' {
                $before = (Get-ItemProperty -LiteralPath $Entry.Key -Name State).State
                Add-BackupEntry $Entry 'state' $before
                Set-ItemProperty -LiteralPath $Entry.Key -Name State -Value $(if ($EnabledState) { 2 } else { 1 }) -Type DWord -Force
            }
            'Task' {
                Add-BackupEntry $Entry 'task' $Entry.State
                if ($EnabledState) { Enable-ScheduledTask -TaskName $Entry.Name -TaskPath $Entry.Key | Out-Null }
                else               { Disable-ScheduledTask -TaskName $Entry.Name -TaskPath $Entry.Key | Out-Null }
            }
            default {
                $before = 'Enabled'
                try { $before = Get-ApprovedState $Entry.Hive $Entry.Approved $Entry.Name } catch { }
                Add-BackupEntry $Entry 'approved' $before
                if (-not (Set-ApprovedState $Entry.Hive $Entry.Approved $Entry.Name $EnabledState)) {
                    Write-Log "  REFUSE $($Entry.Name): $($Entry.Surface) has no enable/disable flag - use -Remove." 'REFUSE'
                    return 'refused'
                }
            }
        }
        Write-Log "  $verb`d $($Entry.Name) [$($Entry.Surface)]" 'OK'
        return 'ok'
    }
    catch {
        Write-Log "  FAILED to $($verb.ToLower()) $($Entry.Name): $($_.Exception.Message)" 'ERROR'
        return 'failed'
    }
}

function Remove-Entry {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param($Entry)
    if (-not $PSCmdlet.ShouldProcess("$($Entry.Name) [$($Entry.Surface)]", 'Remove')) { return 'skipped' }

    if ($Entry.Kind -eq 'Package') {
        Write-Log "  $($Entry.Name) is a packaged app - disabling instead of removing." 'WARN'
        return (Set-EntryState $Entry $false)
    }
    if ($Entry.NeedsAdmin -and -not $script:IsAdmin) {
        Write-Log "  REFUSE $($Entry.Name): $($Entry.Surface) needs an elevated run." 'REFUSE'
        return 'refused'
    }

    try {
        switch ($Entry.Kind) {
            'Run' {
                Add-BackupEntry $Entry 'value' $Entry.Command
                Remove-ItemProperty -LiteralPath "$($Entry.Hive):\$($Entry.Key)" -Name $Entry.Name -Force
            }
            'Folder' {
                $file = Join-Path $Entry.Key $Entry.Name
                Add-BackupEntry $Entry 'shortcut' $Entry.Command
                Remove-Item -LiteralPath $file -Force
            }
            'Task' {
                Add-BackupEntry $Entry 'task' $Entry.State
                Unregister-ScheduledTask -TaskName $Entry.Name -TaskPath $Entry.Key -Confirm:$false
            }
            default {
                Write-Log "  REFUSE $($Entry.Name): unknown surface." 'REFUSE'
                return 'refused'
            }
        }
        Write-Log "  Removed $($Entry.Name) [$($Entry.Surface)]" 'OK'
        return 'ok'
    }
    catch {
        Write-Log "  FAILED to remove $($Entry.Name): $($_.Exception.Message)" 'ERROR'
        return 'failed'
    }
}

# --- Restore --------------------------------------------------------------
function Restore-FromBackup {
    param([string]$Path)
    if (-not (Test-PathSafe $Path)) {
        Write-Log "Backup file not found: $Path" 'ERROR'
        Stop-Run 1
    }
    $rows = @()
    try { $rows = @(Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json) }
    catch { Write-Log "Could not read backup: $($_.Exception.Message)" 'ERROR'; Stop-Run 1 }

    Write-Section "RESTORE from $Path"
    $ok = 0; $bad = 0
    foreach ($r in $rows) {
        try {
            switch ($r.Action) {
                'approved' {
                    Set-ApprovedState $r.Hive $r.Approved $r.Name ([string]$r.Before -eq 'Enabled') | Out-Null
                }
                'state' {
                    Set-ItemProperty -LiteralPath $r.Key -Name State -Value ([int]$r.Before) -Type DWord -Force
                }
                'value' {
                    Set-ItemProperty -LiteralPath "$($r.Hive):\$($r.Key)" -Name $r.Name -Value $r.Before -Force
                }
                'shortcut' {
                    Write-Log "  MANUAL $($r.Name): a deleted shortcut cannot be rebuilt; its target was '$($r.Before)'." 'WARN'
                }
                'task' {
                    if ([string]$r.Before -eq 'Enabled') { Enable-ScheduledTask -TaskName $r.Name -TaskPath $r.Key | Out-Null }
                    else { Disable-ScheduledTask -TaskName $r.Name -TaskPath $r.Key | Out-Null }
                }
            }
            Write-Log "  Restored $($r.Name) [$($r.Surface)]" 'OK'
            $ok++
        }
        catch {
            Write-Log "  FAILED $($r.Name): $($_.Exception.Message)" 'ERROR'
            $bad++
        }
    }
    Write-Log "Restored $ok, failed $bad."
    Stop-Run $(if ($bad) { 3 } else { 0 })
}

# --- Run ------------------------------------------------------------------
Write-Log "Startup app audit started. Log: $LogPath"
if (-not $script:IsAdmin) {
    Write-Log "Running unelevated: per-user entries are fully actionable; machine-wide ones are read-only." 'WARN'
}

if ($Restore) { Restore-FromBackup $Restore }

$entries = @()
$entries += Get-RunEntries
$entries += Get-FolderEntries
$entries += Get-PackagedEntries
if ($IncludeScheduledTasks) { $entries += Get-LogonTaskEntries }

foreach ($e in $entries) {
    $v = Resolve-Verdict $e
    $e.Verdict = $v[0]
    $e.Why     = $v[1]
}

Write-Section 'STARTUP CENSUS'
Write-Log "$($entries.Count) startup entries across $(($entries | Select-Object -ExpandProperty Surface -Unique).Count) surfaces."

foreach ($grp in ($entries | Group-Object Surface | Sort-Object Name)) {
    Write-Host ''
    Write-Log "--- $($grp.Name) ---" 'HEAD'
    foreach ($e in ($grp.Group | Sort-Object Name)) {
        $flag = switch ($e.Verdict) {
            'Keep'     { 'OK' }
            'Orphan'   { 'WARN' }
            'Review'   { 'WARN' }
            default    { 'INFO' }
        }
        Write-Log ("{0}  [{1}] {2}" -f $e.Name.PadRight(34), $e.Verdict.ToUpper(), $e.State) $flag
        if ($e.Identity.App -and $e.Identity.App -ne $e.Name) {
            Write-Log "        app     : $($e.Identity.App)"
        }
        Write-Log "        is      : $($e.Identity.What)"
        if ($e.Target) { Write-Log "        runs    : $($e.Target)" }
        if ($e.Facts.Company) { Write-Log "        by      : $($e.Facts.Company)  (signature: $($e.Facts.Signed))" }
        Write-Log "        cost    : $($e.Identity.Cost)"
        Write-Log "        verdict : $($e.Verdict) - $($e.Why)"
    }
}

# --- Selection ------------------------------------------------------------
function Select-Entries {
    param([string[]]$Names)
    $sel = @()
    $missed = @()
    foreach ($n in $Names) {
        $hit = @($entries | Where-Object {
            $_.Name -eq $n -or
            $_.Identity.App -eq $n -or
            ($_.Target -and [IO.Path]::GetFileName($_.Target) -eq $n) -or
            ($_.Target -and [IO.Path]::GetFileNameWithoutExtension($_.Target) -eq $n) -or
            $_.Name -like "*$n*" -or $_.Identity.App -like "*$n*"
        })
        if ($hit.Count) { $sel += $hit } else { $missed += $n }
    }
    if ($missed.Count) {
        Write-Log "No startup entry matched: $($missed -join ', ')" 'ERROR'
        Stop-Run 1
    }
    return @($sel | Sort-Object Name -Unique)
}

if ($ListOnly) {
    Write-Section 'SUMMARY'
    foreach ($v in @('Keep', 'Optional', 'Review', 'Orphan')) {
        $c = @($entries | Where-Object { $_.Verdict -eq $v }).Count
        if ($c) { Write-Log "$($v.PadRight(9)): $c" }
    }
    $optional = @($entries | Where-Object { $_.Verdict -eq 'Optional' -and $_.State -eq 'Enabled' })
    $orphans  = @($entries | Where-Object { $_.Verdict -eq 'Orphan' })
    Write-Host ''
    if ($optional.Count) {
        Write-Log "$($optional.Count) OPTIONAL entries are still enabled. To turn them all off:" 'HEAD'
        Write-Log "    .\Clean-StartupApps.ps1 -DisableOptional"
        Write-Log "  or pick them off individually, e.g.:"
        Write-Log "    .\Clean-StartupApps.ps1 -Disable $((($optional | Select-Object -First 3).Identity.App) -join ',')"
    }
    if ($orphans.Count) {
        Write-Log "$($orphans.Count) ORPHAN entries point at files that are gone:" 'WARN'
        Write-Log "    .\Clean-StartupApps.ps1 -RemoveOrphans"
    }
    Write-Log "Nothing was changed (census only)."
    Write-Log "Log written to: $LogPath"
    Stop-Run 0
}

$toDisable = @()
$toEnable  = @()
$toRemove  = @()

if ($Disable.Count) { $toDisable += Select-Entries $Disable }
if ($Enable.Count)  { $toEnable  += Select-Entries $Enable }
if ($Remove.Count)  { $toRemove  += Select-Entries $Remove }
if ($DisableOptional) {
    $toDisable += @($entries | Where-Object { $_.Verdict -eq 'Optional' -and $_.State -eq 'Enabled' })
}
if ($RemoveOrphans) {
    $toRemove += @($entries | Where-Object { $_.Verdict -eq 'Orphan' })
}

# A KEEP entry is never touched, whatever was asked for.
$protected = @($toDisable + $toRemove | Where-Object { $_.Verdict -eq 'Keep' })
foreach ($p in $protected) {
    Write-Log "REFUSE $($p.Name): $($p.Identity.What) - this one stays." 'REFUSE'
}
$toDisable = @($toDisable | Where-Object { $_.Verdict -ne 'Keep' } | Sort-Object Name -Unique)
$toRemove  = @($toRemove  | Where-Object { $_.Verdict -ne 'Keep' } | Sort-Object Name -Unique)
$toDisable = @($toDisable | Where-Object { $_.State -ne 'Disabled' })

if (-not ($toDisable.Count + $toEnable.Count + $toRemove.Count)) {
    Write-Section 'NOTHING TO DO'
    Write-Log 'Every selected entry is already in the state you asked for.'
    Write-Log "Log written to: $LogPath"
    Stop-Run 2
}

Write-Section 'PLAN'
foreach ($e in $toDisable) { Write-Log "  DISABLE  $($e.Name.PadRight(34)) $($e.Identity.What)" }
foreach ($e in $toEnable)  { Write-Log "  ENABLE   $($e.Name.PadRight(34)) $($e.Identity.What)" }
foreach ($e in $toRemove)  { Write-Log "  REMOVE   $($e.Name.PadRight(34)) $($e.Identity.What)" 'WARN' }

if (-not $Force -and -not $WhatIfPreference) {
    Write-Host ''
    $ans = Read-Host "Apply this plan? [y/N]"
    if ($ans -notmatch '^[Yy]') {
        Write-Log 'Declined at the prompt. Nothing was changed.'
        Write-Log "Log written to: $LogPath"
        Stop-Run 0
    }
}

Write-Section 'APPLY'
$failed = 0; $done = 0
foreach ($e in $toDisable) { $r = Set-EntryState $e $false; if ($r -eq 'ok') { $done++ } elseif ($r -in @('failed','refused')) { $failed++ } }
foreach ($e in $toEnable)  { $r = Set-EntryState $e $true;  if ($r -eq 'ok') { $done++ } elseif ($r -in @('failed','refused')) { $failed++ } }
foreach ($e in $toRemove)  { $r = Remove-Entry $e;          if ($r -eq 'ok') { $done++ } elseif ($r -in @('failed','refused')) { $failed++ } }

Save-Backup

Write-Section 'SUMMARY'
Write-Log "$done changed, $failed failed."
if ($script:Backup.Count) { Write-Log "Undo this run with: .\Clean-StartupApps.ps1 -Restore `"$BackupPath`"" }
Write-Log "Log written to: $LogPath"
Stop-Run $(if ($failed) { 3 } else { 0 })
