# Clean-AudioDevices.ps1 — design

Status: **approved and implemented** (live-run findings in section 6, item 11). Sections 1–3 were approved in
conversation on 2026-10-05, then revised after a read-only de-risking review: workflow
`wf_83485bae-9b5`, 5 research agents, 2 critics and 21 verifiers. A second user decision followed
on the same day: remove all 42 dead entries by default. Section 6 lists every change the review
made and why.

## Goal

Settings → System → Sound → All sound devices lists every audio endpoint Windows has ever built.
On this machine it labels the not-present ones **Disabled** (measured from the user's screenshot).
There are 62 entries and 11 are live. The user wants the list to show only real devices, and
nothing current may be touched: the SteelSeries Sonar virtual devices, the monitor's NVIDIA HDMI
audio, the Realtek jacks, and the paired Bluetooth earbuds and speakers.

**Success** means four things:

- After `-Clean`, the list holds only active, user-disabled and unplugged endpoints, plus whatever
  Windows itself rebuilds. Those rebuilt entries are reported by name.
- Every live device still plays and records.
- The audio services are running when the script exits.
- `-Restore` puts back every key a run removed, byte for byte, including its security
  descriptor.

## Measured facts this design rests on

All of these were read on this machine (Windows 11 Pro 26200) unless a source is named.

### The endpoint store

- **Where endpoints live.** Each endpoint is a key at
  `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\{Render|Capture}\{guid}`, with
  `Properties` and `FxProperties` subkeys. This is the store Settings reads.
  `pnputil /remove-device` touches only the PnP `Enum` tree and leaves these keys in place.
- **The state.** `DeviceState` keeps the documented `DEVICE_STATE_*` value in its low 4 bits:
  Active 1, Disabled 2, NotPresent 4, Unplugged 8 (`DEVICE_STATEMASK_ALL` = 0xF).
  - The high bits seen here (`0x10000000`, `0x20000000`, `0x01000000`) are undocumented and
    carry no "do not touch" meaning.
  - Masking with 0xF gives the right state for all 62 entries.
- **Properties used:**

  | Value | What it holds |
  |---|---|
  | `{b3f8fa53-0004-438e-9003-51a46e139bfc},2` | Parent devnode instance id, prefixed `{1}.`. Present on all 62 entries. |
  | `,6` | Interface friendly name |
  | `{a45c254e-df1c-4efd-8020-67d146a850e0},2` | Endpoint name |
  | `{b3f8fa53-0004-438e-9003-51a46e139bfc},11` | Topology filter interface path |
  | `{233164c8-1b2c-4c7d-bc68-b671687a2567},1` | Wave filter interface path |
  | `{9dad2fed-2266-4b18-a759-47e7816c60bf},0` | Multi-string of filter paths, each with a `/…` suffix |
  | `{9c119480-ddc2-4954-a150-5bd240d454ad},2` | The endpoint's own `SWD\MMDEVAPI\…` devnode id, when it has one |

  The last four together are the endpoint's **interface references**. 15 of the 42 dead entries
  record none of them.
- **Who may change the keys.** Owner SYSTEM. The `Audiosrv` and `AudioEndpointBuilder` service
  SIDs have Delete and CreateSubKey; TrustedInstaller has FullControl. **Administrators hold only
  SetValue + ReadKey**. Every ACE on these keys is inherited and none is protected.

### How Windows rebuilds endpoints

- **What the endpoint builder does.** `AudioEndpointBuilder` creates one endpoint per bridge pin
  of every **enabled** `KSCATEGORY_AUDIO` interface each time it starts, and rewrites
  `DeviceState` as it goes (Microsoft, *Audio Endpoint Builder Algorithm*).
- **What that means for deleted keys.** A deleted entry whose interface is still enabled, and
  which no live entry already holds, comes back at the next service start **under a new GUID**.
  An entry whose interface is gone stays gone.
- **The enabled interfaces here:**

  | Device | Enabled interfaces |
  |---|---|
  | AMD | `e0`–`e3hdmiouttopo` |
  | NVIDIA | `topo00`–`topo03`, `wave09`, `wave0a` |
  | Realtek | `rearlineoutwave3`, `rtlineintopo`/`wave`, `rtmicintopo`/`wave`, `rtstereomixtopo`/`wave`, `singlelineouttopo` |

  These come from `pnputil /enum-interfaces /enabled`. That output is localised, so the script
  asks the configuration manager directly instead.

### Services and devnodes

- **Stopping is required.** The services must be stopped before deleting. A running endpoint
  builder reasserts its own view of these keys.
- **Dependents.** `AudioEndpointBuilder`'s dependents are `Audiosrv`, `midisrv`,
  `RtkAudioUniversalService`, `AarSvc` and `AarSvc_<luid>`. `Audiosrv` has no trigger-start: it
  must be started explicitly.
- **Ghost devnodes.** `SWD\MMDEVAPI\…` devnodes are created by the endpoint builder for endpoints
  that have keys. Only 3 of the 42 dead entries have one; 10 other not-present devnodes belong to
  unplugged or active endpoints and are kept.
- **Internal vs external hardware.** All internal audio parents (NVIDIA, AMD, Realtek HDAUDIO
  functions, Sonar's `ROOT\MEDIA\0000`) carry ContainerID `{00000000-0000-0000-ffff-ffffffffffff}`,
  the "this PC" container, with RemovalPolicy 1. A Thunderbolt dock or an eGPU carries its own
  container.

### Per-app settings

- **The store.** `HKCU\Software\Microsoft\Internet Explorer\LowRegistry\Audio\PolicyConfig\PropertyStore`
  holds 543 subkeys. Each one has exactly one REG_SZ default value and no subkeys.
- **The value.** It looks like
  `{n}.\\?\<bus>#<hardware-id>#{category}\<filter>…|<app path or #%b{guid}>`. It carries no
  instance segment.
- **Who writes it.** `audioses.dll`, in-process in each app. Audiosrv never writes it.
- **Comparing paths.** Values are lower-case and PnP instance ids are upper-case, so the
  comparison must ignore case.
- **What's dead.** 333 entries point at fixed-bus hardware with no present devnode. A further 2
  point at an absent USB device and are kept.

### Existing code to follow

- **Take-ownership fallback.** `scripts/windows/Reset-SearchIndex.ps1` has `Enable-TokenPrivilege`
  (the `IczTokenPriv` P/Invoke wrapper, checking `ERROR_NOT_ALL_ASSIGNED`) and the take-ownership
  routine `Set-ProtectedRegValue`.
- **Elevation, `-TargetSid`, restore points, transcript.** `scripts/windows/Remove-WindowsBloat.ps1`
  holds the reference self-elevation (relays and re-checks `-WhatIf`, ends with
  `; exit $LASTEXITCODE`), the `-TargetSid` relay, `-CreateRestorePoint`, and
  `Start-Transcript … -WhatIf:$false`.
- **StrictMode-safe reads.** `scripts/autodesk/Uninstall-Revit.ps1` holds `Get-Prop`.

## 1. What gets removed

Removal is decided by **state and location, never by name** (repo invariant 11).

| Endpoint `DeviceState & 0xF` | Parent | Verdict |
|---|---|---|
| 1 Active, 2 Disabled, 8 Unplugged | any | **KEEP** |
| 4 NotPresent | instance id gone from `HKLM\SYSTEM\CurrentControlSet\Enum` | **REMOVE** — *orphaned* |
| 4 | bus `HDAUDIO`, `INTELAUDIO`, `PCI` or `ACPI` **and** ContainerID is the "this PC" container | **REMOVE**, labelled as below |
| 4 | the same buses, but any other ContainerID (dock, eGPU, monitor) | **KEEP** — *external, not connected* |
| 4 | bus `USB`, `BTHENUM`, `BTHHFENUM`, `BTHLEDevice`, `ROOT`, `SW`, `SWD`; parent still exists | **KEEP** — *removable, not connected* |
| 4 | any other bus | **KEEP**, reported (fail closed) |
| anything else, or a required value missing or malformed | — | **KEEP**, reported (fail closed) |

### Labels for REMOVE rows

The labels are report-only and decide nothing. Each one says whether Windows will rebuild the entry:

| Label | Meaning | Windows rebuilds it? | Count here |
|---|---|---|---|
| *interface gone* | none of its interface references is enabled | no | 11 |
| *duplicate* | a live entry holds the same filter | no | 3 |
| *no interface recorded* | it records no interface references | probably not; checked after restart | 15 |
| *port still exposed* | an enabled interface that no live entry holds | **yes, under a new GUID** | 7 |

- **The 7 here:** AMD "Digital Output" ×4, and NVIDIA `topo00` ×2 and `topo03` ×1.
- **Default:** all of them go (the user's decision). `-KeepExposedPorts` keeps the *port still
  exposed* rows.
- **If the enabled-interface query fails**, every label reads *unknown*. That changes nothing
  about what is removed.

### Per-app settings

These are pruned by default; `-SkipAppSettings` opts out. An entry is removed only when all of
these hold:

- the device part of its value parses;
- the bus is `hdaudio` or `intelaudio`;
- no present devnode's instance id starts with that `bus\hardware-id`, compared ignoring case.

Anything else is kept, including USB, Bluetooth, root and unparseable entries.

### Out of scope

The old laptop's ghost PCI HDA controller and the stale audio driver packages. The report points
at `Remove-LegacyHardwareResidue.ps1 -Scope Platform,Audio`.

### Expected on this machine

| | Count |
|---|---|
| Endpoint keys removed | 42 (6 + 11 + 3 + 15 + 7) |
| Endpoints kept | 20 |
| Rebuilt by Windows, predicted | 7 or fewer, under new GUIDs (`topo00` had two claimants and gets one rebuild) |
| Ghost devnodes removed | 3 |
| Per-app entries removed | 333 |

## 2. Run flow

### Parameters

```
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
[switch] ListOnly          census only; also the default when no action switch is given
[switch] Clean             remove (needs elevation; self-elevates)
[switch] KeepExposedPorts  with -Clean: keep 'port still exposed' entries
[switch] SkipAppSettings   with -Clean: leave per-app settings alone
[string] Restore           path to a manifest.json from an earlier run (self-elevates)
[switch] CreateRestorePoint
[switch] Force             skip the confirmation prompt
[string] LogPath           default %TEMP%\AudioDevices_<stamp>.log
[string] BackupPath        default %TEMP%\AudioDevices_<stamp>\   (a folder)
[string] TargetSid         INTERNAL: relayed across elevation; never typed by a user
```

### Prologue

These steps run in this order, all before elevation:

1. `$ErrorActionPreference = 'Stop'; Set-StrictMode -Version Latest`, then
   `if ($Force) { $ConfirmPreference = 'None' }`.
2. **Mode guards** (fail closed, exit `1`): `-Clean` together with `-Restore`, and `-ListOnly`
   together with either of them. `-KeepExposedPorts` or `-SkipAppSettings` without `-Clean` is
   refused out loud, not silently ignored.
3. **Path rooting.** `-LogPath`, `-BackupPath` and `-Restore` are resolved to absolute paths with
   `[IO.Path]::GetFullPath([IO.Path]::Combine((Get-Location).ProviderPath, $value))`. A
   `-Restore` file that doesn't exist exits `1`.
4. `$TargetSid` defaults to `[Security.Principal.WindowsIdentity]::GetCurrent().User.Value`.
5. **Self-elevation** for `-Clean`/`-Restore` when not elevated. Copy `Remove-WindowsBloat.ps1`:
   - relay every bound parameter plus `-TargetSid`, `-WhatIf`, `-Confirm`, `-Verbose` and
     `-Debug`;
   - when `$WhatIfPreference` is set, assert that the assembled command line contains `-WhatIf`
     (regex `(?i)(?<=\s)-WhatIf(?=\s|;|")`), and refuse to elevate (exit `1`) if it doesn't;
   - end the `-Command` string with `; exit $LASTEXITCODE`;
   - a declined UAC prompt exits `1`.
6. `Start-Transcript -Path $LogPath -Append -WhatIf:$false`. Do not copy
   `Clean-StartupApps.ps1:215`, which lacks the flag; that bug is flagged separately.

### Steps of a `-Clean` run, and what `-WhatIf` does at each

| # | Step | Normal run | Under `-WhatIf` |
|---|---|---|---|
| 1 | Census + plan | runs | runs, and prints the full plan |
| 2 | Confirm | the prompt names the counts, warns of about 10 s without sound, and says apps that were playing (Sonar included) may need restarting. `-Force` skips it. | skipped (an explicit `$WhatIfPreference` check, not left to ShouldProcess) |
| 3 | Backup | writes the files, then verifies them (below) | reports what it would write; writes nothing |
| 4 | Restore point | only with `-CreateRestorePoint`; the 24-hour refusal is a WARN, not a failure | skipped |
| 5 | Stop services | records which dependents are running, then stops `AudioEndpointBuilder` (`Audiosrv` goes with it) | skipped |
| 6 | Endpoints | `Remove-AudioEndpointKey` per target | ShouldProcess preview per target |
| 7 | Ghost devnodes | `pnputil /remove-device` for confirmed deletions only | preview |
| 8 | Per-app settings | `Remove-AppAudioSetting` per entry | preview |
| 9 | `finally`: start services | below | skipped (nothing was stopped) |
| 10 | Verify + rebuild check | below | skipped |

If nothing is eligible after step 1, the run exits `2` before step 2.

### Backup layout (step 3)

`$BackupPath\` holds:

- `endpoints\<Flow>_<guid>.hiv`: `reg save` of each target key. The hive file keeps every
  value **and the security descriptor**. Restore uses this file.
- `endpoints\<Flow>_<guid>.reg`: `reg export` of the same key, for people to read.
- `appsettings.reg`: one generated file of the per-app entries being removed. Each entry is
  measured to be exactly one REG_SZ default value; any entry of another shape falls back to its
  own `reg export`.
- `manifest.json`, which records:
  - the computer name, `TargetSid`, script version and timestamp;
  - every endpoint with its flow, GUID, name, interface name, parent, label and backup files;
  - every per-app key name;
  - the devnodes to remove.

**Verification.** Every `.hiv` and `.reg` file must exist and be non-empty. Each `.reg` must
start with `Windows Registry Editor Version 5.00` and contain its key's header line. The manifest
must re-parse with the same counts. **Any failure exits `1` before anything is touched.**

### Endpoint deletion (step 6): `Remove-AudioEndpointKey`

The guard lives **inside** the function (invariant 12).

**Guards, in order:**

1. The path must match
   `^HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\MMDevices\\Audio\\(Render|Capture)\\\{[0-9a-fA-F-]{36}\}$`.
2. Re-read the key now, with the services stopped, and re-run `Get-AudioEndpointVerdict` on the
   fresh record. Anything other than REMOVE is skipped and reported (*changed since census*).
3. `-KeepExposedPorts` is honoured here as well as in the plan.

**Mechanism (no ACL is ever modified):**

1. Enable `SeRestorePrivilege` and `SeBackupPrivilege` through `Enable-TokenPrivilege`. A
   failure is a hard stop for that key.
2. For every key in the subtree, deepest first (enumerated, never hard-coded to
   `Properties`/`FxProperties`), open it with `RegOpenKeyEx(…, REG_OPTION_BACKUP_RESTORE, …)`.
   Under `SeRestorePrivilege` that grants DELETE (Microsoft, `RegOpenKeyEx`). Then delete it
   with `NtDeleteKey(handle)` and close the handle.
3. Re-open the GUID path afterwards. It must be gone.

**Fallback.** If the replica harness (§3) shows the mechanism fails, the fallback is the
`Reset-SearchIndex.ps1` take-ownership route, applied **per key in the subtree** with a
**non-inheritable** ACE. It only takes effect after an explicit, separately approved spec change.

### Ghost devnodes (step 7)

- The list is built **from confirmed deletions, never from the census plan**, so an endpoint
  skipped by the re-read can't lose its devnode.
- A devnode is removed only when `HKLM\SYSTEM\CurrentControlSet\Enum\SWD\MMDEVAPI\{0.0.<0|1>.00000000}.{guid}`
  exists. The flow digit is 0 for Render and 1 for Capture.
- `pnputil /remove-device "<id>"` exit codes: `0` is OK, `3010` means reboot pending, and anything
  else is counted as a failure.

### Per-app pruning (step 8): `Remove-AppAudioSetting`

- **Location.** The function addresses
  `Registry::HKEY_USERS\<TargetSid>\Software\Microsoft\Internet Explorer\LowRegistry\Audio\PolicyConfig\PropertyStore`.
  If that hive isn't loaded, the step is skipped with a WARN.
- **Guard.** It re-checks the §1 per-app rule inside the function.
- **Null safety.** The parse result is null-checked before use. A value read from the registry
  never appears as the **pattern** of a `-match`, because `-match $null` is true.

### `finally` (step 9) and the critical window

Between step 5 and step 9, audio is down. Three layers protect the restart:

1. **No Ctrl+C.** `[Console]::TreatControlCAsInput = $true` for the window, in a `try` because
   ISE has no console. The old value is restored in `finally`.
2. **Exit handler.** A `Register-EngineEvent PowerShell.Exiting` handler starts
   `AudioEndpointBuilder`, then `Audiosrv`, with `sc.exe start`.
3. **`finally`** starts `AudioEndpointBuilder`, then `Audiosrv`, then only the dependents that
   were running. Each start is retried 3 times, 2 s apart. If either core service is not Running
   afterwards, the run prints the two `sc start` recovery commands and exits `3`.

### Verify and rebuild check (step 10)

- **Settle.** Wait until the endpoint key count is stable for 3 s, up to 30 s.
- **Removed keys.** Every removed GUID must still be absent; otherwise that's a failure.
- **Kept keys.** Every kept GUID must still exist, and every Active entry must still be Active;
  otherwise that's a failure.
- **Rebuilt entries.** Any **new** GUID that shares an interface reference, or the same parent
  and name, with a removed entry is reported as **rebuilt by Windows**. That is information, not
  a failure.
- **AMD hint.** When the rebuilt entries include the AMD "Digital Output" ports, the report adds
  one line: disabling "AMD High Definition Audio Device" in Device Manager, if sound never comes
  from the motherboard's video outputs, lets a later run remove them for good.

### `-Restore <manifest.json>`

- **Pre-checks** (exit `1` on failure): the manifest's computer name must match, and every
  referenced backup file must exist.
- **Services and the critical window.** Stop the services, with the same three protections as
  `-Clean`.
- **Endpoints.** For each endpoint in the manifest:
  - if its GUID key **already exists**, skip it and report it (never import over a live key);
  - otherwise, with `SeRestorePrivilege`/`SeBackupPrivilege` enabled, create the empty key with
    `RegCreateKeyEx(…, REG_OPTION_BACKUP_RESTORE, …)` and run `reg restore <key> <file>.hiv`.
    This restores the values, subkeys, **owner and DACL** exactly as they were.
- **Per-app settings.** Import entries from `appsettings.reg` only where the key doesn't exist
  now. These go to `HKEY_USERS\<the manifest's TargetSid>`.
- **Ghost devnodes** are not restored; the endpoint builder recreates them for restored keys.
- **Finish.** `finally` restarts the services, then the run verifies that every restored key exists.

### Exit codes

These follow the shared contract:

| Code | Meaning |
|---|---|
| `0` | Success. Entries Windows rebuilt are not failures. |
| `3010` | Success, but `pnputil` reported a reboot is needed. |
| `2` | Nothing to do. |
| `3` | Partial: a delete, devnode, prune or restore failed; a verify check failed; or the services did not restart. |
| `1` | Aborted: invalid mode combination, elevation declined, `-WhatIf` relay check failed, invalid path, backup failed, manifest missing or from another computer. |

## 3. Code shape

- **StrictMode-safe reads.** Registry reads go through a `Get-Prop`-style reader that handles
  both a `$null` object and a missing property (repo F, checklist 15).
- **Empty results.** Every result that may be empty is wrapped in `@()` before `.Count`
  (checklist 20).
- **Three layers:**
  1. **Gatherers.** `Get-AudioEndpointRecord` (MMDevices plus the parent's Enum facts:
     exists, bus, ContainerID), `Get-EnabledAudioInterface` (via `CM_Get_Device_Interface_List`
     with `CM_GET_DEVICE_INTERFACE_LIST_PRESENT` for `KSCATEGORY_AUDIO`; it returns `$null` on
     failure, which turns every label to *unknown*), and `Get-AppAudioSettingRecord`.
  2. **Pure functions.** `Get-AudioEndpointVerdict` and `Get-AppAudioSettingVerdict` take plain
     records and return `{ Action = 'Keep'|'Remove'; Label; Reason }`. They have no side effects
     and read no globals, so the test harness can drive them directly.
  3. **Actors.** `Remove-AudioEndpointKey`, `Remove-AppAudioSetting`, `Remove-GhostEndpointDevnode`,
     `Stop-AudioStack`/`Start-AudioStack`, `Backup-AudioTargets` and `Restore-AudioTargets`.
- **Native calls.** P/Invoke goes in a single `Add-Type` block guarded by
  `-not ('IczAudioNative' -as [type])`: `AdjustTokenPrivileges` (copied from `IczTokenPriv`),
  `RegOpenKeyEx`/`RegCreateKeyEx` with backup semantics, `NtDeleteKey`, `RegCloseKey` and
  `CM_Get_Device_Interface_List(_Size)`.

## 4. Files, integration and tests

### New files

- `scripts/windows/Clean-AudioDevices.ps1`.
- **`scripts/windows/Clean-AudioDevices.cmd`**, a launcher in the `Clean-StartupApps.cmd` shape:
  - menu `[1]` census, `[2]` clean, `[3]` clean keeping exposed ports, `[4]` restore from manifest;
  - then preview Y/N, then a summary with a confirm;
  - with arguments it passes them straight through;
  - `choice` results are tested in descending order and branched on before any `set`;
  - the pause test reads `CMDCMDLINE` through `LAUNCHLINE`.

  It is written **CRLF**, like every sibling `.cmd` (measured; cmd's label search misbehaves
  with LF-only files). `.gitattributes` already says `*.cmd eol=crlf`. The new `.ps1` files are
  CRLF too, matching `.gitattributes` and most siblings; edits to existing files keep each file's
  own line endings.
- **`tests/Test-AudioEndpointClassifier.ps1`**. Unelevated, never touches the registry. It
  covers:
  - every state (including high-bit variants) × every bus × parent exists/missing ×
    ContainerID internal/external × interface enabled/gone/duplicate/none;
  - missing or malformed fields, which must come out KEEP;
  - an unknown bus, which must come out KEEP;
  - the path guard (`…\Render\{GUID}` accepted; parent keys, other trees and trailing segments
    refused);
  - per-app parsing, including case, a null value, `usb#`, `bthenum#`, `root#` and junk.

  Its **`-ExpectDefective`** mode swaps in a classifier that treats every NotPresent entry as
  removable regardless of bus or container. The harness **must fail** in that mode, on the
  `ROOT`/`USB`/external cases. That proves it can fail.
- **`tests/Test-AudioRegistryMechanism.ps1`**. **Elevated, scratch keys only.**
  - **Builds a replica** under `HKLM\SOFTWARE\IczAudioMechanismTest\Render\{guid}` with
    `Properties`/`FxProperties`. It gives the replica the **same owner and DACL shape** as the
    real `Render` key: owner SYSTEM, Administrators SetValue+ReadKey only, inherited.
  - **Proves:**
    1. a plain `Remove-Item` is denied (the replica really is locked);
    2. `Remove-AudioEndpointKey`'s mechanism deletes it;
    3. `reg save` → delete → backup-semantics create → `reg restore` brings back the values,
       owner and DACL, compared against a snapshot;
    4. no ACL anywhere in the replica changed during the delete;
    5. the path guard refuses the replica root.
  - **Never touches** `MMDevices`.
  - Its `-ExpectDefective` mode runs the delete without enabling `SeRestorePrivilege` and must
    fail at step 2.
  - It removes the scratch tree at the end, and also on failure.

### Edits

- **`hub/catalog.json`:**
  ```json
  { "id": "clean-audiodevices", "name": "Clean audio devices",
    "file": "scripts/windows/Clean-AudioDevices.ps1", "group": "windows",
    "summary": "Not-present audio endpoints from previous hardware and drivers, their ghost devnodes and dead per-app audio settings. Census first; backup and restore.",
    "elevation": "self", "risk": "medium", "preview": ["-ListOnly"],
    "logPattern": "AudioDevices_*.log" }
  ```
  Checked against the live catalog on 2026-10-05:
  - group `windows` exists;
  - every entry carries exactly these nine fields;
  - `self` and `medium` are values already in use.
- **`README.md`:** a script section in the house style. It covers what it removes, what it never
  touches, why entries can come back, the mode table and the exit-code paragraph. Plus a
  quick-reference row, and a line in the exit-code contract.
- **`docs/LESSONS_LEARNED.md`:** checklist rows:
  - audio removal is decided by `DeviceState & 0xF`, the parent's bus and its ContainerID, never
    by name;
  - registry keys Administrators can't delete are opened with backup semantics, not taken over;
  - the audio services are restarted under three layers (no Ctrl+C, an exit handler,
    `finally` with retries);
  - per-app pruning uses `HKEY_USERS\<TargetSid>`;
  - the SWD devnode list comes from confirmed deletions.

  Also a short section on why a deleted endpoint can come back: the endpoint builder rebuilds
  every enabled pin.

### Verification on this machine

Steps 4 to 6 need the user's go-ahead:

1. Run `Test-AudioEndpointClassifier.ps1`: it passes. Then run it with `-ExpectDefective`: it fails.
2. Run `Test-AudioRegistryMechanism.ps1` elevated: it passes. Then run it with `-ExpectDefective`:
   it fails.
3. Run the census unelevated. Expect 42 REMOVE (6 / 11 / 3 / 15 / 7 by label), 20 KEEP, and
   333 per-app entries.
4. Run `-Clean -WhatIf` elevated. It must change nothing: compare a registry snapshot taken
   before and after.
5. Run the real `-Clean`. Then check:
   - the Settings list;
   - playback on Sonar, the monitor and the earbuds;
   - the **rebuilt-by-Windows** report against the 7 predicted.
6. Run `-Restore` with the manifest. The keys return with their original ACLs (compare `Get-Acl`
   with the backup). Then run a second `-Clean` to finish clean.

## 5. Out of scope

- Disabling or uninstalling any device.
- The AMD HDMI audio device: the report only hints at it.
- Driver-store packages and PCI ghosts, which are `Remove-LegacyHardwareResidue.ps1`'s job.
- Per-endpoint settings in `FxProperties` of live endpoints.
- Bluetooth pairings.

## 6. Changes from the de-risking review

Each change is verified (refuter run) unless marked as measured.

1. **Exposed ports come back** (research, plus measured: enabled interfaces against interface
   references). Labels were added and the post-restart rebuild check introduced. The user then
   chose to remove all 42 by default, with `-KeepExposedPorts` as the opt-out.
2. **No ACL modification on delete or restore.** The research and the safety critic disagreed on
   whether `SetAccessControl` propagates inheritable ACEs, and .NET's `SetSecurityInfo` does
   auto-propagate. So backup-semantics handles plus `NtDeleteKey`, and `reg save`/`reg restore`,
   replace the take-ownership dance, which is kept as the fallback. Both are proven on a replica
   before any real key is touched.
3. **Restore never weakens the `Render`/`Capture` ACL** (safety, verified). This is solved by
   item 2.
4. **Ctrl+C in PowerShell 5.1 can abort a `finally`** (safety, verified). Three layers protect the
   service restart. `Audiosrv` is started explicitly.
5. **Thunderbolt docks and eGPUs** sit on `HDAUDIO` but are external (safety, verified). ContainerID
   ≠ "this PC" → KEEP. Measured: all internal parents carry the "this PC" container.
6. **SWD devnode list from confirmed deletions** (safety, verified).
7. **Repo blockers, all verified:**
   - `Start-Transcript -WhatIf:$false`;
   - `-WhatIf` relayed and re-checked across elevation;
   - `; exit $LASTEXITCODE`;
   - paths rooted before elevation;
   - mode-combination guards.
8. **Repo majors, verified:**
   - the `-TargetSid` relay;
   - `-Restore` path rooting and existence check;
   - the per-step `-WhatIf` table;
   - the `Get-Prop`-style reader;
   - `@()` at call sites;
   - `-match` null-pattern guards;
   - the exact hub entry;
   - `$ConfirmPreference = 'None'` with `-Force`.

   Refuted: `ConvertTo-List` (there are no list parameters), and `Test-PathSafe` for `Enum`
   lookups (the registry provider doesn't throw on any character, and instance ids can't carry
   the junk characters). Partly refuted: `-Clean` vs "default applies". The siblings split two
   and two; this script keeps `Clean-StartupApps.ps1`'s census-by-default shape, which the user
   approved.
9. **Minor:**
   - service-start retries;
   - backup verification beyond "non-empty";
   - the `-CreateRestorePoint` 24-hour WARN;
   - an explicit `-ExpectDefective` mutation;
   - `[switch]` types;
   - `Set-StrictMode -Version Latest`;
   - `.cmd` traps;
   - `3010` added to the exit codes;
   - per-app count corrected from 335 to 333, since the 2 USB entries are kept.
10. **Not changed: the Settings label.** A research agent said not-present entries show as
    "Disconnected". The user's screenshot shows **Disabled** on this machine. User-facing text says
    "shown as Disabled (or Disconnected on some builds)".
11. **Live-run findings** (first real clean and restore round trip on this machine):
    - Windows rebuilt 16 of the 42, not 7: the 10 Realtek multi-jack capture endpoints record no
      interface but the driver exposes them. The label rule now marks an endpoint with no
      interface references as *port still exposed* when its interface name equals the parent's
      current driver name; the 5 generic-driver ones stayed gone and keep *no interface recorded*.
      The user chose to keep removing the rebuilt ports on every run.
    - On restore, the endpoint builder discarded the 10 restored Realtek jack keys after the
      restart because the rebuilt endpoints held their ports. A restore now verifies its keys
      before the restart and reports later discards as information, not failure.
    - Per-app entries may carry one subkey `{219ED5A0-9CBF-4F3A-B927-37C9E5C5F14F}` (stored
      volume/mute); backup and restore carry its values. Ghost devnode ids are derived from
      flow + GUID, because some endpoints record none.
12. **Found in passing:** `Clean-StartupApps.ps1:215` lacks `-WhatIf:$false`. This is
    pre-existing, out of scope, and flagged as its own task.
