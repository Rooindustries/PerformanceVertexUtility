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

It runs the real recovery, Stop and status scripts against saved session files with in-memory process adapters. It checks foreign writes between recovery preflight and Stop preview, before each restore and at the setter's final read; all five controls, pending and failed writes, partial restores, already restored values, missing saved values and read-only previews; and repeated upgrade refreshes with an older running record and a newer Restore. `result.json` records each assertion, control write, result and saved journal. These checks do not change real process controls or replace the Windows recovery suite.

To compare another source revision, run `tools/validation/GameTune/Test-GameTuneRecoveryOwnership.ps1 -Source '<source-copy>' -Out '<evidence-directory>'`. `-Scenario RecoveryRace`, `ManualRace`, `Controls` or `LegacySelection` selects one group.

## Recovery names the held setting

On Windows, `backend/scripts/Test-GameTuneRecovery.ps1` (without `-InMemory`) runs recovery on disposable probe processes with the real setter and readbacks. Beside the crash cases it covers settings another program holds after a crash: a pending CPU, GPU and memory priority write, a failed write next to a confirmed one, a confirmed GPU priority write Windows can't read back (the probe's access rules deny the read), and a held setting followed by an app whose identity can't be checked. Each must be left alone, keep Restore and be named with its exact reason, and Restore's preview must block the same settings without a write.

`Invoke-GameTuneRecoveryUi.ps1` checks the refusal in the real app. It starts a disposable `cs2.exe` probe (a copy of Windows PowerShell), tunes it with a real Game priority session and ends that session's controller as a crash would. `-Scenario Held` (the default) then marks the saved write as unconfirmed and raises the probe to High as another program would. `-Scenario Governor` saves the recovery result for a CPU priority a Governor rule holds; it doesn't create a Governor rule. The check opens the app on the Games page and passes only when the Game priority card says "Needs attention" and names CPU priority for cs2.exe with what to do next, while the probe keeps its value and the session keeps its Restore. It refuses to run while the app or a process named cs2 is running, or while the staged backend state isn't empty, removes the session it created and fails if the app left anything in the backend state.

Run it the same way as the review check. The app reads the backend named by `Source` (through `ROO_INDUSTRIES_BACKEND_ROOT`), so one build can check another source frame. `OutRoot` receives `held.png` or `governor.png`, the card text beside it, `result.json` and `cleanup.json`.
