# Windows native control contracts

Date: 2026-09-19. Scope: contracts for independently implemented, journaled Roo Industries adapters. This research used Microsoft documentation, Microsoft SDK headers, and read-only metadata/settings queries on `the i5-14600K test PC`. No setter, restore operation, reboot, adapter restart or registry write was executed.

Machine-readable facts and the read-only evidence are under `<private work folder>/four-tool-tweaks-20260919/fsos/`. The contract is `native-contracts.json`.

## Result handling and journal identity

There is no universal Windows success convention. BCD WMI methods return Boolean; System Restore WMI methods return an unsigned status; PowerShell cmdlets may produce no output; some mitigation failures are warnings. Each adapter must record invocation success, subsequent readback and effective/runtime state separately. A missing target, failed read, unsupported property or empty result is not a disabled setting.

Before applying, bind the journal to the exact boot-object GUID, adapter/property instance, volume or policy group and verify that the captured state still matches. Restore the captured representation, including absence/default state and distinct IPv4/IPv6 values. These are engineering requirements derived from the contracts below, not claims of completed execution tests.

## BCD

| Setting | Element type | Data | Setter |
| --- | --- | --- | --- |
| `disabledynamictick` | `0x260000A5` | Boolean | `SetBooleanElement` |
| `hypervisorlaunchtype` | `0x250000F0` | `uint64`: Off `0`, Auto `1` | `SetIntegerElement` |

The numeric types come from Microsoft's [BCD/BitLocker table](https://learn.microsoft.com/en-us/windows/security/operating-system-security/data-protection/bitlocker/bcd-settings-and-bitlocker) and [OS-loader element enumeration](https://learn.microsoft.com/en-us/previous-versions/windows/desktop/bcd/bcdosloaderelementtypes). The latter defines the hypervisor values. Microsoft documents dynamic-tick changes as debugging settings; this is not evidence of a gaming benefit. Boot-option changes require restart for effect. [BCDEdit options](https://learn.microsoft.com/en-us/windows-hardware/drivers/devtest/bcdedit--set).

Open `root/WMI:BcdStore` with `OpenStore(File="")` for the system store. `OpenObject` requires a GUID enclosed in braces. Use the resolved object's actual `Id` in the journal. On the the i5-14600K test PCXT, the current-object identifier `{fa926493-6f1c-4193-a414-58f0b2456d1e}` resolved successfully; the CLI alias `{current}` returned `false` through WMI. This alias result is live evidence, not a universal parser assumption. [OpenStore](https://learn.microsoft.com/en-us/previous-versions/windows/desktop/bcd/openstore-bcdstore), [OpenObject](https://learn.microsoft.com/en-us/previous-versions/windows/desktop/bcd/openobject-bcdstore).

