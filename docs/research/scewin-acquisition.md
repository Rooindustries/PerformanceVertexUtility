# SCEWIN acquisition

Verified 2026-09-20. This investigation downloaded and unpacked vendor archives on Linux. It did not execute SCEWIN, install its drivers, change firmware, or restart Windows.

## Working source

The official [MSI Center download](https://download.msi.com/uti_exe/desktop/MSI-Center.zip) contains SCEWIN and its matching drivers. The request currently redirects to `download-2.msi.com` and returns MSI Center **2.0.74.0**, 584,849,764 bytes. MSI presents Center on its [product page](https://www.msi.com/Landing/MSI-Center). Acquisition can download this archive and extract the required files without installing MSI Center.

The tested extraction chain is:

| Container | Selected child |
| --- | --- |
| `MSI-Center.zip` | `MSI Center_2.0.74.0.exe` |
| Center Inno installer | `app/c54a62653fbb4312b004df3acb7283a3.appxbundle` |
| Appx bundle | `MSI%20Center_2.0.74.0_x64.appx` |
| x64 Appx | `DCv2/Package/MSI%20Center%20SDK.exe` |
| SDK Inno installer | `tmp/PrePackage/Engine Lib_3.0.0.74.exe` |
| Engine Lib Inno installer | `app/Lib/SCEWIN/5.05.01.0002/` |

Only these three files are needed from the final directory:

| File | Bytes | SHA-256 |
| --- | ---: | --- |
| `SCEWIN_64.exe` | 684,912 | `2d78e7bb62fcab44c54fe853f51e8836ada45ea374027423bcb6d7a5db46502b` |
| `amifldrv64.sys` | 29,056 | `e7cbfb16261de1c7f009431d374d90e9eb049ba78246e38bc4c8b9e06f324b6f` |
| `amigendrv64.sys` | 35,200 | `ffc72f0bde21ba20aa97bee99d9e96870e5aa40cce9884e44c612757f939494f` |

The same directory also contains `BIOSData.db`, `BIOSData.txt`, and `SCEWIN.bat`. These are vendor-supplied data/scripts. They must not be treated as the current computer's backup or imported into its BIOS. Roo Industries must create its own original export.

All three required files have an x64 PE machine type (`0x8664`). On the the i5-14600K test PCXT machine, `Get-AuthenticodeSignature` returned **Valid** for all three, with hashes matching the table. SCEWIN's publisher is `AMI US HOLDINGS INC`, issued by COMODO RSA Extended Validation Code Signing CA. Both drivers' publisher is `American Megatrends, Inc.`, issued by DigiCert EV Code Signing CA (SHA2). This establishes signature validation on that Windows installation, not whether Memory Integrity permits loading those drivers or whether this firmware supports the helper.

## Extraction tool

[innoextract](https://constexpr.org/innoextract/) extracts Inno installer data without executing the installer or its scripts. The upstream **1.9** Linux release successfully unpacked all three current MSI installers. `--include` accepts a path or directory prefix, not a filename wildcard. For the final installer, the tested filter is:

```text
innoextract --silent --include app/Lib/SCEWIN --output-dir <staging> <Engine Lib installer>
```

Windows acquisition can use the upstream [innoextract 1.9 Windows archive](https://constexpr.org/innoextract/files/innoextract-1.9-windows.zip). The archive is 520,705 bytes with SHA-256 `6989342c9b026a00a72a38f23b62a8e6a22cc5de69805cf47d68ac2fec993065`; `innoextract.exe` is 1,218,560 bytes with SHA-256 `946bd06d8b3722a791fea4d84f496139eef6faef61640924cb72f5f1998a68e1`.

The [detached signature](https://constexpr.org/innoextract/files/innoextract-1.9-windows.zip.sig) verified against the author's [published key](https://constexpr.org/dscharrer.asc), fingerprint `ADE9653703D4ADE0E997758128555A66D7E1DEC9`. The key was obtained from the same publisher over HTTPS; this is not an independent identity attestation. The archive includes the extractor's zlib license and dependency notices; retain them with the extractor.

## Version handling

`MSI-Center.zip` is a mutable vendor URL. On this inspection its outer SHA-256 was `fbfa35a0cd8b4a71f6f0cac5090c50a97d082e1f5f93d5b95493526a34032e96`. Relevant nested hashes:

| Container | SHA-256 |
| --- | --- |
| `MSI Center_2.0.74.0.exe` | `95e6be38ed8f1a0ad5055c9831dab057f2b0bba0eb33a25eb60a9486fd0d3ebd` |
| `MSI%20Center%20SDK.exe` | `fd8847f2ec110863a8bb69e98e5fe13edd2e5ffa48e55d88d5372db1c2ebdc36` |
| `Engine Lib_3.0.0.74.exe` | `b0891826df80c988c6502c8cc78761247e7b75d7aef9716c481790b738361525` |

The Engine Lib installer is 32,399,704 bytes, but a usable direct official download URL was not found. Versioned MSI Center archive candidates and exact Engine Lib names under the observed MSI download/update bases returned HTTP 404. This is a bounded search result, not proof that no smaller source exists.

Pin the outer archive, extractor, and selected SCEWIN component hashes. Cache only a complete, validated package. If the upstream archive changes, report the precise acquisition failure and retain the prior validated package until the new source is reviewed. Do not silently select an arbitrary similarly named binary or reuse a partially extracted package.

## Motherboard compatibility

AMI documents that AMISCE exports the machine's setup questions and imports edited NVRAM settings. AMI also offers platform-locked versions, so an AMI BIOS name alone cannot establish compatibility. See [AMI Aptio Utilities](https://f.hubspotusercontent10.net/hubfs/9443417/Data_Sheets/Firmware_Tools_and_Utilities/Aptio_Utilities_Data_Sheet_PUB.pdf).

The [Gigabyte B760M DS3H WIFI6E DDR4 GEN5 support page](https://www.gigabyte.com/ca/Motherboard/B760M-DS3H-WIFI6E-DDR4-GEN5/support) identifies the board and F4 release. No board-specific Windows SCEWIN download was found in this investigation. The MSI source proves package provenance; it does not prove Gigabyte endorsement or successful access to this motherboard's firmware.

The app should determine compatibility through an original export using the intact package, then validate and bind that export to the current motherboard, BIOS revision, and package fingerprint. Preserve the existing import review, HII CRC check, recovery files, and separate restart action. Driver trust, export success, import success, and post-restart verification are distinct outcomes.

Intel's [AMISCE download](https://www.intel.com/content/www/us/en/download/19551/amisce-ami-setup-control-environment-utility-for-m10jnp2sb.html) is explicitly for the M10JNP2SB server board. It is not evidence of compatibility with this Gigabyte board. Intel also publishes the [AMI user guide](https://downloadmirror.intel.com/29468/eng/ami_aptio_5.x_sce_user_guide_nda.pdf), which distinguishes export (`/o /s`) from import (`/i /s`) and documents `/r` as the HII CRC check. This app should continue to avoid automatic import or reboot during setup.

## Distribution terms

Public download availability is not a redistribution license. [MSI's terms](https://www.msi.com/page/website-terms-of-use) describe personal, non-commercial use of MSI software, restrict redistribution without permission, and state that third-party software is separately licensed by its owner. No grant to redistribute AMI's SCEWIN binaries as part of a Roo Industries release was established here. Keep vendor binaries out of the source repository and release package; retain source/provenance records and applicable notices for downloads. Commercial distribution rights remain a separate release consideration.

The Intel download page's displayed agreement includes product-specific and confidentiality terms. It was not selected as an automatic fallback.

## Evidence

The private acquisition evidence directory contains the downloaded MSI archive, extracted containers/components, `source-hashes.json`, installer file lists, and innoextract signature material. The integration task's `signatures.json` records the Windows results. Linux extraction, PE inspection, upstream extractor signature verification, and Windows Authenticode validation are verified. In the subsequent approved integration test, SCEWIN exported the actual Gigabyte BIOS with exit status zero while Secure Boot and Memory Integrity stayed enabled; no AMI driver services remained afterward. The original export contains 4,693 supported settings. No actual BIOS import or restart was performed.
