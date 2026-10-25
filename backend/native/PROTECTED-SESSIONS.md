# Protected game sessions

`Invoke-ProtectedGameSession.ps1` provides reviewed, sustained controls for games launched from a selected launcher. Settings and recovery data remain on disk. The worker stays active until stopped, the launcher exits, or a safety check fails; a game exiting leaves the worker armed for the next instance. There is no default session timeout and the scheduled task has no execution time limit.

| Control | Route | Verification |
|---|---|---|
| Hard CPU affinity | Named Windows job containing the launcher and its new descendants | Job limit and the game's effective affinity must match |
| CPU priority | Game filename's IFEO `PerfOptions` | Actual game priority after launch |
| I/O Very low, Low and Normal; memory priority | IFEO plus temporary launcher defaults | Actual game priority after launch |
| I/O High | `NtSetInformationProcess(ProcessIoPriority)` on the launched game; the worker enables `SeIncreaseBasePriorityPrivilege` on its own token only around that write | Matching native readback and original-value journal |
| GPU scheduling priority | `D3DKMTSetProcessSchedulingPriorityClass` on the target game | Matching `D3DKMTGetProcessSchedulingPriorityClass` readback |
| Execution QoS and dynamic boosts | Native process controls | Matching native readback |

GPU priority is separate from CPU priority. A denied GPU query is reported as `unavailable`; there is no background-process substitute. The native fields are reapplied when they return to their captured original values. A different third-party value suspends that field instead of starting a policy conflict. Each new game process gets a new identity-bound snapshot and recovery journal.

When Windows provides its basic process list (`SystemBasicProcessInformation`, documented from Windows 11 26100.4770), the worker retains an ordinary GPU-control handle during launch and immediately duplicates it into the already running recovery watcher. It captures only the reviewed executable: a program with the game's file name started from another folder is left alone and doesn't end the session, even when it refuses that handle. The worker wakes when Windows reports a new process in the session job, rather than polling, and rescans the process list once a second in case a report is lost. Both actors must independently read the same original class before applying a change. They keep those handles for subsequent readback and restoration; reopening the protected game is unnecessary. Missing capture, access denial, or conflicting recovery evidence cannot authorize a setter. If the game refuses that handle, or Windows gives either copy fewer rights than requested, only that game's GPU and High I/O fields show `unavailable`; the CPU limit and launch priorities keep running. An original the watcher can't read is also `unavailable`. A program with the game's file name inside the session's launcher job that refuses even read access is listed on the session: the CPU limit still reaches it through the job and nothing else is applied to it. A missing privilege is reported the same way, never as a value another program set. An uninitialized graphics process may remain pending for up to 90 seconds. The app checks for the process list by asking Windows for it, not by comparing build numbers; without it the session keeps the fresh-handle route.

The job and launcher defaults affect other new descendants of that launcher too. The preview requires `-AcceptLauncherScope`. This implementation supports one processor group and affinities within the launcher's reviewed original mask. Close the selected game before arming a session. Game and launcher executable hashes, process creation identity, Windows user, topology, and existing registry values are verified before writes. An executable update requires a new preview.

High I/O uses the runtime journal and is never written as IFEO `IoPriority=3` or as a launcher default. Each launched instance gets its own original, including games handed off through a helper that exits. Where the launch handle is retained, it and its recovery-watcher copy also hold I/O access. Both must read the same original before the first write; they remain available if the game later denies fresh setter handles. Sessions selecting both GPU and High I/O acknowledge each control's original separately, so High I/O doesn't wait for graphics to start. Stop and watcher recovery restore the exact saved I/O value; a different value another program set stays pending for reconciliation. A game copy that inherits High from a copy this session tuned (a game restarting itself, directly or through a helper program it starts) is treated as the session's change: its saved original is that copy's original, a reset is put back, and Stop restores it. When the new copy's parent isn't a tuned copy, the most recent earlier tuned copy is the source unless the launcher itself is at High. High that comes from something the session doesn't own, such as a launcher set to High, is left as is and reported that way. Other programs the game starts, such as a crash reporter, inherit High too and keep it until they close.

The CPU cores picker offers each available last-level cache group when there is more than one, with its logical CPU numbers. Windows reports which CPUs share a last-level cache; it doesn't name CCDs, so check the groups against the CPU on a two-CCD part before relying on them. Every choice is intersected with the launcher's allowed CPUs; all allowed cores remain selected initially.

