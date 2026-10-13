# ROO-63 / ROO-64 Slice14 final report

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

Own delta review found one open Medium merge blocker: generated-path handling is still inconsistent between the XAML compiler, PowerShell traversal and ledger cleanup. The final signed negative-build cache has a 264-character directory; ordinary Exists is false, extended-path Exists true, and Clear fails before mutation. Per the lead’s same-class rule I stopped further patches and retained the frame. CR7, trace ownership, logging, signatures and certificate cleanup otherwise pass. **Slice-14 verdict (the CR8 blocker is resolved below): I did not yet agree both branches were ready to merge.** The remaining fix/check is shared long-path-safe generated-work/file traversal/cleanup, followed by closing that ledger. Final report-only SHAs/clean trees: `../roo-62/slice14/final-branches.json`.


## Slice 15: CR8 merged and retained frame closed

A commit `c91173f` was merged into B in `1ac8ea0`. The shared extended-path tree/hash/archive helpers, Linux lint, all call-site replacements and long-path fixtures are identical on both branches. B lint and changed Python syntax checks pass after the merge. Product logging/signing code, short build roots and the XAML guard are unchanged.

| Check | Observed | Pass/fail | Evidence |
| --- | --- | --- | --- |
| Final ownership checks | 43/43 including three long-path fixtures, zero skips | pass | ../roo-62/slice15/harness-last/receipt.json |
| PowerShell 5.1/native trace compile | All 14 scripts, zero errors; HarnessTrace compiled | pass | ../roo-62/slice15/harness-last/powershell-parse.json |
| Trace fixtures | 3/3 on retry; first safe refusal retained, no predicate relaxed | pass on retry | ../roo-62/slice15/trace-receipt.json; trace-first-*.json/log |
| Long ZIP | Relative JSON name/bytes verified in Windows and independently on Linux | pass | ../roo-62/slice15/harness-last/long-evidence.zip; long-zip-independent-readback.json |
| Historical signed frame closure | 31805230c2994beebc7ab152f304f221 removed in 137.017 s; 1,039 closed entries; 264-character path absent | pass | ../roo-62/slice15/frame-31805230-receipt.json; frame-31805230-closed-ledger.json |
| Final residue audit | No owned process, ledgered frame, harness task/firewall/hosts/testcert; same 160 legacy frames | pass | ../roo-62/slice15/final-audit-receipt.json |

The three data-folder files removed by the historical ledger were owned fixture/retention entries. All other 449 as-found files are byte-identical. The PC retains the stopped signed test-feed 0.11.1-beta build; governor paused/disabled. Completed installer downloads: 0. No production requests, push, publish, Blackwell/KVM contact or trust changes. Full B/published/contracts/signed gates were intentionally not rerun.

Detailed site-by-site table, failure ways, deviations, commands and artifacts: `../roo-62/slice15/report.md`. CR8 is resolved and no additional merge blocker was found in this focused self-review. The independent review/fix round and final full gate remain the lead-specified next step. Final identities/clean-tree proof: `../roo-62/slice15/final-branches.json`.


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


## Slice 18: boundary fix, final gate stopped

**Not ready to merge.** Gate heads A `0f19fd230230e5dd498c7dcb24a87b1561cf8934`, B `5bbf0369c2ddf12216b6b2f6b3bde0ecf4d1e5d5`. A's full [Slice 18 report](../roo-62/report.md) contains the audit table, fixture outcomes, repairs, commands and all evidence paths. B adds Get-ReleaseToolPath / argument validation in Build-Release/Release.Checks, native extended-path deletion, and three actual Assert-ReleasePathBound success markers. Product app code is unchanged in this slice.

| Check | Observed | Result | Evidence |
|---|---|---|---|
| Final B report-bearing staging / parse / compile | 81 PS files, zero errors; HarnessTrace compiled | pass | `artifacts/roo-62/slice18/trace2/frame.json`, `trace2/final-b-parse.json` |
| Final runner / boundary checks | 97/97; 33 new tool-boundary checks repeated in the whole suite | pass | `artifacts/roo-62/slice18/harness5/receipt.json` |
| Trace | 3/3 required + ambiguity | pass | `artifacts/roo-62/slice18/trace2/receipt.json` |
| B all 21 | Not started after P2 stop | not run | `artifacts/roo-62/slice18/gate-summary.json` |
| Contracts 25 | Not started | not run | same |
| Close-during-check exact cancellation line | Not started | not run | same |
| Normal/pair/signed/negative build path-bound execution | Logging added, runtime builds not started | unverified | `tools/scripts/Release.Checks.ps1`; same gate summary |
| Signed subset / fresh cert / governor / OTA / wrong subject | No cert created; not started | not run | same |
| Cleanup / lease / raw byte preservation | All 14 audit checks pass; no owned process/frame/cache/lease | pass | `artifacts/roo-62/slice18/cleanup-audit.json` |

P2 downloaded the exact published installer once, then Get-HarnessLongPath rejected its `:Zone.Identifier` name at the short-path GetFullPath call. Published setup never started. This is another CR8 native-path boundary issue, so the same-class stop rule controls; no product patch or ADS workaround was made. The 9070 is back on its as-found signed test-feed 0.11.1-beta, governor paused, exact data and raw tweak-registry bytes restored. Six CS2 tasks and all 160 legacy frames unchanged. No owned services/processes remain; the unrelated Linux support server is preserved. Production download count: **1 completed installer download**; publishing: **0**. Blackwell/KVM untouched. Both branches require the native alternate-stream fix and the remaining gates before merge.
