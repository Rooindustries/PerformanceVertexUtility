# Four-tool completion audit

Audit date: 2026-09-19. Scope: pinned O&O ShutUp10 and WPD controls, their auxiliary features, and the shared four-tool coverage denominator. Source inspection only; no frontend inspection, product edits or Windows mutations.

**The 632 fixed records do not establish complete four-tool coverage.** The compiler visits each source file's `records` array but does not consume O&O `linkedEffects`/`otherFeatures`, WPD `otherFeatures`, or several WPD `providerSemantics`. A passing fixed-count check therefore cannot detect these omissions. The development documentation correctly distinguishes catalog counts from executed behavior, but individual generated `implemented` labels still overstate some source bundles.

Private actionable corrections: `/home/serviroo/.local/share/LeanClientOptimizer/work/four-tool-tweaks-20260919/coverage-audit/coverage-corrections.json`. Each correction is keyed by product, source ID and zero-based variant; input hashes identify the audited snapshot. It retains 486 source records' original constraints/evidence plus linked and dynamic features. No new proprietary implementation body is introduced.

## Snapshot and denominator

| Product | Fixed records | What the count covers |
| --- | ---: | --- |
| O&O ShutUp10 3.5.1130.0 | 376 | 365 IDs plus OS-specific registration variants |
| WPD 1.5.2042 RC 1 | 110 | 102 documented switches plus eight experimental controls |
| FSOS-X Dash 2.4.9 | 79 | Statically registered tuning controls |
| WinUtil fc60cbde | 67 | Configuration entries, including some buttons and selectors |

At capture, the generated catalog contained 1,005 resources and 1,239 presets. Coverage options were 1,236 `implemented`, 13 `pending-executor`, eight `guided-action`, six `partial`, six `guided-action-with-settings`, and six `no-independent-change`. Counts must be recomputed after integration, not retained as permanent completion criteria.

Relevant local surfaces are `tools/catalogs/compile_windows_tweaks.py`, `tools/validation/check_windows_tweaks.py`, `backend/catalogs/windows-tweak-coverage.json`, `backend/catalogs/windows-tweak-actions.json`, and pinned `backend/catalogs/sources/*.json`.

## Findings requiring normalization or implementation

### 1. O&O linked Edge DNS policy is unaccounted

