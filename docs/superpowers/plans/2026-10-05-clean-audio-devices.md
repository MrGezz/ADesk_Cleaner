# Clean-AudioDevices Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A standalone PowerShell 5.1 script, `Clean-AudioDevices.ps1`, that removes not-present audio
endpoints left by previous hardware and drivers from Settings → Sound → All sound devices. It also
removes their ghost devnodes and dead per-app audio settings. It runs census-first, backs up before
changing anything, and can restore exactly what it removed.

**Architecture:** One script in three layers:
- **gatherers** read MMDevices, Enum, PnP and the per-app store into plain records;
- **pure functions** classify those records and build command lines;
- **actors** delete, back up, restore and control services. Each actor carries its own guard.

Registry keys that Administrators cannot delete are opened with backup semantics
(`SeRestorePrivilege` + `REG_OPTION_BACKUP_RESTORE`) and removed with `NtDeleteKey`, so no ACL is
ever modified. Backups are `reg save` hives, which keep each key's security descriptor; restore is
a backup-semantics key creation followed by `reg restore`. Two harnesses lift functions out of the
script by AST, the same way `tests/Test-PyRevitFences.ps1` does:
- an unelevated one: pure functions, CLI guards and scratch HKCU keys;
- an elevated one: a scratch replica of the locked `Render` tree.

**Tech Stack:** Windows PowerShell 5.1 (pwsh 7 must also run the census), C# via `Add-Type`
(advapi32, ntdll, cfgmgr32), `reg.exe`, `pnputil.exe`, cmd.exe for the launcher.

**Spec:** `docs/superpowers/specs/2026-10-05-audio-device-cleaner-design.md`. Read it first; this plan
argues from it and does not repeat its reasoning.

## Global Constraints

### Code and files

- **Host.** The script starts `#Requires -Version 5.1`, then `$ErrorActionPreference = 'Stop'`, then
  `Set-StrictMode -Version Latest`. Harnesses use `Set-StrictMode -Version Latest`.
- **Source text.** ASCII only, no BOM. Windows PowerShell 5.1 reads a BOM-less file as ANSI. Check:
  `python -c "import sys;b=open(sys.argv[1],'rb').read();print(sum(1 for c in b if c>127))" <file>`
  must print `0`.
- **Line endings.** New `.ps1`, `.cmd` and test files are **CRLF**. Edits keep each file's own
  endings: `README.md` is LF; `docs/LESSONS_LEARNED.md` and `hub/catalog.json` are CRLF. The Write
  tool writes LF, so convert new files afterwards and measure:
  `python -c "import sys;b=open(sys.argv[1],'rb').read();c=b.count(b'\r\n');print(c,b.count(b'\n')-c)" <file>`.
  A CRLF file prints `<n> 0`. Never test line endings with `grep $'\r'`, which is wrong in both
  directions.
- **Comments.** A comment states the engineering fact and its consequence for the next reader.
  Never a date, a round number, a defect id or a model name.
- **Git.** Never run `git add` or `git commit`; the user handles git. Each task ends with a
  hand-off line listing the files changed.

### Safety

- **Real keys are off-limits** before Task 9's user gate. Do not touch the real `MMDevices` keys or
  the real `PropertyStore`, and do not stop the audio services. Tests use only
  `HKLM\SOFTWARE\IczAudioMechanismTest` (elevated) and `HKCU\Software\IczAudioTest` (unelevated).
  Both are removed in `finally`.

### Contracts from the spec

- **Exit codes:**

  | Code | Meaning |
  |---|---|
  | `0` | success |
  | `3010` | success, reboot needed |
  | `2` | nothing to do |
  | `3` | partial |
  | `1` | aborted |

- **Defaults.** Default log: `%TEMP%\AudioDevices_<yyyyMMdd_HHmmss>.log`. Default backup folder:
  `%TEMP%\AudioDevices_<same stamp>\`.
- **Fixed constants:**

  | Constant | Value |
  |---|---|
  | Internal ContainerID | `{00000000-0000-0000-ffff-ffffffffffff}` (compare ignoring case) |
  | `KSCATEGORY_AUDIO` | `{6994ad04-93ef-11d0-a3cc-00a0c9223196}` |
  | Fixed buses | `HDAUDIO`, `INTELAUDIO`, `PCI`, `ACPI` |
  | Removable buses | `USB`, `BTHENUM`, `BTHHFENUM`, `BTHLEDEVICE`, `ROOT`, `SW`, `SWD` |

  Endpoint value names:

  | Field | Value name |
  |---|---|
  | parent | `{b3f8fa53-0004-438e-9003-51a46e139bfc},2` |
  | interface name | `{b3f8fa53-0004-438e-9003-51a46e139bfc},6` |
  | endpoint name | `{a45c254e-df1c-4efd-8020-67d146a850e0},2` |
  | topology ref | `{b3f8fa53-0004-438e-9003-51a46e139bfc},11` |
  | wave ref | `{233164c8-1b2c-4c7d-bc68-b671687a2567},1` |
  | filter list | `{9dad2fed-2266-4b18-a759-47e7816c60bf},0` |
  | SWD id | `{9c119480-ddc2-4954-a150-5bd240d454ad},2` |

### Running the tests and workers

- **Run unelevated tests** with
  `powershell.exe -NoProfile -ExecutionPolicy Bypass -File <test>.ps1`.
- **Run elevated tests** with this recipe. **Tell the user a UAC prompt is coming before every
  use.**
  ```powershell
  $log = Join-Path $env:TEMP ("icz-elevated_{0:yyyyMMdd_HHmmss}.txt" -f (Get-Date))
  $cmd = "& '<full path to .ps1>' <args> *> '$log'; exit `$LASTEXITCODE"
  $p = Start-Process powershell.exe -Verb RunAs -Wait -PassThru -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-Command',$cmd
  "exit=$($p.ExitCode)"; Get-Content -LiteralPath $log
  ```
- **Workers** if subagent-driven: implementers are `icz-builder` (claude-sonnet-4-6); reviewers are
  `icz-ps-reviewer` (claude-opus-4-6).

## Review Focus

Five conditions the spec implies that a person is likely to hit. Each gets a test in the task named.

1. **A device reconnects between census and deletion**, for example Bluetooth earbuds turned on
   mid-run. The fresh re-read must skip that endpoint, never delete it. *(Task 6)*
2. **The script is started from 32-bit PowerShell** (`SysWOW64`), where `HKLM\SOFTWARE` is
   redirected. It must refuse with exit `1`, not operate on the wrong view. *(Task 2)*
3. **Paths with spaces and apostrophes** (`C:\Users\O'Brien\My Backups`) in `-BackupPath`,
   `-LogPath`, `-Restore` and the script path. They must survive the elevation relay and
   `reg save`. *(Tasks 2 and 5)*
4. **The per-app hive is not loaded**: `TargetSid` belongs to a user who has signed out. Pruning is
   skipped with a WARN; it never throws and never ends the run. *(Task 6)*
5. **The census is run from pwsh 7 instead of 5.1.** Same counts, no StrictMode or `Add-Type`
   failure. *(Task 4)*

---

## File map

