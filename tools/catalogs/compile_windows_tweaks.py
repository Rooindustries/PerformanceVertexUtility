import argparse
import base64
import copy
import hashlib
import json
from pathlib import Path
import re
import struct
import extra_windows_tweaks

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / 'backend/catalogs/sources'
SAMPLE_SUBMISSION = {0: 'Always ask before sending', 1: 'Windows default', 2: 'Never send samples', 3: 'Send all samples automatically'}


def encoded(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False)


def digest(value):
    return hashlib.sha256(encoded(value).encode()).hexdigest()[:16]


def identity(change):
    address = change['address']
    if 'controlValue' in change:
        return ('control', address['kind'].casefold(), address['target'].casefold(), address['property'].casefold(), ('mode',) if address['kind'] == 'hibernation' and 'mode' in change['controlValue'] else tuple(sorted(change['controlValue'])) if change.get('patch') else ())
    field = change.get('token', {}).get('name', '').casefold()
    bits = change.get('bits', {}).get('mask', 0)
    return tuple(str(address[key]).casefold() for key in ('hive', 'view', 'keyPath', 'valueName')) + (field, bits, encoded(change.get('selector')))


def desired(change):
    return {key: change[key] for key in ('dword', 'value', 'token', 'bits', 'controlValue', 'patch', 'formula') if key in change}


def value_label(change):
    if change['address'].get('kind') in ('mitigations', 'windows-features'):
        values = [value for key, value in change['value'].items() if 'Override' not in key]
        if len(set(values)) == 1:
            return {'ON': 'Enabled', 'OFF': 'Disabled', 'NOTSET': 'Windows default'}.get(values[0], str(values[0]))
    if 'hive' not in change['address']:
        value = change['value']
        if isinstance(value, bool):
            return 'Enabled' if value else 'Disabled'
        return str(value) if not isinstance(value, dict) else '; '.join(key + ': ' + str(item) for key, item in value.items())
    if change.get('dword') is not None:
        return 'Value ' + str(change['dword'])
    if change.get('token'):
        token = change['token']
        return token['name'] + ': ' + ('Remove override' if token['value'] is None else str(token['value']))
    if change.get('bits'):
        return 'Flags ' + hex(change['bits']['value']) + ' / ' + hex(change['bits']['mask'])
    if change.get('formula'):
        return {'installed-memory-kib': 'Use installed RAM size', 'menu-ownership': 'Open file ownership review', 'menu-startup': 'Open System Configuration', 'menu-power': 'Open Power Options'}[change['formula']]
    if change.get('value'):
        value = change['value']
        raw = base64.b64decode(value['bytes'])
        if value['type'] in (1, 2):
            return raw.decode('utf-16le').rstrip('\0') or 'Empty text'
        return 'Bytes ' + raw.hex(' ')
    return 'Remove this override'


def name_numbers(settings):
    for setting in settings:
        numbered = [(option, re.fullmatch(r'Value (-?\d+)(?: \(.*\))?', option['name'])) for option in setting['options']]
        if not any(match for _, match in numbered):
            continue
        values = {option['changes'][0].get('dword') for option in setting['options'] if option['changes'] and option['changes'][0].get('dword') is not None}
        switch = values <= {0, 1}
        field = words(setting['options'][0]['changes'][0]['address'].get('valueName', '')) if setting['options'][0]['changes'] else setting['name']
        for option, match in numbered:
            if match:
                number = int(match.group(1))
                option['name'] = ('On (1)' if number else 'Off (0)') if switch else field + ': ' + str(number)


def apply_windows_defaults(settings, coverage):
    values = json.loads((ROOT / 'backend/catalogs/windows-default-values.json').read_text())['values']
    rewritten = set()
    for value in values:
        found = 0
        for setting in settings:
            for option in setting['options']:
                removes = [change for change in option['changes'] if all(change['address'].get(field, '').casefold() == value[field].casefold() for field in ('hive', 'keyPath', 'valueName'))
                           and not any(change.get(key) is not None for key in ('dword', 'value', 'token', 'bits', 'formula'))]
                if not removes:
                    continue
                if len(option['changes']) != 1 or option.get('controls'):
                    raise ValueError('A choice removes a value Windows keeps together with other changes: ' + setting['id'] + '/' + option['id'])
                removes[0]['dword'] = value['dword']
                option['name'] = 'Windows default'
                rewritten.add((setting['id'], option['id']))
                found += 1
        if not found:
            raise ValueError('A value Windows keeps names no choice that removes it: ' + value['keyPath'] + '\\' + value['valueName'])
    for record in coverage:
        if any((selection['settingId'], selection['optionId']) in rewritten for option in record['options'] for selection in option['selections']):
            record['compatibility'] = ' '.join(filter(None, [record.get('compatibility'), 'Windows default writes the value Windows keeps instead of deleting it.']))


def apply_windows_types(catalog, coverage):
    values = json.loads((ROOT / 'backend/catalogs/windows-value-types.json').read_text())['values']
    converted, twins = set(), {}
    for value in values:
        for setting in catalog['settings']:
            for option in setting['options']:
                for change in option['changes']:
                    if change.get('dword') is None or not all(change['address'].get(field, '').casefold() == value[field].casefold() for field in ('hive', 'keyPath', 'valueName')):
                        continue
                    data = (str(change['dword']) + '\0').encode('utf-16le') if value['type'] == 'REG_SZ' else bytes([change['dword']])
                    change.update(dword=None, value={'name': change['address']['valueName'], 'type': {'REG_SZ': 1, 'REG_BINARY': 3}[value['type']], 'bytes': base64.b64encode(data).decode()})
                    converted.add((setting['id'], option['id']))
    for setting in catalog['settings']:
        for option in setting['options']:
            twin = next((other for other in setting['options'] if (setting['id'], option['id']) in converted and (setting['id'], other['id']) not in converted
                         and other['changes'] == option['changes'] and other.get('controls') == option.get('controls')), None)
            if twin is None:
                continue
            if twin.get('availability') != option.get('availability'):
                raise ValueError('A converted choice matches another choice with different availability: ' + setting['id'] + '/' + option['id'])
            option['sameAs'] = twin['id']
            twins[(setting['id'], option['id'])] = twin['id']
    for record in coverage:
        selections = [selection for option in record['options'] for selection in option['selections']]
        if any((selection['settingId'], selection['optionId']) in converted for selection in selections):
            record['compatibility'] = ' '.join(filter(None, [record.get('compatibility'), 'Writes the registry type Windows keeps for these values instead of a DWORD.']))
    for selection in [selection for preset in catalog['presets'] for selection in preset['selections']] + [selection for record in coverage for option in record['options'] for selection in option['selections']]:
        selection['optionId'] = twins.get((selection['settingId'], selection['optionId']), selection['optionId'])


