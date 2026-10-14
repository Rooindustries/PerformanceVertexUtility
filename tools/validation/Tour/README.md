# App tour

Run the read-only app tour by name from a clean, committed worktree:

```sh
python3 -I tools/validation/Tour/run_tour.py --scenario full \
  --host <test-pc> --expected-machine <COMPUTERNAME> \
  --installer <candidate.exe> --sha256 <candidate-sha256> --version <version> \
  --installer-media <accepted-installer-capture-directory> \
  --restore-installer <as-found-release.exe> --restore-sha256 <release-sha256> \
  --out-dir <new-artifact-directory>
```

The accepted installer directory contains source-binding.json, installer/*.png, installer.mp4, installer-video.json and the retained first Home screenshot. Its candidate identity must match the supplied installer. This run reuses the accepted interactive wizard capture, upgrades the candidate silently over the as-found release, and launches its own app. The installer launcher script remains available for the original separate wizard workflow.

The PC must have an installed, closed Suite and paused saved process rules, with a signed-in desktop whose working area contains 1600×1000 pixels. The driver takes a host lease, verifies both installers before staging, saves both data roots and raw tweak-registry bytes, and uses the shared native process/creation ledger. It restores the as-found installer, appearance, data and registry, and audits tasks, legacy frames, processes, firewall, hosts, certificates and the lease. SmartScreen is never clicked.

App actions find a unique exact AutomationId, or exact Name inside the expected parent under the owned window. The real cursor glides to that element; no mouse click is sent. Sidebar navigation, page tabs and tweak sections use SelectionItemPattern. BIOS Open/Back use InvokePattern. The theme picker uses ExpandCollapsePattern and its two items use SelectionItemPattern. Simple mode uses TogglePattern; page ScrollViewers and the named tweak/app-list viewports that expose their ScrollPattern use ScrollPattern; read-only Expanders use ExpandCollapsePattern. The whitelist rejects other targets and patterns. Every action records identity, parent, runtime ID, cursor, pattern and result in actions.json, including failures.

Pass A uses the original theme in Simple mode, including Memory when visible. Pass B shows advanced pages and tabs, including Leftover cleanup. Pass C uses Blackout Gold and captures the top of every page/tab/section. Long pages have overlapping scroll shots. Windows tweaks includes the full All tweaks list and one top shot per named section. The owned window is brought back to foreground before actions and screenshots when needed. Hidden and operation-dependent states are listed in index.md. Apply, undo/restore, removal, restart, update checks/download/install, report submission and tweak/game/process settings are never invoked.

The interactive recorder captures DWM frame bounds at 15 fps with the real cursor drawn. No recording software is installed on Windows. Linux ffmpeg encodes H.264/yuv420p/CRF20/faststart. Covered or absent owned windows are skipped. PNG screenshots omit the cursor. The artifact contains app and accepted installer PNGs/MP4s, three contact sheets, an index, the action log, UIA trees, raw-frame evidence.zip and the cleanup audit. Media stays outside Git.

Failure ways checked by the run: a foreign app/setup or lease refuses mutation; zero or multiple identity matches refuse the action; a missing pattern or failed readback fails the run; a hidden tab is recorded; an empty section list or stalled scroll fails coverage; source, nonce or media identity mismatch refuses reuse; recording errors fail; cleanup errors fail and keep rollback evidence. PowerShell source uses UTF-8 BOM for Windows PowerShell 5.1. Cmdlet/tool paths use the short plain-path boundary, and native file access uses extended paths. Only the app's automatic startup update check may make a production GET.

A completed set of passes can be retained through a nonce-bound, hash-checked completed-capture.json and resumed in a fresh frame with `--completed-capture <json> --passes C`. Requested passes must not overlap the retained passes, and together they must cover A/B/C. The final video joins the original window frames in order and records both capture sources. Multi-gigabyte frame archives have 30-minute archive/transfer bounds and are retained on the PC if evidence collection fails. ThemePicker is matched as a ComboBox because WinUI also assigns that ID to its child text provider.
