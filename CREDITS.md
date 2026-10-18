# Credits

Performance Tuning Utility is built on other people's work. Every setting, check and tool below came from someone who figured it out first. Thank you.

If you made something listed here and want the credit worded differently, or we missed you, open an issue and we'll fix it.

## Where the settings come from

| Project | Made by | License | What we use |
| --- | --- | --- | --- |
| [Chris Titus Tech's Windows Utility (WinUtil)](https://github.com/ChrisTitusTech/winutil) | Chris Titus Tech and contributors | MIT | Tweak and app definitions, pinned to commit `fc60cbde`. We rebuilt them into our own catalog with previews and rollback. |
| [O&O ShutUp10++](https://www.oo-software.com/en/shutup10) | O&O Software | Freeware | Its privacy settings list. |
| [WPD](https://wpd.app/) | The WPD team | Freeware | Its privacy settings and the telemetry blocklists the app can add to the firewall. |
| [Adobe URL Block List](https://github.com/Ruddernation-Designs/Adobe-URL-Block-List) | Ruddernation Designs | No license published | The Adobe host list the app can add to your hosts file. |
| [Microsoft Learn](https://learn.microsoft.com/) | Microsoft | Documentation | What each Windows setting and policy actually does. |

## Tools the app opens or downloads for you

The app doesn't include these. It links to them, opens them if you already have them, or downloads them from the official site when you ask. The icons next to them in the app come from each tool's own program file or official product page and belong to their owners.

| Tool | Made by |
| --- | --- |
| [.NET Framework 3.5](https://learn.microsoft.com/en-us/dotnet/framework/install/dotnet-35-windows) | Microsoft |
| [AMD Chipset Software](https://www.amd.com/en/support/download/drivers.html) | AMD |
| [AMD Software: Adrenalin Edition](https://www.amd.com/en/support/download/drivers.html) | AMD |
| [Autoruns](https://learn.microsoft.com/en-us/sysinternals/downloads/autoruns) | Microsoft Sysinternals (Mark Russinovich) |
| [CPU-Z](https://www.cpuid.com/softwares/cpu-z.html) | CPUID |
| [Device Cleanup Tool](https://www.uwe-sieber.de/misc_tools_e.html) | Uwe Sieber |
| [DirectX Runtime](https://www.microsoft.com/en-us/download/details.aspx?id=35) | Microsoft |
| [Display Driver Uninstaller](https://www.wagnardsoft.com/) | Wagnardsoft |
| [GPU-Z](https://www.techpowerup.com/gpuz/) | TechPowerUp |
| [HWiNFO](https://www.hwinfo.com/) | Martin Malík (REALiX) |
| [innoextract](https://constexpr.org/innoextract/) | Daniel Scharrer (zlib license). The app downloads it to unpack SCEWIN from the MSI Center package without running that installer. |
| [InSpectre](https://www.grc.com/inspectre.htm) | Steve Gibson (Gibson Research Corporation) |
| [Intel Chipset Device Software](https://www.intel.com/content/www/us/en/download-center/home.html) | Intel |
| [Intel Ethernet Drivers](https://www.intel.com/content/www/us/en/download-center/home.html) | Intel |
| [IObit Driver Booster](https://www.iobit.com/en/driver-booster.php) | IObit |
| [LatencyMon](https://www.resplendence.com/latencymon) | Resplendence Software |
| [MSI Afterburner](https://www.msi.com/Landing/afterburner/graphics-cards) | MSI, built on RivaTuner by Alexey Nicolaychuk (Unwinder) |
| [MSI Kombustor](https://geeks3d.com/furmark/kombustor/) | MSI and Geeks3D |
| [MSI Utility v3](https://forums.guru3d.com/threads/windows-line-based-vs-message-signaled-based-interrupts.378044/) | mbk1969 and the Guru3D forum community |
| [NVCleanstall](https://www.techpowerup.com/nvcleanstall/) | TechPowerUp |
| [NVIDIA App and drivers](https://www.nvidia.com/en-us/drivers/) | NVIDIA |
| [NVIDIA Profile Inspector](https://github.com/Orbmu2k/nvidiaProfileInspector) | Orbmu2k (MIT) |
| [O&O ShutUp10++](https://www.oo-software.com/en/shutup10) | O&O Software |
| [Process Lasso](https://bitsum.com/) | Bitsum |
| [Realtek Ethernet Drivers](https://www.realtek.com/Download/List?cate_id=584) | Realtek |
| [Revo Uninstaller](https://www.revouninstaller.com/) | VS Revo Group |
| [SCEWIN](https://download.msi.com/uti_exe/desktop/MSI-Center.zip) | AMI, shipped by MSI inside MSI Center |
| [UnparkCPU](https://coderbag.com/Programming-C/Disable-CPU-Core-Parking-Utility) | CoderBag |
| [UserDiag](https://userdiag.com/) | SkyEmie (CTRL-F) |
| [Visual C++ Redistributable](https://learn.microsoft.com/en-us/cpp/windows/latest-supported-vc-redist) | Microsoft |
| [WPD](https://wpd.app/) | The WPD team |

## Ideas and research we learned from

| Project | Made by | What it taught us |
| --- | --- | --- |
| [Process Lasso](https://bitsum.com/) | Bitsum | Saved per-app CPU, I/O and priority rules that stay on, which is the idea behind the Governor. |
| [System Informer](https://github.com/winsiderss/systeminformer) | Winsiderss and contributors (MIT) | How Windows reads and sets I/O and memory priority, and which privileges each change needs. |
| [PresentMon](https://github.com/GameTechDev/PresentMon) | Intel (MIT) | How to measure per-frame timing for game checks. |
| [DiskSpd](https://github.com/microsoft/diskspd) | Microsoft (MIT) | Storage benchmark runs in our research. |
| [Win32 metadata](https://github.com/microsoft/win32metadata) | Microsoft | Windows API signatures we checked the native helpers against. |
| [ADLX](https://github.com/GPUOpen-LibrariesAndSDKs/ADLX) | AMD GPUOpen | What AMD's driver does and doesn't expose for GPU priority. |
| [Revo Uninstaller](https://www.revouninstaller.com/) | VS Revo Group | The leftover scan after an uninstall. Our cleanup route was checked against it. |
| [Kernel bug #1: ProcessIoPriority](https://waleedassar.blogspot.com/2013/02/kernel-bug-1-processiopriority.html) | Waleed Assar | His 2013 kernel analysis of the privilege check behind high I/O priority. |

## Libraries

| Library | Made by | License | Used in |
| --- | --- | --- | --- |
| [CommunityToolkit.Mvvm](https://github.com/CommunityToolkit/dotnet) | .NET Foundation and contributors | MIT | The desktop app |
| [Windows App SDK](https://github.com/microsoft/WindowsAppSDK) | Microsoft | MIT | The desktop app |
| [Windows SDK Build Tools](https://www.nuget.org/packages/Microsoft.Windows.SDK.BuildTools) | Microsoft | Microsoft Software License | Building the desktop app |
| [ClrMD](https://github.com/microsoft/clrmd) | Microsoft | MIT | A memory check in the validation tools |
| [Vortice.Windows](https://github.com/amerkoleci/Vortice.Windows) | Amer Koleci | MIT | GPU workloads in the validation tools |

## Fonts

| Font | Made by | License | Where |
| --- | --- | --- | --- |
| [Roboto Flex](https://github.com/googlefonts/roboto-flex) | The Roboto Flex Project Authors | SIL Open Font License 1.1 | The desktop app. License text: `docs/internal/frontend/RooIndustries.OptimizationSuite.App/Assets/Fonts/OFL.txt` |
| [Manrope](https://github.com/googlefonts/manrope) | The Manrope Project Authors | SIL Open Font License 1.1 | Brand assets. License text: `assets/brand/roo-industries/OFL.txt` |

## DNS presets

The DNS presets point at public resolvers run by [Cloudflare](https://one.one.one.one/), [Google Public DNS](https://developers.google.com/speed/public-dns), [Quad9](https://quad9.net/), [Mullvad](https://mullvad.net/en/help/dns-over-https-and-dns-over-tls), [AdGuard DNS](https://adguard-dns.io/) and [Cisco OpenDNS](https://www.opendns.com/). The app doesn't run or ship any of them.

## License texts

WinUtil's MIT license covers the definitions we adapted from it:

```text
MIT License

Copyright (c) 2022 CT Tech Group LLC

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

The font license texts sit next to each font file, as listed above.
