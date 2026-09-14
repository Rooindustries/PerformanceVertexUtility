# Optimization controls

The backend adds supported process-default CPU Sets, a durable bulk removal queue, and a queryable research catalog. These are command interfaces for the desktop to consume. They do not establish UI completion, better frame times, or compatibility with a particular protected game.

## CPU Sets

`Invoke-ProcessCpuSets.ps1` uses Windows' documented CPU Set APIs. Detection opens the target with `PROCESS_QUERY_LIMITED_INFORMATION` (`0x1000`); changes request that right plus `PROCESS_SET_LIMITED_INFORMATION` (`0x3000` combined). One process handle covers identity checks, mutation and readback. The handle is opened under a temporary copy of the caller token with maximum privileges disabled, so an already enabled debug privilege cannot override the target access check. The original thread security context is restored even when the open fails. This uses Microsoft's [restricted-token API](https://learn.microsoft.com/en-us/windows/win32/api/securitybaseapi/nf-securitybaseapi-createrestrictedtoken) and preserves existing impersonation. There is no debug-privilege retry, process-memory access, injection, driver, or anti-cheat modification in this path.

CPU Set IDs are opaque identifiers returned by the operating system. They are not CPU indexes or bits in an affinity mask. The topology result includes processor group, logical processor index, core, cache and NUMA indexes, efficiency class, scheduling class, parking and allocation flags. Sets reserved for another process are rejected.

Inspect the topology and a target before selecting IDs:

```powershell
.\backend\scripts\Invoke-ProcessCpuSets.ps1 -Action Status
.\backend\scripts\Invoke-ProcessCpuSets.ps1 -Action Status -TargetProcessId $targetId
```

Create a preview using IDs from the current topology. The example paths are caller-owned operation storage, not temporary deletion targets:

```powershell
$preview = 'C:\RooOperations\game-cpu-preview.json'
$journal = 'C:\RooOperations\game-cpu-journal.json'
.\backend\scripts\Invoke-ProcessCpuSets.ps1 -Action Preview `
    -TargetProcessId $targetId -CpuSetId $selectedIds -OutputPath $preview
```

After reviewing the returned process identity, original assignment, requested assignment, and compatibility limits, retain the exact preview bytes and hash:

```powershell
$reviewHash = (Get-FileHash -LiteralPath $preview -Algorithm SHA256).Hash
.\backend\scripts\Invoke-ProcessCpuSets.ps1 -Action Apply `
    -InputPath $preview -ReviewSha256 $reviewHash -JournalPath $journal -ConfirmApply
.\backend\scripts\Invoke-ProcessCpuSets.ps1 -Action Restore `
    -JournalPath $journal -ConfirmApply
```

Use `-ResetDefault` instead of `-CpuSetId` when previewing an explicit reset. An empty default assignment is a real state and is restored as an empty assignment.

The preview records computer/user ownership, executable path and process creation time. Apply verifies those fields and the original assignment, then flushes intent before mutation. Duplicate requests use the same journal. Restore changes a control only when it still matches this operation's last applied value; an external value is preserved and reported as a conflict. Windows offers no atomic compare-and-set for CPU Sets, so an independent writer can still race the final check. A crash after mutation is reconciled using live assignment readback. A restored operation cannot be replayed to apply again.

CPU Sets are a scheduler preference. Thread-selected sets and restrictive hard affinity can take precedence. A readable protection level is not proof that an anti-cheat permits changes. The protected-process catalog and Windows protected-process level exclude targets; access denial returns the exact API, access mask and Win32 error. A successful readback proves the process-default assignment, not a performance improvement or freedom from bans. Reapply to a relaunched process only through a fresh identity-bound preview; this command does not install a persistent watcher.

The existing native and PowerShell governors now also limit restoration to recorded controls with matching applied values. Repeated restraint cycles retain the latest captured originals, preserving changes made between cycles.

## Bulk official removal

`New-BulkUninstallPlan.ps1` creates an ordered plan from exact installed-app IDs. Registry IDs include hive, registry view, key and user scope. HKLM views are enumerated separately; the shared HKCU uninstall key uses one canonical view to avoid duplicate entries across process architectures. [Microsoft documents this WOW64 distinction](https://learn.microsoft.com/en-us/windows/win32/winprog64/shared-registry-keys). Appx IDs retain the full package name and current Windows user. Plans bind the current registration data, executable hash and exact arguments. MSI commands derive `/x` from a validated ProductCode and include `/norestart`; a ProductCode present in multiple inventory contexts requires further review. Appx removal uses the full package name in the current-user scope.

```powershell
.\backend\scripts\Get-InstalledAppInventory.ps1
.\backend\scripts\New-BulkUninstallPlan.ps1 -AppId $selectedAppIds `
    -OutputPath 'C:\RooOperations\bulk-preview.json'
```

`-Quiet` uses a published quiet command for registry applications. It does not invent silent switches. A saved inventory may be used for preview, but presence and registration bindings are checked against the actual Windows registry or Appx inventory before execution. Winget text rows without an exact installed identity have no removal adapter in this queue.

After review, execute the exact plan and retain its journal:

```powershell
$plan = 'C:\RooOperations\bulk-preview.json'
$journal = 'C:\RooOperations\bulk-journal.json'
$reviewHash = (Get-FileHash -LiteralPath $plan -Algorithm SHA256).Hash
.\backend\scripts\Invoke-BulkUninstall.ps1 -Action Apply -InputPath $plan `
    -ReviewSha256 $reviewHash -JournalPath $journal -ConfirmApply
```

Selections requiring dependency review also need `-ManualReviewApproved`. Protected selections remain excluded. An executable read lease prevents replacement between the final executable hash check and process launch. The exact registration fingerprint must still match the preview. A durable per-app claim prevents another queue from relaunching an unresolved removal. Real claims live under the current user's `LocalApplicationData\RooOptimizationSuite\uninstall-claims`; fixture claims remain beneath their disposable root.

The queue writes dispatch intent before launching each command. It retains PID and process creation time while observing the remover. Exit zero is not enough: the selected app registration must also be absent. This verifies registration removal, not every file, service, dependency or shared component that the app used.

| Condition | Queue behavior |
|---|---|
| Successful remover and registration absent | Record completion; proceed to the next entry |
| MSI 3010 or 1641 | Record reboot handling; stop scheduling more entries |
| MSI 1605 or 1614 | Interpret as already absent, then check the selected registration |
| MSI 1618 or 1602 | Preserve installer-busy or cancellation outcome; stop |
| Generic executable returns an MSI-like code | Keep generic failure semantics |
| Exit zero but registration remains | Require reconciliation |
| Timeout or interrupted dispatch | Preserve uncertainty; do not kill or automatically repeat the remover |
| Registration or executable changes after preview | Reject before dispatch; require a fresh plan |
| Cancellation during a running entry | Finish observing that entry; start no subsequent entry |

An arbitrary vendor uninstaller cannot provide exactly-once execution solely through a PID and local journal. Once an attempted operation is uncertain, inspect its journal and reconcile it instead of launching it again:

```powershell
.\backend\scripts\Invoke-BulkUninstall.ps1 -Action Status -JournalPath $journal
.\backend\scripts\Invoke-BulkUninstall.ps1 -Action Cancel -JournalPath $journal -ConfirmApply
.\backend\scripts\Invoke-BulkUninstall.ps1 -Action Reconcile -JournalPath $journal -ConfirmApply
```

Reconciliation checks that the recorded process is no longer running and whether the exact registration is absent. An MSI reboot requirement also retains the recorded Windows boot time and remains pending until Windows reports a different boot. It dispatches nothing. A new confirmed `Apply` resumes untouched entries after cancellation or resolved completion; it never silently retries an attempted entry. If a registration remains after an attempted remover, retain the unresolved claim and investigate the vendor outcome. This version does not offer a force-retry override. Descendant processes and external installer services are not comprehensively tracked; a timeout or incomplete registration therefore never authorizes leftover deletion.

## Cleanup after removal

The queue ends with `cleanup-review-required` and never deletes leftovers. Run a new leftover scan, review shared ownership and current contents, and build a separate cleanup manifest. The same separation now applies to `Invoke-UninstallCleanupApplyPackage.ps1`: after running a vendor command, it returns fresh target content hashes and leaves the earlier cleanup list unapplied. A repeated call returns that recorded result without relaunching the vendor or deleting files.

File-only cleanup continues through the existing exact-target allowlist, backup and recovery journal. File restoration recovers backed-up leftovers; it cannot reinstall an application or reverse vendor registry/service changes. Path-based copying/deletion still has a filesystem race window against a concurrent hostile writer. A native file-handle ownership layer, broader dependency analysis, registry/service leftover mutation and install-time tracing remain separate work.

## Capability router requests

The capability IDs are `process-controls.cpu-sets`, `cleanup-uninstall.bulk-removal`, and `system-optimizations.upstream-settings-inventory`. The first two use `Invoke-OptimizerRequest.ps1` through a route-declared `-RequestPath`; command names and dispatch targets are fixed by the wrapper.

| Request | JSON fields in addition to `schemaVersion: 1` |
|---|---|
| CPU Sets preview | `targetProcessId`, `cpuSetIds` array or `resetDefault` boolean, optional `outputPath` |
| CPU Sets apply | `inputPath`, `reviewSha256`, `journalPath`, optional `outputPath` |
| CPU Sets restore | `journalPath`, optional `outputPath` |
| Bulk preview | `appIds` array; optional `inventoryPath`, `quiet`, `outputPath` |
| Bulk apply | `inputPath`, `reviewSha256`, `journalPath`; optional `manualReviewApproved`, `timeoutSeconds`, `outputPath` |

```powershell
.\backend\scripts\Invoke-RooCapability.ps1 -CapabilityId process-controls.cpu-sets `
    -Action preview -RequestPath 'C:\RooOperations\request.json'
```

Mutating router actions additionally require `-ConfirmApply`. Router errors preserve the nested backend evidence. Default CPU Sets preview without a request detects topology; bulk preview without a request describes its required selection. A vendor uninstall has no restore route. Keep journals and reviewed inputs separate from output files.

## Upstream setting inventory

```powershell
.\backend\scripts\Get-UpstreamSettingsCatalog.ps1 -Source winutil -Limit 50
.\backend\scripts\Get-UpstreamSettingsCatalog.ps1 -Search 'CPU' -Offset 0 -Limit 100
.\backend\scripts\Get-UpstreamSettingsCatalog.ps1 -Collection applications -Limit 500
```

The inventory contains 376 setting/control records, 267 application/package records, and 1,319 FSOS-X YAML records. Settings, packages, orchestration actions and inferred Dash symbols are separate collections. Filters return the filtered total and stable pages; no catalog entry automatically executes. Source snapshots and risks travel with the result. See the [research index](research/README.md) for provenance, edition distinctions and the limits of binary-symbol evidence.

## Verification

New reusable checks are `Test-ProcessCpuSets.ps1`, `Test-BulkUninstall.ps1`, `Test-InstalledAppIdentity.ps1`, `Test-NativeGovernorRestoreOwnership.ps1` and `Test-UpstreamSettingsCatalog.ps1`. The combined cleanup regression now includes a vendor fixture that changes an existing file and creates a new file. Tests use disposable processes, registrations represented by fixture markers, and isolated journals; actual installed applications are inventoried read-only.

Windows PowerShell 5.1 and the Windows APIs are the execution surfaces. Linux parsing and schema checks establish source/contract properties only. Vendor MSI/Appx removal, protected games, hardware performance, reboot behavior and UI journeys require separate Windows validation. Current task evidence and any pending machine access are kept in the development handoff rather than represented as product guarantees.
