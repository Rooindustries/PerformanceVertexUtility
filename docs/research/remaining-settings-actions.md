# Remaining setting actions: minimal changes and exact recovery

Captured 2026-09-19 from the pinned WinUtil, FSOS-X Dash and WPD factual inventories and Microsoft contracts. This is an implementation contract, not executed validation. No product files, registry values, boot settings or file permissions were changed.

The private `remaining-actions-contracts.json` describes six actions and 22 minimal proposed registration/value changes. App-helper paths are unresolved plan-time placeholders, not existing deployed binaries. Menu installation and invoking a menu action are different operations and must have different journals.

| Action | Minimum change | Broad source reset to avoid |
| --- | --- | --- |
| Classic context menu | One unnamed empty `REG_SZ` value in the user CLSID override | Deleting an entire existing CLSID subtree |
| Default Explorer folder template | One `FolderType` string preference | Deleting Bags and BagMRU as ordinary apply/undo |
| Power and Safe Mode desktop menus | Namespaced labels and fixed commands to a helper | Deleting generic menus, changing BCD during installation, forced immediate reboot |
| Take Ownership menu | Two namespaced verbs pointing to a typed helper | Inline interpreters, recursive permissions by default, deleting generic source menu trees |
| SmartScreen IFEO cleanup | Remove only the reviewed `Debugger` value | Deleting all IFEO settings for `smartscreen.exe` |
| Service-host threshold | One explicitly typed DWORD, based on validated installed RAM | Provider-inferred numeric type or a hard-coded “default” restoration |

For all registry operations, retain exact value existence, kind, bytes and created-key identities. Restore the captured value or remove only an owned newly introduced value. Prune only keys created by the transaction that remain empty. Leave unrelated values, subkeys, owners and ACLs intact. An outside change after apply is a recovery conflict, not permission to overwrite it.

## Classic context menu

The pinned FSOS-X enabling operation writes:

`HKCU\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32`

