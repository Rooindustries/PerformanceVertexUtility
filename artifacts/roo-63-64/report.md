# ROO-63 / ROO-64 Slice14 final report

**Not ready to merge: shared path handling blocks final frame cleanup.** Fresh unsigned 21/21, separate contracts 25/25, close-during-check and the fresh signed subset all pass. The failed silent and mid-copy update relaunches use actual kernel trace proofs. No product code changed in Slice14; accepted ROO-63/64 fixes are on B. Shared harness fixes are merged from A.

B code HEAD `0f4a48188ab47dc2141a5f5f846f3007c3835885`, A code HEAD `c5c24f9a9ec8bd3ec6c05e4d45ed398afd196eff`. Unsigned all/extra gates used fresh frameb981147c669a440ba0cc1484aa847405 at `bc5cb6c`. Later changes affect shipped optional-preflight exception propagation and signing-fixture cleanup/path guard only; no product, trace or UpdateScenario input changed. The successful signed gate used fresh frame31805230c2994beebc7ab152f304f221 atB `0f4a481`. Report-only final HEADs and clean readback are in `../roo-62/slice14/final-branches.json`.

## Gate results

| Check | Observed | pass/fail | Evidence |
|---|---|---|---|
| Fresh all | 21 named scenarios; actual A/B builds; no interrupted run resumed;2395.119s | pass | slice14/all/scenario-results.json |
| Separate contracts | 25 expected kinds/keys;908.499s | pass | slice14/contracts/contracts/results.json |
| close-during-check | Close owned main window while Checking; native exit0; exact closing-canceled line; 158.174s | pass | slice14/close-during-check/scenario-results.json |
| install trace relaunch | Owned setup chain -> app5704; 1 recorded event/native-birth proof | pass | slice14/all/pc-artifacts/ota/install-b4a93bb4ccae42ea9d128b918e7ed8b9/relaunch-ownership-b4a93bb4ccae42ea9d128b918e7ed8b9-0005.json |
| failure trace relaunch | Owned app7912 -> short-lived setup chain -> old app9964;3 events/native-birth proof; failure status/Try again | pass | slice14/all/pc-artifacts/ota/failure-29275900c13f465b86f68d5aac3bd0fb/relaunch-ownership-29275900c13f465b86f68d5aac3bd0fb-0004.json |
| copy-failure recovery | Exe missing; interactive owned recovery wizard; Finish opens workingB via traced child13840 | pass | slice14/all/pc-artifacts/ota/copy-failure-1daed9d8dbca4ceaa3f81e27d0da7490/ |
| Signed pair | Fresh self-signed RSA 3072 CU My cert; pair built273.452s;9 required Roo PEs plus signed setup/uninstaller | pass | slice14/signed/signed-build.json; build-times.json |
| Signed installed A/B | Each verify checks12 signatures, subject/thumbprint and governor path; both setups included; governor PID 15072 -> 6844 | pass | slice14/signed/verify-A.json; verify-B.json |
| Signed OTA | Seed running governor before preservation; manual A -> ready -> Install -> Updated to version 0.11.1-beta; cache/pending/preservation checked | pass | slice14/signed/ota-install/scenario-results.json; pc-artifacts/ |
| Wrong subject negative | CN=Wrong Subject refuses after PE verification, before ISCC; 0 installers | pass | slice14/signed/negative.json |
| Certificate removal | E39E17DD2BF5CE9A08807C2A7F83D0CD7D550B7A absent; no export or root trust change | pass | slice14/signed/certificate-cleanup.json |
| Long-path guard | 263-character XAML intermediate refused before cert creation; certificate count 0 before/after; 9.407 s | pass | slice14/signed/path-guard/receipt.json |
| Final cleanup | 7/8 currentframes removed; 1 signed frame/ledger remains because of 264-character traversal; 0 owned runtime/network/certificate/cache residue; original settings restored; 160 unledgered legacyframes untouched | fail: owned frame retained | ../roo-62/slice14/final-cleanup/audit-receipt.json |
| RestartChecks | Accepted 10/10, code unchanged; explicitly not rerun | accepted historical gate | slice13b/prior-report-slice12.md |

