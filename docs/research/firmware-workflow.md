# BIOS settings workflow

Tools → BIOS settings keeps package setup, export, editing, review, import and recovery in the app. It edits AMISCE setup scripts; it does not flash a BIOS image or write arbitrary UEFI offsets.

On first use, **Set up and load settings** downloads a pinned official MSI Center archive and the upstream innoextract utility, extracts SCEWIN and its matching drivers, verifies the package, and continues into the original BIOS export and editor. MSI Center and its installers are not run. Setup downloads about 560 MB once; later visits reuse the verified package. Download progress and cancellation are available before firmware access starts. Partial downloads and extracted installers are removed after cancellation, failure or completion. Vendor sample BIOS exports and scripts are never installed or used as this PC's settings.

Acquisition uses a fixed archive size and SHA-256, a pinned extraction utility, HTTPS, signature verification, and the existing package fingerprint. Concurrent setup is serialized. A changed upstream archive requires a reviewed application update; it is not silently trusted. Source details and versions are recorded in [SCEWIN acquisition](scewin-acquisition.md). The app downloads vendor binaries on demand instead of shipping them in its repository or release package.

The page keeps its step, picked values, a running read or write, and the last result while you use other pages, so coming back shows where you left off. **Start over** returns to the first step; with unsaved picks it asks first. It never undoes a written change.

An optional **Use an existing SCEWIN package** section retains manual package selection. That path shows the version, publisher, signature and files before copying them; an unsigned executable requires an explicit source-trust decision. External drivers must have valid signatures. SCEWIN uses its matching driver package when settings are loaded. A successful export establishes script availability for the current firmware, not universal motherboard support or permission to import changes automatically.

## Import contract

- Export uses `/o /s <file> /v`. Import uses `/i /s <reviewed-file> /r`, preserving SCEWIN's HII checksum check. There are no BIOS-check bypass, automatic restart, password bypass, or raw-variable switches.
- The original bytes are retained with the PC identity, board, BIOS version, boot identity and hashes of all package executables, libraries and drivers.
- The editor supports unambiguous enumerated choices and decimal/hexadecimal numeric questions. Numeric validation checks the exported storage width. It does not infer undocumented voltage, timing or thermal limits. Passwords, ordered lists, strings, commented questions and ambiguous records are not offered as editable controls.
- Review produces a change-only script and an exact before/after list. Apply regenerates that script, checks the reviewed hashes and identities, then exports current settings again to detect intervening changes.
- An import-intent journal is written before launching the helper. A second apply of the same review returns the existing journal without importing again. A shared operation lock serializes the app, and an existing SCEWIN process blocks another command. A read or write attempted while another holds the lock reports "Another BIOS read or write is still running" instead of a file error.
- A nonzero exit, reported error, uncertain result or mismatched re-export remains `needsAttention`. Verification cannot silently clear a prior import failure. A clean import plus matching values is `restartRequired`; a subsequent changed boot identity plus matching values is `applied`.
- SCEWIN writes normal status and warnings to stderr. Success requires its zero exit status and no reported error on either stream; missing saved result fields remain invalid. The parser accepts the helper's doubled carriage return after `HIICrc32` while retaining the original bytes and requiring one complete checksum.
- Some boards show a live reading in a setting name, such as `Internal CPU Vcore 1.079V` becoming `1.078V`, which also changes `HIICrc32`. Comparisons treat that as the same layout only when the exports differ in nothing but numbers in setting names and the values themselves; every question must keep its context, token, offset, width, variable, options and value. A checksum change with no name change, a renamed or moved question, or any changed value still fails. Apply still refuses a checksum that changed after loading, because SCEWIN checks the script's checksum, and asks for a reload without claiming a setting changed.
- Restart has a separate confirmation and re-verifies settings first. It sets the one-time firmware boot target to Windows Boot Manager (`bcdedit /set {fwbootmgr} bootsequence {bootmgr}`) so dual-boot PCs return to Windows, and still restarts if that command fails. Undo requires a fresh export and review; values changed by another actor are not overwritten.
- Recovery exports are kept in `%LOCALAPPDATA%\RooIndustriesOptimizationSuite\firmware\sessions`. They are not a guarantee of recovery from a PC that cannot boot or run SCEWIN.

## Verification

Run `backend/scripts/Test-OptimizerCore.ps1 -Area firmware` for the parser and workflow checks. Run `backend/scripts/Test-FirmwareWorkflow.ps1` on Windows to add package inspection and actual process invocation through `ScewinProvider`, using a compiled file-only helper. The fixture never calls firmware APIs, loads a driver, or restarts Windows. It checks exported and imported bytes, switches, errors, interrupted/repeated/concurrent operations, undo and cleanup.

The same command checks automatic acquisition against disposable nested archives through the production download/extraction path: exact hashes, changed sizes, interrupted downloads, insecure sources/redirects, missing or duplicate archive members, concurrent setup, extraction failure, clean retry and preservation of an existing package. Its extractor substitutes archive fixtures and never executes a vendor installer. To check the real vendor download and signature inspection without launching SCEWIN, run `dotnet run --project tools/validation/OptimizerCore/OptimizerCore.csproj -c Release -- --firmware-download <disposable-package-directory>` on Windows.

`tools/validation/AppSweepUi/Test-FirmwarePage.ps1` drives the page's view model through the same CLI fixture: leaving and coming back while editing, during a held write and after it, Load during a write, a failed write, Start over, and an app closed mid-write. `tools/validation/AppSweepUi/Invoke-FirmwarePageUi.ps1` runs the same journey in the real app on the Windows desktop (built with `-p:RooIndustriesTestHooks=true`, which points the page at a disposable fixture folder) and saves screenshots, timestamped window frames for a video, and `ui-result.json`. It refuses to load settings unless the page shows the fixture package.

`tools/scripts/Test-ToolLauncher.ps1` separately verifies catalog resolution, portable dependency extraction, archive path containment, atomic cache publication and launching a disposable executable.

The approved read on the the i5-14600K test PCXT's Gigabyte B760M DS3H WIFI6E DDR4 GEN5, AMI F4, returned a real BIOS export with SCEWIN 5.05.01.0002. Its unchanged bytes parse into 4,693 supported settings. The helper removed its driver services after export, and Secure Boot and Memory Integrity remained enabled. Actual NVRAM imports and post-restart hardware behavior still require a separately approved settings review; file fixtures and a successful read do not establish those outcomes.

## References

- [Intel's AMISCE distribution and product scope](https://www.intel.com/content/www/us/en/download/19551/amisce-ami-setup-control-environment-utility-for-m10jnp2sb.html).
- [AMI Aptio SCE user guide, published by Intel](https://downloadmirror.intel.com/29468/eng/ami_aptio_5.x_sce_user_guide_nda.pdf), export/import syntax, HII verification, script formats and exit codes.
- [Microsoft firmware-variable API](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-setfirmwareenvironmentvariablew): firmware determines available variables; the Windows API is not a universal BIOS-settings interface.

Tool images come from the supplied utilities' executable resources or official product pages. Their provenance is recorded in `Assets/Tools/sources.json`; tools without an embedded or official product icon use a generic tool glyph.
