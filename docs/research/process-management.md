# Process management: Windows contracts, Process Lasso comparison, and implementation priorities

Checked: **2026-09-14**. Repository comparison: **`33bbd55f1196657a5935c783db65a8a0c59448bb`**. This report covers the backend; it does not assess the frontend. “Present” below means the implementation was inspected in that baseline, not that a Windows runtime or game benchmark was executed for this report. Subsequent branch changes must be assessed separately.

## Decision

Prioritize a reversible **process-default CPU Sets** implementation using documented Windows APIs and their minimum access rights. Keep adaptive restraint of approved background workloads as the main way to reduce contention when a game cannot be changed. Add explicit capability results, identity binding, readback, and conflict-aware restoration before adding more aggressive algorithms.

This is a promising compatibility approach, not proof that every anti-cheat permits it. The Windows setter needs less access than ordinary priority and affinity setters, but a game can still reject access or manage its own scheduling. A successful setter/readback proves the configured process default; it does not prove where every thread ran, improved frame times, or future absence of bans. [Microsoft CPU Sets][ms-cpusets], [CPU Set setter][ms-cpu-set], [priority setter][ms-priority-set], [affinity setter][ms-affinity]

Process Lasso is already substantially free. CPU Sets alone would close a feature gap rather than distinguish Roo Industries. The credible improvement target is a free engine with well-defined policies, reliable cleanup, understandable restrictions, and workload measurements that demonstrate when a change helps.

## Current Process Lasso scope and baseline comparison

Bitsum lists **18.3.0.34, released September 2, 2026**, as the current stable release; 18.4.0 was listed as beta. The stable release added Startup Boost. Use the current feature pages and revision history in preference to older FAQ passages when they disagree. For example, the FAQ still describes Reserved CPU Sets as an experiment, while the current feature documentation and release history describe an available tool. [Revision history][pl-changes], [Reserved CPU Sets][pl-reserved]

Free/Pro labels below follow Bitsum’s table as checked on the date above. “Trial/Pro” means the listed free edition feature has a trial limit; memory priority has a stated exception for changing the current instance. Startup Boost and some ancillary features are not separately classified in that table. Bitsum also states that commercial deployment requires purchase within 30 days; a free Roo Industries implementation should not depend on a Process Lasso installation or license. [Free/Pro feature table][pl-free]