Installed signature Status was UnknownError, as expected for the explicitly allowed untrusted test certificate; exact subject `CN=Roo Industries Test Signing ROO-64` and thumbprint matched every required file. No root trust was added, private key exported or SDK installed; existing SDK signtool was used. Production builds remain unsigned unless signing is configured.

All scenario result rows are invocation/frame/nonce-bound and final status follows cleanup. See `slice14/signed/gate-results.json` for all 11 orchestration rows. Contract JSONs bind expected results to actual probe invocations; they cannot pass without running.

## Exact logging checks

Each expected line below was found in the new owned app segment; every record asserts no feed path/query. `<feed-host>` stands for the actual host in the ignored raw JSON. Settings text stays unchanged. The helper serializes an absent extra status expectation as an empty object for some cases; those statuses were checked by the scenario's WaitStatus/readback, and are not represented as additional exact helper comparisons.

| Scenario | Expected exact line | Observed status / pass/fail | Evidence |
|---|---|---|---|
| bad-signature | `Feed <feed-host>: Refused. The update signature is invalid. Couldn't verify this release; installed 0.11.0-beta.` | Couldn't verify the update. The update signature is invalid. Couldn't verify this release. / pass | slice14/all/pc-artifacts/ota/bad-signature-c95079b36ba64307861c1e4b8507fe4a/feed-log-c95079b36ba64307861c1e4b8507fe4a-0003.json |
| blocked | `Cached feed <feed-host>: Available, key e4af8027d58d3b3f, release 0.11.1-beta. Version 0.11.1-beta is available; installed 0.11.0-beta.` | Stop your game session and turn off the timer setting first. The update can't install while they run. / pass | slice14/all/pc-artifacts/ota/blocked-42abcb188edb4d1981c6f104b5275336/feed-log-42abcb188edb4d1981c6f104b5275336-0003.json |
| cancel | `Cached feed <feed-host>: Available, key e4af8027d58d3b3f, release 0.11.1-beta. Version 0.11.1-beta is available; installed 0.11.0-beta.` | Version 0.11.1-beta is ready to install / pass | slice14/all/pc-artifacts/ota/cancel-29557b978fc242f19305f310529e6d59/feed-log-29557b978fc242f19305f310529e6d59-0003.json |
| copy-failure | `Cached feed <feed-host>: Available, key e4af8027d58d3b3f, release 0.11.1-beta. Version 0.11.1-beta is available; installed 0.11.0-beta.` | You have the latest version / pass | slice14/all/pc-artifacts/ota/copy-failure-1daed9d8dbca4ceaa3f81e27d0da7490/feed-log-1daed9d8dbca4ceaa3f81e27d0da7490-0010.json |
| copy-failure-ready | `Cached feed <feed-host>: Available, key e4af8027d58d3b3f, release 0.11.1-beta. Version 0.11.1-beta is available; installed 0.11.0-beta.` | Version 0.11.1-beta is ready to install / pass | slice14/all/pc-artifacts/ota/copy-failure-ready-9d43ac2f3caa438e9c15e61207595e5a/feed-log-9d43ac2f3caa438e9c15e61207595e5a-0009.json |
| copy-failure-ready | `Feed <feed-host>: Available, key e4af8027d58d3b3f, release 0.11.1-beta. Version 0.11.1-beta is available; installed 0.11.0-beta.` | Version 0.11.1-beta is ready to install / pass | slice14/all/pc-artifacts/ota/copy-failure-ready-9d43ac2f3caa438e9c15e61207595e5a/feed-log-9d43ac2f3caa438e9c15e61207595e5a-0009.json |
| failure | `Cached feed <feed-host>: Available, key e4af8027d58d3b3f, release 0.11.1-beta. Version 0.11.1-beta is available; installed 0.11.0-beta.` | The update to 0.11.1-beta didn't finish. Setup log: %LOCALAPPDATA%\RooOptimizationSuite\updates\install-0.11.1-beta.log / pass | slice14/all/pc-artifacts/ota/failure-29275900c13f465b86f68d5aac3bd0fb/feed-log-29275900c13f465b86f68d5aac3bd0fb-0007.json |
| feed-down | `Feed <feed-host>: HTTP 502; installed 0.11.0-beta.` | Couldn't check for updates. The update server returned HTTP 502 instead of 200. / pass | slice14/all/pc-artifacts/ota/feed-down-2e90a20f8cbb4b098948ae5861d3eff0/feed-log-2e90a20f8cbb4b098948ae5861d3eff0-0003.json |
| install | `Cached feed <feed-host>: Available, key e4af8027d58d3b3f, release 0.11.1-beta. Version 0.11.1-beta is available; installed 0.11.0-beta.` | Updated to version 0.11.1-beta / pass | slice14/all/pc-artifacts/ota/install-b4a93bb4ccae42ea9d128b918e7ed8b9/feed-log-b4a93bb4ccae42ea9d128b918e7ed8b9-0009.json |
| malformed-feed | `Feed <feed-host>: Refused. The update feed is invalid: Expected depth to be zero at the end of the JSON payload. There is an open JSON object or array that should be closed. LineNumber: 0 \| BytePositionInLine: 1; installed 0.11.0-beta.` | Couldn't verify the update. The update feed is invalid: Expected depth to be zero at the end of the JSON payload. There is an open JSON object or array that should be closed. LineNumber: 0 \| BytePositionInLine: 1. / pass | slice14/all/pc-artifacts/ota/malformed-feed-bfdc539b6b9e4c898a74e37a89b90d63/feed-log-bfdc539b6b9e4c898a74e37a89b90d63-0003.json |
| manual-download | `Feed <feed-host>: Available, key e4af8027d58d3b3f, release 0.11.1-beta. Version 0.11.1-beta is available; installed 0.11.0-beta.` | Version 0.11.1-beta is ready to install / pass | slice14/all/pc-artifacts/ota/manual-download-0a5f3a28128345ffb4c177c665c56aa6/feed-log-0a5f3a28128345ffb4c177c665c56aa6-0007.json |
| older-version | `Feed <feed-host>: Current, key e4af8027d58d3b3f, release 0.10.0-beta. You have the latest version; installed 0.11.0-beta.` | You have the latest version / pass | slice14/all/pc-artifacts/ota/older-version-8e4db8e8d8e6428aab24ec9277baa5ac/feed-log-8e4db8e8d8e6428aab24ec9277baa5ac-0003.json |
| ready | `Cached feed <feed-host>: Available, key e4af8027d58d3b3f, release 0.11.1-beta. Version 0.11.1-beta is available; installed 0.11.0-beta.` | Version 0.11.1-beta is ready to install / pass | slice14/all/pc-artifacts/ota/ready-512bfbaa776c471a816f6f0704412adb/feed-log-512bfbaa776c471a816f6f0704412adb-0009.json |
| ready | `Feed <feed-host>: Available, key e4af8027d58d3b3f, release 0.11.1-beta. Version 0.11.1-beta is available; installed 0.11.0-beta.` | Version 0.11.1-beta is ready to install / pass | slice14/all/pc-artifacts/ota/ready-512bfbaa776c471a816f6f0704412adb/feed-log-512bfbaa776c471a816f6f0704412adb-0009.json |
| ready | `Cached feed <feed-host>: Available, key e4af8027d58d3b3f, release 0.11.1-beta. Version 0.11.1-beta is available; installed 0.11.0-beta.` | Version 0.11.1-beta is ready to install / pass | slice14/all/pc-artifacts/ota/ready-dd3cecbe9cdc420d919e6bf2e7c2e276/feed-log-dd3cecbe9cdc420d919e6bf2e7c2e276-0009.json |
| ready | `Feed <feed-host>: Available, key e4af8027d58d3b3f, release 0.11.1-beta. Version 0.11.1-beta is available; installed 0.11.0-beta.` | Version 0.11.1-beta is ready to install / pass | slice14/all/pc-artifacts/ota/ready-dd3cecbe9cdc420d919e6bf2e7c2e276/feed-log-dd3cecbe9cdc420d919e6bf2e7c2e276-0009.json |
| same-version | `Feed <feed-host>: Current, key e4af8027d58d3b3f, release 0.11.0-beta. You have the latest version; installed 0.11.0-beta.` | You have the latest version / pass | slice14/all/pc-artifacts/ota/same-version-49479be5b1ac46558c9f0fe2cfaa0275/feed-log-49479be5b1ac46558c9f0fe2cfaa0275-0003.json |
| scheduled-download | `Feed <feed-host>: Available, key e4af8027d58d3b3f, release 0.11.1-beta. Version 0.11.1-beta is available; installed 0.11.0-beta.` | Version 0.11.1-beta is ready to install / pass | slice14/all/pc-artifacts/ota/scheduled-download-27495ec9e453472e864613d5c4325275/feed-log-27495ec9e453472e864613d5c4325275-0006.json |
| slow-feed | `Feed <feed-host>: failed: The request timed out; installed 0.11.0-beta.` | Couldn't check for updates. The request timed out. / pass | slice14/all/pc-artifacts/ota/slow-feed-07b777ed576b4e66931850b1d4893aa5/feed-log-07b777ed576b4e66931850b1d4893aa5-0003.json |
| tampered | `Feed <feed-host>: Available, key e4af8027d58d3b3f, release 0.11.1-beta. Version 0.11.1-beta is available; installed 0.11.0-beta.` | The download didn't match the signed release, so it was deleted. The app will try again later. / pass | slice14/all/pc-artifacts/ota/tampered-ef57fbbba07f47c1852615a45d38e58c/feed-log-ef57fbbba07f47c1852615a45d38e58c-0003.json |
| tampered-size | `Feed <feed-host>: Available, key e4af8027d58d3b3f, release 0.11.1-beta. Version 0.11.1-beta is available; installed 0.11.0-beta.` | The download didn't match the signed release, so it was deleted. The app will try again later. / pass | slice14/all/pc-artifacts/ota/tampered-size-cb2303b5c6774d22bf38df489b2c8db9/feed-log-cb2303b5c6774d22bf38df489b2c8db9-0003.json |
| wrong-channel | `Feed <feed-host>: Refused, key e4af8027d58d3b3f. This release is for another update channel; installed 0.11.0-beta.` | Couldn't verify the update. This release is for another update channel. / pass | slice14/all/pc-artifacts/ota/wrong-channel-feab739cb1864bcb89557bc87041e582/feed-log-feab739cb1864bcb89557bc87041e582-0003.json |
| wrong-product | `Feed <feed-host>: Refused, key e4af8027d58d3b3f. This release is for another product; installed 0.11.0-beta.` | Couldn't verify the update. This release is for another product. / pass | slice14/all/pc-artifacts/ota/wrong-product-2bd3f0e270c54ea78a9820eec0bea3d6/feed-log-2bd3f0e270c54ea78a9820eec0bea3d6-0003.json |
| close-during-check | `Feed <feed-host>: canceled: the app is closing; installed 0.11.0-beta.` | Checking for updates... / pass | slice14/close-during-check/pc-artifacts/ota/close-during-check-980262f89d8d45af8b19d0441df4f573/feed-log-980262f89d8d45af8b19d0441df4f573-0004.json |