| File | Responsibility |
|---|---|
| `scripts/windows/Clean-AudioDevices.ps1` (new, CRLF) | The whole tool: help, params, prologue, native layer, gatherers, pure functions, actors, `Invoke-AudioClean`, `Invoke-AudioRestore`, main dispatch |
| `scripts/windows/Clean-AudioDevices.cmd` (new, CRLF) | Menu launcher + passthrough |
| `tests/Test-AudioEndpointClassifier.ps1` (new, CRLF) | Unelevated: pure functions, CLI child-process guards, HKCU scratch round-trips; `-ExpectDefective` |
| `tests/Test-AudioRegistryMechanism.ps1` (new, CRLF) | Elevated: replica of the locked `Render` tree; delete, hive save/restore, guards, backup; `-ExpectDefective`, `-CleanupOnly` |
| `hub/catalog.json` (edit, CRLF) | One entry |
| `README.md` (edit, LF) | Table row, layout line, quick-reference rows, exit-code line, script section |
| `docs/LESSONS_LEARNED.md` (edit, CRLF) | Section E8, checklist rows 31–35 |

Function order inside the script: help → param → prologue helpers (Task 2) → native (Task 3) →
pure (Tasks 1, 6) → gatherers (Task 4) → actors (Tasks 5–7) → main. Main is the only code outside
functions, so the AST lift never runs it.

## Shared record shapes (defined in Task 1, used everywhere)

```
EndpointRecord  [pscustomobject] Flow ('Render'|'Capture'), Guid ('{...}' as in the registry),
                KeyPath ('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\<Flow>\<Guid>'),
                State ([uint32] or $null), Name, InterfaceName, ParentId (no '{1}.' prefix, or $null),
                ParentExists ([bool]), ParentBus (upper-case first segment, or $null),
                ParentContainerId (string or $null), InterfaceRefs ([string[]], lower-case
                '\\?\...' with '{n}.' prefix and '/...' suffix stripped, unique), SwdId (string or $null)
AppSettingRecord [pscustomobject] Name, Value (string or $null), ValueCount ([int]), SubKeyCount ([int]),
                Bus (lower-case or $null), HardwareId (lower-case or $null)
Verdict         [pscustomobject] Action ('Keep'|'Remove'), Label (string), Reason (string)
Context         [pscustomobject] Enabled ([HashSet[string]] OrdinalIgnoreCase, or $null = unknown),
                LiveRefs ([HashSet[string]] OrdinalIgnoreCase)
```

Endpoint labels:
- **Keep:** `live`, `removable-not-connected`, `external-not-connected`, `unknown-bus`, `malformed`.
- **Remove:** `orphaned`, `interface-gone`, `duplicate`, `no-interface-recorded`,
  `port-still-exposed`, `unknown`.

Per-app labels:
- **Keep:** `hardware-present`, `not-fixed-bus`, `unparseable`, `unexpected-shape`.
- **Remove:** `hardware-gone`.

---

### Task 1: Classifier core and the unelevated harness

**Files:**
- Create: `scripts/windows/Clean-AudioDevices.ps1` (comment-based help with every `.PARAMETER`
  from spec §2, the full `param()` block from spec §2, and this task's functions). Main is for now
  a single line that writes `census not implemented` and does `exit 1`; Task 4 replaces it.
- Create: `tests/Test-AudioEndpointClassifier.ps1`

**Interfaces:**
- Produces:
  - `Get-Prop -Obj <object> -Name <string>` → value or `$null` (copy `scripts/autodesk/Uninstall-Revit.ps1:358-368`)
  - `Get-AudioBusClass -Bus <string>` → `'Fixed'|'Removable'|'Unknown'`
  - `New-AudioClassifierContext -Records <object[]> -EnabledInterfaces <string[]>` → Context. `$null` interfaces give Enabled = `$null`; LiveRefs = refs of records whose `State -band 0xF` is 1, 2 or 8.
  - `Get-AudioEndpointVerdict -Record <object> -Context <object>` → Verdict
  - `Test-AudioRemovalSelected -Verdict <object> [-KeepExposedPorts]` → `[bool]`
  - `Test-AudioEndpointKeyPath -Path <string>` → `[bool]`
  - `ConvertFrom-AppAudioDevicePath -Value <string>` → `[pscustomobject]@{Bus;HardwareId}` (lower-case) or `$null`
  - `Get-AppAudioSettingVerdict -Record <object> -PresentPrefixes <HashSet[string]>` → Verdict

- [ ] **Step 1: Write the harness and its failing assertions.**
  - **Shape.** Same as `tests/Test-PyRevitFences.ps1`: `-ScriptPath` (default
    `..\scripts\windows\Clean-AudioDevices.ps1`), `-ExpectDefective`, `Assert`, functions lifted
    from `$ast.EndBlock.Statements` by AST, then `RESULT: n passed, m failed`, exit 1 if any
    failed.
  - **Factory.** `New-Rec` returns an EndpointRecord with these defaults:
    `Flow='Render'`, `Guid='{00000000-0000-0000-0000-000000000001}'`, `State=4`, `ParentId='HDAUDIO\FUNC_01&VEN_10EC\5&0&0001'`,
    `ParentExists=$true`, `ParentBus='HDAUDIO'`, `ParentContainerId='{00000000-0000-0000-FFFF-FFFFFFFFFFFF}'`, `InterfaceRefs=@()`.
    It overrides from a hashtable.
  - **Fixture refs:** `$E='\\?\hdaudio#a#{6994ad04-93ef-11d0-a3cc-00a0c9223196}\topo00'`, `$L='...\topo01'`,
    `$G='...\topo09'`.
  - **Contexts:** `$ctx` = enabled `$E,$L`, plus one live record holding `$L`; `$ctxUnknown` = enabled `$null`.

  ```powershell
  # state
  foreach ($s in 1,2,8,0x10000001,0x10000008) { Assert ((V (New-Rec @{State=$s})).Label -eq 'live') "state 0x$('{0:X}' -f $s) -> Keep live" }
  foreach ($s in $null,0,3,0x10) { Assert ((V (New-Rec @{State=$s})).Label -eq 'malformed') "state $s -> Keep malformed" }
  Assert ((Get-AudioEndpointVerdict -Record $null -Context $ctx).Label -eq 'malformed') 'null record -> Keep malformed'
  # parent
  Assert ((V (New-Rec @{ParentId=$null})).Label -eq 'malformed') 'no parent link -> Keep malformed'
  Assert ((V (New-Rec @{ParentExists=$false; ParentBus='USB'})).Label -eq 'orphaned') 'parent gone (even USB) -> Remove orphaned'
  Assert ((V (New-Rec @{ParentExists=$false}) $ctxUnknown).Label -eq 'orphaned') 'orphaned survives unknown interfaces'
  foreach ($b in 'USB','BTHENUM','BTHHFENUM','BTHLEDEVICE','ROOT','SW','SWD','root') { Assert ((V (New-Rec @{ParentBus=$b})).Label -eq 'removable-not-connected') "$b parent exists -> Keep" }
  foreach ($b in 'FOO',$null) { Assert ((V (New-Rec @{ParentBus=$b})).Label -eq 'unknown-bus') "bus '$b' -> Keep unknown-bus" }
  foreach ($c in '{8A2E1D3C-0000-4000-8000-000000000000}',$null) { Assert ((V (New-Rec @{ParentContainerId=$c})).Label -eq 'external-not-connected') "container '$c' -> Keep external" }
  # labels on fixed + internal
  Assert ((V (New-Rec @{InterfaceRefs=@()})).Label -eq 'no-interface-recorded') 'no refs'
  Assert ((V (New-Rec @{InterfaceRefs=@($E)})).Label -eq 'port-still-exposed') 'enabled, unheld -> exposed'
  Assert ((V (New-Rec @{InterfaceRefs=@($L)})).Label -eq 'duplicate') 'enabled, held by live -> duplicate'
  Assert ((V (New-Rec @{InterfaceRefs=@($G)})).Label -eq 'interface-gone') 'not enabled, unheld -> gone'
  Assert ((V (New-Rec @{InterfaceRefs=@($E.ToUpper())})).Label -eq 'port-still-exposed') 'ref compare ignores case'
  Assert ((V (New-Rec @{InterfaceRefs=@($E)}) $ctxUnknown).Label -eq 'unknown') 'unknown interfaces -> Remove unknown'
  Assert ((V (New-Rec @{InterfaceRefs=@($G)})).Action -eq 'Remove') 'every fixed/internal NotPresent label is Remove'
  # selection
  Assert (-not (Test-AudioRemovalSelected (Vd Remove port-still-exposed) -KeepExposedPorts)) 'exposed kept with -KeepExposedPorts'
  Assert (-not (Test-AudioRemovalSelected (Vd Remove unknown) -KeepExposedPorts)) 'unknown kept with -KeepExposedPorts'
  Assert (Test-AudioRemovalSelected (Vd Remove duplicate) -KeepExposedPorts) 'duplicate still selected'
  Assert (Test-AudioRemovalSelected (Vd Remove port-still-exposed)) 'exposed selected by default'
  Assert (-not (Test-AudioRemovalSelected (Vd Keep live))) 'Keep never selected'
  ```
  Here `V` wraps `Get-AudioEndpointVerdict -Record $r -Context ($c ?? $ctx)`, written with
  `if` for 5.1, and `Vd` builds a Verdict.

  Path guard. Valid paths must be accepted:
  `HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\Render\{e12c921b-73dd-465e-92fd-9994fdd194b6}`
  and the same under `Capture`. These must be refused:
  - `…\Audio\Render`
  - `…\Audio`
  - `…\Render\{guid}\Properties`
  - `…\Render\{guid}\`
  - `…\Render\e12c921b-73dd-465e-92fd-9994fdd194b6`
  - `HKLM:\SOFTWARE\IczAudioMechanismTest\Render\{guid}`
  - `HKCU:\…\Render\{guid}`
  - `$null`
  - `''`

  Per-app:
  ```powershell
  $v = '{2}.\\?\hdaudio#func_01&ven_10de&dev_009d&subsys_10431adc&rev_1001#{6994ad04-93ef-11d0-a3cc-00a0c9223196}\topo01/00010001|#%b{A9EF3FD9-4240-455E-A4D5-F2B3301887B2}'
  $p = ConvertFrom-AppAudioDevicePath $v
  Assert ($p.Bus -eq 'hdaudio' -and $p.HardwareId -eq 'func_01&ven_10de&dev_009d&subsys_10431adc&rev_1001') 'parses bus + hardware id'
  foreach ($bad in $null,'','garbage','{2}.SWD\x') { Assert ($null -eq (ConvertFrom-AppAudioDevicePath $bad)) "unparseable '$bad' -> null" }
  $present = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase); [void]$present.Add('HDAUDIO\FUNC_01&VEN_10EC&DEV_0897&SUBSYS_1458A194&REV_1005')
  # A: hdaudio ven_10ec (present) -> Keep hardware-present;  B: hdaudio ven_10de (absent) -> Remove hardware-gone
  # C: intelaudio absent -> Remove;  D: usb#vid_2207&pid_a007&mi_02 -> Keep not-fixed-bus;  E: bthenum -> Keep not-fixed-bus
  # F: ValueCount 2 -> Keep unexpected-shape;  G: SubKeyCount 1 -> Keep unexpected-shape;  H: Value 'garbage' -> Keep unparseable
  ```
  The harness builds each of records A–H through `New-AppRec` and asserts the label shown in the
  comment beside it.

- [ ] **Step 2: Run it. It must fail.**
  Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\Test-AudioEndpointClassifier.ps1`
  Expected: exit 1, with assertions failing because the functions don't exist yet.