| Feature | Process Lasso setting or behavior | Free status | Roo Industries baseline and proposed direction |
| --- | --- | --- | --- |
| Adaptive background restraint | Threshold and duration based temporary priority demotion; foreground exclusion; optional Efficiency Mode restraint disabled by default. [Docs][pl-probalance] | Free | Present in managed governor and PowerShell sessions. Retain conservative exclusions and prove hysteresis, restoration, and foreground transitions. |
| CPU priority | Persistent process priority rules. [Docs][pl-priorities] | Free | Present. Prefer approved background demotion; treat foreground boosts as measured, workload-specific choices. |
| CPU affinity | Persistent hard masks, delayed application, and one hardware thread per core. [Docs][pl-affinity] | Free | Present with scalar masks. CPU Sets and explicit processor-group information are the next gap; do not represent a machine-wide topology as one integer mask. |
| CPU Sets | Persistent preferred processor assignments, including selections across processor groups. [Docs][pl-cpusets] | Free | Absent at baseline. First implementation priority. |
| Topology selection | Core-type and cache/CCD selection are exposed in core selectors. [Revision history][pl-changes] | Included controls | Baseline lacks a CPU Set topology contract. Derive SMT siblings, efficiency classes, and cache domains from evidence; do not assume even CPU indexes are physical cores. |
| Efficiency Mode | Persistent process rules enabling or disabling the mode. [Docs][pl-efficiency] | Free | `PowerThrottling` is preview-only in the game profile. Add explicit system-managed/on/off states after CPU Sets. |
| I/O priority | Process I/O importance hints. [Docs][pl-priorities] | Free | Present through `NtQueryInformationProcess`/`NtSetInformationProcess` class 33; VeryLow/Low/Normal allowlist. Preserve runtime status and compatibility limits. |
| GPU scheduling priority | Process scheduling class rules. [Docs][pl-priorities] | Free | Present through D3DKMT, with per-target API failures. Readback and background GPU contention tests matter more than requesting the highest class. |
| Memory priority | Working-set page-retention hints. [Docs][pl-priorities] | Current free; persistent Trial/Pro | Absent from the process-control implementation. Useful opt-in background control after execution-speed throttling. |
| Dynamic thread boosts | Enable/disable native Windows wakeup boosts. [Docs][pl-priorities] | Free | No corresponding baseline control found. Useful for completeness and diagnosis; leave normal boosting enabled by default. |
| Foreground boosting | Optional foreground priority boost; disabled by default. [Docs][pl-probalance] | Free | Named foreground-game boosting exists. Protect audio/capture/voice dependencies and measure effects before generalization. |
| Startup Boost | Temporary AboveNormal/High priority, optional Efficiency Mode override, and restoration that preserves another actor’s intervening priority change. [Docs][pl-startup] | Not separately stated | No equivalent startup-duration feature found. Later, after policy ownership and launch identity are tested. |
| CPU Limiter | Sustained-load trigger temporarily removes allowed CPUs and later restores the original affinity. [Docs][pl-limiter] | Trial/Pro | No distinct limiter algorithm found. Later opt-in background feature; lower CPU consumption is not itself a responsiveness improvement. |
| Instance Balancer | Equal/fixed CPU allocations or NUMA placement across matching instances; rebalances as processes enter/leave. [Docs][pl-balancer] | Trial/Pro | No equivalent found. Useful for batch/server workloads; lower priority for protected-game optimization. |
| Processor Group Extender | Moves threads of older group-unaware programs across groups; Bitsum says unnecessary on Windows 11/Server 2022. [Docs][pl-groups] | Trial/Pro | Prefer topology diagnostics and CPU Sets. Do not add universal thread reassignment. |
| Performance Mode | Automated performance-oriented power behavior. [Docs][pl-performance] | Free | Temporary power-plan executor exists outside process controls. Game/process-triggered power-policy ownership remains a separate gap. |
| Application power plans | Switches plans for running applications and restores afterward. [Docs][pl-power] | Trial/Pro | No equivalent automatic process lifecycle integration found. Requires an explicit plan precedence and restoration design. |
| Idle/load-based power switching | IdleSaver and load thresholds with smoothing/dwell controls. [IdleSaver][pl-idle], [load switching][pl-load] | IdleSaver free; load not separately stated | No equivalent process-governor algorithm found. Later optional power feature, with power/thermal evidence. |
| Configuration switching | Switches complete rule configurations. [Docs][pl-config] | Free | Profile/session infrastructure exists; profile lifecycle is not evidence of equivalent automatic switching. |
| Watchdog | CPU/memory conditions can log, change controls, restart, terminate, or execute an action. [Docs][pl-watchdog] | Trial/Pro | Governor thresholds cover a narrower domain. Add detection/logging first; destructive actions need their own exact authorization. |
| Keep running / instance limits / disallowed processes | Restart and process-count/termination automation. [Keep running][pl-keep], [instance limits][pl-instances] | Trial/Pro | Not a priority for game responsiveness; avoid unsolicited restarts or termination. |
| Keep awake / prevent sleep | Timed keep-awake and per-process anti-sleep rules. [Docs][pl-antisleep] | Timed free; rules Trial/Pro | Not part of inspected process controls. Separate bounded session feature if required. |
| SmartTrim / standby management | Threshold-based working-set trimming and standby-cache clearing. [Docs][pl-trim] | Free | Standby counters and helper packaging contract exist elsewhere; no shipped live purge capability is claimed by that catalog. Avoid using lower working-set numbers as proof of improvement. |
| Timer resolution | System timer controls. [Docs][pl-timer] | Not separately stated | A bounded timer executor exists elsewhere. Its observed effect on other processes requires OS-specific verification. |
| Reserved CPU Sets | Persistent system-wide kernel registry setting requiring restart. [Docs][pl-reserved] | Free | Exclude from the initial implementation. It is distinct from per-process defaults and has a much wider effect. |
| Hard CPU throttling | Legacy forced thread sleeps; Bitsum discourages normal use. [Docs][pl-hard] | Trial/Pro | Do not prioritize for latency-sensitive workloads. |
| Matching, audit, independent engine | Name/wildcard/path/user/command-line/regex matching; an engine can operate without the GUI. [Matching][pl-matching], [components][pl-components] | Core facilities | Profiles, selectors, audit/session scripts, and a managed worker exist. Extend structured matching only with bounded evaluation and identity checks. A background service is not needed to prove bounded execution. |

Baseline evidence: [process capability catalog](../../backend/capabilities/process-controls.json), [native worker source](../../backend/native/ProcessGovernor/RooIndustriesProcessGovernor.cs), [shared control implementation](../../backend/scripts/ProcessProfile.Common.ps1), [policy engine](../../backend/scripts/ProcessPolicy.Common.ps1), [governor profile](../../backend/profiles/probalance-governor.profile.json), [game profile](../../backend/profiles/game-session.profile.json), [system capability catalog](../../backend/capabilities/system-optimizations.json), and [footprint budget](../../backend/profiles/lightweight-governor-budget.profile.json). These links resolve to the checkout’s current files; the comparison above is fixed to `33bbd55`.

