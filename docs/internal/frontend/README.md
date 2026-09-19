# Roo Industries Optimization Suite — WinUI frontend

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
- **Drivers & GPU:** hardware, driver recommendations, and expandable NVIDIA profiles.
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

Physical RAM use is calculated from total physical capacity and available bytes.
Missing or inconsistent readings display as unavailable. Committed memory is
not used as physical RAM usage.

## Runtime

`ROO_INDUSTRIES_BACKEND_ROOT` selects the backend repository or packaged root.
`LiveDataService` reads local inventory and hardware data. Catalogs and some
feature metadata still use `SampleDataService`; they are not live measurements.
Local preferences and recovery data use the root selected by
`BrandCompatibility.LocalDataRoot`, including existing legacy installations.
