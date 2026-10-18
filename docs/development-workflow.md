# Development workflow

Use Linux for source changes and Git operations. Use isolated Windows source copies for PowerShell 5.1 execution, native helper validation, and WinUI compilation. Test the AMD and NVIDIA paths separately; one machine's result does not establish the other's hardware behavior.

1. Start from a clean `main` and record its commit.
2. Run `python tools/validation/check_baseline.py` with the pinned validation requirements installed. Also run `python -m unittest discover -s tools/validation -p 'test_*.py'`, `python tools/validation/build_dotnet.py` (needs the .NET 8 SDK) and `pwsh tools/validation/check_powershell.ps1`, which needs PSScriptAnalyzer 1.25.0.
3. Copy source files to a new Windows test directory. Exclude `backend/state`, build output, credentials, screenshots, local work notes, and utility archives unless a specific test needs them.
4. Run `tools/scripts/Test-Baseline.ps1 -BuildFrontend`. Retain its summary and per-test logs outside source control. Suites that exceed `-TestTimeoutSeconds` (default 900; 2700 for the governor scenario suite) are stopped with their process tree and reported as timed out. `-ExcludeTestName`, `-ShardCount` and `-ShardIndex` split the suites across machines; CI runs the governor scenario suite on its own runner and the rest in two shards.
5. Confirm that runtime state and test-owned processes, fixtures, helpers, and temporary power plans are cleaned up.
6. For UI work, launch the app on the intended Windows desktop, capture screenshots, inspect them, and share the evidence. Compilation alone is not UI verification.
7. Open a pull request against `main`. Every pull request runs the step 2 checks; the Windows suite runs after the merge, or earlier through a manual run of the Baseline workflow. Record the merge commit and any limits of the checks.

The baseline workflow exercises discovery and controlled regression fixtures. It must not run real app uninstallers, delete user data, import real NVIDIA profiles, or alter services, registry settings, or drivers as incidental validation. An additional real-system experiment needs its own exact target, expected outcome, and recovery evidence.

The repository's local `vendor` archive and `scratch` captures are ignored development assets. Preserve them unless their deletion is requested.
