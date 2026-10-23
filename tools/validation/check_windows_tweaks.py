import copy
import json
import re
from pathlib import Path

from jsonschema import Draft202012Validator


NEVER_IN_FPS_PRESET = {'windows.6ae403065279ea14'}


def edition_overlap_failures(catalog, exceptions):
    failures = []
    for setting in catalog['settings']:
        for option in setting['options']:
            gates = option.get('availability', [])
            overlaps = any(
                '*' in wildcard['editions'] and '*' not in restricted['editions'] and
                max(setting['minimumBuild'], wildcard['minimumBuild'], restricted['minimumBuild']) <=
                min(setting['maximumBuild'], wildcard['maximumBuild'], restricted['maximumBuild'])
                for wildcard in gates for restricted in gates
            )
            if overlaps and (setting['id'], option['id']) not in exceptions:
                failures.append('A wildcard overrides an edition restriction for overlapping builds: ' + setting['id'] + '/' + option['id'])
    return failures


def policy_matches(change, policy):
    address = change['address']
    return (all(address.get(field, '').casefold() == policy[field].casefold() for field in ('hive', 'keyPath', 'valueName')) and
            any(change.get(field) is not None for field in ('dword', 'value', 'token', 'bits', 'formula')) and
            ('dword' not in policy or change.get('dword') == policy['dword']))


def edition_allowed(edition, editions):
    return any(edition.casefold().startswith(item[:-1].casefold()) if item.endswith('*') else edition.casefold() == item.casefold() for item in editions)


def policy_gate_failures(catalog, policies):
    failures = []
    for setting in catalog['settings']:
        for option in setting['options']:
            gates = option.get('availability', [{'editions': setting['editions']}])
            for policy in policies:
                if not any(policy_matches(change, policy) for change in option['changes']):
                    continue
                if any(not edition_allowed(edition, policy['editions']) for gate in gates for edition in gate['editions']):
                    failures.append('A choice Windows ignores on some editions is offered there: ' + setting['id'] + '/' + option['id'])
                equivalent = policy.get('equivalentChoice')
                if equivalent and not any(
                    [change['address'] for change in other['changes']] == [option['changes'][0]['address']] and other['changes'][0].get('dword') == equivalent['dword'] and
                    any('*' in gate['editions'] for gate in other.get('availability', [{'editions': setting['editions']}]))
                    for other in setting['options']
                ):
                    failures.append('Editions without ' + option['name'] + ' need the documented equivalent choice: ' + setting['id'])
    return failures


REMOVE_OVERRIDE_ID = 'choice-c4697634bc8964cb'


def windows_default_failures(catalog, values):
    failures = []
    for value in values:
        def kept(change):
            return all(change['address'].get(field, '').casefold() == value[field].casefold() for field in ('hive', 'keyPath', 'valueName'))
        settings = [setting for setting in catalog['settings'] if any(kept(change) for option in setting['options'] for change in option['changes'])]
        if not settings:
            failures.append('A value Windows keeps names no catalog setting: ' + value['keyPath'] + '\\' + value['valueName'])
        for setting in settings:
            for option in setting['options']:
                if any(kept(change) and not any(change.get(field) is not None for field in ('dword', 'value', 'token', 'bits', 'formula')) for change in option['changes']):
                    failures.append('A choice deletes a value Windows keeps: ' + setting['id'] + '/' + option['id'])
            defaults = [option for option in setting['options'] if option['name'] == 'Windows default']
            if [[change.get('dword') if kept(change) else None for change in option['changes']] for option in defaults] != [[value['dword']]]:
                failures.append('Windows default must write the value Windows keeps: ' + setting['id'])
            elif defaults[0]['id'] != REMOVE_OVERRIDE_ID:
                failures.append('Windows default must keep the choice ID that saved choices and profiles use: ' + setting['id'])
    return failures


