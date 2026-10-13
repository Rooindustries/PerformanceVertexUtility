# ROO-62 Slice14 final report

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
