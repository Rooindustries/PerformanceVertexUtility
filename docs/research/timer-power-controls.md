# Timer requests and Ultimate Performance ownership

Date: 2026-09-19. This is backend research and a private ownership prototype. No timer request, power-plan creation/activation/deletion, registry change, scheduled task, service change or reboot was performed on the the i5-14600K test PCXT. Native declarations were compiled and probe syntax was checked without invoking their setters.

Private artifacts are kept outside the repository.

## Existing backend behavior

`backend/scripts/Invoke-TimerResolutionSession.ps1` requests an integer millisecond period through `timeBeginPeriod`, waits for a bounded duration (default 250 ms), and calls `timeEndPeriod`. It queries `NtQueryTimerResolution` before/during/after. This is not a sustained 0.5 ms implementation. The power path in `Invoke-StutterOptimizationRealExecutor.ps1` exports the current active scheme, imports a temporary copy, selects it briefly and attempts restoration/deletion; it does not specifically construct Ultimate Performance.

Existing source also has result-accounting limits: the outer timer path can accept helper exit zero even when the parsed result says capability-limited, and power cleanup records attempts without independent final active-GUID verification. These pre-existing paths were not changed. Any reuse must retain actual acquisition/release errors, check helper status and verify native readback; a successful helper process is insufficient.

## Timer API scope

The documented user-mode multimedia interface takes **whole milliseconds**. Call `timeGetDevCaps`, require success, then acquire with `timeBeginPeriod` and match each successful acquisition with `timeEndPeriod` using the same value. Starting with Windows 10 version 2004, callers cannot rely on their request changing another process's timer resolution. Windows 11 may ignore requests from occluded window-owning processes. [timeBeginPeriod](https://learn.microsoft.com/en-us/windows/win32/api/timeapi/nf-timeapi-timebeginperiod), [timeGetDevCaps](https://learn.microsoft.com/en-us/windows/win32/api/timeapi/nf-timeapi-timegetdevcaps), [timeEndPeriod](https://learn.microsoft.com/en-us/windows/win32/api/timeapi/nf-timeapi-timeendperiod).

For an owned helper, the documented `PROCESS_POWER_THROTTLING_IGNORE_TIMER_RESOLUTION` control can opt out of ignoring its requests. That is a separate process-state operation requiring its own captured state and result check; it does not establish a request for another game. [SetProcessInformation](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-setprocessinformation).

The gaming playbook's bundled `SetTimerResolution.exe` uses the native timer-resolution calls; the gaming toggles launch it with a request of 5,000 units of 100 ns, or 0.5 ms. This comes from static inspection of the pinned helper and toggle, not a Microsoft user-mode API guarantee. No public Microsoft user-mode contract for that 0.5 ms export was identified in this research. The documented `ExSetTimerResolution` interface is a **kernel-driver** interface, clamps requests to platform support, and requires release of the driver's own request. It is not callable as the same documented API from an ordinary app. [ExSetTimerResolution](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/wdm/nf-wdm-exsettimerresolution).

