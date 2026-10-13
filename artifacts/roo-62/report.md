# ROO-62 validation report

## Slice 21: final B gate passed

**Verdict: READY. I agree A and B are ready to merge to main.** The accepted low, rare cache-cleanup finding is fixed and independently reproduced with locked files. All 21 scenarios, 25 contracts, close-during-check and the signed subset pass. Final cleanup and exact as-found comparisons pass. The historical Slice 20 stop below is resolved by this round.

### Source binding and changes

Gate/code head A: **fa814a1e106853f812a97ed1e02cb7cc747d1b60**. Gate/code head B: **b3e26d789c27baa46aaf5f3010c534566ee03f07**. Product/fixture commit: `b3e26d7` (`fix(update): retry cache cleanup and narrow release path bounds`). Final report-only commit and merge SHAs are recorded in `artifacts/roo-63-64/slice21/final-branches.json` and the handoff. No code changed after either B gate frame was staged.

B changes six files, **147 insertions / 21 deletions**:

| Change | Code location | Verification |
| --- | --- | --- |
| Retry deletion of current/older semantic-version cache directories independently of pending-install.json, up to 30 attempts, one second apart; cancellation exits and other exceptions are logged | `docs/internal/frontend/RooIndustries.OptimizationSuite.App/Services/UpdateService.cs:141`, call at `:196` | Actual install, copy-failure, 5-second/40-second deny-delete locks, next start and newer-ready cache checks below |
| Keep successful pending banner/record behavior and install-log trimming; remove the old one-shot installedFolder deletion | `UpdateService.cs:185` | Updated banner, consumed pending record, three retained install logs and byte-identical status assertions |
| Limit post-publish output bounds to stage and wasdk; retain the pre-build XAML bound | `tools/scripts/Build-Release.ps1:175` | Bound fixture 3/3; unsigned, signed and wrong-subject build checkpoints |
| Native-birth deadlines and independently timed deny-delete handle; newer cache hash/identity readback | `tools/validation/Update/Invoke-UpdateScenario.ps1:140`, `:150`, `:300`, `:382` | Nonce-bound JSON and screenshots retained in the gate artifacts |
| Named cache-cleanup scenario, included as an auxiliary check under the existing same-version row | `tools/validation/Update/run_e2e.py:170`, `:393`; `tools/validation/Update/README.md` | Full all sequence remains 21 required rows and executes the additional lock races |
| Exercise actual boundedOutputs assignment from the release script | `tools/validation/Update/Invoke-ReleaseBoundChecks.ps1:26` | A 327-character staged file refuses; a 342-character obj-only file remains and passes |

A has **no code change in Slice 21**. Since its accepted `68d157f` gate, the only code changes were `Build-UpdatePair.ps1:13` (`source-B` to `c`) and `Invoke-SigningScenario.ps1:41` (same copy root in its XAML guard). The pair builder is byte-identical in A/B and was executed by both fresh B pairs. The exact A guard body was also executed against the actual signed layout: 239-character XAML intermediate passes, an 80-character deeper root refuses. A's product-source diff against `20618f6` remains empty, SHA-256 `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`. Evidence: `a-affected-code.json`, `a-signing-guard-command.json`, `a-signing-guard-check.json`, `product-source-binding.json`.

The Slice 20 mid-gate correction shortened the temporary copy to `c` and aligned the signing preguard. It did **not** weaken the bound. This round supersedes the obj-inclusive output audit that caused the generated-editorconfig refusal; it keeps the short layout and pre-build XAML protection.

### Cache checks a–d

Times below are the first independent observation of absence relative to **native app creation**, not a claim of the precise deletion instant. Evidence paths in this section are under `artifacts/roo-63-64/slice21/`.

| Check | Decisive control and observed effect | Result | Evidence |
| --- | --- | --- | --- |
| a. Normal silent OTA | Correct signed manifest/installer, normal setup; installed 0.11.1-beta cache absent by **10.45 s** from relaunch | PASS | `unsigned/installed-cache-cleanup.json`; nonce-bound install result and screenshot under `unsigned/all/pc-artifacts/ota/install-a778add1fc5646b78d299ae8ea07811a/` |
| b. Mid-copy failure plus interactive finish | Only forced copy failure varies; app relaunched with updated banner; installed-version cache absent by **16.17 s** | PASS | `unsigned/copy-failure-cache-cleanup.json`; `unsigned/all/pc-artifacts/ota/copy-failure-21e3f2bf4e61416dbd0169a9af18b8ac/` |
| c1. Short deterministic lock | Owned FileShare.Read handle denies delete until **5.005 s**; cache absent by **5.364 s**, zero cleanup warnings, app alive | PASS | `unsigned/cache-lock-readbacks/cache-lock-5.json` |
| c2. Exhausted retry bound | Same owned file and sharing mode, held **40.014 s**; still present at **35.047 s**, exactly one cleanup warning, app alive | PASS | `unsigned/cache-lock-readbacks/cache-lock-40.json`, 40-second screenshot in `unsigned/all/pc-artifacts/ota/installed-cache-locks-9d213970dd93480287dea1de41fb4728/` |
| c3. Next startup | Release previous lock, restart owned app; cache absent by **4.988 s**, zero cleanup warnings | PASS | `unsigned/cache-lock-readbacks/cache-lock-next-start.json` |
| d. Preserve ready version | Newer 0.11.1-beta folder keeps its native creation identity and installer bytes; old 0.0.1 absent by **7.471 s** | PASS | `unsigned/cache-newer-kept.json` |

The preserved ready installer is **110,081,259 bytes**, SHA-256 `043A64367947BE4AC92602BFA6F815405D2D5D7087E5498FA736A73DBD7F6B3D`. The lock's .NET timer is armed immediately after Start-OwnedProcess, against native birth, independently of UI Automation waits. These checks vary lock duration/version eligibility and observe filesystem identity, bytes, fresh process log segments, warning count and app liveness. They do not model arbitrary filesystem/security failures; the outer exception guard was also checked in the final diff.

### Gate table

| Gate | Observed | Result | Evidence |
| --- | --- | --- | --- |
| Fresh report-bearing A/B staging | A report and both B reports are manifest-listed; source snapshots match exact gate heads | PASS | `staging-receipt.json`, `a-staging-frame.json`, `b-staging-frame.json` |
| Parse and native compile | PS 5.1 parses 80 A / 81 B files with zero errors; ownership native helper and HarnessTrace compile | PASS | `a-parse.json`, `b-parse.json`, `signed/powershell-parse.json` |
| Linux compile/lint | Changed Python compiles; final path lint passes | PASS | `linux-verification.log` |
| Release-bound exact cases | Deep XAML build refuses before output; 327-character staging file refuses; 342-character obj-only file passes and is retained | PASS 3/3 | `release-bound-receipt.json`, `release-bound.log` |
| Accepted A harness/trace/P2/P3 | Unchanged product and unchanged shipped scenario paths; accepted 116/116, trace 5/5 and published P2/P3 stand | ACCEPTED, not rerun | `artifacts/roo-62/slice20/harness-final/receipt.json`, `artifacts/roo-62/slice20/trace-final/receipt.json`, `artifacts/roo-62/slice20/published-final/p2/receipt.json`, `artifacts/roo-62/slice20/published-final/p3/receipt.json` |
| A changed copy-layout paths | Both real B pairs use the shared A/B builder; exact A preguard body passes 239-character layout and refuses deeper layout | PASS, affected checks only | `a-signing-guard-check.json`, unsigned/signed `build-times.json` |
| Unsigned pair | A 126.28 s, B 124.18 s; every source/post-publish/final-output checkpoint passes, outputs max 176 characters | PASS | `unsigned/all/build-times.json`, `unsigned/build-bound-evidence.json` |
| All scenarios plus new cache assertions | 21/21, including early-abort and copy-failure traced relaunches; a–d above pass | PASS | `unsigned/all/scenario-results.json`, `unsigned/unsigned-gate-results.json` |
| Contracts | 25/25 expected kind and verified key match | PASS | `unsigned/contracts/contracts/results.json` |
| Close during check | Clean exit; exact `Feed <test-feed-host>: canceled: the app is closing; installed 0.11.0-beta.` line; unchanged Checking status | PASS | `unsigned/close-during-check/pc-artifacts/` |
| Signed pair | A 133.37 s, B 130.65 s, test certificate only; all bound checkpoints pass, outputs max 183 characters | PASS | `signed/build-times.json`, `signed/build-bound-evidence.json`, `signed/signed-build.json` |
| Signed A and B files / governor | All nine required app/helper PEs, unins000.exe and both setups carry fresh subject/thumbprint; governor runs from signed installed Host | PASS, 12 signature rows each | `signed/verify-A.json`, `signed/verify-B.json` |
| Signed OTA | Ready, Install, relaunch on 0.11.1-beta and updated banner; preservation and installed-cache absence pass | PASS | `signed/gate-results.json`, `signed/ota-install/pc-artifacts/` |
| Wrong-subject negative | Fails before ISCC with Signer subject differs; zero installers; all three prior bound checkpoints pass, outputs max 238 characters | PASS | `signed/negative.json`, `signed/build-bound-evidence.json` |
| Certificate cleanup | Fresh thumbprint **E25C8D50993F72AF92D076051568EC5A4CA5F494** removed by ledger, private key not exported, no root trust change | PASS | `signed/certificate-cleanup.json` |
| Lease, ledgers and as-found audit | Six terminal frames removed/ledgers closed, zero cleanup errors; all audit fields pass | PASS | `terminal-ledger-audit.json`, `cleanup-audit.json`, `owned-process-audit.json` |

Each gate's actual commands, frame IDs and nonces are retained in `command.json`, `*-command.json`, frame receipts and desktop invocation records. The mechanical orchestration commands were:

```text
python3 -I artifacts/roo-63-64/slice21/prepare.py
python3 -I artifacts/roo-63-64/slice21/b-gate.py
python3 -I artifacts/roo-63-64/slice21/signed.py
python3 -I artifacts/roo-63-64/slice21/cleanup-capture.py
python3 -I artifacts/roo-63-64/slice21/cleanup-read-new.py
python3 -I artifacts/roo-63-64/slice21/a-guard-check.py
python3 -I artifacts/roo-63-64/slice21/cleanup-restore.py
python3 -I artifacts/roo-63-64/slice21/final-audit.py
python3 -I artifacts/roo-63-64/slice21/owned-audit.py
```

The unsigned fresh frame is `d92f5bd46d024e2598a3543f58ebf23e`, manifest `9be0753090063468ad807fdd1b717fa33833dbcefcff3665747b91619bd338fe`. The successful signed frame is `a046d569cc68455892c0836a7e2a19db`; its exact manifest is in `signed/receipt.json`. Build logs were copied from ledger-recorded output files and checked against their SHA-256 identities. All published scenarios remain from the accepted A gate; no P2/P3 rerun was needed.

### Log assertions and controls

Every feed-log receipt records the complete expected string, observed fresh segment and exact status expectation. The following expected strings use the receipt's host, with no path/query:

| Control | Expected line | Observation/evidence |
| --- | --- | --- |
| Correct same-version signed feed | `Feed <host>: Current, key e4af8027d58d3b3f, release 0.11.0-beta. You have the latest version; installed 0.11.0-beta.` | Asserted in same-version and cache-cleanup receipts |
| Correct newer release, automatic off then Download | `Feed <host>: Available, key e4af8027d58d3b3f, release 0.11.1-beta. Version 0.11.1-beta is available; installed 0.11.0-beta.` | Asserted in manual-download receipt |
| Startup of newer ready cache | `Cached feed <host>: Available, key e4af8027d58d3b3f, release 0.11.1-beta. Version 0.11.1-beta is available; installed 0.11.0-beta.` | Ready, install and recovery receipts |
| Valid signature, wrong product | `Feed <host>: Refused, key e4af8027d58d3b3f. This release is for another product; installed 0.11.0-beta.` | Wrong-product receipt; exact Settings text unchanged |
| Valid signature, wrong channel | `Feed <host>: Refused, key e4af8027d58d3b3f. This release is for another update channel; installed 0.11.0-beta.` | Wrong-channel receipt; exact Settings text unchanged |
| Invalid signature | `Feed <host>: Refused. The update signature is invalid. Couldn't verify this release; installed 0.11.0-beta.` | Bad-signature receipt, no verified key |
| HTTP failure | `Feed <host>: HTTP 502; installed 0.11.0-beta.` | Feed-down receipt |
| Owned app closed while checking | `Feed <host>: canceled: the app is closing; installed 0.11.0-beta.` | Close-during-check receipt, exit 0 |

All rows assert `feedPathAbsent=true` and the applicable byte-identical status. Their controls vary only the feed/response or close action; actual installed files, cache, process starts and preservation are also checked by the scenario. They do not re-gate unrelated priority, services, memory or Blackwell behavior.

### Cleanup, deviations and review

The final installed app is the **fresh signed test-feed 0.11.1-beta B**. Final app/Host/SessionHost/uninstaller signatures match the fresh certificate thumbprint, which is now absent from certificate stores. Governor is paused, app/helpers are stopped, and all **456 recorded native process identities** are absent or a preserved reused PID. No owned Linux server/runner remains. The unrelated pre-existing `/opt/roo-support` server, PID 1530 on port 8080, was preserved.

Nine new product-output files were removed only after binding them to the two nonce-bound saved-rule responses and the owned launcher/stopped session response, then checking native creation/hash before ledger cleanup. Five changed originals were restored from SHA-256-verified archives. Final **449 data files** and both data-root presence flags match as found. Raw registry comparison uses native RegQueryValueEx bytes, including the **17,833,984-byte State** value and four-byte EnableTransparency value; equality passes without rewriting the registry. Six CS2 tasks are Ready/Enabled with unchanged XML. The 160 legacy frame paths/births are unchanged. Lease, owned frames, new Roo tasks, firewall rules, hosts edits, test certs and version-cache folders are absent. Tailscale serve JSON equals as found; no 8460 entry remains. Evidence: `cleanup/data-restore.json`, `cleanup-audit.json`, `raw-registry-as-found.json`, `raw-registry-final.json`, `final-inventory.json`, `terminal-ledger-audit.json`, `update-cache-audit.json`, `linux-process-audit.txt`.

**Completed production installer downloads this slice: 0.** All new builds/scenarios use the tailnet test feed. No production build replacement, push, publish, Blackwell or KVM action occurred; the signing key stayed on Linux and LongPathsEnabled was not changed.

Two harness/operator deviations are retained. First, a relative edit initially targeted main's UpdateService; its bytes were verified as HEAD plus only that owned edit and restored exactly before any build or commit. Main is clean, and every gate used the B worktree. Evidence: `wrong-cwd-owned-diff.patch`, `wrong-cwd-restoration.json`. Second, the signing orchestration initially supplied the frame itself as OutRoot; interactive_frame correctly refused before certificate/build creation. Its frame/ledger was closed, the runner was corrected to an owned child `s`, and only the signed subset was rerun fresh at the same code head. Evidence: `signed-scope-refusal/`, `signing-runner-correction.json`. This was an invocation-scope refusal, not a path-normalization failure. Two read-only cleanup-progress probes encountered the expected exclusive ledger lock; no ledger change or gate retry resulted, and terminal cleanup passed.

Final diff review: the retry is called even with no pending record or no feed, respects newer versions and the 30-attempt/cancellation limit, catches unexpected errors, and leaves existing status/banner/KeepVersion behavior intact. The release output scope matches the tools that consume those paths, while XAML retains its pre-build bound. The accepted cache race and obj overreach have exact-scenario passing checks. **No blocking finding remains for this slice or either branch.** This verdict relies on the accepted unchanged A gates and the final B evidence above; no unrun suite is claimed.

## Earlier rounds (historical evidence)

## Slice 20: corrected oracle passed; gate stopped on product cleanup

**Verdict: NOT READY for the combined merge.** The corrected long-path oracle passed for the harness and release helpers. Published P2/P3 passed after a harness ownership correction. B's all-scenarios driver recorded 21/21, but its independent copy-failure readback exposes a product cleanup failure, so that count is insufficient to approve the change. Contracts were interrupted; close-during-check and the signed subset were not run. No product fix was made.

### Product blocker

