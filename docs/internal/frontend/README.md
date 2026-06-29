# Roo Industries Optimization Suite — Frontend (first-pass scaffold)

Internal, ignored location (`docs/` is git-ignored). This is the WinUI 3 frontend shell built against the
existing backend contracts and sample JSON. It is **not built or runnable yet** — see "Blocker" below.

## Status

- UI/UX only. No backend behavior, no system-changing logic, no apply/uninstall/delete/driver actions are wired.
- Every destructive/apply control is rendered disabled with a preview-vs-apply explanation.
- Data comes exclusively from `backend/samples/*.json` through `Services/SampleDataService`.

## Blocker: toolchain not installed

This machine has the .NET host (`C:\Program Files\dotnet\dotnet.exe`) but **no .NET SDK** and **no Visual Studio**:

- `dotnet --list-sdks` returns nothing; there is no `C:\Program Files\dotnet\sdk` folder.
- `msbuild` is not on PATH; the Visual Studio installer directory does not exist.

So the project cannot be restored or built here (`dotnet build` / `dotnet new` are unavailable), and the
Windows App SDK / WinUI NuGet packages cannot be restored. The scaffold was authored to compile cleanly once
the toolchain is present, but it has **not** been compiled.

### What to install

1. .NET SDK 8.0 (x64): https://dotnet.microsoft.com/download/dotnet/8.0
2. Visual Studio 2022 with the **.NET Desktop Development** workload and the **Windows App SDK C# Templates**
   component (or the standalone Windows App SDK 1.5). Alternatively, command-line only:
   - `winget install Microsoft.DotNet.SDK.8`
   - Restore is handled by the `Microsoft.WindowsAppSDK` PackageReference already in the csproj.

### Build once the SDK exists

```powershell
cd docs\internal\frontend\Roo.OptimizationSuite.App
dotnet restore
dotnet build -p:Platform=x64
```

Unpackaged run (the csproj sets `WindowsPackageType=None`):

```powershell
dotnet run -p:Platform=x64
```

At runtime the app locates `backend/samples` by walking up from the executable to the repository root (the
folder containing `backend\samples`). Override with the `ROO_BACKEND_ROOT` environment variable if needed.

## Promoting to the public repo

When the toolchain is available and the build is green, move the project folder to the preferred public path:

```text
frontend\Roo.OptimizationSuite.App\
```

Then copy the brand assets the app references into `Assets\` so they ship with the build:

- `Assets\Fonts\Manrope.ttf` (a Manrope **ttf/otf** — WinUI cannot load the brand `.woff2` directly; once added,
  point `RooFontFamily` in `Resources/Brand.xaml` at `ms-appx:///Assets/Fonts/Manrope.ttf#Manrope`).
- `Assets\Brand\` logo PNGs from `assets\brand\roo-industries\` (then switch `Services/BrandAssets` to
  `ms-appx:///` sources instead of the dev repo-asset lookup).

## Architecture

```text
Roo.OptimizationSuite.App/
  App.xaml(.cs)            App entry; lightweight service locator (App.Data, App.Theme); applies persisted theme.
  MainWindow.xaml(.cs)     Settings-style NavigationView shell + content Frame; theme reload; nav helper.
  Resources/
    Theme.RooBlue.xaml     Roo Blue tokens (default).        <- translated from the brand source, see below
    Theme.BlackoutGold.xaml Blackout Gold tokens (alternate).
    Brand.xaml             Font family + shared sizing tokens.
    Styles.xaml            Converters + typography + card/chip layout styles.
  Models/                  POCOs matching the backend sample JSON shapes (System.Text.Json).
  Services/
    BackendLocator         Resolves repo-relative backend\samples and brand asset dirs.
    SampleDataService      Reads backend\samples\*.json into typed models (the only data seam).
    ThemeService           Swaps the active theme ResourceDictionary; persists choice.
    SettingsStore          JSON preference file under LocalAppData (works unpackaged).
    BrandAssets            Loads the nav logo from the repo brand assets during development.
  Converters/              Risk->brush (solid/soft/border), bytes, bool/string/count -> visibility.
  ViewModels/              One per page; PageViewModelBase provides load/ready/empty/error state.
  Views/                   Dashboard, TourneyMode, PerformanceProfiles, UninstallCleanup,
                           DriversProfiles, Monitoring, Reports, Settings.
```

### Theme provenance

Theme tokens are translated 1:1 from the copied Roo Industries source, not invented:

- `assets/brand/roo-industries/rooindustries-index.css` — `:root` / `html[data-theme="default"]` -> Roo Blue;
  `html[data-theme="dark"]` -> Blackout Gold. `rgba()` values are written as `#AARRGGBB`.
- `assets/brand/roo-industries/rooindustries-tailwind.config.js` — semantic token names (surface, ink, accent,
  line, success/warning/danger/info) map onto the `Roo*` and `Risk*` brush keys.
- `assets/brand/roo-industries/rooindustries-font-face.css` — declares the `Manrope Variable` family.

Both themes are dark (the shell pins `RequestedTheme="Dark"`). The app keeps operational surfaces quieter than the
marketing site: flat canvas, single-level cards, restrained accent use; the brand `app-gradient` and
`button-primary` gradients are available as `RooAppBackgroundBrush` / `RooPrimaryButtonBrush` for splash and the
primary CTA only.

### Known first-pass limitations

- Live theme switching swaps the active dictionary and re-navigates the current page so its `StaticResource`
  brushes re-resolve. Shared `Style` objects that bake a brush would not live-update, so the styles here are
  layout-only and pages set surface/border brushes at the element level. System chrome theming is a follow-up.
- The Manrope brand font is `.woff2`; until a `.ttf/.otf` is added the font falls back to the Segoe UI variable
  family (declared in `Resources/Brand.xaml`).
- Sample-backed numbers are point-in-time fixtures; the Monitoring page surfaces the missing live signals.
