# Windows settings

The app combines source controls from O&O ShutUp10, Chris Titus Tech
WinUtil, Gaming toggles and WPD into a shared catalog. The current development
catalog contains 1,026 setting resources and 1,255 presets derived from 632
version/control records. These are catalog counts, not a claim that every
upstream action or visible Windows effect has been verified.

`backend/catalogs/sources/` retains the pinned source facts. Run
`python3 tools/catalogs/compile_windows_tweaks.py` to rebuild the catalog and
`windows-tweak-coverage.json`. The coverage file retains unresolved effects,
refresh requirements, Windows applicability and guided actions. Source bundles use the same setting IDs. Deliberate differences from upstream
behavior are recorded on their coverage entries.

The shared engine handles typed registry values, individual fields in a common
value, services, scheduled tasks, managed firewall rules, hibernation, Windows
features, network adapter controls, DNS configuration, system mitigations and
other named Windows controls. Unsupported or unavailable targets report their
actual detection error. Native execution verification varies by adapter; see
below. Unknown value meanings remain advanced settings.

Every setting declares its Windows build range, editions, exact scope, options
and refresh requirement. Some controls also require installed Office or a
specific available device. Device selections resolve to concrete reviewed
targets; missing primary-network evidence cannot become an all-adapter change.
Detection reports observed configuration. It does not establish that a policy
has taken effect in a running app or improved gaming performance.

`backend/catalogs/windows-policy-editions.json` records Microsoft's registry-policy
edition limits. The compiler applies them after combining all sources, so a
wildcard from another source cannot bypass a limit. Home, Pro, Windows 10 S and Windows 11 SE editions no
longer offer **Consumer suggestions and promotions: Blocked**, **Windows tips**
or **Windows spotlight** turned off, or Windows diagnostic data **Off** (value 0).
Enterprise, Education, IoT Enterprise and Server retain them. A limit can name one
value: Microsoft documents that diagnostic data 0 counts as 1 on other editions,
so both diagnostic data settings also offer **Required diagnostic data** (value 1)
on every edition. **Remove this override** remains available, including when the
limited value was set before this catalog update. An unsupported choice is
excluded from the applicable current choices; its raw registry value remains in
the observations. When removing an override is the only choice left for this PC
and nothing is set, the Windows settings page shows the row as
**Not available here**, without Retry, and hides it in simple mode.

The lock screen policy, third-party spotlight suggestions and Windows Update
deferral keep their existing availability. Microsoft's current references list
Pro for the first two, and the Windows Update page describes which editions the
service is offered on rather than stating that Home ignores the registry policy.

Edition gates match exact edition IDs, `*` for every edition, or a trailing `*`
for a family, such as `Enterprise*` or `Server*`. This keeps evaluation, LTSC,
multi-session and Azure variants in their supported families. Pro Education is
part of the Pro family and does not match `Education*`.

Location-aware search and driver exclusion keep their existing availability.
Their Microsoft references describe MDM CSP editions without establishing an
edition limit for the registry policy. The same file records these two explicit
exceptions to the catalog's overlapping-edition-gate check.

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

`-PresetId explorer-details` can replace `-SelectionsPath`. The original presets `privacy-basics` and `activity-history-off` remain available. Generated source presets are included only when every required setting effect has an executor. Presets are named
selections of the same controls, with no separate execution bodies.

Strict source presets mark edition-limited choices in `optionalSelections`: they
skip them on Home, Pro, Windows 10 S and Windows 11 SE and report them in `skipped`.
Their other choices remain required, and a read failure still refuses the preset.
Edition-limited choices also remain required when the edition supports them. Presets already marked
`availableOnly` keep their existing filtering. A preset with no available choices
is refused without changing an existing profile. Saved choices can retain an
unavailable selection for another edition, but cannot apply it here. Existing
applied profiles can still be restored after the catalog changes.

When editing an applied profile, unavailable old choices do not block its other
changes. The review shows the restoration of their original values alongside
the new changes, and approval is still required. Unavailable choices stay saved
for later. Reviewing only unavailable choices saves them without changing the
active profile; restoring that profile remains a separate action.
Only catalog build, edition and expiry limits can make an existing choice
unavailable during an edit. Read errors, pending reads, restarts, remote sessions
and device or product requirements keep it in the plan with its saved original.
The engine must check those requirements again before applying the edit.
If an old choice needs restoring but its target cannot be read, the edit keeps
its backup and offers to save choices only. Unreadable controls, including
permission errors, unavailable providers and unfinished service transitions,
also stop an explicit restore. A confirmed missing or changed target can be
released without touching it so the rest of the profile can be restored.
A renamed catalog option keeps its old backup and allows
saving choices until the user restores that profile.

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
the request to its own backend root. The native actions include `tweak-catalog`, `tweak-status`, `tweak-preview`,
`tweak-apply`, `tweak-restore`, `tweak-recovery`, and `tweak-recover`.
`acceptDataLoss: true` (or `-AcceptDataLoss` on the direct wrapper) is additionally
required when the reviewed choices can delete Recall snapshots.

