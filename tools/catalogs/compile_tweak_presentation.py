import argparse
import base64
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUTPUT = ROOT / 'docs/internal/frontend/RooIndustries.OptimizationSuite.App/Assets/Tweaks/presentation.json'
NETWORK = {
    'NetworkThrottlingIndex': ('Network traffic scheduling', 'Adjust how Windows balances network traffic with games and media.', 'Connection', {10: 'Windows balance', 4294967295: 'No traffic limit'}),
    'FastSendDatagramThreshold': ('Real-time network traffic', 'Adjust a connection preference used by apps that send frequent updates.', 'Connection', {64000: 'Use real-time preference'}),
    'NonBestEffortLimit': ('App bandwidth reservations', 'Choose whether apps can reserve part of your connection.', 'Connection', {0: 'No app reservations'}),
    '*EEE': ('Ethernet power saving', 'Reduce adapter power use when traffic is low. This can affect connection response.', 'Adapter', {'1': 'Enabled', '0': 'Disabled'}),
    '*InterruptModeration': ('Adapter responsiveness', 'Balance connection responsiveness and processor use. The best choice depends on your adapter.', 'Adapter', {'1': 'Balanced', '0': 'Lower delay preference'}),
    'DisableTaskOffload': ('Network processing', 'Choose how network work is shared with your adapter. This can affect processor use and throughput.', 'Adapter', {1: 'Use Windows processing'}),
    'TCPNoDelay': ('Small transfer responsiveness', 'Adjust responsiveness for apps that send frequent small updates. Applies to TCP connections.', 'Connection', {1: 'Send small updates promptly'}),
    'TcpAckFrequency': ('Connection response timing', 'Adjust a response preference for latency-sensitive TCP apps.', 'Connection', {1: 'Prompt responses'}),
    'NetbiosOptions': ('Older network compatibility', 'Support older PCs and shared devices. Disabling this can affect older local networks.', 'Local network', {0: 'Follow network configuration', 2: 'Disabled'}),
    'EnableMulticast': ('Local computer discovery', 'Find nearby computers by name. Some local sharing setups need this feature.', 'Local network', {0: 'Disabled', 1: 'Enabled'}),
    'DisabledComponents': ('Internet protocol preference', 'Choose a connection compatibility preference. Disabling IPv6 can affect apps and networks that need it.', 'Connection', {0: 'Windows default', 32: 'Prefer IPv4', 1: 'Disable IPv6 tunnels', 255: 'Disable IPv6 except loopback'}),
    'NoActiveProbe': ('Internet connection checks', 'Let Windows check whether this PC has internet access. Some sign-in pages and apps rely on the result.', 'Connection', {1: 'Disable active checks', 0: 'Enable active checks'}),
    'AutoConnectAllowedOEM': ('Automatic Wi-Fi connections', 'Control an older Windows Wi-Fi connection preference. Current Windows versions may no longer use it.', 'Wireless', {0: 'Disabled'}),
    'FeatureStates': ('Wi-Fi sharing preferences', 'Control legacy Wi-Fi sharing choices. These features are no longer part of current Windows versions.', 'Wireless', {}),
    'DODownloadMode': ('Share update downloads', 'Choose whether Windows shares update downloads with other PCs. Sharing can use upload bandwidth.', 'Connection', {0: 'Direct downloads only', 3: 'Share across the internet'}),
    'DnsOverHttpsMode': ('Edge encrypted DNS', 'Choose how Microsoft Edge protects website lookups.', 'DNS', {'off': 'Off', 'automatic': 'Allow unencrypted fallback', 'secure': 'Encrypted lookups only'}),
}
NATIVE_NETWORK = {
    ('network-adapter', 'lso'): ('Large upload handling', 'Adjust how larger uploads are handled. Support and performance depend on the adapter.', 'Adapter'),
    ('network-adapter', 'rsc'): ('Download processing', 'Balance download throughput and processor use on supported adapters.', 'Adapter'),
    ('network-adapter', 'ipv6-binding'): ('IPv6 on active connections', 'Use IPv6 on the active network adapters. Turning it off can interrupt apps or networks that depend on it.', 'Connection'),
    ('teredo', 'type'): ('Game network compatibility', 'Support multiplayer and party connections that need this compatibility feature. Turning it off can affect those apps.', 'Connection'),
}
WINDOWS_DEFAULTS = {
    ('SYSTEM\\CurrentControlSet\\Services\\Tcpip\\Parameters\\Interfaces', 'NameServer'): '',
    ('SYSTEM\\CurrentControlSet\\Control', 'SvcHostSplitThresholdInKB'): 0x380000,
    ('.Default\\Control Panel\\Keyboard', 'InitialKeyboardIndicators'): '2147483648',
    ('SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\ContentDeliveryManager', 'SubscribedContent-338389Enabled'): 1,
    ('SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\ContentDeliveryManager', 'SoftLandingEnabled'): 1,
}
BUILT_IN_DOH = {'1.1.1.1', '1.0.0.1', '2606:4700:4700::1111', '2606:4700:4700::1001', '8.8.8.8', '8.8.4.4', '2001:4860:4860::8888', '2001:4860:4860::8844', '9.9.9.9', '149.112.112.112', '2620:fe::fe', '2620:fe::9'}
EXPLOIT = ' (exploit protection)'
SECURITY = {
    ('defender', 'SubmitSamplesConsent'): ('Send suspicious files to Microsoft (Defender)', "Microsoft Defender can send files it isn't sure about to Microsoft for a closer look. Windows default sends files that are unlikely to hold personal data and asks before sending others. Never send keeps every file on this PC, but it also stops Defender from blocking brand-new threats on first sight."),
    ('mitigations', 'Aslr.BottomUp'): ('Randomize memory allocations' + EXPLOIT, "Puts each program's memory at less predictable spots, so attacks have a harder time finding what they target. In Windows Security: Randomize memory allocations (Bottom-up ASLR)."),
    ('mitigations', 'Dep.Enable'): ('Block code from running in data memory' + EXPLOIT, 'Stops programs from running code out of memory meant only for data, a common attack trick. 64-bit programs always have this on, so it only changes 32-bit programs. In Windows Security: Data Execution Prevention (DEP).'),
    ('mitigations', 'Aslr.HighEntropy'): ('Wider memory randomization for 64-bit programs' + EXPLOIT, 'Gives 64-bit programs a much larger range of random memory spots, which makes memory attacks harder. In Windows Security: High-entropy ASLR.'),
    ('mitigations', 'Sehop.Enable'): ('Check crash handlers before they run' + EXPLOIT, "Makes sure a program's error handling hasn't been tampered with before Windows runs it. Only 32-bit programs use this kind of error handling. In Windows Security: Validate exception chains (SEHOP)."),
    ('mitigations', 'Cfg.Enable'): ('Check where programs jump in their code' + EXPLOIT, 'Stops attacks from sending a program to code it was never meant to run. In Windows Security: Control flow guard (CFG).'),
    ('mitigations', 'StrictHandle.Enable'): ('Close programs that misuse system handles' + EXPLOIT, "Ends a program right away when it uses a Windows handle that isn't valid, instead of letting it carry on. Windows Security shows this only for each app, under Program settings: Validate handle usage."),
    ('mitigations', 'ExtensionPoint.DisableExtensionPoints'): ('Block old-style add-ins from loading into programs' + EXPLOIT, 'Stops older kinds of add-ins from loading themselves into every program. Windows Security shows this only for each app, under Program settings: Disable extension points.'),
    ('mitigations', 'Aslr.ForceRelocateImages'): ('Move every program to a new memory spot' + EXPLOIT, "Moves programs to a new memory spot even when they weren't built for it. With Randomize memory allocations on, that spot is hard to predict. Some older programs may not start. In Windows Security: Force randomization for images (Mandatory ASLR)."),
    ('mitigations', 'FontDisable.Audit'): ('Log untrusted font loads' + EXPLOIT, "Writes to Windows' event log when a program loads a font from outside the Windows fonts folder. It only logs; nothing is blocked. Windows Security shows this only for each app, under Program settings: Block untrusted fonts, audit mode."),
    ('mitigations', 'DynamicCode.Audit'): ('Log code created while programs run' + EXPLOIT, "Writes to Windows' event log when a program creates or changes code in memory as it runs. It only logs; nothing is blocked. Windows Security shows this only for each app, under Program settings: Arbitrary code guard (ACG), audit mode."),
    ('mitigations', 'ImageLoad.AuditRemoteImageLoads'): ('Log programs loading files from network shares' + EXPLOIT, "Writes to Windows' event log when a program loads a code file from another PC on the network. It only logs; nothing is blocked. Windows Security shows this only for each app, under Program settings: Block remote images, audit mode."),
    ('mitigations', 'Dep.EmulateAtlThunks'): ('Keep older programs working with data protection' + EXPLOIT, 'Lets older programs built on a common Windows code library keep running while data memory protection is on. Windows Security shows this only for each app, under Program settings: Enable ATL thunk emulation, part of Data Execution Prevention (DEP).'),
    ('mitigations', 'Cfg.SuppressExports'): ('Block direct jumps into shared functions' + EXPLOIT, "Tightens Control flow guard so attacks can't jump straight into a program's shared functions. Windows Security doesn't show this setting."),
    ('mitigations', 'DynamicCode.BlockDynamicCode'): ('Block code created while programs run' + EXPLOIT, 'Stops programs from creating or changing code in memory as they run. Browsers and some games rely on this and may not start. Windows Security shows this only for each app, under Program settings: Arbitrary code guard (ACG).'),
    ('mitigations', 'ImageLoad.BlockRemoteImageLoads'): ('Block programs loading files from network shares' + EXPLOIT, 'Stops programs from loading code files from another PC on the network. Windows Security shows this only for each app, under Program settings: Block remote images.'),
}
SECTIONS = {'Privacy': 'privacy', 'Apps and browsers': 'apps', 'Services': 'services', 'Devices': 'devices', 'Network': 'network', 'Desktop and File Explorer': 'windows', 'Windows & Explorer': 'windows', 'Windows Update': 'updates', 'Scheduled tasks': 'services', 'Security': 'security', 'Gaming and display': 'gaming', 'System': 'windows'}
NETWORK_SUMMARIES = {
    ('value', 'NetworkThrottlingIndex'): 'Balance network traffic with games and media.',
    ('value', 'FastSendDatagramThreshold'): 'Connection behavior for frequent app updates.',
    ('value', 'NonBestEffortLimit'): 'Control app bandwidth reservations.',
    ('value', '*EEE'): 'Lower power use can affect connection response.',
    ('value', '*InterruptModeration'): 'Trade off connection delay and CPU use.',
    ('value', 'DisableTaskOffload'): 'Can affect CPU use and throughput.',
    ('value', 'TCPNoDelay'): 'Response behavior for small TCP transfers.',
    ('value', 'TcpAckFrequency'): 'Response timing for latency-sensitive TCP apps.',
    ('value', 'NetbiosOptions'): 'Disabling can affect older local networks.',
    ('value', 'EnableMulticast'): 'Some local sharing setups need name discovery.',
    ('value', 'DisabledComponents'): 'Disabling IPv6 can affect apps and connectivity.',
    ('value', 'NoActiveProbe'): 'Some sign-in pages rely on these internet checks.',
    ('value', 'AutoConnectAllowedOEM'): 'Legacy Wi-Fi preference; may have no effect.',
    ('value', 'FeatureStates'): 'Legacy sharing features absent in current Windows.',
    ('value', 'DODownloadMode'): 'Sharing updates uses upload bandwidth.',
    ('value', 'DnsOverHttpsMode'): 'Protect website lookups in Microsoft Edge.',
    ('value', 'NameServer'): 'Choose DNS lookup and content-filtering services.',
    ('value', 'DohFlags'): 'Prefer encryption for the selected DNS provider.',
    ('network-adapter', 'lso'): 'Upload handling depends on adapter support.',
    ('network-adapter', 'rsc'): 'Balance download throughput and CPU use.',
    ('network-adapter', 'ipv6-binding'): 'Turning off can interrupt apps that need IPv6.',
    ('teredo', 'type'): 'Some multiplayer and party features need this.',
    ('service', 'Ndu'): 'Disabling tracking removes network usage totals.',
    ('dns-over-https', 'configuration'): 'Enable encrypted DNS; select the provider separately.',
    ('firewall-profile', 'enabled'): 'Turning this off reduces network protection.',
    ('firewall-blocklist', 'rule'): '2022 blocklist; may interrupt Microsoft services.',
}