- [ ] **Step 3: Implement the eight functions in `Clean-AudioDevices.ps1`.**
  `Get-AudioEndpointVerdict` decides in exactly this order, and the first match returns:
  1. null record, null State, or `State -band 0xF` not in {1,2,4,8} → Keep `malformed`
  2. low nibble in {1,2,8} → Keep `live`
  3. ParentId empty → Keep `malformed`
  4. `-not ParentExists` → Remove `orphaned`
  5. bus class Removable → Keep `removable-not-connected`
  6. bus class not Fixed → Keep `unknown-bus`
  7. ContainerId not equal to the internal id (ignoring case; null included) → Keep `external-not-connected`
  8. `Context.Enabled -eq $null` → Remove `unknown`
  9. no refs → Remove `no-interface-recorded`
  10. any ref in Enabled and not in LiveRefs → Remove `port-still-exposed`
  11. any ref in LiveRefs → Remove `duplicate`
  12. otherwise → Remove `interface-gone`

  Further details:
  - `Reason` is a short English sentence naming the fact, e.g. `parent HDAUDIO\... no longer exists`.
  - `ConvertFrom-AppAudioDevicePath` uses
    `'^\{\d+\}\.\\\\\?\\(?<bus>[^#\\]+)#(?<hwid>[^#\\]+)#'`. A null or empty value returns `$null`
    **before** any `-match`.
  - No pure function reads a script-scope variable. Constants live inside the functions.

- [ ] **Step 4: Run it. It must pass.**
  Same command. Expected: exit 0, `RESULT: <n> passed, 0 failed`.

- [ ] **Step 5: Add `-ExpectDefective` and show it fails.**
  After lifting, the harness redefines `Get-AudioEndpointVerdict` as "`State -band 0xF` equals 4 →
  Remove `defective`, else Keep `live`".
  Run: `… -File tests\Test-AudioEndpointClassifier.ps1 -ExpectDefective`
  Expected: exit 1, with `[FAIL]` lines on the removable-bus, unknown-bus, external and malformed
  cases.

- [ ] **Step 6: Convert both files to CRLF and verify.** Run the ASCII and line-ending one-liners
  on both files. Expected: `0` non-ASCII bytes; `<n> 0` for line endings.

- [ ] **Step 7: Hand off.** Tell the user the two new files are ready to review. Do not commit.

---

### Task 2: CLI prologue — guards, path rooting, elevation relay, transcript

**Files:**
- Modify: `scripts/windows/Clean-AudioDevices.ps1` (prologue helpers plus the main-level prologue
  before dispatch)
- Modify: `tests/Test-AudioEndpointClassifier.ps1` (sections "CLI pure" and "CLI child process")

**Interfaces:**
- Consumes: the `param()` block from Task 1.
- Produces:
  - `Get-AudioCleanerModeError -Clean <bool> -Restore <string> -ListOnly <bool> -KeepExposedPorts <bool> -SkipAppSettings <bool>` → error message `[string]` or `$null`
  - `ConvertTo-PsSingleQuoted -Text <string>` → `'...'` with `'` doubled
  - `Get-AudioRelayArguments -Bound <hashtable> -WhatIfRequested <bool> -VerboseRequested <bool>` → `[string[]]`
  - `New-AudioElevationCommand -ScriptPath <string> -RelayArguments <string[]>` → `"& '<path>' <args>; exit `$LASTEXITCODE"`
  - `Test-WhatIfRelayed -Command <string> -WhatIfRequested <bool>` → `[bool]` (true when not requested, or when it matches `(?i)(?<=\s)-WhatIf(?=\s|;|")`)
  - `Test-IsAdministrator` → `[bool]`

