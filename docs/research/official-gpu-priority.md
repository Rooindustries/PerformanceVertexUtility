# Official GPU scheduling interfaces for protected games

Updated: **2026-09-18**. This report combines executed Windows results with Microsoft and AMD contract review. The backend's integration boundary is described in [Protected sessions](../../backend/native/PROTECTED-SESSIONS.md).

## Current result

**Rivals GPU process priority was successfully changed from class 2 to class 3 and restored to class 2 in two normal-launch trials.** The second trial included **325 controller readbacks and 301 independent watcher readbacks** of class 3 over an apply-to-restore interval of **327.581218 seconds**. After the exact owned controller was deliberately terminated, its watcher restored and independently read class 2 while the game remained alive; both helpers then exited. The earlier two-minute single-handle trial also remains valid. Every fresh-handle GPU getter during both holds returned access denied.

These are the two original private trials. **The retained-handle route is now integrated into the protected-session backend and passed a third live Rivals launch.** The integrated worker read class 3 through login and Practice Range; its separate watcher restored/read class 2 at 06:14:04 UTC after controller termination while the same game remained alive. A fresh backend query remained denied. The integrated checks passed 69 runtime assertions with fresh control handles deliberately denied, seven initialization-policy boundary assertions, and 39 broader hardware assertions including relaunches and core switching. The complete native 90-second initialization-expiry transition was not reproduced; its policy was checked at the decision boundary.

Arbitrary repeated launches, game updates, full-match behavior, performance gains, and game-vendor endorsement remain unestablished. Fortnite remained denied in the [subsequent local access investigation](fortnite-gpu-class-initialization.md), including native handle acquisition **93.3 microseconds** after creation, and again in the integrated backend. Its tested handles lacked `PROCESS_SET_INFORMATION`. Earlier probes stopped at denied readback; subsequent direct Above Normal setters under Administrator and SYSTEM also returned `0xC0000022`. The overall application goal remains unfinished.

| Component | Tested configuration |
| --- | --- |
| Machine | `the i5-14600K test PC`; Intel i5-14600K; AMD RX the i5-14600K test PC XT |
| Windows / SDK | Windows 11 Pro build 26200; installed SDK 10.0.26100.0 |
| AMD driver | 32.0.31035.1003 |
| Games | Fortnite 42.20; Marvel Rivals 1.1.3870120 |
| Hardware scheduling | Real-RX fixture query reported HAGS enabled through `D3DKMT_WDDM_2_7_CAPS`, raw flags 11 |
| Caller privileges | `SeDebugPrivilege` and `SeIncreaseBasePriorityPrivilege` were already enabled in the recorded token check |

## Executed Rivals trials

### Paired controller and recovery watcher

Evidence records: `paired-events.jsonl`, `paired-watch-events.jsonl`, `paired-verified-summary.json`, and `paired-crash-result.json`, with identity-bound original and recovery-ready records. Raw samples were independently counted and the elapsed interval recomputed. The game was PID **18996**, creation FILETIME **134341553526629520**; controller PID **20424** and watcher PID **16596** were owned helpers.

| Stage | Observed result |
| --- | --- |
| Acquire and prepare recovery | The controller normally opened its own game handle **1.1094 ms** after game creation and duplicated that handle into its own prestarted watcher at **1.7026 ms**. Both handles had granted access `0x103200`. |
| Original state and readiness | Both helpers obtained original class **2** before mutation. The original journal and recovery-ready records bind that value and access to the same PID/creation identity. The watcher logged its armed state before apply. |
| Apply | The native setter for class **3** returned **0**; a separate getter returned **0** and class **3**. |
| Controller hold | **325/325** retained-handle getters returned **0/class 3**. All **325** corresponding fresh GPU getters returned `0xC0000022`. |
| Independent watcher hold | **301/301** watcher getters returned **0/class 3** through its duplicated handle. The apply-to-restore interval was **327.581218 seconds**. |
| Controller failure | The exact owned controller, PID **20424**, was deliberately terminated while the game and watcher remained active. |
| Recovery | Watcher native restore-set and separate getter both returned **0**, with observed class **2**. The crash-result record confirms the game remained alive and both helper processes had exited. |

The live trial passed through login/loading and reached Practice Range. Inspected captures `rivals-paired-practice-live.png` and `rivals-after-controller-crash.png` both show Practice Range. They support the visible game-state observation; the native getters establish GPU class. The hold samples establish sampled persistence, not continuous observation between queries.

