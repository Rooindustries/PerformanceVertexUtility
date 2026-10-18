# Roo Industries Optimization Suite

Roo Industries Optimization Suite is a Windows performance and cleanup tool focused on smooth gameplay under memory pressure. It is being built around safe previews, backups, rollback, process-profile tuning, uninstall cleanup, driver/profile recommendations, and practical system diagnostics.

The repository contains a WinUI desktop app, a PowerShell backend, native Windows helpers, and the original benchmark-and-rollback harness. Backend execution and the desktop share versioned contracts and explicit preview, approval, and recovery paths.

## Safety Model

- Default module runs are dry-run only.
- Real changes require `-ConfirmApply`.
- Confirmed module application creates a backup before changing settings; previews do not create rollback snapshots.
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

Rollback the latest confirmed-apply backup for a module:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\LeanClientOptimizer.ps1 -Action RollbackModule -ModuleId M3-safe-services -ConfirmApply
```

To select an older operation explicitly, supply `-BackupPath` with its `backup.json`. A backup must belong to the requested module. Unproven legacy snapshots require explicit selection.

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

## Development baseline

Linux is the development host. Windows compilation and runtime checks run from isolated source copies on the NVIDIA and AMD test PCs. See [backend validation](backend/README.md#validation) for the repeatable commands and [development workflow](docs/development-workflow.md) for the baseline boundaries.

Every pull request runs the baseline contracts, the validation unit tests, the PowerShell parse and Windows PowerShell 5.1 syntax check, and a Linux build of the C# projects. The Windows regression suite runs in three parallel shards on pushes to `main` and on manual runs of the Baseline workflow.

The desktop project is under `docs/internal/frontend/RooIndustries.OptimizationSuite.App`. Build it with `tools/scripts/Build-Frontend.ps1`; the .NET 8 SDK is required. Building does not launch the app. Capture and inspect screenshots whenever the app is launched for a UI check.

See [desktop controls](docs/optimization-controls.md#desktop-workflows) for CPU selection, queued app removal, separate leftover cleanup, and recovery.

## Credits

This app is built on other people's work. [CREDITS.md](CREDITS.md) lists every project, tool, library and font it draws from, with links and licenses.

Made and maintained by Roo Industries.
