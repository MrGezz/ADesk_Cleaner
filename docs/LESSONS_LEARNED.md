# Lessons learned

Every rule in this file was paid for with a failed uninstall. Most of them look
like over-engineering until you know which run they came from, so each one
records the **symptom**, the **root cause**, and — most importantly — **the
invariant that must not be undone**.

Three documents, three jobs:

| Document | Answers |
|---|---|
| [TROUBLESHOOTING.md](TROUBLESHOOTING.md) | "My uninstall just failed with code N. What now?" |
| [Revit_Uninstall_Reference.md](Revit_Uninstall_Reference.md) | "What exactly does Revit register, and where?" |
| **This file** | "Why is the code written this way, and what breaks if I change it?" |

If you are about to edit one of these scripts, skip to the
[regression checklist](#regression-checklist) at the end.

---

## How we got here

The commit history is the iteration log. It is not a straight line, and that is
the point — several fixes were wrong the first time:

| Commit | What forced it |
|---|---|
| `80d02ac` self-elevation for spaced script paths (v6) | Elevation silently did nothing when the script lived under `E:\ICZ 2\` |
| `f2f9384` **Error 1606** | Core Revit MSI refused to uninstall |
| `ea00aea` **Error 1606 2nd Patch Location** | The first 1606 fix was incomplete — same error, second code path |
| `d601439` Patches | Fallout from the above |
| `37844d1` Error-2753 remediation + **five delivery-chain defects** | `1603` + `Internal Error 2753`; fixing it exposed five more bugs between "we chose a command" and "the command ran" |
| `0bac1d7` Navisworks + **nine defects across the Autodesk and pyRevit scripts** | Writing a third uninstaller revealed the first two were wrong in nine places |
| `cd1279d` **-File parameter binding** across three uninstallers | Documented switches simply did not bind |

Two patterns repeat and are worth internalising:

1. **The first fix for an Installer error is usually incomplete.** 1606 needed a
   second patch location; 2753 needed a whole neutralize→recache→retry chain.
2. **Writing script N finds bugs in scripts 1..N-1.** Nine defects surfaced only
   when Navisworks forced a second look. This is why the
   [regression checklist](#regression-checklist) is a table, not prose.

---

## A. The elevation boundary

**The UAC boundary is a serialization boundary.** Anything not explicitly
written into the child's command line does not exist in the privileged process.

### A1. `-WhatIf` does not cross it — and a preview becomes a real uninstall

The worst failure in this repo's history. Common parameters (`-WhatIf`,
`-Confirm`, `-Verbose`, `-Debug`) live **outside** `param()`, so a relay built by
walking the script's own parameter list drops them silently. The elevated child
starts without `-WhatIf`, `ShouldProcess()` returns `$true`, and a command the
operator issued as a preview performs a real uninstall.

Recorded in `Uninstall-AutoCAD.ps1`: on **2026-08-02**,
`-ProductYear 2026 -WhatIf -Force` removed a live AutoCAD 2026.

**Fix, in two parts** — both are required:

```powershell
if ($WhatIfPreference) { $passArgs += '-WhatIf' }          # 1. relay it
...
# 2. FAIL CLOSED - verify it is actually in the bytes about to be launched
if ($WhatIfPreference -and $cmdLine -notmatch '(?i)(?<=\s)-WhatIf(?=\s|;|")') {
    Write-Host 'Refusing to elevate: -WhatIf was requested but is not present...'
    exit 1
}
```

Part 2 is not paranoia. Part 1 is one line that a refactor can drop, and the
failure is silent and destructive. Verify the *output*, not the intent.

> **Invariant:** every self-elevating script relays the four common parameters
> **and** re-checks `-WhatIf` in `$cmdLine` before `Start-Process -Verb RunAs`.

### A2. The elevated child's working directory is not yours

It is `%SystemRoot%\System32`. A relative `-LogPath run.log` relayed across the
boundary writes the transcript into System32. Resolve `-LogPath` to an absolute
path **before** the relaunch, and exit `1` if it cannot be resolved.

### A3. `Start-Process -ArgumentList` mangles spaced paths

In PS 5.1, `Start-Process` re-quotes **array** elements and breaks a script path
containing a space (`E:\ICZ 2\...`) — elevation appears to do nothing at all.
Build the command line as a **single pre-quoted string**.

### A4. `Start-Transcript` is ShouldProcess-aware

Under `-WhatIf` it *previews* instead of opening the log, and the run then
announces a log path for a file that was never written. Use
`Start-Transcript -WhatIf:$false`: the transcript is the script's own diagnostic
output in `%TEMP%`, not a change to the machine being previewed.

The same class of leak makes `Get-CimInstance` autoload `CimCmdlets` mid-run,
whose own top-level `Set-Alias` calls inherit `$WhatIfPreference` and spray
`What if: Performing the operation "Set Alias"` through the report. Preload it in
a child scope with the flag off.

---

## B. Parameter binding and exit codes

### B1. `powershell.exe -File` cannot bind a `[bool]` parameter

`-File` passes every argument as a literal **string**, and a `[bool]` parameter's
argument transformation rejects `"$true"` with *"Boolean parameters accept only
Boolean values and numbers"*. Measured: **no** `-File` form binds — not `:$true`,
not `:1`, not `:0`, not `:true`. `[switch]` has a parser special-case, which is
why `-Force` always worked.

**Consequence for design:** any parameter an operator actually types must be
`[switch]`, because every example in the README uses `-File`. `[bool]` is
acceptable only for default-on parameters that are rarely turned off, and turning
them off requires the `-Command` form.

The elevated child is worse: it dies at **parameter binding, before
`Start-Transcript`** — no log, and elevation appears to "do nothing".

### B2. `exit N` inside a `-Command` script collapses to 1

In `-Command` mode an `exit N` inside the invoked *script* only sets
`$LASTEXITCODE`. Without re-exiting, the child process reports **1** for every
non-zero code. Measured: `exit 42` came back as `1` without it, `42` with it —
destroying the `0`/`2`/`3`/`3010` contract the parent relays.

```powershell
$cmdLine = '... -Command "& ''{0}'' {1}; exit $LASTEXITCODE"' -f $qPath, $args
```

> **Invariant:** the `; exit $LASTEXITCODE` suffix stays.

### B3. `-Force` does not suppress `ShouldProcess`

With `ConfirmImpact='High'`, PowerShell prompts "Are you sure?" per item even
under a custom `-Force`. Set `$ConfirmPreference = 'None'` when `-Force` is
passed, or an "unattended" run blocks forever.

---

### B4. `-File` hands `-Scope A,B` over as ONE string

From a PowerShell prompt, `-Scope Startup,Power` is an array. Through
`powershell.exe -File` — and therefore through every `.cmd` launcher — it is the
single string `"Startup,Power"`, and a `[ValidateSet]` on the `[string[]]`
parameter rejects it before the script runs a line. Measured on
`Remove-LegacyHardwareResidue.ps1`: the README's own `-Scope Asus,Display`
example failed from the launcher with *"does not belong to the set"*.

**Invariant:** no `[ValidateSet]` on a list parameter a launcher can pass.
Split on commas after binding, trim, validate by hand with the same message,
and canonicalise the casing so later `-contains` checks are exact.

## C. Windows Installer failures

Full remediation steps live in [TROUBLESHOOTING.md](TROUBLESHOOTING.md); this is
why the code is shaped the way it is.

### C1. Never route an Autodesk uninstall through `cmd /c`

The ODIS `UninstallString` is **unquoted** and its path contains a space
(`C:\Program Files\Autodesk\AdODIS\V1\installer.exe`). `cmd /c` reads it as
`C:\Program` and fails with a generic **exit 1**. Parse into executable +
arguments and call `Start-Process -FilePath <exe> -ArgumentList <args>`.

### C2. Error 1606 — and why the first fix was not enough

`Could not access network location Revit <year>\` comes from the MSI's own
uninstall sequence composing a **relative** `INSTALLDIR`. It needed **two**
patch locations (`f2f9384`, then `ea00aea`) — the same error reached through a
second code path. The final defence is a directory-property override kept as the
**last** `msiexec` attempt, because property overrides can themselves provoke
2753 on other packages.

### C3. Error 1603 + Internal Error 2753

A custom action sourced from an installed file whose component registration is
damaged. The chain: copy the cached package out of `C:\Windows\Installer`,
condition the named action out **in the copy**, recache with `/fv`, retry.

The protected cache is never modified — recent Windows builds refuse writes there
even elevated. This is the surgical alternative to Microsoft's Program Install
and Uninstall Troubleshooter, and it keeps full component cleanup and rollback.

### C4. `/I` is the install verb — running it "succeeds" while uninstalling nothing

Every Navisworks language pack registers `UninstallString = MsiExec.exe /I{GUID}`.
Run verbatim, it performs a **repair** and exits **0**. Since 0 counts as success,
the product is logged as uninstalled while still installed — and residual cleanup
then deletes the files of a still-registered product.

Coerce `/I` → `/X`, then **verify the coercion took** and drop the candidate if a
bare `/I` survived. On this platform **33 registry rows** carry a `/I` uninstall
string.

> **Invariant:** no harvested command line is ever executed without proving it is
> a removal verb.

---

## D. Discovery: what the registry does not tell you

- **A product is not one entry.** Each Autodesk year registers an ODIS update
  bundle, an ODIS wrapper, and hidden MSI children (`SystemComponent=1`).
- **The main Navisworks MSI has no uninstall string at all.** Any filter that
  skips `SystemComponent=1` or blank-`UninstallString` rows skips the actual
  product. It is reachable only by product code.
- **`ACAD Private` is unnameable.** Every installed AutoCAD year registers a
  child under that identical name, with no year and no "AutoCAD" in it. Match it
  by install location; **de-duplicate targets by product code, never by display
  name**, or all years collapse into one arbitrary entry.
- **The release number is not the year.** AutoCAD 2025 = `R25.0`, 2026 = `R25.1`,
  2027 = `R26.0`. Navisworks major = year − 2003. **Read it from the registry;
  never compute it** — and when it cannot be proven, skip release-scoped cleanup
  rather than guess. Deleting the wrong release key wipes a different version's
  profiles, toolbars and plotter settings.
- **A shared component can carry a year.** `RealDWG Shared <year>` and
  `Shared Components <year>` are consumed by Revit, Navisworks and Inventor. A
  year in the name proves nothing about ownership.
- **Name ≠ ownership.** `Autodesk Navisworks Exporters <year>` is a separate,
  licence-free product that installs *into* Revit/AutoCAD/3ds Max. A naive
  `*Navisworks*` rule kills **Export to NWC** everywhere — the single most likely
  way this tooling causes user-visible damage.
- **Attribute by provenance, not by mention.** FortiClient drivers are identified
  by the INF's `Provider=` directive, not by "Fortinet" appearing anywhere in the
  file. A third party's INF whose only reference is a comment would otherwise be
  handed to `pnputil /delete-driver /uninstall`, which force-removes every device
  bound to that package.

---

## E. Deletion safety

### E1. Gate residual cleanup on success — and on nothing being declined

An early version deleted `C:\Program Files\Autodesk\Revit 2026` and the per-user
settings folders **even though the core uninstall had failed**, leaving files
gone and the registration present. Cleanup runs only when `$failures -eq 0` —
and, added later, only when nothing was **declined**, because a product you
answered "No" to is still installed.

### E2. Put the containment guard inside the function, not at the call sites

If the only thing keeping a recursive force-delete on target is a glob in the
*discovery* function, the next call site has no protection at all. Guard the
function that does the dangerous thing.

`Clear-RevitCache.ps1` goes further: authorisation is **derived from its
catalogue**, so a hardcoded allowlist cannot drift away from what the script
actually resolves. That drift was a real defect — with the collaboration cache
relocated by registry, the run previewed it, prompted for the typed `YES`, then
refused every delete and exited 3.

### E3. Fail closed on unknown input

A `switch` whose `default` arm means "delete the whole container" turns a typo
into data loss. Unknown mode, unknown opt-in switch name → **throw**. Both
directions used to fail dangerously: a typo'd mode deleted everything, a typo'd
switch name silently never cleared even when asked.

### E4. Substring tests are not path tests

`$path -match '\\Autodesk\\'` accepts `C:\Backup\Autodesk\Revit-2026-archive`.
Compare whole path **segments**, check depth, and require the product token and
year in the positions they actually occupy.

### E5. `%APPDATA%` and `%LOCALAPPDATA%` may be junctions

OneDrive Known Folder Move and enterprise folder redirection turn exactly these
roots into reparse points, and `Remove-Item -Recurse -Force` through one can
delete the **target's** contents — user data far outside the product tree.

---

### E6. A vendor pattern is not a removal list

`Remove-LegacyHardwareResidue.ps1` originally built the `-Scope Startup`
Run-key sweep from **every** vendor profile's pattern, eligible or not. With
two profiles that was merely wrong in principle; with AMD, NVIDIA and Gigabyte
in the catalogue it would have deleted this machine's live GPU and board
autostart entries on a Startup run. Found by reading, not by running — which
is the cheap way to find it.

**Invariant:** anything that turns a *name match* into a *removal* reads from
the eligible set, never from the catalogue. Dead-target entries stay
vendor-independent, because "the file is gone" is evidence on its own.

Related, from the same change: `'x' -match $null` is `$true`. A profile field
that can be `$null` (Appx pattern, program pattern, root-task pattern) is
guarded at every use site, or the vendor with no Appx pattern is handed every
Appx package on the machine.

### E7. A name test cannot tell a clone from your extensions

`Uninstall-PyRevit-Complete.ps1` read `pyRevit_config.ini` by scanning every line
for anything shaped like a drive-letter path and treating each hit that contained
"pyrevit" as a clone to delete. The INI's `userextensions` key holds the user's
own extension folders — on this machine `...\IcZ PyRevit\IcZWorkSpace`, on the
other install a folder on `D:` — and both matched. The function-level guard (E2)
was the same substring test, so it let them through, and the sweep deleted a
development workspace on a second drive.

No spelling of the name check fixes this: the workspace really is named after
pyRevit. The fix is to classify by **what a folder contains** and **where it is**:

- read the INI by section and key — `[environment] clones` are candidates,
  `[core] userextensions` are protected, nothing else is consulted;
- a folder holding `bin\` + `pyrevitlib\` is a clone; a folder named
  `*.extension`, or directly holding one, is a user extension area and is never
  deleted; anything under a footprint root (`%APPDATA%`, `%LOCALAPPDATA%`,
  `%PROGRAMDATA%`, `%TEMP%`, ...) is pyRevit's; anything else is unverified and
  only reported;
- nothing outside `%SystemDrive%` is touched unless asked, and then only a
  verified clone;
- all three fences live inside `Remove-Tree`, and what they keep is listed and
  excluded from the verdict so the run can still end CLEAN.

Two things made the test harness worth writing. Paths on this machine come in
two spellings — `%TEMP%` is `C:\Users\ICECRE~1\...`, `Get-ChildItem` returns
`C:\Users\IceCreamAssasin\...` — and they compare unequal, so every path that
crosses a fence is normalised to the long form first (`Get-Item` does it). And a
regression test that passes has to be shown able to fail:
`tests\Test-PyRevitFences.ps1` has an `-ExpectDefective` mode that passes only
when the pre-fix copy WOULD have deleted the workspace.

> **Rule: never delete on the strength of a name. Classify by content and
> location, and put the classification inside the deletion function.**

---

## F. Windows PowerShell 5.1 traps

- **StrictMode: guard the absent OBJECT as well as the absent property.**
  `Get-ItemProperty` on a key with **zero values** returns `$null` *without
  throwing*, so `try/catch` does not fire; the next `.PSObject` dereference kills
  the whole hive enumeration. Valueless container keys are normal, not
  corruption. Check `if ($null -eq $Obj) { return $null }` **before** the lookup.
- **`Measure-Object -Property` returns nothing for an empty pipeline** — not a
  zero-count object. Under StrictMode, `$sum.Sum` is then a terminating error.
  Guard the object, not just the property.
- **`Get-Content` decorates every line** with `PSPath`/`PSParentPath`/`ReadCount`
  note properties. Over this machine's driver store (149 INFs, 9.1 MB, 164k
  lines) `[System.IO.File]::ReadAllLines()` measured **1.8× faster** with
  **0** output differences across all 149 provider names.
- **`Remove-Item` is not long-path aware**, even with `LongPathsEnabled=1`.
  Fallback chain: `Remove-Item` → `cmd /c rd /s /q` → robocopy empty-mirror.
- **`-Force` already clears read-only and hidden.** Do not pay for a recursive
  `attrib` walk (and a process spawn) up front — it only earns its cost in the
  failure path.
- **`-Include` with `-Directory -Recurse` is broken.** Verified during review:
  it returns non-matching directories, so using it to pick deletion targets would
  delete everything under the root.
- **`return ,$array` double-nests** when the caller wraps in `@(...)`, fusing two
  uninstall candidates into one and handing `System.Object[]` to
  `Start-Process -FilePath`.
- **`Test-Path -LiteralPath` THROWS on a malformed path; it does not return
  `$false`.** It validates the string before it tests it, so a `"`, `<`, `>`,
  `|` or a control character raises `ArgumentException` — and under
  `$ErrorActionPreference = 'Stop'` that ends the run. `-LiteralPath` protects
  against *wildcards*, not against *illegal characters*. Every path these
  scripts test is second-hand (a service `ImagePath`, a scheduled-task action, a
  Run key, an uninstall string), so all of them now go through a `Test-PathSafe`
  wrapper that answers "no" instead of throwing. Found the hard way: a run that
  had already removed the drivers died at the very last phase.
- **`[IO.Path]::GetInvalidPathChars()` returns a DIFFERENT set per runtime.**
  .NET Framework (Windows PowerShell 5.1) lists `"`, `<`, `>`, `|` and the
  control characters; .NET Core (pwsh 7) trimmed the same call down to `NUL`
  alone. Asking the framework therefore produces a *weaker* guard under 7 than
  under 5.1, and a validator written against 5.1 silently stops validating. Spell
  the set out in the script rather than asking for it.
- **Vendors write junk into `ImagePath`.** Measured on this machine:
  `GigabyteUpdateService` carries a trailing `U+FFFF` noncharacter after the
  `.exe`. A resolver must cut at the image extension rather than trusting the
  value to end where the path ends — and `REG_MULTI_SZ` (or a caller that
  `[string]`-coerces an array) glues two paths together with a space, which is
  not a path at all.
- **`("a string")[0]` is a CHARACTER, not the string.** A helper that returns one
  string and a caller that writes `(Get-Thing ...)[0]` silently yields `f`
  instead of `function ...`. Wrap single returns as `,$value` or index nothing.
- **`[Environment]::SetEnvironmentVariable` corrupts `PATH`** — see the README
  section; it returns the *expanded* value and always writes `REG_SZ`, baking
  `%SystemRoot%` into a literal and downgrading the value type.

---

## F2. cmd.exe traps in the launchers

- **`CMDCMDLINE` is a DYNAMIC variable, and substring substitution does not
  work on one.** cmd synthesises `CMDCMDLINE`, `CD`, `DATE`, `TIME`, `RANDOM`
  and `ERRORLEVEL` on read rather than storing them in the environment block.
  Plain reads work either way — `%cmdcmdline%` and `!cmdcmdline!` both print
  the right thing — but the `:str1=str2` transform is only applied to variables
  that are really in the block, so `!cmdcmdline:/c=!` silently returns the
  value **unmodified**. Every launcher used

  ```cmd
  if not "!cmdcmdline:/c=!"=="!cmdcmdline!" pause
  ```

  to pause only when started from Explorer. The two sides always compared
  equal, so **the pause never fired in any of the twelve launchers** — a window
  opened, did its work and vanished. Copy the value into a real variable first,
  and keep delayed expansion for the comparison so an `&` or a quote in the
  launch path cannot be parsed as a command:

  ```cmd
  set "LAUNCHLINE=%cmdcmdline%"
  setlocal EnableDelayedExpansion
  if not "!LAUNCHLINE:/c=!"=="!LAUNCHLINE!" pause
  ```

  The lesson generalises: a construct that *silently does nothing* passes every
  smoke test. Nothing errored, the exit code was right, and the only symptom
  was a window closing — which reads as normal.
- **`if errorlevel N` means N OR HIGHER**, so tests after a `choice` must run in
  DESCENDING order or `3` also satisfies the test for `2`.
- **A successful `set` resets ERRORLEVEL to 0**, so branch on a `choice` result
  BEFORE the first assignment. Seeding a default and overriding it looks tidier
  and sends every selection down the first branch.
- **`%VAR%` is substituted when a block is PARSED**, before the block has run.
  Inside `( )` that silently uses the value from before the block. Use `!VAR!`
  and keep control flow flat with labels.

---

## F3. WPF from PowerShell: the ResourceDictionary keeps the PSObject

`hub\Start-Hub.ps1` swaps its theme by rewriting the brushes in the window's
resource dictionary. The first cut did the obvious thing:

```powershell
$window.Resources['Text'] = New-Object System.Windows.Media.SolidColorBrush $color
```

and every `{DynamicResource Text}` consumer threw
`'#FFF1F5F9' is not a valid value for property 'Foreground'`. The indexer's
parameter is `object`, and when the target type is `object` PowerShell passes
its **PSObject wrapper** through unconverted. WPF then holds a PSObject where it
expects a Brush, fails the type check, and reports the value's string form.

Two fixes, both verified: mutate the XAML-declared brush in place
(`$window.Resources['Text'].Color = $color` — brushes declared in a
`ResourceDictionary` are not frozen, and the change reaches every consumer), or
unwrap explicitly with `$brush.psobject.BaseObject` before assigning. The hub
does the former and falls back to the latter for a key the XAML does not declare.

The same wrapper is why `FindWindow($null, $title)` never finds anything from
PowerShell: `$null` marshals to `""` for a `string` parameter, so the call
searches for an empty class name. Enumerate windows by title instead.

> **Rule: anything handed to a .NET `object` parameter from PowerShell may still
> be a PSObject. Unwrap it, or avoid the handoff.**

---

## G. The meta-lesson: drift between sibling scripts

These scripts deliberately ship as **standalone files** with no shared module, so
one file can be dropped on a machine. The cost of that decision is real and must
be managed: **a fix landing in one script and not its siblings.**

Nine defects surfaced this way at `0bac1d7`. A later review found more: the
`-WhatIf` elevation fix existed in three scripts and not in Revit; the `/I`→`/X`
verification existed only in Navisworks; the junction guard only in AutoCAD.

> **Rule: when you fix something in one uninstaller, immediately check the other
> three.** Cheapest way to do it:
> ```bash
> grep -n "Test-SafeResidualPath\|WhatIfPreference\|/X" scripts/*/Uninstall-*.ps1
> ```

---

## Regression checklist

Before committing a change to any script here, confirm these still hold. Each
line is a bug that already happened once.

| # | Invariant | Where |
|---|---|---|
| 1 | Common parameters relayed across UAC **and** `-WhatIf` re-checked in `$cmdLine` before `RunAs` | all four self-elevating uninstallers |
| 2 | `; exit $LASTEXITCODE` present in the elevated command line | all four |
| 3 | `-LogPath` resolved to absolute **before** elevation | all four |
| 4 | `Start-Transcript -WhatIf:$false` | all four |
| 5 | Operator-facing opt-ins are `[switch]`, never `[bool]` | all |
| 6 | `$ConfirmPreference = 'None'` when `-Force` | all with `ShouldProcess` |
| 7 | Autodesk uninstall commands never routed through `cmd /c` | three Autodesk |
| 8 | Harvested `/I` coerced to `/X`, coercion **verified**, candidate dropped if not | Navisworks (port pending elsewhere) |
| 9 | Targets de-duplicated by **product code**, never display name | AutoCAD, Navisworks |
| 10 | Release/version **read** from registry, never computed; skipped if unproven | AutoCAD, Navisworks |
| 11 | Residual cleanup gated on `$failures -eq 0` **and** nothing declined | all |
| 12 | Containment guard inside the deletion function, not at call sites | pyRevit, Clear-RevitCache |
| 13 | Unknown mode / unknown opt-in name throws rather than defaulting | Clear-RevitCache |
| 14 | NWC exporters excluded unless `-IncludeExporters` | Navisworks |
| 15 | `$null -eq $Obj` checked before `.PSObject` | all reading the registry |
| 16 | Drive roots refused | all that delete |
| 17 | Vendor-match removals (Run keys, tasks) drawn from **eligible** vendors only; a refused vendor never feeds a removal list | Remove-LegacyHardwareResidue |
| 18 | List parameters accept one `"a,b"` string and split it **after** binding — no `[ValidateSet]` on a `[string[]]` that `-File` or a `.cmd` launcher can pass | Remove-LegacyHardwareResidue, Remove-WindowsBloat |
| 19 | A `-match` against a pattern that can be `$null` is guarded at the use site — `-match $null` matches everything | Remove-LegacyHardwareResidue (Appx/Program/TaskName patterns) |
| 20 | Function results that may be empty are wrapped in `@()` at the call site before `.Count` under `Set-StrictMode` | Remove-WindowsBloat |
| 21 | No second-hand path (registry value, task action, shortcut target) reaches `Test-Path` directly — all of them go through the non-throwing `Test-PathSafe` | Remove-LegacyHardwareResidue, Clean-StartupApps |
| 22 | Invalid path characters are spelled out, never taken from `[IO.Path]::GetInvalidPathChars()`, which is weaker under pwsh 7 than under 5.1 | Remove-LegacyHardwareResidue, Clean-StartupApps |
| 23 | Every tweak carries an explicit `MinBuild`/`MaxBuild` so a Windows 10 value never fires on Windows 11 and vice versa | Remove-WindowsBloat |
| 24 | Two tweaks never write the same registry value to different data; if they do, selection resolves the conflict out loud | Remove-WindowsBloat |
| 25 | An entry classified KEEP is refused even when named explicitly | Clean-StartupApps |
| 26 | The Explorer-pause test reads `CMDCMDLINE` through a real variable, never `!cmdcmdline:...!` directly — substring substitution does not apply to a dynamic variable | all 12 `.cmd` launchers |
| 27 | No folder is deleted on the strength of its name: the deletion function classifies by content (clone markers, `*.extension` children) and location (footprint roots, system drive) and refuses the rest, out loud | Uninstall-PyRevit-Complete |
| 28 | `pyRevit_config.ini` is read by section and key; `userextensions` paths are protected and are never candidates | Uninstall-PyRevit-Complete |
| 29 | Paths that cross a guard are compared in long form — an 8.3 `%TEMP%` and a long `Get-ChildItem` result are the same folder | Uninstall-PyRevit-Complete |
| 30 | `tests\Test-PyRevitFences.ps1` passes, and passes in `-ExpectDefective` mode against the pre-fix copy | Uninstall-PyRevit-Complete |

### Known outstanding drift

Found during review, **not yet fixed** — each needs a real-machine `-ListOnly`
diff before it ships, because all three can newly *refuse* something currently
accepted:

- `Uninstall-Revit.ps1` has no `Test-SafeResidualPath`: no junction check, and
  substring rather than segment matching (checklist #12/E4/E5).
- `/I`→`/X` verification is weaker in Revit and AutoCAD than in Navisworks —
  `MsiExec.exe /I {GUID}` *with a space* is not coerced (checklist #8).
- `Uninstall-Revit.ps1`'s process guard is name-only, so `-StopRevit` targeting
  one year would terminate an open session of another. The siblings attribute
  running processes by install path.
