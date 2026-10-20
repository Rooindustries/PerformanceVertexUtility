# Performance Vertex Utility

Performance Vertex Utility is a free, open-source Windows tuning tool for smooth gameplay: safe previews, backups and rollback, process tuning, uninstall cleanup, driver and profile recommendations, and diagnostics. It's a WinUI desktop app (`docs/internal/frontend`), a PowerShell backend (`backend/scripts`), native C# helpers (`backend/native`) and the original benchmark-and-rollback harness (`LeanClientOptimizer.ps1`). It's made and maintained by Roo Industries.

## What can never break

Users run this on the PC they game on. These come before any feature.

### 1. Every change has a backup and an undo

Nothing changes a PC without a preview first. Module runs are dry-run unless `-ConfirmApply` is passed, a confirmed apply saves a backup before it touches anything, and rollback restores it. Backend actions go through explicit preview, approval and recovery paths. A change with no working way back is a bug.

### 2. No surprise defaults

What a PC gets by default (module defaults, profiles, presets, catalog choices) changes only on purpose, and the PR says so in its first line.

### 3. Every Windows edition

Catalog settings list the editions and builds they apply to: Home (Core), Pro, Enterprise, Education and Server. A setting a PC can't use shows as not available on that PC, never as an error or a retry that can't work.

### 4. No telemetry

The app sends no usage data. It goes online only to check for updates and download them (automatic downloads can be turned off), to download a tool the user picks, and to send a bug report when the user clicks Send. In this codebase "telemetry" means local performance readings.

### 5. Windows PowerShell 5.1

Backend scripts run on the Windows PowerShell 5.1 that ships with Windows. `tools/validation/check_powershell.ps1` checks 5.1 syntax.

## Invariants

These hold on every commit of `main`. Each names the code that enforces it and the check that proves it. "Every Windows setting" means the Windows tweaks engine, process controls, Game Tune, background limits, leftover cleanup and the `LeanClientOptimizer.ps1` modules.

1. **Preview before change.** Nothing changes a PC without a preview the user approved. `TweakEngine.Apply` takes only a saved preview and its review hash. It rebuilds the plan and refuses if the catalog, a saved profile or any current value changed since the review (`backend/native/Optimizer.Core/TweakEngine.cs`). Process controls and leftover cleanup apply the same way from a reviewed preview (`ProcessControlEngine.Apply`, `FileCleanupEngine.Apply`, `RegistryCleanupEngine.Apply`). Harness modules are dry runs unless `-ConfirmApply` is passed (`Invoke-ApplyModule` in `LeanClientOptimizer.ps1`). Checked by `tools/validation/Tweaks` and `Test-LegacyModuleRollback.ps1`.
2. **Backup before apply.** Every prior value is saved before it changes, never after:
   - Registry tweaks commit in one registry transaction together with the recovery state that holds each original value (`RegistryTweakStore.CommitRegistry` in `RegistryTweaks.cs`).
   - Services, features, power, file permissions and other controls first write a pending journal. If a step fails, they roll back what was attempted (`RegistryTweakStore.Commit`).
   - Process controls save a journal with each original value before the first write, and mark each write as intended before making it (`ProcessControlEngine.Apply` and `Execute`).
   - Leftover cleanup backs entries up before it deletes them (`FileCleanupEngine.Apply`).
   - Harness modules write `backup.json` before applying (`New-ModuleBackup`).
