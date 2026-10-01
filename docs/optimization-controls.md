# Optimization controls

The desktop provides reviewed process controls, saved rules, queued vendor removal, and app-specific file and registry cleanup with recovery. Readback establishes the requested Windows configuration; it does not establish better frame times or compatibility with every protected game.

## Desktop workflows

In **Process Control**, select a running application and choose CPU priority, I/O priority, GPU priority, memory priority, execution QoS, dynamic priority boosts, CPU Sets or hard affinity. Preview shows each original and requested value. Apply once records recovery data for that process identity; Restore preserves controls changed by another actor. The identity includes executable path, PID and creation time, so a reused PID is not a replacement target.

CPU selections can use logical processors, performance/efficiency classes, one thread per physical core, cache groups or NUMA nodes. Hard affinity has its own group-relative mask and can differ from the CPU Set preference. Memory priority controls page retention, not a RAM allocation limit.

**Saved rules** can be edited, paused or deleted. They store semantic CPU selection and a topology fingerprint, resolving fresh opaque IDs for each process instance. Hard-affinity rules also bind the reviewed topology. Rules apply only to the current Windows user's matching processes. Exact executable-path matching is the default; filename matching and executable-file hash binding are explicit options. An external field change suspends that instance rather than repeatedly overriding it.

The **Roo Industries Governor** is the rule worker. It runs separately from the desktop whenever at least one rule is on: saving or turning on a rule starts it, and its scheduled task starts it at sign-in and checks every minute, so a crashed or killed worker comes back and reconciles its journals. Turning off or deleting the last rule stops it, restores still-owned controls and removes the task. **Pause governor** restores still-owned controls and disables the task until **Start governor**; the pause is stored with the rules, so a restart cannot undo it. Opening or closing the desktop never changes enforcement. Rules and recovery state live under `%LOCALAPPDATA%\RooIndustriesOptimizationSuite\process-rules`, owned by Administrators with read-only access for the user; the elevated worker refuses a folder that anyone else can change. While a rule owns a process field, GameTune, Background limits, Background profiles, CPU Sets and Apply once skip or refuse that field with "Managed by the governor". The installer pauses the governor before replacing files and starts it again afterwards; uninstall stops it, restores its controls and removes its task, keeping the rules. Other administrators' governors on the same PC are stopped the same way, with restore, and registered again for their next sign-in. If setup is killed after it stopped the governor, a recovery task re-enables the governor once setup has exited. Governor requests reach `Optimizer.Host` on standard input; a request file is refused for rule, pause and stop actions. A rule cannot claim a field that a running game session controls, and a game session cannot start on a field an enabled or paused rule owns.

In **Apps & Cleanup → Remove apps**, select applications and review their published removal commands. The queue runs sequentially. Stop queue lets the current remover finish; Resume runs only untouched entries. Unknown outcomes require reconciliation. A restart requirement is satisfied only by a Windows boot after that remover's recorded creation time; an older reboot of a resumed queue is insufficient.

After removal, scan one app or all completed removals. Ownership checks retain the other apps saved in the removal queue even after their registrations disappear, alongside fresh installed-app inventory. Select exact file, folder, registry-key or registry-value candidates. Matching evidence is shown for each item; known shared owners, protected locations and incomplete subtree ownership block selection. Whole-key deletion requires explicit acceptance of its restoration limits. A separate preview and confirmation bind the cleanup to the reviewed resources.

Cleanup batches retain per-app progress. Stop after this app preserves unstarted entries; resume acknowledges the recorded cancellation without clearing a newer request. Cleanup history and restoration survive desktop restarts. Vendor removal itself is not reversible: recovery restores supported leftover data and does not reinstall the application.

Desktop operations and backups live under `%LOCALAPPDATA%\RooIndustriesOptimizationSuite\operations`. The whole data folder is writable only by Administrators and SYSTEM; the signed-in user can read it, and only `operations\windows-timer` stays writable for the sign-in timer task. Keep them until recovery is no longer needed. The ordinary `tools/scripts/Build-Frontend.ps1` build also publishes the required `Optimizer.Host` helper.

## Native helper

