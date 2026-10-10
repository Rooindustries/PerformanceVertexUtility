# FSOS-X Dash settings and overlap audit

Date: 2026-09-19. Scope: factual inventory for independent Roo Industries implementations. No FSOS-X application, script or Windows operation was executed during this audit.

## Result

The published release is still R11H2. Static inspection of its Dash 2.4.9 assembly identifies **80 toggle classes and 79 registered controls**. The earlier 79-symbol catalog is not the same set: it includes the unregistered `TcpAutoTuningToggleService` and misses the registered `MitigationsToggleService`. Registration in `FSOSXDash.App` and the toggle-page view models now establish the offered control set, subject to each control's OS gate. [Official release and changelog](https://fsosx.com/#download), [release archive](https://fsosx.com/FSOS-XR11H2.apbx).

The previous claim that only printable symbols could be inspected is superseded. ILSpy can unpack this .NET bundle and inspect the application assembly without running the application. Its private inspection output remains outside the repository; the exported inventories contain functional facts rather than copied method bodies. [ILSpy](https://github.com/icsharpcode/ILSpy), [Microsoft bundle manifest format](https://github.com/dotnet/runtime/blob/main/src/installer/managed/Microsoft.NET.HostModel/Bundle/Manifest.cs).

All **79 registered toggle controls now have a static factual effect model**, including the remaining 36 compound controls. There are no missing extracted control resources. The timer control has one explicitly identified vendor executable boundary: `SetTimerResolution.exe`, present in the archive and extracted without execution.

This is an inventory, not proof that Roo Industries implements all 79 controls. Source inspection establishes declared behavior; it does not establish Windows support, successful application, exact recovery or measured performance.

## Sources and artifacts

The [official archive](https://fsosx.com/FSOS-XR11H2.apbx) is 436,280,934 bytes with SHA-256 `75d0e6a716f722d452d7ed9b9d403c9b9ef20207f35a84ada4213e043fc62741`. Its Dash executable is 137,034,281 bytes with SHA-256 `dd50c1d39bd4c75f44076e49320206759004b2e498f64657681796648c81b8db`. The archive declares PolyForm Noncommercial 1.0.0. No upstream executable or implementation body was added to product code. The official website still advertised the same archive digest when checked on this date.

Private evidence is under `<private work folder>/four-tool-tweaks-20260919/fsos/`:

| Artifact | Meaning |
| --- | --- |
| `dash-complete-model.json` | Authoritative model for all 79 registered controls: enabled/disabled effects, branches, dynamic selectors, helper effects, undo limits and atomic target groups. |
| `dash-static-facts.json` | Actual control IDs, titles, categories, OS/restart metadata, registration, literal registry effects by method, external command facts and unresolved dynamic calls. |
| `dash-reviewed-contracts.json` | Reviewed factual setting bundles, with separate enabled/disabled operations and additional live effects. This is not an executable product catalog. |
| `coverage.json` | Earlier playbook comparison and complete declarative playbook operation grouping. Its `exactDashContracts: 0` describes that comparison phase only; consult the later static Dash files for direct evidence. |
| `summary.json` | Playbook comparison counts. |
| `complete-validation.json` | Registration equality, preserved literal effects, service tuples, feature/property sets, resource identity and a deliberately wrong service-state rejection. |
| `timer-task-definition-facts.json` | Complete task settings and command metadata from the conditional timer task definition. |
| `inspection/` | Private static inspection output; never copy this implementation into the product. |
| `bundle/` | Private extracted upstream assemblies; not launched or distributed. |

The direct Dash evidence follows `FSOSXDash.Services.Toggles.<Type>`, its `EnableAsync` and `DisableAsync` methods, and referenced helpers in the pinned binary. Original symbol-only inventory remains in `backend/catalogs/upstream-settings-inventory.json`; it is historical input, not the current completeness measure.

## Deduplication requirements found in the actual controls

**Shared values with separate fields need composition.** Variable Refresh Rate and Windowed Optimizations both edit the same `HKCU\Software\Microsoft\DirectX\UserGpuPreferences\DirectXUserGlobalSettings` string. Their fields are `VRROptimizeEnable` and `SwapEffectUpgradeEnable`. Their operations preserve unrelated fields. Treating each as a complete string replacement would lose settings; treating them as conflicting complete values would reject a valid combination. Plan the combined field edits against one snapshot. [Pinned Dash assembly: `VariableRefreshRateToggleService`, `WindowedOptimizationsToggleService`](https://fsosx.com/FSOS-XR11H2.apbx).

**A toggle can cover several independently offered settings.** Dash Activity History changes Explorer's recent-program and recent-document flags as well as activity policy; its enabled direction deletes three policy values. Consumer Features spans Content Delivery Manager flags and CloudContent policies. Each underlying target must have one owner-aware implementation, and presets must refer to those shared operations. A label match against WinUtil, WPD or O&O cannot establish full equivalence. [Pinned Dash assembly: `ActivityHistoryToggleService`, `ConsumerFeaturesToggleService`](https://fsosx.com/FSOS-XR11H2.apbx).

**Enabled is not necessarily restore.** Dash often writes an assumed Windows default or deletes a policy. Roo Industries restoration must return the captured original type/value/absence, including values that were already custom before application. Modern Standby Fix also illustrates a naming trap: its enabled method removes `PlatformAoAcOverride`, whereas its disabled method writes DWORD zero. Map actions from verified operations, not the title. [Pinned Dash assembly: `ModernStandbyFixToggleService`, `AutomaticMaintenanceToggleService`, `TdrDelayToggleService`](https://fsosx.com/FSOS-XR11H2.apbx).

**Registry writes may be only part of the control.** Taskbar grouping restarts Explorer. File visibility sends a shell refresh. Mouse acceleration also updates live system parameters. Animation changes include live parameters and machine-level visual-effect defaults. Treat those effects explicitly in the plan and recovery contract. [Pinned Dash assembly: `CombineTaskbarButtonsToggleService`, `FileExtensionsToggleService`, `MouseAccelerationToggleService`, `AnimationsToggleService`](https://fsosx.com/FSOS-XR11H2.apbx).

**Dynamic targets need binding.** NIC controls select adapters through `NetworkAdapterResolver`; audio controls enumerate endpoint keys. Wi-Fi, Bluetooth, printing, Hyper-V and power-saving controls affect groups of services, drivers, power settings or optional features. Bind a review to resolved targets and preserved pre-change state; a static registry name is insufficient. [Pinned Dash assembly: `NetworkAdapterResolver`, `AudioEnhancementsToggleService`, `WifiToggleService`, `BluetoothToggleService`, `PrintingToggleService`, `HyperVToggleService`, `PowerSavingToggleService`](https://fsosx.com/FSOS-XR11H2.apbx).

## Playbook comparison

Every declarative action in the pinned playbook was accounted for independently of Dash: 1,024 occurrences reduce to 1,008 unique declared operations, including 650 registry-value operations, 105 service operations, 150 AppX operations, 76 registry-key operations, seven scheduled-task operations, 12 process-termination operations and eight file operations. Sixteen repeated declarations collapse to existing operation IDs. Conditions remain attached to each occurrence. Another 215 script or executable actions remain separate because flattening an embedded program into one registry action would discard conditional behavior. [Pinned playbook YAML](https://fsosx.com/FSOS-XR11H2.apbx).

Registry identity normalizes hive, path and value-name casing only. `HKCU`, `HKU\.DEFAULT`, `CurrentControlSet` and `ControlSet001` remain distinct. Different data, value kinds or operations remain distinct variants of the same target. Playbook source facts are not automatically Dash behavior, and neither source proves an OS setting is effective on every supported build.

## Coverage limit and next implementation work

All registered toggle identities and their direct/transitive control effects are modeled. The model includes registry values and trees, ACL/owner fallback, service startup and runtime state, scheduled tasks, process termination/restart, boot configuration, optional features, adapter settings, CIM device power state, system parameters, filesystem behavior, hibernation, system restore, and the conditional timer executable. The next step is independent product implementation and Windows verification; static completeness does not establish executor readiness. Game-session commands, cleanup, app installation/removal, power-plan management and application preferences are separate action families; the old 181-symbol count mixes these with actual tweaks.

The required completion evidence for each offered control is: complete effect inventory; shared-target mapping across the four tools; an independently implemented detector; explicit apply choices; one original-state snapshot per shared target; verified readback; exact restore; and a meaningful disposable Windows test where the action can be isolated. None of the static research counts should be presented as a passing execution count.

## Registered control inventory

The table below is generated from registration plus actual control metadata. The machine-readable inventory retains exact IDs and effect references.

Direct static facts cover **291 distinct literal registry operations**, with **301 call occurrences across 54 controls**. The reviewed bundle artifact covers **43 registered controls**, **257 distinct operations** and **137 registry targets**, including token edits. These counts cover different scopes and must not be added together. The subsequent complete model covers all 79 controls with 748 distinct atomic effect facts across 439 target groups. Conditional helper side effects remain explicitly referenced in common contracts rather than being counted as separate unconditional operations.

| Control | Exact ID | Category | Mapping status |
| --- | --- | --- | --- |
| Animations | `animations` | Appearance | Modeled registry bundle |
| Center Taskbar Icons | `center-taskbar` | Appearance | Modeled registry bundle |
| Combine Taskbar Buttons | `combine-taskbar-buttons` | Appearance | Modeled registry bundle |
| Dark Theme | `dark-theme` | Appearance | Modeled registry bundle |
| End Task on Taskbar Right-Click | `end-task-right-click` | Appearance | Modeled registry bundle |
| Show File Extensions | `show-file-extensions` | Appearance | Modeled registry bundle |
| Show Hidden Files | `show-hidden-files` | Appearance | Modeled registry bundle |
| Small Desktop Icons | `small-desktop-icons` | Appearance | Modeled registry bundle |
| Transparency Effects | `transparency` | Appearance | Modeled registry bundle |
| Automatic Driver Updates | `auto-driver-updates` | Devices | Modeled compound effects |
| Bluetooth | `bluetooth` | Devices | Modeled compound effects |
| Dynamic Lighting | `dynamic-lighting` | Devices | Modeled registry bundle |
| Location | `location` | Devices | Modeled compound effects |
| Mobile Hotspot | `hotspot` | Devices | Modeled compound effects |
| Power Saving | `power-saving` | Devices | Modeled compound effects |
| Printing | `printing` | Devices | Modeled compound effects |
| Wi-Fi | `wifi` | Devices | Modeled compound effects |
| Energy Efficient Ethernet | `nic-eee` | Network | Modeled compound effects |
| Fast UDP Datagram Send | `fast-send-datagram-threshold` | Network | Modeled registry bundle |
| Interrupt Moderation | `nic-interrupt-moderation` | Network | Modeled compound effects |
| LLMNR | `llmnr` | Network | Modeled compound effects |
| Large Send Offload | `nic-lso` | Network | Modeled compound effects |
| Nagle Algorithm | `nagle-algorithm` | Network | Modeled compound effects |
| NetBIOS over TCP/IP | `netbios` | Network | Modeled compound effects |
| Network Data Usage | `ndu-service` | Network | Modeled registry bundle |
| Network Throttling Index | `network-throttling` | Network | Modeled registry bundle |
| QoS Reserved Bandwidth | `qos-reserved-bandwidth` | Network | Modeled registry bundle |
| TCP ACK Frequency | `tcp-ack-frequency` | Network | Modeled compound effects |
| TCP Receive Segment Coalescing | `tcp-rsc` | Network | Modeled compound effects |
| TCP/IP Task Offload | `tcpip-task-offload` | Network | Modeled registry bundle |
| Update Delivery Optimization (P2P) | `delivery-optimization-p2p` | Network | Modeled registry bundle |
| CPU Mitigations | `cpu-mitigations` | Security | Modeled compound effects |
| Control Flow Guard | `control-flow-guard` | Security | Modeled compound effects |
| Core Isolation / Memory Integrity | `core-isolation` | Security | Modeled registry bundle |
| Other Security Mitigations | `other-security-mitigations` | Security | Modeled compound effects |
| SmartScreen | `smart-screen` | Security | Modeled compound effects |
| User Account Control | `user-account-control` | Security | Modeled compound effects |
| Virtualization-Based Security (VBS) | `vbs` | Security | Modeled compound effects |
| Vulnerable Driver Blocklist | `vulnerable-driver-blocklist` | Security | Modeled registry bundle |
| Activity History | `activity-history` | System | Modeled registry bundle |
| Background Apps | `bgapps` | System | Modeled registry bundle |
| Consumer Features | `consumer-features` | System | Modeled registry bundle |
| Energy Recommendations | `energyrecs` | System | Modeled registry bundle |
| Hyper-V | `hyper-v` | System | Modeled compound effects |
| Scheduled Defrag / TRIM | `auto-defrag` | System | Modeled compound effects |
| Storage Sense | `storagesense` | System | Modeled registry bundle |
| System Restore | `system-restore` | System | Modeled compound effects |
| Windows Telemetry | `telemetry` | System | Modeled compound effects |
| Windows Update | `windows-update` | System | Modeled compound effects |
| Audio Enhancements | `audio-enhancements` | Tweaks | Modeled compound effects |
| Auto-reboot After BSOD | `auto-reboot-crash` | Tweaks | Modeled registry bundle |
| Automatic Maintenance | `auto-maintenance` | Tweaks | Modeled registry bundle |
| Configure Timer Resolution | `global-timer-resolution` | Tweaks | Modeled compound effects |
| Extended GPU Timeout | `tdr-delay` | Tweaks | Modeled registry bundle |
| Fault Tolerant Heap | `fault-tolerant-heap` | Tweaks | Modeled compound effects |
| Foreground App Boost | `foreground-boost` | Tweaks | Modeled registry bundle |
| Fullscreen Optimizations | `fullscreen-optimizations` | Tweaks | Modeled registry bundle |
| HAGS | `hags` | Tweaks | Modeled registry bundle |
| Hibernation & Sleep | `hibernation` | Tweaks | Modeled compound effects |
| Kernel Paging Executive | `kernel-paging-executive` | Tweaks | Modeled registry bundle |
| Legacy Context Menu | `legacy-context-menu` | Tweaks | Modeled compound effects |
| Long File Paths | `long-paths` | Tweaks | Modeled registry bundle |
| Memory Compression | `memory-compression` | Tweaks | Modeled compound effects |
| Modern Standby Fix | `modern-standby-fix` | Tweaks | Modeled registry bundle |
| Mouse Acceleration | `mouse-acceleration` | Tweaks | Modeled registry bundle |
| Mouse Throttling | `mouse-throttling` | Tweaks | Modeled registry bundle |
| Multi-Plane Overlay (MPO) | `mpo` | Tweaks | Modeled registry bundle |
| NTFS Last-Access Updates | `ntfs-last-access` | Tweaks | Modeled compound effects |
| Open Explorer to This PC | `explorer-launch-target` | Tweaks | Modeled registry bundle |
| Optimizations for Windowed Games | `windowed-optimizations` | Tweaks | Modeled registry bundle |
| Safe Mode and Power Plans in the Desktop Menu | `desktop-context-menu` | Tweaks | Modeled compound effects |
| Search Indexing | `search-indexing` | Tweaks | Modeled compound effects |
| Snappy Menus | `menu-delay` | Tweaks | Modeled registry bundle |
| Sticky Keys Shortcut | `sticky-keys` | Tweaks | Modeled registry bundle |
| SysMain | `sysmain` | Tweaks | Modeled compound effects |
| Text Input Service (ctfmon) | `text-input-service` | Tweaks | Modeled registry bundle |
| Variable Refresh Rate | `variable-refresh-rate` | Tweaks | Modeled registry bundle |
| Windows Game Mode | `windows-game-mode` | Tweaks | Modeled registry bundle |
| Xbox Game Bar | `game-bar` | Tweaks | Modeled registry bundle |

`tcp-autotuning` exists as a class but is not registered in this version. It is excluded from the 79 offered controls.

The category/ID/title inventory above is supported by the pinned assembly registration and each control type. [R11H2 archive](https://fsosx.com/FSOS-XR11H2.apbx).

## Compound-control completion

The remaining 36 controls were traced through their helper methods and are recorded in `dash-complete-model.json`. Enabling/disabling paths, conditional target selection, native invocations, failure handling, default values and restoration asymmetries are explicit. Timer task definition fields were extracted separately into `timer-task-definition-facts.json`; the bundled tool is identified by byte count and hash in the complete model. No application or Windows mutation was executed. [Pinned Dash implementation](https://fsosx.com/FSOS-XR11H2.apbx).

Additional findings that affect a faithful, non-overlapping implementation:

- The network resolver chooses active physical gateway adapters first, then other gateway adapters, then other active adapters. If resolution is empty, the original falls back to every interface or a wildcard adapter name. Roo Industries must bind explicit targets in the reviewed plan.
- Power Saving is a device-wide NIC/USB/HID registry and CIM bundle. It does not switch a power plan. Its opposite direction forces assumed defaults and does not recover custom per-device values.
- Wi-Fi, Mobile Hotspot, Bluetooth, printing and telemetry overlap service startup/runtime targets. Hyper-V and VBS share boot configuration and optional features. CPU Mitigations, Control Flow Guard and Other Security Mitigations overlap individual system mitigation flags.
- Seven controls use an ACL helper that, following access denial, changes registry ownership and grants inherited FullControl to Administrators and SYSTEM. That side effect is now explicit; an independent executor must not silently inherit it or claim restoration while leaving modified permissions.
- The helper named RestartExplorer kills matching Explorer processes and relies on Windows to relaunch the shell. Other controls explicitly start Explorer after termination. These are different execution paths.
- Several upstream controls report success after ignored helper errors or read only a subset of what they changed. The modeled detector branches document those limits. Roo Industries verification must read every affected target independently.
- UAC has a vendor-specific backup path, but substitutes defaults for absent/wrong-type data and forces UAC enabled if the saved value was disabled. Most other opposite-direction actions are default writes or deletions, not original-state restoration.

These findings come from the named controls and `RegistryAclHelper`, `ServiceControlHelper`, `NetworkAdapterResolver`, `CoreIsolationRegistry`, `WinApi` and `UacHelper` in the pinned assembly. [R11H2 archive](https://fsosx.com/FSOS-XR11H2.apbx).

The registered tweak set contains no app-package installation/removal operations and no `netsh` invocation. TCP Auto-Tuning's `netsh` operations belong to its unregistered class. App installation/removal, game sessions, power-plan selection, downloads and cleanup are separate Dash action families outside this 79-toggle inventory; they must remain separate from tweak-completeness claims.

## Verification

The final data was checked against the pinned registration list, the independently extracted literal registry calls, service startup tuples, NIC property names and optional-feature names. All 79 registered IDs are present with both directions and helper references. A deliberately changed Wi-Fi service startup value was rejected by the same validator. The bundled timer resource was extracted and hash-identified without execution. `complete-validation.json` records these results. No runtime behavior, Windows write or recovery outcome was validated by this research.