The baseline governor profile uses 35% total CPU pressure, 8% per-process CPU, 8 seconds over threshold, a 15-second minimum restraint, a 3% restore threshold, 20-second cooldown, and one-second polling. It applies BelowNormal CPU/Low I/O priority and protects foreground, capture, voice, security, networking, drivers, and input categories. These are existing Roo Industries choices, not replicated Bitsum defaults or verified optimal values. The worker identifies itself as managed `csc`, with a bounded worker ready and no installed Windows service. Its source should not be described as a C++/NativeAOT engine.

## CPU Sets: exact public contracts

### Calls, access rights, and empty state

| API | Required access and contract |
| --- | --- |
| `GetSystemCpuSetInformation` | Optional target handle requires `PROCESS_QUERY_LIMITED_INFORMATION`; it determines `AllocatedToTargetProcess`. Pass `NULL, 0` to discover required **bytes**; insufficient space reports `ERROR_INSUFFICIENT_BUFFER`. `ReturnedLength` is valid/required bytes and can be zero. Reserved `Flags` must be zero. [Microsoft][ms-cpu-enumerate] |
| `GetProcessDefaultCpuSets` | Requires `PROCESS_QUERY_LIMITED_INFORMATION`. Buffer capacity and returned length count **32-bit IDs**, not bytes. A process with no explicit defaults returns success and zero IDs. Insufficient space returns false with `ERROR_INSUFFICIENT_BUFFER`. [Microsoft][ms-cpu-get] |
| `SetProcessDefaultCpuSets` | Requires `PROCESS_SET_LIMITED_INFORMATION`. Supplies a list of CPU Set IDs. Passing a null list with count zero clears explicit defaults. The defaults apply to threads without their own selected sets. [Microsoft][ms-cpu-set] |
| `GetThreadSelectedCpuSets` | Requires `THREAD_QUERY_LIMITED_INFORMATION`. Empty selected state returns success and zero IDs; buffer sizes count IDs. [Microsoft][ms-thread-get] |
| `SetThreadSelectedCpuSets` | Requires `THREAD_SET_LIMITED_INFORMATION`; selected sets override process defaults. Null/zero clears the thread override so process defaults can apply. This API need not be exposed as an optimizer action merely to test the interaction. [Microsoft][ms-thread-set] |

The CPU Set APIs list Windows 10 and Windows Server 2016 as their minimum supported systems. Check the actual exports and query results; do not make every optional control depend on the host supporting all newer APIs. Preserve error status immediately after a failed native call. The setters’ documentation says valid parameters cannot fail; this is not permission to ignore an invalid handle, denied access, exited target, or rejected input. [Enumeration][ms-cpu-enumerate], [getter][ms-cpu-get], [setter][ms-cpu-set]

Verified SDK values: `PROCESS_QUERY_LIMITED_INFORMATION=0x1000`, `PROCESS_SET_LIMITED_INFORMATION=0x2000`, `PROCESS_SET_INFORMATION=0x0200`, `PROCESS_QUERY_INFORMATION=0x0400`; thread limited-query/set rights are `0x0800`/`0x0400`. A CPU Set read/write handle therefore requests `0x3000`. Prefer separate read and mutation acquisition so read-only diagnostics remain available when mutation is denied. [Microsoft SDK header][sdk-winnt]

### Native record layout and interpretation

The current SDK layout is 32 bytes. The API explicitly requires advancing by each record’s `Size`, not by a hard-coded struct stride. Unknown `Type` records must be skipped. [Structure contract][ms-cpu-record]

| Byte offset | Width | Field |
| --- | --- | --- |
| 0 | 4 | `Size` |
| 4 | 4 | `Type`; `CpuSetInformation=0` |
| 8 | 4 | `CpuSet.Id` |
| 12 | 2 | `Group` |
| 14 / 15 | 1 each | `LogicalProcessorIndex` / `CoreIndex` |
| 16 / 17 | 1 each | `LastLevelCacheIndex` / `NumaNodeIndex` |
| 18 / 19 | 1 each | `EfficiencyClass` / `AllFlags` |
| 20 | 4 | `Reserved`, sharing its first byte with `SchedulingClass` |
| 24 | 8 | `AllocationTag` |

Offsets are derived from the published fixed-width fields. Flag bits are Parked `0x01`, Allocated `0x02`, AllocatedToTargetProcess `0x04`, RealTime `0x08`. Preserve raw flags and do not assign meanings to reserved bits. [Microsoft SDK header][sdk-winnt]

