# ROO-94: 0.11.1-beta release candidate

Release verdict: **ready for the lead’s review and publishing approval**. No product failure or open release blocker was found. Nothing was published or uploaded. Real feed-driven 0.11.0 → 0.11.1 OTA remains a post-publish check; P2b proves only the installer launch.

Branch: `servi/roo-94-release-0-11-1`, base `b572dddbb3e6563e59d9df6735d28ebdce5b088e`. Release/test head `688eddc7858df73dba14d628ce4f06d6b4141d85`. The report-only commit follows this head.

## Product changes

- `b57989c`: app Version `0.11.1-beta`; Build-Release numeric derivation is `0.11.1.0`.
- `e562d66`: RecoverAsync considers only cached versions newer than the installed assembly version; current/older cleanup cannot race their manifest reads. Newer failed targets retain recovery.

```diff
diff --git a/docs/internal/frontend/RooIndustries.OptimizationSuite.App/RooIndustries.OptimizationSuite.App.csproj b/docs/internal/frontend/RooIndustries.OptimizationSuite.App/RooIndustries.OptimizationSuite.App.csproj
index dfa1c69..2e74d9b 100644
--- a/docs/internal/frontend/RooIndustries.OptimizationSuite.App/RooIndustries.OptimizationSuite.App.csproj
+++ b/docs/internal/frontend/RooIndustries.OptimizationSuite.App/RooIndustries.OptimizationSuite.App.csproj
@@ -10,7 +10,7 @@
     <Title>Roo Industries Optimization Suite</Title>
     <Product>Roo Industries Optimization Suite</Product>
     <Company>Roo Industries</Company>
-    <Version>0.11.0-beta</Version>
+    <Version>0.11.1-beta</Version>
     <IncludeSourceRevisionInInformationalVersion>false</IncludeSourceRevisionInInformationalVersion>
     <ApplicationManifest>app.manifest</ApplicationManifest>
     <Platforms>x86;x64;ARM64</Platforms>
diff --git a/docs/internal/frontend/RooIndustries.OptimizationSuite.App/Services/UpdateService.cs b/docs/internal/frontend/RooIndustries.OptimizationSuite.App/Services/UpdateService.cs
index 6c59f8a..2336619 100644
--- a/docs/internal/frontend/RooIndustries.OptimizationSuite.App/Services/UpdateService.cs
+++ b/docs/internal/frontend/RooIndustries.OptimizationSuite.App/Services/UpdateService.cs
@@ -195,8 +195,9 @@ public sealed class UpdateService
             }
             _ = CleanInstalledCacheAsync(root);
             if (_feed is null) return;
+            if (!SemanticVersion.TryParse(CurrentVersion, out var installedVersion)) return;
             var candidates = Directory.EnumerateDirectories(root).Select(folder => new { Folder = folder, Name = Path.GetFileName(folder) })
-                .Where(item => SemanticVersion.TryParse(item.Name, out _)).OrderByDescending(item => { SemanticVersion.TryParse(item.Name, out var value); return value; });
+                .Where(item => SemanticVersion.TryParse(item.Name, out var version) && version!.CompareTo(installedVersion) > 0).OrderByDescending(item => { SemanticVersion.TryParse(item.Name, out var value); return value; });
             foreach (var candidate in candidates)
             {
                 var path = Path.Combine(candidate.Folder, "manifest.json");
```

## Gate

| Check | Observed | Result | Evidence |
| --- | --- | --- | --- |
| Fresh staging + PS 5.1 parse + HarnessTrace compile | Verified report-bearing source; zero parse errors | pass | `a-parse.json`, `staging-receipt.json`, `a-staging-cleanup.json` |
| B all scenarios | 21/21, including normal install, failure, copy-failure and cache-lock retries | pass | `b-suite/all/scenario-results.json`, `b-suite/all/pc-artifacts/ota/` |
| ready startup | Newer 0.11.2-beta cache retained; older cache removed; no recovery-error status/log | pass | `b-suite/all/pc-artifacts/ota/ready-c6c8e8a4016b457d9b8eabeb2006cad4/ready-startup-no-recovery-error-c6c8e8a4016b457d9b8eabeb2006cad4-0007.json` |
| Contracts | 25/25 signed-feed cases | pass | `b-suite/contracts/pc-artifacts/ota/`, `b-suite/contracts/runner.log` |
| Close during check | Exact canceled: the app is closing line; clean exit | pass | `b-suite/close-during-check/pc-artifacts/ota/` |
| Signed subset | Explicitly skipped: signing code unchanged since accepted 381094b | not rerun | `gate-product-parity.json` |
| Production-feed release build | Exit 0; smoke test; all three path-bound checkpoints; unsigned; 1379 payload files | pass | `release-build/receipt.json`, `release-build/candidate-release-build-stdout-*.log`, `release-build/payload-hashes.json` |
| Candidate P2: real 0.10.0 → RC wizard | 22/22 checks; full payload/preservation, fresh governor and discriminating saved-rule proof | pass | `p2/p2/receipt.json`, `p2/p2/pc-artifacts/` |
| Candidate P2 live feed | “You have the latest version”; no download/cache; no exceptions/setup errors | pass | `p2/p2/receipt.json` |
| P2b launch stand-in | 24/24 checks; exact pending fields and command; traced relaunch; updated banner; preservation/governor/payload | pass | `p2b/p2b/receipt.json`, `p2b/p2b/pc-artifacts/` |
| P2b installed cache | Gone 6.147 seconds from native app birth (35 s bound) | pass | `p2b/p2b/receipt.json` |
| Manifest prepare + verify | Linux only; installer ProductVersion, size/SHA and ECDSA envelope verified | pass | `manifest/receipt.json`, `manifest/verify.log` |
| End installation | Published 0.11.0-beta; exact 7fd804b4… local bytes | pass | `end-install/receipt.json` |
| As-found/cleanup | All 16 audit checks; raw bytes and 449 files restored; all ledgers terminal | pass | `cleanup-audit.json`, `raw-registry-final.json`, `terminal-ledger-audit.json`, `update-cache-audit.json`, `linux-process-audit.json` |