F10: verified key is assigned only after signature success; wrong-product/channel and later signed-payload refusals retain it. An invalid/missing signature logs no verified key. F11: host-only Describe/LogFeed includes live and cached outcomes, punctuation, installed version and closing cancellation; user Status strings remain unchanged. Slash/dash password arguments are refused. These are product behavior checks, separate from the harness's source-binding/ownership checks.

## Commands and controls

Exact private argv/fields remain in each `command.json`, `*-command.json` and signing command JSON. Reusable public form:

```text
python3 -I <repo>/.claude/worktrees/roo-63-64/tools/validation/Update/run_e2e.py --host <test-pc> --expected-machine <computer-name> --feed-url https://<feed-host>:8460/ota-e2e/beta.json --signing-key <external-signing-key> --scenario all --out-dir <repo>/artifacts/roo-63-64/slice14/all
```

```text
python3 -I <repo>/.claude/worktrees/roo-63-64/tools/validation/Update/run_e2e.py --host <test-pc> --expected-machine <computer-name> --feed-url https://<feed-host>:8460/ota-e2e/beta.json --signing-key <external-signing-key> --scenario contracts --out-dir <repo>/artifacts/roo-63-64/slice14/contracts --receipt <repo>/artifacts/roo-63-64/slice14/all/receipt.json --skip-build --build-root C:\RooBuild\roo-industries-roo20-ota-b981147c669a440ba0cc1484aa847405\ota\builds --evidence-root C:\RooBuild\roo-industries-roo20-ota-b981147c669a440ba0cc1484aa847405\contracts
```

