"""Validate maintained data contracts and repository structure without running the app."""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
import runpy
import sys
import xml.etree.ElementTree as ET

try:
    from jsonschema import Draft202012Validator
except ImportError:
    raise SystemExit('Install validation dependencies: python -m pip install -r tools/validation/requirements.txt')

ROOT = Path(__file__).resolve().parents[2]


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f'duplicate JSON key: {key}')
        result[key] = value
    return result


def read_json(path):
    return json.loads(path.read_text(encoding='utf-8-sig'), object_pairs_hook=unique_object)


def public_hygiene_text(relative: str, source: str):
    if relative != 'backend/catalogs/upstream-settings-inventory.json':
        return source
    catalog = json.loads(source, object_pairs_hook=unique_object)
    # Inventoried third-party application names, package IDs and publisher links
    # are source facts. Keep authored explanations subject to the normal check.
    for app in catalog.get('applications', []):
        if app.get('sourceId') != 'winutil' or app.get('recordKind') != 'application-package':
            continue
        for key in ('id', 'sourceSettingId', 'displayName', 'packageIds', 'publisherWebsite'):
            app.pop(key, None)
        for reference in app.get('evidenceRefs', []):
            reference.pop('symbol', None)
    return json.dumps(catalog)


def validate(root: Path, contracts_only: bool = False):
    failures = []
    if not contracts_only:
        failures.extend(runpy.run_path(str(Path(__file__).with_name("check_branding.py")))["check"](root))
    documents = {}
    for folder in ('backend/contracts', 'backend/samples', 'backend/profiles', 'backend/uninstall', 'backend/catalogs', 'backend/capabilities', 'modules'):
        for path in sorted((root / folder).rglob('*.json')):
            try:
                documents[path.relative_to(root).as_posix()] = read_json(path)
            except (ValueError, OSError) as error:
                failures.append(f'{path.relative_to(root)}: {error}')
    schema = documents['backend/contracts/roo-industries-backend-contracts.schema.json']
    Draft202012Validator.check_schema(schema)
    mapping = documents['backend/contracts/validation-map.json']
    cases = 0

    def check(data, definition, label):
        nonlocal cases
        validator = Draft202012Validator(schema if definition == '$root' else {
            '$schema': schema['$schema'], '$defs': schema['$defs'], '$ref': f'#/$defs/{definition}'
        })
        for error in validator.iter_errors(data):
            location = '/'.join(str(part) for part in error.absolute_path)
            failures.append(f'{label}/{location}: {error.message}')
        cases += 1

    check(documents['backend/contracts/contract-catalog.json'], '$root', 'contract-catalog')
    for descriptor in documents['backend/contracts/contract-catalog.json']['contracts']:
        if descriptor['definitionRef'].split('/')[-1] not in schema['$defs']:
            failures.append(f'Unresolved contract reference: {descriptor["definitionRef"]}')
    for name, rule in mapping['schemas'].items():
        if name not in documents:
            failures.append(f'Mapped contract missing: {name}')
            continue
        data = documents[name]
        if isinstance(rule, str):
            check(data, rule, name)
        else:
            values = data[rule['itemsProperty']]
            for index, value in enumerate(values):
                check(value, rule['definition'], f'{name}[{index}]')
    for name in documents:
        if name.startswith('backend/samples/') and name not in mapping['schemas'] and name not in mapping['domainTests']:
            failures.append(f'Sample has no declared validator: {name}')
    for name, script in mapping['domainTests'].items():
        if name not in documents or not (root / script).is_file():
            failures.append(f'Domain validation mapping is incomplete: {name} -> {script}')
    for name, data in documents.items():
        if name.endswith('.routes.json'):
            check(data, 'capabilityRouteManifest', name)
    # A parseable object with the wrong apps type must fail the actual inventory contract.
    invalid = dict(documents['backend/samples/installed-app-inventory.sample.json'], apps='not an array')
    validator = Draft202012Validator({'$defs': schema['$defs'], '$ref': '#/$defs/uninstallAppInventory'})
    if not any(list(error.absolute_path) == ['apps'] and error.validator == 'type' for error in validator.iter_errors(invalid)):
        failures.append('Negative control failed: an invalid inventory apps field passed validation')
    inventory_name = 'backend/catalogs/upstream-settings-inventory.json'
    trace_pattern = r'Cod[e]x|Cl[a]ude|Chat[G]PT|generated b[y]|AI assist[a]nt'
    if inventory_name in documents:
        catalog_text = json.dumps(documents[inventory_name])
        if re.search(trace_pattern, public_hygiene_text(inventory_name, catalog_text), re.I):
            failures.append('Research inventory contains an authored public tool trace')
        altered = json.loads(catalog_text)
        altered['applications'][0]['nextAction'] = 'generated ' + 'by a validation probe'
        if not re.search(trace_pattern, public_hygiene_text(inventory_name, json.dumps(altered)), re.I):
            failures.append('Negative control failed: factual metadata exception hid an authored trace')
    xml_count = 0
    if not contracts_only:
        frontend = root / 'docs/internal/frontend'
        for extension in ('*.xaml', '*.csproj', '*.manifest'):
            for path in frontend.rglob(extension):
                if {'bin', 'obj'}.intersection(path.parts):
                    continue
                try:
                    ET.parse(path)
                    xml_count += 1
                except ET.ParseError as error:
                    failures.append(f'{path.relative_to(root)}: {error}')
        for folder in ('backend', 'modules', 'tools', 'docs'):
            for path in (root / folder).rglob('*'):
                if not path.is_file() or path.suffix not in ('.ps1', '.cs', '.json', '.md', '.py', '.xaml'):
                    continue
                relative = path.relative_to(root).as_posix()
                if any(part in ('bin', 'obj', 'state', '__pycache__') for part in path.parts) or relative.startswith('docs/internal/gitignored/'):
                    continue
                source = path.read_text(encoding='utf-8-sig')
                if re.search(r'^(<{7}|={7}|>{7})(?: |$)', source, re.M):
                    failures.append(f'{relative}: unresolved merge marker')
                hygiene_source = public_hygiene_text(relative, source)
                if not relative.startswith('docs/internal/') and re.search(trace_pattern, hygiene_source, re.I):
                    failures.append(f'{relative}: public tool trace requires review')
        if any((root / 'backend/state').rglob('*')):
            failures.append('backend/state is not empty')
    result = {'jsonFiles': len(documents), 'schemaCases': cases, 'domainTestSamples': len(mapping['domainTests']), 'xmlFiles': xml_count, 'negativeControl': True, 'failures': failures}
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--contracts-only', action='store_true')
    parser.add_argument('--root', type=Path, default=ROOT)
    args = parser.parse_args()
    result = validate(args.root.resolve(), args.contracts_only)
    print(json.dumps(result, indent=2))
    sys.exit(bool(result['failures']))
