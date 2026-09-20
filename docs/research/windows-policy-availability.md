# Windows policy availability

Research date: 2026-09-20. Target: Windows 11 build 26200, Professional. Microsoft identifies build 26200 as Windows 11 25H2. This report covers the 29 records in `gated-policies.json`, SHA-256 `1ae08577a544ee3a0325f44f5725e3b8d55ccdb25fe2945e7fceb1f1ff0e37f1`. [Windows release information](https://learn.microsoft.com/en-us/windows/release-health/windows11-release-information)

## Result

All 29 choices can remain selectable as saved intent. That does not establish that all 29 original registry operations have an effect on this machine. Selection availability, execution prerequisites, registry readback, and verified behavior need separate states. This is the implementation recommendation, not a claim that Microsoft documents the application's selection model.

- The four Edge rows have an incorrect legacy upper bound: Microsoft documents Edge **77–88**, not 77–87. They are still obsolete on newer Edge. A current `DiagnosticData` policy provides a supported replacement for Edge 122 and later. [Legacy metrics policy](https://learn.microsoft.com/en-us/deployedge/microsoft-edge-policies/MetricsReportingEnabled), [legacy site policy](https://learn.microsoft.com/en-us/deployedge/microsoft-edge-policies/SendSiteInfoToImproveServices), [current diagnostic policy](https://learn.microsoft.com/en-us/deployedge/microsoft-edge-policies/DiagnosticData)
- The 14 app-permission intents have current AppPrivacy policies on Pro. Those policies are machine-wide; the catalog's original `DeviceAccess` values are per-user. Removing the old build cap without changing or verifying the underlying path would not establish support. [Privacy CSP](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-privacy)
- Widgets still has supported Windows 11 controls. The `TaskbarDa` cap at 22620 does not establish that Widgets disappears after that build. Its direct registry-write contract on build 26200 remains unverified; the documented `AllowNewsAndInterests` policy is available on Pro. [Windows 11 settings reference](https://learn.microsoft.com/en-us/windows/apps/develop/settings/settings-windows-11#personalization---taskbar---widgets-button), [Widgets policy](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-newsandinterests#allownewsandinterests)
- The Pro exclusion for `ConnectedSearchUseWeb` is documented. Wi-Fi Sense, Windows 10 Feeds, and the Windows Update PC Health Check install action do not become Windows 11 features by removing their gates. [Search CSP](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-search#donotusewebresults), [Wi-Fi Sense removal](https://learn.microsoft.com/en-us/windows/privacy/manage-connections-from-windows-operating-system-components-to-microsoft-services#23-wi-fi-sense), [Feeds applicability](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-feeds), [PC Health Check update](https://support.microsoft.com/en-us/servicing/os/windows/2021/07/kb5005463-pc-health-check-application)
- Applying consuming-product gates to **removing an override or restoring its snapshot** is unnecessarily restrictive. Removal does not require an installed consumer. It still requires the exact user/hive/view/target and must not overwrite unrelated changes. This is an execution-model recommendation; removal must not be described as enabling a removed feature.

No Windows commands, product operations, or registry writes were performed for this research. No frontend files were read or edited. The report establishes documentation and template contracts, not live behavior on the target.

## Evidence and decision rules

The original targets and existing gates below come from the supplied catalog snapshot. Microsoft documentation establishes product and edition applicability. Downloaded Microsoft ADMX files establish exact registry mappings and types; their presence alone does not prove a current Windows component consumes a value.

The following archives were downloaded and inspected on Linux, without running either installer. Temporary extraction directories were removed after inspection:

| Primary artifact | Version | SHA-256 | Inspected content |
| --- | --- | --- | --- |
| [Windows 11 25H2 templates](https://www.microsoft.com/en-us/download/details.aspx?id=108542) | V3, January 2026 | `49a603cdc543558ab46f3774a562cc0d21868d75df5b3caefd6a1c3efd4ee7e5` | `AppPrivacy.admx`, `NewsAndInterests.admx`, `Search.admx`, `WindowsExplorer.admx` |
| [Office administrative templates](https://www.microsoft.com/en-us/download/details.aspx?id=49030) | 5568.1000 | `a775828c86808bed55343c4738bed9458825d6fb7fa1948c2726e0b38dc45cfa` | `office16.admx` and English `office16.adml` resources |

Office extraction produced errors for unrelated reparse entries; both referenced Office policy elements and their English explanatory resources were successfully extracted and parsed. Windows template extraction completed successfully. These source checks did not install templates on any device.

| Signal or transition | Required evidence | Missing or conflicting evidence |
| --- | --- | --- |
| Save a choice | Valid catalog option and exact target identity | Preserve intent without inventing effectiveness. |
| Apply a legacy product policy | Actual product/version plus documented applicability | Missing product, obsolete version, or unknown product variant is an explicit prerequisite/result. Registry existence is insufficient. |
| Apply a supported replacement | Its actual hive/scope, value, edition/build contract, and competing policy state | Do not silently enlarge per-user scope or overwrite another setting's target. |
| Claim success | Registry readback plus the consuming component's effective policy or observable behavior | A writable/readable registry value proves storage only. |
| Remove/restore an override | Correct initiating user, registry view, complete prior snapshot, and conflict handling | A new Windows build or absent product does not itself prevent cleanup. Unresolved user identity still prevents a safe target. |

## Address notation

All supplied operations use `Registry64`. `HKCU` must mean the initiating operator's user hive, including when a helper runs under another identity. The final backslash component below is the **value name**, not a subkey.

| Alias | Exact prefix |
| --- | --- |
| `OFFICE` | `HKCU\Software\Policies\Microsoft\Office\16.0\Common` |
| `EDGE-M` | `HKLM\SOFTWARE\Policies\Microsoft\Edge` |
| `EDGE-U` | `HKCU\SOFTWARE\Policies\Microsoft\Edge` |
| `DA` | `HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\DeviceAccess\Global` |
| `APP` | `HKLM\Software\Policies\Microsoft\Windows\AppPrivacy` |
| `WIFI` | `HKLM\SOFTWARE\Microsoft\WcmSvc\wifinetworkmanager\features\{user-sid}` |

`delete` means removing that value, not writing zero. Every table's "original" column describes the supplied data, including values whose effective behavior could not be verified.

## Office and Edge: six records

| ID | Original target and choices | Applicability and recommended execution gate | Primary evidence |
| --- | --- | --- | --- |
| `windows.e62dbec0b81d06ff` | `OFFICE\qmenable`: DWORD `0`; delete | Template defines a user policy for Office 2016 CEIP: `0` disables participation, `1` permits opt-in. Require a known Office product that consumes this legacy policy. Generic `office16` presence alone does not prove current Microsoft 365 behavior. No Pro-specific exclusion is documented. Remove the product gate for cleanup; offer modern Office diagnostics separately. | [Office templates](https://www.microsoft.com/en-us/download/details.aspx?id=49030), [current Office privacy products](https://learn.microsoft.com/en-us/microsoft-365-apps/privacy/products-versions-privacy-controls) |
| `windows.c075970f84ec328b` | `EDGE-M\MetricsReportingEnabled`: DWORD `0`; delete | Legacy effective range Edge 77–88, with the documented managed-device prerequisite. Ignored after 88. Correct `edge:77:87` to `edge:77:88` for legacy execution; on current Edge offer `DiagnosticData`. Cleanup needs no Edge version gate. | [MetricsReportingEnabled](https://learn.microsoft.com/en-us/deployedge/microsoft-edge-policies/MetricsReportingEnabled) |
| `windows.ffb1454675fe0bab` | `EDGE-U\MetricsReportingEnabled`: DWORD `0`; delete | Same product range and prerequisites as the preceding row. Preserve user scope when proposing a current replacement; do not combine HKCU and HKLM records without accounting for precedence. | [MetricsReportingEnabled](https://learn.microsoft.com/en-us/deployedge/microsoft-edge-policies/MetricsReportingEnabled), [Edge policy configuration](https://learn.microsoft.com/en-us/deployedge/configure-microsoft-edge) |
| `windows.8c7083a823121bf9` | `OFFICE\sendcustomerdata`: DWORD `0`; delete | The legacy template maps `0` to disabled and `1` to enabled. Microsoft explicitly says the corresponding personal-information policy has no effect on Microsoft 365 Apps for enterprise from version 1904. `office16` alone is too broad; require the applicable legacy product/version, or replace the intent with explicitly labeled current connected-experience controls. | [Office templates](https://www.microsoft.com/en-us/download/details.aspx?id=49030), [replaced Office policies](https://learn.microsoft.com/en-us/microsoft-365-apps/privacy/manage-privacy-controls#existing-policy-settings-that-are-replaced-by-new-policy-settings) |
| `windows.67492e826e19151c` | `EDGE-M\SendSiteInfoToImproveServices`: DWORD `0`; delete | Legacy Edge 77–88 only; ignored after 88. Correct the off-by-one legacy gate; use the current diagnostic control for supported Edge versions. | [SendSiteInfoToImproveServices](https://learn.microsoft.com/en-us/deployedge/microsoft-edge-policies/SendSiteInfoToImproveServices) |
| `windows.7c8b9bf95199812d` | `EDGE-U\SendSiteInfoToImproveServices`: DWORD `0`; delete | Same product range as preceding row, retaining user scope. A replacement shares `DiagnosticData` with the metrics intent; conflicting selections must be resolved before applying. | [SendSiteInfoToImproveServices](https://learn.microsoft.com/en-us/deployedge/microsoft-edge-policies/SendSiteInfoToImproveServices), [DiagnosticData](https://learn.microsoft.com/en-us/deployedge/microsoft-edge-policies/DiagnosticData) |

### Current Edge replacement

`SOFTWARE\Policies\Microsoft\Edge\DiagnosticData`, DWORD `0` disables diagnostic collection, `1` keeps required data, and `2` includes optional data. Microsoft's Windows support threshold is Edge 122; the policy requires a browser restart and applies to Microsoft-account profiles. This is broader than a separate sites-only toggle. No Pro exclusion appears in the policy's applicability. Verify acceptance and any overriding scope in `edge://policy`; direct registry writes alone do not prove acceptance. [DiagnosticData](https://learn.microsoft.com/en-us/deployedge/microsoft-edge-policies/DiagnosticData), [Edge verification procedure](https://learn.microsoft.com/en-us/deployedge/configure-microsoft-edge#3-test-your-policies)

The old metrics policy additionally requires a domain-joined Windows instance or a supported Pro/Enterprise managed instance. Its enabled behavior also depends on the site-information policy and Windows diagnostics. The old site policy does not publish the same management restriction; do not add it merely because the names are related. [Metrics prerequisites](https://learn.microsoft.com/en-us/deployedge/microsoft-edge-policies/MetricsReportingEnabled), [site-policy behavior](https://learn.microsoft.com/en-us/deployedge/microsoft-edge-policies/SendSiteInfoToImproveServices)

### Current Office replacements

For supported Office products, `HKCU\Software\Policies\Microsoft\Office\Common\ClientTelemetry\SendTelemetry` uses DWORD `1` for required data, `2` for optional data, and `3` for neither. Required service data is a separate category. Under `OFFICE\Privacy`, `UserContentDisabled`, `DownloadContentDisabled`, `ControllerConnectedServicesEnabled`, and `DisconnectedState` use DWORD `1` to allow their respective connected-experience categories and `2` to disable them. These are separate intents; a single old personal-information switch cannot be substituted without describing which features it controls. [Office privacy registry mappings](https://learn.microsoft.com/en-us/microsoft-365-apps/privacy/manage-privacy-controls#control-privacy-settings-by-editing-the-registry)

Detect the Office product, channel, and version, not only the `16.0` registry family. Microsoft's product table lists the current privacy controls for Microsoft 365 Apps and applicable retail/volume products, with version 1904 as the minimum for the listed classic Windows Office apps. This does not establish that every legacy `qmenable` consumer disappeared in 1904; that claim remains unverified. [Office product applicability](https://learn.microsoft.com/en-us/microsoft-365-apps/privacy/products-versions-privacy-controls)

## App permissions: fourteen records

Each original row writes REG_SZ `Deny` or `Allow` to `DA\<component>\Value`, gated to builds 10240–16299. No first-party contract was located establishing that all these exact `DeviceAccess` values stop working at 16299, or that writing them controls build 26200. Treat their legacy execution as unverified, rather than claiming either universal removal or present support.

The replacements below are verified in Microsoft's current ADMX: `APP\<policy>`, DWORD `0` delegates to the user, `1` forces allow, and `2` forces deny. The ADMX establishes these exact names and numeric meanings. [Windows 11 25H2 templates](https://www.microsoft.com/en-us/download/details.aspx?id=108542)

All listed modern policies are documented for **Pro, Enterprise, Education, and IoT Enterprise/LTSC**. `CSP min` records the documented CSP availability floor; some ADMX policies predate their CSP exposure. It is a conservative floor for a new common gate, not proof the corresponding registry policy first appeared on that build. [Privacy applicability](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-privacy)

| ID | Original component under `DA` | Modern value under `APP` | CSP min | Primary applicability |
| --- | --- | --- | --- | --- |
| `windows.390a641655997ac5` | `{D89823BA-7180-4B81-B50C-7E471E6121A3}` | `LetAppsAccessCalendar` | 14393 | [Calendar](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-privacy#letappsaccesscalendar) |
| `windows.8094fa90aef667a2` | `{8BC668CF-7728-45BD-93F8-CF2B3B41D7AB}` | `LetAppsAccessCallHistory` | 14393 | [Call history](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-privacy#letappsaccesscallhistory) |
| `windows.27dceacfb5f3bad8` | `{E5323777-F976-4f5b-9B55-B94699C46E44}` | `LetAppsAccessCamera` | 14393 | [Camera](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-privacy#letappsaccesscamera) |
| `windows.f4f3fe6eec4af4da` | `{7D7E8402-7C54-4821-A34E-AEEFD62DED93}` | `LetAppsAccessContacts` | 14393 | [Contacts](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-privacy#letappsaccesscontacts) |
| `windows.e5bc23aaf240501d` | `{2297E4E2-5DBE-466D-A12B-0F8286F0D9CA}` | `LetAppsGetDiagnosticInfo` | 15063 | [App diagnostics](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-privacy#letappsgetdiagnosticinfo) |
| `windows.0ff20ccca85cc838` | `{9231CB4C-BF57-4AF3-8C55-FDA7BFCC04C5}` | `LetAppsAccessEmail` | 14393 | [Email](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-privacy#letappsaccessemail) |
| `windows.4f15b51618f19faa` | `LooselyCoupled` | `LetAppsSyncWithDevices` | 14393 | [Unpaired devices](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-privacy#letappssyncwithdevices) |
| `windows.7c7f075549bd661a` | `{992AFA70-6F47-4148-B3E9-3003349C1548}` | `LetAppsAccessMessaging` | 14393 | [Messaging](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-privacy#letappsaccessmessaging) |
| `windows.5da29a7625715500` | `{2EEF81BE-33FA-4800-9670-1CD474972C3F}` | `LetAppsAccessMicrophone` | 14393 | [Microphone](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-privacy#letappsaccessmicrophone) |
| `windows.7b6387fb0beb29cc` | `{52079E78-A92B-413F-B213-E8FE35712E72}` | `LetAppsAccessNotifications` | 15063 | [Notifications](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-privacy#letappsaccessnotifications) |
| `windows.64e2f577f966b91d` | `{E390DF20-07DF-446D-B962-F5C953062741}` | `LetAppsAccessTasks` | 15063 | [Tasks](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-privacy#letappsaccesstasks) |
| `windows.c2611ffceccdd511` | `{C1D23ACC-752B-43E5-8448-8D0E519CD6D6}` | `LetAppsAccessAccountInfo` | 14393 | [Account information](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-privacy#letappsaccessaccountinfo) |
| `windows.c0992e387472e78f` | `{A8804298-2D5F-42E3-9531-9C8C39EB29CE}` | `LetAppsAccessRadios` | 14393 | [Radio control](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-privacy#letappsaccessradios) |
| `windows.2666ea7030872d52` | `{BFA794E4-F964-4FDB-90F6-51056BFE4B44}` | `LetAppsAccessLocation` | 14393 | [Location](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-privacy#letappsaccesslocation) |

The recommended correction for every row is **provide the supported modern policy with its scope disclosed**, while keeping the original choice available as legacy intent if source fidelity is required. Mapping from an old GUID to the modern policy is based on the supplied setting's intent, not a newly verified Microsoft GUID migration table.

Per-app settings override the modern default; inspect `*_ForceAllowTheseApps`, `*_ForceDenyTheseApps`, and `*_UserInControlOfTheseApps` before claiming a universal result. Apps already open may need restarting. `0` is user control, not force allow. [Policy precedence and refresh](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-privacy#letappsaccesscalendar)

These controls do not establish that every traditional desktop application is denied all access. Camera/microphone desktop permission behavior and apps with direct hardware access have additional limits. App-diagnostics privacy controls also exclude ordinary desktop apps. [Desktop-app boundaries](https://support.microsoft.com/en-us/windows/privacy/windows-desktop-apps-and-privacy), [camera and microphone](https://support.microsoft.com/en-us/windows/privacy/windows-camera-microphone-and-privacy), [app diagnostics](https://support.microsoft.com/en-gb/windows/privacy/windows-app-diagnostics-and-privacy)

## Remaining nine records

| ID | Exact original target and choices | Finding on Windows 11 Pro 26200 | Recommended gate or prerequisite |
| --- | --- | --- | --- |
| `windows.097b68b347ea5404` | `HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced\TaskbarDa`, DWORD `0` / `1` | Widgets and its taskbar button remain supported. Current settings documentation is a **status-reading/data-portability reference**, and even describes a different serialized value shape; it is not a guarantee that this exact DWORD remains writable/effective. [Settings reference](https://learn.microsoft.com/en-us/windows/apps/develop/settings/settings-windows-11), [supported UI](https://support.microsoft.com/en-us/windows/experience/stay-up-to-date-with-news-and-interests) | Remove the claim that build 22621+ lacks the feature. For exact legacy writes, require a verified consumer/capability result. Offer `HKLM\SOFTWARE\Policies\Microsoft\Dsh\AllowNewsAndInterests` DWORD `0` / `1` on Pro build 22000+, with the broader device-wide Widgets scope explicit. [Widgets policy](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-newsandinterests#allownewsandinterests) |
| `windows.545d278a6e57e1c7` | `WIFI\FeatureStates`, masked DWORD: mask `0xffff0001`, value `0`, absent default `828` | Wi-Fi Sense was removed by Windows 10 1803. No first-party meaning for this exact mask/default was established. [Removal](https://learn.microsoft.com/en-us/windows/privacy/manage-connections-from-windows-operating-system-components-to-microsoft-services#23-wi-fi-sense) | Retain removed-feature execution status on 26200; selection may still be saved. The catalog's 10586 ceiling cannot be justified for every Wi-Fi Sense subfeature solely from full removal in 1803. No modern equivalent to this removed sharing service was identified. |
| `windows.88fe51b11c7ae2aa` | `WIFI\FeatureStates`, delete | A cleanup operation, not an effective Wi-Fi Sense setting on Windows 11. [Feature status](https://learn.microsoft.com/en-us/windows/privacy/manage-connections-from-windows-operating-system-components-to-microsoft-services#23-wi-fi-sense) | Remove the feature/build prerequisite for cleanup; require the correct SID and snapshot/conflict handling. This is a shared value also targeted by both masked rows, so deleting it is not equivalent to restoring either mask independently. |
| `windows.09d74e279714979c` | `WIFI\FeatureStates`, masked DWORD: mask `0xffff0040`, value `0`, absent default `828` | Contact credential sharing was removed in Windows 10 1607, so the original 10586 legacy ceiling is consistent with that removal. The exact mask remains undocumented in inspected first-party sources. [Credential-sharing removal](https://learn.microsoft.com/en-us/windows-hardware/customize/desktop/unattend/changed-answer-file-settings-for-previous-windows10-builds#windows-10-version-1607) | Keep the removed-feature effect restriction for 14393+; do not label a stored mask as a functioning Windows 11 sharing toggle. |
| `windows.7fa16c5ff56a179a` | `HKCU\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Sensor\Permissions\{BFA794E4-F964-4FDB-90F6-51056BFE4B44}\SensorPermissionState`, **REG_SZ** `0`; delete | No first-party contract was established for this exact type/value or its 16299 ceiling. Old unattended SensorPermissions settings were removed, but that does not by itself prove this registry value's retirement. [Removed unattended settings](https://learn.microsoft.com/en-us/windows-hardware/customize/desktop/unattend/changed-answer-file-settings-for-previous-windows10-builds#windows-10-version-1607) | Keep legacy effect unverified. For the supplied app-location intent offer `APP\LetAppsAccessLocation` on Pro; disclose machine scope and the duplicate target shared with the DeviceAccess location replacement. [Location policy](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-privacy#letappsaccesslocation) |
| `windows.ea8a48526956e77c` | `HKLM\SOFTWARE\Policies\Microsoft\Windows\Windows Search\ConnectedSearchUseWeb`, DWORD `0`; delete | Microsoft explicitly excludes Pro for `DoNotUseWebResults`, while listing Enterprise, Education, IoT Enterprise/LTSC and Windows 10 1803+. The template confirms `0` disables web queries and `1` permits them. [CSP contract](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-search#donotusewebresults), [ADMX mapping](https://www.microsoft.com/en-us/download/details.aspx?id=108542) | Retain Pro's unsupported-effect result; allow selection/cleanup. No contract-equivalent Pro replacement was verified. `DisableSearchBoxSuggestions` is documented for File Explorer query history, so its Pro support does not prove a supported Start/web-search substitute. [Separate Explorer policy](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-admx-windowsexplorer#disablesearchboxsuggestions) |
| `windows.69db91a7c17867c9` | `HKLM\SOFTWARE\Microsoft\PCHC\PreviousUninstall`, DWORD `1`; delete | KB5005463 installs PC Health Check on Windows 10 20H2+, and explicitly does not install it on Windows 11. The inspected article does not document this registry value as a supported installer-blocking interface. [KB5005463](https://support.microsoft.com/en-us/servicing/os/windows/2021/07/kb5005463-pc-health-check-application) | No matching Windows 11 Windows Update install action to block. Do not infer a universal app-install blocker from the value. Preserve legacy selection and permit exact cleanup; no modern equivalent is necessary for this update path. |
| `windows.04b6d7dda595eb7e` | `HKLM\SOFTWARE\Policies\Microsoft\Windows\Windows Feeds\EnableFeeds`, DWORD `0`; delete | Feeds CSP explicitly lists Windows 11 unsupported for every edition; Windows 10 Pro/Business/Enterprise/Education are listed. Its policy values are `0` disabled, `1` allowed. [Feeds applicability](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-feeds) | Keep this original operation Windows-10-specific. Offer the separately labeled Windows 11 Widgets policy if that matches intent; it is not the same target. [Widgets](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-newsandinterests#allownewsandinterests) |
| `windows.681b49e3861a2c3a` | `HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Feeds\ShellFeedsTaskbarViewMode`, DWORD `2` / `0` | The supported Windows 11 UI controls Widgets, while Windows 10 has the older Feeds control. No current first-party contract was found for this exact registry operation or its 19044 ceiling. [Microsoft UI distinction](https://support.microsoft.com/en-us/windows/experience/stay-up-to-date-with-news-and-interests) | Keep legacy effect unverified on 26200; do not widen the cap as proof. Offer Windows 11's actual Widgets control, explicitly separating hiding a user taskbar button from disabling the whole device's Widgets experience. |

The current `Search.admx` still gives `DoNotUseWebResults` a `WinBlueOnly` support reference, while the current CSP lists later Enterprise-family Windows versions. That metadata discrepancy is recorded rather than resolved by assuming all editions work. Both sources leave Pro unsupported for a claimed current effect. The supplied catalog's Server edition entries were not validated by the client CSP and should remain a separate explicit unknown.

The current Widgets CSP also lists newer `DisableWidgetsBoard`/lock-screen/feed policies as Insider-only. Build number 26200 alone does not establish Insider membership or feature rollout. The stable replacement proposed here is `AllowNewsAndInterests`, not those preview policies. [Widgets policy applicability](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-newsandinterests)

## Existing modern catalog controls

These IDs were resolved from `backend/catalogs/windows-tweaks.json` by exact registry value and hive. Reuse these controls; do not add another writer for the same policy. The mappings connect related intents and are not authorization to silently apply a broader policy.

| Legacy ID | Existing modern ID(s) | Scope or meaning change |
| --- | --- | --- |
| `windows.e62dbec0b81d06ff` | `windows.d261f7a6d03a12dc` | User scope retained; current diagnostics intent |
| `windows.c075970f84ec328b` | `windows.4852ffda155a5221` | Same hive; merges separate diagnostic intents |
| `windows.ffb1454675fe0bab` | `windows.49d76828a1fab446` | Same hive; merges separate diagnostic intents |
| `windows.8c7083a823121bf9` | `windows.3bcf54d03a596e7e`, `windows.5e0a51ace80cd71e`, `windows.a0f0376664a7f854`, `windows.f0f38d011623934f` | User scope retained; four distinct controls |
| `windows.67492e826e19151c` | `windows.4852ffda155a5221` | Same hive; merges separate diagnostic intents |
| `windows.7c8b9bf95199812d` | `windows.49d76828a1fab446` | Same hive; merges separate diagnostic intents |
| `windows.097b68b347ea5404` | `windows.1685f7eddddce555` | Entire device Widgets; broader than button visibility |
| `windows.390a641655997ac5` | `windows.be67257ae643130f` | HKCU per-user preference to HKLM machine policy |
| `windows.8094fa90aef667a2` | `windows.1d1c29f00646cf6d` | HKCU per-user preference to HKLM machine policy |
| `windows.27dceacfb5f3bad8` | `windows.3b7506aee9968d0e` | HKCU per-user preference to HKLM machine policy |
| `windows.f4f3fe6eec4af4da` | `windows.e0b7a561e07c8967` | HKCU per-user preference to HKLM machine policy |
| `windows.e5bc23aaf240501d` | `windows.441f950c394a9816` | HKCU per-user preference to HKLM machine policy |
| `windows.0ff20ccca85cc838` | `windows.f141a691cb4d08a1` | HKCU per-user preference to HKLM machine policy |
| `windows.4f15b51618f19faa` | `windows.1d5804d97f121868` | HKCU per-user preference to HKLM machine policy |
| `windows.7c7f075549bd661a` | `windows.87d0b67905984a8c` | HKCU per-user preference to HKLM machine policy |
| `windows.5da29a7625715500` | `windows.fdc84180952cce98` | HKCU per-user preference to HKLM machine policy |
| `windows.7b6387fb0beb29cc` | `windows.d416ee4bae8ba18f` | HKCU per-user preference to HKLM machine policy |
| `windows.64e2f577f966b91d` | `windows.16a03834f6220999` | HKCU per-user preference to HKLM machine policy |
| `windows.c2611ffceccdd511` | `windows.882d304d8d3d810b` | HKCU per-user preference to HKLM machine policy |
| `windows.c0992e387472e78f` | `windows.ad3e95d5a579ca29` | HKCU per-user preference to HKLM machine policy |
| `windows.2666ea7030872d52` | `windows.502838d154ef3c8b` | HKCU per-user preference to HKLM machine policy |
| `windows.545d278a6e57e1c7` | None verified | None verified |
| `windows.88fe51b11c7ae2aa` | None verified | None verified |
| `windows.09d74e279714979c` | None verified | None verified |
| `windows.7fa16c5ff56a179a` | `windows.502838d154ef3c8b` | HKCU per-user preference to HKLM machine policy |
| `windows.ea8a48526956e77c` | None verified | None verified |
| `windows.69db91a7c17867c9` | None verified | None verified |
| `windows.04b6d7dda595eb7e` | `windows.1685f7eddddce555` | Machine scope retained; Windows 11 Widgets target |
| `windows.681b49e3861a2c3a` | `windows.1685f7eddddce555` | Entire device Widgets; broader than button visibility |

The existing AppPrivacy controls offer DWORD `2` and delete. Their delete choice restores user control; it does not force allow with `1`. Therefore the original per-user `Allow` option is not equivalent to selecting the modern control's delete option. Both legacy location rows map to one modern location policy; each pair of legacy Edge diagnostic intents maps to one modern policy per hive.

Related catalog mismatches discovered during mapping, recorded without changing product code:

- `windows.1685f7eddddce555` starts at 22621, while the authoritative Widgets policy includes 22000. Lowering this **existing modern policy's** minimum to 22000 is supported by primary evidence; it does not establish that TaskbarDa writes work on 26200. [Widgets contract](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-newsandinterests#allownewsandinterests)
- `windows.4852ffda155a5221` and `windows.49d76828a1fab446` contain Edge requirements beginning at 77; the machine row also has an alternative without a product requirement. The current Windows DiagnosticData contract begins at Edge 122. This affects claims of an applied effect on older/missing Edge, not whether a choice can be saved. [DiagnosticData contract](https://learn.microsoft.com/en-us/deployedge/microsoft-edge-policies/DiagnosticData)
- Existing Office connected-experience targets contain `{office-major-version}`. The inspected Microsoft contract supplies `16.0`; a resolved target must match the applicable Office product before an effect is claimed. [Office registry contract](https://learn.microsoft.com/en-us/microsoft-365-apps/privacy/manage-privacy-controls#control-privacy-settings-by-editing-the-registry)

## Machine-readable recommendations

This is a research mapping, not an executable migration. `modern_intent` means a different registry contract or scope that must be represented explicitly. `selectable: true` applies to every record. A cleanup option, where present, should not inherit the consumer's version/edition gate. `legacy_effect` describes documentation confidence on the target, not the success of a live test.

```json
{
  "target": {
    "windowsBuild": 26200,
    "edition": "Professional"
  },
  "selectable": true,
  "cleanupRequiresConsumerSupport": false,
  "modernAppPolicyRoot": "HKLM\\Software\\Policies\\Microsoft\\Windows\\AppPrivacy",
  "modernAppValues": {
    "userControl": 0,
    "forceAllow": 1,
    "forceDeny": 2
  },
  "records": [
    {"id": "windows.e62dbec0b81d06ff", "legacy_effect": "product_variant_required", "correction": "identify_legacy_ceip_consumer", "modern_intent": "Office.SendTelemetry", "existingModernIds": ["windows.d261f7a6d03a12dc"], "scopeOrMeaningChange": "User scope retained; current diagnostics intent"},
    {"id": "windows.c075970f84ec328b", "legacy_effect": "obsolete_after_edge_88", "legacyEdgeMin": 77, "legacyEdgeMax": 88, "modern_intent": "Edge.DiagnosticData", "modernEdgeMin": 122, "scope": "machine", "existingModernIds": ["windows.4852ffda155a5221"], "scopeOrMeaningChange": "Same hive; merges separate diagnostic intents"},
    {"id": "windows.ffb1454675fe0bab", "legacy_effect": "obsolete_after_edge_88", "legacyEdgeMin": 77, "legacyEdgeMax": 88, "modern_intent": "Edge.DiagnosticData", "modernEdgeMin": 122, "scope": "user", "existingModernIds": ["windows.49d76828a1fab446"], "scopeOrMeaningChange": "Same hive; merges separate diagnostic intents"},
    {"id": "windows.8c7083a823121bf9", "legacy_effect": "ignored_m365_enterprise_1904_plus", "correction": "identify_office_product_and_version", "modern_intent": "Office.connected_experiences", "existingModernIds": ["windows.3bcf54d03a596e7e", "windows.5e0a51ace80cd71e", "windows.a0f0376664a7f854", "windows.f0f38d011623934f"], "scopeOrMeaningChange": "User scope retained; four distinct controls"},
    {"id": "windows.67492e826e19151c", "legacy_effect": "obsolete_after_edge_88", "legacyEdgeMin": 77, "legacyEdgeMax": 88, "modern_intent": "Edge.DiagnosticData", "modernEdgeMin": 122, "scope": "machine", "existingModernIds": ["windows.4852ffda155a5221"], "scopeOrMeaningChange": "Same hive; merges separate diagnostic intents"},
    {"id": "windows.7c8b9bf95199812d", "legacy_effect": "obsolete_after_edge_88", "legacyEdgeMin": 77, "legacyEdgeMax": 88, "modern_intent": "Edge.DiagnosticData", "modernEdgeMin": 122, "scope": "user", "existingModernIds": ["windows.49d76828a1fab446"], "scopeOrMeaningChange": "Same hive; merges separate diagnostic intents"},
    {"id": "windows.097b68b347ea5404", "legacy_effect": "exact_write_unverified", "correction": "retain_exact_write_uncertainty_reuse_supported_widgets_policy", "modern_intent": "Dsh.AllowNewsAndInterests", "modernMinBuild": 22000, "modernScope": "machine", "existingModernIds": ["windows.1685f7eddddce555"], "scopeOrMeaningChange": "Entire device Widgets; broader than button visibility"},
    {"id": "windows.390a641655997ac5", "legacy_effect": "unverified", "modern_intent": "LetAppsAccessCalendar", "modernCspMinBuild": 14393, "existingModernIds": ["windows.be67257ae643130f"], "scopeOrMeaningChange": "HKCU per-user preference to HKLM machine policy"},
    {"id": "windows.8094fa90aef667a2", "legacy_effect": "unverified", "modern_intent": "LetAppsAccessCallHistory", "modernCspMinBuild": 14393, "existingModernIds": ["windows.1d1c29f00646cf6d"], "scopeOrMeaningChange": "HKCU per-user preference to HKLM machine policy"},
    {"id": "windows.27dceacfb5f3bad8", "legacy_effect": "unverified", "modern_intent": "LetAppsAccessCamera", "modernCspMinBuild": 14393, "existingModernIds": ["windows.3b7506aee9968d0e"], "scopeOrMeaningChange": "HKCU per-user preference to HKLM machine policy"},
    {"id": "windows.f4f3fe6eec4af4da", "legacy_effect": "unverified", "modern_intent": "LetAppsAccessContacts", "modernCspMinBuild": 14393, "existingModernIds": ["windows.e0b7a561e07c8967"], "scopeOrMeaningChange": "HKCU per-user preference to HKLM machine policy"},
    {"id": "windows.e5bc23aaf240501d", "legacy_effect": "unverified", "modern_intent": "LetAppsGetDiagnosticInfo", "modernCspMinBuild": 15063, "existingModernIds": ["windows.441f950c394a9816"], "scopeOrMeaningChange": "HKCU per-user preference to HKLM machine policy"},
    {"id": "windows.0ff20ccca85cc838", "legacy_effect": "unverified", "modern_intent": "LetAppsAccessEmail", "modernCspMinBuild": 14393, "existingModernIds": ["windows.f141a691cb4d08a1"], "scopeOrMeaningChange": "HKCU per-user preference to HKLM machine policy"},
    {"id": "windows.4f15b51618f19faa", "legacy_effect": "unverified", "modern_intent": "LetAppsSyncWithDevices", "modernCspMinBuild": 14393, "existingModernIds": ["windows.1d5804d97f121868"], "scopeOrMeaningChange": "HKCU per-user preference to HKLM machine policy"},
    {"id": "windows.7c7f075549bd661a", "legacy_effect": "unverified", "modern_intent": "LetAppsAccessMessaging", "modernCspMinBuild": 14393, "existingModernIds": ["windows.87d0b67905984a8c"], "scopeOrMeaningChange": "HKCU per-user preference to HKLM machine policy"},
    {"id": "windows.5da29a7625715500", "legacy_effect": "unverified", "modern_intent": "LetAppsAccessMicrophone", "modernCspMinBuild": 14393, "existingModernIds": ["windows.fdc84180952cce98"], "scopeOrMeaningChange": "HKCU per-user preference to HKLM machine policy"},
    {"id": "windows.7b6387fb0beb29cc", "legacy_effect": "unverified", "modern_intent": "LetAppsAccessNotifications", "modernCspMinBuild": 15063, "existingModernIds": ["windows.d416ee4bae8ba18f"], "scopeOrMeaningChange": "HKCU per-user preference to HKLM machine policy"},
    {"id": "windows.64e2f577f966b91d", "legacy_effect": "unverified", "modern_intent": "LetAppsAccessTasks", "modernCspMinBuild": 15063, "existingModernIds": ["windows.16a03834f6220999"], "scopeOrMeaningChange": "HKCU per-user preference to HKLM machine policy"},
    {"id": "windows.c2611ffceccdd511", "legacy_effect": "unverified", "modern_intent": "LetAppsAccessAccountInfo", "modernCspMinBuild": 14393, "existingModernIds": ["windows.882d304d8d3d810b"], "scopeOrMeaningChange": "HKCU per-user preference to HKLM machine policy"},
    {"id": "windows.c0992e387472e78f", "legacy_effect": "unverified", "modern_intent": "LetAppsAccessRadios", "modernCspMinBuild": 14393, "existingModernIds": ["windows.ad3e95d5a579ca29"], "scopeOrMeaningChange": "HKCU per-user preference to HKLM machine policy"},
    {"id": "windows.2666ea7030872d52", "legacy_effect": "unverified", "modern_intent": "LetAppsAccessLocation", "modernCspMinBuild": 14393, "existingModernIds": ["windows.502838d154ef3c8b"], "scopeOrMeaningChange": "HKCU per-user preference to HKLM machine policy"},
    {"id": "windows.545d278a6e57e1c7", "legacy_effect": "feature_removed", "removedByBuild": 17134, "modern_intent": null, "existingModernIds": []},
    {"id": "windows.88fe51b11c7ae2aa", "legacy_effect": "cleanup_only", "correction": "remove_build_gate_for_exact_cleanup", "requiresResolvedUserSid": true, "existingModernIds": []},
    {"id": "windows.09d74e279714979c", "legacy_effect": "feature_removed", "removedByBuild": 14393, "modern_intent": null, "existingModernIds": []},
    {"id": "windows.7fa16c5ff56a179a", "legacy_effect": "type_and_effect_unverified", "modern_intent": "LetAppsAccessLocation", "modernCspMinBuild": 14393, "existingModernIds": ["windows.502838d154ef3c8b"], "scopeOrMeaningChange": "HKCU per-user preference to HKLM machine policy"},
    {"id": "windows.ea8a48526956e77c", "legacy_effect": "edition_unsupported", "correction": "retain_pro_effect_restriction", "modern_intent": null, "existingModernIds": []},
    {"id": "windows.69db91a7c17867c9", "legacy_effect": "update_does_not_target_windows_11", "registryContract": "unverified", "modern_intent": null, "existingModernIds": []},
    {"id": "windows.04b6d7dda595eb7e", "legacy_effect": "windows_10_only", "modern_intent": "Dsh.AllowNewsAndInterests", "modernMinBuild": 22000, "modernScope": "machine", "existingModernIds": ["windows.1685f7eddddce555"], "scopeOrMeaningChange": "Machine scope retained; Windows 11 Widgets target"},
    {"id": "windows.681b49e3861a2c3a", "legacy_effect": "unverified_on_windows_11", "modern_intent": "Dsh.AllowNewsAndInterests_broader_than_button", "exactModernRegistryWrite": "unverified", "existingModernIds": ["windows.1685f7eddddce555"], "scopeOrMeaningChange": "Entire device Widgets; broader than button visibility"}
  ]
}
```

## Verification remaining for implementation

All 29 input IDs are accounted for. Exact modern AppPrivacy, Widgets, Office legacy, and Search value mappings were checked in the first-party templates. Product behavior on the named machine remains pending.

Before recording an applied effect, use a controlled fixture or explicitly authorized reversible check of the consuming surface: Edge effective policy, Office account-privacy state, Windows app permission result, or actual Widgets/taskbar behavior. Include a blocking competing policy or per-app exception, the initiating-user identity, and exact restoration. For removed or edition-inapplicable features, an honest unsupported/not-applicable result is required even when the selection and registry cleanup remain available.

The unverified areas are the original DeviceAccess GUID contracts, exact current TaskbarDa/ShellFeeds writes, SensorPermissionState type/effect, Wi-Fi FeatureStates masks, PreviousUninstall's installer contract, current qmenable product coverage, and a contract-equivalent Pro web-search replacement. No statement in this report turns those unknowns into supported behavior.
