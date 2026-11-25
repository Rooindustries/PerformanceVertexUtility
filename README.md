# Performance Vertex Utility

Performance Vertex Utility is a free, open-source Windows performance and cleanup tool focused on smooth gameplay under memory pressure. It is being built around safe previews, backups, rollback, process-profile tuning, uninstall cleanup, driver/profile recommendations, and practical system diagnostics.

The repository contains a WinUI desktop app, a PowerShell backend, native Windows helpers, and the original benchmark-and-rollback harness. Backend execution and the desktop share versioned contracts and explicit preview, approval, and recovery paths.

## Safety Model

- Default module runs are dry-run only.
- Real changes require `-ConfirmApply` and the saved preview you reviewed (`-PreviewPath`).
- Confirmed module application creates a backup before changing settings; previews do not create rollback snapshots.
- Rollback restores saved registry values and service startup states. It also restarts services that were running before apply stopped them, including dependent services that stopped with them.
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

The result lists every planned change and a `previewPath`, the saved copy of that plan.

Actually apply the module you previewed:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\LeanClientOptimizer.ps1 -Action ApplyModule -ModuleId M3-safe-services -ConfirmApply -PreviewPath <previewPath>
```

Apply checks that the module still plans exactly what the preview showed: each registry path, value name, type and data, each service's startup and state, and which settings are protected or skipped. If the manifest or the PC's Windows edition changed what the module would do since the preview, apply stops before it backs up or changes anything and lists what changed. Apply also refuses without `-PreviewPath`, with a preview of another module, or with a preview from an earlier harness version, which has no plan hash. Preview again in those cases. The same preview can be applied again after a rollback. Values on the PC may change after the preview; apply backs up whatever is there when it runs.

Some policies only work on some Windows editions. The harness reads those limits from `backend/catalogs/windows-policy-editions.json`, the same file the app uses, and checks this PC's edition and build. A value Windows ignores here, such as the tips and spotlight policies in `M2-safe-registry` on Home and Pro, shows in the preview with `skipped` and the reason, and apply neither backs it up nor writes it. Enterprise, Education, IoT Enterprise and Server still get them. Rollback of an earlier apply that wrote such a value still restores it.

Manifest registry entries must declare `REG_DWORD`, `REG_QWORD` or `REG_SZ`, in any letter case. Any other type, a missing type, or data the type can't hold (such as a negative DWORD) stops the preview and the apply before any change and names the setting. Earlier versions wrote other types as `REG_SZ`; rollback still undoes those applies.

A module that stops a service is refused in preview and apply when a protected service depends on that service, directly or through another dependent. Stopping it would stop the protected service too, and rollback doesn't restart protected services.

If a confirmed apply fails after it saved its backup, the PC may be partly changed. The error says so, names the backup, tells you to run rollback with `-BackupPath` and that backup before applying again, and ends with the original error. Until that rollback succeeds, another confirmed apply of the module stops before it backs up or changes anything and names the same backup. A rollback preview or a failed rollback doesn't lift this. Rolling back the latest backup also picks it.

Rollback the latest confirmed-apply backup for a module:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\LeanClientOptimizer.ps1 -Action RollbackModule -ModuleId M3-safe-services -ConfirmApply
```

To select an older operation explicitly, supply `-BackupPath` with its `backup.json`. A backup must belong to the requested module. Unproven legacy snapshots require explicit selection.

Leave off `-ConfirmApply` to preview rollback. The result lists settings it would restore in `actions`, and settings it would leave alone in `leftAsChanged`, with their registry path and value name or service name. The restore counts exclude settings left alone; in a preview, they count the planned restores. `success=true` means no failures occurred; settings listed in `leftAsChanged` were kept as they are.

Confirmed apply writes the registry kind declared in the manifest, replacing an existing different kind. For example, applying a DWORD setting to an existing text value now makes it a DWORD. Earlier harness versions could keep the existing kind. The setting values in the manifest are unchanged.

Rollback restores a registry value only while its kind and data still match what the module applied. A later edit or deletion stays as it is, with a `Left as changed` notice. New backups preserve the original value kind and raw data, including unexpanded environment variables, multi-string arrays, full-width DWORD and QWORD values, and binary data. Each restore is read back and checked. If an original cannot be backed up and restored exactly, apply stops before changing any setting. This includes unsupported kinds, unpaired Unicode surrogates, text whose raw bytes .NET would normalize, and numeric payloads that are not exactly four bytes for DWORD or eight for QWORD. Embedded NULs, extra terminators and empty MultiString elements remain supported when their stored bytes round-trip exactly. A registry read that changes kind or size between queries also stops the operation; the original data stays untouched.

If another program writes raw data that this harness could not have produced, rollback leaves that value alone and continues restoring independent settings. Read errors, inconsistent managed and native reads, invalid original evidence for an eligible restore, and failed readback still stop rollback safely. Invalid Unicode remains a read failure even when the byte layout matches the writer.

