# Backend

The backend provides Windows discovery, process controls, cleanup planning, driver and utility inventory, and structured preview/apply/restore results. The desktop consumes the same scripts and contracts.

## Layout

| Location | Responsibility |
|---|---|
| `scripts` | Discovery, execution, recovery, and regression checks |
| `native` | Process governor and standby-memory helpers |
| `contracts` | JSON Schema definitions and explicit validation mappings |
| `capabilities` | Capability descriptions and executor routes |
| `catalogs` | Driver profiles, utility inventory, optimization references, and Games tab launch presets |
| `profiles` | Process policies and protected-process rules |
| `uninstall` | Dependency-review policy and leftover selection rules |
| `samples` | Curated examples; current-PC screens use live discovery |

## Execution and recovery

Discovery and default previews do not change system settings. Process controls require confirmed apply, capture original state, bind targets to process identity, and provide restore commands. Runtime validation uses disposable processes and temporary state roots.

`Invoke-UninstallCleanupApplyPackage.ps1` can run an explicitly reviewed official uninstaller or perform a separately reviewed file cleanup. After vendor removal it returns `cleanup-review-required` with a fresh content scan, leaving the earlier deletion list unapplied. File-only cleanup requires one matching app identity, hashes of the reviewed input files, explicit approvals, and separate dependency-review approval where required. Protected leftovers, unsupported item types, overlapping targets, and unsafe backup locations are rejected. The caller must retain the reviewed inputs; rebuilding them at apply time is not approval of the new contents.

Cleanup copies originals and flushes a recovery journal before destructive work. Each attempted deletion is recorded before execution. Partial failures return the saved journal and actual completed-deletion count. Repeating the same saved operation does not run it again. Restore copies backup contents to their original paths and can be retried. This restores backed-up leftovers; it does not reinstall an application removed by its vendor uninstaller. Keep recovery storage outside temporary directories and deletion targets.

NVIDIA imports and hardware-specific utilities retain their explicit approval and tool requirements. Several catalog entries support discovery, preview, or a disposable fixture rather than unrestricted real execution. Timer-resolution and temporary power-plan validation exercise bounded reversible paths. Service, registry, and driver changes must not be inferred from a capability label or a successful preview.

Supported CPU Sets, durable bulk removal, and the sourced settings inventory are described in [Optimization controls](../docs/optimization-controls.md). The [research index](../docs/research/README.md) separates documented upstream behavior, inferred controls, implementation coverage, and remaining validation.

## Protected launch sessions

`Invoke-ProtectedGameSession.ps1` exposes Preview, Start, Status, Affinity, Stop and Recover. Arm a reviewed session before opening the game through its normal launcher. The separate worker and recovery watcher bind every game instance to its executable path, creation time and launcher job. Launcher scope must be accepted explicitly.

High I/O priority is applied to each launched game through its reviewed runtime journal, with exact readback and Stop restoration. It does not change the launcher's I/O priority. The Games CPU picker offers each available last-level cache group, so a game can be limited to the CPUs that share one cache. Run `Test-ProtectedGameSessions.ps1 -HighIo -InspectSeconds 60` for the disposable hand-off, relaunch, denied-new-handle and recovery checks plus a manual affinity/I/O inspection window. See [Protected game sessions](native/PROTECTED-SESSIONS.md) for scope and required hardware.

When Windows provides its basic process list (documented from Windows 11 26100.4770; the app asks Windows rather than comparing build numbers), GPU and High I/O sessions retain a normal launch-time process handle and immediately copy it to the recovery watcher. Both handles must independently read the same original GPU class before applying the reviewed value. The session reads back the actual process class, reapplies only a reset to its captured original, and preserves other values. The watcher can restore through its retained handle after the controller exits. Without that process list, sessions keep the existing fresh-handle route. The capture uses Microsoft's documented [basic process enumeration](https://learn.microsoft.com/en-us/windows/win32/api/winternl/nf-winternl-ntquerysysteminformation) and [handle duplication](https://learn.microsoft.com/en-us/windows/win32/api/handleapi/nf-handleapi-duplicatehandle).

Missing access or privilege remains `unavailable` for that field only; the CPU limit keeps running. Graphics initialization can remain pending for up to 90 seconds. An unreadable original or missing, conflicting or stale recovery acknowledgement never authorizes a GPU setter. Launch timing and game protection can prevent capture. A Windows API contract does not establish publisher endorsement or compatibility with future game updates.

Run `Test-ProtectedGameSessions.ps1 -RetainedGpu` on the RX9070XT validation machine to exercise real GPU work after a disposable process denies new control handles. This mode covers sustained class changes, controller and watcher termination, foreign values and rejected recovery evidence. `-HardwareGpu` runs the broader launch-priority, core-switching, relaunch and recovery checks; those checks also exercise the disposable fixture's IFEO registry settings.

## Validation

The desktop saves the Game priority Review and its hash. Start checks the reviewed process IDs, creation times, executable paths and controls before changing anything, then limits every poll to that saved plan. A closed or restarted reviewed game, changed profile or edited review refuses the whole Start. Older direct backend calls without a review retain their existing behavior.

