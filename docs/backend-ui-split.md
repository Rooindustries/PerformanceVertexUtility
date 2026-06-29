# Backend And UI/UX Split

Captured: June 28, 2026

## Ownership Principle

Backend ownership covers reliability, safety, Windows integration, data contracts, and validation.

Frontend ownership covers the UI and UX implementation: layout, interaction design, visual polish, responsiveness, page composition, and product feel.

The split should let the frontend be built as a professional Roo Industries WinUI experience without requiring UI code to guess how system actions work, while backend code keeps risky Windows behavior deterministic, reversible, tested, and documented.

## Backend Owns

### Backend Architecture

- Project structure for backend services, models, manifests, and command execution.
- Stable interfaces between the WinUI frontend and backend actions.
- Versioned data contracts for modules, performance profiles, uninstall inventory, driver catalogs, reports, and telemetry.
- Local storage layout under app data and `C:\ProgramData\LeanClientOptimizer`.

### Safety And Reliability

- Backup creation.
- Rollback logic.
- Restore-point strategy where appropriate.
- Confirmation gates for risky actions.
- Protected process/service/registry/device lists.
- Dry-run and preview behavior.
- Error handling and recovery paths.
- Logging and audit trails.

### Process Lasso Replacement Backend

- Process discovery.
- Protected process classification.
- Priority/profile rules.
- Affinity rules where safe and reversible.
- Foreground game detection.
- Tourney Mode backend behavior.
- Profile apply/disable/rollback.
- Future runtime service or scheduled task design.

### Revo-Style Uninstaller Backend

- Installed app inventory from registry, MSI, Appx, winget, and uninstall metadata.
- Multi-select uninstall queue execution.
- Official uninstall command handling.
- Leftover scan logic for folders, files, services, scheduled tasks, startup entries, and registry references.
- Deletion preview data.
- Confirmed cleanup execution.
- Deleted item manifest and rollback/export paths.

### Driver And Profile Backend

- Hardware detection.
- Installed driver detection.
- Driver catalog schema.
- Game-tagged recommendation data.
- NVIDIA Profile Inspector profile catalog.
- DDU/NVCleanstall/manual installer gating.
- Benchmark/provider integration where possible.

### Existing Optimizer Harness

- `LeanClientOptimizer.ps1` maintenance.
- Baseline, smoke test, dry-run, apply, rollback, and report execution.
- Module manifest validation.
- Protected services and registry pattern enforcement.

### WinUtil And Utilities Integration

- WinUtil config sync/vendor strategy.
- Normalized source catalog.
- Risk labeling.
- Execution backend only after audit.
- Utilities archive detection and safe launcher contracts.

### Testing

- Backend unit/integration tests.
- Manual validation scripts.
- JSON schema validation.
- Command result parsing.
- Regression checks for baseline/smoke/dry-run/apply/rollback.
- Performance target measurement logic.

## Frontend Owns

### WinUI Shell

- Settings-style `NavigationView` shell.
- Page layout and routing.
- Responsive window behavior.
- Navigation hierarchy and page grouping.
- Search/command UI if included.

### Visual Design

- Roo Blue and Blackout Gold theme application.
- Manrope font usage.
- Logo placement.
- Splash/loading polish.
- Icons, spacing, density, typography, and motion.
- Professional empty/loading/error states from backend status data.

### Page UX

- Dashboard composition.
- Process profile editor UI.
- Tourney Mode UI.
- Bulk uninstall queue UI.
- Leftover review UI.
- Driver catalog UI.
- Reports viewer UI.
- Monitoring panels.
- Settings page.
- Dialogs, confirmations, toasts, and progress surfaces.

### UX Writing And Flow

- Clear user-facing labels.
- Risk descriptions based on backend-provided risk metadata.
- Confirmation copy.
- Non-scary but honest warning states.
- Client-facing polish.

### Frontend State

- View models that consume backend contracts.
- Filtering, sorting, grouping, tabs, and search.
- Selection state.
- Progress display.
- UI-only preferences.

## Shared Contracts

Frontend code should not implement risky Windows operations directly. It should call backend-owned interfaces.

Backend code should not require the frontend to parse PowerShell text output manually. Backend actions should return structured results.

Shared contract shape:

```json
{
  "actionId": "performance.applyProfile",
  "dryRun": true,
  "risk": "medium",
  "requiresElevation": true,
  "preview": [],
  "backupPath": null,
  "result": null,
  "errors": []
}
```

Every risky backend action should support:

- Preview.
- Apply.
- Cancel.
- Rollback where possible.
- Structured status.
- Logs.
- User-facing summary text.

## Do Not Cross

Frontend code should not:

- Run registry/service/process/device cleanup actions directly.
- Shell out to remote scripts.
- Implement deletion logic.
- Bypass backend confirmations.
- Hardcode protected process/service lists.
- Decide whether an action is safe.

Backend code should not:

- Block UI polish by changing visual structure casually.
- Hardcode UI-only layout assumptions into backend responses.
- Force pages to mirror backend implementation details.
- Treat process count as a visual-only metric.

## Immediate Working Agreement

1. Backend contracts and mock/sample JSON come first.
2. Frontend UI is built against those contracts.
3. Mock data is replaced with real Windows integrations behind the same contracts.
4. Frontend state handling, progress, empty states, and confirmations are polished.
5. Every dangerous UI action is validated against preview, backup, and rollback logic.