def apply_availability(settings):
    alternatives = json.loads((ROOT / 'backend/catalogs/windows-setting-alternatives.json').read_text())
    ids = {setting['id'] for setting in settings}
    for setting in settings:
        original_gate = {'minimumBuild': setting['minimumBuild'], 'maximumBuild': setting['maximumBuild'], 'editions': setting['editions']}
        if setting['id'] in alternatives:
            setting['alternatives'] = alternatives[setting['id']]
            if not set(setting['alternatives']).issubset(ids):
                raise ValueError('A current policy alternative is missing')
        for option in setting['options']:
            changes = option['changes']
            if not changes:
                continue
            address = changes[0]['address']
            path = address['keyPath'].casefold()
            name = address.get('valueName', '').casefold()
            if path.endswith('policies\\microsoft\\edge') and name in ('metricsreportingenabled', 'sendsiteinfotoimproveservices'):
                for gate in option.get('availability', []):
                    gate['requirements'] = [text.replace('edge:77:87', 'edge:77:88') for text in gate.get('requirements', [])]
            if path.endswith('policies\\microsoft\\edge') and name == 'diagnosticdata':
                gates = option.setdefault('availability', [{'minimumBuild': setting['minimumBuild'], 'maximumBuild': setting['maximumBuild'], 'editions': setting['editions']}])
                for gate in gates:
                    gate['requirements'] = [text for text in gate.get('requirements', []) if not text.startswith('edge:')] + ['edge:122:999']
            if path.endswith('policies\\microsoft\\dsh') and name == 'allownewsandinterests':
                setting['minimumBuild'] = 22000
                for gate in option.get('availability', []):
                    gate['minimumBuild'] = 22000
            if not option.get('controls') and all(not any(change.get(key) is not None for key in ('dword', 'value', 'token', 'bits', 'formula', 'selector')) and '{' not in change['address']['keyPath'] for change in changes):
                for other in setting['options']:
                    other.setdefault('availability', [copy.deepcopy(original_gate)])
                option['availability'] = [{'minimumBuild': 10240, 'maximumBuild': 26200, 'editions': ['*']}]
                setting['minimumBuild'] = 10240
                setting['maximumBuild'] = 26200
                setting['editions'] = ['*']


def apply_policy_editions(catalog):
    policies = json.loads((ROOT / 'backend/catalogs/windows-policy-editions.json').read_text())['policies']
    constrained = set()
    equivalents = []
    for setting in catalog['settings']:
        for option in setting['options']:
            gates = copy.deepcopy(option.get('availability', [{'minimumBuild': setting['minimumBuild'], 'maximumBuild': setting['maximumBuild'], 'editions': setting['editions']}]))
            matched = False
            for change in option['changes']:
                if not any(change.get(field) is not None for field in ('dword', 'value', 'token', 'bits', 'formula')):
                    continue
                address = change['address']
                for policy in policies:
                    if not all(address.get(field, '').casefold() == policy[field].casefold() for field in ('hive', 'keyPath', 'valueName')) or 'dword' in policy and change.get('dword') != policy['dword']:
                        continue
                    matched = True
                    if 'equivalentChoice' in policy:
                        equivalents.append((setting, option, change, policy['equivalentChoice']))
                    for gate in gates:
                        gate['editions'] = policy['editions'] if '*' in gate['editions'] else sorted(edition for edition in gate['editions'] if any(edition.casefold().startswith(allowed[:-1].casefold()) if allowed.endswith('*') else edition.casefold() == allowed.casefold() for allowed in policy['editions']))
                    gates = [gate for gate in gates if gate['editions']]
            if matched:
                if not gates:
                    raise ValueError('A registry policy edition constraint excludes every source gate: ' + setting['id'] + '/' + option['id'])
                option['availability'] = gates
                constrained.add((setting['id'], option['id']))
    for setting, limited, change, equivalent in equivalents:
        if 'changes' in equivalent:
            replacement = [{'address': {'hive': item['hive'], 'view': 'Registry64', 'keyPath': item['keyPath'], 'kind': 'value', 'valueName': item['valueName']}, 'dword': item['dword']} for item in equivalent['changes']]
            identifier = digest(replacement)
        else:
            replacement = [{'address': change['address'], 'dword': equivalent['dword']}]
            identifier = digest(desired(replacement[0]))
        if any(option['changes'] == replacement for option in setting['options']):
            continue
        gates = [{'minimumBuild': setting['minimumBuild'], 'maximumBuild': setting['maximumBuild'], 'editions': equivalent.get('editions', ['*'])}]
        setting['options'].insert(setting['options'].index(limited) + 1, {'id': 'choice-' + identifier, 'name': equivalent['name'], 'changes': replacement, 'replaces': limited['id'], 'availability': copy.deepcopy(gates)})
        if 'changes' not in equivalent:
            continue
        remover = next((option for option in setting['options'] if option['changes'] == [{'address': change['address'], 'dword': None}]), None)
        if remover is None:
            raise ValueError('A per-user equivalent needs the row to have a choice that removes the policy: ' + setting['id'])
        reset = [{'address': change['address'], 'dword': None}] + [{'address': item['address'], 'dword': declared.get('windowsDefault')} for item, declared in zip(replacement, equivalent['changes'])]
        setting['options'].insert(setting['options'].index(remover) + 1, {'id': 'choice-' + digest(reset), 'name': remover['name'], 'changes': reset, 'replaces': remover['id'], 'availability': copy.deepcopy(gates)})
    for preset in catalog['presets']:
        optional = [item for item in preset['selections'] if (item['settingId'], item['optionId']) in constrained]
        if optional and not preset.get('availableOnly', False):
            preset['optionalSelections'] = optional


WINDOWS_REFUSED_SERVICES = {'wermgr', 'waasmedicsvc'}
WINDOWS_REFUSED_TASK_FOLDERS = ('\\microsoft\\windows\\waasmedic\\', '\\microsoft\\windows\\updateorchestrator\\')


def windows_refuses(change):
    address = change['address']
    if address.get('kind') == 'service':
        return address['target'].casefold() in WINDOWS_REFUSED_SERVICES
    if address.get('kind') == 'scheduled-task':
        return address['target'].casefold().startswith(WINDOWS_REFUSED_TASK_FOLDERS)
    return False


def incompatible_rules():
    return [{(item['settingId'], item['optionId']) for item in rule['selections']} for rule in json.loads((ROOT / 'backend/catalogs/incompatible-settings.json').read_text())['rules']]


def combines_incompatible(selections):
    chosen = {(item['settingId'], item['optionId']) for item in selections}
    return any(rule <= chosen for rule in incompatible_rules())


def mark_protected_services(settings):
    protected = {name.casefold() for name in json.loads((ROOT / 'modules/tweak_manifest.json').read_text())['protected']['services']}
    note = 'Windows, networking or connected devices depend on this service. Stopping or disabling it can break them until it is turned back on.'
    for setting in settings:
        targets = {control['address']['target'].casefold() for option in setting['options'] for control in option.get('controls', []) if control['address']['kind'] == 'service'}
        if targets & protected:
            setting['advanced'] = True
            if note not in setting['description']:
                setting['description'] = note + ' ' + setting['description']


def native(kind, target, property, value):
    return {'address': {'kind': kind, 'target': target, 'property': property}, 'controlValue': value}


