# Report privacy E2E

Run this recipe only during an explicitly granted Windows validation window. It uses the existing `windows_ssh.py interactive-frame` transport, the original staged source and creation ledger, and a preclaimed canonical host lease. It does not acquire or release that lease.

Stage tracked source with `--include-frontend`. Before invocation, the frame owner creates an empty `report-e2e-results` child with `New-HarnessDirectory` and lifetime `frame` in the original ledger. Use a fresh frame for each run. No source files may change after staging.

From Linux, pass the original receipt's source path and commit without substituting another checkout:

```bash
arguments=$(jq -c '{Source:.stagingPath,OutRoot:(.runRoot+"\\report-e2e-results"),ExpectedCommit:.sourceCommit,Scenario:"All"}' "$receipt")
python3 tools/validation/windows_ssh.py --host "$host" --expected-machine "$machine" interactive-frame \
  --receipt "$receipt" --script tools/validation/BugReportE2E/Invoke-BugReportE2E.ps1 \
  --arguments "$arguments"
```

`All` builds and runs both fixtures once. `AppLog` selects only the nine-write disk fixture; `Rendered` selects only the eight-scene WinUI fixture. The entry refuses a different commit, manifest, machine, frame, invocation context, reused output or changed source. Builds require the existing user-local .NET 8 SDK and pass `--disable-build-servers` for each build command; the rendered fixture runs on that same .NET. Rendered proof also requires the WinUI prerequisites, UI Automation and existing ffmpeg with libx264. Missing prerequisites fail the run; this recipe installs nothing.

The AppLog fixture links the actual logger and redactor. Its sole root-selection stub directs real writes into the original-owned empty leaf; current profile, user and machine values remain real, and the redactor reads the PC's real profile list. Its private receipt contains those values and the raw log bytes. Retrieve it privately. The required phase marker is `ROO_INDUSTRIES_BUG_REPORT_APPLOG_9PASS` with nine exact payloads, native exit zero and matching source, binary, sink and file hashes.

The rendered fixture links the actual page, click handlers, VM, service, parser and resources. A minimal App supplies fake Live/Operations and a FakeSender; inputs are seeded through VM properties. The fixture derives its Grid host's theme and background resource from the embedded production MainWindow source and checks that source's hash against the original build. Every checkpoint and final receipt compares the actual inherited theme and shared brush with the staged source; this still does not prove production startup. It never starts the production app, calls a real backend or HTTP sender, enables AppLog, or opens Explorer. It captures eight scenes in order, top and bottom, with sixteen unique checkpoint acknowledgments, UIA receipts, sixteen PNGs and a ten-second owned-window H.264 video in limited-range yuv420p. The required phase marker is `ROO_INDUSTRIES_BUG_REPORT_RENDERED_8COMPLETE`. Screenshot and video review by the lead and Sol remains a separate approval step.

The two populated flows each seed Description with CRLF, CR, then LF through the actual VM and bound TextBox. Only Description comparisons treat those line endings as equivalent. Every other code point, line order, blank line and field stays exact; raw captured values and hashes are kept unchanged.

Each scene/view publishes its own closed `<scene>-<view>-checkpoint.json` without overwriting another checkpoint. The harness reads only the next known path and keeps its immutable capture copy in the separate capture root. Each ack and owner release is written to an original-owned pending file, closed, checked, then moved into place without overwrite. Original ledger file IDs and raw hashes must survive publication. C# file-exchange reads share read and delete access, without write sharing, so the original ledger probe can stay open while the fixture reads. Require sixteen unique checkpoint/ack pairs and all source, state, UIA and capture checks before completion. Native sharing and publication behavior still require Windows proof.

Retrieve `report-e2e-results`, build bindings, private disk evidence, UI evidence and `capture` before cleanup. Admission requires the entry marker `ROO_INDUSTRIES_BUG_REPORT_E2E_COMPLETE`, original wrapper exit zero, the exact engine/source/completion evidence, `done.json` pass and a bound final receipt with all selected phase, raw-output and invocation-cleanup evidence. Both visual approvals and the later original whole-frame cleanup/release are also required. A ledger pass alone proves nothing. A receipt write or registration failure fails the invocation and emits no completion marker; even a partial receipt containing `passed=true` cannot pass admission. The final receipt distinguishes selected and unselected phases and records source, manifest, binary, frame and invocation identities. UI nonce equals the original frame ID; it does not replace the invocation nonce.

The entry stops only original-owned process handles, preserves frame-lifetime evidence, checks immutable source and the existing lease again, and completes invocation cleanup. The frame owner then runs the existing `tools/validation/Update/Clear-UpdateFrame.ps1` through the original ledger after retrieval. The entry never deletes the frame or releases the whole Windows window.

Production startup, root bootstrap/migration, live delivery and all Windows normal/adverse behavior remain unproved by Linux compilation or static checks. The actual duplicated-writer reader adverse E2E is authored below and remains unrun; an inherited launch is not claimed. This recipe is not permission to contact or wake a host, run the default AppSweep suite, or use an ungranted desktop session.

## Explicit duplicated-writer mode

The default recipe above remains the normal proof class. A separately authorized invocation may add `ReaderAdverse:true` to its JSON arguments. Each selected real phase then gets one fresh original-owned holder. `Rendered` also builds the AppLog executable solely as its holder helper; it does not run the nine-write disk scenario. `All` builds each project once and runs each selected phase once. There are no retries or ambient-environment switches.

