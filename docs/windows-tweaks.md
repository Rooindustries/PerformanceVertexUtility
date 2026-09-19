# Windows tweaks

The shared backend exposes twelve Privacy and Explorer settings in
`backend/catalogs/windows-tweaks.json`. It supports current-state detection,
reviewed apply, and restoration of an individual profile. The first batch uses
registry values; it does not implement service, task, network-adapter or package
changes. No frontend changes are included in this backend batch.

## Included settings

| Group | Settings |
| --- | --- |
| Privacy | Advertising ID policy, activity history, activity publishing, activity upload, personalized tips from diagnostic data, feedback prompts |
| Windows & Explorer | File extensions, hidden files, app color mode, Windows color mode, Task View button, taskbar alignment |

Every setting declares its Windows build range, editions, exact registry scope,
options and refresh requirement. Unsupported editions/builds reject new changes.
Restoration uses stored claims and originals, so removing a catalog entry or
upgrading Windows does not discard an existing recovery record. Detection reports
registry configuration; it does not assert that a cached shell view has refreshed
or that an external management policy cannot supersede it.

The Privacy definitions follow Microsoft's [Privacy policy mapping](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-privacy)
and [Experience policy mapping](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-experience).
Explorer bindings are pinned to the [WinUtil configuration](https://raw.githubusercontent.com/ChrisTitusTech/winutil/fc60cbde09d669178bda1665be9cb1a703516fca/config/tweaks.json).
Source references identify individual targets; they do not imply that an entire
upstream preset is implemented. In particular, WinUtil's Activity History option
keeps the activity feed enabled while disabling publication and upload. The
individual controls here expose those policies separately. Disabling these
policies can affect [Windows Backup for Organizations](https://learn.microsoft.com/en-us/windows/configuration/windows-backup/).

## One setting, shared ownership

The planner resolves registry handles to their native key identity, with the
value name matched without case sensitivity. Two controls targeting the same
resource and value become one write. Conflicting values are rejected. User and
machine targets remain separate. Registry views merge only when Windows resolves
them to the same native key.

A profile contains selections such as `explorer.file-extensions = show`. Multiple
profiles can request the same value. Removing one profile keeps the shared value
until the last owner releases it. The first original value, its type and bytes,
and originally missing keys remain available throughout that ownership period.
An already matching value does not get written again or replace the original
snapshot. External drift blocks changes to that affected setting; unrelated
profiles can still be restored.

## Commands

Build the native helper:

```powershell
./backend/scripts/Build-OptimizerHost.ps1 -DotNetPath "$env:USERPROFILE/.dotnet/dotnet.exe"
```

Read the catalog and current Windows configuration:

```powershell
./backend/scripts/Invoke-WindowsTweaks.ps1 -Action Catalog
./backend/scripts/Invoke-WindowsTweaks.ps1 -Action Status
```

A selections file is an array of exact setting and option IDs:

```json
[
  { "settingId": "explorer.file-extensions", "optionId": "show" },
  { "settingId": "explorer.hidden-files", "optionId": "show" }
]
```

Create a new preview file, inspect it, then apply its exact SHA-256:

```powershell
./backend/scripts/Invoke-WindowsTweaks.ps1 -Action Preview -ProfileId my-explorer `
  -SelectionsPath ./selection.json -OutputPath ./review.json

./backend/scripts/Invoke-WindowsTweaks.ps1 -Action Apply -PreviewPath ./review.json `
  -ReviewHash (Get-FileHash ./review.json -Algorithm SHA256).Hash -ConfirmApply
```

`-PresetId explorer-details` can replace `-SelectionsPath`. The other bundled
presets are `privacy-basics` and `activity-history-off`. Presets are named
selections of the same controls, with no separate execution bodies.

To restore a profile, create another selections file containing `[]`, preview it
with the same `ProfileId`, then use `-Action Restore` with that review's hash.
Restore requires an empty selection, preserves other active owners, and removes
only the originally absent keys that are still empty and have unchanged
permissions. Retained keys are reported in `notices`. It does not restart
Explorer or force a sign-out.

The capability ID is `system-optimizations.windows-settings`. Its router accepts
`-RequestPath` using the native host request fields:

```json
{
  "schemaVersion": 1,
  "repoRoot": "C:\\RooIndustriesOptimizationSuite",
  "profileId": "my-explorer",
  "presetId": "explorer-details",
  "outputPath": "C:\\RooIndustriesOperations\\review.json"
}
```

For apply/restore, use `previewPath`, `reviewHash`, and `confirm: true` instead of
selection fields, and also supply the router's `-ConfirmApply`. The wrapper binds
the request to its own backend root. The native actions are `tweak-catalog`,
`tweak-status`, `tweak-preview`, `tweak-apply`, and `tweak-restore`.

Apply returns `state`, `changed`, `replayed`, and `restorable`. `changed` counts
setting changes, not an ownership-only update. A replay returns the current state
without reapplying an old profile that may already have been restored. Older
reviews outside the retained receipt history are rejected as stale.

## Recovery and validation

Windows uses a registry transaction for the target changes and the recovery
receipt at `HKLM\Software\RooIndustriesOptimizationSuite\Tweaks\<user SID>`,
value `State`. Native mutations require an administrator token for this protected
recovery store, including when the selected preferences are per-user. The
transaction commits both together, or neither. The receipt is bound to the PC,
Windows user, and store. Stale revisions, changed review bytes, changed catalog
choices, missing required fields, and conflicting current values reject apply.
Recent history is bounded to 128 entries and may be shortened to keep the receipt
within 8 MiB; active recovery snapshots are not discarded. An original value
larger than 64 KiB is rejected before application.

The file fixture uses the same planner and profile/recovery contract, committing
fixture values and state together through the shared atomic file writer. It does
not edit the Windows registry. Create one with `-Action CreateFixture
-FixturePath <new-file> -ConfirmApply`, then pass that `FixturePath` to subsequent
commands. Fixture plans cannot be applied to the Windows store.

Run the normal checks with:

```powershell
./backend/scripts/Test-Tweaks.ps1 -DotNetPath "$env:USERPROFILE/.dotnet/dotnet.exe"
```

The separate native registry fixture is opt-in. After exact approval, its command
is `dotnet run --project tools/validation/Tweaks/Tweaks.csproj -c Release --
<repo-root> --registry-fixture`. Its entire write scope is
`HKCU\Software\RooIndustriesTweakTests\ec3d917cb672498785218eb3d0aa790f`; the test
refuses an existing root and removes its created keys after the run. It does not
change the production tweak targets or production recovery store.

## Remaining coverage

The complete O&O ShutUp10++ and WPD inventories, unresolved FSOS-X Dash controls,
remaining WinUtil options, existing legacy-module migration, and frontend
controls remain separate work. This batch establishes native registry execution
and shared ownership. It does not claim complete parity with any upstream tool.
