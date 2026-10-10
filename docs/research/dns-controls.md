# Windows DNS controls and recovery contract

Research date: 2026-09-19. Scope: native DNS integration for the WinUtil provider choices. Private machine-readable contract: `<private work folder>/four-tool-tweaks-20260919/winutil/dns-contract.json`. Windows probes targeted verified host `the i5-14600K test PC`, build 26200, and performed reads only.

## Recommended interface

Use **one resource per interface GUID and address family**, with family-specific DNS CIM instances for writes. Capture configured overrides separately from effective resolver addresses. `Get-DnsClientServerAddress` exposes interface identity, family and address arrays but does not expose DNS configuration origin. Its family selector accepts IPv4/IPv6; the setter accepts the selected CIM instance through `InputObject`. This avoids applying two unqualified index-based writes and assuming each affects only its intended family. [Get-DnsClientServerAddress](https://learn.microsoft.com/en-us/powershell/module/dnsclient/get-dnsclientserveraddress), [Set-DnsClientServerAddress](https://learn.microsoft.com/en-us/powershell/module/dnsclient/set-dnsclientserveraddress).

Bind the GUID to the current index immediately before apply and restore. Preserve PnP device identity, NetLuid and driver information as supporting evidence; an index or display name alone is insufficient after adapter replacement or renaming. Exclude protected access adapters, such as Tailscale, from implicit selection. This does not require a driver. [Network adapter fields](https://learn.microsoft.com/en-us/previous-versions/windows/desktop/legacy/hh968170(v=vs.85)), [GUID-to-LUID conversion](https://learn.microsoft.com/en-us/windows/win32/api/netioapi/nf-netioapi-convertinterfaceguidtoluid).

## What the native API establishes

`GetInterfaceDnsSettings`, `SetInterfaceDnsSettings` and `FreeInterfaceDnsSettings` are in `Iphlpapi.dll`; their documented minimum is Windows 10 build 19041. The getter takes a GUID by value and a structure pointer. Initialize only `Version`; the getter documentation requires empty `Flags`. Copy returned strings before freeing the object. A returned zero means success; any nonzero status is an error, not an empty configuration. [Getter](https://learn.microsoft.com/en-us/windows/win32/api/netioapi/nf-netioapi-getinterfacednssettings), [free function](https://learn.microsoft.com/en-us/windows/win32/api/netioapi/nf-netioapi-freeinterfacednssettings).

For static writes, version 1 uses `DNS_SETTING_NAMESERVER=0x2`, adding `DNS_SETTING_IPV6=0x1` for IPv6. Populate the NUL-terminated UTF16 server list and zero unflagged fields. The published API does **not** specify a DHCP-reset convention for NULL versus an empty `NameServer`; use the documented cmdlet reset instead of inventing one. The getter has no DHCP-origin enum, and its published empty-Flags requirement does not establish a family-selecting read API. [Setter](https://learn.microsoft.com/en-us/windows/win32/api/netioapi/nf-netioapi-setinterfacednssettings), [version 1 fields](https://learn.microsoft.com/en-us/windows/win32/api/netioapi/ns-netioapi-dns_interface_settings).

The private contract includes the x64 ABI: version 1 is 64 bytes and version 3 is 112 bytes, both confirmed in read probes. Version3 adds per-server DoH properties. Its structure documentation names build 19645; use actual version 3/API capability checks rather than assuming every system with the version 1 API supports DoH. [Version3 fields](https://learn.microsoft.com/en-us/windows/win32/api/netioapi/ns-netioapi-dns_interface_settings3).

## Static override versus automatic configuration

Read exact `NameServer` value existence, kind and raw data under these separate machine keys:

- IPv4: `SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\{GUID}`.
- IPv6: `SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters\Interfaces\{GUID}`.

Microsoft independently documents both paths. Its driver documentation also demonstrates that drivers can supply these values, so presence does not identify who configured them. Preserve `ProfileNameServer` separately; a profile override must not be discarded as an ordinary adapter setting. [Microsoft DNS registry mapping](https://learn.microsoft.com/en-us/windows-hardware/drivers/network/mb-dns-updates).

| Evidence | State and behavior |
| --- | --- |
| Readable nonempty same-family static list | Explicit adapter override; capture its ordered list and exact raw state. |
| Static override absent/empty; profile override absent/empty; adapter exists | No adapter static override. Label automatic configuration; do not claim an active DHCP lease merely from absence. |
| Nonempty profile override | Capture and bind that profile separately before modifying overlapping configuration. |
| Bad type, malformed address, wrong family, read failure or identity mismatch | Unknown/conflicting; reject a mutable plan until capture is valid. |

A nonempty effective list can come from DHCP. IP-address assignment's DHCP flag does not establish DNS origin. `netsh ... show dnsservers` can independently describe the current source, but its human-readable text is localized. The tested `netsh` dumps emitted no DNS records on this box, so absent dump lines cannot establish default state. [Netsh DNS commands](https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/netsh-interface).

For a static change, pass the exact family CIM instance to `Set-DnsClientServerAddress` with an ordered list. For automatic configuration, pass that instance with `ResetServerAddresses`. Reread both requested families and their configuration evidence. Restoring automatic configuration must not turn an earlier DHCP lease address into a permanent static address. Exact absent-versus-empty registry restoration is an additional requirement: these read-only probes do not establish that the cmdlet reproduces original raw existence. [Setter and reset semantics](https://learn.microsoft.com/en-us/powershell/module/dnsclient/set-dnsclientserveraddress).

## DoH configuration and exact undo

Global DoH entries are shared machine resources keyed by canonical server IP. Capture existence, `DohTemplate`, `AllowFallbackToUdp` and `AutoUpgrade`. To prove absence, enumerate the complete table successfully and match the address; a filtered lookup is documented to require an existing entry. Do not translate any lookup error into absence. [Get DoH configuration](https://learn.microsoft.com/en-us/powershell/module/dnsclient/get-dnsclientdohserveraddress).

| Original state | Apply | Restore |
| --- | --- | --- |
| Entry absent | Add the requested tuple. | Remove only the still-owned entry after its other owners release it; verify absence. |
| Entry present | Set the requested tuple. | Restore the original template and both booleans; add it back if absent. |
| Entry unreadable or changed outside the transaction | Do not assume defaults. | Preserve the conflict for recovery rather than overwriting it. |

Always pass both booleans explicitly: omitted flags can reset to false. `AutoUpgrade=true` also affects the same resolver used on another adapter or through NRPT, so per-adapter ownership alone is insufficient. [Add DoH entry](https://learn.microsoft.com/en-us/powershell/module/dnsclient/add-dnsclientdohserveraddress), [set DoH entry](https://learn.microsoft.com/en-us/powershell/module/dnsclient/set-dnsclientdohserveraddress), [remove DoH entry](https://learn.microsoft.com/en-us/powershell/module/dnsclient/remove-dnsclientdohserveraddress).

WinUtil additionally writes per-interface `DohFlags` under Dnscache interface settings. That registry layout is retained as upstream evidence, not labeled a Microsoft management API. The supported native alternative is version 3 DNS interface settings with server properties. `ENABLE_AUTO=1` uses the global template and requires NULL `Template`; `ENABLE=2` uses an explicit template. Those flags are mutually exclusive. Fallback is 4 and cannot stand alone. Preserve all existing per-interface/profile properties during restore. [Server properties](https://learn.microsoft.com/en-us/windows/win32/api/netioapi/ns-netioapi-dns_server_property), [DoH property flags](https://learn.microsoft.com/en-us/windows/win32/api/netioapi/ns-netioapi-dns_doh_server_settings).

Configured DoH is not proof that a particular query used encrypted transport. Any claim of active encryption requires separate traffic/resolver evidence. A DHCP reset must never indiscriminately delete pre-existing global resolver templates.

## Provider definitions and availability

The private contract retains all 14 pinned WinUtil provider definitions, including address order and secondary templates. Default means no change; DHCP means automatic reset. Each Mullvad option requires DoH and must fail rather than fall back to plaintext when encrypted configuration is unavailable. Source Mullvad primary/secondary addresses sometimes use different filtering profiles; the UI must not claim identical filtering on both. [Pinned WinUtil provider definitions](https://github.com/ChrisTitusTech/winutil/blob/fc60cbde09d669178bda1665be9cb1a703516fca/config/dns.json).

Mullvad announced that its public encrypted DNS service ends **November 2, 2026**. Preserve source coverage but record that availability limit. Quad9's current official documentation confirms that the pinned `2620:fe::9` secondary is valid. Cisco continues supporting the older `doh.opendns.com` endpoint. [Mullvad notice](https://mullvad.net/en/help/dns-over-https-and-dns-over-tls), [Quad9 addresses](https://docs.quad9.net/services/), [Cisco DoH compatibility](https://umbrella.cisco.com/blog/enhancing-support-dns-encryption-with-dns-over-https).

## Read-only evidence and remaining verification

On the the i5-14600K test PCXT, Ethernet 3 has a DHCP-supplied IPv4 resolver while the native API returns an empty static `NameServer`. Version1 and version 3 getters succeeded for both active adapters; removed tunnel interfaces returned status 2. The DoH cmdlets were present and returned 12 existing global entries. No adapter had a nonempty static/profile override available to inspect. The exact observations and source hashes are saved privately beside `dns-contract.json`.

No network setting was changed. Static apply, independent IPv4/IPv6 preservation, exact absent-state restoration, pre-existing DoH override restoration and partial-failure rollback remain unexecuted. The contract supports implementing those paths; a controlled fixture or explicitly approved network test is still needed to verify writes.
