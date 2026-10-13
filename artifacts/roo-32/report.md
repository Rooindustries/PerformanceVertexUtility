# ROO-32 foreground memory relief

Decision: adopt foreground-idle relief. The page-cache change is not adopted. The experiment's foreground branch is unchanged except that its success log is removed. Failure logging remains. No working-set trim was added to the foreground path. Existing minimize/background relief remains.

## Changes and source binding

- `MemoryRelief.cs`: global ten-second input-idle threshold, two-second polling after navigation, generation cancellation and aggressive compacting GC with one LOH compaction. Detach invalidates pending foreground work.
- `MainWindow.xaml.cs`: call PageShown on frame navigation and initial attachment.
- `tools/validation/Memory/`: committed journey, build/install/restore driver, optional ClrMD HeapProbe, summaries and named process-exit E2E. The shared path lint covers the new suite.

Product commit `84b2c79`; initial E2E commit `8b2915f`. Three-run measurement/build head `1e3e61bd5f61cfbc3a09796ea3fe5bf4b0f140ee`; cleanup-audit delta head `2c44286cfbfaaa2dd64c06e016df912f4b4a3920`; targeted sampler fixture head `45486ab1154df6d87a8f5b4a3ee84391119370d1`. Later changes affect audit comparison and the new fixture only; product and measurement code were not changed after the completed three-run gate.

## Experiments accepted by the lead

| Experiment, all-run medians | Final Home private WS / bytes MiB | Post-reopen private WS / bytes MiB |
| --- | ---: | ---: |
| X, original caching | 268.934 / 382.234 | 277.320 / 396.770 |
| Y, three pages uncached | 255.832 / 367.875 | 322.246 / 443.543 |
| Z, foreground relief with success logs | 196.520 / 292.668 | 284.641 / 409.492 |

Y saved 13.102 MiB private working set at final Home and cost 44.926 MiB more after reopening. Z saved 72.414 MiB at final Home and stayed within the selected post-reopen/minimized budgets. Its 33 logged collections had 59 ms median and 96 ms p95/max pauses; reachable managed objects stayed near 27.3 MiB while GC segments fell from 73.379 to 31.355 MiB. These are the accepted experiment artifacts under the main checkout's `artifacts/roo-32/experiment/`; neither control was rerun.

UIA does not update GetLastInputInfo. The supplied loop checks global input age on its first two-second poll, so relief can occur near two seconds after navigation when input was already idle. It does not enforce a ten-second page-age delay. The final build intentionally has no success/pause logging.

## Final memory E2E

Command (host arguments use the authorized i5-14600K test PC; paths below are placeholders for the recorded command inputs):

```sh
python3 -I tools/validation/Memory/run_memory.py --scenario baseline \
  --host <test-pc> --expected-machine <computer-name> --runs 3 --heap-probe \
  --compare <main-checkout>/artifacts/roo-32/experiment/X/memory.csv \
  --restore-installer <main-checkout>/artifacts/release/RooIndustries-OptimizationSuite-0.11.0-beta-setup.exe \
  --restore-sha256 7fd804b4082fd3e92ccb6bd0693530ab0bee8a7d9e41fba44c03ecef92707bb9 \
  --out-dir artifacts/roo-32/gate
```

The unsigned 0.11.1-beta measurement build completed in 131.897 s, with embedded feed `url=`. Installer: 110,087,616 bytes; SHA-256 `2840640a6512136ecfdbd88f01c16947cb2ca6592753991a6bb5e95d7295bcff`. Build-Release smoke/layout checks passed.

Three independent app lifetimes produced 51 regular points, three post-reopen points, 27 reopen timings and one final-Home heap probe. The two additional unfocused points are after minimize, preserving the accepted gate order. The all-run results retain flagged run 1; the sensitivity view excludes it.

