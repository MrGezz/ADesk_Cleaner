<#
.SYNOPSIS
    Reset and rebuild the Windows Search index, with throttle controls that let the
    rebuild finish in hours instead of days.

.DESCRIPTION
    Replacement for Reset_and_Rebuild_Search_Index.bat. Fixes three defects in that
    script (unbounded restart loop, missing SQLite WAL/SHM sidecars, no wait for the
    DB file lock to release) and adds the throttle settings that actually govern
    rebuild speed.

    The rebuild is slow for two reasons that a plain reset does not address:

      1. Gathering Manager\DisableBackOff = 0
         The indexer suspends itself whenever it sees user activity (keyboard,
         mouse, CPU load, disk load, battery). On a machine in daily use it makes
         very little forward progress. -Turbo sets this to 1 for the duration of
         the rebuild and -RevertTurbo puts it back.

      2. EnableFindMyFiles = 1 ("Enhanced" mode)
         Indexes entire drives rather than just the user libraries. Combined with
         large dev trees (node_modules, .git, package caches) this pushes the item
         count into the millions. Exclusions are the fix; see -Analyze.

.PARAMETER Status
    Report current configuration and index state. Changes nothing. No admin needed.

.PARAMETER Analyze
    Scan -AnalyzePath and report the folders contributing the most files, so you
    know what to exclude in Indexing Options. Changes nothing. No admin needed.

.PARAMETER Repair
    Re-enable and start the wsearch service without touching the index. Use this
    to recover from an interrupted reset that left the service stopped/disabled.

.PARAMETER TakeOwnership
    Allow writing to owner-locked keys. On Windows 11 23H2+ the
    'Gathering Manager' key sets AreAccessRulesProtected and grants
    Administrators ReadKey only; full control belongs to NT SERVICE\WSearch and
    TrustedInstaller, so even SYSTEM cannot write it. With this switch the
    script takes ownership, writes the value, then restores the original owner
    and ACL, leaving the value as the only net change. Without it, a denied
    turbo write is reported and skipped.

.PARAMETER TurboOnly
    Apply the un-throttle settings without wiping the index. Use this if the index
    is fine but is simply crawling too slowly.

.PARAMETER RevertTurbo
    Restore polite throttling. Run this once the rebuild has completed, otherwise
    the indexer keeps competing with you for CPU and disk indefinitely.

.PARAMETER NoTurbo
    Perform the reset without applying the un-throttle settings.

.PARAMETER NoMonitor
    Skip the post-reset progress monitor. Note that turbo is normally reverted
    automatically when the monitor sees the rebuild finish; with -NoMonitor you
    must run -RevertTurbo yourself.

.PARAMETER Mode
    Classic  - index user libraries only. Far fewer items, much faster.
    Enhanced - index whole drives.
    Keep     - leave the current setting alone. Default.

.PARAMETER Force
    Skip the confirmation prompt.

.EXAMPLE
    .\Reset-SearchIndex.ps1 -Status
    Show what is configured now, without changing anything.

.EXAMPLE
    .\Reset-SearchIndex.ps1 -Analyze
    Find out which folders are inflating the item count.

.EXAMPLE
    .\Reset-SearchIndex.ps1 -TurboOnly
    Stop the indexer throttling itself, without discarding the existing index.

.EXAMPLE
    .\Reset-SearchIndex.ps1
    Full reset with turbo and a live progress monitor.

.NOTES
    Derived from the reset sequence published by Shawn Brink (elevenforum.com).
    Requires elevation for everything except -Status and -Analyze; it will
    re-launch itself elevated when needed.
#>

#Requires -Version 5.1
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [switch]$Status,
    [switch]$Analyze,
    [string]$AnalyzePath = $env:USERPROFILE,
    [switch]$Repair,
    [switch]$Monitor,
    [switch]$TurboOnly,
    [switch]$RevertTurbo,
    [switch]$NoTurbo,
    [switch]$NoMonitor,
    [switch]$TakeOwnership,
    [ValidateSet('Classic', 'Enhanced', 'Keep')]
    [string]$Mode = 'Keep',
    [int]$StopTimeoutSec = 90,
    [int]$StartRetries = 6,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------- constants --