The duplicated handle came from the controller's own normal `OpenProcess` result and was transferred to its own watcher. No handle was borrowed from an unrelated process. No injection or security-descriptor, driver, anti-cheat, or registry change was used for this GPU trial.

### Earlier single-handle trial

Evidence record: `rivals-basic-apply.jsonl`. Its 131 JSON records were inspected and its hold samples independently counted. The target was `Marvel-Win64-Shipping.exe`, PID **20876**, creation FILETIME **134341535093611251**. The record also contains the full executable path.

| Stage | Observed result |
| --- | --- |
| Discovery and handle | First seen **1.4805 ms** after creation; normal handle opened **2.6575 ms** after creation. Requested access `0x101200`; granted access `0x103200`. |
| First GPU query | **2.7625 ms** after creation; status `0xC000000D`, with no value. This is query timing, not handle-acquisition timing. |
| Original state | The first successful getter returned class **2**, logged approximately **770.4244 ms** after creation. The initial error was not replaced with a default class. |
| Apply | Setter requested class **3** and returned `0x00000000`. A separate getter returned `0x00000000` and class **3**. |
| Hold | **120/120** retained-handle queries returned `0x00000000` and class **3**, at approximately one-second intervals. Their elapsed times span **0.0001324–119.7199794 seconds**. |
| Fresh-handle comparison | **120/120** fresh GPU getters returned `0xC0000022`. Their `freshOpenError` fields were null: the recorded failure was the GPU getter, not `OpenProcess`. |
| Restore | While the game remained alive, setter **2** and a separate getter **2** both returned `0x00000000`. The logged apply-to-restore interval was **120.7278 seconds**. |

The hold proves sampled persistence; it does not continuously observe the intervals between queries. The trial used a normal Epic launch and only the helper's normally opened retained handle. It changed and restored the game's GPU class without borrowed handles, injection, or security-descriptor, driver, anti-cheat, or registry changes.

Both trials use documented Windows APIs and establish the observed behavior on this build. Explicit game-vendor endorsement and a universal acquisition-time guarantee have not been established.

### Verified startup sequence

