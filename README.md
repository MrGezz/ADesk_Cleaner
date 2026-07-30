# Revit-Cleaner

Two PowerShell uninstallers for Autodesk Revit environments on Windows. Each targets a
different layer of the stack, and each is registry-driven, preview-first, and fully logged.

| Script | Removes | Elevation |
|---|---|---|
| [`Uninstall-Revit.ps1`](Uninstall-Revit.ps1) | **Autodesk Revit**, any year — core application plus its orphaned add-ins, content packs, and exporters | Required (self-elevates) |
| [`Uninstall-PyRevit-Complete.ps1`](Uninstall-PyRevit-Complete.ps1) | **pyRevit** and **pyRevit CLI** — clones, add-in manifests, Windows installation registrations, Start Menu entries, `PATH` entries | Optional |

> Both scripts share the same philosophy: discover what is installed from the registry
> rather than from hardcoded paths or GUIDs, invoke the vendor's own uninstaller wherever one
> exists, preview before acting, refuse to touch shared components, and log everything.

## Which script do I need?

| Situation | Script |
|---|---|
| Removing Revit itself | `Uninstall-Revit.ps1` |
| Revit uninstall fails with `1603`, `1606`, or `2753` | `Uninstall-Revit.ps1` — see [TROUBLESHOOTING.md](TROUBLESHOOTING.md) |
| pyRevit installer reports a **leftover installation folder** | `Uninstall-PyRevit-Complete.ps1` |
| pyRevit still listed in Add/Remove Programs after deleting its folder | `Uninstall-PyRevit-Complete.ps1` |
| pyRevit ribbon still loading, or a stale clone needs replacing | `Uninstall-PyRevit-Complete.ps1` |
| Wiping a machine completely | pyRevit first, then Revit |

Removing pyRevit before Revit lets pyRevit detach from each Revit installation while its CLI
still exists, which leaves no orphaned add-in manifests behind.

---

## `Uninstall-Revit.ps1` — Autodesk Revit

A scoped, self-elevating PowerShell script that cleanly uninstalls **any year of Autodesk Revit** on Windows — the core application plus its orphaned add-ins, content packs, and exporters — while deliberately preserving shared Autodesk components and other Autodesk products (AutoCAD, Navisworks, other Revit versions). The target release is chosen with `-ProductYear` (default `2026`).

Autodesk products don't uninstall as a single item. The core application, every add-in, and each content pack register as **separate** entries in Add/Remove Programs, and the core product uses Autodesk's ODIS installer whose command line is unquoted and easy to invoke incorrectly. This script discovers the right entries from the registry, invokes each vendor uninstaller correctly, and stops short of anything shared.

> Built and hardened against a real Revit 2026 removal, then generalized to any year. Conservative by design: it previews before acting, refuses to touch cross-version or shared components, and logs everything.

### Features

- **Any Revit year** via `-ProductYear` — one script for 2023–2027+.
- **Registry-driven discovery** across the 64-bit, 32-bit (WOW6432Node), and per-user uninstall hives — no hardcoded product GUIDs.
- **Correct ODIS invocation.** Runs Autodesk's `AdODIS\V1\installer.exe` directly (not through `cmd`), so its unquoted, space-containing path is handled properly.
- **Multi-method resolution** per product: cached local `.msi` (LocalPackage) → MSI product code → MSI with directory-property override (clears the stubborn "Error 1606 … `Revit <year>\`" case) → `QuietUninstallString` → raw `UninstallString`, trying each in order until one succeeds.
- **Per-attempt verbose MSI logs** (`%TEMP%\MSIVerbose_<guid>_<stamp>_<Kind>.log`), so a failed attempt's evidence is never overwritten by the next one.
- **Precise "Revit + year" sweep** for orphaned add-ins/content, with hard exclusions for shared and cross-version components.
- **Self-elevation** via UAC — launch from a normal shell (handles script paths containing spaces).
- **Preview mode** (`-ListOnly`) and full `-WhatIf` support.
- **Safe residual cleanup**, gated on a successful uninstall and guarded so it can only ever delete Revit/RVT `<year>` folders under an Autodesk tree.
- **Transcript logging** to `%TEMP%`.

### Requirements

- Windows 10/11
- Windows PowerShell 5.1 (built in) — no modules required
- Administrator rights (the script self-elevates via UAC)

### Usage