def check(root):
    failures = []
    catalog = json.loads((root / 'backend/catalogs/windows-tweaks.json').read_text())
    schema = json.loads((root / 'backend/contracts/roo-industries-backend-contracts.schema.json').read_text())
    validator = Draft202012Validator({'$defs': schema['$defs'], '$ref': '#/$defs/windowsTweaksCatalog'})
    settings = catalog['settings']
    policy_editions = json.loads((root / 'backend/catalogs/windows-policy-editions.json').read_text())
    exceptions = {(item['settingId'], item['optionId']) for item in policy_editions['allowedOverlaps'] if item.get('reference') and item.get('quote') and item.get('reason')}
    failures.extend(edition_overlap_failures(catalog, exceptions))
    wildcard = {'minimumBuild': 10240, 'maximumBuild': 26100, 'editions': ['*']}
    restricted = {'minimumBuild': 26100, 'maximumBuild': 26200, 'editions': ['Enterprise']}
    fixture = {'settings': [{'id': 'fixture', 'minimumBuild': 10240, 'maximumBuild': 26200, 'options': [{'id': 'blocked', 'availability': [wildcard, restricted]}]}]}
    if not edition_overlap_failures(fixture, set()):
        failures.append('Edition overlap check must reject a shared inclusive build endpoint.')
    if edition_overlap_failures(fixture, {('fixture', 'blocked')}):
        failures.append('Edition overlap check must allow an explicitly reviewed choice.')
    if not edition_overlap_failures(fixture, {('fixture', 'another-choice')}):
        failures.append('Edition overlap exceptions must not cover other choices of a setting.')
    restricted['minimumBuild'] = 26101
    if edition_overlap_failures(fixture, set()):
        failures.append('Edition overlap check must allow disjoint build ranges.')
    failures.extend(policy_gate_failures(catalog, policy_editions['policies']))
    policy = {'hive': 'LocalMachine', 'keyPath': 'Fixture', 'valueName': 'Level', 'dword': 0, 'editions': ['Enterprise*'], 'equivalentChoice': {'dword': 1}}
    address = {'hive': 'LocalMachine', 'keyPath': 'fixture', 'valueName': 'level'}
    def gated(editions, extra=()):
        options = [{'id': 'off', 'name': 'Off', 'changes': [{'address': address, 'dword': 0}], 'availability': [{'editions': editions}]}, *extra]
        return {'settings': [{'id': 'fixture', 'editions': ['*'], 'options': options}]}
    required = {'id': 'required', 'name': 'Required', 'changes': [{'address': address, 'dword': 1}], 'availability': [{'editions': ['*']}]}
    if not policy_gate_failures(gated(['*'], [required]), [policy]):
        failures.append('Policy edition check must reject a limited value offered on every edition.')
    if not policy_gate_failures(gated(['Enterprise', 'Professional'], [required]), [policy]):
        failures.append('Policy edition check must reject a limited value offered on an edition outside its families.')
    if policy_gate_failures(gated(['Enterprise', 'EnterpriseS', 'Enterprise*'], [required]), [policy]):
        failures.append('Policy edition check must allow a limited value inside its edition families.')
    if not policy_gate_failures(gated(['Enterprise']), [policy]):
        failures.append('Policy edition check must require the documented equivalent choice on other editions.')
    if policy_gate_failures(gated(['Enterprise'], [required, {'id': 'full', 'name': 'Full', 'changes': [{'address': address, 'dword': 3}], 'availability': [{'editions': ['*']}]}, {'id': 'remove', 'name': 'Remove', 'changes': [{'address': address, 'dword': None}]}]), [policy]):
        failures.append('Policy edition check must leave other values and override removal on every edition.')
    windows_defaults = json.loads((root / 'backend/catalogs/windows-default-values.json').read_text())['values']
    failures.extend(windows_default_failures(catalog, windows_defaults))
    kept = {'hive': 'LocalMachine', 'keyPath': 'Fixture', 'valueName': 'value', 'dword': 0}
    def stock(*options):
        return {'settings': [{'id': 'fixture', 'options': [{'id': identifier, 'name': name, 'changes': [{'address': {'hive': 'LocalMachine', 'keyPath': 'fixture', 'valueName': 'VALUE'}, 'dword': dword}]} for identifier, name, dword in options]}]}
    if not windows_default_failures(stock((REMOVE_OVERRIDE_ID, 'Remove this override', None), ('on', 'On (1)', 1)), [kept]):
        failures.append('Windows default check must reject a choice that deletes a value Windows keeps.')
    if not windows_default_failures(stock(('choice-95a6ed84299d0109', 'Windows default', 0), ('on', 'On (1)', 1)), [kept]):
        failures.append('Windows default check must reject a Windows default with a new choice ID.')
    if not windows_default_failures(stock((REMOVE_OVERRIDE_ID, 'Windows default', 1), ('on', 'Off (0)', 0)), [kept]):
        failures.append('Windows default check must reject a Windows default that writes another value.')
    if windows_default_failures(stock((REMOVE_OVERRIDE_ID, 'Windows default', 0), ('on', 'On (1)', 1)), [kept]):
        failures.append('Windows default check must allow a Windows default that writes the value Windows keeps.')
    if not windows_default_failures(stock((REMOVE_OVERRIDE_ID, 'Windows default', 0)), [dict(kept, valueName='other')]):
        failures.append('Windows default check must reject a value Windows keeps that names no setting.')
    powers = [setting for setting in settings if any(control['address']['kind'] == 'hibernation' for option in setting['options'] for control in option.get('controls', []))]
    modes = [setting for setting in powers if any('mode' in control['value'] for option in setting['options'] for control in option.get('controls', []))]
    startup = [setting for setting in powers if any('fastStartup' in control['value'] for option in setting['options'] for control in option.get('controls', []))]
    if len(modes) != 1 or len(startup) != 1:
        failures.append('Hibernation mode and Fast Startup must each have one shared setting.')
    for setting in settings:
        for option in setting['options']:
            if option['name'] == 'Source value' or option['name'].startswith('Set ') and ' value to ' in option['name']:
                failures.append('A choice must show its meaning or actual value: ' + setting['id'])
            for change in option['changes']:
                address = change['address']
                if change.get('formula', '').startswith('menu-') and 'RAM' in option['name']:
                    failures.append('A menu command must not be labeled as a memory formula: ' + setting['id'])
                if address['hive'] == 'LocalMachine' and address['keyPath'].casefold() == r'SYSTEM\CurrentControlSet\Control\Session Manager\Power'.casefold() and address['valueName'].casefold() == 'hiberbootenabled':
                    failures.append('Fast Startup must share native power ownership, not a separate registry writer.')
    bad_cases = []
    registry = next(index for index, setting in enumerate(settings) if setting['options'][0]['changes'])
    native = next(index for index, setting in enumerate(settings) if setting['options'][0].get('controls'))
    bad = copy.deepcopy(catalog); del bad['settings'][registry]['options'][0]['changes'][0]['dword']; bad_cases.append(('missing desired registry value', bad))
    bad = copy.deepcopy(catalog); bad['settings'][registry]['options'][0]['changes'][0].update(dword=1, token={'name': 'field', 'value': 'on'}); bad_cases.append(('contradictory registry encodings', bad))
    bad = copy.deepcopy(catalog); del bad['settings'][native]['options'][0]['controls'][0]['value']; bad_cases.append(('missing native value', bad))
    bad = copy.deepcopy(catalog); bad['settings'][native]['options'][0]['controls'][0]['address']['kind'] = 'unreviewed-command'; bad_cases.append(('unknown native executor', bad))
    bad = copy.deepcopy(catalog); bad['settings'][registry]['options'][0]['changes'] = []; bad_cases.append(('empty setting operation', bad))
    for name, invalid in bad_cases:
        if validator.is_valid(invalid):
            failures.append('Catalog negative control accepted ' + name)
    coverage = json.loads((root / 'backend/catalogs/windows-tweak-coverage.json').read_text())
    expected = {'O&O ShutUp10': 376, 'WPD': 110, 'Gaming toggles': 79, 'Chris Titus Tech WinUtil': 67}
    actual = {product: sum(record['product'] == product for record in coverage['records']) for product in expected}
    if actual != expected:
        failures.append('Pinned source inventory coverage changed: ' + str(actual))
    if any(option['status'] == 'implemented' and option['remainingEffects'] for record in coverage['records'] for option in record['options']):
        failures.append('A source control with unresolved effects cannot be marked implemented.')
    feature_facts = json.loads((root / 'backend/catalogs/windows-source-features.json').read_text())
    expected_features = {item['id'] for item in feature_facts['linkedEffects'] + feature_facts['features']}
    if {item['id'] for item in coverage['features']} != expected_features:
        failures.append('Linked effects and additional source features must remain in the coverage inventory.')
    settings_by_id = {item['id']: item for item in settings}
    preset_ids = {item['id'] for item in catalog['presets']}
    fps_source = root / 'backend/catalogs/fps-preset.json'
    fps = next((item for item in catalog['presets'] if item['id'] == 'fps-boost'), None)
    if fps_source.exists() != (fps is not None):
        failures.append('The fps-boost preset must exist exactly when backend/catalogs/fps-preset.json does.')
    if fps is not None:
        measured = json.loads(fps_source.read_text())['selections']
        if [(item['settingId'], item['optionId']) for item in measured] != [(item['settingId'], item['optionId']) for item in fps['selections']]:
            failures.append('The fps-boost preset must list exactly the measured winners.')
        if any(item['settingId'] in NEVER_IN_FPS_PRESET for item in measured):
            failures.append('The fps-boost preset includes a setting that must never ship in it (it breaks the PC after a reboot).')
        for item in measured:
            option_ids = {option['id'] for option in settings_by_id.get(item['settingId'], {}).get('options', [])}
            if item['optionId'] not in option_ids or not item.get('evidence'):
                failures.append('An FPS preset choice needs a real catalog option and benchmark evidence: ' + item['settingId'])
    for feature in coverage['features']:
        if feature['status'] == 'shared-settings' and (not feature.get('settings') or any(identifier not in settings_by_id for identifier in feature['settings'])):
            failures.append('A shared source feature must reference real setting resources: ' + feature['id'])
        if feature['status'] == 'shared-preset' and feature.get('implementation') not in preset_ids:
            failures.append('A grouped source feature must reference a real preset: ' + feature['id'])
    windows_types = json.loads((root / 'backend/catalogs/windows-value-types.json').read_text())['values']
    failures.extend(windows_type_failures(catalog, windows_types))
    text = {'hive': 'CurrentUser', 'keyPath': 'Fixture', 'valueName': 'Delay', 'type': 'REG_SZ'}
    def typed(*options, presets=()):
        address = {'hive': 'CurrentUser', 'keyPath': 'fixture', 'valueName': 'DELAY'}
        return {'settings': [{'id': 'fixture', 'options': [dict({'id': identifier, 'name': identifier, 'changes': [dict({'address': address}, **write)]}, **extra) for identifier, write, extra in options]}],
                'presets': [{'id': preset, 'selections': [{'settingId': 'fixture', 'optionId': choice}]} for preset, choice in presets]}
    one = {'dword': None, 'value': {'name': 'Delay', 'type': 1, 'bytes': 'MQAAAA=='}}
    if not windows_type_failures(typed(('number', {'dword': 1}, {})), [text]):
        failures.append('Windows type check must reject a number written where Windows keeps text.')
    if windows_type_failures(typed(('text', one, {}), ('removal', {'dword': None}, {})), [text]):
        failures.append('Windows type check must allow text and removal where Windows keeps text.')
    if not windows_type_failures(typed(('text', one, {})), [dict(text, valueName='other')]):
        failures.append('Windows type check must reject a value type that names no setting.')
    if windows_type_failures(typed(('text', one, {}), ('twin', one, {'sameAs': 'text'}), presets=[('picks-text', 'text')]), [text]):
        failures.append('Windows type check must allow a hidden choice that writes what its visible twin writes.')
    if not windows_type_failures(typed(('text', one, {}), ('twin', {'dword': None, 'value': dict(one['value'], bytes='MAAAAA==')}, {'sameAs': 'text'})), [text]):
        failures.append('Windows type check must reject a hidden choice that writes something else.')
    if not windows_type_failures(typed(('text', one, {}), ('twin', one, {'sameAs': 'text'}), presets=[('picks-twin', 'twin')]), [text]):
        failures.append('Windows type check must reject a preset that picks a hidden choice.')
    failures.extend(label_failures(root, catalog))
    stated = re.search(r'catalog contains ([\d,]+) setting resources and ([\d,]+) presets derived from ([\d,]+)\s+version/control records', (root / 'docs/windows-tweaks.md').read_text())
    actual_counts = (len(settings), len(catalog['presets']), len(coverage['records']))
    if stated and tuple(int(value.replace(',', '')) for value in stated.groups()) != actual_counts:
        failures.append('docs/windows-tweaks.md states catalog counts ' + ', '.join(stated.groups()) + ' but the catalog has ' + ', '.join(format(value, ',') for value in actual_counts))
    return failures


