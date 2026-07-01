# Roo Industries Optimization Suite - WinUI Frontend

Internal WinUI 3 frontend for the local Roo Optimization Suite. The project is kept
under `docs/internal/frontend` while the backend contracts and runtime scripts are
still being hardened. It should stay a frontend shell: no risky Windows behavior is
implemented directly in the UI layer.

## Build

Build from the repository root:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\scripts\Build-Frontend.ps1
```

The script builds:

```text
docs\internal\frontend\Roo.OptimizationSuite.App\Roo.OptimizationSuite.App.csproj
```

Default behavior:

- Builds `Debug` with `-p:Platform=x64`.
- Uses `ROO_DOTNET_EXE` or the `-DotNetPath` argument when provided.
- Otherwise prefers `%LOCALAPPDATA%\Microsoft\dotnet\dotnet.exe`, then `dotnet.exe`
  on `PATH`.
- Requires a dotnet host with at least one installed SDK.
- Builds only; it does not run or focus the app.

Manual development run, from the project directory only:

```powershell
dotnet run -p:Platform=x64
```

## Runtime data sources

`BackendLocator` resolves the repository root from `ROO_BACKEND_ROOT` when set.
Without that override, it walks upward from the executable until it finds
`backend\samples`.

The frontend currently reads data from two service paths:

- `LiveDataService` runs read-oriented backend PowerShell scripts from
  `backend\scripts` and consumes JSON output for process inventory, process
  classification, hardware summary, installed-app inventory, and leftover preview
  data.
- `SampleDataService` reads `backend\samples\*.sample.json` for product status,
  backend fixtures, driver recommendations, NVIDIA profile catalog data, telemetry
  fixtures, and report summaries.

Local UI preferences are stored in:

```text
%LOCALAPPDATA%\RooOptimizationSuite\settings.json
```

## Current shell

```text
Roo.OptimizationSuite.App/
  App.xaml(.cs)             App entry, shared services, persisted theme, crash log hook.
  MainWindow.xaml(.cs)      Settings-style NavigationView shell and page routing.
  Resources/
    Theme.RooBlue.xaml      Default Roo Blue resource dictionary.
    Theme.BlackoutGold.xaml Alternate Blackout Gold resource dictionary.
    Brand.xaml              Font family and shared sizing tokens.
    Styles.xaml             Converters, typography, card, chip, and layout styles.
  Assets/Fonts/             Checked-in app font assets copied to output.
  Models/                   System.Text.Json models for backend contracts and fixtures.
  Services/
    BackendLocator          Resolves repo-relative backend and brand asset locations.
    LiveDataService         Runs read-oriented backend scripts and parses JSON.
    SampleDataService       Loads checked-in sample JSON fixtures.
    ThemeService            Swaps theme dictionaries and persists preference.
    SettingsStore           Stores local UI preferences under LocalAppData.
    BrandAssets             Loads repo brand logos during development.
  ViewModels/               Page view models with load, ready, empty, and error state.
  Views/
    DashboardPage.xaml
    PerformanceProfilesPage.xaml
    UninstallCleanupPage.xaml
    DriversProfilesPage.xaml
    MonitoringPage.xaml
    ReportsPage.xaml
    SettingsPage.xaml
```

Navigation labels in the shell are Dashboard, Game Tune, Clean Junk, Drivers &
Settings, Live Feel, Before & After, and Settings.

## Theme and assets

- The app ships two dark theme dictionaries: Roo Blue and Blackout Gold.
- `ThemeService` persists the selected theme and swaps the active resource
  dictionary at runtime.
- `Brand.xaml` currently points to the checked-in Roboto Flex TTF asset under
  `Assets\Fonts`.
- Development logo lookup comes from `assets\brand\roo-industries` through
  `BrandAssets`.

If the project moves out of `docs/internal/frontend`, keep the build script,
`BackendLocator`, and `BrandAssets` in sync. A packaged/public layout should copy
the required brand images into the app `Assets` folder and use `ms-appx:///` asset
URIs instead of repo-relative logo lookup.

## Current limitations

- Live data depends on the backend scripts being present under `backend\scripts`
  and returning JSON that matches the frontend models.
- Catalog-style data still comes from checked-in sample JSON until the matching
  backend endpoints are wired.
- The development logo path is repo-relative. Packaged builds need app-local brand
  assets.