The B suite ran at `94debf51ce76b79888221742d0e67dc29d27f8cd`. Build/P2/P2b ran at `688eddc7858df73dba14d628ce4f06d6b4141d85`. The difference between these heads is validation-only, including P2b’s baseline/pending readback and the candidate wrapper corrections. `gate-product-parity.json` proves an empty product diff. The exact product fixes are unchanged across every gate.

## Candidate and manifest

- Installer: `/home/serviroo/Desktop/Code/LeanClientOptimizer/artifacts/release/RooIndustries-OptimizationSuite-0.11.1-beta-setup.exe`
- Size: **110,084,774 bytes**.
- SHA-256: `d03bb21101cbd0f64b4429f3fb4aac751bb976d25b3796080dc65a9b5c971ca0`.
- Build receipt: `artifacts/release/RooIndustries-OptimizationSuite-0.11.1-beta-setup.build.json`.
- Payload hash list: `artifacts/release/RooIndustries-OptimizationSuite-0.11.1-beta-setup.payload-hashes.json` (1,379 entries), also `release-build/payload-hashes.json`.
- Embedded raw resource: `url=https://81pttzmhr81hs8hb.public.blob.vercel-storage.com/u/DoivrJtEaTb3vhUKDJzQJlDCKIzdZdgX/beta.json`. Parsed URL exactly equals `tools/release/update-feed.txt`.
- Manifest SHA-256: `cbe279370b907f7c4ef03ad699fa167b509da3a8aa5190cbe73649a407579e52`.
- Fresh 32-character slug URL: `https://81pttzmhr81hs8hb.public.blob.vercel-storage.com/b/bfLhwtoYxyxre9B5pnNUJKGFdz17RVy2/RooIndustries-OptimizationSuite-0.11.1-beta-setup.exe`.
- User-authored notes were not edited; signing key stayed on Linux.

Verify output:

```json
{"verified": true, "version": "0.11.1-beta", "installer": {"url": "https://81pttzmhr81hs8hb.public.blob.vercel-storage.com/b/bfLhwtoYxyxre9B5pnNUJKGFdz17RVy2/RooIndustries-OptimizationSuite-0.11.1-beta-setup.exe", "size": 110084774, "sha256": "d03bb21101cbd0f64b4429f3fb4aac751bb976d25b3796080dc65a9b5c971ca0"}}
```

## Commands and provenance

All commands run from the roo-94 worktree except manifest/verify, which ran from main as explicitly requested. The only writes under main were the authorized release artifacts; main source was never edited. Full argument arrays and Windows commands are saved with each receipt.

```sh
python3 -I tools/validation/Update/run_e2e.py --host optimizer-9070 --expected-machine SERVI-WINDOWS-D --feed-url https://roo-devbox.tail9fe6d9.ts.net:8460/ota-e2e/beta.json --signing-key /home/serviroo/.config/roo-industries/update-signing/roo-update-signing-p256.pem --receipt artifacts/roo-94/b-suite/frame.json --build-root <frame>\b --scenario all --skip-contracts --out-dir artifacts/roo-94/b-suite/all --evidence-root <frame>\all
# Then contracts and close-during-check with --skip-build on the same receipt/pair.
tools/validation/Update/Build-ReleaseCandidate.ps1 -Source <fresh-source> -OutRoot <fresh-frame>\r
# It invokes Build-Release.ps1 -OutputRoot <frame>\r\release -UpdateFeedUrl <exact committed feed>.
python3 -I tools/validation/Update/run_shipped.py --scenario p2 --candidate --source-commit 688eddc7858df73dba14d628ce4f06d6b4141d85 --host optimizer-9070 --expected-machine SERVI-WINDOWS-D --baseline-installer /home/serviroo/Desktop/Code/LeanClientOptimizer/artifacts/release/RooIndustries-OptimizationSuite-0.10.0-beta-setup.exe --baseline-sha256 6c6515cdf93c6b5751a37957ae855962d534ca786720773571747d202b576ed4 --published-installer /home/serviroo/Desktop/Code/LeanClientOptimizer/artifacts/release/RooIndustries-OptimizationSuite-0.11.1-beta-setup.exe --innoextract /home/serviroo/Desktop/Code/LeanClientOptimizer/artifacts/roo-29/p0/tool/build/innoextract --out-dir artifacts/roo-94/p2
# P2b: same command, --scenario p2b, published 0.11.0 baseline SHA 7fd804b4082fd3e92ccb6bd0693530ab0bee8a7d9e41fba44c03ecef92707bb9, fresh p2b out-dir.
```

