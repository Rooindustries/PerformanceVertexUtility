# Utilities Integration Plan

This document records which tools from `Utilities.zip` should become app features, launchers, or benchmark providers.

## Boundaries

- The app may bundle tools in release builds, but development should reference the local utilities archive to avoid making the source repository huge.
- `backend/catalogs/utilities-bundle-catalog.json` is generated from `vendor\Utilities.zip` metadata only; do not extract the full archive for catalog validation.
- `backend/scripts/Get-UtilitiesBundleInventory.ps1` reads zip entry metadata only. It must not launch bundled utilities or mutate the system.
- Do not bypass or remove licenses from Process Lasso, Revo Uninstaller, or any other third-party tool.
- If a licensed tool is undesirable, build a native replacement module that uses Windows-supported APIs and normal uninstall mechanisms.
- Risky tools require manual confirmation and restore-point/backups.

## Tool Decisions

| Tool | User stance | App treatment |
|---|---|---|
| Process Lasso | Used, but license is undesirable | Build native priority/affinity/I/O profile engine; optionally launch Process Lasso if installed/licensed. |
| HWiNFO | Used for monitoring | Dedicated monitoring section. |
| CPU-Z | Occasionally used for RAM type | Manual diagnostics and optional report parser. |
| MSI Afterburner | Used | Startup-capable runtime after user-approved profiles; no default overclock. |
| DDU | Used for fresh driver installs | Manual guided workflow only. |
| NVCleanstall | Used | NVIDIA-only manual driver build workflow. |
| NVIDIA Profile Inspector | Used with `base-profile.nip`; future NIP testing desired | Profile catalog, import/export, benchmark testing, top-five recommendations. |
| OOSU10 | Used | Manual launcher/reference; native safe privacy toggles in app. |
| WPD | Used | Manual launcher/reference; native safe privacy toggles in app. |
| Revo Uninstaller | Used, but wants replacement | Native bulk uninstaller module. |
| DeviceCleanup | Used | Native dead-device cleanup module plus optional launcher. |
| UserDiag | Used | Separate diagnostics section. |
| Autoruns | Not used; user wants explanation | Advanced startup inspector, education, manual launch only. |
| AffTool / intPolicy | Research only | Read-only interrupt/affinity policy status first; no blind apply. |
| MSI Utility v3 | Used for MSI mode awareness | Read-only MSI mode/status detector first; apply later only with restore/export proof. |
| InSpectre | Mitigation awareness only | Security mitigation detector first; disabling Spectre/Meltdown mitigations is high-risk manual-only and never silent. |
| UnparkCPU | Reference only | Prefer native power-plan/core-parking controls with export/rollback; bundled tool stays manual/reference. |
| LatencyMon | Diagnostics | DPC/ISR latency diagnostics workflow, not an optimizer action. |
| MSI Kombustor | Optional benchmark | Separate stress/benchmark workflow only, with thermal safety gates and no auto-run. |
| DL_SCEWIN | Firmware utility | Dangerous manual-only firmware reference; no optimizer automation. |
| Driver Booster | Avoided | Excluded from default driver strategy. |
| AMD/Intel/NVIDIA/Realtek driver installers | Package sources | Hardware-gated recommendations only, manual confirmation required. |
| DirectX/.NET/VC++ prerequisites | Dependency repair | Repair/install workflow only, explicit confirmation required. |
| Thorium | Avoided | Excluded by default. |
| Vesktop | Avoided | Excluded by default. |

## Native Priority/Profile Engine

Replacement target for most Process Lasso use cases:

- Per-process priority class.
- Per-process CPU affinity.
- Per-process I/O priority where supported.
- Per-process power throttling state where supported.
- Per-game launch profile.
- Background app demotion.
- Foreground game boost profile.
- Profile rollback to Windows defaults.

Rules:

