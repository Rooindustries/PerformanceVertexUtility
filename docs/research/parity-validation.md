# Removal and scheduling acceptance criteria

Checked against primary sources on **2026-09-15**. Repository starting point: `8df0c71bc22655e522f864ffb9a93ad6ea250371`. This report defines the cleanup contracts and comparison protocol, including broader parity work such as installation tracing. It is not an execution report. See [optimization controls](../optimization-controls.md) for implemented workflows, reusable checks and current limits; keep runtime evidence bound to the tested revision.

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

Use four conditions: **neither controller**, **Roo only**, **Lasso only**, and **both intentionally active**. The fourth measures interference, not additive performance. Compare equivalent explicit rules separately from each product's documented default adaptive mode. Lasso's governor can run without its GUI; verify process/service state and persistent settings before labeling a baseline clean. Preserve operator configuration and restore it after any authorized trial. [Lasso architecture](https://bitsum.com/apps/process-lasso/docs/).

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

## Implementation order and closure

The starting baseline exposed metadata/rule-based candidate scanning, separate file recovery and a process footprint script. Their historical tests do not establish coverage of every requirement above. The implementation sequence is:

1. Exact resource ownership/conflict records, then registry backup/delete/restore and native handle-based file execution.
2. Grouped batch leftover review, orphan cleanup and honest trace/snapshot provenance using that same executor.
3. Persistent topology-aware rules across process lifecycles, complete per-field readback and external-writer handling.
4. Independent fixture corpus and repeated CPU/I/O/GPU measurements, followed by actual operator/visual checks.

Close each table row only with the tested revision, named truth surface and outcome. Unsupported capability states must identify the precise missing API, right or backup format; they must not make an untested feature appear complete. Preserve uncertain removal states, changed user data and competing-controller changes through recovery.
