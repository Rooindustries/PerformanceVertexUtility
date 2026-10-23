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

## Required restore E2E gates

Before merging a change to profile or Game Tune Undo, run this manual group on
an explicitly granted Windows test PC, in its original owned source frame:

```powershell
& "$Source\tools\validation\Background\Invoke-RestoreE2EGates.ps1" -Source $Source -OutRoot $OwnedArtifacts
```

The caller must first supply the existing verified `windows_ssh.py`
`REMOTE_GUARDS` recipe in the same PowerShell session. The group requires its
`Assert-FrameSourceSnapshot` and protected path helpers; it fails if they are
missing. It checks current source bytes before importing any source and again
after the groups, including protocol, commit, frame, SID, machine and file count.
It dot-sources the Harness-dependent groups inside a script block so they share
its Harness scope; a plain `&` call starts a new script scope that can't see it.
The drivers parse each backend body with its real script path, so `$PSScriptRoot`
resolves the same way as in a normal backend run.

The original `frame-receipt.json` and active canonical Harness lease remain
required. Create `OutRoot` and both `compiled\actor` and `compiled\ui` directories
through the owned Harness ledger. Create `e2e-inputs.json` through that ledger
as a file; the group holds its original file identity and hash while running.
Its `sourceCommit`, `originalSourceCommit`, `originalSource`,
`originalSourceManifest` and `originalSourceFileCount` bind the current source
and original b0 export. Every row in `files` has an absolute plain `path` and
`sha256`. Include the original export manifest and every published file in both
compiled directories, with no duplicate or unlisted paths: apphost EXE, entry
DLL, runtimeconfig, deps, managed dependencies and other published files. The
group rechecks this inventory and every hash after execution.
Keep a separate reviewed c50 export with `reviewedSourceCommit`,
`reviewedSource`, `reviewedSourceManifest` and `reviewedSourceFileCount`. The
count is an integer from the retained c50 manifest, not a new corrected export.
Bind both export manifests and every export file before and after execution,
and retain each export directory's original active Harness creation identity.
`OriginalSource` remains the b0 interleaving input; it does not stand in for c50.

The group refuses another user, machine, source frame or terminal session.
`-Scenario` selects named native cases; its completion artifact states exactly
which cases ran. It does not certify omitted cases or the whole release gate.

`Test-RestoreSerialization.ps1` exercises real Windows controls and both actual
restore bodies. It isolates only the data root. The separate Core actor uses
public Preview/Apply/Restore, records native birth and actual terminal sessions,
and must report `InstanceBusyException` for a contention refusal. The original
b0 interleaving is an explicit negative control. Its bad outcome is retained
before separately labelled post-red owned fixture cleanup; that cleanup is not
Undo proof. Canonical ledger image paths remain intact; actor requests use the
existing Plain normalization and retain both representations. Setter breakpoint
counters count attempts, while actual readbacks and emitted outcomes establish
what Windows did. Failed/pending saved-outcome replays are labelled as replays; the actual setter/readback failure case uses a
PowerShell debugger breakpoint and real controls. No simulated getter, setter,
mutex or API result is an E2E pass.

Missing-record cases start with a real verified apply and retain the original
producer bytes, then replay a labelled saved format. They cover absent and
empty control arrays, an unmatched target beside a genuinely verified memory
peer, and a matching record without an outcome. Requested-first, repeat and
external-drift steps preserve recovery without a target write or kept claim.
Six base histories finish only at the actual original; six separate `-ended`
histories terminate their own original process while still pending. Completion
is terminal; neither history reopens completed Game Tune recovery. Applied-only
inputs exercise reader compatibility, not conformance to the current raw backup
schema or provenance from an old installation.

The junction case owns a real image and a sibling junction. It retains native,
CIM, MainModule and actual saved producer paths, original birth/session/name,
canonical image and hashes. Every required path observation must succeed and
be nonempty. It compares c50 only when the actual saved and native spellings
differ; equal spellings leave F1 NOT REPRODUCED and missing red. Undefined live
exit-time bits are raw observations only. Cleanup stops and disposes the
original target before removing the original junction ID, image and real
folder. A failed stop, unregistered link or refused link cleanup retains all
dependent resources and fails completion.

