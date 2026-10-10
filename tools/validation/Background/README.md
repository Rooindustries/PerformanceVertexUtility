# Background apps and ROO-20 desktop checks

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
Memory guides and Background apps UI on SERVI-WINDOWS-D. The CCD preset is also
checked on CS2-GEN4 without touching unrelated scheduled tasks. Test builds use
an empty or tailnet test update feed. No test sends bug reports or production
requests. Processes, tasks, source frames and fixture changes are owned,
recorded, restored and stopped.

Run from the repository worktree on Linux. Stage a fresh source frame after
changing source or a check; its receipt binds the interactive task to that frame.

```sh
python3 -I tools/validation/windows_ssh.py --host optimizer-9070 --expected-machine SERVI-WINDOWS-D upload --directory roo-industries-roo20-background --parent 'C:\RooBuild' --include-frontend > artifacts/roo-20/background/9070-frame.json
python3 -I tools/validation/Background/run_e2e.py --receipt artifacts/roo-20/background/9070-frame.json --scenario build
python3 -I tools/validation/Background/run_e2e.py --receipt artifacts/roo-20/background/9070-frame.json --scenario install
python3 -I tools/validation/Background/run_e2e.py --receipt artifacts/roo-20/background/9070-frame.json --scenario presets
```

Build-Merged.ps1 parses the PowerShell scripts, runs the synthetic topology cases,
then invokes Build-Release.ps1 with the tailnet test feed. The install scenario
uses the OTA validation driver's manual-install path and its preservation seed.
For a frame without that seed, run the manual installer from the signed-in
desktop session and use the other scenarios directly. `--arguments` accepts a
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
python3 -I tools/validation/Background/summarize_memory.py artifacts/roo-20/memory-baseline-0.11.0 --baseline-summary artifacts/roo-20/memory-baseline-0.10.0/summary.json
```

```sh
python3 -I tools/validation/windows_ssh.py --host blackwell-lan --expected-machine CS2-GEN4 upload --directory roo-industries-roo20-background --parent 'C:\RooBuild' > artifacts/roo-20/background/blackwell-frame.json
python3 -I tools/validation/Background/run_e2e.py --machine blackwell --receipt artifacts/roo-20/background/blackwell-frame.json --scenario presets
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
