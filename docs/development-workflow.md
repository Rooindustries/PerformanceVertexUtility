# Development workflow

Use Linux for source changes and Git operations. Use isolated Windows source copies for PowerShell 5.1 execution, native helper validation, and WinUI compilation. Test the AMD and NVIDIA paths separately; one machine's result does not establish the other's hardware behavior.

1. Start from a clean `main` and record its commit.
2. Run `python tools/validation/check_baseline.py` with the pinned validation requirements installed.
3. Copy source files to a new Windows test directory. Exclude `backend/state`, build output, credentials, screenshots, local work notes, and utility archives unless a specific test needs them.
4. Run `tools/scripts/Test-Baseline.ps1 -BuildFrontend`. Retain its summary and per-test logs outside source control.
5. Confirm that runtime state and test-owned processes, fixtures, helpers, and temporary power plans are cleaned up.
6. For UI work, launch the app on the intended Windows desktop, capture screenshots, inspect them, and share the evidence. Compilation alone is not UI verification.
7. Merge the validated changes into `main` and record the resulting commit and any limits of the checks.

The baseline workflow exercises discovery and controlled regression fixtures. It must not run real app uninstallers, delete user data, import real NVIDIA profiles, or alter services, registry settings, or drivers as incidental validation. An additional real-system experiment needs its own exact target, expected outcome, and recovery evidence.

The repository's local `vendor` archive and `scratch` captures are ignored development assets. Preserve them unless their deletion is requested. No remote repository is assumed; configure and verify the remote before publication.
