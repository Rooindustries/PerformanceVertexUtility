# AppX removal scopes

Researched 2026-09-20 against the current backend and Microsoft contracts. No app was removed, no Windows state changed, and no frontend or product file was edited.

## Minimal supported extension

Extend the existing PowerShell AppX provider and bulk-removal journal. Enumerate all users explicitly, retain package full names and installed-user SIDs, then create one removal entry per reviewed package/SID pair. A frozen list of explicit `-User` removals gives the clearest match to the existing exact-identity contract. An `-AllUsers` command is also supported, but its reviewed scope must expressly cover all accounts at execution; it is not a way to ignore user identity.

`Get-AppxPackage -AllUsers -PackageTypeFilter Main,Bundle -ErrorAction Stop` includes parent bundles that the default Main/Framework query omits. Retain framework/resource/dependency metadata separately for protection and dependency review. All-user and other-user queries require an administrator token. A successful complete empty enumeration proves absence; an access/provider failure does not. [Get-AppxPackage](https://learn.microsoft.com/en-us/powershell/module/appx/get-appxpackage?view=windowsserver2025-ps).

Use `PackageManager.FindUsers(packageFullName)` to obtain authoritative `PackageUserInformation` records if the PowerShell wrapper's user-state data is incomplete. Capture `UserSecurityId` and `InstallState`; do not infer users from profile-directory names or `InstalledLocation`. [FindUsers](https://learn.microsoft.com/en-us/uwp/api/windows.management.deployment.packagemanager.findusers?view=winrt-26100), [user information](https://learn.microsoft.com/en-us/uwp/api/windows.management.deployment.packageuserinformation?view=winrt-26100).

For each captured SID, use `Remove-AppxPackage -Package <exact-full-name> -User <SID> -ErrorAction Stop`. The `User` parameter accepts SIDs, not account names. For explicit all-users execution, use the reviewed parent bundle where applicable. Validate actual admin state when a provider denies access. [Removal parameter sets](https://learn.microsoft.com/en-us/powershell/module/appx/remove-appxpackage?view=windowsserver2025-ps).

## Existing seams

| File and entry point | Required extension |
| --- | --- |
| `backend/scripts/Get-InstalledAppInventory.ps1:111` | Current query is current-user only; add explicit scope and complete per-user installation evidence. Retain package kind, parent-bundle relationship, removability and dependencies. |
| `backend/scripts/InstalledAppIdentity.Common.ps1:24` | Constructor hard-codes `current-user`. Preserve the existing full-name/SID stable identity and add an explicitly reviewed other-user scope. A grouped all-users selection expands to those identities. |
| `backend/contracts/roo-industries-backend-contracts.schema.json`, `appSourceIdentity` | Scope is currently a constant. Add the new scope and required captured-SID/state fields without weakening current-user validation. |
| `backend/scripts/BulkUninstall.Common.ps1:16` | Validator currently requires the target SID to equal the operation owner. Keep that rule for current-user scope; require exact reviewed SIDs and admin capability for other-user scope. |
| `backend/scripts/BulkUninstall.Common.ps1:38` | Presence query ignores the identity SID. Query the exact captured SID and full package name with terminating errors. |
| `backend/scripts/BulkUninstall.Common.ps1:59` | AppX fingerprint currently contains identity only. Bind scope, user-install state, package type/parent, and relevant protection/dependency facts from a fresh inventory. |
| `backend/scripts/New-BulkUninstallPlan.ps1:38` | Build the exact per-SID command; preserve structured provider error details instead of only converting all failures to exit 1. |
| `backend/scripts/Preview-OfficialUninstall.ps1:39` | Alternate preview also hard-codes current-user scope; keep both entry points consistent. |
| `backend/scripts/Invoke-BulkUninstall.ps1:61` | Existing completion/reconciliation already checks registration absence. Extend that check per captured SID and aggregate only when every target is verified. |
| `backend/scripts/Test-InstalledAppIdentity.ps1` and `Test-BulkUninstall.ps1` | Extend existing identity, replay, timeout and contradictory-success fixtures with the cases below. |

These are inspected source seams, not claims that the extension already exists. The current process observer waits for the child and leaves timed-out operations for reconciliation; keep that behavior rather than automatically issuing another removal.

## Native API types and constants

| Contract | Exact values |
| --- | --- |
| `PackageTypes` flags | Main 1, Framework 2, Resource 4, Bundle 8, Optional 32; All 0xFFFFFFFF requires build 19041. Main+Bundle is 9. |
| `PackageInstallState` | NotInstalled 0, Staged 1, Installed 2, Paused 6. Treat Staged/Paused as separate states rather than ready registrations. |
| `RemovalOptions` | None 0; PreserveApplicationData 4096 only for development-mode packages; DeferRemovalWhenPackagesAreInUse 8192; RemoveForAllUsers 524288 (`0x80000`, build 17763+). |
| Async return | `IAsyncOperationWithProgress<DeploymentResult, DeploymentProgress>`. |
| `AsyncStatus` | Started 0, Completed 1, Canceled 2, Error 3. |

Sources: [package types](https://learn.microsoft.com/en-us/uwp/api/windows.management.deployment.packagetypes?view=winrt-26100), [installation state](https://learn.microsoft.com/en-us/uwp/api/windows.management.deployment.packageinstallstate?view=winrt-26100), [removal options](https://learn.microsoft.com/en-us/uwp/api/windows.management.deployment.removaloptions?view=winrt-26100), [async status](https://learn.microsoft.com/en-us/uwp/api/windows.foundation.asyncstatus?view=winrt-26100).

A native helper may call `RemovePackageAsync(fullName, RemovalOptions.RemoveForAllUsers)` for the explicitly reviewed all-users operation. Retain the operation object and await terminal completion; obtaining it or receiving progress 100 is not success. Record status, operation HRESULT and available `DeploymentResult` fields: `ExtendedErrorCode`, `ErrorText`, and `ActivityId`. Catch exceptions from the async projection/result retrieval. `IsRegistered` is not an all-users removal receipt. Cancellation/error/timeout remain separate from completed removal. [Removal async contract](https://learn.microsoft.com/en-us/uwp/api/windows.management.deployment.packagemanager.removepackageasync?view=winrt-26100), [deployment result](https://learn.microsoft.com/en-us/uwp/api/windows.management.deployment.deploymentresult?view=winrt-26100).

## Verify removal independently

After the awaited operation, successfully enumerate each captured SID and compare the exact full package name. A failed query means unknown, never absent. Also rescan the selected family across users before an “all registered users removed” result: a newly installed version or newly registered SID is remaining scope, even when every original full name disappeared. Reject changed membership before dispatch; preserve completed per-SID results when later entries fail.

For a native lookup, `FindPackageForUser(sid, fullName)` binds the two identities; an empty SID means current user, so never substitute empty for failed SID resolution. Do not infer absence from arbitrary exceptions. A successful per-user enumeration is the simpler negative-evidence surface. [Exact-user lookup](https://learn.microsoft.com/en-us/uwp/api/windows.management.deployment.packagemanager.findpackageforuser?view=winrt-26100).

## Provisioning and new users are separate

| Goal | Authoritative surface |
| --- | --- |
| Remove current registrations | AppX per-user/all-user package inventory and removal. |
| Prevent automatic installation for future users | Provisioned-package inventory and a separately selected deprovision action. |
| Remove leftover files | Fresh cleanup scan/review after deployment, independently scoped. |

`Get-AppxProvisionedPackage -Online` identifies packages configured for new accounts. A provisioning removal is not proof that existing accounts lost their app. The native `DeprovisionPackageForAllUsersAsync` takes **PackageFamilyName**, not PackageFullName, requires admin privileges, and starts at build 17763. Keep its identity, review and verification separate from registered-user removal. [Provisioned inventory](https://learn.microsoft.com/en-us/powershell/module/dism/get-appxprovisionedpackage?view=windowsserver2025-ps), [image removal semantics](https://learn.microsoft.com/en-us/powershell/module/dism/remove-appxprovisionedpackage?view=windowsserver2025-ps), [deprovision API](https://learn.microsoft.com/en-us/uwp/api/windows.management.deployment.packagemanager.deprovisionpackageforallusersasync?view=winrt-26100).

O&O's pinned machine-removal path additionally takes ownership of the installation directory and attempts recursive deletion after all-users removal. That raw directory action is unnecessary for the supported registration-removal contract. Account for it as separate vendor cleanup behavior; use the existing fresh-leftover review rather than automatically deleting shared WindowsApps content. Reinstallation is not exact application-data restoration, and normal Store apps cannot use the development-only preservation flag. [Pinned O&O package](https://dl5.oo-software.com/files/ooshutup10/OOSU10.exe), [data-preservation limits](https://learn.microsoft.com/en-us/powershell/module/appx/remove-appxpackage?view=windowsserver2025-ps).

## Discriminating tests

1. Same full name for SID A and B: unique identities; removing A leaves B and cannot complete the grouped request.
2. Installed 2 versus Staged 1, Paused 6, unknown or missing user state: only proven registrations enter that scope; incomplete inventory rejects mutation.
3. Parent bundle plus main/resource/framework children: plan the supported parent identity and avoid duplicate removal/dependency damage.
4. App exists only for another SID: current-user empty results must not report global absence; query denial must remain unknown.
5. Async Started/progress 100, then Error or Canceled: no success; retain HRESULT/activity details. Completed with a remaining registration requires reconciliation.
6. Version/user membership changes after preview: reject stale dispatch. New versions/users found after removal prevent an all-users-complete claim.
7. Partial SID success, timeout or process interruption: reconcile exact targets; never automatically repeat an uncertain invocation.
8. Registrations absent but provisioning remains, and provisioning absent but a registration remains: report the two outcomes independently.
9. Replay completed queue: no second remover invocation; current-user schema compatibility and unrelated MSI/registry routes remain intact.

No removal or test mutation was executed for this research. Provider fixtures can validate the new logic first; actual deployment behavior needs a self-created disposable package and explicitly approved scope.