| Point | X private WS MiB | Final build private WS MiB | Difference MiB | Final build private bytes MiB |
| --- | ---: | ---: | ---: | ---: |
| final-Home-60s | 268.934 | 196.395 | -72.539 | 291.223 |
| minimized-60s | 7.062 | 6.965 | -0.098 | 345.406 |
| unfocused-10s | not measured | 23.188 | unavailable | 345.043 |
| unfocused-40s | not measured | 1.523 | unavailable | 303.543 |
| post-reopen-Home-15s | 277.320 | 247.391 | -29.930 | 356.367 |

Unflagged medians, final Home: 198.295 MiB private WS / 292.779 MiB private bytes; post-reopen: 249.670 / 352.957; minimized: 7.447 / 337.385. Full all-run and unflagged per-point tables are in `gate/medians.csv` and `gate/differences.csv`. Accepted X lacks unfocused samples, so no paired difference is invented.

| Gate check | Observed | Result | Evidence |
| --- | --- | --- | --- |
| PS 5.1 parse | 5.1.26100.9444, zero errors | pass | gate/parse.json; sampling-checks-final/parse.json |
| final-Home-60s | -72.539 MiB measured − X; allowed ≤ -30 MiB | pass | gate/summary.json; gate/memory.csv; gate/post-reopen-memory.csv |
| post-reopen-Home-15s | -29.930 MiB measured − X; allowed ≤ +15 MiB | pass | gate/summary.json; gate/memory.csv; gate/post-reopen-memory.csv |
| minimized-60s | -0.098 MiB measured − X; allowed ≤ +2 MiB | pass | gate/summary.json; gate/memory.csv; gate/post-reopen-memory.csv |
| reopen Windows tweaks | +1.135 ms median − X; allowed ≤ +50 ms | pass | gate/reopen.csv; gate/summary.json |
| reopen Tools | -3.356 ms median − X; allowed ≤ +50 ms | pass | gate/reopen.csv; gate/summary.json |
| reopen Remove apps | +14.769 ms median − X; allowed ≤ +50 ms | pass | gate/reopen.csv; gate/summary.json |
| memory relief failure logs | 0 matching lines | pass | gate/app-log-run1.txt through app-log-run3.txt |
| foreground success logging removed | 0 matching lines | pass | gate/app-log-run1.txt through app-log-run3.txt |
| installedVersionRestored | verified | pass | gate/cleanup-audit-final.json; gate/final-inventory.json |
| installedPayloadRestored | verified | pass | gate/cleanup-audit-final.json; gate/final-inventory.json |
| dataByteIdentical | verified | pass | gate/cleanup-audit-final.json; gate/final-inventory.json |
| dataRootPresenceRestored | verified | pass | gate/cleanup-audit-final.json; gate/final-inventory.json |
| rawRegistryByteIdentical | verified | pass | gate/cleanup-audit-final.json; gate/final-inventory.json |
| CS2TasksUnchanged | verified | pass | gate/cleanup-audit-final.json; gate/final-inventory.json |
| legacyFramesUnchanged | verified | pass | gate/cleanup-audit-final.json; gate/final-inventory.json |
| noOwnedFrame | verified | pass | gate/cleanup-audit-final.json; gate/final-inventory.json |
| zeroRooOrFrameProcesses | verified | pass | gate/cleanup-audit-final.json; gate/final-inventory.json |
| leaseAbsent | verified | pass | gate/cleanup-audit-final.json; gate/final-inventory.json |
| hostsByteIdentical | verified | pass | gate/cleanup-audit-final.json; gate/final-inventory.json |
| firewallUnchanged | verified | pass | gate/cleanup-audit-final.json; gate/final-inventory.json |
| testCertificatesUnchanged | verified | pass | gate/cleanup-audit-final.json; gate/final-inventory.json |
| scheduledTasksRestored | verified | pass | gate/cleanup-audit-final.json; gate/final-inventory.json |
| Shared path lint / Python compilation | pass | pass | lint.log; py-compile.log |
| Real sampler helper-exit / app-exit cases | 2/2 | pass | sampling-checks-final/receipt.json |