def compile_presentation():
    catalog = json.loads((ROOT / 'backend/catalogs/windows-tweaks.json').read_text())
    coverage = json.loads((ROOT / 'backend/catalogs/windows-tweak-coverage.json').read_text())
    gaming = {row['id']: row['category'] for row in json.loads((ROOT / 'backend/catalogs/sources/gaming.json').read_text())['records']}
    source_sections = {}
    dns_choices = {}
    provider_members = {}
    for record in coverage['records']:
        category = gaming.get(record['sourceId']) if record['product'] == 'Gaming toggles' else None
        section = {'Network': 'network', 'CPU & Scheduling': 'gaming', 'GPU & Display': 'gaming', 'Input': 'devices', 'Security': 'security'}.get(category)
        for option in record['options']:
            for selection in option['selections']:
                if section:
                    source_sections[selection['settingId']] = section
                if record['product'] == 'Chris Titus Tech WinUtil' and record['sourceId'] == 'WPFchangedns':
                    provider = option['id'].replace('_', ' ').replace('Open DNS', 'OpenDNS')
                    dns_choices[(selection['settingId'], selection['optionId'])] = 'Automatic (network default)' if provider == 'DHCP' else provider
                    provider_members.setdefault(selection['settingId'], set()).add(provider)
    result = {}
    for setting in catalog['settings']:
        section = source_sections.get(setting['id'], SECTIONS.get(setting['category'], 'windows'))
        first = setting['options'][0]
        change = (first['changes'] or first.get('controls', []))[0]
        address = change['address']
        value_name = address.get('valueName', '')
        kind, prop = address.get('kind'), address.get('property')
        entry = {'section': section}
        if kind in ('download-blocker', 'windows-features'):
            entry['section'] = 'debloat'
        if kind == 'mitigations':
            entry['section'] = 'security'
        if 'office' in address.get('keyPath', '').lower() or any(word in setting['name'].lower() for word in ('diagnostic data', 'browsing history', 'telemetry', 'personal information')):
            entry['section'] = 'privacy'
        extras = setting['category'] in ('Apps and browsers', 'System', 'Desktop and File Explorer', 'Windows & Explorer') and any(word in setting['name'].lower() for word in ('advertis', 'sponsored', 'suggestion', 'recommendation', 'subscription button', 'ai-generated themes', 'bing chat', 'sidebar', 'shopping assistant', 'copilot', 'cortana'))
        if extras or 'contentdeliverymanager' in address.get('keyPath', '').lower() or 'copilot' in value_name.lower() or value_name in ('AllowNewsAndInterests', 'EnableFeeds', 'TaskbarDa', 'AllowCortana', 'AllowRecallEnablement', 'DisableAIDataAnalysis', 'DisableWindowsConsumerFeatures', 'DisableConsumerFeatures', 'SilentInstalledAppsEnabled'):
            entry['section'] = 'debloat'
        field = prop if kind == 'defender' else next((key for key in change['value'] if '.Override' not in key), None) if kind == 'mitigations' else None
        if (kind, field) in SECURITY:
            entry['name'], entry['description'] = SECURITY[(kind, field)]
            if kind == 'mitigations':
                entry['choices'] = {option['id']: {'ON': 'On', 'OFF': 'Off'}[option['controls'][0]['value'][field]] for option in setting['options']}
        copy = NETWORK.get(value_name)
        if copy:
            name, description, topic, labels = copy
            entry.update(section='network', name=name, description=description, topic=topic, choices={})
            for option in setting['options']:
                assignment = option['changes'][0]
                value = assignment.get('dword')
                if assignment.get('value', {}).get('type') in (1, 2):
                    value = base64.b64decode(assignment['value']['bytes']).decode('utf-16le').rstrip('\0')
                elif assignment.get('value', {}).get('type') == 4:
                    value = str(int.from_bytes(base64.b64decode(assignment['value']['bytes']), 'little'))
                entry['choices'][option['id']] = labels.get(value, 'Remove this preference' if value is None and not assignment.get('bits') else 'Use this preference')
        if (kind, prop) in NATIVE_NETWORK:
            name, description, topic = NATIVE_NETWORK[(kind, prop)]
            entry.update(section='network', name=name, description=description, topic=topic, choices={})
            for option in setting['options']:
                value = option['controls'][0]['value']
                enabled = all(value.values()) if isinstance(value, dict) else value
                entry['choices'][option['id']] = ('Disabled' if value == 'Disabled' else 'Windows default') if kind == 'teredo' else 'Enabled' if enabled else 'Disabled'
        if kind == 'service' and address['target'] == 'Ndu':
            entry.update(section='network', name='Network usage tracking', description='Show data usage totals for your connections. Disabling tracking removes those totals.', topic='Connection')
        if value_name == 'NameServer':
            family = 'IPv6' if 'tcpip6' in address['keyPath'].lower() else 'IPv4'
            entry.update(section='network', name='DNS provider · ' + family, description='Choose the service used to find websites. Some providers also filter ads or unwanted content.', topic='DNS', choices={o['id']: dns_choices[(setting['id'], o['id'])] for o in setting['options']})
        if kind == 'dns-over-https' or value_name == 'DohFlags':
            members = provider_members.get(setting['id'], set())
            provider = next(iter(members)) if len(members) == 1 else 'Mullvad shared' if members and all(p.startswith('Mullvad') for p in members) else 'Shared provider'
            suffix = 'encrypted lookups' if kind == 'dns-over-https' else 'encrypted DNS preference'
            entry.update(section='network', name=provider + ' · ' + suffix, description=('Make encrypted lookups available for this provider. Select the provider separately to use it.' if kind == 'dns-over-https' else 'Prefer encrypted lookups when this provider is selected on the active connection.'), topic='DNS', choices={o['id']: 'Use this preference' for o in setting['options']})
        if kind == 'firewall-profile':
            name = {'Domain': 'Work network firewall', 'Private': 'Trusted network firewall', 'Public': 'Public network firewall'}[address['target']]
            entry.update(section='network', name=name, description='Protect this type of connection. Turning the firewall off reduces its protection; organization rules may take precedence.', topic='Firewall')
        if kind == 'firewall-blocklist':
            entry.update(section='network', description='Block a saved list of connections. The list is dated 2022 and may interrupt Microsoft services; it does not cover every current address.', topic='Firewall')
        defaults = {item['address']['valueName']: WINDOWS_DEFAULTS[(item['address']['keyPath'], item['address']['valueName'])] for option in setting['options'] for item in option['changes']
                    if (item['address'].get('keyPath'), item['address'].get('valueName')) in WINDOWS_DEFAULTS}
        if defaults:
            entry['defaults'] = defaults
        if kind == 'dns-over-https' and address['target'] in BUILT_IN_DOH:
            entry['defaults'] = {prop: dict(change['value'], autoUpgrade=False)}
        if entry['section'] == 'network' and not entry.get('description'):
            raise ValueError('Missing network description: ' + setting['id'])
        if entry['section'] == 'network':
            summary_key = (kind, value_name if kind == 'value' else address.get('target') if kind == 'service' else prop)
            entry['summary'] = NETWORK_SUMMARIES[summary_key]
        result[setting['id']] = entry
    if len(result) != len(catalog['settings']):
        raise ValueError('Setting identity is not unique')
    distinguish(catalog, result)
    return result


