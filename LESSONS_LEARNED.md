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
- **`[Environment]::SetEnvironmentVariable` corrupts `PATH`** — see the README
  section; it returns the *expanded* value and always writes `REG_SZ`, baking
  `%SystemRoot%` into a literal and downgrading the value type.

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
> grep -n "Test-SafeResidualPath\|WhatIfPreference\|/X" Uninstall-*.ps1
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
