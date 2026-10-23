# Protected game sessions

`Invoke-ProtectedGameSession.ps1` provides reviewed, sustained controls for games launched from a selected launcher. Settings and recovery data remain on disk. The worker stays active until stopped, the launcher exits, or a safety check fails; a game exiting leaves the worker armed for the next instance. There is no default session timeout and the scheduled task has no execution time limit.

| Control | Route | Verification |
|---|---|---|
| Hard CPU affinity | Named Windows job containing the launcher and its new descendants | Job limit and the game's effective affinity must match |
| CPU priority | Game filename's IFEO `PerfOptions` | Actual game priority after launch |
| I/O and memory priority | IFEO plus temporary launcher defaults | Actual game priority after launch |
| GPU scheduling priority | `D3DKMTSetProcessSchedulingPriorityClass` on the target game | Matching `D3DKMTGetProcessSchedulingPriorityClass` readback |
| Execution QoS and dynamic boosts | Native process controls | Matching native readback |

GPU priority is separate from CPU priority. A denied GPU query is reported as `unavailable`; there is no background-process substitute. The native fields are reapplied when they return to their captured original values. A different third-party value suspends that field instead of starting a policy conflict. Each new game process gets a new identity-bound snapshot and recovery journal.

On Windows 11 build 26100.4770 or later, the worker retains an ordinary GPU-control handle during launch and immediately duplicates it into the already running recovery watcher. Both actors must independently read the same original class before applying a change. They keep those handles for subsequent readback and restoration; reopening the protected game is unnecessary. Missing capture, access denial, or conflicting recovery evidence cannot authorize a setter. An uninitialized graphics process may remain pending for up to 90 seconds. Earlier Windows builds retain the original fresh-handle route.

The job and launcher defaults affect other new descendants of that launcher too. The preview requires `-AcceptLauncherScope`. This implementation supports one processor group and affinities within the launcher's reviewed original mask. Close the selected game before arming a session. Game and launcher executable hashes, process creation identity, Windows user, topology, and existing registry values are verified before writes. An executable update requires a new preview.

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

After a system restart, or if both worker and watcher were terminated, the session's task recovers it at the next sign-in, and the app recovers it when it opens and before installing an update. A missing job blocks recovery only while the old launcher or a copy of the game that still has the session's core limit is running, because only those can still be inside it. To recover by hand:

```powershell
.\backend\scripts\Invoke-ProtectedGameSession.ps1 -Action Recover `
  -SessionRoot $sessionRoot -ConfirmApply
```

Recovery cannot take over a live worker. Create a new preview and session directory to start again after stop/recovery. The existing session's saved controls remain available for that review. The uninstaller runs `-Action RemoveAll`, which stops or recovers each of the user's sessions and removes their tasks.

## Validation

`tools/scripts/Test-GameSessionClient.ps1` exercises the desktop service against the actual session worker with disposable RX9070XT workloads. It covers review-hash binding, saved-session discovery, sustained native GPU-class readback, live affinity changes, stop/restoration, and rejection of stale, missing or conflicting UI success signals. Its requested GPU and affinity controls do not write registry launch policies.

`tools/scripts/Test-GameSessionClient.ps1 -Mode launch-profiles` drives saved launch settings through the desktop service and the real worker with a probe launcher and game: saving, launcher restarts, app restarts between steps, a simulated power loss, Stop and restore, changed launch priorities and game files, pruning, idle cost and turning them off. `-Mode session-recovery` covers sign-in recovery with the app closed, recovery at app start and before an update, Recover while a new copy of the game runs and the uninstall cleanup.

`backend/scripts/Test-ProtectedGameSessions.ps1` is discovered by the normal backend regression runner. It uses disposable launcher/game processes and the `RooIndustriesLaunchPolicyProbe.exe` IFEO key, restoring and removing fixture state afterward. It requires permission to perform that reversible registry fixture on the selected machine.

`-HardwareGpu` additionally runs and verifies real offscreen compute on an RX9070XT. Assertions independently query the game fixture's CPU, I/O, memory, GPU and affinity values; exercise GPU reset/reapplication, live core switching, game PID changes, explicit stop, stale requests, and forced worker exit with watcher recovery. A target-specific anti-cheat denial must still be verified on that title and reported independently of fixture success.

`-RetainedGpu` runs GPU-only sessions against disposable RX9070XT workloads that deny new `PROCESS_SET_INFORMATION` handles after capture. Its 69 runtime assertions cover actual class changes after access is denied, sustained readback, original-value reset, controller and watcher termination, third-party values, missing/conflicting/stale recovery authority, and fixture cleanup after a controlled failure. Seven additional checks verify initialization decisions for recent/expired status, missing evidence, access denial, and other APIs/status namespaces. A full 90-second native initialization timeout was not reproduced by delaying rendering-device creation; the timeout check establishes the decision boundary only. This mode does not write IFEO values. The broader hardware regression passes 39 assertions, including a new game instance under the same persistent session.

On the RX 9070XT/i5-14600K test machine, Fortnite 42.20 and Marvel Rivals 1.1.3870120 accepted CPU Above Normal, I/O Normal, memory Normal and live P-core/E-core/all-core affinity changes. Independent scheduler traces confirmed execution stayed inside each requested mask. Fortnite also exited and relaunched under one continuously armed session. These are control-compatibility results, not evidence of an FPS improvement.

The integrated retained-handle route changed Marvel Rivals 1.1.3870120 from actual GPU class 2 to 3 on that machine, continued through login and Practice Range, and independently restored class 2 after controller termination while the same game remained alive. Fresh-handle queries still returned `0xC0000022`. This establishes the tested launch, not arbitrary timing reliability, performance gains, or publisher endorsement.

Fortnite's controller and recovery handles both returned `0xC0000022` in the integrated session. Its field remained `unavailable`, with no original, no GPU mutation journal and no setter. Fortnite GPU-class control remains unresolved. [Full API investigation](../../docs/research/official-gpu-priority.md), [Fortnite access evidence](../../docs/research/fortnite-gpu-class-initialization.md).

State publication uses the shared `OperationFiles` writer. `Test-OptimizerCore.ps1 -Area operation-files` verifies replacement with an open reader, complete old/new generations, failed replacement preservation, retry, and temporary-file cleanup.