3. **Undo restores the exact prior value.** Undo writes back the saved original, with the same value kind and data, and reads it back (`TweakComposition.Resolve`, plus the readback in `CommitRegistry`). DWORDs round-trip bit for bit. If another program changed a setting after we applied it, undo keeps that program's value and names the setting instead of overwriting it (`LeftAsChanged` for tweaks, `ProcessControlEngine.LeftAsSet` for process controls). Process controls restore the journal's originals (`ProcessControlEngine.Restore`), and cleanup restores its backups (`FileCleanupEngine.Restore`, `RegistryCleanupEngine.Restore`). Checked by `tools/validation/Tweaks`, `tools/validation/AppSweepUi/GovernorChecks.cs` and `Test-LegacyModuleRollback.ps1`.
4. **No surprise defaults.** A PC only gets what the user chose in a reviewed preview. Presets are fixed catalog entries. The FPS preset must equal the measured winners with benchmark evidence and never include a setting that breaks a PC after a reboot (`tools/validation/check_windows_tweaks.py`). A PR that changes what a PC gets by default says so in its first line.
5. **Edition detection.** The engine reads the PC's build and edition from `CurrentBuildNumber` and `EditionID` (`RegistryTweaks.cs`). Each setting and option lists the builds and editions it applies to, and only matching options are offered (`TweakEngine.Supported`). A row with no option for this PC, or a Windows feature this PC doesn't have, reports "No choice applies to this Windows version, edition or installed product." The app shows that as "Not available here" with no Retry (`PcLacks`, `UnavailableHere` and `CanRetry` in `WindowsTweaksViewModel.cs`). It's never an error or a retry that can't work. Checked by `tools/validation/Tweaks` (catalog integration and feature checks) and `tools/validation/WindowsTweaksUi`.
6. **Bug report privacy.** A bug report leaves the PC only when the user clicks Send (`BugReportViewModel.SendAsync`). Everything it carries goes through `BugRedactor` first: description, specs, tweak summary and log tails (`Services/BugRedactor.cs`). The redactor replaces:
   - the user's profile path with `%USERPROFILE%`
   - the user name with `<user>` and the PC name with `<pc-name>`
   - every other account's profile folder on this PC with `<user>`, including names with spaces, apostrophes, JSON escapes or a different letter case
   - account SIDs with `<sid>`

   The app log is redacted the same way when it's written (`AppLog.Write`), and redacting twice changes nothing. Checked by `tools/validation/AppSweepUi/BugReportChecks.cs`.

### Changing code an invariant depends on

A PR that touches any of the code above:
- Names the invariants it touches.
- Traces every way into the changed behavior (each page and button, preset and profile, undo, recovery after a crash or restart, the harness) and every state its inputs can be in. Each one gets a case.
- Writes the failing check on `main` first, then the fix that turns it green, and runs the apply, verify, undo and verify-restored flow on a real Windows PC before merge.
- Briefs its reviewer with the diff, these invariants and the entry-point list, and asks them to break each one.
- Gives every bug found a one-line root cause and a new invariant or regression check, so the same kind of bug can't come back.

## Ways to hurt a PC

- Validation never runs real app uninstallers, deletes user data, imports real NVIDIA profiles, or changes services, registry settings or drivers as a side effect. Use disposable fixtures and probe processes, and remove everything you create, registry values included, in `finally`.
- Clean up test-owned processes, fixtures, helpers and temporary power plans. `backend/state` must stay empty.
- Keep personal and test-machine identifiers (user folders, emails, private addresses, machine names) out of the repo. The baseline check fails on them.
- Keep Windows paths short. Windows PowerShell 5.1 can't open paths over 259 characters, and long user folders get close.

## Prove a change on Linux

Linux is the development host. These four Baseline jobs run for same-repository pull requests, pushes to `main` and manual runs on the self-hosted Linux runner (`runs-on: [self-hosted, laptop]`). Fork pull requests skip these jobs and need isolated local validation:

```sh
python -m pip install -r tools/validation/requirements.txt
python tools/validation/check_baseline.py
python -m unittest discover -s tools/validation -p 'test_*.py'
pwsh tools/validation/check_powershell.ps1   # needs PSScriptAnalyzer 1.25.0
python tools/validation/build_dotnet.py      # needs the .NET 8 SDK
```

If GitHub Actions can't start them, run the same steps on the exact head commit and record a `local-ci` commit status (`gh api repos/Rooindustries/PerformanceVertexUtility/statuses/<sha> -f state=success -f context=local-ci -f description=...`), never as PR text.

## What needs real Windows

Anything that reads or changes the registry, services, process, I/O or GPU priority, drivers or the desktop app. The Baseline workflow's Windows matrix runs on GitHub-hosted Windows only on a manual run, or on pushes to `main` while the repository variable `HOSTED_WINDOWS_CI` is `true`. Run the backend suites from an isolated source copy on a Windows test PC:

```powershell
.\tools\scripts\Test-Baseline.ps1 -TestName Test-LegacyModuleRollback.ps1
.\tools\scripts\Test-Baseline.ps1 -BuildFrontend
```

From Linux, `tools/validation/windows_ssh.py` checks the machine name, stages tracked source and runs a validation script (see `backend/README.md`). Add `--include-frontend` for suites that compile desktop sources. Test the AMD and NVIDIA paths on their own PCs; one doesn't prove the other. Compiling the app isn't a UI check: launch it, take screenshots and look at them.

## How we ship

- Small PRs, one fix each, on a branch from `main`, with conventional commit subjects (`fix:`, `test:`, `docs:`).
- The PR's first line says what a user would notice.
- Reproduce a bug before fixing it, and prove the fix with a check that fails before and passes after, on the platform where the bug lives.
- Update any doc the change makes wrong. See `docs/development-workflow.md` for the full workflow.
