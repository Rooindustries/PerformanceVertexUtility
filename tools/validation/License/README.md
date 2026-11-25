# License notice rows

`Invoke-LicenseRows.ps1` builds the release from a staged frame and drives the real app and the real setup program through UI Automation on a Windows test PC.

- A1: opens the built app, selects Settings in the navigation and reads the About panel. It passes when the product name, the version line, the copyright line and the source line follow each other in that order, each matching its whole text.
- S1: starts the built setup with no arguments, the way a user does, and presses Next page by page until the page with Install. It passes when an earlier page shows the whole text of `LICENSE` (line ends aside) with Next and no accept choice. It then presses Cancel and Yes, so nothing is installed.

The build copies the frame's source next to it and raises only the app project's Version line, because `Build-Release.ps1` refuses a version that is already released. The release is built without an update feed, so the app never goes online.

Each row reports passed, failed, invalid (its start, action or observation could not be read) or not run. The script exits 0 only when every row passed. It refuses to start while another app window or setup is open, stops only what it started, and treats any change to the install state as invalid.

Stage a frame with `--include-frontend` under `C:\RooBuild` and run it through the interactive route on a signed-in, unlocked desktop:

```sh
python3 -I tools/validation/windows_ssh.py --host <test-pc> --expected-machine <COMPUTERNAME> upload-frame --include-frontend --parent 'C:\RooBuild' --directory roo-industries-lic > receipt.json
arguments=$(jq -c '{Source:.stagingPath,OutRoot:(.runRoot+"\\results"),Label:"head",Rows:["A1","S1"]}' receipt.json)
python3 -I tools/validation/windows_ssh.py --host <test-pc> --expected-machine <COMPUTERNAME> interactive-frame --receipt receipt.json --script tools/validation/License/Invoke-LicenseRows.ps1 --arguments "$arguments" --minutes 75
```

Results land in `<OutRoot>\<Label>\results.json`, with the release build log and the layout's file list next to it. Then remove the frame with `tools/validation/Update/Clear-UpdateFrame.ps1 -Frame <runRoot> -ExpectedMachine <COMPUTERNAME>` through `windows_ssh.py run`.
