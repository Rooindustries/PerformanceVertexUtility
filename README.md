# Performance Vertex Utility

Performance Vertex Utility is a free, open-source Windows performance and cleanup tool focused on smooth gameplay under memory pressure. It is being built around safe previews, backups, rollback, process-profile tuning, uninstall cleanup, driver/profile recommendations, and practical system diagnostics.

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

Leave off `-ConfirmApply` to preview rollback. The result lists settings it would restore in `actions`, and settings it would leave alone in `leftAsChanged`, with their registry path and value name or service name. The restore counts exclude settings left alone; in a preview, they count the planned restores. `success=true` means no failures occurred; settings listed in `leftAsChanged` were kept as they are.

Confirmed apply writes the registry kind declared in the manifest, replacing an existing different kind. For example, applying a DWORD setting to an existing text value now makes it a DWORD. Earlier harness versions could keep the existing kind. The setting values in the manifest are unchanged.

Rollback restores a registry value only while its kind and data still match what the module applied. A later edit or deletion stays as it is, with a `Left as changed` notice. New backups preserve the original value kind and raw data, including unexpanded environment variables, multi-string arrays, full-width DWORD and QWORD values, and binary data. Each restore is read back and checked. If an original cannot be backed up and restored exactly, apply stops before changing any setting. This includes unsupported kinds, unpaired Unicode surrogates, text whose raw bytes .NET would normalize, and numeric payloads that are not exactly four bytes for DWORD or eight for QWORD. Embedded NULs, extra terminators and empty MultiString elements remain supported when their stored bytes round-trip exactly. A registry read that changes kind or size between queries also stops the operation; the original data stays untouched.

If another program writes raw data that this harness could not have produced, rollback leaves that value alone and continues restoring independent settings. Read errors, inconsistent managed and native reads, invalid original evidence for an eligible restore, and failed readback still stop rollback safely. Invalid Unicode remains a read failure even when the byte layout matches the writer.

Service rollback checks the startup type against the one saved for apply before restoring or restarting that service. Changed or missing services are left alone. Protected registry values and services are left alone even if an older backup includes them.

Older registry backups without a saved kind cannot prove the kind that apply wrote to an existing value. Rollback leaves those values alone and lists the missing evidence in `leftAsChanged.reason`; text and numeric JSON values cannot fill that gap. The original backup stays available for manual recovery. A value recorded as absent before apply can still be removed when its current kind and data match the old creation contract. Older service backups without the applied startup type are also left alone. Missing or invalid original-existence evidence is reported and grants no restore or deletion.

For custom manifests, an empty value name selects the actual default value; `(default)` is a literal value name. Older harness versions treated `(default)` as an alias. Rollback leaves legacy default aliases alone when the backup lacks a `kind` field, because those records cannot prove whether the original default existed. New-format backups keep the exact value name and can restore or remove it normally.

Rollback checks selected originals and service startup types before writing. An existing registry value needs an exact supported kind and non-null data in the saved format. Text, arrays, unsigned numbers and encoded data must keep their original shape and canonical encoding; empty strings and arrays remain valid. A preflight error leaves all settings untouched. If a write or readback fails, rollback stops and returns `success=false`, the verified restore counts, `failures`, and untouched `pending` settings. `partial=true` means writes were attempted and settings may have changed. The CLI reports an error and keeps the original backup. A retry checks current state again: exact values already matching the backup appear in `alreadyAtOriginal`, while later edits stay untouched. Rollback does not promise a transaction across registry values and services.

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

Same-repository pull requests and pushes to `main` run the baseline contracts, the validation unit tests, the PowerShell parse and Windows PowerShell 5.1 syntax check, and a Linux build of the C# projects on the self-hosted Linux runner. Fork pull requests skip these jobs and need isolated local validation. The Windows regression suite runs in three parallel shards on GitHub-hosted Windows on manual runs of the Baseline workflow, and on pushes to `main` while the repository variable `HOSTED_WINDOWS_CI` is `true`.

The desktop project is under `docs/internal/frontend/RooIndustries.OptimizationSuite.App`. Build it with `tools/scripts/Build-Frontend.ps1`; the .NET 8 SDK is required. Building does not launch the app. Capture and inspect screenshots whenever the app is launched for a UI check.

See [desktop controls](docs/optimization-controls.md#desktop-workflows) for CPU selection, queued app removal, separate leftover cleanup, and recovery.

## Credits

This app is built on other people's work. [CREDITS.md](CREDITS.md) lists the projects, tools, libraries and fonts it draws from, with links and licenses.

Made and maintained by Roo Industries.