P2 uses locally staged candidate bytes with ZoneId=3. Its unsigned ShellExecute path showed the ordinary Open File security warning, whose owned Run button was activated; **SmartScreen did not appear**, so no fallback without MOTW was used. P2b downloads the verified live 0.11.0 installer once on Windows, compares it with the supplied known baseline, leaves that app/governor running, then uses the candidate handoff probe. The actual pending file is read back before closing the app. The probe calls RuntimeEnvironment.Apply from the installed 0.11.0 Core and holds the rehashed installer until the app exits. Its pending writer uses OperationFiles and camelCase. App closure uses the normal main-window close. No signed feed offered the candidate.

P2 and P2b both observed the fixture initially at CPU Normal, affinity 0xFFFFF and memory priority 5; the fresh governor changed the same native process to High, 0x3 and memory priority 2. I/O remained Normal (2). PID and native-birth replacement were asserted for each governor.

## Harness fixes / deviations

- Explicit `--candidate` mode was necessary: the original shipped harness demanded the local installer match the live 0.11.0 feed and would otherwise download that installer. The live feed remains independently verified and the candidate is explicitly local/unpublished. Fusion challenge general/10 records this mismatch and resolution.
- Candidate wrapper initially used a relative PowerShell name; it failed before any product build. Fixed to the explicit system executable. One diagnostic retry confirmed the cause; both failed frames are terminal.
- Candidate wrapper initially compared the raw `url=…` resource with a bare URL. Build and smoke passed; the harness check failed. Fixed to compare the exact resource wire format and report its parsed URL. Only the touched release build was rerun. No product patch.
- Operator cleanup initially tried to treat the existing updates parent as an empty owned container; the guard retained it. The retry excluded that as-found parent and required prior ledger removal receipts for already removed files. Only the owned new log was removed; all original bytes were restored.
- No signed rerun, Blackwell/KVM contact, trust/Defender change, push, publish or LongPathsEnabled change.

## What the checks prove

| Control varied | Observes | Does not claim |
| --- | --- | --- |
| B manifest, installer bytes, availability, game/timer state, cancellation and setup faults | Typed/status/log refusal, process ownership, actual install/relaunch, payload and bounded cleanup | Public CDN delivery of the unpublished candidate |
| P2 baseline = exact real 0.10.0, candidate = exact local RC, MOTW on | Wizard defaults/security warning, installed payload, byte preservation, native governor replacement and three distinct rule controls | SmartScreen behavior on another PC; it did not appear here |
| P2b installed baseline = published 0.11.0, exact silent launch = candidate | Actual pending JSON, deliberate environment, command flags, clean close, traced relaunch/banner, payload/preservation/governor/cache | Feed offer, signed-manifest download or Install confirmation before publication |
| Snapshot restoration | Exact file hashes, raw registry type/bytes, unchanged six CS2 task XML/state and legacy-frame birth identities, terminal ownership ledgers | Other PCs or unrelated optimization controls |

## End state and audit

9070: published **0.11.0-beta**, app closed, governor **paused/disabled as found**. Both data roots retain their original presence; all **449 files** are byte-identical, with zero new/missing/changed files. Raw registry values retain their original types and exact bytes (including the 17,833,984-byte tweak State). Six CS2 tasks remain Ready/Enabled with identical XML. All 160 legacy frames keep the same path/native creation identity. No owned Suite/frame process, task, firewall rule, hosts entry, certificate, host lease, release cache or owned frame remains. Linux tailnet JSON is unchanged, with no 8460 entry; the as-found support server PID 1530 is preserved. No owned process was left running.

**Completed production installer downloads: 1**, published 0.11.0 during P2b. Candidate downloads: 0; 0.10 downloads: 0 (known local release staged); uploads/publishes: 0. Live-feed checks are read-only GETs.

## Next publish command (NOT RUN)

Run only after the lead/user authorizes publishing, from the main checkout:

```sh
python3 tools/release/publish_update.py publish --installer artifacts/release/RooIndustries-OptimizationSuite-0.11.1-beta-setup.exe --manifest artifacts/release/RooIndustries-OptimizationSuite-0.11.1-beta-feed.json --installer-path b/bfLhwtoYxyxre9B5pnNUJKGFdz17RVy2/RooIndustries-OptimizationSuite-0.11.1-beta-setup.exe --feed-path u/DoivrJtEaTb3vhUKDJzQJlDCKIzdZdgX/beta.json --yes-publish
```

I agree this release candidate is ready. The remaining production verification is the real feed-driven OTA after publishing.