CPU Set IDs are API identifiers, not processor indexes or affinity bit positions. Group, logical processor, core, cache, and NUMA information must retain their group context. Equal `(Group, CoreIndex)` identifies shared execution resources such as SMT siblings. Higher `EfficiencyClass` values mean faster, less efficient processors; do not invert this ordering. Equal class values do not prove a specific P/E distinction. `SchedulingClass` has no detailed semantics on the inspected public page, so it should not drive a default “fastest core” policy. [Structure contract][ms-cpu-record]

Proposed parser rules: require at least an eight-byte header; reject zero size, undersized headers, overflow, and a size exceeding the remaining returned bytes. For a known record, require all fields the report exposes to exist; a full current-layout record requires 32 bytes. Accept a larger known record and skip its extension using `Size`. Never parse uninitialized capacity beyond `ReturnedLength`. Retry changed buffer-size requirements a bounded number of times, with checked allocation limits. Synthetic malformed buffers should produce explicit failures, not an empty topology.

### What readback establishes

CPU Sets provide soft scheduling affinity compatible with power management. Hard process/thread affinity takes precedence. A thread’s explicit selected sets take precedence over process defaults. On multi-group systems, a conflicting thread group can cause set assignments to be ignored. Sets allocated exclusively elsewhere can also be ignored; query allocation relative to the intended target. These conditions explain why a nonempty default list is not proof of effective thread placement. [Microsoft CPU Sets][ms-cpusets]

Do not describe a parked set as a broken or nonexistent CPU. Report topology and state separately. Reject foreign allocated sets from automatic selections rather than presenting an assignment the OS may ignore. Store the original default list exactly, including the empty state; never convert a failed query into a restorable empty list.

For durable rules, keep a topology-aware selection and re-resolve it against a fresh enumeration. The inspected public contract does not promise that numeric IDs remain portable across machines or reboots. Record the topology used for a preview and reject stale selections at apply time. Do not equate a shared cache index with a named vendor CCD or a measured cache capacity without additional hardware evidence.

CPU Set process defaults are documented as defaults for threads **inside that process**. That does not establish inheritance by child processes. Hard process affinity explicitly documents child-process inheritance; keep these two behaviors separate. [CPU Set setter][ms-cpu-set], [affinity setter][ms-affinity]

## Permissions and anti-cheat compatibility

The desired behavior is normal operating-system compatibility. Do not add injection, target-memory reads/writes, debugger attachment, protection changes, handle-right escalation, or a driver intended to override a denial. Continue useful optimization of approved background processes when a protected game rejects a setting.

| Evidence owner | What the checked source supports | What it does not establish |
| --- | --- | --- |
| Microsoft | APIs specify required process access; Windows checks requested access against process security. Protected processes restrict stronger rights. [Access rights][ms-rights] | A public API is not a whitelist from every anti-cheat vendor. Limited rights can still be denied. |
| Bitsum | Its current anti-cheat page discusses launcher affinity inheritance, registry priority at creation, and system-wide reserved sets. Its CPU Set page says sets can reduce complications for affinity-sensitive applications. [Anti-cheat][pl-anticheat], [CPU Sets][pl-cpusets] | No direct universal CPU Set compatibility guarantee was found in these pages. |
| Bitsum engineer | In an October 31, 2025 support reply, Jeremy Collake states that competing CPU Set tools use the same API and that CPU Sets have no registry-enforcement method; inconsistent behavior needs investigation. [Reply][pl-cpu-persistence] | This is first-party implementation commentary, not approval from EAC or a performance comparison. |
| Bitsum FAQ | Makes a no-ban claim about Process Lasso and describes its external process adjustments. [FAQ][pl-faq] | That claim cannot be transferred to Roo Industries, different techniques, or all future game versions. |
| Epic Games / EAC | Epic’s EAC support article says insecure/outdated background software can cause a game integrity violation and exit. [Support][eac-violation] | No Roo Industries/CPU Set whitelist or universal no-ban assurance was obtained. |
| BattlEye | Distinguishes actual cheats/bypassing components from ordinary tools, permits game-specific restrictions, and blocks vulnerable kernel drivers. Its FAQ distinguishes a blocked-file message from a ban. [FAQ][battleye-faq] | Compatibility and sanctions are distinct; a general policy does not certify a particular Roo Industries build. |
| Riot | Its February 7, 2024 developer guidance says external memory-reading tools are not allowed with Vanguard. [Developer guidance][riot-vanguard] | This older, still-published guidance is not a current CPU Set whitelist or complete compatibility contract. |
| FACEIT | Prohibits anti-cheat bypass/debug/modification and lists some benign tools as allowed examples. Separate support guidance identifies modified system/graphics files and third-party applications as crash causes. [Policy][faceit-policy], [crash support][faceit-crashes] | Being an optimizer is not sufficient evidence of compatibility, and permission for a named tool is not proof of performance benefit. |

