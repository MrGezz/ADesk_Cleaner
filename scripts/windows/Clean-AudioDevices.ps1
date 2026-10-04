<#
.SYNOPSIS
    Remove the audio endpoints Windows keeps for hardware and drivers that are
    gone, so Settings > Sound > All sound devices lists only real devices.

.DESCRIPTION
    Windows keeps one registry key per audio endpoint it has ever built, under
    HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\{Render|Capture}.
    The Sound settings page lists every one of them and shows the not-present
    ones as Disabled (Disconnected on some builds). On an install carried from
    machine to machine, or through several drivers, most of the list is ghosts.

    What is removed is decided by state and location, never by name:

      * Only endpoints whose DeviceState (low 4 bits) is NOTPRESENT (4) are
        candidates. Active, user-disabled and unplugged endpoints are never
        touched.
      * A candidate goes when its parent device no longer exists at all, or
        when the parent is built-in hardware on a fixed bus (HDAUDIO,
        INTELAUDIO, PCI, ACPI) carrying the "this PC" container id.
      * A parent on USB, Bluetooth or a software bus (ROOT, SW, SWD) that still
        exists is kept: there "not present" means unplugged, or an app such as
        SteelSeries GG not running. So is an external parent (a Thunderbolt
        dock or an eGPU) and anything on an unknown bus.

    Windows' endpoint builder rebuilds an endpoint for every port the current
    drivers expose, each time the audio service starts. Entries labelled
    port-still-exposed therefore come back under a new id after removal; the
    run reports them by name as rebuilt by Windows. -KeepExposedPorts leaves
    them alone.

    Administrators cannot delete these keys: only SYSTEM, TrustedInstaller and
    the two audio services can. The script never changes an ACL. It opens each
    key with backup semantics (SeRestorePrivilege), deletes it with NtDeleteKey,
    and backs it up first with "reg save", whose hive file keeps the key's
    security descriptor so -Restore puts it back exactly.

    The audio services are stopped while keys are deleted, because a running
    endpoint builder rewrites them. Expect about ten seconds without sound.

    Also removed, unless -SkipAppSettings: the ghost SWD\MMDEVAPI devnodes of
    removed endpoints, and per-app audio settings (volume and chosen device per
    app) that point at built-in hardware which is no longer present.

    Out of scope: driver-store packages and phantom PCI devnodes of old
    hardware - see Remove-LegacyHardwareResidue.ps1 -Scope Platform,Audio.

.PARAMETER ListOnly
    Census only. The default when neither -Clean nor -Restore is given. Shows
    every endpoint with its verdict and label, and the per-app settings counts.
    Changes nothing and needs no elevation.

.PARAMETER Clean
    Remove the selected endpoints, their ghost devnodes and the dead per-app
    settings. Self-elevates.

.PARAMETER KeepExposedPorts
    With -Clean: keep the endpoints labelled port-still-exposed (and, when the
    enabled-interface query failed, those labelled unknown).

.PARAMETER SkipAppSettings
    With -Clean: leave the per-app audio settings alone.

.PARAMETER Restore
    Path of a manifest.json written by an earlier -Clean. Puts back every
    endpoint key and per-app setting it removed that does not exist now.
    Self-elevates.

.PARAMETER CreateRestorePoint
    Create a System Restore point before changing anything. Windows refuses a
    second one within 24 hours; that is reported, not failed.

.PARAMETER Force
    Skip the confirmation prompt.

.PARAMETER LogPath
    Transcript path. Defaults to %TEMP%\AudioDevices_<yyyyMMdd_HHmmss>.log.

.PARAMETER BackupPath
    Backup folder. Defaults to %TEMP%\AudioDevices_<same stamp>.

.PARAMETER TargetSid
    Internal. The SID of the user whose per-app audio settings are pruned.
    Captured before self-elevation and relayed across the UAC boundary, so that
    elevating through a different administrator account still prunes the
    invoking user's settings, not the administrator's.

.EXAMPLE
    .\Clean-AudioDevices.ps1
    Census: every endpoint, what it is, and what -Clean would do. No elevation.

.EXAMPLE
    .\Clean-AudioDevices.ps1 -Clean -WhatIf
    The exact plan of a clean run, changing nothing.

.EXAMPLE
    .\Clean-AudioDevices.ps1 -Clean
    Back up, then remove every not-present endpoint the rules select.

.EXAMPLE
    .\Clean-AudioDevices.ps1 -Clean -KeepExposedPorts
    The same, keeping the ports the current drivers still expose.

.EXAMPLE
    .\Clean-AudioDevices.ps1 -Restore "$env:TEMP\AudioDevices_20261005_101500\manifest.json"
    Put back everything that run removed.

.NOTES
    Exit codes (shared with the other scripts in this repository):

      0     Success. Entries Windows rebuilt are reported, not failures.
      3010  Success; pnputil asked for a restart.
      2     Nothing to do.
      3     Partial: a delete, devnode, prune or restore failed, a check after
            the run failed, or the audio services did not restart.
      1     Aborted: invalid combination of switches, elevation declined,
            -WhatIf could not be relayed, invalid path, backup failed, manifest
            missing or written on another computer.
#>

#Requires -Version 5.1
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [switch]$ListOnly,
    [switch]$Clean,
    [switch]$KeepExposedPorts,
    [switch]$SkipAppSettings,
    [string]$Restore,
    [switch]$CreateRestorePoint,
    [switch]$Force,
    [string]$LogPath,
    [string]$BackupPath,
    [string]$TargetSid
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# --- Classification ---------------------------------------------------------
# Everything in this section is pure: no registry access, no script-scope
# state. The test harness drives these functions with synthetic records, so a
# function here that reached for a global would pass the tests and still be
# wrong at run time.

# StrictMode-safe property reader: the value, or $null - never a throw. A
# registry key with no values makes Get-ItemProperty return $null without
# throwing, and dereferencing .PSObject on that $null ends the whole
# enumeration under Set-StrictMode -Version Latest.
function Get-Prop {
    param($Obj, [string]$Name)
    if ($null -eq $Obj) { return $null }
    $p = $Obj.PSObject.Properties[$Name]
    if ($null -ne $p) { return $p.Value }
    return $null
}

# Fixed buses carry built-in hardware, so a not-present endpoint there belongs
# to a port or a driver that is gone. On removable and software buses "not
# present" only means unplugged, or the owning app (SteelSeries GG for Sonar)
# not running - removing those would cost the user their device settings.
function Get-AudioBusClass {
    param([string]$Bus)
    if ([string]::IsNullOrWhiteSpace($Bus)) { return 'Unknown' }
    $b = $Bus.ToUpperInvariant()
    if (@('HDAUDIO', 'INTELAUDIO', 'PCI', 'ACPI') -contains $b) { return 'Fixed' }
    if (@('USB', 'BTHENUM', 'BTHHFENUM', 'BTHLEDEVICE', 'ROOT', 'SW', 'SWD') -contains $b) { return 'Removable' }
    return 'Unknown'
}

# What the verdict needs to know beyond one record: which driver interfaces are
# enabled right now ($null = could not be read), and which interfaces a live
# endpoint (active, disabled or unplugged) already holds. A not-present endpoint
# on an enabled interface that nothing live holds is a port the driver still
# exposes, and the endpoint builder rebuilds it after deletion.
function New-AudioClassifierContext {
    param([object[]]$Records, [string[]]$EnabledInterfaces)
    $cmp = [StringComparer]::OrdinalIgnoreCase
    $enabled = $null
    if ($null -ne $EnabledInterfaces) {
        $enabled = [System.Collections.Generic.HashSet[string]]::new($cmp)
        foreach ($i in $EnabledInterfaces) { if ($i) { [void]$enabled.Add($i) } }
    }
    $live = [System.Collections.Generic.HashSet[string]]::new($cmp)
    foreach ($r in @($Records)) {
        $state = Get-Prop $r 'State'
        if ($null -eq $state) { continue }
        if (@(1, 2, 8) -contains ((([int64]$state) -band 0xF))) {
            foreach ($ref in @(Get-Prop $r 'InterfaceRefs')) { if ($ref) { [void]$live.Add($ref) } }
        }
    }
    [pscustomobject]@{ Enabled = $enabled; LiveRefs = $live }
}

# The removal rule. The first matching step decides; every doubt is a Keep.
# Only the low 4 bits of DeviceState are the documented DEVICE_STATE_* value
# (1 active, 2 disabled, 4 not present, 8 unplugged); Windows sets undocumented
# high bits (0x10000000, 0x20000000, 0x01000000) that carry no meaning here.
function Get-AudioEndpointVerdict {
    param($Record, $Context)
    $keep   = { param($Label, $Why) [pscustomobject]@{ Action = 'Keep';   Label = $Label; Reason = $Why } }
    $remove = { param($Label, $Why) [pscustomobject]@{ Action = 'Remove'; Label = $Label; Reason = $Why } }

    if ($null -eq $Record) { return & $keep 'malformed' 'no endpoint record' }
    $state = Get-Prop $Record 'State'
    if ($null -eq $state) { return & $keep 'malformed' 'DeviceState is missing' }
    $low = ([int64]$state) -band 0xF
    if (@(1, 2, 4, 8) -notcontains $low) {
        return & $keep 'malformed' ('DeviceState 0x{0:X} is not a documented state' -f ([int64]$state))
    }
    if ($low -ne 4) {
        $what = @{ 1 = 'active'; 2 = 'disabled by the user'; 8 = 'unplugged' }[[int]$low]
        return & $keep 'live' "endpoint is $what"
    }

    $parent = [string](Get-Prop $Record 'ParentId')
    if ([string]::IsNullOrWhiteSpace($parent)) { return & $keep 'malformed' 'no parent device recorded' }
    if (-not [bool](Get-Prop $Record 'ParentExists')) { return & $remove 'orphaned' "parent $parent no longer exists" }

    $bus = [string](Get-Prop $Record 'ParentBus')
    $class = Get-AudioBusClass $bus
    if ($class -eq 'Removable') { return & $keep 'removable-not-connected' "parent on $bus still exists; not present there means not connected" }
    if ($class -ne 'Fixed') { return & $keep 'unknown-bus' "parent bus '$bus' is not one this script recognises" }

    # Built-in devices carry the "this PC" container. A Thunderbolt dock or an
    # eGPU sits on HDAUDIO too, but carries its own container and comes back.
    $container = [string](Get-Prop $Record 'ParentContainerId')
    if (-not [string]::Equals($container, '{00000000-0000-0000-ffff-ffffffffffff}', [StringComparison]::OrdinalIgnoreCase)) {
        return & $keep 'external-not-connected' "parent container '$container' is not this PC"
    }

    # Read the sets straight off the context: returning a HashSet from a
    # function would unroll it into an array and lose its comparer.
    $enabled = $null; $liveRefs = $null
    if ($null -ne $Context) {
        $p = $Context.PSObject.Properties['Enabled'];  if ($p) { $enabled  = $p.Value }
        $p = $Context.PSObject.Properties['LiveRefs']; if ($p) { $liveRefs = $p.Value }
    }
    if ($null -eq $enabled) { return & $remove 'unknown' 'the enabled driver interfaces could not be read' }
    $refs = @(@(Get-Prop $Record 'InterfaceRefs') | Where-Object { $_ })
    if ($refs.Count -eq 0) {
        # Measured: an endpoint that records no interface but was built by the
        # driver the device runs NOW (same name) is a port that driver still
        # exposes - Realtek's multi-jack endpoints came back after removal. One
        # built under another driver (the generic "High Definition Audio Device")
        # stayed gone.
        $iface = [string](Get-Prop $Record 'InterfaceName')
        $parentName = [string](Get-Prop $Record 'ParentName')
        if ($iface -and $parentName -and [string]::Equals($iface, $parentName, [StringComparison]::OrdinalIgnoreCase)) {
            return & $remove 'port-still-exposed' "built by the current driver ($parentName); Windows will rebuild it"
        }
        return & $remove 'no-interface-recorded' 'no driver interface recorded, and built under another driver'
    }

    $held = @($refs | Where-Object { $null -ne $liveRefs -and $liveRefs.Contains($_) })
    $exposed = @($refs | Where-Object { $enabled.Contains($_) -and -not ($null -ne $liveRefs -and $liveRefs.Contains($_)) })
    if ($exposed.Count) { return & $remove 'port-still-exposed' 'the current driver still exposes this port; Windows will rebuild it' }
    if ($held.Count)    { return & $remove 'duplicate' 'a live endpoint already holds this port' }
    return & $remove 'interface-gone' 'the driver interface it was built from is no longer enabled'
}