```text
python3 -I <repo>/.claude/worktrees/roo-63-64/tools/validation/Update/run_e2e.py --host <test-pc> --expected-machine <computer-name> --feed-url https://<feed-host>:8460/ota-e2e/beta.json --signing-key <external-signing-key> --scenario close-during-check --out-dir <repo>/artifacts/roo-63-64/slice14/close-during-check --receipt <repo>/artifacts/roo-63-64/slice14/all/receipt.json --skip-build --build-root C:\RooBuild\roo-industries-roo20-ota-b981147c669a440ba0cc1484aa847405\ota\builds --evidence-root C:\RooBuild\roo-industries-roo20-ota-b981147c669a440ba0cc1484aa847405\close-during-check
```

Signed orchestration used `windows_ssh.py interactive` with Source=<frame>\source, OutRoot=<frame>\s, FeedUrl=<test-feed>, A0.11.0-beta/B0.11.1-beta. Scenario order: build, start-governor, seed, manual-install, verify-A, ready, install, verify-B, cleanup, negative, certificate-cleanup. Exact fields are in `slice14/signed/*-command.json`; runner argv in each signed ota*/command.json. Pathguard used OutRoot=<frame>\signing instead, and asserted the refusal plus no certificate.

The unsigned controls vary feed signature/product/channel/version/size/hash/transport, existing session state, confirm/cancel, installer abort/copy failure or close timing. They observe exact status/log lines, cache/pending/preservation, real process chains and installed version; they ignore unrelated user performance, external workloads and malicious-administrator behavior. Signed controls vary certificate subject/trust and compare actual PE signatures, new governor identity and update completion. Tests never rely on path/title alone for authority.