GPU scheduling deserves separate reporting: Bitsum documents no child inheritance or registry enforcement for GPU priority and recommends adjusting other GPU workloads when the game is inaccessible. Do not silently substitute GPU priority for a denied CPU priority change. [Priority documentation][pl-priorities]

### Protection and failure diagnostics

`GetProcessInformation` with `ProcessProtectionLevelInfo` uses a query-limited process handle and a `PROCESS_PROTECTION_LEVEL_INFORMATION` containing one 32-bit `ProtectionLevel`. The Win32 enumeration value is **7**. **`PROTECTION_LEVEL_NONE=0xFFFFFFFE`**, while zero means `WINTCB_LIGHT`; zero is not an unprotected sentinel. The SDK lists `PPL_APP=8`. Keep the raw unsigned value. [Getter][ms-info-get], [structure][ms-protection], [Win32 information enum][ms-info-class], [SDK protection constants][sdk-winbase]

Treat failure as unknown. `NONE` reports Windows protection state, not absence of third-party handle filtering. Do not use the similarly named NT `PROCESSINFOCLASS` numbering for the Win32 API. Optional API/version failure should not disable unrelated controls.

Recommended per-control diagnostic fields are API name, requested access mask, PID, creation identity, available image identity, OS build, helper/process architecture, query outcome, mutation outcome, exact Win32/HRESULT/NTSTATUS, and post-write readback. For access errors, inspect the real token/admin condition, executable manifest, ACL or executable-policy block, architecture, and required binary/export before classifying the reason. Do not label a protected target “requires elevation” merely because the OS returned access denied. No `SeDebugPrivilege` retry is needed for this design.

## Other documented controls and tradeoffs

**Execution-speed throttling / EcoQoS.** `GetProcessInformation` is query-limited; `SetProcessInformation` requires `PROCESS_SET_INFORMATION`. Win32 `ProcessPowerThrottling=4`; the state is three ULONGs (`Version`, `ControlMask`, `StateMask`), version 1, execution-speed bit `0x1`, ignore-timer-resolution bit `0x4`. For the execution-speed bit, control/state `1/1` enables EcoQoS, `1/0` explicitly disables throttling, and `0/0` delegates policy to Windows. Preserve unrelated bits and the original control mask when restoring. [Getter][ms-info-get], [setter][ms-info-set], [SDK declarations][sdk-process]

Windows calls this EcoQoS on Windows 11; earlier implementations used LowQoS. It is intended for work outside the foreground experience. QoS can influence core selection and frequency while scheduling priority remains a distinct input. Therefore, do not present “EcoQoS off” as equivalent to High CPU priority or guaranteed P-core-only scheduling. Snapshot and test process and thread interactions independently. [Setter guidance][ms-info-set], [QoS documentation][ms-qos]

**CPU priority and inheritance.** Raising all game threads can compete with audio, input, capture, and other dependencies. Microsoft discourages Realtime for ordinary applications and urges care with High. It also documents that children can inherit Idle/BelowNormal when no explicit creation priority overrides the parent. Existing launcher-demotion rules therefore need a disposable parent/child test plus actual launcher evidence before claiming they cannot affect newly launched games. A High launcher is not documented to propagate priority symmetrically. [Scheduling priorities][ms-scheduling]

**Thread priority boosts.** `SetProcessPriorityBoost` needs `PROCESS_SET_INFORMATION`. Its Boolean is inverted relative to an “enabled” user setting: true disables boosts, false enables them. It affects existing and future threads. Preserve the current value; normally retain boosts that help threads waking from waits. [Microsoft][ms-boost]

**Memory priority.** Values 1–5 represent VeryLow through Normal, with 5 the normal default. This is a page-retention hint, not a RAM cap or a promise to free a particular byte count. It can be an opt-in control for known background work; verify paging behavior and task completion before recommending it. [Microsoft][ms-memory]

**I/O and GPU.** Baseline I/O control uses an NT information class outside the values described by the public `NtQueryInformationProcess` page; Microsoft warns that the NT interface and returned structures can change. Keep this optional and retain its raw status. D3DKMT GPU scheduling is a documented user-mode call returning NTSTATUS, including invalid-parameter and other failures. Neither successful call proves a frame-time gain. [NT API guidance][ms-ntquery], [D3DKMT][ms-gpu]

**CPU caps.** Job objects offer documented CPU rate control, including hard caps and weights, but are a separate containment/lifecycle design. A cap can stop associated threads until the next interval, and nested job quotas are relative to a parent’s allocation. Do not attach an arbitrary existing game to a new job as an automatic replacement for a denied affinity call. If later needed, start with owned disposable/background workloads. [Microsoft job CPU control][ms-job-cpu]

