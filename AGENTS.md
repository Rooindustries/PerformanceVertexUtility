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

These must hold on every commit of `main`. Each one names the code that enforces it and the check that proves it. A path that doesn't meet one yet is listed under "Known gaps". The PR that closes a gap removes that line in the same change.

1. **Preview before change.** Nothing changes a PC until the user approved a preview of that exact change.
   - Enforced by: `TweakEngine.Apply` takes only a saved preview and its review hash. It rebuilds the plan and refuses if a saved profile or any current value changed since the review, or if the catalog changed for a preview that selects settings; undo previews are allowed across catalog updates (`backend/native/Optimizer.Core/TweakEngine.cs`). Process controls and leftover cleanup apply only a reviewed preview the same way (`ProcessControlEngine.Apply`, `FileCleanupEngine.Apply`, `RegistryCleanupEngine.Apply`). Harness modules are dry runs unless `-ConfirmApply` is passed (`Invoke-ApplyModule` in `LeanClientOptimizer.ps1`). Game Tune starts when the user clicks Start for that game, and Stop undoes it.
   - Checked by: `tools/validation/Tweaks`, `tools/validation/OptimizerCore` (`Test-OptimizerCore.ps1`), `Test-LegacyModuleRollback.ps1`.
   - Known gaps:
     - A confirmed harness apply re-reads its module manifest instead of the one the user previewed.
     - Game Tune Start isn't bound to the game the user reviewed: it tunes whichever supported game is running when it executes.
2. **Backup before apply.** Every prior value is saved before it changes, never after.
   - Enforced by:
     - Registry tweaks commit in one registry transaction together with the recovery state that holds each original value (`RegistryTweakStore.CommitRegistry` in `RegistryTweaks.cs`).
     - Services, features, power, file permissions and other controls write a pending journal before the first change. If a step fails, rollback is attempted. If rollback can't finish (for example while Windows servicing waits for a restart), the journal stays and the app asks for recovery (`RegistryTweakStore.Commit`, `ControlTweaks.cs`).
     - Process controls save a journal with each original value before the first write, and record each write's intent before making it (`ProcessControlEngine.Apply` and `Execute`).
     - Leftover cleanup backs each entry up before deleting it (`FileCleanupEngine.Apply`, `RegistryCleanupEngine.Apply`).
     - Harness modules write `backup.json` before applying (`New-ModuleBackup`).
   - Checked by: `tools/validation/Tweaks`, `tools/validation/OptimizerCore` (`Test-OptimizerCore.ps1`), `tools/validation/AppSweepUi`, `Test-LegacyModuleRollback.ps1`.
3. **Undo restores the exact prior value.** Undo writes back the saved original, with the same value kind and data, and checks it. If another program changed the setting after we applied ours, undo keeps that program's value and says which setting it left.
   - Enforced by:
     - Windows tweaks restore the saved original and read it back. DWORDs round-trip bit for bit, and a setting changed by someone else is reported as left changed (`TweakComposition.Resolve`, `LeftAsChanged`, the readback in `CommitRegistry`).
     - The process governor leaves a value another program set and says "Left as another program set it." (`ProcessControlEngine.LeftAsSet`). Other process restores stop and report reconciliation when the value drifted (`ProcessControlEngine.Restore`).
     - Cleanup restores verify their backups and refuse a conflicting destination (`FileCleanupEngine.Restore`, `RegistryCleanupEngine.Restore`).
   - Checked by: `tools/validation/Tweaks`, `tools/validation/OptimizerCore` (`Test-OptimizerCore.ps1`), `tools/validation/AppSweepUi/GovernorChecks.cs`.
   - Known gaps:
     - Game Tune Stop and profile backup restores overwrite a value another program set afterwards. Background-limit restores already keep it.
     - Harness rollback restores the manifest's value kind rather than the original kind, overwrites later changes, and doesn't verify restored values or service startup types. Registry keys created by apply stay in place; undo removes values without deleting parent keys or unrelated entries.
4. **No surprise defaults.** A PC only gets what the user chose. Presets are fixed catalog entries.
   - Enforced by: `tools/validation/check_windows_tweaks.py` requires the FPS preset to list exactly the measured winners in `backend/catalogs/fps-preset.json`. Each pick must be a real catalog option with benchmark evidence, and the setting known to break a PC after a reboot is excluded.
   - A PR that changes what a PC gets by default says so in its first line.
   - Known gaps: the harness manifest gap in 1.
5. **Edition detection.** A setting a PC can't use shows as not available on that PC, never as an error or a retry that can't work.
   - Enforced by: the engine reads the PC's build and edition from `CurrentBuildNumber` and `EditionID` (`RegistryTweaks.cs`), and offers only options whose build and edition gates match (`TweakEngine.Supported`). A Windows feature the PC doesn't have makes its choices unavailable instead of failing the read (`TweakControlRead.Allows`). A row with no option for this PC reports "No choice applies to this Windows version, edition or installed product.", and missing Windows components report "... is not installed" or "... is not available with ...". The app shows these as "Not available here" with no Retry (`PcLacks`, `UnavailableHere` and `CanRetry` in `WindowsTweaksViewModel.cs`).
   - Checked by: `tools/validation/Tweaks` (catalog integration and feature checks), `tools/validation/WindowsTweaksUi`.
   - Known gaps:
     - Defender rows read as "Couldn't check" on Windows without Defender's PowerShell commands.
6. **Bug report privacy.** A bug report leaves the PC only when the user clicks Send (`BugReportViewModel.SendAsync`). The description, editable specs and diagnostics must redact account profile paths, the current user and PC names, and account SIDs. Contact details the user supplies are kept as typed.
   - Enforced by: the attached files (specs, tweak summary, log tails), description and editable specs go through `BugRedactor` before they're zipped or sent. It replaces:
     - the user's profile path with `%USERPROFILE%`
     - the user name with `<user>` and the PC name with `<pc-name>`
     - S-1-5-21 account SIDs with `<sid>`
     - other accounts' profile folders with `<user>`

     The app log is redacted when it's written (`AppLog`).
   - Checked by: `tools/validation/AppSweepUi/BugReportChecks.cs`.
   - Known gaps:
     - Another account's folder name stops being redacted at a space or apostrophe, and the app log uses its own narrower rules.
     - Other accounts' profiles outside a drive's `Users` directory, including relocated and network profiles, aren't redacted.
     - Account names and PC names of one character aren't redacted.
     - Microsoft Entra account SIDs (`S-1-12-1-...`) aren't redacted.

### Changing code an invariant depends on

A PR that touches any of the code above:
- Names the invariants it touches.
- Traces every way into the changed behavior (each page and button, preset and profile, undo, recovery after a crash or restart, the harness) and every state its inputs can be in. Each one gets a case.
- Writes the failing check on `main` first, then the fix that turns it green. Anything that applies or undoes a setting also runs apply, verify, undo and verify-restored on a Windows test PC before merge.
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
