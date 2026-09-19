# August Launch Plan

Target launch window: August 15-16, 2026

Captured: June 28, 2026

## Launch Principle

The app must be publishable, professional, and useful by the August launch. The first release should be centered on the workflows that make the product valuable: Process Lasso-style performance profiles, Revo-style uninstall/cleanup, and driver/profile recommendations. The WinUI shell, WinUtil catalog, and reports exist to support those workflows, not to distract from them.

The north-star performance target is smooth RAM-heavy and VRAM-heavy gameplay on 16 GB RAM class machines, especially Overwatch with OBS and Discord open, aiming for 144 Hz-class frame pacing where possible. See `docs/performance-target.md`.

Depth can continue after launch, but risky automation still needs preview, backup, confirmation, and rollback support.

## Must Ship For Launch

- Professional WinUI app shell using the Windows Settings-style layout.
- Roo Industries Blue default theme and Blackout Gold alternate theme.
- Manrope font, Roo Industries app icon, static logo navigation, and polished splash/loading moment.
- Dashboard with current PC status, safety status, last baseline, and recommended next action.
- Optimize page backed by `modules/tweak_manifest.json`.
- Baseline, smoke test, dry-run, apply, rollback, and report flows wired to the existing PowerShell harness.
- Clear risk labels, preview screens, backup paths, confirmation dialogs, and rollback visibility.
- WinUtil source catalog shown inside the app: apps, tweaks, features/fixes, DNS presets, and presets.
- Utilities catalog shown inside the app with safe launch/manual-gated behavior.
- Monitoring page with HWiNFO detection and built-in counter summary.
- Reports page for baseline/module/client-facing reports.
- Settings page for theme, paths, provider detection, backup location, and safety defaults.
- Native Process Lasso replacement MVP:
  - Per-process priority profile catalog.
  - Per-process affinity/profile rules where safe.
  - Foreground game boost profile.
  - Game Tune session profile for Overwatch + OBS + Discord style workloads.
  - Background app demotion preview.
  - Protected process list for Windows, security, network, Samsung continuity, Tailscale, and Wispr.
  - Apply/disable/rollback profile states.
- Revo-style bulk uninstaller MVP:
  - Installed app inventory from registry/MSI/Appx/winget where available.
  - Multi-select uninstall queue.
  - Official uninstall string first.
  - Leftover scan preview for files, folders, services, tasks, startup entries, and registry references.
  - Explicit confirmation before leftover deletion.
  - Deleted item manifest and rollback/export path.
- Driver and profile workflow MVP:
  - Hardware detection for CPU/GPU/network/system model.
  - Installed GPU driver version.
  - Driver catalog UI with game tags and stability notes.
  - Manual install launch flow with warnings.
  - NVIDIA Profile Inspector catalog seeded by `base-profile.nip`.
  - Tested/recommended profile slots, even if full automated benchmarking continues after launch.
- Installer/package, release notes, app screenshots, and basic user guide.

## Should Ship If Stable

- WinUtil app install preview and selected package install logging.
- DNS provider backup/apply/rollback flow.
- Startup inspector with safe recommendations.
- Dead-device inventory and preview-only cleanup list.
- UserDiag/diagnostics page with Roo Industries plan recommendation CTA.
- Runtime Process Lasso replacement service with continuous enforcement and profile auto-switching.

## Do Not Rush Into Launch

These can appear as preview/manual workflows, but should not ship as aggressive automation unless they pass testing:

- Unconfirmed Revo-style leftover deletion.
- Aggressive Process Lasso replacement behavior that continuously changes priority/affinity without visible profile state and rollback.
- DDU or NVCleanstall automation.
- NVIDIA Profile Inspector profile application automation.
- Windows feature repair flows that reset networking, updates, or system components.
- Advanced WinUtil tweaks such as Edge removal, OneDrive removal, IPv6 disablement, Xbox component removal, Windows AI removal, autologin, remote access, or Ultimate Performance defaults on laptops.

## Timeline

### June 28-July 3: Foundation

- Install WinUI/.NET/Visual Studio toolchain.
- Create WinUI solution and project structure.
- Implement navigation shell and page placeholders.
- Load Roo Industries theme tokens and brand assets.
- Load local manifests read-only.
- Create domain models for performance profiles, uninstall inventory, leftovers, driver catalog, and protected processes.

### July 4-July 10: Process Profiles First

- Build the Process Lasso replacement UI first.
- Detect running processes and protected processes.
- Create profile editor for priority, affinity, I/O/power-throttling placeholders, foreground game boost, and background demotion.
- Implement preview/apply/disable/rollback for safe priority rules.
- Keep continuous auto-enforcement behind a later service gate.

### July 11-July 18: Revo-Style Uninstaller

- Build installed app inventory.
- Build multi-select uninstall queue.
- Run official uninstallers only after confirmation.
- Add leftover scan preview.
- Add deletion manifests and backup/export path.
- Only enable leftover deletion after confirmation and test on low-risk sample apps.

### July 19-July 26: Drivers And Profiles

- Build hardware and installed driver detection.
- Build driver catalog schema and UI.
- Add game-tagged driver recommendations.
- Add NVIDIA Profile Inspector profile catalog seeded by `base-profile.nip`.
- Keep DDU/NVCleanstall/manual driver install flows gated.
- Start benchmark/provider integration if stable.

### July 27-August 2: Optimizer, WinUtil, And Client Polish

- Wire baseline, smoke test, dry-run, apply, rollback, and report actions.
- Add WinUtil app/tweak/features/DNS catalog views.
- Add startup inspector.
- Add diagnostics/UserDiag CTA page.
- Add report polish for client-facing output.

### August 3-August 9: Packaging And Hardening

- Package installer.
- Run UI pass across window sizes.
- Validate protected services/features.
- Improve error handling, logs, empty states, and recovery paths.

### August 10-August 14: Release Candidate Freeze

- No new risky features.
- Regression test baseline/smoke/dry-run/apply/rollback/report.
- Capture screenshots and release notes.
- Prepare launch build.

### August 15-August 16: Launch

- Ship v1.
- Monitor issues.
- Keep advanced automation behind preview/manual gates until post-launch testing proves it.

## Daily Operating Rule

Every day should leave the app more launchable than it started. If a feature threatens the launch date, ship the UI and preview/reporting path first, then add automation after release.