def expand(effect):
    method = effect.get('method')
    if method == 'system-process-mitigation':
        mapping = json.loads((ROOT / 'backend/catalogs/windows-mitigations.json').read_text())
        result = []
        for parameter in effect['mitigations']:
            field = next(entry for entry in mapping if entry['parameter'] == parameter)
            result.append({'method': 'native-patch', 'kind': 'mitigations', 'target': 'system', 'property': 'policy', 'name': parameter, 'value': {field['group'] + '.' + field['field']: 'ON' if effect['operation'] == 'enable' else 'OFF', field['group'] + '.' + field['override']: False}})
        return result
    if method == 'service':
        name = effect['name']
        if effect.get('perUserTemplate'):
            return [effect]
        result = []
        startup = effect.get('startup', effect.get('startupType'))
        running = effect.get('running')
        if effect.get('operation') == 'stop-if-running-and-disable':
            startup, running = 4, False
        if effect.get('operation') == 'set-vendor-startup-and-start-if-default-run':
            startup = {'Automatic': 2, 'AutomaticDelayed': 2, 'Manual': 3, 'Disabled': 4}.get(effect['startupMode'])
            if effect.get('defaultRun'):
                running = True
            if effect['startupMode'] == 'AutomaticDelayed':
                result.append({'method': 'native', 'kind': 'service', 'target': name, 'property': 'delayed-start', 'value': True})
        if isinstance(startup, int):
            result.append({'method': 'native', 'kind': 'service', 'target': name, 'property': 'startup', 'value': startup})
        if isinstance(running, bool):
            result.append({'method': 'native', 'kind': 'service', 'target': name, 'property': 'running', 'value': running})
        if running == 'restart':
            result.append(effect)
        return result or [effect]
    if method == 'conditional' and effect.get('condition') == 'SysMain Start is not4':
        return effect['then']
    if method == 'registry-restore-from-backup-or-default':
        return [{'method': 'registry-value', 'hive': effect['hive'], 'path': effect['path'], 'name': name, 'kind': 'DWord', 'operation': 'set', 'data': value} for name, value in effect['fallbacks'].items()]
    if method == 'registry-values-selection':
        return [item for name in effect['names'] for item in expand(dict(effect, method='registry-value-selection', name=name))]
    if method == 'registry-value-selection' and 'roots' in effect['selector']:
        selector = dict(effect['selector'])
        roots = selector.pop('roots')
        return [dict(effect, selector=dict(selector, root=root)) for root in roots]
    return [effect]