## Failed attempts and narrow fixes

| Attempt | Failure / diagnosis | Fix and check | Evidence |
|---|---|---|---|
| First signed pair 966c… | A built; B XAML compiler could not find intermediate assembly; cleanup read a pass-only result and refused to remove the owned cert | Certificate cleanup now reads unique creation-ledger cert; failed-build cert E596… removed through ledger; later failed-build cleanup passes | slice14/signed-build-failed-966c/; failed-build-cert-cleanup.json |
| Second signed pair 4732… | Same XAML failure reproduced;263-character intermediate DLL normal File.Exists false /extended-path true; LocalAssembly null | Stop blind retries; short output root resolves compiler path dependency; new guard rejects long root before cert; cert C5A6… removed | slice14/build-diagnosis/path-limit.json; slice14/signed-path-failed-4732/certificate-cleanup.json |
| Third signed 7ffd… | Signed pair/verify A passed; local driver enabled governor after seed so preservation baseline false vs current true | Move Resume before seed; clear only ledger-owned B cache; fresh final pair/cert and subset pass | slice14/signed-governor-baseline-failed-7ffd/; cache-cleanup.json |
| Separate contracts first driver invocation | Build root defaulted under new evidence dir; UpdateProbe missing | Explicit --build-root points to receipt-bound existing pair; extra contracts rerun 25/25; all not rerun | slice14/contracts/wrong-build-root.log; slice14/gate-results-before-driver-fix.json |