- [ ] **Step 1: Write the failing assertions.**
  ```powershell
  Assert ((Get-AudioCleanerModeError -Clean $true -Restore 'x' -ListOnly $false -KeepExposedPorts $false -SkipAppSettings $false) -match 'together') '-Clean + -Restore refused'
  Assert ((Get-AudioCleanerModeError -Clean $true -Restore '' -ListOnly $true -KeepExposedPorts $false -SkipAppSettings $false)) '-ListOnly + -Clean refused'
  Assert ((Get-AudioCleanerModeError -Clean $false -Restore '' -ListOnly $false -KeepExposedPorts $true -SkipAppSettings $false) -match '-Clean') '-KeepExposedPorts alone refused'
  Assert ((Get-AudioCleanerModeError -Clean $false -Restore '' -ListOnly $false -KeepExposedPorts $false -SkipAppSettings $true) -match '-Clean') '-SkipAppSettings alone refused'
  Assert ($null -eq (Get-AudioCleanerModeError -Clean $true -Restore '' -ListOnly $false -KeepExposedPorts $true -SkipAppSettings $true)) 'valid combination'
  $sp = "C:\Users\O'Brien\My Scripts\Clean-AudioDevices.ps1"
  $args1 = Get-AudioRelayArguments -Bound @{Clean=$true; BackupPath="C:\Users\O'Brien\My Backups"; TargetSid='S-1-5-21-1'; Confirm=$false} -WhatIfRequested $true -VerboseRequested $false
  $cmd = New-AudioElevationCommand -ScriptPath $sp -RelayArguments $args1
  Assert ($cmd.StartsWith("& 'C:\Users\O''Brien\My Scripts\Clean-AudioDevices.ps1' ")) 'script path single-quoted, apostrophe doubled'
  Assert ($cmd.EndsWith('; exit $LASTEXITCODE')) 'ends with ; exit $LASTEXITCODE'
  Assert ($cmd -like "*-BackupPath 'C:\Users\O''Brien\My Backups'*") 'backup path relayed and quoted'
  Assert ($cmd -like '*-Confirm:$false*') '-Confirm:$false relayed'
  Assert (Test-WhatIfRelayed -Command $cmd -WhatIfRequested $true) '-WhatIf present when requested'
  Assert (-not (Test-WhatIfRelayed -Command ($cmd -replace ' -WhatIf','') -WhatIfRequested $true)) 'missing -WhatIf detected'
  ```
  **Child process.** Each case starts Windows PowerShell 5.1 with `-File` on the script, gets 60 s
  before it is killed, and asserts **both** the exit code **and** a message. The message check
  matters: a declined UAC prompt also exits 1.

  | Arguments | Exit | Message contains |
  |---|---|---|
  | `-Clean -Restore x.json` | 1 | `together` |
  | `-ListOnly -Clean` | 1 | `-ListOnly` |
  | `-KeepExposedPorts` | 1 | `-Clean` |
  | `-Restore .\no-such-manifest.json` | 1 | `not found` |
  | `C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe … -ListOnly` (Review Focus 2) | 1 | `64-bit` |

- [ ] **Step 2: Run it. It must fail.** Expected: exit 1, with these assertions failing.

- [ ] **Step 3: Implement.** The prologue runs after `param()`, in spec §2 order:
  1. `$ConfirmPreference = 'None'` when `-Force`.
  2. The 64-bit guard: `[Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess`
     → message `Run the 64-bit Windows PowerShell; 32-bit PowerShell sees a redirected HKLM\SOFTWARE.`
     and exit 1.
  3. The mode guard → message and exit 1.
  4. Path rooting: one stamp shared by the log and backup defaults; pattern
     `scripts/windows/Remove-WindowsBloat.ps1:207-239`.
  5. `$TargetSid` default.
  6. `$ListOnly = $true` when neither `-Clean` nor `-Restore` is given.
  7. Self-elevation for `-Clean`/`-Restore` when `-not (Test-IsAdministrator)`. Build the command
     with the functions above, refuse when `Test-WhatIfRelayed` is false, and run
     `Start-Process … -Verb RunAs -Wait -PassThru`. Exit with the child's code, or 1 if the launch
     was cancelled (pattern `Remove-WindowsBloat.ps1:255-314`).
  8. `Start-Transcript -Path $LogPath -Append -WhatIf:$false`.

  `Get-AudioRelayArguments` relays:
  - the switches `Clean`, `KeepExposedPorts`, `SkipAppSettings`, `CreateRestorePoint` and `Force`;
  - the strings `Restore`, `LogPath`, `BackupPath` and `TargetSid`, each through
    `ConvertTo-PsSingleQuoted`;
  - `Confirm` as `-Confirm:$true|$false`, but only when bound;
  - `-WhatIf` and `-Verbose`, from their arguments.

- [ ] **Step 4: Run it. It must pass, and the Task 1 assertions must still pass.**

- [ ] **Step 5: Check encoding and line endings again, then hand off.**

---

### Task 3: Native layer and the elevated replica harness

**Files:**
- Modify: `scripts/windows/Clean-AudioDevices.ps1` (native section)
- Create: `tests/Test-AudioRegistryMechanism.ps1`

**Interfaces:**
- Produces:
  - `Initialize-IczAudioNative`: runs `Add-Type` once, guarded by `-not ('IczAudioNative' -as [type])`.
  - `Enable-AudioPrivileges` → `[bool]`: true only if **both** `SeBackupPrivilege` and `SeRestorePrivilege` were assigned.
  - `Test-AudioMechanismRoot -SubKey <string>` → `[bool]`. Accepts `^SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\MMDevices\\Audio\\(Render|Capture)\\\{[0-9a-fA-F-]{36}\}$` or `^SOFTWARE\\IczAudioMechanismTest(\\.+)?$`; refuses everything else.
  - `Remove-RegistryTreeBackupSemantics -SubKey <string>` → `@{Ok=[bool];Code=[int];Message=[string]}`. Guard `Test-AudioMechanismRoot` **inside**; it enables privileges itself.
  - `Save-AudioRegistryHive -SubKey <string> -File <string>` → `[bool]`. Runs `reg.exe save "HKLM\<SubKey>" "<File>" /y`; requires exit 0 and file length > 0.
  - `Restore-AudioRegistryHive -SubKey <string> -File <string>` → `@{Ok;Message}`. Guard inside; refuses (`Ok=$false`, message contains `exists`) if the key exists; otherwise `CreateKeyBackupSemantics`, then `reg.exe restore "HKLM\<SubKey>" "<File>"`, then checks the key exists.
  - `Get-EnabledAudioInterface` → `[string[]]` lower-case, or `$null` on failure.