## Operator flow

In the desktop app, open Process Control → Game sessions. Close the game, select its running launcher and installed executable, choose launch priorities and a core mask, accept the launcher scope, and review the settings. **Arm session** starts the worker; launch the game normally after it reports Ready. The panel shows requested and observed values separately, permits live core switching, and offers Stop and restore or recovery after a worker exit. Saved sessions are rediscovered when the app opens, and Restore & Logs includes their actual recovery state. GPU access denial remains unavailable; it does not prevent other accepted controls from being shown individually.

Desktop session state lives under `%LOCALAPPDATA%\RooIndustriesOptimizationSuite\operations\game-session-*\session`, outside the repository. Closing the app does not stop a session. A session's task also runs at the user's sign-in, but only to recover a session whose worker died; it never arms a game.

**Save for next time** (step 3, part of the review) keeps the reviewed preview bytes as saved launch settings in `operations\launch-profile-*`. While the app is open, a check every 3 seconds looks for a new run of that launcher (same path, same Windows user). For each new run it recovers any interrupted session of those settings, builds a fresh preview and arms it only when it equals the saved review apart from the launcher process: launcher and game files, CPU topology, the launcher's original cores and I/O or memory defaults, the game's original launch priorities and the requested controls (`ProtectedSessions.ProfileMismatch`). Anything else is reported on the saved row and waits for the next launcher run. A launcher run is armed once: Stop and restore is not undone while it keeps running. **Turn off and restore** stops or recovers its sessions and then deletes the saved settings. Only the three newest restored sessions of saved settings are kept. After a restart, saved settings arm again once the app is open.

Build the native package with `backend/scripts/Build-OptimizerHost.ps1`. It includes the command host and a self-contained x64 Windows background worker in `backend/bin/optimizer/session`; the worker and recovery watcher create no console windows. Put the requested controls in a JSON file, for example:

```json
{
  "cpuPriority": "AboveNormal",
  "ioPriority": 2,
  "memoryPriority": 5,
  "affinity": { "group": 0, "mask": "0xFFF" },
  "gpuPriority": 3
}
```

The mask must describe the operator's actual CPU topology. GPU value 3 means Above Normal. A requested value does not establish that the game accepts it.

```powershell
# Read-only preview; use the actual launcher PID and installed game executable.
.\backend\scripts\Invoke-ProtectedGameSession.ps1 -Action Preview `
  -LauncherProcessId $launcherId -GamePath $gameExecutable `
  -ControlsPath $controlsFile -PreviewPath $previewFile -AcceptLauncherScope

# Pass the reviewHash returned by Preview after inspecting its scope and originals.
.\backend\scripts\Invoke-ProtectedGameSession.ps1 -Action Start `
  -PreviewPath $previewFile -ReviewHash $reviewHash -ConfirmApply

# Start the game through its normal launcher after the session becomes armed.
.\backend\scripts\Invoke-ProtectedGameSession.ps1 -Action Status -SessionRoot $sessionRoot
.\backend\scripts\Invoke-ProtectedGameSession.ps1 -Action Affinity `
  -SessionRoot $sessionRoot -AffinityMask $newMask -ConfirmApply
.\backend\scripts\Invoke-ProtectedGameSession.ps1 -Action Stop `
  -SessionRoot $sessionRoot -ConfirmApply
