# Process control contracts and persistent rules

Checked: **2026-09-15**. Source review: **`8df0c71bc22655e522f864ffb9a93ad6ea250371`**. This supplements [the process-management research](process-management.md). No Windows process, game, registry, or frontend was accessed for this report. Runtime checks below are pending; they are requirements, not reported passes.

## Implementation direction

Complete memory priority, execution-speed policy, dynamic boosts, and saved CPU Set rules through one reversible process-control boundary. Keep query availability, requested policy, observed state, and application performance separate. Extend the existing CPU Set identity and journal model rather than teaching every caller a different restoration rule.

Process Lasso already exposes persistent CPU/GPU/I/O/memory priorities, boost settings, CPU Sets, and Efficiency Mode rules. Its current I/O menu also lists High, beyond Roo's VeryLow/Low/Normal implementation. Matching these controls establishes feature coverage; superiority requires measurements or a demonstrably better workflow. [Bitsum priorities](https://bitsum.com/apps/process-lasso/docs/rules/priorities/), [CPU Sets](https://bitsum.com/apps/process-lasso/docs/rules/cpu-sets/), [Efficiency Mode](https://bitsum.com/apps/process-lasso/docs/rules/efficiency-mode/).

## Native boundary

Use explicit handle access rather than a general-purpose `Process.Handle`. In this table, QL means `PROCESS_QUERY_LIMITED_INFORMATION`, SET means `PROCESS_SET_INFORMATION`, and SETL means `PROCESS_SET_LIMITED_INFORMATION`. Rights are requested permissions, not evidence that opening a particular target will succeed. [Process access rights](https://learn.microsoft.com/en-us/windows/win32/procthread/process-security-and-access-rights).

| Control | Query and mutation contract | Required distinctions |
| --- | --- | --- |
| CPU priority | `GetPriorityClass`: QL or QUERY_INFORMATION; zero is failure. `SetPriorityClass`: SET; BOOL plus immediate Win32 error. | Preserve the actual original class. CPU priority is not GPU, memory, or I/O priority. Background begin/end flags work only for the calling process. [Getter](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-getpriorityclass), [setter](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-setpriorityclass). |
| Hard affinity | `GetProcessAffinityMask`: QL or QUERY_INFORMATION; returns process and system masks. `SetProcessAffinityMask`: SET. | A zero mask can reflect multi-group limitations even after a successful getter. It is not an unrestricted-mask sentinel. Validate against the target's group and system mask. [Getter](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-getprocessaffinitymask), [setter](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-setprocessaffinitymask). |
| Process CPU Sets | `GetProcessDefaultCpuSets`: QL; counts IDs, not bytes. Success with zero IDs means no explicit defaults. `SetProcessDefaultCpuSets`: SETL; null/zero clears defaults. | Empty known state is valid; unavailable state is not empty. The default applies inside this process and does not establish child-process inheritance. [Getter](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-getprocessdefaultcpusets), [setter](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-setprocessdefaultcpusets). |
| Memory priority | `GetProcessInformation`/`SetProcessInformation`, `ProcessMemoryPriority`, `MEMORY_PRIORITY_INFORMATION`; query QL, setter SET. | Documented values are 1 VeryLow, 2 Low, 3 Medium, 4 BelowNormal, 5 Normal. Five is the system default, not a substitute for a failed original-state query. [Getter](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-getprocessinformation), [setter](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-setprocessinformation), [values](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/ns-processthreadsapi-memory_priority_information). |
| Execution-speed policy | The same information APIs with `ProcessPowerThrottling` and a three-ULONG structure; QL/SET. | Keep `Version`, `ControlMask`, and `StateMask`. A Boolean loses system ownership. [Structure](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/ns-processthreadsapi-process_power_throttling_state), [getter](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-getprocessinformation). |
| Dynamic boosts | `GetProcessPriorityBoost`: QL or QUERY_INFORMATION. `SetProcessPriorityBoost`: SET. | The native Boolean means **disable**: true disables, false enables. A user-facing `boostsEnabled` value is its inverse. The setter affects existing and subsequently created threads. [Getter](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-getprocesspriorityboost), [setter](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-setprocesspriorityboost). |
| GPU scheduling class | `D3DKMTGetProcessSchedulingPriorityClass`/`D3DKMTSetProcessSchedulingPriorityClass`, Gdi32, NTSTATUS. | The published pages do not specify minimum process-handle rights or an exhaustive per-driver support matrix. Report the rights actually requested and the returned status; do not call an untested rights choice a documented requirement. [Getter](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/d3dkmthk/nf-d3dkmthk-d3dkmtgetprocessschedulingpriorityclass), [setter](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/d3dkmthk/nf-d3dkmthk-d3dkmtsetprocessschedulingpriorityclass). |
| Process I/O priority | Existing code uses NT process-information class 33 through `NtQueryInformationProcess`/`NtSetInformationProcess`. | This class is outside Microsoft's documented query-class list. Treat it as an optional internal interface, retaining native errors and runtime evidence. Do not present it as a fully documented Win32 process setter. [NT interface contract](https://learn.microsoft.com/en-us/windows/win32/api/winternl/nf-winternl-ntqueryinformationprocess). |

The SDK declares Win32 information-class ordinals `ProcessMemoryPriority=0`, `ProcessPowerThrottling=4`, and `ProcessProtectionLevelInfo=7`. Power-policy version is 1; execution-speed flag is `0x1`; ignore-timer-resolution flag is `0x4`. Do not mix these ordinals with NT `PROCESSINFOCLASS`. [Microsoft SDK declarations](https://github.com/microsoft/win32metadata/blob/main/generation/WinSDK/RecompiledIdlHeaders/um/processthreadsapi.h).

Memory priority changes page-retention preference, not committed-memory limits or a promised number of freed bytes. It has thread-level counterparts, so process readback is not a measurement of every existing page. [Memory semantics](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/ns-processthreadsapi-memory_priority_information), [thread information](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-setthreadinformation).

GPU classes enumerate Idle through Realtime. API availability does not promise every target or class will be accepted. Preserve query failure independently from setter failure and readback mismatch. Bitsum reports that its GPU rules do not inherit to children and cannot use its registry priority mechanism; treat that as vendor implementation evidence, not permission from anti-cheat vendors. [GPU enum](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/d3dkmthk/ne-d3dkmthk-_d3dkmt_schedulingpriorityclass), [Bitsum GPU limitations](https://bitsum.com/apps/process-lasso/docs/rules/priorities/#gpu-priority-classes).

NTSTATUS is not a Win32 last-error value. Preserve its raw 32-bit hexadecimal value and distinguish success/informational statuses from warnings/errors; a general `status == 0` test recognizes only one success code. Validate returned data as well. [Microsoft NTSTATUS guidance](https://learn.microsoft.com/en-us/windows-hardware/drivers/kernel/using-ntstatus-values).

For owned file operations, `FILE_IO_PRIORITY_HINT_INFO` provides a documented per-file-handle alternative with VeryLow/Low/Normal. Drivers decide whether to honor these hints. That is not a replacement for changing an arbitrary process's already-open handles. High process I/O priority needs separate evidence before expanding Roo's allowlist. [File I/O hints](https://learn.microsoft.com/en-us/windows/win32/api/winbase/ns-winbase-file_io_priority_hint_info), [file setter](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-setfileinformationbyhandle).

## Execution-speed decision table

Let E be execution-speed bit `0x1`. The table describes an observed process policy, not measured core placement. Microsoft documents explicit on, explicit off, and return to system management. On Windows 11 the enabled mode is EcoQoS; older Windows uses LowQoS. [Setter examples](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-setprocessinformation).

| Evidence | `ControlMask & E` | `StateMask & E` | Interpretation and permitted action |
| --- | --- | --- | --- |
| Query succeeded; supported version | E | E | Explicit execution-speed throttling on. |
| Query succeeded; supported version | E | 0 | Explicit throttling off; not system default. |
| Query succeeded; supported version | 0 | 0 | No caller override for E; system managed. |
| Query succeeded; supported version | 0 | E | No caller control of E. Retain raw state; do not label this an explicit EcoQoS request. The public pages do not fully define this query combination or its round-trip behavior. Test it independently. |
| Query failed, fields missing, unsupported version, or unknown flags | Any | Any | Unknown; no reversible mutation is authorized from this snapshot. Other independently readable controls can remain usable. |

`ControlMask` determines caller control; `StateMask` carries on/off state. A state bit alone must not be used to identify ownership. [Field contract](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/ns-processthreadsapi-process_power_throttling_state).

Recommended construction for an E-only operation is `C' = (C & ~E) | desiredControl` and `S' = (S & ~E) | desiredState`, using a fresh readable pair. Desired pairs are E/E, E/0, or 0/0. This preserves another mechanism's policy; globally zeroing both masks would also release a timer-resolution override. These formulas are an implementation recommendation derived from the mask contract, not evidence that every possible observed pair is accepted by every OS build.

Snapshot raw masks and the E policy separately. During restore, compare the current E policy with this operation's last accepted E policy and preserve the latest unrelated bits. If an observed pair cannot be round-tripped through the documented representation, leave it unchanged and report the limitation. Do not silently discard unfamiliar bits. The three canonical policies, timer-only policies, and mixed policies require actual getter/setter/readback tests before claiming full restoration.

HighQoS is separate from High CPU priority and does not guarantee P-core-only placement. Windows also considers thread policy, multimedia classification, audibility, visibility, and heuristics. A process-only control must not claim that every thread has the same effective QoS. The thread setter is documented; the current thread getter page does not list `ThreadPowerThrottling`, so thread-wide reversible enforcement requires additional support evidence. [QoS classification](https://learn.microsoft.com/en-us/windows/win32/procthread/quality-of-service), [thread getter](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-getthreadinformation), [thread setter](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-setthreadinformation).

## Identity, persistence, and restoration

A PID identifies a process only during its lifetime. A retained handle continues to identify the same object after termination. Get creation FILETIME and executable path through that handle; do not reopen by PID between identity verification and mutation. [Process identity lifetime](https://learn.microsoft.com/en-us/windows/win32/procthread/process-handles-and-identifiers), [creation time](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-getprocesstimes), [image path](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-queryfullprocessimagenamew).

**Liveness is independent of creation identity.** `GetProcessTimes` leaves exit FILETIME undefined for a live process. `GetExitCodeProcess` provides a query-limited liveness indication, but exit code 259 can be ambiguous because an exited application can return that value. A zero-time wait on a process handle with `SYNCHRONIZE` distinguishes signaled/unsignaled state; if those rights are unavailable, report the unresolved condition rather than inferring termination. [Exit time](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-getprocesstimes), [exit code](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-getexitcodeprocess), [wait contract](https://learn.microsoft.com/en-us/windows/win32/api/synchapi/nf-synchapi-waitforsingleobject).

The following is the proposed Roo transaction contract. Windows supplies setters, not cross-control transactions or compare-and-set ownership. Required evidence is the approved policy/revision, machine and user binding, executable selector, exact process instance, per-control known original state, current exclusion/protection result, and durable per-field intent/readback.

| Event / independent signals | Expected transition |
| --- | --- |
| Enabled rule; matching executable; new known instance; allowed target; original query known | Resolve controls against current topology. Persist original state and intended changes before mutation, then apply and read back each field. |
| Matching name but different required path/user, missing required selector evidence, or disabled rule | No apply. An executable basename is not proof of a path-bound match. |
| Same PID with different creation time, even if path matches | New instance. Never replay the prior instance's originals. A saved rule can create a fresh transaction. |
| Old target exited; same executable starts under another PID | Close old-instance ownership without restoration. Resolve and snapshot the new instance independently. |
| Desired value already present before Roo writes | Record a no-op, not ownership. Removing the rule must not invent a previous value. |
| Original query unknown, even if setter access succeeds | No write for that field; restoration would be impossible to substantiate. |
| Rule or manual session overlaps an active field owner | One deterministic owner. Reject or explicitly supersede with an ownership transfer; do not let workers alternate writes. |
| Current field differs from the last accepted Roo write | External drift. Preserve it on ordinary restore. Persistent re-enforcement, if exposed, needs an explicit rule mode and bounded conflict policy. |
| Unrelated control or unrelated power-policy bit changes | Preserve it. Ownership is per field/mechanism, not the entire process snapshot. |
| Setter succeeds and exact field readback matches | Mark that field applied; only then update its last-accepted state. |
| Setter succeeds but readback fails or differs | Mark needs-reconciliation, retain original/intent/observation, and do not report completed application or unconditional rollback safety. |
| A later field fails after earlier fields changed | Restore only earlier owned fields whose live state still matches their last accepted values. Retain conflicts and unresolved writes. |
| Restore sees original already present | No write; record already-original. If it sees last-applied instead, restore original and independently read back. |
| Retry, duplicate stop, or recovery after worker interruption | Reconcile durable intent against the exact live instance. Completed work is idempotent; malformed, foreign, incomplete, or conflicting journals do not authorize writes. |

Compare again immediately before a setter, but acknowledge the remaining external race. A second actor can write the same value or change away and back; equality alone cannot prove exclusive historical ownership. Never claim atomic multi-tool arbitration.

Saved-rule identity and instance identity serve different purposes. Persist the executable selector and desired policy; keep PID/creation time/original values only in per-instance journals. Rule revision changes and rule deletion must not erase recovery data before active ownership is reconciled. CPU affinity has documented child inheritance, while Idle/BelowNormal CPU classes can also affect default child creation; test launchers and children separately. [Affinity inheritance](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-setprocessaffinitymask), [priority inheritance](https://learn.microsoft.com/en-us/windows/win32/procthread/scheduling-priorities).

## CPU topology selectors

| Selector / observed state | Contract and resolution rule |
| --- | --- |
| Explicit CPU selection | Store `(Group, LogicalProcessorIndex)` plus topology evidence; resolve current IDs from fresh enumeration. Numeric IDs have no documented cross-boot or cross-machine stability guarantee. |
| One hardware thread per core | Group by `(Group, CoreIndex)` and choose one deterministic member. Do not assume even indexes identify physical cores. |
| Performance or efficiency cores | Higher `EfficiencyClass` means faster and less efficient. If there is only one class, report that no heterogeneous split was observed rather than inventing P/E labels. |
| Cache or NUMA selection | Key indexes with Group. A cache-sharing index does not identify a vendor CCD or cache capacity. |
| SchedulingClass | Preserve for diagnostics. The public structure page gives no semantics; do not use it as a documented fastest-core ranking. |
| Unknown record type or longer record | Skip unknown types and advance by each record's Size; reject malformed/truncated records instead of producing empty topology. |

These rules derive from the CPU Set structure; selection behavior is a Roo recommendation. Independent core relationships can corroborate SMT and efficiency classes. [CPU Set fields](https://learn.microsoft.com/en-us/windows/win32/api/winnt/ns-winnt-system_cpu_set_information), [processor relationships](https://learn.microsoft.com/en-us/windows/win32/api/winnt/ns-winnt-processor_relationship).

Allocation is target-relative: enumerate with the actual process handle. A set allocated elsewhere can be ignored by Windows; Roo should reject it rather than claim placement. Parked sets remain real topology entries. Thread-selected sets and restrictive hard affinity take precedence over process defaults, so exact default-list readback is not proof of every thread's execution location. [Enumeration](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-getsystemcpusetinformation), [CPU Set scheduling](https://learn.microsoft.com/en-us/windows/win32/procthread/cpu-sets).

Windows 11/Server 2022 defaults can span processor groups. A scalar hard-affinity mask still represents one group, and setting it can fail when a target explicitly assigned a thread outside its primary group. Use CPU Sets for a process preference spanning groups. [Processor groups](https://learn.microsoft.com/en-us/windows/win32/procthread/processor-groups), [affinity limits](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-setprocessaffinitymask).

The Windows 11 mask-form CPU Set APIs can independently verify ID-to-group mapping: they map IDs to home processors in `GROUP_AFFINITY` records. Keep them optional if Windows 10 remains supported. If a saved selector resolves to nothing, a group disappears, or topology changes incompatibly, stop with an explicit stale-selection result; only a distinct reset action clears defaults. [Mask getter](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-getprocessdefaultcpusetmasks), [mask setter](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-setprocessdefaultcpusetmasks).

## Permission and compatibility evidence

Keep `apiPresent`, `queryKnown`, `writeAccepted`, `readbackMatched`, `protectionKnown`, and `gameCompatibilityObserved` independent. Known Windows protection can exclude a target; `PROTECTION_LEVEL_NONE` does not establish a third-party game's policy. A failed query is not unprotected. [Protection structure](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/ns-processthreadsapi-process_protection_level_information), [process security](https://learn.microsoft.com/en-us/windows/win32/procthread/process-security-and-access-rights).

A denial should retain the API, exact access mask, target identity, native error, and relevant OS/helper architecture. It must not trigger a stronger-rights, driver, injection, or protection-changing fallback. Continue approved controls on accessible background workloads. API success establishes OS state, while a normal protected-game run is only evidence for that tested build/session. Neither establishes better frame pacing or future sanction policy. These are product evidence boundaries, not claims of vendor certification.

## Required independent checks

| Check | Failure it must detect |
| --- | --- |
| Power policy matrix | Exercise E on/off/default with timer policy absent/on/off; vary both masks independently. Include missing fields, state-only E, unknown bits/version, and failed getters. A mutation that derives policy from StateMask alone must fail. |
| Power restoration | Start with a non-default timer policy; change E; let another actor alter timer policy; restore E while preserving the new timer policy. Do not accept a globally zeroed restore. |
| Memory and boost | Start from non-default originals. Verify native values after apply and restore; an inverted boost Boolean and a default-to-5 restore must fail. |
| Unknown queries | Feed query failure independently for CPU, affinity, I/O, GPU, memory, power, and boosts while other queries succeed. No unknown field may be written or marked restored. |
| Identity and liveness | Exit/relaunch, same-name different-path, changed creation identity, unavailable identity, and exit code 259. Never let the previous instance's journal authorize the new instance. |
| External writers and no-ops | Write a conflicting controlled field, an unrelated field, and an initially already-desired field. Ordinary restore must preserve all three cases appropriately. |
| Partial execution/recovery | Fail after the first write, fail readback, interrupt between intent/write/observation, repeat apply/stop, and load malformed/foreign journals. Inspect live values, not just status strings. |
| Persistent rule lifecycle | Relaunch matching executable, run two instances, edit/disable/delete rules, restart worker, and overlap sessions. Verify per-instance originals and deterministic field ownership. |
| Topology | Use noncontiguous IDs, repeated group-relative core indexes, one versus multiple efficiency classes, stale IDs, foreign allocation, parked CPUs, malformed records, and an empty selector. Index-as-ID and empty-as-reset mutations must fail. |
| Actual Windows writes | On disposable processes, independently query every changed native field before/after/restore. A supported setter on one process does not close a denied/unsupported target case. |
| Scheduling effects | Separate process defaults from thread selections and hard affinity. Hardware execution on multiple groups remains pending until a suitable machine is used; parser fixtures cannot establish it. |
| Performance and protected games | Measure repeated matched workloads and frame-time distributions, governor overhead, and background completion. Preserve game/build/settings and anti-cheat outcomes. Do not replace these checks with successful API calls. |

The earlier research contains a broader benchmark protocol. QoS benchmarking must also record visibility, audibility, power source, and inactivity: Windows documents that inactivity can change inferred QoS and skew unattended measurements. [QoS behavior](https://learn.microsoft.com/en-us/windows/win32/procthread/quality-of-service).

## Source concerns in the reviewed baseline

1. [CPU Set identity](../../backend/native/CpuSets/RooCpuSets.cs) tests exit FILETIME against zero although the live-process value is undefined by contract. Replace that inference with explicit liveness evidence.
2. [Native governor](../../backend/native/ProcessGovernor/RooProcessGovernor.cs) maps failed CPU/I/O queries to null and affinity queries to zero; preview construction can still propose changes. Preserve per-control query status and require known originals.
3. The native governor has conflict-aware restore comparisons, but `ApplyChanges` and restoration do not perform immediate exact readback before reporting the field result. Add field-level observation and reconciliation; preserve the existing external-writer checks.

These are source findings at the stated revision. This report does not modify those implementations or claim a reproduced Windows failure.

## I/O High, privilege scope, and exact read rights

Follow-up checked **2026-09-15**, without machine access.

**I/O High is an internal process-control capability, not a fully documented application guarantee.** The WDK enum orders VeryLow=0, Low=1, Normal=2, High=3, and Critical=4; Microsoft reserves High and Critical for system use in the documented IRP interface. `ProcessIoPriority=33` remains outside the public NT query-class contract. No documented arbitrary-process High setter was found. [WDK enum](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/wdm/ne-wdm-_io_priority_hint), [NT query contract](https://learn.microsoft.com/en-us/windows/win32/api/winternl/nf-winternl-ntqueryinformationprocess).

Original implementation evidence is more permissive than that public surface. System Informer's own adapter uses a four-byte `IO_PRIORITY_HINT`, QL for query, and SET for mutation; its action code specifically identifies missing `SeIncreaseBasePriorityPrivilege` as a possible I/O-set failure. These are that project's implementation findings, not a Microsoft support promise. Its driver fallback is outside Roo's proposed path. [Adapter](https://github.com/winsiderss/systeminformer/blob/master/phlib/nativeprocess.c), [action handling](https://github.com/winsiderss/systeminformer/blob/master/SystemInformer/actions.c). The original 2013 Windows 7 SP1 kernel analysis identifies the privilege check specifically for High; this corroborates the historical gate, not current Windows 11 behavior. [Original research](https://waleedassar.blogspot.com/2013/02/kernel-bug-1-processiopriority.html).

Microsoft documents `SeIncreaseBasePriorityPrivilege` as the scheduling-priority privilege, distinct from `SeDebugPrivilege`. Enabling it when it is already assigned to the caller is a normal token operation; it does not grant a denied target handle or establish game permission. An API-rejected High request must remain rejected unless its exact missing requirement is satisfied through the normal authorized caller context. [Privilege definitions](https://learn.microsoft.com/en-us/windows/win32/secauthz/privilege-constants).

Use `AdjustTokenPrivileges` only on the effective caller token, preserving an existing impersonation context. It requires TOKEN_ADJUST_PRIVILEGES and also TOKEN_QUERY when saving PreviousState. Check both its BOOL result and last error: nonzero with ERROR_NOT_ALL_ASSIGNED does not enable an absent privilege. It cannot add privileges. Restore PreviousState on every exit. [Adjustment contract](https://learn.microsoft.com/en-us/windows/win32/api/securitybaseapi/nf-securitybaseapi-adjusttokenprivileges). Keeping the enablement inside a serialized operation or a dedicated scoped thread context is a Roo recommendation to avoid affecting unrelated concurrent calls.

| High request evidence | Expected result |
| --- | --- |
| Native call returns STATUS_PRIVILEGE_NOT_HELD; required privilege is absent | Report the precise missing privilege; no policy/ACL changes and no claim that High was applied. |
| Privilege present but disabled | An explicit High operation can attempt scoped enablement, native value 3, exact query readback, original-value restoration, and privilege-state restoration. Record the OS build and each outcome. |
| Privilege enabled but native setter still rejects | Preserve raw NTSTATUS; privilege availability is not proof of acceptance. Do not substitute Critical or malformed values. |
| Native setter succeeds and readback is 3 | Report observed process-priority support for this build/target. This does not establish driver scheduling effect or remove the documented support limitation. |

The required probe varies only the effective privilege state while retaining the same owned target and valid value. It must also cover privilege absence, failed enablement, native rejection after enablement, and cleanup after a failure. Current Windows 11 High acceptance remains pending this probe. The documented alternatives remain per-file VeryLow/Low/Normal hints or current-process background mode; neither sets arbitrary-process High. [File hints](https://learn.microsoft.com/en-us/windows/win32/api/winbase/ns-winbase-file_io_priority_hint_info), [background mode](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-setpriorityclass).

| Getter on current Windows | Minimum documented process right |
| --- | --- |
| `GetProcessAffinityMask` | QL (`0x1000`); QUERY_INFORMATION also accepted. [Contract](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-getprocessaffinitymask). |
| `GetProcessGroupAffinity` | QL (`0x1000`); QUERY_INFORMATION also accepted. Buffer counts are USHORT elements; retry ERROR_INSUFFICIENT_BUFFER using the returned count. [Contract](https://learn.microsoft.com/en-us/windows/win32/api/processtopologyapi/nf-processtopologyapi-getprocessgroupaffinity). |
| `GetPriorityClass` | QL (`0x1000`); QUERY_INFORMATION also accepted. Zero is failure, not Normal. [Contract](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-getpriorityclass). |
| `GetProcessPriorityBoost` | QL (`0x1000`); QUERY_INFORMATION also accepted. Output is valid only after successful BOOL return. [Contract](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-getprocesspriorityboost). |

Add `SYNCHRONIZE` (`0x00100000`) only when liveness requires a wait. QL plus SYNCHRONIZE is `0x00101000`; SYNCHRONIZE is not needed for the four getters themselves. Retain the handle across identity, zero-time wait, and operation. [Process rights](https://learn.microsoft.com/en-us/windows/win32/procthread/process-security-and-access-rights).

| `WaitForSingleObject(processHandle, 0)` | Meaning |
| --- | --- |
| WAIT_OBJECT_0 (`0`) | Process is signaled/terminated. A subsequent exit-code value 259 is its exit code, not evidence it is running. |
| WAIT_TIMEOUT (`0x102`) | Process was not signaled at this observation; it can still exit before the next call. |
| WAIT_FAILED (`0xFFFFFFFF`) | Liveness unknown; retain the immediate Win32 error. |
| Unexpected result | Liveness unknown; retain the raw wait result without inventing a Win32 error. |

The zero timeout returns immediately. A wait requires SYNCHRONIZE and a handle that remains open; the process object becomes signaled on termination. This resolves the ambiguity in `GetExitCodeProcess`, whose STILL_ACTIVE value 259 can also be an application's final exit code. [Wait contract](https://learn.microsoft.com/en-us/windows/win32/api/synchapi/nf-synchapi-waitforsingleobject), [process termination](https://learn.microsoft.com/en-us/windows/win32/procthread/terminating-a-process), [exit-code contract](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-getexitcodeprocess).