The app runs the compiled .NET 8 Windows x64 helper `Optimizer.Host` and passes each request on standard input. Requests are UTF-8 JSON with `schemaVersion: 1` and an absolute `repoRoot`. Mutating requests require `confirm: true`; reviewed paths and hashes remain separate from journals.

| Operation family | Actions | Additional input |
|---|---|---|
| Direct process controls | `process-status`, `process-preview`, `process-apply`, `process-restore` | PID; controls/semantic selection for preview; preview path/hash and journal for apply; journal for restore |
| Rules | `rules-list`, `rule-save`, `rule-delete` | Policy root; complete rule or rule ID |
| Worker | `policy-run`, `policy-stop`, `policy-status`, `policy-summary`, `policy-secure`, `policy-pause` | Policy root; `paused` for pause |
| Application cleanup | `cleanup-authority`, `cleanup-scan`, `cleanup-preview`, `cleanup-apply`, `cleanup-restore` | Queue journal/app ID; selected item IDs for preview; reviewed paths/hashes for execution |
| Cleanup batches | `cleanup-batch-preview`, `cleanup-batch-apply`, `cleanup-batch-cancel`, `cleanup-batch-restore` | Application operation references or batch review/journal; cancellation ID when resuming a stopped batch |

`Invoke-ProcessPolicyWorker.ps1` exposes Status, Sync, Pause, Resume and Remove for a policy folder; `Invoke-GovernorSetup.ps1` suspends, resumes and removes every governor task for the installer. It validates the task's owner/folder binding and observes the actual worker identity. A stale `running` journal is not evidence of a live worker.

## Control and cleanup limits

- CPU Sets express scheduling preferences. Thread-specific assignments and hard affinity may further restrict placement. Hard-affinity changes use one processor group; CPU Sets can represent multiple groups. Homogeneous efficiency classes cannot identify performance/efficiency cores.
- GPU priority is a per-process scheduling hint, not GPU-device affinity, and is not inherited by child processes. High I/O uses an NT interface whose availability depends on Windows and the token; errors remain explicit. No unsupported API result becomes an assumed default.
- Protected/excluded targets and access denial remain intact. Compatibility can be obtained by controlling eligible background workloads; these controls do not bypass an anti-cheat, inject into games, or promise zero ban risk.
- Discovery searches published installation locations, product/publisher data directories, package-family data, and current-user/machine Software registry views. Coverage is reported separately from candidate eligibility. Access failures, unsupported names, depth limits and the one-million-key limit remain visible; the scan does not claim those locations were inspected.
- Registry values bind exact raw type/data and native namespace. Unrelated parent timestamps do not invalidate a selected value. Whole-key reviews additionally bind the captured tree and metadata. Application registration, remover lifetime, reboot requirements and peer inventory are rechecked independently. Inventory changes require a new review.
- Registry deletion and receipt creation commit in one registry transaction. Before committed deletion, an uncommitted delete/restore rehearsal verifies the promised recoverable data and rolls back. Whole-key restoration recreates ordinary persistent keys and preserves captured owner, group and DACL; audit/integrity metadata, original volatility and original last-write times are not promised. Value-only operations preserve the parent object and its unrelated data.
- File execution retains verified ancestor/object handles, checks file identities and streams, flushes backups, and verifies them through a disposable restore before deletion. Supported data streams, attributes, timestamps and owner/group/DACL metadata are recorded. Reparse paths, multiple hard links, encrypted/compressed/sparse or unsupported storage cases remain excluded. Shared package payloads such as WindowsApps are not app leftovers.
- File-tree operations are not filesystem transactions. Unreviewed children and changed destinations are preserved, with partial outcomes retained for recovery. Restoring a partly completed directory uses its recorded identity and finalizes metadata only after its reviewed descendants are restored. Windows does not provide atomic compare-and-set for process controls; independent writers can race observations.

See the [process contracts](research/process-control-contracts.md), [registry contracts](research/registry-cleanup-contracts.md) and [measurement protocol](research/parity-validation.md) for the supporting API contracts and test cases.

## Launcher affinity and protected children

Windows child processes inherit their parent's hard-affinity mask. A launcher rule can therefore establish placement for a newly created child without opening that child to change its controls. This is a documented Windows mechanism, also described in Bitsum's anti-cheat guidance. It does not remove the child's access restrictions. [Microsoft affinity contract](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-setprocessaffinitymask), [Bitsum launcher guidance](https://bitsum.com/apps/process-lasso/docs/help/anti-cheat/).