Reopen all-run median/max ms: Windows tweaks 175.494/208.814, Tools 83.664/109.628, Remove apps 184.857/300.859. Markers are unchanged: WindowsTweaksList realized visible ListItem, OpenFirmware enabled visible Button, RemovalApps realized visible ListItem. Timer includes Select() returning and uses a 20 ms UIA poll; it does not claim all backend work is complete.

## What the checks vary and ignore

| Check | Control varied / effect observed | Fields outside its claim |
| --- | --- | --- |
| Memory budgets | Foreground relief versus frozen X; PID-matched private WS medians at named points | Whole-machine/GPU allocations and user-input latency |
| Reopening | Same Select() and content markers; median/max per page | Backend completion after the marker |
| App logs | Cursor-bound owned lifetimes; failure lines and removed success logging | GC pause duration in the final build, which no longer logs it |
| Sampler exit fixture | Real helper stopped after enumeration before Get-Process; real app separately stopped | Long-running foreign-worker behavior, covered by the unchanged ownership guard |
| Restore audit | Installed app/backend hashes, 449 data-file hashes, registry type/raw bytes, Suite/CS2 tasks, host state | Suite rule StartBoundary rebasing and unrelated Windows schedule changes |

## Harness repairs and evidence

1. Remote bootstrap initially loaded the memory module before its shared path helper. Fixed ordering; no build/install occurred in that attempt. Evidence: `gate-bootstrap-failure/`; its ledger closed.
2. A short-lived candidate exited between CIM enumeration and Get-Process during a partial run. The measured app had a different PID. The sampler now records the exited descriptor separately, invents no metrics and adopts no exited PID. Failed-lifetime log segments are preserved in finally. Evidence: `gate-helper-race/`; deterministic repair check `sampling-checks-final/receipt.json` uses the real sampler functions and Windows counters. The completed gate itself had zero sampling races.
3. Post-frame audit needed the installed-root context for the product's data-folder resolver. The source-free audit now supplies it; restored data/registry/payload readback passes.
4. Setup rebases the Suite governor trigger StartBoundary. Only that field is ignored for Suite process-rule tasks; other Roo/CS2 definitions and enabled state are checked. Two unrelated Windows tasks also self-rescheduled during the measurement: SoftwareProtectionPlatform/SvcRestartTask and Flighting/OneSettings/RefreshCache. Their raw XML snapshots are retained; no harness command changed or restored them. The audit now distinguishes those schedules from owned changes.
5. The new targeted fixture initially intercepted its own cleanup recursively. A one-shot interception guard fixes the fixture. Earlier attempts are retained under `sampling-checks/` and `sampling-checks-rerun/`; the final 2/2 receipt is `sampling-checks-final/`.

The original `gate/receipt.json` retains the overbroad task-audit failure. `gate/gate-final-receipt.json` is the passing composite receipt: measurements on the recorded head plus the repeated corrected audit. No product or measurement code changed for that audit correction; the targeted fixture was added afterwards.

## End state and review

Published 0.11.0-beta is restored from the hash-verified local installer. App closed; governor disabled/paused as found. App/backend payload hashes, both data-root presence states, all 449 file hashes and raw registry value types/bytes match the as-found snapshot. Six CS2 tasks remain Ready and Enabled with identical XML; 160 legacy frames are untouched. All owned ledgers are closed, and no owned processes, frames, lease, firewall/hosts entry, certificate or update cache remain. Zero production installer downloads; no production uploads or publishing. Blackwell, KVM and LongPathsEnabled were untouched.

Self-review: the two-file product diff matches the accepted Z behavior without success logging, and the page-cache change is absent. Foreground work is invalidated on Detach and superseded navigation; the existing minimize/background path remains. The reusable E2E has explicit machine and restore inputs, a fresh immutable source frame, host lease, nonce/hash bindings and cleanup status computed after restoration. All requested numerical gates pass. I agree this branch is ready for lead review and merge.
