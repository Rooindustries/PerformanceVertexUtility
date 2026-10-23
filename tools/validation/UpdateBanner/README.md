# Update banner install checks

`Invoke-UpdateBannerUi.ps1` drives a test-hooks Debug build of the desktop app on a Windows test PC and checks what the update banner and Settings show when an install can't start. It never contacts an update feed, never downloads or runs setup, and never changes a PC setting.

Stage a fresh frame with `--include-frontend` under `C:\RooBuild`, then run it through the existing interactive route on a signed-in, unlocked desktop with no other app window open:

```sh
python3 -I tools/validation/windows_ssh.py --host <test-pc> --expected-machine <COMPUTERNAME> upload-frame --include-frontend --parent 'C:\RooBuild' --directory roo-industries-ub > receipt.json
arguments=$(jq -c '{Source:.stagingPath,OutRoot:(.runRoot+"\\results"),Label:"after"}' receipt.json)
python3 -I tools/validation/windows_ssh.py --host <test-pc> --expected-machine <COMPUTERNAME> interactive-frame --receipt receipt.json --script tools/validation/UpdateBanner/Invoke-UpdateBannerUi.ps1 --arguments "$arguments" --minutes 30
```

The script takes the frame's host lease first and fails if another frame holds it; wait and retry. After copying `<OutRoot>\<Label>.zip`, release the lease and remove the frame with `tools/validation/Update/Clear-UpdateFrame.ps1 -Frame <runRoot> -ExpectedMachine <COMPUTERNAME>` through `windows_ssh.py run`.

The script builds the helper and the app with `RooIndustriesTestHooks=true` inside the staged copy. Three hooks exist only in that build:

- `ROO_INDUSTRIES_TEST_UPDATE_READY` makes the app show a ready fixture release instead of checking a feed. Its confirmation never starts setup.
- `ROO_INDUSTRIES_TEST_HOLD_CHANGE` names a flag file. While it exists, the app holds a running change open, the same marker a removal, Windows settings apply or cleanup sets.
- `ROO_INDUSTRIES_TEST_INSTALL_FREE_BYTES` replaces the install drive's free bytes.

Cases, each read back through UI Automation:

- Low disk space: Install now leaves the banner naming the space to free, and Settings shows the same text.
- A change running: Install now never opens the confirmation; the banner and Settings both say a change is still running and both install buttons wait, disabled.
- The change finishing: both buttons come back and the banner returns to the release notes.
- Nothing running: Install opens the confirmation (Not now is pressed), or the banner and Settings name another blocker on that PC.
- Later still hides the banner.
- Closing the window while a change runs asks instead of closing; Keep open leaves the app running, and with nothing running the window closes at once.

Results, screenshots and frames for the video land in `<OutRoot>\<Label>` and `<OutRoot>\<Label>.zip`. Screenshots are cropped to the app window, and Settings shots stop below the Updates panel so the log folder path isn't captured. The script stops only the app process it started, and every folder it builds into is recorded in the frame ledger so frame cleanup removes it.
