# App tour

Run the interactive upgrade and read-only tour by name from a clean, committed worktree:

```sh
python3 -I tools/validation/Tour/run_tour.py --scenario full \
  --host <test-pc> --expected-machine <COMPUTERNAME> \
  --installer <candidate.exe> --sha256 <candidate-sha256> --version <version> \
  --restore-installer <as-found-release.exe> --restore-sha256 <release-sha256> \
  --out-dir <new-artifact-directory>
```

The PC must have an installed, closed Suite and paused saved process rules, with a signed-in desktop whose working area contains 1600×1000 pixels. The driver takes a host lease, verifies both installers before staging, saves both data roots and raw tweak-registry bytes, and uses the shared native process/creation ledger. It restores the as-found installer, appearance, data and registry, and audits tasks, legacy frames, processes, firewall, hosts, certificates and the lease.

The wizard uses an owned out-of-process ShellExecute launcher. SmartScreen is recorded and fails the run; it is never clicked. The ordinary Open File security warning is accepted only for that owned launcher. Finish enables Open app and clears the optional guide launch, with native accessibility state readback. Checklist rows use their native accessibility rectangles inside the verified UIA checklist. The app starts through the owned setup chain.

The tour allows navigation, page tabs, tweak-section selection, scrolling, expanders, the appearance theme and Simple mode controls, Open BIOS settings and its Back button. It does not activate operations or change tweak, game, process, update or report settings. Cursor movement is smooth; FromPoint must resolve to the intended AutomationId or Name, runtime identity and process before SendInput clicks. An unnamed decorative visual may resolve through its UIA ancestors, stopping at any other interactive control; the full ancestry proof is recorded. Only navigation can fall back to SelectionItemPattern.Select, and the receipt records that fallback.

Pass A uses the original theme in Simple mode. Pass B shows advanced pages and tabs. Pass C uses Blackout Gold and captures the top of every page/tab/section. Hidden tabs and operation-dependent states are listed in index.md. Each long page is scrolled through its content ScrollPattern, with overlapping screenshots.

No recording software is installed on Windows. If ffmpeg is unavailable there, the interactive recorder captures DWM frame bounds at 15 fps with the real cursor drawn; Linux ffmpeg encodes H.264/yuv420p/CRF20/faststart. Covered or absent owned windows are skipped. PNG screenshots omit the cursor. The artifact contains screenshots, installer and app MP4s, three contact sheets, an index, nonce-bound UIA/cursor receipts, raw-frame evidence.zip and the cleanup audit. Media stays outside Git.

Failure ways checked by the run: a foreign app/setup or lease refuses before mutation; an unexpected wizard dialog stops; a wrong cursor target is never clicked; changed checklist labels or states refuse input; a hidden tab is recorded; an empty section list or stalled scroll fails rather than claiming coverage; source, nonce or media identity mismatch refuses reuse; recording errors fail; cleanup errors fail and keep rollback evidence. Tool/cmdlet paths use the short plain-path boundary and native file access uses extended paths. The app's automatic startup update check is a production read-only GET; this tour never presses Check or downloads an update.
