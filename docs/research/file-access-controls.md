# Reversible file access controls

A native deny-ACE transaction is viable for the tested NTFS fixtures. **26 checks passed on the verified 9070XT**, including byte-exact DACL restoration, unchanged owner/control flags, existing-rule preservation, drift/replacement rejection, and reparse-point rejection. These checks establish the file-access primitive; they do not establish that changing an ACL permanently disables a real vendor installer or Microsoft Store behavior.

The prototype ran at **2026-09-19 17:25:59 UTC**, on `SERVI-WINDOWS-D`, Windows build `10.0.26200.0`, NTFS. It used only newly created paths beneath a uniquely named temporary directory. Actual Store, Razer, Logitech, system and user targets were untouched. No registry, service, task or network configuration was changed. The final fixture tree and staging directory were removed, and a subsequent process check found no owned prototype process.

## Pinned source behavior

| WinUtil control | File operation | Source undo problem |
| --- | --- | --- |
| Store recommended search results | Deny Everyone Full Control on the selected user's Store `LocalState\store.db` | Grants Everyone Full Control without removing the deny |
| Razer automatic installation | Create the installer directory if absent; otherwise delete its contents; deny Everyone Write on the directory | Removes all explicit Everyone deny entries, including any that predated WinUtil |
| Logitech Download Assistant | Stop the matching process, create/empty its download folder, deny Everyone Write | Does not restore deleted content/process state and broadly removes Everyone deny entries |

