# WinUtil control and side-effect inventory

Research date: 2026-09-19. Pinned upstream commit: `fc60cbde09d669178bda1665be9cb1a703516fca`. This is a factual mapping for independent Roo Industries implementations. No upstream script, application, Windows command, registry edit or network configuration change was executed.

## Complete inventory

Private artifact: `/home/serviroo/.local/share/LeanClientOptimizer/work/four-tool-tweaks-20260919/winutil/controls.json`.

| Coverage | Count |
| --- | ---: |
| Controls in the pinned configuration | 67 |
| Controls containing declared registry changes | 50 |
| Declared registry targets | 122 |
| Controls containing apply scripts | 26 |
| Controls containing undo scripts | 20 |
| Declarative service entries | 6 |
| Normalized apply side effects | 78 |
| Normalized undo side effects | 33 |

The artifact retains every control ID, source name, category, exact registry path/name/type, apply value, vendor reset value, toggle defaults, three-state MPO choices, script-side operations, helper actions, dynamic selectors and prerequisites. It contains operation data rather than copied script bodies. The configuration SHA-256 is `fd2cc2916321e502957bffc5cbbf2e0e842458fa95249d7f4f3a5c3af3fa7068`. [Pinned configuration](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/config/tweaks.json).

The 67 entries include an O&O launcher, DNS selector and two power-plan actions; they are not 67 independent registry tweaks. The O&O launcher should resolve to the shared O&O coverage rather than introduce duplicate implementations. [Button dispatch](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/functions/public/Invoke-WPFButton.ps1), [O&O launcher](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/functions/public/Invoke-WPFOOSU.ps1).

## Registry and service contracts

Registry identity must normalize repeated path separators and case, retain the hive, bind the initiating user and explicitly select the registry view. Upstream uses the PowerShell provider's process view without an explicit Registry32/Registry64 override. Its removal marker means delete a value, not delete the containing key. `OriginalValue` is a configured reset value; it is not captured from the machine. [Registry writer](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/functions/private/Set-WinUtilRegistry.ps1).

Within a control, declarative services run before registry changes, followed by the apply/undo script. Declarative service changes normally preserve a pre-existing nondefault startup mode: apply occurs only when the detected startup matches the configured `OriginalType`, unless `KeepServiceStartup` is disabled. Script-level `Set-Service` calls do not use that check. Changing startup mode does not itself stop a running service. [Control dispatcher](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/functions/private/Invoke-WinUtilTweaks.ps1), [service writer](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/functions/private/Set-WinUtilService.ps1).

MPO has three explicit choices: normal behavior removes both values; compatibility mode sets `OverlayTestMode=5` and removes `DisableOverlays`; full disable sets both to 5 and 1 respectively. The upstream combo helper captures values/existence and verifies partial rollback, but restores using the configured kind rather than the original registry kind. Native recovery must capture kind as well. [Combo writer](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/functions/private/Set-WinUtilRegistryComboState.ps1), [combo detection](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/functions/private/Get-WinUtilRegistryComboState.ps1).

