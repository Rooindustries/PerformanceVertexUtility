# Lean Client Optimizer

Lean Client Optimizer is a Windows performance and cleanup tool focused on smooth gameplay under memory pressure. It is being built around safe previews, backups, rollback, process-profile tuning, uninstall cleanup, driver/profile recommendations, and practical system diagnostics.

The current repository contains the first benchmark-and-rollback harness. The desktop app layer will build on the same safety model.

## Safety Model

- Default module runs are dry-run only.
- Real changes require `-ConfirmApply`.
- Every module creates a backup first.
- Rollback restores saved registry values and service startup states.
- Protected services and protected registry patterns are blocked by the manifest.
- The harness is compatible with Windows PowerShell 5.1.

## Quick Start

Run from this folder:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\LeanClientOptimizer.ps1 -Action ListModules
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\LeanClientOptimizer.ps1 -Action ToolInventory
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\LeanClientOptimizer.ps1 -Action Baseline
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\LeanClientOptimizer.ps1 -Action SmokeTest
```

Dry-run a module:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\LeanClientOptimizer.ps1 -Action ApplyModule -ModuleId M3-safe-services
```

Actually apply a module:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\LeanClientOptimizer.ps1 -Action ApplyModule -ModuleId M3-safe-services -ConfirmApply
```

Rollback the latest backup for a module:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\LeanClientOptimizer.ps1 -Action RollbackModule -ModuleId M3-safe-services -ConfirmApply
```

Generate a basic report:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\LeanClientOptimizer.ps1 -Action Report
```

## Modules

| Module | Purpose | Default |
|---|---|---|
| `M2-safe-registry` | Ads/search/Copilot/AI/feedback/Game DVR/visual registry cleanup | Safe |
| `M3-safe-services` | Low-risk Windows service trim | Performance |
| `M4-optional-common-services` | Xbox, printing, hotspot, search, Office, third-party helpers, Mixed Reality | Ask |
| `M5-vendor-helper-trim` | Intel/vendor helpers that need device testing | Ask |
| `M6-svchost-grouping` | Advanced `svchost` process-count reduction | Advanced |

## Data Locations

Default data root:

```text
C:\ProgramData\LeanClientOptimizer
```

Subfolders:

| Folder | Contents |
|---|---|
| `baselines` | Clean snapshots |
| `backups` | Per-module rollback data |
| `runs` | Apply/dry-run results |
| `smoke` | Smoke-test results |
| `reports` | HTML reports |

## Recommended Test Flow

1. Run `Baseline` three times on clean boots.
2. Run `SmokeTest`.
3. Dry-run `M2-safe-registry`.
4. Apply `M2-safe-registry`, reboot, run `Baseline` and `SmokeTest`.
5. Repeat for `M3-safe-services`.
6. Test optional modules one at a time.
7. Only combine modules that pass alone.

## Development Status

This project is under active development. High-risk workflows remain preview, confirmation, and rollback gated.
