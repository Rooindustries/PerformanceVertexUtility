# Performance Vertex Utility

Performance Vertex Utility is a free, open-source Windows tuning tool for smooth gameplay: safe previews, backups and rollback, process tuning, uninstall cleanup, driver and profile recommendations, and diagnostics. It's a WinUI desktop app (`docs/internal/frontend`), a PowerShell backend (`backend/scripts`), native C# helpers (`backend/native`) and the original benchmark-and-rollback harness (`LeanClientOptimizer.ps1`). It's made and maintained by Roo Industries.

## What can never break

Users run this on the PC they game on. These come before any feature.

### 1. Every change has a backup and an undo

Nothing changes a PC without a preview first. Module runs are dry-run unless `-ConfirmApply` is passed, a confirmed apply saves a backup before it touches anything, and rollback restores it. Backend actions go through explicit preview, approval and recovery paths. A change with no working way back is a bug.

### 2. No surprise defaults

What a PC gets by default (module defaults, profiles, presets, catalog choices) changes only on purpose, and the PR says so in its first line.

### 3. Every Windows edition

Catalog settings list the editions and builds they apply to: Home (Core), Pro, Enterprise, Education and Server. A setting a PC can't use shows as not available on that PC, never as an error or a retry that can't work.

### 4. No telemetry

The app sends no usage data. It goes online only to check for updates and download them (automatic downloads can be turned off), to download a tool the user picks, and to send a bug report when the user clicks Send. In this codebase "telemetry" means local performance readings.

### 5. Windows PowerShell 5.1

Backend scripts run on the Windows PowerShell 5.1 that ships with Windows. `tools/validation/check_powershell.ps1` checks 5.1 syntax.

## Ways to hurt a PC

- Validation never runs real app uninstallers, deletes user data, imports real NVIDIA profiles, or changes services, registry settings or drivers as a side effect. Use disposable fixtures and probe processes, and remove everything you create, registry values included, in `finally`.
- Clean up test-owned processes, fixtures, helpers and temporary power plans. `backend/state` must stay empty.
- Keep personal and test-machine identifiers (user folders, emails, private addresses, machine names) out of the repo. The baseline check fails on them.
- Keep Windows paths short. Windows PowerShell 5.1 can't open paths over 259 characters, and long user folders get close.

## Prove a change on Linux

Linux is the development host. These are the four Baseline jobs every pull request and push to `main` runs on the self-hosted Linux runner (`runs-on: [self-hosted, laptop]`):

```sh
python -m pip install -r tools/validation/requirements.txt
python tools/validation/check_baseline.py
python -m unittest discover -s tools/validation -p 'test_*.py'
pwsh tools/validation/check_powershell.ps1   # needs PSScriptAnalyzer 1.25.0
python tools/validation/build_dotnet.py      # needs the .NET 8 SDK
```

If GitHub Actions can't start them, run them on the PR's head commit and post the results on the PR.

## What needs real Windows

Anything that reads or changes the registry, services, process, I/O or GPU priority, drivers or the desktop app. The Baseline workflow's Windows matrix runs on GitHub-hosted Windows only on a manual run, or on pushes to `main` while the repository variable `HOSTED_WINDOWS_CI` is `true`. Run the backend suites from an isolated source copy on a Windows test PC:

```powershell
.\tools\scripts\Test-Baseline.ps1 -TestName Test-LegacyModuleRollback.ps1
.\tools\scripts\Test-Baseline.ps1 -BuildFrontend
```

From Linux, `tools/validation/windows_ssh.py` checks the machine name, stages tracked source and runs a validation script (see `backend/README.md`). Add `--include-frontend` for suites that compile desktop sources. Test the AMD and NVIDIA paths on their own PCs; one doesn't prove the other. Compiling the app isn't a UI check: launch it, take screenshots and look at them.

## How we ship

- Small PRs, one fix each, on a branch from `main`, with conventional commit subjects (`fix:`, `test:`, `docs:`).
- The PR's first line says what a user would notice.
- Reproduce a bug before fixing it, and prove the fix with a check that fails before and passes after, on the platform where the bug lives.
- Update any doc the change makes wrong. See `docs/development-workflow.md` for the full workflow.