# PnP stores many names as resource strings - '@oem17.inf,%Key%;Realtek(R) Audio' -
# whose readable form is the text after the last semicolon.
function ConvertFrom-PnpResourceString {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return $null }
    if ($Text.StartsWith('@') -and $Text.Contains(';')) { return $Text.Substring($Text.LastIndexOf(';') + 1) }
    return $Text
}

# Whether a verdict is acted on. -KeepExposedPorts also keeps 'unknown',
# because without the enabled-interface list an exposed port cannot be told
# apart from a dead one.
function Test-AudioRemovalSelected {
    param([Parameter(Position = 0)]$Verdict, [switch]$KeepExposedPorts)
    if ($null -eq $Verdict) { return $false }
    if ((Get-Prop $Verdict 'Action') -ne 'Remove') { return $false }
    if ($KeepExposedPorts -and @('port-still-exposed', 'unknown') -contains (Get-Prop $Verdict 'Label')) { return $false }
    return $true
}

# The only key shape the endpoint deleter may ever be pointed at: one endpoint
# GUID directly under Render or Capture. Never the container keys, never a
# subkey, never another hive.
function Test-AudioEndpointKeyPath {
    param([string]$Path)
    if ([string]::IsNullOrEmpty($Path)) { return $false }
    return $Path -match '^HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\MMDevices\\Audio\\(Render|Capture)\\\{[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\}$'
}

# The PnP devnode the endpoint builder creates for an endpoint. Derived, not
# read: measured, some endpoints (the AMD HDMI ones here) record no SWD id even
# though their devnode exists.
function Get-SwdInstanceId {
    param([string]$Flow, [string]$Guid)
    if ($Guid -notmatch '^\{[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\}$') { return $null }
    switch ($Flow) {
        'Render'  { return "SWD\MMDEVAPI\{0.0.0.00000000}.$Guid" }
        'Capture' { return "SWD\MMDEVAPI\{0.0.1.00000000}.$Guid" }
    }
    return $null
}

# A per-app setting names its device as '{n}.\\?\<bus>#<hardware-id>#{category}\<filter>...|<app>'.
# The value carries no instance segment, so presence is judged on bus + hardware id.
function ConvertFrom-AppAudioDevicePath {
    param([string]$Value)
    if ([string]::IsNullOrEmpty($Value)) { return $null }
    if ($Value -notmatch '^\{\d+\}\.\\\\\?\\(?<bus>[^#\\]+)#(?<hwid>[^#\\]+)#') { return $null }
    return [pscustomobject]@{ Bus = $Matches['bus'].ToLowerInvariant(); HardwareId = $Matches['hwid'].ToLowerInvariant() }
}

# A per-app setting goes only when it points at built-in hardware (hdaudio,
# intelaudio) that no present device matches. Anything else - USB, Bluetooth,
# software devices, an unexpected shape, or no presence list - is kept.
function Get-AppAudioSettingVerdict {
    param($Record, $PresentPrefixes)
    $keep   = { param($Label, $Why) [pscustomobject]@{ Action = 'Keep';   Label = $Label; Reason = $Why } }
    $remove = { param($Label, $Why) [pscustomobject]@{ Action = 'Remove'; Label = $Label; Reason = $Why } }

    if ($null -eq $Record) { return & $keep 'unexpected-shape' 'no record' }
    $value = Get-Prop $Record 'Value'
    if ($null -eq $value -or [int](Get-Prop $Record 'ValueCount') -ne 1) {
        return & $keep 'unexpected-shape' 'not exactly one default value'
    }
    # Measured: an entry may carry one subkey, {219ED5A0-9CBF-4F3A-B927-37C9E5C5F14F},
    # holding that app's stored volume and mute as plain values. Any other subkey,
    # or one with nested keys or value kinds the backup cannot write, is kept.
    $subCount = [int](Get-Prop $Record 'SubKeyCount')
    if ($subCount -gt 0) {
        $names = @(Get-Prop $Record 'SubKeyNames')
        $known = '{219ED5A0-9CBF-4F3A-B927-37C9E5C5F14F}'
        if ($subCount -ne 1 -or $names.Count -ne 1 -or -not [string]::Equals([string]$names[0], $known, [StringComparison]::OrdinalIgnoreCase) -or
            -not [bool](Get-Prop $Record 'SubKeyShapeOk')) {
            return & $keep 'unexpected-shape' 'carries a subkey other than the per-app volume store'
        }
    }
    $parsed = ConvertFrom-AppAudioDevicePath ([string]$value)
    if ($null -eq $parsed) { return & $keep 'unparseable' 'the device part of the value could not be read' }
    if (@('hdaudio', 'intelaudio') -notcontains $parsed.Bus) { return & $keep 'not-fixed-bus' "device on $($parsed.Bus) may be reconnected" }
    if ($null -eq $PresentPrefixes) { return & $keep 'presence-unknown' 'the list of present devices could not be read' }
    $prefix = ('{0}\{1}' -f $parsed.Bus, $parsed.HardwareId).ToUpperInvariant()
    if ($PresentPrefixes.Contains($prefix)) { return & $keep 'hardware-present' "device $prefix is present" }
    return & $remove 'hardware-gone' "no present device matches $prefix"
}

# --- Native layer -----------------------------------------------------------
# The endpoint keys are owned by SYSTEM, and only SYSTEM's audio services and
# TrustedInstaller may delete them; Administrators hold SetValue + ReadKey.
# Taking ownership was rejected: .NET's SetAccessControl calls SetSecurityInfo,
# which pushes inheritable ACEs down to every child, and fails part-way on
# children an administrator cannot WRITE_DAC. Instead each key is opened with
# REG_OPTION_BACKUP_RESTORE under SeBackupPrivilege + SeRestorePrivilege, which
# grants KEY_READ + DELETE + KEY_WRITE whatever the ACL says, and deleted by
# handle with NtDeleteKey. No ACL is ever changed, so an interrupted run cannot
# leave a weakened key behind.

function Initialize-IczAudioNative {
    if ('IczAudioNative' -as [type]) { return }
    Add-Type -ErrorAction Stop -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public static class IczAudioNative
{
    static readonly UIntPtr HKLM = new UIntPtr(0x80000002u);
    const int REG_OPTION_BACKUP_RESTORE = 0x4;
    const int REG_FORCE_RESTORE = 0x8;
    const int REG_OPENED_EXISTING_KEY = 2;
    const int ERROR_ALREADY_EXISTS = 183;
    const int ERROR_NO_MORE_ITEMS = 259;
    const int ERROR_NOT_ALL_ASSIGNED = 1300;
    const int CR_BUFFER_SMALL = 0x1A;
    const uint SE_PRIVILEGE_ENABLED = 0x2;
    const uint TOKEN_ADJUST_PRIVILEGES = 0x20;
    const uint TOKEN_QUERY = 0x8;

    [StructLayout(LayoutKind.Sequential)] struct LUID { public uint LowPart; public int HighPart; }
    [StructLayout(LayoutKind.Sequential)] struct TOKEN_PRIVILEGES { public uint PrivilegeCount; public LUID Luid; public uint Attributes; }

    [DllImport("advapi32.dll", SetLastError = true)]
    static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);
    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool LookupPrivilegeValue(string host, string name, ref LUID luid);
    [DllImport("advapi32.dll", SetLastError = true)]
    static extern bool AdjustTokenPrivileges(IntPtr token, bool disableAll, ref TOKEN_PRIVILEGES newState, uint length, IntPtr prev, IntPtr relen);
    [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode)]
    static extern int RegOpenKeyExW(UIntPtr hKey, string subKey, int options, int samDesired, out IntPtr result);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode)]
    static extern int RegCreateKeyExW(UIntPtr hKey, string subKey, int reserved, string cls, int options, int samDesired, IntPtr security, out IntPtr result, out int disposition);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode)]
    static extern int RegEnumKeyExW(IntPtr hKey, int index, StringBuilder name, ref int nameLen, IntPtr reserved, IntPtr cls, IntPtr clsLen, IntPtr lastWrite);
    [DllImport("advapi32.dll")] static extern int RegCloseKey(IntPtr hKey);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode)]
    static extern int RegRestoreKeyW(IntPtr hKey, string file, int flags);
    [DllImport("ntdll.dll")] static extern int NtDeleteKey(IntPtr keyHandle);

    [DllImport("cfgmgr32.dll", CharSet = CharSet.Unicode)]
    static extern int CM_Get_Device_Interface_List_SizeW(out int len, ref Guid cls, string deviceId, int flags);
    [DllImport("cfgmgr32.dll", CharSet = CharSet.Unicode)]
    static extern int CM_Get_Device_Interface_ListW(ref Guid cls, string deviceId, char[] buffer, int len, int flags);

    // AdjustTokenPrivileges returns true even when it assigned nothing; only
    // GetLastError tells ERROR_NOT_ALL_ASSIGNED apart from success.
    public static bool EnablePrivilege(string name)
    {
        IntPtr token;
        if (!OpenProcessToken(GetCurrentProcess(), TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY, out token)) return false;
        try
        {
            LUID luid = new LUID();
            if (!LookupPrivilegeValue(null, name, ref luid)) return false;
            TOKEN_PRIVILEGES tp = new TOKEN_PRIVILEGES();
            tp.PrivilegeCount = 1; tp.Luid = luid; tp.Attributes = SE_PRIVILEGE_ENABLED;
            if (!AdjustTokenPrivileges(token, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero)) return false;
            return Marshal.GetLastWin32Error() != ERROR_NOT_ALL_ASSIGNED;
        }
        finally { CloseHandle(token); }
    }

    // Deepest first: NtDeleteKey only deletes a key that has no subkeys.
    // Returns 0, a Win32 error from the open/enumerate, or the NTSTATUS of the delete.
    public static int DeleteTreeBackupSemantics(string hklmSubKey)
    {
        IntPtr h;
        int rc = RegOpenKeyExW(HKLM, hklmSubKey, REG_OPTION_BACKUP_RESTORE, 0, out h);
        if (rc != 0) return rc;
        try
        {
            List<string> children = new List<string>();
            for (int i = 0; ; i++)
            {
                StringBuilder sb = new StringBuilder(256);
                int len = sb.Capacity;
                int e = RegEnumKeyExW(h, i, sb, ref len, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
                if (e == ERROR_NO_MORE_ITEMS) break;
                if (e != 0) return e;
                children.Add(sb.ToString());
            }
            foreach (string child in children)
            {
                int r = DeleteTreeBackupSemantics(hklmSubKey + "\\" + child);
                if (r != 0) return r;
            }
            return NtDeleteKey(h);
        }
        finally { RegCloseKey(h); }
    }

    // Creates the key with backup semantics and loads a "reg save" hive into it
    // through the SAME handle. reg.exe's own restore re-opens the new key with an
    // ACL-checked handle, and a key under Render/Capture inherits an ACL that
    // denies administrators write access - so the restore must stay in-process.
    // RegRestoreKey also restores each key's security descriptor from the hive.
    // An existing key is an error, never overwritten.
    public static int RestoreKeyBackupSemantics(string hklmSubKey, string hiveFile)
    {
        IntPtr h; int disposition;
        int rc = RegCreateKeyExW(HKLM, hklmSubKey, 0, null, REG_OPTION_BACKUP_RESTORE, 0, IntPtr.Zero, out h, out disposition);
        if (rc != 0) return rc;
        try
        {
            if (disposition == REG_OPENED_EXISTING_KEY) return ERROR_ALREADY_EXISTS;
            return RegRestoreKeyW(h, hiveFile, REG_FORCE_RESTORE);
        }
        finally { RegCloseKey(h); }
    }

    // Interfaces of the given class that are enabled right now (the list can grow
    // between the size call and the read; retried).
    public static string[] GetPresentInterfaces(Guid category)
    {
        for (int attempt = 0; attempt < 3; attempt++)
        {
            int len;
            int cr = CM_Get_Device_Interface_List_SizeW(out len, ref category, null, 0);
            if (cr != 0) return null;
            char[] buffer = new char[len];
            cr = CM_Get_Device_Interface_ListW(ref category, null, buffer, len, 0);
            if (cr == CR_BUFFER_SMALL) continue;
            if (cr != 0) return null;
            List<string> list = new List<string>();
            StringBuilder sb = new StringBuilder();
            foreach (char ch in buffer)
            {
                if (ch == '\0') { if (sb.Length == 0) break; list.Add(sb.ToString()); sb.Length = 0; }
                else sb.Append(ch);
            }
            return list.ToArray();
        }
        return null;
    }
}
'@
}