**Memory trimming and timers.** Bitsum’s own FAQ notes that actively used memory will be paged back after trimming. Avoid optimizing a display counter at the expense of page faults. For `timeBeginPeriod`, Windows 10 2004 changed the global behavior and Windows 11 adds visibility/audibility conditions; a helper’s successful request does not guarantee a higher resolution for the game. Pair begin/end calls and measure any claimed effect. [Bitsum FAQ][pl-faq], [Microsoft timers][ms-timer]

## Implementation sequence

These are engineering recommendations, not claims that the corresponding benchmark or runtime work has already passed.

1. **CPU Set query/apply/restore and diagnostics.** Use a small Windows API adapter with explicit handles. Expose topology, original/default IDs, target identity, errors, and readback. Distinguish clear (`[]`) from unreadable. Integrate through profile, preview, backup, apply, stop/restore, capability catalog, routing, and both execution paths that claim support. Do not advertise a native-governor control implemented only in PowerShell, or vice versa.
2. **Process-policy ownership.** Bind preview/apply to PID plus creation time and available executable identity. Acquire the handle, recheck identity, snapshot, persist backup, mutate, and read back the same object. Record only fields actually changed. Restore only fields still equal to the session’s last applied state, unless an explicit user action requests overriding a conflict. Define precedence among profile, dynamic governor, and manual sessions so they cannot continually overwrite each other.
3. **Add execution-speed state and memory-priority controls.** Require current-state availability and bounded reversible probes. Keep CPU priority, CPU placement, execution-speed policy, and memory priority as separate controls. Provide an explicit system-managed state for the power policy.
4. **Improve the governor with evidence.** Retain sustained-load thresholds, dwell time, hysteresis, exemptions, and denial backoff. Test launches, foreground transitions, voice/capture load, and child inheritance. Refresh expensive metadata only when required and keep audit buffers bounded. Polling plus bounded lifecycle reconciliation is sufficient initially; event collection should earn its added complexity through footprint evidence.
5. **Add opt-in automation after ownership is reliable.** Startup boosts, instance allocation, and process-triggered power plans are plausible extensions. Give overlapping power rules a deterministic precedence and preserve external plan changes. Keep watchdog detection useful before implementing termination/restart actions.
6. **Promote only measured presets.** Compare Windows defaults, the current governor, CPU Sets alone, and combined policies. A plan that is more configurable or easier to restore may be better operationally without being faster. Describe those improvements separately.

Existing issue requiring the repository’s normal approval process: baseline native `RestoreSnapshot` restores original priority/affinity/I/O/GPU values whenever current state differs from the backup, without a last-applied ownership comparison. Source inspection therefore identifies a path that can overwrite another actor’s change, including a field the active restraint did not modify. Proposed remediation is field ownership plus a conflicting-writer fixture. This report does not change that existing code. New CPU Set restoration should avoid introducing the same behavior.

## Verification plan and evidence boundaries

All rows below are **pending execution** for the proposed CPU Set implementation. Existing test names indicate where coverage belongs; they do not establish results from this research pass.

