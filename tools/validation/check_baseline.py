"""Validate maintained data contracts and repository structure without running the app."""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
import runpy
import sys
import tempfile
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


def code_loading_failures(root: Path):
    def quoted(text):
        return re.findall(r"[\"']([A-Za-z0-9_()]+)[\"']", text)
    def same(label, found, wanted, failures):
        if len(found) != len(set(found)) or set(found) != set(wanted):
            failures.append(f'{label}: differs from RuntimeEnvironment (missing {sorted(set(wanted) - set(found))}, extra {sorted(set(found) - set(wanted))})')
    csharp = (root / 'backend/native/Optimizer.Core/RuntimeEnvironment.cs').read_text(encoding='utf-8-sig')
    def array(label):
        match = re.search(label + r'\s*=\s*\[(.*?)\];', csharp, re.S)
        return quoted(match.group(1)) if match else []
    def method(name):
        match = re.search(r'public static void ' + name + r'\(\)\s*\{(.*?)\n    \}', csharp, re.S)
        return match.group(1) if match else ''
    prefixes = array('ClearPrefixes')
    pinned = array('Pinned')
    failures = []
    if not prefixes or not pinned:
        return ['backend/native/Optimizer.Core/RuntimeEnvironment.cs: ClearPrefixes or Pinned was not found']
    development = array('DevelopmentCodeLoading') + array('DevelopmentClearOnly')
    if not development or len(development) != len(set(development)):
        failures.append('RuntimeEnvironment.cs: the development-only name list is missing or lists a name twice')
    if any(not name.endswith('_') for name in prefixes):
        failures.append('RuntimeEnvironment.cs: every clearing prefix must end in an underscore')
    for name in ('Sanitize', 'RequireClean'):
        if 'Prefixed()' not in method(name):
            failures.append(f'RuntimeEnvironment.cs {name}: a release build must work by prefix (Prefixed()), not by a name list')
    powershell = (root / 'backend/scripts/BrandCompatibility.Common.ps1').read_text(encoding='utf-8-sig')
    def ps(label):
        match = re.search(r'\$script:' + label + r'=@\((.*?)\)\r?\n', powershell, re.S)
        return quoted(match.group(1)) if match else []
    same('PowerShell RooIndustriesClearedPrefixes', ps('RooIndustriesClearedPrefixes'), prefixes, failures)
    same('PowerShell RooIndustriesPinnedVariables (pinned to 0)', ps('RooIndustriesPinnedVariables'), pinned, failures)
    if 'RooIndustriesCodeLoadingVariables' in powershell:
        failures.append('BrandCompatibility.Common.ps1 still defines a code-loading name list; use RooIndustriesClearedPrefixes')
    launcher = (root / 'backend/scripts/Start-RooIndustriesHelper.cmd').read_text(encoding='utf-8')
    lines = [line.rstrip('\r') for line in launcher.split('\n')]
    loops = re.findall(r'for %%p in \(([^)]*)\) do', launcher)
    if len(loops) < 3:
        failures.append('Start-RooIndustriesHelper.cmd: expected the prefix loop in the listing, the clear pass and the final check')
    for loop in loops:
        same('Start-RooIndustriesHelper.cmd prefix loop', loop.split(), prefixes, failures)
    same('Start-RooIndustriesHelper.cmd (pinned to 0)', re.findall(r'(?m)^set ([A-Za-z0-9_()]+)=0\r?$', launcher), pinned, failures)
    for name in re.findall(r'(?m)^set ([A-Za-z0-9_()]+)=\r?$', launcher):
        if name != 'RANDOM':
            failures.append(f'Start-RooIndustriesHelper.cmd clears {name} by name; the launcher must clear by prefix')
    if re.search(r"(?i)for /f[^\n]*in \([`']", launcher):
        failures.append('Start-RooIndustriesHelper.cmd enumerates with for /f over a command, which starts a second command interpreter')
    checks = re.findall(r'if not errorlevel 1 exit /b (\d+)', launcher)
    if len(checks) != 1 or checks[0] == '87':
        failures.append('Start-RooIndustriesHelper.cmd needs exactly one final check that exits with its own code (not 87) when a prefixed variable is left')
    final = next((index for index, line in enumerate(lines) if 'exit /b ' + (checks[0] if checks else '-') in line), len(lines))
    helper = next((index for index, line in enumerate(lines) if '"%P1%"' in line), len(lines))
    internal = {'@echo', 'setlocal', 'set', 'call', 'for', 'if', 'exit', 'goto', 'del', '(for'}
    subroutine = lines[next((index for index, line in enumerate(lines) if line.startswith(':clear')), len(lines)):]
    for line in lines[:final + 1] + subroutine:
        word = line.split(' ')[0].lower() if line.strip() else ''
        if word and not word.startswith(':') and word not in internal:
            failures.append(f'Start-RooIndustriesHelper.cmd runs {word} before the variables are cleared: {line.strip()}')
    if final > helper:
        failures.append('Start-RooIndustriesHelper.cmd starts the helper before the final check')
    installer = (root / 'tools/release/SetupProcess.iss').read_text(encoding='utf-8-sig')
    procedure = re.search(r'procedure ClearCodeLoading;.*?\nend;', installer, re.S)
    body = procedure.group(0) if procedure else ''
    prefix_block = re.search(r'Prefixes := \[(.*?)\];', installer, re.S)
    same('SetupProcess.iss HasClearedPrefix', quoted(prefix_block.group(1)) if prefix_block else [], prefixes, failures)
    arrays = re.findall(r'Names := \[(.*?)\];', body, re.S)
    same('SetupProcess.iss ClearCodeLoading (pinned to 0)', quoted(arrays[0]) if arrays else [], pinned, failures)
    if len(arrays) != 1 or 'PrefixedNames' not in body:
        failures.append('SetupProcess.iss ClearCodeLoading must clear by PrefixedNames and keep only the pinned list')
    return failures


