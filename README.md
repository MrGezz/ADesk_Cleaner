# ADesk_Cleaner

Six PowerShell uninstallers for Windows — four for Autodesk environments, one for Fortinet
FortiClient, one for Adobe Creative Cloud — plus a Revit cache cleaner and a small
general-purpose cleanup utility. Each uninstaller targets a different layer of the stack, and
each is registry-driven, preview-first, and fully logged.

| Script | Removes | Elevation |
|---|---|---|
| [`Uninstall-Revit.ps1`](Uninstall-Revit.ps1) | **Autodesk Revit**, any year — core application plus its orphaned add-ins, content packs, and exporters | Required (self-elevates) |
| [`Uninstall-AutoCAD.ps1`](Uninstall-AutoCAD.ps1) | **Autodesk AutoCAD**, any year — the whole per-year product family (ODIS bundle, updates, and the two hidden MSI children) plus orphaned add-ins | Required (self-elevates) |
| [`Uninstall-Navisworks.ps1`](Uninstall-Navisworks.ps1) | **Autodesk Navisworks** Manage / Simulate / Freedom, any year — the ODIS bundle, the hidden MSI child, and all 11 language packs. **Preserves the NWC exporters by default** | Required (self-elevates) |
| [`Uninstall-PyRevit-Complete.ps1`](Uninstall-PyRevit-Complete.ps1) | **pyRevit** and **pyRevit CLI** — clones, add-in manifests, Windows installation registrations, Start Menu entries, `PATH` entries | Optional |
| [`Uninstall-FortiClient.ps1`](Uninstall-FortiClient.ps1) | **Fortinet FortiClient** — the MSI, plus the network-stack residue it orphans: kernel drivers, driver-store packages, the virtual adapter devnodes, firewall rules and config hives | Required (self-elevates) |
| [`Uninstall-Adobe.ps1`](Uninstall-Adobe.ps1) | **Adobe Creative Cloud products you select** — Photoshop, Illustrator, Acrobat and the rest, by SAP code or name, via Adobe's own HyperDrive uninstaller. **Preserves shared runtimes** other Adobe apps still reference | Required (self-elevates) |
| [`Clear-RevitCache.ps1`](Clear-RevitCache.ps1) | Not an uninstaller — **keeps Revit installed** and clears its per-user caches: accelerator cache, web caches, journal history, and (opt-in) the cloud collaboration cache and the Home screen's Recent models page | None |
| [`Clean-Directory.ps1`](Clean-Directory.ps1) | Not an uninstaller — a recursive sweep for build junk (`*.bak`, `__pycache__`) under a directory you name | None |

> All six uninstallers share the same philosophy: discover what is installed from the registry
> rather than from hardcoded paths or GUIDs, invoke the vendor's own uninstaller wherever one
> exists, preview before acting, refuse to touch shared components, and log everything.

## Which script do I need?

