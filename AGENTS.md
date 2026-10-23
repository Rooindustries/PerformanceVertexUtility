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
   - Enforced by: `TweakEngine.Apply` takes only a saved preview and its review hash. It rebuilds the plan and refuses if a saved profile or any current value changed since the review, or if the catalog changed for a preview that selects settings; undo previews are allowed across catalog updates (`backend/native/Optimizer.Core/TweakEngine.cs`). Process controls and leftover cleanup apply only a reviewed preview the same way (`ProcessControlEngine.Apply`, `FileCleanupEngine.Apply`, `RegistryCleanupEngine.Apply`). Harness modules are dry runs unless `-ConfirmApply` is passed, and a confirmed apply takes only the saved preview (`-PreviewPath`). It refuses before any backup or write if the module's plan changed since that preview, if a registry entry declares a type other than REG_DWORD, REG_QWORD or REG_SZ, if a service it stops has a protected dependent, or while the module's newest backup is from an apply that stopped part-way and hasn't been undone (`Get-ModulePlan`, `Assert-ModulePreview`, `Assert-LastApplyFinished` and `Invoke-ApplyModule` in `LeanClientOptimizer.ps1`). Game Tune Start takes the plan Review saved and its hash. It refuses and changes nothing when a reviewed game closed or restarted (process ID, start time and path), the profile or a running reviewed app's plan changed, or the review file changed, and every poll touches only reviewed apps and controls (`Start-GameTuneSession.ps1`, `StartMatchTuneAsync` in `PerformanceProfilesViewModel.cs`). Stop undoes it. Saved launch settings arm a new launcher run only when its fresh preview equals the saved review apart from the launcher process (`ProtectedSessions.ProfileMismatch`).
   - Checked by: `tools/validation/Tweaks`, `tools/validation/OptimizerCore` (`Test-OptimizerCore.ps1`), `Test-LegacyModuleRollback.ps1`, `Test-GameTuneReviewBinding.ps1`, `tools/validation/AppSweepUi`.
   - Known gaps:
     - Confirmed harness Undo isn't bound to a reviewed preview.
     - Backend calls to `Start-GameTuneSession.ps1 -ConfirmApply` without `-ReviewPath` (the capability router and the older session suites) still tune whatever matches at each poll. The app always passes its review.
2. **Backup before apply.** Every prior value is saved before it changes, never after.
   - Enforced by:
     - Registry tweaks commit in one registry transaction together with the recovery state that holds each original value (`RegistryTweakStore.CommitRegistry` in `RegistryTweaks.cs`).
     - Services, features, power, file permissions and other controls write a pending journal before the first change. If a step fails, rollback is attempted. If rollback can't finish (for example while Windows servicing waits for a restart), the journal stays and the app asks for recovery (`RegistryTweakStore.Commit`, `ControlTweaks.cs`). After a restart, the feature check closes that journal only when each changed feature is finished, back where it was (Windows undid it, so its ownership is released) or no longer listed. A feature in any other state, or a restore Windows undid, keeps the journal (`RegistryTweakStore.Recover`).
     - Process controls save a journal with each original value before the first write, and record each write's intent before making it (`ProcessControlEngine.Apply` and `Execute`).
     - Process profile applies save every planned original and proposed value before the first change, to a path the app records before the script starts, and save each control's outcome right after its write. An apply that is cut off, or whose result is lost, is offered for Restore on the next page load (`Apply-ProcessProfile.ps1 -RecoveryJournal`, `LiveDataService.SettleProcessApply`). Restore undoes each control saved as applied. The control a cut left unconfirmed, or an unwritten one another program changed, stays pending until its app closes.
     - Leftover cleanup backs each entry up before deleting it (`FileCleanupEngine.Apply`, `RegistryCleanupEngine.Apply`).
     - Harness modules write `backup.json` before applying, through a flushed temporary file that is then renamed, so a crash leaves the previous file or none (`New-ModuleBackup`, `Write-JsonFile`). The backup also records each dependent service's state before a stop, and right after the stop (even a failed one) whether each running dependent is now stopped (`Save-DependentStopEvidence`).
     - Game Tune records the app and backend process IDs and start times. If the app ends during a run, the backend stops tuning and restores its backup. On reopening, the desktop also recovers interrupted backends and sessions whose app ended after the run. Recovery restores only verified original process instances whose controls still match our applied or original values. Missing backups, unreadable identities and unconfirmed writes keep the backup and report an error, with no automatic retry. Another program's value is kept and reported (`Get-GameTuneSessionStatus.ps1 -RecoverInterrupted`). Older sessions without controller identity still need manual Restore.
     - A game session interrupted by a crash or restart is recovered by its own task at sign-in, when the app opens and before an update installs; the uninstaller recovers the rest (`Invoke-ProtectedGameSession.ps1 -Action RemoveAll`).
   - Checked by: `tools/validation/Tweaks`, `tools/validation/OptimizerCore` (`Test-OptimizerCore.ps1`), `tools/validation/AppSweepUi`, `Test-LegacyModuleRollback.ps1`, `Test-GameTuneRecovery.ps1`, `tools/validation/Background/Test-InterruptedApply.ps1`, `Test-InterruptedApplyJournal.ps1`.