def assignment(effect):
    method = effect.get('method')
    if method == 'menu-command':
        result = assignment(dict(effect, method='registry-value', operation='delete'))
        result['formula'] = effect['formula']
        return result
    if method == 'file-acl':
        targets = {
            r'{LocalAppData}\Packages\Microsoft.WindowsStore_8wekyb3d8bbwe\LocalState\store.db': ('store-search', 0x1f01ff),
            r'{SystemRoot}\Installer\Razer': ('razer-downloads', 0x116),
            r'{ProgramW6432-or-ProgramFiles}\LogiDownloadAssistant': ('logitech-downloads', 0x116),
        }
        if effect.get('target') in targets:
            target, mask = targets[effect['target']]
            if target in ('razer-downloads', 'logitech-downloads'):
                return native('download-blocker', target, 'blocked', effect['operation'] == 'deny')
            return native('file-acl', target, 'permissions', {'denyMask': mask, 'enabled': effect['operation'] == 'deny'})
    if method == 'power-plan' and effect.get('operation') == 'duplicate':
        return dict(native('power-plan', 'ultimate', 'selection', {'enabled': True}), patch=True)
    if method == 'power-plans' and effect.get('operation') == 'restore-default-schemes':
        return dict(native('power-plan', 'ultimate', 'selection', {'enabled': False}), patch=True)
    if method in ('hosts-append', 'hosts-text-rewrite'):
        return dict(native('hosts', 'system', 'adobe-block', {'enabled': method == 'hosts-append'}), patch=True)
    if method in ('registry-key', 'registry-key-delete'):
        path = effect.get('path', effect.get('target', '')).replace('HKCU:\\', '').replace('HKLM:\\', '')
        classic = r'Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}'
        if path.casefold() == classic.casefold():
            return assignment(dict(method='registry-value', hive='HKCU', path=classic + r'\InprocServer32', name='', operation='delete'))
        if path.casefold() == r'SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\smartscreen.exe'.casefold():
            return assignment(dict(method='registry-value', hive='HKLM', path=path, name='Debugger', operation='delete'))
    if method == 'registry' and effect.get('valueFormula') and effect.get('name') == 'SvcHostSplitThresholdInKB':
        change = assignment(dict(method='registry-value', hive=effect['hive'], path=effect['path'], name=effect['name'], operation='delete'))
        change['formula'] = 'installed-memory-kib'
        return change
    if method == 'powercfg-hibernation' or method == 'command' and effect.get('target', '').lower() == 'powercfg.exe' and effect.get('arguments', [])[:1] == ['/hibernate']:
        enabled = effect.get('enabled', effect.get('arguments', [None, 'off'])[1] == 'on')
        fields = {'mode': 'Full', 'enabled': 1, 'configuredType': 2} if enabled else {'mode': 'Off', 'enabled': 0}
        return dict(native('hibernation', 'system', 'configuration', fields), patch=True)
    if method == 'windows-optional-feature':
        name = effect.get('name', effect.get('target'))
        return dict(native('windows-features', 'system', 'features', {name: 'Enabled' if effect['operation'] == 'enable' else 'Disabled'}), patch=True)
    if method == 'native-patch':
        return dict(native(effect['kind'], effect['target'], effect['property'], effect['value']), patch=True)
    if method == 'registry-value-selection':
        selector = effect['selector']
        base = assignment(dict(effect, method='registry-value', hive=selector['hive'], path=selector['root']))
        if base is None:
            return None
        filter = selector.get('filter', '')
        rule = 'all'
        if filter == 'primary-network-interface-ids':
            rule = 'primary-interfaces'
        elif filter == 'primary-network-devices':
            rule = 'primary-network-devices'
        elif isinstance(filter, dict):
            rule = 'network-devices' if filter.get('DriverDesc') else 'device-classes'
        elif selector.get('suffix') and not selector.get('createSuffixIfMissing'):
            rule = 'existing-suffix'
        base['selector'] = {'depth': selector['depth'], 'suffix': selector.get('suffix', ''), 'filter': rule, 'existingValuesOnly': effect.get('existingValuesOnly', False)}
        if selector.get('targetRoot'):
            base['selector']['targetRoot'] = selector['targetRoot']
        return base
    if method == 'dns-over-https':
        return native('dns-over-https', effect['address'], 'configuration', {'template': effect['template'], 'allowFallback': False, 'autoUpgrade': True})
    if method == 'defender-preference':
        return native('defender', 'system', effect['target'], effect['value'])
    if method == 'cim-property-selection' and effect['className'] == 'MSPower_DeviceEnable':
        return native('device-power', 'non-network', 'enabled', effect['value'])
    if method == 'network-adapter-binding' and effect['target']['componentId'] == 'ms_tcpip6':
        return native('network-adapter', 'primary', 'ipv6-binding', effect['operation'] == 'enable')
    if method == 'environment-variable' and not effect.get('gate'):
        target = effect.get('registryAlias', {'hive': 'HKLM' if effect['scope'] == 'Machine' else 'HKCU', 'path': r'SYSTEM\CurrentControlSet\Control\Session Manager\Environment' if effect['scope'] == 'Machine' else 'Environment', 'name': effect['target']})
        return assignment(dict(method='registry-value', **target, kind='String', operation='delete' if effect['value'] in (None, '') else 'set', data=effect['value']))
    if method == 'task-cache-trigger-patch':
        prefix = r'SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\TaskCache\Tree'
        if effect['resolveGuidFrom'].startswith(prefix):
            return native('scheduled-task', effect['resolveGuidFrom'][len(prefix):], 'enabled', bool(effect['value'] & 64))
        return None
    if method == 'native':
        return native(effect['kind'], effect['target'], effect['property'], effect['value'])
    if method == 'service-startup':
        return native('service', effect['target'], 'startup', {'Automatic': 2, 'Manual': 3, 'Disabled': 4}[effect['startupType']])
    if method == 'scheduled-task':
        if effect['path'].lstrip('\\').startswith('FSOS-'):
            return None
        value = effect['value'] if effect['operation'] == 'set-enabled' else effect['operation'] == 'enable'
        return native('scheduled-task', '\\' + effect['path'].lstrip('\\'), 'enabled', value)
    if method == 'boot-configuration':
        value = None if effect['operation'] == 'delete' else effect['value'].lower() == 'yes' if effect['setting'] == 'disabledynamictick' else {'off': 0, 'auto': 1}[effect['value'].lower()]
        return native('boot-configuration', 'current', effect['setting'], value)
    if method == 'mmagent':
        return native('memory', 'system', 'compression', effect['enabled'])
    if method == 'filesystem-behavior':
        return native('filesystem', 'ntfs', 'last-access', effect['value'])
    if method == 'network-adapter-advanced-property':
        return assignment({'method': 'registry-value-selection', 'selector': {'hive': 'HKLM', 'root': r'SYSTEM\CurrentControlSet\Control\Class\{4D36E972-E325-11CE-BFC1-08002BE10318}', 'depth': 1, 'filter': 'primary-network-devices'}, 'name': effect['registryKeyword'], 'kind': 'String', 'operation': 'set', 'data': effect['registryValue'], 'existingValuesOnly': True})
    if method == 'network-adapter-feature':
        enabled = effect['api'].startswith('Enable')
        value = {'ipv4v1': enabled, 'ipv4': enabled, 'ipv6': enabled} if 'Lso' in effect['api'] else {'ipv4': enabled, 'ipv6': enabled}
        return native('network-adapter', 'primary', 'lso' if 'Lso' in effect['api'] else 'rsc', value)
    if method == 'firewall-blocklist':
        addresses = json.loads((ROOT / 'backend/catalogs/wpd-blocklists.json').read_text())['groups'][effect['group']]
        return native('firewall-blocklist', 'RooIndustries-Block-' + digest(addresses), 'rule', {'enabled': True, 'addresses': addresses})
    if method == 'command' and effect.get('target', '').lower() == 'netsh' and effect.get('arguments', [])[:4] == ['interface', 'teredo', 'set', 'state']:
        return native('teredo', 'system', 'type', effect['arguments'][-1].capitalize())
    if method == 'command' and effect.get('target', '').upper() == 'DISM' and '/Set-ReservedStorageState' in effect['arguments']:
        return native('reserved-storage', 'system', 'enabled', '/State:Enabled' in effect['arguments'])
    if method not in ('registry-value', 'registry-string-token', 'registry-bits'):
        return None
    hive = {'HKLM': 'LocalMachine', 'HKCU': 'CurrentUser', 'HKU': 'Users'}.get(effect['hive'])
    if hive is None or any(token in effect['path'] for token in ('{resolved-', '$', '%')):
        return None
    result = {'address': {'hive': hive, 'view': 'Registry64', 'keyPath': effect['path'], 'kind': 'value', 'valueName': effect['name']}, 'dword': None}
    power_fields = {
        (r'SYSTEM\CurrentControlSet\Control\Power'.casefold(), 'hiberfilesizepercent'): 'sizePercent',
        (r'SYSTEM\CurrentControlSet\Control\Power'.casefold(), 'hiberfiletype'): 'configuredType',
        (r'SYSTEM\CurrentControlSet\Control\Power'.casefold(), 'hibernateenableddefault'): 'defaultEnabled',
        (r'SYSTEM\CurrentControlSet\Control\Session Manager\Power'.casefold(), 'hiberbootenabled'): 'fastStartup',
    }
    field = power_fields.get((effect['path'].casefold(), effect['name'].casefold())) if hive == 'LocalMachine' else None
    if field and (effect['operation'] in ('delete', 'delete-value') or effect.get('kind') == 'DWord'):
        return dict(native('hibernation', 'system', 'configuration', {field: None if effect['operation'] in ('delete', 'delete-value') else int(effect['data'])}), patch=True)
    if method == 'registry-string-token':
        result['token'] = {'name': effect['token'], 'value': effect['value']}
        return result
    if method == 'registry-bits':
        result['bits'] = {key: effect[key] for key in ('mask', 'value', 'absentDefault')}
        return result
    if effect['operation'] in ('delete', 'delete-value'):
        return result
    if effect['operation'] not in ('set', 'write'):
        return None
    kind, value = effect.get('kind'), effect.get('data')
    if hive == 'LocalMachine' and effect['path'].casefold() == r'SYSTEM\CurrentControlSet\Control\Power'.casefold() and effect['name'] == 'HibernateEnabled':
        return dict(native('hibernation', 'system', 'configuration', {'mode': 'Full', 'enabled': 1, 'configuredType': 2} if int(value) else {'mode': 'Off', 'enabled': 0}), patch=True)
    service = re.fullmatch(r'SYSTEM\\(?:CurrentControlSet|ControlSet001)\\Services\\([^\\]+)', effect['path'], re.I)
    if hive == 'LocalMachine' and service and effect['name'].casefold() == 'start' and kind == 'DWord':
        return native('service', service.group(1), 'startup', int(value))
    if kind == 'DWord':
        result['dword'] = int(value, 0) if isinstance(value, str) else int(value)
        result['dword'] &= 0xffffffff
    elif kind in ('String', 'ExpandString'):
        if not isinstance(value, (str, int)) or isinstance(value, bool):
            raise ValueError('String setting has invalid data: ' + repr(effect))
        value = str(value)
        result['value'] = {'name': effect['name'], 'type': 1 if kind == 'String' else 2, 'bytes': base64.b64encode((value + '\0').encode('utf-16le')).decode()}
    elif kind == 'QWord':
        result['value'] = {'name': effect['name'], 'type': 11, 'bytes': base64.b64encode(struct.pack('<Q', int(value))).decode()}
    elif kind == 'Binary':
        if isinstance(value, str):
            value = bytes.fromhex(value.replace(',', '').replace(' ', ''))
        result['value'] = {'name': effect['name'], 'type': 3, 'bytes': base64.b64encode(bytes(value)).decode()}
    elif kind == 'MultiString':
        if not isinstance(value, list):
            return None
        result['value'] = {'name': effect['name'], 'type': 7, 'bytes': base64.b64encode(('\0'.join(value) + '\0\0').encode('utf-16le')).decode()}
    else:
        return None
    return result


def label(name):
    value = re.sub(r'^(Disable|Deactivate|Block|Turn off|Prevent|Allow|Enable)\s+', '', name, flags=re.I)
    return value[:1].upper() + value[1:]


def words(name):
    return re.sub(r'(?<=[a-z0-9])(?=[A-Z])', ' ', name.replace('HyperV', 'Hyper-V ')).replace('_', ' ').replace('  ', ' ').strip() or 'Default value'


