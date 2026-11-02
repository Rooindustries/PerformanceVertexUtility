# Game priority review check

`Invoke-GameTuneReviewUi.ps1` drives the real desktop app through UI Automation. It starts a disposable `Overwatch.exe` probe (a copy of Windows PowerShell), clicks **Review** on the Game priority card, closes that probe, starts a second `Overwatch.exe` probe from another folder and clicks **Start**. It passes only when Start leaves the second probe's priority as it was just before Start and the card says "Not started" with the closed-or-restarted reason. On a build without review binding it fails, because Start tunes the second probe; the script then clicks **Restore** to put it back.

While it runs, the staged `backend\profiles\game-session.profile.json` boosts only `Overwatch.exe` and has no background rules, so no real app changes priority. The original bytes are written back in `finally`. The script refuses to run when the app or a process named Overwatch is already running, and removes the review file it created under the app's settings folder.

Stage a frame with the desktop sources, build the app in it, then run the check in the signed-in desktop session. When no .NET is installed for the whole PC, the check starts the app with the user's `.dotnet` folder as `DOTNET_ROOT`:

```sh
python3 -I tools/validation/windows_ssh.py --host <test-pc> --expected-machine <COMPUTERNAME> upload --directory roo-industries-game-tune-ui --parent '<staging-parent>' --include-frontend > frame.json
python3 -I tools/validation/windows_ssh.py --host <test-pc> --expected-machine <COMPUTERNAME> interactive --receipt frame.json --script tools/scripts/Build-Frontend.ps1 --minutes 30
python3 -I tools/validation/windows_ssh.py --host <test-pc> --expected-machine <COMPUTERNAME> interactive --receipt frame.json --script tools/validation/GameTune/Invoke-GameTuneReviewUi.ps1 --arguments '{"Source":"<stagingPath>","OutRoot":"<runRoot>\\ui","AppExe":"<stagingPath>\\docs\\internal\\frontend\\RooIndustries.OptimizationSuite.App\\bin\\...\\RooIndustries.OptimizationSuite.App.exe"}' --minutes 15
```

`OutRoot` receives window screenshots (`01-before-review`, `02-reviewed`, `03-after-start`, plus `04-restored` on a failing build), the card text beside each one, `after-start.json` with the second probe's priority just before and after **Start**, `result.json` with each probe's priority, `cleanup.json`, and JPEG frames for the video under `frames`.

## Recovery and Stop ownership

The recovery suite also has a Linux-compatible mode:

```sh
pwsh -NoProfile -File backend/scripts/Test-GameTuneRecovery.ps1 -InMemory -OutRoot '<evidence-directory>'
```

It runs the real recovery, Stop and status scripts against saved session files with in-memory process adapters. It checks foreign writes between recovery preflight and Stop preview, before each restore and at the setter's final read; all five controls, pending and failed writes, partial restores, already restored values, missing saved values and read-only previews; pending and failed writes another program now holds, in Stop's preview and in interrupted-session recovery, where each held setting must be left alone, keep the session recoverable and be named with its exact reason; and repeated upgrade refreshes with an older running record and a newer Restore. `result.json` records each assertion, control write, result and saved journal. These checks do not change real process controls or replace the Windows recovery suite.

To compare another source revision, run `tools/validation/GameTune/Test-GameTuneRecoveryOwnership.ps1 -Source '<source-copy>' -Out '<evidence-directory>'`. `-Scenario RecoveryRace`, `ManualRace`, `Controls`, `Unconfirmed` or `LegacySelection` selects one group.

## Recovery names the held setting

`Invoke-GameTuneRecoveryUi.ps1` checks the same refusal in the real app. It starts a disposable `cs2.exe` probe (a copy of Windows PowerShell), tunes it with a real Game priority session, ends that session's controller as a crash would, marks the saved write as unconfirmed and raises the probe to High as another program would. It then opens the app on the Games page. It passes only when the Game priority card says "Needs attention" and names CPU priority for cs2.exe with what happens next, while the probe stays at High and the session keeps its Restore. It refuses to run while the app or a process named cs2 is running, or while the staged backend state isn't empty, and removes the session it created.

Run it the same way as the review check. The app reads the backend named by `Source` (through `ROO_INDUSTRIES_BACKEND_ROOT`), so one build can check another source frame. `OutRoot` receives `01-recovery.png`, the card text beside it, `result.json` and `cleanup.json`.