Four coherence cases mutate only in-memory inputs at the actual Confirm seam
after a real preview. They are labelled constructed, not actual PID reuse or
outside tampering. They require refusal, pending recovery and zero setters,
then remove the original breakpoint and use the unchanged backup for a fresh
positive Undo.

The default authored selection has 84 scenario names and 672 serialization
histories: the existing 622 plus five late-exit names across both bodies and
all five controls (50). The 10 keeps-other-value and 10 output cases stay
unchanged, making 692 top-level histories. Each of the 10 postwrite histories
has two fresh-original producer legs, so the 50 new histories require 60
producer legs. These counts describe authored selections, not completed runs.
These are SOURCE-DERIVED counts, UNRUN until real Windows completion receipts
exist. Explicit incompatible `-Control` fails. Selected runs record exact
kind/control/scenario triples and expected/actual counts. No subset certifies
the default grid, C6 or rendered proof.

Late-exit histories stop the original only after the actual restore caller's
execution identity check. They use breakpoints bound to the named Common
function, with one matching source line in that function. The original
breakpoint objects are removed before repeat or fresh-ended retry.

| Scenario | Required observation |
| --- | --- |
| `late-exit-restore` | A clean late end closes the target once. For CPU, a separate owned original in the same actual producer backup restores once. |
| `late-exit-original` | The genuine original-value preview enters confirmation before the target ends; no target setter or current kept claim. |
| `late-exit-kept` | A genuinely applied record and actual external value produce a kept preview before exit; the closed result has no current kept claim. |
| `late-exit-postwrite` | Two fresh-original legs stop before and after aggregate readback. Both retain all earlier successful native writes and readbacks. |
| `late-exit-release-error` | A real mutex release failure remains pending after exit. Remove the injection and settle the original mutex before a separate fresh-ended retry. |

The CPU restore history owns two separate PING originals with one unpredictable
basename, separate directory/image/process ledger entries and native handles.
One actual Apply or Start call creates both snapshots; Game uses one session.
Both CPU originals are Normal and both memory values are read back as 5 before
the producer requests AboveNormal and memory 5. A same-process control, actor
or duplicate snapshot is not the surviving original.

Only these five new histories pass an immutable owned-instance guard through
their actual producer and every Undo call. It validates the original retained
handle and the actual backend instance before calling the unchanged native
mutator on the same Process and Change objects. An unowned candidate is refused
before that method; the fixture then fails and retains its rejection trace.
Inventory, classification and producer responses are not filtered or mocked.
The unowned branch has no claimed native negative execution proof.

A clean explicit instance check can close a late-ended original. An observed
query, write, readback or cleanup error stays hard, even if a later check sees
that the process ended. The driver saves prior writes, exact provider error
types, full producer bytes, raw results, reopened status and original cleanup
receipts. It never fills in native values after exit or counts the same
original as both closed and currently restored. A race between a clean check
and a later failed operation remains pending for that attempt.

These histories are UNRUN until real Windows receipts exist. The postwrite
history requires both leg completion and cleanup artifacts. Its after-aggregate
old-f4 comparison remains missing because old f4 has no new observer seam;
no observer is transplanted and no new source-comparison parameter is added.
The release-error history exercises instance release, not all five cleanup
faults. P1, C6, rendered UI8/media and the other required manual gates remain
separate.

No-effect histories first run the actual foreground-game producer, then retain
its unmodified backup bytes and exact native values and record set before any
external fixture write or labelled replay. The public raising policy stays the
same. Changed fixtures use CPU Normal -> AboveNormal, I/O Low -> Normal and
memory 2 -> 5. A CPU target's independent memory peer also starts at 2 and
requests 5. Other targets use an independent CPU peer Normal -> AboveNormal.
GPU starts at Normal and requests BelowNormal; affinity starts at the actual
allowed mask A and requests its least significant bit. Changed external values
are CPU BelowNormal, I/O VeryLow, memory 3, GPU High and the remaining allowed
affinity bits. An insufficient mask or unavailable native precondition fails;
it is missing proof, never a skipped pass.