```powershell
# Preview only for the default year (2026) — lists matches, changes nothing:
powershell -ExecutionPolicy Bypass -File .\Uninstall-Revit.ps1 -ListOnly

# Preview a specific year:
powershell -ExecutionPolicy Bypass -File .\Uninstall-Revit.ps1 -ProductYear 2024 -ListOnly

# Interactive — prompts before each product and each residual folder:
powershell -ExecutionPolicy Bypass -File .\Uninstall-Revit.ps1 -ProductYear 2024

# Fully unattended and silent — closes Revit if open, no prompts:
powershell -ExecutionPolicy Bypass -File .\Uninstall-Revit.ps1 -ProductYear 2025 -StopRevit -Force

# Core application only — skip add-ins and residual cleanup:
powershell -ExecutionPolicy Bypass -File .\Uninstall-Revit.ps1 -ProductYear 2026 -IncludeAddins:$false -RemoveResidualFiles:$false
```

Run `-ListOnly` first. It is the safety gate: it shows exactly what will be removed before you commit.

### Parameters

| Parameter | Type | Default | Description |
|---|---|---|---|
| `-ProductYear` | string | `2026` | Four-digit Revit release year to target (e.g. `2024`). Scopes the core match, add-in sweep, residual folders, the residual guard, and the self-elevation relaunch. Validated as four digits. |
| `-IncludeAddins` | bool | `$true` | Also remove every product whose name references Revit **and** the target year (add-ins, content, exporters, DB Link, IFC, interop tools). Disable with `-IncludeAddins:$false`. |
| `-IncludeMaterialLibraries` | bool | `$false` | Opt in to also remove Material Library packages matching the target year. Off by default because material libraries are commonly shared across products. |
| `-NeutralizeBrokenCustomActions` | bool | `$true` | On `1603` + `Internal Error 2753`, automatically neutralize the broken custom action in a patched copy of the cached package, recache it (`/fv`), and retry — see [TROUBLESHOOTING.md](TROUBLESHOOTING.md). Disable with `-NeutralizeBrokenCustomActions:$false`. |
| `-RemoveResidualFiles` | bool | `$true` | After a successful uninstall, delete leftover Revit-`<year>`-specific folders (settings, journals, add-in manifests, RVT content, program folder). Disable with `-RemoveResidualFiles:$false`. |
| `-StopRevit` | switch | off | Terminate `Revit.exe` if running. Without it, the script aborts when Revit is open. |
| `-ListOnly` | switch | off | Discover and print matches, then exit. No changes. |
| `-Force` | switch | off | Fully non-interactive: skips per-item prompts **and** suppresses PowerShell's built-in confirmation. |
| `-LogPath` | string | `%TEMP%\...` | Override the transcript log path. |

### How it works

**Product selection.** The core product is matched by name (`Autodesk Revit <year>`). With `-IncludeAddins`, the sweep additionally matches any product whose display name contains both `Revit`/`RVT` and the target year — a single rule that catches the full add-in/content family without an exhaustive list. Cross-version and shared components are excluded: version-range packs (e.g. `2024-2027`), Content Catalog, RealDWG, material libraries, licensing, Genuine Service, Identity Manager, Autodesk Access, ODIS, Desktop Connector, and any version-neutral interop manager. Products without `Revit` in the name (AutoCAD, Navisworks) never match, even when they share the year.

**Uninstall resolution (per product), tried in order:**

1. `msiexec.exe /x "C:\Windows\Installer\<cached>.msi" /qn /norestart` — the locally cached package (resolved via the Windows Installer COM API), which bypasses network-source resolution.
2. `msiexec.exe /x {GUID} /qn /norestart` — the product code. Fully silent, deterministic.
3. `msiexec.exe /x {GUID} … ROOTDRIVE=C:\ INSTALLDIR="…\Autodesk\Revit <year>"` — a last-resort directory-property override that clears the case where the MSI's own uninstall sequence composes a relative `INSTALLDIR` and dies with `Error 1606. Could not access network location Revit <year>\` (see [TROUBLESHOOTING.md](TROUBLESHOOTING.md)). Kept last because property overrides can themselves provoke error 2753 on some packages.
4. `QuietUninstallString` — the vendor's own silent command, run directly.
5. Raw `UninstallString` — for EXE uninstallers (Autodesk ODIS), a `--silent` variant is attempted first with the exact vendor command kept as an automatic fallback, so a wrong silent flag can never block the uninstall.

Exit codes `0`, `3010` (reboot required), and `1605` (already gone) are treated as success.

### Safety

