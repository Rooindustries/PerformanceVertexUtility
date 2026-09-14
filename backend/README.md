# Backend

The backend provides Windows discovery, process controls, cleanup planning, driver and utility inventory, and structured preview/apply/restore results. The desktop consumes the same scripts and contracts.

## Layout

| Location | Responsibility |
|---|---|
| `scripts` | Discovery, execution, recovery, and regression checks |
| `native` | Process governor and standby-memory helpers |
| `contracts` | JSON Schema definitions and explicit validation mappings |
| `capabilities` | Capability descriptions and executor routes |
| `catalogs` | Driver profiles, utility inventory, and optimization references |
| `profiles` | Process policies and protected-process rules |
| `uninstall` | Dependency-review policy and leftover selection rules |
| `samples` | Curated examples; current-PC screens use live discovery |

## Execution and recovery

Discovery and default previews do not change system settings. Process controls require confirmed apply, capture original state, bind targets to process identity, and provide restore commands. Runtime validation uses disposable processes and temporary state roots.

`Invoke-UninstallCleanupApplyPackage.ps1` can run an explicitly reviewed official uninstaller or perform a separately reviewed file cleanup. After vendor removal it returns `cleanup-review-required` with a fresh content scan, leaving the earlier deletion list unapplied. File-only cleanup requires one matching app identity, hashes of the reviewed input files, explicit approvals, and separate dependency-review approval where required. Protected leftovers, unsupported item types, overlapping targets, and unsafe backup locations are rejected. The caller must retain the reviewed inputs; rebuilding them at apply time is not approval of the new contents.

Cleanup copies originals and flushes a recovery journal before destructive work. Each attempted deletion is recorded before execution. Partial failures return the saved journal and actual completed-deletion count. Repeating the same saved operation does not run it again. Restore copies backup contents to their original paths and can be retried. This restores backed-up leftovers; it does not reinstall an application removed by its vendor uninstaller. Keep recovery storage outside temporary directories and deletion targets.

NVIDIA imports and hardware-specific utilities retain their explicit approval and tool requirements. Several catalog entries support discovery, preview, or a disposable fixture rather than unrestricted real execution. Timer-resolution and temporary power-plan validation exercise bounded reversible paths. Service, registry, and driver changes must not be inferred from a capability label or a successful preview.

Supported CPU Sets, durable bulk removal, and the sourced settings inventory are described in [Optimization controls](../docs/optimization-controls.md). The [research index](../docs/research/README.md) separates documented upstream behavior, inferred controls, implementation coverage, and remaining validation.

## Validation

Install Python 3.10+ and the development requirements:

```console
python -m pip install -r tools/validation/requirements.txt
python tools/validation/check_baseline.py
```

The static checker validates declared schemas, their mapped fixtures, route manifests, JSON syntax, XML structure, public-source hygiene, and empty runtime state. `validation-map.json` names the domain checks for curated examples without a dedicated schema; schema coverage is reported separately.

On Windows, run the complete suite in an isolated source copy:

```powershell
.\tools\scripts\Test-Baseline.ps1 -BuildFrontend
```

Set `ROO_PYTHON_EXE` or `ROO_DOTNET_EXE` when the development interpreters are outside `PATH`. Desktop compilation needs the .NET 8 SDK. The suite invokes Windows PowerShell 5.1, captures one log per test and a JSON summary under ignored `artifacts/validation`, and checks that `backend/state` is empty. It does not launch the WinUI app.

Run individual regressions with `-TestName`:

```powershell
.\tools\scripts\Test-Baseline.ps1 -TestName Test-LegacyModuleRollback.ps1,Test-UninstallCleanupApplyPackage.ps1
```

From Linux, configure a Windows SSH alias with its own authorized key and use the direct helper:

```console
python3 tools/validation/windows_ssh.py --host windows-test --expected-machine TEST-PC inspect
python3 tools/validation/windows_ssh.py --host windows-test --expected-machine TEST-PC upload
python3 tools/validation/windows_ssh.py --host windows-test --expected-machine TEST-PC run validation.ps1
```

The helper disables SSH proxying, checks the Windows computer name before writes, and preserves argument boundaries through encoded PowerShell. Upload includes tracked working-tree source and a SHA-256 manifest under the current Windows user's Temp directory; it excludes frontend sources. Add new source files to Git before uploading them. The returned staging path can be used by a trusted validation script that runs `Test-Baseline.ps1` and verifies the manifest before and after testing. Retrieve results before removing the owned staging directory.

A green build or fixture suite does not establish real-provider operation, real uninstall success, a performance gain, or visual quality. Record those separately on the relevant Windows machine.
