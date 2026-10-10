# O&O ShutUp10 setting inventory

Research date: 2026-09-19. Scope: independently implementable setting behavior for Roo Industries Optimization Suite. No application, vendor assembly, registry operation, service operation, uninstaller, or cleanup action was executed.

## Pinned source and completeness

The official download currently supplies **O&O ShutUp10 3.5.1130.0**, released 2026-09-02. It must not be confused with older ShutUp10++ 1.9 inventories. The release version is independently present in the downloaded PE version resource. [Official release history](https://www.oo-software.com/en/shutup10/changelog), [official download page](https://www.oo-software.com/en/download/current/ooshutup10).

| Artifact | Identity |
| --- | --- |
| Portable x64 package | [OOSU10.exe](https://dl5.oo-software.com/files/ooshutup10/OOSU10.exe) |
| Download size | 79,930,408 bytes |
| SHA-256 | `1ad8cdc324a79ac37a50858fddcd28eb7491459114f0da514c4750b08b115103` |
| Regular settings | **365 distinct option IDs** |
| Version-specific registrations | **376** |
| Registry action registrations | **407**, plus aggregate Edge DNS policy behavior |
| Categories | **21** |

The complete factual inventory is stored privately at `<private work folder>/four-tool-tweaks-20260919/oosu/inventory.json`. It includes every setting-registration statement from this pinned version: ID, English resource label, category, scope, registry view/path/name/type, enable value, vendor-default reset value, build/edition gates, restart flags and special behavior. The extraction checks exhaustively reconcile 376 registration statements and 407 registry calls, with zero unparsed statements or missing labels. These counts include obsolete settings and OS-specific variants; they are not a claim that365 settings apply to a particular PC.

The binary was unpacked and inspected statically. Only factual behavior records are intended for an independently written native implementation. Proprietary implementation bodies are excluded from product source. This is **static mapping evidence**, not executed effectiveness evidence.

## Coverage by category

| Category | Distinct IDs | Version variants | Registry actions |
| --- | ---: | ---: | ---: |
| Activity History and Clipboard | 6 | 6 | 6 |
| App Privacy | 89 | 93 | 98 |
| Cortana (Personal Assistant) | 11 | 11 | 14 |
| Microsoft Edge (legacy version) | 14 | 14 | 14 |
| Gaming | 1 | 1 | 3 |
| Location Services | 6 | 7 | 11 |
| Lock Screen | 3 | 3 | 4 |
| Miscellaneous | 16 | 17 | 18 |
| Mobile Devices | 4 | 4 | 4 |
| Microsoft Edge (new version based on Chromium) | 97 | 97 | 97 |
| Microsoft Office | 20 | 20 | 20 |
| Privacy | 25 | 27 | 29 |
| Search | 6 | 7 | 7 |
| Security | 14 | 14 | 16 |
| Synchronization of Windows Settings | 7 | 7 | 7 |
| Taskbar | 7 | 8 | 8 |
| User Behavior | 6 | 6 | 8 |
| #COPILOT# & Windows AI | 14 | 14 | 14 |
| Microsoft Defender and Microsoft SpyNet | 4 | 4 | 4 |
| Windows Explorer | 5 | 5 | 5 |
| Windows Update | 10 | 11 | 20 |

All regular settings register registry operations. Seven of the registrations change service startup values, including two OS variants of the same Location option. There are no scheduled-task or process-priority registrations in this setting collection. The separate AI-removal feature includes uninstall and file-erasure operations, described below.

## Identity, overlap and recovery contracts

The native registry helper explicitly chooses **Registry64 on 64-bit Windows and Registry32 on 32-bit Windows**. A current-user setting uses HKCU in direct execution; service delegation substitutes HKU plus the initiating user's SID. No setting registration uses merged HKCR. Explicit HKCU\Software\Classes entries remain user-scoped keys. These facts come from the pinned package's registry-helper metadata.

Treat `hive + registry view + normalized path + value name + initiating user` as resource identity. The same option ID may have different registrations by OS version; the duplicate IDs are `P023`, `P019`, `P021`, `P022`, `L005`, `N001`, `P065`, `P070`, `M003`, `M019`, and `W010`. The inventory retains all variants. Treat a user policy and machine policy as different resources with related effective behavior, not as duplicate keys. O&O documents the separate scopes and machine-policy precedence. [O&O scope documentation](https://manuals.oo-software.com/ooshutup10/en/docs/features/overview/).

Most actions are fixed String/DWord writes. `S006` and `S007` are old Wi-Fi Sense bitwise-AND operations against one SID-dependent value, with distinct masks and an absent-value fallback. They require atomic read/modify/write and composable masks if legacy Windows support is implemented. Vendor `Create` and `Edit` commands both perform value writes; `Create` is not an absent-only operation.

The captured vendor reset values describe factory/default behavior. **They must not replace the user's captured originals.** Native restore should preserve original type, value, existence, ownership, and unrelated values. The vendor's own documentation distinguishes restoring originals from factory reset. [O&O undo semantics](https://manuals.oo-software.com/ooshutup10/docs/common-features/undo-history/).

## Additional side effects that must be represented

1. **Edge DNS policy:** toggling a machine-scope entry from the Chromium Edge registration group invokes an aggregate callback. Later-added legacy Edge entries `E011` and `E012` do not receive that callback. If any registered machine Edge option is enabled, it writes String `automatic` to `HKLM\SOFTWARE\Policies\Microsoft\Edge:DnsOverHttpsMode`; otherwise it deletes that value. This effect is not an individual option ID. It must be represented in source coverage and conflict analysis. Prefer an explicit setting instead of an invisible change. Microsoft's policy documents the registry target and permitted modes. [DnsOverHttpsMode](https://learn.microsoft.com/en-us/deployedge/microsoft-edge-policies/dnsoverhttpsmode).
2. **Empty policy-key cleanup:** deleting a value can recursively remove empty ancestors while they remain under policy prefixes. Exact restoration should delete only empty keys created and owned by the transaction.
3. **Factory reset policy-tree cleanup:** the vendor reset flow can delete whole machine-policy subkeys referenced by selected settings. This is broader than undoing individual values and could remove unrelated policies. Do not reproduce it in normal native restore.
4. **Service startup settings:** the regular table includes `lfsvc`, `DiagTrack`, `dmwappushservice`, `SEMgrSvc`, `WFDSConMgrSvc`, and `wuauserv`. Their registry paths and values are in the inventory. They require service-change review and verification; registry read-back alone does not show that a running service has stopped.

## Independent Microsoft-source checks

Private `microsoft-edge-verification.json` records 48 policy lookups, including the DNS side effect. **47 official pages were retrieved**; the page for`EdgeSecureNetworkEnabled` returned404. Each successful record includes its source URL, snapshot hash, Windows browser-version applicability, registry name/type/path, profile applicability and refresh requirements. These are source confirmations, not runtime tests. [Microsoft Edge policy reference](https://learn.microsoft.com/en-us/deployedge/microsoft-edge-policies).

The independent checks expose current compatibility differences: `AddressBarMicrosoftSearchInBingProviderEnabled`, `MetricsReportingEnabled`, `SendSiteInfoToImproveServices`, and `SiteSafetyServicesEnabled` are obsolete; `WebWidgetAllowed` is deprecated. Maintain legacy coverage without showing a successful effective result on incompatible Edge versions. [Bing address-bar policy](https://learn.microsoft.com/en-us/deployedge/microsoft-edge-policies/addressbarmicrosoftsearchinbingproviderenabled), [metrics policy](https://learn.microsoft.com/en-us/deployedge/microsoft-edge-policies/metricsreportingenabled), [site-information policy](https://learn.microsoft.com/en-us/deployedge/microsoft-edge-policies/sendsiteinfotoimproveservices), [site-safety policy](https://learn.microsoft.com/en-us/deployedge/microsoft-edge-policies/sitesafetyservicesenabled), [web-widget policy](https://learn.microsoft.com/en-us/deployedge/microsoft-edge-policies/webwidgetallowed).

Many Edge policy pages expressly exclude profiles signed in with a Microsoft account. A readable registry value is only a configured state for those profiles. For example, Do Not Track has this exclusion; BrowserSignin has different applicability. Preserve each policy's documented behavior rather than assuming all policies work identically. [ConfigureDoNotTrack](https://learn.microsoft.com/en-us/deployedge/microsoft-edge-policies/configuredonottrack), [BrowserSignin](https://learn.microsoft.com/en-us/deployedge/microsoft-edge-policies/browsersignin).

Private `microsoft-windows-verification.json` contains 169 Windows policy-to-registry mappings, of which 30 registry actions exactly match inventory paths and names. Each match retains the documented applicability and allowed-value text. The remaining O&O mappings are supported by vendor static evidence; they are not mislabeled as independently Microsoft-confirmed. Useful source families include [Privacy](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-privacy), [Experience](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-experience), [System](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-system), [Search](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-search), and[WindowsAI](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-windowsai).

## Separate AI-removal operations

The AI page groups existing AI settings, uninstalls detected Copilot applications and erases Recall data. The settings group is a preset over existing atomic controls, not another implementation. The uninstall and erasure steps are separate irreversible actions. [Official AI-removal documentation](https://manuals.oo-software.com/ooshutup10/en/docs/common-features/ai-removal/).

Static package detection uses package-family prefixes`Microsoft.Windows.Ai.Copilot`, `Microsoft.Copilot`, and `Microsoft.MicrosoftOfficeHub_8wekyb3d8bbwe`; desktop names start with`Microsoft Copilot` or`Copilot`, excluding`Copilot CLI`. Removal invokes Windows PackageManager removal for current-user/machine scopes or registered desktop uninstall commands. Roo Industries should use its existing app-removal inventory and exact selections, preserving scope and identity rather than uninstalling arbitrary name-prefix matches.

Recall data discovery targets the initiating user's local-app-data`CoreAIPlatform.00` directory. The vendor invokes its proprietary SafeErase engine after attempting ownership changes. This is not an ordinary reversible tweak. An independent cleanup flow requires exact path review and must not claim that zero-filling SSD files guarantees physical erasure. The proprietary erasure internals and Premium enforcement service were not assessed.

## Implementation batches and acceptance limits

The complete registry mapping is available for all 365 IDs. Activity History, Synchronization, Lock Screen, Explorer, Search, Mobile Devices and the ordinary Privacy controls can reuse an independent registry transaction engine. Edge controls additionally need product-version/profile applicability; App Privacy needs exact build/scope handling; Office needs installed-version substitution; legacy Wi-Fi needs bitwise composition. Service startup settings and AI removal must use their corresponding executors and review flows.

Before marking any setting implemented, require catalog/source coverage, detected applicability, exact conflict identity, preview, original-state capture, apply/read-back, restoration, and no duplicate execution when multiple source presets select the same resource. Distinguish configured, effective, unsupported, and unknown states. Native transaction tests can use isolated registry fixtures; production service changes, uninstallers and user-data deletion require their exact approvals.

No Windows machine was accessed and no live state was changed during this research. Source completeness is established for the regular setting-registration catalog; live effectiveness and app-removal parity remain implementation/validation work.

## Dynamic path bindings

Twenty registrations require variable binding: 18 Office targets use a detected Office major version; `S006` and `S007` use a captured user SID. Exact contracts and affected IDs are retained in private `oosu/binding-contracts.json`.

Office discovery selects one version, with no version allowlist and no fan-out. It checks the machine ClickToRun Configuration key before Common InstallRoot, preferring a nonempty `VersionToReport` string over `Path` within each key. It parses the version's first dot-separated component, or two digits following the last case-sensitive `\Office` path component. The discovery uses process-default registry view; regular setting writes separately use the OS-specific explicit view. Normal availability also requires the initiating user's `Software\Microsoft\Office\<major>.0\Common` key. Even the versionless Office options share that availability gate. Missing or malformed discovery must not produce a literal template path or a guessed `16.0` target. These are static facts from the pinned [official package](https://dl5.oo-software.com/files/ooshutup10/OOSU10.exe).

The old Wi-Fi Sense SID is captured from the running user's Windows token, and the options are registered only when that SID exists. Native delegation must bind the initiating user, preserve the old Windows-version gate, and validate the SID as a single path component. Separate `delegatedUserScope` metadata describes resolving an HKCU target through HKU and the initiating SID; it is not another resource to apply.