def code_loading_negative_controls(root: Path):
    sources = {
        'backend/native/Optimizer.Core/RuntimeEnvironment.cs': (lambda text: text.replace('Release ? Prefixed() :', 'Release ? DevelopmentCodeLoading :', 1), 'Sanitize by a list'),
        'backend/scripts/BrandCompatibility.Common.ps1': (lambda text: text.replace("$script:RooIndustriesClearedPrefixes=", "$script:RooIndustriesCodeLoadingVariables=@('DOTNET_GCName')\n$script:RooIndustriesClearedPrefixes=", 1), 'PowerShell name list'),
        'backend/scripts/Start-RooIndustriesHelper.cmd': (lambda text: text.replace('set DOTNET_EnableDiagnostics=0\r\n', 'set DOTNET_GCName=\r\nset DOTNET_EnableDiagnostics=0\r\n', 1), 'launcher name list'),
        'tools/release/SetupProcess.iss': (lambda text: text.replace('Names := PrefixedNames;', "Names := ['DOTNET_GCName'];", 1), 'installer name list'),
    }
    results = {}
    for relative, (mutate, label) in sources.items():
        with tempfile.TemporaryDirectory() as folder:
            temporary = Path(folder)
            for needed in sources:
                target = temporary / needed
                target.parent.mkdir(parents=True, exist_ok=True)
                text = (root / needed).read_bytes().decode('utf-8')
                target.write_bytes((mutate(text) if needed == relative else text).encode('utf-8'))
            results[label] = bool(code_loading_failures(temporary))
    return results


def validate(root: Path, contracts_only: bool = False):
    failures = []
    failures.extend(code_loading_failures(root))
    for label, rejected in code_loading_negative_controls(root).items():
        if not rejected:
            failures.append(f'Negative control failed: a {label} passed the clearing check')
    failures.extend(runpy.run_path(str(Path(__file__).with_name('check_windows_tweaks.py')))['check'](root))
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
