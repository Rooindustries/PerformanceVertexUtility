# Memory measurement

Run the `baseline` journey on an SSH-accessible Windows test PC with a signed-in desktop session. Close the Suite and pause saved process rules first. The PC must have an installed Suite and a matching restore installer. Keep the same hardware and settings for comparisons.

```sh
python3 -I tools/validation/Memory/run_memory.py \
  --scenario baseline --host <test-pc> --expected-machine <computer-name> \
  --runs 3 --heap-probe \
  --compare <control-folder>/memory.csv \
  --restore-installer <as-found-installer.exe> \
  --restore-sha256 <sha256> \
  --out-dir artifacts/memory/<fresh-output-folder>
```

The driver requires a clean, committed source tree and a fresh output folder. It stages a fresh frame, takes the host lease, builds an unsigned release with an empty update feed, verifies the embedded feed, installs it and measures independent app lifetimes. It restores the captured installation, data files and raw tweak/theme registry bytes, then closes the ledger and audits the host. The Suite governor task's TimeTrigger StartBoundary may be rebased by setup; the audit ignores only that timestamp for Suite rule tasks and checks their remaining definition and enabled state. CS2 and other Roo task XML is compared exactly. Unrelated Windows tasks can reschedule themselves; their full snapshots are retained, but their live schedule fields are not treated as harness changes. Task names must remain the same. It never fetches a production feed or installer. It refuses other running Suite processes; a failed restoration retains the frame and its rollback evidence. SmartScreen is never clicked.

Each run waits 60 seconds on initial Home, visits Home, Games (Games, Processes, Background apps), Remove apps, Graphics drivers, Windows tweaks, Tools, Undo changes, Report a bug, Settings and Home, settling 15 seconds at each point. It waits another 60 seconds on final Home. Optional HeapProbe attaches at this point in the last run, before reopening pages, using the installed DAC without inducing GC or copying object values.

Reopening repeats Home → page → Home three times each for Windows tweaks, Tools and Remove apps. Time starts at `SelectionItemPattern.Select()` and ends at the same visible UIA markers used by the experiment:

- Windows tweaks: the first realized ListItem under `WindowsTweaksList`.
- Tools: the visible, enabled `OpenFirmware` button.
- Remove apps: the first realized ListItem under `RemovalApps`.

The poll interval is 20 ms. The marker can appear before all backend work finishes. After reopening, Home settles for 15 seconds and is sampled. The app is then minimized for 60 seconds and sampled. Finally it is restored, an owned evidence window takes focus, and samples are taken 10 and 40 seconds after losing focus. These extra focus samples come after the minimized point, preserving the experiment's gate-point order.

Every sample records app and live Suite helper PIDs, image paths, creation times, WorkingSet64, PrivateMemorySize64 and the Process `Working Set - Private` counter matched by PID, plus totals. The launcher is normalized to Normal CPU, I/O and memory priority before each app launch. Other applications and build helpers are excluded. A helper that exits between enumeration and the read is retained in `sampling-races.json` without invented metrics or process adoption; a live foreign helper or an app identity change fails the run. UIA does not reset the session's last-input time, so the foreground relief can run on its first two-second poll when input was already idle.

Artifacts include nonce-bound remote receipts, raw CSV/JSON samples, reopen timings, page screenshots, cursor-bound app-log segments, optional heap/type summaries, payload hashes, as-found archives, raw registry snapshots and the terminal cleanup audit. Local readable filenames remain bound to their nonce and SHA-256 through `measurement-receipt.json`. `summary.json` and `medians.csv` retain all runs and also report a sensitivity view excluding lifetimes whose private working set at any Games point fell below half of their initial/Home reference. A flagged run is retained in the all-run median.

To summarize again without running Windows:

```sh
python3 -I tools/validation/Memory/Summarize-Memory.py <output-folder> \
  --compare <control-folder>/memory.csv
```

`--compare` also reads adjacent `post-reopen-memory.csv` and `reopen.csv` when present. It writes `differences.csv` with measured minus control values. Missing control points remain unavailable. The driver gates all-run private-working-set medians: final Home at least 30 MiB below the control, post-reopen no more than 15 MiB above it, minimized no more than 2 MiB above it, reopening medians within +50 ms per page, and zero memory-relief failure log lines.

The shared path lint includes this suite. Filesystem access uses the extended-path helpers; cmdlets and tools receive bounded plain paths. The uploader's private-key checks and the Update harness's process/window ownership and cleanup rules remain in force.