# Both privileges, or neither is good enough: backup semantics without
# SeRestorePrivilege opens the key read-only and the delete then fails.
function Enable-AudioPrivileges {
    Initialize-IczAudioNative
    $backup  = [IczAudioNative]::EnablePrivilege('SeBackupPrivilege')
    $restore = [IczAudioNative]::EnablePrivilege('SeRestorePrivilege')
    return ($backup -and $restore)
}

function ConvertTo-HklmSubKey {
    param([string]$Path)
    if ([string]::IsNullOrEmpty($Path)) { return $null }
    if ($Path -match '^(?i)HKLM:\\(?<sub>.+)$') { return $Matches['sub'] }
    return $null
}

# The only keys the backup-semantics deleter and creator may touch: one audio
# endpoint GUID key, or the scratch tree the mechanism test builds. This guard
# lives inside both functions, so no future call site can aim them elsewhere.
function Test-AudioMechanismRoot {
    param([string]$SubKey)
    if ([string]::IsNullOrEmpty($SubKey)) { return $false }
    if ($SubKey -match '^SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\MMDevices\\Audio\\(Render|Capture)\\\{[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\}$') { return $true }
    return ($SubKey -match '^SOFTWARE\\IczAudioMechanismTest(\\[^\\]+)*$')
}

function Remove-RegistryTreeBackupSemantics {
    param([string]$SubKey)
    $result = { param($Ok, $Code, $Message) [pscustomobject]@{ Ok = $Ok; Code = $Code; Message = $Message } }
    if (-not (Test-AudioMechanismRoot $SubKey)) { return & $result $false -1 "refused: HKLM\$SubKey is not an audio endpoint key" }
    if (-not (Enable-AudioPrivileges)) { return & $result $false -1 'could not enable SeBackupPrivilege and SeRestorePrivilege' }
    $code = [IczAudioNative]::DeleteTreeBackupSemantics($SubKey)
    if ($code -ne 0) { return & $result $false $code ('delete of HKLM\{0} failed: 0x{1:X8}' -f $SubKey, $code) }
    if (Test-Path -LiteralPath "HKLM:\$SubKey") { return & $result $false -1 "HKLM\$SubKey still exists after the delete" }
    return & $result $true 0 'deleted'
}

# Windows PowerShell 5.1 turns every stderr line of a native command into an
# ErrorRecord under 2>&1, and with $ErrorActionPreference = 'Stop' the first
# one throws - before the exit code can be read. Native tools run through here.
function Invoke-NativeCommand {
    param([string]$FilePath, [string[]]$Arguments)
    $saved = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $out = @(& $FilePath @Arguments 2>&1 | ForEach-Object { "$_" })
        $code = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $saved }
    return [pscustomobject]@{ Code = $code; Output = ($out -join ' ') }
}

# "reg save" writes a hive file that keeps every value, every subkey and every
# key's security descriptor - the only backup a restore can reproduce exactly.
function Save-AudioRegistryHive {
    param([string]$SubKey, [string]$File)
    $r = Invoke-NativeCommand -FilePath 'reg.exe' -Arguments @('save', "HKLM\$SubKey", $File, '/y')
    if ($r.Code -ne 0) { Write-Verbose ("reg save HKLM\{0}: {1}" -f $SubKey, $r.Output); return $false }
    return ((Test-Path -LiteralPath $File) -and (Get-Item -LiteralPath $File).Length -gt 0)
}

# Recreate a key from its hive with backup semantics (an administrator cannot
# create subkeys under Render/Capture): values, subkeys, owner and DACL come
# back as they were. Never over an existing key.
function Restore-AudioRegistryHive {
    param([string]$SubKey, [string]$File)
    $result = { param($Ok, $Message) [pscustomobject]@{ Ok = $Ok; Message = $Message } }
    if (-not (Test-AudioMechanismRoot $SubKey)) { return & $result $false "refused: HKLM\$SubKey is not an audio endpoint key" }
    if (Test-Path -LiteralPath "HKLM:\$SubKey") { return & $result $false "key exists: HKLM\$SubKey" }
    if (-not (Test-Path -LiteralPath $File -PathType Leaf)) { return & $result $false "missing hive file: $File" }
    if (-not (Enable-AudioPrivileges)) { return & $result $false 'could not enable SeBackupPrivilege and SeRestorePrivilege' }
    $rc = [IczAudioNative]::RestoreKeyBackupSemantics($SubKey, $File)
    if ($rc -eq 183) { return & $result $false "key exists: HKLM\$SubKey (it appeared during the restore)" }
    if ($rc -ne 0) {
        # The key was created empty by this call (183 is excluded above), so
        # removing it leaves nothing half-restored for the endpoint builder.
        if (Test-Path -LiteralPath "HKLM:\$SubKey") { [void][IczAudioNative]::DeleteTreeBackupSemantics($SubKey) }
        return & $result $false ('restore of HKLM\{0} failed: error {1}' -f $SubKey, $rc)
    }
    if (-not (Test-Path -LiteralPath "HKLM:\$SubKey")) { return & $result $false "HKLM\$SubKey is missing after the restore" }
    return & $result $true 'restored'
}

# Enabled KSCATEGORY_AUDIO interfaces, lower-case, or $null when the query
# fails. Returned with the unary comma so an empty list stays an empty array -
# call it as  $x = Get-EnabledAudioInterface , never wrapped in @().
function Get-EnabledAudioInterface {
    try {
        Initialize-IczAudioNative
        $list = [IczAudioNative]::GetPresentInterfaces([Guid]'6994ad04-93ef-11d0-a3cc-00a0c9223196')
    }
    catch { Write-Verbose "interface query: $($_.Exception.Message)"; return $null }
    if ($null -eq $list) { return $null }
    return , ([string[]]@($list | ForEach-Object { $_.ToLowerInvariant() }))
}

# --- Gatherers --------------------------------------------------------------
# Read-only. They turn registry and PnP state into the plain records the
# classification section judges; nothing here decides anything.

# One record per endpoint key, or one key with -Flow and -Guid ($null when that
# key is gone). Values are read through RegistryKey.GetValue, which returns a
# REG_MULTI_SZ as string[] and never wraps it in a PSObject.
function Get-AudioEndpointRecord {
    param([string]$Flow, [string]$Guid)
    $root = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio'
    $keys = @()
    if ($Flow -and $Guid) {
        $one = "$root\$Flow\$Guid"
        if (-not (Test-Path -LiteralPath $one)) { return $null }
        $keys = @(Get-Item -LiteralPath $one)
    }
    else {
        foreach ($f in 'Render', 'Capture') {
            if (Test-Path -LiteralPath "$root\$f") { $keys += @(Get-ChildItem -LiteralPath "$root\$f") }
        }
    }
    foreach ($k in $keys) {
        $flowName = Split-Path -Leaf $k.PSParentPath
        $state = Get-Prop (Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue) 'DeviceState'
        $props = $null
        try { $props = Get-Item -LiteralPath (Join-Path $k.PSPath 'Properties') -ErrorAction Stop } catch { $props = $null }
        $get = { param($Name) if ($null -eq $props) { return $null }; return $props.GetValue($Name) }

        $parentId = [string](& $get '{b3f8fa53-0004-438e-9003-51a46e139bfc},2')
        if ($parentId) { $parentId = $parentId -replace '^\{\d+\}\.', '' } else { $parentId = $null }
        $parentExists = $false; $bus = $null; $container = $null; $parentName = $null
        if ($parentId) {
            $enumPath = "HKLM:\SYSTEM\CurrentControlSet\Enum\$parentId"
            $parentExists = Test-Path -LiteralPath $enumPath
            $bus = ($parentId -split '\\')[0].ToUpperInvariant()
            if ($parentExists) {
                $enumProps = Get-ItemProperty -LiteralPath $enumPath -ErrorAction SilentlyContinue
                $container = [string](Get-Prop $enumProps 'ContainerID')
                # The device's current driver name: FriendlyName, else DeviceDesc.
                $parentName = ConvertFrom-PnpResourceString ([string](Get-Prop $enumProps 'FriendlyName'))
                if (-not $parentName) { $parentName = ConvertFrom-PnpResourceString ([string](Get-Prop $enumProps 'DeviceDesc')) }
            }
            if (-not $container) { $container = $null }
        }

        # Interface references: the topology filter, the wave filter and the
        # filter list, each normalised to '\\?\...' without the '{n}.' prefix or
        # the '/pin' suffix - the form the enabled-interface list uses.
        $raw = @(& $get '{b3f8fa53-0004-438e-9003-51a46e139bfc},11') + @(& $get '{233164c8-1b2c-4c7d-bc68-b671687a2567},1') +
               @(& $get '{9dad2fed-2266-4b18-a759-47e7816c60bf},0')
        $refs = @($raw | Where-Object { $_ -is [string] -and $_ } |
                  ForEach-Object { (($_ -replace '^\{\d+\}\.', '') -replace '/.*$', '').ToLowerInvariant() } | Sort-Object -Unique)

        $swd = [string](& $get '{9c119480-ddc2-4954-a150-5bd240d454ad},2')
        [pscustomobject]@{
            Flow = $flowName; Guid = $k.PSChildName; KeyPath = "$root\$flowName\$($k.PSChildName)"
            State = $state
            Name = [string](& $get '{a45c254e-df1c-4efd-8020-67d146a850e0},2')
            InterfaceName = [string](& $get '{b3f8fa53-0004-438e-9003-51a46e139bfc},6')
            ParentId = $parentId; ParentExists = $parentExists; ParentBus = $bus; ParentContainerId = $container; ParentName = $parentName
            InterfaceRefs = $refs
            SwdId = $(if ($swd) { $swd } else { $null })
        }
    }
}

# 'BUS\HARDWARE-ID' of every present device, upper-case, or $null when PnP
# cannot be read. Returned with the unary comma so the HashSet survives.
function Get-PresentDevicePrefixSet {
    $set = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    try { $devices = @(Get-PnpDevice -PresentOnly -ErrorAction Stop) } catch { Write-Verbose "Get-PnpDevice: $($_.Exception.Message)"; return $null }
    foreach ($d in $devices) {
        $parts = ([string]$d.InstanceId) -split '\\'
        if ($parts.Count -ge 2) { [void]$set.Add(('{0}\{1}' -f $parts[0], $parts[1]).ToUpperInvariant()) }
    }
    return , $set
}

function Get-AppAudioStoreRoot {
    param([string]$TargetSid)
    return "Registry::HKEY_USERS\$TargetSid\Software\Microsoft\Internet Explorer\LowRegistry\Audio\PolicyConfig\PropertyStore"
}

# Per-app audio settings of the target user. Each key normally holds exactly
# one REG_SZ default value naming device + app; anything else is reported with
# its counts so the verdict can keep it.
function Get-AppAudioSettingRecord {
    param([string]$TargetSid)
    if (-not (Test-Path -LiteralPath "Registry::HKEY_USERS\$TargetSid")) {
        Write-Warning "The registry hive of $TargetSid is not loaded (signed out?). Per-app audio settings are skipped."
        return
    }
    $root = Get-AppAudioStoreRoot -TargetSid $TargetSid
    if (-not (Test-Path -LiteralPath $root)) { return }
    foreach ($k in @(Get-ChildItem -LiteralPath $root)) { ConvertTo-AppAudioSettingRecord -Key $k }
}