- The C# class `IczAudioNative` exposes exactly:
  ```csharp
  public static bool EnablePrivilege(string name);                 // AdjustTokenPrivileges; false when GetLastWin32Error()==1300 (ERROR_NOT_ALL_ASSIGNED)
  public static int  DeleteTreeBackupSemantics(string hklmSubKey); // 0 = deleted; else Win32 error or NTSTATUS
  public static int  CreateKeyBackupSemantics(string hklmSubKey);  // 0 = created; parent must exist
  public static string[] GetPresentInterfaces(Guid category);      // null when CONFIGRET != 0
  ```
  Constants: HKLM = `new UIntPtr(0x80000002u)`; `REG_OPTION_BACKUP_RESTORE = 0x4` (samDesired is
  ignored with it); `CM_GET_DEVICE_INTERFACE_LIST_PRESENT = 0x0`.
  `DeleteTreeBackupSemantics` works like this:
  1. Open the key with `RegOpenKeyExW(HKLM, sub, REG_OPTION_BACKUP_RESTORE, 0, out h)`.
  2. Collect child names with `RegEnumKeyExW`.
  3. Recurse into each child path.
  4. Call `NtDeleteKey(h)` from ntdll; STATUS_SUCCESS is 0.
  5. Close the handle with `RegCloseKey`.

  `GetPresentInterfaces` calls `CM_Get_Device_Interface_List_SizeW`, then
  `CM_Get_Device_Interface_ListW`, and splits the multi-string.

- [ ] **Step 1: Write the harness.**
  - It exits 2 with `run elevated` when not elevated.
  - It takes `-ScriptPath`, `-ExpectDefective` and `-CleanupOnly`.
  - It lifts functions by AST.
  - **Fixture:**
    - **Tree.** Create `HKLM\SOFTWARE\IczAudioMechanismTest\Render\{11111111-2222-3333-4444-555555555555}`.
      Under it, `Properties` gets `{a45c254e-df1c-4efd-8020-67d146a850e0},2`=REG_SZ `Speakers`,
      `t_dword`=REG_DWORD 4, `t_bin`=REG_BINARY 8 bytes and `t_multi`=REG_MULTI_SZ `a`,`b`;
      `FxProperties` gets `t_fx`=REG_BINARY 16 bytes.
    - **Owner.** With `Enable-AudioPrivileges`, set owner SYSTEM on the GUID key, `Properties` and
      `FxProperties`.
    - **DACL.** Set the replica `Render` DACL to the **real** `MMDevices\Audio\Render` key's ACEs,
      copied as explicit ACEs with their inheritance flags and protected
      (`SetAccessRuleProtection($true,$false)`). The children then inherit them.
  - **Assertions:**
    1. Fixture sanity: the BUILTIN\Administrators ACE on the replica GUID key has no `Delete` right.
    2. `Remove-Item -LiteralPath HKLM:\SOFTWARE\IczAudioMechanismTest\Render\{1111…} -Recurse` throws, so the replica is locked.
    3. Snapshot `(Get-Acl).Sddl` of the GUID key, `Properties`, `FxProperties` and the replica `Render`, plus `reg export` of the GUID key to `A.reg`.
    4. `Save-AudioRegistryHive` returns `$true` and the file is non-empty.
    5. `Remove-RegistryTreeBackupSemantics` returns `Ok`; the GUID key is gone; the replica `Render` SDDL equals its snapshot.
    6. `Restore-AudioRegistryHive` returns `Ok`; `reg export` gives `B.reg` byte-identical to `A.reg`; the SDDL of the GUID key, `Properties` and `FxProperties` equals the snapshot.
    7. A second `Restore-AudioRegistryHive` returns `Ok=$false` with `exists`.
    8. `Remove-RegistryTreeBackupSemantics -SubKey 'SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\Render'` and `-SubKey 'SOFTWARE\Microsoft'` both return `Ok=$false`, and both keys still exist.
  - **`finally`:** `Remove-RegistryTreeBackupSemantics -SubKey 'SOFTWARE\IczAudioMechanismTest'`.
    If that fails, print the path and `rerun with -CleanupOnly`.
  - **`-ExpectDefective`** replaces assertion 6's restore with `reg.exe import A.reg`.

- [ ] **Step 2: Run it elevated (tell the user UAC is coming). It must fail.**
  Expected: exit 1 with failures, because the native functions don't exist yet.

- [ ] **Step 3: Implement the native section and the five PowerShell wrappers.**

- [ ] **Step 4: Run it elevated. It must pass.** Expected: exit 0, `0 failed`, and the scratch
  tree gone (`Test-Path HKLM:\SOFTWARE\IczAudioMechanismTest` is false).
  **If assertion 5 or 6 fails, stop.** Report it to the user and do not improvise. The fallback
  (take ownership per key, non-inheritable ACE) needs a spec change first.

- [ ] **Step 5: Run it elevated with `-ExpectDefective`. It must fail.** Expected: exit 1, with
  assertion 6 failing because the import is denied or the SDDL differs.

- [ ] **Step 6: Check encoding and line endings, then hand off.**

---

### Task 4: Gatherers and the census (`-ListOnly`, the default)

**Files:**
- Modify: `scripts/windows/Clean-AudioDevices.ps1` (gatherers, `Get-AudioCensus`, `Write-AudioCensus`; main dispatch for `-ListOnly`)
- Modify: `tests/Test-AudioEndpointClassifier.ps1` (one live, read-only section)

**Interfaces:**
- Consumes: Task 1 functions, `Get-EnabledAudioInterface` (Task 3).
- Produces:
  - `Get-AudioEndpointRecord [-Flow <string> -Guid <string>]` → EndpointRecord[]. With no
    arguments it reads every endpoint; with both it reads one key, or returns `$null` if the key
    is gone. Values are read through `(Get-Item).GetValue()` on the `Properties` key; `State`
    comes through `Get-Prop`. `ParentExists` is `Test-Path "HKLM:\SYSTEM\CurrentControlSet\Enum\<ParentId>"`;
    `ParentContainerId` is `Get-Prop (Get-ItemProperty <that>) 'ContainerID'`.
  - `Get-PresentDevicePrefixSet` → `HashSet[string]` (OrdinalIgnoreCase) of the first two
    segments of each `Get-PnpDevice -PresentOnly` instance id.
  - `Get-AppAudioSettingRecord -TargetSid <string>` → AppSettingRecord[], from `Registry::HKEY_USERS\<sid>\Software\Microsoft\Internet Explorer\LowRegistry\Audio\PolicyConfig\PropertyStore`. If the hive is missing it returns `@()` and writes a WARN.
  - `Get-AudioCensus -TargetSid <string> [-KeepExposedPorts] [-SkipAppSettings]` →
    `[pscustomobject]@{ Context; Endpoints = @({Record;Verdict;Selected}); AppSettings = @({Record;Verdict}); PresentPrefixes }`
  - `Write-AudioCensus -Census <object>`: KEEP and REMOVE counts per label, one line per endpoint
    (`Flow  Label  Name (InterfaceName)`), per-app counts per label, a note on how many entries
    are `port-still-exposed` ("Windows will likely rebuild these"), and the out-of-scope pointer
    to `Remove-LegacyHardwareResidue.ps1 -Scope Platform,Audio`.
- Main: `-ListOnly` runs the census, writes it, and exits 0.

