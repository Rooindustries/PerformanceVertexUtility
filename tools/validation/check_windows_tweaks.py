import copy
import json
import re
from pathlib import Path

from jsonschema import Draft202012Validator


NEVER_IN_FPS_PRESET = {'windows.6ae403065279ea14'}

def check(root):
    failures = []
    catalog = json.loads((root / 'backend/catalogs/windows-tweaks.json').read_text())
    schema = json.loads((root / 'backend/contracts/roo-industries-backend-contracts.schema.json').read_text())
    validator = Draft202012Validator({'$defs': schema['$defs'], '$ref': '#/$defs/windowsTweaksCatalog'})
    settings = catalog['settings']
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
    expected = {'O&O ShutUp10': 376, 'WPD': 110, 'FSOS-X Dash': 79, 'Chris Titus Tech WinUtil': 67}
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
    failures.extend(label_failures(root, catalog))
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