REGISTRY_TYPES = {'REG_SZ': 1, 'REG_BINARY': 3}


def windows_type_failures(catalog, values):
    failures = []
    for value in values:
        def kept(change):
            return all(change['address'].get(field, '').casefold() == value[field].casefold() for field in ('hive', 'keyPath', 'valueName'))
        settings = [setting for setting in catalog['settings'] if any(kept(change) for option in setting['options'] for change in option['changes'])]
        if not settings:
            failures.append('A value type Windows keeps names no catalog setting: ' + value['keyPath'] + '\\' + value['valueName'])
        for setting in settings:
            for option in setting['options']:
                for change in option['changes']:
                    written = change.get('value', {}).get('type') if change.get('value') else 4 if change.get('dword') is not None else None
                    if kept(change) and (written != REGISTRY_TYPES[value['type']] if written is not None else any(change.get(field) is not None for field in ('token', 'bits', 'formula'))):
                        failures.append('A choice writes a different registry type than Windows keeps (' + value['type'] + '): ' + setting['id'] + '/' + option['id'])
    for setting in catalog['settings']:
        options = {option['id']: option for option in setting['options']}
        for option in setting['options']:
            twin = options.get(option.get('sameAs'))
            if 'sameAs' in option and (twin is None or 'sameAs' in twin or twin['changes'] != option['changes'] or twin.get('controls') != option.get('controls') or twin.get('availability') != option.get('availability')):
                failures.append('A hidden choice must write exactly what its visible twin writes: ' + setting['id'] + '/' + option['id'])
    hidden = {(setting['id'], option['id']) for setting in catalog['settings'] for option in setting['options'] if 'sameAs' in option}
    for preset in catalog['presets']:
        if any((item['settingId'], item['optionId']) in hidden for item in preset['selections']):
            failures.append('A preset picks a hidden choice instead of its visible twin: ' + preset['id'])
    return failures