- [ ] **Step 1: Write the failing live assertions.** Section `live census (read-only)`:
  - `Get-EnabledAudioInterface`, as a set, equals the lower-cased `Interface Path:` lines of
    `pnputil /enum-interfaces /class {6994ad04-93ef-11d0-a3cc-00a0c9223196} /enabled`.
  - On this machine, the endpoint Remove counts per label are exactly
    `orphaned 6, interface-gone 11, duplicate 3, no-interface-recorded 15, port-still-exposed 7`,
    and Keep `live` is 20.
  - Every per-app Remove has Bus `hdaudio` or `intelaudio`, and no Remove has `usb` or `bthenum`.
  - These counts belong to this machine. Make the section skip, with a printed note, when
    `$env:COMPUTERNAME` is not the one recorded in the harness.

- [ ] **Step 2: Run it. It must fail.**

- [ ] **Step 3: Implement the gatherers, `Get-AudioCensus`, `Write-AudioCensus` and the `-ListOnly` dispatch.**

- [ ] **Step 4: Run the harness (it must pass), then run the census itself.**
  - `powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\windows\Clean-AudioDevices.ps1`:
    exit 0, no UAC prompt, the table shows the counts above, and the transcript file exists.
  - **Review Focus 5:** run the same census with `"C:\Program Files\PowerShell\7\pwsh.exe" -NoProfile -File …`.
    Expected: exit 0 and identical counts.

- [ ] **Step 5: Check encoding and line endings, then hand off.**

---

### Task 5: Backup and manifest

**Files:**
- Modify: `scripts/windows/Clean-AudioDevices.ps1`
- Modify: both harnesses

**Interfaces:**
- Consumes: `Save-AudioRegistryHive` (Task 3); the records from Task 4.
- Produces:
  - `ConvertTo-RegSzLiteral -Text <string>` → the text with `\` written as `\\` and `"` as `\"`.
  - `Export-AppAudioSettingReg -Records <object[]> -RootKey <string> -Path <string>`: writes
    UTF-16LE with a BOM (as `reg export` does): the header `Windows Registry Editor Version 5.00`,
    then per record `[<RootKey>\<Name>]` and `@="<literal>"`, then a blank line.
  - `Backup-AudioTargets -Endpoints <object[]> -AppSettings <object[]> -Folder <string> -TargetSid <string> -AppRootKey <string>` → the manifest object, also written to `manifest.json` as UTF-8. It honours `-WhatIf` by writing nothing and returning the would-be manifest.
  - `Test-AudioBackup -Folder <string> -Manifest <object>` → `[string[]]` problems; empty means OK.
- Manifest (`Version = 1`):
  - `Script = 'Clean-AudioDevices.ps1'`, `Computer`, `TargetSid`, `Created` (ISO 8601).
  - `Endpoints = @({Flow; Guid; SubKey; Name; InterfaceName; ParentId; Label; Hive = 'endpoints\<Flow>_<Guid>.hiv'; Reg = 'endpoints\<Flow>_<Guid>.reg'})`.
  - `AppSettings = @{ RootKey; File = 'appsettings.reg'; Entries = @({Name; Value}) }`.
  - `Devnodes = @(<SwdId of each endpoint that has one>)`.
  - Every path is relative to the folder.
- `Test-AudioBackup` checks that:
  - every file exists and is non-empty;
  - each `.reg` starts with the header and contains `[HKEY_LOCAL_MACHINE\<SubKey>]`;
  - `appsettings.reg` contains one `@=` line per entry;
  - `manifest.json` re-parses with the same counts.

- [ ] **Step 1: Write the failing assertions.**
  - **Unelevated harness:**
    - `ConvertTo-RegSzLiteral 'a\b"c'` equals `a\\b\"c`.
    - Export two records to `"$env:LOCALAPPDATA\Icz Audio O'Test\app.reg"`. One record's value is
      the long `{2}.\\?\hdaudio#…|#%b{…}` string from Task 1; the other's is `C:\Program Files\x "y".exe`.
      Root key: `HKEY_CURRENT_USER\Software\IczAudioTest\PropertyStore`.
    - `reg.exe import` it; both values read back identical.
    - `finally` removes `HKCU:\Software\IczAudioTest` and the folder.
  - **Elevated harness:**
    - `Backup-AudioTargets`, given the replica endpoint record (KeyPath under `IczAudioMechanismTest`),
      writes to `"$env:TEMP\Icz Audio O'Backup"` (Review Focus 3). `Test-AudioBackup` returns `@()`.
    - Truncate the `.reg` to 10 bytes; `Test-AudioBackup` now reports one problem naming that file.
    - With `-WhatIf`, `Backup-AudioTargets` creates no folder.

- [ ] **Step 2: Run both harnesses. Both must fail on the new assertions.** The elevated run needs a UAC prompt; tell the user first.

- [ ] **Step 3: Implement the four functions.**

- [ ] **Step 4: Run both harnesses. Both must pass, and all earlier assertions must still pass.**

- [ ] **Step 5: Check encoding and line endings, then hand off.**

---

### Task 6: The `-Clean` run

**Files:**
- Modify: `scripts/windows/Clean-AudioDevices.ps1`
- Modify: `tests/Test-AudioEndpointClassifier.ps1`

**Interfaces:**
- Consumes: everything above.
- Produces:
  - **Pure:**
    - `Get-SwdInstanceId -Flow <string> -Guid <string>` → `SWD\MMDEVAPI\{0.0.0.00000000}.<guid>` for Render, `{0.0.1.00000000}` for Capture, `$null` for anything else.
    - `Get-AudioServicesToRestart -Dependents <object[]>` → names whose `Status` was `Running`.
    - `Find-RebuiltAudioEndpoint -Removed <object[]> -BeforeGuids <string[]> -After <object[]>` → records whose GUID is new **and** that share an InterfaceRef with a removed record, or have the same Flow+ParentId+Name.
    - `Get-AudioOutcomeProblems -RemovedGuids <string[]> -Kept <object[]> -After <object[]>` → `[string[]]`: a removed GUID still present; a kept GUID missing; a kept record that was Active and isn't now.
  - **Actors:**
    - `Remove-AudioEndpointKey -Record <object> -Context <object> [-KeepExposedPorts]` → `@{Guid; Result='Removed'|'Skipped'|'Refused'|'Failed'; Reason}`.
      1. If `-not (Test-AudioEndpointKeyPath $Record.KeyPath)`, return `Refused`.
      2. Re-read with `Get-AudioEndpointRecord -Flow -Guid`. If the key is gone, return `Skipped` `already gone`.
      3. Run the verdict on the **fresh** record. If it isn't selected, return `Skipped` with `changed since census: <label>`.
      4. `ShouldProcess`.
      5. `Remove-RegistryTreeBackupSemantics`.
      6. Check the key is gone with `Test-Path`.
    - `Remove-GhostEndpointDevnode -Flow <string> -Guid <string>` → `'Removed'|'NotPresent'|'RebootRequired'|'Failed'`. It acts only when `HKLM:\SYSTEM\CurrentControlSet\Enum\<SwdId>` exists. `pnputil /remove-device "<SwdId>"`: 0 means Removed, 3010 means RebootRequired, anything else means Failed.
    - `Remove-AppAudioSetting -Record <object> -TargetSid <string> -PresentPrefixes <HashSet[string]>` → `'Removed'|'Skipped'|'Failed'`. A root that doesn't exist gives `Skipped`, reason `hive not loaded`. It re-reads the key and re-runs the verdict before `Remove-Item`.
    - `Stop-AudioStack` → `@{Ok; RunningDependents}`.
    - `Start-AudioStack -Dependents <string[]>` → `@{Ok; NotRunning}`. It starts `AudioEndpointBuilder`, then `Audiosrv`, then the dependents. Each is retried 3 times, 2 s apart.
    - `Enter-AudioCriticalWindow` → state, and `Exit-AudioCriticalWindow -State`. Entering sets `[Console]::TreatControlCAsInput` (in a `try`) and registers `Register-EngineEvent PowerShell.Exiting -SourceIdentifier IczAudioRestart`, whose action runs `sc.exe start AudioEndpointBuilder` and then `sc.exe start Audiosrv`. Exiting restores both.
    - `Wait-AudioEndpointSettle` → records, once the endpoint key count has been stable for 3 s (30 s at most).
    - `Invoke-AudioClean -Census <object> -BackupPath <string> -TargetSid <string> [-KeepExposedPorts] [-SkipAppSettings] [-CreateRestorePoint] [-Force]` → `[int]` exit code. It follows the spec §2 step table literally, including every `-WhatIf` cell.
  - **Prompt and summary:**
    - The confirmation is `Read-Host` with `[y/N]`. Its text names the endpoint, devnode and per-app counts, says `About 10 seconds without sound`, and says `apps that were playing (Sonar included) may need restarting`. A decline exits 0 with `Declined. Nothing was changed.`
    - The final summary prints:
      - removed counts by label;
      - **rebuilt by Windows** with names;
      - the AMD hint from spec §2 when any rebuilt record's ParentId starts with `HDAUDIO\FUNC_01&VEN_1002`;
      - the backup folder;
      - the manifest path, for `-Restore`.