```

`Start` returns the session directory. An `active` state means all requested controls were observed applied in the currently tracked games. `partial` includes the per-field failure or unavailable readback. `armed` means the launch policy is ready and no tracked game is running. Check `hostRunning`, heartbeat/error, and field observations alongside the stored state. RPC envelope `completed` only means that the request completed.

## Stop and recovery

The reviewed preview bytes and original registry values are retained inside the session directory before mutation. Removing the caller's temporary preview does not remove recovery authority. Stop removes only the owned launch policy, returns launcher defaults, releases the job limit, and restores directly writable native fields. Startup priorities in an already-running protected game can remain until that game exits; those fields report `restartRequired`.

An independent watcher acknowledges the job handle before the launcher is attached or launch settings are changed. The watcher retains that handle while the worker runs and performs the same recovery after an unexpected worker exit. Recovery validates the saved preview bytes, operation identity, process creation identities, and recovery paths. It preserves conflicting external values and reports `recoveryRequired`. A stale control request cannot stop a different session.

For a captured GPU session, the watcher also retains its own game handle. If both worker and watcher exit, those handles are lost; manual recovery can still be denied while a protected game remains alive. A saved original is not proof that a new handle can restore it.

After a system restart, or if both worker and watcher were terminated, the session's task recovers it at the next sign-in, and the app recovers it when it opens and before installing an update. A missing job blocks recovery only while the old launcher or a copy of the game that still has the session's core limit is running, because only those can still be inside it. The session records which Windows start it ran in (the `BootId` Windows keeps under `PrefetchParameters`); after a restart nothing can still be inside its job, so recovery finishes even while a copy of the game runs on the same cores. To recover by hand:

```powershell
.\backend\scripts\Invoke-ProtectedGameSession.ps1 -Action Recover `
  -SessionRoot $sessionRoot -ConfirmApply
```

Recovery cannot take over a live worker. Create a new preview and session directory to start again after stop/recovery. The existing session's saved controls remain available for that review. The uninstaller runs `-Action RemoveAll`, which stops or recovers each session in the selected recovery folder and removes its task once restoration is confirmed. A blocked recovery reports failure and keeps its journal and sign-in task. Tasks belonging to another recovery folder are left alone. Failure to list or remove recovery tasks is reported as failed cleanup. Sign-in recovery, recovery retries, Stop, the uninstaller, the update check and the app all use the same completion check (`ProtectedSessions.IsRestored`, reported as `restored` in session status): restored launch policies, cleared job limits and journal-backed native controls that are restored, expired or left as is because the game already had the requested value. Missing native recovery evidence keeps recovery pending and blocks an update, including for an older session labelled stoppedWithErrors.

## Validation

`tools/scripts/Test-GameSessionClient.ps1` exercises the desktop service against the actual session worker with disposable RX9070XT workloads. It covers review-hash binding, saved-session discovery, sustained native GPU-class readback, live affinity changes, stop/restoration, and rejection of stale, missing or conflicting UI success signals. Its requested GPU and affinity controls do not write registry launch policies.

`tools/scripts/Test-GameSessionClient.ps1 -Mode launch-profiles` drives saved launch settings through the desktop service and the real worker with a probe launcher and game: saving, launcher restarts, app restarts between steps, a simulated power loss, Stop and restore, changed launch priorities and game files, pruning, idle cost and turning them off. `-Mode session-recovery` covers sign-in recovery with the app closed, recovery at app start and before an update, Recover while a new copy of the game runs, Recover after a restart while a copy pinned to the session's cores runs, and the uninstall cleanup, including already-restored journals from before data-folder protection and a game that already had the requested priority boost. `-Mode launch-profile-same-name` saves settings with GPU priority, restarts the launcher, starts a copy of the game's file from another folder while the re-armed session waits, and checks that the session keeps running and the real game still gets its saved GPU priority. `-Mode cleanup-failure` verifies that a failing scenario keeps its original assertion error and still removes its fixture state when recovery also fails. `-Mode recovery-completion` withholds a disposable game's native journal, checks that the sign-in executable retains its task and an older stoppedWithErrors session blocks updates, then returns the journal and independently verifies the restored value. It also injects a task-discovery error at the cmdlet boundary and verifies failed cleanup alongside real no-match success.

`backend/scripts/Test-ProtectedGameSessions.ps1` is discovered by the normal backend regression runner. It uses disposable launcher/game processes and the `RooIndustriesLaunchPolicyProbe.exe` IFEO key, restoring and removing fixture state afterward. While the first session is armed it starts two copies of the probe from another folder, one created with a security descriptor that refuses GPU-control handles, and checks that the session stays armed and the next real launch still gets every control. It also counts how often the session wakes to read the process list while it waits for the game and while the game runs (at most 5 times a second), and checks that each launch, including a second copy started while the game runs, is captured within 50 ms. It requires permission to perform that reversible registry fixture on the selected machine.