def category(record, change):
    if 'controlValue' in change:
        return {'service': 'Services', 'scheduled-task': 'Scheduled tasks', 'network-adapter': 'Network', 'firewall-blocklist': 'Network', 'mitigations': 'Security'}.get(change['address']['kind'], 'System')
    path = change['address']['keyPath'].casefold()
    source = record['category'].casefold()
    if any(part in path for part in ('microsoft\\edge', 'microsoftedge', 'bravesoftware', 'google\\chrome', 'microsoft\\office')):
        return 'Apps and browsers'
    if any(part in path for part in ('windowsupdate', 'deliveryoptimization')):
        return 'Windows Update'
    if any(part in path for part in ('directx', 'graphicsdrivers', 'gamedvr', 'gamebar')):
        return 'Gaming and display'
    if any(part in path for part in ('explorer', 'themes', 'control panel\\desktop', 'dwm')):
        return 'Desktop and File Explorer'
    if any(part in path for part in ('tcpip', 'tcpip6', 'dnsclient', 'netbt', 'wcm', 'wlan', 'network')):
        return 'Network'
    if any(part in path for part in ('devic', 'mouse', 'keyboard', 'usb', 'audio')):
        return 'Devices'
    if any(part in path for part in ('defender', 'smartscreen', 'credentials', 'mitigation', 'deviceguard', 'security')):
        return 'Security'
    if any(part in source for part in ('privacy', 'location', 'activity', 'cortana', 'user behavior', 'diagnostic', 'synchron', 'policy', 'telemetry', 'permission', 'advertis')):
        return 'Privacy'
    return 'System'


def choice_name(direction, change):
    if 'controlValue' in change:
        value = change['controlValue']
        if change['address']['kind'] == 'service' and change['address']['property'] == 'startup':
            return {0: 'Boot', 1: 'System', 2: 'Automatic', 3: 'Manual', 4: 'Disabled'}[value]
        if isinstance(value, bool):
            return ('Running' if value else 'Stopped') if change['address']['property'] == 'running' else 'Enabled' if value else 'Disabled'
        if direction == 'source-default':
            return 'Windows default'
        if direction in ('enabled', 'disabled'):
            return direction.capitalize()
        if direction == 'apply' and change['address']['kind'] == 'defender':
            if change['address']['property'] != 'SubmitSamplesConsent':
                raise ValueError('No choice names for Defender ' + change['address']['property'])
            return SAMPLE_SUBMISSION[value]
        states = list(value.values()) if isinstance(value, dict) else [value]
        if direction == 'apply' and all(isinstance(state, str) for state in states) and len(set(states)) == 1:
            return states[0]
        return words(direction)
    if change.get('dword') is None and not any(key in change for key in ('value', 'token', 'bits')):
        return 'Not configured'
    return {'apply': 'Disabled', 'source-default': 'Enabled', 'enabled': 'Enabled', 'disabled': 'Disabled'}.get(direction, words(direction))


def apply_labels(settings):
    labels = json.loads((ROOT / 'backend/catalogs/windows-setting-labels.json').read_text())['records']
    def key(address):
        return tuple((name, str(value).casefold()) for name, value in sorted(address.items()) if name != 'token')
    matches = {}
    for row in labels:
        matches.setdefault(key(row['match']), []).append(row)
    for setting in settings:
        first = setting['options'][0]
        change = first['changes'][0] if first['changes'] else first['controls'][0]
        kind = change['address'].get('kind')
        if change['address'].get('valueName') in ('AllowRecallEnablement', 'DisableAIDataAnalysis'):
            availability = change['address']['valueName'] == 'AllowRecallEnablement'
            setting.update(name='Recall availability' if availability else 'Recall snapshots', description='This policy can delete saved Recall snapshots. Restoring the policy cannot recover deleted data. Allowing Recall does not enable recording without the user opting in.', advanced=False)
            for option in setting['options']:
                number = option['changes'][0].get('dword')
                option['name'] = 'Windows default' if number is None else ('Remove Recall and its snapshots' if number == 0 else 'Allow Recall') if availability else ('Off and delete saved snapshots' if number == 1 else 'Allow snapshot recording')
            continue
        if kind in ('file-acl', 'download-blocker', 'hosts', 'timer', 'timer-startup', 'power-plan', 'firewall-profile'):
            target = change['address']['target']
            names = {'store-search': 'Microsoft Store search database access', 'razer-downloads': 'Razer download folder writes', 'logitech-downloads': 'Logitech download folder writes', 'telemetry-consent': 'Windows customer experience program launch', 'compatibility-telemetry': 'Compatibility telemetry launch', 'diagnostic-runner': 'Diagnostic runner launch', 'application-telemetry': 'Application telemetry launch', 'device-census': 'Device Census launch'}
            setting['name'] = names[target] if kind in ('file-acl', 'download-blocker') else target + ' network firewall' if kind == 'firewall-profile' else {'hosts': 'Adobe network block list', 'timer': '0.5 ms timer request', 'timer-startup': 'Start timer at Windows sign-in', 'power-plan': 'Ultimate Performance power plan'}[kind]
            setting['description'] = {
                'file-acl': 'Changes only the reviewed permission on this existing file or folder. Other permissions and contents stay intact; already-open handles are unaffected. Restore returns the exact original permissions.',
                'hosts': 'Blocks 898 reviewed hostnames through the Windows hosts file. Existing entries and outside edits are preserved. This can prevent Adobe services from connecting.',
                'timer': 'Keeps an owned helper running with a 0.5 ms native timer request until stopped. This does not establish a game-wide timer change or a performance improvement.',
                'power-plan': 'Creates an owned copy of Ultimate Performance. Restore selects the previous plan and removes only that unchanged copy.',
                'download-blocker': 'Creates the download folder if needed and blocks new writes. Existing data is kept. Restore removes an app-created folder only when it is unchanged and empty.',
                'timer-startup': 'Starts the owned timer helper in your Windows session when you sign in. Enabling this also starts the current timer request.',
                'firewall-profile': 'Configures this local Windows Firewall profile. Group Policy can override its effective state.',
            }[kind]
            setting['advanced'] = kind in ('file-acl', 'download-blocker', 'firewall-profile')
            if kind in ('timer', 'timer-startup', 'power-plan', 'download-blocker', 'firewall-profile'): setting['refresh'] = 'none'
            for option in setting['options']:
                value = option['controls'][0]['value']
                enabled = value if isinstance(value, bool) else value == 'True' if isinstance(value, str) else value['enabled']
                option['name'] = ('Add restriction' if enabled else 'Remove this restriction') if kind == 'file-acl' else ('Start request' if enabled else 'Stop request') if kind == 'timer' else ('Use Ultimate Performance' if enabled else 'Return to previous plan') if kind == 'power-plan' else ('Block listed hosts' if enabled else 'Remove this block list')
                if kind in ('download-blocker', 'timer-startup', 'firewall-profile'): option['name'] = 'Enabled' if enabled else 'Disabled'
            continue
        if change['address'].get('valueName') == 'DnsOverHttpsMode':
            setting.update(name='Microsoft Edge encrypted DNS', description='Choose whether Edge uses encrypted DNS and permits an unencrypted fallback.', advanced=False)
            for option in setting['options']:
                value = option['changes'][0].get('value')
                choice = base64.b64decode(value['bytes']).decode('utf-16le').rstrip('\0') if value else 'not-configured'
                option['name'] = {'off': 'Off', 'automatic': 'Automatic with fallback', 'secure': 'Encrypted DNS only', 'not-configured': 'Not configured'}[choice]
            continue
        if change['address'].get('kind') == 'hibernation':
            fields = change['value']
            setting['name'] = 'Hibernation' if 'mode' in fields else 'Fast Startup' if 'fastStartup' in fields else 'Hibernation configuration'
            setting['description'] = 'Choose full hibernation or turn it off. Restore returns to the captured configuration.' if 'mode' in fields else 'Controls Fast Startup while preserving the current hibernation mode.'
            setting['advanced'] = False
            for option in setting['options']:
                value = option['controls'][0]['value']
                option['name'] = value['mode'] if 'mode' in value else ('Not configured' if value.get('fastStartup') is None else 'Enabled' if value['fastStartup'] else 'Disabled')
            continue
        possible = matches.get(key(change['address']), [])
        token = change.get('token', {}).get('name', '').casefold()
        row = next((row for row in possible if row['match'].get('token', {}).get('name', '').casefold() == token), None)
        if row is None:
            setting['advanced'] = setting['id'].startswith('windows.')
            if setting['advanced']:
                for option in setting['options']:
                    if option['changes']:
                        change = option['changes'][0]
                        option['name'] = value_label(change)
            continue
        if row['name']:
            setting['name'] = row['name'].replace(' — ', ': ')
        notes = list(dict.fromkeys(note for note in row['effectNotes'] + row['constraints'] if isinstance(note, str)))
        if row['semanticStatus'] == 'unknown':
            notes = ['Value meanings have not been verified. Review the exact target and value before applying.'] + [note for note in row['constraints'] if isinstance(note, str)]
        if notes:
            setting['description'] = ' '.join(notes)
        if row['refresh'] != 'unknown':
            setting['refresh'] = row['refresh']
        unresolved = False
        for option in setting['options']:
            change = option['changes'][0] if option['changes'] else option['controls'][0]
            label = next((choice for choice in row['choices'] if
                          encoded(choice.get('matchToken')) == encoded(desired(change)) if 'matchToken' in choice), None) if option['changes'] else next((choice for choice in row['choices'] if encoded(choice.get('matchValue', choice.get('value'))) == encoded(change['value'])), None)
            if label is not None:
                option['name'] = value_label(change) if label['semanticStatus'] == 'unknown' else label['label']
                unresolved |= label['semanticStatus'] != 'verified'
            else:
                unresolved = True
                option['name'] = value_label(change)
        setting['advanced'] = unresolved