| Situation | Script |
|---|---|
| Removing Revit itself | `Uninstall-Revit.ps1` |
| Removing AutoCAD itself | `Uninstall-AutoCAD.ps1` |
| Removing Navisworks itself | `Uninstall-Navisworks.ps1` |
| Revit uninstall fails with `1603`, `1606`, or `2753` | `Uninstall-Revit.ps1` — see [TROUBLESHOOTING.md](TROUBLESHOOTING.md) |
| AutoCAD uninstall fails with `1603` or `2753` | `Uninstall-AutoCAD.ps1` — same automated remediation |
| Navisworks uninstall fails with `1603` or `2753` | `Uninstall-Navisworks.ps1` — same automated remediation |
| AutoCAD still listed in Add/Remove Programs after a "successful" uninstall | `Uninstall-AutoCAD.ps1` — it also removes the two hidden MSI children |
| Navisworks still listed after a "successful" uninstall | `Uninstall-Navisworks.ps1` — the main product MSI has **no uninstall string at all** and is only reachable by product code |
| Navisworks removed, but Revit/AutoCAD lost their **Export to NWC** command | An earlier sweep took the exporters. See [Reinstalling the exporters](#reinstalling-the-exporters) |
| A reinstalled AutoCAD came back with the old broken profile | `Uninstall-AutoCAD.ps1 -RemoveResidualRegistry` |
| A reinstalled Navisworks came back with the old workspace/clash settings | `Uninstall-Navisworks.ps1 -RemoveResidualRegistry` |
| pyRevit installer reports a **leftover installation folder** | `Uninstall-PyRevit-Complete.ps1` |
| pyRevit still listed in Add/Remove Programs after deleting its folder | `Uninstall-PyRevit-Complete.ps1` |
| pyRevit ribbon still loading, or a stale clone needs replacing | `Uninstall-PyRevit-Complete.ps1` |
| Removing FortiClient itself | `Uninstall-FortiClient.ps1` |
| FortiClient gone from Add/Remove Programs, but a **Fortinet virtual adapter** still shows in Network Connections | `Uninstall-FortiClient.ps1` — it removes the devnode and the driver package, which the MSI leaves behind |
| `forti*.sys` drivers or a `FortiFilter` service survived a FortiClient uninstall | `Uninstall-FortiClient.ps1` — it finds them by binary metadata, not by name |
| FortiClient uninstall fails with `1603` | `Uninstall-FortiClient.ps1` — check its verbose MSI log for a live process or an EMS-enforced uninstall lock |
| Removing **one** Adobe app (say Photoshop) but keeping the others | `Uninstall-Adobe.ps1 -Product PHSP` |
| Not sure what Adobe products are even installed | `Uninstall-Adobe.ps1 -ListOnly` — it finds the nine that have **no name** in Add/Remove Programs |
| An Adobe app is gone from Add/Remove Programs but its folder and shortcuts remain | `Uninstall-Adobe.ps1` — re-run it; residual cleanup is keyed to the products it removed |
| Adobe uninstall reported **exit code 130** | Expected. That component is still referenced by another Adobe app — remove the apps first, then re-run with `-IncludeSharedComponents` |
| Camera Raw / CoreSync / colour profiles survived removing every Adobe app | `Uninstall-Adobe.ps1 -All -IncludeSharedComponents` as a second pass |
| Adobe context-menu entries or cloud-sync icon overlays still in Explorer | `Uninstall-Adobe.ps1 -RemoveShellExtensions` — they are registered as `AccExt`, with no "Adobe" in the name |
| Reclaiming the multi-GB `ProgramData\Adobe\CameraRaw` library | `Uninstall-Adobe.ps1 -RemoveUserData` — **also deletes your Camera Raw presets** |
| Revit is running out of disk, or a stale cache needs clearing — **without** uninstalling it | `Clear-RevitCache.ps1` |
| Reclaiming the multi-GB cloud model cache after a project ships | `Clear-RevitCache.ps1 -IncludeCollaborationCache -OlderThanDays 30` |
| Emptying the **Recent models** page on Revit's Home screen | `Clear-RevitCache.ps1 -ClearRecentFiles` |
| Clearing `*.bak` / `__pycache__` out of a project tree | `Clean-Directory.ps1` |
| Wiping a machine completely | pyRevit first, then Revit, then Navisworks, then AutoCAD |

Removing pyRevit before Revit lets pyRevit detach from each Revit installation while its CLI
still exists, which leaves no orphaned add-in manifests behind. AutoCAD goes last because both
Revit and Navisworks consume `RealDWG Shared`, which the three Autodesk uninstallers all
preserve by name. (`Uninstall-PyRevit-Complete.ps1` has no shared-component logic — it never
touches anything outside the pyRevit footprint, so it needs none.)

## Exit codes

The three Autodesk uninstallers, `Uninstall-FortiClient.ps1` and `Uninstall-Adobe.ps1` share one
contract:

| Code | Meaning |
|---|---|
| `0` | Success |
| `3010` | Success, reboot required |
| `3` | Partial failure — one or more products did not uninstall |
| `2` | Nothing matched; no changes made |
| `1` | Aborted (target application running, elevation cancelled, invalid `-LogPath`) |

A run in which you **declined** products at the prompts also exits `0` — declining is a
deliberate choice, not a failure, so it does not earn exit `3`. Such a run says so explicitly
in its last lines (`Completed with N product(s) declined and still installed.`) and skips
residual cleanup entirely, because deleting the files of a product you chose to keep would
leave a registered product with no files. If you are driving these scripts from automation,
use `-Force` so nothing can be declined, and read the transcript rather than the exit code
alone.

`Uninstall-FortiClient.ps1` additionally returns `1` when a Fortinet virtual adapter is
reporting `Up` — that usually means a VPN tunnel is connected, and tearing the stack down
mid-tunnel can strand routes. It returns `3010` far more often than the Autodesk scripts do,
because removing boot-start NDIS drivers genuinely requires a restart; treat `3010` as success
and re-run the script after rebooting to finish the file sweep.

`Uninstall-Adobe.ps1` returns `1` for two additional cases specific to selection: a `-Product`
value that matches **no** product or **more than one** (it prints the candidates and changes
nothing), and `-Force` without `-Product` or `-All` (there is no menu to answer, and it refuses
to assume you meant every Adobe product). Note that Adobe's **exit code `130`** — a shared
component still referenced by another installed product — is *not* a failure and does not
produce exit `3`; the run reports it and exits `0`.

`Uninstall-PyRevit-Complete.ps1` returns `1` only when you decline to close Revit; a
**NOT CLEAN** verdict is reported in its output rather than in the exit code.
`Clean-Directory.ps1` returns `1` when `-RootPath` does not exist or resolves to a drive root,
and `0` otherwise.

`Clear-RevitCache.ps1` uses the same five codes with cache-shaped meanings: `0` success,
`3` partial failure (something could not be deleted, usually a file still open), `2` nothing to
clear, `1` aborted (Revit running without `-StopRevit`, or an invalid `-LogPath`). It never
returns `3010` — clearing a cache never requires a reboot.

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

# ALSO remove the year's Material Library packages (opt-in, bare switch):
powershell -ExecutionPolicy Bypass -File .\Uninstall-Revit.ps1 -ProductYear 2026 -IncludeMaterialLibraries

# Core application only — skip add-ins and residual cleanup (needs -Command, see the note below):
powershell -ExecutionPolicy Bypass -Command "& '.\Uninstall-Revit.ps1' -ProductYear 2026 -IncludeAddins:$false -RemoveResidualFiles:$false"
```

**`-IncludeMaterialLibraries` is a switch — pass it bare, like `-Force`.** Not
`-IncludeMaterialLibraries:$true`. This is not cosmetic: `powershell.exe -File` passes every
argument as a literal **string**, and a `bool` parameter's argument transformation rejects the
string `"$true"` with *"Boolean parameters accept only Boolean values and numbers"*. Measured:
**no** `-File` form binds a `bool` — not `:$true`, not `:1`, not `:0`, not `:true`. Switches have
a parser special-case, which is why `-Force` has always worked. The three default-on `bool`
parameters (`-IncludeAddins`, `-RemoveResidualFiles`, `-NeutralizeBrokenCustomActions`) are only
ever passed to turn a removal *off*, and that needs the `-Command` form shown above.

Run `-ListOnly` first. It is the safety gate: it shows exactly what will be removed before you commit.

### Parameters

| Parameter | Type | Default | Description |
|---|---|---|---|
| `-ProductYear` | string | `2026` | Four-digit Revit release year to target (e.g. `2024`). Scopes the core match, add-in sweep, residual folders, the residual guard, and the self-elevation relaunch. Validated as four digits. |
| `-IncludeAddins` | bool | `$true` | Also remove every product whose name references Revit **and** the target year (add-ins, content, exporters, DB Link, IFC, interop tools). Disable with `-IncludeAddins:$false`, which needs the `-Command` form. |
| `-IncludeMaterialLibraries` | switch | off | **Opt-in.** Also remove Material Library packages matching the target year. Off by default because material libraries are commonly shared across products. |
| `-NeutralizeBrokenCustomActions` | bool | `$true` | On `1603` + `Internal Error 2753`, automatically neutralize the broken custom action in a patched copy of the cached package, recache it (`/fv`), and retry — see [TROUBLESHOOTING.md](TROUBLESHOOTING.md). Disable with `-NeutralizeBrokenCustomActions:$false`, which needs the `-Command` form. |
| `-RemoveResidualFiles` | bool | `$true` | After a successful uninstall, delete leftover Revit-`<year>`-specific folders (settings, journals, add-in manifests, RVT content, program folder). Disable with `-RemoveResidualFiles:$false`, which needs the `-Command` form. |
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

## `Uninstall-AutoCAD.ps1` — Autodesk AutoCAD

A scoped, self-elevating PowerShell script that cleanly uninstalls **any year of Autodesk AutoCAD** on Windows — the whole per-year product family plus its orphaned add-ins — while preserving shared Autodesk components, other AutoCAD years, and AutoCAD toolsets. The target release is chosen with `-ProductYear` (default `2026`).

AutoCAD is harder to remove correctly than Revit, for three reasons this script is built around:

1. **It is a family, not a product.** Each year registers four separate entries: an ODIS *update* bundle, the ODIS *bundle wrapper*, and two **hidden** MSI children (`SystemComponent=1`, so they never appear in Add/Remove Programs). The MSI children carry **no `UninstallString` and no `QuietUninstallString` at all** — `msiexec` against their product code is the only route.
2. **`ACAD Private` is unnameable.** One of the hidden children is called exactly `ACAD Private` — no year, no "AutoCAD" in the name — and **every installed AutoCAD year registers one under that identical name**. No name rule can reach it, and de-duplicating a target list by display name would collapse all of them into one arbitrary entry. This script matches it by install location and de-duplicates by **product code**.
3. **The release number is not the year.** AutoCAD 2025 is `R25.0`, **2026 is `R25.1`**, 2027 is `R26.0`. The per-user profile keys live under `...\Autodesk\AutoCAD\R<release>` with the year appearing nowhere, so deleting the wrong one wipes a *different* version's profiles, toolbars, and plotter settings. The release is therefore **read from the registry, never computed** — and when it cannot be proven, release-scoped cleanup is skipped rather than guessed.

> Built on the same hardened MSI machinery as `Uninstall-Revit.ps1`. The 2753 remediation is not inherited by analogy: the AutoCAD core package carries the *same* file-sourced custom action (`_560A25DD.D5955B9C…`, type 3217) that produced the Revit failure.

### Features

- **Any AutoCAD year** via `-ProductYear` — one script for 2018–2027+.
- **Registry-driven discovery** across the 64-bit, 32-bit (WOW6432Node), and per-user uninstall hives — no hardcoded product GUIDs.
- **Finds the hidden components** other uninstallers leave behind (`ACAD Private`, `AutoCAD <year> - <lang>`), attributed to the correct year by install location.
- **Explicit removal order** — update bundles → add-ins → ODIS bundle wrapper → MSI children — with a re-check before each step, since the wrapper normally removes its own children.
- **Runtime release resolution** (`2026 → R25.1`), never arithmetic.
- **Toolset guard.** Aborts before removing base AutoCAD when a toolset that shares the install tree or release key (Architecture, Mechanical, Electrical, MEP, Map 3D, Plant 3D, P&ID, Raster Design, Civil 3D) is installed for the target year. Override with `-IgnoreToolsetGuard`.
- **Year-scoped process guard.** Identifies running AutoCAD processes by executable path, so a drawing open in *another* installed year is never closed.
- **Correct ODIS invocation.** Runs Autodesk's `AdODIS\V1\Installer.exe` directly (not through `cmd`), so its unquoted, space-containing path is handled properly.
- **Multi-method resolution** per product, with **per-attempt verbose MSI logs** and automatic `1603`+`2753` remediation (neutralize → recache → retry).
- **Self-elevation** via UAC, **preview mode** (`-ListOnly`), and full `-WhatIf` support.
- **Guarded residual cleanup** of files, and opt-in cleanup of the release-scoped registry keys.

### Requirements

- Windows 10/11
- Windows PowerShell 5.1 (built in) — no modules required
- Administrator rights (the script self-elevates via UAC)

### Usage

```powershell
# Preview only for the default year (2026) — lists matches, changes nothing:
powershell -ExecutionPolicy Bypass -File .\Uninstall-AutoCAD.ps1 -ListOnly

# Preview a specific year:
powershell -ExecutionPolicy Bypass -File .\Uninstall-AutoCAD.ps1 -ProductYear 2025 -ListOnly

# Interactive — prompts before each product and each residual folder:
powershell -ExecutionPolicy Bypass -File .\Uninstall-AutoCAD.ps1 -ProductYear 2025

# Fully unattended and silent, closing AutoCAD if it is open:
powershell -ExecutionPolicy Bypass -File .\Uninstall-AutoCAD.ps1 -ProductYear 2025 -StopAutoCAD -Force

# Full wipe including the release-scoped profile keys (opt-in, bare switch):
powershell -ExecutionPolicy Bypass -File .\Uninstall-AutoCAD.ps1 -ProductYear 2026 -RemoveResidualRegistry -Force

# Core application only — skip add-ins and residual cleanup (needs -Command, see the note below):
powershell -ExecutionPolicy Bypass -Command "& '.\Uninstall-AutoCAD.ps1' -ProductYear 2026 -IncludeAddins:$false -RemoveResidualFiles:$false"
```

**`-RemoveResidualRegistry` and `-IncludeMaterialLibraries` are switches — pass them bare, like
`-Force`.** Not `-RemoveResidualRegistry:$true`. This is not cosmetic: `powershell.exe -File`
passes every argument as a literal **string**, and a `bool` parameter's argument transformation
rejects the string `"$true"` with *"Boolean parameters accept only Boolean values and numbers"*.
Measured: **no** `-File` form binds a `bool` — not `:$true`, not `:1`, not `:0`, not `:true`.
Switches have a parser special-case, which is why `-Force` has always worked. The three default-on
`bool` parameters (`-IncludeAddins`, `-RemoveResidualFiles`, `-NeutralizeBrokenCustomActions`) are
only ever passed to turn a removal *off*, and that needs the `-Command` form shown above.

Run `-ListOnly` first. It is the safety gate: it shows the resolved release, the exact four-entry family in removal order, and every residual location before you commit.

### Parameters

| Parameter | Type | Default | Description |
|---|---|---|---|
| `-ProductYear` | string | `2026` | Four-digit AutoCAD release year to target. Scopes the core match, add-in sweep, residual folders, the residual guard, and the self-elevation relaunch. Validated as four digits. |
| `-IncludeAddins` | bool | `$true` | Also remove every product whose name references AutoCAD **and** the target year (object enablers, language packs, extensions). Disable with `-IncludeAddins:$false`, which needs the `-Command` form. |
| `-IncludeMaterialLibraries` | switch | off | **Opt-in.** Also remove Material Library packages matching the target year. Off by default because material libraries are shared across products. |
| `-RemoveResidualFiles` | bool | `$true` | After a successful uninstall, delete leftover AutoCAD-`<year>` folders. Every path carries the year, so this never needs the release number. Disable with `-RemoveResidualFiles:$false`, which needs the `-Command` form. |
| `-RemoveResidualRegistry` | switch | off | **Opt-in.** Also delete `HKCU`/`HKLM:\SOFTWARE\Autodesk\AutoCAD\R<release>`. Only acts when the release-to-year mapping was proven and no other product still claims that release. |
| `-NeutralizeBrokenCustomActions` | bool | `$true` | On `1603` + `Internal Error 2753`, neutralize the broken custom action in a patched copy of the cached package, recache it (`/fv`), and retry. Disable with `-NeutralizeBrokenCustomActions:$false`, which needs the `-Command` form. |
| `-StopAutoCAD` | switch | off | Terminate target-year AutoCAD processes if running. Other years are identified by path and never touched. Without it, the script aborts when a target-year process is open. |
| `-IgnoreToolsetGuard` | switch | off | Proceed even when a toolset sharing the base install tree or release key is installed for the target year. |
| `-ListOnly` | switch | off | Discover and print matches, then exit. No changes. |
| `-Force` | switch | off | Fully non-interactive: skips per-item prompts **and** suppresses PowerShell's built-in confirmation. |
| `-LogPath` | string | `%TEMP%\...` | Override the transcript log path. |

### How it works

**Release resolution.** `HKLM:\SOFTWARE\Autodesk\AutoCAD\R<rel>\ACAD-<id>:<lcid>` carries `UPIRELEASE`, `ProductNameGlob`, `ProductName`, and `Location`. The script scans every release container and keeps the one whose product keys prove the target year. If two releases claim the same year, or none does, release-scoped operations are skipped and logged.

**Product selection.** Core patterns are anchored (`AutoCAD <year>*`, `Autodesk AutoCAD <year>*`) with no leading wildcard, so `Autodesk AutoCAD MEP 2026 - English` and `AutoCAD LT 2026` can never match — both carry a token between "AutoCAD" and the year. `ACAD Private` is matched separately by install location, gated on a real MSI registration. The target list is then de-duplicated **by product code**. Shared components are excluded by name — notably `RealDWG Shared <year>` and `Shared Components <year>`, which carry a year but are consumed by Revit, Navisworks, and Inventor.

**Removal order,** with the registration re-checked before each step:

1. **Update bundles** — patches on the base; removing them first returns it to the state its own uninstaller expects and leaves no orphaned entry.
2. **Add-ins / extras** — depend on the base, so they go while it still exists and their uninstall actions can still resolve it.
3. **ODIS bundle wrapper** — the orchestrator for the core product.
4. **MSI children** — normally already gone after step 3, so these usually report `1605` ("not installed"), which counts as success.

Exit codes `0`, `3010` (reboot required), and `1605` (already gone) are treated as success.

### Safety

- **Preview-first** with `-ListOnly` and full `-WhatIf`.
- **Toolset guard aborts by default** rather than silently orphaning Civil 3D or a toolset.
- **Other AutoCAD years are never touched** — not their products, not their residual folders, not their running processes.
- **A process with no resolvable path is never killed.** It is reported instead, because it cannot be proven to belong to the target year.
- **Shared Autodesk infrastructure keeps running** — the licensing service, Identity Manager, and Autodesk Access are deliberately absent from the process list.
- **Residual file cleanup is gated** on a successful uninstall and constrained by a runtime guard: a path must sit under an `...\Autodesk\...` tree, reference `AutoCAD`, and contain the target year, or it is refused and logged.
- **Residual registry cleanup is opt-in and doubly gated** — the release must have been proven from the registry, the key path must match `...\AutoCAD\R<n>.<n>` exactly, and a post-uninstall re-census must find nothing under that release still claiming a different year.

### Logging

Every run writes a full transcript to `%TEMP%\Uninstall-AutoCAD<year>_<timestamp>.log`. Each MSI attempt additionally writes its own verbose Windows Installer log to `%TEMP%\MSIVerbose_<guid>_<stamp>_<Kind>.log`. Attach these logs when reporting issues.

### Reinstalling AutoCAD later

Reinstall-safe for the same reasons as the Revit script: products go through Autodesk's own uninstallers, so registrations are cleared rather than force-deleted, and the Autodesk installer framework (ODIS / Autodesk Access), Genuine Service, licensing, and shared libraries are preserved. Reboot first, then install through Autodesk Access.

`-RemoveResidualRegistry` is the switch to use when a *previous* AutoCAD install left a corrupt profile that a reinstall keeps resurrecting — that state lives in `...\AutoCAD\R<release>`, not in the program folder.

### Notes and limitations

- The ODIS bundle uninstall can take several minutes; it removes each sub-component MSI in sequence.
- The two hidden MSI children are expected to report `1605` when reached — that means the ODIS wrapper already removed them, and it is treated as success.
- `-RemoveResidualFiles` deletes per-user settings and profiles. Custom `.cuix` files, plotter configurations, and templates stored inside those trees go with them; drawings under `Documents\` are untouched.
- The directory-property override kept as the last `msiexec` attempt is a generic last resort here, not a targeted fix: the AutoCAD packages inspected do not carry the `DIRCA_INSTALLDIR` action that made it the specific remedy on Revit.
- Tested on Windows PowerShell 5.1 against a machine with AutoCAD 2025, 2026, and 2027 installed side by side.
- This tool is not affiliated with or endorsed by Autodesk. "AutoCAD", "Revit", and "Civil 3D" are trademarks of Autodesk, Inc.

---

## `Uninstall-Navisworks.ps1` — Autodesk Navisworks

A scoped, self-elevating PowerShell script that cleanly uninstalls **any year and edition of Autodesk Navisworks** (Manage, Simulate, Freedom) on Windows, while preserving the NWC exporters, shared Autodesk components, and every other Autodesk product. The target release is chosen with `-ProductYear` (default `2026`) and the edition with `-Edition` (default `All`).

The whole script is built around one fact that makes Navisworks different from Revit and AutoCAD:

> **`Autodesk Navisworks Exporters <year>` is not part of Navisworks.**
> It is a separate, licence-free product that installs *into* Revit, AutoCAD and 3ds Max, and it keeps producing NWC files after every Navisworks edition is gone. Autodesk ships it as a standalone download precisely so teams can generate NWC without a licensed Navisworks seat.

A naive "Navisworks + `<year>`" name rule — the rule `Uninstall-Revit.ps1` uses for its own add-ins — sweeps the exporters up with the application and silently kills **Export to NWC** in every Revit, AutoCAD and 3ds Max on the machine. That is the single most likely way an uninstaller of this product causes user-visible damage, so the exporters are excluded from the default scope by an explicit rule and only removed via `-IncludeExporters`.

Three further Navisworks-specific traps this script is built around:

1. **The 11 language packs register `/I`, not `/X`.** Every language pack's `UninstallString` is `MsiExec.exe /I{GUID}` — the *install/repair* verb. Running it verbatim repairs the pack, never uninstalls it, and the run reports success. Verified on this platform: **33 registry rows** carry a `/I` uninstall string. This script synthesizes `/x {ProductCode}` from the registry key name and refuses any harvested `/I` command line it cannot coerce.
2. **The main product MSI has no uninstall string at all.** Like AutoCAD, each edition registers twice — an ODIS bundle wrapper and a hidden MSI child (`SystemComponent=1`, blank `UninstallString`) — under the *identical* `DisplayName`. The child is a real installed MSI with a cached `LocalPackage`, so `msiexec /x {GUID}` works, but any filter that skips `SystemComponent=1` or blank-`UninstallString` rows skips the actual product. Targets are de-duplicated **by product code**, never by display name.
3. **The version key is not the year.** Navisworks registers under `...\Autodesk\Navisworks <Edition>\<major>.0`, where `major = year - 2003` (2023 = 20, 2026 = 23). Unlike AutoCAD there are no half-steps — but the mapping is still **read** from the registry rather than computed, and version-scoped cleanup is skipped when it cannot be proven.

### Features

- **Any Navisworks year** via `-ProductYear` and **any edition** via `-Edition` — one script for 2019–2027+.
- **Exporters preserved by default.** The one destructive mistake this product invites is refused unless you ask for it explicitly.
- **Registry-driven discovery** across the 64-bit, 32-bit (WOW6432Node), and per-user uninstall hives — no hardcoded product GUIDs.
- **Finds the hidden MSI child** that carries no uninstall string, and all 11 language packs whose localized names have no consistent separator (Korean has no `" - "` at all, so names are never parsed by splitting).
- **Coerces the `/I` language-pack trap** to `/X`, and drops the candidate rather than running a repair when it cannot.
- **Explicit removal order** — updates → language packs → ODIS bundle wrapper → hidden MSI children — with the wrapper identified by its ODIS command line, not by its GUID shape.
- **Runtime version resolution** (`2026 → 23.0`), proven by reading `Product Name` out of the registry, with the arithmetic kept only as a cross-check. The product token is *discovered* (whichever child key carries `Product Name`) rather than guessed, because it is `NAVMAN-1` for Manage but `exporters-1` for the exporters.
- **Path-scoped process guard.** `Roamer.exe` is the application (there is no `Navisworks.exe`). Helpers that merely live in the folder — `OptionsEditor`, `AppManager`, `upi`, `senddmp`, `AdPreviewGenerator` — exist in up to 20 copies across AutoCAD, Revit, Desktop Connector and the licensing stack, so they are matched by **full path only**, never by name.
- **Self-elevation** via UAC with a **fail-closed `-WhatIf` relay**, **preview mode** (`-ListOnly`), and full `-WhatIf` support.
- **Guarded residual cleanup** of files, and opt-in cleanup of the version-scoped registry keys.
- **Multi-method resolution** per product, with **per-attempt verbose MSI logs** and automatic `1603`+`2753` remediation (neutralize → recache → retry).

### Requirements

- Windows 10/11
- Windows PowerShell 5.1 (built in) — no modules required
- Administrator rights (the script self-elevates via UAC)

### Usage

```powershell
# Preview only for the default year (2026), all editions — changes nothing:
powershell -ExecutionPolicy Bypass -File .\Uninstall-Navisworks.ps1 -ListOnly

# Preview a specific year and edition:
powershell -ExecutionPolicy Bypass -File .\Uninstall-Navisworks.ps1 -ProductYear 2025 -Edition Manage -ListOnly

# Interactive — prompts before each product and each residual folder:
powershell -ExecutionPolicy Bypass -File .\Uninstall-Navisworks.ps1 -ProductYear 2026 -Edition Manage

# Fully unattended and silent, closing Navisworks if it is open:
powershell -ExecutionPolicy Bypass -File .\Uninstall-Navisworks.ps1 -ProductYear 2025 -StopNavisworks -Force

# ALSO remove the NWC exporters — this breaks Export to NWC from Revit/AutoCAD/3ds Max:
powershell -ExecutionPolicy Bypass -File .\Uninstall-Navisworks.ps1 -ProductYear 2026 -IncludeExporters

# Full wipe including the version-scoped profile keys (opt-in, bare switch):
powershell -ExecutionPolicy Bypass -File .\Uninstall-Navisworks.ps1 -ProductYear 2026 -RemoveResidualRegistry -Force

# Keep the residual files (needs -Command, see the note below):
powershell -ExecutionPolicy Bypass -Command "& '.\Uninstall-Navisworks.ps1' -ProductYear 2026 -RemoveResidualFiles:$false"
```

**`-IncludeExporters`, `-IncludeCoordinationIssuesAddin`, `-IncludeMaterialLibraries` and
`-RemoveResidualRegistry` are switches — pass them bare, like `-Force`.** Not
`-IncludeExporters:$true`. This is not cosmetic: `powershell.exe -File` passes every argument as a
literal **string**, and a `bool` parameter's argument transformation rejects the string `"$true"`
with *"Boolean parameters accept only Boolean values and numbers"*. Measured: **no** `-File` form
binds a `bool` — not `:$true`, not `:1`, not `:0`, not `:true`. Switches have a parser
special-case, which is why `-Force` has always worked. The two default-on `bool` parameters
(`-RemoveResidualFiles`, `-NeutralizeBrokenCustomActions`) are only ever passed to turn a removal
*off*, and that needs the `-Command` form shown above.

Run `-ListOnly` first. It is the safety gate: it shows the resolved version key, every matched product in removal order, and every residual location before you commit.

### Parameters

| Parameter | Type | Default | Description |
|---|---|---|---|
| `-ProductYear` | string | `2026` | Four-digit Navisworks release year to target. Scopes the core match, residual folders, the residual guard, version resolution, and the self-elevation relaunch. Validated as four digits. |
| `-Edition` | string | `All` | `All`, `Manage`, `Simulate` or `Freedom`. All three can be installed side by side; non-selected editions are never matched, stopped, or cleaned up. |
| `-IncludeExporters` | switch | off | **Opt-in, and the one to think about.** Also remove `Autodesk Navisworks Exporters <year>` and its payload inside Revit / AutoCAD / 3ds Max. **This breaks NWC export from those applications** for that exporter year. |
| `-IncludeCoordinationIssuesAddin` | switch | off | **Opt-in.** Also remove the ACC/BIM 360 Coordination Issues add-in. It carries no year and its payload spans v18–v24, so it is only removed after a post-uninstall census proves no Navisworks edition of **any** year remains. |
| `-IncludeMaterialLibraries` | switch | off | **Opt-in.** Also remove Material Library packages matching the target year. Off by default because material libraries are shared across products. |
| `-RemoveResidualFiles` | bool | `$true` | After a fully successful uninstall, delete leftover Navisworks-`<year>` folders (settings, templates, caches, program folder, Start Menu entries, ODIS uninstaller stubs). Disable with `-RemoveResidualFiles:$false`, which needs the `-Command` form. |
| `-RemoveResidualRegistry` | switch | off | **Opt-in.** Also delete `HK{LM,CU}:\SOFTWARE\Autodesk\Navisworks <Edition>\<major>.0` and `...\Navisworks API Runtime\<major>\<Edition>`. Only acts when the version mapping was proven, and never touches the parent container key. |
| `-NeutralizeBrokenCustomActions` | bool | `$true` | On `1603` + `Internal Error 2753`, neutralize the broken custom action in a patched copy of the cached package, recache it (`/fv`), and retry. Disable with `-NeutralizeBrokenCustomActions:$false`, which needs the `-Command` form. |
| `-StopNavisworks` | switch | off | Terminate target-installation Navisworks processes. Other editions and years are identified by path and never touched. Without it, the script aborts when a target process is running. |
| `-ListOnly` | switch | off | Discover and print matches, then exit. No changes. |
| `-Force` | switch | off | Fully non-interactive: skips per-item prompts **and** suppresses PowerShell's built-in confirmation. |
| `-LogPath` | string | `%TEMP%\...` | Override the transcript log path. Resolved to an absolute path before elevation. |

### How it works

**Version resolution.** `HKLM:\SOFTWARE\Autodesk\Navisworks <Edition>\<major>.0` holds one child key carrying a `Product Name` value (`NAVMAN-1` for Manage). The script finds that child by *asking which one has the value* — never by matching the token name, which is inconsistently cased between products — reads the year out of `Product Name`, and cross-checks it against `major + 2003`. On mismatch, or when no key proves the year, version-scoped operations are skipped and logged. `Location\Path` gives the authoritative install root; the fallback is the hidden MSI child's `InstallLocation`, deliberately **not** the ODIS wrapper's, which points at the parent `C:\Program Files\Autodesk` and would path-match every Autodesk product on the machine.

**Product selection.** Core patterns are anchored (`Autodesk Navisworks <Edition> <year>*`) with no leading wildcard, so `Navisworks Exporters` can never match. The single trailing wildcard is what picks up the 11 language packs. Then everything Navisworks-*named* but not Navisworks-*owned* is excluded: the exporters, the Coordination Issues add-in, and all three word orders of the ACC publish add-in (`Publish NWC Addin`, `Publish NWC Addin v1.3`, `NWC Publish Add-in`). Shared components — `RealDWG Shared`, Content Catalog, licensing, ODIS, Autodesk Access, Desktop Connector — are excluded by name as in the sibling scripts.

**Removal order,** with the wrapper identified by its ODIS command line:

1. **Update bundles** — kept as a step for robustness, though on this platform Navisworks updates do **not** register in the uninstall hive at all (they exist only as `%ProgramData%\Autodesk\Uninstallers\<name>` folders). This is a real difference from AutoCAD; do not build the order around finding them.
2. **Language packs** — MSI children of the core, removed while it still exists.
3. **ODIS bundle wrapper** — the orchestrator for the edition.
4. **Hidden MSI children** — normally already gone after step 3, so these usually report `1605` ("not installed"), which counts as success.

Exit codes `0`, `3010` (reboot required), and `1605` (already gone) are treated as success.

### Safety

- **Preview-first** with `-ListOnly` and full `-WhatIf`, and the `-WhatIf` relay **fails closed** at the UAC boundary rather than letting a preview become a real uninstall.
- **The exporters are refused by default** — by the name rule, by the residual-path guard, and by an explicit check on every candidate path.
- **`Common Files\Autodesk Shared` is refused outright.** Each `RealDWG Shared <year>` inside it contains `nwcore.dll`, whose file metadata reads *ProductName: Autodesk Navisworks*. Anything matching on the string "Navisworks" inside that tree would select DLLs that Revit, Inventor and Civil 3D depend on.
- **Other Navisworks editions and years are never touched** — not their products, not their residual folders, not their running processes.
- **The edition-less cache folders are conditional.** `%APPDATA%\Autodesk\Navisworks <year>` and `%LOCALAPPDATA%\Autodesk\Navisworks <year>` carry no edition token and are created by *any* year-`N` component **including the exporters** — verified on a machine with no Navisworks 2023 application but with Exporters 2023 installed. They are only claimed when the exporters for that year are going too.
- **A process with no resolvable path is never killed** unless its name is one of the four executables verified unique to the application (`Roamer`, `FileToolsGUI`, `FileTools2GUI`, `FiletoolsTaskRunner`). Everything else is reported instead.
- **Residual cleanup is gated** on a fully successful uninstall — and, unlike a straight port of the sibling scripts, also on **nothing having been declined**. A product you answered "No" to is still installed, so deleting its files would leave a registered product with no files.
- **Authored content is called out by name.** `%APPDATA%\Autodesk\Navisworks <Edition> <year>` holds custom clash tests, property sets, appearance profiles, avatars and workspaces that no reinstall recreates. The prompt says so rather than calling it a "residual folder".
- **Residual registry cleanup is opt-in and doubly gated** — the version must have been proven from the registry, the key path must match a version-leaf shape exactly, and the exporters' keys are refused even if they somehow reach the guard.

### Logging

Every run writes a full transcript to `%TEMP%\Uninstall-Navisworks<year>_<timestamp>.log`. Each MSI attempt additionally writes its own verbose Windows Installer log to `%TEMP%\MSIVerbose_<guid>_<stamp>_<Kind>.log`. Attach these logs when reporting issues.

### Troubleshooting

Stuck on exit `1603` or Internal Error `2753`? The same automated chain the Revit and AutoCAD scripts use applies here — neutralize → recache → retry. See [TROUBLESHOOTING.md](TROUBLESHOOTING.md) for the full error-code map and the manual fallback routes.

### Reinstalling the exporters

If NWC export disappeared from Revit / AutoCAD / 3ds Max, the exporters were removed — either by `-IncludeExporters` here, or by an earlier tool using a blanket "Navisworks" rule. They are **not** restored by reinstalling Navisworks itself, because they are a separate product.

Reinstall the free **NWC Export Utility** for the matching year from your Autodesk account. Note the exporter year tracks the *Navisworks* release, not the host application: a Revit 2026 user may deliberately keep Exporters 2023 installed to produce NWC files a 2023-era Navisworks can read, which is why removing exporters for one year can break a workflow that has nothing to do with the edition being removed.

### Reinstalling Navisworks later

Reinstall-safe for the same reasons as the sibling scripts: products go through Autodesk's own uninstallers, so registrations are cleared rather than force-deleted, and the Autodesk installer framework (ODIS / Autodesk Access), Genuine Service, licensing and shared libraries are preserved. Reboot first, then install through Autodesk Access.

`-RemoveResidualRegistry` is the switch to use when a *previous* Navisworks install left a corrupt profile that a reinstall keeps resurrecting — that state lives in `...\Autodesk\Navisworks <Edition>\<major>.0`, not in the program folder.

### Notes and limitations

- The ODIS bundle uninstall can take several minutes; it removes each sub-component MSI in sequence.
- The hidden MSI child is expected to report `1605` when reached — that means the ODIS wrapper already removed it, and it is treated as success.
- **Per-user residuals are cleaned for the elevated account only.** If UAC asked for admin *credentials* rather than consent, the elevated child runs as the administrator and `%APPDATA%` is that profile — the signed-in user keeps their Navisworks settings. The script detects this and says so; re-run from the affected account to clear it.
- `Navisworks Simulate` and `Navisworks Freedom` matching is derived from the verified Manage/Exporters pattern rather than from a live install of those editions. The product-token key is discovered rather than assumed specifically so this cannot bite.
- Display names are verified for 2023–2027. Pre-2023 word order could not be confirmed, so the matcher also accepts the reversed `Navisworks <year> <Edition>` form.
- The directory-property override kept as the last `msiexec` attempt is a generic last resort here, not a targeted fix: the Navisworks packages inspected do not carry the `DIRCA_INSTALLDIR` action that made it the specific remedy on Revit.
- This tool is not affiliated with or endorsed by Autodesk. "Navisworks", "Revit", and "AutoCAD" are trademarks of Autodesk, Inc.

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

## `Uninstall-FortiClient.ps1` — Fortinet FortiClient

A self-elevating PowerShell script that uninstalls **Fortinet FortiClient** and then removes
the network-stack residue the vendor MSI orphans: kernel drivers, driver-store packages, the
virtual adapter device nodes, the Windows Firewall rules, and the configuration hives. Runs
the vendor uninstaller first and only cleans up after it, exactly like the Autodesk scripts.

Two things make this product different from every other script in this repo. The first is why
you cannot simply use Add/Remove Programs:

> **FortiClient registers itself as un-removable in the Windows UI.** Verified on this
> platform: its uninstall key carries `NoRemove = 1` and `NoModify = 1`, so `appwiz.cpl` hides
> the Remove and Change buttons entirely. That is a UI deterrent only — `msiexec /X` works
> fine — but it means the supported graphical route simply is not there.

The second is that FortiClient is mostly **network plumbing, not files**. It installs an NDIS
lightweight filter bound into every adapter, two virtual miniport adapters with PnP device
nodes, up to six kernel drivers, and three driver-store packages. Removing those by name, or
in the wrong order, is how a FortiClient cleanup takes the machine's networking with it.

Four FortiClient-specific traps this script is built around:

1. **OEM INF numbers are recycled, and this machine proves it.** The `ftsvnic` service's
   `DisplayName` reads `@oem45.inf,%VER_ADAPTER_STR%;Fortinet SSL VPN Virtual Ethernet Adapter`
   — but `C:\Windows\INF\oem45.inf` is **NVIDIA's `nvhda.inf`** (Azalia/HDMI audio). Windows
   reclaimed the slot after the original Fortinet package was removed, and the stale service
   key kept pointing at the number. `pnputil /delete-driver oem45.inf /uninstall` would
   uninstall the machine's audio driver. This script never derives an INF name from a registry
   string: driver packages are resolved by reading INF **file content** under `C:\Windows\INF`,
   and each one is re-verified in the moment before it is deleted.
2. **The service name is not the driver name, and three services have no `forti` in them.**
   Verified on this platform: `FortiFW` loads `FortiFW2.sys` and `fortisniff` loads
   `fortisniff2.sys` — and `ft_vnic`, `ftsvnic` and `pppop` (a Fortinet-provided "PPPoP WAN
   Adapter") contain no `forti` substring at all. A sweep filtered on the service **key name**
   finds six of the nine services on this machine and silently misses those three. Discovery
   here walks every service's `ImagePath`, resolves it to a real file, and attributes it by the
   binary's own `CompanyName`.
3. **The NDIS lightweight filter is the one that breaks networking.** `FortiFilter` is
   `Class=NetService`, `Start=1` (SYSTEM_START), and verified **Enabled on 12 adapters** here —
   every WiFi interface, the Hyper-V Default Switch, even the kernel-debugger NIC. Deleting its
   service key or its `.sys` while those bindings exist leaves the NDIS binding database
   referencing a filter that no longer exists, which can leave adapters unable to bind TCP/IP
   after reboot. It comes out only through its driver package, always **last** among driver
   operations, and it is never forced.
4. **The blunt instruments are refused outright.** `netsh winsock reset` and `netsh wfp reset`
   appear in most published FortiClient removal recipes. Verified on this platform: there is no
   Fortinet Winsock LSP — all 28 catalog entries are Microsoft providers — and Fortinet's WFP
   callouts are owned by its own drivers, which unregister them on unload. Both commands are
   pure downside: they drop every socket and wipe **all** third-party and Windows Firewall
   filtering state. Neither is ever issued. For the same reason the script never writes to the
   `Credential Providers` key: `FortiCredentialProvider2.dll` ships on disk but is **not**
   registered there, and a speculative prune of that key can remove `PasswordProvider` and make
   the machine unloggable.

### Features

- **Vendor-first removal.** The MSI runs before anything is hand-removed, because it owns the
  uninstall key, the `Installer\Products` records, the COM registrations and the program tree.
- **Discovery by identity, never by name** — services by `ImagePath` plus binary `CompanyName`,
  driver packages by INF file content, PnP devices by their live service binding.
- **Runtime-resolved device instance IDs.** `ROOT\NET\000N` numbering is positional and shifts
  as root-enumerated devices come and go, and Hyper-V and the kernel debugger share that
  namespace — so the target is resolved by service binding and refused if it is ambiguous.
- **Fixed, non-negotiable removal order** — devnodes, then driver packages, then orphaned
  service keys, with the NDIS filter package last and the file sweep only after a reboot.
- **Reboot-aware and idempotent.** Loaded drivers hold their `.sys` files open until restart, so
  the first run removes registrations and reports what is pending; re-running finishes the job.
  "Already gone" is treated as success everywhere, including MSI `1605` and `sc.exe` `1060`.
- **Two independent firewall-rule routes** — the Fortinet rule group, plus application filters
  whose program path resolves under a discovered Fortinet root. Never a loose name search.
- **Self-elevation** via UAC with a **fail-closed `-WhatIf` relay**, **preview mode**
  (`-ListOnly`), and full `-WhatIf` support.
- **Credential hygiene.** The saved SSL-VPN blobs and the encrypted EMS identity are removed
  with the hives, but are never read, logged, echoed, or exported — and the script performs no
  registry export at all.

### Requirements

- Windows 10/11
- Windows PowerShell 5.1 (built in) — no modules required
- Administrator rights (the script self-elevates via UAC)

### Usage

```powershell
# Preview the full census — every service, driver, package, device and rule. Changes nothing:
powershell -ExecutionPolicy Bypass -File .\Uninstall-FortiClient.ps1 -ListOnly

# Interactive removal, prompting before each step:
powershell -ExecutionPolicy Bypass -File .\Uninstall-FortiClient.ps1 -StopFortiClient

# Fully unattended, including the config hives and the saved VPN credentials:
powershell -ExecutionPolicy Bypass -File .\Uninstall-FortiClient.ps1 -StopFortiClient -RemoveResidualRegistry -Force

# Second pass after the reboot, to sweep the files the kernel was holding open:
powershell -ExecutionPolicy Bypass -File .\Uninstall-FortiClient.ps1 -Force

# Also remove the legacy 2016 Fortinet PPPoP WAN Adapter package:
powershell -ExecutionPolicy Bypass -File .\Uninstall-FortiClient.ps1 -IncludeLegacyPppop -StopFortiClient

# Turning a default-on removal OFF needs -Command, not -File (see the note below):
powershell -ExecutionPolicy Bypass -Command "& '.\Uninstall-FortiClient.ps1' -RemoveDrivers:$false -StopFortiClient"
```

**`-RemoveResidualRegistry` and `-IncludeLegacyPppop` are switches — pass them bare, like
`-Force`.** Not `-RemoveResidualRegistry:$true`. This is not cosmetic: `powershell.exe -File`
passes every argument as a literal **string**, and a `bool` parameter's argument transformation
rejects the string `"$true"` with *"Boolean parameters accept only Boolean values and numbers"*.
Measured: **no** `-File` form binds a `bool` — not `:$true`, not `:1`, not `:0`, not `:true`.
Switches have a parser special-case, which is why `-Force` has always worked. The three
default-on `bool` parameters (`-RemoveDrivers`, `-RemoveFirewallRules`, `-RemoveResidualFiles`)
are only ever passed to turn a removal *off*, and that needs the `-Command` form shown above.

Run `-ListOnly` first. It is the safety gate: it prints every service, driver file, driver-store
package, PnP device, firewall rule and residual path it has resolved, before you commit.

### Parameters

| Parameter | Type | Default | Description |
|---|---|---|---|
| `-RemoveDrivers` | bool | `$true` | Remove the Fortinet kernel drivers, driver-store packages and virtual adapter devnodes that survive the MSI. This is the reason the script exists — the MSI routinely leaves them. Packages are resolved by INF content, never by a registry-supplied `oemNN` name. |
| `-IncludeLegacyPppop` | switch | off | **Opt-in.** Also remove the Fortinet "PPPoP WAN Adapter" (`pppop`, `pppop64.sys`, a 2016-vintage `Legacy` package). It predates FortiClient 6.0.6, its name contains no `forti`, and it may belong to a different Fortinet product — so it is reported but never removed silently. |
| `-RemoveFirewallRules` | bool | `$true` | Remove the inbound allow-rules FortiClient registers (8 of them on this machine). Matched by group name and by application filters under a Fortinet root — never by a loose name search. |
| `-RemoveResidualFiles` | bool | `$true` | After a successful uninstall, delete leftover Fortinet program folders, Start Menu entries, the all-users desktop shortcut, and the orphaned driver `.sys` files. |
| `-RemoveResidualRegistry` | switch | off | **Opt-in.** Also delete `HKLM:\SOFTWARE\Fortinet`, `HKCU:\SOFTWARE\Fortinet` and the per-SID `SOFTWARE\Fortinet` keys of every **loaded** user hive. Note what this holds: the saved SSL-VPN tunnel, its DPAPI credential blobs, and the encrypted EMS registration. |
| `-StopFortiClient` | switch | off | Stop the `FA_Scheduler` service and terminate FortiClient processes before uninstalling. Without it the script aborts when FortiClient is running. |
| `-SkipTunnelGuard` | switch | off | Proceed even when a Fortinet virtual adapter reports `Up`. Off by default because tearing the stack down mid-tunnel can strand routes and black-hole the default gateway. |
| `-ListOnly` | switch | off | Run the full census and print everything that would be removed, then exit. No changes. |
| `-Force` | switch | off | Fully non-interactive: skips per-item prompts **and** suppresses PowerShell's built-in confirmation. |
| `-LogPath` | string | `%TEMP%\...` | Override the transcript log path. Resolved to an absolute path before elevation. |

### How it works

**Discovery.** The product comes from the uninstall hives by `Publisher` (`*Fortinet*`) as well
as `DisplayName`, because the free VPN-only edition registers as `FortiClient VPN` and localized
builds vary further. Install roots are read from `INSTALLDIR` **before** anything deletes the
hive that holds it, and normalized to the `Fortinet` parent rather than the `FortiClient` child.

**Attribution.** A service belongs to Fortinet when its resolved `ImagePath` binary says so in
its own version resource, or when that binary sits under a discovered Fortinet root — never
because its key name starts with `forti`. `ImagePath` is resolved through all four forms that
occur in practice: quoted absolute, `\SystemRoot\`-relative, bare relative, and `\??\` NT paths.

**Removal order,** which is the whole ballgame:

1. **Census and preview** — nothing is mutated.
2. **Active tunnel guard** — a Fortinet adapter reporting `Up` aborts the run.
3. **The scheduler service, then the processes it respawns.** `FA_Scheduler` is the parent of
   the tray, the ESNAC agent and the VPN daemon, so it is stopped *first*; killing a child
   before its launcher just gets the child restarted.
4. **MSI uninstall** with `/qn /norestart` — the registered `QuietUninstallString` is empty, so
   the silent switches must be supplied explicitly or the run blocks on a dialog.
5. **Re-census.** The question is not what FortiClient installed, it is what the MSI orphaned.
6. **PnP devnodes, then driver packages**, with the `NetService` package sorted last.
7. **Orphaned service keys** that no surviving package owns — the service registration goes
   before the file, never the reverse.
8. **Firewall rules, shortcuts, residual files, then the config hives.**

Exit codes `0`, `3010` (reboot required) and `1605` (already gone) are treated as success.

### Safety

- **Preview-first** with `-ListOnly` and full `-WhatIf`, and the `-WhatIf` relay **fails closed**
  at the UAC boundary rather than letting a preview become a real uninstall.
- **Driver packages are re-verified in the moment before deletion.** If the INF no longer reads
  as a Fortinet file, the script refuses and says so — this is the `oem45.inf` guard, and it is
  the single most important line in the file.
- **The NDIS filter is never forced.** If `pnputil /delete-driver` fails on it, the run reports
  and stops rather than retrying with `/force`, because forcing it out while it is still bound
  is precisely what strands the binding database.
- **Driver files are guarded by their own version resource**, not by a path rule — they live in
  `System32\drivers`, which carries no Fortinet path segment, so nothing else would be safe.
- **Residual directory deletion requires the path to name Fortinet**, and drive roots, protected
  system roots and short paths are refused outright with a logged reason.
- **Sibling Fortinet products are not collateral.** `...\Fortinet` is the *scoping* root for
  process and firewall attribution, never a deletion target — only `...\Fortinet\FortiClient` is
  queued for removal, and the vendor parent is swept afterwards **only if it ends up empty**.
  For the same reason the product match requires the *DisplayName* to say FortiClient; the
  publisher only corroborates it, so a FortiEDR or FortiExplorer install is never fed to
  `msiexec /x`.
- **Discovery roots are validated as strictly as deletion targets.** `INSTALLDIR` and
  `InstallLocation` are vendor-authored and routinely malformed; a root of `C:\` would scope the
  whole drive, and measured on this machine that would attribute 183 of 360 running processes —
  `explorer.exe`, `lsass.exe`, `svchost.exe` — to FortiClient. Roots that are drive roots,
  top-level system containers, or that do not name the vendor are discarded with a warning.
- **An INF is claimed only by its `Provider` directive**, resolved through the strings table —
  not by the word "Fortinet" appearing somewhere in the file. A third party's INF whose only
  mention is a comment (`; do not install alongside Fortinet FortiClient`) is refused.
- **A locked file is a retry-later, not a failure.** Treating it as fatal would abort the run
  after the service registrations are already gone — the worst state to stop in.
- **Driver removal is skipped entirely if the product uninstall failed**, because removing
  drivers out from under a half-uninstalled product is how a machine loses its network stack.
- **Colliding process names are path-scoped.** `certutil.exe`, `scheduler.exe`, `ipsec.exe` and
  `update_task.exe` all live in the FortiClient folder *and* elsewhere on Windows, so they are
  terminated only when the running image resolves under a Fortinet root.
- **Unloaded user profiles are left alone.** `reg load` without a guaranteed unload can corrupt
  or permanently lock a profile, and the leftovers are inert configuration.

### Logging

Every run writes a full transcript to `%TEMP%\Uninstall-FortiClient_<timestamp>.log`. Each MSI
attempt additionally writes its own verbose Windows Installer log to
`%TEMP%\MSIVerbose_<guid>_<timestamp>.log`. Attach these logs when reporting issues. Saved
credentials and the EMS identity are never written to either.

### After uninstalling

**Reboot, then run the script once more.** `FortiFilter.sys`, `ftvnic.sys` and friends are
loaded in kernel memory and cannot be deleted until the machine restarts; the second run sweeps
them and reports a clean result. This is expected, not a failure — it is why `3010` is a success
code here.

Removing FortiClient stops the endpoint's EMS/FortiGate telemetry and deletes any saved SSL-VPN
tunnel. It does **not** deregister the endpoint on the server side — only the administrator of
that FortiGate or EMS can do that. If the client was enforcing a NAC compliance gate on a
network you use, expect that network to stop admitting the machine.

Windows Security Center may briefly continue to list `FortiClient AntiVirus` as a registered
product. That registration is owned by `FCWscD7.exe` and clears on reboot; the script does not
hand-edit `HKLM:\SOFTWARE\Microsoft\Security Center`, because doing so can leave Defender
reporting itself as disabled.

### Notes and limitations

- Verified against **FortiClient 6.0.6.0242** (x64) on Windows 11. Newer 6.4+ and 7.x builds add
  a `C:\ProgramData\Fortinet` tree and may ship an EMS-pushed uninstall password; the script
  probes for the former and reports the latter from the MSI log rather than guessing.
- **An EMS-enforced uninstall lock cannot be bypassed by this script, by design.** If `msiexec`
  returns `1603` and the verbose log names a password or a management lock, removal has to be
  initiated from the managing EMS. The script reports it rather than attempting to defeat it.
- The `pppop` / PPPoP WAN Adapter package is a separate, older Fortinet product. It is always
  reported and never removed without `-IncludeLegacyPppop`.
- **Per-user residuals are cleaned for loaded hives only.** A user who is logged off keeps their
  `HKCU\SOFTWARE\Fortinet` leftovers; they are inert, and forcing them out risks the profile.
- No System Restore point and no registry export are taken — matching the other scripts in this
  repo, and additionally because an export of these hives would write DPAPI credential blobs to
  a file on disk.
- This tool is not affiliated with or endorsed by Fortinet. "FortiClient" and "Fortinet" are
  trademarks of Fortinet, Inc.

---

## `Uninstall-Adobe.ps1` — Adobe Creative Cloud, one product at a time

A self-elevating PowerShell script that uninstalls **the Adobe products you choose** by driving
Adobe's own HyperDrive uninstaller, then removes only the residue belonging to the products
actually removed. It is the only script in this repo built around **selection**: run it with
`-ListOnly` to see what is installed, then name what you want gone.

The thing that makes Adobe different from every other product in this repo:

> **An Adobe Creative Cloud product is not an MSI.** There is no `ProductCode`, no cached
> `.msi`, no `msiexec` route, and nothing in `HKLM:\SOFTWARE\Classes\Installer\Products`.
> Verified on this platform: `C:\Windows\Installer` holds 1,303 cached packages and **not one**
> is Adobe's. Every product instead delegates to a single shared broker, identified by a
> four-letter **SAP code**:
>
> ```
> "…\Common Files\Adobe\Adobe Desktop Common\HDBox\Uninstaller.exe"
>   --uninstall=1 --sapCode=PHSP --productVersion=26.6.1 --productPlatform=win64
>   --productAdobeCode={PHSP-26.6.1-64-ADBEADBEADBEADBEADBEA} --productName="Photoshop" --mode=1
> ```
>
> That command line is replayed **verbatim** from the registry, never reconstructed:
> `--productAdobeCode` is a per-product literal whose `ADBEADBE` padding length varies with the
> SAP code and version string, and cannot be derived.

Six Adobe-specific traps this script is built around:

1. **The products are invisible to a normal registry sweep — twice over.** Verified on this
   platform: all **12** Adobe rows live in the 32-bit view
   (`HKLM:\SOFTWARE\WOW6432Node\…\Uninstall`) — *including the win64 applications* — and the
   native 64-bit hive holds **zero**. Worse, **9 of the 12 carry no `DisplayName` at all**; they
   are hidden from Add/Remove Programs by having no name rather than by `SystemComponent=1`, so
   the usual `SystemComponent -eq 1` detection never fires either. A sweep filtered on
   `DisplayName -like '*Adobe*'` finds **three** products and silently leaves nine installed.
   This script keys on `Publisher` and on the uninstall command's own `--sapCode`, and
   synthesises a label from `--productName` when `DisplayName` is absent.
2. **Exit code `130` is a refusal, not a failure.** Adobe's engine refcounts shared components:
   asked to remove one that another installed product still references, it returns `130` and
   correctly declines. This machine's own `C:\ProgramData\Adobe\Installer\Summary.htm` already
   records a `130` from a previous attempt. A script that treats non-zero as failure and
   escalates to deleting the files by hand destroys a runtime the surviving applications still
   need — the same hazard as pulling `RealDWG Shared` out from under Revit. Here `130` is
   reported as *"still referenced"* and counted as success.
3. **The exit code is not the authority; the registry is.** `Uninstaller.exe` is a thin shim
   that hands the real work to `HDPIM.dll` and, when the Creative Cloud desktop app is present,
   to a GUI over a named pipe — so the process can return before, or independently of, the
   outcome. Every product is verified by **re-reading its uninstall key afterwards**. Key gone =
   removed, whatever the code said; key still present = not removed, whatever the code said.
4. **`InstallLocation` is a shared parent, and deleting it destroys the uninstaller.** Verified
   on this platform: **seven of the twelve rows** declare an `InstallLocation` of
   `C:\Program Files (x86)\Common Files\Adobe` or its 64-bit twin — not a per-product folder.
   That first path is the directory **containing `HDBox\Uninstaller.exe`**. A cleanup loop that
   deletes each removed row's `InstallLocation` would, on Camera Raw, delete the tool needed to
   remove everything else. This script never derives a deletion target from `InstallLocation`.
5. **The applications block their own uninstall, deliberately.** Photoshop and Illustrator are
   declared in Adobe's conflicting-process metadata with `forceKillAllowed="false"` — the engine
   refuses rather than kills them, because you may have unsaved work. Running the uninstall with
   them open produces an opaque failure. The script pre-flights for them and stops with a list,
   and only closes them under `-StopAdobe`, which asks each window to close before forcing it.
6. **File attribution by `CompanyName` is unsafe here in both directions.** Measured across 645
   binaries under the Adobe roots on this platform: "Adobe" is spelled **eight** different ways
   (`Adobe`, `Adobe Inc.`, `Adobe Inc` with no period, `Adobe Systems Incorporated`,
   `Adobe, Inc.`, `Adobe ` with a trailing space, `Adobe.`, `Adobe Systems, Incorporated`);
   **114 files carry no `CompanyName` at all** — including `CoreSync.exe` and `CCXProcess.exe`,
   the two most visible background processes; and **57 DLLs inside Adobe Illustrator 2025 report
   `Autodesk, Inc.`**, because Illustrator ships AutoCAD's ObjectDBX libraries. In a repo that
   also ships Autodesk uninstallers, that cuts both ways. Residual removal here is authorised by
   **path containment** under a verified Adobe root, never by a per-file vendor string.

### Features

- **You choose what goes.** `-Product` accepts SAP codes (`PHSP`), display names
  (`"Adobe Photoshop 2025"`), or fragments (`Photoshop`), in any mixture. With no selector and
  no `-Force`, it presents a numbered menu.
- **Ambiguity is never resolved by guessing.** A selector matching more than one product aborts
  the run and prints the candidates with their SAP codes. A selector matching none aborts and
  prints the full selectable list.
- **Applications and shared components are classified, not confused.** Structural test first —
  a product with a dedicated install directory is an application; one whose `InstallLocation`
  is a shared `Common Files` parent is not — corroborated by a known-SAP list, so a machine
  carrying products this repo has never seen still classifies correctly.
- **Vendor-first removal.** Adobe's own uninstaller runs before anything is hand-removed, and
  its command line is replayed byte-for-byte out of the registry.
- **Verified against the registry, not the exit code**, after every single product.
- **`CCXP` is guarded, not forbidden.** Adobe's metadata claims `node.exe` as a conflicting
  process for it, and the engine force-kills what it claims — which on a developer workstation is
  every unrelated Node process. So the script refuses **only while foreign `node.exe` processes
  are actually running**, lists them with their PIDs and paths, and tells you to close them.
  An earlier revision refused CCXP outright; that was a bug, because nothing else references CCXP
  so refcounting never reclaims it either — it stayed registered forever, and the vendor-wide
  sweep (gated on *no* Adobe product remaining) could then never run, permanently stranding
  ~620 MB of shared plumbing. A guard you can satisfy is correct; a refusal you cannot is not.
- **Shared plumbing is only swept once nothing is registered.** `Common Files\Adobe` is shared
  by every Adobe product *and holds the uninstaller* — so it is touched only after the last
  Adobe row is gone.
- **Reparse-point-safe profile enumeration.** Verified on this platform: `C:\Users\IcZ` is a
  **symbolic link** to the one real profile and `C:\Users\All Users` is a symbolic link to
  `C:\ProgramData`. An unfiltered per-profile loop walks into `ProgramData` under an
  Adobe-shaped path and processes the same profile twice.
- **Adobe's own install metadata is captured first**, into the log folder, before any tree that
  contains it can be deleted.
- **Self-elevation** via UAC with a **fail-closed `-WhatIf` relay**, **preview mode**
  (`-ListOnly`), and full `-WhatIf` support.

### Requirements

- Windows 10/11
- Windows PowerShell 5.1 (built in) — no modules required
- Administrator rights (the script self-elevates via UAC)

### Usage

```powershell
# Preview the census — every product with its SAP code and classification. Changes nothing:
powershell -ExecutionPolicy Bypass -File .\Uninstall-Adobe.ps1 -ListOnly

# Interactive: pick from a numbered menu, prompting before each step:
powershell -ExecutionPolicy Bypass -File .\Uninstall-Adobe.ps1

# One product by SAP code, unattended:
powershell -ExecutionPolicy Bypass -File .\Uninstall-Adobe.ps1 -Product PHSP -StopAdobe -Force

# Two products by name — -Product matches display names as well as SAP codes:
powershell -ExecutionPolicy Bypass -File .\Uninstall-Adobe.ps1 -Product Photoshop,Illustrator -StopAdobe -Force

# Every application, then a second pass to reclaim the shared runtimes:
powershell -ExecutionPolicy Bypass -File .\Uninstall-Adobe.ps1 -All -StopAdobe -Force
powershell -ExecutionPolicy Bypass -File .\Uninstall-Adobe.ps1 -All -IncludeSharedComponents -Force

# Full wipe including user presets, workspaces and the Camera Raw library:
powershell -ExecutionPolicy Bypass -File .\Uninstall-Adobe.ps1 -All -IncludeSharedComponents -RemoveUserData -RemoveShellExtensions -RemoveResidualRegistry -StopAdobe -Force

# Turning the default-on removal OFF needs -Command, not -File (see the note below):
powershell -ExecutionPolicy Bypass -Command "& '.\Uninstall-Adobe.ps1' -RemoveResidualFiles:$false -Product PHSP"
```

**Every opt-in is a switch — pass them bare, like `-Force`.** Not `-RemoveUserData:$true`. This
is not cosmetic: `powershell.exe -File` passes every argument as a literal **string**, and a
`bool` parameter's argument transformation rejects the string `"$true"` with *"Boolean
parameters accept only Boolean values and numbers"*. Measured: **no** `-File` form binds a
`bool` — not `:$true`, not `:1`, not `:0`, not `:true`. The single default-on `bool`
(`-RemoveResidualFiles`) is only ever passed to turn cleanup *off*, and that needs the
`-Command` form shown above.

**`-Product Photoshop,Illustrator` works, but not for the reason you would expect.**
`powershell.exe -File` does **not** split a comma-separated value into an array — measured, it
binds `$Product` to the single string `"Photoshop,Illustrator"`, which matches no product. That
is the same `-File` literal-string limitation that stops a `bool` parameter binding. Rather than
document a workaround for the invocation form every example here uses, the script splits the
value itself — and tries a whole-token match **first**, so a product whose real name contains a
comma is never split out from under you.

Run `-ListOnly` first. It is the safety gate, and it prints the exact `-Product` arguments to
use — including for the nine products that have no name in Add/Remove Programs at all.

**Two passes are normal, and not a bug.** Shared runtimes stay refcounted until the last
application referencing them is gone, so removing one application of two legitimately leaves
them in place with exit code `130`. Re-run with `-IncludeSharedComponents` once the last
application is removed.

### Parameters

| Parameter | Type | Default | Description |
|---|---|---|---|
| `-Product` | string[] | — | Which products to remove. Accepts SAP codes (`PHSP`), display names, or fragments, case-insensitively and in any mixture. A selector that matches zero or more than one product aborts the run rather than guessing. |
| `-All` | switch | off | Uninstall every discovered Adobe **application**. Shared components are still excluded unless `-IncludeSharedComponents` is also passed. |
| `-IncludeSharedComponents` | switch | off | Also attempt the shared runtimes — Camera Raw, CoreSync, the colour-profile bundles, UXP WebView Support. Safe rather than dangerous, because Adobe refcounts them and answers `130` for anything still in use; off by default only because attempting them while an application survives is a no-op that fills the log with refusals. |
| `-RemoveUserData` | switch | off | **Opt-in.** Also delete `%APPDATA%\Adobe`, `%LOCALAPPDATA%\Adobe`, `LocalLow\Adobe` and `ProgramData\Adobe\CameraRaw`. Measured on this platform: **2.24 GB** in `CameraRaw` alone, including user-authored presets under `Settings` and `SaveOptions`, plus 133 MB of Illustrator/Photoshop workspaces and installed fonts in `Roaming`. |
| `-RemoveShellExtensions` | switch | off | **Opt-in.** Remove CoreSync's Explorer integration. These carry no vendor string: the handler is registered as `AccExt`, and the three icon-overlay entries have value names beginning with **three leading spaces** (`" AccExtIco1"`). Every candidate is resolved through its CLSID to a DLL path and removed only when that path lies under an Adobe root. |
| `-RemoveResidualFiles` | bool | `$true` | Delete the removed products' own program folders and orphaned shortcuts, and — only once **no** Adobe product remains registered — the shared plumbing under `Common Files\Adobe` and `ProgramData\Adobe`. |
| `-RemoveResidualRegistry` | switch | off | **Opt-in.** Also delete `HKLM:\SOFTWARE\Adobe`, its WOW6432Node twin, `HKCU:\SOFTWARE\Adobe`, the App Paths entries in **both** registry views, and the `adobe+ilst` / `adobe+phxs` URL protocol handlers. Skipped while any Adobe product is still registered. |
| `-StopAdobe` | switch | off | Close running Adobe applications first. Each window is asked to close and only forced after it declines — Adobe's own engine refuses to force-kill these precisely to protect unsaved work. Without it the script aborts when Adobe is running. |
| `-ListOnly` | switch | off | Run the census, print every product with its SAP code and classification, and exit. No changes. |
| `-Force` | switch | off | Fully non-interactive. **Requires `-Product` or `-All`** — there is no menu to answer, and the script refuses to assume you meant everything. |
| `-LogPath` | string | `%TEMP%\...` | Override the transcript log path. Resolved to an absolute path before elevation. |

### Safety

- **Never `msiexec` for a Creative Cloud product.** The `--productAdobeCode` value *looks* like a
  GUID and is not one; handing it to `msiexec /x` is meaningless. The MSI path exists in the
  script for Acrobat and Reader only, and is selected by the shape of the registered
  `UninstallString`, not by guessing.
- **The Adobe Creative Cloud Cleaner Tool is never invoked, and never downloaded.** It is a
  blunt instrument that strips shared components other Adobe products still depend on. When the
  supported path fails, the script stops and points at Adobe's own log so you can decide.
- **No PDF association is ever rewritten.** The script never writes to `HKCR\.pdf` or to
  `…\Explorer\FileExts\.pdf\UserChoice`. After a PDF handler is removed Windows falls back to
  the remaining registered handlers on its own; hand-editing `UserChoice` is what leaves a
  machine with *no* working PDF association.
- **No Winsock, WFP or hosts-file changes.** Unlike `Uninstall-FortiClient.ps1`, there is no
  driver stage here at all — verified on this platform, Adobe ships **no** kernel driver and
  **no** `oem*.inf` driver package, so that machinery would be pure risk with no benefit.
- **Five refusals guard every deletion**: drive roots, paths with fewer than three segments,
  exact matches on protected system roots, paths that do not name Adobe, and — for the shared
  plumbing — any Adobe product still being registered.
- **The Microsoft-signed payload is reported, not hidden.** `Common Files\Adobe` contains
  Adobe's *private* copy of the Edge WebView2 runtime — 557 MB of Microsoft-signed code on this
  platform. It goes with the folder, and the script says so in the log rather than presenting it
  as Adobe code.

### Logging

Every run writes a full transcript to `%TEMP%\Uninstall-Adobe_<timestamp>.log`, and copies
Adobe's own install metadata (`Common Files\Adobe\Installers`, `ProgramData\Adobe\Installer`)
into `Uninstall-Adobe_<timestamp>_metadata\` beside it **before** anything is removed — that
metadata is the only on-disk record of what was installed, and it lives inside trees the script
may later delete. The capture is named from the log file so one run is always one identifiable
pair; its size (~7 MB) is reported in the transcript rather than copied silently.

**Old runs are pruned automatically, keeping the 5 most recent.** Nothing else ever cleans these
up: measured, 42 transcripts and 2 captures had accumulated in `%TEMP%` after a single afternoon.
Only artifacts this script created are considered — matched by an anchored pattern, never a
`Uninstall*` glob, because `%TEMP%` is full of other tools' files — the run in progress is
explicitly protected, and every deletion is named in the transcript.

When something fails, the script points at Adobe's own log:

```powershell
Get-Content 'C:\Program Files (x86)\Common Files\Adobe\Installers\Install.log' -Encoding Unicode -Tail 200
```

**`-Encoding Unicode` is required** — the file is UTF-16LE, and reading it as UTF-8 yields
interleaved nulls that look like corruption.

### Notes and limitations

- **Uninstalling does not deactivate your licence.** It does not free a seat on a named-user
  plan. Sign out in the Creative Cloud desktop app first, or deactivate at `account.adobe.com`.
- **Application preferences are destroyed by Adobe, not by this script.** The HyperDrive
  uninstall workflow sets `deleteUserPreferences=true` internally and exposes no flag to turn it
  off. The script warns before the first removal; `-RemoveUserData` is a separate, larger step.
- The Creative Cloud desktop app is handled if present but is **not** assumed to exist — verified
  on this platform it is absent, and "Adobe Creative Cloud" and "Adobe Creative Cloud Experience"
  are different products. Every step keyed on it is a guarded no-op.
- **Adobe Genuine Service** (`AGSService`, `AdobeGCClient`) is removed only if present. Verified
  on this platform it is absent — and note that a case-insensitive search for "Genuine" on this
  machine hits **Autodesk's** Genuine Service, which is why nothing here matches on that word.
- Shell-extension cleanup can leave `CoreSync_x64.dll` on disk: Explorer holds it open. The
  registrations go immediately; the file goes on the next sweep or the next sign-in.
- No System Restore point and no registry export are taken, matching the other scripts here.
- This tool is not affiliated with or endorsed by Adobe. "Adobe", "Photoshop", "Illustrator",
  "Acrobat", "Camera Raw" and "Creative Cloud" are trademarks of Adobe Inc.

---

## `Clear-RevitCache.ps1` — Revit caches, without uninstalling anything

The only script here that **keeps** Revit installed. It clears Revit's per-user caches — the
Personal Accelerator cache, the embedded browser caches, stale interprocess queues and journal
history — and, opt-in, the cloud collaboration cache and the Home screen's **Recent models**
page. Measured on one real machine: **4.9 GB** in `PacCache`, **1.1 GB** of journals, **35 GB**
across two years of collaboration cache.

No elevation. Every path is under the current user's profile, so run it as the user whose
caches you want cleared — running it elevated as a different account clears *that* account's
caches instead, which is the same trap the Navisworks script documents for per-user residuals.

### Nothing is matched by wildcard

Every other script here discovers what to remove from the registry. This one cannot: a cache is
a folder, not a registration, and `%LOCALAPPDATA%\Autodesk\Revit\Autodesk Revit <year>\` holds
caches and non-caches side by side. So the script carries an explicit **catalogue** of cache
locations and touches nothing else. A subfolder a future Revit release adds is *reported* as
left alone rather than swept up:

```
left alone: Autodesk Revit 2026\CC0778F2-011B-4284-B105-0009461644C5   (not in the cache catalogue)
left alone: Revit Personal Accelerator   (accelerator config (config.json), not cache)
```

The catalogue is also the authorisation: a location it did not resolve cannot be deleted, and a
catalogue row naming an unknown mode or an unknown opt-in switch is a **startup error**, not a
silent no-op. Both directions of that used to fail dangerously — a typo'd mode meant "delete the
whole container", a typo'd switch meant "never clears, even when asked".

### The three opt-ins

| Switch | What it adds | Why it is not default |
|---|---|---|
| `-IncludeCollaborationCache` | The local copy of every cloud-workshared (BIM 360 / ACC) model | **Unsynced work lives here and nowhere else.** Sync and close every cloud model first. Anything already synced is re-downloaded on next open — slow, but lossless. |
| `-ClearRecentFiles` | The Home screen's Recent models page | Not about disk space; it resets a list you navigate by. See below. |
| `-IncludeErrorReports` | `%LOCALAPPDATA%\Autodesk\CER` | Crash dumps for **every** Autodesk product, not just Revit — the evidence Autodesk support asks for. |

An opt-in cache that exists but was not asked for is reported with its size and its switch, so
a 22 GB cache is never silently invisible:

```
22.68 GB  2023 CollaborationCache - NOT in scope; add -IncludeCollaborationCache
```

`-OlderThanDays` is the practical safety valve for the collaboration cache: a project you have
not opened in 30 days is one you have already synced.

### Clearing the Recent models page

The Home screen's Recent list is **two stores**, and clearing one without the other leaves the
page half-populated:

1. the card thumbnails, in `%APPDATA%\Autodesk\Revit\Autodesk Revit <year>\RecentFileCache\`
2. the list itself, which lives inside **`Revit.ini`** under `[Recent File List]`

`Revit.ini` holds every Revit setting you have, so it is edited **surgically** rather than
deleted: only the `FileN=` lines, and the `ConfigN=` lines in `[Recent Workset List]` that are
keyed to them, are removed. Section headers and every unrelated setting stay. The file is
**UTF-16 LE with a BOM** — rewriting it as UTF-8 corrupts the lot — so the original encoding is
detected from the BOM and handed back to the writer, and the file is backed up to
`Revit.ini.<timestamp>.bak` first.

Revit rewrites `Revit.ini` when it exits, so this only sticks with Revit closed — which the
process guard already enforces. No model is touched; only the shortcuts to them.

### Usage

```powershell
# Preview every cache on the machine with sizes — changes nothing:
powershell -ExecutionPolicy Bypass -File .\Clear-RevitCache.ps1 -ListOnly

# Clear the safe caches for every year, prompting per location:
powershell -ExecutionPolicy Bypass -File .\Clear-RevitCache.ps1

# One year, unattended, closing Revit and the accelerator if they are open:
powershell -ExecutionPolicy Bypass -File .\Clear-RevitCache.ps1 -ProductYear 2026 -StopRevit -Force

# Empty the Home screen's Recent models page as well:
powershell -ExecutionPolicy Bypass -File .\Clear-RevitCache.ps1 -ClearRecentFiles

# ALSO clear cloud models — only projects untouched for 30+ days:
powershell -ExecutionPolicy Bypass -File .\Clear-RevitCache.ps1 -IncludeCollaborationCache -OlderThanDays 30
```

Run `-ListOnly` first, for the same reason the uninstallers have it.

### Parameters

| Parameter | Type | Default | Description |
|---|---|---|---|
| `-ProductYear` | string | `All` | Four-digit year, or `All` for every year found on disk. Shared caches (`PacCache`, `interprocess`, CER) are not year-scoped. |
| `-KeepJournals` | int | `10` | Journal sessions to keep per year. Journals are Revit's own crash log, so this trims rather than empties. A session is kept or dropped as a unit — the `.txt`, its `.worker1.log`, its `.dmp` and its `.abbrev` go together. |
| `-IncludeCollaborationCache` | switch | off | **Opt-in.** Cloud model cache. Unsynced work lives here. |
| `-ClearRecentFiles` | switch | off | **Opt-in.** Empty the Home screen's Recent models page. |
| `-IncludeErrorReports` | switch | off | **Opt-in.** The shared Autodesk crash dump store. |
| `-OlderThanDays` | int | `0` | Only clear entries older than N days. `0` disables the filter. |
| `-StopRevit` | switch | off | Terminate `Revit.exe` and the accelerator. Without it the script aborts when Revit is running, and skips only the cache a still-running helper holds open. |
| `-ListOnly` | switch | off | Print every cache entry with size and age, then exit. |
| `-Force` | switch | off | Non-interactive: skips the per-location prompt **and** the typed `YES` the collaboration cache otherwise requires. |
| `-LogPath` | string | `%TEMP%\...` | Override the log path. |

### Notes and limitations

- **`RecentFileCache` is not cleared by default** — it is ~0.1 MB, so there is no space case for
  it, and it is part of the Recent page rather than a cache in its own right. `-ClearRecentFiles`
  is the switch that takes it.
- Clearing the web caches (`CefCache`, `WebBrowserControl`) can force a re-sign-in to Revit Home
  and Autodesk services.
- The accelerator (`RevitAccelerator.exe`) holds `PacCache` open. Without `-StopRevit` the script
  skips that one cache and clears the rest rather than aborting the run.
- A collaboration cache relocated by registry override is cleared **where it actually lives**;
  the override is read rather than assumed. A location that resolves to a system directory is
  refused outright.
- Exit `3` after a run usually means a file was still open — close Revit and re-run.

---

## `Clean-Directory.ps1` — build-junk sweeper

Not an uninstaller and not Autodesk-specific. A small recursive sweep that finds and deletes
build junk under a directory you name — currently `*.bak` files and `__pycache__` folders.

It follows the same preview-first shape as the uninstallers, at a much smaller scale: it lists
every match with its full path, then requires you to type `YES` in full before deleting
anything. There is no elevation, no registry access, and no vendor uninstaller involved.

### Usage

```powershell
# Preview only — lists every match, deletes nothing:
powershell -ExecutionPolicy Bypass -File .\Clean-Directory.ps1 -RootPath "C:\Projects" -WhatIf

# Real run — lists matches, then requires typing YES:
powershell -ExecutionPolicy Bypass -File .\Clean-Directory.ps1 -RootPath "C:\Projects"
```

### Parameters

| Parameter | Type | Default | Description |
|---|---|---|---|
| `-RootPath` | string | *(required)* | The top-level directory to scan recursively. The script exits `1` if it does not exist, or if it resolves to a drive root. |
| `-WhatIf` | switch | off | List what would be deleted and exit without deleting. A plain switch, not the PowerShell common parameter. |

To sweep other patterns, edit the two arrays at the top of the script:

```powershell
$FilePatterns   = @("*.bak")
$FolderPatterns = @("__pycache__")
```

### Notes and limitations

- Deletion is **permanent** — items do not go to the Recycle Bin.
- The confirmation is a literal `YES`; anything else aborts with nothing deleted.
- Per-item failures (locked files, denied ACLs) are collected and reported at the end rather
  than stopping the run — but the script still exits `0` in that case, so check the printed
  error list rather than the exit code.
- A drive root is refused outright (exit `1`). `-RootPath C:\` would otherwise recurse the
  whole disk and delete every `*.bak` and `__pycache__` on it behind a single `YES`. Any other
  path is accepted as given, so read the `-WhatIf` output before committing.

---

## Reference documentation

[`Revit_Uninstall_Reference.md`](Revit_Uninstall_Reference.md) is the working teardown reference
behind `Uninstall-Revit.ps1`: the twelve lessons that cost real debugging cycles (ODIS command
quoting, StrictMode traps, MSI maintenance mode always running from the registered cache, the
PowerShell 5.1 Windows Installer COM traps), the product-selection rule, the captured product
codes from a verified removal, and the error-1606 / error-2753 root-cause analysis. Most of it
generalizes to the AutoCAD and Navisworks scripts, which reuse the same MSI machinery.

[TROUBLESHOOTING.md](TROUBLESHOOTING.md) is the operator-facing companion: the error-code map
and the manual fallback routes when the automated remediation cannot proceed.

[LESSONS_LEARNED.md](LESSONS_LEARNED.md) is the maintainer-facing one, and covers **all** the
scripts rather than just Revit. Every uninstall error that forced an iteration — 1606 needing a
second patch location, 1603/2753, the `/I` language-pack trap, `-WhatIf` failing to cross the
UAC boundary and destroying a live install — is written up as symptom → root cause → **the
invariant that must not be undone**. It ends with a 16-line regression checklist to run through
before committing a change, plus the drift that is currently known and unfixed.

**Read it before editing any script here.** These three documents answer different questions:

| Document | Answers |
|---|---|
| [TROUBLESHOOTING.md](TROUBLESHOOTING.md) | "My uninstall failed with code N. What now?" |
| [Revit_Uninstall_Reference.md](Revit_Uninstall_Reference.md) | "What exactly does Revit register, and where?" |
| [LESSONS_LEARNED.md](LESSONS_LEARNED.md) | "Why is the code written this way, and what breaks if I change it?" |

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
