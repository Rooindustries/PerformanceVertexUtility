# BIOS settings workflow

Tools → BIOS settings keeps package setup, export, editing, review, import and recovery in the app. It edits AMISCE setup scripts; it does not flash a BIOS image or write arbitrary UEFI offsets.

On first use, select the Windows x64 SCEWIN folder supplied for the motherboard. The app shows the version, publisher, signature and files before copying the package. An unsigned executable requires an explicit source-trust decision. External drivers must have valid signatures. No driver is installed through an independent installer: SCEWIN uses its own matching package when the user selects Load settings. A successful export establishes script availability, not universal motherboard support.

The supplied `DL_SCEWIN.exe` is a downloader, not a firmware helper. It retrieves MSI Center and extracts SCEWIN. The app does not run that downloader or assume an MSI package supports a different motherboard. The first-use folder selection remains necessary until a compatible redistributable package is available.

## Import contract

- Export uses `/o /s <file> /v`. Import uses `/i /s <reviewed-file> /r`, preserving SCEWIN's HII checksum check. There are no BIOS-check bypass, automatic restart, password bypass, or raw-variable switches.
- The original bytes are retained with the PC identity, board, BIOS version, boot identity and hashes of all package executables, libraries and drivers.
- The editor supports unambiguous enumerated choices and decimal/hexadecimal numeric questions. Numeric validation checks the exported storage width. It does not infer undocumented voltage, timing or thermal limits. Passwords, ordered lists, strings, commented questions and ambiguous records are not offered as editable controls.
- Review produces a change-only script and an exact before/after list. Apply regenerates that script, checks the reviewed hashes and identities, then exports current settings again to detect intervening changes.
- An import-intent journal is written before launching the helper. A second apply of the same review returns the existing journal without importing again. A shared operation lock serializes the app, and an existing SCEWIN process blocks another command.
- A nonzero exit, reported error, uncertain result or mismatched re-export remains `needsAttention`. Verification cannot silently clear a prior import failure. A clean import plus matching values is `restartRequired`; a subsequent changed boot identity plus matching values is `applied`.
- Restart has a separate confirmation and re-verifies settings first. Undo requires a fresh export and review; values changed by another actor are not overwritten.
- Recovery exports are kept in `%LOCALAPPDATA%\RooIndustriesOptimizationSuite\firmware\sessions`. They are not a guarantee of recovery from a PC that cannot boot or run SCEWIN.

## Verification

Run `backend/scripts/Test-OptimizerCore.ps1 -Area firmware` for the parser and workflow checks. Run `backend/scripts/Test-FirmwareWorkflow.ps1` on Windows to add package inspection and actual process invocation through `ScewinProvider`, using a compiled file-only helper. The fixture never calls firmware APIs, loads a driver, or restarts Windows. It checks exported and imported bytes, switches, errors, interrupted/repeated/concurrent operations, undo and cleanup.

`tools/scripts/Test-ToolLauncher.ps1` separately verifies catalog resolution, portable dependency extraction, archive path containment, atomic cache publication and launching a disposable executable.

Real motherboard compatibility, driver loading, NVRAM writes and post-restart hardware behavior require a compatible vendor package and a separately approved settings review. They are not established by the file fixtures.

## References

- [Intel's AMISCE distribution and product scope](https://www.intel.com/content/www/us/en/download/19551/amisce-ami-setup-control-environment-utility-for-m10jnp2sb.html).
- [AMI Aptio SCE user guide, published by Intel](https://downloadmirror.intel.com/29468/eng/ami_aptio_5.x_sce_user_guide_nda.pdf), export/import syntax, HII verification, script formats and exit codes.
- [Microsoft firmware-variable API](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-setfirmwareenvironmentvariablew): firmware determines available variables; the Windows API is not a universal BIOS-settings interface.

Tool images come from the supplied utilities' executable resources or official product pages. Their provenance is recorded in `Assets/Tools/sources.json`; tools without an embedded or official product icon use a generic tool glyph.