def detail(setting, where):
    first = setting['options'][0]
    change = (first['changes'] or first.get('controls', []))[0]
    selector = change.get('selector') or {}
    value = change.get('value')
    if where.get('kind') == 'mitigations' and isinstance(value, dict):
        text = ', '.join(key.replace('.', ': ') for key in value if not key.split('.')[-1].startswith('Override'))
    elif selector.get('suffix'):
        text = selector['suffix'].rsplit('\\', 1)[-1]
    elif selector.get('filter'):
        text = {'primary-network-devices': 'active network adapters', 'network-devices': 'all network adapters', 'primary-interfaces': 'active connections'}.get(selector['filter'], selector['filter'].replace('-', ' '))
    elif any(option['changes'] and option['changes'][0].get('bits') for option in setting['options']):
        masks = sorted({option['changes'][0]['bits']['mask'] for option in setting['options'] if option['changes'] and option['changes'][0].get('bits')})
        text = 'flags ' + ', '.join(hex(mask) for mask in masks)
    elif first['changes'] and first['changes'][0].get('dword') is None and not first['changes'][0].get('value'):
        text = 'whole value'
    else:
        text = where.get('valueName') or where.get('target') or where.get('keyPath', '').rsplit('\\', 1)[-1]
    return re.sub(r'(?<=[a-z0-9])(?=[A-Z])', ' ', text).replace('_', ' ').strip() or 'default value'


