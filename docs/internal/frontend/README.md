# Performance Vertex Utility WinUI frontend

The Windows desktop app uses WinUI 3. System changes run through the existing
backend review, apply, and restore operations.

## Build and verify

On Windows, from the repository root:

```powershell
./tools/scripts/Test-Frontend.ps1 -DotNetPath "$env:USERPROFILE/.dotnet/dotnet.exe"
```

This runs the physical-memory display regressions and builds the backend helper
and WinUI app. It does not launch the app or change system settings.
`tools/scripts/Build-Frontend.ps1` remains available for builds alone.

## Interface

- **Overview:** physical memory, running processes, detected game, hardware, and shortcuts.
- **Games & processes:** separate Games, Processes, and Background apps tabs.
- **Installed apps:** application removal and leftover cleanup.
- **Startup & services:** background-process inventory and startup information.
- **Graphics drivers:** your hardware and where to get the newest graphics driver. The NVIDIA profiles section is hidden (`x:Load="False"`) until Profile Inspector ships with the installer.
- **Memory:** physical RAM use, largest processes, and diagnostic tools.
- **Timer & cache:** timer and shader-cache actions, with expandable performance readings.
- **Tools:** official tool names, logos, search, categories, and BIOS settings.
- **Backups & history:** saved settings and operation history.
- **Settings:** appearance and app information.

Navigation and app-owned icons use the packaged SVG files in `Assets/Icons`.
Third-party tools retain their official logo assets. Blue and gold accents use
shared flat surfaces and spacing. The navigation collapses on smaller windows;
`AdaptivePanel` reflows cards and controls to fit their available width.

Game setup reveals its settings after a launcher is selected. Custom CPU masks
and saved process rules are expandable. Each action keeps its existing backend
command and review requirements. Changing a selection invalidates its review.
The Games and Processes tabs refresh live status every 2 seconds only while the
app window is in front. Behind another window or minimized they start no reads,
and a read already running when the window goes behind starts no follow-on
helper; when the window comes back they read once, then resume.

Physical RAM use is calculated from total physical capacity and available bytes.
Missing or inconsistent readings display as unavailable. Committed memory is
not used as physical RAM usage.

## Runtime

`ROO_INDUSTRIES_BACKEND_ROOT` selects the backend repository or packaged root.
`LiveDataService` reads local inventory and hardware data. Catalogs and some
feature metadata still use `SampleDataService`; they are not live measurements.
Local preferences and recovery data use the root selected by
`BrandCompatibility.LocalDataRoot`, including existing legacy installations.