- [ ] **Step 1: Write the failing assertions.**
  ```powershell
  Assert ((Get-SwdInstanceId 'Capture' '{dcc07c43-9dfe-4e6a-9411-fe2ae0b9543e}') -eq 'SWD\MMDEVAPI\{0.0.1.00000000}.{dcc07c43-9dfe-4e6a-9411-fe2ae0b9543e}') 'capture SWD id'
  Assert ($null -eq (Get-SwdInstanceId 'Other' '{x}')) 'bad flow -> null'
  Assert (@(Get-AudioServicesToRestart @([pscustomobject]@{Name='Audiosrv';Status='Running'},[pscustomobject]@{Name='midisrv';Status='Stopped'})) -join ',' -eq 'Audiosrv') 'only running dependents'
  # Find-RebuiltAudioEndpoint: removed R(refs $E); before {R,K}; after {K, N1(refs $E)} -> N1; after {K, N2(other refs, other parent)} -> none; N3(no refs, same Flow+ParentId+Name as R) -> N3
  # Get-AudioOutcomeProblems: removed guid still in After -> 1 problem; kept guid missing -> 1 problem; kept State 1 now 8 -> 1 problem; clean -> 0
  ```
  Review Focus 1 and 4, using stubs defined after the lift:
  - `Get-AudioEndpointRecord` returns a fresh record with `State=8`.
  - `Remove-RegistryTreeBackupSemantics` appends to `$script:DeleteCalls`.

  The assertions:
  - `Remove-AudioEndpointKey` gives `Result -eq 'Skipped'` with `Reason -like 'changed since census*'`, and `$script:DeleteCalls.Count -eq 0`.
  - A record whose KeyPath is under `IczAudioMechanismTest` gives `Result -eq 'Refused'`, and the delete stub is not called.
  - `Remove-AppAudioSetting -TargetSid 'S-1-5-21-0-0-0-9999'` gives `Skipped` with `hive not loaded`, and throws nothing.

- [ ] **Step 2: Run it. It must fail.**

- [ ] **Step 3: Implement the functions and the `-Clean` dispatch in main.** If nothing is
  selected, `Invoke-AudioClean` returns 2 before the prompt. The exit code is 3 if any result is
  Failed, any outcome problem exists, or `Start-AudioStack` was not Ok. Otherwise it is 3010 if
  any devnode reported RebootRequired, and 0 otherwise.

- [ ] **Step 4: Run the harness. It must pass.**

- [ ] **Step 5: Live preview, which must change nothing.** Elevated (tell the user UAC is coming):
  1. Before the run, unelevated:
     - save `Flow\Guid=DeviceState` for every endpoint key to `before.txt`;
     - record `(Get-CimInstance Win32_Service -Filter "Name='AudioEndpointBuilder'").ProcessId`.
  2. Run `scripts\windows\Clean-AudioDevices.ps1 -Clean -WhatIf -Force` with the elevated recipe.
  3. After it, check:
     - it exited 0;
     - the output has a `What if` line per selected endpoint (42) and per devnode (3), and the
       per-app `What if` count equals the census's per-app Remove count;
     - the regenerated `after.txt` is byte-identical to `before.txt`;
     - the service PID is unchanged;
     - no `AudioDevices_*` backup folder was created;
     - the transcript file exists.

- [ ] **Step 6: Check encoding and line endings, then hand off.**

---

### Task 7: The `-Restore` run

**Files:**
- Modify: `scripts/windows/Clean-AudioDevices.ps1`
- Modify: `tests/Test-AudioEndpointClassifier.ps1`

**Interfaces:**
- Consumes: `Restore-AudioRegistryHive` (Task 3), the manifest (Task 5), the service and
  critical-window functions (Task 6).
- Produces:
  - `Read-AudioManifest -Path <string>` → manifest, or it throws. Reasons:
    - `from another computer (<name>)`;
    - `unsupported manifest version`;
    - `outside the backup folder: <rel>`, for any relative path that resolves outside the manifest's folder;
    - `missing backup file: <rel>`.
  - `Restore-AppAudioSettings -Entries <object[]> -RootKey <string>` → `@{Restored=[int]; Skipped=[int]}`. It creates only missing keys, writing the default value as REG_SZ.
  - `Invoke-AudioRestore -ManifestPath <string> [-Force]` → `[int]` exit code, following spec §2 "`-Restore`". For endpoints, an `exists` result counts as Skipped, not Failed.