- **Preview-first** with `-ListOnly` and full `-WhatIf`.
- **Shared components are never removed** in the default scope.
- **Residual cleanup is gated** on a successful uninstall and constrained by a runtime guard: a path must sit under an `...\Autodesk\...` tree, reference `Revit`/`RVT`, and contain the target year, or it is refused and logged.
- **Clean failure handling:** if a method fails, the script logs the raw uninstall strings and moves on without leaving partial state.

### Logging

Every run writes a full transcript to `%TEMP%\Uninstall-Revit<year>_<timestamp>.log`, including each product matched, the exact command invoked, and the exit code. Each MSI attempt additionally writes its own verbose Windows Installer log to `%TEMP%\MSIVerbose_<guid>_<stamp>_<Kind>.log`. Attach these logs when reporting issues.

### Troubleshooting

Stuck on exit `1603`, `1606`, or Internal Error `2753`? The script handles the two hard cases automatically: the relative-`INSTALLDIR` 1606 (directory-property override) and the damaged-custom-action 2753 (neutralize → recache → retry). See [TROUBLESHOOTING.md](TROUBLESHOOTING.md) for the full error-code map and the manual fallback routes.

### Reinstalling Revit later

This uninstaller is reinstall-safe. It removes products through Autodesk's own
uninstallers (ODIS `installer.exe` and `msiexec` by product code), so product
registrations are cleared properly rather than force-deleted, and it preserves
the Autodesk installer framework (ODIS / Autodesk Access), Genuine Service,
licensing, and shared libraries that a reinstall depends on. Residual folders it
deletes (settings, journals, add-in manifests, content, program folder) are
recreated by the installer.

When you want Revit back:

1. **Reboot first.** Not mandatory unless a run reported exit code `3010`
   (reboot required), but it clears pending file operations and is standard
   pre-reinstall hygiene.
2. **Install through Autodesk Access / your Autodesk account**, not a leftover
   local installer, so you get a fresh package and can re-add the content packs
   that were removed.
3. If Autodesk Access still shows the product as "installed" (a UI-cache quirk
   that can occur when you uninstall outside Access), refresh/repair or reboot
   and it will correct itself.

### Notes and limitations

- The core Revit ODIS uninstall can take a while (it removes each sub-component MSI in sequence); MSI-based add-ins take seconds each.
- Some third-party or ODIS uninstallers display their own progress UI regardless of silent flags. `msiexec` items run fully silent.
- Self-elevation opens a separate elevated window that closes on completion — watch the `%TEMP%` log for results rather than the original window.
- Tested on Windows PowerShell 5.1. PowerShell 7 should work but is not the primary target.
- This tool is not affiliated with or endorsed by Autodesk. "Revit", "AutoCAD", and "Navisworks" are trademarks of Autodesk, Inc.

---

## `Uninstall-PyRevit-Complete.ps1` — pyRevit and pyRevit CLI

Fully removes **pyRevit** and **pyRevit CLI** — clones, engines, Revit add-in manifests,
Windows "installed programs" registrations, Start Menu entries, and `PATH` entries — then
verifies that nothing is left.

> Built and verified against a real pyRevit 6.4.0 removal on a machine where a
> folder-deleting script had already left the install half-removed.

### Why a dedicated pyRevit uninstaller

Folder-deleting uninstall scripts leave pyRevit **half-removed**, and the pyRevit installer
then reports a leftover installation folder on the next install.

Both pyRevit and pyRevit CLI are installed by **Inno Setup**, which does two things a manual
folder sweep misses:

1. It ships an uninstaller (`unins000.exe`) *inside* the install folder.
2. It registers the install under
   `HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\<GUID>_is1`,
   carrying an `InstallLocation` value.

Deleting the install folder without running `unins000.exe` **orphans that registry key**.
Windows still lists pyRevit as installed, and the installer's existing-install check still
finds a registration pointing at a path you already deleted. Deleting the folder is what
*creates* the problem the warning reports.

Two traps that specifically catch hand-written cleanup scripts:

| Trap | Detail |
|---|---|
| **pyRevit CLI hides one level deeper** | The standalone pyRevit CLI installs per-user to `%LOCALAPPDATA%\Programs\pyRevit CLI` (confirmed on 6.4.0) — not `%LOCALAPPDATA%\pyRevit CLI`, and not `%PROGRAMFILES%`. A non-recursive glob over `%LOCALAPPDATA%` never descends into `Programs\`. Because this script discovers installs from the registry, the exact path never has to be known in advance. |
| **The registration is not under `Software\pyRevit`** | Checking `HKCU:\Software\pyRevit` and `HKLM:\SOFTWARE\pyRevit` finds nothing useful. The registration that matters lives under `…\CurrentVersion\Uninstall\<GUID>_is1`, keyed by an opaque GUID — so it has to be *searched for* by `DisplayName`, not guessed at by path. |

This script runs the shipped uninstallers **first**, then sweeps, then verifies.

### Features

- **Vendor-uninstaller-first.** Runs each `unins000.exe /VERYSILENT` so the Windows registration is retired properly instead of orphaned.
- **Registry-driven discovery** across all three uninstall hives (HKCU, HKLM, WOW6432Node) — custom install directories cannot hide.
- **Config-aware.** Parses `pyRevit_config.ini` for clone paths before deleting it, catching clones installed outside the default location.
- **Correct CLI verbs.** `revits killall`, `detach --all`, `clones forget --all`, `caches clear --all`, run while the CLI still exists.
- **Non-destructive `PATH` editing** that preserves `REG_EXPAND_SZ` and never rewrites when there is nothing to change.
- **Extensions backed up** to your Desktop before anything is deleted.
- **Elevation optional** — pyRevit's default installers are per-user; machine-wide items are explicitly reported as skipped rather than silently missed.
- **Long-path and read-only tolerant** deletion, with drive-root guards.
- **Dry-run mode** (`-DryRun`, aliased `-WhatIf`) and a final **CLEAN / NOT CLEAN** verification pass.

### Requirements

- Windows PowerShell 5.1 or later
- **Revit must be closed** (the script offers to stop it)
- Elevation is **optional**, unlike `Uninstall-Revit.ps1`. pyRevit's default installers are
  per-user, so an unelevated run is normally sufficient. Elevate only if you used
  `pyRevit_*_admin_signed.exe`, or have anything under `%PROGRAMDATA%` / `%PROGRAMFILES%`.
  This script does **not** self-elevate; it reports what it skipped instead.

### Usage

```powershell
# Preview only — reports every intended change, modifies nothing:
powershell -ExecutionPolicy Bypass -File .\Uninstall-PyRevit-Complete.ps1 -DryRun

# Interactive — prompts before stopping Revit:
powershell -ExecutionPolicy Bypass -File .\Uninstall-PyRevit-Complete.ps1

# Unattended:
powershell -ExecutionPolicy Bypass -File .\Uninstall-PyRevit-Complete.ps1 -Force

# Replace a stale clone but keep the CLI you manage clones with:
powershell -ExecutionPolicy Bypass -File .\Uninstall-PyRevit-Complete.ps1 -KeepCli

