Run the single retained F12 case from the repository root:

```sh
python3 tools/validation/SetupMigration/run.py
```

The driver is restricted to `optimizer-9070`, verifies `SERVI-WINDOWS-D`, elevation, Intel i5-14600K and RX 9070 XT, and refuses existing same-user protected data-root markers. It creates an admin-only owned folder under Windows Temp and a unique user-data fixture below the token LocalAppData folder. It sends no production requests. Original product folders, CS2 tasks and recovery archives are never used as fixtures.

The Debug Host project links the actual Host Program.cs and Core project with its existing migration pause compiled in. Its module initializer installs a private HKU overlay independently in every Host process, verifies the actual BrandCompatibility root and DataFolder.Holds, and sets the existing copied-pause knob inside that test binary. The PowerShell wrapper independently overlays HKU and invokes the unchanged Invoke-GovernorSetup Resume script. HKLM stays native; cleanup addresses only exact owned root marker values and the exact owned hash-named task.

The additive `/migration=1` branch of SetupProcess.Test.iss calls the actual RunBounded with a 12-second test limit. The retained compiler diagnostic verifies the 64-bit helper's current directory and real Add-Type compiler before and after HKU overlay. It uses separate diagnostic type names and leaves the real Common helper compilation in Resume intact.

F12 requires a running, enabled, valid fixture task before Resume. During the actual copied pause it records source and stage payload hashes, `.migrating`, the nonempty SuspendedForMove task record, disabled scheduler state, zero workers, actual policy-status showing stopped, and the exact live policy-secure child identity. The real timeout must report 258 and end that child and its Resume parent. A fresh startup must recover the data and protection, resume one worker, and enforce AboveNormal on a fresh Normal probe. Cleanup must leave all original task XML/SDDL and relevant HKLM/HKU values identical.

Startup uses the actual linked DataFolderGate.cs. Its test-only UI/log stubs and service transport adapter invoke the actual Host `data-secure` and DataFolder.Require path. This verifies startup protection and recovery without launching WinUI; it does not verify the shipped window or service transport UI.

Source/binary hashes, native identities, JSON evidence, console output and before/after snapshots are downloaded under ignored `artifacts/continuation/setup-migration-evidence/<run>`. Owned data and executable staging remain on Windows for inspection. The driver returns a nonzero status on any failed case. It creates no commit or push and runs no full suite.