# One per-app entry as a record. Shared by the census and by the fresh re-read
# just before an entry is deleted.
function ConvertTo-AppAudioSettingRecord {
    param($Key)
    $k = $Key
    if ($null -ne $k) {
        $value = $k.GetValue('')
        if ($value -isnot [string]) { $value = $null }
        $parsed = ConvertFrom-AppAudioDevicePath $value
        # A subkey is backed up value by value, so it qualifies only when it has
        # no subkeys of its own and holds only kinds the backup can write.
        $subNames = @($k.GetSubKeyNames())
        $shapeOk = $true
        $subValues = [System.Collections.Generic.List[object]]::new()
        foreach ($s in $subNames) {
            $sk = $k.OpenSubKey($s)
            if ($null -eq $sk) { $shapeOk = $false; continue }
            try {
                if ($sk.SubKeyCount -ne 0) { $shapeOk = $false }
                foreach ($n in $sk.GetValueNames()) {
                    $kind = [string]$sk.GetValueKind($n)
                    if (@('String', 'Binary', 'DWord', 'QWord') -notcontains $kind) { $shapeOk = $false; continue }
                    $subValues.Add([pscustomobject]@{ Key = $s; Name = $n; Kind = $kind; Data = $sk.GetValue($n) })
                }
            }
            finally { $sk.Close() }
        }
        [pscustomobject]@{
            Name = $k.PSChildName; Value = $value
            ValueCount = @($k.GetValueNames()).Count; SubKeyCount = $k.SubKeyCount
            SubKeyNames = $subNames; SubKeyShapeOk = $shapeOk; SubValues = $subValues.ToArray()
            Bus = $(if ($parsed) { $parsed.Bus } else { $null }); HardwareId = $(if ($parsed) { $parsed.HardwareId } else { $null })
        }
    }
}

# The whole picture: every endpoint with its verdict and whether it is
# selected, every per-app setting with its verdict, and the ghost devnodes a
# clean would remove.
function Get-AudioCensus {
    param([string]$TargetSid, [switch]$KeepExposedPorts, [switch]$SkipAppSettings)
    $records = @(Get-AudioEndpointRecord)
    $enabled = Get-EnabledAudioInterface
    $context = New-AudioClassifierContext -Records $records -EnabledInterfaces $enabled
    $endpoints = @(foreach ($r in $records) {
        $v = Get-AudioEndpointVerdict -Record $r -Context $context
        [pscustomobject]@{ Record = $r; Verdict = $v; Selected = (Test-AudioRemovalSelected $v -KeepExposedPorts:$KeepExposedPorts) }
    })
    $ghosts = @(foreach ($e in @($endpoints | Where-Object { $_.Selected })) {
        $id = Get-SwdInstanceId -Flow $e.Record.Flow -Guid $e.Record.Guid
        if ($id -and (Test-Path -LiteralPath "HKLM:\SYSTEM\CurrentControlSet\Enum\$id")) { $id }
    })
    $present = Get-PresentDevicePrefixSet
    $apps = @()
    if (-not $SkipAppSettings) {
        $apps = @(foreach ($a in @(Get-AppAudioSettingRecord -TargetSid $TargetSid)) {
            [pscustomobject]@{ Record = $a; Verdict = (Get-AppAudioSettingVerdict -Record $a -PresentPrefixes $present) }
        })
    }
    return [pscustomobject]@{
        Context = $context; Endpoints = $endpoints; GhostDevnodes = $ghosts; AppSettings = $apps
        PresentPrefixes = $present; TargetSid = $TargetSid
        KeepExposedPorts = [bool]$KeepExposedPorts; SkipAppSettings = [bool]$SkipAppSettings
    }
}

function Write-AudioCensus {
    param($Census)
    $eps = @($Census.Endpoints)
    Write-Host ''
    Write-Host ("AUDIO ENDPOINTS  ({0} in the registry)" -f $eps.Count) -ForegroundColor Cyan
    foreach ($g in @($eps | Group-Object { '{0}|{1}' -f $_.Verdict.Action, $_.Verdict.Label } | Sort-Object Name)) {
        $first = $g.Group[0].Verdict
        Write-Host ('  {0,-7} {1,-26} {2,4}' -f $first.Action.ToUpper(), $first.Label, $g.Count) -ForegroundColor $(if ($first.Action -eq 'Remove') { 'Yellow' } else { 'Gray' })
    }
    Write-Host ''
    foreach ($e in @($eps | Sort-Object { $_.Verdict.Action }, { $_.Verdict.Label }, { $_.Record.Flow }, { $_.Record.Name })) {
        $name = if ($e.Record.InterfaceName) { '{0} ({1})' -f $e.Record.Name, $e.Record.InterfaceName } else { [string]$e.Record.Name }
        $mark = if ($e.Selected) { 'REMOVE' } elseif ($e.Verdict.Action -eq 'Remove') { 'kept' } else { 'KEEP' }
        Write-Host ('  {0,-6} {1,-24} {2,-7} {3}' -f $mark, $e.Verdict.Label, $e.Record.Flow, $name) -ForegroundColor $(if ($e.Selected) { 'Yellow' } else { 'Gray' })
    }
    if ($null -eq $Census.Context.Enabled) {
        Write-Host ''
        Write-Host '  The enabled driver interfaces could not be read; not-present built-in endpoints are labelled unknown.' -ForegroundColor Yellow
    }
    $exposed = @($eps | Where-Object { $_.Verdict.Label -eq 'port-still-exposed' }).Count
    if ($exposed) {
        Write-Host ''
        Write-Host ("  {0} endpoint(s) are ports your current drivers still expose. Windows rebuilds them (under a new id)" -f $exposed) -ForegroundColor Gray
        Write-Host '  the next time the audio service starts; -KeepExposedPorts leaves them alone.' -ForegroundColor Gray
    }

    Write-Host ''
    if ($Census.SkipAppSettings) { Write-Host 'PER-APP AUDIO SETTINGS  (skipped)' -ForegroundColor Cyan }
    else {
        $apps = @($Census.AppSettings)
        Write-Host ("PER-APP AUDIO SETTINGS  ({0} entries)" -f $apps.Count) -ForegroundColor Cyan
        foreach ($g in @($apps | Group-Object { '{0}|{1}' -f $_.Verdict.Action, $_.Verdict.Label } | Sort-Object Name)) {
            $first = $g.Group[0].Verdict
            Write-Host ('  {0,-7} {1,-26} {2,4}' -f $first.Action.ToUpper(), $first.Label, $g.Count) -ForegroundColor $(if ($first.Action -eq 'Remove') { 'Yellow' } else { 'Gray' })
        }
    }

    $selected = @($eps | Where-Object { $_.Selected }).Count
    $appRemove = @($Census.AppSettings | Where-Object { $_.Verdict.Action -eq 'Remove' }).Count
    Write-Host ''
    Write-Host ("-Clean would remove {0} endpoint(s), {1} ghost devnode(s) and {2} per-app setting(s)." -f $selected, @($Census.GhostDevnodes).Count, $appRemove) -ForegroundColor Cyan
    Write-Host 'Driver packages and phantom PCI devices of old hardware are not handled here:' -ForegroundColor Gray
    Write-Host '  Remove-LegacyHardwareResidue.ps1 -Scope Platform,Audio' -ForegroundColor Gray
}

# --- Clean run --------------------------------------------------------------

# Pure: the dependents to start again are exactly those that were running.
function Get-AudioServicesToRestart {
    param([object[]]$Dependents)
    return @(@($Dependents) | Where-Object { $null -ne $_ -and [string]$_.Status -eq 'Running' } | ForEach-Object { [string]$_.Name })
}

# Pure: endpoints that appeared during the run (an id not seen before) and sit
# on a removed endpoint's interface, or carry its flow + parent + name. These
# are ports the drivers still expose; the endpoint builder rebuilt them.
function Find-RebuiltAudioEndpoint {
    param([object[]]$Removed, [string[]]$BeforeGuids, [object[]]$After)
    $cmp = [StringComparer]::OrdinalIgnoreCase
    $before = [System.Collections.Generic.HashSet[string]]::new($cmp)
    foreach ($g in @($BeforeGuids)) { if ($g) { [void]$before.Add($g) } }
    $refs = [System.Collections.Generic.HashSet[string]]::new($cmp)
    $sigs = [System.Collections.Generic.HashSet[string]]::new($cmp)
    foreach ($r in @($Removed)) {
        if ($null -eq $r) { continue }
        foreach ($ref in @($r.InterfaceRefs)) { if ($ref) { [void]$refs.Add($ref) } }
        if ($r.ParentId -and $r.Name) { [void]$sigs.Add(('{0}|{1}|{2}' -f $r.Flow, $r.ParentId, $r.Name)) }
    }
    $found = [System.Collections.Generic.List[object]]::new()
    foreach ($a in @($After)) {
        if ($null -eq $a -or $before.Contains([string]$a.Guid)) { continue }
        $shared = $false
        foreach ($ref in @($a.InterfaceRefs)) { if ($ref -and $refs.Contains($ref)) { $shared = $true } }
        if ($shared -or $sigs.Contains(('{0}|{1}|{2}' -f $a.Flow, $a.ParentId, $a.Name))) { $found.Add($a) }
    }
    return $found.ToArray()
}

# Pure: what must hold after a run. A removed id is gone; every kept endpoint
# still exists; every endpoint that was active still is.
function Get-AudioOutcomeProblems {
    param([string[]]$RemovedGuids, [object[]]$Kept, [object[]]$After)
    $byGuid = @{}
    foreach ($a in @($After)) { if ($null -ne $a -and $a.Guid) { $byGuid[([string]$a.Guid).ToLowerInvariant()] = $a } }
    $problems = [System.Collections.Generic.List[string]]::new()
    foreach ($g in @($RemovedGuids)) {
        if ($g -and $byGuid.ContainsKey($g.ToLowerInvariant())) { $problems.Add("removed endpoint $g is still in the registry") }
    }
    foreach ($k in @($Kept)) {
        if ($null -eq $k) { continue }
        $now = $byGuid[([string]$k.Guid).ToLowerInvariant()]
        if ($null -eq $now) { $problems.Add("kept endpoint $($k.Name) $($k.Guid) is gone"); continue }
        if ($null -ne $k.State -and ((([int64]$k.State) -band 0xF) -eq 1) -and ($null -eq $now.State -or ((([int64]$now.State) -band 0xF) -ne 1))) {
            $problems.Add("endpoint $($k.Name) $($k.Guid) was active and no longer is")
        }
    }
    return $problems.ToArray()
}

# Deletes one endpoint key. The guard is HERE, not at the call site: the path
# must be an endpoint key that matches the record's own flow and id, and the
# key is re-read and re-judged at this moment - with the audio services
# stopped - so a device that came back since the census is skipped, not deleted.
function Remove-AudioEndpointKey {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param($Record, $Context, [switch]$KeepExposedPorts)
    $out = { param($Result, $Reason) [pscustomobject]@{ Guid = $Record.Guid; Flow = $Record.Flow; Name = $Record.Name; Result = $Result; Reason = $Reason } }
    if ($null -eq $Record) { return [pscustomobject]@{ Guid = $null; Flow = $null; Name = $null; Result = 'Refused'; Reason = 'no record' } }
    $expected = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\{0}\{1}' -f $Record.Flow, $Record.Guid
    if (-not (Test-AudioEndpointKeyPath ([string]$Record.KeyPath)) -or -not [string]::Equals([string]$Record.KeyPath, $expected, [StringComparison]::OrdinalIgnoreCase)) {
        return & $out 'Refused' 'not an audio endpoint key, or the path disagrees with the record'
    }
    $fresh = Get-AudioEndpointRecord -Flow $Record.Flow -Guid $Record.Guid
    if ($null -eq $fresh) { return & $out 'Skipped' 'already gone' }
    $verdict = Get-AudioEndpointVerdict -Record $fresh -Context $Context
    if (-not (Test-AudioRemovalSelected $verdict -KeepExposedPorts:$KeepExposedPorts)) { return & $out 'Skipped' "changed since census: $($verdict.Label)" }
    $display = if ($Record.InterfaceName) { '{0} ({1})' -f $Record.Name, $Record.InterfaceName } else { [string]$Record.Name }
    if (-not $PSCmdlet.ShouldProcess("$($Record.Flow) endpoint $display $($Record.Guid)", 'Remove')) { return & $out 'WhatIf' $verdict.Label }
    $r = Remove-RegistryTreeBackupSemantics -SubKey (ConvertTo-HklmSubKey $Record.KeyPath)
    if (-not $r.Ok) { return & $out 'Failed' $r.Message }
    if (Test-Path -LiteralPath $Record.KeyPath) { return & $out 'Failed' 'still present after the delete' }
    return & $out 'Removed' $verdict.Label
}