1. Start an owned recovery helper and verify its process identity before arming the game launch.
2. Watch for the exact shipping executable using `SystemBasicProcessInformation` on a supported Windows build. The paired trial used a process-local high-resolution waitable timer with a requested one-millisecond interval. This does not guarantee one-millisecond capture. Microsoft documents the basic snapshot as a faster process-enumeration option. [Process enumeration](https://learn.microsoft.com/en-us/windows/win32/api/winternl/nf-winternl-ntquerysysteminformation).
3. Open an ordinary process handle requesting `QUERY_LIMITED_INFORMATION | SET_INFORMATION | SYNCHRONIZE`, then immediately duplicate that owned handle into the recovery helper. Verify the executable path, PID, creation identity, granted access, and live state through both handles.
4. Wait for graphics initialization if the retained getter initially returns `0xC000000D`. Require a successful original-class getter from both helpers; denied or unknown state must not be replaced with a default.
5. Durably record the original value and obtain the recovery helper's acknowledgement before applying class 3. Verify the result through the separate getter.
6. Retain both handles for observation and restoration. On controller loss, the watcher restores through its existing handle. Restore only a still-owned value; preserve a conflicting external value and report failed readback.

The original harness was a bounded investigation fixture. The subsequent backend integration provides the persistent feature; recovery after simultaneous loss of both helpers remains unestablished because the retained handles are then lost.

## Startup variability and other executed evidence

An earlier Rivals read-only run had granted access `0x103200` and a **first GPU query at 4.8526 ms** after creation. That value is not an established handle-acquisition timestamp. Its getter initially returned `0xC000000D`, then successfully read class 2 around 0.9 seconds after creation. A separate run first sampled at approximately 15.5 ms had reduced access `0x103000` and GPU getter `0xC0000022`. These differing outcomes establish timing variability. The successful apply trace recorded a maximum scan gap of **44.0351 ms**, so a requested timer interval is not a guaranteed detection deadline.

The earlier managed Fortnite record, `fortnite-fastest-apply.jsonl`, binds PID **21016** and creation FILETIME **134341545568564346**. Its first GPU query was **0.5187 ms** after creation; requested access was `0x101200`, granted access was `0x103000`, and the getter returned `0xC0000022`. Ten subsequent retained queries also returned that status. The record ends with `applied:false`; there was no setter call. The later native acquisition and handle-duplication comparisons are recorded in the [follow-up investigation](fortnite-gpu-class-initialization.md).

Earlier parent-process experiments verified class 3 on an EAC wrapper/service before Fortnite creation, and on an ordinary Rivals launcher before its access became restricted. Those parent values did not provide readable child-game GPU state. **GPU process-class inheritance remains unverified.** Microsoft's published CPU inheritance rules concern `CreateProcess`, `GetPriorityClass`, and CPU thread scheduling; they do not establish GPU-class inheritance. [CPU scheduling contract](https://learn.microsoft.com/en-us/windows/win32/procthread/scheduling-priorities).

The RX the i5-14600K test PC XT fixture separately accepted DXGI device-relative priority `0 → 1 → 7 → 0`, with successful getter/setter results, while its GPU process class stayed 2. CPU High priority, value 128, also left GPU process class 2. These checks demonstrate distinct control scopes.

## Windows authority and required readback

The documented `D3DKMTSetProcessSchedulingPriorityClass` and `D3DKMTGetProcessSchedulingPriorityClass` operate on a process `HANDLE`. Their enum identifies Normal as 2 and AboveNormal as 3. They are available from Windows Vista through Gdi32. The published pages do not specify minimum handle rights, protected-target behavior, or an inheritance guarantee. Preserve raw NTSTATUS and the requested/granted access evidence; do not invent a documented access requirement. [Setter](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/d3dkmthk/nf-d3dkmthk-d3dkmtsetprocessschedulingpriorityclass), [getter](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/d3dkmthk/nf-d3dkmthk-d3dkmtgetprocessschedulingpriorityclass), [class values](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/d3dkmthk/ne-d3dkmthk-_d3dkmt_schedulingpriorityclass).

Microsoft documents that existing handles retain granted access when later security changes restrict new acquisition. A process handle remains valid until closed, including after process termination; validity alone therefore does not establish liveness. Handle callbacks may reduce requested rights, including `PROCESS_SET_INFORMATION`, so a requested mask is not proof of the granted mask. [Retained-access model](https://devblogs.microsoft.com/oldnewthing/20200320-00/?p=103579), [handle lifetime](https://learn.microsoft.com/en-us/windows/win32/procthread/process-handles-and-identifiers), [access filtering](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/wdm/ns-wdm-_ob_pre_create_handle_information).

`DuplicateHandle` is a documented operation for process-object handles. The source and receiving process handles require `PROCESS_DUP_HANDLE`; the duplicate refers to the same object and its value is valid in the receiving process. This supports transferring the controller's own normally opened game handle to its owned watcher. It does not establish a right to obtain another process's handles or a guarantee that every protected-game duplication will retain usable access; the paired trial independently verified both resulting handles. [DuplicateHandle contract](https://learn.microsoft.com/en-us/windows/win32/api/handleapi/nf-handleapi-duplicatehandle).

| Required evidence | Interpretation |
| --- | --- |
| Verified executable, PID, creation identity, and live process on the retained handle | Establishes the target instance; a process name or reused PID is insufficient. |
| Getter fails or returns no valid class | Original state is unknown. No reversible mutation can be based on an assumed class 2. |
| Original getter succeeds; setter succeeds; separate getter matches | Establishes the requested class on that target at readback time. |
| Retained getter succeeds while a fresh getter fails | Retained readback remains evidence for its bound target; the fresh failure does not erase it. |
| Later state differs or becomes unreadable | Preserve the observed conflict/error. Earlier success does not establish the current class or future restorability. |
| Restore setter succeeds and separate live-target getter matches original | Establishes restoration for that process instance. |
| Launcher, device-relative priority, queue descriptor, allocation setting, or frame-rate change | Does not establish the game's GPU process class. |

## Other official interfaces

| Interface | Documented scope and verified limit |
| --- | --- |
| New process-class/PID/band variants | The current Microsoft D3DKMT index and reviewed public header expose the original process-class pair. No documented `…SchedulingPriorityClass2`, PID-based replacement, or public callable `D3DKMTSetProcessSchedulingPriorityBand` contract was established. This bounds the review; private exports or future interfaces may exist. [API index](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/d3dkmthk/), [pinned public header](https://github.com/microsoft/win32metadata/blob/5c5efbc01d4c87f6830ec304d42777991d533154/generation/WinSDK/RecompiledIdlHeaders/shared/d3dkmthk.h). |
| D3DKMT context priority | Getter/setter use a graphics context handle. The in-process variant orders contexts within one process. Neither reviewed contract supplies an external PID-to-game-context opening operation. [Context setter](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/d3dkmthk/ns-d3dkmthk-_d3dkmt_setcontextschedulingpriority), [in-process contract](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/d3dkmthk/ns-d3dkmthk-_d3dkmt_setcontextinprocessschedulingpriority). |
| DXGI device priority | `IDXGIDevice::SetGPUThreadPriority` controls a device already held by the caller. Relative values are −7 through +7; the setter also documents Windows 10+ absolute mode. The getter page describes the relative range. This is a device control, not a process-class reader. [Setter](https://learn.microsoft.com/en-us/windows/win32/api/dxgi/nf-dxgi-idxgidevice-setgputhreadpriority), [getter](https://learn.microsoft.com/en-us/windows/win32/api/dxgi/nf-dxgi-idxgidevice-getgputhreadpriority). |
| D3D12 queue priority | Queue creation supports Normal 0, High 100, and GlobalRealtime 10000, subject to capability/privilege requirements. `GetDesc` reads queue configuration. The caller needs the actual device/queue; `OpenSharedHandle` lists resources, heaps, and fences, not arbitrary foreign queues. [Priority contract](https://learn.microsoft.com/en-us/windows/win32/api/d3d12/ne-d3d12-d3d12_command_queue_priority), [capability query](https://learn.microsoft.com/en-us/windows/win32/api/d3d12/ns-d3d12-d3d12_feature_data_command_queue_priority), [queue readback](https://learn.microsoft.com/en-us/windows/win32/api/d3d12/nf-d3d12-id3d12commandqueue-getdesc), [shared objects](https://learn.microsoft.com/en-us/windows/win32/api/d3d12/nf-d3d12-id3d12device-opensharedhandle). |
| DXCore | Public states provide adapter/process memory, utilization, frequency, temperature, and enumeration data. No reviewed state reads or sets process scheduling class or band. [State enumeration](https://learn.microsoft.com/en-us/windows/win32/api/dxcore_interface/ne-dxcore_interface-dxcoreadapterstate), [pinned definitions](https://github.com/microsoft/DirectX-Headers/blob/505594c6e8d8369d94a3bc31162823daef013467/include/directx/dxcore_interface.h). |
| GPU focus bands | Idle, Normal, Focus, and Realtime are documented driver-side bands. Windows calls `DXGKDDI_SETCONTEXTSCHEDULINGPROPERTIES` during context creation, priority changes, and focus changes. This is an OS-to-display-driver callback, not an external process setter. [Bands](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/d3dkmddi/ne-d3dkmddi-_dxgk_scheduling_priority_band), [callback](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/d3dkmddi/nc-d3dkmddi-dxgkddi_setcontextschedulingproperties). |

Foreground activation is an input to Windows policy. `SetForegroundWindow` does not promise a particular GPU band or return one. HAGS likewise leaves prioritization decisions with Windows. The MMCSS `GPU Priority` registry field is explicitly documented as unused. None supplies the missing Fortnite class readback. [Foreground contract](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setforegroundwindow), [HAGS architecture](https://devblogs.microsoft.com/directx/hardware-accelerated-gpu-scheduling/), [MMCSS field](https://learn.microsoft.com/en-us/windows/win32/procthread/multimedia-class-scheduler-service).

## Independent scheduler observation

DxgKrnl events 21, 239, and 515 were tested against a real AMD compute workload with independently getter-confirmed process-class transitions `2 → 3 → 2`. Their captured priority payloads did not distinguish the classes. These events therefore failed calibration as a process-class observer on the tested configuration.

The decoded event 21 v2 and 515 v1 schemas supplied no value-map name for `PublicPriority` / `priorityBand`. Raw integers must not be assigned process-class or band meanings by guesswork. Microsoft's TDH APIs can decode metadata and maps; they do not themselves establish missing field semantics. [Event metadata](https://learn.microsoft.com/en-us/windows/win32/api/tdh/nf-tdh-tdhgeteventinformation), [value maps](https://learn.microsoft.com/en-us/windows/win32/api/tdh/nf-tdh-tdhgeteventmapinformation).

Microsoft's GPUView documentation describes process/context association, queued work, timing, and preemption. No documented field mapping that independently distinguishes process classes 2 and 3 was located. Utilization or faster execution does not uniquely determine a scheduling class. `D3DKMTQueryStatistics` is also labelled reserved for system use and offers no reviewed process-class result field. [GPUView process view](https://learn.microsoft.com/en-us/windows-hardware/drivers/display/viewing-a-process), [DMA details](https://learn.microsoft.com/en-us/windows-hardware/drivers/display/selections-in-the-gpu-hardware-queue), [query restriction](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/d3dkmthk/nf-d3dkmthk-d3dkmtquerystatistics).

## Game Mode configuration and runtime state

The unpackaged native C++/WinRT reader successfully obtained `GameModeUserConfiguration::GetDefault()` and **108 indexed entries** through `GameList::FindAllAsync()` as the existing administrator user. The corrected reader returned **0 related process names** from `GamingRelatedProcessNames().Size()`. The initial `relatedProcessCount:1` output was a mislabeled non-null-object Boolean and must not be interpreted as a count.

The indexed entries included Start-menu utilities and produced **no Fortnite/Rivals match**. No package capability or developer provisioning was added, and no Game Mode property setter or `SaveAsync` was executed. The successful reads establish availability of those operations on this caller/build; they do not establish an applicable target configuration or write support.

GamesEnumeration member pages identify `gameList` and warn about special Microsoft provisioning. They do not explain how that warning applies to unpackaged full-trust callers. Microsoft's general capability guidance distinguishes full-trust callers from AppContainer apps, and its desktop unsupported-API list does not name GamesEnumeration. Neither supplies a specific exemption. The observed successful reads must be preserved alongside this documentation gap; provisioning is not a demonstrated blocker for those reads. [Capability guidance](https://learn.microsoft.com/en-us/windows/apps/package-and-deploy/app-capability-declarations), [desktop restrictions](https://learn.microsoft.com/en-us/windows/apps/desktop/modernize/winrt-api-desktop-app-support), [member requirements](https://learn.microsoft.com/en-us/uwp/api/windows.gaming.preview.gamesenumeration.gamelistentry.gamemodeconfiguration?view=winrt-26100).

| Property/operation | What it establishes |
| --- | --- |
| `entry.GameModeConfiguration()` | Obtains the entry's configuration, introduced in GamesEnumerationContract v2 / SDK 16299. It has no target PID argument. [Acquisition](https://learn.microsoft.com/en-us/uwp/api/windows.gaming.preview.gamesenumeration.gamelistentry.gamemodeconfiguration?view=winrt-26100). |
| `PercentGpuTimeAllocatedToGame` | Nullable `Int32` configuration for GPU time when Game Mode is enabled. The reviewed contract gives no accepted range, default, null interpretation, clamping, or activation timing. Null must remain distinct from zero. [GPU-time property](https://learn.microsoft.com/en-us/uwp/api/windows.gaming.preview.gamesenumeration.gamemodeconfiguration.percentgputimeallocatedtogame?view=winrt-26100). |
| `IsEnabled` | Whether the entry is enabled for Game Mode; it is not a runtime activation result. [Enabled property](https://learn.microsoft.com/en-us/uwp/api/windows.gaming.preview.gamesenumeration.gamemodeconfiguration.isenabled?view=winrt-26100). |
| `SaveAsync` | An async persistence operation. No atomicity, live-application timing, rollback, or concurrent-writer guarantee is documented. Successful persistence and fresh-object readback would still be configuration evidence. [Save contract](https://learn.microsoft.com/en-us/uwp/api/windows.gaming.preview.gamesenumeration.gamemodeconfiguration.saveasync?view=winrt-26100). |

A documented runtime observation is `PowerRegisterForEffectivePowerModeNotifications(EFFECTIVE_POWER_MODE_V2, …)`, available from Windows 10 version 1903. It supplies the current mode and changes; `EffectivePowerModeGameMode` identifies **system Game Mode power state**. It provides no game PID or GPU percentage. Registration must be cleaned up with `PowerUnregisterFromEffectivePowerModeNotifications`. This route is documented; no executed result is recorded here. [Registration](https://learn.microsoft.com/en-us/windows/win32/api/powersetting/nf-powersetting-powerregisterforeffectivepowermodenotifications), [mode meanings](https://learn.microsoft.com/en-us/windows/win32/api/powersetting/ne-powersetting-effective_power_mode), [cleanup](https://learn.microsoft.com/en-us/windows/win32/api/powersetting/nf-powersetting-powerunregisterfromeffectivepowermodenotifications).

`HasExpandedResources` reports the calling app's runtime resource state, with no external PID or GPU percentage. Its expanded-resource API family is deprecated from Windows 10 version 1809. A call in an external helper does not observe the game's state. No reviewed public Game Mode ETW contract established effective per-process GPU-time allocation. [Caller-local query](https://learn.microsoft.com/en-us/windows/win32/api/expandedresources/nf-expandedresources-hasexpandedresources), [deprecation](https://learn.microsoft.com/en-us/previous-versions/windows/desktop/gamemode/game-mode-portal).

## AMD interface review

All **42 public ADLX headers** at commit `64c04f050899ad15dcc36aab11bf0722d2943db5` were retrieved and searched for priority/scheduling, with relevant application and 3D declarations inspected. No process scheduling-class getter/setter was found. Application interfaces identify processes; 3D interfaces expose graphics features. AGS's public header at `086c47ed8e427199510887230718cd7c086f9702` likewise supplied no external process-class control. [ADLX application interface](https://github.com/GPUOpen-LibrariesAndSDKs/ADLX/blob/64c04f050899ad15dcc36aab11bf0722d2943db5/SDK/Include/IApplications.h), [ADLX 3D interface](https://github.com/GPUOpen-LibrariesAndSDKs/ADLX/blob/64c04f050899ad15dcc36aab11bf0722d2943db5/SDK/Include/I3DSettings3.h), [AGS interface](https://github.com/GPUOpen-LibrariesAndSDKs/AGS_SDK/blob/086c47ed8e427199510887230718cd7c086f9702/ags_lib/inc/amd_ags.h).

Legacy ADL documents application-profile querying and assignment, but no reviewed property establishes the running process's WDDM class. A profile value is not runtime class readback. Installed-driver support and ADLX's restricted Session 0 surface remain separate constraints. No AMD profile change forms part of the verified Rivals route. [ADL profiles](https://gpuopen-librariesandsdks.github.io/adl/group__APPPROFILESAPI.html), [ADLX compatibility](https://gpuopen.com/manuals/adlx/programming-with-adlx/adlx-programming-guide/specifications/compatibility/), [service support](https://gpuopen.com/manuals/adlx/programming-with-adlx/adlx-programming-guide/advanced-configurations/using-adlx-in-a-windows-system-service-application/).

## Remaining verification

| Requirement | Status |
| --- | --- |
| Rivals process class 2 → 3, sampled hold, live restoration to 2 | **Verified for three recorded process instances:** two private trials and the integrated backend. |
| Rivals repeatability across ordinary launches | **Three successful trials recorded; broader reliability unestablished.** Earlier read-only/denied runs show timing variability. |
| Owned controller failure and watcher recovery | **Verified in the paired trial and integrated backend:** watcher restored/read class 2 while the game remained alive. |
| Backend integration and recovery checks | **Implemented.** 69 retained-handle runtime assertions, seven initialization-policy assertions and 39 broader session assertions passed; live Rivals apply/crash-restore passed. Simultaneous helper loss and arbitrary capture timing remain limitations. |
| Fortnite GPU apply and restoration | **Unresolved.** Startup and later handles remained restricted. Subsequent direct setters under Administrator and SYSTEM also returned `0xC0000022`; the game was closed normally after that bounded trial. |
| Game updates, full-match behavior, and performance gains | **Not established.** The paired trial reached Practice Range. |
| GPU process-class inheritance | **No supporting contract found; tested negative in the rendering fixture.** All 12 parent-GPU/child-CPU combinations retained child GPU class 2. |
| Target Game Mode configuration and active GPU allocation | **Excluded as a solution by the user.** Only an actual game GPU process-class change meets the requirement; allocation is a different control. No configuration was saved. |
| Game-vendor endorsement / universal support guarantee | **Not established.** Official API availability and the recorded build-specific result have narrower scope. |

## Cleanup and evidence retention

Both successful game mutations were restored with live native getter confirmation. The games were then closed normally. Final inspection found no trial tasks, owned helper processes, owned ETW sessions, or prior IFEO trial keys. Epic's original process and CPU/I/O/memory/GPU/affinity values were unchanged; Steam's process identity, Process Lasso's service/configuration hash, and the active power plan matched the baseline. Local main and implementation-worktree `backend/state` directories were empty.

The Windows evidence archive was copied and verified locally before the temporary Windows directory and archive were removed. All **225 manifest entries** passed size/SHA-256 checks, and ZIP CRC validation passed. Archive SHA-256: `D83711674C263E333E603917848A9643C32BBB25D02C26A4F079E7B361132C00`.
