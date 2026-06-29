# Backend Contracts

This folder contains backend contracts and read-only helper scripts for Roo Industries Optimization Suite.

The current PowerShell optimizer harness remains internal. These contracts define the structured shapes that a future WinUI app can consume while backend implementation is added behind preview, confirmation, backup, and rollback gates.

## Layout

| Folder | Purpose |
|---|---|
| `contracts` | Versioned JSON Schema definitions for backend responses and workflow models. |
| `samples` | Realistic fixtures for dashboard, process profiles, uninstall cleanup, drivers, telemetry, and reports. |
| `scripts` | Discovery, preview, gated apply/rollback helpers, and validation. |
| `uninstall` | Protected app catalog, leftover scan rules, and preview-only uninstall cleanup policy. |

## Safety Boundary

Discovery, classification, preview, and validation scripts read local state and return structured JSON. Process profile apply and rollback scripts default to dry-run behavior. Real process priority changes require `-ConfirmApply`, save a backup manifest first, and only change `PriorityClass` in this MVP.

The uninstall cleanup backend is preview-only in this MVP. It can inventory apps, classify protected components, build uninstall queue previews, show official uninstall command metadata, preview leftover candidates, and create dry-run cleanup manifests with backup/export requirements. It does not run uninstallers, delete files or folders, edit registry keys, remove services, remove scheduled tasks, run driver cleanup tools, or write state during dry-run validation.

These backend scripts do not disable services, edit the registry, delete files, uninstall applications, install drivers, create scheduled tasks, create services, run remote scripts, or apply driver/profile tools.

Run validation:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\backend\scripts\Test-BackendContracts.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\backend\scripts\Test-ProcessProfileBackend.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\backend\scripts\Test-UninstallCleanupBackend.ps1
```