# Machine-wide install (*_admin_signed.exe) — run from an elevated PowerShell:
powershell -ExecutionPolicy Bypass -File .\Uninstall-PyRevit-Complete.ps1 -Force
```

Run `-DryRun` first, for the same reason `Uninstall-Revit.ps1` has `-ListOnly`.

### Parameters

| Parameter | Type | Default | Description |
|---|---|---|---|
| `-DryRun` | switch | off | Report every intended change and modify nothing. Aliased to `-WhatIf`. |
| `-Force` | switch | off | Skip the confirmation prompt before stopping Revit. **Unsaved Revit work is lost.** |
| `-KeepCli` | switch | off | Leave pyRevit CLI installed and remove only pyRevit itself. Useful when you manage clones with the CLI and are only replacing the clone. |

### What it does

Ten phases, logged to `%TEMP%\pyrevit_uninstall_<timestamp>.log`.

| # | Phase | Detail |
|---|---|---|
| 0 | Host applications | Detects `Revit`, `pyrevit`, `pyrevit-telemetryserver`, `pyrevit-doctor`. Offers to stop them; aborts if you decline, since locked DLLs turn deletes into silent no-ops. |
| 1 | Graceful detach | `pyrevit revits killall`, `detach --all`, `clones forget --all`, `caches clear --all` — run while the CLI still exists. |
| 2 | Extensions backup | If a populated `Extensions` folder exists, copies it to a timestamped folder on your Desktop **before** anything is deleted, and lists what it found. Skipped silently when there is nothing to back up. |
| 3 | Registered installs | Searches all three uninstall hives, runs each `unins000.exe /VERYSILENT /SUPPRESSMSGBOXES /NORESTART`, and confirms the registration is retired. |
| 4 | Add-in manifests | Removes `pyRevit*.addin` and loader DLLs from every Revit version and scope. |
| 5 | Leftover folders | Sweeps whatever the uninstallers left behind, including the `%APPDATA%\pyRevit` config folder that Inno does not own. |
| 6 | Start Menu | Removes pyRevit shortcuts, user and all-users. |
| 7 | Registry footprint | Removes pyRevit keys plus any registration that survived phase 3. |
| 8 | `PATH` | Removes pyRevit entries from the user `PATH`, and from the machine `PATH` when elevated — otherwise it logs `Machine PATH: NOT CHECKED (needs elevation)`. Broadcasts `WM_SETTINGCHANGE`. |
| 9 | Verification | Re-scans everything and prints an explicit **CLEAN** / **NOT CLEAN** verdict. |

### Locations swept

Folders matching `*pyrevit*` directly under:

```
%APPDATA%                    %PROGRAMFILES%
%LOCALAPPDATA%               %ProgramFiles(x86)%
%LOCALAPPDATA%\Programs      %USERPROFILE%
%PROGRAMDATA%                %TEMP%
%SystemDrive%\
```

…plus any clone path found in `pyRevit_config.ini`.

Add-in manifests under:

```
%APPDATA%\Autodesk\Revit\Addins            %PROGRAMDATA%\Autodesk\Revit\Addins
%APPDATA%\Autodesk\ApplicationPlugins      %PROGRAMDATA%\Autodesk\ApplicationPlugins
%PROGRAMFILES%\Autodesk\Revit*\AddIns
```

Registry:

```
HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*               (searched)
HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*               (searched)
HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*   (searched)
HKCU\Software\pyRevit  ·  HKCU\Software\pyRevitLabs
HKLM\SOFTWARE\pyRevit  ·  HKLM\SOFTWARE\pyRevitLabs  (+ WOW6432Node)
```

### How it works

Things that are easy to get wrong, and how this script handles them.

**Custom clone directories.** Before deleting `pyRevit_config.ini`, the script parses it for
clone paths. A clone installed outside the default location is found by reading pyRevit's own
configuration rather than by guessing folder names.

**Inno relaunches itself.** `unins000.exe` copies itself to `%TEMP%\_iu*.tmp` and the original
process exits immediately, so `Start-Process -Wait` returns before the uninstall has finished.
The script polls for the registration to disappear (120 s), then removes the key directly if
the uninstaller stalled.

**`PATH` is edited through the registry, not `[Environment]`.**
`[Environment]::GetEnvironmentVariable('Path', 'Machine')` returns the **expanded** value and
`SetEnvironmentVariable` always writes **`REG_SZ`**. Reading and writing back therefore bakes
`%SystemRoot%` into a literal path *and* downgrades the value type from `REG_EXPAND_SZ`. This
script reads with `DoNotExpandEnvironmentNames`, preserves the original value kind, keeps
empty segments intact, and writes only when a segment actually matches pyRevit — so a no-op
run never touches `PATH` at all. It then broadcasts `WM_SETTINGCHANGE` so open applications
pick up the change.

**Deletion that actually completes.** Read-only and hidden attributes are cleared first (git
clones ship read-only objects; Inno ships hidden files). `Remove-Item` falls back to
`rd /s /q`, then to a robocopy empty-mirror for paths over 260 characters — Windows
PowerShell 5.1 is not long-path aware even when `LongPathsEnabled=1` is set. Drive roots and
bare paths are refused, and the robocopy fallback only runs on paths naming pyRevit.

**Rejected CLI verbs are reported.** `pyrevit clear all` and `pyrevit clone --all` are not
valid commands — the CLI responds by printing its usage screen, which a naive script logs as
~40 lines of apparent success. The script detects a usage dump and flags the verb as rejected
instead.

### After uninstalling

Verify the folders are gone and nothing remains registered:

```powershell
# Should return nothing:
Get-ChildItem $env:APPDATA, $env:LOCALAPPDATA, "$env:LOCALAPPDATA\Programs", $env:PROGRAMDATA -Directory -Filter "*pyrevit*" -ErrorAction SilentlyContinue