A genuine no-effect request keeps CPU Normal, I/O Normal, memory 5, GPU Normal
or the original affinity A. Its later external value is respectively
AboveNormal, Low, 2, High or the least significant bit of A. Conflicting legacy
applied metadata uses AboveNormal, Low, 2, BelowNormal or that affinity bit,
respectively. Memory's conflict is 2, not the changed-history request 5.

The following 24 names each run with both restore bodies and all five controls.
They retain all 53 existing names and their adverse, retry and cleanup oracles.

| Scenario | History and required result |
| --- | --- |
| `no-effect-original` | Genuine equal original/request; target omitted, peer restored once. |
| `no-effect-external` | External drift before preview; target untouched, peer once. |
| `no-effect-after-preview` | Drift at first Confirm; excluded target never enters Confirm. |
| `no-effect-applied-equal` | Labelled equal legacy applied field; exclusion grants no ownership. |
| `no-effect-applied-conflict` | Conflicting legacy field retains recovery; actual original resolves. |
| `no-effect-proposed-missing` | Missing request plus valid legacy original remains unverified. |
| `no-effect-proposed-null` | Null request plus valid legacy original remains unverified. |
| `no-effect-proposed-invalid` | Invalid request plus valid legacy original remains unverified. |
| `no-effect-applied-invalid` | Invalid legacy applied field prevents exclusion. |
| `no-effect-applied-null` | Explicit null legacy applied field prevents exclusion. |
| `no-effect-record-applied` | Real changed apply, then constructed matching equal-value record; existing verified-kept behavior. |
| `no-effect-record-failed` | Same replay with failed outcome; pending, then original resolves. |
| `no-effect-record-pending` | Same replay with pending outcome; pending, then original resolves. |
| `no-effect-record-unknown` | Same replay with unknown outcome; pending, then original resolves. |
| `no-effect-changed-absent` | Real target-only changed apply; remove whole list, retain recovery at request and drift. |
| `no-effect-changed-empty` | Real target-only apply with empty-list replay; same recovery. |
| `no-effect-changed-unmatched` | Remove target record, preserve genuine peer record; peer restores once. |
| `no-effect-changed-absent-ended` | Separate absent-list history closes only after its original process ends. |
| `no-effect-changed-empty-ended` | Separate empty-list history with known-ended resolution. |
| `no-effect-changed-unmatched-ended` | Separate unmatched history with peer once and known-ended resolution. |
| `no-effect-confirm-busy-retry` | Real native instance contention blocks original and kept previews; release permits fresh retry. |
| `no-effect-confirm-busy-ended` | Both previews retain recovery; fresh known-ended pass closes without writes. |
| `no-effect-confirm-wrapper-retry` | Two guarded backend-wrapper getter failures; fresh wrapper confirms original and restores peer once. |
| `no-effect-confirm-wrapper-ended` | Same failures followed by fresh known-ended completion, without a peer write. |

Two further names, `no-effect-affinity-decimal` and `no-effect-affinity-hex`, run
only on affinity across both bodies. They replay the actual A as a decimal
original or exact unsigned-bit-pattern hex request. They test existing signed64
reader compatibility, not raw Profile schema conformance. No invented high-bit
mask is written to hardware. Explicit incompatible `-Control` fails.

Every true exclusion has zero target setters, confirmations, restored records
and kept claims. A genuine peer restores exactly once across repeats. Uncertain
histories also set the target to its original before preview, then change it
back at Confirm: fresh confirmation must retain recovery. Only a later fresh
original or known-ended pass closes it. Completed Game histories are repeated
without reopening or resetting them. Partial Game attempts may have completed
envelopes with public restorable status; pending-only repeats report failed
and remain restorable. Full result, status and immutable backup checks apply
together with native readbacks.

