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

The job and launcher defaults affect other new descendants of that launcher too. The preview requires `-AcceptLauncherScope`. This implementation supports one processor group and affinities within the launcher's reviewed original mask. Close the selected game before arming a session. Game and launcher executable hashes, process creation identity, Windows user, topology, and existing registry values are verified before writes. An executable update requires a new preview.

## Operator flow

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

After a system restart, or if both worker and watcher were terminated, inspect the retained state and run:

```powershell
.\backend\scripts\Invoke-ProtectedGameSession.ps1 -Action Recover `
  -SessionRoot $sessionRoot -ConfirmApply
```

Recovery cannot take over a live worker. Create a new preview and session directory to start again after stop/recovery. The existing session's saved controls remain available for that review. Automatic logon startup is not enabled by this command.

## Validation

`backend/scripts/Test-ProtectedGameSessions.ps1` is discovered by the normal backend regression runner. It uses disposable launcher/game processes and the `RooLaunchPolicyProbe.exe` IFEO key, restoring and removing fixture state afterward. It requires permission to perform that reversible registry fixture on the selected machine.

`-HardwareGpu` additionally runs and verifies real offscreen compute on an RX9070XT. Assertions independently query the game fixture's CPU, I/O, memory, GPU and affinity values; exercise GPU reset/reapplication, live core switching, game PID changes, explicit stop, stale requests, and forced worker exit with watcher recovery. A target-specific anti-cheat denial must still be verified on that title and reported independently of fixture success.

On the RX 9070XT/i5-14600K test machine, Fortnite 42.20 and Marvel Rivals 1.1.3870120 accepted CPU Above Normal, I/O Normal, memory Normal and live P-core/E-core/all-core affinity changes. Independent scheduler traces confirmed execution stayed inside each requested mask. Fortnite also exited and relaunched under one continuously armed session. These are control-compatibility results, not evidence of an FPS improvement.

Both protected games returned `0xC0000022` from `D3DKMTGetProcessSchedulingPriorityClass`, including a read-only SYSTEM-account check. True target GPU priority was verified only on the disposable RX 9070XT workload. The game limitation remains unresolved; the session does not claim the GPU setting was applied. [Bitsum documents the same lack of GPU-priority inheritance and IFEO enforcement](https://bitsum.com/apps/process-lasso/docs/rules/priorities/).

State publication uses the shared `OperationFiles` writer. `Test-OptimizerCore.ps1 -Area operation-files` verifies replacement with an open reader, complete old/new generations, failed replacement preservation, retry, and temporary-file cleanup.