3. **Undo restores the exact prior value.** Undo writes back the saved original, with the same value kind and data, and checks it. If another program changed the setting after we applied ours, undo keeps that program's value and says which setting it left.
   - Enforced by:
     - Windows tweaks restore the saved original and read it back. DWORDs round-trip bit for bit, and a setting changed by someone else is reported as left changed (`TweakComposition.Resolve`, `LeftAsChanged`, the readback in `CommitRegistry`).
     - The process governor leaves a value another program set and says "Left as another program set it." (`ProcessControlEngine.LeftAsSet`). Other process restores stop and report reconciliation when the value drifted (`ProcessControlEngine.Restore`).
     - Game Tune Stop and profile Undo leave out controls they never planned to change: there is no saved record for that control, the valid saved original and requested values match, and no legacy applied value conflicts. Other unverified controls stay recoverable when the value is not the original, including changed requests with absent, empty or nonmatching records. A clean explicit instance check can close recovery when the original ends, including after earlier verified writes. An observed query, write, readback or cleanup error keeps that snapshot pending. A closed snapshot is counted once and has no current restored or kept attribution; earlier writes remain in the artifacts. Requested or legacy applied fields alone do not prove that a write succeeded. Every live restore decision still holds both existing leases through fresh ownership, readback and cleanup (`Stop-GameTuneSession.ps1`, `Restore-ProcessProfileBackup.ps1`, `Confirm-RooIndustriesRestoreControl`).
     - Cleanup restores verify their backups and refuse a conflicting destination (`FileCleanupEngine.Restore`, `RegistryCleanupEngine.Restore`).
     - Harness rollback verifies restored registry kinds/data and original service startup plus Running when required, preserves later changes and ambiguous runtime states, and reports missing ownership evidence (`Invoke-RollbackModule`). Other original service runtime states keep startup-only behavior. It restarts only dependent services the apply confirmed its own stop stopped, when they were running before and nothing about them changed since; a refused, partial or unrecorded stop grants no restart. Before each dependent start, it atomically saves the restore attempt; a failed save prevents the start. Each verified or observed dependent restoration is saved in the backup, releasing runtime ownership so repeated Undo preserves later stops across process restarts. Confirmed Apply and Undo share one machine-wide lock (`Enter-ChangeLock`): Apply holds it from creating its backup through every write, and Undo from selecting the backup through every write and service action. Another confirmed Apply or Undo waits at most two seconds before refusing, so Undo can't act on a backup whose apply is still running and stale snapshots cannot erase newer ownership markers. Undo refuses a backup file that is a symbolic link or has other hard links, so ownership lives in one file (`Resolve-BackupFile`). Process exit releases the lock; previews take no lock and write no recovery state. A stopped dependent with an attempted but unconfirmed restoration stays stopped and is reported as left changed; its backup evidence is kept. It removes only its values, keeping parent keys and unrelated entries.
     - Game Tune Stop and automatic recovery check each saved control right before restoring it. A control already at its original value needs no write, a value another program set after a verified Game Tune write is kept and listed as left, and a saved control with no valid original value blocks that app's restore and keeps the backup (`Stop-GameTuneSession.ps1`). The app names the game, the setting and the value Restore left, and explains any other skipped setting in its own words (`SummarizeControls` and `DescribeGameTuneSkips` in `PerformanceProfilesViewModel.cs`).
   - Checked by: `tools/validation/Tweaks`, `tools/validation/OptimizerCore` (`Test-OptimizerCore.ps1`), `tools/validation/AppSweepUi/GovernorChecks.cs`, `tools/validation/AppSweepUi/GameTuneRestoreChecks.cs`, `Test-LegacyModuleRollback.ps1`, `Test-GameTuneRecovery.ps1 -InMemory`, `tools/validation/Background/Test-RestoreKeepsOtherValue.ps1`, `tools/validation/Background/Test-RestoreSerialization.ps1`.
   - Restore proof: `tools/validation/Background/Invoke-RestoreE2EGates.ps1 -Source $Source -OutRoot $OwnedArtifacts` is a required manual real Windows gate, separate from automatic Baseline. The retired Linux-only [Profile confirmation](https://github.com/Rooindustries/PerformanceVertexUtility/blob/8159820c33531fa476a3aefa987a3b8094ecfae6/tools/validation/Background/Test-ProfileRestoreConfirmation.ps1) and [identity recovery](https://github.com/Rooindustries/PerformanceVertexUtility/blob/8159820c33531fa476a3aefa987a3b8094ecfae6/tools/validation/Background/Test-ProfileRestoreIdentityRecovery.ps1) simulations remain in Git history; their old receipts apply only to their recorded source inputs. Current restore proof uses the real Windows group, not those simulations. C6 and rendered UI8/media remain required; see `tools/validation/Background/README.md`. Its `harness-blocked` group (`-Group harness-blocked`) covers saved-format recovery, an owned junction launch and the late-exit, governor and adverse-write histories. A matching-spelling junction run does not reproduce the alias defect; retain that limitation with the raw observations.
   - Known gaps:
     - The 53 `harness-blocked` restore scenarios fail on real Windows because of test-harness bugs, so the default run leaves them out until ROO-673 fixes them.
4. **No surprise defaults.** A PC only gets what the user chose. Presets are fixed catalog entries.
   - Enforced by: `tools/validation/check_windows_tweaks.py` requires the FPS preset to list exactly the measured winners in `backend/catalogs/fps-preset.json`. Each pick must be a real catalog option with benchmark evidence, and the setting known to break a PC after a reboot is excluded.
   - A PR that changes what a PC gets by default says so in its first line.
5. **Edition detection.** A setting a PC can't use shows as not available on that PC, never as an error or a retry that can't work.
   - Enforced by: the engine reads the PC's build and edition from `CurrentBuildNumber` and `EditionID` (`RegistryTweaks.cs`), and offers only options whose build and edition gates match (`TweakEngine.Supported`). Registry policies Microsoft documents as edition-limited, such as diagnostic data off, are gated from `backend/catalogs/windows-policy-editions.json` (`check_windows_tweaks.py` fails while one is offered elsewhere). A Windows feature the PC doesn't have makes its choices unavailable instead of failing the read (`TweakControlRead.Allows`). A row with no option for this PC reports "No choice applies to this Windows version, edition or installed product.", and missing Windows components report "... is not installed" or "... is not available with ...". A setting whose PowerShell commands are missing reports "... is not available with this Windows version." before any read or write (`Assert-Commands` in `WindowsControls.ps1`); when an installed module provides them but fails to load, it reports "... couldn't load its PowerShell commands: <load error>" instead, which the app keeps as Couldn't check with Retry; exploit protection settings report it when their readback command is missing, and read Couldn't check before any write when its module fails to load, without caching that failure (`MitigationControl.Read`). The app shows these, and rows where clearing an override is the only choice left for this PC, as "Not available here" with no Retry (`PcLacks`, `UnavailableHere` and `CanRetry` in `WindowsTweaksViewModel.cs`).
   - Checked by: `tools/validation/Tweaks` (catalog integration and feature checks), `Test-WindowsControlOutput.ps1`, `tools/validation/OptimizerCore` (`Test-OptimizerCore.ps1 -Area control-reads`), `tools/validation/WindowsTweaksUi`, `tools/validation/check_windows_tweaks.py`, `tools/validation/TweakReads` (every row's recorded Windows reads and each choice's writes never read as Couldn't check, Custom value or Not read, except rows its allowlist names with their cause).
6. **Bug report privacy.** A bug report leaves the PC only when the user clicks Send (`BugReportViewModel.SendAsync`). The description, editable specs and diagnostics must redact account profile paths, the current user and PC names, and account SIDs. Contact details the user supplies are kept as typed.
   - Enforced by: the attached files (specs, tweak summary, log tails), description and editable specs go through `BugRedactor` before they're zipped or sent. It replaces:
     - the user's profile path with `%USERPROFILE%`
     - the user name with `<user>` and the PC name with `<pc-name>`
     - local (`S-1-5-21-...`) and Microsoft Entra (`S-1-12-1-...`) account SIDs with `<sid>`
     - other accounts' profile folders with `<user>`: any folder directly under a `Users` or `Documents and Settings` folder, whether the path starts with a drive, an NT device or volume, a UNC share or `%SystemDrive%`, and with mixed, doubled or JSON-escaped separators and `.` components. Relocated, roaming and network profiles come from Windows' profile list (`BugRedactor.RegisteredProfiles`), and the folders next to them are private too, also through `.` and `..` components, the drive's volume, NT device or administrative share (`D$`) spelling, the `\Device\Mup` spelling of a share and the server's short or full name. JSON `\u` escapes in profile roots, separators, account SIDs and `%USERPROFILE%` are recognized without rewriting the surrounding text. Inside a link's query a profile path ends at the next `&`, `#` or `;` parameter, so the rest of the link stays as written.
     - a name suffix that older logs left after `%USERPROFILE%`, like `%USERPROFILE%.name\...`, with `<user>`
     - a one-letter user or PC name in the forms `PC\A`, `AzureAD\A` and `\\X\share` with `<user>` or `<pc-name>`. As a bare word one letter is far more often ordinary text, so it stays.

     The app log is redacted when it's written (`AppLog`).
   - Checked by: `tools/validation/AppSweepUi/BugReportChecks.cs` (run alone with `AppSweepUi bug-report`).
   - Known gaps:
     - Other accounts' folders outside a `Users` folder that Windows doesn't list as profiles, such as redirected folders or deleted accounts' leftovers, aren't redacted.
     - Text that reads as both a path and JSON escapes stays as written: three backslashes before a folder starting with `n`, `r`, `t`, `b` or `f` whose own separator is also followed by one of those letters, `%USERPROFILE%` followed directly by `\u` with no deeper separator after it, and a one-letter account named `b`, `f`, `n`, `r`, `t` or `u` after a single backslash.
     - An old-log suffix after `%USERPROFILE%` that starts with a space or comma and isn't followed by a separator reads as prose and stays.
     - One-letter user and PC names stay readable as bare words.
     - A one-letter account name after a domain other than the PC name or `AzureAD`, such as `CONTOSO\A`, stays readable.
     - A quoted single-rooted path with doubled backslashes is also valid text for a UNC profile path. This ambiguous spelling is redacted as a UNC profile, even when its producer meant a JSON-escaped local path.
     - A relocated profile's parent folder written in its 8.3 short form, like `D:\USERPR~1\Bob`, isn't recognized.

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
- Cleanup removes only what the fixture created. Registry fixtures in `tools/validation/OptimizerCore` use `OwnedRegistryKey`, which deletes only the keys Windows reports it created. Any other delete of a fixed name (registry key, task, service, account, folder) needs the guard that proves the fixture created it, listed in `tools/validation/fixture-cleanup-allowlist.json`; `check_baseline.py` fails otherwise.
- Keep personal and test-machine identifiers (user folders, emails, private addresses, machine names) out of the repo. The baseline check fails on them.
- Keep Windows paths short. Windows PowerShell 5.1 can't open paths over 259 characters, and long user folders get close.

## Prove a change on Linux

Linux is the development host. These four Baseline jobs run for same-repository pull requests, pushes to `main` and manual runs on the self-hosted Linux runner (`runs-on: [self-hosted, laptop]`). Fork pull requests skip these jobs and need isolated local validation:

```sh
python -m pip install -r tools/validation/requirements.txt
python tools/validation/check_baseline.py   # needs the .NET 8 SDK for the Windows Tweaks read walk
python -m unittest discover -s tools/validation -p 'test_*.py'
python -I tools/validation/Update/check_publish_guard.py --local-only --out "${TMPDIR:-/tmp}/publish-guard.json"
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

For report privacy changes, run `tools/validation/BugReportE2E/Invoke-BugReportE2E.ps1` through the existing `windows_ssh.py interactive-frame` command with `Source`, `OutRoot`, `ExpectedCommit` and `Scenario=All`. Follow [the report E2E recipe](tools/validation/BugReportE2E/README.md): use a granted Windows window, the original preclaimed frame/lease and empty original-ledger output; retrieve proof before original-ledger cleanup. Linux preparation does not prove the nine disk writes or eight rendered scenes.

## How we ship

- Small PRs, one fix each, on a branch from `main`, with conventional commit subjects (`fix:`, `test:`, `docs:`).
- The PR's first line says what a user would notice.
- Reproduce a bug before fixing it, and prove the fix with a check that fails before and passes after, on the platform where the bug lives.
- Update any doc the change makes wrong. See `docs/development-workflow.md` for the full workflow.
