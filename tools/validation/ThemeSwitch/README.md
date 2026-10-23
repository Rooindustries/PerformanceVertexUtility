# Theme switch keeps work in progress

Changing the theme in Settings must not rebuild the window. Picks, open reviews and a change that is still running stay on their pages, and every page shows the new theme's colors.

Run it from a clean, committed worktree on Linux against a Windows test PC that has the app installed and closed:

```sh
python3 -I tools/validation/ThemeSwitch/run_theme.py --host <test-pc> --expected-machine <COMPUTERNAME> --out-dir <new-artifact-directory>
```

The driver stages a source frame, waits for the shared host lease, runs `Invoke-ThemeSwitch.ps1` in the signed-in desktop session, downloads the evidence, clears the frame and encodes the video. It exits 0 only when every check passes.

The script builds the app and its helper from the staged source with test hooks, then drives the real app with UI Automation. It never applies anything to the PC except one process priority change on a disposable copy of `PING.EXE`, which the Games page undoes. It saves the user's `settings.json` before starting and writes the original bytes back at the end. The build points the Windows App SDK's packaging folder at a short path, because the default one inside a staged frame passes the 259-character limit. The fixture is set to Normal priority right after it starts, since the interactive task runs below normal and its children inherit that. Dropdown choices go through `tools/validation/UiAutomation/ComboChoice.Common.ps1`, which finds the item even when the long process list hasn't drawn it yet and checks the dropdown really took the choice.

| Way it can fail | Check |
| --- | --- |
| The window is rebuilt and every page starts over | Same window handle after each switch |
| Picks are lost | Remove apps keeps both picked apps; Windows tweaks keeps its search and picked change |
| An open review is lost | Remove apps keeps its removal review |
| A running change is hidden | The switch happens while a process change is paused in the helper; Games then shows its result with Undo, and Undo restores the fixture |
| Switching back loses work | The same checks after Blackout Gold to Blue |
| Stale colors | Every page is captured after each switch and compared with a fresh launch in the same theme: no accent pixels of the other theme may remain |
| Blue keeps Blackout Gold's Windows accent colors (checked boxes and other standard controls stay gold) | With test hooks the app writes its theme dictionary's own keys to `evidence/theme-keys.tsv` at startup and after every switch. Under Blue no `SystemAccentColor*` key may remain, both after Blackout Gold to Blue and after a restart with Blue saved; under Blackout Gold all seven must be there |
| The theme isn't kept | `settings.json` holds the last choice and a restart opens in it |

Screenshots and video frames black out any text that contains the Windows account name, PC name or profile path. Settings shows the log folder, so the video masks it on the frames where Settings is visible.

Evidence: `evidence/summary-*.json` (checks, screenshots with accent pixel counts), `evidence/theme-keys.tsv` (when, theme and keys of each repaint), `evidence/*.png` (`fresh-blue`, `switched-gold`, `switched-blue`, `fresh-gold`, and the open process review), `theme-switch.mp4` and `result.json`.