- [ ] **Step 1: Write the failing assertions.** All manifests are crafted under `$env:LOCALAPPDATA\IczAudioManifestTest\`:
  - computer `NOT-THIS-PC` → throws `another computer`;
  - `Hive='..\..\evil.hiv'` → throws `outside the backup folder`;
  - a hive file deleted → throws `missing backup file`;
  - a valid manifest → returns an object whose Endpoints count matches;
  - `Restore-AppAudioSettings`, with two entries and the root `HKCU:\Software\IczAudioTest\PropertyStore`, one of them pre-existing with another value → `Restored 1, Skipped 1`, and the pre-existing value is unchanged.

- [ ] **Step 2: Run it. It must fail.**
- [ ] **Step 3: Implement the functions and the `-Restore` dispatch.**
- [ ] **Step 4: Run it. It must pass.** Then rerun the elevated harness (UAC). Both must be green.
- [ ] **Step 5: Check encoding and line endings, then hand off.**

---

### Task 8: Launcher, hub entry and documentation

**Files:**
- Create: `scripts/windows/Clean-AudioDevices.cmd` (CRLF)
- Modify: `hub/catalog.json` (CRLF; append to `scripts` after `reset-searchindex`)
- Modify: `README.md` (LF)
- Modify: `docs/LESSONS_LEARNED.md` (CRLF)

**Interfaces:** none produced. The launcher calls the script by the flags fixed in Task 2.

- [ ] **Step 1: Write the launcher.**
  - **Template.** Copy `scripts/windows/Clean-StartupApps.cmd`'s structure: header comment,
    `SCRIPT`/`PS` variables, passthrough on arguments, `:menu`, summary, `run_elevated`, `:done`,
    and the `LAUNCHLINE` pause.
  - **Menu `choice /C 1234`:**

    | Key | Action |
    |---|---|
    | `[1]` | Census only (no elevation) |
    | `[2]` | Clean (`-Clean`) |
    | `[3]` | Clean, keeping ports your drivers still expose (`-Clean -KeepExposedPorts`) |
    | `[4]` | Restore from a manifest (`-Restore "<path>"`, quotes stripped from the input) |

  - **Order.** Branch on `if errorlevel 4/3/2` in descending order before any `set`.
  - **Questions, for `[2]`/`[3]` only:** preview Y/N (adds `-WhatIf`) and per-app settings Y/N
    (N adds `-SkipAppSettings`).
  - **Elevation.** `[2]`–`[4]` always run elevated, since the script would self-elevate anyway;
    use the `Start-Process … -Verb RunAs` line with `-NoExit`.
  - **Encoding.** Write the file, convert it to CRLF, and verify `<n> 0` and ASCII.

- [ ] **Step 2: Add the catalog entry** exactly as in spec §4 "Edits". Verify that
  `python -c "import json;d=json.load(open('hub/catalog.json'));e=[s for s in d['scripts'] if s['id']=='clean-audiodevices'][0];print(e['file'],e['elevation'],e['preview'])"`
  prints `scripts/windows/Clean-AudioDevices.ps1 self ['-ListOnly']`, and that the file is still
  all CRLF.

- [ ] **Step 3: Edit the README.**
  - **Top table:** a row between `Clean-StartupApps.ps1` and `Clear-RevitCache.ps1`, "Not an
    uninstaller — removes not-present audio endpoints …", with elevation `Required (self-elevates; -ListOnly does not)`.
  - **Layout line 37:** add `Clean-AudioDevices`.
  - **"Which script do I need?":** four rows:
    - "Settings → Sound lists devices you no longer have";
    - "… Disabled entries from an old PC";
    - "Put the audio entries back" (`-Restore <manifest.json>`);
    - "Entries came back after cleaning" (ports your drivers still expose; see the section).
  - **Exit codes:** one line, "`Clean-AudioDevices.ps1` shares the contract; `3010` means
    `pnputil` asked for a restart; entries Windows rebuilds are not failures."
  - **New section** `## \`Clean-AudioDevices.ps1\` — the Sound settings list, without the ghosts`
    after the `Clean-StartupApps.ps1` section and before `Clear-RevitCache.ps1`. Subsections:
    - *What it removes and what it never touches* (the spec §1 table in prose);
    - *Why some entries come back* (the endpoint builder rebuilds enabled ports; the AMD hint);
    - *The keys Administrators cannot delete* (backup semantics, no ACL change);
    - *Backup and restore*;
    - *The launcher*;
    - *Usage* (census, `-Clean -WhatIf`, `-Clean`, `-Clean -KeepExposedPorts`,
      `-Restore "$env:TEMP\AudioDevices_…\manifest.json"`);
    - *Parameters* (table);
    - *Notes and limitations* (about 10 s of silence; Sonar may need restarting; per-app counts
      drift as apps write).
  - Keep LF endings and ASCII.

- [ ] **Step 4: Edit LESSONS_LEARNED.** Add section `### E8. The key Administrators cannot delete,
  and the entry Windows rebuilds` after E7, covering:
  - the ACL;
  - why take-ownership was rejected (`SetSecurityInfo` auto-propagation);
  - backup semantics plus `NtDeleteKey`;
  - the enabled-interface rule;
  - that `pnputil /remove-device` leaves the Settings row in place.

  Then add checklist rows 31–35 with the five invariants listed in spec §4 "Edits". The `Where`
  column is `Clean-AudioDevices`. Keep CRLF.

- [ ] **Step 5: Verify.**
  - Run the line-ending and ASCII one-liners on all four files: each must keep its own
    convention, and `README.md` must stay LF.
  - `cmd /c scripts\windows\Clean-AudioDevices.cmd -ListOnly` must return exit 0, with the census
    printed (passthrough).
  - `findstr /n "LAUNCHLINE" scripts\windows\Clean-AudioDevices.cmd` must show the pause test.
  - `[System.Management.Automation.Language.Parser]::ParseFile` of the `.ps1` must report 0
    errors.

- [ ] **Step 6: Hand off.**

---

### Task 9: Live run on this machine (gated by the user)

**Files:** none, unless a defect is found. Then fix it in the owning task's file and rerun that
task's harness.

- [ ] **Step 1: Final green bar.**
  - Run both harnesses (elevated via UAC); both must pass.
  - Run both `-ExpectDefective` modes; both must fail.
  - Run the census; it must show the Task 4 counts.
  - Repeat the Task 6 Step 5 preview; it must change nothing.

- [ ] **Step 2: Snapshot for the restore check (unelevated).** Save `(Get-Acl).Sddl` and a
  `reg export` of three removable keys:
  - one orphaned: `Render\{1bd6e58a-9f00-417f-b0fb-93aa4651f1e5}`;
  - one interface-gone: `Render\{e12c921b-73dd-465e-92fd-9994fdd194b6}`;
  - one port-still-exposed: `Render\{2d7cbc39-ff20-42b7-81b4-6fef19f4dc2c}`.

  Save them under `%LOCALAPPDATA%\IczAudioLiveCheck\`.

- [ ] **Step 3: GATE. Ask the user for an explicit go-ahead to run the real `-Clean`.** Offer two ways: they run `Clean-AudioDevices.cmd` → `[2]`, or the executor runs `-Clean -Force` with the elevated recipe. Do not proceed without a yes.

- [ ] **Step 4: Check the real run.**
  - The exit code is 0 or 3010.
  - `Get-Service AudioEndpointBuilder,Audiosrv` shows both Running.
  - The summary lists the rebuilt entries; compare them with the 7 predicted.
  - Ask the user to confirm:
    - the Settings list (a screenshot);
    - playback on SteelSeries Sonar, the monitor (NVIDIA HDMI), and the Nothing Ear buds.
  - Rerun the census:
    - Remove holds only `port-still-exposed` entries, at most 7;
    - the per-app Remove count is 0;
    - Keep `live` still includes all 11 Active endpoints.

- [ ] **Step 5: Idempotence.** Run `-Clean -Force` a second time. It exits 2, or removes only
  rebuilt ports that Windows rebuilds again; report which.

- [ ] **Step 6: GATE. Ask the user for a go-ahead on the restore round-trip.**
  1. Run `-Restore <manifest>`. It exits 0.
  2. The three snapshot keys exist again.
  3. Their `Get-Acl` SDDL and their `reg export` match the Step 2 snapshot.
  4. Run `-Clean -Force` again to finish clean, and rerun the census to confirm.

- [ ] **Step 7: Close out.**
  - Delete `%LOCALAPPDATA%\IczAudioLiveCheck\`.
  - Report to the user: the final census, the rebuilt list, and the backup folders that can be
    deleted.
  - Write the outcome to memory (`icz_memory_remember`, scope `revit-cleaner`).
  - Hand off every changed file for the user to commit.