The tested access-control transaction intentionally preserves contents. File deletion and process termination are separate actions, not requirements for adding a deny ACE. [Pinned Store definition](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/config/tweaks.json#L96), [Razer definition](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/config/tweaks.json#L963), [Logitech definition](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/config/tweaks.json#L1004).

## What the native prototype does

The private C# helper opens the exact fixture with native file APIs, retains the handle, and captures volume/file identity plus creation time. It reads owner, group and DACL through `GetSecurityInfo`, retaining original DACL bytes, owner SID and descriptor control flags. It adds a single non-inheriting explicit deny ACE to the existing raw ACL, preserving every original ACE. It writes only the DACL through `SetSecurityInfo`; owner, group and SACL are not written. [File identity API](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-getfileinformationbyhandle), [security descriptor APIs](https://learn.microsoft.com/en-us/windows/win32/secauthz/security-descriptor-operations).

The new explicit deny is placed before existing ACEs, respecting the preferred explicit-deny-before-allow order. A fresh readback must contain exactly the original ACL plus that one ACE, with the original owner and control flags. Windows does not automatically reorder the ACL supplied to `SetSecurityInfo`, and inheritable entries can propagate to children; these facts are why this prototype uses a non-inheriting ACE and checks the full resulting DACL. [ACE ordering](https://learn.microsoft.com/en-us/windows/win32/secauthz/order-of-aces-in-a-dacl), [SetSecurityInfo behavior](https://learn.microsoft.com/en-us/windows/win32/api/aclapi/nf-aclapi-setsecurityinfo).

Restoration first checks that the path still identifies the same object and that its current descriptor matches the transaction's applied descriptor. It removes exactly the inserted ACE and requires the remaining DACL to equal the original bytes. It then writes that DACL and verifies owner, DACL and control flags. An identical pre-existing ACE is treated as no owned mutation; restoration leaves it intact. Different pre-existing Everyone denies are preserved.

An ACL has no application-specific ownership tag. Ownership is established by the saved before/after state and the exact added ACE, not just a SID. Broad `RemoveAccessRuleAll`/`icacls /remove:d` behavior is therefore unsuitable. Multiple Roo Industries presets requesting the same restriction must share one transaction/owner count; releasing one preset must not remove an ACE still required by another.

## Actual checks

| Case | Executed result |
| --- | --- |
| Everyone Full Control deny on a file | New ordinary read and write opens both failed with Win32 error **5** |
| Exact restoration of that file | Original DACL bytes, owner and control flags matched; original content remained readable |
| Non-inheriting directory Write denial | Creating a new file failed; existing child ACL bytes stayed unchanged |
| Existing child writes | Remained possible; parent-only Write denial does not block every operation on existing children |
| Existing different Everyone deny | Survived apply and exact restore |
| Existing identical deny | Not claimed or removed by the new transaction |
| Foreign ACL edit before apply | Rejected before mutation |
| Foreign ACL edit after apply | Restore returned `DescriptorConflict` and left the edited descriptor unchanged |
| Owner edit after apply | Restore returned `DescriptorConflict` without changing the new owner |
| Path replacement before apply | Rejected before mutation; both objects' descriptors were preserved |
| Path replacement before restore | Restore returned `IdentityConflict`; the replacement file/content/ACL stayed unchanged |
| Originally absent empty directory | Created fixture, applied/restored restriction, then removed only the empty owned directory |
| Created directory gaining content | Cleanup eligibility rejected; new content preserved |
| Junction as selected target | Rejected; junction destination ACL remained unchanged |
| Junction in an ancestor path | Rejected before mutation |
| Protected DACL | DACL bytes and protection/control flag restored exactly |
| Already-open writable file handle | Remained writable after the full deny, while new ordinary opens were rejected |
| Source-style grant as undo | New read still failed with error **5**; original DACL was not restored |
| Source-style remove-all-denies as undo | Lost a pre-existing deny; original DACL comparison failed as expected |

The two deliberately wrong undo cases are negative controls. Their test assertions require the bad undo to fail the intended recovery property. They were then cleaned up using the retained fixture handle and original DACL. No weakened assertion turned those bad operations into a successful restoration.

## Rights-mask findings

The explicit Full Control deny mask was `0x001F01FF`. The narrower file-specific Write mask was `0x00000116`. On this machine, applying the source's actual `icacls /deny *S-1-1-0:(W)` to a disposable reference file produced **`0x00100116`**, which additionally denies `SYNCHRONIZE`.

Both directory masks blocked new-file creation and allowed exact ACL restoration in the fixtures. The source-style mask also caused an ordinary generic-read open on the reference file to fail with error 5. That is consistent with Microsoft's explanation that generic read and generic write both request `SYNCHRONIZE`, so denying that shared right can deny both forms of access. The native implementation must select and label a precise mask; “Write blocked, reading unaffected” is not true of the measured source mask. [Microsoft file-rights contract](https://learn.microsoft.com/en-us/windows/win32/fileio/file-security-and-access-rights).

For an independently implemented download-folder control, the tested `0x00000116` mask avoids the source's extra synchronize denial, but it is an intentional behavior difference. It preserves existing child data and does not establish complete vendor-installation prevention. A stricter existing-tree restriction would need individually reviewed child targets and individual snapshots; it should not silently inherit denies or delete contents to obtain a stronger result.

## Target-specific privilege finding

The initial access probe used `FILE_FLAG_BACKUP_SEMANTICS`. The 9070XT SSH process token had both `SeBackupPrivilege` and `SeRestorePrivilege` enabled, so that probe could still open the denied fixture. The incorrect assumption was that it represented an ordinary application open. The failed attempt is retained as evidence; the corrected ordinary-file probe removed backup intent and produced the expected access-denied result.

Microsoft explicitly documents the backup/restore privilege path that can override ordinary file ACL checking. The descriptor read/write helper may need this path for recovery, but the effective-access test must use the intended caller's ordinary access semantics. An administrative backup-style open is not proof that the deny ACE failed, and an ordinary denied open is not proof that a privileged installer cannot bypass it. [File backup access](https://learn.microsoft.com/en-us/windows/win32/fileio/file-security-and-access-rights), [privilege inspection](https://learn.microsoft.com/en-us/windows/win32/secauthz/privileges).

## Implementation contract

1. Resolve an allowlisted target from the initiating user's SID/profile or verified system path. Do not use an elevated helper's own LocalAppData for Store. Inspect the target and each ancestor for reparse behavior.
2. Open the object and retain its identity and handle for the transaction. Capture the exact descriptor before any write and durably persist it outside the target. Do not take ownership merely to simplify ACL access.
3. Capture whether a directory was newly created by this transaction. Use atomic creation results; a prior `Test-Path` check followed by `CreateDirectory` is not proof that the app created the directory.
4. Revalidate target identity and descriptor immediately before apply. Add only the reviewed non-inheriting ACE. Preserve an identical pre-existing restriction as externally owned/no-op state.
5. Read back the complete expected DACL and owner/control flags. Report the actual covered access rights, not an untested product-level “installation disabled” state.
6. On restore, refuse replacement or descriptor drift. Remove only the owned ACE and verify exact original DACL/owner/control flags. Never add Everyone Full Control or remove every Everyone deny as a substitute.
7. Delete an app-created directory only after successful restoration, only if still the same object, and only if empty. Use object-bound deletion or a validated no-replacement design in production. A nonempty directory is retained.

`CreateDirectoryW` distinguishes a newly created directory from an existing path. Windows also provides handle-based file-information/deletion operations; these are relevant to closing the prototype's path-based cleanup race. [Directory creation](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-createdirectoryw), [handle-based file information](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-setfileinformationbyhandle).

## Explicit limits

The prototype is not a production transaction engine. Its journal lives in memory until results are written. Crash/restart recovery, concurrent third-party ACL writes between comparison and write, atomic path traversal, and race-free empty-directory deletion were not proven. Windows ACL APIs do not supply an automatic compare-and-swap around this read/modify/write sequence. The retained handle protects which object is modified, but production must still validate the resolved path/ancestor contract and persist recovery state.

Only NTFS was tested. ReFS, network filesystems, cloud placeholders, hardlinks, unusual/null DACLs, recursive inheritance changes and actual Store/installer behavior were not tested. SACL preservation follows from not writing SACL security information; the test did not read and compare SACL contents. File identity based on the tested NTFS handle information must not be assumed equivalent on every filesystem.

A deny ACE does not revoke already granted open handles. A non-inheriting parent ACE does not rewrite child ACLs. Path replacement is a detected conflict, not a reason to apply an old snapshot to a new file. These limits must remain visible in the native control's status and recovery behavior.

## Evidence

Private prototype and evidence directory:

`/home/serviroo/.local/share/LeanClientOptimizer/work/four-tool-tweaks-20260919/acl-prototype/`

- `PrototypeAcl.cs`: throwaway native/.NET prototype, SHA-256 `33e5226ffc517253360b68be491866d395f5c0a1a9783402d544bb08af4ccbbe`.
- `run.ps1`: controlled fixture sequence, including the two wrong-undo counterexamples.
- `result.json`: final 26 passing checks, SHA-256 `1c901e0d486d5e5fca3d75fcf0aba1a32651c557b3764146ef8bff7f2c2642b9`.
- `result-attempt1.json` and `result-attempt2.json`: original unsigned-literal harness error and backup-intent access-probe failure; their fixture stages were cleaned.
- `result-attempt3.json` and `result-attempt4.json`: preceding successful scopes before the additional contract cases.
- `token-privileges.csv`: read-only evidence for the observed backup/restore token behavior.
- `cleanup-final.json`: fixture/stage absence and no owned process on the verified target.
- `manifest.json`: hashes of retained local artifacts.

The companion private `file-access-contracts.json` summarizes masks, proved behavior and unproved cases. No production backend/frontend files were changed. The prototype itself remains outside the repository.