Game Tune saves the app and backend process IDs and creation times. If the app ends during a run, the backend stops tuning and restores its backup. On opening the page, the desktop also calls `Get-GameTuneSessionStatus.ps1 -RecoverInterrupted` to recover a crashed backend or a session whose app ended just after the run. This checks every saved session, newest first, and keeps an older Restore visible when a newer run changed nothing. After a reboot, original game processes have ended, so their saved session can finish without changing replacement processes. Unreadable identities, missing backups and values changed by another program keep the evidence and show that recovery needs attention. Failed recovery does not retry automatically. Plain status calls remain read-only, and older sessions without a saved controller identity still use manual Restore.

Install Python 3.10+ and the development requirements:

```console
python -m pip install -r tools/validation/requirements.txt
python tools/validation/check_baseline.py
```

The static checker validates declared schemas, their mapped fixtures, route manifests, JSON syntax, XML structure, public-source hygiene, and empty runtime state. `validation-map.json` names the domain checks for curated examples without a dedicated schema; schema coverage is reported separately.

On Windows, run the complete suite in an isolated source copy:

```powershell
.\tools\scripts\Test-Baseline.ps1 -BuildFrontend
```

Set `ROO_INDUSTRIES_PYTHON_EXE` or `ROO_INDUSTRIES_DOTNET_EXE` when the development interpreters are outside `PATH`. Desktop compilation needs the .NET 8 SDK. The suite invokes Windows PowerShell 5.1, captures one log per test and a JSON summary under ignored `artifacts/validation`, and checks that `backend/state` is empty. It does not launch the WinUI app.

Run individual regressions with `-TestName`:

```powershell
.\tools\scripts\Test-Baseline.ps1 -TestName Test-LegacyModuleRollback.ps1,Test-UninstallCleanupApplyPackage.ps1
```

The legacy rollback suite also has a fixture-only base/new apply comparison. Supply an exported base harness and its SHA-256; it records the actual absent/present UInt32-max outcomes and checks differing-kind writes on a disposable HKCU key:

```powershell
.\backend\scripts\Test-LegacyModuleRollback.ps1 -Scenario ApplyComparison -BaseHarnessPath C:\OwnedFixture\base.ps1 -BaseHarnessSha256 <sha256>
```

Set `ROO_INDUSTRIES_LEGACY_BASE_HARNESS` and `ROO_INDUSTRIES_LEGACY_BASE_HARNESS_SHA256` to include that comparison in the suite's `All` scenario through `Test-Baseline.ps1`. The comparison removes its fixture in `finally` and never changes real services.

From Linux, configure a Windows SSH alias with its own authorized key and use the direct helper:

```console
python3 tools/validation/windows_ssh.py --host windows-test --expected-machine TEST-PC inspect
python3 tools/validation/windows_ssh.py --host windows-test --expected-machine TEST-PC upload
python3 tools/validation/windows_ssh.py --host windows-test --expected-machine TEST-PC run validation.ps1
```

The helper disables SSH proxying, checks the Windows computer name before writes, and preserves argument boundaries through encoded PowerShell. Upload includes tracked working-tree source and a SHA-256 manifest under the current Windows user's Temp directory; it excludes frontend sources. Add new source files to Git before uploading them. The returned staging path can be used by a trusted validation script that runs `Test-Baseline.ps1` and verifies the manifest before and after testing. Retrieve results before removing the owned staging directory.

A green build or fixture suite does not establish real-provider operation, real uninstall success, a performance gain, or visual quality. Record those separately on the relevant Windows machine.

Profile and Game Tune restore changes also require the manual real Windows
entry point `tools/validation/Background/Invoke-RestoreE2EGates.ps1 -Source
$Source -OutRoot $OwnedArtifacts`. Use its original frame receipt, active Harness
lease and hashed E2E inputs as described in the [Background checks](../tools/validation/Background/README.md#required-restore-e2e-gates).
This group is separate from automatic Baseline discovery. Historical Linux
restore diagnostics simulate process I/O; schema validation of their full JSON
envelopes proves only the contract. Real restore, contention, C6 and rendered
UI8/media gates must finish on the authorized Windows source before merge.
Saved-format replay and owned junction launch checks are part of that manual
gate. Keep c50 and b0 evidence separate; an un-reproduced alias case stays
recorded as missing red.

These manual checks cover a saved request that already matched its original
value. The producer saves no change record for that control. When Undo reads
an absent or valid saved change list with no matching record, it excludes the
request only if the original and requested values are valid and equal, and
any legacy applied value is also valid and equal. Undo leaves that control
alone if another program changes it later, while restoring recorded changes
on other controls. Conflicting or invalid legacy metadata keeps recovery
available until a fresh check confirms the original value or the process has
ended. Changed requests with missing apply evidence stay recoverable. An
already-original or kept value seen in a preview still needs a fresh check
before recovery closes.

Restore checks the saved process instance at explicit points before publishing
its result. If a clean check proves that the original ended or restarted,
that entry is reported as already closed. A failed query, write, readback or
resource cleanup keeps the entry pending with its actual error, even if the
process later exits. Other saved entries continue. Verified writes made
before an exit remain in the artifacts; a closed entry is counted once and
has no current restored or kept value. A process can exit between a clean
check and a later operation. If that operation fails, the attempt stays
pending. These timing cases require the manual Windows gate; authored
scenarios and Linux static checks do not prove native behavior.
