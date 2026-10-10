# Windows setting labels and value meanings

Captured 2026-09-19 against the generated `2026-09-19.2` catalog snapshot containing 883 settings. The catalog's generic mapping of source `apply` to **Disabled**, and source default/undo to **Enabled**, produces incorrect choices. Source direction describes what the source tool's button does; it does not establish the resulting Windows feature state.

This audit produced exact-target presentation proposals in the private `presentation-overrides.json`: **345 target overrides, 340 fully resolved targets, five partially resolved targets, and 538 explicitly unresolved targets**. There are 644 proposed value-label changes, including neutral deletion wording. Counts describe semantic review, not apply/restore execution. No product compiler, catalog or UI was edited by this audit.

## Matching and recovery contract

Overrides match registry **hive, view, full key path, value name, selector, and token name or bitmask where present**. Native controls match **kind, target and property**. Choices match the complete typed payload. A string `"1"` and DWORD `1` are different assignments. Two tokens inside the same string are separate settings; changing either must preserve the other token.

Deletion is labeled **Remove this override**. This deletes the selected local assignment; another policy, application preference or Windows default determines the subsequent effective state. It does not mean Enabled, Disabled, factory default, or restore the user's original value. Exact restoration remains a separate operation that uses the saved existence, type, data and ownership history. This follows the registry deletion contract and the independently captured vendor reset operations. [RegDeleteValue](https://learn.microsoft.com/en-us/windows/win32/api/winreg/nf-winreg-regdeletevaluew), [WPD audit](wpd-settings.md), [WinUtil source](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/config/tweaks.json).

The private output retains old setting/option IDs only as diagnostic references. They must not substitute for target and typed-value matching because generated IDs or source names can change. It also retains unknown choices with literal review descriptions; those descriptions are not a claim of understood feature behavior and should not become ordinary On/Off controls.

## Confirmed errors and replacements

| Exact setting/value | Current misleading wording | Value-specific wording |
| --- | --- | --- |
| AppPrivacy `LetApps…=0/1/2` | Boolean source-direction labels | User chooses / Allow all apps / Block all apps |
| Windows `AllowTelemetry=0/1/3` | Disabled / Enabled | Off on supported editions / Required / Optional |
| Office `SendTelemetry=1/2/3` | Disabled / Enabled | Required / Optional / Neither |
| Edge `NetworkPredictionOptions=0/1/2` | Boolean labels | Allowed on any network / Legacy value treated as any network / Off |
| Edge `BrowserSignin=0/1/2` | Boolean labels | Blocked / Allowed / Required |
| Edge local AI model `0/1` | Boolean labels | Download allowed / Download blocked |
| `AppsUseLightTheme` and `SystemUsesLightTheme` `0/1` | Reversed Dark Theme choices | Dark / Light |
| `HideFileExt=0/1` | Potential inverse Boolean naming | Show / Hide |
| Explorer `Hidden=1/2` | Source Enabled/Disabled | Show / Hide |
| `DynamicScrollbars=0/1` | Scrollbars Always Visible inversion | Always show / Hide when idle |
| `DisplayParameters=1` | Disabled | Show crash details |
| `VerboseStatus=1` | Disabled | Detailed sign-in messages on |
| `ShellSmartScreenLevel="Warn"` | Disabled | Warn |
| `AUOptions=2` | Disabled | Notify before downloading |
| Feature-update delay `365` | Disabled | 365 days |
| `AllowOptionalContent=3` | Disabled | User chooses optional updates |
| `DODownloadMode=0/3` | Disabled / Enabled | HTTP only without peers / Internet peers |
| Boot `disabledynamictick=true` | Enabled | Dynamic timer ticks disabled |

App-permission values are defined in the Microsoft policy contract, including per-app exceptions and app restart requirements. Default denial cannot be called universal denial when a per-app allow override exists. Background spatial perception is currently HoloLens 2 only, and graphics-capture policies require Windows 11. [Privacy CSP](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-privacy).

Windows diagnostic data level zero has edition restrictions; it is not a promise of no diagnostic traffic on Pro/Home. Office's Neither choice does not stop required service data. [Windows diagnostic policy](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-system#allowtelemetry), [Office privacy policy](https://learn.microsoft.com/en-us/microsoft-365-apps/privacy/manage-privacy-controls).

The exact Edge enums and Boolean meanings were checked against 47 captured Microsoft policy pages. The output includes policy version ranges, deprecated/obsolete markers, personal Microsoft-account profile exclusions and browser restart requirements where documented. In particular, a policy title can itself contain misleading historical wording: `NewTabPageBingChatEnabled` has a title beginning with “Disable”, but its documented true value retains Chat links and false removes them. Captions therefore follow value-specific behavior rather than the title's leading verb. [Bing Chat links](https://learn.microsoft.com/en-us/deployedge/microsoft-edge-policies/newtabpagebingchatenabled), [network prediction](https://learn.microsoft.com/en-us/deployedge/microsoft-edge-policies/networkpredictionoptions), [sign-in](https://learn.microsoft.com/en-us/deployedge/microsoft-edge-policies/browsersignin), [local AI model](https://learn.microsoft.com/en-us/deployedge/microsoft-edge-policies/genailocalfoundationalmodelsettings).

File Explorer, theme and scrollbar mappings are confirmed by the pinned source controls rather than inferred from the integer. The source record for FSOS-X Hidden Files uses `1/2`, while WinUtil's undo uses `0`. That disagreement is preserved as an unresolved choice, not hidden by a convenient label. [FSOS-X source package](https://fsosx.com/FSOS-XR11H2.apbx), [WinUtil toggle definitions](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/config/tweaks.json).