These were harness/environment failures, not a product defect. Final cleanup adds the remaining shared-class blocker: the 264-character wrong-subject tool-cache directory exists through an extended path, but PowerShell traversal fails. `../roo-62/slice14/final-cleanup/path-blocker.json` and `native-audit.json` retain the error and discriminating readback. [Microsoft documents MAX_PATH and extended-length paths](https://learn.microsoft.com/en-us/windows/win32/fileio/maximum-file-path-limitation). No further implementation was made after that finding. All failed receipts remain. No earlier interrupted B run is counted. Final pathguard and cleanup changes affect only the signing harness; the product compiled/tested in fresh unsigned B is unchanged. Full source-based entry-point self-audit and CR7 call-site bounds are in `../roo-62/slice14/self-audit.md` and the A report.

## Cleanup and review

9070 final install: signed test-feed 0.11.1-beta, stopped, governor paused, cert removed. No Suite/owned harness process/task/firewall/hosts marker/cache remains. One owned signed frame/ledger remains. Settings bytes/transparency restored to as-found; durable original rules/undo/history retained with explicitly itemized volatile logs/cache changes. The retained P2 tester fixture/rules/undo remain; temporary Update seed targets were cleared through their ledgers. 160 old frames without ledgers remain, as required by the no-unowned-cleanup rule. Ordinary feed-host mapping and unrelated Process Lasso/CS2 tasks were preserved. Blackwell/KVM were not contacted. PID15504 is absent after power loss; no stop/replacement search occurred.

Production installer transfers this slice: 2 complete (P2 IWR 1 + P3 actual app OTA 1); none from B. No publication, main change, push, amend, Blob token, private signing-key transfer, Defender or trust-root change. No unit tests added. Reports/final tree readback are separate from gate source hashes.

B commits in this slice:
```text
0f4a48188ab47dc2141a5f5f846f3007c3835885 serviroo <serviroo@rooindustries.com> merge(validation): guard signing build path lengths
c5c24f9a9ec8bd3ec6c05e4d45ed398afd196eff serviroo <serviroo@rooindustries.com> fix(validation): refuse long XAML signing build paths
b7cbf08a1644a3002f3216328a52d6cd20791e5f serviroo <serviroo@rooindustries.com> merge(validation): clean certificates after failed builds
c28f65581833273c372ba2d77fb819c62c71880f serviroo <serviroo@rooindustries.com> fix(validation): clean signing certificates from the ledger
4a620b2fd408af4205e95d70389e867dfabda2f8 serviroo <serviroo@rooindustries.com> merge(validation): preserve optional-host failure types
dedd7ec1447e91f607a84d6bf54eafd769e5ce42 serviroo <serviroo@rooindustries.com> fix(validation): preserve preflight transport failure types
bc5cb6c934acd7df744da182cd9c6205c83478be serviroo <serviroo@rooindustries.com> merge(validation): stabilize the trace fixture lock
70e094cccc6dfad620a1c926ef827b132162b8ae serviroo <serviroo@rooindustries.com> fix(validation): wait for the trace fixture ledger lock
391d2e7211265ab7cf72ca368e87be22a4235875 serviroo <serviroo@rooindustries.com> merge(validation): distinguish remote command deadlines
3882f7dae778ec165596529e3cbd9123ca4b8cb4 serviroo <serviroo@rooindustries.com> fix(validation): distinguish remote deadlines from offline hosts
```

B diff since 68c154b:
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
 tools/validation/Update/run_e2e.py                  |  7 +++----
 tools/validation/Update/run_harness_checks.py       | 10 +++++-----
 tools/validation/Update/run_shipped.py              | 12 +++++++-----
 tools/validation/windows_ssh.py                     | 21 +++++++++++++++------
 15 files changed, 86 insertions(+), 38 deletions(-)
```

Own delta review found one open Medium merge blocker: generated-path handling is still inconsistent between the XAML compiler, PowerShell traversal and ledger cleanup. The final signed negative-build cache has a 264-character directory; ordinary Exists is false, extended-path Exists true, and Clear fails before mutation. Per the lead’s same-class rule I stopped further patches and retained the frame. CR7, trace ownership, logging, signatures and certificate cleanup otherwise pass. **I do not yet agree both branches are ready to merge.** The remaining fix/check is shared long-path-safe generated-work/file traversal/cleanup, followed by closing that ledger. Final report-only SHAs/clean trees: `../roo-62/slice14/final-branches.json`.
