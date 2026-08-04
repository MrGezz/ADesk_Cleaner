# Troubleshooting stubborn Autodesk uninstalls

Companion to the three Autodesk uninstallers — `Uninstall-Revit.ps1`,
`Uninstall-AutoCAD.ps1` and `Uninstall-Navisworks.ps1` — which share the same
MSI machinery and the same automated remediation chain. When a product refuses
to uninstall, the cause is almost always damaged Windows Installer state on the
machine, not the script. This covers the error codes seen in practice and how to
clear them.

Throughout, `<Product>` stands for `Revit`, `AutoCAD` or `Navisworks`, and the
stop switch is `-StopRevit`, `-StopAutoCAD` or `-StopNavisworks` respectively.

## Quick map

### Windows Installer codes

| Exit / error | Meaning | What to do |
|---|---|---|
| `1605` | "This action is only valid for a product that is installed" — already gone | Treated as success by the script; nothing to do |
| `3010` | Success, reboot required | Reboot; the removal is complete |
| `1618` | Another install/uninstall is already running | Wait for it (or reboot), then retry |
| `1619` | Package could not be opened | Almost always a path problem, not a corrupt package: a leading-space or relative path reaching `msiexec`, or a `.msi` still held open by an unreleased COM wrapper in the calling process (`0x80030020 STG_E_SHAREVIOLATION`). Both are handled in-script; if it appears, read the newest verbose log |
| `1606` | "Could not access network location …" | Either the MSI's own `DIRCA_INSTALLDIR` composing a relative `INSTALLDIR` (fixed automatically by the `MSI-PropsOverride` attempt) or a broken shell-folder registry value — see below |
| `1603` + Internal Error `2753` | Damaged MSI registration: a custom action sourced from an installed file cannot be resolved | Auto-remediated by the script (neutralize → recache → retry); MS troubleshooter is the manual fallback — see below |

### The scripts' own exit codes

These come from the script, not from `msiexec`, and are what automation should
branch on.

| Code | Meaning |
|---|---|
| `0` | Success |
| `3010` | Success, reboot required |
| `3` | Partial failure — one or more products did not uninstall |
| `2` | Nothing matched; no changes made |
| `1` | Aborted (target application running, elevation cancelled, invalid `-LogPath`) |

## Error 1603 with Internal Error 2753 (the hard one)

`Internal Error 2753. <file/component key>` means **"the file is not marked for
installation."** A custom action in the product's *uninstall* sequence — one
sourced from an INSTALLED FILE (CustomAction base type 17/18/21/22) — points at
a component whose registration is damaged. This happens after an interrupted
uninstall or a patch that left the registration inconsistent. A plain
`msiexec /x` (product code *or* cached local package path) cannot get past it —
every method returns 1603/2753 — because maintenance mode always runs from the
registered cached package (`Package we're running from ==>` in the verbose
log), so no command-line variation changes the tables being executed.

### Fix A (automated): the script's neutralize → recache → retry chain

All three Autodesk uninstallers implement this chain
(`-NeutralizeBrokenCustomActions`, default on) and resolve it without
force-removal. Verified end-to-end on the Revit 2023 core (2026-07-24):

1. Detects `Error 2753` in the failed attempt's verbose log and extracts the
   failing action name.
2. Copies the cached package to
   `%TEMP%\<Product>CleanerPatch_<stamp>\<registered name>.msi` — each script
   uses its own staging folder (`RevitCleanerPatch_`, `AutoCadCleanerPatch_`,
   `NavisCleanerPatch_`), but the exact registered *file* name inside it
   matters: repair source resolution probes
   `SOURCEDIR + <registered PackageName>` and fails 2203/1316 otherwise. A
   pristine backup (`<name>_pristine_<stamp>.msi`) is saved alongside.
3. Sets the broken action's `InstallExecuteSequence` `Condition` to `'0'` in
   the copy (the protected cache itself refuses transacted opens even
   elevated).
4. Recaches the copy with `msiexec /fv` (accepted: PackageCode unchanged;
   carries the INSTALLDIR override because repair costing hits
   `DIRCA_INSTALLDIR` too).
5. Retries by product code — the engine now executes the patched cache, skips
   the dead action, and the rest of the uninstall runs normally with full
   component cleanup and rollback.