The actual fixture parent duplicates its real stdout and stderr writer handles into that holder, after validating its source, frame, nonce, birth, image and original ready-file hash. The adverse phase reads that ready record while a native READ|DELETE access handle is live; actual Windows proof remains unrun. This reproduces live writer references after parent exit; it does not claim an actual inherited launch. The holder performs no logging, backend, network or UI work and expires after at most 420 seconds. Expiry never passes. Both original phase stream readers must remain incomplete during a real ten-second wait after parent exit 0. The shared guard validates the actual duplication receipt and compiled parent assembly, stops only the retained original holder, and requires real EOF on both tasks within five seconds. Existing nine-write or eight-scene/sixteen-checkpoint assertions still run against the actual returned streams.

The adverse entry marker is `ROO_INDUSTRIES_BUG_REPORT_READER_ADVERSE_COMPLETE`, never the normal completion marker. Require one consumed reader proof per selected phase, actual parent exit 0, original holder/file identities, source/manifest/nonce bindings, both wait results/timings, actual pipe/duplicate flags, stream hashes and original-holder cleanup. Its receipt records `normalStreamCompletionProved=false`. Normal runs strip inherited injection and make no adverse claim; builds and media commands never receive it.

The holder first publishes a closed `ready-staged.json`. The original owner verifies it while final readiness is absent, then publishes a closed `release-ready.json` bound to the source, nonce, PID and staged hash. The holder validates that acknowledgment before renaming the same staged file to `ready.json`. Both moves must preserve the original file ID and raw ledger hash; content digests use validated lowercase copies without changing ledger identities. Native ordering and identity proof remain unrun.

Ready/release/attached evidence remains in the original frame's `reader-applog` or `reader-rendered` leaf. Retrieve it with the existing phase evidence before original-ledger cleanup. Every holder receipt is retained before readiness and cleaned through its original handle in the entry's final path, including phase failures. No file/process adoption, PID search, generic kill, global environment change or new lease is permitted. Both normal and adverse Windows runs, reader effectiveness, WinUI/media and visual inspection remain unrun by Linux preparation. This mode grants no host or power permission; later full-window coordination, original frame cleanup and any required original-owned GPU busy marker remain the frame owner's responsibility.

## Attachment refresh and retries

The eight scenes are `offline-empty`, `offline-attached`, `offline-saved`, `online-rate-limited`, `online-offline`, `online-failed`, `online-fallback-saved` and `online-sent`. The five online scenes share one actual page, VM, service and outgoing attachment. Each send changes the bound Processor value before the actual Send click. The fake sender captures the actual ZIP path, ZIP bytes and payload before returning or throwing; it never makes an HTTP request.

| Send | Outcome | CPU suffix | Fixture UTC | Result |
| --- | --- | --- | --- | --- |
| 1 | RateLimited | ` \| rate-limited` | 01:02:03 | 429 with RetryAfter 120 seconds; refreshed attachment retained |
| 2 | Offline | ` \| offline` | 01:04:04 | HttpRequestException after capture; refreshed attachment retained |
| 3 | Rejected | ` \| rejected` | 01:04:04 | Immediate retry returns 404; refreshed attachment retained |
| 4 | Sent | ` \| later` | 01:05:05 | Later 200 deletes the outgoing ZIP and resets the report fields |

All fixture times use 2026-10-21 UTC. Only the service's captured fixture clock advances, by 121 seconds before Offline and 61 before the later send. Offline to Rejected has no clock advance. This is fixture time, not elapsed native timing proof. The actual phase, UI acknowledgment, reader and recorder timers keep their existing bounds. Save runs between Rejected and Sent, writes the current redacted ZIP and report to `failed\reports\saved`, and must preserve the refreshed record and original outgoing bytes.

The native final JSON requires `ROO_INDUSTRIES_BUG_REPORT_ATTACHMENT_REFRESH_COMPLETE` and exactly four `attachmentRefresh` rows in RateLimited, Offline, Rejected, Sent order. Read-only reflection observes the actual private VM attachment record before each send and after each outcome. The VM passes that field directly to the real service. This observation and the captured sender bytes are the proof seam; the fixture does not intercept service method arguments.

Each row keeps immutable BEFORE ZIP, SENT ZIP and payload files, their SHA256 hashes and lengths, record fields and reference comparisons, current labels/status, and fixture time. The three retained outcomes require a different record with the same path and the actual refreshed size. Every next send must use the prior refreshed record. Original, before-send and prior-outcome ZIP hashes cannot pass as current sender bytes. Sent requires a null after-record and retained hash, no outgoing file, and the existing successful reset. The PowerShell consumer registers and copies the raw evidence through the original ledger, parses each ZIP and payload against independent CPU/privacy expectations, and compares the retained bytes with both real checkpoint captures. Both normal and separately authorized reader-adverse runs require these checks.

The new eight-scene, sixteen-checkpoint, three-retained-outcome and four-send retry/later proof is authored and **UNRUN**. Linux syntax or semantic compilation does not prove the desktop, native record updates, media, reader behavior or cleanup. The AppLog contract remains nine payloads.