The pinned package binds 48 machine-Edge records to an aggregate callback that writes `HKLM\SOFTWARE\Policies\Microsoft\Edge:DnsOverHttpsMode` as String `automatic` when any relevant machine-Edge setting is enabled, otherwise deletes it. Legacy `E011`/`E012` are registered later and do not themselves receive the callback. The generated catalog has no corresponding DNS-mode resource; the affected rows can nevertheless say implemented. [Pinned O&O package](https://dl5.oo-software.com/files/ooshutup10/OOSU10.exe), [Microsoft DNS mode contract](https://learn.microsoft.com/en-us/deployedge/microsoft-edge-policies/dnsoverhttpsmode).

Normalize this to one explicit shared Edge DNS mode control with original-state recovery. Include its source relationship in coverage and reviewed presets. Do not silently turn the vendor's aggregate reset into deletion of a pre-existing user's value. A deliberate omission must be visible as a scope decision rather than disappearing from the denominator.

### 2. Product gates and evidence are lost

The normalized O&O source has 98 records whose `evidence` is an array of dictionary field names such as `policy`, `url` and `registryPath`, rather than the original evidence objects. Restore those objects. O&O Edge minimum/maximum major versions, installed-product requirements, Microsoft-account profile restrictions, obsolete/deprecated state, the remote-session exclusion and action-level edition gates also need preservation.

Examples: `E116`/`E216` and `E117`/`E217` have a vendor maximum Edge major 87; `E128`/`E228` require 99; `M027` excludes remote sessions; both `W010` variants restrict one driver-update policy to particular editions while retaining the separate fallback value. Browser-version applicability is distinct from Windows build applicability. [Edge metrics policy](https://learn.microsoft.com/en-us/deployedge/microsoft-edge-policies/metricsreportingenabled), [sidebar policy](https://learn.microsoft.com/en-us/deployedge/microsoft-edge-policies/hubssidebarenabled), [per-profile restriction example](https://learn.microsoft.com/en-us/deployedge/microsoft-edge-policies/configuredonottrack).

For WPD, preserve its six Edge controls' HKCU `BLBeacon\version >= 77` gate and its Office/experimental gates. The direct-registry policy route is an intentional alternative to WPD's default local-GPO provider; a successful registry write does not prove effective local or domain-policy behavior. [WPD provider selection](https://wpd.app/docs/arguments/).

### 3. O&O AI removal has three separate outcomes

The source exposes grouped AI settings, installed-app removal and Recall-data removal. The private static inventory identifies 39 AI-group registrations by `WindowsAI` category or `IsUsingAI`; the group can reuse existing atoms. It is not merely the 14 settings in the WindowsAI category. Existing source-specific settings therefore do not establish that the source's combined AI flow exists. [O&O AI feature contract](https://manuals.oo-software.com/ooshutup10/en/docs/common-features/ai-removal/).

The action catalog's Copilot route is currently linked only to WinUtil's `WPFTweaksWindowsAI`. It does not account for O&O's separate feature ID. Existing backend AppX inventory and removal use the current user's context; they do not establish O&O's other-user/machine-wide scope. Reuse shared app-removal infrastructure while preserving exact package/user identities and desktop exclusions. A removed current-user package is not proof that all users' registrations or provisioning were removed. [Package removal scopes](https://learn.microsoft.com/en-us/uwp/api/windows.management.deployment.packagemanager.removepackageasync?view=winrt-26100).

O&O's static selectors include `Microsoft.Windows.Ai.Copilot`, `Microsoft.Copilot`, Office Hub, desktop Copilot names and a `Copilot CLI` exclusion. A broad search result is not an approved package identity. The source's Recall erasure targets the initiating user's `CoreAIPlatform.00` directory and is irreversible. It needs a separately reviewed file manifest, exact user/path binding, link handling and truthful removal results. The source data is present in `otherFeatures`, but no catalog action currently accounts for it.

### 4. Two Recall policies themselves have irreversible data effects

`AllowRecallEnablement=0` removes the component's bits and deletes existing snapshots; component removal requires restart. `DisableAIDataAnalysis=1` also deletes existing snapshots. Restoring either policy value cannot restore those files. Mark this by atomic target/value across every source, not only O&O IDs `C204`, `C103`, and `C203`. Policy permission to record also does not create the user's required opt-in. [Microsoft Recall enablement](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-windowsai#allowrecallenablement), [Microsoft snapshot policy](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-windowsai#disableaidataanalysis).

This is a data-effect distinction even when the policy write and registry restore work correctly. A universal “reversible settings” statement would be false for these choices.

### 5. WPD task side effects are reduced to notes

`Consolidator`, `MCA`, `AitAgent` and `DeviceCensus` have linked executable ACL changes and process termination. The normalized records describe these only in notes, while coverage marks their task-only operations implemented. Five executable targets are recorded in the correction artifact. Native task disabling is useful but does not reproduce denying launch through other entry points. [Pinned WPD package](https://wpd.app/get/latest.zip), [documented task enabled property](https://learn.microsoft.com/en-us/windows/win32/api/taskschd/nf-taskschd-iregisteredtask-put_enabled).

Keep separate reviewed controls for task state, current process termination and executable access if those behaviors are retained. Replacing WPD's undocumented TaskCache byte patches with Task Scheduler APIs is an appropriate functional normalization, but source coverage must name that decision and verification boundary. Do not copy offsets or temporary ownership changes merely to reproduce a vendor implementation detail.

### 6. WPD features outside the fixed switches

| Feature | Existing fact | Required shared representation |
| --- | --- | --- |
| Installed-app removal | Dynamic current-user main-package inventory with framework/blacklist/location filters | Link an exact package selection to the app-removal executor; await deployment completion and verify absence. |
| Custom constructor | Open-ended GPO/service/task/registry definitions | Typed validated import into shared atoms; not an invented finite list and not arbitrary script execution. |
| Global Firewall controls | Enable/disable profile states, with service actions in the source | Separate reviewed per-profile state and original-state recovery; block-list rules are not this control. |
| Restore point | WMI creation plus a frequency value if missing | Shared creation action with actual result; merely opening System Protection is navigation. |
| Recommended/all/default presets | Compositions over existing switches and blocker groups | Preset membership and choices must be explicit; avoid duplicate executors. |
| State/rule export and app CLI options | App administration and packaging behavior | Reuse native export/preset facilities where offered; classify splash/locale/WPD PATH installation as app behavior outside Windows tweaks. |

These boundaries are documented by WPD and retained in the private source facts. Its default reset explicitly does not restore Store apps. Its app-removal “restore” link is not recovery of package/data state. [WPD arguments and presets](https://wpd.app/docs/arguments/), [WPD app-removal FAQ](https://wpd.app/docs/faq/), [WPD blocker providers](https://wpd.app/docs/wfp/).

## Cases that close the actual contracts

| Case | Required result |
| --- | --- |
| Extra feature exists only outside `records` | Coverage validator reports it as accounted, normalized or pending; 632 count alone cannot pass completeness. |
| Edge callback requires a DNS mode while another owner already sets secure mode | Resolve conflict before writes; retain the original and other owner's policy. |
| Last Edge-related owner releases its selection | Restore captured DNS mode; never delete another owner's value. |
| Edge 87 versus Edge 88+, absent Edge, and Microsoft-account profile | Correct product/profile applicability; configured state separated from effective behavior. |
| Home versus Pro for `W010` | Preserve per-action edition gates; test fallback independently. |
| AI settings all configured, but apps/data remain or inventory fails | Aggregate status remains partial/unknown rather than complete removal. |
| Copilot exists only for another user; Copilot CLI also installed | Correct explicit scope, preserve excluded application, no current-user-only success claim. |
| Package removal returns a started async operation then later fails | Final operation result controls status; no optimistic completion. |
| Recall directory absent, inaccessible, linked elsewhere or changed since preview | Absence is distinct from error; validate identity; preserve unselected targets. |
| Recall policy restores successfully after Windows deleted snapshots | Report settings restored and data not restored. |
| WPD task disabled, but executable launch remains permitted | Task-state success only; not full linked-source behavior. |
| Firewall profiles initially differ or are policy-enforced | Capture each separately; owned blocking rule alone is not global Firewall enablement. |
| Restore-point frequency existed with a nondefault value | Preserve it and verify restore-point creation separately. |
| Two custom/preset selections target the same resource with equal/opposing values | Share ownership for equal values; explicit conflict for opposing values. |
| Factory reset would remove unrelated policies | Normalize to exact owned restore; preserve unrelated entries and disclose the narrower behavior. |

## Completion status

This audit establishes source and coverage omissions, not runtime execution. Existing core adapters can be reused, but routing an action or assigning a status string is not evidence that its result was achieved. A complete answer needs an inventory that accounts for fixed records, linked effects and offered dynamic actions, alongside per-action executed or explicitly pending evidence. No runtime mutation or further delegation occurred during this audit.

## Integration follow-through

The compiler now retains the linked-effect and auxiliary-feature inventory as
well as the fixed records. Product gates, corrected evidence, shared Edge DNS
choice, AI and WPD presets, task-linked file permissions, per-account AppX
registrations, custom imports, restore-point creation and Recall data warnings
have implementation paths. Coverage distinguishes guided Windows actions and
normalized restore behavior from setting executors. The validator checks the
auxiliary denominator and referenced settings/presets in addition to fixed counts.

See [Windows settings](../windows-tweaks.md) for executed native/fixture checks
and remaining verification limits. The findings above describe the audited
pre-integration snapshot; their original counts are not current completion data.
