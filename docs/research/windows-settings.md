# Windows settings inventory for Roo Industries

Captured 2026-09-14. Roo source coverage is pinned to local commit `33bbd55f1196657a5935c783db65a8a0c59448bb`; implementation added after that commit must supply its own verification evidence.

The accompanying [normalized inventory](../../backend/catalogs/upstream-settings-inventory.json) contains **376 setting/action/control records**, **267 application package records**, and **1,319 FSOS-X YAML action records**. These are source records, not a claim of 1,962 distinct optimizations: presets, buttons, package operations, progress messages, aliases, and inferred binary symbols are identified by their record kinds. The inventory is complete for the pinned WinUtil configuration keys and FSOS-X YAML action nodes. Dash implementation internals remain only partially observable.

| Source | Pinned identity | Primary evidence |
| --- | --- | --- |
| WinUtil current main | `fc60cbde09d669178bda1665be9cb1a703516fca`; commit 2026-09-14 02:59:32 UTC | [Repository commit](https://github.com/ChrisTitusTech/winutil/commit/fc60cbde09d669178bda1665be9cb1a703516fca); [configuration directory](https://github.com/ChrisTitusTech/winutil/tree/fc60cbde09d669178bda1665be9cb1a703516fca/config) |
| WinUtil stable release observed | 26.08.19, published 2026-08-19 | [Stable release](https://github.com/ChrisTitusTech/winutil/releases/tag/26.08.19). Inventory counts use the newer pinned main commit. |
| FSOS-X playbook | R11H2; playbook.conf version 11.2; release dated 2026-09-04 | [Official release site](https://fsosx.com/); [downloaded archive](https://fsosx.com/FSOS-XR11H2.apbx) |
| FSOS-X archive verification | 436,280,934 bytes; SHA-256 `75d0e6a716f722d452d7ed9b9d403c9b9ef20207f35a84ada4213e043fc62741` | Downloaded bytes matched the digest published on the official site. |
| FSOS-X Dash bundled with R11H2 | PE FileVersion 2.4.9.0; ProductVersion 2.4.9; 137,034,281 bytes | `Executables/FSOSXDash.exe` inside the [verified archive](https://fsosx.com/FSOS-XR11H2.apbx); SHA-256 `dd50c1d39bd4c75f44076e49320206759004b2e498f64657681796648c81b8db` |
| Earlier local FSOS-X evidence | R7 / playbook 7.0; Dash strings indicated 1.2.0.0 | [Earlier playbook catalog](../../backend/catalogs/fsosx-playbook-capabilities.json) and [earlier Dash catalog](../../backend/catalogs/fsosx-dash-capabilities.json) were used only as historical pointers. |

WinUtil’s pinned [LICENSE](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/LICENSE) declares MIT. The FSOS-X archive’s `LICENSE.txt` declares [PolyForm Noncommercial 1.0.0](https://polyformproject.org/licenses/noncommercial/1.0.0/) and directs commercial-licensing inquiries to FrameSync Labs. The new inventory contains factual names, identifiers, targets, evidence pointers, and original summaries. It contains no upstream implementation bodies, executable commands, binaries, or copied application assets. Package entries and bundled third-party programs retain their own license/provenance questions; a library’s MIT notice does not establish an MIT license for Dash.

The source-defined counts below can be reproduced from the eight pinned WinUtil configuration files. The earlier June repository note is a historical snapshot with different counts.

| WinUtil source section | Entries | Meaning |
| --- | --- | --- |
| [tweaks.json](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/config/tweaks.json) | 67 | Checkbox tweaks, preference toggles, choice controls, and power/cleanup/external-tool actions |
| [feature.json](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/config/feature.json) | 33 | Windows features, fixes, panel launchers, and supporting actions |
| [dns.json](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/config/dns.json) | 14 | Resolver presets, including IPv4/IPv6 and DoH metadata when declared |
| [preset.json](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/config/preset.json) | 4 | Standard 12 members; Minimal 4; Advanced 17; AppxDefault 18 |
| [applications.json](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/config/applications.json) | 233 | Installable application catalog entries; counted separately from optimizer settings |
| [appx.json](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/config/appx.json) | 34 | Windows app identities for explicit removal/restoration; counted separately |
| [appnavigation.json](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/config/appnavigation.json) | 11 | Package-manager selection, install/upgrade/uninstall actions, selection helpers and one information note |
| [themes.json](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/config/themes.json) | 3 | Light and Dark themes plus shared styling; shared styling is not an independent setting |
| [inputXML.xaml](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/xaml/inputXML.xaml) | 69 | Every named interactive control accounted for: 29 additional controls and 40 UI-only/navigation/template/alias records |
| [start.ps1](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/scripts/start.ps1#L9) | 3 | Config, Preset and Offline command-line parameters |
| [autounattend.xml](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/tools/autounattend.xml) | 1 | Bundled setup template tracked as a composite media action, with handler evidence |

The application catalog spans the following categories. These are selectable package entries, not proof that Roo can install every package or that any given upstream installer remains available.

| Application category | Entries |
| --- | --- |
| Browsers | 15 |
| Communications | 18 |
| Development | 41 |
| Document | 17 |
| Games | 17 |
| Microsoft Tools | 18 |
| Multimedia Tools | 22 |
| Pro Tools | 19 |
| Selfhosted Tools | 10 |
| Utilities | 56 |

The three update buttons are defined outside `tweaks.json`. At this pin, the recommended policy restores update services/tasks, excludes driver offerings, defers feature updates 365 days and quality updates 4 days, and configures restart behavior while users are signed in. Defaults removes WinUtil policy values and re-enables services/tasks. Disable stops update services, disables related tasks, and removes downloaded update files. These are separate stateful workflows, with security-servicing consequences. [Recommended handler](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/functions/public/Invoke-WPFUpdatessecurity.ps1), [defaults handler](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/functions/public/Invoke-WPFUpdatesdefault.ps1), [disable handler](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/functions/public/Invoke-WPFUpdatesdisable.ps1).

Windows 11 Creator includes source ISO selection, edition selection, optional host-driver injection, source verification, media modification, ISO output, direct USB output, USB target refresh, erasure/write, and cleanup. Its bundled setup template also contains fixed account/OOBE, package, hardware-check and security-relevant defaults. Those fixed changes are part of the composite media workflow; they are not independent user-visible toggles. Roo should expose an inspectable media plan and explicit choices before any later image-writing executor. [Creator handler](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/functions/private/Invoke-WinUtilISO.ps1), [setup customization source](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/functions/private/Invoke-WinUtilISOScript.ps1), [upstream creator guide](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/docs/src/content/docs/guides/win11creator.mdx).

One specific recovery difference matters: WinUtil’s Ultimate Performance enable action duplicates and activates a plan, while disable uses the full default-scheme reset. That can remove preexisting custom plans. Roo’s independent implementation should preserve its original active GUID, export the required state, and delete only an owned temporary plan. [Power-plan handler](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/functions/public/Invoke-WPFUltimatePerformance.ps1).

The current FSOS-X playbook contains **31 selectable options**, including three named browser choices and an explicit no-browser choice. The archive contains **199 files and 5 directories**. All eight configuration YAML files, `playbook.conf`, `LICENSE.txt`, 16 PowerShell scripts, one batch script, and one VBScript wrapper were inspected as source text; Dash was inspected through PE metadata and printable strings. Other bundled binaries, the Notepad settings data file, images, and power-plan payloads are represented by archive-member metadata. Source-file hashes and exact YAML line numbers are recorded in the inventory. [Current archive](https://fsosx.com/FSOS-XR11H2.apbx).

| FSOS-X source phase | YAML actions |
| --- | --- |
| phase1-prepare | 58 |
| phase2-strip | 502 |
| phase3-harden | 135 |
| phase4-gaming | 119 |
| phase5-apply | 124 |
| phase6-extended | 318 |
| phase7-privacy | 55 |
| main | 8 |

The 1,319 YAML nodes include 663 registry-value actions, 76 registry-key actions, 105 service actions, 151 AppX actions, 7 scheduled-task actions, 14 process-termination actions, 8 file actions, 160 embedded PowerShell actions, 43 command actions, 12 external-program invocations, 73 status messages, and 7 phase dispatches. An embedded script is retained as an action-level record with detected operation/tool names; its nested branches are not falsely counted as fully understood independent settings. Explicit option conditions are preserved, including negation. The option-to-action links do not attempt to evaluate AME’s condition language or conditional checks inside scripts. [Current archive, Configuration/main.yml and Configuration/Tasks](https://fsosx.com/FSOS-XR11H2.apbx).

The playbook can request privileged, destructive, and security-sensitive changes; it is an installation/overhaul source, not a drop-in safe preset. Its source requirement and supported-build declarations are recorded without claiming compatibility testing. Every inventory item has `automaticApply: false`; the inventory carries no executable payload. The useful transferable design is individually identified settings, explicit dependency checks, observed state, and recovery records.

Dash’s current binary exposes **79 exact toggle-service names**, **70 named command symbols**, **31 selected session/application option properties**, and **15 page symbols**, plus a CPU-mitigations label/state-query pair. All 292 exact backing-property symbols are also listed as supplemental metadata; many describe internal state rather than editable preferences. The current site independently describes recent changes such as change history, additional security/audio/mouse controls, per-game options, and power-plan state fixes. The source-controlled parts of the playbook do not reveal all Dash internals. Generic symbols such as Apply, Start, Stop, Delete and Restore have ambiguous ownership and remain explicitly marked `binary-symbol-ambiguous`. Class names can also outlive UI controls or omit dynamically created ones; none establishes a default, exact Windows value, or a measured performance result. [Official Dash/release information](https://fsosx.com/#dash), [binary provenance](https://fsosx.com/FSOS-XR11H2.apbx).

The following Roo coverage is **source inspection at the pinned baseline**, not a new execution result. A related capability family does not prove equivalence to each upstream toggle; the inventory records those distinctions on each row.

| Area | Existing Roo source | Concrete next implementation/verification step |
| --- | --- | --- |
| Ordinary Windows preferences | [Existing module definitions](../../modules/tweak_manifest.json); [system capability catalog](../../backend/capabilities/system-optimizations.json) | Add per-setting typed detectors and exact existence/type/value backups for extensions, hidden files, taskbar controls, themes, and other individually reviewed preferences. Restore the actual prior value rather than an upstream default constant. |
| Operation history and recovery | [Capability router](../../backend/scripts/Invoke-RooCapability.ps1); [executor helpers](../../backend/scripts/BackendExecutor.Common.ps1) | Bind a plan to its target and observed prior state; detect drift before apply/restore, record completed steps, support retry/partial-failure recovery, and expose the actual result. |
| Per-game scheduling | [Process capability catalog](../../backend/capabilities/process-controls.json) | Reuse owned CPU/I/O/GPU/affinity session paths with process identity, topology and protected-process checks. Validate restore when the game exits or launch fails; avoid unmeasured CPU-core exclusion presets. |
| Timer requests | [Timer session](../../backend/scripts/Invoke-TimerResolutionSession.ps1) | Keep begin/end pairing and bounded session ownership. This is not proven equivalent to Dash’s global-timer toggle; verify the requesting process and actual timer behavior. |
| Power plans | [Real executor](../../backend/scripts/Invoke-StutterOptimizationRealExecutor.ps1) | Preserve source-reviewed temporary-plan export/import/select/restore/delete behavior; validate cleanup on every failure path and avoid resetting unrelated plans. |
| Memory pressure | [Standby helper build path](../../backend/scripts/Build-StandbyMemoryHelper.ps1) | Ship/read out the precise helper/toolchain requirement and collect memory-pressure facts first. An irreversible transient purge needs before/after evidence and exact approval. |
| DNS and adapter controls | [System facts](../../backend/scripts/Get-SystemOptimizationFacts.ps1) | Implement per-adapter current DNS, DHCP/static mode, encrypted DNS, adapter properties and route facts. Preserve Tailscale/LAN resolution and provide an exact snapshot/recovery plan before any approved network write. |
| Service controls | [Stutter optimization contracts](../../backend/scripts/StutterOptimization.Common.ps1) | Start with running/startup state and dependency detection, then prove a disposable or narrowly reversible service lifecycle. Restore only services actually changed by the session. |
| Cleanup and uninstall | [Cleanup/uninstall catalog](../../backend/capabilities/cleanup-uninstall.json) | Reuse installed-app identity, protected-app rules, selected targets and disposable backup/delete/restore validation. Package reinstall alone does not restore lost user data. |
| Features and repair | [Windows feature capability declarations](../../backend/capabilities/system-optimizations.json) | Provide read-only feature-state and toolchain detection, then separately implement exact DISM/SFC contracts including exit status, pending reboot, source requirements and recovery limits. |
| Security and platform toggles | [Existing protected module declarations](../../modules/tweak_manifest.json) | Keep Defender, firewall, UAC, SmartScreen, memory integrity, VBS, mitigations, driver blocklist, BitLocker, updates, Store, WebView2 and required device features preserved by default; expose accurate detected state and an explicit explanation. |

A lower process count, an “Essential” upstream category, or a security-off switch is insufficient evidence for a performance recommendation. Microsoft documents that timer requests have been process-specific since Windows 10 version 2004; Windows 11 also limits guarantees for occluded window-owning processes, and high timer resolution can increase scheduling overhead and power use. A successful helper call alone therefore does not prove improved game timing. [timeBeginPeriod contract](https://learn.microsoft.com/en-us/windows/win32/api/timeapi/nf-timeapi-timebeginperiod).

Long-path support requires both the Windows setting and an opted-in application manifest, with per-process caching that can require restart. Memory integrity is a security feature with driver-compatibility requirements. Network offload, receive scaling and moderation choices depend on adapter capabilities and workload; the Microsoft network guidance is Windows Server guidance, so it cannot establish a gaming latency gain on an untested client. These contracts support per-setting detection and measurement rather than universal optimization claims. [Long-path contract](https://learn.microsoft.com/en-us/windows/win32/fileio/maximum-file-path-limitation), [memory-integrity guidance](https://learn.microsoft.com/en-us/windows/security/hardware-security/enable-virtualization-based-protection-of-code-integrity), [adapter tuning guidance](https://learn.microsoft.com/en-us/windows-server/networking/technologies/network-subsystem/net-sub-performance-tuning-nics).

Every entry below is separately addressable by `sourceSettingId` in the JSON. Risk labels are independent implementation-review judgments; they do not certify that low-risk rows are executable or compatible on a particular Windows build.

All **67 WinUtil tweak/configuration entries** follow. Each source identifier links to its exact pinned definition in [tweaks.json](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/config/tweaks.json).

| Source identifier | Upstream name | Risk |
| --- | --- | --- |
| [`WPFTweaksActivity`](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/config/tweaks.json#L2) | Activity History - Disable | medium |
| [`WPFTweaksHiber`](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/config/tweaks.json#L32) | Hibernation - Disable | medium |
| [`WPFTweaksWidget`](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/config/tweaks.json#L61) | Widgets - Remove | high |
| [`WPFTweaksRevertStartMenu`](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/config/tweaks.json#L80) | Start Menu Previous Layout - Enable | medium |
| [`WPFTweaksDisableStoreSearch`](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/config/tweaks.json#L96) | Microsoft Store Recommended Search Results - Disable | medium |
| [`WPFTweaksLocation`](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/config/tweaks.json#L109) | Location Tracking - Disable | medium |
| [`WPFTweaksServices`](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/config/tweaks.json#L146) | Services - Set to Manual | high |
| [`WPFTweaksBraveDebloat`](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/config/tweaks.json#L186) | Brave Browser - Debloat | high |
| [`WPFTweaksDisableWarningForUnsignedRdp`](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/config/tweaks.json#L279) | RDP Unsigned File Warnings - Disable | critical |
| [`WPFTweaksEdgeDebloat`](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/config/tweaks.json#L302) | Microsoft Edge - Debloat | high |
| [`WPFTweaksConsumerFeatures`](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/config/tweaks.json#L430) | ConsumerFeatures - Disable | medium |
| [`WPFTweaksTelemetry`](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/config/tweaks.json#L446) | Telemetry - Disable | medium |
| [`WPFTweaksDeliveryOptimization`](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/config/tweaks.json#L571) | Delivery Optimization - Disable | medium |
| [`WPFTweaksRemoveEdge`](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/config/tweaks.json#L587) | Microsoft Edge - Remove | high |
| [`WPFTweaksDisableBitLocker`](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/config/tweaks.json#L613) | BitLocker - Disable | critical |
| [`WPFTweaksUTC`](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/config/tweaks.json#L626) | Date & Time - Set Time to UTC | high |
| [`WPFTweaksRemoveOneDrive`](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/config/tweaks.json#L642) | Microsoft OneDrive - Remove | high |
| [`WPFTweaksRemoveHomeAndGallery`](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/config/tweaks.json#L686) | File Explorer Home and Gallery - Disable | high |
| [`WPFTweaksDisplay`](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/config/tweaks.json#L716) | Visual Effects - Set to Best Performance | high |
| [`WPFTweaksReservedStorage`](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/config/tweaks.json#L815) | Disable Reserved Storage | high |
| [`WPFTweaksRestorePoint`](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/config/tweaks.json#L828) | Restore Point - Create | medium |
| [`WPFTweaksEndTaskOnTaskbar`](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/config/tweaks.json#L855) | End Task With Right Click - Enable | low |
| [`WPFTweaksStorage`](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/config/tweaks.json#L871) | Storage Sense - Disable | high |
| [`WPFTweaksWindowsAI`](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/config/tweaks.json#L887) | Windows AI - Disable And Remove | high |
| [`WPFTweaksWPBT`](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/config/tweaks.json#L931) | Windows Platform Binary Table (WPBT) - Disable | medium |
| [`WPFTweaksPreventDeviceMetadataFromNetwork`](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/config/tweaks.json#L947) | Prevent Device Companion Apps | high |
| [`WPFTweaksRazerBlock`](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/config/tweaks.json#L963) | Razer Software Auto-Install - Disable | high |
| [`WPFTweaksLogiBlock`](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/config/tweaks.json#L1004) | Logitech Download Assistant Auto-Install - Disable | high |
| [`WPFTweaksDisableNotifications`](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/config/tweaks.json#L1039) | System Tray Notifications & Calendar - Disable | high |
| [`WPFTweaksBlockAdobeNet`](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/config/tweaks.json#L1062) | Adobe URL Block List - Enable | high |
| [`WPFTweaksRightClickMenu`](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/config/tweaks.json#L1088) | Right-Click Menu Previous Layout - Enable | high |
| [`WPFTweaksDiskCleanup`](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/config/tweaks.json#L1104) | Disk Cleanup - Run | high |
| [`WPFTweaksDeleteTempFiles`](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/config/tweaks.json#L1117) | Temporary Files - Remove | high |
| [`WPFTweaksIPv46`](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/config/tweaks.json#L1132) | IPv6 - Set IPv4 as Preferred | high |
| [`WPFTweaksTeredo`](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/config/tweaks.json#L1148) | Teredo - Disable | high |
| [`WPFTweaksDisableIPv6`](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/config/tweaks.json#L1170) | IPv6 - Disable | high |
| [`WPFTweaksDisableBGapps`](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/config/tweaks.json#L1192) | Background Apps - Disable | high |
| [`WPFTweaksDisableExplorerAutoDiscovery`](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/config/tweaks.json#L1208) | File Explorer Automatic Folder Discovery - Disable | medium |
| [`WPFToggleDetailedBSoD`](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/config/tweaks.json#L1263) | BSoD Verbose Mode | low |
| [`WPFToggleBatteryPercentage`](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/config/tweaks.json#L1289) | System Tray Battery Percentage | low |
| [`WPFToggleDarkMode`](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/config/tweaks.json#L1307) | Dark Theme for Windows | low |
| [`WPFToggleShowExt`](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/config/tweaks.json#L1349) | File Explorer File Extensions | low |
| [`WPFToggleHiddenFiles`](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/config/tweaks.json#L1377) | File Explorer Hidden Files | low |
| [`WPFToggleVerboseLogon`](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/config/tweaks.json#L1405) | Logon Verbose Mode | low |
| [`WPFToggleNewOutlook`](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/config/tweaks.json#L1423) | Microsoft Outlook New Version | low |
| [`WPFToggleScrollbars`](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/config/tweaks.json#L1465) | Scrollbars Always Visible | low |
| [`WPFMultiplaneOverlay`](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/config/tweaks.json#L1483) | Multiplane Overlay | medium |
| [`WPFToggleMouseAcceleration`](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/config/tweaks.json#L1521) | Mouse Acceleration | medium |
| [`WPFToggleNumLock`](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/config/tweaks.json#L1555) | Num Lock on Startup | low |
| [`WPFToggleWindowSnapping`](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/config/tweaks.json#L1581) | Window Snapping | low |
| [`WPFToggleStandbyFix`](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/config/tweaks.json#L1599) | S0 Sleep Network Connectivity | high |
| [`WPFToggleS3Sleep`](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/config/tweaks.json#L1617) | S3 Sleep | medium |
| [`WPFToggleHideSettingsHome`](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/config/tweaks.json#L1635) | Settings Home Page | low |
| [`WPFToggleBingSearch`](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/config/tweaks.json#L1653) | Start Menu Bing Search | low |
| [`WPFToggleLoginBlur`](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/config/tweaks.json#L1671) | Logon Screen Acrylic Blur | low |
| [`WPFTweaksDisableLockscreen`](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/config/tweaks.json#L1689) | Lock Screen - Disable | medium |
| [`WPFToggleStartMenuRecommendations`](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/config/tweaks.json#L1706) | Start Menu Recommendations | low |
| [`WPFToggleStickyKeys`](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/config/tweaks.json#L1750) | Sticky Keys | medium |
| [`WPFToggleTaskbarAlignment`](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/config/tweaks.json#L1768) | Taskbar Centered Icons | low |
| [`WPFToggleTaskbarSearch`](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/config/tweaks.json#L1796) | Taskbar Search Icon | low |
| [`WPFToggleTaskView`](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/config/tweaks.json#L1814) | Taskbar Task View Icon | low |
| [`WPFToggleGameMode`](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/config/tweaks.json#L1832) | Game Mode | medium |
| [`WPFToggleLongPaths`](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/config/tweaks.json#L1858) | Enable Long Paths | medium |
| [`WPFOOSUbutton`](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/config/tweaks.json#L1876) | O&O ShutUp10++ - Run | high |
| [`WPFchangedns`](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/config/tweaks.json#L1883) | DNS - Set to: | high |
| [`WPFAddUltPerf`](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/config/tweaks.json#L1891) | Ultimate Performance Profile - Enable | medium |
| [`WPFRemoveUltPerf`](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/config/tweaks.json#L1899) | Ultimate Performance Profile - Disable | high |

All **33 WinUtil feature/fix/panel entries** follow. Opening a Windows panel is classified separately from applying a change through it. [Pinned feature definitions](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/config/feature.json).

| Source identifier | Upstream name | Record kind |
| --- | --- | --- |
| [`WPFFeaturesdotnet`](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/config/feature.json#L2) | .NET Framework (Versions 2, 3, 4) - Enable | setting |
| [`WPFFixesNTPPool`](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/config/feature.json#L14) | NTP Server - Enable | action |
| [`WPFFeatureshyperv`](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/config/feature.json#L24) | Hyper-V - Enable | setting |
| [`WPFFeatureslegacymedia`](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/config/feature.json#L34) | Legacy Media Components (WMP, DirectPlay) - Enable | setting |
| [`WPFFeaturewsl`](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/config/feature.json#L48) | Windows Subsystem for Linux (WSL) - Enable | setting |
| [`WPFFeaturenfs`](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/config/feature.json#L60) | Network File System (NFS) - Enable | setting |
| [`WPFFeatureRegBackup`](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/config/feature.json#L79) | Registry Backup (Daily Task 12:30am) - Enable | setting |
| [`WPFFeatureEnableLegacyRecovery`](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/config/feature.json#L96) | Legacy F8 Boot Recovery - Enable | setting |
| [`WPFFeatureDisableLegacyRecovery`](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/config/feature.json#L107) | Legacy F8 Boot Recovery - Disable | setting |
| [`WPFFeaturesSandbox`](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/config/feature.json#L118) | Windows Sandbox - Enable | setting |
| [`WPFFeatureInstall`](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/config/feature.json#L128) | Install Features | action |
| [`WPFPanelAutologin`](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/config/feature.json#L137) | AutoLogon - Run | action |
| [`WPFFixesUpdate`](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/config/feature.json#L146) | Windows Update - Reset | action |
| [`WPFFixesNetwork`](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/config/feature.json#L155) | Network - Reset | action |
| [`WPFPanelDISM`](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/config/feature.json#L164) | System Corruption Scan - Run | action |
| [`WPFFixesWinget`](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/config/feature.json#L173) | WinGet - Reinstall | action |
| [`WPFPanelComputer`](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/config/feature.json#L182) | Computer Management | panel-launch |
| [`WPFPanelControl`](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/config/feature.json#L193) | Control Panel | panel-launch |
| [`WPFPanelMouse`](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/config/feature.json#L204) | Mouse Properties | panel-launch |
| [`WPFPanelNetwork`](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/config/feature.json#L215) | Network Connections | panel-launch |
| [`WPFPanelPower`](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/config/feature.json#L226) | Power Panel | panel-launch |
| [`WPFPanelPrinter`](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/config/feature.json#L237) | Printer Panel | panel-launch |
| [`WPFPanelPrograms`](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/config/feature.json#L248) | Programs and Features | panel-launch |
| [`WPFPanelRegion`](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/config/feature.json#L259) | Region | panel-launch |
| [`WPFPanelSecurity`](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/config/feature.json#L270) | Security and Maintenance | panel-launch |
| [`WPFPanelSound`](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/config/feature.json#L281) | Sound Settings | panel-launch |
| [`WPFPanelSystem`](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/config/feature.json#L292) | System Properties | panel-launch |
| [`WPFPanelTimedate`](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/config/feature.json#L303) | Time and Date | panel-launch |
| [`WPFPanelFirewall`](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/config/feature.json#L314) | Windows Defender Firewall | panel-launch |
| [`WPFPanelRestore`](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/config/feature.json#L325) | Windows Restore | panel-launch |
| [`WPFWinUtilInstallPSProfile`](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/config/feature.json#L336) | CTT PowerShell Profile - Install | action |
| [`WPFWinUtilUninstallPSProfile`](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/config/feature.json#L345) | CTT PowerShell Profile - Remove | action |
| [`WPFWinUtilSSHServer`](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/config/feature.json#L354) | OpenSSH Server - Enable | action |

All **14 WinUtil DNS choices** follow. Their exact IPv4/IPv6 addresses and encrypted-DNS templates, where declared, are in the catalog. [Pinned DNS definitions](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/config/dns.json).

| Resolver source identifier | IPv4 primary | IPv4 secondary |
| --- | --- | --- |
| Google | 8.8.8.8 | 8.8.4.4 |
| Cloudflare | 1.1.1.1 | 1.0.0.1 |
| Cloudflare_Malware | 1.1.1.2 | 1.0.0.2 |
| Cloudflare_Malware_Adult | 1.1.1.3 | 1.0.0.3 |
| Open_DNS | 208.67.222.222 | 208.67.220.220 |
| Quad9 | 9.9.9.9 | 149.112.112.112 |
| AdGuard_Ads_Trackers | 94.140.14.14 | 94.140.15.15 |
| AdGuard_Ads_Trackers_Malware_Adult | 94.140.14.15 | 94.140.15.16 |
| Mullvad | 194.242.2.2 | 194.242.2.3 |
| Mullvad_Ads_Trackers | 194.242.2.3 | 194.242.2.2 |
| Mullvad_Ads_Trackers_Malware | 194.242.2.4 | 194.242.2.3 |
| Mullvad_Ads_Trackers_Malware_Social | 194.242.2.5 | 194.242.2.4 |
| Mullvad_Ads_Trackers_Malware_Adult_Gambling | 194.242.2.6 | 194.242.2.5 |
| Mullvad_Ads_Trackers_Malware_Adult_Gambling_Social | 194.242.2.9 | 194.242.2.6 |

All **31 current FSOS-X setup choices** follow. “Source default” describes the inspected playbook, not a Roo default; the explicit no-browser entry is a separate choice. [playbook.conf in R11H2](https://fsosx.com/FSOS-XR11H2.apbx).

| Option identifier | Source label | Source default |
| --- | --- | --- |
| `browser-none` | Do not install a browser | unselected |
| `browser-brave` | Brave | unselected |
| `browser-helium` | Helium | unselected |
| `browser-thorium` | Thorium | selected |
| `remove-xbox` | Remove Xbox & Gamebar | unselected |
| `remove-store` | Remove Microsoft Store | unselected |
| `remove-edge` | Remove Edge | selected |
| `remove-bloat` | Remove Common Bloatware | selected |
| `remove-ai` | Remove AI (Copilot, Recall) | selected |
| `fs-privacy` | Harden Privacy Further | selected |
| `disable-power-saving` | Disable Power Saving (Desktops Only) | unselected |
| `remove-onedrive` | Remove OneDrive | selected |
| `disable-defender` | Disable Windows Defender and SmartScreen | unselected |
| `disable-mitigations` | Disable Security Mitigations | unselected |
| `remove-hyperv` | Remove Hyper-V and Virtualization | unselected |
| `disable-printing` | Disable Printing | unselected |
| `disable-webview2` | Disable WebView2 | unselected |
| `disable-wifi` | Disable Wi-Fi | unselected |
| `disable-bluetooth` | Disable Bluetooth | unselected |
| `disable-location` | Disable Location | unselected |
| `disable-storage-sense` | Disable Storage Sense | unselected |
| `remove-accessibility` | Remove Accessibility Features | unselected |
| `disable-auto-driver-updates` | Disable Auto Driver Updates | unselected |
| `fs-wallpaper` | Apply FSOS Wallpaper | selected |
| `fs-darkmode` | Enable Dark Mode | selected |
| `fs-noanimations` | Disable Animations | selected |
| `fs-notransparency` | Disable Transparency | selected |
| `fs-w10-context` | Windows 10 Context Menu | unselected |
| `fs-w10-taskbar` | Windows 10 Taskbar | unselected |
| `fs-w10-tbleft` | Left Taskbar Alignment | unselected |
| `fs-small-icons` | Small Desktop Icons | unselected |

All **79 current Dash toggle-service symbols** follow. The short names are inferred from symbols in the pinned binary, and the risk classification is an independent review judgment. This is a symbol inventory, not source-confirmed behavior. [Dash binary inside verified R11H2](https://fsosx.com/FSOS-XR11H2.apbx).

| Binary symbol | Inferred setting | Risk |
| --- | --- | --- |
| `ActivityHistoryToggleService` | Activity History | high |
| `AnimationsToggleService` | Animations | high |
| `AudioEnhancementsToggleService` | Audio Enhancements | high |
| `AutoDefragToggleService` | Auto Defrag | high |
| `AutoRebootCrashToggleService` | Auto Reboot Crash | high |
| `AutomaticMaintenanceToggleService` | Automatic Maintenance | high |
| `BackgroundAppsToggleService` | Background Apps | high |
| `BluetoothToggleService` | Bluetooth | high |
| `CenterTaskbarToggleService` | Center Taskbar | high |
| `CombineTaskbarButtonsToggleService` | Combine Taskbar Buttons | high |
| `ConsumerFeaturesToggleService` | Consumer Features | high |
| `ControlFlowGuardToggleService` | Control Flow Guard | critical |
| `CoreIsolationToggleService` | Core Isolation | critical |
| `DarkThemeToggleService` | Dark Theme | high |
| `DeliveryOptimizationToggleService` | Delivery Optimization | high |
| `DesktopContextMenuToggleService` | Desktop Context Menu | high |
| `DriverUpdatesToggleService` | Driver Updates | high |
| `DynamicLightingToggleService` | Dynamic Lighting | high |
| `EndTaskRightClickToggleService` | End Task Right Click | high |
| `EnergyEfficientEthernetToggleService` | Energy Efficient Ethernet | high |
| `EnergyRecommendationsToggleService` | Energy Recommendations | high |
| `ExplorerLaunchTargetToggleService` | Explorer Launch Target | high |
| `FastSendDatagramThresholdToggleService` | Fast Send Datagram Threshold | high |
| `FaultTolerantHeapToggleService` | Fault Tolerant Heap | high |
| `FileExtensionsToggleService` | File Extensions | high |
| `FullscreenOptimizationsToggleService` | Fullscreen Optimizations | high |
| `GameBarToggleService` | Game Bar | high |
| `GlobalTimerResolutionToggleService` | Global Timer Resolution | high |
| `HagsToggleService` | Hags | high |
| `HibernationToggleService` | Hibernation | high |
| `HiddenFilesToggleService` | Hidden Files | high |
| `HotspotToggleService` | Hotspot | high |
| `HyperVToggleService` | Hyper V | high |
| `InterruptModerationToggleService` | Interrupt Moderation | high |
| `KernelPagingExecutiveToggleService` | Kernel Paging Executive | high |
| `LargeSendOffloadToggleService` | Large Send Offload | high |
| `LegacyContextMenuToggleService` | Legacy Context Menu | high |
| `LlmnrToggleService` | Llmnr | high |
| `LocationToggleService` | Location | high |
| `LongPathsToggleService` | Long Paths | high |
| `MemoryCompressionToggleService` | Memory Compression | high |
| `MenuDelayToggleService` | Menu Delay | high |
| `ModernStandbyFixToggleService` | Modern Standby Fix | high |
| `MouseAccelerationToggleService` | Mouse Acceleration | high |
| `MouseThrottleToggleService` | Mouse Throttle | high |
| `MpoToggleService` | Mpo | high |
| `NagleAlgorithmToggleService` | Nagle Algorithm | high |
| `NduServiceToggleService` | Ndu Service | high |
| `NetbiosToggleService` | Netbios | high |
| `NetworkThrottlingToggleService` | Network Throttling | high |
| `NtfsLastAccessToggleService` | Ntfs Last Access | high |
| `OtherSecurityMitigationsToggleService` | Other Security Mitigations | critical |
| `PowerSavingToggleService` | Power Saving | high |
| `PrintingToggleService` | Printing | high |
| `QosReservedBandwidthToggleService` | Qos Reserved Bandwidth | high |
| `SearchIndexingToggleService` | Search Indexing | high |
| `SmallDesktopIconsToggleService` | Small Desktop Icons | high |
| `SmartScreenToggleService` | Smart Screen | critical |
| `StickyKeysToggleService` | Sticky Keys | high |
| `StorageSenseToggleService` | Storage Sense | high |
| `SysMainToggleService` | Sys Main | high |
| `SystemRestoreToggleService` | System Restore | high |
| `TaskOffloadToggleService` | Task Offload | high |
| `TcpAckFrequencyToggleService` | Tcp Ack Frequency | high |
| `TcpAutoTuningToggleService` | Tcp Auto Tuning | high |
| `TcpRscToggleService` | Tcp Rsc | high |
| `TdrDelayToggleService` | Tdr Delay | high |
| `TelemetryToggleService` | Telemetry | high |
| `TextInputServiceToggleService` | Text Input Service | high |
| `TransparencyToggleService` | Transparency | high |
| `UacToggleService` | Uac | critical |
| `VariableRefreshRateToggleService` | Variable Refresh Rate | high |
| `VbsToggleService` | Vbs | critical |
| `VulnerableDriverBlocklistToggleService` | Vulnerable Driver Blocklist | critical |
| `WifiToggleService` | Wifi | high |
| `Win32PrioritySeparationToggleService` | Win32 Priority Separation | high |
| `WindowedOptimizationsToggleService` | Windowed Optimizations | high |
| `WindowsGameModeToggleService` | Windows Game Mode | high |
| `WindowsUpdateToggleService` | Windows Update | high |

The **31 selected Dash option properties** provide additional evidence for session settings that are not represented by ToggleService names. Command symbols and all 15 page names remain fully listed in the JSON, with generic commands marked ambiguous. [Current Dash binary provenance](https://fsosx.com/FSOS-XR11H2.apbx).

| Binary property | Inferred option |
| --- | --- |
| `ApplyGamingPowerPlan` | Apply Gaming Power Plan |
| `BoostGamePriority` | Boost Game Priority |
| `ClearStandbyMemory` | Clear Standby Memory |
| `CloseDashAfterLaunch` | Close Dash After Launch |
| `CustomAffinityMask` | Custom Affinity Mask |
| `DisableSearchUi` | Disable Search Ui |
| `DisableSmoothScrolling` | Disable Smooth Scrolling |
| `EnableLoadLatencyReduction` | Enable Load Latency Reduction |
| `GameGpuPriority` | Game Gpu Priority |
| `GameIoPriority` | Game Io Priority |
| `GamePriority` | Game Priority |
| `MinimizeToTray` | Minimize To Tray |
| `PauseNonEssentialServices` | Pause Non Essential Services |
| `PinPowerState` | Pin Power State |
| `ReduceSteamResourceUsage` | Reduce Steam Resource Usage |
| `RevertToPowerPlanGuid` | Revert To Power Plan Guid |
| `ShaderCacheSchedule` | Shader Cache Schedule |
| `StartWithWindows` | Start With Windows |
| `LowerOtherProcesses` | Lower Other Processes |
| `ProBalanceSystemCpuTrigger` | Pro Balance System Cpu Trigger |
| `ProBalanceProcessCpuTrigger` | Pro Balance Process Cpu Trigger |
| `ProBalanceProcessCpuRestore` | Pro Balance Process Cpu Restore |
| `ProBalanceTimeOverQuotaMs` | Pro Balance Time Over Quota Ms |
| `ProBalanceMinAdjustMs` | Pro Balance Min Adjust Ms |
| `ProBalanceMaxAdjustMs` | Pro Balance Max Adjust Ms |
| `AffinityMode` | Affinity Mode |
| `Theme` | Theme |
| `CheckForUpdatesOnStartup` | Check For Updates On Startup |
| `ExitAfterSession` | Exit After Session |
| `SilentSession` | Silent Session |
| `ShowGetOptimized` | Show Get Optimized |

Inventory verification compared complete source-key sets against generated entries for every maintained config section, accounted for every named interactive XAML control, matched all 1,319 YAML action records by file/sequence/line, checked unique IDs and required metadata, and parsed the output as strict JSON. The upstream feature JSON required permissive input parsing for a literal control character inside a string; the emitted inventory has no such syntax exception. Separate negative checks reject a missing upstream setting and an accidentally enabled automatic-apply flag. The FSOS archive digest and Dash file version/hash were read directly from downloaded bytes.

No upstream utility was launched, no Windows settings were applied, and no performance measurements were taken. The source inventory establishes what was observed and what Roo can independently implement next. It cannot establish every proprietary Dash control, the behavior of opaque bundled tools, the result of nested script branches, or actual Windows execution readiness. Those limits are recorded in the JSON beside source-level backend coverage, rather than represented as completed runtime verification.