# Should also return nothing:
Get-ChildItem 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall' | ForEach-Object { Get-ItemProperty $_.PSPath } | Where-Object DisplayName -match pyrevit | Select-Object DisplayName, InstallLocation
```

Then reinstall pyRevit — the leftover-installation prompt should not appear.

If phase 2 backed anything up, your extensions are on your Desktop in
`pyRevit_Extensions_Backup_<timestamp>`. Copy the `.extension` folders back into
`%APPDATA%\pyRevit\Extensions` after reinstalling, or re-register them with
`pyrevit extensions`. Extensions kept outside the clone directory and registered by path are
untouched by the uninstall.

### Troubleshooting

[TROUBLESHOOTING.md](TROUBLESHOOTING.md) covers Autodesk MSI/ODIS failures and does not apply
to pyRevit. The pyRevit script's own failure modes:

**`NOT CLEAN` with `needs-admin:` entries** — machine-wide items were skipped. Re-run from an
elevated PowerShell.

**`NOT CLEAN` naming a folder that won't delete** — something still has a file open. Confirm
Revit is closed, check for a stray `pyrevit-telemetryserver.exe`, and re-run. If it persists,
reboot and re-run before investigating further.

**`uninstaller missing … registration is orphaned`** — expected if a previous script already
deleted the install folder. The script removes the dangling key, which is exactly what clears
the installer's leftover-installation complaint.

**Phase 1 logs `rejected by CLI`** — that verb is not available on your CLI version. Harmless;
phases 3–8 do not depend on it.

**Script won't start** — `-ExecutionPolicy Bypass` applies to that one process only and changes
no machine setting. Prefer it over altering your execution policy.

### Verified on

| | |
|---|---|
| OS | Windows 11 Pro for Workstations, build 26200 |
| Shell | Windows PowerShell 5.1 |
| pyRevit | 6.4.0.26100 (per-user install + standalone CLI) |
| Revit | 2023, 2025, 2026 |

Syntax-checked with the PowerShell 5.1 parser, then run end to end against a live pyRevit
6.4.0 install (unelevated, per-user):

- `-DryRun` correctly identified all three install folders — including
  `%LOCALAPPDATA%\Programs\pyRevit CLI`, the one a non-recursive glob misses — plus both
  `_is1` registrations and the user `PATH` entry.
- The full run retired both Inno registrations via their own `unins000.exe`, swept the
  remaining `%APPDATA%\pyRevit` config folder, cleaned the user `PATH` with its
  `ExpandString` type intact, and reported machine `PATH` as
  `NOT CHECKED (needs elevation)` rather than silently skipping it.
- Phase 9 reported **CLEAN**. An independent re-scan afterwards confirmed zero pyRevit
  folders, add-in manifests, registrations across all three uninstall hives, and `PATH`
  entries in either scope.

Reinstalling after a CLEAN verdict was not itself re-tested — but the orphaned registration
that triggers the installer's leftover warning is verifiably gone, which is the condition the
warning checks.

---

## A warning about `[Environment]::SetEnvironmentVariable`

Relevant to anyone writing their own cleanup script, and to anyone who has already run one.

If you have previously run an uninstall script that cleaned `PATH` via
`[Environment]::SetEnvironmentVariable(..., 'Machine')`, your machine `PATH` may already be
damaged: converted from `REG_EXPAND_SZ` to `REG_SZ`, with `%SystemRoot%` baked in as a literal
path. Entries are not lost and the `PATH` keeps working, but the value type is wrong and any
future `%VAR%` entry will no longer expand.

This fires **even when machine `PATH` contains no matching entries at all**. Scripts typically
filter segments with `Where-Object { $_ }`, which silently drops the **empty trailing segment**
that a great many `PATH` values carry — that alone makes the filtered result differ from the
original, so the "did anything change?" guard passes and the whole value gets rewritten.
Preserving empty segments is what stops a no-op run from doing damage.

Check the value kind — `ExpandString` is correct:

```powershell
(Get-Item 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment').GetValueKind('Path')
```

If it returns `String`, restore it from an **elevated** PowerShell. Print the current value and
save a copy before changing anything:

```powershell
$k = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment'
$p = (Get-Item $k).GetValue('Path', $null, 'DoNotExpandEnvironmentNames')
$p | Out-File "$env:USERPROFILE\Desktop\machine-path-backup.txt" -Encoding utf8
$new = (($p -split ';') | ForEach-Object { $_ -replace '(?i)^C:\\Windows', '%SystemRoot%' }) -join ';'
Set-ItemProperty -Path $k -Name Path -Value $new -Type ExpandString
```

## Disclaimer

Uninstalling software modifies your system. Review the `-ListOnly` / `-DryRun` output before running for real, and keep the generated log. The software is provided "as is" — see [LICENSE](LICENSE).

## License

[MIT](LICENSE) © 2026 MrGezz