High-resolution waitable timers are a supported way to schedule the app's own timed work, but creating one is not equivalent to applying the gaming toggles' persistent timer-resolution request to other applications. [CreateWaitableTimerEx](https://learn.microsoft.com/en-us/windows/win32/api/synchapi/nf-synchapi-createwaitabletimerexw).

Read-only native observations on `the i5-14600K test PC` at `2026-09-19T17:17:48Z` were:

| Observation | Result |
| --- | --- |
| WinMM capability result | `0`, minimum 1 ms |
| Native query status | `0` |
| Native first/second interval outputs | 156,250 / 5,000 units of 100 ns |
| Native current interval | 10,000 units, or 1 ms |

The range suggests a 0.5 ms native request can be investigated, but no request was made. Current interval may reflect other processes. Neither the aggregate query nor a successful acquisition proves that Fortnite, Marvel Rivals or another process receives different timing, or that FPS improves.

### Sustained timer ownership

Use one dedicated helper request per active timer lease. Persist the session ID, helper PID **and creation time**, executable identity, requested interval, acquisition result, owner set and last heartbeat. Multiple presets referring to the same timer request add logical owners; they must not repeatedly call the native acquire function or overwrite the first session record.

The helper remains alive while the lease remains wanted, including when the UI closes if that behavior is explicitly part of the feature. It acquires once, waits on a cancellation signal, then releases once in `finally`. A failed acquisition must not issue a release. Closing the UI is separate from stopping the feature. Startup persistence, if offered, is an independently reviewed task/startup operation; it is not hidden inside the timer helper.

Stop must address only the identified helper/session. A PID match alone is insufficient. Release the app's request; do not attempt to force the aggregate interval back to the sampled starting value, since other processes can acquire/release their own requests meanwhile. A crashed helper must be detected and shown as inactive/recovery-needed. OS cleanup on abnormal termination and a fresh helper's reacquisition need an explicit native regression; the file fixture does not establish those kernel semantics.

The native compatibility path should report requested interval, returned interval, status and helper liveness separately. A strictly documented user-mode implementation can offer the WinMM 1 ms request but must not silently label it as equivalent to the gaming toggles' 0.5 ms behavior. Their registry flag, BCD dynamic-tick setting and startup task are separate effects already inventoried; they are not implicit authority to change those targets during this timer probe.

## Ultimate Performance plan

The inspected WinUtil handler duplicates template GUID `e9a42b02-d5df-448d-aa00-03f14749eb61` and activates the returned plan. Its disable branch invokes `powercfg /restoredefaultschemes`. That branch would discard custom schemes and is unsuitable as the undo operation requested here. [Pinned WinUtil handler](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/functions/public/Invoke-WPFUltimatePerformance.ps1), [reset-all semantics](https://learn.microsoft.com/en-us/windows/win32/api/powrprof/nf-powrprof-powerrestoredefaultpowerschemes).

Use `PowerDuplicateScheme` with an explicitly supplied destination GUID. It returns zero on success and `ERROR_ALREADY_EXISTS` (`183`) for a collision. Do not delete or adopt an existing scheme merely because its name or deterministic GUID matches. A null destination pointer requests a newly generated GUID; supplied storage permits a predetermined destination. Free only the memory owned by the caller/API as applicable. [PowerDuplicateScheme](https://learn.microsoft.com/en-us/windows/win32/api/powrprof/nf-powrprof-powerduplicatescheme).

`PowerGetActiveScheme` returns the active GUID and allocated memory that must be freed through `LocalFree`. `PowerSetActiveScheme` changes the current user's selection; use the same user identity for capture, apply and restore. Creating a plan does not activate it. Each return code must be zero and the selected GUID must be read back. [Active scheme reader](https://learn.microsoft.com/en-us/windows/win32/api/powersetting/nf-powersetting-powergetactivescheme), [selector](https://learn.microsoft.com/en-us/windows/win32/api/powersetting/nf-powersetting-powersetactivescheme), [scheme management](https://learn.microsoft.com/en-us/windows/win32/power/managing-power-schemes).

The the i5-14600K test PCXT's active GUID was `0d4215c0-8a6b-4819-9f38-288a679c6a33`; 17 schemes were enumerated. The Ultimate template GUID was not in that enumeration. This does not establish whether the approved duplicate operation can resolve a hidden/default template. Do not silently substitute another plan if duplication fails; report the exact Win32 result. The existing user plan must remain intact.

### Deterministic ownership and recovery

The destination should be stable per installation/user and profile version, for example a UUIDv5 from a persisted installation identity plus `ultimate-performance:v1`. Use a distinct logical resource for the current active selection, shared across presets/game sessions. Capture the prior active GUID once on the first owner; equivalent later owners reuse it. Conflicting desired power plans require resolution in preview.

Suggested journal progression:

1. Capture current active GUID, current user/machine identity, scheme inventory and source/template fingerprint. Confirm the destination is absent or already backed by a valid owned receipt.
2. Persist create intent before duplication. After successful duplication, persist the created GUID receipt, baseline absence and fingerprint of the resulting plan. Add an app-owned name/description through supported power APIs if desired.
3. Select the created plan, check the return code and read back the active GUID. Retain the original GUID until the last logical owner releases.
4. On final release, restore the original only if the active selection still belongs to this lease. Verify the original exists and selection succeeds. If someone selected another plan, preserve that selection and report external change rather than claiming restoration.
5. Delete only the scheme this transaction demonstrably created, after it is inactive and unchanged. Verify disappearance by enumeration. If restoration fails while it is active, retain the plan and recovery record. If its settings were externally edited, retain it for review.

`PowerEnumerate` supplies scheme/subgroup/setting identities; fingerprint sorted native AC/DC setting values and relevant metadata to detect outside edits. `PowerDeleteScheme` deletes exactly one identified scheme. Never use a display-name search or reset-all command for cleanup. [Enumeration](https://learn.microsoft.com/en-us/windows/win32/api/powrprof/nf-powrprof-powerenumerate), [single-scheme deletion](https://learn.microsoft.com/en-us/windows/win32/api/powrprof/nf-powrprof-powerdeletescheme).

A crash between native creation and durable acknowledgement is a real uncertainty window. Persisted intent plus a matching GUID alone must not authorize deletion of a possibly external scheme. Keep an uncertain-ownership recovery state until its creation can be established. If the original scheme was deleted externally, retain the current plan and recovery record rather than choosing Balanced or recreating a plan without a reviewed recovery action. These are proposed transaction rules, not guarantees supplied by the power API.

## Prototype and reviewable native tests

`ownership_fixture.py` uses only disposable JSON files. Thirteen cases passed: shared/idempotent ownership, first-baseline retention, GUID collision, external active selection, modified-plan retention, failed restore/retry, uncertain creation, unused-plan cleanup, fresh reactivation, missing original, timer acquire/release pairing, external timer requests and process-identity mismatch. A representative wrong restore that overwrote an external selection was rejected. This validates the ownership model, not Windows behavior.

`ProbeNative.cs` compiled on the the i5-14600K test PCXT and both test scripts passed PowerShell parsing. Their native setters were **not invoked**. Both scripts default to review-only output and require `-ExecuteApprovedTest`, an exact machine check and separate approval before execution:

- `test-timer-native.ps1`: a bounded three-second request, either WinMM 1 ms or the native 0.5 ms compatibility export, with acquisition/release receipts and before/during/after queries. It does not change registry/BCD/startup state or assert game effectiveness.
- `test-power-native.ps1`: duplicate only the Ultimate template into `98472f39-9146-5073-8c16-73ea66ded98f`, require the reviewed prior active GUID above, select for one second, restore if no external change intervened, and delete only the newly created inactive test plan. A pre-existing destination causes a no-mutation failure. It verifies the final GUID set and active selection.

The exact review scope is `native-test-scope.md`. These small probes do not cover worker crash, app-close survival, reboot persistence, arbitrary settings drift or performance. A subsequent sustained-session test must exercise the final product worker with multiple logical owners, app restart, explicit stop, controlled helper termination and concurrent unrelated requests, while retaining precise request ownership. Neither current probe has approval to alter the the i5-14600K test PCXT.

## Native power API audit

Microsoft's SDK header annotates the third `PowerDuplicateScheme` argument as `_Inout_ GUID **`, clarifying the web page's simplified annotation. The C# declaration is `uint PowerDuplicateScheme(IntPtr root, [In] ref Guid source, ref IntPtr destinationGuidPointer)`. All these power APIs return a Win32 `DWORD` status, not a Boolean/HRESULT; use the returned value rather than an unrelated last-error value. [SDK declaration](https://github.com/microsoft/win32metadata/blob/main/generation/WinSDK/RecompiledIdlHeaders/um/powrprof.h), [API contract](https://learn.microsoft.com/en-us/windows/win32/api/powrprof/nf-powrprof-powerduplicatescheme).

For a predetermined destination, allocate and initialize 16 bytes containing that GUID and pass a pointer variable referring to the allocation by reference. `out IntPtr` does not express the required initialized input pointer; do not rely on it to select either mode. Use `ref IntPtr` with explicitly initialized storage or zero. `ref Guid` is the wrong pointer depth. The caller frees its own allocation with its matching allocator. For generated-GUID mode, initialize the pointer variable to zero; Windows allocates the resulting GUID and the caller uses `LocalFree`. Do not free the pointer-variable address. Do not infer ownership of a changed/foreign pointer in the predetermined mode: treat that as a contract violation, preserve recovery evidence and free only known caller-owned memory. The private probe was tightened accordingly; no duplicate operation was executed.

The concise declarations are in `timer-power/PowerApiSignatures.cs`; `PowerSchemeFingerprintRead.cs` contains only read imports and a read-only projection helper. Both the native statuses and exact bytes are part of the data contract in `power-api-contract.json`.

### Fingerprint coverage

Enumerate `ACCESS_SUBGROUP=17`, then `ACCESS_INDIVIDUAL_SETTING=18` for every subgroup. Explicitly include `NO_SUBGROUP_GUID=fea3413e-7e05-4911-9a71-700331f1c294` to cover settings stored directly under the scheme. Read both AC and DC through the generic value APIs and retain registry type, returned byte count and raw bytes; a DWORD-only index reader would silently narrow the schema. [Enumeration contract](https://learn.microsoft.com/en-us/windows/win32/api/powrprof/nf-powrprof-powerenumerate), [AC value](https://learn.microsoft.com/en-us/windows/win32/api/powersetting/nf-powersetting-powerreadacvalue), [DC value](https://learn.microsoft.com/en-us/windows/win32/api/powersetting/nf-powersetting-powerreaddcvalue).

Read friendly name, description and icon resource at scheme, subgroup and setting scopes. Preserve exact returned Unicode bytes and the read result. A missing field is different from an empty string. A null-buffer size query for these readers can succeed with `0`; enumeration uses `ERROR_MORE_DATA` (`234`) for sizing, and a short data buffer may also return `234`. Reallocate from the returned byte count with a bounded retry; never treat truncated data as a complete fingerprint. [Friendly name](https://learn.microsoft.com/en-us/windows/win32/api/powrprof/nf-powrprof-powerreadfriendlyname), [Description](https://learn.microsoft.com/en-us/windows/win32/api/powrprof/nf-powrprof-powerreaddescription), [Icon resource](https://learn.microsoft.com/en-us/windows/win32/api/powrprof/nf-powrprof-powerreadiconresourcespecifier).

Sort rows ordinally by scope/subgroup/setting/channel, retain type/status/data, and hash a versioned canonical representation. Keep two purposes separate: a configuration hash compares copied AC/DC configuration, while an ownership/deletion fingerprint includes scheme identity and expected app metadata. App-specific naming changes must not make a valid clone fail configuration comparison. Any unexpected read failure leaves the snapshot incomplete; do not authorize deletion from a digest of error placeholders.

The read-only native helper captured **21 subgroups, 178 settings and 956 rows** on the prior active plan. All 356 AC/DC reads succeeded. There were 197 `ERROR_FILE_NOT_FOUND` metadata results: 194 icons, two subgroup names and one subgroup description. These statuses were retained. Two complete consecutive projections matched, with canonical SHA-256 `8a5dd67a1156b87117df292e1c0272a975bda90bfb40bb30c8433c13480a5ecd`. The source Ultimate template was also readable through these APIs, despite not being listed among the installed schemes; its configured values differed from the user's active plan in two AC/DC rows. This resolves template readability for this host without proving duplication or selection.

A native projection is not a byte-for-byte dump of every possible registry extension or security descriptor. For deletion protection against arbitrary edits, retain an additional read-only manifest of the owned scheme's actual registry subtree (key membership, value names, kinds and raw data, plus the selected ACL/owner scope if required). Otherwise explicitly limit the fingerprint to supported power settings and metadata. Some returned metadata describes shared Windows setting definitions and can change with locale or system updates; such drift should cause retention/review, not deletion.

### Uncertain creation after a crash

The supported power API does not return a durable creation transaction identifier or join the installation's file journal atomically. A name, template match, predetermined GUID, absent-before observation or matching fingerprint cannot independently prove which process created the current scheme. The journal needs distinct states:

| Durable evidence | Recovery action |
| --- | --- |
| Create intent; destination still absent | Retry the creation under the same serialized operation, after rechecking the reviewed baseline. |
| Create intent; destination exists; no successful-create receipt | Mark ownership uncertain. Do not activate, adopt or delete it automatically. |
| Successful-create receipt; destination exists; expected fingerprint matches | Resume the owned transaction, subject to active-selection/owner checks. |
| Receipt exists but scheme is missing or fingerprint differs | Record external change; do not recreate or delete blindly. |
| Restore has not been verified and owned plan remains active | Retain the scheme and recovery journal; do not delete the active plan. |

An installation-specific marker written only after a successful create can supply additional post-create evidence and narrow the uncertainty window, but it is another non-atomic write. A plain marker/name is not proof of creation; copying a plan can copy its metadata. A durable authenticated receipt can establish what the installation acknowledged, but cannot eliminate the crash interval before acknowledgement or detect every identical replacement of an object. The simplest safe behavior for that interval is explicit uncertainty and retention, not automatic deletion. This is a transaction-design conclusion from the API boundary, not a claimed Windows transaction facility.

Fingerprint/recheck guards are also not atomic compare-and-delete operations against unrelated applications. Serialize the app's own writers, compare immediately before a mutation, preserve detected outside changes and retain recovery evidence. If the product requires an absolute guarantee against simultaneous external writes, the reviewed public APIs do not supply that atomic primitive; an equal fingerprint alone must not be described as such a guarantee.

## Integrated worker lifetime check

The worker originally survived its start call but was terminated with the SSH
parent job. Read-only job inspection reported flags `0x2800` (kill on close and
permitted breakaway). The integrated launcher now uses `CreateProcessW` with
`CREATE_BREAKAWAY_FROM_JOB | DETACHED_PROCESS` and no inherited handles.
`DETACHED_PROCESS` replaced `CREATE_NO_WINDOW`, which left a hidden console host
running beside the worker for the whole session.
A new SSH session verified the worker remained active after its parent process
and originating session exited, then verified release and fixture removal. The
six native acquire/release/lost-worker checks also passed after this change.
A job that does not permit breakaway receives the exact Windows launch error.

Contract: [Microsoft process creation flags](https://learn.microsoft.com/en-us/windows/win32/procthread/process-creation-flags),
[CreateProcessW](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-createprocessw).
