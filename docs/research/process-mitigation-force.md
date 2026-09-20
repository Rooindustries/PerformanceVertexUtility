# Process mitigation state and override restoration

Checked on 2026-09-20 against Microsoft documentation and the signed ProcessMitigations module installed on `SERVI-WINDOWS-D`. This investigation used read-only SSH and local static inspection; it did not change mitigation, registry, service, or running-process configuration.

`BottomUp` and `OverrideBottomUp` are independent values. For scalar commands, select `-Enable` or `-Disable` from the saved mitigation state and lowercase `-Force 'on'` or `-Force 'off'` from the saved override Boolean. `-Force 'notset'` preserves the existing override; it does not clear the flag or restore the mitigation to `NOTSET`. The installed implementation applies Force to selected entries in either list. Both the scalar and XML setters save unrelated groups; native per-group setters also impose state coupling. The final raw-slot contract below supports an existing exact registry transaction while preserving unselected bits. This layout is pinned to the inspected binaries, not a publicly documented Microsoft mitigation ABI. [Installed Microsoft implementation](#installed-implementation)

| Saved state | Saved override | Parameters for BottomUp | Evidence and limit |
| --- | --- | --- | --- |
| `ON` | `false` | `-Enable BottomUp -Force 'off'` | Managed state `1`, force bit clear |
| `ON` | `true` | `-Enable BottomUp -Force 'on'` | Managed state `1`, force bit set |
| `OFF` | `false` | `-Disable BottomUp -Force 'off'` | Managed state `2`, force bit clear |
| `OFF` | `true` | `-Disable BottomUp -Force 'on'` | Managed state `2`, force bit set |
| `NOTSET` | `false` | Explicit XML `BottomUp="notset" OverrideBottomUp="false"` | Native ASLR writer clears state and force bits |
| `NOTSET` | `true` | Explicit XML `BottomUp="notset" OverrideBottomUp="true"` | Native ASLR writer clears state bits and sets the independent force bit |

Add `-System` for the system policy. These are parameter contracts, not evidence that all rows have been executed against Windows.

## Microsoft documentation

The cmdlet declares Force as a string accepting `on`, `off`, and `notset`; a Boolean is invalid. Its documented description mentions the Enable list, but the installed implementation also handles Disable. Documentation suggests `-System -Remove -Disable <name>` for default restoration; the installed native implementation rejects the buffer passed by this cmdlet, as detailed below. [Set-ProcessMitigation](https://learn.microsoft.com/en-us/powershell/module/processmitigations/set-processmitigation?view=windowsserver2025-ps)

System `NOTSET` means Windows' default applies; app `NOTSET` means the system setting applies. It does not mean the effective protection is off. [Customize exploit protection](https://learn.microsoft.com/en-us/defender-endpoint/customize-exploit-protection#powershell-reference)

`Get-ProcessMitigation -System` reads the stored system defaults. It does not establish the effective mitigation state of existing processes. [Get-ProcessMitigation](https://learn.microsoft.com/en-us/powershell/module/processmitigations/get-processmitigation?view=windowsserver2025-ps)

## Installed implementation

The live module is version `1.0.12`; `Microsoft.ProcessMitigations.Commands.dll` is file version `10.0.26100.1 (WinBuild.160101.0800)`, with a valid Microsoft Windows signature. Its SHA-256 is `702DA853B7151C6637D0724DA7D6552B8A0197602C0C606A727305F8D0E3D810`. The locally inspected DLL has the same hash. Fresh decompilation of the relevant types matched the existing inspection artifacts.

Retained primary evidence includes these artifacts:

- `read-only-evidence.json`: target identity, module metadata, signature, hash, accepted Force values, and ASLR fields at `2026-09-20T02:37:46.7867694Z`.
- `SetProcessMitigationsCommand.cs`, `setEnableAndDisable`, lines 235–288: Enable sets ON, Disable sets OFF and wins if both lists contain the name. A selected entry calls `SetForce` only when Force differs from literal lowercase `notset`; the assigned Boolean is whether its lowercased value equals `on`. The default Force is lowercase `notset` (line 29).
- `PolicyPairList.cs`: BottomUp maps to ASLR policy field `BottomUp` and force field `BottomUp`. Several other parameters share one override, such as DEP and EmulateAtlThunks; the map must determine the association.
- `RegistryManager.cs`, `OptionValueToOptionState` and `OptionStateToOptionValue`: state occupies bits `0x3`; the independent override uses `0x4`. `WritePolicyToRegistry` passes both values to native policy APIs and reports native failures as warnings.
- `source-manifest.json`: hashes of the freshly inspected source artifacts.

Use explicit lowercase Force literals. The installed comparison with `notset` is case-sensitive even though parameter validation is case-insensitive.

## Scalar removal and preservation problems

The managed module attaches its remove flag to the policy group and passes a non-null group buffer and its size to `RtlSetImageMitigationPolicy`. The installed native API requires null buffer and zero size for the remove/reset flags; otherwise it returns `0xC000000D` (`STATUS_INVALID_PARAMETER`). A valid native remove deletes the entire selected `MitigationOptions` or `MitigationAuditOptions` value; it is not a single-field removal. Do not substitute that broad removal for an individual restore. Evidence: `RtlSetImageMitigationPolicy.asm`, addresses `0x180138ad5`–`0x180138af1`, `0x180138b47`–`0x180138b7e`, and `0x180139ad2`.

The scalar mapper also visits unselected entries and writes every policy group. Some parameter names differ from stored field names, such as DEP versus Enable. Such an unselected lookup can yield `NOTSET`, and native writers really replace those bits with zero. Scalar selection alone therefore does not guarantee preservation of unrelated fields.

## System-only XML path

Microsoft supports `Get-ProcessMitigation -RegistryConfigFilePath` export and `Set-ProcessMitigation -PolicyFilePath` import. It also documents that importing a baseline does not necessarily remove unwanted settings; omission is insufficient restoration evidence. [Import/export](https://learn.microsoft.com/en-us/defender-endpoint/import-export-exploit-protection-emet-xml), [troubleshooting](https://learn.microsoft.com/en-us/defender-endpoint/troubleshoot-exploit-protection-mitigations)

The installed `ImportMitigation` parses `SystemConfig` separately from `AppConfig`, attempts to load the existing system ImagePolicy, changes that object, and saves it. A document containing only SystemConfig does not enumerate, reset, or save application policies. However, ImagePolicy::Save calls Policy::Save for all 16 native groups, not only XML elements present in the document. ImagePolicy::Load attempts every group and resets every in-memory group if any load fails; the importer tolerates selected missing/access errors. Thus omitted system groups are not reliably preserved. This path avoids the PowerShell parameter mapper but remains a bulk system writer. Evidence: `xml-import-system.asm`, `xml-image-save.asm`, and `MitigationConfiguration.disassembly.txt` at `0x180011f98`–`0x180012188`.

An included ASLR element initializes omitted primary attributes to NOTSET and omitted Boolean attributes to false. Therefore construct the complete ASLR element from the captured state, including each sibling and override. Primary attributes accept `true`, `false`, or `notset`; RequireInfo and override attributes are Boolean. For the initially observed all-unset ASLR group, the explicit policy representation is:

```xml
<MitigationPolicy>
  <SystemConfig>
    <ASLR ForceRelocateImages="notset" RequireInfo="false"
          BottomUp="notset" HighEntropy="notset"
          OverrideForceRelocateImages="false" OverrideBottomUp="false"
          OverrideHighEntropy="false" />
  </SystemConfig>
</MitigationPolicy>
```

Change BottomUp to `true` for the approved ON state, and back to `notset` for default restoration. For any other baseline, fill every attribute from that baseline. Evidence: `xml-import-aslr.asm`, `xml-value-parser.asm`, and `xml-state-conversion.asm`. In `RtlSetImageMitigationPolicy.asm`, the ASLR branch at `0x1801390f4`–`0x18013920d` masks and replaces each primary state nibble even for zero/notset and encodes its override bit separately. Thus explicit XML supports all six primary-state/override combinations at the serializer/native boundary, including `NOTSET,true`.

This still does not preserve registry-value absence. XML saves materialize system option/audit values. The managed reader initializes fields to NOTSET when a value is missing, but returns OFF for some subordinate Boolean options after a zero-valued record exists. Exact restoration must capture original value existence as well as typed fields. An all-NOTSET typed snapshot alone cannot reconstruct that distinction.

The read-only export at `2026-09-20T02:40:24Z` contained 18 AppConfig entries and no SystemConfig. Its owned temporary Windows file was removed. The original `02:37:46Z` ASLR snapshot had RequireInfo and all primary states NOTSET, with all overrides false. A later read at `02:45:47Z` observed option/audit values present and subordinate options OFF; it is retained separately and must not replace the earlier baseline. This investigation performed no policy writes. Actual full-field and app-policy readback remains necessary after any separately authorized apply/restore.

## Native evidence identity

The copied Microsoft-signed `MitigationConfiguration.dll` is version `10.0.26100.1`, SHA-256 `123A5B95ACB7D8AAA45C130D46AB204B037D7ACB9D1B96C1E09007CD07D4D5EC`. The copied Microsoft-signed `ntdll.dll` is version `10.0.26100.9278`, SHA-256 `A74F7482085EAB125CCC09152AB7E0B5994BCB13E1A7B29880BDBB24179ECB8B`. Microsoft public symbols identify the inspected functions. [MitigationConfiguration symbols](https://msdl.microsoft.com/download/symbols/MitigationConfiguration.pdb/0DD4C30FAF7DB5EA2DC40DA5E67E91E81/MitigationConfiguration.pdb), [ntdll symbols](https://msdl.microsoft.com/download/symbols/ntdll.pdb/C3093720177DA6851519DCFFE8DF53FE1/ntdll.pdb)

These static findings apply to the pinned binaries. They do not prove that an XML import, every mitigation group, or an exact original-absence restoration has executed successfully. The public native API reference does not document the complete ASLR/remove representation. [Native API reference](https://learn.microsoft.com/en-us/windows/win32/debug/rtlsetimagemitigationpolicy-function)

## Recovery evidence after the failed scalar apply

There is no pre-write raw registry backup in this investigation. The first raw-value observation is the post-write `02:45:47Z` artifact. The earlier typed snapshot and export still discriminate some original absences through the signed reader's implementation.

All three values below reside at `HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\kernel`. The native system helper uses `NtOpenKey`, not key creation. `RtlSetImageMitigationPolicy` writes the two binary values as 24-byte `REG_BINARY` records; its payload branch writes EAFModules as a 1024-byte `REG_SZ` buffer even when the managed list is empty.

| Value | What the captured pre-write state proves | Recovery implication |
| --- | --- | --- |
| `MitigationOptions` | With no reader warnings, subordinate fields such as `Aslr.RequireInfo`, `Dep.EmulateAtlThunks`, or `Cfg.SuppressExports` being NOTSET establish the missing-value path. A successful native read, including a present all-zero or zero-length value, always assigns these fields ON or OFF. | Original value absence is established. A value-specific removal restores this representation; a zero record does not. |
| `MitigationAuditOptions` | The same proof applies if the captured `BinarySignature.AuditStoreSigned` is NOTSET and the read had no warnings. Its query uses the audit flag and reads this separate value. Primary audit fields being NOTSET alone are insufficient. | Original absence is established by that subordinate field. Remove only this value after confirming the saved field and no-warning evidence. |
| `EAFModules` | Absence is not established. Missing MitigationOptions makes the native payload query return before reading EAFModules; the managed list remains empty. A missing SystemConfig export likewise does not distinguish absent, empty, or otherwise unobserved EAFModules. | Do not infer absence or delete it as proven cleanup. Its original raw representation/content needs a pre-write raw backup or independent historical evidence. |

Evidence: `RegistryManager.cs` lines 375–406 and 420–474 convert subordinate bits only on successful reads and silently retain initialized NOTSET solely for `STATUS_OBJECT_NAME_NOT_FOUND`; lines 623–647 do so for AuditStoreSigned. `RtlQueryImageMitigationPolicy.asm` reads the selected binary value first at `0x180057f17`, returns failure before payload-module lookup, and only calls the EAFModules helper after success at `0x1800581a1`. `RtlpOpenSystemSessionKey.asm` resolves the exact path above. The scalar EAFModules write is at `0x180139747`–`0x180139768` in `RtlSetImageMitigationPolicy.asm`.

For recovery of the captured typed baseline, preserve a post-failure raw snapshot, validate that the two binary values still match the owned failed write, remove only the values whose original absence is proven, then require the complete typed map and application-policy export to equal their original snapshots. Do not use the native remove flag: the non-audit remove path also deletes EAFModules. This restores the proven typed state without inventing an EAFModules baseline; exact restoration of that raw value remains unresolved.

## Historical EAFModules evidence

The existing shadow copy `\\?\GLOBALROOT\Device\HarddiskVolumeShadowCopy3`, created `2026-09-18T17:09:39.198049Z`, contained a SYSTEM hive whose active `ControlSet001\Control\Session Manager\kernel` lacked all three values: MitigationOptions, MitigationAuditOptions, and EAFModules. This establishes absence at that historical snapshot, not immediately before the September 20 test. A targeted filename/content search under the private work directory found no earlier raw mitigation-value backup.

Two private-copy attempts with `RegLoadAppKeyW`, `KEY_READ`, and `REG_PROCESS_APPKEY` returned Win32 `1009` (`ERROR_BADDB`), including with the matching SYSTEM.LOG1/LOG2 files. No global registry namespace mount was attempted. Microsoft documents that this API uses a private handle and does not mount under HKLM/HKU. [RegLoadAppKeyW](https://learn.microsoft.com/en-us/windows/win32/api/winreg/nf-winreg-regloadappkeyw)

The fallback used [python-registry](https://github.com/williballenthin/python-registry), a read-only offline parser, version 1.3.1, on a temporary Linux copy inside a mode-0700 directory. Only the active-control-set selector and the three named mitigation values were inspected. The source, initial copy, and final copy SHA-256 all matched `DA0637D6966BB21D8AC2F2B391C40D8F0BD7648786E445C7115B03F08CD14FC4`. All owned Windows/Linux hive copies, matching log copies, and the private parser installation were removed. Evidence is retained as `historical-hive-read-only.json`, `historical-hive-with-logs-read-only.json`, and `historical-hive-offline-read-only.json` in the evidence directory above; the hives themselves are not retained.

After explicit approval to restore the historical EAFModules absence, the separate recovery run removed the matching zero-filled value. Its `2026-09-20T03:27:36.3770568Z` readback reports all three values absent and the complete typed policy equal to the immediate original snapshot. This closes the approved recovery action; it does not turn the historical EAFModules evidence into an immediate pre-write raw backup. Evidence: `eaf-cleanup-result.log` from the Windows validation run.

## Per-group native ABI for the catalog

`RtlSetImageMitigationPolicy` is an exported, documented API, but the public Microsoft reference does not publish these ASLR/DEP/CFG structure layouts. The table is a contract verified from the pinned signed x64 binaries, not a public Windows SDK compatibility guarantee. Microsoft symbols identify each native class's enum and buffer-size getter; `native-policy-abi-getters.json` and `windows-mitigations-native-contract.json` retain the machine-readable mapping for all 16 catalog entries. [Public API boundary](https://learn.microsoft.com/en-us/windows/win32/debug/rtlsetimagemitigationpolicy-function)

Pass a null image path for the system policy. Flags `0` selects MitigationOptions; flags `8` selects MitigationAuditOptions. Each buffer contains the indicated number of bytes, divided into 64-bit words. Primary state uses mask `0x3`: NOTSET=`0`, ON=`1`, OFF=`2`. The corresponding normal-policy override uses mask `0x4`. Subordinate options use `0x8` of their parent's word and are independently Boolean, not tristate; the native writer encodes them only while their parent is ON.

| Catalog parameter | XML element.attribute | XML kind | Native enum / buffer bytes | Flags | Word byte offset | State mask |
| --- | --- | --- | --- | --- | --- | --- |
| DEP | DEP.Enable | Primary tristate | 0 / 8 | 0 | 0 | `0x3` |
| EmulateAtlThunks | DEP.EmulateAtlThunks | Subordinate Boolean | 0 / 8 | 0 | 0 | `0x8` |
| SEHOP | SEHOP.Enable | Primary tristate | 13 / 8 | 0 | 0 | `0x3` |
| ForceRelocateImages | ASLR.ForceRelocateImages | Primary tristate | 1 / 24 | 0 | 0 | `0x3` |
| RequireInfo | ASLR.RequireInfo | Subordinate Boolean | 1 / 24 | 0 | 0 | `0x8` |
| BottomUp | ASLR.BottomUp | Primary tristate | 1 / 24 | 0 | 8 | `0x3` |
| HighEntropy | ASLR.HighEntropy | Primary tristate | 1 / 24 | 0 | 16 | `0x3` |
| StrictHandle | StrictHandle.Enable | Primary tristate | 3 / 8 | 0 | 0 | `0x3` |
| CFG | ControlFlowGuard.Enable | Primary tristate | 7 / 16 | 0 | 0 | `0x3` |
| SuppressExports | ControlFlowGuard.SuppressExports | Subordinate Boolean | 7 / 16 | 0 | 0 | `0x8` |
| DisableExtensionPoints | ExtensionPoints.DisableExtensionPoints | Primary tristate | 6 / 8 | 0 | 0 | `0x3` |
| BlockDynamicCode | DynamicCode.BlockDynamicCode | Primary tristate | 2 / 8 | 0 | 0 | `0x3` |
| AuditDynamicCode | DynamicCode.Audit | Audit Boolean; omit for NOTSET | 2 / 8 | 8 | 0 | `0x3` |
| AuditFont | Fonts.Audit | Audit Boolean; omit for NOTSET | 9 / 8 | 8 | 0 | `0x3` |
| BlockRemoteImageLoads | ImageLoad.BlockRemoteImageLoads | Primary tristate | 10 / 24 | 0 | 0 | `0x3` |
| AuditRemoteImageLoads | ImageLoad.AuditRemoteImageLoads | Audit Boolean; omit for NOTSET | 10 / 24 | 8 | 0 | `0x3` |

The audit XML attributes are Boolean when present: `true` encodes ON and `false` encodes OFF. Omitting them within an included element encodes NOTSET; spelling `notset` as the attribute value is parsed as false and becomes OFF. Direct audit buffers instead support all three primary state values. Audit rows' catalog override names refer to the normal policy (`Flags=0`), not an independent audit override; preserve that normal-policy flag separately.

Query the whole selected native group immediately before changing it, retain sibling words and unused bits, then patch only the selected state/override bits and call the corresponding group setter. ASLR has ForceRelocateImages, BottomUp, and HighEntropy at offsets 0/8/16; CFG has Enable and StrictControlFlowGuard at offsets 0/8; ImageLoad has BlockRemoteImageLoads, BlockLowLabelImageLoads, and PreferSystem32 at offsets 0/8/16. Calling ASLR enum 1, flags 0, with a 24-byte buffer changes only the ASLR portion of MitigationOptions. It neither writes MitigationAuditOptions nor enters the payload/EAFModules branch. Flags 1/2 must not be used with these populated buffers.

The native query returns `0xC0000034` when the selected binary value is absent. An explicitly absent value can be modeled as a zero group with raw absence metadata retained; other error statuses remain failures. Canonicalizing the subordinate bits in that zero group to OFF gives the same native Boolean semantics without depending on the managed reader's synthetic NOTSET initialization.

These group calls still enforce native relationships. CFG=OFF forces StrictControlFlowGuard=OFF. CFG=NOTSET preserves strict OFF but produces strict NOTSET for either strict ON or NOTSET. CFG=ON uses the supplied strict state. The strict override bit is retained independently. Therefore preserving an input sibling word is not sufficient to promise an unchanged CFG sibling; validate the intended state combination before writing. ASLR's three primary words are encoded independently.

Global raw offsets, confirmed in the pinned native writer, are zero-based bit positions in a little-endian 24-byte record:

| Fields sharing a raw slot | Slot start bit |
| --- | --- |
| DEP, EmulateAtlThunks | 0 |
| SEHOP | 4 |
| ForceRelocateImages, RequireInfo | 8 |
| BottomUp | 16 |
| HighEntropy | 20 |
| StrictHandle | 24 |
| DisableExtensionPoints | 32 |
| BlockDynamicCode, AuditDynamicCode | 36 |
| CFG, SuppressExports | 40 |
| AuditFont | 48 |
| BlockRemoteImageLoads, AuditRemoteImageLoads | 52 |
| ImageLoad sibling BlockLowLabelImageLoads | 56 |
| ImageLoad sibling PreferSystem32 | 60 |
| CFG sibling StrictControlFlowGuard | 72 |

Flags 0 and 8 use the same offsets in their respective binary values. Each slot occupies four bits: primary NOTSET=0, ON=1, OFF=2, and ON with its subordinate option enabled=3; override occupies slot bit 2. The native writer replaces all four bits of every slot in the selected group. In particular, native buffer option mask `0x8` is not raw slot bit 3: the option is folded into raw state 3 while its parent is ON. The JSON mapping includes exact hexadecimal masks for every catalog row and the full group slot sets. Evidence is `RtlSetImageMitigationPolicy.asm`, including DEP at `0x18013920f`, SEHOP at `0x1801395f2`, ASLR at `0x1801390e2`, CFG at `0x180138d53`, and ImageLoad at `0x180139970`.

For an exact raw transaction, patch only the requested low-state mask `0x3` and, when independently requested, normal-policy override mask `0x4`. Preserve raw slot bit 3 (`0x8`) and all unrelated bytes. The pinned native reader ignores slot bit 3 for every mapped field; it is unknown raw data, not a subordinate option. Preserve exact snapshots rather than reconstructing records from typed output. `windows-mitigations-raw-contract.json` contains all 16 field offsets, value names, masks, and the following decoder distinction:

| Raw low state `3` at this slot | Pinned native query result |
| --- | --- |
| DEP; ForceRelocateImages; CFG | ON plus native option bit `0x8`, representing the explicitly mapped subordinate option |
| SEHOP; DynamicCode | ON plus native option bit `0x8`, representing TelemetryOnly or AllowThreadsToOptOut, respectively |
| AuditDynamicCode; AuditFont | ON plus native option bit `0x8` through the same decoder; the catalog exposes no separate subordinate control for this audit flag |
| BottomUp; HighEntropy; StrictHandle; DisableExtensionPoints; BlockRemoteImageLoads; AuditRemoteImageLoads | NOTSET, with the raw override bit retained independently |

Raw state 3 must therefore not be uniformly decoded as ON or uniformly rejected as an error. Likewise, a no-op on a field that reads NOTSET must not rewrite a raw 3 into canonical zero. Retain the original bytes for no-op and rollback behavior, and do not assign a product meaning to an unmapped native option. Evidence: the common option-capable query path at `0x18005827e`/`0x18005868f`, ASLR at `0x180058594`, CFG at `0x180058458`, non-option scalar path at `0x18005855d`, and ImageLoad at `0x18005895d` in `RtlQueryImageMitigationPolicy.asm`. These are configured-policy reads, not proof of live protection in existing processes.

Raw before/applied snapshots must retain value existence, type, and bytes. A normal per-group call still materializes MitigationOptions if absent, causing some managed subordinate fields to read OFF instead of synthetic NOTSET; that is not evidence of additional active mitigations. Restore the exact captured raw representation at final-owner recovery only after checking for outside changes. Native read/modify/write does not provide caller-visible atomic compare-and-set against independent writers.

The observed managed CFG failure is explained by the adapter's order: the first BottomUp write materializes MitigationOptions; a later SuppressExports entry then reads OFF rather than its desired absent-baseline NOTSET. The scalar loop invokes `-Remove -Disable SuppressExports`, supplying CFG flags 2 and a non-null 16-byte buffer. Native validation rejects that combination with `0xC000000D`. Enum 7/size 16/flags 0 passes that native validation. This is a source-derived reconstruction consistent with the reported warning, not a captured native-call trace or an executed direct-set test.
