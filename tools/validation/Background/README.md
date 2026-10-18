# Background apps and desktop checks

The placement calculation can fail by reversing efficiency classes, omitting a
third efficiency tier, assuming AMD cache indexes are contiguous or limited to
two, placing work on the cache containing logical CPU 0, treating a homogeneous
CPU as hybrid, combining processor groups into one mask, overflowing bit 63,
ignoring the process system affinity, writing an empty intersection, accepting
duplicate or missing topology coordinates, or guessing when Windows cannot read
the topology. These are recorded before implementing the calculation.

Test-BackgroundPlacement.ps1 checks synthetic i5-14600K, Meteor Lake, 9950X3D,
7800X3D, four-cache 64-logical-CPU, two-group, restricted-system-mask and empty
intersection topologies. It calls the actual shared placement function, retains
the input and observed output as JSON, and does not change processes.

The live checks must use owned disposable images, independent native I/O and
memory reads, CPU/affinity reads, and compare all originals after Restore.
Placement must leave profile games, protected apps, exclusions and saved-rule
targets unchanged. The existing lower preset also boosts the configured foreground
game; that behavior is retained and independently recorded. Other checks cover
memory availability/validation, partial control failures, per-field saved-rule
ownership, and start-time mismatches on restore. A PID, name and path match alone
is not sufficient. `placement-origins` starts the background fixture at Realtime
CPU priority or High I/O priority and checks that Restore returns all four
controls. The Game priority and Background limits checks also restore High I/O;
Game priority additionally restores Realtime CPU. Independent token reads check
that restoring High I/O leaves its temporary privilege at the original value.

The desktop journey covers the merged Running process, Games, Windows tweaks,
Memory guides and Background apps UI on <COMPUTERNAME>. The CCD preset is also
checked on <COMPUTERNAME> without touching unrelated scheduled tasks. Test builds use
an empty or tailnet test update feed. No test sends bug reports or production
requests. Processes, tasks, source frames and fixture changes are owned,
recorded, restored and stopped.

Run from the repository worktree on Linux. Stage a fresh source frame after
changing source or a check; its receipt binds the interactive task to that frame.

```sh
python3 -I tools/validation/windows_ssh.py --host <test-pc> --expected-machine <COMPUTERNAME> upload --directory roo-industries-background --parent 'C:\RooBuild' --include-frontend > artifacts/background/intel-frame.json
python3 -I tools/validation/Background/run_e2e.py --machine intel --host <test-pc> --expected-machine <COMPUTERNAME> --receipt artifacts/background/intel-frame.json --scenario build --arguments '{"FeedUrl":"https://<feed-host>:8460/ota-e2e/beta.json"}'
python3 -I tools/validation/Background/run_e2e.py --machine intel --host <test-pc> --expected-machine <COMPUTERNAME> --receipt artifacts/background/intel-frame.json --scenario install
python3 -I tools/validation/Background/run_e2e.py --machine intel --host <test-pc> --expected-machine <COMPUTERNAME> --receipt artifacts/background/intel-frame.json --scenario presets
```

Build-Merged.ps1 parses the PowerShell scripts, runs the synthetic topology cases,
then invokes Build-Release.ps1 with the tailnet test feed. The install scenario
uses the OTA validation driver's manual-install path in a fresh leased Update
frame, captures existing rules, undo files, theme and governor state immediately
before setup, and keeps its evidence beside the supplied receipt. The original
build frame and installer remain untouched. `--arguments` accepts a
JSON object of script parameters, including `InstallerPath`; `--out-root` sets
the remote artifact directory.

Other independently runnable names are `placement-origins`, `game-memory`,
`limits-memory`, `identity`, `memory-controls`, `memory-ownership`, `priority`,
`games`, `services`, `guides`, `background-ui` and `memory`. The last runs the original three-run page recipe
with an additional owned window taking focus for samples at 10 and 40 seconds.
Those additional samples follow the minimized sample and are excluded from
comparisons of the original journey's peaks. No other desktop check should run
concurrently with `memory`.