| Concern | Independent expected result and check |
| --- | --- |
| Layout and identifier handling | Synthetic records contain noncontiguous IDs such as 257/4097 and repeated group-relative core indexes in different groups. Exact parsed fields and flags must match a separately authored fixture. An index-as-ID mutation must fail. |
| Variable-length parsing | Mix a 32-byte known record, a larger known record, and an unknown type. Test truncated headers, short known records, size zero, oversized size, signed/overflow boundaries, and trailing invalid data. Errors must not become an empty topology. |
| Sizing and races | Exercise empty defaults, insufficient capacity, a growing returned count, retry exhaustion, and a process exiting between calls. Assert bounded retries and correct byte-versus-ID units. |
| State distinction | Unset defaults return `[]`; unavailable query returns an explicit unavailable/error state and cannot authorize apply/restore. Invalid selectors must not become clear operations. |
| Actual reversible CPU Set write | On a disposable Windows process: query original IDs, choose a valid different selection, apply, independently query the exact normalized ID set, clear, and restore original state. Include an originally nonempty set and an originally empty set. |
| Thread overrides | The fixture owns a thread with an explicit selected set. A process-default write must leave that thread selection intact. Clearing the thread override must return it to the documented process-default behavior. |
| Hard-affinity interaction | Fixture records a restrictive affinity plus CPU defaults. Readback of defaults must not be reported as proof of placement outside the hard mask. Capture execution only on hardware/OS where the relevant topology is available. |
| Allocation and topology | Foreign-allocated sets are excluded or explicitly rejected. Test a target-relative allocation flag, parked sets, homogeneous classes, multiple efficiency classes, SMT siblings, more than one group, and stale preview IDs. Multi-group execution needs suitable Windows hardware; parser fixtures are not a substitute. |
| Permissions | Query-only operation works without mutation rights on a disposable target. A controlled denied-write fixture produces the exact access/API error, leaves state unchanged, and does not request stronger rights. Protected/PPL diagnostics distinguish NONE, protected, and unknown. |
| Identity | PID reuse, missing creation identity, exited target, image mismatch, and new matching instances do not receive another process’s saved state. |
| Partial failure and retries | Simulate CPU Set success followed by another-control failure; compensate only actual writes. Repeated apply/stop is idempotent. Handle an interrupted worker and backup recovery without unbounded retries or residual processes. |
| External and overlapping writers | A second actor changes the controlled field; ordinary restore records a conflict and preserves it. An unrelated changed field is untouched. Define and exercise precedence for two sessions selecting the same process. |
| Profile/runtime integration | Schema validation, preview, routing, capability facts, application, and stop/restore agree on control names, support, and exact errors. Reuse `Test-ProcessControlCapabilities.ps1`, `Test-CapabilityRouterProcessControls.ps1`, policy/runtime tests, and the native worker test only for paths actually changed. |
| Governor behavior | Foreground entry/exit, transient versus sustained load, cooldown, non-normal initial priority, process children, and protected companions have independently specified outcomes. Default launcher demotion must be checked for child inheritance. |
| Cleanup and footprint | Disposable processes terminate; handles close; `backend/state` is empty after validation; no helper, fixture, temporary power plan, or utility remains. Measure idle CPU, private bytes, wakeups, log growth, and startup latency against the existing budget. |
| Anti-cheat/game behavior | A real title is launched through its normal protected launcher only in an authorized validation session. Record build, anti-cheat version when observable, setting result, normal session behavior, and observed messages. A successful session is limited compatibility evidence, not a no-ban guarantee. |

For frame pacing, the official PresentMon console can collect per-frame CSV from ETW events; it is separate from the optional GUI/service/overlay. Its documentation lists instrumentation limits for some graphics APIs and GPU execution metrics with hardware-accelerated scheduling. Pin capture version and fields, and document missing measurements. [PresentMon][presentmon]

Recommended comparison protocol: use the same game build, scene/replay, graphics settings, frame cap, OS power state, temperature range, and background workload; randomize repeated A/B runs and retain raw samples. Report frame-time percentiles and long-frame counts alongside average FPS, audio/OBS health, background task completion, CPU/GPU load, power/temperature when measured, and governor overhead. Separate clean-system runs from CPU, GPU, and memory-contention scenarios. Do not infer an input-to-photon latency change from FPS alone. Windows QoS can also vary with foreground visibility, audibility, battery state, and inactivity; record those conditions. [Microsoft QoS][ms-qos]

Unproven here: Windows API execution of proposed changes, protected-game compatibility, P/E/SMT/CCD placement on the intended machine, multi-group behavior, thermal/battery tradeoffs, better frame times than Windows defaults or Process Lasso, and any universal guarantee against bans. EAC’s public FAQ category page loaded, but the detailed compatibility answers were not exposed by this retrieval; a direct page fetch returned HTTP 403. Epic’s accessible support article supplies the narrower EAC evidence used above. No system settings or game/anti-cheat state were changed for this report.

## Source links

All links were checked on **2026-09-14**. Vendor feature descriptions establish documented behavior; Microsoft API pages and SDK declarations establish implementation contracts. Implementation and benchmark recommendations above are explicitly the report’s analysis.

