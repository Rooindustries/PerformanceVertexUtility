# Removal and scheduling acceptance criteria

Checked against primary sources on **2026-09-15**. Repository starting point: `8df0c71bc22655e522f864ffb9a93ad6ea250371`. This report defines the cleanup contracts and comparison protocol, including broader parity work such as installation tracing. The measured CPU result below is separate from the proposed checks. See [optimization controls](../optimization-controls.md) for implemented workflows, reusable checks and current limits; keep runtime evidence bound to the tested revision.

The target is a useful, free replacement for the requested Revo and Process Lasso workflows. Feature availability, correct execution, and performance improvement are separate claims. A named workload can demonstrate an improvement; no finite benchmark establishes that an optimizer is universally better. Existing [removal research](uninstall-cleanup.md) and [process research](process-management.md) retain the broader edition and feature catalogs.

## Product acceptance

Revo documents registry/file review, consecutive uninstall queues, tracing and later scanning of unlogged leftovers. Its manual warns that shared program directories can produce candidates belonging to another product. Consequently, deleting more entries is not a sufficient quality measure. [Revo uninstaller manual](https://www.revouninstaller.com/online-manual/uninstaller/).

| Requested workflow | Required result | Minimum independent evidence |
|---|---|---|
| Deep app cleanup | Discover app-specific installation, user-data, common-data and registry candidates; explain each match and exclusion; let the user select exact resources. | An independently authored fixture manifest identifies owned, shared, user-created and unrelated resources. Compare discovery precision/recall separately from deletion. |
| Registry removal and recovery | Preserve hive, registry view, SID, key versus value, raw type/data and security scope. Back up before mutation; restore selected items without silently replacing newer data. | Native registry reads before/delete/restore, including unnamed values, empty values, binary, DWORD/QWORD, expandable strings and both views. |
| Multiple apps | Queue official removers sequentially; offer a grouped post-removal review across completed apps with per-app results and recovery. Shared targets have one resource record with all owners. | Two products sharing a directory/value; cancel during the first remover; resume only untouched entries; one failure must not mislabel another app or repeat an uncertain remover. |
| Forced/orphan cleanup | Permit a review started from a precise executable/path and product identity when registration is absent or a remover is unusable. Missing registration must not manufacture ownership. | Orphaned app fixtures beside same-publisher sibling apps and similarly named unrelated folders. Broad names yield suggestions, never automatic approval. |
| Installation tracing | Record a bounded installation session and distinguish newly created resources from modified pre-existing resources. Link evidence to installer/process identity, user and time; retain uncertainty. | Installer child creates a resource, shared service performs a change, unrelated process writes concurrently, and a pre-existing value is edited afterward. Only justified reversals are offered. |
| Persistent process controls | Saved rules for CPU Sets, hard affinity, CPU/GPU/I/O/memory priority and supported efficiency controls apply to new matching instances; each field has visible readback and recovery state. | Independent native queries across start, relaunch, rule edit/disable, engine restart, overlapping rules and external writes. |
| Adaptive responsiveness | Approved background contention is reduced while foreground and protected/excluded processes retain their intended state. | Repeatable CPU, storage and GPU contention trials with latency distributions, background progress and controller overhead. |
| Complete operator workflow | Selection, explanations, errors, progress, cancellation, recovery and persistence are usable at supported display sizes. | Actual screenshots plus interaction tests; final Windows state is checked independently of UI labels. |

The forced workflow follows Revo's documented exact-name/path input and separate review; Revo warns that imprecise names can produce false matches. [Forced Uninstall guide](https://www.revouninstaller.com/how-to/use-forced-uninstall/). Selective recovery is a distinct feature: Revo automatically backs up registry removals, while file backup is configurable. Neither product should label cleanup recovery as reversal of an arbitrary vendor uninstall. [Backup Manager](https://www.revouninstaller.com/online-manual/backup-manager/).

## Cleanup authority and conflicting evidence

This is the proposed execution contract, not an assertion that existing default flags establish authority. Bind review to operation ID, app identity, computer/SID, exact resource identities, discovery revision and snapshot hashes. Exclusions and contrary evidence remain effective even when the primary match is favorable.

| Required evidence | Independent state | Permitted transition/result |
|---|---|---|
| Exact selected registration and reviewed remover | Registration/executable changed; owner scope differs | Reject dispatch; obtain a new review. |
| Vendor exit is acceptable | Registration remains, reboot is pending, or observation was interrupted | Preserve unresolved/reboot state. Do not promote it to completed cleanup authority. |
| Removal journal identifies a completed app | App was reinstalled or its identity now refers to another installation | Invalidate old cleanup approval; preserve current resources. |
| Candidate path/registry reference matches app | Another installed product or unselected queue member owns it | Preserve shared resource; deleting the selected product does not remove the other owner's claim. |
| Candidate matches exact install location | Ownership unknown, sibling content present, or user-created documents exist | Present evidence for review; do not infer that the entire subtree is disposable. |
| Exact review/hash matches | Missing target, access denial, provider unavailable, or partial enumeration | Distinguish absent, failed and incomplete. An unreadable resource is not empty. |
| Exact reviewed file/key/value exists | Content, value type/data, subtree membership or protection state changed | Preserve changed resource; refresh review. |
| Target still matches review | Backup is incomplete, corrupt, unwritable, or overlaps a deletion target | Do not delete. |
| Traced resource was newly created | Later app/user modification or additional owner exists | Preserve or request a new explicit conflict review. |
| Trace records a pre-existing value/file modification | Current value still equals the recorded installation result | Offer restoration of its captured predecessor, not deletion of the pre-existing object. |
| No registration exists | Orphan name/path is broad, trace missing, or ownership incomplete | Candidate discovery remains usable; destructive selection needs exact resource evidence. |
| Journal proves a deletion with valid backup | Restore destination is absent | Restore into that destination through the verified parent. |
| Valid restore request | Destination exists and differs, parent changed, or resource belongs to a new installation | Preserve both current data and backup; report conflict. A retry must not become overwrite permission. |

For MSI, query component users with `MsiEnumClientsExW` using the relevant installation contexts/SIDs. `MsiGetComponentPathExW` supplies a component **key path**, not a complete file ownership inventory. A missing MSI client does not exclude non-MSI ownership. [Component clients](https://learn.microsoft.com/en-us/windows/win32/api/msi/nf-msi-msienumclientsexw), [component key path](https://learn.microsoft.com/en-us/windows/win32/api/msi/nf-msi-msigetcomponentpathexw).

Registry execution needs its own contract. `RegQueryValueExW` returns raw type/data and distinguishes an absent default value from a present empty one; strings are not guaranteed terminated. `RegDeleteKeyExW` explicitly selects a registry view and deletes a key's values, even though it refuses keys containing subkeys. Deleting only reviewed values and then checking an empty key is still not an atomic compare-and-delete transaction. Do not describe ordinary handles or a before/after fingerprint as a lock against all writers. [Value query](https://learn.microsoft.com/en-us/windows/win32/api/winreg/nf-winreg-regqueryvalueexw), [key deletion](https://learn.microsoft.com/en-us/windows/win32/api/winreg/nf-winreg-regdeletekeyexw), [registry access rights](https://learn.microsoft.com/en-us/windows/win32/sysinfo/registry-key-security-and-access-rights).

Revo advises tracing one installation at a time, avoiding newly launched unrelated programs, and running/configuring the installed program before ending capture. That workflow itself identifies why a time interval alone is inadequate ownership proof. [Tracing guide](https://www.revouninstaller.com/how-to/trace-a-program-with-revo-uninstaller-pro/). Microsoft Process Monitor captures filesystem, registry and process/thread activity, making it a useful independent fixture oracle, not a production dependency. ETW capture must retain loss counters: missing events invalidate claims of complete attribution. Before/after snapshots are useful but must be labeled snapshots rather than complete process tracing. [Process Monitor](https://learn.microsoft.com/en-us/sysinternals/downloads/procmon), [ETW and missing events](https://learn.microsoft.com/en-us/windows/win32/etw/about-event-tracing).

The trace design must capture preimages separately before claiming it can reverse modifications: an event naming a write does not supply the original complete file. An installer-child relationship supports attribution; a shared service or broker requires additional correlation. Uncorrelated changes remain uncertain, even within the selected time interval. Imported recipes/logs suggest resources and must pass local identity, ownership and current-state checks again.

## Handle-based file backup and deletion

Use one small native boundary with explicit supported-volume and backup-fidelity checks. The strategy below strengthens identity and confines deletion; it is not an atomic filesystem-tree transaction.

1. **Acquire a verified path chain.** Open from a trusted local volume/root and resolve one child component at a time relative to a retained directory handle. Microsoft's user-mode `NtCreateFile` accepts `RootDirectory` and a relative `ObjectName`; `FILE_OPEN_REPARSE_POINT` opens the reparse object itself. Verify each directory before descending; reject `..`, separators in a child name, device/stream syntax and unexpected reparse objects. This avoids reopening a mutable absolute ancestor chain. Keep the NT adapter isolated and return its exact status on failure. [NtCreateFile](https://learn.microsoft.com/en-us/windows/win32/api/winternl/nf-winternl-ntcreatefile).

2. **Hold the target through the consequential operation.** A synchronous file handle requesting read plus `DELETE`, with only `FILE_SHARE_READ`, denies competing data-write/delete opens. An existing incompatible writer must cause a sharing failure. Directory handles opened through `CreateFile` require `FILE_FLAG_BACKUP_SEMANTICS`. Do not request `DELETE_ON_CLOSE` while still validating or creating the backup. Attribute/extended-attribute access is not excluded by these sharing flags, so this is not a freeze of all metadata. [CreateFile sharing and flags](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-createfilew).

3. **Verify the opened object.** Query `FileIdInfo` and compare volume serial plus 128-bit file ID, then validate content hash, length, type, reparse tag and link count against review. IDs distinguish open objects, not historical content or exclusive ownership. `FileStandardInfo` supplies link count, directory and delete-pending state; `FileAttributeTagInfo` exposes the actual tag. Keep a resolved handle path for audit/containment, not as replacement authority. Initially reject multiple hard links and unsupported reparse, cloud-placeholder, EFS or filesystem cases. [File identity](https://learn.microsoft.com/en-us/windows/win32/api/winbase/ns-winbase-file_id_info), [standard information](https://learn.microsoft.com/en-us/windows/win32/api/winbase/ns-winbase-file_standard_info), [attribute/tag](https://learn.microsoft.com/en-us/windows/win32/api/winbase/ns-winbase-file_attribute_tag_info), [final handle path](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-getfinalpathnamebyhandlew).

4. **Enumerate without authorizing new children.** `GetFileInformationByHandleEx` supports directory enumeration with IDs and reparse information through `FileIdExtdDirectoryInfo`. Validate variable record lengths/offsets and bounded buffer retries. For every reviewed child, open and verify its own handle; retain the parent while doing so. Directory sharing does not establish an immutable subtree. An inserted child must survive, and the remaining directory may then fail the empty-directory removal. No recursive path deletion may expand the approved set. [Handle information classes](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-getfileinformationbyhandleex), [directory record layout](https://learn.microsoft.com/en-us/windows/win32/api/winbase/ns-winbase-file_id_extd_dir_info).

5. **Back up the same source handle.** Use `BackupRead` to preserve supported data streams and security information, with a synchronous handle and explicit security rights. Record which metadata is covered; store timestamps/attributes needed by the restore contract separately. Finish/release its context even on error. EFS requires the separate raw-encrypted-file path; refusing it is preferable to a false full-backup claim. Persist the archive, verify its digest and readable structure, flush it, then durably record backup completion before deletion intent. [BackupRead](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-backupread), [FlushFileBuffers](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-flushfilebuffers).

6. **Delete by the retained handle.** After revalidating required metadata, persist deletion intent and call `SetFileInformationByHandle(FileDispositionInfo)` on the same object. Delete approved children before their empty parent. Record API outcome and delete-pending separately; close handles and inspect the parent/name before claiming disappearance. Preserve any replacement with a different identity. Do not switch to forced path recursion on failure. [SetFileInformationByHandle](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-setfileinformationbyhandle), [FILE_DISPOSITION_INFO](https://learn.microsoft.com/en-us/windows/win32/api/winbase/ns-winbase-file_disposition_info).

7. **Restore without overwriting.** Verify archive/operation binding, re-acquire the destination chain, and create a new object exclusively. Restore via `BackupWrite`, checking required rights for security restoration and rejecting unsupported stream kinds. Retain a restore journal before creating anything. A staging sibling can be committed with a handle rename and `ReplaceIfExists=false` relative to the verified parent; collision remains a conflict. Check restored streams, attributes and promised security afterward. [BackupWrite](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-backupwrite), [handle rename](https://learn.microsoft.com/en-us/windows/win32/api/winbase/ns-winbase-file_rename_info).

`OpenFileById` is useful for same-volume identity probes/recovery, but opening a historic ID alone does not establish its current reviewed location or content. Its documentation explicitly excludes SMB 3.0 support. Unsupported storage should return a precise capability limit, not fall back to weaker destructive operations. [OpenFileById](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-openfilebyid).

### Discriminating cleanup tests

Build expected resources independently of scanner defaults. A representative deliberately wrong implementation must fail each critical guard test.

| Fixture/fault | Expected independently observed result |
|---|---|
| Two apps share a publisher directory/component; only one is selected | Selected exclusive items removed; shared and sibling bytes/values unchanged. Repeat with both selected and a third owner still present. |
| Vendor creates new leftovers and modifies old ones after preview | Old approval cannot delete either unreviewed state; a fresh scan finds them. |
| Same path replaced after review; identical-length different bytes; same bytes with another file identity | Old identity/content authorization is rejected, including the same-bytes replacement. |
| Junction/symlink at root, ancestor or child; attempted ancestor rename during apply | No traversal/deletion outside the approved root; exact failure recorded. |
| Writable file handle/mapping held; new child inserted between enumeration and deletion | Busy file preserved; new child preserved; operation does not claim complete subtree removal. |
| Hard-linked file; alternate stream; read-only file; EFS file | Supported cases round-trip with promised fidelity; unsupported cases remain intact with a capability result. |
| Insufficient backup space, injected short read/write, corrupt archive, kill after backup or deletion intent | No unbacked deletion; restart reconciles the journal against actual identity/state without widening the selection. |
| Registry hive/view/SID collision; missing/default/empty value; changed sibling value or new subkey | Only exact reviewed resource eligible; scope or state conflict preserves current data. |
| Restore twice; destination recreated by another actor; corrupt backup | Idempotent verified result or explicit conflict; no silent overwrite or lost backup. |
| Queue crash/cancel/reboot plus concurrent second queue | No duplicate unresolved remover; per-app resource claims and recovery remain consistent. |

## Scheduling correctness before performance

Lasso already supports persistent CPU Sets and priority rules. GPU priorities are not inherited by child processes and do not have its registry enforcement route. Bitsum recommends lowering competing GPU workloads when protected targets reject changes. I/O priority is a hint, not a throughput or latency guarantee. These are compatibility boundaries, not deficiencies that a launcher trick can remove. [Persistent CPU Sets](https://bitsum.com/apps/process-lasso/docs/rules/cpu-sets/), [priority documentation](https://bitsum.com/apps/process-lasso/docs/rules/priorities/).

Windows documents that hard affinity and thread-specific selections can take precedence over process-default CPU Sets. A returned default list therefore proves configuration, not effective thread placement. [Microsoft CPU Sets](https://learn.microsoft.com/en-us/windows/win32/procthread/cpu-sets).

| State | Required control/result | Independent check |
|---|---|---|
| Fresh matching process | Bind executable/rule scope and process creation time; snapshot only intended controls | Native getter from a separate test process, not the executor's result object. |
| Relaunch, duplicate instance or PID reuse | Evaluate the rule for each new identity; never reuse an old instance's original values | Repeated launch/exit with deliberately different initial controls and an unrelated same-name executable. |
| Topology changed or requested set unavailable | Reject stale numeric selections or resolve a documented semantic selector against current topology | Non-contiguous IDs, changed cache/core groups and missing selected CPUs. No guessed even/odd SMT layout. |
| CPU Set readback matches but thread override/hard affinity conflicts | Report the process default and effective constraint separately | Independent per-thread queries and ETW placement evidence for an owned workload. |
| Target protected, excluded or access denied | Preserve target, return exact API/access/error; operate only on approved background targets | Denied target remains unchanged while a disposable background workload accepts the intended change. |
| Another controller changes a field | Detect conflict and avoid endless enforcement or restoring over its value | Independent writer alternates a selected field while another unrelated field is changed once. |
| Rule disabled, engine stops or process leaves a restraint cycle | Restore only still-owned values for a live matching identity | Original values restored; external changes and untouched fields retained. |
| Threshold noise, foreground switch or dependency becomes active | Bounded hysteresis/dwell and exclusions; no priority oscillation | Controlled load waveform, state-transition timestamps, voice/audio/capture progress. |

ProBalance's documented mechanism is temporary, selective background priority reduction with restoration, rather than constant foreground elevation. Its reported responsiveness benefit is a testable comparison claim. [ProBalance](https://bitsum.com/apps/process-lasso/docs/algorithms/probalance/).

## Fair workload comparison

Record exact executable/configuration hashes, OS build, driver, topology, power plan, display refresh/VRR/frame cap, graphics settings, GPU scheduling mode, background load, temperature and clock range. Pin measurement-tool versions and capture options. Save raw per-run data outside the tracked source tree.

Use four conditions: **neither controller**, **Roo Industries only**, **Lasso only**, and **both intentionally active**. The fourth measures interference, not additive performance. Compare equivalent explicit rules separately from each product's documented default adaptive mode. Lasso's governor can run without its GUI; verify process/service state and persistent settings before labeling a baseline clean. Preserve operator configuration and restore it after any authorized trial. [Lasso architecture](https://bitsum.com/apps/process-lasso/docs/).

| Workload | Foreground measurement | Competing-work measurement |
|---|---|---|
| Idle plus controlled process churn | Rule detection/apply delay and launch completion | Controller CPU time, private bytes, handle/thread count, disk/log growth. |
| CPU contention: short interactive bursts plus sustained workers | Wake-to-work completion, deadline misses, CPU ready-time distribution | Completed work/checksum, throughput and time to finish after restraint. |
| Storage contention: fixed small reads alongside sequential/random background I/O | Read latency p50/p95/p99 and IOPS | Background bandwidth, completed bytes and errors; fixed file/cache/queue-depth settings. |
| GPU contention: fixed render scene plus separate compute/render competitor | Displayed frame intervals, long-frame count, GPU busy/wait and verified adapter | Competitor completion/throughput; priority readback by process, not inherited-launch assumptions. |
| Mixed gameplay/replay with audio/capture/background activity | Frame distribution plus audio glitches/capture drops | Background progress and total power/thermal state where measured. |

Microsoft's WPA CPU analysis distinguishes Running, Ready and Waiting and uses precise scheduling traces to investigate ready delays. An application timer wakeup includes more than scheduling delay; label it accordingly. [CPU analysis](https://learn.microsoft.com/en-us/windows-hardware/test/wpt/cpu-analysis).

DiskSpd provides explicit latency collection (`-L`), warmup, duration, cache, queue and affinity controls; its own affinity/priority options must not silently counteract the optimizer. Run only on disposable files, never raw disks or user data. Retain XML and verify error counts. [DiskSpd parameters](https://github.com/microsoft/diskspd/wiki/Command-line-and-parameters), [latency interpretation](https://github.com/microsoft/diskspd/wiki/Analyzing-test-results).

PresentMon reports per-frame presentation/display and GPU metrics; metric availability depends on capture options and instrumentation. Preserve dropped/not-displayed frames and frame-type distinctions. Do not substitute presentation interval for input-to-photon latency; label estimated/instrumented latency by its actual source, and use hardware measurement for a hardware-latency claim. [PresentMon console metrics](https://github.com/GameTechDev/PresentMon/blob/main/README-ConsoleApplication.md).

The following are proposed engineering gates, not vendor guarantees:

- Run a pilot, then lock workload/configuration and randomized order before comparison. Start with at least ten paired blocks and a fixed warmup/capture duration; expand only if precision is insufficient. Analyze paired per-run outcomes, not millions of correlated frames as independent repetitions.
- Report p50/p95/p99, deadline misses or long frames per minute, throughput and sample counts. Report p99.9 only with adequate tail observations; disclose sparse tails. Keep all valid runs and predeclare exclusions such as failed capture or thermal throttling.
- Require the upper 95% confidence bound on the paired p99 latency ratio to stay within a predeclared non-regression margin, initially 1.05, for clean-system trials. Report uncertainty if the data cannot establish it. For an improvement claim, the interval must exclude no improvement in the named contention scenario while background work remains within a declared acceptable budget.
- Measure the complete resident engine separately with UI hidden and visible. Use CPU seconds per wall second and also a clearly normalized system percentage; include idle/churn overhead, startup delay, memory, wakeups, handles and log growth. A four-second working-set sample is a smoke measurement, not evidence of sustained low overhead.
- Keep process-control, benchmark, visual and per-game compatibility evidence separate. A disposable-process success or a no-error game session cannot establish future anti-cheat policy or a zero-ban guarantee.

## Measured CPU contention result

A run completed at **2026-09-15 19:14 UTC** on the i5-14600K/9070 XT test PC, Windows 11 build 26200. Ten paired blocks used randomized order with seed `16092026`; each condition ran for nine seconds. A separate earlier two-block pilot was excluded from these estimates.

The workload pinned two busy background threads and a periodic foreground worker to logical CPU 0. Every 20 ms, the foreground worker performed 500,000 dependent integer-mix iterations. Both fixture processes disabled dynamic priority boosts. The normal condition had no Roo Industries worker; the treatment used the real saved-rule host to lower only the background process from Normal to BelowNormal. This did not reserve the CPU against other software. The existing Ultimate Performance plan and Lasso configuration were left unchanged; Lasso process identities and binary hashes matched before and after the experiment.

| Measurement | Result |
|---|---|
| Valid paired blocks | 10; 450 timing samples per condition per block |
| Median of per-run p99 scheduled-to-finish time | Normal: 63.327 ms; Roo Industries rule: 1.937 ms |
| Paired p99 ratio, rule / normal | 0.0376; 95% bootstrap interval 0.0261–0.0560 |
| Paired background-throughput ratio, rule / normal | 0.9881; 95% bootstrap interval 0.9860–0.9902 |
| Median per-run fraction exceeding the 20 ms interval | Normal: 15.22%; Roo Industries rule: 0.22% |

Ratios use the geometric mean of paired run ratios. Confidence intervals resample whole paired blocks 10,000 times with seed `20260916`; individual bursts are not treated as independent runs. The predeclared gate required ten blocks, a p99-ratio upper bound below 1, and a background-throughput lower bound of at least 0.80. This run met that gate.

Independent Windows process APIs checked CPU time, priority, affinity and boost state; the original priority was restored before each fixture exited. A deliberately ineffective rule failed the native readback gate and left its result incomplete. The analysis also rejects contradictory controls, missing work, changed controller identity and incomplete recovery; a faster foreground result cannot override excessive background slowdown.

This establishes an effect of Roo Industries's background-priority rule in this synthetic workload. The timing includes timer wakeup, scheduling and work completion. It is not a measurement of CPU ready time, input latency or game frame time. Lasso stayed active in both conditions, so it is not an isolated comparison against Windows or a separately configured Lasso rule. Effective-clock/temperature traces, storage/GPU contention and protected-game trials are not covered by this result.

Raw JSON remains outside source control. Its SHA-256 is `b2c6b4706195eb236ff2dba6c383f34a7455ee051ff108b8d79b6c578c87c203`; the measured benchmark assembly SHA-256 is `02613e0f56070efcd27b20c6c175726232b5323d92be262fe1d1232f943cfe29`. The JSON also records the host/core binary hashes and complete per-run samples. Reproduce with `Measure-OptimizerCpu.ps1` and `tools/validation/analyze_cpu_measurement.py`.

## Measured storage tradeoff

A read-only storage run completed at **2026-09-15 20:16 UTC** on the same PC's WD_BLACK SN850X 4 TB NVMe drive. Ten randomized paired blocks used nine-second measured windows, two-second warmups and separate 512 MiB disposable files. Foreground reads were random 4 KiB at queue depth 1; background reads were sequential 128 KiB at queue depth 32. Both used one thread, disabled software caching and disabled DiskSpd's default CPU affinity. CPU priorities stayed Normal. The treatment used the saved-rule host to lower only the background process's I/O priority from Normal (2) to Low (1).

| Measurement | Result |
|---|---|
| Median per-run foreground read p99 | Normal: 0.983 ms; Low: 0.076 ms |
| Paired foreground p99 ratio, Low / Normal | 0.07694; 95% interval 0.07635–0.07752 |
| Median background read throughput | Normal: 6,564 MiB/s; Low: 1.714 MiB/s |
| Paired background-throughput ratio, Low / Normal | 0.000261; 95% interval 0.000223–0.000305 |
| Balance gate | Failed: only about 0.026% of background throughput remained |

The analysis uses the same paired-block bootstrap method and 0.80 background-retention floor as the CPU experiment. The faster foreground reads do not establish an overall performance win: the background workload was starved under this sustained contention. These results argue against treating a persistent Low I/O rule as a universally beneficial default. They do not establish the behavior of every device, workload or priority level. Lasso remained active and unchanged; this was not an isolated comparison against its own equivalent rule.

The harness used the [Microsoft DiskSpd 2.3 release](https://github.com/microsoft/diskspd/releases/tag/v2.3), amd64 binary SHA-256 `dd4e57e1e8ccaf5d6437938f8aab7f17e9a1e6d8fba8a093006b7cadf16faea2`. Its default Normal file-I/O hint does not call the per-file priority setter, so no `-I` option was used to manufacture the treatment. A native probe found that this build's `-ys`/`-yf` notification events did not signal; the harness uses working shared `-yr`/`-yp` start/stop controls and checks actual XML durations instead. See the [pinned generator](https://github.com/microsoft/diskspd/blob/v2.3/IORequestGenerator/IORequestGenerator.cpp) and [command options](https://github.com/microsoft/diskspd/wiki/Command-line-and-parameters).

Before every treatment, the rule was applied, paused and independently read back as restored while the process was alive, then restarted for measurement. After the read processes exited, their exact instances were reconciled as expired. XML checks confirmed paths, blocks, queue depths, cache mode, nonzero read counts, zero writes and matched measured durations. File hashes were unchanged and fixture processes/data were removed. A deliberately ineffective rule failed the native readback gate and left its result incomplete.

Raw JSON SHA-256: `25b2c813a91aed0cd49964e45ac294ab0d7ccfc214a26a1f0827043b6494f626`. Measured harness assembly SHA-256: `3ae4b4b87414a0d3135c117cfc848a45a262279f5d8b9bd11e475a467ce5582d`. Raw JSON/XML and plots remain outside source control. Reproduce with `Measure-OptimizerStorage.ps1` and `tools/validation/analyze_storage_measurement.py`.

## Measured GPU contention result

A run completed at **2026-09-15 20:49 UTC** on the RX 9070 XT, explicitly selected by vendor/device ID and bound to the same adapter LUID in both workload processes. Ten paired nine-second blocks used randomized order with seed `16092026`. The foreground submitted an offscreen Direct3D11 compute dispatch every 20 ms: 16,384 elements and 256 dependent integer-mix iterations. The background used 262,144 elements, 4,096 iterations and four dispatches per batch. Both CPU priorities stayed Normal, with dynamic boosts disabled. The treatment lowered only the background GPU priority from Normal (2) to BelowNormal (1) through the real saved-rule host.

| Measurement | Result |
|---|---|
| Median per-run scheduled-to-completion p99 | Normal: 2.641 ms; BelowNormal: 2.646 ms |
| Paired foreground p99 ratio, rule / normal | 1.00297; 95% interval 0.99183–1.01229 |
| Median background dispatches per second | Normal: 1,790.86; BelowNormal: 1,790.70 |
| Paired background-throughput ratio | 0.99977; 95% interval 0.99847–1.00121 |
| Improvement gate | Not met: the foreground interval includes no improvement |

The analysis uses the same paired-run method and background-retention floor as the CPU and storage experiments. This workload did not show a clear benefit from the GPU-priority change. Readback established the requested configuration; it did not establish a speedup.

CPU submission/completion timing was recorded before output verification and kept separate from GPU timestamp intervals. Each query was polled independently, with disjoint or unordered timestamps rejected. Four output values spread across each buffer were recomputed on the CPU after timing; deterministic foreground values matched across conditions. The original GPU priority was independently verified before the processes exited. Deliberately ineffective priority and incorrect-shader variants both failed their intended checks and left incomplete results.

This is an offscreen compute result, not presented frames, input latency or gameplay. Existing Lasso processes remained active and unchanged in both conditions. A later read-only inspection found that the installed Lasso GUI/governor had signature hash mismatches, so this environment must not be represented as a verified stock-vendor comparison. No service or installation change was made. Per-game and isolated-controller comparisons remain separate work.

Raw JSON SHA-256: `defb3304c617a549ec6553f450244fa70f087253f0f0f174b14524b0d81ff3d9`. Measured benchmark assembly SHA-256: `c910f884b572c8cdfdf0af7ae2834768b447bb2894d020408a74d574560cad79`. Raw samples, controller hashes and plots remain outside source control. Reproduce with `Measure-OptimizerGpu.ps1` and `tools/validation/analyze_gpu_measurement.py`.

## Stock-reference CPU comparison

The final run completed on **2026-09-16 at 06:42 UTC** on the same 9070 XT/i5-14600K PC. Ten randomized blocks contained normal priority, Roo Industries and stock Process Lasso conditions, each lasting nine seconds with 450 foreground samples. Both controllers set only the disposable background process to BelowNormal. Their configured polling interval was 500 ms; Lasso used the current `Performance.UpdateSpeedCore` setting. The original governor service was temporarily stopped under an approved recovery guard, then restored with its startup mode, executable path and configuration hash unchanged. The existing Lasso GUI remained open in all conditions.

The reference was the publisher's signed **18.3.0.34** governor, SHA-256 `EA338D4C47F61BB3AA107A26DE3614D112F19DA9438291B3A8212F21BB01D495`. Its installer was extracted without installation. Private Windows-written INI files and unquoted short paths established working rule application; the benchmark does not alter the installed Lasso configuration. The publisher documents private configuration paths. The current engine key was also checked against the verified binary and the installed configuration; the older online INI example's `UpdateSpeed` key must not be treated as the current core setting. [Command-line reference](https://bitsum.com/apps/process-lasso/docs/reference/command-lines/), [INI reference](https://bitsum.com/apps/process-lasso/docs/reference/ini-config/).

| Measurement | Result |
|---|---|
| Median per-run foreground p99 | Normal: 74.594 ms; Roo Industries: 2.902 ms; Lasso: 1.419 ms |
| Paired Roo Industries / normal p99 ratio | 0.04149; 95% interval 0.02676–0.06581 |
| Paired Lasso / normal p99 ratio | 0.02357; 95% interval 0.01632–0.03906 |
| Paired Roo Industries / Lasso p99 ratio | 1.76054; 95% interval 0.85000–3.21704 |
| Background throughput retained versus normal | Roo Industries: 98.21%; Lasso: 97.89% (paired geometric ratios) |
| Paired Roo Industries / Lasso background-throughput ratio | 1.00325; 95% interval 0.98931–1.02132 |
| Controller CPU accumulated over ten measured windows | Roo Industries: 3.53125 s; Lasso: 0.15625 s, across 90 s per condition |
| Controller private bytes, nearest-rank p50 | Roo Industries: 14.21 MB; Lasso: 3.71 MB (decimal MB) |
| Roo Industries versus Lasso improvement / 5% non-regression gates | Neither established |

Both explicit rules improved this synthetic workload versus normal priority while retaining background progress. **The comparison does not establish a Roo Industries latency advantage or its predeclared 5% non-regression bound against Lasso.** The wide interval also does not establish that the point-estimate slowdown is repeatable. Roo Industries used more observed controller CPU and private memory. Process CPU counters were quantized; an individual zero sample is not zero CPU use. These short windows follow fresh controller starts and are not a sustained-idle overhead measurement. Startup-to-apply includes configuration preparation and remains separate from workload timing.

All final runs were retained. Earlier pilots and a run using the outdated polling-key name were excluded from this matched estimate before interpretation; their raw evidence remains separate. The final build includes the [measured allocation reduction](process-polling.md). That component improvement does not establish a game or controller-latency speedup. Effective-clock/temperature traces were not captured, and these offscreen CPU workers do not measure presented frames, input latency or an adaptive ProBalance comparison.

A competing installed governor was rejected before measurement. An intentionally unmatched reference rule failed the independent Windows priority readback and left the result incomplete. Each completed trial checked placement, boost state, original-priority restoration and controller isolation. Lasso fixture priority was restored by the harness after terminating its exact owned reference instance; Roo Industries restored its own journaled change. Analysis rejects missing conditions, altered reference identity, contradictory control/recovery data and background starvation.

Raw final JSON SHA-256: `dbaa4bf2b20d6533753662c0f9d09104be49b500e92f57a1bb5a15697873f410`. Benchmark assembly SHA-256: `533484A12A0D4A0582BC47104A7FEBCAF0760DF7EE9C60902615A16E878BFFD3`; Host: `67DB9F639AC73FC6039F0DD055BC44DBB5CF99106272F3A381E3ECFBB35B3A14`; Core: `70E306FBD9F021C4DD32A8EC1E02755AD214EA71BB88A76FB5370B09B826B876`. Reproduce with `Measure-OptimizerReference.ps1` and `analyze_reference_measurement.py` under an approved service-recovery guard.

## Protected-game validation limit

A normal Steam launch of the installed Overwatch title reached a warning that continuing would disconnect another computer's active CS2 session. The launch was cancelled, no Overwatch process was started, and the original Steam process remained running with its window hidden again. Screenshots and process observations were retained privately. Actual protected-game behavior remains unverified; the separate launcher-inheritance/access-denial fixture is not a substitute for gameplay evidence.

## Implementation order and closure

The starting baseline exposed metadata/rule-based candidate scanning, separate file recovery and a process footprint script. Their historical tests do not establish coverage of every requirement above. The implementation sequence is:

1. Exact resource ownership/conflict records, then registry backup/delete/restore and native handle-based file execution.
2. Grouped batch leftover review, orphan cleanup and honest trace/snapshot provenance using that same executor.
3. Persistent topology-aware rules across process lifecycles, complete per-field readback and external-writer handling.
4. Independent fixture corpus and repeated CPU/I/O/GPU measurements, followed by actual operator/visual checks.

Close each table row only with the tested revision, named truth surface and outcome. Unsupported capability states must identify the precise missing API, right or backup format; they must not make an untested feature appear complete. Preserve uncertain removal states, changed user data and competing-controller changes through recovery.