Windows Update enum choices and related enablement values were resolved from matching Windows 26200 ADMX and English ADML, alongside Microsoft policy documentation. The records distinguish policy enablement, numeric selection, durations and notification behavior. For example, `AllowOptionalContent=3` requires the associated policy to be enabled; changing that child value alone does not establish the effective policy. [Update CSP](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-update#allowoptionalcontent), [Delivery Optimization CSP](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-deliveryoptimization#dodownloadmode).

## Source contradictions

WPD writes `DisableCustomerImprovementProgram=0` for its off operation. Microsoft's Internet Explorer policy makes zero require participation, while one blocks participation. WPD also writes `DisableQueryRemoteServer=0` for its MSDT off operation; the independent restriction is one. These are source disagreements requiring an explicit implementation decision, not justification to show the written value as Disabled. [Internet Explorer policy](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-internetexplorer#disablecustomerexperienceimprovementprogramparticipation), [MSDT policy](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-admx-msdt#msdtsupportprovider), [exact WPD facts](wpd-settings.md).

The pinned WinUtil Activity History bundle writes `EnableActivityFeed=1` alongside `PublishUserActivities=0` and `UploadUserActivities=0`. The individual feed atom must therefore be labeled as allowed; a bundle title containing Disable does not change that atom's meaning. The combined effective behavior depends on all three policies. [Pinned bundle](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/config/tweaks.json#L2), [activity policy](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-privacy#enableactivityfeed).

CSP numeric values must not be copied directly onto a mapped registry name without checking the mapping. `AllowTailoredExperiencesWithDiagnosticData` is positive-polarity CSP terminology; its registry policy `DisableTailoredExperiencesWithDiagnosticData` uses the opposite disabling polarity. Matching Microsoft ADMX confirms the registry operation, while CSP text describes the feature behavior. [Experience CSP](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-experience#allowtailoredexperienceswithdiagnosticdata).

## Native controls

Service startup choices use the actual startup enumeration: Boot and System apply to drivers, followed by Automatic, Manual and Disabled. Running/stopped is a separate state. Delayed automatic startup is also separate and requires the appropriate startup mode. Friendly names should come from the exact service's SCM DisplayName rather than reusing a source bundle name such as Bluetooth for multiple services. [Service configuration](https://learn.microsoft.com/en-us/windows/win32/api/winsvc/nf-winsvc-changeserviceconfigw).

Scheduled task Enabled means eligible for triggers, not currently running. Boot hypervisor `Auto/Off` is not equivalent to installing/removing the Hyper-V feature. Dynamic-tick overrides are explicitly timer/debugging settings; no FPS improvement is established by labeling them. Native NTFS choices describe timestamp updates rather than an abstract optimization. [Task enabled state](https://learn.microsoft.com/en-us/windows/win32/api/taskschd/nf-taskschd-iregisteredtask-put_enabled), [boot options](https://learn.microsoft.com/en-us/windows-hardware/drivers/devtest/bcdedit--set), [NTFS behavior](https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/fsutil-behavior).

The graphics options `SwapEffectUpgradeEnable` and `VRROptimizeEnable` are separately matched tokens in `DirectXUserGlobalSettings`; the pinned FSOS-X control identifies their on/off writes. Restart the affected game after changing windowed optimizations. Auto HDR can enable that feature, and per-game overrides can affect the result. The registry token's presence alone does not establish GPU/display/game support. [Microsoft graphics guidance](https://support.microsoft.com/en-us/windows/hardware/display-graphics/optimizations-for-windowed-games-in-windows-11), [FSOS-X package](https://fsosx.com/FSOS-XR11H2.apbx).

WPD blocklist controls should say Block listed addresses and identify the list/date. “Telemetry disabled” and “Windows Update disabled” would overstate a rule matching an old set of destinations. The override names the three address groups and preserves their list53 date, 2022-05-22. [WPD list payload](https://wpd.app/get/update).

## Explicitly unresolved cases

Five targets have useful labels for some choices but unresolved alternatives:

- `MouseSpeed`, `MouseThreshold1`, and `MouseThreshold2`: the catalog contains both the FSOS-X string values and WinUtil DWORD variants. Same-looking values do not prove the DWORD variant is honored.
- Explorer `Hidden=0`: the pinned sources disagree; the documented/source-confirmed Show/Hide pair is `1/2`.
- `AllowOptionalContent=0`: zero is absent from the captured registry policy enum, which defines `1/2/3`. Disabling the companion policy is a different operation.

The remaining 538 targets have no complete value-specific semantic override from this bounded pass. This includes vendor/device-specific registry values, driver properties, undocumented flags, arbitrary bitfields, version-sensitive source leftovers, and policies whose exact platform meaning has not yet been confirmed. Every target is retained with its exact payload and source references. Unknown does not mean ineffective or forbidden; it means the UI must not invent a feature-state claim.

The next semantic work should prioritize the actual supported choices intended for user exposure. For each unknown, obtain the matching platform/device contract or isolate a controlled effective-state check. A source variable name or an apparent Boolean is insufficient. Missing reset semantics must use captured-original restoration rather than guessed default values.

## Validation and artifacts

The audit checks account for all 883 unique catalog setting IDs, require sources on every proposed override, preserve typed value/token identity, and assert that deletion choices use neutral wording. Every Microsoft enum caption is bound to its ADMX policy and ADMX/ADML file hashes. No runtime effectiveness or recovery claim was inferred from these checks.

Private artifacts are under `<private work folder>/four-tool-tweaks-20260919/`: `presentation-overrides.json`, the immutable `presentation-catalog-snapshot.json`, the four pinned source inventories, and captured ADMX/ADML. The output's snapshot hash binds these findings to the reviewed catalog; regenerate/reconcile after changes to choices or targets.
