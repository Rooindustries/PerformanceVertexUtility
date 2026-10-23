import copy
import json
import os
from pathlib import Path
import re
import subprocess

from jsonschema import Draft202012Validator


CATALOG = 'backend/catalogs/launch-presets.json'
SCHEMA = 'backend/contracts/roo-industries-backend-contracts.schema.json'
CLAIMS = re.compile(r'\b(?:fps|frames?|frame ?rates?|faster|smoother|latency|lag|stutter\w*|improv\w*|better|gains?)\b', re.I)


def catalog_failures(catalog, schema):
    validator = Draft202012Validator({'$schema': schema['$schema'], '$defs': schema['$defs'], '$ref': '#/$defs/launchPresetCatalog'})
    failures = [CATALOG + '/' + '/'.join(str(part) for part in error.absolute_path) + ': ' + error.message for error in validator.iter_errors(catalog)]
    if failures:
        return failures
    owners = {}
    for preset in catalog['presets']:
        for label, key in (('id', preset['id']), ('name', preset['name'].casefold()), ('settings', json.dumps(preset['settings'], sort_keys=True))):
            if (label, key) in owners:
                failures.append(f'Launch presets {owners[label, key]} and {preset["id"]} have the same {label}')
            owners.setdefault((label, key), preset['id'])
        if preset['name'].casefold() == 'custom':
            failures.append(f'Launch preset {preset["id"]} uses the name Custom, which the Games tab shows once a setting is edited')
        if CLAIMS.search(preset['name'] + ' ' + preset['description']):
            failures.append(f'Launch preset {preset["id"]} makes a performance claim without measured evidence')
    return failures


def negative_controls(catalog, schema):
    def twin(presets, **fields):
        presets.append(dict(copy.deepcopy(presets[0]), **fields))
    cases = {
        'preset with Realtime CPU priority': ('settings/cpuPriority: ', lambda presets: presets[0]['settings'].update(cpuPriority='Realtime')),
        'preset with High I/O priority': ('settings/ioPriority: ', lambda presets: presets[0]['settings'].update(ioPriority=3)),
        'preset with Realtime GPU priority': ('settings/gpuPriority: ', lambda presets: presets[0]['settings'].update(gpuPriority=5)),
        'preset with I/O priority written as true': ('settings/ioPriority: ', lambda presets: presets[0]['settings'].update(ioPriority=True)),
        'preset with a setting the session form lacks': ("'affinity' was unexpected", lambda presets: presets[0]['settings'].update(affinity={'group': 0, 'mask': '0x1'})),
        'preset that changes nothing': ('presets/0/settings: ', lambda presets: presets[0].update(settings={})),
        'repeated preset id': ('the same id', lambda presets: twin(presets, name='Fixture twin', settings={'memoryPriority': 4, 'ioPriority': 1})),
        'repeated preset name in another case': ('the same name', lambda presets: twin(presets, id='fixture-twin', name=presets[0]['name'].upper(), settings={'memoryPriority': 4, 'ioPriority': 1})),
        'preset with the same settings as another': ('the same settings', lambda presets: twin(presets, id='fixture-twin', name='Fixture twin')),
        'preset named Custom': ('name Custom', lambda presets: presets[0].update(name='custom')),
        'preset description with a performance claim': ('performance claim', lambda presets: presets[0].update(description='More FPS in every game.')),
    }
    results = {}
    for label, (expected, change) in cases.items():
        variant = copy.deepcopy(catalog)
        change(variant['presets'])
        results[label] = any(expected in failure for failure in catalog_failures(variant, schema))
    return results


def loader_failures(root):
    project = root / 'tools/validation/ClientBoundary/ClientBoundary.csproj'
    command = [os.environ.get('DOTNET', 'dotnet'), 'run', '--project', str(project), '--configuration', 'Release', '-p:EnableWindowsTargeting=true', '--', str(root), '--launch-presets']
    try:
        result = subprocess.run(command, cwd=root, capture_output=True, text=True)
    except FileNotFoundError:
        return ['The launch preset loader check needs the .NET 8 SDK (dotnet).']
    if result.returncode == 0:
        return []
    return ['The launch preset loader check failed: ' + (result.stdout + result.stderr)[-2000:]]


def check(root):
    if not (root / CATALOG).is_file():
        return [CATALOG + ' is missing']
    schema = json.loads((root / SCHEMA).read_text(encoding='utf-8'))
    if 'launchPresetCatalog' not in schema['$defs']:
        return [SCHEMA + ' has no launchPresetCatalog definition']
    catalog = json.loads((root / CATALOG).read_text(encoding='utf-8'))
    failures = catalog_failures(catalog, schema)
    failures += ['Negative control failed: a ' + label + ' passed the launch preset check' for label, rejected in negative_controls(catalog, schema).items() if not rejected]
    return failures + loader_failures(root)


if __name__ == '__main__':
    errors = check(Path(__file__).resolve().parents[2])
    print(json.dumps({'failures': errors}, indent=2))
    raise SystemExit(bool(errors))