`docs/internal/frontend/RooIndustries.OptimizationSuite.App/Services/UpdateService.cs:159,165,170,183`: after interactive recovery from a forced silent mid-copy failure, the app reports the successful update and consumes `pending-install.json`, but deleting the cached installer fails. The readback still contains **110,083,366 bytes**, SHA-256 `E571731CEAB7FE6415F301C3D41DC5CEF7825C598B561AE45DCD8619D763F46B`, in the installed version's cache. The fresh log says `Couldn't clean up the installed update: Access to the path 'RooIndustries-OptimizationSuite-0.11.1-beta-setup.exe' is denied.` The existing recovery path does not retry cleanup for a current-version folder after the pending record is consumed.

Severity **Low**, confidence **high**, rare failure-recovery path. This cleanup code already exists in `20618f6`; it was observed on B, not reproduced against the published binary's failure path. The retained installer and consumed pending record are confirmed. An Inno process retaining the source executable is the leading **unconfirmed hypothesis**; the denying handle was not captured. A handle trace at recovery startup would distinguish that from an ACL or attribute problem. Normal silent install cleaned its cache successfully in the same gate.

Evidence: `artifacts/roo-63-64/slice20/product-cache-cleanup-failure.json`, and the nonce-bound `result-...0012.json`, `feed-log-...0010.json`, `relaunch-ownership-...0007.json` in `artifacts/roo-63-64/slice20/attempt2/all/pc-artifacts/ota/copy-failure-ee37e4de484f4b11aabc23f1fecd47fd/`. The product stop rule was applied; there is no change to UpdateService in this slice.

### Changes and exact-scenario checks

| Change | Location | Result/evidence |
| --- | --- | --- |
| Create the long target and canonical file-ID oracle with literal extended strings and direct CreateDirectoryW/CreateFileW; compare helper-result IDs; ADS roundtrip and unchanged base ID | `tools/validation/Update/Invoke-HarnessChecks.ps1:80` | 31 passing rows on B: 30 executed assertions plus the explicit long-relative not-applicable observation; `paths/receipt.json` |
| Keep an already accepted trace proof after its owned setup root exits/retires; recheck the child native birth/image, invocation/trace nonce, unique event, and requested ancestor | `Harness.Common.ps1:251`, `Invoke-TraceOwnershipChecks.ps1:49` | Retired-root fixture passes, foreign/reused/ambiguous candidates still refuse; `trace-final/receipt.json` |
| Shorten the temporary B copy to `c` and align the signing preguard with that path; B preserves its shared Assert-ReleasePathBound calculation | `Build-UpdatePair.ps1:13`, `Invoke-SigningScenario.ps1:39` | Successful unsigned pair has maximum output paths 256/253; `artifacts/roo-63-64/slice20/attempt2/build-bound-evidence.json`. Signing itself remains unrun after the product stop |
| Rebind the lint allowlist after fixture lines move | `tools/validation/path-lint-allowlist.json` | Final A/B lint pass; `lint-code-final-a.log`, `lint-code-final-b.log` |

The first P3 attempt installed the correct bytes, but a later harness ownership check discarded a proof already accepted by the same invocation after setup exited. That is fixed at the shared proof lookup, with the retired-root fixture, then fresh published P2/P3. The first B pair attempt was correctly refused by the release bound because the copy root made a generated path 263 characters. The short copy root fixes the harness layout; no path normalizer or product bound was weakened. Evidence from both failed attempts is retained.

### Path-form fixture matrix

All evidence below is `artifacts/roo-62/slice20/paths/receipt.json`. Long targets exceed 300 characters, and the canonical expected path is constructed independently of either helper. `LongPathsEnabled=0` was preserved.

| Form | Short harness | Long harness | Long Release.Checks |
| --- | --- | --- | --- |
| doubled separators | PASS, same raw/plain/canonical ID | PASS, same literal canonical ID | PASS, same canonical ID |
| dot segment | PASS | PASS | PASS |
| parent segment | PASS | PASS | PASS |
| trailing dot | PASS | PASS | PASS |
| trailing space | PASS | PASS | PASS |
| forward slashes | PASS | PASS | PASS |
| relative / drive-relative | PASS, both forms | Not applicable: tool boundary cannot set a 260+ current directory | Same reason |
| Zone.Identifier ADS | PASS, bytes, ID and Get-Item -Stream readback | PASS, literal stream bytes/ID and unchanged base ID | PASS, stream bytes and canonical base ID |
| invalid stream | PASS, refused without altering bytes | PASS, refused | Harness validation is the shared fixture |
| stream passed to tool | PASS, refused | PASS, refused | PASS, refused |
| canonical long path passed to tool | Not applicable to short length | PASS, 260-character tool refusal | PASS, same refusal |

Control varies only the spelling/stream suffix; expected canonical identity and bytes stay fixed. Effects observed: native open/file ID, ADS bytes and provider readback, refusals, preserved bytes. Product update behavior and long relative current directories are outside this fixture.

### Gate results and source binding

| Gate | Observed | Result | Evidence |
| --- | --- | --- | --- |
| Fresh report-bearing A/B staging | Exact staged manifests pass source snapshot; 80 A and 81 B PowerShell files parse, native helpers and HarnessTrace compile | PASS at the recorded heads | `final-staging/staging-receipt.json`, `final-staging/a-parse.json`, `b-parse.json` |
| Corrected path oracle | All short and applicable long forms, both helpers | PASS | `paths/receipt.json` |
| Linux compile/lint | Both code-final trees | PASS | `lint-code-final-a.log`, `lint-code-final-b.log`; py_compile commands below |
| run_harness_checks | 116/116 rows, zero skips; one explicit not-applicable observation | PASS | `harness-final/receipt.json` |
| Trace ownership | Required i–iii, ambiguity, retained-root proof: 5/5 | PASS | `trace-final/receipt.json` |
| A P2 | Real baseline 6c6515cd…; published payload 1,379/1,379; preservation, governor and discriminating High/0x3/memory 2 rule readback | PASS; known richer-log field unverified | `published-final/p2/receipt.json`, `run.json` |
| A P3 | Live production download 110,073,731 bytes / 7fd804b4…; alpha→beta, preserved data and governor, fresh latest-version check | PASS; transient Available text and richer shipped log unverified | `published-final/p3/receipt.json`, `run.json` |
| B all scenarios | Driver 21/21, install/failure/copy-failure trace proofs; independent successful-recovery cache readback fails | FAIL overall despite passing driver count | `artifacts/roo-63-64/slice20/attempt2/all/scenario-results.json`, product blocker above |
| B contracts | Seven completed cases before the deliberate product stop | INCOMPLETE, no 25/25 claim | `artifacts/roo-63-64/slice20/attempt2/contracts/runner.log` |
| B close-during-check | Not started after product stop | UNRUN | `artifacts/roo-63-64/slice20/attempt2/unsigned-gate-results.json` |
| B signed pair/OTA/governor/negative | No new test certificate or signing run | UNRUN | Product stop decision |
| B release bounds | Source, post-publish and final payload checkpoints pass for both unsigned builds | PASS for these builds; signed/negative unrun | `artifacts/roo-63-64/slice20/attempt2/build-bound-evidence.json` |
| Lease/resources/raw as-found data | 20 terminal ledgers closed, 459 native process identities absent/reused-preserved, original files/registry equal | PASS | `cleanup-audit.json`, `terminal-ledger-audit.json`, `owned-process-audit.json`, `update-cache-audit.json` |

Staging/parse and the final harness/P2/P3/trace reruns used A `68d157fed470ec2c9dfa1770aaad04a001916cad` / B `7def76e18ecdf2972b93642a72184fd17600dd26`, as recorded in `gate-code-heads.json`. B all/contracts used **`27d427518872fef233b6cf1011c8cd4ea3878eb6`**, fresh frame `4d7bf1ae3b954d97b9f0bb8becbd18bd`, manifest `c1067aa8c5c23b97202ac0506c4bb3997010153f86fbd7503b6b68a7695c1027`. Code-final heads before report commits are A **873f5ffe62c954f5996e7576c055ec20280e81af** and B **24371b6d27a56645e235a5c3a212245d7a59323e**. The later changes only shorten the pair copy and align the signing preguard; the signed path is explicitly unverified. No complete gate at the final heads is claimed. Report-only final commits are identified in the handoff and `artifacts/roo-62/slice20/final-branches.json`.

A's product diff against `20618f6` under backend/docs/tools/release/tools/scripts remains empty, SHA-256 `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`; `product-source-binding-final.json`.

### Commands and controls

Exact host, frame, nonce and argument records accompany each receipt (`desktop.command.json`, `command.json`, `*-command.json`). The scripts below are the mechanical drivers retained with this gate:

```bash
python3 -I tools/validation/Update/run_harness_checks.py --lint-only
python3 -I -m py_compile tools/validation/windows_ssh.py tools/validation/Update/run_harness_checks.py tools/validation/Update/run_e2e.py tools/validation/Update/run_shipped.py
python3 -I artifacts/roo-62/slice20/prepare-final.py
python3 -I artifacts/roo-62/slice20/paths.py
python3 -I tools/validation/Update/run_harness_checks.py --host "$ROO_TEST_SSH_HOST" --expected-machine "$ROO_TEST_COMPUTER" --source-commit 20618f6 --published-installer "$PUBLISHED_INSTALLER" --out-dir "$HARNESS_OUT"
python3 -I artifacts/roo-62/slice20/trace-final.py
python3 -I artifacts/roo-62/slice20/published-final.py
python3 -I artifacts/roo-63-64/slice20/b-gate2.py
python3 -I artifacts/roo-62/slice20/cleanup-capture.py
python3 -I artifacts/roo-62/slice20/cleanup-read-new.py
python3 -I artifacts/roo-62/slice20/cleanup-restore.py
python3 -I artifacts/roo-62/slice20/final-audit.py
python3 -I artifacts/roo-62/slice20/owned-audit.py
```

P2 varies the installed baseline and then launches the exact published installer through the owned shell launcher with MOTW. It observes payload hashes, saved files/settings, governor identity and independent rule controls; richer feed logging is unavailable in the shipped binary. P3 varies only the source Version to alpha, uses the default production feed, and observes newly created exact installer bytes, setup/relaunch, preservation and current status; it cannot capture the brief Available text before auto-download. B varies one feed/install failure input per scenario and observes fresh status/logs, cache/files, process ownership and preservation; it does not capture the denying file handle. Ownership fixtures vary parent provenance, PID birth, ambiguity and root retirement; they observe native birth/image, event proof and refusal, not arbitrary process lifetime.

### Cleanup, production requests and remaining work

The PC is restored to the prior **0.11.1-beta test-feed build** using the frozen slice-14 signed installer, with governor paused. All **449 original files** and both data-root existence states match as found. The raw registry comparison covers exact value kind and bytes, including the **17,833,984-byte State value**; no reserialized state is used. Both P2 retained fixture ledgers were reconciled. Removal of 26 new data files is bound to original creation ledgers, saved-rule responses, native fixture identities or the owned stopped game-session response. Four modified original files were restored from the captured archives. The first cleanup driver failed before mutation on a null metadata field; it was corrected. The process audit was chunked after the inline 64 KiB transport cap refused a too-large read-only request.

There are zero owned Roo/frame processes, tasks, firewall rules, hosts edits, test certificates, leases, update-cache directories or frames. All 160 unledgered legacy frames retain their native creation identities. All six CS2 tasks are Ready/Enabled with byte-identical XML. Tailscale serve equals its as-found JSON with no 8460 route. The unrelated support HTTP service was preserved. Blackwell, KVM, LongPathsEnabled, Defender and trust roots were untouched. Nothing owned is left running.

**Completed production installer downloads: 4**, comprising two harness Invoke-WebRequest downloads and two independently verified app OTA downloads (one pair in the initial attempt, one pair in the successful rerun). Production had GETs only; no publish/upload/push or Blob token. The signing key stayed on Linux. See `production-download-count.json`.

Open: lead decision/product fix for cleanup after successful interactive recovery, then the affected gate and the outstanding contracts, close-during-check and signed subset. The accepted native normalizer and corrected oracle have no open path-handling finding. The shared trace-proof retention and short copy layout fixes passed their applicable reruns. Approval of the combined merge is withheld.

## Slice 19: OS normalization implemented; final gate stopped

**Verdict: NOT READY to merge.** The specified OS normalizer is implemented. The long-path file-ID acceptance proof cannot run as written on the as-found test PC. No fallback normalizer, registry opt-in or product fix was added. P2/P3 and B's all/contracts/close/signed gate were not started.

The failing check is `Windows normalization long doubled separators`, invocation `c9c46113fb784121b5c0070f06f6a04e`, frame `55276c5be43241349f937fc1896044a4`. Its 381-character plain input normalized successfully, but the direct plain `CreateFileW` oracle could not open it (`paths/path-failure.json`). A separate 416-character owned diagnostic captured **Win32 3**, “The system cannot find the path specified”, for both the doubled and canonical plain paths; `GetFullPathNameW` succeeded, the extended open returned error 0, and the release and harness normalizers agreed. **This is not a demonstrated GetFullPathNameW failure or product failure.** `LongPathsEnabled` was read as 0 and was left unchanged.

Microsoft documents that an unprefixed long `CreateFileW` needs both the registry opt-in and a longPathAware manifest; [maximum path length documentation](https://learn.microsoft.com/en-us/windows/win32/fileio/maximum-file-path-limitation). [GetFullPathNameW](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-getfullpathnamew) calculates a name without proving that a file can be opened. The observed failed open is consistent with the disabled opt-in. The long-path plain-open oracle needs a lead-approved adjustment; the implementation was not replaced by a hand-written or fallback normalizer.

### Code and self-review

| Item | Change | Location | Check/evidence |
| --- | --- | --- | --- |
| Native normalization | Added the requested 32768-character GetFullPathNameW P/Invoke; native file helpers now use it too | `tools/validation/LoadTimes/CleanupOwnership.Common.ps1:17` | Shared type compiled during every upload; short file-ID checks passed; long normalization succeeded |
| Harness normalizer | Split and validate ADS suffix, normalize only the file part, preserve extended inputs and append the stream | `tools/validation/Update/Harness.Common.ps1:18` | 11 short checks passed; long proof stopped on plain open |
| Tool boundary | Reject stream paths before the length/tool check, including the native argument helper | `Harness.Common.ps1:36`, `CleanupOwnership.Common.ps1:27` | Short ADS tool refusal; B release stream refusal in the separate diagnostic |
| Fixtures | Replaced the slice-17 hand-normalization assumptions with a direct CreateFileW/file-ID oracle; added PathsOnly | `tools/validation/Update/Invoke-HarnessChecks.ps1:80` | `artifacts/roo-62/slice19/paths/receipt.json` |
| Bootstrap | Load the same current native helper before pre-frame paths | `tools/validation/windows_ssh.py:111` | Fresh A/B uploads, source verification, parse/compile |
| v1 compatibility | Caller helper is loaded before an older staged helper. Protected CreateNew UTF-8 BOM wrapper/child files avoid nested encoded-command size limits while retaining the v1 context/output contract | `tools/validation/windows_ssh.py:451` | Old `20618f6` helper desktop fixture passed; task arguments 210 characters; frame path remains visible to cleanup guards; `artifacts/roo-62/slice19/v1-compatibility3/receipt.json` |
| Lint | Require an explicit reason for any .NET GetFullPath use in scanned PowerShell; kept provider-only allowlist entries | `tools/validation/Update/run_harness_checks.py:13` | Final A/B lint pass; scratch old-normalizer restoration fails |
| B-only release helper | Minimal guarded native type, same ADS split/OS normalization and stream tool refusal; A product tree untouched | `tools/scripts/Release.Checks.ps1:1` on B | Release type compiled and agreed with harness on the 416-character diagnostic |

Self-review found and corrected the v1 staged-helper dependency before handoff. An intermediate compressed transport still exceeded the task command bound in a dry invocation; the final code uses protected script files, the same boundary used by v2. Failed attempts are retained, not used as passing evidence. Two diagnostic attempts failed because the mechanical driver called Complete-HarnessInvocation without an invocation row; diagnostic3 instead reports native observations and lets Clear-UpdateFrame close the ledger. No path algorithm was changed in response to the long-path refusal.

### Path fixtures

| Path form | Short | 300+ characters | Evidence |
| --- | --- | --- | --- |
| doubled separators | PASS: matching plain, extended and original file IDs | FAIL: normalization succeeded; plain CreateFileW failed before file-ID comparison | `artifacts/roo-62/slice19/paths/receipt.json` |
| dot segment | PASS: matching plain, extended and original file IDs | UNRUN after the first long-path refusal | `artifacts/roo-62/slice19/paths/receipt.json` |
| parent segment | PASS: matching plain, extended and original file IDs | UNRUN after the first long-path refusal | `artifacts/roo-62/slice19/paths/receipt.json` |
| trailing dot | PASS: matching plain, extended and original file IDs | UNRUN after the first long-path refusal | `artifacts/roo-62/slice19/paths/receipt.json` |
| trailing space | PASS: matching plain, extended and original file IDs | UNRUN after the first long-path refusal | `artifacts/roo-62/slice19/paths/receipt.json` |
| forward slashes | PASS: matching plain, extended and original file IDs | UNRUN after the first long-path refusal | `artifacts/roo-62/slice19/paths/receipt.json` |
| relative path | PASS: matching plain, extended and original file IDs | UNRUN after the first long-path refusal | `artifacts/roo-62/slice19/paths/receipt.json` |
| drive-relative path | PASS: matching plain, extended and original file IDs | UNRUN after the first long-path refusal | `artifacts/roo-62/slice19/paths/receipt.json` |
| Zone.Identifier ADS and explicit DATA | PASS: write/read, explicit $DATA and separate Get-Item -Stream readback | UNRUN after the first long-path refusal | `artifacts/roo-62/slice19/paths/receipt.json` |
| invalid stream refused | PASS: refused, ADS bytes unchanged | UNRUN after the first long-path refusal | `artifacts/roo-62/slice19/paths/receipt.json` |
| stream tool refused | PASS: refused before a tool call | UNRUN after the first long-path refusal | `artifacts/roo-62/slice19/paths/receipt.json` |


Control: only the path spelling or stream suffix varies; the file bytes and expected file identity stay fixed. Effects: raw Windows open, helper-result open and original file IDs, ADS bytes/provider readback, refusal and retained bytes. These checks do not observe product OTA or UI behavior. Long checks after the first failure are explicitly unverified.

### Gate and evidence

Initial attempted gate heads: A `82ddec79b9911b0b9ebc4dd859f3b60fb148c7a4`, B `61f1b55a6c9b6f5e116c5d8fa0e1e2fba353ce08`. Final code heads after the compatibility correction: A `610bd4bcae3066406b75cb31350adc82c638265a`, B `12e68848d0276d3c1822b2125baf4b219a7ccefa`. Report-only commits follow these heads; their final SHAs are recorded in `final-branches.json` and the handoff. No complete final gate is claimed at either pair.

| Check | Observed | Result | Evidence |
| --- | --- | --- | --- |
| A product binding | Diff against 20618f6 under backend/docs/tools/release/tools/scripts empty; SHA e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 | PASS | `artifacts/roo-62/slice19/product-source-binding.json` |
| Fresh report-bearing A/B source staging | Both final code heads verified; reports included in the manifest | PASS | `artifacts/roo-62/slice19/final-staging/staging-receipt.json` |
| PS 5.1 parse and HarnessTrace compile | 80 A files, 81 B files; zero parse errors; shared native + trace compile | PASS | `artifacts/roo-62/slice19/final-staging/a-parse.json`, `b-parse.json` |
| B release native type | Compiled; extended open succeeds; same normalized result as harness | PASS diagnostic | `artifacts/roo-62/slice19/native-diagnostic3/native-error.json` |
| Python compile and lint | Both final trees pass | PASS | `artifacts/roo-62/slice19/lint-final-a.log`, `lint-final-b.log` |
| Old-normalizer scratch revert | Rejected for GetFullPath without allowlist | PASS negative | `artifacts/roo-62/slice19/lint-old-normalizer-fail.log` |
| Normalization path fixture | 11 short checks pass; first long plain-open proof fails | FAIL | `artifacts/roo-62/slice19/paths/receipt.json`, `paths/path-failure.json` |
| Full run_harness_checks / trace 3 | Not run after path-class stop | UNRUN | `artifacts/roo-62/slice19/gate-summary.json` |
| A P2 / P3 | No install, live feed or installer request | UNRUN | `artifacts/roo-62/slice19/gate-summary.json` |
| B all 21 / contracts 25 / close-during-check | Not started | UNRUN | `artifacts/roo-62/slice19/gate-summary.json` |
| B signed subset / release bounds per build | No build or test certificate created | UNRUN | `artifacts/roo-62/slice19/gate-summary.json` |
| Lease and cleanup | All 11 saved frame ledgers closed; no active/error entries; native process audit and WMI inventory clear | PASS | `artifacts/roo-62/slice19/ledger-inventory.json`, `cleanup-audit.json`, `owned-process-audit.json` |
| Raw registry/data equality | Exact captured type/base64 bytes and every data-file hash equal | PASS | `artifacts/roo-62/slice19/raw-registry-as-found.json`, `raw-registry-final.json`, `cleanup-audit.json` |

### Commands

```bash
python3 -I -m py_compile tools/validation/windows_ssh.py tools/validation/Update/run_harness_checks.py
python3 -I tools/validation/Update/run_harness_checks.py --lint-only
# Mechanical evidence drivers use fresh frames and explicit optimizer-9070 / SERVI-WINDOWS-D.
python3 -I artifacts/roo-62/slice19/prepare.py
python3 -I artifacts/roo-62/slice19/paths.py
python3 -I artifacts/roo-62/slice19/native-diagnostic3.py
python3 -I artifacts/roo-62/slice19/v1-compatibility3.py
python3 -I artifacts/roo-62/slice19/prepare-final.py
python3 -I artifacts/roo-62/slice19/final-audit.py
python3 -I artifacts/roo-62/slice19/owned-audit.py
```

`paths.py` calls `windows_ssh.interactive_frame` on `Invoke-HarnessChecks.ps1 -Source <fresh-source> -OutRoot <owned-frame>\p -PathsOnly`, then collects its nonce-bound receipt and clears the frame through its ledger. The native diagnostic is a distinct owned, non-product fixture. `v1-compatibility3.py` stages a synthetic contract fixture containing the original `20618f6` ownership helper, then calls the public v1 `interactive()`; it does not claim to be an exact-head product gate. The fixture records its freshly created v1 execution directory immediately after creation, and the existing v1 wrapper removes its task/processes by their receipts.


### Cleanup and remaining decision

All 160 legacy frames retain their as-found paths and native creation identities. The six CS2 tasks are Ready/Enabled with identical exported XML. Both data roots keep their as-found files; no seeded tester data or settings were changed. No Roo/frame process, harness task, firewall rule, hosts edit, test certificate, lease or update-version cache remains. The original install log is retained. Tailscale serve JSON is unchanged; no 8460 entry was created. The pre-existing Linux `/opt/roo-support` HTTP service is preserved.

The 9070 remains on its **as-found signed test-feed 0.11.1-beta**, app stopped and saved-rules governor paused. Blackwell/KVM were not contacted. **Completed production installer downloads: 0; live Vercel feed GETs: 0.** The signing key was neither read nor copied. Nothing owned is left running.

Remaining blocker: agree a long-file oracle that can work under the PC's disabled unprefixed long-path policy, then prove every long form and run the still-unrun final gate. All other late-round accepted results remain historical evidence, not substitutes for this gate.


**Not ready to merge: one cleanup blocker remains.** All executable Windows gates passed; final owned-frame cleanup did not. The kernel trace now proves the early-abort relaunch instead of requiring a short-lived setup parent to remain alive. CR7 distinguishes a remote command deadline from an unreachable host. No product file changed in this slice.

A code HEAD `c5c24f9a9ec8bd3ec6c05e4d45ed398afd196eff`; B code HEAD `0f4a48188ab47dc2141a5f5f846f3007c3835885`. The final report-only commits and clean-tree readback are recorded in `slice14/final-branches.json` after these reports are committed. A's published-product/build projection against `20618f6` is zero bytes, SHA-256 `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`. Published gates used A `70e094c`; the later changes affect optional-preflight deadline handling and the signing fixture only. The affected shipped deadline path was separately exercised after `dedd7ec`. Unsigned B gate used `bc5cb6c`; later merges change no product/trace/UpdateScenario inputs. The fresh signed gate used B `0f4a481`. Reports change no staged test inputs.

PID15504: **absent after power loss**, as settled by the lead. No stop, replacement PID search, KVM action or Blackwell contact. The old run15 Linux monitor was absent; no unrelated process was stopped.

## Gate results

| Check | Observed | pass/fail | Evidence |
|---|---|---|---|
| CR7 live command | Start-Sleep 20 with deadline 5: RemoteTimeout at 5.005 s; immediate follow-up succeeds | pass | slice14/cr7-live/receipt.json |
| CR7 dead host | 192.0.2.1 SSH 15.050 s, SCP 15.011 s; HostUnreachable | pass | slice14/cr7-live/receipt.json |
| CR7 shipped caller | Journey.remote preserves RemoteTimeout at 5.005 s; follow-up succeeds; optional-host catch is HostUnreachable only | pass | slice14/cr7-shipped-caller/receipt.json |
| Python | 11 changed Python files compile; B merged runner compiles | pass | slice14/linux-verification.json |
| PowerShell/native trace | Windows PowerShell 5.1.26100.9444; 116 validation.ps1 files; 0 parse errors; HarnessTrace.cs Add-Type compiled | pass | slice14/parse/receipt.json |
| Common ownership suite | 40/40, 0 skips; includes original 19 and real encoded windows_ssh runner | pass | slice14/ownership/receipt.json |
| Trace fixtures | i: 25 ms parent/800 ms ledger lock; ii foreign same-image child; iii: 5 s native/event mismatch:3/3, 0 skips | pass | slice14/trace-retry/receipt.json |
| P2 published bootstrap | 0.10 SHA 6c6515cd… -> published 0.11 SHA 7fd804b4…;21 decisive assertions pass; logging-detail observation remains unavailable in shipped code | pass with stated observation limit | slice14/published/p2/receipt.json |
| P3 live Vercel OTA | Version-only alpha -> published beta; 15 decisive assertions pass; transient Available and host/key logging remain unverified observations | pass with stated observation limits | slice14/published/p3/receipt.json |
| B all | 21/21; install/failure/copy-failure actual relaunch receipts require trace proof | pass | ../roo-63-64/slice14/all/scenario-results.json |
| B separate contracts | 25/25; expected kind and verified key | pass | ../roo-63-64/slice14/contracts/contracts/results.json |
| B close-during-check | Exact canceled: the app is closing line; clean exit 0 | pass | ../roo-63-64/slice14/close-during-check/scenario-results.json |
| B signed subset | Fresh RSA 3072 test cert; signed pair, manual A, ready, install B, verify A/B, governor, wrong subject, cert removal all pass | pass | ../roo-63-64/slice14/signed/gate-results.json |
| Final cleanup | 7 of 8 new owned frames cleared; 1 signed frame/ledger retained after 264-character traversal failure; 0 live owned process/task/firewall/hosts/cert/cache; 160 unledgered legacy frames preserved | fail: owned frame retained | slice14/final-cleanup/audit-receipt.json |

The ownership fixtures vary exactly the named authority, native birth, result nonce, source manifest, cache version, parent lifetime or ledger contention. They observe refusal/adoption and retained bytes/identity; unrelated performance/settings and other users' workflows are outside their assertions. P2 varies the installed baseline and wizard upgrade, observing payload/preservation/governor/rule behavior; P3 varies only assembly Version for its alpha, then observes a new live download and silent update. Transport checks vary only destination or deadline, not product behavior. Signing varies certificate trust/subject and observes actual PE signatures/install/relaunch. Historical P0/P4/P4b/P5 gates remain at their recorded heads; this slice does not rerun or relabel them.

## CR7 call sites and bounds

`RemoteTimeout` and `HostUnreachable` are sibling CalledProcessError types. Subprocess.TimeoutExpired yields 124/RemoteTimeout; only exit 255 plus connection diagnostics yields HostUnreachable. Deadlines fail the run, never the optional-machine offline skip. Wrappers log failures and retain their finally cleanup. The timeout message contains no encoded script or credential.

| Changed call site | Operation | Bound |
|---|---|---|
| windows_ssh.py:94 | invoke transport; ordinary query/guard | 75s default; explicit timeout parameter |
| windows_ssh.py:166,234 | Remote manifest/full file-set verification and local source comparison | 300s |
| windows_ssh.py:296,306 | Source SCP; extraction+hash verification | 300s each |
| windows_ssh.py:380 | Desktop scheduled scenario/build/install | (minutes+2)×60s; builds 42 min, installs/scenarios explicit budgets; maximum 242 min |
| windows_ssh.py:414 | CLI run | --timeout; default 75 s |
| Update/run_e2e.py:54,454 | Remote wrapper; evidence archive | 75s default /600s evidence |
| Update/run_shipped.py:73,169,257 | Remote wrapper; dual-root/task snapshot; evidence archive | 75s default /600s snapshot+archive |
| Update/run_harness_checks.py:132,144,164,174,177 | Clear test frames | 900s |
| RedirectedFolders/stage.py:18 | Staged source extraction | 300s |
| SetupMigration/run.py:49,53,58 | Source extraction; complete migration run; evidence archive | 300s /1800s /600s |
| Release/Test-FinalDriverOwnership.py:57,134,179 | Source guards; final cleanup | 300s /900s /300s |
| Release/Test-PreflightReadiness.py:32,65 | Direct script; cleanup | 300s /900s |
| Release/Test-SourceReadBoundary.py:42,279 | Cleanup; setup | 900s /300s |
| Release/Run-HistoricalBlackwell.py:23 | Long validation wrapper; source audit only, never executed | 900s |
| Final Clear driver (ignored exact orchestration) | Large 3978-entry ledger removal; remaining signed frames | 1800s after a recorded 900 s deadline; no offline skip |
| Update/check_windows_transport.py:25,31,52 | Intentional live deadline; follow-up; unreachable SSH/SCP | 5s /75s /75s with 15 s connection bound |

Every invoke/run_transport/interactive call site under tools/validation was audited:64 rows in `slice14/cr7-callsite-audit-final.json` and `slice14/cr7-callsite-table-final.md`. The wrapper's source/evidence/cleanup limits are separate from ConnectTimeout 15, ServerAliveInterval 15 and CountMax 3. Legacy/Blackwell entry points were inspected/compiled, not run. Small frame cleanup used 900 s. The 3978-entry ledger exceeded 900 s after making progress, correctly raised RemoteTimeout, and resumed its 62 remaining entries under an explicit 1800 s bound. Both attempts and actual times are retained; no failed attempt is relabeled as pass.

## Findings closed by their checks

| Finding | Fix | Decisive control/observed | pass/fail | Evidence |
|---|---|---|---|---|
| F1 | Same-invocation P5 dual-root/install/task snapshot, active-root guard and uninstaller-leftovers observation | active root already present; root created since stale P0 => refused/unchanged | pass | slice14/ownership/receipt.json |
| F2 | One native ownership ledger plus asynchronous kernel-start trace; owned separate shell launcher; live or traced parent proof | foreign app/process/TWizardForm refused; native trace 3/3 and actual failure/copy-failure relaunch pass | pass | slice14/ownership/receipt.json; slice14/trace-retry/receipt.json |
| F3 | Nonce/CreateNew result names/content and identity checks | existing file and another nonce refused; prior bytes retained | pass | slice14/ownership/receipt.json |
| F4 | SmartScreen screenshot/tree then fail; exact owned launcher security-warning Run only | SmartScreen fixture no click; actual P2 warning/wizard handled | pass | slice14/ownership/receipt.json |
| F5 | Reverse-ledger cleanup; P4 never cleans Downloads | unledgered Downloads folder retained | pass | slice14/ownership/receipt.json |
| F6 | Plain/decoded-enc/frame-runner and reparse guards | REAL windows_ssh interactive runner refuses Clear; junction target and unknown empty child retained | pass | slice14/ownership/receipt.json |
| F7 | External key requirement; upload scans forbidden extensions, PEM content and PKCS12 DER before SSH | extensionless tools/release/update-signing-private dummy PEM/DER refused before network | pass | slice14/ownership/receipt.json |
| F8 | Full remote source set equals immutable manifest | extra Directory.Build.targets and edited local harness refuse frame reuse | pass | slice14/ownership/receipt.json |
| F9 | Actual B version/absent cache preflight and ledger cache identity | foreign B cache refused; 4.2.8-beta selected; app-deleted cache retired before recreation | pass | slice14/ownership/receipt.json |
| F10 | B Refuse carries only a successfully verified key | 25 contracts; signed wrong-product/channel UI logs include e4af8027d58d3b3f | pass | ../roo-63-64/slice14/contracts/contracts/results.json; ../roo-63-64/slice14/feed-log-assertions.json |
| F11 | B Describe/host-only Cached feed/cancellation logs; slash/dash password guard | 24 exact feed-log lines; no feed path/query; close log/cleanexit; signing success and wrongsubjectnegative | pass | ../roo-63-64/slice14/contracts/contracts/results.json; ../roo-63-64/slice14/feed-log-assertions.json |
| F12 | P4b exact timeout message and 18–30 s interval | boundary rejection checks retained; actual published P4b 20.1847239 s at accepted Slice12 head | pass | slice14/ownership/receipt.json; slice12/published-final/p4/receipt.json |
| F13 | One exclusive hosts stream, same-handle rewrite and sharing retries | concurrent writer blocked during cleanup; its later SECOND-WRITER edit survives | pass | slice14/ownership/receipt.json |
| F14 | contracts cannot combine skip-contracts; required pass rows bound to frame | argparse 2; failed row/another frame cannot pass completeness | pass | slice14/ownership/receipt.json |

Original Slice11 findings 1–14 are also covered by the current 40: dual roots, firewall nonce, native ownership, Clear safety, signing-key exclusion, immutable frame reuse, product/source binding, fresh governor PID/birth, live feed/fresh log/oracle, P1 completeness, P4b, corrected restart wording, cleanup-before-status and rotation/counting. `slice14/self-audit.md` lists every entry point against all four classes. It distinguishes code inspection from E2E and keeps accepted unrun extras historical.

## Published evidence and commands

The 0.10 baseline was 110,024,946 bytes, SHA-256 `6c6515cdf93c6b5751a37957ae855962d534ca786720773571747d202b576ed4`. The live signed manifest and local published installer agree on 0.11.0-beta, 110,073,731 bytes, SHA-256 `7fd804b4082fd3e92ccb6bd0693530ab0bee8a7d9e41fba44c03ecef92707bb9`. Each release verification used a new HTTPS feed GET and trusted key e4af8027d58d3b3f. No cached manifest authorized these checks.

P2 matched all 1,379 payload files and 153 preservation files. The app and old governor stayed running before the default wizard; the old app closed automatically, the new governor's PID and birth changed. Explorer fixture independently read Normal/full 0xFFFFF/memory 5 before the rule and High/0x3/memory 2 after. Settings and the new owned app-log segment say **“You have the latest version”**, with no Downloading line or release cache. MOTW ZoneId 3 was set; SmartScreen did not appear.

P3's alpha changed only Version; all five embedded resources matched the published payload. Startup created a new installer after app launch with exactly the signed bytes. Silent setup included ROOWAITPID/ROORELAUNCH; beta reopened with **“Updated to version 0.11.0-beta”**, consumed pending-install.json, preserved all 153 files and matched 1,379 payload hashes, new governor identity and a fresh Current check. The short Available UI text was replaced by Downloading before sampling; old shipped code logs no host/key, so those observations remain unverified. They are not product failures or promoted to passing claims. B's new logging is tested separately.

Exact commands (private paths/hosts are placeholders here; actual argv and fields are retained in the named JSON):

```text
python3 -I <repo>/.claude/worktrees/roo-29-shipped/tools/validation/Update/run_harness_checks.py --host <test-pc> --expected-machine <computer-name> --source-commit 20618f6 --published-installer <repo>/artifacts/release/RooIndustries-OptimizationSuite-0.11.0-beta-setup.exe --out-dir <repo>/artifacts/roo-62/slice14/ownership
```

```text
python3 -I <repo>/.claude/worktrees/roo-29-shipped/tools/validation/Update/run_shipped.py --source-commit 20618f6 --host <test-pc> --expected-machine <computer-name> --baseline-installer <repo>/artifacts/release/RooIndustries-OptimizationSuite-0.10.0-beta-setup.exe --baseline-sha256 6c6515cdf93c6b5751a37957ae855962d534ca786720773571747d202b576ed4 --published-installer <repo>/artifacts/release/RooIndustries-OptimizationSuite-0.11.0-beta-setup.exe --innoextract <repo>/artifacts/roo-29/p0/tool/build/innoextract --out-dir <repo>/artifacts/roo-62/slice14/published --scenario p2
```

```text
python3 -I <repo>/.claude/worktrees/roo-29-shipped/tools/validation/Update/run_shipped.py --source-commit 20618f6 --host <test-pc> --expected-machine <computer-name> --baseline-installer <repo>/artifacts/release/RooIndustries-OptimizationSuite-0.10.0-beta-setup.exe --baseline-sha256 6c6515cdf93c6b5751a37957ae855962d534ca786720773571747d202b576ed4 --published-installer <repo>/artifacts/release/RooIndustries-OptimizationSuite-0.11.0-beta-setup.exe --innoextract <repo>/artifacts/roo-29/p0/tool/build/innoextract --out-dir <repo>/artifacts/roo-62/slice14/published --scenario p3
```

Trace fixture invocation output is in `slice14/trace-retry/desktop.log`; fields are Source=<fresh trace frame>\source, OutRoot=<frame>\trace-checks, ExpectedMachine=<computer-name>; remote parse body in `slice14/parse/command.ps1`. CR7 command: `python3 -I tools/validation/Update/check_windows_transport.py --host 192.0.2.1 --expected-machine <computer-name> --live-host <test-pc> --out-dir <artifact-dir>`. Driver copies under slice14 retain exact cleanup/parse/signed orchestration; repo entry points are runnable by scenario name. No unit tests added.

## Residue, preservation and deviations

| Item | Observed/decision | pass/fail | Evidence |
|---|---|---|---|
| Initial inventory | 163 frames; 3 ledgers; 0 Suite processes/firewall/testcert/blackhole; both data roots snapshotted | pass | slice14/residue/as-found.json |
| Historical interrupted frame e666… | Cleared through native identity/creation ledger; pre-boot process entries marked absent | pass | slice14/residue/roo-industries-roo20-ota-e6666be857564a3a9b9bac0a6722b560-closed-ledger.json |
| Historical bbfb… + auxiliary 423b… | Parent ledger contained auxiliary foreign-ledger-fixture folder identity, so both cleared with existing authority | pass | slice14/residue/roo-industries-roo29-shipped-bbfb95ed7c224c8ab9e27014d5496cc3-closed-ledger.json |
| This slice frames | 7/8 cleared; large ledger hit 900 s after 997->62 active entries, resumed under explicit 1800 s; final signed frame fails on 264-character path; 40-case scopes separately closed | fail: one frame retained | slice14/final-cleanup/receipt.json |
| Legacy unledgered frames | 160 preserved; no new authority invented; one owned signed frame remains | retained per constraint | slice14/residue/unledgered-frames.json; slice14/final-cleanup/final-inventory.json |
| Final processes/network/certs | No Suite/owned harness process, task, firewall, hosts marker, A/B cache or testcert. Ordinary feed-host mapping retained. No 8460 route; JSON equals as-found; all 10 recorded Linux server PIDs absent | pass | slice14/final-cleanup/audit-receipt.json; linux-audit.json |
| Unrelated process | Process Lasso ProcessGovernor PID 3772 retained, same as-found identity | preserved | slice14/final-cleanup/final-inventory.json |
| User data | Original settings bytes restored; transparency DWORD restored 1->0; original durable history/rules/undo retained; test seed data retained; runtime logs/heartbeat and owned cache/fixture cleanup changes itemized | pass with explicit runtime deltas | slice14/final-cleanup/user-data-preservation.json; restored-as-found.json; residue/as-found-user-data.zip |
| CS2 tasks | Six Ready/Enabled; XML/enabled values unchanged | pass | slice14/final-cleanup/audit-receipt.json |
| Blackwell | Off-limits; no contact/P5/audit. Earlier two unrelated task StartBoundary changes remain caller-unverified, no new causal claim | not part of gate | slice12/owned-end-audit/final-os-task-xml-differences.json |
| End install | Fresh signed test-feed 0.11.1-beta; governor paused; app stopped; test certificate removed | pass | slice14/final-cleanup/final-inventory.json; ../roo-63-64/slice14/signed/certificate-cleanup.json |

Additional harness fixes exposed by this gate: tracefixture lock acquisition now retries sharing violations for up to 5 s before the unchanged 800 ms hold; signing cleanup derives authority from its certificate creation-ledger entry even after a failed build; long XAML output paths are refused before creating a certificate. Signed retries diagnosed a 263-character intermediate DLL whose ordinary File.Exists was false and extended-path Exists true; compiler LocalAssembly was null. Short output root `<frame>\s` produced a successful fresh signed pair. A local driver also moved governor Resume before the seed snapshot so its preservation baseline matched the intended running state. These are reported harness fixes; no product or trust-root change. Failed receipts/logs remain in the B slice14 directories.

Completed production installer downloads: **2 full transfers** (one actual Windows Invoke-WebRequest in P2, one independently verified app OTA download in P3). The harness-only IWR counter is 1; P3's counter 0 intentionally excludes its app download. Linux production installer downloads 0; production uploads 0. All B transfers used the owned test feed. The final path blocker is confirmed by `slice14/final-cleanup/native-audit.json`: ordinary Directory.Exists=false and extended-path Exists=true for the 264-character directory. [Microsoft documents MAX_PATH and extended-length paths](https://learn.microsoft.com/en-us/windows/win32/fileio/maximum-file-path-limitation). No signing key left Linux, no Blob token, no publish, main change, push, amend, Defender/trust-root change or kill-by-name.

Historical restart wording remains **“shutdown.exe initiated a restart; caller unknown (see restart-investigation.md)”**. This slice accepts the lead's power-loss explanation and does not reopen that investigation.

## Delta review and commits

I reviewed the whole Slice14 diff against the requested authority and timeout invariants. Deadlines can no longer become optional-host skips; source, build, installer, evidence and cleanup paths have explicit bounds. Trace adoption requires captured ancestry/window/order plus native birth/live-handle identity; actual early-abort and copy-failure relaunches now pass through it. Cleanup used only recorded identities and retained unknown frames. Certificate cleanup works on failed-build ledgers. No product defect was observed. A new Medium merge blocker remains in generated-path handling: Clear-UpdateFrame.ps1:24 cannot traverse the signed negative-build tool cache at 264 characters. The ledger/source remain intact and nothing is running. This repeats the Windows path-length dependency found at the XAML build boundary, so implementation stopped under the lead’s same-class rule; no scenario-specific cleanup bypass was added.

A commits in this slice:
```text
c5c24f9a9ec8bd3ec6c05e4d45ed398afd196eff serviroo <serviroo@rooindustries.com> fix(validation): refuse long XAML signing build paths
c28f65581833273c372ba2d77fb819c62c71880f serviroo <serviroo@rooindustries.com> fix(validation): clean signing certificates from the ledger
dedd7ec1447e91f607a84d6bf54eafd769e5ce42 serviroo <serviroo@rooindustries.com> fix(validation): preserve preflight transport failure types
70e094cccc6dfad620a1c926ef827b132162b8ae serviroo <serviroo@rooindustries.com> fix(validation): wait for the trace fixture ledger lock
3882f7dae778ec165596529e3cbd9123ca4b8cb4 serviroo <serviroo@rooindustries.com> fix(validation): distinguish remote deadlines from offline hosts
```

A diff since 06dddb5:
```text
 tools/validation/RedirectedFolders/stage.py         |  2 +-
 tools/validation/Release/Run-HistoricalBlackwell.py |  2 +-
 .../validation/Release/Test-FinalDriverOwnership.py |  6 +++---
 tools/validation/Release/Test-PreflightReadiness.py |  4 ++--
 tools/validation/Release/Test-SourceReadBoundary.py |  4 ++--
 tools/validation/SetupMigration/run.py              |  6 +++---
 tools/validation/Update/Harness.Common.ps1          |  7 ++++++-
 tools/validation/Update/Invoke-SigningScenario.ps1  | 13 +++++++++----
 .../Update/Invoke-TraceOwnershipChecks.ps1          |  6 +++++-
 tools/validation/Update/README.md                   |  4 ++++
 tools/validation/Update/check_windows_transport.py  | 20 ++++++++++++++++++++
 tools/validation/Update/run_e2e.py                  |  6 +++---
 tools/validation/Update/run_harness_checks.py       | 10 +++++-----
 tools/validation/Update/run_shipped.py              | 12 +++++++-----
 tools/validation/windows_ssh.py                     | 21 +++++++++++++++------
 15 files changed, 86 insertions(+), 37 deletions(-)