def compile_catalog():
    catalog = json.loads((SOURCE / 'verified-settings.json').read_text())
    catalog['version'] = '2026-09-20.1'
    settings = catalog['settings']
    known = {}
    settings[:] = [setting for setting in settings if setting['options']]
    for setting in settings:
        identities = {identity(change) for option in setting['options'] for change in option['changes']}
        if len(identities) != 1:
            raise ValueError('Verified controls must have a single shared target')
        known[next(iter(identities))] = setting
    coverage, extra_coverage = [], []
    actions = json.loads((ROOT / 'backend/catalogs/windows-tweak-actions.json').read_text())['actions']
    auxiliary = json.loads((ROOT / 'backend/catalogs/windows-source-features.json').read_text())
    inputs = [(file, json.loads(file.read_text())) for file in sorted(SOURCE.glob('*.json')) if file.name != 'verified-settings.json'] + extra_windows_tweaks.sources(ROOT)
    for file, source in inputs:
        for record_index, record in enumerate(source['records']):
            gates = [gate for gate in record['availability'] if gate['maximumBuild'] >= gate['minimumBuild']]
            covered = {'product': source['product'], 'version': source['version'], 'sourceId': record['id'], 'name': record['name'], 'variant': record_index, 'options': []}
            if record.get('feature'): covered['feature'] = record['feature']
            for direction, effects in record['effects'].items():
                choices, pending = {}, []
                effects = copy.deepcopy(effects)
                if record['id'] in ('desktop-context-menu', 'Pro1'):
                    enabled = direction == ('enabled' if record['id'] == 'desktop-context-menu' else 'source-default')
                    menus = [(r'DesktopBackground\Shell\RooIndustries.PowerOptions', 'Power options', 'menu-power'), (r'DesktopBackground\Shell\RooIndustries.StartupOptions', 'Startup options', 'menu-startup')] if record['id'] == 'desktop-context-menu' else [(r'*\shell\RooIndustries.TakeOwnership', 'Take ownership with Roo Industries', 'menu-ownership'), (r'Directory\shell\RooIndustries.TakeOwnership', 'Take ownership with Roo Industries', 'menu-ownership')]
                    effects = []
                    for path, caption, formula in menus:
                        base = dict(hive='HKCU', path='Software\\Classes\\' + path, kind='String', operation='set' if enabled else 'delete')
                        effects.append(dict(base, method='registry-value', name='MUIVerb', data=caption))
                        effects.append(dict(base, method='registry-value', name='MultiSelectModel', data='Single'))
                        effects.append(dict(base, path=base['path'] + '\\command', name='', method='menu-command' if enabled else 'registry-value', formula=formula))
                    covered['compatibility'] = 'Register only menu values owned by this app. Power and startup entries open Windows review dialogs; ownership opens the app review before changing one selected item. Restore preserves unrelated menus.'
                if record['id'] == 'global-timer-resolution':
                    effects = [effect for effect in effects if effect.get('method') not in ('conditional', 'scheduled-task', 'process-stop')]
                    effects.append({'method': 'native', 'kind': 'timer', 'target': 'system', 'property': 'half-millisecond', 'value': direction == 'enabled'})
                    effects.append({'method': 'native', 'kind': 'timer-startup', 'target': 'system', 'property': 'enabled', 'value': direction == 'enabled'})
                    covered['startup'] = 'The owned worker continues after the UI closes and starts in the current user session at Windows sign-in.'
                for linked in record.get('linkedActions', []):
                    names = {r'{Windows}\System32\wsqmcons.exe': 'telemetry-consent', r'{Windows}\System32\compattelrunner.exe': 'compatibility-telemetry', r'{Windows}\System32\compattel\DiagTrackRunner.exe': 'diagnostic-runner', r'{Windows}\System32\aitagent.exe': 'application-telemetry', r'{Windows}\System32\devicecensus.exe': 'device-census'}
                    if linked.get('path') in names:
                        effects.append({'method': 'native', 'kind': 'file-acl', 'target': names[linked['path']], 'property': 'permissions', 'value': {'denyMask': 0x20, 'enabled': direction == 'apply'}})
                        covered['processRefresh'] = 'Restart Windows to close existing processes. Apply changes new-launch permissions; it does not force-stop processes.'
                for effect in [item for effect in effects for item in expand(effect)]:
                    change = assignment(effect)
                    if change is not None and windows_refuses(change):
                        change = None
                    if change is None:
                        pending.append(effect)
                        continue
                    if not gates:
                        continue
                    key = identity(change)
                    name = label(record['name'])
                    if len({(item.get('path'), item.get('name')) for item in effects}) > 1:
                        name += ': ' + words(effect['name'] if isinstance(effect.get('name'), str) else change['address'].get('valueName', change['address'].get('target', '')))
                    if key not in known:
                        setting = {'id': 'windows.' + digest(key), 'name': name, 'category': category(record, change),
                                   'description': 'Changes ' + name[:1].lower() + name[1:] + ('. Applies to this user.' if change['address'].get('hive') == 'CurrentUser' else '. Applies to this PC.'),
                                   'minimumBuild': min(gate['minimumBuild'] for gate in gates), 'maximumBuild': max(gate['maximumBuild'] for gate in gates),
                                   'editions': sorted({edition for gate in gates for edition in gate['editions']}), 'refresh': record['refresh'], 'options': [], 'sources': []}
                        settings.append(setting)
                        known[key] = setting
                    setting = known[key]
                    option_gates = copy.deepcopy(gates)
                    constraints = record.get('sourceConstraints', {})
                    requirements = []
                    if constraints.get('requiresInstalledProduct') == 'Microsoft Edge':
                        requirements.append('edge:' + str(constraints.get('minimumEdgeMajorVersion', 77)) + ':' + str(constraints.get('maximumEdgeMajorVersion', 999)))
                    if constraints.get('excludedWhenChromiumEdgeInstalled'): requirements.append('legacy-edge')
                    if constraints.get('excludedInRemoteSession'): requirements.append('local-session')
                    extra_gate = constraints.get('additionalGate', {})
                    if extra_gate.get('minimumMajorVersion'): requirements.append('edge-profile:' + str(extra_gate['minimumMajorVersion']) + ':999')
                    if extra_gate.get('contains') == 'Office16': requirements.append('office16')
                    for gate in option_gates:
                        if requirements: gate['requirements'] = requirements
                    matching_constraint = next((item for item in record.get('effectConstraints', []) if item.get('identity', {}).get('hive') == effect.get('hive') and item.get('identity', {}).get('path', '').casefold() == effect.get('path', '').casefold() and item.get('identity', {}).get('name', '').casefold() == effect.get('name', '').casefold()), None)
                    if matching_constraint and 'All' not in matching_constraint['supportedEditions']:
                        editions = {'Pro': ['Professional', 'ProfessionalN', 'ProfessionalEducation', 'ProfessionalEducationN', 'ProfessionalWorkstation', 'ProfessionalWorkstationN'], 'Enterprise': ['Enterprise', 'EnterpriseS', 'EnterpriseN', 'EnterpriseSN'], 'Education': ['Education', 'EducationN'], 'IoT': ['IoTEnterprise', 'IoTEnterpriseS'], 'Server': ['ServerStandard', 'ServerDatacenter']}
                        allowed = [edition for group in matching_constraint['supportedEditions'] for edition in editions.get(group, [group])]
                        for gate in option_gates: gate['editions'] = allowed if '*' in gate['editions'] else sorted(set(gate['editions']).intersection(allowed))
                        option_gates = [gate for gate in option_gates if gate['editions']]
                    if not option_gates: continue
                    if source['product'] == 'O&O ShutUp10' and 'office' in record['category'].casefold():
                        setting['requirements'] = ['office']
                    proof = {'product': source['product'], 'reference': source['reference'], 'evidence': source['version'] + ' · ' + record['id'] + ' · static source mapping'}
                    if proof not in setting['sources']:
                        setting['sources'].append(proof)
                    option = next((option for option in setting['options'] if desired(option['changes'][0]) == desired(change)), None) if 'controlValue' not in change else next((option for option in setting['options'] if option.get('controls', [{}])[0].get('value') == change['controlValue']), None)
                    if option is None:
                        option = {'id': 'choice-' + digest(desired(change)), 'name': choice_name(direction, change), 'changes': [] if 'controlValue' in change else [change], 'availability': option_gates}
                        if 'controlValue' in change:
                            option['controls'] = [{'address': change['address'], 'value': change['controlValue'], 'patch': change.get('patch', False)}]
                        setting['options'].append(option)
                    elif 'availability' in option:
                        for gate in option_gates:
                            if gate not in option['availability']:
                                option['availability'].append(copy.deepcopy(gate))
                    if setting['id'].startswith('windows.'):
                        setting['minimumBuild'] = min(setting['minimumBuild'], min(gate['minimumBuild'] for gate in gates))
                        setting['maximumBuild'] = max(setting['maximumBuild'], max(gate['maximumBuild'] for gate in gates))
                        setting['editions'] = sorted(set(setting['editions']).union(*(gate['editions'] for gate in gates)))
                    if record['id'] == 'WPFchangedns' and direction.startswith('Mullvad'):
                        option['validUntilUtc'] = '2026-11-02T00:00:00Z'
                    for rule in auxiliary['atomicDataLossRules']:
                        if change['address'].get('keyPath', '').casefold() == rule['path'].casefold() and change['address'].get('valueName', '').casefold() == rule['name'].casefold() and change.get('dword') == rule['desiredDword']:
                            option['dataLoss'] = ['Windows deletes saved Recall snapshots when this change takes effect. Restoring the setting cannot restore those snapshots.']
                    selection = {'settingId': setting['id'], 'optionId': option['id']}
                    if setting['id'] in choices and choices[setting['id']] != selection:
                        raise ValueError('Contradictory final values in ' + source['product'] + '/' + record['id'] + '/' + direction)
                    choices[setting['id']] = selection
                pending.extend(record.get('extraEffects', []))
                refresh_methods = {'shell-restart', 'process-restart', 'shell-notification', 'settings-broadcast', 'application-theme', 'RestartExplorer', 'RefreshShellAssoc', 'BroadcastWindowsSettingChange', 'RefreshTaskbar', 'BroadcastImmersiveColorChange', 'ApplyMouseAcceleration'}
                refresh_effects = [effect for effect in pending if effect.get('method') in refresh_methods or effect.get('kind') in ('shell-or-input-notification', 'live-system-parameter', 'process-restart') or effect.get('method') == 'service' and (effect.get('running') == 'restart' or effect.get('perUserTemplate')) or effect.get('method') == 'conditional' and effect.get('condition') == 'camsvc exists' or effect.get('method') == 'process-stop' and effect.get('target', {}).get('pattern', '').casefold() == 'explorer']
                recovery_effects = [effect for effect in pending if effect.get('method') == 'registry-snapshot-if-missing']
                pending = [effect for effect in pending if effect not in refresh_effects and effect not in recovery_effects]
                normalized = []
                for effect in pending:
                    method = effect.get('method')
                    if record['id'] == 'fault-tolerant-heap' and method == 'process-invocation':
                        normalized.append(effect); covered['compatibility'] = 'Disable FTH with its Enabled value and restart. Clearing learned history is a separate reset, not part of settings restoration.'
                    elif record['id'] == 'WPFTweaksDisableExplorerAutoDiscovery' and method == 'registry-key-delete':
                        normalized.append(effect); covered['compatibility'] = 'Set the default folder template without deleting saved folder views. Restore returns the original preference.'
                    elif record['id'] in ('WPFTweaksRazerBlock', 'WPFTweaksLogiBlock') and method in ('ensure-directory', 'delete-files', 'process-stop'):
                        normalized.append(effect); covered['compatibility'] = 'Create the folder if absent and restrict new writes. Keep existing files and processes. Restore removes an app-created folder only if it is unchanged and empty.'
                    elif record['id'] == 'WPFTweaksBlockAdobeNet' and (method == 'download-text' or method == 'command' and effect.get('target') == 'ipconfig'):
                        normalized.append(effect); covered['compatibility'] = 'Use the pinned reviewed hosts list. Restore removes only its owned block. Reopen affected apps or refresh the DNS cache after applying.'
                    elif record['id'] == 'WPFAddUltPerf' and method == 'power-plan' and effect.get('operation') == 'activate':
                        normalized.append(effect); covered['compatibility'] = 'Creation and activation share one owned operation. Restore selects the captured prior plan and removes only the owned copy.'
                if normalized:
                    covered.setdefault('normalizedEffects', []).extend(normalized)
                    pending = [effect for effect in pending if effect not in normalized]
                if refresh_effects:
                    for selection in choices.values():
                        next(setting for setting in settings if setting['id'] == selection['settingId'])['refresh'] = 'sign-out'
                if recovery_effects:
                    covered['recovery'] = 'Exact original snapshots in the shared engine replace the source backup keys.'
                if record['id'] in ('legacy-context-menu', 'WPFTweaksRightClickMenu'):
                    covered['compatibility'] = 'Remove only the classic-menu registration value; preserve unrelated COM registration data. Sign out to refresh Explorer.'
                if record['id'] == 'smart-screen':
                    covered['compatibility'] = 'Remove the IFEO Debugger override, preserving unrelated performance and tracing settings.'
                if record['id'] == 'user-account-control':
                    covered['enableChoice'] = 'Enable standard Windows UAC values; use Restore for the captured original values.'
                status = 'outside-supported-windows-range' if not gates else 'partial' if pending and choices else 'pending-executor' if pending else 'implemented' if choices else 'no-independent-change'
                if status == 'implemented' and combines_incompatible(choices.values()):
                    status = 'excluded-incompatible'
                row = {'id': direction, 'status': status, 'selections': list(choices.values()), 'remainingEffects': pending, 'refreshInstructions': 'Sign out or restart Windows after applying.' if refresh_effects else None}
                covered['options'].append(row)
                if choices and status == 'implemented':
                    preset_id = file.stem + '.' + record['id'].lower() + '.' + str(record_index) + '.' + direction
                    catalog['presets'].append({'id': preset_id, 'name': source['product'] + ' · ' + record['name'] + ' · ' + words(direction), 'selections': list(choices.values())})
            linked = [action for action in actions if record['id'] in action['sourceIds']]
            if linked:
                covered['actions'] = linked
                for option in covered['options']:
                    if option['remainingEffects']:
                        option['status'] = 'guided-action-with-settings' if option['selections'] else 'guided-action'
                        option['scope'] = 'Use the named app or Windows flow; the listed source side effects are not silently applied by a settings profile.'
            (extra_coverage if record.get('auxiliary') else coverage).append(covered)
    features = extra_windows_tweaks.feature_coverage(ROOT, coverage, extra_coverage, catalog)
    for setting in settings:
        for option in setting['options']:
            if any(control['address']['kind'] == 'timer-startup' and control['value'] is True for control in option.get('controls', [])):
                option['controls'].append({'address': {'kind': 'timer', 'target': 'system', 'property': 'half-millisecond'}, 'value': True, 'patch': False})
    settings[:] = [setting for setting in settings if setting['options']]
    for setting in settings:
        names = {}
        for option in setting['options']:
            names.setdefault(option['name'], []).append(option)
        for options in names.values():
            if len(options) > 1:
                for option in options:
                    value = desired(option['changes'][0]) if option['changes'] else {'controlValue': option['controls'][0]['value']}
                    hint = str(value['dword']) if value.get('dword') is not None else 'value ' + option['id'][-4:]
                    option['name'] += ' (' + hint + ')'
    apply_labels(settings)
    raw = [setting['id'] + ' ' + option['id'] for setting in settings for option in setting['options'] if re.match(r'(apply|source-default|enabled|disabled)( \(|$)', option['name'])]
    if raw:
        raise ValueError('Choices still named after their source direction: ' + ', '.join(raw))
    name_numbers(settings)
    apply_windows_defaults(settings, coverage + extra_coverage)
    apply_availability(settings)
    mark_protected_services(settings)
    apply_windows_types(catalog, coverage + extra_coverage)
    settings.sort(key=lambda setting: (setting['category'], setting['name'], setting['id']))
    rules = json.loads((ROOT / 'backend/catalogs/incompatible-settings.json').read_text())['rules']
    by_id = {setting['id']: setting for setting in settings}
    incompatible = []
    for rule in rules:
        selections = [{'settingId': item['settingId'], 'optionId': item['optionId']} for item in rule['selections']]
        if len(selections) < 2 or len({item['settingId'] for item in selections}) != len(selections):
            raise ValueError('An incompatible-settings rule needs two or more different settings')
        for item in selections:
            if item['optionId'] not in {option['id'] for option in by_id.get(item['settingId'], {}).get('options', [])}:
                raise ValueError('An incompatible-settings rule names a setting or choice that is not in the catalog: ' + item['settingId'])
        for item in selections:
            others = ', '.join(by_id[other['settingId']]['name'] for other in selections if other is not item)
            note = 'The app will not apply this together with ' + others + '. ' + rule['reason']
            if note not in by_id[item['settingId']]['description']:
                by_id[item['settingId']]['description'] = note + ' ' + by_id[item['settingId']]['description']
        pairs = {(item['settingId'], item['optionId']) for item in selections}
        catalog['presets'] = [preset for preset in catalog['presets'] if not pairs <= {(item['settingId'], item['optionId']) for item in preset['selections']}]
        incompatible.append({'selections': selections, 'reason': rule['reason']})
    if incompatible:
        catalog['incompatible'] = incompatible
    fps = ROOT / 'backend/catalogs/fps-preset.json'
    if fps.exists():
        source = json.loads(fps.read_text())
        choices = {setting['id']: {option['id'] for option in setting['options']} for setting in settings}
        selections = [{'settingId': item['settingId'], 'optionId': item['optionId']} for item in source['selections']]
        if len({item['settingId'] for item in selections}) != len(selections):
            raise ValueError('The FPS preset selects one setting more than once')
        for item in selections:
            if item['optionId'] not in choices.get(item['settingId'], ()):
                raise ValueError('The FPS preset names a setting or choice that is not in the catalog: ' + item['settingId'])
        if combines_incompatible(selections):
            raise ValueError('The FPS preset combines settings that cannot be used together')
        catalog['presets'].append({'id': 'fps-boost', 'name': source['name'], 'selections': selections, 'availableOnly': True})
    apply_policy_editions(catalog)
    return catalog, {'schemaVersion': 1, 'version': catalog['version'], 'records': coverage, 'additionalSettings': extra_coverage, 'features': features}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    catalog, coverage = compile_catalog()
    for name, data in [('windows-tweaks.json', catalog), ('windows-tweak-coverage.json', coverage)]:
        path = ROOT / 'backend/catalogs' / name
        expected = json.dumps(data, indent=2, ensure_ascii=False) + '\n'
        if args.check:
            if path.read_text() != expected:
                raise SystemExit('Catalog needs regeneration: ' + name)
        else:
            path.write_text(expected)
    print(json.dumps({'settings': len(catalog['settings']), 'presets': len(catalog['presets']), 'sourceRecords': len(coverage['records'])}))


if __name__ == '__main__':
    main()