$RK_Search = 'HKLM:\SOFTWARE\Microsoft\Windows Search'
$RK_Gather = 'HKLM:\SOFTWARE\Microsoft\Windows Search\Gathering Manager'
$RK_Policy = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search'
$IndexDir  = Join-Path $env:ProgramData 'Microsoft\Search\Data\Applications\Windows'

# Processes that hold a handle on the index database. All must exit before the
# files can be deleted -- this is the step the original .bat omits.
$IndexProcs = 'SearchIndexer', 'SearchProtocolHost', 'SearchFilterHost', 'SearchApp'

# Covers both the modern SQLite index (Windows.db + WAL/SHM sidecars) and the
# legacy ESE index (Windows.edb + its transaction logs).
$DbPatterns = 'Windows.db', 'Windows.db-wal', 'Windows.db-shm',
              'Windows-gather.db', 'Windows-gather.db-wal', 'Windows-gather.db-shm',
              'Windows.edb', '*.jrs', '*.chk', 'edb*.log', 'MSS*.log'

# ------------------------------------------------------------------ helpers --

function Write-Step { param([string]$Message) Write-Host "==> $Message" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Message) Write-Host "    $Message" -ForegroundColor Green }
function Write-Warn { param([string]$Message) Write-Host "    $Message" -ForegroundColor Yellow }
function Write-Bad  { param([string]$Message) Write-Host "    $Message" -ForegroundColor Red }
function Write-Info { param([string]$Message) Write-Host "    $Message" -ForegroundColor Gray }