def distinguish(catalog, result):
    settings = {setting['id']: setting for setting in catalog['settings']}
    def address(setting):
        first = setting['options'][0]
        return (first['changes'] or first.get('controls', []))[0]['address']
    def groups():
        names = {}
        for identifier, entry in result.items():
            names.setdefault((entry['section'], (entry.get('name') or settings[identifier]['name']).casefold()), []).append(identifier)
        return [members for members in names.values() if len(members) > 1]
    scopes = {'CurrentUser': 'this user', 'LocalMachine': 'all users'}
    for members in groups():
        if len({address(settings[identifier]).get('hive') for identifier in members}) > 1:
            for identifier in members:
                hive = address(settings[identifier]).get('hive')
                if hive in scopes:
                    result[identifier]['name'] = (result[identifier].get('name') or settings[identifier]['name']) + ' (' + scopes[hive] + ')'
    for members in groups():
        for identifier in members:
            result[identifier]['name'] = (result[identifier].get('name') or settings[identifier]['name']) + ' · ' + detail(settings[identifier], address(settings[identifier]))
    for members in groups():
        for identifier in members:
            where = address(settings[identifier])
            result[identifier]['name'] = (result[identifier].get('name') or settings[identifier]['name']) + ' · ' + (where.get('keyPath') or where.get('property') or identifier)
    if groups():
        raise ValueError('Setting names are not unique within a section')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    text = json.dumps(compile_presentation(), indent=2, ensure_ascii=False) + '\n'
    if args.check:
        if OUTPUT.read_text() != text:
            raise SystemExit('Tweak presentation needs regeneration')
    else:
        OUTPUT.parent.mkdir(parents=True, exist_ok=True)
        OUTPUT.write_text(text)
    print('Tweak presentation covers every catalog setting.')


if __name__ == '__main__':
    main()