def label_failures(root, catalog):
    presentation = json.loads((root / 'docs/internal/frontend/RooIndustries.OptimizationSuite.App/Assets/Tweaks/presentation.json').read_text())
    unreadable, numbered, sections = [], [], {}
    for setting in catalog['settings']:
        entry = presentation.get(setting['id'], {})
        name = (entry.get('name') or setting['name']).strip()
        if not re.match(r'^(?:[A-Za-z0-9]|"[A-Za-z0-9])', name):
            unreadable.append(setting['id'] + ' ' + repr(name))
        for option in setting['options']:
            label = (entry.get('choices') or {}).get(option['id'], option['name'])
            if re.fullmatch(r'Value -?\d+(?: \(.*\))?', label):
                numbered.append(setting['id'] + ' ' + label)
        sections.setdefault((entry.get('section', 'windows'), name.casefold()), []).append(setting['id'])
    duplicates = [key[1] + ' in ' + key[0] + ': ' + ', '.join(members) for key, members in sections.items() if len(members) > 1]
    failures = []
    if unreadable:
        failures.append(str(len(unreadable)) + ' setting names are empty or start with punctuation: ' + '; '.join(unreadable[:5]))
    if numbered:
        failures.append(str(len(numbered)) + ' choices are labelled only as a bare value number: ' + '; '.join(numbered[:5]))
    if duplicates:
        failures.append(str(len(duplicates)) + ' setting names repeat within a section: ' + '; '.join(duplicates[:5]))
    return failures


if __name__ == '__main__':
    errors = check(Path(__file__).resolve().parents[2])
    print(json.dumps({'failures': errors}))
    raise SystemExit(bool(errors))