A real conflict exists between WinUtil Activity History and O&O Activity Feed: the former requests `EnableActivityFeed=1`, the latter 0. These choices cannot be merged as identical tweaks. The source also includes registry keys with no declared build/edition gates; those omissions are unknown compatibility, not evidence of universal support. [Activity History definition](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/config/tweaks.json#L2), [O&O inventory](oosu-settings.md).

## Nonregistry operations

The artifact fully records these effect families, including order and conditional targets:

| Family | Exact selection or behavior retained |
| --- | --- |
| Hibernation, reserved storage, Teredo | Powercfg/DISM/netsh requested state and reset state |
| Service configuration | Literal service names, startup modes, preservation gate, direct-script exceptions |
| RAM-dependent setting | Installed physical-capacity sum divided by 1024; original registry kind must be detected |
| Defender | `SubmitSamplesConsent` setting, independent of telemetry registry settings |
| App removal | Widgets, Edge, OneDrive, Copilot/CoreAI and Office Hub selectors, scope, installer parameters |
| ACL changes | Store database, OneDrive, Razer and Logitech paths; exact SID and requested rights |
| Cleanup | User/system temp, Razer/Logitech content, OneDrive leftovers and DISM component cleanup |
| Hosts edits | Downloaded list, append behavior, reset pattern and DNS-cache flush |
| Explorer | Refresh notification versus forced process restart; folder-view subtree deletion |
| Encryption | BitLocker volume selection, decrypt operation, incomplete re-enable inputs |
| Recovery | Restore-point creation and conditional System Restore enablement |
| Network | DNS/DoH, Teredo and per-adapter IPv6 binding changes |

These are source behavior facts, not a recommendation to apply every operation. All per-control actions and values are available in `controls.json` with the corresponding pinned source link. Native implementations must select concrete resources before mutation rather than execute unresolved wildcards.

## DNS and power-plan specifics

The DNS selector contains 14 providers plus `Default` and `DHCP`. **Default is a no-op; DHCP is a reset.** Provider definitions retain IPv4/IPv6 pairs, primary/secondary DoH templates and DoH-only flags. The upstream helper selects every adapter whose status is Up, including any qualifying virtual adapter. [DNS definitions](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/config/dns.json).

DoH configuration modifies both global server registrations and interface-specific `DohFlags` QWords. DHCP resets DNS, removes discovered global DoH registrations and deletes the interface's DoH subtree. Those registrations may be shared with other interfaces. Native review must bind interface GUIDs and model global ownership separately. The artifact records all dynamic paths and fallback conditions. [DNS helper](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/functions/private/Set-WinUtilDNS.ps1).

The source calls the DNS setter separately for IPv4 and IPv6 using the same interface index. Read-back of both families is required before claiming dual-stack success. DHCP is not restoration of an earlier static configuration. [Microsoft DNS setter contract](https://learn.microsoft.com/en-us/powershell/module/dnsclient/set-dnsclientserveraddress?view=windowsserver2025-ps).

Ultimate Performance enable duplicates template `e9a42b02-d5df-448d-aa00-03f14749eb61` and activates the returned GUID. Disable calls a global default-scheme reset, which is broader than deleting the created plan. Native behavior should retain the old active GUID, reuse one owned plan and restore only owned changes. [Power-plan helper](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/functions/public/Invoke-WPFUltimatePerformance.ps1).

## Reset is not restoration

Several upstream inverse operations cannot restore prior state:

- Granting permissions does not remove the explicit deny ACE previously added. Razer/Logitech reset removes all matching deny ACEs, potentially including older entries. Capture and restore original DACL state instead. [Microsoft icacls contract](https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/icacls).
- Reinstalling Edge or OneDrive does not recover deleted profiles/files or previous permissions.
- Hosts reset removes from a text marker through the end of the file; it can remove later unrelated content.
- Explorer folder-view apply and undo both delete saved-view subtrees.
- BitLocker enable needs an appropriate protector parameter set; the upstream undo supplies only the volume. Preserve encryption/protector state rather than treating the inverse command as sufficient. [Enable-BitLocker contract](https://learn.microsoft.com/en-us/powershell/module/bitlocker/enable-bitlocker?view=windowsserver2025-ps).
- DISM `/ResetBase` prevents uninstalling existing update packages. It belongs in explicit maintenance, with truthful irreversible status. [Microsoft component-cleanup contract](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/clean-up-the-winsxs-folder?view=windows-11).

The telemetry script literally addresses service `wermgr`; the source does not establish that the service exists. Native detection must report the actual target and must not silently substitute another service. The Windows AI script also constructs a SID/package-dependent EndOfLife key before proving the package exists. Native planning must require complete identities.

## Verification boundary

All 67 controls and their helper-dispatched paths are accounted for. Source fingerprints are retained in the artifact; `source-verification.json` compares the local files against raw files at the pinned commit. This is an exhaustive source-operation inventory for that snapshot. Actual Windows applicability, effective behavior and native apply/restore remain separate implementation checks. No production changes were made.