- Never set critical Windows/security/network/Samsung/Tailscale/Wispr processes to low priority.
- Never force affinities on unknown anti-cheat protected games.
- Save every original process rule before applying.
- Profiles should be per executable path, not only process name, to avoid false matches.

## Native Bulk Uninstaller

Replacement target for the Revo-style workflow:

1. Inventory uninstallable apps from:
   - `HKLM\Software\Microsoft\Windows\CurrentVersion\Uninstall`
   - `HKLM\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall`
   - `HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall`
   - MSI product database
   - Appx packages
   - winget, if present
2. Let user select multiple apps.
3. Create restore point and app-specific backup.
4. Run official uninstall strings first.
5. Re-scan leftovers:
   - install folders
   - ProgramData folders
   - AppData Local/Roaming folders
   - services
   - scheduled tasks
   - startup entries
   - known vendor registry keys
6. Show preview of leftovers.
7. Delete leftovers only after explicit confirmation.
8. Save deleted-file manifest and registry export for rollback.

Rules:

- Do not remove shared runtimes such as VC++ redistributables, DirectX, .NET, WebView2, Store components, drivers, or security software unless explicitly selected.
- Do not delete files based only on fuzzy string matching.
- Prefer vendor/product GUIDs, install locations, publisher, uninstall metadata, and signed paths.

## Dead Device Cleanup

Replacement target for DeviceCleanup:

- Enumerate non-present PnP devices.
- Group by class: display, audio, Bluetooth, USB, storage, network, HID, monitors.
- Default select only stale non-present devices older than a configurable age.
- Protect current Wi-Fi, Bluetooth, display, touchpad, keyboard, storage, and Samsung/Intel platform devices.
- Export before/after device inventory.

## Driver Recommendation System

Driver installers should not run blindly.

Inputs:

- GPU vendor/device ID.
- Installed GPU driver version.
- CPU, chipset, network adapter, motherboard/laptop model.
- Installed games.
- Known-good driver metadata maintained in this repo.
- Benchmark results per game/profile/driver.

Outputs:

- Recommended driver per hardware and game.
- Game-logo tags for drivers tested against specific titles.
- Manual install buttons.
- DDU/NVCleanstall guided workflows when appropriate.

Required metadata shape:

```json
{
  "driverId": "nvidia-595.79-clean",
  "vendor": "NVIDIA",
  "version": "595.79",
  "packagePath": "tools/Drivers/Graphics/NVIDIA_595.79_NO_Nvidia_App.exe",
  "hardwareMatches": ["PCI\\VEN_10DE"],
  "gameTags": ["Fortnite", "Valorant"],
  "stability": "tested",
  "notes": "Best tested 1% lows for selected titles."
}
```

## NIP Profile Testing

- Seed profile: `Utilities/Other/base-profile.nip`.
- A file directly under `Utilities/Other` counts as the seed profile only when its SHA-256 matches the catalog's `sourceSha256`, whatever its name. The inventory, capability registry, profile review and Apply all use that rule.
- Future `.nip` files should be added to the profile catalog.
- Apply profile only on NVIDIA systems.
- Benchmark each candidate profile against selected games.
- Score by average FPS, 1% lows, frametime consistency, input latency proxy, crash rate, and visual issues.
- Publish top five tested profiles as selectable options.

## Diagnostics summary

After UserDiag or native diagnostics:

- Summarize CPU, GPU, RAM, storage, thermals, driver age, startup load, and obvious bottlenecks.
- Show only findings. The app doesn't recommend paid services.

## Autoruns Explanation

Autoruns is an advanced Sysinternals startup inspector. It shows nearly every auto-start location in Windows:

- Run keys.
- Startup folders.
- Services and drivers.
- Scheduled tasks.
- Shell extensions.
- Browser helpers.
- Explorer extensions.
- Codecs.
- AppInit DLLs.
- Winsock/network providers.

It is useful for finding hidden startup junk, but dangerous as a casual cleaner. The app should implement a safer startup inspector first and expose Autoruns only as an advanced manual launcher.
