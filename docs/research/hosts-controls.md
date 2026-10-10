# Hosts block-list control and recovery prototype

Research date: 2026-09-19. Question: can Roo Industries add a reviewed domain block list and remove its own changes while preserving every unrelated byte, including edits made afterward? The private prototype answers the byte-editing and transaction-state question. It does not modify production backend code, the system hosts file, DNS configuration or resolver caches.

## Pinned input and validation

WinUtil commit `fc60cbde09d669178bda1665be9cb1a703516fca` points to a moving external hosts URL. The retrieved list was separately pinned to commit `3cba6db8b7cf53a270ce7357ed711dd0a5aa7898`, with 31,573 bytes and SHA-256 `faf1a5d8fd409647af8e419f1743d98d875403c8169da6f8db4896ad6727dacb`. [WinUtil definition](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/config/tweaks.json#L1062), [pinned external data](https://raw.githubusercontent.com/Ruddernation-Designs/Adobe-URL-Block-List/3cba6db8b7cf53a270ce7357ed711dd0a5aa7898/hosts).

The source has 948 active records. Strict review accepts **898 hostnames** and rejects 50 records: 49 IP literals in the hostname position and one trailing-dot entry whose canonical name already appears separately. These rejected lines are listed individually in `source-review.json`; the raw download is never silently treated as clean input. Hosts mappings resolve names to addresses; putting an IP literal in the name field does not establish a destination-IP firewall block. [Microsoft hosts format](https://support.microsoft.com/en-us/windows/experience/how-to-reset-the-hosts-file-back-to-the-default).

The reviewed normalized payload is 29,613 bytes, SHA-256 `cdd0b8a98ef32bba48e0c76c37028c5770049e2401df316e6cd7c25f85c906d5`. It contains only generated `0.0.0.0 hostname` records. The parser rejects localhost/local-network names, redirects to unapproved addresses, wildcard names, URL syntax, malformed labels, active HTML/script content, invalid encodings and oversized data. It imports no downloaded comments or commands. Duplicate accepted names are compared case-insensitively and emitted once.

## Owned section

The block uses these exact marker families, with a unique transaction ID and payload hash:

```text
# BEGIN Roo Industries hosts adobe-v1 <transaction> payload=<sha256>
...
# END Roo Industries hosts adobe-v1 <transaction>
```

Insert the block **at the beginning, immediately after an optional UTF-8 BOM**, with a complete ending newline. Retain the entire original byte sequence after it. This avoids adding a separator to an original file that lacks a final newline, eliminating ambiguity about which newline should be removed during undo.

Existing comments, spacing, mixed CRLF/LF/CR endings, BOM and final-newline absence remain byte-for-byte intact. The generated block uses the dominant existing newline convention, defaulting to CRLF. Non-ASCII bytes in existing comments are retained without decoding/re-encoding the entire file. Unknown active syntax and UTF-16/NUL-containing files are rejected unchanged. This is an explicit supported-input boundary; the prototype does not silently convert encodings. Windows PowerToys documents UTF-8 and optional UTF-8 BOM as hosts-editor choices. [PowerToys hosts editor](https://learn.microsoft.com/en-us/windows/powertoys/hosts-file-editor).

Before insertion, inspect existing active mappings. A matching hostname already mapped exclusively to `0.0.0.0` is retained outside the block and omitted from the generated records. Any different existing address, including an IPv6 mapping, is a conflict requiring resolution. The operation never takes ownership of a pre-existing user's entry.

## Recovery behavior

| State | Result |
| --- | --- |
| Original unchanged since preview | Apply the exact reviewed bytes and retain the first backup. |
| File or reviewed plan hash changed | Reject before mutation. |
| Same transaction already applied | Do not append another block or overwrite its backup. |
| Owned block intact; outside bytes changed | Remove only the exact owned span; preserve all outside edits. |
| Owned block edited, missing or duplicated | Preserve current file and recovery record; no guessed deletion. |
| Restore already completed | Release remains recorded; later outside edits are preserved. |
| Failure after applying an intact block | Remove that block, retaining any intervening outside edits. |

The journal binds original bytes/hash, desired bytes/hash, exact block bytes, transaction ID, source hash and reviewed-payload hash. A caller-provided review hash must match the recomputed complete plan. Recovery checks journal integrity before using it. Blindly copying the full original file back would erase later edits; an independent test demonstrates that wrong result and verifies the span-based removal.

For source updates, create a new review against the existing owned block and retain the first original baseline. Cross-preset ownership belongs in the shared resource journal; this private prototype models one owner and refuses a different transaction trying to claim its fixture.

## What was exercised

Run the private prototype with:

```text
python3 <private work folder>/four-tool-tweaks-20260919/winutil/hosts-prototype/test_hosts_prototype.py
```

**32 checks passed**, including the full 898-host payload, exact round trips, mixed encodings/newlines, missing final newline, additions before/after the block, edited unrelated comments, duplicate/conflicting records, malformed source, stale/tampered review, repeated apply/undo, changed markers, corrupt journal, injected failures before/after replacement and recovery after reopening the journal. File mode is preserved in the Linux fixtures. Symlinks, hard-link aliases and paths outside the private fixture root are rejected.

Evidence is in `test-evidence.json` and `test-output.txt`; source decisions are in `source-manifest.json` and `source-review.json`. The private fixture directory is empty after the run. No Windows or system hosts write was performed.

## Production writer requirements

The prototype uses same-directory staged files, fsync, hash rechecks and replacement for private Linux fixtures. It does not prove Windows file sharing, DACL preservation, alternate streams, power-loss recovery or serialization against an arbitrary external writer racing after the final comparison. Those remain explicit integration checks.

The Windows writer must preserve file security/attributes, retain a durable backup/journal before mutation, prevent or detect competing writes, and reread actual results. `ReplaceFileW` preserves several original attributes and DACLs when its normal merge succeeds, but has distinct partial-failure states; inspect paths and content after errors rather than assuming either original or replacement remains in place. Do not ignore ACL-merge errors to claim success. [ReplaceFileW contract](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-replacefilew).

## Upstream actions not required for correct ownership

Downloading a moving branch during apply and appending the entire response are unnecessary: use the reviewed, hash-bound hostname payload. The upstream regex deleting everything from a version marker through end-of-file is unnecessary and cannot provide exact undo. Re-encoding the whole file or removing pre-existing entries is likewise unnecessary.

A DNS-cache refresh is a separate activation action after a verified hosts change; it is not part of byte restoration and was not executed by this prototype. Running the external repository's scripts is unnecessary. Invalid IP-alias lines should remain accounted for as excluded source records rather than silently becoming firewall rules or a claimed IP-blocking feature.

## Windows native writer investigation

A second private prototype ran on the verified the i5-14600K test PCXT at **2026-09-19 18:06:31 UTC**, Windows `10.0.26200.0`, NTFS. It completed **23 assertions and two metadata observations, with zero failures**. Every target was a newly created temporary file. No system hosts file, registry, DNS cache or network setting was touched. Fixtures/staging were removed and a follow-up check found no owned process.

`ReplaceFileW` solves the particular reader-sharing problem, but it does **not** provide conditional replacement of the file identity inspected during preview. For the hosts ownership contract, prefer a held-handle in-place writer with a durable before/after journal. Keep sharing failures explicit instead of quietly switching to pathname replacement.

### Replacement and sharing results

| Controlled case | Result |
| --- | --- |
| Target held for `GENERIC_READ`, sharing `FILE_SHARE_READ | FILE_SHARE_DELETE`, without `FILE_SHARE_WRITE` | `ReplaceFileW` succeeded, Win32 `0` |
| Same reader; attempt to open an in-place read/write handle | Failed with Win32 **32**, sharing violation, before any write |
| Reader sharing only read, without delete | `ReplaceFileW` failed with Win32 **32**; original and replacement bytes/names stayed intact; no backup appeared |
| Ordinary handle rename with a target reader denying delete sharing | Failed with Win32 **5**; target/source unchanged |
| POSIX handle rename under that same target-reader sharing restriction | Failed with Win32 **32**; target identity/content unchanged |
| Ordinary and POSIX handle rename without that reader | Both succeeded in their separate baseline controls |
| Target held read/write with share-read only | Competing ordinary write-open and rename both failed with Win32 **32** |

These are different API error surfaces, not generic elevation failures. The source-target fixture had valid permissions; changing only the relevant sharing condition produced the successful baselines. The caller's actual token/privileges are not evidence that Windows sharing restrictions can be bypassed.

The results agree with Microsoft's `ReplaceFileW` contract: the replaced file is opened for read/delete/synchronize with read/write/delete sharing. A reader that grants delete sharing can coexist even if it denies write sharing. The replacement file has its own access and sharing requirements. [ReplaceFileW](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-replacefilew), [CreateFile sharing](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-createfilew).

### Metadata, security and stream results

The controlled target and replacement deliberately had different owner SIDs, file IDs, timestamps and alternate-stream contents.

| Property | Observed after `ReplaceFileW` |
| --- | --- |
| Main contents | Replacement bytes |
| Original backup | Original bytes and original file ID |
| Previously open reader | Still read original bytes through its original file ID |
| Result file ID | **Replacement file's ID**, not the original target ID |
| DACL | Original DACL bytes preserved, including its protected state |
| Owner | **Replacement file's owner**, different from original target owner |
| Creation time | Original target creation time preserved |
| Hidden/archive flags in this fixture | Original flags preserved |
| Last-write timestamp | Not preserved as original |
| Original-only alternate stream | Preserved |
| Same-named alternate stream in both files | Replacement stream won |
| Replacement-only alternate stream | Retained |

Microsoft's preservation list specifically includes DACLs and original streams absent from the replacement. It also explicitly states that the resulting file has the replacement's file ID. The documentation's separate object-identifier concept must not be confused with that file ID. The prototype did not test EFS, compression, short names, object identifiers, SACLs or security resource attributes. [Replacement preservation contract](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-replacefilew).

A staged file with accidental alternate streams can therefore override original stream contents. Simply saying that replacement “preserves ACLs and metadata” would also hide the owner change observed here. Do not enable merge/ACL-error ignore flags to turn a preservation failure into reported success. `REPLACEFILE_WRITE_THROUGH` is documented as unsupported; it is not a durable-commit switch.

### Reproducible target-identity race

The prototype used a controlled interleaving rather than a timing-dependent stress test:

1. Open and inspect the original target, retaining its read handle and file ID.
2. Rename that original away using its permitted delete sharing.
3. Create a different file at the same target name.
4. Call `ReplaceFileW` with the original target pathname.

Replacement succeeded and replaced the intervening file. Its backup contained the intervening bytes, while the held original handle still read the original object. Thus a successful identity/hash check followed by pathname replacement can overwrite a different file. A post-write check may detect the mistake, but it does not make the previous overwrite conditional or harmless.

A relative destination directory handle does not solve this. `FILE_RENAME_INFO`/`FILE_RENAME_INFORMATION` identifies a source handle and destination directory/name with a replace-if-present choice; neither includes an expected destination file ID. The relative Win32 wrapper call returned **87** on this machine, including after checking buffer layout. The native `NtSetInformationFile` relative-directory call succeeded with **NTSTATUS `0x00000000`** and reproduced the same intervening-name replacement. The native call was an isolated contract experiment, not a dependency recommendation for the production writer. [Win32 rename information](https://learn.microsoft.com/en-us/windows/win32/api/winbase/ns-winbase-file_rename_info), [native rename information](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/ntifs/ns-ntifs-_file_rename_information).

These APIs cannot, by themselves, express compare-destination-identity-and-replace. This is a scoped conclusion about the tested APIs and their documented operands, not a claim that every possible filesystem/driver/transaction design has been exhausted. Holding the destination without delete sharing prevents the tested replacement routes, including this POSIX rename case, but then the app's own replacement call cannot simply proceed through that guard either.

### Held-handle in-place protocol

The tested alternative opens the existing file read/write and grants only share-read. It reads and writes through that same handle. It keeps the original file ID, owner, DACL, creation time and alternate stream; timestamps associated with actual data changes may update normally.

The production protocol should be:

1. Acquire the target handle with read/write access, refusing reparse or unexpected target identity. Deny competing write/delete sharing for the mutation interval. A reader that did not allow write sharing produces a retryable sharing violation before mutation; wait within a bounded policy or report the precise in-use condition. Do not force-close foreign handles.
2. Read the authoritative bytes through that handle and validate the review/journal identity. Produce desired bytes using the existing owned-span algorithm, preserving permitted outside edits. Do not reopen the pathname to perform the write.
3. Persist and flush a journal containing target identity, operation/transaction identity, exact current-before bytes and hash, exact desired bytes and hash, lengths and pending phase. This per-write before image is separate from the first ownership baseline.
4. Write the desired bytes sequentially from offset zero **without first truncating or pre-extending the file**. Check each API result/byte count. Keep the original tail until the complete desired prefix has been written and flushed.
5. Set end-of-file to the desired length, flush again, reread through the same handle and require exact desired bytes. Persist the committed journal state before releasing the mutation lock/handle.
6. After an interrupted operation, reacquire the intended object, verify its identity and journal integrity, and classify the actual bytes before deciding to finish or undo that pending write.

`WriteFile`, `SetEndOfFile` and `FlushFileBuffers` have separate failure contracts; return values must be checked individually. Pre-extending with `SetEndOfFile` introduces unspecified gap bytes and complicates recovery unnecessarily. [WriteFile](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-writefile), [file-length changes](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-setendoffile), [buffer flushing](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-flushfilebuffers).

### Prefix recovery model and executed cases

Let `B` be the exact bytes immediately before this write, `D` the desired bytes, and `k` the successfully written prefix length. Before final truncation, a recognized sequential-prefix state is:

- Length `max(len(B), k)`.
- Bytes `[0:k]` equal `D[0:k]`.
- If `k < len(B)`, the remaining bytes equal `B[k:]`.

Classify exact `B` as before, exact `D` as after, and a matching intermediate prefix as an interrupted pending write. Any other bytes, changed file identity or invalid journal are a conflict. Prefix recognition is a state match, not proof that no outside actor has ever written coincidentally identical bytes.

The Windows prototype wrote and flushed seven new bytes over a longer old file, closed the handle, reread the persisted journal, reopened the file and recognized the interrupted state. It also recognized a fully written new prefix with the old tail still present before truncation, and an actual extending-write prefix longer than the original file. Completing and then restoring the fixture preserved the original file identity and exact contents. An unrelated edit was rejected as a conflict.

For rollback of an interrupted write, restore the journal's immediate `B`, not a stale installation-era backup. For normal removal of the owned hosts section after later outside edits, first compute a new before/desired pair using span-based removal. The writer protocol must not undo the previously established outside-edit preservation contract.

### Limits and evidence

In-place writes are not atomic snapshots for concurrent readers. Suitably sharing readers may observe a partial state, and other readers may fail sharing while the writer is active. Memory-mapped writers, real power loss/torn sectors, hardware cache ordering, antivirus behavior, and real hosts-file permissions were not tested. A power-loss result outside the recognized prefix model must remain a recovery conflict with retained evidence; it must not trigger blind replacement. The persisted prototype journal was reopened, but the production authenticated journal and full restart/recovery lifecycle remain integration requirements.

`ReplaceFileW` partial failures `1175/1176/1177` were documented but not deliberately injected. Depending on the code and backup option, names/content/merged metadata can differ after failure. Inspect actual state instead of assuming that every failed call leaves the original path unchanged. [Failure contract](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-replacefilew).

Private evidence:

`<private work folder>/four-tool-tweaks-20260919/hosts-writer-prototype/`

- `PrototypeWriter.cs`, SHA-256 `5053643c1bc98de35dd5cb56eb2b3f057e80bf11b774a17155af2c2f260fe830`.
- `run.ps1` and `run_remote.py`: fixture-only orchestration.
- `result.json`, SHA-256 `2e4537227aaae135175a99e60fa82a2c86862650efafaa5dc00a336d6eba51a9`: 23 passing assertions and two observations.
- `result-attempt1.json`: initial relative Win32 rename error 87.
- `result-attempt2.json`: over-specific expectation of error 32 for ordinary handle rename; the actual error was 5. The final assertion checks failure **and unchanged target/source**, with a successful no-reader baseline.
- `result-attempt3.json`: preceding successful scope before the full-prefix/pre-truncation and physical extension cases.
- `cleanup-final.json`: verified temporary fixture/staging absence and no owned process.

`hosts-writer-evidence.json` beside the prototype directory contains the complete summarized result. This investigation appended research only; production backend/frontend files were not edited.