The wrapper cases are constructed lifetime adversaries, not spontaneous Windows
failures. Before closing the backend wrapper, the driver refuses references to
either original process object, zero or shared handles, and a changed original
native birth. It keeps the original owned and query handles. Both actual getter
errors must be captured; a guard refusal or an unrelated exception is MISSING
injection proof. Busy histories use a separate real actor; it blocks the peer
as well until release. No cached preview can certify no-write completion.

The new pre-fix 861 red is a separate pair, one per body: actual CPU
Normal -> AboveNormal with an applied record, memory 5 -> 5 without a record,
then external memory 2. CPU must restore Normal once while old 861 falsely
keeps memory pending, with zero memory setters or kept claims. This adds no
green histories and does not replace the 12 c50 negatives or b0 interleaving.
`BeforeNoEffectSource` defaults empty. A nonempty value requires exactly
`-Scenario no-effect-external -Control memoryPriority` with profile, game or all.
Both producer and restore use that separately bound exact 861 source; status
reader and driver remain current and carry separate paths, hashes and commits.
The preserved Linux git archive alone is not a Windows export or native proof.
Corrected fixture inputs require new receipts; historical sources, seals,
binaries, Core/Host/private P1 vectors and old failed observations keep their
original identities. Conditional alias evidence still requires actual differing
successful path observations.

Twelve separately reported old-c50 negative controls are the six base legacy
shapes across both bodies, with the current driver and reviewed c50 product.
Each owns a new directory/process/backup and must retain requested-first JSON,
readback, producer and cleanup receipts plus the specific lost-recovery failure.
An arbitrary nonzero exit is not red proof. The six ended names are green-only
histories, not six extra old-source runs. Conditional old-c50 alias observations
are separate from these 12 and from the b0 TOCTOU case. For a later granted
window, the current driver can target the separately bound product export:

```powershell
& {. (Join-Path $Source 'tools\validation\Background\Test-RestoreSerialization.ps1') -Source $reviewedSource -SourceCommit 'c50c8c8c9a0c8bd2d9103dc0059d088f79a85964' -ActorExe $actor -OutRoot $ownedRedCase -Kind $body -Control priorityClass -Scenario $legacyMode}
```

Those variables must come from the approved frame and complete input bindings,
in a session that already opened the frame's Harness.
This call is an expected-failing old-source control, not a second controller,
automatic retry or permission for host contact. Its failure must be judged from
the specific saved observations and original cleanup.

`Test-RestoreSummaryOutput.ps1` runs the real AppSweep process with owned

filesystem failures. The `restore-summary-setup-failure`, `-body-failure`,
`-cleanup-failure` and `-body-cleanup-failure` modes create only validation
fixtures: an owned setup blocker, missing body input or held cleanup file.
Generated output must disappear in every case, including recovered cleanup
failures. Explicit output, its sentinel and receipts remain, including early
setup failure. The driver retains the original process identity, saves raw
output before assertions and attempts each owned cleanup even when a check
fails. It checks every captured property, cleanup error counts and original
body error ordering. These Windows scenarios remain unrun until a new grant.

Validate the complete captured envelopes, including single-field malformed
copies, with:

```sh
bash tools/validation/Background/test_restore_contracts.sh "$source" "$artifacts" --negative-records
```

That command validates JSON against the schema. It proves no Windows behavior.
Whole actual Profile backups saved as `producer-profile-backup.json` are also
validated against `processProfileBackupManifest`. Its three optional additions
are `originalMemoryPriority` and `proposedMemoryPriority` (integer 1 through 5,
or null), and `processStartTimeUtc` (string or null). Required fields and all
other types stay the same. Raw Game backups and reader-compatible replays use
different scopes; no projection hides undeclared fields.

