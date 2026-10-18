# WinUI Project Brief

Captured: 2026-06-27

Launch target: August 15-16, 2026 for the Tourney launch. See `docs/tourney-launch-plan.md`.

## Source Context

Initial planning context is kept outside the public repo under ignored internal notes. Public docs should preserve product decisions without exposing planning thread identifiers.

## Product Direction

Performance Tuning Utility is moving from a PowerShell benchmark-and-rollback harness into a WinUI desktop app.

The target shell should follow the Windows Settings app pattern:

- Left-side navigation with clear page groups.
- Search and/or command entry near the top of the shell.
- Main content pages made of dense operational sections, not marketing panels.
- Settings-style rows, status chips, module cards, detail pages, dialogs, and confirmation flows.
- Responsive behavior that keeps the navigation usable in narrow windows.

Use the brand layer already captured in this repo:

- Default theme: Blue.
- Alternate theme: Blackout Gold.
- Font: Manrope Variable.
- Static logo in navigation.
- Animated logo only for splash/loading.

## Durable Constraints From Prior Session

- Preserve Wi-Fi, Bluetooth, Tailscale, Wispr Flow, Defender, firewall, Store, WebView2, Windows Update, and Samsung phone/laptop continuity features by default.
- Keep risky operations gated by explicit confirmation, backups, and rollback.
- Keep benchmarking separate from the main app shell, but allow it as an internal provider workflow.
- Build native replacements for Process Lasso-style priority/profile management and Revo-style bulk uninstall cleanup instead of bypassing third-party licensing.
- DDU, NVCleanstall, OOSU10, WPD, driver installers, and destructive cleanup flows remain manual or confirmation-gated.
- Implement the Chris Titus Tech Windows Utility feature set as a source-backed catalog, routed through the app's preview, confirmation, backup, and rollback flows instead of remote script execution.
- Driver recommendations should be hardware-aware and game-aware, with tested game-logo tags.
- NVIDIA Profile Inspector should start from `framesync.nip`, then later score candidate `.nip` profiles and expose the top tested options.

## Repo Roles

- `LeanClientOptimizer.ps1`: Current CLI harness for modules, baseline, smoke tests, dry-run/apply, rollback, reports, and tool inventory.
- `modules/tweak_manifest.json`: Safe, optional, device-specific, and advanced optimization modules.
- `modules/utilities_manifest.json`: Tool catalog and integration policy for `vendor/Utilities.zip`.
- `modules/telemetry_providers.json`: Visual/system/frame telemetry provider contract.
- `modules/brand_manifest.json`: App-facing theme, logo, and font contract.
- `modules/winutil_manifest.json`: Chris Titus WinUtil source catalog and safety mapping.
- `docs/*.md`: Implementation notes that should guide the app UI and safety model.
- `assets/brand/roo-industries`: Brand assets copied from Roo Industries sources.
- `vendor/Utilities.zip`: Bundled development archive for user tools.

## First WinUI App Shape

Recommended first page map:

- Dashboard: PC status, safety status, last baseline, and next recommended action.
- Optimize: Manifest-backed tweak modules with dry-run preview, apply, rollback, and risk labels.
- Startup: Startup entries and safer Autoruns-style inspection.
- Apps: Native bulk uninstaller workflow.
- Tools: Chris Titus WinUtil-sourced app installs, features, fixes, DNS presets, and Windows panels.
- Drivers: Hardware/game-aware driver and NIP profile recommendations.
- Monitoring: HWiNFO and built-in sensor/counter views.
- Benchmarks: Separate workflow launcher and result history.
- Reports: Baseline, module, rollback, and client-facing reports.
- Settings: Theme, paths, provider detection, backups, and update metadata.

## Implementation Notes

- Treat PowerShell as the first backend boundary: the WinUI app can call the harness or replace pieces with native services over time.
- Keep the manifest contracts stable so the UI can be data-driven.
- Put all dangerous actions behind preview screens, explicit confirmations, and saved rollback data.
- Use WinUI `NavigationView` as the shell control and a `Frame` for page content.