Apply returns `state`, `changed`, `replayed`, and `restorable`. `changed` counts
setting changes, not an ownership-only update. A replay returns the current state
without reapplying an old profile that may already have been restored. Older
reviews outside the retained receipt history are rejected as stale.

## Native recovery

Registry changes and their recovery receipt commit together in a Windows
registry transaction. The receipt is stored at
`HKLM\Software\RooIndustriesOptimizationSuite\Tweaks\<user SID>`, value
`State`. This store requires an administrator token, including for per-user
preferences. The PC, Windows user, store identity, catalog, review hash and
state revision bind each operation.

Non-registry changes use a durable `Pending` journal. Each attempted native
write is recorded before execution and read back afterward. Failure restores
completed changes in reverse order. An external change or failed restoration
retains the journal for recovery instead of reporting success. Registry changes
are committed only after the native phase succeeds. `tweak-recovery` reads the
receipt; `tweak-recover` requires confirmation and its exact pending hash.

Windows feature changes can require a restart. An accepted pending target is
reported separately from a completed change. The journal remains until a fresh
read after restart shows each changed feature's final state. Pending servicing
blocks another feature change or restoration. No automatic restart occurs.
When Windows undid a change during the restart, the check releases that
feature's ownership, keeps the rest of the profile, closes the journal and
adds a notice. A feature Windows no longer lists is released only when a
direct DISM check confirms it is absent or superseded. A partially installed
changed feature keeps the journal and every claim until servicing finishes.
An unrelated partially installed feature does not block normal reads or applies.
A feature in a state this app didn't set, or a restore Windows undid, keeps
the journal and names the feature so the user can set it in Turn Windows
features on or off and check again.

Hibernation uses `powercfg` and captures actual file mode plus five raw power
registry values, including their absence. Hibernation and Fast Startup share
one native resource with separate field ownership. Restoring one profile
preserves another profile's Fast Startup choice. Full hibernation requires S4
support; an unreproducible full-file size fails review before mutation.
Restoration covers configuration, not the contents of an earlier hibernation
image. Full/reduced modes need space for the Windows-managed file.

The file fixture uses the same planner, composition and ownership contract. It
does not change production Windows settings. Create it with `-Action
CreateFixture -FixturePath <new-file> -ConfirmApply`. Fixture reviews cannot
cross into the native Windows store.

## Executed verification

On the 9070XT, Windows build 26200 Professional:

- The approved native registry fixture passed 13 checks for apply, exact
  type/byte restoration, shared ownership, stale review, retries and rollback.
- The approved service/task/firewall/HKLM fixture passed 17 checks, including
  partial failure, interruption recovery and cleanup.
- The approved hibernation round trip exercised full and reduced modes and
  restored the original disabled state and five registry values. The app's
  profile apply/restore path then passed five native checks. No sleep,
  hibernation or restart was invoked; the temporary hibernation file was removed.
- Native temporary files verified exact permission/ownership restore (12 checks),
  hosts content and metadata recovery (6), and absent/existing download blockers (7).
- Native timer checks covered acquisition, release and lost-worker detection (6).
  A separate SSH session proved the worker survived its exited parent and session.
  The approved sign-in task test passed 6 checks for registration, real helper
  acquisition, stop, exact task removal and cleanup.
- Ultimate Performance passed 8 temporary-plan checks, including external selection
  preservation and returning to the captured prior plan from the explicit Off choice.
- The current settings fixture suite passed 136 checks. Public routes, AppX account
  scope, installed-app identity and the disposable bulk-removal queue also passed.
  Native restore-point enumeration succeeded; no new system restore point was created.

The current file-fixture suite also covers ownership composition, field drift,
device selection, missing inputs, dependencies and pending servicing. Run:

```powershell
./backend/scripts/Test-Tweaks.ps1 -DotNetPath "$env:USERPROFILE/.dotnet/dotnet.exe"
```