The client suite uses the runtime selected with `-DotNetPath` for its fixture apphosts and checks the runtime loaded by a child. Run it with a non-default .NET installation to verify that selection. The wrapper restores the caller's runtime environment when it finishes. The `cleanup-failure` mode also checks a missing second fixture copy and a standalone probe that never publishes game readiness; each failure must preserve its original error and leave no fixture copies, folders, processes, policies or tasks.

A native field retains its preview hash before Apply. If its journal is missing and the field is pending or conflicted, recovery can acknowledge an unchanged live value only after checking the retained preview's bytes, owner, process identity, requested control and original value, then independently reading that same original from the process. The latest observation alone is insufficient. An applied field, unknown value or older record without that preview authority stays pending while its game lives. Once that exact process has ended, recovery can expire its missing native field without writing a replacement value. Registry and job restoration still need their own completion checks. The `recovery-completion` mode covers differing current values, changed preview bytes, unchanged live values, and missing authority across game exit.

`-HardwareGpu` additionally runs and verifies real offscreen compute on an RX9070XT. Assertions independently query the game fixture's CPU, I/O, memory, GPU and affinity values; exercise GPU reset/reapplication, live core switching, game PID changes, explicit stop, stale requests, and forced worker exit with watcher recovery. A target-specific anti-cheat denial must still be verified on that title and reported independently of fixture success.

`Test-ProtectedGameSessions.ps1 -HighIo` exercises the Processes apply/Undo path, a launcher handing off through an exiting helper, sustained High I/O and a cache-group affinity restriction, game relaunch, original-value reset, foreign values, Stop and worker-death recovery. Where Windows provides the basic process list, it denies fresh setter handles on the disposable game before reapplication, Stop and watcher recovery. A game that refuses every setter handle from its start keeps the CPU limit while only I/O shows unavailable. `-InspectSeconds 60` leaves the first active probe available for Task Manager affinity and Process Explorer I/O inspection. The generic checks need at least two allowed logical CPUs; the first-cache-group check needs a CPU with more than one last-level cache group. This suite needs no GPU workload.

`-HighIo -RetainedGpu` adds High I/O to the positive retained-GPU scenarios on the RX9070XT fixture. It checks independent GPU and I/O originals, I/O reset through the retained handle, and exact I/O recovery on Stop, controller death, watcher death and a foreign GPU value. GPU recovery-authority rejection scenarios keep their existing GPU-only inputs.

`-RetainedGpu` runs GPU-only sessions against disposable RX9070XT workloads that deny new `PROCESS_SET_INFORMATION` handles after capture. Its 69 runtime assertions cover actual class changes after access is denied, sustained readback, original-value reset, controller and watcher termination, third-party values, missing/conflicting/stale recovery authority, and fixture cleanup after a controlled failure. Seven additional checks verify initialization decisions for recent/expired status, missing evidence, access denial, and other APIs/status namespaces. A full 90-second native initialization timeout was not reproduced by delaying rendering-device creation; the timeout check establishes the decision boundary only. This mode does not write IFEO values. The broader hardware regression passes 39 assertions, including a new game instance under the same persistent session.

On the RX 9070XT/i5-14600K test machine, Fortnite 42.20 and Marvel Rivals 1.1.3870120 accepted CPU Above Normal, I/O Normal, memory Normal and live P-core/E-core/all-core affinity changes. Independent scheduler traces confirmed execution stayed inside each requested mask. Fortnite also exited and relaunched under one continuously armed session. These are control-compatibility results, not evidence of an FPS improvement.

The integrated retained-handle route changed Marvel Rivals 1.1.3870120 from actual GPU class 2 to 3 on that machine, continued through login and Practice Range, and independently restored class 2 after controller termination while the same game remained alive. Fresh-handle queries still returned `0xC0000022`. This establishes the tested launch, not arbitrary timing reliability, performance gains, or publisher endorsement.

Fortnite's controller and recovery handles both returned `0xC0000022` in the integrated session. Its field remained `unavailable`, with no original, no GPU mutation journal and no setter. Fortnite GPU-class control remains unresolved. [Full API investigation](../../docs/research/official-gpu-priority.md), [Fortnite access evidence](../../docs/research/fortnite-gpu-class-initialization.md).

State publication uses the shared `OperationFiles` writer. `Test-OptimizerCore.ps1 -Area operation-files` verifies replacement with an open reader, complete old/new generations, failed replacement preservation, retry, and temporary-file cleanup.