After collecting the memory directory, verify its CSV/JSON agreement, waits and
totals and compare it with the frozen baseline summary:

```sh
python3 -I tools/validation/Background/summarize_memory.py artifacts/background/memory-baseline-0.11.0 --baseline-summary artifacts/background/memory-baseline-0.10.0/summary.json
```

```sh
python3 -I tools/validation/windows_ssh.py --host <test-pc> --expected-machine <COMPUTERNAME> upload --directory roo-industries-background --parent 'C:\RooBuild' > artifacts/background/amd-frame.json
python3 -I tools/validation/Background/run_e2e.py --machine amd --host <test-pc> --expected-machine <COMPUTERNAME> --receipt artifacts/background/amd-frame.json --scenario presets
```

Each driver writes JSON evidence, records owned PID/start-time identities, restores
its fixture controls and stops its own processes in `finally`. Desktop scenarios
also save UIAutomation text/trees and screenshots. Collect the receipt's
`runRoot\evidence` with SCP before removing an owned frame. Do not remove other
frames, scheduled tasks or processes.

Fix-round failure cases: a job may accept a priority write but keep its pinned value; each flow must report that control as failed, retain the other successful fields, and exclude the failed field from subsequent restore ownership. A governor restore may find one field changed externally; it must preserve that field while restoring the rest. A matching PID/name/path with a different start time must refuse every write, including when reopening the process after preview. New named scenarios record independent CPU, affinity, I/O and memory readback, backup outcomes, skips and cleanup.

For a controlled reproduction against an earlier staged backend,
`--arguments '{"BackendSource":"C:\\RooBuild\\<earlier-frame>\\source"}'` selects
that backend only inside the fixture driver. It does not change the installed
app or provide a product runtime override. Keep the new oracle and fixture
setup identical and preserve both versions' input, apply and restore JSON.

The service check applies a selection for the already-stopped PrintWorkflow
service, verifies the successful UI result, then restores the selection. It
proves the running-state read/apply path accepts the selection; it does not prove
a running-to-stopped transition on a PC where that service cannot be started.
The priority check captures both the immediate per-control results and the text
three seconds later so polling cannot silently hide a display regression.

Test configuration is required: pass SSH host and expected COMPUTERNAME, and pass `FeedUrl` to Build-Merged.ps1 (or set `ROO_TEST_UPDATE_FEED` in its Windows environment). The runner takes `--machine intel` or `--machine amd` only as an evidence label; it never chooses an SSH endpoint for you. Run `review2` for all launcher and query-only cases, or pass `--arguments '{"Mode":"placement"}'` on the AMD test PC for the placement launcher/child check. See [REVIEW2.md](REVIEW2.md) for the decisive controls.

The recovery-slot checks vary a closed instance, all instances closed, a reused
PID/start time, unreadable identity, a failed live control, and controls already
restored. Closed instances must release the slot; unverifiable or unrestored live
instances must retain it. Invalid pointer JSON, a missing/corrupt backup, and a
generation mismatch must preserve the old pointer bytes beside the original
path before another Apply. Locked/denied reads must not be treated as corrupt.
The settings checks start with empty/truncated JSON, preserve the corrupt bytes,
save theme/effects/simple-mode values, and reload them through a fresh store.
A loaded store must keep its known values if a later reload fails. GPU checks
vary a mid-session release and subsequent re-restraint, checking the original
GPU value independently after each restore. Manual update failures with automatic
downloads off must invite another Download, without claiming a scheduled retry.

Direction checks must catch Windows CPU enum values being mistaken for priority
order, a low CPU value suppressing independently needed I/O or memory changes,
and a fresh value becoming lower between preview and write. Idle / I/O VeryLow /
memory 1 must remain untouched in Lower, Game priority demotion and Background
limits, with no restore ownership for those controls. Game boosts only raise;
placement and inverse restore may change either direction. Partial/failed restore
text must name the remaining live apps and explain their failures. An archived
invalid recovery reference must show a dismissible notice once on the Background
apps card, without changing the preserved bytes or falsely freeing a valid slot.
