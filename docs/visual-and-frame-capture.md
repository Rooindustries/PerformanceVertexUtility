# Visual And Frame-Capture Integration

This harness supports two kinds of visibility:

1. **System metrics** from PowerShell, WMI/CIM, services, counters, and event logs.
2. **Visual/runtime checks** from a display automation layer or third-party frame telemetry tools.

## Computer Use Display Provider

Computer Use is useful for smoke testing because it can inspect real app windows, not just process names.

Use it for:

- Confirming an app visibly launches after a tweak.
- Capturing screenshots of Settings, Store, Samsung apps, Wispr Flow, or benchmark launchers.
- Detecting blocking windows, launchers, permission prompts, crash dialogs, and frozen UI.
- Verifying that a game benchmark actually reached the menu or benchmark result screen.

Do not use it for:

- Changing Windows security/privacy settings.
- Accepting permission prompts automatically.
- Bypassing warnings or safety screens.
- Running destructive UI actions.

Recommended visual smoke checks:

| Check | Expected |
|---|---|
| Wispr Flow window | App opens or is visible when configured for startup. |
| Samsung continuity app/window | Core continuity surface opens when requested. |
| Microsoft Store | Store launches and renders a visible home/update page. |
| Settings | Settings launches and remains responsive. |
| Game benchmark launcher | Launcher/game reaches menu or benchmark screen. |
| Benchmark result screen | Result text/FPS summary is visible after run. |

## Frame Telemetry Providers

Preferred order:

1. CapFrameX, if installed.
2. PresentMon CLI, if installed.
3. RTSS / MSI Afterburner, if installed and already configured.
4. HWiNFO64 sensors, if installed.
5. Built-in fallback: process counters, GPU engine counters where available, and Windows graphics assessment.

Current machine discovery found:

| Tool | Status |
|---|---|
| HWiNFO64 | Found at `C:\Program Files\HWiNFO64` |
| CapFrameX | Not found in common install paths |
| RTSS / RivaTuner | Not found in common install paths |
| MSI Afterburner | Not found in common install paths |
| PresentMon | Not found in common install paths |
| OCAT | Not found in common install paths |

## Game Benchmark Rules

- Run plugged in.
- Fixed power mode.
- Fixed brightness/refresh rate.
- Fixed resolution and graphics preset.
- No overlays except the selected telemetry tool.
- Run each benchmark at least 3 times.
- Compare average FPS, 1% lows, frame-time variance, CPU/GPU utilization, temperature, and package power where available.
- Reject an optimization profile if it saves processes but reduces average FPS or 1% lows by more than 3% in repeatable tests.

## Integration Contract For Future App

The app should treat visual and frame telemetry as providers:

```json
{
  "provider": "CapFrameX | PresentMon | RTSS | HWiNFO | ComputerUse | BuiltIn",
  "available": true,
  "path": "C:\\Program Files\\...",
  "canAutomate": true,
  "canExportCsv": true,
  "requiresUserSetup": false
}
```

The benchmark runner should continue even if a provider is missing, but the final report must say which telemetry sources were used.