The unnamed/default value is **REG_SZ with empty data**. That is distinct from a missing value. FSOS-X then force-restarts Explorer; its opposite operation deletes the whole parent CLSID tree. Only the one value is required to reproduce its registration change. [Pinned FSOS-X package](https://fsosx.com/FSOS-XR11H2.apbx).

The independent transaction should snapshot the default value and whether each affected key already existed, write the empty string, and verify its kind/data. Restoration should put the exact original back. If all affected keys were originally absent, remove the restored-to-absent value and then only the newly created empty keys. A pre-existing sibling or a subsequently added value must prevent pruning.

This CLSID override is a vendor-observed compatibility setting. No Microsoft platform contract for forcing the classic menu through this CLSID was found in the bounded search. Do not claim official support or current-build effectiveness merely because the registry write succeeds. Visual verification on the intended Windows 11 build is still required. Offer a scoped shell refresh or later sign-out; force-killing every `explorer.exe` is not necessary to install the value and is not a detector.

Use the initiating user's explicit classes hive. HKCR is a merged view with different write-routing behavior, so the elevated helper should not use its own HKCU or ambiguous HKCR. [Microsoft HKCR contract](https://learn.microsoft.com/en-us/windows/win32/sysinfo/hkey-classes-root-key).

## Explorer folder discovery and saved views

The exact preference in the pinned WinUtil control is:

`HKCU\Software\Classes\Local Settings\Software\Microsoft\Windows\Shell\Bags\AllFolders\Shell`

`FolderType` = **REG_SZ `NotSpecified`**.

WinUtil first deletes both complete Bags and BagMRU trees; its undo deletes both again. Those deletions reset saved folder state and are not exact recovery. A one-value preference operation can preserve both trees and restore only the original `FolderType`. That implements the default-template override, not a claim that every existing saved folder view has been reset. [Pinned WinUtil control](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/config/tweaks.json#L1208).

If resetting existing folder views is also offered, make it a separately named **Reset saved folder views** action. It requires complete snapshots outside the affected trees and a quiescent, validated shell session. Explorer can repopulate these trees; recovery must detect newly saved views and avoid replacing them silently. There is no justified need to perform this full reset merely to add the default-template value.

The Shell Bags override is not documented as a current Windows API contract by the Microsoft developer sources checked here. Microsoft's `FOLDERTYPEID` page describes typed view-template GUIDs; its deprecated `FOLDERTYPEID_NotSpecified` identifier is not proof about the distinct registry string `FolderType="NotSpecified"`. Do not conflate those interfaces. Verify newly visited folders and pre-existing customized folders separately. [Folder template contract](https://learn.microsoft.com/en-us/windows/win32/shell/foldertypeid).

## Desktop Power and Safe Mode menus

Register under the initiating user's explicit `Software\Classes\DesktopBackground\Shell` with application-owned names, for example `RooIndustries.PowerOptions` and `RooIndustries.SafeMode`. The Power entry needs a label and a command that starts the verified helper with the fixed `power-options` verb. The helper can open Power Options; it need not activate or reset any power plan.

The Safe Mode cascade needs `MUIVerb`, an empty `SubCommands` string, and four ordered child verbs. Each child has a label and a fixed helper command: normal, minimal, network, or minimal-console. `Icon` and `Position` are decorations, not required behavior. Do not replace generic existing `PowerOptions` or `BootMode` trees. Detect existing matching entries and preserve them rather than silently duplicating or taking ownership of them. This design uses Microsoft's documented static/cascading verb mechanism. [Shell verb registration](https://learn.microsoft.com/en-us/windows/win32/shell/context-menu-handlers).

Installing these menus should only register entries. Invoking a Safe Mode entry opens review of the actual boot change. The source's nested PowerShell/cmd command, immediate forced restart and persistent mutation of `{current}` are not required merely to offer the menu. The reviewed native boot action can use the following exact BCD elements:

| Mode | SafeBoot `0x25000080` | SafeBootAlternateShell `0x26000081` |
| --- | --- | --- |
| Normal | Remove only the selected override | Remove only the selected override |
| Safe Mode | Integer `0` (minimal) | Absent |
| Safe Mode with networking | Integer `1` (network) | Absent |
| Safe Mode with Command Prompt | Integer `0` (minimal) | Boolean true |

Resolve `{current}` to an actual loader identity, snapshot both elements and any pending boot sequence, and preserve all other BCD fields. Microsoft defines the safe-boot values and alternate-shell element independently of menu implementation. [BCD loader elements](https://learn.microsoft.com/en-us/previous-versions/windows/desktop/bcd/bcdosloaderelementtypes), [SafeBoot values](https://learn.microsoft.com/en-us/previous-versions/windows/desktop/bcd/bcdlibrary-safeboot).

A preferable one-boot design is an owned copy of the current loader, safe-boot settings on that copy, and a one-time boot sequence. This avoids overwriting the normal loader's persistent configuration. It still needs a complete clone/boot-sequence journal, detection of a pre-existing pending sequence and post-boot cleanup of only the owned entry. It is an independent design derived from Microsoft's copy and bootsequence operations, not verified runtime behavior. [BCD commands](https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/bcdedit), [one-time boot sequence](https://learn.microsoft.com/en-us/windows-hardware/drivers/devtest/bcdedit--bootsequence).

Restart is a separate final action. A countdown should occur inside the app, followed by a non-force restart after the user has resolved open work. **`shutdown /t` greater than zero implicitly forces applications closed**, even without an explicit `/f`. Removing `/f` from a source command while retaining a positive timeout does not remove that behavior. [Shutdown contract](https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/shutdown).

## Take Ownership menu and helper

Use application-owned verbs under explicit user classes paths:

- `Software\Classes\*\shell\RooIndustries.TakeOwnership`
- `Software\Classes\Directory\shell\RooIndustries.TakeOwnership`

A minimal static registration provides the label, `MultiSelectModel=Single`, and a command pointing directly to an absolute, verified app helper. Its fixed operation is `ownership-review`, followed by one literal selected-path argument. No selected path should be interpolated into a `cmd /c`, PowerShell `-Command`, or script body. Ampersands and percent signs must remain path characters, not interpreter syntax. `HasLUAShield` only adds the visual shield; it does not elevate the helper. [Microsoft static verb contract](https://learn.microsoft.com/en-us/windows/win32/shell/context-menu-handlers).

For the static command route, round-trip actual argv for spaces, Unicode, ampersands, percent signs, carets, parentheses, apostrophes and trailing separators before enabling mutation. Reject unexpected argument counts and options. Subsequent helper launches should use a fixed executable and an argument-list API rather than manually concatenated commands. [ProcessStartInfo.ArgumentList](https://learn.microsoft.com/en-us/dotnet/api/system.diagnostics.processstartinfo.argumentlist), [CreateProcessW](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-createprocessw).

A richer supported route is `DelegateExecute` with `IExecuteCommand` and `IObjectWithSelection`: the shell provides an `IShellItemArray`, which can be passed as structured selected-object information to the helper. That avoids string substitution and handles multiple selections explicitly. It needs actual COM packaging and activation verification. On the the i5-14600K test PCXT's documented UAC-disabled administrator workflow, **per-user COM registration is not sufficient**: Microsoft says the runtime ignores it in that state. A per-machine class registration or another verified route is necessary. [Microsoft shell example](https://devblogs.microsoft.com/oldnewthing/20100312-01/?p=14623), [selection interface](https://learn.microsoft.com/en-us/windows/win32/api/shobjidl_core/nn-shobjidl_core-iobjectwithselection), [COM registration caveat](https://learn.microsoft.com/en-us/windows/win32/sysinfo/hkey-classes-root-key).

The invoked ownership operation needs a separate exact recovery record. Resolve the selected item to a handle and stable file identity; retain its original owner, DACL and inheritance/control flags. The minimal owner-only operation changes the owner using the security API. WPD's full behavior also grants Full Control, so offer that as an explicit access-grant choice if parity is required. Do not describe owner-only as equivalent to WPD's permission grant.

Use `GetSecurityInfo` and `SetSecurityInfo` against the retained handle where possible. Preserve unrelated ACEs, group and SACL; never substitute a null DACL. Default to the selected object only. Explicit recursion needs a per-object journal, bounded enumeration and preservation of unselected reparse targets. Restore the original descriptor components only on the same object identity after checking for outside changes. Inheritable ACE changes can propagate to existing children, so inheritance flags are part of the affected scope. [Security reads](https://learn.microsoft.com/en-us/windows/win32/api/aclapi/nf-aclapi-getsecurityinfo), [security writes](https://learn.microsoft.com/en-us/windows/win32/api/aclapi/nf-aclapi-setsecurityinfo).

Menu removal should undo only the app's registration. It must not change previously selected file permissions and must not delete the generic `TakeOwnership` keys belonging to WPD or another tool. WPD's source uses an interpreter chain and broad menu-tree deletion; neither is needed for an independent native implementation. [Pinned WPD facts](wpd-settings.md).

## SmartScreen IFEO cleanup

The source deletes the entire machine IFEO subtree when enabling SmartScreen:

`HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\smartscreen.exe`

The minimally scoped launch-redirection repair is to inspect and remove only the reviewed **Debugger** value from the effective registry view. That value controls debugger launch. `PerfOptions`, `GlobalFlag`, tracing settings, verifier configuration, unrelated subkeys and key security do not need deletion to remove that direct redirection. An absent Debugger value is a no-op. [Debugger launch contract](https://learn.microsoft.com/en-us/windows-hardware/drivers/debugger/preparing-to-debug-the-service-application), [IFEO architecture considerations](https://learn.microsoft.com/en-us/windows-hardware/drivers/devtest/application-verifier-faqs).

Record exact prior type/data/existence and restore just that value if requested, with drift checks. Detect filtered/path-specific IFEO configuration separately; the root-value cleanup must not claim to remove an uninspected effective filter. This audit does not establish a complete supported schema for every filter variant.

Removing a launch override does not by itself enable SmartScreen policy or the Edge component. Show **Launch override removed** for this action, and determine protection status from its separate authoritative policy/runtime state. The source's broad enable/reset operation must not delete unrelated policy choices merely to achieve the IFEO cleanup. [SmartScreen policy](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-smartscreen), [FSOS-X behavior](https://fsosx.com/FSOS-XR11H2.apbx).

## Service-host split threshold

The target is:

`HKLM\SYSTEM\CurrentControlSet\Control\SvcHostSplitThresholdInKB`

Use an explicit **REG_DWORD**, not a PowerShell provider-inferred numeric kind. A Microsoft Community answer signed by **Mala S, Microsoft Community – Moderator**, dated **2018-12-31**, identifies the DWORD and says that a threshold equal to or above installed RAM in KB groups eligible services. Its example is 8 GiB → 8,388,608 KB. This is Microsoft-signed support guidance for Windows 10, not a formal current Windows 11 registry API guarantee. The bounded search found no Microsoft engineering reference documenting the override name/type/formula more strongly. [Original Microsoft support answer](https://learn.microsoft.com/en-us/answers/questions/3172755/windows-explorer-freezing-microsoft-store-backgrou).

Microsoft's engineering guidance explains that Windows 10 1703 separates most shared services above 3.5 GB, while some continue to share a host. It also describes the separate per-service `SvcHostSplitDisable` exception. Fewer processes are not proof of better performance: isolation and fault behavior change along with memory use. Do not alter exception flags to force a claimed universal result. [Service-host design](https://learn.microsoft.com/en-us/windows/application-management/svchost-service-refactoring).

The formula and units can be implemented precisely:

`thresholdKiB = checked(sum(Win32_PhysicalMemory.Capacity)) / 1024`

`Capacity` is uint64 **bytes**. Prefer `GetPhysicallyInstalledSystemMemory` where practical: it directly returns installed **kilobytes**, so do not divide that result again. Its SMBIOS error result must remain an error, not zero or a fallback to committed/available RAM. OS-usable physical memory can be smaller because of hardware reservations. [PhysicalMemory capacity](https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/win32-physicalmemory), [installed-memory API](https://learn.microsoft.com/en-us/windows/win32/api/sysinfoapi/nf-sysinfoapi-getphysicallyinstalledsystemmemory).

| Installed RAM | DWORD decimal in KiB |
| --- | ---: |
| 8 GiB | 8,388,608 |
| 16 GiB | 16,777,216 |
| 32 GiB | 33,554,432 |
| 64 GiB | 67,108,864 |

Validate a complete, nonzero reading and unsigned 32-bit range. A 4 TiB result is 4,294,967,296 KiB and cannot fit in a DWORD; reject it rather than wrapping or silently using QWORD. Capture the existing value's actual type/data/existence and restore that exact original. Never write an assumed universal `0x380000` default during recovery. Reboot is needed before assessing process regrouping; a successful registry write does not change already running service hosts. [Registry numeric types](https://learn.microsoft.com/en-us/windows/win32/sysinfo/registry-value-types).

## Required verification

Before reporting execution complete, use disposable fixtures for absent/pre-existing values, wrong original types, sibling keys, outside edits, partial failure and exact restore. Menu tests must invoke a harmless helper fixture through the actual shell and verify arguments; registry text alone is insufficient. Ownership needs a disposable file/tree with exact owner/DACL restoration. Boot-provider tests must preserve every unrelated entry/field and prove cleanup of the owned one-time entry. Live reboot, production permissions, registry and boot changes remain outside this read-only research task.

The private machine-readable contract is `<private work folder>/four-tool-tweaks-20260919/remaining-actions-contracts.json`. It includes source inventory hashes, exact proposed registry addresses, native invocation boundaries and per-action acceptance cases. Classic-menu and folder-template effectiveness on the intended Windows build remain explicitly unverified.

## Completion semantics: FTH disable and state reset

Microsoft documents **`HKLM\Software\Microsoft\FTH\Enabled` = DWORD `0`, followed by a system restart**, as the procedure to disable FTH. It separately documents `Rundll32.exe fthsvc.dll,FthSysprepSpecialize` as resetting the tracked-application list. The reset clears all FTH applications; it is not a required step in the documented disable procedure or a harmless refresh. The explicit post-restart statement concerns activation for new applications. It does not establish that an existing running process has shed a mitigation or that learned state was erased. The article's stated platform is Windows 7, so current-build runtime behavior remains separate verification. [Microsoft FTH contract](https://learn.microsoft.com/en-us/previous-versions/windows/win32/win7appqual/fault-tolerant-heap).

For completion reporting, distinguish these actions:

| Action | Completion evidence | Restoration |
| --- | --- | --- |
| Disable FTH configuration | Exact DWORD readback; report restart pending until a new boot is observed | Restore the exact prior value/type/absence, with a restart where needed |
| Verify FTH behavior for a selected application | Post-restart observation bound to that application's PID, image and creation time; existing learned applications need their own case | Registry readback alone is insufficient |
| Reset FTH tracked applications | Separate reviewed global reset, verified on a disposable Windows image | No supported exact inverse was established; backing up only a guessed `FTH\State` subtree is not proof of complete recovery |

The first row implements Microsoft's documented disable sequence without deleting learned state. It must not claim the third row as completed. FSOS's source combines both operations, so inventory them as separate effects rather than treating the destructive reset as an implicit part of normal apply or restore.

## Completion semantics: Explorer defaults and saved views

Microsoft's view-state API distinguishes per-folder property bags from user/global defaults and inherited defaults. Default lookup can occur when a folder-specific bag is absent. This supports treating a default preference and existing saved views as different state, but it does **not** document the raw `FolderType="NotSpecified"` registry string or its precedence on current Windows. [SHGetViewStatePropertyBag](https://learn.microsoft.com/en-us/windows/win32/api/shlwapi/nf-shlwapi-shgetviewstatepropertybag).

The minimum WinUtil-derived preference remains the one `FolderType` string already identified above. Omitting Bags/BagMRU deletion preserves cached state; it is not demonstrated full parity with WinUtil's broader operation for every previously customized folder. Setting readback supports **Default folder template configured**, while a separate **Reset saved folder views** action must account for removing those saved preferences. Restoring the default string does not restore views erased by a reset. The pinned FSOS playbook itself sets this preference as one registry action without a neighboring whole-tree reset, providing another source-level distinction rather than a runtime guarantee. [WinUtil operation](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/config/tweaks.json#L1208), [FSOS playbook](https://fsosx.com/FSOS-XR11H2.apbx).

Current-build verification should cover a newly visited folder, a folder with an existing customized view and a folder with an explicit content template separately. No Microsoft engineering contract for the exact raw override was identified in this bounded search; community-hosted posts were not promoted to platform documentation. Do not infer its support from the distinct deprecated `FOLDERTYPEID_NotSpecified` GUID. No shell launch, registry change, cache deletion or FTH reset was performed for this follow-up.
