# Chris Titus WinUtil Integration

Captured: 2026-06-28

## Source

The app should implement the Chris Titus Tech Windows Utility feature set as a source-backed catalog, not by launching a remote script.

Primary sources:

- Repository: https://github.com/ChrisTitusTech/winutil
- Documentation: https://winutil.christitus.com/
- Config files: https://github.com/ChrisTitusTech/winutil/tree/main/config
- License: MIT

Current source snapshot:

| Area | Source file | Count |
|---|---|---:|
| Installable app catalog | `config/applications.json` | 194 |
| Tweaks and preference toggles | `config/tweaks.json` | 67 |
| Features, fixes, and legacy panels | `config/feature.json` | 29 |
| DNS presets | `config/dns.json` | 8 |
| Presets | `config/preset.json` | Minimal 5, Standard 13, Advanced 17 |

## Product Position

Chris Titus WinUtil becomes a feature-source layer inside the Roo Industries app.

The Roo app should not look like WinUtil and should not execute the public launcher from inside the product. Instead, it should:

- Sync or vendor audited WinUtil config definitions.
- Render them through the Windows Settings-style WinUI shell.
- Route every action through Roo backup, preview, confirmation, telemetry, and rollback rules.
- Keep Roo Blue and Blackout Gold as the only product themes.

## Page Mapping

| WinUtil area | Roo app page |
|---|---|
| Applications | Apps > Install |
| Essential Tweaks | Optimize > Safe / Standard |
| Customize Preferences | Settings / Personalization |
| Advanced Tweaks - Caution | Optimize > Advanced |
| Performance Plans - Not For Laptops | Optimize > Power, hidden from defaults on laptops |
| Features | Tools / Settings |
| Fixes | Tools > Repair |
| Legacy Windows Panels | Tools > Windows Panels |
| DNS presets | Network tools |
| Presets | Optimize presets after audit |

## Safety Rules

- Never run `irm ... | iex` or another remote script execution path from the app.
- Do not blindly import advanced tweaks into default profiles.
- Do not make Ultimate Performance default on laptops.
- Do not remove Edge, OneDrive, Xbox components, Windows AI components, or disable IPv6 without a specific warning and rollback plan.
- Preserve the existing Lean Client protections: Wi-Fi, Bluetooth, Tailscale, Wispr Flow, Defender, firewall, Store, WebView2, Windows Update, and Samsung continuity.
- For DNS changes, save current adapter DNS settings and test resolution before/after apply.
- For app installs, show the selected packages, package manager source, install command, and logs.
- For repair workflows, require restore point or equivalent backup first.

## Implementation Plan

1. Add a WinUtil sync step that downloads pinned config files into a local cache.
2. Normalize WinUtil entries into Roo app actions: install, tweak, preference, feature, fix, DNS, panel, preset.
3. Add risk labels and protected-feature checks before any entry can be shown as safe.
4. Map audited tweaks into `modules/tweak_manifest.json` or a new app-side catalog.
5. Build the WinUI pages using this normalized catalog.
6. Add apply backends one area at a time, starting with read-only catalog display and app install preview.

## First Useful Slice

For the first WinUI prototype, implement WinUtil support as read-only catalog display:

- Show app categories and package count.
- Show tweak categories and risk grouping.
- Show DNS providers.
- Show presets but mark them `Needs audit`.

After that, implement safe app installs and DNS backup/apply/rollback before attempting advanced tweak execution.