In Process Control, select the actual running launcher, review **Set hard affinity**, then apply once or save a rule before launching the child. The rule affects every new child that inherits from that launcher, including unrelated helpers. A launcher can delegate creation to another process or specify a different affinity, so its process name alone is not evidence that a particular game inherited the selection. Restoring the launcher affects later launches; it does not reset an already running child's inherited mask. Relaunch that child after restoration when it needs the original placement.

`Test-ProcessInheritance.ps1` executes this path with a disposable launcher and children. It independently verifies the baseline mask, native launcher apply, inherited child mask, denied child control access, launcher restore and later-child inheritance. The child denies both process set-information access classes; the production adapter returns access denied without a privilege retry. A deliberately ineffective denial fixture fails the test. This models a Windows access boundary, not a specific anti-cheat implementation, and does not establish publisher approval or freedom from bans.

Do not generalize this affinity result to every other control. Process-default CPU Sets document inheritance by threads within that process; they are not proof of child-process placement. GPU priorities are not inherited. Normal creation-time priority semantics also differ from copying every parent priority class. Read each control back where allowed and retain an explicit unknown state where access is denied. [CPU Set thread contract](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-setprocessdefaultcpusets), [process inheritance](https://learn.microsoft.com/en-us/windows/win32/procthread/inheritance).

## CPU Sets

`Invoke-ProcessCpuSets.ps1` uses Windows' documented CPU Set APIs. Detection opens the target with `PROCESS_QUERY_LIMITED_INFORMATION` and `SYNCHRONIZE` (`0x101000`); changes additionally request `PROCESS_SET_LIMITED_INFORMATION` (`0x103000` combined). Synchronization provides an explicit liveness check; the live process exit FILETIME is not interpreted. One process handle covers identity checks, mutation and readback. The handle is opened under a temporary copy of the caller token with maximum privileges disabled, so an already enabled debug privilege cannot override the target access check. The original thread security context is restored even when the open fails. This uses Microsoft's [restricted-token API](https://learn.microsoft.com/en-us/windows/win32/api/securitybaseapi/nf-securitybaseapi-createrestrictedtoken) and preserves existing impersonation. There is no debug-privilege retry, process-memory access, injection, driver, or anti-cheat modification in this path.

CPU Set IDs are opaque identifiers returned by the operating system. They are not CPU indexes or bits in an affinity mask. The topology result includes processor group, logical processor index, core, cache and NUMA indexes, efficiency class, scheduling class, parking and allocation flags. Sets reserved for another process are rejected.

Inspect the topology and a target before selecting IDs:

```powershell
.\backend\scripts\Invoke-ProcessCpuSets.ps1 -Action Status
.\backend\scripts\Invoke-ProcessCpuSets.ps1 -Action Status -TargetProcessId $targetId
```

Create a preview using IDs from the current topology. The example paths are caller-owned operation storage, not temporary deletion targets:

```powershell
$preview = 'C:\RooIndustriesOperations\game-cpu-preview.json'
$journal = 'C:\RooIndustriesOperations\game-cpu-journal.json'
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
    -OutputPath 'C:\RooIndustriesOperations\bulk-preview.json'
```

`-Quiet` uses a published quiet command for registry applications. It does not invent silent switches. A saved inventory may be used for preview, but presence and registration bindings are checked against the actual Windows registry or Appx inventory before execution. Winget text rows without an exact installed identity have no removal adapter in this queue.

After review, execute the exact plan and retain its journal:

```powershell
$plan = 'C:\RooIndustriesOperations\bulk-preview.json'
$journal = 'C:\RooIndustriesOperations\bulk-journal.json'
$reviewHash = (Get-FileHash -LiteralPath $plan -Algorithm SHA256).Hash
.\backend\scripts\Invoke-BulkUninstall.ps1 -Action Apply -InputPath $plan `
    -ReviewSha256 $reviewHash -JournalPath $journal -ConfirmApply
```

Selections requiring dependency review also need `-ManualReviewApproved`. Protected selections remain excluded. An executable read lease prevents replacement between the final executable hash check and process launch. The exact registration fingerprint must still match the preview. A durable per-app claim prevents another queue from relaunching an unresolved removal. Real claims live under the current user's `LocalApplicationData\RooIndustriesOptimizationSuite\uninstall-claims`; fixture claims remain beneath their disposable root.

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

Reconciliation checks that the recorded process is no longer running and whether the exact registration is absent. An MSI reboot requirement remains pending until the current Windows boot time is later than that remover’s recorded process creation time. It dispatches nothing. A new confirmed `Apply` resumes untouched entries after cancellation or resolved completion; it never silently retries an attempted entry. If a registration remains after an attempted remover, retain the unresolved claim and investigate the vendor outcome. This version does not offer a force-retry override. Descendant processes and external installer services are not comprehensively tracked; a timeout or incomplete registration therefore never authorizes leftover deletion.

## Earlier file-cleanup interface

The queue ends with `cleanup-review-required` and never deletes leftovers. Run a new leftover scan, review shared ownership and current contents, and build a separate cleanup manifest. The same separation now applies to `Invoke-UninstallCleanupApplyPackage.ps1`: after running a vendor command, it returns fresh target content hashes and leaves the earlier cleanup list unapplied. A repeated call returns that recorded result without relaunching the vendor or deleting files.

`Invoke-RemovalLeftovers.ps1` scans the saved app metadata from a completed queue against the current filesystem. It checks queue ownership, the exact app identity, and current registration absence. A reinstalled app cannot reuse the old queue's cleanup approval. Older queues without saved app metadata cannot use this scan.

```powershell
.\backend\scripts\Invoke-RemovalLeftovers.ps1 -Action Scan `
    -QueueJournalPath $journal -AppId $appId
$cleanupPreview = 'C:\RooIndustriesOperations\leftover-review.json'
.\backend\scripts\Invoke-RemovalLeftovers.ps1 -Action Preview `
    -QueueJournalPath $journal -AppId $appId -ItemId $selectedLeftoverIds -OutputPath $cleanupPreview
$cleanupHash = (Get-FileHash -LiteralPath $cleanupPreview -Algorithm SHA256).Hash
.\backend\scripts\Invoke-RemovalLeftovers.ps1 -Action Apply `
    -QueueJournalPath $journal -AppId $appId -ReviewPath $cleanupPreview `
    -ReviewSha256 $cleanupHash -ConfirmApply -ManualReviewApproved
.\backend\scripts\Invoke-RemovalLeftovers.ps1 -Action Restore `
    -QueueJournalPath $journal -AppId $appId -ReviewPath $cleanupPreview `
    -ReviewSha256 $cleanupHash -ConfirmApply
```

File-only cleanup continues through the existing exact-target allowlist, backup and recovery journal. File restoration recovers backed-up leftovers; it cannot reinstall an application or reverse vendor registry/service changes. Path-based copying/deletion still has a filesystem race window against a concurrent hostile writer. The desktop now uses the native handle-based file and transactional registry path described above. This earlier file-only interface remains available for existing recovery records. Service deletion and install-time tracing are separate capabilities and are not implied by a file/registry scan.

## Cleanup exclusions

`Invoke-CleanupExclusions.ps1` manages the current Windows user's exclusions for Roo Industries's application cleanup. Each entry protects a local path and its descendants, a registry subtree, or one named registry value. A selected folder or whole key containing an excluded item is also protected. Discovery explains the exclusion in the item's evidence.

```powershell
$current = .\backend\scripts\Invoke-CleanupExclusions.ps1 -Action Status | ConvertFrom-Json
.\backend\scripts\Invoke-CleanupExclusions.ps1 -Action Save `
    -InputPath 'C:\RooIndustriesOperations\exclusions.json' `
    -ExpectedRevision $current.data.revision -ConfirmApply
```

The input file contains both lists, including empty lists when appropriate:

```json
{
  "paths": ["C:\\Users\\Example\\AppData\\Local\\ExampleApp\\SavedProjects"],
  "registry": [
    {
      "hive": "CurrentUser",
      "view": "Registry64",
      "keyPath": "Software\\ExampleApp",
      "kind": "value",
      "valueName": "License"
    }
  ]
}
```

Paths must be absolute local paths beneath a drive root. Registry entries use `CurrentUser` or `LocalMachine`, an explicit `Registry32` or `Registry64` view, and an exact Software subkey. A key entry has `kind: "key"` and `valueName: null`; an unnamed value has `kind: "value"` and `valueName: ""`.

The saved document is bound to the Windows user and machine. Saving requires the revision returned by the latest read; a stale editor cannot overwrite another update. Canonical file and native registry identities prevent short-path and shared-view aliases from bypassing exclusions. Missing future paths are resolved through their existing ancestors. Unreadable or unsupported identities produce an error for review.

Native application cleanup, cleanup batches, and the older file cleanup manifest/apply commands enforce exclusions. Apply checks the current list again, so adding an exclusion after preview stops further deletion. Already completed changes remain in their recovery journals. Restoration remains available if the exclusion list changes or becomes unreadable. Vendor removal executables control their own changes; these exclusions govern Roo Industries's subsequent cleanup.

## Restore selected applications

The native `cleanup-batch-restore` request accepts `restoreAppIds`, an array of exact application IDs from the saved batch. Each selected application's saved file and registry data is restored together. Omit the property to restore the whole batch; an explicit empty, duplicate or unknown selection is rejected before journal changes.

```json
{
  "schemaVersion": 1,
  "repoRoot": "C:\\RooIndustriesOptimizationSuite",
  "journalPath": "C:\\RooIndustriesOperations\\cleanup-batch-journal.json",
  "restoreAppIds": ["the-exact-app-id-from-the-batch"],
  "confirm": true
}
```

Run the request through `Optimizer.Host.dll cleanup-batch-restore <request.json>`. A successful subset returns `partiallyRestored` while other cleaned applications remain unchanged. Restore another selection or omit the selection to finish recovery. Errors retain `needsReconciliation` and the per-application result. Repeated recovery preserves already restored applications and their subsequent edits. Starting any recovery ends the batch's deletion phase permanently.

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
.\backend\scripts\Invoke-RooIndustriesCapability.ps1 -CapabilityId process-controls.cpu-sets `
    -Action preview -RequestPath 'C:\RooIndustriesOperations\request.json'
```

Mutating router actions additionally require `-ConfirmApply`. Router errors preserve the nested backend evidence. Default CPU Sets preview without a request detects topology; bulk preview without a request describes its required selection. A vendor uninstall has no restore route. Keep journals and reviewed inputs separate from output files.

## Upstream setting inventory

```powershell
.\backend\scripts\Get-UpstreamSettingsCatalog.ps1 -Source winutil -Limit 50
.\backend\scripts\Get-UpstreamSettingsCatalog.ps1 -Search 'CPU' -Offset 0 -Limit 100
.\backend\scripts\Get-UpstreamSettingsCatalog.ps1 -Collection applications -Limit 500
```

The inventory contains 376 setting/control records, 267 application/package records, and 1,319 {source} YAML records. Settings, packages, orchestration actions and inferred Dash symbols are separate collections. Filters return the filtered total and stable pages; no catalog entry automatically executes. Source snapshots and risks travel with the result. See the [research index](research/README.md) for provenance, edition distinctions and the limits of binary-symbol evidence.

## Verification

`Test-CleanupExclusions.ps1` exercises persisted preferences, stale updates, and the legacy deletion boundary. The Core cleanup and batch checks cover canonical aliases, late exclusions, independent recovery, selected applications, interrupted recovery, duplicate requests, and conflicting journal signals. `Test-OptimizerHost.ps1` exercises exclusions and selected restoration through the public commands with actual disposable removers.

`Test-OptimizerCore.ps1`, `Test-OptimizerHost.ps1`, `Test-ProcessPolicyWorker.ps1`, `Test-CleanupAuthority.ps1` and `Test-NativeGovernorRecovery.ps1` exercise the native controls, app/registry/file identity, batch recovery, worker lifetime and partial failures. Host tests create disposable installed-app records and vendor removers to use the production removal-to-cleanup path. `Measure-OptimizerPolicy.ps1` rebuilds the helper and records its binary hashes, worker startup, idle footprint and process-launch detection samples; its output states the presence of external controllers and the resulting comparison limits.

`Measure-OptimizerCpu.ps1 -OutputPath <file>` runs ten paired CPU-contention blocks using owned disposable processes and the real saved-rule host. It changes no power plan or system timer resolution and verifies the fixture's original priority before shutdown. Analyze the resulting JSON with `python tools/validation/analyze_cpu_measurement.py <file> --output <summary>`. `Test-CpuMeasurementAnalysis.ps1` checks the analysis guards without running a workload. See the [measured CPU result](research/parity-validation.md#measured-cpu-contention-result) for the observed effect and its limits.

`Measure-OptimizerStorage.ps1 -DiskSpdPath <exe> -OutputPath <new-file>` uses a verified DiskSpd 2.3 binary and disposable files to compare normal background I/O with a saved Low rule. `-Priority VeryLow` selects a separate experiment; results must not be combined across priorities. The harness checks live restoration, process exit, measured XML and unchanged file contents. Analyze with `python tools/validation/analyze_storage_measurement.py <file> --output <summary>`; `Test-StorageMeasurementAnalysis.ps1` checks its guards. The [measured Low-priority result](research/parity-validation.md#measured-storage-tradeoff) improved foreground latency at an unacceptable background-throughput cost under that workload.

`Measure-OptimizerGpu.ps1 -OutputPath <new-file>` compares normal and BelowNormal background GPU priority using owned offscreen compute workloads. The default adapter IDs select the 9070 XT; `-VendorId` and `-DeviceId` must identify the intended hardware. It verifies adapter identity, GPU output and priority recovery, keeping CPU completion timing separate from GPU timestamps. Analyze with `python tools/validation/analyze_gpu_measurement.py <file> --output <summary>`; `Test-GpuMeasurementAnalysis.ps1` checks its guards. The [measured GPU result](research/parity-validation.md#measured-gpu-contention-result) did not establish a benefit for that workload.

`Measure-OptimizerReference.ps1 -ReferenceGovernorPath <verified-exe> -RecoveryHeartbeatPath <active-guard-heartbeat> -OutputPath <new-file>` adds separate normal, Roo Industries and stock Process Lasso CPU conditions. The installed governor must already be stopped under an approved recovery guard; the measurement command does not stop services. It accepts only the pinned signed 18.3.0.34 reference, writes private settings, and rejects competing governors or unapplied rules. Both engines request 500 ms polling (`Performance.UpdateSpeedCore` for Lasso). Analyze with `tools/validation/analyze_reference_measurement.py`; its negative cases run through `Test-CpuMeasurementAnalysis.ps1`. Reference launch requires a space-free configuration path resolved through Windows short names. The benchmark installs no vendor software.

New reusable checks are `Test-ProcessCpuSets.ps1`, `Test-BulkUninstall.ps1`, `Test-InstalledAppIdentity.ps1`, `Test-NativeGovernorRestoreOwnership.ps1` and `Test-UpstreamSettingsCatalog.ps1`. The combined cleanup regression now includes a vendor fixture that changes an existing file and creates a new file. Tests use disposable processes, registrations represented by fixture markers, and isolated journals; actual installed applications are inventoried read-only.

The bulk tests also cover post-removal scan, reviewed file deletion, exact restoration, stale review hashes, reinstallation and cross-app rejection. `Test-ClientCleanupBoundary.ps1` compiles the desktop services into a disposable command-line test and checks recovery-ticket handling for live, ended, replaced and incomplete process identities.

Windows PowerShell 5.1 and the Windows APIs are the execution surfaces. Linux parsing and schema checks establish source/contract properties only. Vendor MSI/Appx removal, protected games, hardware performance, reboot behavior and UI journeys require separate Windows validation. Current task evidence and any pending machine access are kept in the development handoff rather than represented as product guarantees.

## Privacy and Explorer settings

`system-optimizations.windows-settings` exposes the first twelve shared Windows
settings through `Invoke-WindowsTweaks.ps1` and the native host. Profiles share
one original snapshot per native registry resource, with transactional target
and recovery updates. See [Windows tweaks](windows-tweaks.md) for the catalog,
request format, exact restore semantics, fixture checks, and coverage limits.
