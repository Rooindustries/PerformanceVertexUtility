# Roo Industries Brand Integration

The optimizer app should use the same brand source as `rooindustries.com` and the public `Rooindustries/RooIndustries` repo.

## Naming

Use **Roo Industries** in product text, titles, shortcuts, descriptions and documentation. Code identifiers and executable names use `RooIndustries`; environment variables use `ROO_INDUSTRIES_`; lowercase identifiers use `roo-industries-`. Do not shorten the company name.

The naming check runs through `tools/validation/check_baseline.py` and can be run separately with `tools/validation/check_branding.py`. Official third-party product identities and source URLs keep their original names.

Existing installations retain their original data directory in place so absolute recovery paths and reviewed hashes remain valid. Fresh installations use the full product directory name. The explicit compatibility modules retain only the old storage, environment, theme, job, task, restore-staging and cross-version exclusion identities needed to read settings and restore earlier changes. Current executables, UI, scripts, resources and newly created task labels use the full name. Historical measurement inputs remain readable without rewriting the recorded evidence.

## Copied Assets

Assets live in:

```text
assets\brand\roo-industries
```

Important files:

| File | Use |
|---|---|
| `embed_logo.png` | Primary large brand mark and OpenGraph-style logo |
| `favicon-96x96.png` | Compact app/nav icon |
| `favicon.ico` / `favicon.svg` | Windows/web favicon sources |
| `logo.webp` | Website logo asset |
| `logo-animated-small.apng` | Animated splash/loading brand moment |
| `logo-animated-small.webm` | Animated video version |
| `web-app-manifest-192x192.png` | PWA/app tile icon |
| `web-app-manifest-512x512.png` | Large PWA/app tile icon |
| `manrope-latin-variable.woff2` | Actual brand font |
| `rooindustries-index.css` | Source theme token reference |
| `rooindustries-tailwind.config.js` | Source Tailwind semantic token map |

## Font

Use `Manrope Variable` for the app:

```css
@font-face {
  font-family: "Manrope Variable";
  font-style: normal;
  font-display: swap;
  font-weight: 200 800;
  src: url("../assets/brand/roo-industries/manrope-latin-variable.woff2")
    format("woff2-variations");
}
```

The repo file is named `roboto-latin.css`, but its contents declare `Manrope Variable`. The app should call the font Manrope so future code is obvious.

## Themes

Use `modules\brand_manifest.json` as the app-facing theme contract.

| Theme | Source attribute | Purpose | Short version |
|---|---:|---|---|
| Roo Industries Blue | `default` | Main brand theme | Deep navy, cyan, electric performance feel |
| Blackout Gold | `dark` | Premium alternate | Black graphite surfaces, silver text, gold accents |

Both themes are dark. Do not add a plain light mode unless it is designed separately.

## App Guidance

The website is expressive and marketing-forward. The optimizer app should keep the brand but make the UI more operational:

| Area | Direction |
|---|---|
| Dashboards | Dense, scan-friendly, not a landing page |
| Cards | Use for modules, results, and repeated items only |
| Glow | Use sparingly for active states, passes, warnings, and benchmark highlights |
| Buttons | Icon-first where possible; color should communicate risk and action |
| Themes | Token-driven, so safety views, benchmark views, and client flows stay consistent |
| Logo | Static logo in navigation; animated logo only for splash/loading |

## Sources

- Website: https://www.rooindustries.com
- Public repo: https://github.com/Rooindustries/RooIndustries
