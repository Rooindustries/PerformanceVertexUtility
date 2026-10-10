# Fortnite GPU class: contracts and access experiments

Updated **2026-09-18**. This note combines primary-source review with independently checked RX the i5-14600K test PC XT results from the next stage of [the GPU priority investigation](official-gpu-priority.md). **No verified official Fortnite GPU process-class workaround was found on this build.** The tested direct, launcher-handle, and process pseudo-handle routes produced handles without the access right required by the controlled fixture; Fortnite's GPU getter remained denied. This is evidence about specific tested paths, not universal impossibility. The required outcome remains a change in the game's `D3DKMT_SCHEDULINGPRIORITYCLASS`, with independent original, applied, and restored observations. The denied access-investigation prototypes remain private; the separately integrated retained-handle backend also reported Fortnite's class unavailable.

The integrated session was tested through Epic's normal launch and reached Fortnite's lobby. The controller and its independent recovery watcher both retained ordinary startup handles, but both returned `D3DKMTGetProcessSchedulingPriorityClass` status `0xC0000022`. The session reported `partial`, GPU field `unavailable`, unknown original/readback, and no GPU mutation journal. No setter ran. This verifies truthful backend behavior under denial; it does not resolve Fortnite GPU-class control.

## Initial GPU class

**No Microsoft contract was located that derives the initial GPU process class from CPU creation priority, IFEO `CpuPriorityClass`, or the parent's GPU class.** This is a documentation limit, not proof that such behavior cannot occur on the tested Windows build.