### Fix B (manual fallback): Microsoft Program Install and Uninstall Troubleshooter

This tool force-removes the broken registration outright — no component
cleanup, but effective when the automated chain cannot proceed.

1. Download the official package (`.diagcab`):
   `https://download.microsoft.com/download/7/E/9/7E9188C0-2511-4B01-8B4E-0A641EC2F600/MicrosoftProgram_Install_and_Uninstall.meta.diagcab`
   (Reachable via Microsoft's support topic "Fix problems that block programs
   from being installed or removed".)
2. Run it → **Next** → choose **Uninstalling**.
3. Pick the stuck product (e.g. **Revit 2023**) from the list. If it is not
   listed, choose it by **product code** — for the 2023 core that is
   `{7346B4A0-2300-0510-0000-705C0D862004}`.
4. Let it remove the registration and clean the broken cache entry.
5. **Re-run the matching script** for that year, e.g.
   `powershell -ExecutionPolicy Bypass -File .\Uninstall-Revit.ps1 -ProductYear 2023 -StopRevit -Force`
   (or `.\Uninstall-AutoCAD.ps1 ... -StopAutoCAD -Force`, or
   `.\Uninstall-Navisworks.ps1 ... -StopNavisworks -Force`).
   The core now reports `1605` ("already gone") → success, so the run completes
   and residual cleanup finally proceeds.

Windows 11 note: Microsoft positions this troubleshooter for Windows 10, but the
`.diagcab` still runs on Windows 11. The built-in **Settings → Apps → Installed
apps → (…) → Uninstall/Repair** is the sanctioned Win11 path but will hit the
same 2753 on a damaged package; the troubleshooter is the one that force-clears
it.

### Diagnose first (optional)

Capture a verbose log to see exactly which file 2753 references:

```
msiexec /x {7346B4A0-2300-0510-0000-705C0D862004} /qn /norestart /l*v "%TEMP%\revit2023_v.log"
```

Open the log and search for `2753` and `Return value 3`. If the referenced file
still exists and the original source media is available, a repair-then-uninstall
(`msiexec /fvomus {code}` then `/x {code}`) can re-cache the package and let the
uninstall succeed. For Autodesk, source media is usually gone, so the
troubleshooter route is faster.

Two cautions learned on ICECREAMASSASIN:

- Forcing `INSTALLDIR`/`ROOTDRIVE` on an uninstall can itself provoke 2753 by
  flipping a component condition out of the action sequence — this is why the
  script keeps `MSI-PropsOverride` as the LAST MSI attempt, after the
  unmodified ones.
- Machine state drifts. The Revit 2023 core returned 1603/2753 in the morning
  runs and pure 1606-at-CostFinalize by the final runs of the same day. Always
  diagnose from the *newest* per-attempt log
  (`%TEMP%\MSIVerbose_<guid>_<stamp>_<Kind>.log`) — the script writes one per
  attempt precisely so an earlier attempt's evidence is never overwritten.

## Error 1606 ("Could not access network location …")

Two distinct causes produce this message. Identify yours from the verbose log:
if the "network location" is a bare **relative fragment** like `Revit 2023\`
and the failure lands in `CostFinalize` (with `Note: 1: 1314`), it is Cause A;
if it names a real (dead) drive/UNC path, it is Cause B.

### Cause A — the MSI's own `DIRCA_INSTALLDIR` action (proven, Revit 2023 core)

Autodesk's Revit MSIs carry a Type-51 custom action:

```
DIRCA_INSTALLDIR:  INSTALLDIR = [INSTALLDIR][ADSK_INSTALL_PATH]\
                   condition: NOT INSTALLDIR><ADSK_INSTALL_PATH   (>< = "contains")
ADSK_INSTALL_PATH: "Revit <year>"   (Property table default)
```

At install time ODIS passes the parent folder in `INSTALLDIR`, so the
composition yields a real absolute path. Uninstalling **directly with msiexec**
(the registry `UninstallString` is plain `MsiExec.exe /X{code}`), `INSTALLDIR`
arrives empty, the action composes the bare relative fragment `Revit <year>\`,
and `CostFinalize` fails: `Note: 1: 1314` → `Error 1606. Could not access
network location Revit <year>\.` — surfaced to the caller only as generic exit
1603. This is **not** a SourceList problem (the SourceList was verified healthy
while this fired), and no amount of LocalPackage/SourceList surgery fixes it.

**Fix:** pass an absolute `INSTALLDIR` that *contains* the `Revit <year>`
token. The contains-condition then evaluates true, `DIRCA_INSTALLDIR` is
skipped, and the override survives to costing:

```
msiexec /x {code} /qn /norestart ROOTDRIVE=C:\ INSTALLDIR="C:\Program Files\Autodesk\Revit <year>"
```

The script's `MSI-PropsOverride` attempt issues exactly this automatically
(last among the MSI attempts — see the 2753 cautions above). Formatting
matters: no trailing backslash before the closing quote (`\"` escapes the
quote and mangles the rest of the command line), and `ROOTDRIVE` unquoted
(no spaces; MSI requires its trailing backslash).

