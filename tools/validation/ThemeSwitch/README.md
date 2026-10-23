# Theme switch keeps work in progress

Changing the theme in Settings must not rebuild the window or close the app. Picks, open reviews and a change that is still running stay on their pages, and every page shows the new theme's colors.

Run it from a clean, committed worktree on Linux against a Windows test PC that has the app installed and closed:

```sh
python3 -I tools/validation/ThemeSwitch/run_theme.py --host <test-pc> --expected-machine <COMPUTERNAME> --out-dir <new-artifact-directory>
```

The driver stages a source frame, waits for the shared host lease, runs `Invoke-ThemeSwitch.ps1` in the signed-in desktop session, downloads the evidence, clears the frame and encodes the video. It exits 0 only when every check passes. `--fail-before-undo` stops the run on purpose after the first session's switches, before Undo, to prove the cleanup below; that run always fails.

The script builds the app and its helper from the staged source with test hooks, then drives the real app with UI Automation. It never applies anything to the PC except a process priority change on a disposable copy of `PING.EXE`, which the Games page undoes. It saves the user's `settings.json` before starting and writes the original bytes back at the end. The build points the Windows App SDK's packaging folder at a short path, because the default one inside a staged frame passes the 259-character limit. The fixture is set to Normal priority right after it starts and at the start of each session, since the interactive task runs below normal and its children inherit that. Dropdown choices go through `tools/validation/UiAutomation/ComboChoice.Common.ps1`, which finds the item even when the long process list hasn't drawn it yet and checks the dropdown really took the choice.

The run opens the app once per theme, with that theme saved, so each theme is tried both as the one loaded at startup and as one switched to later. In each session it picks two apps and opens their removal review, picks a Windows tweak, applies the process change, then switches from the start theme to every other theme and back. The first switch happens while the change is still running. After each switch it checks that the app is still open, then runs the checks below. After Undo it switches to the next session's theme, if there is one, and closes the app.

| Way it can fail | Check |
| --- | --- |
| A switch closes the app (a theme adds a resource the previous one didn't have) | Every theme to every other theme and back, from a fresh start in each: the app stays open, and one check fails unless every one of these switches passed all of its checks |
| The window is rebuilt and every page starts over | Same window handle after each switch |
| Picks are lost | Remove apps keeps both picked apps; Windows tweaks keeps its search and picked change |
| An open review is lost | Remove apps keeps its removal review |
| A running change is hidden | The first switch of each session happens while a process change is paused in the helper; Games then shows its result with Undo after every switch, and Undo restores the fixture |
| Stale colors | Every page is captured after each switch and compared with a fresh launch in the same theme: no accent pixels of the other theme may remain |
| Blue keeps Blackout Gold's Windows accent colors (checked boxes and other standard controls stay gold) | With test hooks the app writes its theme dictionary's own keys to `evidence/theme-keys.tsv` at startup and after every switch. Under Blue no `SystemAccentColor*` key may remain, after every switch to Blue and after a restart with Blue saved; under Blackout Gold all seven must be there |
| The theme isn't kept | `settings.json` holds the last choice and the next start opens with it picked |
| A new theme isn't covered | The Settings theme list must offer exactly the themes the run switches between |
| A failed run leaves app records behind | Before starting, the run lists the app's `operations` folder and saves `process-active.txt`. At the end, even after a failure, it deletes only new `process-*` folders whose preview names this run's fixture (after the fixture has stopped) and new `removal-*` folders that hold only a preview. It writes back the original `process-active.txt`, or deletes it when it didn't exist and now names a folder the run deleted. Anything else new is kept and fails the run |

Screenshots and video frames black out any text that contains the Windows account name, PC name or profile path. Settings shows the log folder, so the video masks it on the frames where Settings is visible.

Evidence: `evidence/summary-*.json` (checks, every switch and whether it passed, the operations cleanup, screenshots with accent pixel counts), `evidence/theme-keys.tsv` (when, theme and keys of each repaint), `evidence/*.png` (`fresh-<theme>`, `switched-<theme>-from-<start theme>` and each session's open process review), `theme-switch.mp4` (the first session's first switch) and `result.json`.