| Reviewed authority | What it establishes | What remains unknown |
| --- | --- | --- |
| [CreateProcessW, `dwCreationFlags`](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-createprocessw) and [Scheduling Priorities](https://learn.microsoft.com/en-us/windows/win32/procthread/scheduling-priorities) | Creation flags select the class used for CPU thread scheduling. With no explicit priority flag, the default is Normal except for the documented Idle/Below Normal inheritance cases. | Neither contract specifies a GPU initialization rule or GPU-class inheritance. The CPU inheritance rule cannot be extended to GPU class by analogy. |
| [D3DKMT process setter](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/d3dkmthk/nf-d3dkmthk-d3dkmtsetprocessschedulingpriorityclass), [getter](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/d3dkmthk/nf-d3dkmthk-d3dkmtgetprocessschedulingpriorityclass), and [class enum](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/d3dkmthk/ne-d3dkmthk-_d3dkmt_schedulingpriorityclass) | A process handle identifies the target. The setter accepts the GPU scheduling-class enum; the getter returns it. | These pages do not specify an initial class, initialization timing, inheritance, or a CPU-to-GPU mapping. |
| [Setter function-pointer contract](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/d3dkmthk/nc-d3dkmthk-pfnd3dkmt_setprocessschedulingpriorityclass) | The same handle and class arguments are documented. | It adds no initialization or inheritance guarantee. |

The earlier observation that a CPU priority change left an already initialized fixture's GPU class at 2 did not resolve first-initialization behavior. The new comparison created **12 separate child processes**, varying the parent's getter-confirmed GPU class and the child's CPU creation flags independently. Each child recorded CPU class before creating a graphics device, selected the actual AMD RX the i5-14600K test PC XT, rendered and checked a known pixel, and then read its GPU class six times during additional verified graphics work.

| Parent GPU class, verified before launch | Default CPU flags → observed 32 | Normal CPU flags 32 | Above Normal CPU flags 32768 | High CPU flags 128 |
| --- | --- | --- | --- | --- |
| 2 | GPU class 2 | GPU class 2 | GPU class 2 | GPU class 2 |
| 3 | GPU class 2 | GPU class 2 | GPU class 2 | GPU class 2 |
| 4 | GPU class 2 | GPU class 2 | GPU class 2 | GPU class 2 |

Every child retained the requested CPU class, with **72/72 successful GPU getters returning class 2**, **72 verified pixel checks**, and **12 exit codes of 0**. The parent's setters and separate getters verified `2 → 3 → 4 → 2`; its original class 2 was restored. These counts were derived from the individual `initialization/parent-*-cpu-*.jsonl` records and checked against `initialization-summary.json`; the rendering code confirms that each reported frame requires the expected GPU output.

This rules out those CPU creation flags and parent GPU classes as an initialization workaround in this fixture on the tested build. It does not establish Fortnite's unreadable GPU class, every possible initialization path, or a Windows inheritance guarantee. This comparison used `CreateProcessW` flags; it was not a new IFEO registry trial.

## ETW observation

**No additional Microsoft-published event ID and field mapping was found that independently reports the GPU process scheduling class.** In particular, this review supplies no new interpretation for the context priority fields in events 21, 239, or 515, whose previous calibration is recorded in the main report.

Microsoft's [GPUView event listing documentation](https://learn.microsoft.com/en-us/windows-hardware/drivers/display/event-listing-dialog-box) describes video-kernel profiler events and their function names, manifest-property inspection, and `GuidStats.txt`. It does not identify a process-class payload or numeric mapping. A profiler entry/exit record for a scheduling API, if present, would establish a call's occurrence; it would not alone establish the original class or successfully applied state. The [GPUView process view](https://learn.microsoft.com/en-us/windows-hardware/drivers/display/viewing-a-process) documents process identity, context queues, and CPU threads without a GPU process-class field.

The installed-provider review used these documented interfaces:

1. Enumerate the provider's manifest descriptors with [TdhEnumerateManifestProviderEvents](https://learn.microsoft.com/en-us/windows/win32/api/tdh/nf-tdh-tdhenumeratemanifestproviderevents).
2. Fetch each descriptor's schema with [TdhGetManifestEventInformation](https://learn.microsoft.com/en-us/windows/win32/api/tdh/nf-tdh-tdhgetmanifesteventinformation), preserving provider, event ID, version, opcode, and keyword. Inspect all properties, including structure members, rather than only event names or top-level fields.
3. Preserve property types and map metadata. [EVENT_PROPERTY_INFO](https://learn.microsoft.com/en-us/windows/win32/api/tdh/ns-tdh-event_property_info) supplies `MapNameOffset` for a declared value map; a missing map is not permission to assign enum semantics to a raw integer.
4. For actual captured records, retain the decoding source and any unavailable-schema error from [TdhGetEventInformation](https://learn.microsoft.com/en-us/windows/win32/api/tdh/nf-tdh-tdhgeteventinformation). Manifest enumeration is explicitly limited to manifest-defined events. A negative manifest search does not establish the absence of all WPP, classic, dynamic, or private tracing paths.

An event candidate would need a target-process binding, a documented process-class meaning or a discriminating getter-confirmed calibration, and coverage of original, changed, and restored values. Context/device/queue priorities, GPU bands, CPU thread priority, utilization, and API-call timing must remain separate from the requested process class.

The native TDH inventory in `manifest.jsonl` retrieved **1,859 schemas from all six selected providers, with zero reported errors**:

| Provider | Schemas retrieved |
| --- | ---: |
| Microsoft-Windows-DxgKrnl | 711 |
| Microsoft-Windows-Win32k | 369 |
| Microsoft-Windows-Dwm-Core | 341 |
| Microsoft-Windows-DXGI | 212 |
| Microsoft-Windows-Direct3D12 | 135 |
| Microsoft-Windows-Direct3D11 | 91 |

An independent search of the complete records reproduced all **29 priority-related schemas** in `priority-schemas.json`. None supplied a new process scheduling-class field or authoritative mapping. Potentially confusing examples were DxgKrnl event **81 v0**, `ProcessPolicyChange`, whose field is `AllocationPriorityClass`; event **370 v0**, `VidMmProcessDemotedCommitmentChange`, whose `PriorityClass` declares the `VIDMM_ALLOCATION_PRIORITY_CLASS` map; and Direct3D12 events **47–49 v1**, whose `Priority` belongs to `CommandQueue`. Existing context events 21, 239, and 515 remained distinct. These are schema observations, not a claim that every possible tracing mechanism has been exhausted.

The separate `game-policy-manifest.jsonl` inventory retrieved another **28 schemas**, comprising **16 Microsoft-Windows-MMCSS** and **12 Microsoft-Gaming-Services** schemas, again with zero reported errors. MMCSS priority fields concern CPU threads; the Gaming Services schemas contain general diagnostic messages. No GPU process-class field was found. The combined inventories therefore cover **1,887 schemas across eight selected providers**, without claiming coverage of every Game Mode or Game Bar tracing path.

Process Explorer **17.14**, obtained from Microsoft's official distribution, was inspected as an offline artifact and was not executed. Its inspected resources expose CPU/I/O/memory priority controls and GPU graphs; the searched ASCII and UTF-16 strings contained neither D3DKMT process-class API name nor a GPU-priority control label. This limited static inspection did not establish a usable class setter; it is not proof of every behavior the binary could implement.

## Fortnite caller and access checks

The additional checks all bind to `FortniteClient-Win64-Shipping.exe`, PID **16284**, creation FILETIME **134341737654396652**, in interactive session **1**. The inspected `fortnite-session-check-live.png` shows the game's Play screen. Across each of four caller matrices, all eight GPU getters returned **`0xC0000022`**, with no class value:

| Evidence | Caller condition | Result |
| --- | --- | --- |
| `ssh-rights.json` | Administrator in session 0 | 8/8 denied |
| `interactive-rights.json` | Administrator in game session 1 | 8/8 denied |
| `rights-PriorityEnabled.json` | Session 1; `SeDebugPrivilege` and `SeIncreaseBasePriorityPrivilege` both verified enabled **before** the queries | 8/8 denied |
| `rights-Minimal.json` | Session 1; both privileges verified disabled **before** the queries | 8/8 denied |

Each matrix requested `0x200`, `0x400`, `0x1000`, `0x1200`, `0x101200`, `0x2000`, `0x3000`, and `0x1400`. The corresponding granted masks were `0x2000`, `0x1000`, `0x1000`, `0x3000`, `0x103000`, `0x2000`, `0x3000`, and `0x1000`. Handles were compared with the identity-bound process handle. The initial two records measured privileges after the query rows; their privilege listings are not treated as query-time evidence. The explicit enabled/disabled records resolve that measurement limit.

`GetProcessInformation` succeeded and reported `0xFFFFFFFE`, the header constant for `PROTECTION_LEVEL_NONE`. This establishes that the reported PPL level was None; it does not negate the observed reduced access or establish its exact implementation. [Protection-level contract](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/ns-processthreadsapi-process_protection_level_information), [Microsoft header definition](https://github.com/microsoft/win32metadata/blob/main/generation/WinSDK/RecompiledIdlHeaders/um/WinBase.h).

`caller-packaging.json` records a 64-bit Windows PowerShell caller with Authenticode status `Valid`; the later `caller-signer.json` independently records the **Microsoft Windows / Microsoft Corporation** certificate subject and `Valid` signature status. The game's file and product version fields were empty, so this pass does not establish a fresh game version. **No Fortnite GPU setter was executed in this access matrix.** The same-session and explicit privilege comparisons did not resolve the denial; they are not evidence that every caller or future supported integration must fail.

## Handle-table and duplication probes

The next hypothesis was that an ordinary launcher-created game handle could remain usable even though new direct handles were restricted. The probe used `PssCaptureSnapshot` with capture flags **`0x34`**: handles, basic handle information, and type-specific information. It captured no VA clone or memory contents. Only entries with valid process type and type-specific PID information were considered. Every successfully duplicated handle was checked against the independently opened target by kernel-object identity, PID, creation time, and executable path before GPU queries. Granted rights came from the actual local duplicate, not the ambiguously documented PSS `GrantedAccess` member. [Capture contract](https://learn.microsoft.com/en-us/windows/win32/api/processsnapshot/ne-processsnapshot-pss_capture_flags), [entry validity](https://learn.microsoft.com/en-us/windows/win32/api/processsnapshot/ne-processsnapshot-pss_handle_flags), [object comparison](https://learn.microsoft.com/en-us/windows/win32/api/handleapi/nf-handleapi-compareobjecthandles).

An owned holder/graphics-child fixture first demonstrated that this path works under ordinary Windows access checks:

| Requested source-process mask | Capture result | Bound child GPU result |
| --- | --- | --- |
| `0x101040`: Query Limited Information + Duplicate Handle + Synchronize | Win32 **5**, access denied | No copy or setter |
| `0x100440`: Query Information + Duplicate Handle + Synchronize | Success, without requesting VM Read | `2 → 3`, separate hold read 3, restored/read 2 |
| `0x100450`: preceding mask plus VM Read | Success | `2 → 3`, separate hold read 3, restored/read 2 |
| `0x1FFFFF`: All Access | Success | `2 → 3`, separate hold read 3, restored/read 2 |

All three successful captures and walks were freed with status 0. The child independently read original class 2 at exit and exited with code 0. Evidence: `pss-owned-v2/fixture.jsonl`, `child.jsonl`, and `holder.jsonl`. This measures sufficient source rights on this build; Microsoft's capture API does not publish a minimum-rights mask for this flag combination. Snapshots captured by the caller were freed with `PssFreeSnapshot(GetCurrentProcess(), snapshot)`, which addresses the snapshot owner. [Capture API](https://learn.microsoft.com/en-us/windows/win32/api/processsnapshot/nf-processsnapshot-psscapturesnapshot), [snapshot ownership](https://learn.microsoft.com/en-us/windows/win32/api/processsnapshot/nf-processsnapshot-pssfreesnapshot).

The live run then bound Fortnite PID **16736**, creation FILETIME **134341777370302568**. It inspected only the selected Epic/Fortnite launchers and Easy Anti-Cheat processes. **48/48 snapshots succeeded**, and **32 duplicated game handles** passed the identity checks. All 32 copies had granted mask **`0x103000`**, missing `PROCESS_SET_INFORMATION`; all GPU getters returned **`0xC0000022`**. Every walk marker and snapshot free returned 0. No game setter was attempted. Evidence: `pss-fortnite.jsonl`.

A distinct access-mode comparison tested `MAXIMUM_ALLOWED`, `GENERIC_ALL`, `GENERIC_WRITE | QUERY_LIMITED_INFORMATION | SYNCHRONIZE`, and `PROCESS_ALL_ACCESS`, alongside the explicit `0x101200` request. All five direct handles still lacked `0x200` and their GPU getters were denied. `DUPLICATE_SAME_ACCESS` copies of the game handles found in the EAC bootstrap/service also lacked that right and were denied. Evidence: `pss-access-modes/inspect-fortnite.jsonl`. The Windows duplication callback contract permits rights to be reduced; a successful `DuplicateHandle` call alone does not prove the requested rights survived. [Duplication API](https://learn.microsoft.com/en-us/windows/win32/api/handleapi/nf-handleapi-duplicatehandle), [callback restriction contract](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/wdm/ns-wdm-_ob_pre_duplicate_handle_information).

The final duplication variant used the process pseudo-handle behavior discussed in Microsoft's process access-rights warning. An owned-child positive control acquired a source handle with only `PROCESS_DUP_HANDLE` (`0x40`), obtained an identity-matching copy, changed class `2 → 3`, and restored it to 2. A separately opened oracle handle verified all three states. On Fortnite, Windows also granted the `0x40` source handle, but copies using both explicit requested access and `DUPLICATE_SAME_ACCESS` still lacked `0x200`; both GPU getters returned `0xC0000022`. No access filter was disabled or modified. Evidence: `pseudo-owned/pseudo-fixture.jsonl` and `pseudo-fortnite/inspect-fortnite.jsonl`. [Microsoft's process access-rights warning](https://learn.microsoft.com/en-us/windows/win32/procthread/process-security-and-access-rights).

## Independent GPU access-rights control

To distinguish getter denial from a setter that might nevertheless work, an ordinary RX the i5-14600K test PC XT child was queried and set through seven different valid handle masks. An independently opened oracle observed the actual GPU class after every setter attempt.

| Requested mask | Actual granted mask | Getter / setter status | Independent class after attempt |
| --- | --- | --- | --- |
| `0x1000` | `0x1000` | Both `0xC0000022` | 2 |
| `0x2000` | `0x2000` | Both `0xC0000022` | 2 |
| `0x400` | `0x1400` | Both `0xC0000022` | 2 |
| `0x200` | `0x2200` | Both 0 | 3 |
| `0x3000` | `0x3000` | Both `0xC0000022` | 2 |
| `0x600` | `0x3600` | Both 0 | 3 |
| `0x100000` | `0x100000` | Both `0xC0000022` | 2 |

Both APIs succeeded exactly for the tested handles containing `PROCESS_SET_INFORMATION` (`0x200`). Every oracle read succeeded, and all seven cases ended with a verified return to class 2. `OpenProcess(0)` separately failed with Win32 5 before either GPU API could be called. The initial run stopped while handling that zero-rights case before any setter; it is not counted as a completed matrix. Evidence: `gpu-rights-owned-v2/rights-fixture.jsonl`, independently matched to `gpu-rights-summary.json`.

This establishes the right's effect for the controlled fixture on this build. Combined with the missing right on Fortnite's tested handles, it explains why retrying those same access paths has no demonstrated route to a successful class change. It does not replace a future successful getter/setter/readback on the actual game.

## Native startup timing check

The earlier managed startup probe had reached its first GPU query about 0.52 ms after creation. A further C++ probe used the installed SDK's `SystemBasicProcessInformation` declaration, a preallocated buffer, and a bounded busy poll after the EAC service appeared. The busy period was limited to ten seconds; it temporarily changed only its own polling thread's affinity and relative priority, then restored them before inspecting the acquired handle. No protection setting or anti-cheat process priority was changed.

This run acquired Fortnite PID **11876**, creation FILETIME **134341822028858695**, with its `OpenProcess` return timestamp **93.3 microseconds after process creation**. The acquired handle's observed mask was again **`0x103000`**, and the GPU getter returned **`0xC0000022`**. It ended with `applied:false`; no game setter ran. The timestamp measures handle acquisition, not the later GPU query. Evidence: `native-startup.jsonl`. This is an earlier tested acquisition point, not a guarantee that every possible startup interval was covered. [Documented basic-process snapshot](https://learn.microsoft.com/en-us/windows/win32/api/winternl/nf-winternl-ntquerysysteminformation).

## Launch-returned handles and public brokers

A bounded follow-up reviewed whether a supported launch operation could supply the actual game handle without reopening or duplicating it. **No additional documented Fortnite-compatible route was established.** This pass reviewed contracts only; it did not launch Windows processes or repeat the access experiments.

| Public contract | What it returns or controls | Relevance to the missing game handle |
| --- | --- | --- |
| `CreateProcess` family / `PROCESS_INFORMATION.hProcess` | A handle to the newly created process. Microsoft describes creation handles as having full access, subject to security checking. | A real candidate when the caller legitimately creates the final application directly. Creating a launcher supplies that launcher's handle; the contract does not promise a handle to a game subsequently created by another process. [Returned identity](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/ns-processthreadsapi-process_information), [access qualification](https://learn.microsoft.com/en-us/windows/win32/procthread/process-handles-and-identifiers). |
| `ShellExecuteEx` with `SEE_MASK_NOCLOSEPROCESS` | May return a handle to the newly started application. Some successful activations return no handle, including reuse of an existing application. | No documented guarantee of `PROCESS_SET_INFORMATION` or of receiving the eventual shipping game's handle through an existing launcher/protocol handler. [Shell execution contract](https://learn.microsoft.com/en-us/windows/win32/api/shellapi/ns-shellapi-shellexecuteinfow). |
| `ICreatingProcess` / `ICreateProcessInputs` | A Shell site-chain callback can adjust creation/startup flags, environment variables, hotkey, and title. | The reviewed interface has no process-handle output, GPU-class property, or authorization to control a later launcher-created child. [Creation callback](https://learn.microsoft.com/en-us/windows/win32/api/shobjidl_core/nn-shobjidl_core-icreatingprocess), [available inputs](https://learn.microsoft.com/en-us/windows/win32/api/shobjidl_core/nn-shobjidl_core-icreateprocessinputs). |
| `IApplicationActivationManager::ActivateApplication` | Activates a Windows Store application identified by AUMID and returns the PID fulfilling that launch contract. | Returns no process handle or GPU-class control. A PID alone returns the investigation to the already-tested handle-acquisition boundary. [Activation contract](https://learn.microsoft.com/en-us/windows/win32/api/shobjidl_core/nf-shobjidl_core-iapplicationactivationmanager-activateapplication). |
| `GetProcessInformation` / `SetProcessInformation` | Public information classes cover memory, power throttling, protection information, machine type, and other listed settings. | The reviewed public enumeration provides no GPU scheduling-process-class alternative; reserved values are not supported control contracts. [Information classes](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/ne-processthreadsapi-process_information_class). |

The creation-handle contract does not establish that directly starting Fortnite's shipping executable preserves its supported launcher and anti-cheat flow, or that the resulting handle would retain the required access. That missing binding keeps direct creation a conditional mechanism rather than a verified workaround. None of these contracts grants a protection exemption or establishes publisher endorsement.

## Outcome

| Requirement or hypothesis | Status and limit |
| --- | --- |
| Initial CPU class or parent GPU class changes child GPU class | **Tested negative** for all 12 fixture combinations; all children stayed at class 2. |
| Parent fixture restoration | **Verified:** setter and separate getter both succeeded for original class 2. |
| Additional manifest-based process-class observation | **Reviewed:** 1,887 schemas across eight selected providers, zero reported errors, no new qualifying field. Non-manifest/private paths remain outside this inventory. |
| Session or the two named privileges explain Fortnite denial | **Tested negative** for the recorded process instance and access masks. |
| Launcher handle capture/duplication can control an ordinary graphics child | **Verified:** three successful source masks, class apply/hold/restore, and PSS cleanup. |
| Launcher handles or broader normal access modes provide Fortnite GPU control | **Tested negative:** identity-matching copies and direct handles lacked `0x200`; getters remained denied. |
| Process pseudo-handle duplication provides Fortnite GPU control | **Tested negative:** owned positive control passed, but both game-copy variants were still restricted. |
| `0x200` controls getter/setter access in the owned fixture | **Verified for seven valid masks:** independent observations agreed with every setter result and all states returned to 2. |
| Native acquisition earlier than the managed polling result | **Tested negative:** handle acquired at 93.3 microseconds still lacked `0x200` and the GPU getter was denied. |
| A public launch broker supplies the actual game handle or an alternative process-class control | **Contract review only:** no additional Fortnite-compatible route established. Direct creation remains conditional on a supported launch path and verified returned rights. |
| Fortnite original, changed, sustained, and restored GPU class | **Unresolved:** original remains unreadable. The later direct-setter follow-up below attempted class 3 under Administrator and SYSTEM; both setters returned `0xC0000022`. |
| Fortnite backend behavior | **Verified denial:** the integrated retained-handle session reported unavailable in both actors and created no GPU mutation journal. No working Fortnite class-control route is implemented. |
| Vendor-supported integration contract | **Not established.** Outreach was declined; no external message was sent and the private draft remains local. |

The access-test phase was cleaned up and archived with **90 per-file size/SHA-256 checks** passing. Archive SHA-256: `AB873FC4D10519EFCE155CCB5E3E1FD4F2340A29EF41054EF702DD072D9D0B05`. Its Windows staging directory and remote archive were removed after local verification. The native timing phase was also closed normally, its helpers and tasks removed, and its separate archive verified against all **18 file hashes** before removing the Windows stage. Native archive SHA-256: `7BE855029E6C5466B4A4BD573E61800EEAAFE06209CEE4455D5466A139179971`. Final checks preserved the original Epic/Steam process identities, Epic priorities/affinity, Process Lasso configuration/service, power plan, and EAC service configuration; both local `backend/state` directories were empty. No game setter ran during these access and timing phases. Cleanup of the subsequent direct-setter trial is recorded below.

## Review limits

The reviewed sources were the Microsoft contracts linked above and Microsoft GPUView/display-driver documentation. Targeted searches covered the exact process-class API names, initialization/inheritance terms, and DxgKrnl process-priority event terms. First-party repository tree checks did not locate a public DxgKrnl event-manifest source in `microsoft/perfview`, `microsoft/Windows-driver-samples`, or `microsoft/Windows-classic-samples`. A repository-tree search is not a scan of every source body. Third-party manifest mirrors were not accepted as current Microsoft event authority. The executed results above establish only the recorded fixture, installed schemas, and Fortnite process instance; they do not prove that an official solution is universally impossible.

## Stock application and direct setter follow-up

The official System Informer **4.0.26241.138** distribution was tested in user mode with `-nokph`, an existing private portable settings file, and no staged driver. Its EXE, UserNotes plugin and ToolStatus plugin had valid Winsider signatures; the release archive matched its published SHA-256. The stock **Graphics priority** control changed an owned process from actual class 2 to 3 and back to 2, independently logged by that process. A newly opened dialog also read class 3. On the separately identity-bound Fortnite process, the same control failed its initial GPU getter with access denied and never reached its setter. [Official release](https://github.com/winsiderss/systeminformer/releases/tag/v4.0.26241.138).

To distinguish a refused getter from a refused setter, a later bounded live test called `D3DKMTSetProcessSchedulingPriorityClass(handle, 3)` directly. The game was in its lobby and was closed normally after the trial, providing process-lifetime cleanup without assuming an unreadable original. Both the Administrator caller and the SYSTEM caller returned `0xC0000022` from the setter and both before/after getters. Both held granted mask `0x103000`, without `PROCESS_SET_INFORMATION`. SeDebugPrivilege and SeIncreaseBasePriorityPrivilege were enabled for both; SeTcbPrivilege was also enabled for SYSTEM. No successful class change is claimed.

The stock application, fixture, scheduled helpers, game and temporary Windows source/package directory were removed after evidence transfer. No driver was loaded and no anti-cheat, registry or boot setting was changed. This extends the observed denied paths; it does not establish universal impossibility or a working Fortnite workaround.

## Supported-tool contract follow-up

Bitsum's current [GPU priority documentation](https://bitsum.com/apps/process-lasso/docs/rules/priorities/) explicitly excludes anti-cheat-protected processes from its GPU-class control and excludes GPU classes from registry enforcement. Its developer [confirmed the access limitation on January 19, 2026](https://community.bitsum.com/forum/index.php?topic=38884.0). Bitsum identifies the same D3DKMT process-class getter/setter in its [GPU priorities description](https://bitsum.com/gpu-priorities/). These are product support statements, not proof that every possible Windows integration must fail; they provide no supported Process Lasso workaround for the recorded Fortnite denial. No Process Lasso rule, service or configuration was changed for this review.

## Additional configuration and launch review

The subsequent search examined different published integration surfaces:

| Surface | Finding and limit |
| --- | --- |
| [AMD GAIA gaming-server proposal](https://github.com/amd/gaia/issues/407) | Names the exact D3DKMT setter, but remains an open proposal. The three proposed implementation files were absent from the reviewed repository tree at `3af8615629cf76a09ae88f57b53adb387cb413a6`; no alternate protected-process access mechanism was established. |
| [Microsoft D3DConfig](https://devblogs.microsoft.com/directx/d3dconfig-a-new-tool-to-manage-directx-control-panel-settings/) in [Agility SDK 1.619.5](https://www.nuget.org/packages/Microsoft.Direct3D.D3D12/1.619.5) | Documentation and static inspection established no GPU process-class override. Among 4,130 unique ASCII/UTF-16 strings, priority matches were four validation-message names; no scheduling or D3DKMT name was found. This limited inspection is not a complete behavioral proof. The package was inspected on Linux and not installed or executed. |
| [Microsoft remote-session GPU priority setting](https://learn.microsoft.com/en-us/azure/dev-box/how-to-resolve-dev-box-connectivity-issues) | Documents remote-connection prioritization, with no per-game process-class contract or Fortnite readback. No registry change was made. |
| [EOS launcher restart API](https://dev.epicgames.com/docs/api-ref/functions/eos-platform-check-for-launcher-and-restart) | Takes an EOS platform object and returns an EOS result, not a Windows game-process handle. Epic's reviewed shortcut and anti-cheat help supplied no final-process access guarantee or supported EAC/BattlEye selector. |

None of these reviewed surfaces supplied a new supported Fortnite class-control candidate. No new live priority test or Windows mutation followed from this pass; the requested game-class outcome remains unresolved.

## Additional policy and telemetry experiments

The next self-process fixture tested six background-mode/QoS combinations before graphics-device creation and the same combinations after creation from independently read GPU classes 2 and 3: **18 policy cases**. All **125 native GPU getters** succeeded. The policies left the GPU class unchanged; a direct-setter positive control changed 2 → 3 → 2 and restoration succeeded. These are results for the tested fixture/build, not a universal policy-independence guarantee or a Fortnite control result. The published [background-mode](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-setpriorityclass) and [QoS](https://learn.microsoft.com/en-us/windows/win32/procthread/quality-of-service) contracts themselves provide no GPU process-class selector. No game or global policy was changed in that fixture.

The earlier ETW calibration had explicitly enabled only events 21, 239 and 515. A subsequent DxgKrnl capture removed the event-ID filter and enabled all provider keywords around getter-confirmed class transitions **2 → 3 → 1 → 3 → 2**. It recorded **86,641 events across 126 decoded shapes**, with zero reported loss, decoding failures or saved-record cap hits. Its 9 MiB ETL stayed below the 64 MiB circular capacity. The fixture passed 42 during-phase native class reads and 43 verified compute dispatches. Event 515 still exposed identical priority payloads during those distinct class setters.

Profiler events 105/106 added a useful but narrower signal: controlled call intervals associated function number 2031 with the setter and 2032 with the getter on this Windows build. Their payload reports the function number, without class input, result status or target handle. This is an empirical call-occurrence mapping, not a stable API contract or a class-value oracle. In particular, [TraceLogging's self-describing metadata](https://learn.microsoft.com/en-us/windows/win32/etw/event-metadata-overview) means installed-manifest enumeration alone is not exhaustive.

A calibrated observer then watched a normal Fortnite desktop-shortcut launch for 120 seconds. The native-bound game instance reached `AthenaLobby` according to its diagnostic log during that window. The observer processed 14,948,708 profiler events with no reported losses, decode failures or output-cap hits. Matching setter/getter events belonged only to the observer's own positive control; none were recorded for the Fortnite PID. This does not establish absence from all game settings, gameplay paths, alternative APIs or per-target tracing conditions. No game GPU setter was invoked by this experiment.

The game closed normally. All owned helpers, trace sessions, tasks and Windows stages were removed after archive verification; Epic/Steam/ProcessGovernor identities, Process Lasso configuration and the power plan matched their baselines. These experiments narrow specific unknowns and leave Fortnite class control unresolved; they do not prove it impossible.

## Game Mode session and presentation checks

The 18 cases above are one background-mode/QoS matrix, not a count of all possible approaches. A subsequent read-only comparison ran the public GameList and GameModeUserConfiguration readers under the same user in SSH session 0 and interactive session 1. Both returned 107 entries, no Fortnite or Rivals match, an Epic launcher candidate without a configuration object, and no gaming-related exemption names. Both effective-power registrations succeeded and reported system mode 3, HighPerformance. That number is not GPU process class 3 and does not establish Game Mode activation or inactivity. The only confirmed game entry in a follow-up read belonged to another game; it was not changed or launched. These reads exclude session selection as the explanation for the absent target entries in this comparison, while leaving actual Game Mode activation untested. [GameList](https://learn.microsoft.com/en-us/uwp/api/windows.gaming.preview.gamesenumeration.gamelist?view=winrt-26100), [category meanings](https://learn.microsoft.com/en-us/uwp/api/windows.gaming.preview.gamesenumeration.gamelistcategory?view=winrt-26100), [effective-power registration](https://learn.microsoft.com/en-us/windows/win32/api/powersetting/nf-powersetting-powerregisterforeffectivepowermodenotifications).

Microsoft explicitly associates focus changes with GPU context scheduling updates. The documented fields concern context priority bands, relative priority and quantum; they do not establish a process-class change. Likewise, Fullscreen Optimizations can make an application believe it is exclusive fullscreen while Windows presents it through an optimized borderless path. A fullscreen API return alone therefore does not prove the underlying presentation path. [Context scheduling callback](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/d3dkmddi/nc-d3dkmddi-dxgkddi_setcontextschedulingproperties), [context arguments](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/d3dkmddi/ns-d3dkmddi-_dxgkarg_setcontextschedulingproperties), [fullscreen behavior](https://devblogs.microsoft.com/directx/demystifying-full-screen-optimizations/).

An owned RX the i5-14600K test PC XT presentation fixture exposed a missing prerequisite during follow-up validation: the Windows session was unlocked on the active input desktop, but the display was off. Earlier runs did not measure display power; their fullscreen state disappeared at Present, and the legacy-discard comparison returned `DXGI_STATUS_OCCLUDED`. Those attempts are not counted as confirmed visible-presentation tests. Adapter enumeration independently placed the active 1920×1080 display on the the i5-14600K test PC XT. Microsoft's occlusion guidance includes powered-off displays, and its console-display notification separately distinguishes off, on and dimmed states. [Occlusion conditions](https://learn.microsoft.com/en-us/windows/win32/direct3ddxgi/waiting-when-occluded), [display-power notification](https://learn.microsoft.com/en-us/windows/win32/power/power-setting-guids).

A temporary display-required request succeeded but did not alone produce an on notification. The documented display-on system command produced only a brief on state in this observation. A one-pixel KVM pointer movement and return then reset input activity, after which the fixture independently observed the display on throughout the completed run. Its original thread execution requirement was restored, without changing the power plan. [Execution-state contract](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-setthreadexecutionstate), [display system command](https://learn.microsoft.com/en-us/windows/win32/menurc/wm-syscommand).

The corrected run completed fourteen phase/baseline pairs across foreground, background, borderless and DXGI fullscreen operation, starting from native-read classes 2 and 3. All 112 samples independently matched the expected foreground PID, active input desktop, display-on notification and DXGI state; presentation returned success and GPU-rendered pixels were checked. Every sample retained its starting process class. The direct self-setter positive control changed 2 → 3 → 2, and final restoration to 2 succeeded. The evidence validator rejected a deliberately altered display-off sample. This establishes the observed result for the fixture's API states, not an independently traced exclusive-scanout path or Game Mode activation. Process Lasso foreground boosting was disabled and its configuration remained unchanged.

All owned helpers, tasks, thread execution requirements and Windows stages were cleared after archive verification. Epic/Steam/ProcessGovernor identities, Process Lasso configuration and the power plan were preserved. The corrected run closes the fixture's display-state gap; it supplies no actual Fortnite process-class change and does not establish that all possible approaches have been tested.