With `--negative-records`, the same whole-file validator must reject three
single-field object-type copies and four memory copies set to 0 or 6. It must
accept eight memory copies set to 1, 5, null or absent, one field at a time.
It also validates an unchanged complete kept-record envelope without a
Profile backup, then requires the combined negative command to refuse that
missing coverage and retain its report. These derived copies are contract
artifacts, never restore inputs or extra native histories. Perl JSON::PP
`allow_bignum` keeps unrelated 64-bit values intact.

`profile-backup-coverage.json` records `rawProfileMatched`,
`rawProfileNegativeCount`, `rawProfileMemoryNegativeCount`,
`rawProfileMemoryPositiveCount`, `missingProfileRefused` and
`coverageComplete`. Complete negative coverage requires a genuine Profile
source, counts 3/4/8 and the missing-input refusal, alongside actual kept-record
coverage. Default positive validation still supports old or Game-only artifact
directories. Negative mode now refuses them when Profile coverage is missing.
Schema proof also requires genuine producer/source/engine and original backup
hashes. These new boundary cases are AUTHORED/UNRUN until those actual
artifacts exist; schema acceptance proves no native restore behavior.

Its coverage receipt lists the actual kept controls and representations it saw;
missing real producer variants remain unrun. Historical Linux outputs with
simulated process I/O remain useful schema inputs, including unsafe historical
outcomes, and remain labelled as historical.

`Test-RestoreActorReceipt.ps1` checks receipt waiting with real disposable child processes and atomic file publication on Linux or Windows. Run it with a new evidence directory:

```powershell
pwsh -NoProfile -File tools/validation/Background/Test-RestoreActorReceipt.ps1 -Source $Source -OutRoot $NewOwnedEvidence -SourceCommit $Commit
```

This checks the shared receipt consumer. It does not run the native actor or prove Windows process ownership or restore behavior. The real Windows group remains required.

`Invoke-RestoreKeptUi.ps1` drives the real desktop app's Game priority Restore
after another program changed the priority. Build the app in a short copy of the
source with `tools\scripts\Build-Frontend.ps1`, then run the script through
`windows_ssh.py interactive-frame` with `Source`, `AppRoot`, `OutRoot` and
`Label` (`before` for a build of main, `after` for the change). It starts an
owned PING fixture, applies a one-process Game priority profile from the app
root's own backend, sets the fixture to Below normal, clicks Restore game
priority and saves the card text, screenshots and window frames for a video. It
passes only when the fixture keeps Below normal, its affinity comes back and the
card names the priority it left. A build of main fails that check after saving
its evidence. It covers one rendered state, not UI8.

The retired Linux-only [Profile confirmation](https://github.com/Rooindustries/PerformanceVertexUtility/blob/8159820c33531fa476a3aefa987a3b8094ecfae6/tools/validation/Background/Test-ProfileRestoreConfirmation.ps1) and [identity recovery](https://github.com/Rooindustries/PerformanceVertexUtility/blob/8159820c33531fa476a3aefa987a3b8094ecfae6/tools/validation/Background/Test-ProfileRestoreIdentityRecovery.ps1) simulations remain in Git history. Their old receipts apply only to their recorded source inputs. `Test-RestoreGovernorOwnership.ps1`, `Test-RestoreProcessOperationOwnership.ps1` and `Test-RestoreOwnershipScale.ps1` are historical simulations, not current native proof. These Background checks are not automatically discovered by `Test-Baseline.ps1`. The Baseline workflow runs its declared Linux checks and optional Windows matrix. The manual real restore group is a separate required gate. C6 still requires 40 real processes, two controls, 125 histories and each whole Undo under 45 seconds. UI8, screenshots, interaction video and both actual vision reviews remain separate required Windows gates.

The Global governor gate coordinates supported actors for the current SID.
The unchanged Local process-instance mutex coordinates direct Core actors in
the same terminal session. Uncooperative direct DLL consumers in another
terminal session and legacy direct policy/governor setter routing are outside
this change; they are not claimed serialized by these checks.