### Cause B — broken shell-folder registry value

A **shell-folder registry value** points at an invalid, redirected, or blank
path, and the installer can't resolve it. It recurs across packages until the
underlying value is fixed.

Permanent fix — correct the offending value (back up the key first):

- `HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders`
- `HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders`
- `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders`

Look for an entry (commonly `Personal`, `AppData`, `Common AppData`, `Cache`, or
a `{GUID}`) whose data points to a drive/UNC path that no longer exists or is
empty, and restore it to the correct local path (e.g. `Personal` →
`%USERPROFILE%\Documents`). Sign out/in afterward.

## Navisworks: a "successful" uninstall that removed nothing

Specific to `Uninstall-Navisworks.ps1`, and the reason it does not simply reuse
the Revit candidate builder.

Every Navisworks language pack — 11 per product — registers its uninstall
command as:

```
UninstallString = MsiExec.exe /I{GUID}
```

`/I` is the **install/repair** verb, not `/X`. A script that runs the registered
`UninstallString` verbatim therefore *repairs* each language pack, `msiexec`
returns `0`, and the run reports success while every pack remains installed.
Measured on a machine with Navisworks Manage 2026 plus Exporters 2023 and 2026:
**33 registry rows carry a `/I` uninstall string.**

`Uninstall-Navisworks.ps1` coerces `/I{GUID}` → `/X{GUID}`, and drops the
candidate entirely if the coercion cannot be anchored on a GUID — the MSI branch
has already synthesized a correct `/x {ProductCode}` from the registry key name,
which is the reliable route.

Two related shapes worth recognizing in the log:

- **The main product MSI has no `UninstallString` at all** (`SystemComponent=1`,
  blank uninstall string). It is still a real installed MSI with a cached
  `LocalPackage`, so `msiexec /x {ProductCode}` works. Any tool that filters out
  `SystemComponent=1` rows will skip the actual product and report nothing to do.
- **Two rows share the identical `DisplayName`** — the ODIS bundle wrapper and
  the hidden MSI child are both called `Autodesk Navisworks Manage <year>`, with
  different product codes and different `DisplayVersion` shapes (the wrapper's
  is the compressed form, `23.2.144496`, with the last dot dropped). This is
  expected, not duplication. De-duplicate by product code; never by name or
  version.

If **Export to NWC** vanished from Revit / AutoCAD / 3ds Max after a Navisworks
uninstall, the exporters were removed — they are a separate product and are not
restored by reinstalling Navisworks. Reinstall the free NWC Export Utility for
the matching year.

## General order of operations

1. Run `-ListOnly` to confirm scope.
2. Run the uninstall (`-StopRevit` / `-StopAutoCAD` / `-StopNavisworks`, plus
   `-Force`).
3. If a product fails, read the transcript
   `%TEMP%\Uninstall-<Product><year>_*.log` (the script prints the raw uninstall
   strings for any failure) and the per-attempt verbose logs
   `%TEMP%\MSIVerbose_<guid>_<stamp>_<Kind>.log`.
4. `1606` → Cause A is handled automatically by the `MSI-PropsOverride`
   attempt; for Cause B, fix the shell-folder values for a permanent cure.
5. `1603` / `2753` → Microsoft Program Install and Uninstall Troubleshooter, then
   re-run the script so residual cleanup completes.
