import json
from pathlib import Path


def sources(root):
    originals = {name: json.loads((root / 'backend/catalogs/sources' / (name + '.json')).read_text()) for name in ('oosu', 'wpd')}
    availability = [{'minimumBuild': 10240, 'maximumBuild': 26200, 'editions': ['*']}]
    records = []
    for profile in ('Domain', 'Private', 'Public'):
        records.append({'id': 'firewall-' + profile.lower(), 'name': profile + ' network firewall', 'category': 'Security', 'refresh': 'none', 'availability': availability,
                        'effects': {direction: [{'method': 'native', 'kind': 'firewall-profile', 'target': profile, 'property': 'enabled', 'value': value}]
                                    for direction, value in [('enabled', 'True'), ('disabled', 'False')]}, 'auxiliary': True, 'feature': 'firewallGlobalControl'})
    records.append({'id': 'firewall-service', 'name': 'Windows Firewall service', 'category': 'Services', 'refresh': 'none', 'availability': availability,
                    'effects': {'enabled': [{'method': 'native', 'kind': 'service', 'target': 'MpsSvc', 'property': 'startup', 'value': 2}, {'method': 'native', 'kind': 'service', 'target': 'MpsSvc', 'property': 'running', 'value': True}]}, 'auxiliary': True, 'feature': 'firewallGlobalControl'})
    wpd = dict(originals['wpd'], records=records)
    edge = {'id': 'edge-dns-over-https-auto', 'name': 'Microsoft Edge encrypted DNS', 'category': 'Apps and browsers', 'refresh': 'reopen affected apps', 'availability': availability,
            'sourceConstraints': {'requiresInstalledProduct': 'Microsoft Edge', 'minimumEdgeMajorVersion': 83}, 'auxiliary': True, 'feature': 'edge-dns-over-https-auto',
            'effects': {value: [{'method': 'registry-value', 'hive': 'HKLM', 'path': r'SOFTWARE\Policies\Microsoft\Edge', 'name': 'DnsOverHttpsMode', 'kind': 'String', 'operation': 'delete' if value == 'not-configured' else 'set', 'data': value}]
                        for value in ('off', 'automatic', 'secure', 'not-configured')}}
    return [(Path('wpd-extra.json'), wpd), (Path('oosu-extra.json'), dict(originals['oosu'], records=[edge]))]


def feature_coverage(root, coverage, extra, catalog):
    facts = json.loads((root / 'backend/catalogs/windows-source-features.json').read_text())
    features = []
    routes = {'copilot-app-removal': 'installed-apps:copilot', 'recall-data-erasure': 'windows:recall-data', 'installed-app-removal': 'installed-apps:all', 'custom-switches': 'tweak-custom-import',
              'restorePoint': 'restore-point-create', 'app-settings-and-cli': 'existing-app-settings-and-profile-state'}
    for feature in facts['linkedEffects'] + facts['features']:
        row = dict(feature)
        key = feature['id']
        row.pop('coverageStatus', None)
        if key in ('empty-policy-key-cleanup', 'factory-reset-policy-tree-cleanup'):
            row['status'] = 'normalized'; row['implementation'] = 'Restore captured values and prune only unchanged empty keys created by the operation.'
        elif key in routes:
            row['status'] = 'guided-action' if key == 'recall-data-erasure' else 'integrated-action' if key != 'app-settings-and-cli' else 'application-behavior'
            row['implementation'] = routes[key]
            if key == 'recall-data-erasure': row['scope'] = 'Open Windows Privacy settings and guide Recall snapshot deletion through its Windows Hello confirmation. This action does not claim deletion merely because the page opens.'
        elif key in ('ai-settings-group', 'privacy-presets'):
            row['status'] = 'shared-preset'; row['implementation'] = 'oosu.ai-settings' if key == 'ai-settings-group' else 'wpd.recommended'
        else:
            matching = [item for item in extra if item.get('feature') == key]
            row['status'] = 'shared-settings' if matching else 'pending'
            row['settings'] = sorted({choice['settingId'] for item in matching for option in item['options'] for choice in option['selections']})
        features.append(row)
    ai = next(feature for feature in facts['features'] if feature['id'] == 'ai-settings-group')
    members = {(item['sourceId'], item['variant']) for item in ai['members']}
    selections = [choice for item in coverage if item['product'] == 'O&O ShutUp10' and (item['sourceId'], item['variant']) in members
                  for option in item['options'] if option['id'] == 'apply' for choice in option['selections']]
    def add(identifier, name, choices):
        unique = {(item['settingId'], item['optionId']): item for item in choices}
        if unique: catalog['presets'].append({'id': identifier, 'name': name, 'selections': list(unique.values()), 'availableOnly': True})
    add('oosu.ai-settings', 'O&O ShutUp10 · AI settings available on this PC', selections)
    source = json.loads((root / 'backend/catalogs/sources/wpd.json').read_text())
    basic = {record['id'] for record in source['records'] if record['category'] in ('Local Group Policy', 'Services', 'Task Scheduler') and not record.get('sourceConstraints', {}).get('requiresExperimentalMode')}
    basic.add('bTelemetry')
    add('wpd.recommended', 'WPD · Recommended settings available on this PC', [choice for item in coverage if item['product'] == 'WPD' and item['sourceId'] in basic for option in item['options'] if option['id'] == 'apply' for choice in option['selections']])
    add('wpd.all-settings', 'WPD · All settings available on this PC', [choice for item in coverage if item['product'] == 'WPD' for option in item['options'] if option['id'] == 'apply' for choice in option['selections']])
    return features
