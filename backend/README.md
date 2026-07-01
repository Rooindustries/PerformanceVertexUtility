# Backend Contracts

This folder contains backend contracts and read-only helper scripts for Roo Industries Optimization Suite.

The current PowerShell optimizer harness remains internal. These contracts define the structured shapes that a future WinUI app can consume while backend implementation is added behind preview, confirmation, backup, and rollback gates.

## Layout

| Folder | Purpose |
|---|---|
| `contracts` | Versioned JSON Schema definitions for backend responses and workflow models. |
| `samples` | Realistic fixtures for dashboard, process profiles, uninstall cleanup, drivers, telemetry, and reports. |
| `scripts` | Discovery, preview, controlled mock or fixture executors, gated apply/rollback helpers, and validation. |
| `uninstall` | Protected app catalog, leftover scan rules, and guarded uninstall cleanup policy. |

## Safety Boundary

Discovery, classification, preview, and validation scripts read local state and return structured JSON. Process profile and Game Tune scripts default to dry-run behavior. Confirmed Game Tune sessions can apply and restore process priority, CPU affinity, I/O priority, and GPU scheduling priority against matched processes after writing session state and a backup manifest.

The process governor backend adds bounded ProBalance-style restraint for sustained background CPU offenders. It previews by default, requires `-ConfirmApply` for live restraint, writes session state and backup snapshots before applying temporary priority or I/O priority changes, excludes protected and foreground processes, restores after calm periods, and supports status plus stop/restore commands.

The persistent process policy backend adds saved-rule enforcement during bounded sessions. It previews by default, supports process-name, wildcard-name, path, category, and command-line selectors, applies priority, affinity, I/O priority, and GPU scheduling priority controls through existing process-control primitives, watches for newly launched or relaunched matching processes, writes session state plus backup snapshots under the selected state root, and supports status plus stop/restore commands. Confirmed application is gated by explicit rule approval and allowed executable path roots, and protected game, capture, voice, driver, security, network, input, Store, WebView2, and Windows Update processes are skipped.

The uninstall cleanup backend can inventory apps, classify protected components, build uninstall queue previews, show official uninstall command metadata, preview leftover candidates, create dry-run cleanup manifests with backup/export requirements, run mock uninstaller and leftover-deletion runners, and delete only disposable fixture leftovers after explicit fixture flags. It does not run real uninstallers, delete real files or folders, edit registry keys, remove services, remove scheduled tasks, run driver cleanup tools, or write state during dry-run validation.

The NVIDIA NIP backend can preview NVPI export/import and restore commands and run a mock NVPI executor that proves export-before-import, rollback manifest writing, timeout handling, and hidden invocation. Real NVIDIA Profile Inspector execution remains blocked unless a future audited flag and runner are explicitly supplied.

The {source} and WinUtil parity backend can preview standby memory, timer resolution, power plan, shader cache, and service pause contracts. Mock runners cover the system-changing flows; disposable fixture execution is limited to shader cache backup/delete/restore under the OS temp path. Real system-changing stutter optimizations remain blocked.

These backend scripts do not disable services, edit the registry, delete files, uninstall applications, install drivers, create scheduled tasks, create services, run remote scripts, or apply driver/profile tools.

Run validation:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\backend\scripts\Test-BackendContracts.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\backend\scripts\Test-ProcessProfileBackend.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\backend\scripts\Test-GameTuneSessionRuntime.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\backend\scripts\Test-ProcessGovernorRuntime.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\backend\scripts\Test-ProcessPolicyRuntime.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\backend\scripts\Test-UninstallCleanupBackend.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\backend\scripts\Test-NvidiaNipExecutor.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\backend\scripts\Test-UninstallCleanupRunnerContracts.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\backend\scripts\Test-StutterOptimizationExecutorContracts.ps1
```