# The PnP devnode of an endpoint that was just removed. Only ever called with a
# confirmed deletion, never with the census plan.
function Remove-GhostEndpointDevnode {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([string]$Flow, [string]$Guid)
    $id = Get-SwdInstanceId -Flow $Flow -Guid $Guid
    if (-not $id) { return 'Failed' }
    if (-not (Test-Path -LiteralPath "HKLM:\SYSTEM\CurrentControlSet\Enum\$id")) { return 'NotPresent' }
    if (-not $PSCmdlet.ShouldProcess($id, 'Remove ghost devnode')) { return 'WhatIf' }
    $r = Invoke-NativeCommand -FilePath 'pnputil.exe' -Arguments @('/remove-device', $id)
    switch ($r.Code) {
        0       { return 'Removed' }
        3010    { return 'RebootRequired' }
        default { Write-Host ("    pnputil /remove-device {0}: exit {1} {2}" -f $id, $r.Code, $r.Output) -ForegroundColor Yellow; return 'Failed' }
    }
}

# Deletes one per-app entry, re-read and re-judged first. Addresses
# HKEY_USERS\<TargetSid>, never HKCU: elevated through another administrator's
# account, HKCU is that administrator's hive.
function Remove-AppAudioSetting {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param($Record, [string]$TargetSid, $PresentPrefixes)
    $name = [string](Get-Prop $Record 'Name')
    $out = { param($Result, $Reason) [pscustomobject]@{ Name = $name; Result = $Result; Reason = $Reason } }
    if ([string]::IsNullOrWhiteSpace($name) -or $name.Contains('\') -or $name.Contains('/')) { return & $out 'Refused' 'not a single per-app entry name' }
    if (-not (Test-Path -LiteralPath "Registry::HKEY_USERS\$TargetSid")) { return & $out 'Skipped' "hive not loaded for $TargetSid" }
    $path = '{0}\{1}' -f (Get-AppAudioStoreRoot -TargetSid $TargetSid), $name
    if (-not (Test-Path -LiteralPath $path)) { return & $out 'Skipped' 'already gone' }
    $fresh = ConvertTo-AppAudioSettingRecord -Key (Get-Item -LiteralPath $path)
    $v = Get-AppAudioSettingVerdict -Record $fresh -PresentPrefixes $PresentPrefixes
    if ($v.Action -ne 'Remove') { return & $out 'Skipped' "changed since census: $($v.Label)" }
    if (-not $PSCmdlet.ShouldProcess("per-app audio setting $name", 'Remove')) { return & $out 'WhatIf' $v.Label }
    try { Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop } catch { return & $out 'Failed' $_.Exception.Message }
    if (Test-Path -LiteralPath $path) { return & $out 'Failed' 'still present after the delete' }
    return & $out 'Removed' $v.Label
}

# Stopping the endpoint builder stops Audiosrv and every other dependent with
# it. Which dependents were running is recorded first: only those are started
# again afterwards.
function Stop-AudioStack {
    $result = { param($Ok, $Running, $Message) [pscustomobject]@{ Ok = $Ok; RunningDependents = $Running; Message = $Message } }
    try {
        $aeb = Get-Service -Name 'AudioEndpointBuilder' -ErrorAction Stop
        $running = @(Get-AudioServicesToRestart -Dependents @($aeb.DependentServices | Select-Object Name, Status))
        Stop-Service -Name 'AudioEndpointBuilder' -Force -ErrorAction Stop -WhatIf:$false
        $aeb.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(30))
        return & $result $true $running 'stopped'
    }
    catch { return & $result $false @() $_.Exception.Message }
}

# Audiosrv has no trigger start and does not come back with the endpoint
# builder, so both are started explicitly, then the recorded dependents. Each
# start is retried; whatever is still not running is returned by name.
function Start-AudioStack {
    param([string[]]$Dependents)
    $order = @('AudioEndpointBuilder', 'Audiosrv') + @(@($Dependents) | Where-Object { $_ -and @('AudioEndpointBuilder', 'Audiosrv') -notcontains $_ })
    $notRunning = [System.Collections.Generic.List[string]]::new()
    foreach ($name in $order) {
        $running = $false
        for ($attempt = 1; $attempt -le 3 -and -not $running; $attempt++) {
            try {
                Start-Service -Name $name -ErrorAction Stop -WhatIf:$false
                $svc = Get-Service -Name $name -ErrorAction Stop
                $svc.WaitForStatus('Running', [TimeSpan]::FromSeconds(10))
                $running = ((Get-Service -Name $name).Status -eq 'Running')
            }
            catch { Start-Sleep -Seconds 2 }
        }
        if (-not $running) { $notRunning.Add($name) }
    }
    return [pscustomobject]@{ Ok = ($notRunning.Count -eq 0); NotRunning = $notRunning.ToArray() }
}

# While the audio services are down, nothing may stop the script before it
# starts them again. Ctrl+C is read as input instead of breaking (PowerShell 5.1
# lets a second Ctrl+C abort a finally block), and an engine-exit handler starts
# both services if the script ends any other orderly way. Killing the process
# or closing the window bypasses both; the summary prints the recovery commands.
function Enter-AudioCriticalWindow {
    $state = [pscustomobject]@{ CtrlC = $null; Job = $null }
    try { $state.CtrlC = [Console]::TreatControlCAsInput; [Console]::TreatControlCAsInput = $true } catch { $state.CtrlC = $null }
    $state.Job = Register-EngineEvent -SourceIdentifier ([System.Management.Automation.PsEngineEvent]::Exiting) -Action {
        & sc.exe start AudioEndpointBuilder | Out-Null
        & sc.exe start Audiosrv | Out-Null
    }
    return $state
}

function Exit-AudioCriticalWindow {
    param($State)
    if ($null -eq $State) { return }
    if ($null -ne $State.CtrlC) { try { [Console]::TreatControlCAsInput = $State.CtrlC } catch { Write-Verbose 'no console' } }
    if ($null -ne $State.Job) {
        Get-EventSubscriber | Where-Object { $_.Action -eq $State.Job } | Unregister-Event -ErrorAction SilentlyContinue
        Remove-Job -Job $State.Job -Force -ErrorAction SilentlyContinue
    }
}

# The endpoint builder rebuilds what it still sees right after it starts; wait
# until the endpoint key count has been stable for a few seconds.
function Wait-AudioEndpointSettle {
    param([int]$StableSeconds = 3, [int]$TimeoutSeconds = 30)
    $root = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio'
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $last = -1; $since = Get-Date
    while ((Get-Date) -lt $deadline) {
        $n = @(Get-ChildItem -LiteralPath "$root\Render", "$root\Capture" -ErrorAction SilentlyContinue).Count
        if ($n -ne $last) { $last = $n; $since = Get-Date }
        elseif (((Get-Date) - $since).TotalSeconds -ge $StableSeconds) { break }
        Start-Sleep -Milliseconds 500
    }
    return @(Get-AudioEndpointRecord)
}

# The -Clean run, step by step as the design lays it out. Returns the exit code.
function Invoke-AudioClean {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param($Census, [string]$BackupPath, [string]$TargetSid, [switch]$KeepExposedPorts, [switch]$SkipAppSettings,
          [switch]$CreateRestorePoint, [switch]$Force)
    $whatIf = [bool]$WhatIfPreference
    $targets = @($Census.Endpoints | Where-Object { $_.Selected })
    $appTargets = @()
    if (-not $SkipAppSettings) { $appTargets = @($Census.AppSettings | Where-Object { $_.Verdict.Action -eq 'Remove' }) }
    if ($targets.Count -eq 0 -and $appTargets.Count -eq 0) {
        Write-Host ''; Write-Host 'Nothing to remove.' -ForegroundColor Green
        return 2
    }

    # 2. Confirm - skipped by -Force and, explicitly, by -WhatIf.
    if (-not $Force -and -not $whatIf) {
        Write-Host ''
        Write-Host ("About to remove {0} audio endpoint(s), up to {1} ghost devnode(s) and {2} per-app setting(s)." -f $targets.Count, @($Census.GhostDevnodes).Count, $appTargets.Count) -ForegroundColor Yellow
        Write-Host 'Everything is backed up first. About 10 seconds without sound while the audio services restart;' -ForegroundColor Yellow
        Write-Host 'apps that were playing (Sonar included) may need restarting.' -ForegroundColor Yellow
        $answer = Read-Host 'Continue? [y/N]'
        if ($answer -notmatch '^(?i)y(es)?$') { Write-Host 'Declined. Nothing was changed.' -ForegroundColor Gray; return 0 }
    }

    # 3. Backup - verified before anything is touched.
    $appRoot = "HKEY_USERS\$TargetSid\Software\Microsoft\Internet Explorer\LowRegistry\Audio\PolicyConfig\PropertyStore"
    try {
        $manifest = Backup-AudioTargets -Endpoints $targets -AppSettings $appTargets -Folder $BackupPath -TargetSid $TargetSid -AppRootKey $appRoot -Devnodes @($Census.GhostDevnodes)
    }
    catch { Write-Host "Backup failed; nothing was changed: $($_.Exception.Message)" -ForegroundColor Red; return 1 }
    if ($whatIf) {
        Write-Host ("What if: the backup of {0} endpoint key(s) and {1} per-app setting(s) would be written to {2}" -f $targets.Count, $appTargets.Count, $BackupPath)
    }
    else {
        $problems = @(Test-AudioBackup -Folder $BackupPath -Manifest $manifest)
        if ($problems.Count) {
            Write-Host 'The backup did not verify; nothing was changed:' -ForegroundColor Red
            foreach ($p in $problems) { Write-Host "  $p" -ForegroundColor Red }
            return 1
        }
        Write-Host "Backup written and verified: $BackupPath" -ForegroundColor Green
    }

    # 4. Restore point (opt-in). Windows refuses a second one within 24 hours.
    if ($CreateRestorePoint -and -not $whatIf) {
        try { Checkpoint-Computer -Description 'Clean-AudioDevices' -RestorePointType 'MODIFY_SETTINGS' -ErrorAction Stop; Write-Host 'Restore point created.' -ForegroundColor Green }
        catch { Write-Host "Restore point not created: $($_.Exception.Message)" -ForegroundColor Yellow }
    }

    # 5-9. Services down, delete, services up.
    $beforeGuids = @($Census.Endpoints | ForEach-Object { $_.Record.Guid })
    $results = [System.Collections.Generic.List[object]]::new()
    $devResults = [System.Collections.Generic.List[object]]::new()
    $appResults = [System.Collections.Generic.List[object]]::new()
    $stack = $null; $window = $null; $start = $null; $stopFailed = $false
    try {
        if (-not $whatIf) {
            $window = Enter-AudioCriticalWindow
            Write-Host 'Stopping the audio services...' -ForegroundColor Cyan
            $stack = Stop-AudioStack
            if (-not $stack.Ok) { $stopFailed = $true; Write-Host "Could not stop the audio services; nothing was deleted: $($stack.Message)" -ForegroundColor Red }
        }
        if (-not $stopFailed) {
            foreach ($t in $targets) { $results.Add((Remove-AudioEndpointKey -Record $t.Record -Context $Census.Context -KeepExposedPorts:$KeepExposedPorts)) }
            # From confirmed deletions only (or, under -WhatIf, from those that would be).
            foreach ($res in @($results | Where-Object { $_.Result -eq 'Removed' -or $_.Result -eq 'WhatIf' })) {
                $devResults.Add([pscustomobject]@{ Guid = $res.Guid; Result = (Remove-GhostEndpointDevnode -Flow $res.Flow -Guid $res.Guid) })
            }
            foreach ($a in $appTargets) { $appResults.Add((Remove-AppAudioSetting -Record $a.Record -TargetSid $TargetSid -PresentPrefixes $Census.PresentPrefixes)) }
        }
    }
    finally {
        if (-not $whatIf) {
            Write-Host 'Starting the audio services...' -ForegroundColor Cyan
            $deps = @(); if ($null -ne $stack) { $deps = @($stack.RunningDependents) }
            $start = Start-AudioStack -Dependents $deps
            Exit-AudioCriticalWindow -State $window
        }
    }

    # 10. Verify, and name what Windows rebuilt.
    $count = { param($List, $Result) @($List | Where-Object { $_.Result -eq $Result }).Count }
    Write-Host ''
    Write-Host 'RESULT' -ForegroundColor Cyan
    if ($whatIf) {
        Write-Host ("  What if: {0} endpoint(s), {1} ghost devnode(s), {2} per-app setting(s) would be removed." -f (& $count $results 'WhatIf'), (& $count $devResults 'WhatIf'), (& $count $appResults 'WhatIf'))
        foreach ($s in @($results | Where-Object { $_.Result -ne 'WhatIf' })) { Write-Host ("  {0}: {1} {2} - {3}" -f $s.Result, $s.Flow, $s.Name, $s.Reason) -ForegroundColor Yellow }
        return 0
    }
    $failed = 0
    $removedGuids = @($results | Where-Object { $_.Result -eq 'Removed' } | ForEach-Object { $_.Guid })
    $removedRecords = @($targets | Where-Object { $removedGuids -contains $_.Record.Guid } | ForEach-Object { $_.Record })
    $kept = @($Census.Endpoints | Where-Object { -not $_.Selected } | ForEach-Object { $_.Record })
    $after = @(Wait-AudioEndpointSettle)
    $problems = @(Get-AudioOutcomeProblems -RemovedGuids $removedGuids -Kept $kept -After $after)
    $rebuilt = @(Find-RebuiltAudioEndpoint -Removed $removedRecords -BeforeGuids $beforeGuids -After $after)

    Write-Host ("  Endpoints removed: {0} of {1}" -f $removedGuids.Count, $targets.Count) -ForegroundColor Green
    foreach ($g in @($results | Where-Object { $_.Result -eq 'Removed' } | Group-Object Reason)) { Write-Host ("    {0,-24} {1,4}" -f $g.Name, $g.Count) }
    foreach ($s in @($results | Where-Object { $_.Result -ne 'Removed' })) {
        if (@('Failed', 'Refused') -contains $s.Result) { $failed++ }
        Write-Host ("  {0}: {1} {2} {3} - {4}" -f $s.Result, $s.Flow, $s.Name, $s.Guid, $s.Reason) -ForegroundColor $(if (@('Failed', 'Refused') -contains $s.Result) { 'Red' } else { 'Yellow' })
    }
    $failed += & $count $devResults 'Failed'
    Write-Host ("  Ghost devnodes removed: {0}" -f (& $count $devResults 'Removed')) -ForegroundColor Green
    if ($SkipAppSettings) { Write-Host '  Per-app settings: skipped' }
    else {
        Write-Host ("  Per-app settings removed: {0} of {1}" -f (& $count $appResults 'Removed'), $appTargets.Count) -ForegroundColor Green
        foreach ($s in @($appResults | Where-Object { $_.Result -ne 'Removed' })) {
            if (@('Failed', 'Refused') -contains $s.Result) { $failed++ }
            Write-Host ("  {0}: per-app {1} - {2}" -f $s.Result, $s.Name, $s.Reason) -ForegroundColor Yellow
        }
    }
    if ($rebuilt.Count) {
        Write-Host ''
        Write-Host ("  Rebuilt by Windows ({0}) - ports your current drivers still expose:" -f $rebuilt.Count) -ForegroundColor Yellow
        foreach ($r in $rebuilt) { Write-Host ("    {0,-7} {1} ({2})" -f $r.Flow, $r.Name, $r.InterfaceName) }
        if (@($rebuilt | Where-Object { [string]$_.ParentId -like 'HDAUDIO\FUNC_01&VEN_1002*' }).Count) {
            Write-Host '  If sound never comes from the motherboard''s video outputs, disabling "AMD High Definition Audio Device"' -ForegroundColor Gray
            Write-Host '  in Device Manager lets a later run remove those entries for good.' -ForegroundColor Gray
        }
    }
    foreach ($p in $problems) { Write-Host "  PROBLEM: $p" -ForegroundColor Red; $failed++ }
    if (-not $start.Ok) {
        $failed++
        Write-Host ("  The audio services did not all restart: {0}" -f ($start.NotRunning -join ', ')) -ForegroundColor Red
        Write-Host '  From an elevated prompt run:  sc start AudioEndpointBuilder   then   sc start Audiosrv' -ForegroundColor Red
    }
    Write-Host ''
    Write-Host "Backup: $BackupPath" -ForegroundColor Gray
    Write-Host ("To put it all back:  .\Clean-AudioDevices.ps1 -Restore `"{0}`"" -f (Join-Path $BackupPath 'manifest.json')) -ForegroundColor Gray
    if ($failed) { return 3 }
    if ((& $count $devResults 'RebootRequired') -gt 0) { Write-Host 'pnputil asked for a restart.' -ForegroundColor Yellow; return 3010 }
    return 0
}

# --- Restore ----------------------------------------------------------------

# A manifest is trusted only when it was written on this computer, every file
# it names resolves INSIDE its own folder and exists, every key it names is an
# audio endpoint key, and its per-app root is a PropertyStore under HKEY_USERS.
# A tampered or foreign manifest throws with the reason; nothing is touched.
function Read-AudioManifest {
    param([string]$Path)
    $full = [IO.Path]::GetFullPath($Path)
    $folder = (Split-Path -Parent $full).TrimEnd('\') + '\'
    # Written as UTF-8 without a BOM; Windows PowerShell 5.1 would read it as
    # ANSI and restore a non-ASCII app path as mojibake.
    $m = Get-Content -LiteralPath $full -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([string](Get-Prop $m 'Version') -ne '1') { throw "unsupported manifest version: $(Get-Prop $m 'Version')" }
    if ([string](Get-Prop $m 'Computer') -ne $env:COMPUTERNAME) { throw "this manifest is from another computer ($(Get-Prop $m 'Computer'))" }
    foreach ($ep in @(@(Get-Prop $m 'Endpoints') | Where-Object { $null -ne $_ })) {
        if (-not (Test-AudioEndpointKeyPath ('HKLM:\' + [string](Get-Prop $ep 'SubKey')))) { throw "not an audio endpoint key: $(Get-Prop $ep 'SubKey')" }
        foreach ($rel in @([string](Get-Prop $ep 'Hive'), [string](Get-Prop $ep 'Reg'))) {
            $target = [IO.Path]::GetFullPath([IO.Path]::Combine($folder, $rel))
            if (-not $target.StartsWith($folder, [StringComparison]::OrdinalIgnoreCase)) { throw "outside the backup folder: $rel" }
            if (-not (Test-Path -LiteralPath $target -PathType Leaf)) { throw "missing backup file: $rel" }
        }
    }
    $apps = Get-Prop $m 'AppSettings'
    if (@(@(Get-Prop $apps 'Entries') | Where-Object { $null -ne $_ }).Count -and
        [string](Get-Prop $apps 'RootKey') -notmatch '^HKEY_USERS\\S-1-[0-9-]+\\Software\\Microsoft\\Internet Explorer\\LowRegistry\\Audio\\PolicyConfig\\PropertyStore$') {
        throw "unexpected per-app root: $(Get-Prop $apps 'RootKey')"
    }
    return $m
}

# Recreates per-app entries that do not exist now, values and volume subkey
# exactly as backed up. An entry that exists - the app has written it again -
# is left alone: the current setting is newer than the backup.
function Restore-AppAudioSettings {
    param([object[]]$Entries, [string]$RootKey)
    $restored = 0; $skipped = 0
    foreach ($e in @(@($Entries) | Where-Object { $null -ne $_ })) {
        $name = [string](Get-Prop $e 'Name')
        if ([string]::IsNullOrWhiteSpace($name) -or $name.Contains('\') -or $name.Contains('/')) { $skipped++; continue }
        $path = "$RootKey\$name"
        if (Test-Path -LiteralPath $path) { $skipped++; continue }
        New-Item -Path $path -Force | Out-Null
        Set-Item -LiteralPath $path -Value ([string](Get-Prop $e 'Value'))
        foreach ($g in @(@(Get-Prop $e 'Sub') | Where-Object { $null -ne $_ } | Group-Object Key)) {
            $sub = "$path\$($g.Name)"
            New-Item -Path $sub -Force | Out-Null
            foreach ($v in $g.Group) {
                switch ([string]$v.Kind) {
                    'Binary' { New-ItemProperty -LiteralPath $sub -Name $v.Name -PropertyType Binary -Value ([Convert]::FromBase64String([string]$v.Data)) | Out-Null }
                    'DWord'  { New-ItemProperty -LiteralPath $sub -Name $v.Name -PropertyType DWord -Value ([int]$v.Data) | Out-Null }
                    'QWord'  { New-ItemProperty -LiteralPath $sub -Name $v.Name -PropertyType QWord -Value ([int64]$v.Data) | Out-Null }
                    'String' { New-ItemProperty -LiteralPath $sub -Name $v.Name -PropertyType String -Value ([string]$v.Data) | Out-Null }
                }
            }
        }
        $restored++
    }
    return [pscustomobject]@{ Restored = $restored; Skipped = $skipped }
}

# Pure: sorts restore results. A key that was restored and verified before the
# services restarted, then removed by the endpoint builder because a newer
# endpoint it rebuilt holds the same port, is Discarded - Windows' decision,
# not a failed restore. 'key exists' is Skipped; everything else not present
# before the restart is Failed.
function Get-AudioRestoreOutcome {
    param([object[]]$Results, [string[]]$PresentAfter)
    $after = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($p in @($PresentAfter)) { if ($p) { [void]$after.Add($p) } }
    $restored = [System.Collections.Generic.List[object]]::new(); $discarded = [System.Collections.Generic.List[object]]::new()
    $skipped = [System.Collections.Generic.List[object]]::new();  $failed = [System.Collections.Generic.List[object]]::new()
    foreach ($r in @(@($Results) | Where-Object { $null -ne $_ })) {
        if (-not $r.Ok) {
            if ([string]$r.Message -like 'key exists*') { $skipped.Add($r.Endpoint) } else { $failed.Add($r.Endpoint) }
        }
        elseif (-not $r.PresentBeforeRestart) { $failed.Add($r.Endpoint) }
        elseif ($after.Contains([string]$r.Endpoint.SubKey)) { $restored.Add($r.Endpoint) }
        else { $discarded.Add($r.Endpoint) }
    }
    return [pscustomobject]@{ Restored = $restored.ToArray(); Discarded = $discarded.ToArray(); Skipped = $skipped.ToArray(); Failed = $failed.ToArray() }
}

# The -Restore run. Endpoint keys need the audio services stopped (a running
# endpoint builder owns them) and come back from their hives with their own
# owner and ACL; ghost devnodes are not restored - the endpoint builder makes
# them again for the restored keys. Returns the exit code.
function Invoke-AudioRestore {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([string]$ManifestPath, [switch]$Force)
    $whatIf = [bool]$WhatIfPreference
    try { $m = Read-AudioManifest -Path $ManifestPath } catch { Write-Host "Cannot restore: $($_.Exception.Message)" -ForegroundColor Red; return 1 }
    $folder = Split-Path -Parent ([IO.Path]::GetFullPath($ManifestPath))
    $eps = @(@($m.Endpoints) | Where-Object { $null -ne $_ })
    $missing = @($eps | Where-Object { -not (Test-Path -LiteralPath "HKLM:\$($_.SubKey)") })
    $entries = @(@($m.AppSettings.Entries) | Where-Object { $null -ne $_ })
    $appRoot = 'Registry::' + [string]$m.AppSettings.RootKey
    $sid = [string]$m.TargetSid
    $hiveLoaded = Test-Path -LiteralPath "Registry::HKEY_USERS\$sid"
    $appMissing = @()
    if ($hiveLoaded) { $appMissing = @($entries | Where-Object { -not (Test-Path -LiteralPath "$appRoot\$($_.Name)") }) }

    Write-Host ''
    Write-Host 'RESTORE' -ForegroundColor Cyan
    Write-Host ("  Endpoint keys in the manifest: {0}; missing now: {1}; already present (left alone): {2}" -f $eps.Count, $missing.Count, ($eps.Count - $missing.Count))
    if ($entries.Count -and -not $hiveLoaded) { Write-Host "  Per-app settings: the hive of $sid is not loaded; they are skipped." -ForegroundColor Yellow }
    else { Write-Host ("  Per-app settings in the manifest: {0}; missing now: {1}" -f $entries.Count, $appMissing.Count) }
    if ($missing.Count -eq 0 -and $appMissing.Count -eq 0) { Write-Host '  Nothing to restore.' -ForegroundColor Green; return 2 }

    if ($whatIf) {
        foreach ($ep in $missing) { [void]$PSCmdlet.ShouldProcess("$($ep.Flow) endpoint $($ep.Name) $($ep.Guid)", 'Restore') }
        foreach ($a in $appMissing) { [void]$PSCmdlet.ShouldProcess("per-app audio setting $($a.Name)", 'Restore') }
        return 0
    }
    if (-not $Force) {
        if ($missing.Count) { Write-Host '  About 10 seconds without sound while the audio services restart.' -ForegroundColor Yellow }
        $answer = Read-Host 'Restore? [y/N]'
        if ($answer -notmatch '^(?i)y(es)?$') { Write-Host 'Declined. Nothing was changed.' -ForegroundColor Gray; return 0 }
    }

    $failed = 0
    $results = [System.Collections.Generic.List[object]]::new()
    if ($missing.Count) {
        $window = $null; $stack = $null
        try {
            $window = Enter-AudioCriticalWindow
            $stack = Stop-AudioStack
            if (-not $stack.Ok) { $failed++; Write-Host "Could not stop the audio services; nothing was restored: $($stack.Message)" -ForegroundColor Red }
            else {
                foreach ($ep in $missing) {
                    $r = Restore-AudioRegistryHive -SubKey $ep.SubKey -File (Join-Path $folder $ep.Hive)
                    # Verified now, before the services restart: what the endpoint
                    # builder does with the key afterwards is its own decision.
                    $results.Add([pscustomobject]@{ Endpoint = $ep; Ok = $r.Ok; Message = $r.Message
                                                    PresentBeforeRestart = (Test-Path -LiteralPath "HKLM:\$($ep.SubKey)") })
                }
            }
        }
        finally {
            $deps = @(); if ($null -ne $stack) { $deps = @($stack.RunningDependents) }
            $start = Start-AudioStack -Dependents $deps
            Exit-AudioCriticalWindow -State $window
        }
        if (-not $start.Ok) {
            $failed++
            Write-Host ("  The audio services did not all restart: {0}" -f ($start.NotRunning -join ', ')) -ForegroundColor Red
            Write-Host '  From an elevated prompt run:  sc start AudioEndpointBuilder   then   sc start Audiosrv' -ForegroundColor Red
        }
    }
    $presentAfter = @($results | Where-Object { Test-Path -LiteralPath "HKLM:\$($_.Endpoint.SubKey)" } | ForEach-Object { $_.Endpoint.SubKey })
    $outcome = Get-AudioRestoreOutcome -Results $results.ToArray() -PresentAfter $presentAfter
    foreach ($ep in @($outcome.Skipped)) { Write-Host "  Skipped (exists now): $($ep.Name) $($ep.Guid)" -ForegroundColor Yellow }
    foreach ($ep in @($outcome.Failed)) {
        $failed++
        $why = @($results | Where-Object { $_.Endpoint -eq $ep } | ForEach-Object { $_.Message }) -join ' '
        Write-Host "  FAILED: $($ep.Name) $($ep.Guid) - $why" -ForegroundColor Red
    }
    $restoredKeys = @($outcome.Restored).Count + @($outcome.Discarded).Count
    if (@($outcome.Discarded).Count) {
        Write-Host ("  Windows discarded {0} restored endpoint(s) after the restart: a newer endpoint it rebuilt holds the same port." -f @($outcome.Discarded).Count) -ForegroundColor Yellow
        foreach ($ep in @($outcome.Discarded)) { Write-Host ("    {0,-7} {1} ({2})" -f $ep.Flow, $ep.Name, $ep.InterfaceName) }
    }
    $app = [pscustomobject]@{ Restored = 0; Skipped = 0 }
    if ($hiveLoaded -and $appMissing.Count) {
        try { $app = Restore-AppAudioSettings -Entries $appMissing -RootKey $appRoot }
        catch { $failed++; Write-Host "  Per-app restore failed: $($_.Exception.Message)" -ForegroundColor Red }
    }
    Write-Host ("  Endpoint keys restored: {0} of {1}" -f $restoredKeys, $missing.Count) -ForegroundColor Green
    Write-Host ("  Per-app settings restored: {0}" -f $app.Restored) -ForegroundColor Green
    if ($failed) { return 3 }
    return 0
}

# --- Backup -----------------------------------------------------------------
# Everything a clean removes is written down before anything is touched:
#   endpoints\<Flow>_<Guid>.hiv   "reg save" hive - what -Restore loads back,
#                                 security descriptors included
#   endpoints\<Flow>_<Guid>.reg   "reg export" of the same key, for people
#   appsettings.reg               the per-app entries, for people and for a
#                                 manual "reg import"
#   manifest.json                 what was removed, and the per-app values
#                                 -Restore writes back

function ConvertTo-RegSzLiteral {
    param([string]$Text)
    return $Text.Replace('\', '\\').Replace('"', '\"')
}

function Get-RecordOf { param($Item) if ($null -ne $Item -and $null -ne $Item.PSObject.Properties['Record']) { return $Item.Record } return $Item }

# A .reg file in reg.exe's own format (UTF-16LE with BOM). Each entry is its
# default REG_SZ value plus, when present, the values of its volume subkey.
function Export-AppAudioSettingReg {
    param([object[]]$Records, [string]$RootKey, [string]$Path)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("Windows Registry Editor Version 5.00`r`n`r`n")
    foreach ($item in @($Records)) {
        $r = Get-RecordOf $item
        [void]$sb.AppendFormat("[{0}\{1}]`r`n", $RootKey, $r.Name)
        [void]$sb.AppendFormat("@=`"{0}`"`r`n`r`n", (ConvertTo-RegSzLiteral ([string]$r.Value)))
        foreach ($g in @(@(Get-Prop $r 'SubValues') | Where-Object { $null -ne $_ } | Group-Object Key)) {
            [void]$sb.AppendFormat("[{0}\{1}\{2}]`r`n", $RootKey, $r.Name, $g.Name)
            foreach ($v in $g.Group) {
                $name = '"{0}"' -f (ConvertTo-RegSzLiteral ([string]$v.Name))
                switch ($v.Kind) {
                    'String' { [void]$sb.AppendFormat("{0}=`"{1}`"`r`n", $name, (ConvertTo-RegSzLiteral ([string]$v.Data))) }
                    'Binary' { [void]$sb.AppendFormat("{0}=hex:{1}`r`n", $name, ((@([byte[]]$v.Data) | ForEach-Object { '{0:x2}' -f $_ }) -join ',')) }
                    'DWord'  { [void]$sb.AppendFormat("{0}=dword:{1:x8}`r`n", $name, [BitConverter]::ToUInt32([BitConverter]::GetBytes([int]$v.Data), 0)) }
                    'QWord'  { [void]$sb.AppendFormat("{0}=hex(b):{1}`r`n", $name, (([BitConverter]::GetBytes([int64]$v.Data) | ForEach-Object { '{0:x2}' -f $_ }) -join ',')) }
                }
            }
            [void]$sb.Append("`r`n")
        }
    }
    [IO.File]::WriteAllText($Path, $sb.ToString(), [Text.Encoding]::Unicode)
}

# Writes the backup and returns the manifest. Under -WhatIf it writes nothing
# and returns the manifest it would have written. A folder that already holds a
# manifest is refused: an earlier run's backup is never overwritten.
function Backup-AudioTargets {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([object[]]$Endpoints, [object[]]$AppSettings, [string]$Folder, [string]$TargetSid, [string]$AppRootKey, [string[]]$Devnodes)
    $epEntries = @(foreach ($item in @($Endpoints)) {
        $r = Get-RecordOf $item
        $label = $null
        if ($null -ne $item.PSObject.Properties['Verdict']) { $label = $item.Verdict.Label }
        $sub = ConvertTo-HklmSubKey $r.KeyPath
        if (-not $sub) { throw "Endpoint $($r.Guid) has no HKLM key path; nothing was written." }
        $base = 'endpoints\{0}_{1}' -f $r.Flow, $r.Guid
        [pscustomobject]@{
            Flow = $r.Flow; Guid = $r.Guid; SubKey = $sub; Name = $r.Name; InterfaceName = $r.InterfaceName
            ParentId = $r.ParentId; Label = $label; Hive = "$base.hiv"; Reg = "$base.reg"
        }
    })
    $appRecords = @(foreach ($item in @($AppSettings)) { Get-RecordOf $item })
    $appEntries = @(foreach ($r in $appRecords) {
        [pscustomobject]@{
            Name = $r.Name; Value = $r.Value
            Sub = @(foreach ($v in @(@(Get-Prop $r 'SubValues') | Where-Object { $null -ne $_ })) {
                $data = $v.Data
                if ($v.Kind -eq 'Binary') { $data = [Convert]::ToBase64String([byte[]]$v.Data) }
                [pscustomobject]@{ Key = $v.Key; Name = $v.Name; Kind = $v.Kind; Data = $data }
            })
        }
    })
    $manifest = [pscustomobject]@{
        Version = 1; Script = 'Clean-AudioDevices.ps1'; Computer = $env:COMPUTERNAME; TargetSid = $TargetSid
        Created = (Get-Date).ToString('o'); Endpoints = $epEntries
        AppSettings = [pscustomobject]@{ RootKey = $AppRootKey; File = 'appsettings.reg'; Entries = $appEntries }
        Devnodes = @($Devnodes | Where-Object { $_ })
    }
    if (Test-Path -LiteralPath (Join-Path $Folder 'manifest.json')) { throw "The backup folder already holds a manifest: $Folder" }
    if (-not $PSCmdlet.ShouldProcess($Folder, 'Write the backup')) { return $manifest }

    New-Item -ItemType Directory -Path (Join-Path $Folder 'endpoints') -Force | Out-Null
    foreach ($ep in $epEntries) {
        if (-not (Save-AudioRegistryHive -SubKey $ep.SubKey -File (Join-Path $Folder $ep.Hive))) { throw "reg save of HKLM\$($ep.SubKey) failed." }
        $r = Invoke-NativeCommand -FilePath 'reg.exe' -Arguments @('export', "HKLM\$($ep.SubKey)", (Join-Path $Folder $ep.Reg), '/y')
        if ($r.Code -ne 0) { throw "reg export of HKLM\$($ep.SubKey) failed: $($r.Output)" }
    }
    if ($appRecords.Count) { Export-AppAudioSettingReg -Records $appRecords -RootKey $AppRootKey -Path (Join-Path $Folder 'appsettings.reg') }
    [IO.File]::WriteAllText((Join-Path $Folder 'manifest.json'), ($manifest | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
    return $manifest
}

# Every file the manifest names must exist and look like what it claims to be.
# Returns the problems; an empty result means the backup can be trusted.
function Test-AudioBackup {
    param([string]$Folder, $Manifest)
    $problems = [System.Collections.Generic.List[string]]::new()
    $header = 'Windows Registry Editor Version 5.00'
    foreach ($ep in @($Manifest.Endpoints)) {
        foreach ($rel in $ep.Hive, $ep.Reg) {
            $p = Join-Path $Folder $rel
            if (-not (Test-Path -LiteralPath $p -PathType Leaf) -or (Get-Item -LiteralPath $p).Length -eq 0) { $problems.Add("missing or empty: $rel") }
        }
        $regPath = Join-Path $Folder $ep.Reg
        if (Test-Path -LiteralPath $regPath -PathType Leaf) {
            $text = [IO.File]::ReadAllText($regPath)
            if (-not $text.StartsWith($header) -or $text.IndexOf("[HKEY_LOCAL_MACHINE\$($ep.SubKey)]", [StringComparison]::OrdinalIgnoreCase) -lt 0) {
                $problems.Add("not a registry export of HKLM\$($ep.SubKey): $($ep.Reg)")
            }
        }
    }
    $entries = @($Manifest.AppSettings.Entries)
    if ($entries.Count) {
        $rel = [string]$Manifest.AppSettings.File
        $p = Join-Path $Folder $rel
        if (-not (Test-Path -LiteralPath $p -PathType Leaf) -or (Get-Item -LiteralPath $p).Length -eq 0) { $problems.Add("missing or empty: $rel") }
        else {
            $text = [IO.File]::ReadAllText($p)
            $defaults = @($text -split "`r`n" | Where-Object { $_.StartsWith('@=') }).Count
            if (-not $text.StartsWith($header)) { $problems.Add("not a registry file: $rel") }
            elseif ($defaults -ne $entries.Count) { $problems.Add("$rel holds $defaults default value(s); the manifest lists $($entries.Count)") }
        }
    }
    $mj = Join-Path $Folder 'manifest.json'
    if (-not (Test-Path -LiteralPath $mj -PathType Leaf)) { $problems.Add('missing: manifest.json') }
    else {
        try {
            $m2 = Get-Content -LiteralPath $mj -Raw -Encoding UTF8 | ConvertFrom-Json
            if (@($m2.Endpoints).Count -ne @($Manifest.Endpoints).Count -or @($m2.AppSettings.Entries).Count -ne $entries.Count) { $problems.Add('manifest.json does not match the backup it describes') }
        }
        catch { $problems.Add("manifest.json does not parse: $($_.Exception.Message)") }
    }
    return $problems.ToArray()
}

# --- Command line -----------------------------------------------------------

# Unknown or contradictory combinations fail closed: a switch that would be
# silently ignored is a run the operator did not ask for.
function Get-AudioCleanerModeError {
    param([bool]$Clean, [string]$Restore, [bool]$ListOnly, [bool]$KeepExposedPorts, [bool]$SkipAppSettings)
    $hasRestore = -not [string]::IsNullOrWhiteSpace($Restore)
    if ($Clean -and $hasRestore) { return 'Cannot use -Clean and -Restore together.' }
    if ($ListOnly -and ($Clean -or $hasRestore)) { return '-ListOnly cannot be combined with -Clean or -Restore.' }
    if (($KeepExposedPorts -or $SkipAppSettings) -and -not $Clean) { return '-KeepExposedPorts and -SkipAppSettings only apply to -Clean.' }
    return $null
}

function ConvertTo-PsSingleQuoted {
    param([string]$Text)
    return "'" + ($Text -replace "'", "''") + "'"
}

# Everything the elevated child needs, as PowerShell source tokens. Paths are
# relayed already rooted: the elevated child starts in System32, not in the
# operator's folder. COMMON parameters live outside param() and are relayed
# explicitly - a -WhatIf that does not cross the UAC boundary turns a preview
# into a real run.
function Get-AudioRelayArguments {
    param([System.Collections.IDictionary]$Bound, [bool]$WhatIfRequested, [bool]$VerboseRequested)
    $out = [System.Collections.Generic.List[string]]::new()
    foreach ($name in 'Clean', 'KeepExposedPorts', 'SkipAppSettings', 'CreateRestorePoint', 'Force') {
        if ($Bound.Contains($name) -and [bool]$Bound[$name]) { $out.Add("-$name") }
    }
    foreach ($name in 'Restore', 'LogPath', 'BackupPath', 'TargetSid') {
        if ($Bound.Contains($name) -and -not [string]::IsNullOrWhiteSpace([string]$Bound[$name])) {
            $out.Add(('-{0} {1}' -f $name, (ConvertTo-PsSingleQuoted ([string]$Bound[$name]))))
        }
    }
    if ($Bound.Contains('Confirm')) { $out.Add(('-Confirm:${0}' -f ([bool]$Bound['Confirm']).ToString().ToLowerInvariant())) }
    if ($WhatIfRequested)  { $out.Add('-WhatIf') }
    if ($VerboseRequested) { $out.Add('-Verbose') }
    return $out.ToArray()
}

# One -Command string. Without the trailing "exit $LASTEXITCODE" an exit code
# from the script collapses to 1 and "partial" can no longer be told from
# "aborted".
function New-AudioElevationCommand {
    param([string]$ScriptPath, [string[]]$RelayArguments)
    return ("& {0} {1}; exit `$LASTEXITCODE" -f (ConvertTo-PsSingleQuoted $ScriptPath), (@($RelayArguments) -join ' '))
}

# Fail closed: verify -WhatIf is in the bytes about to be launched.
function Test-WhatIfRelayed {
    param([string]$Command, [bool]$WhatIfRequested)
    if (-not $WhatIfRequested) { return $true }
    return ($Command -match '(?i)(?<=\s)-WhatIf(?=\s|;|")')
}

function Test-IsAdministrator {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Every exit after the transcript starts goes through here, so the log is
# always closed.
function Stop-Run {
    param([int]$Code)
    if ($script:TranscriptStarted) { try { Stop-Transcript | Out-Null } catch { Write-Verbose "Stop-Transcript: $($_.Exception.Message)" } }
    exit $Code
}

# --- Main -------------------------------------------------------------------

if ($Force) { $ConfirmPreference = 'None' }

# A 32-bit PowerShell on 64-bit Windows sees a redirected HKLM\SOFTWARE, so
# every read and delete below would aim at the wrong registry view.
if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
    Write-Host 'Run the 64-bit Windows PowerShell; 32-bit PowerShell sees a redirected HKLM\SOFTWARE.' -ForegroundColor Red
    exit 1
}

$modeError = Get-AudioCleanerModeError -Clean $Clean.IsPresent -Restore $Restore -ListOnly $ListOnly.IsPresent `
                                       -KeepExposedPorts $KeepExposedPorts.IsPresent -SkipAppSettings $SkipAppSettings.IsPresent
if ($modeError) { Write-Host $modeError -ForegroundColor Red; exit 1 }

# Resolve every path to a ROOTED path before elevation: the elevated child's
# working directory is System32, not the operator's.
$stamp = '{0:yyyyMMdd_HHmmss}' -f (Get-Date)
if ([string]::IsNullOrWhiteSpace($LogPath)) { $LogPath = Join-Path $env:TEMP "AudioDevices_$stamp.log" }
else {
    try { $LogPath = [IO.Path]::GetFullPath([IO.Path]::Combine((Get-Location).ProviderPath, $LogPath)) }
    catch { Write-Host "Invalid -LogPath '$LogPath': $($_.Exception.Message)" -ForegroundColor Red; exit 1 }
}
if ([string]::IsNullOrWhiteSpace($BackupPath)) { $BackupPath = Join-Path $env:TEMP "AudioDevices_$stamp" }
else {
    try { $BackupPath = [IO.Path]::GetFullPath([IO.Path]::Combine((Get-Location).ProviderPath, $BackupPath)) }
    catch { Write-Host "Invalid -BackupPath '$BackupPath': $($_.Exception.Message)" -ForegroundColor Red; exit 1 }
}
if (-not [string]::IsNullOrWhiteSpace($Restore)) {
    try { $Restore = [IO.Path]::GetFullPath([IO.Path]::Combine((Get-Location).ProviderPath, $Restore)) }
    catch { Write-Host "Invalid -Restore path '$Restore': $($_.Exception.Message)" -ForegroundColor Red; exit 1 }
    if (-not (Test-Path -LiteralPath $Restore -PathType Leaf)) { Write-Host "Restore manifest not found: $Restore" -ForegroundColor Red; exit 1 }
}

# The user whose per-app settings are pruned. Captured BEFORE elevation: after a
# UAC prompt answered by a different administrator, HKCU is that admin's hive.
if ([string]::IsNullOrWhiteSpace($TargetSid)) { $TargetSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value }

if (-not $Clean -and [string]::IsNullOrWhiteSpace($Restore)) { $ListOnly = [switch]$true }

if (-not $ListOnly -and -not (Test-IsAdministrator)) {
    Write-Host 'Administrator rights required. Relaunching elevated...' -ForegroundColor Yellow
    if ([string]::IsNullOrWhiteSpace($PSCommandPath)) {
        Write-Host 'Cannot self-elevate: the script path is unknown. Run it with -File, or from an elevated PowerShell.' -ForegroundColor Red
        exit 1
    }
    $bound = @{}
    foreach ($k in $PSBoundParameters.Keys) { $bound[$k] = $PSBoundParameters[$k] }
    $bound['LogPath'] = $LogPath; $bound['BackupPath'] = $BackupPath; $bound['TargetSid'] = $TargetSid
    if (-not [string]::IsNullOrWhiteSpace($Restore)) { $bound['Restore'] = $Restore }
    $relay = @(Get-AudioRelayArguments -Bound $bound -WhatIfRequested ([bool]$WhatIfPreference) -VerboseRequested ($VerbosePreference -eq 'Continue'))
    $inner = New-AudioElevationCommand -ScriptPath $PSCommandPath -RelayArguments $relay
    if (-not (Test-WhatIfRelayed -Command $inner -WhatIfRequested ([bool]$WhatIfPreference))) {
        Write-Host 'Refusing to elevate: -WhatIf was requested but is not in the elevated command line.' -ForegroundColor Red
        exit 1
    }
    $psExe = (Get-Process -Id $PID).Path
    if ([string]::IsNullOrWhiteSpace($psExe)) { $psExe = 'powershell.exe' }
    try {
        $child = Start-Process -FilePath $psExe -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $inner) `
                               -Verb RunAs -Wait -PassThru
        $code = 0
        if ($child -and $null -ne $child.ExitCode) { $code = $child.ExitCode }
        exit $code
    }
    catch {
        Write-Host "Elevation was cancelled or failed: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
}

# Start-Transcript is ShouldProcess-aware: under -WhatIf it would only preview
# itself and the announced log would never be written.
$script:TranscriptStarted = $false
try {
    $logDir = Split-Path -Parent $LogPath
    if ($logDir -and -not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force -WhatIf:$false | Out-Null }
    Start-Transcript -Path $LogPath -Append -WhatIf:$false | Out-Null
    $script:TranscriptStarted = $true
}
catch { Write-Host "Could not start the transcript at '$LogPath': $($_.Exception.Message)" -ForegroundColor Yellow }

if ($ListOnly) {
    Write-AudioCensus -Census (Get-AudioCensus -TargetSid $TargetSid)
    Write-Host ''
    Write-Host "Log: $LogPath" -ForegroundColor Gray
    Stop-Run 0
}

if ($Clean) {
    $census = Get-AudioCensus -TargetSid $TargetSid -KeepExposedPorts:$KeepExposedPorts -SkipAppSettings:$SkipAppSettings
    Write-AudioCensus -Census $census
    $code = Invoke-AudioClean -Census $census -BackupPath $BackupPath -TargetSid $TargetSid -KeepExposedPorts:$KeepExposedPorts `
                              -SkipAppSettings:$SkipAppSettings -CreateRestorePoint:$CreateRestorePoint -Force:$Force
    Stop-Run ([int]$code)
}

# -Restore is the only mode left; the mode guard admitted nothing else.
$code = Invoke-AudioRestore -ManifestPath $Restore -Force:$Force
Stop-Run ([int]$code)