Only one confirmed Apply or Undo runs on a PC at a time, for any module or backup. Each takes a machine-wide lock before it reads or creates a backup. Apply holds it from creating its backup through every setting change, so an Undo can't act on a backup whose apply is still changing services. Undo holds it from choosing a backup through every restore and saved marker. Another confirmed Apply or Undo waits up to two seconds, then stops without changing anything and says another one is running. The lock is released when the operation finishes, fails or its process exits. Previews take no lock. Undo reads and updates the selected `backup.json` itself: a backup that is a symbolic link, or that has another hard link, is refused before any change, because updating one name could leave a stale copy under the other.

Service rollback checks the startup type against the one saved for apply before changing it. For a service that was Running, rollback must observe both the original startup type and Running before counting it as restored. A failed start or readback stops rollback and leaves later settings pending. If startup already matches the original but the service is no longer Running, rollback leaves it alone and reports the missing runtime ownership evidence. A retry cannot distinguish a failed start from another program stopping the service. Other original runtime states keep the earlier startup-only behavior; rollback does not stop, pause or resume them. Stopping a service also stops the services that depend on it. The backup records each of those dependents first. Right after the stop, apply checks each one that was running and saves whether it is now stopped. If a service refuses to stop, apply saves the same check, then fails with the partly-changed error above, which ends with the stop error. If saving the check fails too, the stop error is still the one reported. Rollback starts only the dependents apply confirmed it stopped, after the service they depend on is back. A dependent without that record, from a refused stop, an apply that ended before saving it or an older backup, is left as it is and listed in `leftAsChanged`. Confirmed rollback saves each dependent's restore attempt atomically before starting it; if that save fails, the dependent stays stopped. It saves completion as soon as it verifies or observes the original state. If an interrupted Undo or a failed completion save leaves a dependent Running, the next confirmed Undo records completion and resumes dependents whose restart was never attempted. If that dependent is Stopped instead, Undo leaves it stopped, reports that another program may have stopped it after the earlier attempt, and keeps the backup evidence. Later stops also stay untouched after a completed Undo, including across process restarts. Previews never update these records. A dependent whose startup or state changed since, or whose own dependencies aren't running, is left alone and listed in `leftAsChanged`. Changed or missing services are left alone. Protected registry values and services are left alone even if an older backup includes them.

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
| `runs` | Apply results and saved previews |
| `smoke` | Smoke-test results |
| `reports` | HTML reports |

## Recommended Test Flow

1. Run `Baseline` three times on clean boots.
2. Run `SmokeTest`.
3. Dry-run `M2-safe-registry`.
4. Apply that `M2-safe-registry` preview with `-PreviewPath`, reboot, run `Baseline` and `SmokeTest`.
5. Repeat for `M3-safe-services`.
6. Test optional modules one at a time.
7. Only combine modules that pass alone.

## Development Status

This project is under active development. High-risk workflows remain preview, confirmation, and rollback gated.

## Development baseline

Linux is the development host. Windows compilation and runtime checks run from isolated source copies on the NVIDIA and AMD test PCs. See [backend validation](backend/README.md#validation) for the repeatable commands and [development workflow](docs/development-workflow.md) for the baseline boundaries.

Pushes to `main` and the pull requests GitHub runs, from this repository or from a fork, run the baseline contracts, the validation unit tests, the PowerShell parse and Windows PowerShell 5.1 syntax check, and a Linux build of the C# projects on GitHub-hosted Linux runners. The Windows regression suite runs in three parallel shards on GitHub-hosted Windows on manual runs of the Baseline workflow, and on pushes to `main` while the repository variable `HOSTED_WINDOWS_CI` is `true`.

The desktop project is under `docs/internal/frontend/RooIndustries.OptimizationSuite.App`. Build it with `tools/scripts/Build-Frontend.ps1`; the .NET 8 SDK is required. Building does not launch the app. Capture and inspect screenshots whenever the app is launched for a UI check.

See [desktop controls](docs/optimization-controls.md#desktop-workflows) for CPU selection, queued app removal, separate leftover cleanup, and recovery.

## Credits

This app is built on other people's work. [CREDITS.md](CREDITS.md) lists the projects, tools, libraries and fonts it draws from, with links and licenses.

Made and maintained by Roo Industries.

## License

Performance Vertex Utility is free and open-source software under the GNU General Public License version 3 only. The full text is in [LICENSE](LICENSE).

Anyone may use, change and share the GPL-covered software. If you distribute it, changed or unchanged, you must keep the GPL rights of the people you give it to and make the corresponding source code available, the way the GPL requires.

Roo Industries holds the copyright in its own Performance Vertex Utility software.

The Roo Industries and Performance Vertex Utility names and logos are not covered by that license.

Some third-party material in the app stays under its owners' terms and is outside the GPL grant for Performance Vertex Utility: the O&O ShutUp10++ setting titles, the WPD setting titles, the Adobe host list and the 28 third-party tool icons on the Tools page. They are listed in [CREDITS.md](CREDITS.md#not-covered-by-this-projects-license).

The app changes Windows settings and comes with no warranty. See sections 15 and 16 of the license.

Additional permission under GNU GPL version 3 section 7

If you modify this Program, or any covered work, by linking or combining it with the Microsoft Windows App SDK, the Windows SDK, the Microsoft Edge WebView2 runtime, the Microsoft Visual C++ runtime or the .NET runtime (or a modified version of those libraries), containing parts covered by the terms of those libraries' licenses, the licensors of this Program grant you additional permission to convey the resulting work.
