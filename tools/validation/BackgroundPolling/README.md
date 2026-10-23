# Background polling

The Games and Processes panels read live status every 2 seconds. Each read starts a new `Optimizer.Host` process. This suite proves the reads stop while the app window sits behind another window, and that the panel catches up when the user comes back.

It builds the app from the staged source (framework-dependent .NET, self-contained Windows App SDK, so it never runs as an installed copy), starts it next to a maximized probe window it owns, and counts the app's child host processes by their real creation time (`GetProcessTimes`), read by a 10 ms process snapshot loop that also records each child's action from its command line. `Win32_ProcessStartTrace` is the cross-check: its timestamps can trail the real start by more than a second, so they never place a start in a window, but a traced start the loop missed or couldn't time fails every case whose window could hold it. Focus changes are confirmed with `GetForegroundWindow`, and an inactive window starts timing 0.5 s after that. The foreground window is sampled every 100 ms while a window is timed; a case fails if the app comes to the front during an inactive window or another copy of the app appears, since the desktop is shared.

Cases and the counts they require:

| Case | Window | Host starts |
| --- | --- | --- |
| `games-active-baseline` | app in front, 10 s | 3 to 8 |
| `games-inactive` | probe in front, 60 s | 0 |
| `games-reactivated-once` | app in front 1.2 s, then probe 5 s | exactly 1 |
| `games-read-in-flight-at-deactivation` | probe brought forward while a read is still running, then 10 s | 0 after the switch |
| `games-quick-toggles` | ten 300 ms app/probe toggles, then probe 6 s | 1 to 4 |
| `games-minimized` | app minimized, 20 s | 0 |
| `games-restored` | restore from minimized, 3 s | 1 to 3 |
| `games-session-ended-while-inactive` | probe in front while the probe launcher exits and the session stops itself | 0, and the panel shows the stopped session within 3 s of coming back |
| `processes-active-baseline` | Processes tab, probe process selected, app in front 10 s | 3 to 8 |
| `processes-inactive` | probe in front, 60 s | 0 |
| `processes-reactivated-once` | app in front 1.2 s, then probe 5 s | exactly 1 |

`games-minimized`, `games-restored` and the panel text in `games-session-ended-while-inactive` also pass on builds that poll in the background; they guard the minimized path and the catch-up read.

The game session uses a renamed copy of `PING.EXE` as its launcher and another as the game, with every priority on "Keep current". The session is started through the app, ended by stopping the owned launcher, then stopped and recovered through `Invoke-ProtectedGameSession.ps1`, which removes its scheduled task. The run deletes only the `game-session-*` operation folders whose preview names its own game copy. The Processes case only selects an owned probe process; it never previews or applies. Dropdown choices go through `tools/validation/UiAutomation/ComboChoice.Common.ps1`, which finds the item even when the long process list hasn't drawn it yet and checks the dropdown really took the choice.

The run refuses to start while another app process is open or `C:\RooBuild\host-lease.json` names a live frame. When other runs share the PC, hold the lease with a frame of your own (`upload-frame`, then `Enter-HarnessHostLease` from `tools/validation/Update/Harness.Common.ps1`), pass its frame id as `LeaseFrame`, and clear that frame with `Clear-UpdateFrame.ps1` afterwards; the run then refuses unless that frame holds the lease. It needs an elevated, signed-in, unlocked desktop. Stage a fresh frame for each commit and run it through the interactive task:

```sh
python3 -I tools/validation/windows_ssh.py --host <test-pc> --expected-machine <COMPUTERNAME> upload --directory roo-industries-background-polling --parent 'C:\RooBuild' --include-frontend > "$receipt"
arguments=$(jq -c '{Source:.stagingPath,OutRoot:(.runRoot+"\\evidence")}' "$receipt")
python3 -I tools/validation/windows_ssh.py --host <test-pc> --expected-machine <COMPUTERNAME> interactive \
  --receipt "$receipt" --script tools/validation/BackgroundPolling/Invoke-BackgroundPolling.ps1 \
  --arguments "$arguments" --minutes 30
```

The run ends with `ROO_INDUSTRIES_BACKGROUND_POLLING_PASS` or lists the failed cases. Evidence in `evidence\background-polling` holds `cases.json`, `focus.json`, `children.json` (the loop's children with real creation times, and the traced starts), `session-cleanup.json`, build logs and app-window screenshots. Copy it with SCP, then remove the frame.