```

**Slice-14 verdict (the filesystem blocker is resolved in slice 15 below): I did not yet agree A and B were ready to merge to main.** Required remaining work is one shared generated-path/filesystem policy, its exact long-path cleanup check, and closure of signed frame `31805230c2994beebc7ab152f304f221`. The already passing product gates need no repetition unless that fix touches their inputs. The final code is committed; the reports are committed separately; neither branch was pushed or merged into main. Final report-only SHAs/clean readback: `slice14/final-branches.json`.


## Slice 15: CR8 closure

One shared extended-path walker/hash/archive path now handles the listed harness tree operations. Linux lint passes and rejects a reverted scratch walk before Windows work. PowerShell 5.1 parsed all 14 scripts with zero errors, HarnessTrace compiled, ownership checks passed 43/43 and trace fixtures passed 3/3 on retry. The first trace refusal is retained and explained without a causal claim in the detailed report.

Frame `31805230c2994beebc7ab152f304f221` is closed: 1,039 entries, 137.017 seconds, frame/ledger/264-character path absent. The three new fixtures distinguish recorded versus unrecorded long descendants and ZIP inclusion, with 331-character file paths. Final audit: zero owned processes or ledgered frames; same 160 legacy frames; 449 unchanged data files and exactly three ledger-owned fixture files removed. Installed build remains the stopped signed test-feed 0.11.1-beta; governor paused/disabled. Completed installer downloads this slice: 0. Blackwell/KVM untouched.

Detailed check and site-by-site tables: `slice15/report.md`; authoritative evidence: `slice15/harness-last/receipt.json`, `slice15/trace-receipt.json`, `slice15/frame-31805230-receipt.json`, `slice15/final-audit-receipt.json`. CR8 is resolved. Full gates remain intentionally deferred until the independent review/fix round, as requested. Final commit identities and clean-state proof: `slice15/final-branches.json`.


# Slice 16 targeted fix round

Harness A code head: `a20d61a764f7fe4565793c8b3095a17ee3cc2ff3`. Logging/signing B code head: `f52714edeb0b7a7b6652f34d82d6acd139f08503`. A merged into B; product changes remain B-only. Reports are committed separately after these code heads. No full gate, P2/P3, OTA all/contracts, signed pipeline, push or publish ran. Blackwell and KVM were not contacted. Completed installer downloads: **0**.

| Item | Change and location | Check and observed result | Evidence |
| --- | --- | --- | --- |
| R1 | No new change. Exact-file-set guard includes manifest-listed artifacts, windows_ssh.py:146. | Fresh A frames stage the tracked reports and pass source verification. The final gate at the exact report-bearing heads remains for the lead's next slice. | harness-final-tree/frame.json; p0/source-binding.json |
| R2 | CreateNew host lease and identity assertion, Harness.Common.ps1:152/160; immediate guards at app/setup/uninstall/governor/network mutations. Clear releases the owning lease. | Second frame refused; owner bytes/app untouched; stale missing-frame lease refused/kept; owner Clear releases it; foreign app refuses before setup. All four checks pass. | harness-final-tree/windows-receipt.json (R2 rows); cleanup.json |
| R3 | Public upload/verify_source/interactive restored to main v1; Update APIs renamed *_frame, windows_ssh.py:403/444/448 and :247/:347. Bounded timeouts preserved. | Configurable Encoding proof 4/4 passes on a fresh legacy frame under an owned protected parent. v1 handles native success/failure, UTF-8 and completion. Public verifier accepts an extra generated file, matching main. Caller table linked below. | ../../roo-63-64/slice16/targeted/encoding/result.json; legacy-frame.json; legacy-callers.md |
| R4 | Guard logger separately, SystemRestart.cs:22. RestartChecks.cs:42 adds throwing-every-call and throwing-second-call controls. | 12/12 restart checks pass; both commands run in order in each logger case. Real Windows restart never invoked. | ../../roo-63-64/slice16/targeted/restart.log |
| R5 | Encoded switch/parser, Harness.Common.ps1:595: powershell/pwsh, e/ec, encodedcommand prefixes >=2 and encodedarguments >=8; malformed/missing UTF-16LE refuses. | Live suspended -ec, /enc and undecodable -e refuse through the encoded guard itself. pwsh absent, so direct parser stand-in is explicitly labeled. | harness-final-tree/windows-receipt.json (R5 rows) |
| R6 | git-common-dir input resolution and --frozen-p0, run_harness_checks.py:44. | Detached /tmp/roo-fresh-check resolves the main checkout's artifacts/roo-29/p2-real-0.10/p0 without Windows/network; worktree removed. | linux/frozen-resolution.json |
| CR8 filesystem | Shared extended-path metadata/read/copy/hash/archive/cleanup; LoadTimes Native CreateFile/FileStream/ReadAllBytes use extended paths. | 331-character create/register/copy/result/hash/archive/clear checks pass; unrecorded long directory/file refused with path/bytes/ledger kept. Long generated obj ignored by snapshot; long unexpected source refused. | harness-final-tree/windows-receipt.json; long-evidence.zip; receipt.json |
| CR8 lint | Update files, embedded Python PowerShell, windows_ssh and LoadTimes scanned; explicit exact file/line/text/reason allowlist. | Both branch lints pass. Scratch reverted recursive walk and embedded Test-Path fail. | linux/lint.json; linux/lint-final.json; tools/validation/path-lint-allowlist.json |
| CR8 release bound | B Release.Checks.ps1:17 shared calculation; Build-Release.ps1:29 before work/output, :168/:191 after publish/final payload before signing/hashes/ISCC. Signing scenario reuses it. | Actual deep Build-Release refuses at a 379-character XAML path with no output. Extended output walker refuses a 331-character payload tree. Normal positive builds belong to the next full gate. | ../../roo-63-64/slice16/targeted/release-bound.json |
| CR8 Linux extraction | safe_archive_path, windows_ssh.py:322, used by both runners and payload oracle. | Extended/UNC/colon/parent/absolute/double-dot names refused; extraction errors propagate to fail. | linux/zip-member-refusals.json; harness-final-tree/receipt.json |
| CR10 | Direct prefix of drive/UNC rooted paths without dot segments, Harness.Common.ps1:18; same in native ownership helper. | Long Register-HarnessFile/New-HarnessText/Copy-HarnessFile/Read-HarnessResult passes at 331+ characters. | harness-final-tree/windows-receipt.json (CR10 row) |
| CR9 | Unique native/event birth match [-1,+10] s, Harness.Common.ps1:221; entire trace used for ambiguity, existing chain/window/handle checks retained. Native birth captured on refusal; trace proof records lagMs. | 8/8 invocations, 4 checks each, zero skips. Five idle and three loaded fresh nonces. Ambiguous two-event matcher refused (stand-in). Loaded total CPU samples 100%; logical threads hard pinned one per CPU. | trace-complete/receipt.json; trace-1..8.json; load-counters-6..8.json |
| Simplification | Removed duplicate flush after hosts removal in Invoke-ShippedScenario.ps1. | Existing exclusive hosts cleanup/writer fixtures pass; DNS flush remains in ledger cleanup. | harness-final-tree/windows-receipt.json (hosts rows) |

## Targeted gate

- Python py_compile: six changed Python entry points pass. Linux input resolution and both lint refusal controls pass.
- PowerShell 5.1.26100.9444: 127 validation/scripts files parsed with zero errors; HarnessTrace.cs compiles. Final A harness run parses its Update files again, zero errors.
- Invoke-HarnessChecks and driver checks: **61/61 pass**, including **40/40 native checks**, no skips.
- CR9: **8/8**, each 4/4. Across 16 traced adoptions: min **1132.9649 ms**, median **1600.93035 ms**, max **1993.0319 ms**. These measured lags support widening the matching interval; they do not prove a particular WMI delivery-lag mechanism.
- Restart **12/12**; legacy Encoding **4/4**; release refusal **2/2**.

## Commands

```sh
python3 -m py_compile tools/validation/windows_ssh.py tools/validation/Update/run_e2e.py tools/validation/Update/run_shipped.py tools/validation/Update/run_harness_checks.py tools/validation/Update/run_trace_checks.py tools/validation/Release/Test-WindowsSshEncoding.py
python3 -I tools/validation/Update/run_harness_checks.py --lint-only
python3 -I tools/validation/Update/run_harness_checks.py --host optimizer-9070 --expected-machine SERVI-WINDOWS-D --source-commit 20618f6 --published-installer <main>/artifacts/release/RooIndustries-OptimizationSuite-0.11.0-beta-setup.exe --out-dir <main>/artifacts/roo-62/slice16/harness-final-tree
python3 -I tools/validation/Update/run_trace_checks.py --host optimizer-9070 --expected-machine SERVI-WINDOWS-D --out-dir <main>/artifacts/roo-62/slice16/trace-complete
python3 -I tools/validation/Release/Test-WindowsSshEncoding.py --host optimizer-9070 --expected-machine SERVI-WINDOWS-D --receipt <main>/artifacts/roo-63-64/slice16/targeted/legacy-frame.json --out <main>/artifacts/roo-63-64/slice16/targeted/encoding
```

Post-check mechanical recipe and actual stage bindings: `prepare.py`, `post.py`, `legacy.py`, targeted/frame.json. Restart was built with `dotnet build tools/validation/OptimizerCore/OptimizerCore.csproj -c Release -p:UseSharedCompilation=false --disable-build-servers /nr:false`, then its built DLL ran with `--restart`. The deep bound fixture is kept in `Invoke-ReleaseBoundChecks.ps1` and runs by name through `interactive_frame`.

## In-scope harness fixes and deviations

1. The junction fixture exposed loss of Target metadata and then a dangling link whose target had already gone. The native ownership helper now reads the recorded junction itself with FSCTL_GET_REPARSE_POINT; a new dangling-junction fixture proves cleanup. The failed closure's surviving owned link was removed by verifying its original identity through a recovered copy of that ledger. Failed receipts and recovery evidence are kept in prepare/ and harness/.
2. PowerShell interpreted the unparenthesized switch `-in` expression differently than intended. Explicit parentheses fix it; live decoder checks now require the precise encoded-runner refusal, preventing another guard from satisfying them.
3. PowerShell 5.1 Add-Type rejects extended OutputAssembly paths at its provider resolver. Console compilation is an explicit bounded external-tool boundary: plain output <260, pre-existing output refused. All harness read/hash/delete operations still use extended paths. This exception is in New-HarnessConsoleAssembly; there is no long-path compiler fallback.
4. The initial CPU load inherited BelowNormal and used only the eight E-core threads. Normal/AboveNormal unpinned load made observation difficult. Final fixture stays BelowNormal, pins one busy thread to each of the 20 logical CPUs, clears inherited CPU sets/power restraint on only its owned process and exits itself after four minutes. Counter evidence confirms 100% CPU during the accepted loaded runs.
5. Owned PID 2260 (native birth 134363454863692424, recorded image in load-probe2/load.json) was stopped through a retained birth/image-verified handle using a high-priority Reflection.Emit rescue because compilation in ordinary cleanup was starved. Its ledger was reconciled and closed; no name kill occurred. Rescue command/result evidence is retained under load-probe2/. This was our own load fixture, not a lead exception or product process.
6. Legacy upload's receipt count referred to a removed variable during the API split; Encoding staging reproduced it. It now reports len(contents); the real legacy proof passes.

## Cleanup

Audit: installed **0.11.1-beta** test build remains stopped, governor state unchanged. **160 legacy frames**, **0 ledger frames**, **0 Roo/frame processes**, no host lease, harness firewall/hosts entries or test certificates. Both data-root file sets and every SHA match slice15's as-found state exactly (0 missing/new/changed). No service, KVM, Blackwell or production mutation occurred. Unrelated Process Lasso preserved. Audit/raw task XML and hosts bytes are in audit/final-inventory.json; closed ledgers are kept with each run's cleanup receipt. Historical failed invocations remain labeled fail; only their cleanup is closed.

## Limits and review

No normal release build or full published/OTA/signing gate ran, as directed. P2/P3, B all/contracts/signed and final report-bearing fresh frames remain for the lead's final gate. Blackwell-only callers were not executed. pwsh is a labeled parser stand-in; ambiguity is a synthetic event-list stand-in. The fixture compiler exception is explicitly bounded and verified on short paths.

The focused diff review found no remaining blocker in the requested changes. Both code trees are ready for the lead's independent diff review; merge readiness awaits the final gate requested for the next slice.


Final parse repeated on the final B code tree: 127/127 PowerShell files, zero parse errors, HarnessTrace Add-Type successful (`artifacts/roo-63-64/slice16/final-parse/parse.json`); frame closed. Final native audit repeated after it: 160 legacy frames unchanged, no ledger frame/lease/process/harness task/firewall/hosts marker/cert, exact data bytes unchanged. All six unrelated CS2 tasks remain Ready and Enabled. Every task XML in the earlier monitored snapshot is unchanged; the broader current inventory also records OS tasks which that earlier filtered snapshot did not enumerate, so those are not claimed as newly created by this slice.

The explicit lint allowlist is five entries: provider Test-Path in Harness.Common:32 (HKLM/HKCU/Cert); certificate removal at Harness.Common:538 (store/thumbprint); data-archive Directory.Move at Harness.Common:633 (both endpoints extended after identity check); certificate enumeration in Invoke-SigningScenario:41 (Cert provider); SDK enumeration in Invoke-SigningScenario:47 (fixed short Windows SDK path, owned fallback uses extended walker). The JSON records exact current line/text and reason and is authoritative if these text line references move.

No task-owned Linux server or runner remains. No feed or installer production request was made. The authoritative slice evidence report is `artifacts/roo-62/slice16/report.md`; the final branches receipt records report commits and clean trees.


R3 final caller audit also found Background's historical install subcommand still passing a v1 context to the now-v2 Update scenario. Commit f0da1de adds an Update-side adapter that stages a fresh frame, takes its lease, captures current rule/undo hashes, theme and governor state immediately before setup, collects evidence and closes only that frame. The caller's build/installer remains read-only. Non-install Background scenarios keep public v1 interactive. Commit a3d8b95 puts receipt persistence inside the cleanup-protected block. This is a compatibility repair, not a product change.

| Additional check | Observed | Result | Evidence |
| --- | --- | --- | --- |
| Legacy Background install adapter, owned dry invocation | Fresh v2 frame and host lease; current-data preservation capture succeeds; no installer starts; legacy source verification still succeeds | 4/4 pass | legacy-install/probe-corrected/receipt.json; adapter/evidence.zip; owner-cleanup.json |
| Changed/merged PowerShell | Both changed scripts parse under 5.1 with zero errors; merged B retains FeedUrl/FeedKeyId/OlderVersion and CurrentData | pass | ../../roo-63-64/slice16/legacy-merge-parse.json |
| Final cleanup after adapter check | 160 legacy frames; zero ledger frames, Roo/frame processes, leases, harness network rules/hosts markers or test certificates; exact data bytes unchanged | pass | audit/final-inventory.json; preservation.json |

The initial local ZIP-result reader expected a filename without the helper's sequence suffix. The desktop invocation and its cleanup passed; that reader failed and its receipt remains fail. The corrected reader requires the actual invocation nonce and sequence-bound filename, and its fresh owned invocation passes. No installed product or seeded data changed. The adapter's real setup path is deliberately not run in this targeted-only slice; it uses the existing manual-install path for the next authorized gate.

Slice16 final code heads before report-only commits: A `a3d8b951614278863e5af198788c027b6e18dd9f`, B `42f5ff616b4a4b46b190daf38508b51ed5893895`. Exact final report-bearing heads and clean states are recorded in `artifacts/roo-62/slice16/final-branches.json`.


# Slice 17 final gate: stopped on a shared harness blocker

Gate A: `0f43b62453f38f3d760161340704e7ebf74ac579`.
Gate B: `8322a13cb3663fae8ebf4ca26d907207dd5a52f9`.
Both heads were clean before staging and include the committed reports. Report-only commits follow this gate; their final SHAs are in `final-branches.json`.

The gate is **not complete**. P2 failed in the harness before the published installer ran. The small discriminating fixture confirms that Windows PowerShell 5.1 `Invoke-WebRequest -OutFile` rejects a `\\?\` destination even when the directory exists: extended path fails with `System.IO.FileNotFoundException: Unable to find the specified file`; the same HTTPS feed request to the ordinary short path succeeds and writes 1,251 bytes. This is another path in the accepted provider/extended-path compatibility class. Per the lead's same-class rule, remaining gates were stopped and no product fix or download-path patch was made.

| Gate | Observed | Result | Evidence |
| --- | --- | --- | --- |
| Hardening | Exact requested normalizer in Harness.Common.ps1:18; Release.Checks.ps1:1. Short paths normalize through GetFullPath; long separators collapse; long dot/parent/trailing dot/space segments refuse. Three new fixtures at Invoke-HarnessChecks.ps1:234. | pass | hardening-failure-ways.json; harness/windows-receipt.json |
| Fresh A staging / R1 | Manifest includes artifacts/roo-62/report.md; exact source snapshot passes at A gate SHA. | pass | staging-receipt.json; a-staging-frame.json; a-staging-cleanup.json |
| Fresh B staging / R1 | Manifest includes both committed reports; exact source snapshot passes at B gate SHA. | pass | staging-receipt.json; b-staging-frame.json; b-staging-cleanup.json |
| PS 5.1 parse / HarnessTrace compile | A 80 files, B 81 files, zero errors; HarnessTrace compiled on both. All Update/LoadTimes/Release and tools/scripts PS1 files were included. | pass | a-parse.json; b-parse.json |
| Full harness checks | 64/64, including 43/43 native checks; zero skips. Short doubled separator found; long doubled separator found at 313 chars; long parent segment refused with the explicit normalization reason. | pass | harness/receipt.json; windows-receipt.json; harness-runner.log |
| Trace once | All three required ownership fixtures plus the existing ambiguity fixture pass (4/4). The eight-run CR9 series was not repeated. | pass | trace/receipt.json; desktop.log; cleanup.json |
| P2 published bootstrap | Uninstall, real 6c6515cd baseline wizard, seed, independent tweak readback, undo existence, old app + governor running all pass. DownloadPublished then fails at Invoke-ShippedScenario.ps1:218. No published setup starts. Cleanup reports zero errors. | fail | published/p2/receipt.json; desktop.log; pc-artifacts/shipped/p2-14f1cde1202e4f50acdb8877f1db3584/failure-14f1cde1202e4f50acdb8877f1db3584-0065.json |
| P3 live alpha OTA | Not started after the shared-class failure. | blocked | published/gate-results.json |
| B all 21 / contracts 25 / close-during-check | Not started after the shared-class failure. | blocked | gate-summary.json |
| B signed subset / governor / wrong-subject / cert cleanup | Not started; no new signing certificate was created. | blocked | gate-summary.json |
| B normal/pair/signed/negative release bounds | No B build ran, so no execution/pass claim for its release guards. Parse only passed. | unverified | b-parse.json; gate-summary.json |
| Host leases | Every driver actually run takes a ledger-owned lease; all owner frames close. Final lease absent. | pass | staging cleanup receipts; harness/cleanup.json; trace/cleanup.json; download-path-probe/closed-ledger.json; cleanup/closed-ledger.json; cleanup-audit.json |
| Final cleanup / preservation | Original signed test-feed 0.11.1-beta build restored from the retained slice14 installer, app stopped, governor paused. Zero owned processes/tasks/firewall/hosts/certs/lease/cache/frames. Both data-root file sets/hashes match as-found. 160 legacy frame paths + native births match. Six CS2 tasks remain Ready/Enabled with identical XML. | pass | final-inventory.json; cleanup-audit.json; owned-process-audit.json; cleanup/build-rollback.json; cleanup/data-restore.json |

## Confirmed shared blocker and the follow-up scope

High-confidence High harness blocker: `tools/validation/Update/Invoke-ShippedScenario.ps1:218` calls `Invoke-WebRequest -OutFile (Get-HarnessLongPath $path)`. Both native directory existence and ordinary-path success contradict an absent directory or bad HTTPS feed as the cause. `download-path-probe/receipt.json` retains both requests, output paths, existence and exceptions. It creates and closes only its own frame.

The same command shape exists in `Invoke-SigningScenario.ps1:53` for the SDK package. Its `Expand-Archive` at :54 also delegates extended paths to a PowerShell provider. Those signing paths were not executed here and are **unverified**, not claimed as a second reproduced failure. The shared fix should make harness download/extraction file IO use native extended-path streams/ZIP APIs, with targeted real PS5.1 checks; do not switch random call sites back to ordinary paths. The bounded Add-Type/compiler boundary already documented in slice16 remains separate.

## Commands

```sh
python3 -I artifacts/roo-62/slice17/prepare.py
python3 -I tools/validation/Update/run_harness_checks.py --host optimizer-9070 --expected-machine SERVI-WINDOWS-D --source-commit 20618f6 --published-installer <main>/artifacts/release/RooIndustries-OptimizationSuite-0.11.0-beta-setup.exe --out-dir <main>/artifacts/roo-62/slice17/harness
python3 -I artifacts/roo-62/slice17/trace.py
python3 -I tools/validation/Update/run_shipped.py --scenario p2 --source-commit 20618f6 --host optimizer-9070 --expected-machine SERVI-WINDOWS-D --baseline-installer <main>/artifacts/release/RooIndustries-OptimizationSuite-0.10.0-beta-setup.exe --baseline-sha256 6c6515cdf93c6b5751a37957ae855962d534ca786720773571747d202b576ed4 --published-installer <main>/artifacts/release/RooIndustries-OptimizationSuite-0.11.0-beta-setup.exe --innoextract <main>/artifacts/roo-29/p0/tool/build/innoextract --out-dir <main>/artifacts/roo-62/slice17/published
python3 -I artifacts/roo-62/slice17/download-path-probe.py
python3 -I artifacts/roo-62/slice17/final-audit.py
```

Absolute argv and exact remote commands/source manifests are in published/p2-command.json, published/p2/desktop.command.json and the retained mechanical recipes. A's product diff against 20618f6 remains empty (`e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`). The Release.Checks helper change is B-only because A must keep that published product binding.

## Cleanup details and limits

- P2 leaves two deliberately retained tester-fixture entries. Cleanup replayed their actual creation ledger and checked native identities, rather than matching a replacement PID/path. The reconciled historical ledger has no active retained entries: cleanup/p2-reconciled-ledger.json.
- The test-created rule and preview are bound to the nonce-bearing rule-save/tweak-preview receipts and checked by hash/native birth before ledger removal. Original settings, app log, governor heartbeat and host state were restored from the initial ZIP after comparing hashes. No original file was lost.
- A mechanical cleanup comparison initially compared a doubled-separator literal with the canonical rule path; the first audit correctly reported that one seeded rule remained. Its exact nonce/id/hash/birth were then verified and it was removed through the ledger; final audit passes. No product/harness source was changed for that cleanup correction.
- Tweak recovery lives in HKLM, outside the two file roots. Its original raw byte hash was not captured. The prior accepted slice14 state exactly matches P2's BeforeRevision. That revision-bound state was restored and every decoded field independently matches; raw registry-byte equality remains unverified. Transparency returned to its initial value 0. Evidence: cleanup/prior-tweak-state.json, data-restore.json, tweak-state-comparison.json.
- Native audit checks 45 owned PID/birth identities: zero live matches, zero unreadable identities. Root/lease/network/cert/task audit passes. An unrelated Linux support HTTP server (PID 1530, port 8080) was preserved; this slice started no Linux server.

Completed production installer downloads: **0**. One production installer Invoke-WebRequest was attempted and failed before any output file was created; no successful transfer is claimed. The discriminating probe made two additional small live-feed GET attempts, with one completed 1,251-byte output. No publish, push, signing-key use/transfer, new test cert, trust-root/Defender change, Blackwell or KVM contact occurred.

**Verdict: not ready to merge.** R1 staging, hardening and the ownership checks pass, but the shared provider/download IO blocker is open and P2/P3 plus B's unsigned/contracts/close/signed/build guards still lack the required final-gate proof. No product failure was observed.

Update-cache audit found no release directory, executable, partial file or pending record. The as-found install-0.11.1-beta.log is preserved with its original SHA; install logs are not counted as release cache. Evidence: cache-audit.json and task-cache-audit.json.


## Slice 18: native/tool path boundary and stopped final gate

**Verdict: neither branch is ready to merge.** The native alternate-data-stream path remains a blocking CR8 concern. The final gate stopped in P2, per the lead's same-class stop rule; P3 and every B runtime/build/signing gate remain unrun.

Gate code heads: A `0f19fd230230e5dd498c7dcb24a87b1561cf8934`, B `5bbf0369c2ddf12216b6b2f6b3bde0ecf4d1e5d5`. Subsequent report-only commits do not claim new runtime validation. A's product-source diff against `20618f6` is empty (SHA-256 `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`). The report-bearing trees staged successfully through the actual v2 interactive runner.

Changes: `Get-HarnessToolPath` separates normal, shorter-than-260 tool paths from native extended paths. Compiler output, HTTP downloads, archive extraction, ACL reads, junction creation, signatures, location changes, script/executable launches and task action paths use the boundary. Native IO keeps extended paths. B adds the matching release helper and actual path-bound success log markers. The complete audit is [tool-boundary-audit.md](slice18/tool-boundary-audit.md), with the inspected historical diffs in `slice18/a-reviewed-history.diff` and `slice18/b-reviewed-history.diff`. The fixture table is [tool-fixtures.md](slice18/tool-fixtures.md).

| Gate | Observed | Result | Evidence |
|---|---|---|---|
| Python compile, A/B | All Update Python plus windows_ssh compile | pass | `slice18/a-py-compile.log`, `slice18/b-py-compile.log` |
| Boundary lint, A/B | Clean trees pass; restored slice-17 IWR line is refused at Invoke-ShippedScenario:218 | pass | `slice18/a-final-lint.log`, `slice18/b-final-lint.log`, `slice18/lint-reverted-fail.log` |
| Fresh staging A/B | Exact manifest includes committed reports; snapshot verified | pass | `slice18/harness5/frame.json`, `slice18/trace2/frame.json` |
| PowerShell 5.1 parse / trace compile | A Update parse has zero errors; B all 81 Update/LoadTimes/Release/tools-script files have zero errors; HarnessTrace compiles | pass | `slice18/harness5/powershell-parse.json`, `slice18/trace2/final-b-parse.json` |
| Owned harness checks | 97/97, including 76 Windows fixture checks, no skips | pass | `slice18/harness5/receipt.json`, `slice18/harness5/windows-receipt.json` |
| Trace ownership | 3 required cases plus ambiguity stand-in, all pass | pass | `slice18/trace2/receipt.json` |
| P2 real baseline | 0.10.0 installer identity and wizard, seeding, old app + governor running pass; published download completes; MOTW write throws before published setup | **fail / blocked** | `slice18/published2/p2/receipt.json`, `slice18/published2/p2/desktop.log`, nonce-bound `failure-*.json` in `slice18/published2/p2/pc-artifacts` |
| P3 alpha → live beta | Stopped after P2 | not run | `slice18/gate-summary.json` |
| B all 21 / contracts 25 / close-during-check | Stopped after P2 | not run | `slice18/gate-summary.json` |
| B signed pair / OTA / governor / negative / cert cleanup | Stopped before certificate creation or any B build | not run | `slice18/gate-summary.json` |
| Lease + cleanup + raw bytes | 14 audit checks pass; exact data file set/hash equality; raw registry kind/bytes equal; no release-cache directories | pass | `slice18/cleanup-audit.json`, `slice18/raw-registry-as-found.json`, `slice18/raw-registry-final.json`, `slice18/update-cache-audit.json` |

The blocking call is `Invoke-ShippedScenario.ps1:221`: `[IO.File]::WriteAllText((Get-HarnessLongPath ($path+':Zone.Identifier')), ...)`. `Harness.Common.ps1:22` calls `[IO.Path]::GetFullPath` on that ordinary short alternate-stream name and throws **"The given path's format is not supported."** This is a harness path-normalization failure, not evidence of a product failure. The creation ledger independently captured the completed file hash `7FD804B4082FD3E92CCB6BD0693530AB0BEE8A7D9E41FBA44C03ECEF92707BB9`. The later explicit size/SHA comparison did not run because the preceding MOTW write threw; no installer execution occurred. **One completed production installer download**; the published installer was never executed. No upload or publish occurred. The next fix needs a defined native alternate-stream boundary, normalizing the base file separately and preserving the stream suffix; it is deliberately not patched in this stop round.

The exact P2 command is in `slice18/published2/p2-command.json`. The baseline was 110,024,946 bytes / `6c6515cdf93c6b5751a37957ae855962d534ca786720773571747d202b576ed4`; the published installer was 110,073,731 bytes / `7fd804b4082fd3e92ccb6bd0693530ab0bee8a7d9e41fba44c03ecef92707bb9`. Linux signing keys stayed on Linux. Blackwell and the KVM were not contacted.

Harness repairs during this gate: the new junction fixture initially used an unsupported ledger kind; it now uses the existing folder/junction identity. The failed fixture entry was corrected outside code only after checking its recorded target and native birth inside that invocation's creation window (`harness/fixture-registration-correction.json`); it was then removed through the ledger. Bare executable names now resolve through Get-Command before path guarding. The new Get-Content observation initially retained PS provider metadata, causing deep JSON expansion; receipts now contain independently verified character count/hash. The isolated scenario passes 33/33, and the final complete 97-case run repeats it. Microsoft documents that older PowerShell versions serialize String extended properties: [ConvertTo-Json](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.utility/convertto-json). Actual PSPath/PSDrive/PSProvider properties and the 2.2 GB stalled process observation are saved in `powershell-string-metadata.json` and `tool-only/live-diagnostic.json`.

The first P2 attempt did not start its scheduled action because its nested-encoded command was 32,784 characters. Windows allows 32,767 including the terminator: [CreateProcessW](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-createprocessw). The v2 wrapper now uses a ledger-owned file; the real runner checks and the next P2 invocation prove this path executes. The failed task XML and decoded wrapper are in `published/closed-ledger.json` and `published/p2-wrapper.ps1`. Neither failed preliminary P2 nor local fixture HTTP GETs count as completed installer downloads.

Cleanup restored the as-found signed test-feed **0.11.1-beta** from the retained local installer, with Suite closed and governor paused. Both data roots have zero missing/new/changed files. Every captured tweak-state/EnableTransparency raw registry byte and kind matches; both recovery State bytes and absent Pending values are preserved. The 160 legacy frames and six Ready/Enabled CS2 task definitions match as found. All 118 recorded owned PID/birth identities are absent; reused PIDs are preserved. No owned tasks, hosts lines, firewall rules, certificates, leases, frames or update cache directories remain. The pre-existing install log is retained. The unrelated `/opt/roo-support` HTTP server PID 1530 remains on Linux port 8080, as found; nothing owned remains running. Final evidence: `final-inventory.json`, `owned-process-audit.json`, `ledger-inventory.json`, `linux-process-audit.txt`, `cleanup/closed-ledger.json` and `cleanup/p2-reconciled-ledger.json`.

Delta review: the implemented boundary covers the audited cmdlet/tool categories and preserves v1 invocation context, process creation identity and ledger-only cleanup. The new alternate-stream input contradicts the native-path invariant, so this review **blocks merge**. The B build/signature/runtime gates and full published journey are still missing proof, rather than marked pass from earlier slices.
