# WPD settings and independent Windows mappings

Captured 2026-09-19. This accounts for **110 fixed setting controls: 102 documented switches and eight experimental controls**, plus documented application controls, dynamic installed-app operations and custom constructor settings. It is **not** a claim of complete runtime parity. The pinned executable was inspected as data with trusted ILSpy 9.1.0.7988 to recover factual registrations and provider operations; it was not run. Proprietary implementation bodies are not copied into the repository. No Windows settings were changed by this audit. The tables distinguish documented Windows targets from unresolved behavior.

## Source identity

The official site identifies **1.5.2042 RC 1** and an address-list date of **2022-05-22**. The downloaded ZIP is 342,794 bytes and matches the published SHA-256 `8c9105cc81ac94f291a8d18b4ac0a88b51488bf49aa9a076490b1c42aacabe09`. It contains the executable and three data/documentation files; it is not merely a link or empty bootstrap archive. [Product](https://wpd.app/), [published checksum](https://wpd.app/download/), [package](https://wpd.app/get/latest.zip).

| Member | Bytes | SHA-256 |
| --- | ---: | --- |
| `Constructor.json` | 1,360 | `eb2e7ba7b20c5c8ce5fd43bf2c0637c141ad139451b8bb0229d1eaa1b93f2da1` |
| `Localization.json` | 472,825 | `7e82e1cd00be3f4f9a3cccb0f004f55e685cabf14efc271e2c4ca55fb178b492` |
| `README.txt` | 10,108 | `8eb699fa039771643ba4c7de547e5458fcf146e04077ff5358d0c03d61345f98` |
| `WPD.exe` | 590,336 | `c21e9de5b28de8edfb6b2264b33846e842f7954ad70fa07b3c652feb5f0a09d7` |

PE version strings identify `1.5.2042` and assembly `1.5.2042.0`. `Constructor.json` supplies custom Group Policy, service, scheduled-task and registry examples. `README.txt` agrees with the online list of 102 switches. Static setup registrations identify the eight additional controls as `Pro1` through `Pro8`. Every fixed setup registration is now accounted for. [Official package](https://wpd.app/get/latest.zip), [arguments](https://wpd.app/docs/arguments/).

The independent mappings below use Microsoft documentation and Microsoft ADMX files copied read-only from the verified 9070XT, build 26200. The private machine inventory records the matching policy name, source-file hash and declared scope. ADMX availability establishes a policy definition, not that an obsolete component exists or honors it on that build.

## Coverage and limits

| Source group | Switches |
| --- | ---: |
| Local Group Policy | 17 |
| MS Office Local Group Policy | 3 |
| Microsoft Edge (Chromium) Local Group Policy | 6 |
| Services | 5 |
| Task Scheduler | 13 |
| Advanced Local Group Policy | 10 |
| Advanced App Permissions | 24 |
| Advanced Services | 7 |
| Miscellaneous | 4 |
| Windows Update | 10 |
| Blocker | 3 |
| Experimental | 8 |

There are also 29 documented CLI entries, including argument forms with optional values. They cover application behavior, tab loading, presets, state export, restore-point creation, firewall selection and per-switch selection. These are controls, not 29 more Windows tweaks. WPD's Apps page is an installed-package operation, and its custom-switch constructor is open-ended. Neither has a finite universal machine-independent list. The private inventory retains these boundaries explicitly. [Arguments](https://wpd.app/docs/arguments/), [requirements](https://wpd.app/docs/), [official screenshot](https://wpd.app/assets/img/mainwindow.png).

The tables give independent Windows targets. Each private inventory row now also has a `vendorControl` containing the source-specific WPD registration, off/default operations, availability and linked effects. `vendor-static-mapped` establishes static source behavior, not current OS effectiveness or executed parity. No entry is automatically selected or execution-verified.

## Registry mapping

All values below are `REG_DWORD`. The desired values express the particular privacy/restriction choice, not the original state or a restore constant. Native Windows policy access should resolve the 64-bit view; user identity and Office architecture must be verified separately. A key name alone cannot resolve effective Group Policy precedence.

### Local Group Policy

| WPD identifier | Independent target and value | Evidence/status |
| --- | --- | --- |
| `CEIPEnable` | `HKLM\SOFTWARE\Policies\Microsoft\SQMClient\Windows\CEIPEnable` = `0` | [vendor-static-mapped](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-admx-icm#ceipenable) |
| `DisableCustomerImprovementProgram` | `HKLM\Software\Policies\Microsoft\Internet Explorer\SQM\DisableCustomerImprovementProgram` = `1` | [vendor-static-mapped](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-internetexplorer#disablecustomerexperienceimprovementprogramparticipation) |
| `CEIP` | `HKLM\SOFTWARE\Policies\Microsoft\Messenger\Client\CEIP` = `2` | [vendor-static-mapped](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-admx-icm#internetmanagement-restrictcommunication-2) |
| `AllowCortana` | `HKLM\SOFTWARE\Policies\Microsoft\Windows\Windows Search\AllowCortana` = `0` | [vendor-static-mapped](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-experience#allowcortana) |
| `AllowSearchToUseLocation` | `HKLM\SOFTWARE\Policies\Microsoft\Windows\Windows Search\AllowSearchToUseLocation` = `0` | [vendor-static-mapped](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-search#allowsearchtouselocation) |
| `WindowsErrorReporting` | `HKLM\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting\Disabled` = `1` | [vendor-static-mapped](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-errorreporting#disablewindowserrorreporting) |
| `DisableUAR` | `HKLM\SOFTWARE\Policies\Microsoft\Windows\AppCompat\DisableUAR` = `1` | [vendor-static-mapped](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-admx-appcompat#appcompatturnoffuseractionrecord) |
| `DisableInventory` | `HKLM\SOFTWARE\Policies\Microsoft\Windows\AppCompat\DisableInventory` = `1` | [vendor-static-mapped](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-admx-appcompat#appcompatturnoffprograminventory) |
| `AllowTelemetry` | `HKLM\SOFTWARE\Policies\Microsoft\Windows\DataCollection\AllowTelemetry` = `1` | [vendor-static-mapped](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-system#allowtelemetry) |
| `RestrictImplicitCollection` | `HKLM\SOFTWARE\Policies\Microsoft\InputPersonalization\RestrictImplicitTextCollection` = `1`<br>`HKLM\SOFTWARE\Policies\Microsoft\InputPersonalization\RestrictImplicitInkCollection` = `1` | [vendor-static-mapped](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-admx-globalization#implicitdatacollectionoff_2) |
| `AllowInputPersonalization` | `HKLM\SOFTWARE\Policies\Microsoft\InputPersonalization\AllowInputPersonalization` = `0` | [vendor-static-mapped](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-privacy#allowinputpersonalization) |
| `AllowLinguisticDataCollection` | `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\TextInput\AllowLinguisticDataCollection` = `0` | [vendor-static-mapped](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-textinput#allowlinguisticdatacollection) |
| `ScenarioExecutionEnabled` | `HKLM\SOFTWARE\Policies\Microsoft\Windows\WDI\{9c5a40da-b965-4fc3-8781-88dd50a6299d}\ScenarioExecutionEnabled` = `0` | [vendor-static-mapped](https://wpd.app/get/latest.zip) |
| `DisableQueryRemoteServer` | `HKLM\SOFTWARE\Policies\Microsoft\Windows\ScriptedDiagnosticsProvider\Policy\DisableQueryRemoteServer` = `1` | [vendor-static-mapped](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-admx-msdt#msdtsupportprovider) |
| `AdvertisingInfo` | `HKLM\SOFTWARE\Policies\Microsoft\Windows\AdvertisingInfo\DisabledByGroupPolicy` = `1` | [vendor-static-mapped](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-privacy#disableadvertisingid) |
| `DisableContentFileUpdates` | `HKLM\SOFTWARE\Policies\Microsoft\SearchCompanion\DisableContentFileUpdates` = `1` | [vendor-static-mapped](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-admx-icm#searchcompanion-disablefileupdates) |
| `DisableWindowsConsumerFeatures` | `HKLM\SOFTWARE\Policies\Microsoft\Windows\CloudContent\DisableWindowsConsumerFeatures` = `1` | [vendor-static-mapped](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-experience#allowwindowsconsumerfeatures) |

### MS Office Local Group Policy

| WPD identifier | Independent target and value | Evidence/status |
| --- | --- | --- |
| `qmenable` | `HKCU\SOFTWARE\Policies\Microsoft\Office\16.0\Common\qmenable` = `0` | [vendor-static-mapped](https://learn.microsoft.com/en-us/microsoft-365-apps/privacy/manage-privacy-controls) |
| `sendtelemetry` | `HKCU\SOFTWARE\Policies\Microsoft\Office\Common\ClientTelemetry\sendtelemetry` = `3` | [vendor-static-mapped](https://learn.microsoft.com/en-us/microsoft-365-apps/privacy/manage-privacy-controls) |
| `sendcustomerdata` | `HKCU\SOFTWARE\Policies\Microsoft\Office\16.0\Common\sendcustomerdata` = `0` | [vendor-static-mapped](https://learn.microsoft.com/en-us/microsoft-365-apps/privacy/manage-privacy-controls) |

### Microsoft Edge (Chromium) Local Group Policy

| WPD identifier | Independent target and value | Evidence/status |
| --- | --- | --- |
| `AddressBarMicrosoftSearchInBingProviderEnabled` | `HKCU\SOFTWARE\Policies\Microsoft\Edge\AddressBarMicrosoftSearchInBingProviderEnabled` = `0` | [vendor-static-mapped](https://learn.microsoft.com/en-us/deployedge/microsoft-edge-policies/AddressBarMicrosoftSearchInBingProviderEnabled) |
| `AlternateErrorPagesEnabled` | `HKCU\SOFTWARE\Policies\Microsoft\Edge\AlternateErrorPagesEnabled` = `0` | [vendor-static-mapped](https://learn.microsoft.com/en-us/deployedge/microsoft-edge-policies/AlternateErrorPagesEnabled) |
| `AutofillAddressEnabled` | `HKCU\SOFTWARE\Policies\Microsoft\Edge\AutofillAddressEnabled` = `0` | [vendor-static-mapped](https://learn.microsoft.com/en-us/deployedge/microsoft-edge-policies/AutofillAddressEnabled) |
| `AutofillCreditCardEnabled` | `HKCU\SOFTWARE\Policies\Microsoft\Edge\AutofillCreditCardEnabled` = `0` | [vendor-static-mapped](https://learn.microsoft.com/en-us/deployedge/microsoft-edge-policies/AutofillCreditCardEnabled) |
| `NetworkPredictionOptions` | `HKCU\SOFTWARE\Policies\Microsoft\Edge\NetworkPredictionOptions` = `2` | [vendor-static-mapped](https://learn.microsoft.com/en-us/deployedge/microsoft-edge-policies/NetworkPredictionOptions) |
| `PersonalizationReportingEnabled` | `HKCU\SOFTWARE\Policies\Microsoft\Edge\PersonalizationReportingEnabled` = `0` | [vendor-static-mapped](https://learn.microsoft.com/en-us/deployedge/microsoft-edge-policies/PersonalizationReportingEnabled) |

### Advanced Local Group Policy

| WPD identifier | Independent target and value | Evidence/status |
| --- | --- | --- |
| `PublishUserActivities` | `HKLM\SOFTWARE\Policies\Microsoft\Windows\System\PublishUserActivities` = `0` | [vendor-static-mapped](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-privacy#publishuseractivities) |
| `UploadUserActivities` | `HKLM\SOFTWARE\Policies\Microsoft\Windows\System\UploadUserActivities` = `0` | [vendor-static-mapped](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-privacy#uploaduseractivities) |
| `EnableActivityFeed` | `HKLM\SOFTWARE\Policies\Microsoft\Windows\System\EnableActivityFeed` = `0` | [vendor-static-mapped](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-privacy#enableactivityfeed) |
| `AllowClipboardHistory` | `HKLM\SOFTWARE\Policies\Microsoft\Windows\System\AllowClipboardHistory` = `0` | [vendor-static-mapped](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-experience#allowclipboardhistory) |
| `AllowCrossDeviceClipboard` | `HKLM\SOFTWARE\Policies\Microsoft\Windows\System\AllowCrossDeviceClipboard` = `0` | [vendor-static-mapped](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-privacy#allowcrossdeviceclipboard) |
| `AllowDeviceNameInTelemetry` | `HKLM\SOFTWARE\Policies\Microsoft\Windows\DataCollection\AllowDeviceNameInTelemetry` = `0` | [vendor-static-mapped](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-system#allowdevicenameindiagnosticdata) |
| `DisableSettingSync` | `HKLM\SOFTWARE\Policies\Microsoft\Windows\SettingSync\DisableSettingSync` = `2` | [vendor-static-mapped](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-admx-settingsync#disablesettingsync) |
| `DisableFileSyncNGSC` | `HKLM\SOFTWARE\Policies\Microsoft\Windows\OneDrive\DisableFileSyncNGSC` = `1` | [vendor-static-mapped](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-system#disableonedrivefilesync) |
| `DisableAntiSpyware` | `HKLM\SOFTWARE\Policies\Microsoft\Windows Defender\DisableAntiSpyware` = `1` | [vendor-static-mapped](https://learn.microsoft.com/en-us/windows-hardware/customize/desktop/unattend/security-malware-windows-defender-disableantispyware) |
| `EnableSmartScreen` | `HKLM\SOFTWARE\Policies\Microsoft\Windows\System\EnableSmartScreen` = `0` | [vendor-static-mapped](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-smartscreen#enablesmartscreeninshell) |

### Advanced App Permissions

| WPD identifier | Independent target and value | Evidence/status |
| --- | --- | --- |
| `LetAppsAccessAccountInfo` | `HKLM\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy\LetAppsAccessAccountInfo` = `2` | [vendor-static-mapped](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-privacy#letappsaccessaccountinfo) |
| `LetAppsAccessCalendar` | `HKLM\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy\LetAppsAccessCalendar` = `2` | [vendor-static-mapped](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-privacy#letappsaccesscalendar) |
| `LetAppsAccessCallHistory` | `HKLM\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy\LetAppsAccessCallHistory` = `2` | [vendor-static-mapped](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-privacy#letappsaccesscallhistory) |
| `LetAppsAccessCamera` | `HKLM\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy\LetAppsAccessCamera` = `2` | [vendor-static-mapped](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-privacy#letappsaccesscamera) |
| `LetAppsAccessContacts` | `HKLM\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy\LetAppsAccessContacts` = `2` | [vendor-static-mapped](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-privacy#letappsaccesscontacts) |
| `LetAppsAccessEmail` | `HKLM\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy\LetAppsAccessEmail` = `2` | [vendor-static-mapped](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-privacy#letappsaccessemail) |
| `LetAppsAccessGazeInput` | `HKLM\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy\LetAppsAccessGazeInput` = `2` | [vendor-static-mapped](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-privacy#letappsaccessgazeinput) |
| `LetAppsAccessLocation` | `HKLM\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy\LetAppsAccessLocation` = `2` | [vendor-static-mapped](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-privacy#letappsaccesslocation) |
| `LetAppsAccessMessaging` | `HKLM\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy\LetAppsAccessMessaging` = `2` | [vendor-static-mapped](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-privacy#letappsaccessmessaging) |
| `LetAppsAccessMicrophone` | `HKLM\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy\LetAppsAccessMicrophone` = `2` | [vendor-static-mapped](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-privacy#letappsaccessmicrophone) |
| `LetAppsAccessMotion` | `HKLM\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy\LetAppsAccessMotion` = `2` | [vendor-static-mapped](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-privacy#letappsaccessmotion) |
| `LetAppsAccessNotifications` | `HKLM\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy\LetAppsAccessNotifications` = `2` | [vendor-static-mapped](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-privacy#letappsaccessnotifications) |
| `LetAppsAccessPhone` | `HKLM\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy\LetAppsAccessPhone` = `2` | [vendor-static-mapped](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-privacy#letappsaccessphone) |
| `LetAppsAccessRadios` | `HKLM\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy\LetAppsAccessRadios` = `2` | [vendor-static-mapped](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-privacy#letappsaccessradios) |
| `LetAppsAccessTasks` | `HKLM\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy\LetAppsAccessTasks` = `2` | [vendor-static-mapped](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-privacy#letappsaccesstasks) |
| `LetAppsAccessTrustedDevices` | `HKLM\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy\LetAppsAccessTrustedDevices` = `2` | [vendor-static-mapped](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-privacy#letappsaccesstrusteddevices) |
| `LetAppsGetDiagnosticInfo` | `HKLM\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy\LetAppsGetDiagnosticInfo` = `2` | [vendor-static-mapped](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-privacy#letappsgetdiagnosticinfo) |
| `LetAppsRunInBackground` | `HKLM\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy\LetAppsRunInBackground` = `2` | [vendor-static-mapped](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-privacy#letappsruninbackground) |
| `LetAppsSyncWithDevices` | `HKLM\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy\LetAppsSyncWithDevices` = `2` | [vendor-static-mapped](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-privacy#letappssyncwithdevices) |
| `LetAppsActivateWithVoice` | `HKLM\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy\LetAppsActivateWithVoice` = `2` | [vendor-static-mapped](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-privacy#letappsactivatewithvoice) |
| `LetAppsActivateWithVoiceAboveLock` | `HKLM\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy\LetAppsActivateWithVoiceAboveLock` = `2` | [vendor-static-mapped](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-privacy#letappsactivatewithvoiceabovelock) |
| `LetAppsAccessBackgroundSpatialPerception` | `HKLM\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy\LetAppsAccessBackgroundSpatialPerception` = `2` | [vendor-static-mapped](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-privacy#letappsaccessbackgroundspatialperception) |
| `LetAppsAccessGraphicsCaptureProgrammatic` | `HKLM\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy\LetAppsAccessGraphicsCaptureProgrammatic` = `2` | [vendor-static-mapped](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-privacy#letappsaccessgraphicscaptureprogrammatic) |
| `LetAppsAccessGraphicsCaptureWithoutBorder` | `HKLM\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy\LetAppsAccessGraphicsCaptureWithoutBorder` = `2` | [vendor-static-mapped](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-privacy#letappsaccessgraphicscapturewithoutborder) |

### Miscellaneous

| WPD identifier | Independent target and value | Evidence/status |
| --- | --- | --- |
| `ShowSyncProviderNotifications` | `HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced\ShowSyncProviderNotifications` = `0` | [vendor-static-mapped](https://wpd.app/get/latest.zip) |
| `TailoredExperiencesWithDiagnosticDataEnabled` | `HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Privacy\TailoredExperiencesWithDiagnosticDataEnabled` = `0` | [vendor-static-mapped](https://wpd.app/get/latest.zip) |
| `StartTrackProgs` | `HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced\Start_TrackProgs` = `0` | [vendor-static-mapped](https://wpd.app/get/latest.zip) |
| `HttpAcceptLanguageOptOut` | `HKCU\Control Panel\International\User Profile\HttpAcceptLanguageOptOut` = `1` | [vendor-static-mapped](https://wpd.app/get/latest.zip) |

The app-permission policies are choices: user control `0`, force allow `1`, force deny `2`. Their per-package exceptions affect the result and must be detected alongside the default. Microsoft documents build and edition requirements individually; the private inventory records the minimum builds from those sections. In particular, the capture controls require Windows 11 and background spatial perception is limited to HoloLens 2. They must not be offered as effective universal desktop switches. [Privacy policy contracts](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-privacy).

Several apparent Boolean settings are not Boolean. Messenger CEIP uses `2` to disable participation in the Microsoft ICM policy. Settings synchronization uses `DisableSettingSync=2`; its separate `DisableSettingSyncUserOverride` determines whether the user can enable it again. The handwriting policy has both user and machine variants. Roo Industries must preserve each selected scope and companion value rather than merge by label. [ICM policies](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-admx-icm), [SettingSync policy](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-admx-settingsync#disablesettingsync), [handwriting policy](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-admx-globalization#implicitdatacollectionoff_2).

Windows diagnostic data `0` is restricted to Enterprise, Education and Server; `1` is required data and `3` optional data. The consumer-experiences policy excludes Pro in its current Microsoft contract. These are availability checks, not reasons to claim a no-op write succeeded. [System policy](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-system#allowtelemetry), [consumer experiences](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-experience#allowwindowsconsumerfeatures).

`DisableAntiSpyware` is a retired consumer setting with documented ignored/protected cases. It must not become a green "Defender disabled" indicator based on a registry readback. The Office personal-information policy has no effect on Microsoft 365 Apps from version 1904; the replacement connected-experience choices are distinct settings. Office `SendTelemetry=3` does not stop required service data. [Defender contract](https://learn.microsoft.com/en-us/windows-hardware/customize/desktop/unattend/security-malware-windows-defender-disableantispyware), [Office contracts](https://learn.microsoft.com/en-us/microsoft-365-apps/privacy/manage-privacy-controls).

Static registration inspection now confirms the exact PerfTrack, miscellaneous preference and legacy Office CEIP writes/resets. PerfTrack is explicitly excluded on Windows 11 by WPD. Their current OS/application effect still requires applicability and readback verification; source constants are not performance evidence.

## Services and tasks

The independent service choice is disabled startup plus stopped state. The target names below come from WPD documentation/package identifiers; the provider contract is Microsoft's Service Control Manager. A missing service is unavailable. Per-user templates and live user instances need separate identity, original state and recovery. [Service configuration API](https://learn.microsoft.com/en-us/windows/win32/api/winsvc/nf-winsvc-changeserviceconfigw), [per-user services](https://learn.microsoft.com/en-us/windows/application-management/per-user-services-in-windows).

| WPD identifier | Service identity | Scope |
| --- | --- | --- |
| `DiagTrack` | `DiagTrack` | Machine |
| `dhscs` | `diagnosticshub.standardcollector.service` | Machine |
| `dmwappushservice` | `dmwappushservice` | Machine |
| `DcpSvc` | `DcpSvc` | Machine |
| `WMPNetworkSvc` | `WMPNetworkSvc` | Machine |
| `CDPUserSvc` | `CDPUserSvc` | User template and selected instance |
| `OneSyncSvc` | `OneSyncSvc` | User template and selected instance |
| `PimIndexMaintenanceSvc` | `PimIndexMaintenanceSvc` | User template and selected instance |
| `UnistoreSvc` | `UnistoreSvc` | User template and selected instance |
| `UserDataSvc` | `UserDataSvc` | User template and selected instance |
| `MessagingService` | `MessagingService` | User template and selected instance |
| `WpnUserService` | `WpnUserService` | User template and selected instance |
| `wuauserv` | `wuauserv` | Machine |
| `WaaSMedicSvc` | `WaaSMedicSvc` | Machine |
| `UsoSvc` | `UsoSvc` | Machine |

The task target is `Enabled=false` through Task Scheduler, with its previous enabled state retained. Full paths below are confirmed by WPD setup registrations, but task presence has not been tested on every OS. WPD-specific ACL and TaskCache side effects are recorded in the static findings below. Protected-task failures must be surfaced; modifying TaskCache registry entries or ACLs is not a substitute for the documented provider. [Task enabled property](https://learn.microsoft.com/en-us/windows/win32/api/taskschd/nf-taskschd-iregisteredtask-put_enabled), [package evidence](https://wpd.app/get/latest.zip).

| WPD identifier | Full task path |
| --- | --- |
| `Consolidator` | `\Microsoft\Windows\Customer Experience Improvement Program\Consolidator` |
| `KernelCeipTask` | `\Microsoft\Windows\Customer Experience Improvement Program\KernelCeipTask` |
| `UsbCeip` | `\Microsoft\Windows\Customer Experience Improvement Program\UsbCeip` |
| `BthSQM` | `\Microsoft\Windows\Customer Experience Improvement Program\BthSQM` |
| `SqmTasks` | `\Microsoft\Windows\PI\Sqm-Tasks` |
| `BackgroundUploadTask` | `\Microsoft\Windows\SettingSync\BackgroundUploadTask` |
| `Proxy` | `\Microsoft\Windows\Autochk\Proxy` |
| `MCA` | `\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser` |
| `ProgramDataUpdater` | `\Microsoft\Windows\Application Experience\ProgramDataUpdater` |
| `AitAgent` | `\Microsoft\Windows\Application Experience\AitAgent` |
| `DiskDiagnosticDataCollector` | `\Microsoft\Windows\DiskDiagnostic\Microsoft-Windows-DiskDiagnosticDataCollector` |
| `GatherNetworkInfo` | `\Microsoft\Windows\NetTrace\GatherNetworkInfo` |
| `DeviceCensus` | `\Microsoft\Windows\Device Information\Device` |
| `WaaSMedicTask` | `\Microsoft\Windows\WaaSMedic\PerformRemediation` |
| `ScheduledStart` | `\Microsoft\Windows\WindowsUpdate\Scheduled Start` |
| `ScheduleScan` | `\Microsoft\Windows\UpdateOrchestrator\Schedule Scan` |
| `ScheduleScanStaticTask` | `\Microsoft\Windows\UpdateOrchestrator\Schedule Scan Static Task` |
| `ScheduleWakeToWork` | `\Microsoft\Windows\UpdateOrchestrator\Schedule Wake To Work` |
| `ScheduleWork` | `\Microsoft\Windows\UpdateOrchestrator\Schedule Work` |

The separate `WUGP` control maps to `HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\DisableWindowsUpdateAccess=1`. This is a legacy access policy, not proof that modern update servicing is fully disabled. It must remain distinct from update services, tasks and address blocking. [Microsoft ICM definition](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-admx-icm#removewindowsupdate-icm).

## Network blockers

The public update payload contains address-list version **53**, dated **2022-05-22**, with SHA-256 `0fb1b0e5b9c161314efc860e72099888db12a4b891beb1f4871f2c08273d67ae`. The data was downloaded directly and parsed without running WPD. [Official payload](https://wpd.app/get/update).

| WPD switch | Payload list | Raw entries | Unique raw entries | Collapsed IP/CIDR networks |
| --- | --- | ---: | ---: | ---: |
| `bTelemetry` | `TelemetryList` | 167 | 167 | 158 |
| `bExtra` | `ExtraList` | 965 | 964 | 867 |
| `bUpdate` | `UpdateList` | 374 | 374 | 325 |

Range parsing and address-family-aware interval collapse found no intersection between these three pinned groups. One raw duplicate occurs within Extra. This is a reproducible property of these bytes, not a statement about current Microsoft endpoints. A modern rule catalog needs separately reviewed updates; this old list cannot establish current coverage or absence of collateral blocking.

WPD publishes its provider, sublayer and filter GUIDs, and documents Windows Firewall/WFP route choices. These are WPD-owned identities: Roo Industries needs its own provider/rule ownership. Static inspection confirms outbound enabled block rules through Windows Firewall. Its code does not explicitly set protocol/profile fields. The WFP branch creates persistent remote-IPv4 block filters at `FWPM_LAYER_ALE_AUTH_CONNECT_V4`, without application/protocol conditions. Runtime filtering and effective precedence remain untested. The native implementation should retain Windows Firewall, install only explicit owned rules, detect disabled firewall/policy restrictions, and remove only the owned rules on recovery. [WPD WFP documentation](https://wpd.app/docs/wfp/).

## Application controls and unresolved static candidates

- App arguments: `-help`, `-install`, `-install "all"`, `-multipleInstances`, `-nosplash`, `-nowarnOS`, `-proxy`, `-locale`, `-restorePoint`, `-dumpRules`, `-dumpRules "Path"`, `-wfpOnly`, `-saveState`, `-close`.
- Tab arguments: `-reg4gp`, `-pro`, `-showAppxErrors`, `-noMOcheck`, `-nofw`, `-noappx`.
- Button arguments: `-default`, `-privacyAll`, `-recommended`, `-privacy ""`, `-revert ""`.
- Advanced Button arguments: `-security`, `-includeAdv`, `-defender ""`, `-wfp ""`.

All eight experimental identities are now resolved from setup and helper operations. They are gated by `-pro`; custom constructor registrations occur after the same gate. The table below records their actual off/on effects. [Official package](https://wpd.app/get/latest.zip), [documented experimental argument](https://wpd.app/docs/arguments/).

App removal must use actual package identities, dependencies and removability facts. A package reinstall is not restoration of prior application data. Custom constructor switches should use the same typed target validation and conflict engine, with each custom target explicitly reviewed; supporting the constructor format must not imply approval to execute arbitrary targets. These are implementation requirements derived from the requested exact recovery and deduplication behavior, not copied WPD implementation.

## Source-specific operation findings

The following facts come from the pinned [official package](https://wpd.app/get/latest.zip), inspected statically. `vendor-facts.json` contains 107 parsed Privacy setup registrations, each with scope, parameters, minimum Windows/release-ID filters, excluded OS values, panel and automation membership. The separate three network controls bring fixed coverage to 110. Every registration has both off and on/default operation facts. CLI presets reference these existing controls; they are not duplicate implementations.

### Experimental controls

| ID | Control | Off action | On/default action |
| --- | --- | --- | --- |
| `Pro1` | Take ownership menu | Remove HKCR `*\shell\TakeOwnership` and `Directory\shell\TakeOwnership` trees | Register menu/command values; invoking the menu elevates ownership and grants owner-rights SID full control for the selected target. Directory form is recursive and has explicit system-directory exclusions. |
| `Pro2` | Inking and typing personalization | HKCU `Software\Microsoft\InputPersonalization`: `RestrictImplicitInkCollection=1`, `RestrictImplicitTextCollection=1`; `TrainedDataStore\HarvestContacts=0`; `Software\Microsoft\Personalization\Settings\AcceptedPrivacyPolicy=0` | Write `0, 0, 1, 1` respectively. All DWORD. |
| `Pro3` | Messaging cloud sync | HKCU `SOFTWARE\Microsoft\Messaging\CloudServiceSyncEnabled` DWORD `0` | DWORD `1` |
| `Pro4` | Snipping Tool banner | HKCU `SOFTWARE\Microsoft\Windows\TabletPC\Snipping Tool\IsScreenSketchBannerExpanded` DWORD `0` | DWORD `1` |
| `Pro5` | Suggested Wi-Fi hotspots | HKLM `Software\Microsoft\wcmsvc\wifinetworkmanager\config\AutoConnectAllowedOEM` DWORD `0` through policy provider | Delete policy value |
| `Pro6` | Network connectivity checks | HKLM `Software\Policies\Microsoft\Windows\NetworkConnectivityStatusIndicator\NoActiveProbe` DWORD `1` | Delete policy value |
| `Pro7` | Notification Center | HKCU `Software\Policies\Microsoft\Windows\Explorer\DisableNotificationCenter` DWORD `1` | Delete policy value |
| `Pro8` | Toast notifications | HKCU `SOFTWARE\Policies\Microsoft\Windows\CurrentVersion\PushNotifications\NoToastApplicationNotification` DWORD `1` | Delete policy value |

`Pro1` is feature-on rather than privacy-off. Its destructive tree removal is not an acceptable substitute for restoring the original keys. The native control should register only owned values and restore the original key/value/ACL facts. Actual ownership changes occur when the user invokes the installed menu, and require their own recoverability statement.

### Differences that affect native integration

| Source behavior | Consequence for Roo Industries |
| --- | --- |
| WPD's IE CEIP off value is `DisableCustomerImprovementProgram=0`; its MSDT off value is `DisableQueryRemoteServer=0`. | These conflict with the intended restriction documented by Microsoft. The independent mappings above use `1`, and the source difference must remain recorded. |
| All six Edge policies use the User section, not Machine. WPD requires HKCU BLBeacon major version >=77 to register them. | Preserve HKCU/SID scope; do not turn them into machine policy silently. |
| WPD defaults to a local Group Policy object and saves it; `-reg4gp` switches to direct registry values. On/default deletes policy entries rather than writing an opposite constant. Exit requests `GPUpdate.exe /force` after policy changes. | A direct-registry implementation is a distinct provider route. Bind local policy state, effective value and scope when claiming GPO parity; restore captured originals. |
| Missing ordinary preference values are created during UI setup for four miscellaneous controls and `Pro3`/`Pro4`. | Detection in Roo Industries must remain non-mutating. Offer explicit default choices instead of writing while loading a page. |
| WPD hides the telemetry level choices on Pro/Home/Core; the hidden-choice off path writes `0`. | Honor Windows edition semantics: do not claim telemetry is fully off on unsupported editions. |
| User-service off writes the selected instance plus `ControlSet001` base template. Its on path writes only the base template using a raw default code, including `OneSyncSvc=1`. | Restore original active-control-set/template/instance facts, not the vendor's raw constant or whichever prefix match appears first. |
| Several task controls alter executable permissions and terminate matching image names. | These side effects require separate named actions; setting Task Scheduler Enabled=false alone is not full source parity. |
| Six task controls patch byte 42 in TaskCache's binary Triggers value after temporary ownership/access changes. | Do not copy undocumented binary offsets into an ordinary task executor. Use the supported task API and report rejected/unsupported operations precisely. |
| Some registry writes swallow exceptions; AppX removal starts a deployment operation without awaiting its completion. | Native status must derive from actual readback and final deployment result, not the source's optimistic return value. |

The IE and MSDT comparison uses [Microsoft Internet Explorer policy](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-internetexplorer#disablecustomerexperienceimprovementprogramparticipation) and [MSDT policy](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-admx-msdt#msdtsupportprovider). These source discrepancies are not reasons to weaken independent verification.

The task-linked executable effects are: `Consolidator` → `System32\wsqmcons.exe`; `MCA` → `System32\compattelrunner.exe` and `System32\compattel\DiagTrackRunner.exe`; `AitAgent` → `System32\aitagent.exe`; `DeviceCensus` → `System32\devicecensus.exe`. Off terminates the image and adds a World SID deny-execute ACE; on removes that ACE. WPD temporarily takes ownership and then restores the previous owner, without preserving a complete original ACL snapshot.

The raw TaskCache cases are `BackgroundUploadTask`, `WaaSMedicTask`, `ScheduleScan`, `ScheduleScanStaticTask`, `ScheduleWakeToWork`, and `ScheduleWork`. The first uses off/on bytes `0/192`; the others `2/66`. These are factual source constants, not a supported Windows schema contract. The inventory retains the exact task-to-key resolution and flags the difference from the native Task Scheduler route.

### Provider defaults and non-setting actions

Service defaults used by WPD are listed below. They describe its on/default button, not correct recovery for an existing machine. Code `1` is automatic delayed through WPD's service helper; `2` is automatic; `3` manual. The per-user reset branch writes its raw code to the template Start value instead of using that helper.

| Service identifier | Default code | Start if stopped |
| --- | ---: | --- |
| `DiagTrack` | 2 | true |
| `dhscs` | 3 | false |
| `dmwappushservice` | 3 | false |
| `DcpSvc` | 3 | false |
| `WMPNetworkSvc` | 3 | false |
| `CDPUserSvc` | 2 | true |
| `OneSyncSvc` | 1 | true |
| `PimIndexMaintenanceSvc` | 3 | false |
| `UnistoreSvc` | 3 | false |
| `UserDataSvc` | 3 | false |
| `MessagingService` | 3 | false |
| `WpnUserService` | 2 | true |
| `wuauserv` | 3 | false |
| `WaaSMedicSvc` | 3 | false |
| `UsoSvc` | 1 | true |

The embedded offline IP data is separately pinned: version **52**, date **2021-09-28**, 166 telemetry entries, 831 extra entries and 359 update entries. `embedded-blocker-addresses.json` retains those literals. The update endpoint's version 53 data is not the same as the executable's fallback; a native profile must identify which list it uses.

Static AppX behavior is current-user main-package enumeration, excluding framework packages, configured blacklist entries and install locations outside `WindowsApps`. Selected removal uses package full names. The UI's restore link opens the WPD website; it does not reconstruct removed packages or data. Roo Industries must reuse its own package inventory/recovery contract and await actual deployment completion.

Creating a restore point also creates `SystemRestorePointCreationFrequency=0` in HKLM if absent before calling the SystemRestore WMI provider. WPD installation adds `WPD_DIR` and a PATH entry for the selected user/machine scope. These application actions are separate from privacy tweaks; Roo Industries should reuse its own packaging and recovery providers.

## Independent implementation and acceptance

One atom should represent each registry value, service configuration, full task identity or owned address rule. Source labels and presets reference those atoms. The same desired atom shares ownership; conflicting desired values require a user choice; releasing one preset leaves other owners intact. Preserve the first exact original snapshot until the final owner releases it.

For policies, detect build/edition/component support and higher-precedence or per-app overrides before claiming an effect. For user targets, bind to the intended user's SID rather than the helper's HKCU. For service/task operations, use provider reads and exact identity. A successful write establishes stored state only; display separate pending restart or effective-state limits where required.

Review must show the actual target, intended value, applicable scope and recovery consequence. Tests must exercise missing values, non-default types, identical/contradictory selections, overlapping presets, outside changes, failed middle steps, restart/recovery, and duplicate application. The native write test already approved for the tweak engine does not authorize new production policies, services, firewall rules or package removals.

Private evidence is at `/home/serviroo/.local/share/LeanClientOptimizer/work/four-tool-tweaks-20260919/wpd/`: `inventory.json`, `vendor-facts.json`, `blocker-addresses.json`, `embedded-blocker-addresses.json`, `package-manifest.json`, captured first-party pages, package data and reproducible extraction/normalization scripts. The inventory's `executionVerified` remains false for every row. Read-only audit completion is distinct from native implementation, UI integration and real apply/restore verification.