Require a Boolean `ReturnValue` of `true` from enumeration, getters, setters and deletion. Do not compare it with numeric zero. Capture local element existence and its typed Boolean/Integer payload. Prove absence through a successful enumeration of the identified object; a failed getter alone is not proof of absence. Requery after mutation. Restore a previously absent element by deletion; restore a present element with its original typed value. Deletion exposes inherited/default behavior and is different from writing `false` or `0`. [EnumerateElements](https://learn.microsoft.com/en-us/previous-versions/windows/desktop/bcd/enumerateelements-bcdobject), [GetElement](https://learn.microsoft.com/en-us/previous-versions/windows/desktop/bcd/getelement-bcdobject), [Boolean setter](https://learn.microsoft.com/en-us/previous-versions/windows/desktop/bcd/setbooleanelement-bcdobject), [Integer setter](https://learn.microsoft.com/en-us/previous-versions/windows/desktop/bcd/setintegerelement-bcdobject), [DeleteElement](https://learn.microsoft.com/en-us/previous-versions/windows/desktop/bcd/deleteelement-bcdobject).

The the i5-14600K test PCXT probe successfully enumerated 15 elements and found neither requested type. No BCD change followed. Store readback can establish persistence; it cannot establish that the next boot used the setting. BitLocker and boot-policy compatibility must be assessed for the actual device before a boot-setting plan is executed; do not silently suspend protection as an adapter fallback.

## System process mitigations

`Get-ProcessMitigation -System` reads configured system defaults, not the mitigation state of every running process. `ON`, `OFF` and `NOTSET` are distinct. System `NOTSET` means the Windows default; it must not be converted to `OFF`. Restore an originally unconfigured setting through the documented `-Remove` mechanism rather than `-Reset` of the entire policy. [Get cmdlet](https://learn.microsoft.com/en-us/powershell/module/processmitigations/get-processmitigation?view=windowsserver2025-ps), [configuration/default semantics](https://learn.microsoft.com/en-us/defender-endpoint/enable-exploit-protection), [Set cmdlet](https://learn.microsoft.com/en-us/powershell/module/processmitigations/set-processmitigation?view=windowsserver2025-ps).

The shipped module on the the i5-14600K test PCXT is `ProcessMitigations` 1.0.12. Static inspection of its Microsoft DLL established two important implementation details: native write/query failures can be emitted as warnings, and setting a requested flag passes policy groups through the writer. Therefore `exit 0` and `-ErrorAction Stop` alone are insufficient. Capture warning and error streams, then requery all affected groups and their sibling fields. Unexplained warnings or sibling drift leave the operation unverified. The source DLL SHA-256 is `702da853b7151c6637d0724da7d6552b8a0197602c0c606a727305f8d0e3d810`; evidence is in `native-sources/mitigation-inspection/` and `native-readonly-types.json`.

| Parameter | Readback field | Coupled override field |
| --- | --- | --- |
| `DEP` / `EmulateAtlThunks` | `Dep.Enable` / `Dep.EmulateAtlThunks` | `Dep.OverrideDEP` |
| `SEHOP` | `Sehop.Enable` | `Sehop.OverrideSEHOP` |
| `ForceRelocateImages` / `RequireInfo` | `Aslr.ForceRelocateImages` / `Aslr.RequireInfo` | `Aslr.OverrideForceRelocateImages` |
| `BottomUp` / `HighEntropy` | `Aslr.BottomUp` / `Aslr.HighEntropy` | Corresponding `OverrideBottomUp` / `OverrideHighEntropy` |
| `StrictHandle` | `StrictHandle.Enable` | `StrictHandle.OverrideStrictHandle` |
| `CFG` / `SuppressExports` | `Cfg.Enable` / `Cfg.SuppressExports` | `Cfg.OverrideCFG` |
| `DisableExtensionPoints` | `ExtensionPoint.DisableExtensionPoints` | `ExtensionPoint.OverrideExtensionPoint` |
| `BlockDynamicCode` / `AuditDynamicCode` | `DynamicCode.BlockDynamicCode` / `DynamicCode.Audit` | `DynamicCode.OverrideDynamicCode` |
| `AuditFont` | `FontDisable.Audit` | `FontDisable.OverrideFontDisable` |
| `BlockRemoteImageLoads` / `AuditRemoteImageLoads` | `ImageLoad.BlockRemoteImageLoads` / `ImageLoad.AuditRemoteImageLoads` | `ImageLoad.OverrideBlockRemoteImageLoads` |

These field names were verified against live read-only objects and the shipped module's parameter map. A flags-only snapshot omits override state and coupled options. Restoration must preserve the entire affected group; whether a particular `-Remove` call resets sibling fields requires a disposable execution regression before relying on that behavior. The module explicitly rejects 14 payload/child-process parameters in system mode using warnings; the Dash mitigation parameters listed above are not in that block list.

## System Restore

`root/default:SystemRestore.Enable` and `Disable` return `uint32`; `0` (`S_OK`) is success, while other values are COM error codes. A system-drive or empty-drive call has global monitoring consequences: documented Enable starts monitoring all drives; Disable leaves no drives monitored. Capture volume identities and the entire affected configuration, rather than treating `C:\` as a single isolated target. Enabling a non-system volume requires the system drive enabled first. [Enable](https://learn.microsoft.com/en-us/windows/win32/sr/enable-systemrestore), [Disable](https://learn.microsoft.com/en-us/windows/win32/sr/disable-systemrestore).

The public Enable documentation says it returns before activation completes. The the i5-14600K test PCXT's actual `sr.mof` and CIM schema additionally expose `WaitTillEnabled:Boolean`. Inspect the method schema and use that parameter when present; older signatures must remain compatible. A returned zero still does not validate a per-volume detector.

No supported programmatic per-volume enabled-state getter was identified in these interfaces. `SystemRestore` instances enumerate restore points; `GetLastRestoreStatus` reports a past restore, and `SystemRestoreConfig.RPSessionInterval` is an interval backed by a registry value. None proves current per-volume protection. Microsoft's cmdlet docs direct state inspection to the System Protection/restore UI. Consequently a point count of zero, an interval, or successful Enable invocation must not produce a fabricated enabled/disabled status. [SystemRestore class](https://learn.microsoft.com/en-us/windows/win32/sr/systemrestore), [Enable-ComputerRestore](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.management/enable-computerrestore?view=powershell-5.1), [System Protection](https://support.microsoft.com/en-us/windows/experience/backup-recovery/system-protection).

**Configuration restoration is not restore-point recovery.** An erased restore point cannot be reconstructed from a settings journal. This research did not execute Disable or establish point-retention behavior for every Windows build; the Enable/Disable API pages do not promise retention. Treat point-erasing paths as destructive, and do not advertise exact data rollback. Before automated disable/restore can meet an exact-restore contract, a reliable supported per-volume baseline and a disposable test of the target build's retention behavior are still required. This is a specific verification dependency, not evidence that the WMI mutation interface is absent.

## Hibernation

Read `GetPwrCapabilities` and require its nonzero `BOOLEAN` result; on zero record `GetLastError`. `HiberFilePresent` reports file presence and `SystemS4` reports S4 support; they are distinct. Use the SDK structure layout, with one-byte `BOOLEAN` fields. Current SDK `HiberFileType` constants are None `0`, Reduced `1`, Full `2`. Unknown types or failed reads remain unknown. [GetPwrCapabilities](https://learn.microsoft.com/en-us/windows/win32/api/powerbase/nf-powerbase-getpwrcapabilities), [structure](https://learn.microsoft.com/en-us/windows/win32/api/winnt/ns-winnt-system_power_capabilities), [Microsoft SDK header](https://github.com/microsoft/win32metadata/blob/main/generation/WinSDK/RecompiledIdlHeaders/um/winnt.h).

Snapshot enabled/file-present state, type, documented `HiberFileSizePercent` under `HKLM\SYSTEM\CurrentControlSet\Control\Power`, and the original type/absence of related configuration fields. `powercfg /hibernate on|off`, `/type full|reduced`, and `/size <percent>` are supported controls. Reduced mode supports hiberboot only. Microsoft's prescribed transition to reduced mode is `/size 0` then `/type reduced`; size changes enable hibernation. Restore full/reduced type and sizing policy in the correct order, then independently query them again. A previous disabled state is restored last, because size/type setup may enable it. [Powercfg contract](https://learn.microsoft.com/en-us/windows-hardware/design/device-experiences/powercfg-command-line-options#hibernate-or-h).

Require process completion, exit code zero, captured diagnostics and matching readback. Percentage restoration does not guarantee identical file bytes after RAM/build changes. No supported command restores the prior hibernation image contents. Restoring configuration therefore cannot undo discarded hibernation data. `HiberbootEnabled`/Fast Startup and power-menu visibility are separate settings; avoid declaring them verified from `HibernateEnabled` alone. [Hibernation support](https://learn.microsoft.com/en-us/troubleshoot/windows-client/setup-upgrade-and-drivers/disable-and-re-enable-hibernation), [system power states](https://learn.microsoft.com/en-us/windows/win32/power/system-power-states), [Fast Startup behavior](https://learn.microsoft.com/en-us/troubleshoot/windows-client/setup-upgrade-and-drivers/fast-startup-causes-system-hibernation-shutdown-fail).

## Network adapters

Bind each plan to `InterfaceGuid` plus `PnPDeviceID`, setting `InstanceID`, driver identity/version and exact `RegistryKeyword`. Re-resolve fresh instances before apply/restore and compare identities. The adapter alias can change; `InterfaceIndex` can change across disable/enable. Do not use a wildcard when the reviewed adapter disappears. Prefer a resolved property CIM object for `Set-NetAdapterAdvancedProperty -InputObject`. [Adapter identity contract](https://learn.microsoft.com/en-us/windows/win32/fwp/wmi/netadaptercimprov/msft-netadapter).

Read advanced properties with `-AllProperties`; validate the exact keyword and `ValidRegistryValues`. Store the entire `RegistryValue` string array, not a formatted display label or a scalar coercion. Set the saved array for restoration. `Reset-NetAdapterAdvancedProperty` selects the driver's factory default and is not exact restore. A property absent before application cannot be recreated/deleted safely by guessing its type; require the property's supported create/remove contract or leave that operation unsupported. [Get](https://learn.microsoft.com/en-us/powershell/module/netadapter/get-netadapteradvancedproperty?view=windowsserver2025-ps), [Set](https://learn.microsoft.com/en-us/powershell/module/netadapter/set-netadapteradvancedproperty?view=windowsserver2025-ps), [Reset](https://learn.microsoft.com/en-us/powershell/module/netadapter/reset-netadapteradvancedproperty?view=windowsserver2025-ps).

LSO exposes `V1IPv4Enabled`, `IPv4Enabled` and `IPv6Enabled`; `IPv4Enabled` is LSOv2 IPv4. Restore each captured supported field separately. RSC exposes separate IPv4/IPv6 configuration and operational booleans, plus failure reasons: configured-on does not prove operational-on. Query and report both. [LSO class](https://learn.microsoft.com/en-us/windows/win32/fwp/wmi/netadaptercimprov/msft-netadapterlsosettingdata), [RSC class](https://learn.microsoft.com/en-us/windows/win32/fwp/wmi/netadaptercimprov/msft-netadapterrscsettingdata), [LSO setter](https://learn.microsoft.com/en-us/powershell/module/netadapter/set-netadapterlso?view=windowsserver2025-ps), [RSC setter](https://learn.microsoft.com/en-us/powershell/module/netadapter/set-netadapterrsc?view=windowsserver2025-ps).

NetAdapter setters normally emit no output unless `-PassThru`; lack of output is not failure or proof of success. Use terminating-error handling and fresh typed readback. `-NoRestart` avoids immediate adapter restart, but settings may remain pending until restart. Capture that pending state and restart only under the specific authorized plan. On the the i5-14600K test PCXT, the read-only LSO query returned no instances; RSC returned one instance. The LSO result is Unavailable, not Disabled. The live schema and Microsoft docs confirm the LSO property names; no live LSO object was available to inspect extra PowerShell aliases.

## Verification scope

Read-only evidence confirms BCD/SystemRestore method return types, the current-object WMI alias behavior, absence of both BCD elements in a successful enumeration, mitigation field/override names, the current System Restore signature and NIC schema. SDK constants were checked in Microsoft's headers. No apply/undo or destructive-effect test was performed. Remaining execution gates are per-volume System Restore state/retention, mitigation group-preserving restoration, hardware-dependent NIC changes and hibernation type/size restoration on representative disposable Windows environments.

## Hibernation representation on the the i5-14600K test PCXT

At `2026-09-19T16:28:13Z`, the read-only `GetPwrCapabilities` call succeeded. `SystemS4=true`, `HiberFilePresent=false`, SDK `HiberFileType=0` (None), `Hiberboot=false`, and `AoAc=false`. `C:\hiberfil.sys` was absent. The current configuration in `HKLM\SYSTEM\CurrentControlSet\Control\Power` was:

| Value | Presence/type | Data |
| --- | --- | --- |
| `HibernateEnabled` | Present, DWORD | `0` |
| `HiberFileSizePercent` | Present, DWORD | `0` |
| `HiberFileType` | Absent | — |
| `HibernateEnabledDefault` | Present, DWORD | `1` |

The exact query is `fsos/query-hibernation-readonly.ps1`; the result is `servicing-readonly-windows.json`. The SDK Windows 10+ layout is 76 bytes, with offsets 6/8/18/20/22 for SystemS4/HiberFilePresent/Hiberboot/AoAc/HiberFileType. One-byte Boolean fields and four-byte DWORD/enum fields matter. `power-capabilities-layout.json` records the Microsoft header hash, derived offsets and an independent layout check. This was not compiled against an installed Windows SDK header on the target; the resulting buffer was successfully used with the actual API.

**The registry `HiberFileType` mapping is not established.** It is a separate representation from the SDK capability byte. Do not cast between them or invent registry values from the SDK enum. The current registry value is absent, so this host supplies no observed mapping for a present DWORD. The published `powercfg` contract also does not promise exact retention or reset of the raw `HiberFileType`/`HibernateEnabled` value presence, types or data across on/off/type/size transitions.

A configuration snapshot can represent `{actualMode, filePresent, raw HibernateEnabled, raw HiberFileSizePercent, raw HiberFileType}`, where each raw field includes existence, registry kind and data. Preserve `HibernateEnabledDefault` as an independent unchanged-state check. For this host the semantic mode is Off; the raw type is absent and the size policy is DWORD zero. A restore may be called exact for this representation only after both the supported API/file observation and every captured raw field match. If the supported transition alone leaves different raw values, raw repair is **not yet validated**: it needs an authorized disposable round trip showing consistency between kernel/file mode and the original opaque registry representation. This research does not authorize or establish such a repair, and never promises recovery of a hibernation image.

The target's own `powercfg /h /?` reports a minimum custom percentage of 40, whereas the general command reference currently says 50. The separate system-power-state documentation identifies default Full/Reduced sizes of 40%/20%. Therefore hardcoded cross-version assumptions about accepted percentages or preserved sizing are inappropriate: retain the actual saved policy and validate it on the target build. `/size 0` followed by `/type reduced` is documented; preservation of arbitrary raw registry values by an on/off round trip is not. [Power-state/hiberfile contract](https://learn.microsoft.com/en-us/windows/win32/power/system-power-states), [Powercfg options](https://learn.microsoft.com/en-us/windows-hardware/design/device-experiences/powercfg-command-line-options#hibernate-or-h). The live help is saved in `servicing-readonly-tools.json`.

## Optional features and dependency state

Use DISM for feature state and parent enumeration. `DismGetFeatureParent` returns a `DismFeature` array and count on `S_OK`; recursively query returned parents and preserve feature/image/package identity. A successful zero-count result means no declared parents from that query; an error does not. `Win32_OptionalFeature` provides only Enabled/Disabled/Absent/Unknown and no parent graph or pending-state distinction. [Parent API](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/dism/dismgetfeatureparent-function?view=windows-11), [CIM class](https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/win32-optionalfeature).

The live DISM read enumerated 137 features and returned these target states:

| Feature | Current state | Returned parents |
| --- | --- | --- |
| `Microsoft-Hyper-V-All` | Disabled | None |
| `HypervisorPlatform` | Disabled | None |
| `VirtualMachinePlatform` | Disabled | None |
| `Recall` | DisabledWithPayloadRemoved | None |
| `Containers-DisposableClientVM` | Disabled | None |

The Hyper-V family relationships were: `Microsoft-Hyper-V` and `Microsoft-Hyper-V-Tools-All` → `Microsoft-Hyper-V-All`; `Microsoft-Hyper-V-Hypervisor` and `Microsoft-Hyper-V-Services` → `Microsoft-Hyper-V`; management PowerShell and management clients → `Microsoft-Hyper-V-Tools-All`. These are servicing parents, not proof of every runtime dependency or every default child action. Capture the complete feature-state baseline when an umbrella feature can expand changes, and compare the full result with the reviewed affected set. The sources are the actual `DismGetFeatureParent` results in `servicing-readonly-parents.json`.

`DismInitialize`, session open, all queried parents, session close and shutdown returned zero after correcting interop. The shipped Microsoft DISM module declares `DismFeature` with `Pack=1`: its x64 stride is 12 bytes, not 16. Optional pointer arguments must be real null pointers; passing PowerShell `$null` through string parameters produced an invalid-argument initialization in the first probe. The corrected reusable script is `query-feature-parents-readonly.ps1`. All returned arrays are released through `DismDelete`. The probe process exited, with no remaining child DISM host attributed to it.

### State and return-code contract

Do not cast native `DismPackageFeatureState` integers to PowerShell `FeatureState`; they use different numbers. The shipped Microsoft module maps native values as follows:

| Native value | Native name | PowerShell feature state | Journal meaning |
| --- | --- | --- | --- |
| `0` or `2` | NotPresent / Staged | Disabled | Distinguish raw baseline values |
| `1` | UninstallPending | DisablePending | Await restart/reconciliation |
| `3` | Removed / Resolved | DisabledWithPayloadRemoved | Payload recovery is a separate dependency |
| `4` | Installed | Enabled | Configured installed state |
| `5` | InstallPending | EnablePending | Await restart/reconciliation |
| `6` | Superseded | Superseded | Do not treat as a normal toggle baseline |
| `7` | PartiallyInstalled | PartiallyInstalled | Repair/reconcile before a new transaction |

Unknown values remain unknown. Native meanings are documented in the [DISM state enumeration](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/dism/dismpackagefeaturestate-enumeration?view=windows-11); the translation was checked in the target's Microsoft DISM PowerShell module.

`RestartRequired=Possible` in feature information describes whether that feature can require restart; it does not mean this machine currently has a pending operation. Mutation results use `RestartNeeded`, actual pending feature states, or DISM's success-with-reboot code. Native Enable/Disable can return `S_OK`, `ERROR_SUCCESS_REBOOT_REQUIRED` (`3010`), or `DISMAPI_S_RELOAD_IMAGE_SESSION_REQUIRED`; failures are HRESULT errors. Reload the session when required and requery. Cancellation may arrive too late, or leave unknown image state: reconcile instead of claiming rollback from cancellation alone. [Restart metadata](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/dism/dismrestarttype-enumeration?view=windows-11), [Enable contract](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/dism/dismenablefeature-function?view=windows-11), [Disable contract](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/dism/dismdisablefeature-function?view=windows-11).

### Apply and restoration constraints

Enabling with `-All` may enable parents and their default dependencies. Preserve all planned affected baselines and shared ownership; do not disable a parent during restore while another selected feature or external workload still owns it. A prior Removed state is not restored by ordinary Disable, which can leave the payload staged. Payload-removing operations need their own exact scope and source availability; restoring Enabled from Removed can require matching repair media or Windows Update. Older native API documentation contains version restrictions that differ from the current PowerShell interface, so use the supported cmdlet contract for `-Source`, `-LimitAccess` and `-All` and verify the resulting state. [Enable-WindowsOptionalFeature](https://learn.microsoft.com/en-us/powershell/module/dism/enable-windowsoptionalfeature?view=windowsserver2025-ps), [Disable-WindowsOptionalFeature](https://learn.microsoft.com/en-us/powershell/module/dism/disable-windowsoptionalfeature?view=windowsserver2025-ps).

Recall component state is separate from snapshot opt-in and policy state. Microsoft documents that disabling AllowRecallEnablement removes Recall and deletes saved snapshots, and enabling availability cannot consent to snapshot collection for the user. Therefore a component-state journal does not cover Recall data restoration. [Manage Recall](https://learn.microsoft.com/windows/client-management/manage-recall).

Windows Sandbox remained Disabled and `WindowsSandbox.exe` remained absent throughout this research. Nothing was enabled, disabled, removed, restarted or rebooted. Remaining mutation/restore assertions require isolated execution evidence; neither this dependency enumeration nor an API signature establishes that an exact feature or hibernation round trip has passed.

For the proposed journaled feature adapter, retain both desired state and actual state: `desired=Enabled, actual=EnablePending` means accepted with restart required, not verified Enabled. Keep the original baseline and ownership. As an engineering guard, block another servicing mutation—including inverse restore—until pending/partial state is reconciled. After restart, open a new session and verify the entire declared feature/dependency/group set before closing the journal or restoring it. Windows documentation establishes the pending state; this conservative transaction guard is a design recommendation, not a claim that every additional Windows servicing operation is categorically prohibited.

### Exact dispatch of Remove and All

Static inspection of the target's `Microsoft.Dism.PowerShell.dll` resolves the invocation path, but not the inconsistent documentation's per-feature behavior. Its SHA-256 is `7965876a59411a72c0ae0e2408da7d1b05a489327472919430dc510f60b0fabc`.

| PowerShell parameter | Shipped implementation path |
| --- | --- |
| `Disable-WindowsOptionalFeature -Remove` | `Remove` assigns `_removePayload`; `ProcessRecord` passes that Boolean directly to exported `DismDisableFeature`. |
| `Enable-WindowsOptionalFeature -All` | `All` assigns `_enableAll`; `ProcessRecord` passes that Boolean directly to exported `DismEnableFeature`. |
| `-Source` / `-LimitAccess` | Passed directly to the same `DismEnableFeature` call as source array/count and Boolean. |

There is no alternate `Ex` removal endpoint, managed feature-specific fallback, or managed Windows-version branch in either cmdlet's execution path. The private static evidence is in `native-sources/dism-inspection/Microsoft.Dism.Commands/DisableWindowsOptionalFeatureCommand.cs`, `EnableWindowsOptionalFeatureCommand.cs` and `DismInterop.cs`. This corrects any inference that choosing the cmdlet bypasses the native API's documented restrictions.

The native Disable page says `RemovePayload` is unsupported after Windows 8/Server 2012, while current cmdlet documentation continues to offer `-Remove` and current Recall documentation explicitly prescribes it. The native Enable page similarly has restrictive version notes while current cmdlet documentation describes `-All` and parent dependencies. The shipped wrapper passes those switches unchanged. These facts establish a documentation conflict; they do not prove that a provider honors every flag for every component/build. [Native Disable](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/dism/dismdisablefeature-function?view=windows-11), [Disable cmdlet](https://learn.microsoft.com/en-us/powershell/module/dism/disable-windowsoptionalfeature?view=windowsserver2025-ps), [Recall's component-specific contract](https://learn.microsoft.com/windows/client-management/manage-recall), [Enable cmdlet](https://learn.microsoft.com/en-us/powershell/module/dism/enable-windowsoptionalfeature?view=windowsserver2025-ps).

For an original `DisabledWithPayloadRemoved` state, the candidate restoration is `Disable-WindowsOptionalFeature -Online -FeatureName <exact feature> -Remove -NoRestart`, followed by any required restart and a new stable DISM read. It is exact **only if** that read returns Removed/native `3` for the same feature/package/image and the declared dependency set also matches its captured baseline. Ordinary Disabled/native `2` is a different result. An already Removed baseline proves its present state, not that enabling and removing it again will return there. No such round trip was executed here.

Automatic exact restore from a Removed baseline therefore needs component/build-specific removal capability evidence and a matching payload/source plan. Recall has a documented removal request path; its lifecycle still needs a disposable round-trip test. If native readback stays Staged, is pending, or fails, keep the journal unresolved instead of reporting restoration or attempting package/file deletion as a substitute. Payload restoration also does not recreate user data deleted by a component's lifecycle. For `-All`, use the enumerated/declared expansion in preview and verify the full affected set afterward; forwarding the switch does not validate the graph or permit undeclared extra changes.