[pl-free]: https://bitsum.com/howfree/
[pl-changes]: https://bitsum.com/changes/processlasso/
[pl-faq]: https://bitsum.com/process-lasso-faq/
[pl-probalance]: https://bitsum.com/apps/process-lasso/docs/algorithms/probalance/
[pl-priorities]: https://bitsum.com/apps/process-lasso/docs/rules/priorities/
[pl-affinity]: https://bitsum.com/apps/process-lasso/docs/rules/cpu-affinities/
[pl-cpusets]: https://bitsum.com/apps/process-lasso/docs/rules/cpu-sets/
[pl-efficiency]: https://bitsum.com/apps/process-lasso/docs/rules/efficiency-mode/
[pl-startup]: https://bitsum.com/apps/process-lasso/docs/rules/startup-boost/
[pl-limiter]: https://bitsum.com/apps/process-lasso/docs/algorithms/cpu-limiter/
[pl-balancer]: https://bitsum.com/apps/process-lasso/docs/algorithms/instance-balancer/
[pl-groups]: https://bitsum.com/apps/process-lasso/docs/algorithms/group-extender/
[pl-performance]: https://bitsum.com/apps/process-lasso/docs/algorithms/performance-mode/
[pl-power]: https://bitsum.com/apps/process-lasso/docs/power/power-profiles/
[pl-idle]: https://bitsum.com/apps/process-lasso/docs/power/idlesaver/
[pl-load]: https://bitsum.com/apps/process-lasso/docs/power/load-based-switching/
[pl-config]: https://bitsum.com/apps/process-lasso/docs/power/config-profile-switcher/
[pl-watchdog]: https://bitsum.com/apps/process-lasso/docs/rules/watchdog/
[pl-keep]: https://bitsum.com/apps/process-lasso/docs/rules/keep-running/
[pl-instances]: https://bitsum.com/apps/process-lasso/docs/rules/instance-limits/
[pl-antisleep]: https://bitsum.com/apps/process-lasso/docs/rules/anti-sleep/
[pl-trim]: https://bitsum.com/apps/process-lasso/docs/algorithms/smarttrim/
[pl-timer]: https://bitsum.com/apps/process-lasso/docs/rules/timer-resolution/
[pl-reserved]: https://bitsum.com/apps/process-lasso/docs/rules/reserved-cpu-sets/
[pl-hard]: https://bitsum.com/apps/process-lasso/docs/algorithms/hard-throttling/
[pl-matching]: https://bitsum.com/apps/process-lasso/docs/reference/process-matching/
[pl-components]: https://bitsum.com/apps/process-lasso/docs/getting-started/how-it-works/
[pl-anticheat]: https://bitsum.com/apps/process-lasso/docs/help/anti-cheat/
[pl-cpu-persistence]: https://community.bitsum.com/forum/index.php?topic=38498.0%3Bprev_next%3Dprev
[ms-cpusets]: https://learn.microsoft.com/en-us/windows/win32/procthread/cpu-sets
[ms-cpu-enumerate]: https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-getsystemcpusetinformation
[ms-cpu-get]: https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-getprocessdefaultcpusets
[ms-cpu-set]: https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-setprocessdefaultcpusets
[ms-cpu-record]: https://learn.microsoft.com/en-us/windows/win32/api/winnt/ns-winnt-system_cpu_set_information
[ms-thread-get]: https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-getthreadselectedcpusets
[ms-thread-set]: https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-setthreadselectedcpusets
[ms-affinity]: https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-setprocessaffinitymask
[ms-rights]: https://learn.microsoft.com/en-us/windows/win32/procthread/process-security-and-access-rights
[ms-info-get]: https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-getprocessinformation
[ms-info-set]: https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-setprocessinformation
[ms-info-class]: https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/ne-processthreadsapi-process_information_class
[ms-protection]: https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/ns-processthreadsapi-process_protection_level_information
[sdk-winnt]: https://raw.githubusercontent.com/microsoft/win32metadata/main/generation/WinSDK/RecompiledIdlHeaders/um/winnt.h
[sdk-process]: https://raw.githubusercontent.com/microsoft/win32metadata/main/generation/WinSDK/RecompiledIdlHeaders/um/processthreadsapi.h
[sdk-winbase]: https://raw.githubusercontent.com/microsoft/win32metadata/main/generation/WinSDK/RecompiledIdlHeaders/um/WinBase.h
[ms-qos]: https://learn.microsoft.com/en-us/windows/win32/procthread/quality-of-service
[ms-scheduling]: https://learn.microsoft.com/en-us/windows/win32/procthread/scheduling-priorities
[ms-priority-set]: https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-setpriorityclass
[ms-boost]: https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-setprocesspriorityboost
[ms-memory]: https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/ns-processthreadsapi-memory_priority_information
[ms-ntquery]: https://learn.microsoft.com/en-us/windows/win32/api/winternl/nf-winternl-ntqueryinformationprocess
[ms-gpu]: https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/d3dkmthk/nf-d3dkmthk-d3dkmtsetprocessschedulingpriorityclass
[ms-job-cpu]: https://learn.microsoft.com/en-us/windows/win32/api/winnt/ns-winnt-jobobject_cpu_rate_control_information
[ms-timer]: https://learn.microsoft.com/en-us/windows/win32/api/timeapi/nf-timeapi-timebeginperiod
[eac-violation]: https://www.epicgames.com/help/c-32735058/c-37477814/a19193670
[battleye-faq]: https://www.battleye.com/support/faq/
[riot-vanguard]: https://www.riotgames.com/en/DevRel/vanguard
[faceit-policy]: https://support.faceit.com/hc/en-us/articles/360015788779-What-is-deemed-to-be-a-cheat
[faceit-crashes]: https://support.faceit.com/hc/en-us/articles/360014237399-Troubleshooting-game-crashes
[presentmon]: https://github.com/GameTechDev/PresentMon
