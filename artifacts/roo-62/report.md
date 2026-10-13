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