function Test-Elevated {
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Re-launch this script elevated, preserving the parameters it was called with.
function Invoke-SelfElevate {
    Write-Warn 'Administrator rights required. Re-launching elevated...'

    $relaunchArgs = foreach ($entry in $PSBoundParameters.GetEnumerator()) {
        if ($entry.Value -is [switch]) {
            if ($entry.Value.IsPresent) { "-$($entry.Key)" }
        }
        else {
            "-$($entry.Key)"
            "`"$($entry.Value)`""
        }
    }

    $hostExe = (Get-Process -Id $PID).Path
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit',
                 '-File', "`"$PSCommandPath`"") + $relaunchArgs

    try {
        Start-Process -FilePath $hostExe -ArgumentList $argList -Verb RunAs
    }
    catch {
        Write-Bad 'Elevation was declined. Nothing has been changed.'
        exit 1
    }
    exit 0
}

function Get-RegValue {
    param([string]$Path, [string]$Name)
    try { (Get-ItemProperty -Path $Path -Name $Name -ErrorAction Stop).$Name }
    catch { $null }
}

# Non-throwing. Returns $true on success. Callers decide whether a failure is
# fatal -- most tuning writes are not, and must never abort a reset in progress.
function Set-RegValue {
    param([string]$Path, [string]$Name, [int]$Value)
    try {
        if (-not (Test-Path $Path)) { New-Item -Path $Path -Force -ErrorAction Stop | Out-Null }
        New-ItemProperty -Path $Path -Name $Name -Value $Value `
            -PropertyType DWord -Force -ErrorAction Stop | Out-Null
        return $true
    }
    catch { return $false }
}

# Some Windows Search subkeys (notably 'Gathering Manager' on Win11 23H2+) set
# AreAccessRulesProtected and grant Administrators ReadKey only -- full control
# on the key itself belongs to NT SERVICE\WSearch and TrustedInstaller. Even
# SYSTEM cannot write there, so running as SYSTEM is not a workaround.
#
# Writing requires taking ownership, which needs SeTakeOwnershipPrivilege
# enabled in the token. PowerShell does not enable it by default.
function Enable-TokenPrivilege {
    param([string]$Privilege)

    if (-not ('IczTokenPriv' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public class IczTokenPriv
{
    [StructLayout(LayoutKind.Sequential)]
    struct LUID { public uint LowPart; public int HighPart; }

    [StructLayout(LayoutKind.Sequential)]
    struct TOKEN_PRIVILEGES { public uint PrivilegeCount; public LUID Luid; public uint Attributes; }

    [DllImport("advapi32.dll", SetLastError = true)]
    static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);

    [DllImport("advapi32.dll", SetLastError = true)]
    static extern bool LookupPrivilegeValue(string host, string name, ref LUID luid);

    [DllImport("advapi32.dll", SetLastError = true)]
    static extern bool AdjustTokenPrivileges(IntPtr token, bool disableAll,
        ref TOKEN_PRIVILEGES newState, uint length, IntPtr prev, IntPtr relen);

    [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);

    const uint SE_PRIVILEGE_ENABLED     = 0x00000002;
    const uint TOKEN_ADJUST_PRIVILEGES  = 0x00000020;
    const uint TOKEN_QUERY              = 0x00000008;
    const int  ERROR_NOT_ALL_ASSIGNED   = 1300;

    public static bool Enable(string privilege)
    {
        IntPtr token;
        if (!OpenProcessToken(GetCurrentProcess(), TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY, out token))
            return false;
        try
        {
            LUID luid = new LUID();
            if (!LookupPrivilegeValue(null, privilege, ref luid)) return false;

            TOKEN_PRIVILEGES tp = new TOKEN_PRIVILEGES();
            tp.PrivilegeCount = 1;
            tp.Luid = luid;
            tp.Attributes = SE_PRIVILEGE_ENABLED;

            if (!AdjustTokenPrivileges(token, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero))
                return false;

            // AdjustTokenPrivileges returns true even when it assigned nothing.
            return Marshal.GetLastWin32Error() != ERROR_NOT_ALL_ASSIGNED;
        }
        finally { CloseHandle(token); }
    }
}
'@ -ErrorAction SilentlyContinue
    }

    try { [IczTokenPriv]::Enable($Privilege) } catch { $false }
}

# Write a value to a key Administrators cannot write, then put the original
# owner and ACL back. Net change is the value alone -- the key does not stay
# permanently weakened.
function Set-ProtectedRegValue {
    param([string]$Path, [string]$Name, [int]$Value)

    if (Set-RegValue -Path $Path -Name $Name -Value $Value) { return $true }

    if (-not $TakeOwnership) {
        Write-Warn "$Name : access denied (key is owner-locked)."
        Write-Info 'Re-run with -TakeOwnership to write it. See -Status notes.'
        return $false
    }

    if (-not (Enable-TokenPrivilege 'SeTakeOwnershipPrivilege')) {
        Write-Bad "$Name : could not enable SeTakeOwnershipPrivilege."
        return $false
    }

    $subKey       = $Path -replace '^HKLM:\\', ''
    $admins       = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
    $originalAcl  = $null
    $originalOwner = $null

    try {
        # Capture the original state so it can be restored.
        $originalAcl   = Get-Acl $Path
        $originalOwner = $originalAcl.GetOwner([Security.Principal.SecurityIdentifier])

        # 1. Take ownership (requires only TakeOwnership rights).
        $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey(
            $subKey, [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree,
            [Security.AccessControl.RegistryRights]::TakeOwnership)
        $acl = $key.GetAccessControl([Security.AccessControl.AccessControlSections]::None)
        $acl.SetOwner($admins)
        $key.SetAccessControl($acl)
        $key.Close()

        # 2. As owner, grant Administrators full control.
        $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey(
            $subKey, [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree,
            [Security.AccessControl.RegistryRights]::ChangePermissions)
        $acl = $key.GetAccessControl()
        $acl.SetAccessRule([Security.AccessControl.RegistryAccessRule]::new(
            $admins, [Security.AccessControl.RegistryRights]::FullControl,
            [Security.AccessControl.InheritanceFlags]::None,
            [Security.AccessControl.PropagationFlags]::None,
            [Security.AccessControl.AccessControlType]::Allow))
        $key.SetAccessControl($acl)
        $key.Close()

        # 3. Write.
        $written = Set-RegValue -Path $Path -Name $Name -Value $Value
    }
    catch {
        Write-Bad "$Name : ownership takeover failed - $($_.Exception.Message)"
        $written = $false
    }
    finally {
        # 4. Restore the original ACL and owner regardless of outcome.
        if ($originalAcl) {
            try {
                $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey(
                    $subKey, [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree,
                    [Security.AccessControl.RegistryRights]::ChangePermissions -bor
                    [Security.AccessControl.RegistryRights]::TakeOwnership)
                $key.SetAccessControl($originalAcl)
                $restore = $key.GetAccessControl([Security.AccessControl.AccessControlSections]::None)
                $restore.SetOwner($originalOwner)
                $key.SetAccessControl($restore)
                $key.Close()
                Write-Info "$Name : original ACL and owner restored."
            }
            catch {
                Write-Bad "$Name : COULD NOT RESTORE ACL - $($_.Exception.Message)"
                Write-Bad "Key left with Administrators:FullControl at $Path"
            }
        }
    }

    return $written
}

function Get-IndexDbSizeMB {
    try {
        $bytes = (Get-ChildItem $IndexDir -File -Force -ErrorAction Stop |
                  Measure-Object -Property Length -Sum).Sum
        [math]::Round(($bytes / 1MB), 1)
    }
    catch { $null }
}

# ------------------------------------------------------------------- status --

function Show-Status {
    Write-Step 'Windows Search status'

    $svc = Get-Service wsearch -ErrorAction SilentlyContinue
    if ($svc) {
        Write-Info ("Service        : {0} / {1}" -f $svc.Status, $svc.StartType)
    }
    else {
        Write-Bad 'Service        : wsearch not found'
    }

    $enhanced = Get-RegValue $RK_Search 'EnableFindMyFiles'
    $modeText = switch ($enhanced) {
        1       { 'Enhanced (indexes whole drives - high item count)' }
        0       { 'Classic (user libraries only)' }
        default { 'Classic (default - EnableFindMyFiles not set)' }
    }
    Write-Info "Index mode     : $modeText"

    $backOff = Get-RegValue $RK_Gather 'DisableBackOff'
    if ($backOff -eq 1) {
        Write-Info 'Throttling     : OFF (turbo active - indexes at full speed)'
    }
    else {
        Write-Info 'Throttling     : ON (indexer pauses whenever you use the PC)'
    }

    # Report up front whether turbo is even writable on this build, rather than
    # letting the user discover it mid-reset.
    try {
        $acl = Get-Acl $RK_Gather -ErrorAction Stop
        $adminWritable = $acl.Access | Where-Object {
            $_.IdentityReference -match 'Administrators' -and
            $_.PropagationFlags -notmatch 'InheritOnly' -and
            $_.RegistryRights -match 'FullControl|SetValue|WriteKey'
        }
        if ($adminWritable) {
            Write-Info 'Turbo writable : yes'
        }
        else {
            Write-Info 'Turbo writable : NO - key is owner-locked to WSearch/TrustedInstaller'
            Write-Info '                 (needs -TakeOwnership; not even SYSTEM can write it)'
        }
    }
    catch {
        Write-Info 'Turbo writable : unknown (cannot read ACL)'
    }

    $setupDone = Get-RegValue $RK_Search 'SetupCompletedSuccessfully'
    Write-Info ("Rebuild flag   : SetupCompletedSuccessfully = {0}{1}" -f
                $setupDone, $(if ($setupDone -eq 0) { '  (rebuild pending/running)' } else { '' }))

    $sizeMB = Get-IndexDbSizeMB
    if ($null -ne $sizeMB) {
        Write-Info "Index size     : $sizeMB MB  ($IndexDir)"
    }
    else {
        Write-Info "Index size     : unreadable without elevation"
    }

    $proc = Get-Process SearchIndexer -ErrorAction SilentlyContinue
    if ($proc) {
        Write-Info ("SearchIndexer  : PID {0}, {1} MB working set" -f
                    $proc.Id, [math]::Round($proc.WorkingSet64 / 1MB))
    }
    else {
        Write-Info 'SearchIndexer  : not running'
    }

    Write-Host ''
    Write-Info 'Exact indexed item count: Indexing Options (control.exe srchadmin.dll)'
}

# ------------------------------------------------------------------ analyze --

function Show-Analysis {
    param([string]$Root)

    Write-Step "Analyzing file counts under $Root"
    Write-Info 'This walks the whole tree and can take a minute or two.'
    Write-Host ''

    $timer = [Diagnostics.Stopwatch]::StartNew()
    $total = (Get-ChildItem $Root -Recurse -File -Force -ErrorAction SilentlyContinue |
              Measure-Object).Count
    Write-Info ("Total files: {0:N0}  (scanned in {1}s)" -f $total, [math]::Round($timer.Elapsed.TotalSeconds))
    Write-Host ''

    Write-Step 'Heaviest top-level folders'
    $folders = Get-ChildItem $Root -Directory -Force -ErrorAction SilentlyContinue
    $rows = foreach ($folder in $folders) {
        $count = (Get-ChildItem $folder.FullName -Recurse -File -Force -ErrorAction SilentlyContinue |
                  Measure-Object).Count
        [pscustomobject]@{ Folder = $folder.Name; Files = $count }
    }
    $rows | Sort-Object Files -Descending | Select-Object -First 15 |
        Format-Table @{ n = 'Folder'; e = { $_.Folder }; w = 40 },
                     @{ n = 'Files';  e = { '{0:N0}' -f $_.Files }; a = 'right' } -AutoSize

    Write-Step 'Known bloat patterns (exclude these first)'
    $bloat = 'node_modules', '.git', '.venv', 'venv', '__pycache__',
             'target', 'bin', 'obj', '.gradle', '.next', 'dist'
    foreach ($name in $bloat) {
        $dirs = Get-ChildItem $Root -Recurse -Directory -Filter $name -Force -ErrorAction SilentlyContinue
        if ($dirs) {
            $files = ($dirs | ForEach-Object {
                Get-ChildItem $_.FullName -Recurse -File -Force -ErrorAction SilentlyContinue
            } | Measure-Object).Count
            Write-Info ("{0,-16} {1,4} dirs  {2,10:N0} files" -f $name, $dirs.Count, $files)
        }
    }

    Write-Host ''
    Write-Info 'Exclude these in: Indexing Options > Modify > uncheck the folder'
    Write-Info 'Windows Search has no wildcard exclusions, so exclude the parent'
    Write-Info 'dev folder, or switch to Classic mode with -Mode Classic.'
}

# -------------------------------------------------------------------- turbo --

# Never throws. A tuning failure must not abort a reset that has already
# deleted the index -- the service still has to come back up.
function Enable-Turbo {
    Write-Step 'Removing indexer throttling'
    $applied = 0

    # The indexer suspends itself on user activity unless this is set. This is
    # the single biggest factor in rebuild wall-clock time.
    if (Set-ProtectedRegValue $RK_Gather 'DisableBackOff' 1) {
        Write-Ok 'DisableBackOff = 1 (no longer pauses when you use the PC)'
        $applied++
    }

    # Do not drop to idle priority under power-saver / modern standby.
    if (Set-ProtectedRegValue $RK_Gather 'RespectPowerModes' 0) {
        Write-Ok 'RespectPowerModes = 0'
        $applied++
    }

    # Policy key; Administrators can create and write this one normally.
    if (Set-RegValue $RK_Policy 'PreventIndexOnBattery' 0) {
        Write-Ok 'PreventIndexOnBattery = 0'
        $applied++
    }
    else {
        Write-Warn 'PreventIndexOnBattery : write failed.'
    }

    Write-Host ''
    if ($applied -eq 0) {
        Write-Warn 'No throttle settings could be applied. The rebuild will still'
        Write-Warn 'run, but at reduced speed while you are using the PC.'
        return $false
    }

    Write-Warn "Turbo active ($applied of 3 settings)."
    Write-Warn 'It makes the indexer compete with you for CPU and disk.'
    Write-Warn 'Run  .\Reset-SearchIndex.ps1 -RevertTurbo  once the rebuild finishes.'
    return $true
}

function Disable-Turbo {
    Write-Step 'Restoring normal indexer throttling'

    $a = Set-ProtectedRegValue $RK_Gather 'DisableBackOff' 0
    $b = Set-ProtectedRegValue $RK_Gather 'RespectPowerModes' 1

    if ($a -or $b) { Write-Ok 'Throttling restored. The indexer will yield to you again.' }
    else           { Write-Warn 'Nothing to revert (settings were never applied).' }
}

# Raise SearchIndexer above background priority for the rebuild. Windows runs it
# in background mode, which forces the lowest I/O priority. Resets on restart.
function Set-IndexerPriority {
    try {
        $proc = Get-Process SearchIndexer -ErrorAction Stop
        $proc.PriorityClass = [Diagnostics.ProcessPriorityClass]::Normal
        Write-Ok 'SearchIndexer priority raised to Normal for this run.'
    }
    catch {
        Write-Info 'Could not raise SearchIndexer priority (it runs as SYSTEM). Skipped.'
    }
}

# ------------------------------------------------------------ service + wipe --

function Stop-SearchService {
    param([int]$TimeoutSec)

    Write-Step 'Stopping Windows Search'

    & sc.exe config wsearch start= disabled | Out-Null

    $svc = Get-Service wsearch
    if ($svc.Status -ne 'Stopped') {
        Stop-Service wsearch -Force -ErrorAction SilentlyContinue
        try   { $svc.WaitForStatus('Stopped', [TimeSpan]::FromSeconds($TimeoutSec)) }
        catch { Write-Warn 'Service did not report Stopped in time; continuing.' }
    }
    Write-Ok 'Service stopped.'

    # The service reports Stopped before SearchIndexer.exe releases its file
    # handles. Deleting the DB while those handles are open is what makes the
    # original .bat fail silently.
    Write-Info 'Waiting for index file handles to be released...'
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ($true) {
        $alive = Get-Process -Name $IndexProcs -ErrorAction SilentlyContinue
        if (-not $alive) { break }

        if ((Get-Date) -gt $deadline) {
            Write-Warn ("Force-terminating: {0}" -f (($alive.Name | Sort-Object -Unique) -join ', '))
            $alive | Stop-Process -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 3
            break
        }
        Start-Sleep -Milliseconds 500
    }
    Write-Ok 'All index processes have exited.'
}

function Remove-IndexDatabase {
    Write-Step 'Deleting index database'

    if (-not (Test-Path $IndexDir)) {
        Write-Warn "Index folder not found: $IndexDir"
        return
    }

    $targets = foreach ($pattern in $DbPatterns) {
        Get-ChildItem -Path $IndexDir -Filter $pattern -File -Force -ErrorAction SilentlyContinue
    }
    $targets = $targets | Sort-Object FullName -Unique

    if (-not $targets) {
        Write-Info 'No index files present (already reset, or never built).'
        return
    }

    $freedMB = [math]::Round((($targets | Measure-Object Length -Sum).Sum / 1MB), 1)

    foreach ($file in $targets) {
        $removed = $false
        foreach ($attempt in 1..3) {
            try {
                Remove-Item $file.FullName -Force -ErrorAction Stop
                $removed = $true
                break
            }
            catch {
                if ($attempt -eq 2) {
                    # Take ownership and grant Administrators full control, then retry.
                    & takeown.exe /F $file.FullName 2>&1 | Out-Null
                    & icacls.exe $file.FullName /grant "*S-1-5-32-544:F" 2>&1 | Out-Null
                }
                Start-Sleep -Seconds 2
            }
        }

        if ($removed) { Write-Ok "Deleted $($file.Name)" }
        else          { Write-Bad "COULD NOT DELETE $($file.Name) - still locked" }
    }

    Write-Info "Reclaimed approximately $freedMB MB."
}

function Set-RebuildFlag {
    Write-Step 'Flagging the index for a full rebuild'
    Set-RegValue $RK_Search 'SetupCompletedSuccessfully' 0
    Write-Ok 'SetupCompletedSuccessfully = 0'
}

function Set-IndexMode {
    param([string]$Requested)

    if ($Requested -eq 'Keep') { return }

    Write-Step "Setting index mode to $Requested"
    $value = if ($Requested -eq 'Enhanced') { 1 } else { 0 }
    Set-RegValue $RK_Search 'EnableFindMyFiles' $value

    if ($Requested -eq 'Classic') {
        Write-Ok 'Classic mode. Only user libraries are indexed - far fewer items.'
        Write-Info 'Files outside the libraries still appear in Explorer search,'
        Write-Info 'but those searches fall back to a slower live scan.'
    }
    else {
        Write-Ok 'Enhanced mode. Whole drives are indexed - expect a long rebuild.'
    }
}

function Start-SearchService {
    param([int]$Retries)

    Write-Step 'Restarting Windows Search'
    & sc.exe config wsearch start= delayed-auto | Out-Null

    # Bounded retry with backoff. The original .bat looped on this forever with
    # no delay, which spins the CPU indefinitely if the start can never succeed.
    for ($attempt = 1; $attempt -le $Retries; $attempt++) {
        try {
            Start-Service wsearch -ErrorAction Stop
            Start-Sleep -Seconds 2
            if ((Get-Service wsearch).Status -eq 'Running') {
                Write-Ok "Service running (attempt $attempt)."
                return $true
            }
        }
        catch {
            Write-Warn "Start attempt $attempt of $Retries failed: $($_.Exception.Message)"
        }

        if ($attempt -lt $Retries) {
            $wait = [math]::Min(30, [math]::Pow(2, $attempt))
            Write-Info "Retrying in $wait seconds..."
            Start-Sleep -Seconds $wait
        }
    }

    Write-Bad "Service failed to start after $Retries attempts."
    Write-Info 'Check the System event log, then try: sc.exe start wsearch'
    return $false
}

# ------------------------------------------------------------------ monitor --

function Watch-Rebuild {
    Write-Step 'Monitoring rebuild progress'
    Write-Info 'Press Ctrl+C to stop watching. The rebuild continues regardless.'
    Write-Host ''

    $lastSize   = 0
    $stableFor  = 0
    $started    = Get-Date

    while ($true) {
        Start-Sleep -Seconds 30

        $sizeMB  = Get-IndexDbSizeMB
        if ($null -eq $sizeMB) { $sizeMB = 0 }
        $delta   = [math]::Round($sizeMB - $lastSize, 1)
        $elapsed = (Get-Date) - $started
        $clock   = '{0:hh\:mm\:ss}' -f $elapsed

        $running = $null -ne (Get-Process SearchIndexer -ErrorAction SilentlyContinue)

        if (-not $running) {
            Write-Warn "[$clock] SearchIndexer is not running. Rebuild is not progressing."
        }
        elseif ($delta -gt 0.1) {
            Write-Info ("[{0}] index {1} MB  (+{2} MB / 30s)" -f $clock, $sizeMB, $delta)
            $stableFor = 0
        }
        else {
            $stableFor++
            Write-Info ("[{0}] index {1} MB  (no growth, {2} consecutive)" -f $clock, $sizeMB, $stableFor)
        }

        $lastSize = $sizeMB

        # Heuristic: 10 consecutive samples (5 minutes) with no database growth,
        # with a non-trivial index present, means the crawl has drained.
        if ($stableFor -ge 10 -and $sizeMB -gt 50) {
            Write-Host ''
            Write-Ok "Index appears complete after $clock (no growth for 5 minutes)."
            Write-Info 'Confirm the item count in Indexing Options.'
            return $true
        }
    }
}

# --------------------------------------------------------------------- main --

Write-Host ''
Write-Host '  Windows Search - Reset and Rebuild' -ForegroundColor White
Write-Host '  ----------------------------------' -ForegroundColor DarkGray
Write-Host ''

# Read-only modes: no elevation required, no changes made.
if ($Analyze) { Show-Analysis -Root $AnalyzePath; return }
if ($Status)  { Show-Status; return }

if (-not (Test-Elevated)) { Invoke-SelfElevate }

# Watch a rebuild that is already running, without resetting anything. Needs
# elevation because the index directory is not readable otherwise.
if ($Monitor) {
    $svc = Get-Service wsearch -ErrorAction SilentlyContinue
    if (-not $svc -or $svc.Status -ne 'Running') {
        Write-Bad 'Windows Search is not running; there is nothing to monitor.'
        Write-Info 'Start it with:  .\Reset-SearchIndex.ps1 -Repair'
        exit 1
    }
    Watch-Rebuild | Out-Null
    return
}

# Recovery path: re-enable and start the service without touching the index.
# Use after any interrupted reset that left wsearch stopped or disabled.
if ($Repair) {
    Write-Step 'Repairing Windows Search service state'

    $svc = Get-Service wsearch -ErrorAction SilentlyContinue
    if (-not $svc) {
        Write-Bad 'The wsearch service is not registered on this system.'
        exit 1
    }
    Write-Info "Before: $($svc.Status) / $($svc.StartType)"

    if (Start-SearchService -Retries $StartRetries) {
        $svc = Get-Service wsearch
        Write-Host ''
        Write-Ok "Service is $($svc.Status) / $($svc.StartType)."

        if ((Get-RegValue $RK_Search 'SetupCompletedSuccessfully') -eq 0) {
            Write-Info 'Rebuild flag is set, so indexing is running from scratch.'
        }
        Write-Info 'Watch progress with:  .\Reset-SearchIndex.ps1 -Status'
    }
    else {
        Write-Bad 'Could not start the service. Check the System event log.'
        exit 1
    }
    return
}

if ($RevertTurbo) {
    Disable-Turbo
    Write-Host ''
    Write-Info 'Restart Windows Search for this to take effect:  Restart-Service wsearch'
    return
}

if ($TurboOnly) {
    Enable-Turbo
    Write-Step 'Restarting Windows Search to apply'
    Restart-Service wsearch -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3
    Set-IndexerPriority
    Write-Host ''
    Write-Ok 'Done. The existing index was kept; only throttling changed.'
    return
}

# --- full reset ---

Show-Status
Write-Host ''

if (-not $Force) {
    Write-Warn 'This deletes the search index. Search results will be incomplete'
    Write-Warn 'until the rebuild finishes, which can take hours on a large scope.'
    Write-Host ''
    $answer = Read-Host '    Continue? [y/N]'
    if ($answer -notmatch '^(y|yes)$') {
        Write-Info 'Cancelled. Nothing was changed.'
        return
    }
    Write-Host ''
}

if (-not $PSCmdlet.ShouldProcess('Windows Search index', 'Reset and rebuild')) { return }

# Once the service is stopped and the database deleted, bringing the service
# back up is an obligation, not a step. Everything destructive goes in the try;
# the restart goes in the finally so it runs on every path, including an
# unexpected throw. An earlier version applied tuning settings between the
# delete and the restart without this guard -- a denied registry write then
# stranded the machine with no index and a disabled service.
$serviceStarted = $false

try {
    Stop-SearchService -TimeoutSec $StopTimeoutSec
    Remove-IndexDatabase
    Set-RebuildFlag
    Set-IndexMode -Requested $Mode

    # Applied while stopped so the gatherer picks it up on start. Enable-Turbo
    # is non-throwing by contract; a denied write warns and continues.
    if (-not $NoTurbo) { Enable-Turbo | Out-Null }
}
finally {
    $serviceStarted = Start-SearchService -Retries $StartRetries
}

if (-not $serviceStarted) {
    Write-Host ''
    Write-Bad 'The index was reset but the service is NOT running.'
    Write-Info 'Recover with:  .\Reset-SearchIndex.ps1 -Repair'
    exit 1
}

Start-Sleep -Seconds 5
if (-not $NoTurbo) { Set-IndexerPriority }

Write-Host ''
Write-Ok 'Reset complete. The rebuild is now running.'
Write-Host ''

if ($NoMonitor) {
    if (-not $NoTurbo) {
        Write-Warn 'Turbo is still active. Run -RevertTurbo when the rebuild finishes.'
    }
    return
}

$finished = Watch-Rebuild

if ($finished -and -not $NoTurbo) {
    Write-Host ''
    Disable-Turbo
    Restart-Service wsearch -Force -ErrorAction SilentlyContinue
    Write-Ok 'Turbo reverted automatically.'
}