The separately approved native fixture switches are `--registry-fixture`,
`--controls-fixture` and `--power-fixture` on
`tools/validation/Tweaks/Tweaks.csproj`. They refuse unexpected baseline state
and clean only their owned test resources. They are not part of the ordinary
file-fixture run. `--feature-restart-fixture` is: it drives the real recovery
store in a disposable current-user key with simulated Windows feature states,
so no feature changes and no restart happens.

Catalog contracts and negative controls run with:

```sh
python3 tools/catalogs/compile_windows_tweaks.py --check
python3 tools/validation/check_baseline.py --contracts-only
```

## Integrated actions and limits

Windows settings includes search, categories, source filters, reusable profiles,
presets, before/after review, apply, restore and interruption recovery. Every
setting remains visible and selectable. Each row separates the current reading
from the proposed change. Choose a value, then turn on the row's switch to select
that action for review. Turning it off keeps the current setting; it does not undo
an applied change. Use Windows default explicitly removes the local override,
and another policy may still control the setting. Choices for missing components
are saved separately from applied Windows profiles and do not create a recovery
backup. They require a new review before Windows applies them. Backups & history reads
the actual recovery state. An empty list does not become a sample backup.

The section list separates Gaming, Network, Debloat, Apps, Privacy, Windows,
Updates, Devices, Security, and Services. All tweaks provides a combined search.
Selections and reviewed changes survive switching sections. Network opens first
and describes each preference's purpose, scope and material effects. Registry
paths and native command details stay in the internal review and recovery data.
Debloat links to the existing reviewed app-removal flow.

Section membership and network copy are generated without changing executor
identities or values:

```sh
python3 tools/catalogs/compile_tweak_presentation.py --check
```

Remove apps connects Widgets, Copilot, Edge and OneDrive to the existing
installed-app removal queue. Each remover and subsequent leftover cleanup has
its own review. The other-account option inventories exact installed AppX
registrations by SID; removal does not claim to deprovision future accounts.
WPD custom switches import registry, policy, service and task definitions into
the shared catalog. Importing alone applies nothing.

File ownership review captures one selected file or folder's identity, owner and
DACL. Hosts changes keep a marked block and preserve outside content and metadata;
a known interrupted write can be recovered from the durable journal. Razer and
Logitech download restrictions can create an absent folder, but restore removes
an owned folder only if it remains unchanged and empty.

The timer control owns a separate 0.5 ms request worker; its sign-in option uses
a current-user task. This replaces {source}'s system boot task with an interactive
session lifetime. The control reports the worker's request, not a measured game
benefit or proof that every process uses that interval. Ultimate Performance uses
an owned clone and restores the captured original selection, preserving external
changes and other plans.

Restore-point creation verifies a new Windows sequence and description, including
completion. Enumeration can lag behind completion, so verification polls for the
exact requested point and retains a retryable journal if it has not appeared.
A successful API return alone is insufficient. The optional creation
frequency override uses the same settings recovery engine. Recall snapshot
deletion opens Windows Privacy settings and guides the Windows-owned deletion
flow; opening the page is not reported as deletion success.

Source behavior is normalized where exact-state recovery is more appropriate:
restore preserves unrelated policy values and context menus; FTH changes preserve
learned history; Explorer folder-template changes preserve saved folder views;
WPD Group Policy controls write their documented policy values without claiming
to edit the Local Group Policy database. Edge encrypted DNS is an explicit setting,
not an automatic side effect of changing another Edge policy. Windows dialogs
handle BitLocker, Disk Cleanup and separately requested folder-view resets.

The Windows validation includes reversible tests for documentation-address DoH
entries, disconnected Wi-Fi settings, boot overrides, NTFS, Teredo, reserved
storage, an inactive firewall profile, SysMain and memory compression, ASLR,
TelnetClient and hibernation. Configuration readback and exact restoration are
checked separately. A real restore point was created, verified, replayed without
duplication, and removed while retaining existing points. System mitigation writes
capture raw registry values and change only selected fields; the layout is pinned
to inspected Windows binaries and is not a public mitigation registry ABI.
The sign-in task was created, explicitly run and removed in the approved fixture.
No reboot or actual sign-in cycle was performed.

The choice and preset matrices run every catalog entry through apply, replay,
shared ownership and restore using isolated files. They prove transaction behavior,
not the performance benefit or consumer effect of every Windows policy.

Windows UI state checks use the real view model with an isolated file transaction:

```powershell
dotnet run --project tools/validation/WindowsTweaksUi/WindowsTweaksUi.csproj -c Release -- .
```

The native fixture modes change system configuration and require approval of their
exact test scopes. The catalog matrices and UI state checks do not change Windows settings.
