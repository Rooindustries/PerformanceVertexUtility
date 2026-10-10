# the i5-14600K test PCXT BIOS setting inventory and effectiveness tests

This note is a test design and inventory record. It does not claim that a BIOS setting is effective or ineffective. Every setting in the machine-readable inventory is currently `untested`.

## Evidence boundary

The reviewed source is the fresh read at `<private work folder>/bios-verification-20260920/original.txt`.

| Field | Value |
| --- | --- |
| Machine | the i5-14600K test PCXT development PC; exact machine identity retained with the private snapshot |
| Board | Gigabyte Technology Co., Ltd. B760M DS3H WIFI6E DDR4 GEN5 x.x |
| BIOS | American Megatrends International, LLC. F4, 2025-12-02 |
| Raw export SHA-256 | `B324FAEBD2AF63EF65DFCBCB80113FB0DD285843FCEF6BD7D38A58C4FB4A67F6` |
| HII CRC32 | `6F5ADBC2` |
| Encoding and line endings | Latin-1; 57,534 CRLF lines and two lone CRs |
| Parsed settings | 4,693: 2,649 choice, 1,725 decimal, 319 hexadecimal |
| Storage widths | 3,743 one-byte, 838 two-byte, 100 four-byte, 12 eight-byte |

The session identity and backup hash are in `session.json` beside the export. The vendor support page identifies F4 as a BIOS release for this exact DDR4 GEN5 board and separately lists later F5/F5a releases; this test record is bound to the captured F4 identity, not to a later firmware image. [Gigabyte support](https://www.gigabyte.com/ca/Motherboard/B760M-DS3H-WIFI6E-DDR4-GEN5/support)

The parser accepts AMISCE's verbose HII script and derives the product setting ID from form context, token, offset, and displayed question name. The inventory adds the storage identity that must be used for alias analysis: `variable GUID + variable name + offset + width`. Intel describes AMISCE as a utility for updating NVRAM variables from Windows, Linux, or EFI; that capability establishes a write path, not a proof that firmware consumes a particular variable in the expected way. [Intel AMISCE](https://www.intel.com/content/www/us/en/download/19551/amisce-ami-setup-control-environment-utility-for-m10jnp2sb.html)

## Inventory and binding findings

The complete parseable inventory is `<private work folder>/bios-verification-20260920/inventory/effectiveness-inventory.json`. It retains the exact question IDs, names, help text, current values, options, form context, variable GUID/name, token, offset, width, and source block. The parser input copy and its unmodified inventory are also retained as `original.txt` and `original.inventory.json` in that directory.

There are 18 variable names across 253 form contexts and 204 form titles. No two questions share the complete storage identity. Five groups share a GUID, offset, and width while using different variable names; these are namespace collisions to review, not proven aliases:

| GUID | Offset/width | Displayed questions | Variable names |
| --- | --- | --- | --- |
| `5432122d-d034-49d2-a6de-65a829eb4c74` | `10/1` | `ME Unconfig on RTC Clear`; `Dynamic Lan Switch` | `MeSetupStorage`; `MeSetup` |
| same | `06/1` | `TPM 1.2 Deactivate`; `Force ME DID Init Status` | `MeSetupStorage`; `MeSetup` |
| same | `09/1` | `MBP HOB Skip`; `Delayed Authentication Mode` | `MeSetup`; `PchSetup` |
| same | `0A/1` | `HECI2 Interface Communication`; `FIPS Mode Select` | `MeSetup`; `MeSetupStorage` |
| same | `0B/1` | `KT Device`; `Set HW-Enforced Anti-Rollback for Current SVN` | `MeSetup`; `MeSetupStorage` |

The different variable names are part of the binding and must remain separate until a raw before/after export demonstrates a real alias. Display-name duplicates are common and are not aliases by themselves. For example, there are two distinct `Fast Boot` records, three `SATA mode` records, and repeated `PCI Express Root Port`, `I2C Address`, `Device Type`, and timing records. The UI must show the form, variable name, offset, and width wherever a label is repeated.

The verbose export contains no `Suppress If`, `Gray Out If`, `Disable If`, `Inconsistent If`, `QuestionId`, `VarStoreInfo`, or refresh dependency directives. A dependency is therefore `unknown` unless it is established by a board-specific observation. The inventory records this limitation rather than manufacturing dependency claims.

## What counts as effectiveness

The test has four separate outcomes:

1. **Write acceptance:** SCEWIN returns success and a fresh export parses. This only proves that the helper accepted the script.
2. **NVRAM persistence:** the requested target value is present in the fresh post-import export, every other storage-keyed setting is unchanged, and a second fresh export after restore equals the pre-test value. This still does not prove runtime use.
3. **Behavioral effect:** after the required reboot or power transition, a controlled firmware, OS, device, or physical oracle changes in the direction predicted by the setting contract. A suitable control run and the same baseline are required.
4. **Ineffective or ignored:** only a completed behavioral test with a valid oracle may produce this label. A retained NVRAM value, a successful import, a no-op display, or a reboot-only observation is not enough.

At every stage, compare all questions by `variable GUID + variable name + offset + width`, preserve the exact original value and type, and record normalization or collateral changes. If a paired control changes when one field is modified, classify the pair as a binding or dependency finding and remove both from single-control effectiveness claims until resolved.

## Initial low-risk batch: persistence only, no reboot

The first batch is deliberately limited to three one-byte settings whose changed values do not alter boot mode, storage mode, security keys, CPU ratios, memory training, or PCI resource allocation. It is safe to stop after the post-import readback and restore. It is not a behavior test until the later oracle step.

| Exact question and ID | Storage key | Before | Test value | Restore | Behavior oracle when separately authorized |
| --- | --- | ---: | ---: | ---: | --- |
| `LEDs in System Power On State` — `3BE7D87FEFDE62D5A9E5999C4E9315FEE0CFF3477E743FBFBE722340712EE113` | `ec87d643-eba4-4bb5-a1e5-3f3e36b20da9\|Setup\|1132\|1` | `01` On | `00` Off | `01` On | A controlled shutdown/power-on and direct board LED observation. A Windows readback cannot prove this LED output. |
| `Bootup NumLock State` — `F08A713AB2CABF18E131405D9D891463421449F9BAE12D09F2BE5DBAAF8AD8BA` | `ec87d643-eba4-4bb5-a1e5-3f3e36b20da9\|Setup\|00\|1` | `01` On | `00` Off | `01` On | A reboot with a directly observed firmware/boot screen and keyboard state. The no-reboot phase proves persistence only. |
| `Full Screen LOGO Show` — `1B19117F8105782F653FFACCC87473D82BEB0559A68E1C3A6A0DC2B350F8B8E9` | `ec87d643-eba4-4bb5-a1e5-3f3e36b20da9\|Setup\|50\|1` | `1` On | `0` Off | `1` On | A reboot with a directly observed firmware logo/boot path. The no-reboot phase proves persistence only. |

Run them one at a time. For each setting: export the current state; save the exact target and all storage-keyed values; import one change; export again; verify only the intended target changed; import the saved target value from a fresh current export; export again; verify full equality. Do not combine them in one change script because an unexpected result would not identify the responsible field. The application journal, reviewed script hash, helper exit code, and both re-exports belong in the test evidence.

The approved Windows runs completed for all three settings on 2026-09-20. Each native import returned exit code 0 with `restartRequired`, each fresh readback contained the test value, and each inverse restore returned the complete storage-keyed profile to its baseline. The store records are `valueStored` with restoration complete; no restart or behavior evidence is attached, so the UI reports `Value saved` and keeps these settings out of the collapsed ineffective menu.

## Follow-on batches and prerequisites

These are test designs, not authorization to execute them.

### GPU address-space and ReBAR

The export has two user-facing ReBAR controls and two related above-4G controls. They are different storage identities and must be tested separately before deciding whether the UI should collapse them:

| Setting | ID | Current → test | Storage |
| --- | --- | --- | --- |
| `Above 4G Decoding` | `AAEE39787327D806624E444DEE4CC72D7A2E08C838071EB80D2013EC44786DC4` | `00` → `01` | `Setup`, offset `10E8`, width `1` |
| `Above 4GB MMIO BIOS assignment` | `86A5D372D6C0E64AE434EE827EED51A676A51FC1EE3F8AB68DDD087D830E0A35` | `00` → `01` | `SaSetup`, offset `7E`, width `1` |
| `Re-Size BAR Support` | `C14A4BF90643AC1815A1AED5EEDC2B1D636B662C0152441B73673FBE1CB88743` | `00` → `01` | `Setup`, offset `10E9`, width `1` |
| `PCIE Resizable BAR Support` | `0E1C6C73B7C403586490849A83665B515A67F4DE085D95469AB4800EB2C42ED6` | `00` → `01` | `SaSetup`, offset `42B`, width `1` |

Prerequisites are a known-good display path, a known-good boot path, a captured PCI/device baseline, and physical recovery if the GPU or boot display fails. After reboot, compare the GPU's PCI resource and Resizable BAR capability state using a board/device-specific Windows oracle, then run a repeatable GPU workload. A larger BAR or a changed PCI resource map is evidence of enumeration, not automatically a performance improvement. Restore the exact original values and repeat the device baseline. Do not call either pair an alias solely because the labels are similar.

### Virtualization and DMA protection

The exact controls are `Intel (VMX) Virtualization Technology` (`CF5C01812EDD30CA9391B167077F966AFB6EDBD82F62DB037635174ABDBECD37`, `01` → `00`), `VT-d` (`9566224E5D18A54366C44A58CAC26681ED996CD0104DD5392C2E938CBBD5E935`, `01` → `00`), and `Control Iommu Pre-boot Behavior` (`71DC4844530BD814360444C73E1472597BF9B17EA7A60C3505E45EED7DC6E820`, `02` Auto → `00` Disabled). Test one at a time with a reboot and record `msinfo32`, device enumeration, and a controlled virtualization/DMA oracle. Microsoft documents that Hyper-V and dependent security features share the hypervisor and that IOMMU/VT-d is relevant to DMA protection; the presence of a hypervisor is not proof that this particular BIOS switch changed it. [Microsoft Hyper-V troubleshooting](https://learn.microsoft.com/en-us/troubleshoot/windows-client/application-management/virtualization-apps-not-work-with-hyper-v) and [Hyper-V hardware requirements](https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/host-hardware-requirements). Restore the original values and verify the pre-test security/device state.

### CPU power and performance controls

`CPU EIST Function` (`E0B5F3F88D2E9F3BAAA5C17FD2C52DA5DDF2105848513FCBBB3894C2FA2E212A`, `00` Auto → `01` Disabled), `C-States Control` (`EB1757B030369573E4C1FC6ADABB790657AE3E4ACF4A08B274328308AE5D92B2`, `00` Auto → `01` Disabled), and `Intel(R) Turbo Boost Technology` (`A0CCDF07C9D2F664967A1FB86232B17B966E506E46CC6F181729C456C2998501`, `00` Auto → `01` Disabled) require a reboot and a fixed workload, temperature, power, and clock sampling plan. Microsoft documents that Windows selects processor P-states and C-states dynamically; a single instantaneous frequency or benchmark result cannot prove that a firmware control was honored. [Microsoft CPU analysis](https://learn.microsoft.com/en-us/windows-hardware/test/wpt/cpu-analysis). Keep these out of the initial batch because they can alter thermals and stability.

### Wake and physical power transitions

`Wake on LAN Enable` (`DDB8CAA43E43377117146E13AA81F9E8FEB57D474F2F86C70C1FD2D951607207`, `01` → `00`) and `LAN Wake From DeepSx` (`07AAEDDF6F82FCEEA72BD94A980EA252D681C92C415196F2C4ED85A63D7A0366`, `01` → `00`) need a controlled sleep/S4/S5 test, a separate network sender, a known-good local keyboard/display or KVM, and a recovery path. `powercfg /devicequery wake_armed` and `/lastwake` are useful OS evidence, but a lack of a wake event can also result from the OS, NIC driver, switch, power state, or packet path. [Microsoft powercfg](https://learn.microsoft.com/en-us/windows-hardware/design/device-experiences/powercfg-command-line-options). No setting should be called ineffective without isolating those prerequisites.

### Boot, storage, security, and memory

Defer `CSM Support`, `Secure Boot`, `Network Stack`, `SATA mode`, VMD root-port mapping, TPM controls, memory profiles/timings, CPU core counts, BCLK/clock ratios, voltage/VR controls, and firmware/ME/debug options until a physical recovery path and the relevant boot, recovery-key, storage, or hardware prerequisites are confirmed. Their success condition is not merely “the export retained the value”: it includes a successful boot through the intended device, intact security state, and a complete restore. A failure may require firmware setup recovery, board defaults, or physical intervention; these settings belong in the separate advanced/unverified menu until tested.

## UI disposition

Use the inventory's `test_stage`, `risk`, `status`, and `proof` fields to separate controls:

- `Verified effective` contains only settings with a completed contract-backed behavioral oracle and a verified restore.
- `Persistence tested` contains settings that survive isolated write/read/restore but have not yet passed a behavior oracle.
- `Advanced / unverified` contains the remaining settings, including all 4,693 records in this snapshot until evidence changes their status.
- `Ineffective or ignored` is an evidence state that can be assigned only after a valid behavior test. It must never be inferred from a stable NVRAM value, an accepted import, a no-op reboot, or an absent dependency directive.

The complete inventory currently assigns two settings to the low-risk persistence batch, 699 to a reboot-oracle planning stage, 2,007 to hardware-recovery-required planning, and 1,985 to contract-needed planning. Those numbers are planning classifications, not effectiveness results.

## References

- [Intel AMISCE product page and user guide](https://www.intel.com/content/www/us/en/download/19551/amisce-ami-setup-control-environment-utility-for-m10jnp2sb.html)
- [Gigabyte B760M DS3H WIFI6E DDR4 GEN5 support and BIOS history](https://www.gigabyte.com/ca/Motherboard/B760M-DS3H-WIFI6E-DDR4-GEN5/support)
- [Microsoft CPU analysis, P-states and C-states](https://learn.microsoft.com/en-us/windows-hardware/test/wpt/cpu-analysis)
- [Microsoft Hyper-V hardware requirements](https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/host-hardware-requirements)
- [Microsoft powercfg command-line options](https://learn.microsoft.com/en-us/windows-hardware/design/device-experiences/powercfg-command-line-options)
