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


def branding_negative_controls():
    check = runpy.run_path(str(Path(__file__).with_name('check_branding.py')))['check']
    prefix = 'Ro' + 'o'
    legacy = prefix + 'LegacyThing'
    exception = {'text': legacy, 'files': ['listed.ps1'], 'reason': 'fixture'}
    location = 'tools/validation/branding-exceptions.json'
    cases = {
        'new short name': ([], {'fixture.ps1': prefix + 'NewThing'}, ['fixture.ps1:1: shortened product reference']),
        'listed exception': ([exception], {'listed.ps1': legacy}, []),
        'unlisted exception': ([exception], {'listed.ps1': legacy, 'unlisted.ps1': legacy}, ['unlisted.ps1:1: shortened product reference']),
        'another short name on an excepted line': ([exception], {'listed.ps1': legacy + ' ' + prefix + 'Other'}, ['listed.ps1:1: shortened product reference']),
        'stale exception': ([exception], {'listed.ps1': 'unchanged'}, [f'{location}: stale exception {legacy!r} in listed.ps1']),
        'stale file in a used exception': ([dict(exception, files=['listed.ps1', 'other.ps1'])], {'listed.ps1': legacy, 'other.ps1': 'unchanged'}, [f'{location}: stale exception {legacy!r} in other.ps1']),
        'full name exception': ([dict(exception, text=prefix + 'IndustriesFine')], {'listed.ps1': prefix + 'IndustriesFine'}, [f'{location}: exception {prefix + "IndustriesFine"!r} is not shortened']),
        'empty exception reason': ([dict(exception, reason='')], {'listed.ps1': legacy}, [f'{location}: exception {legacy!r} has an empty reason']),
        'exception without files': ([dict(exception, files=[])], {'listed.ps1': legacy}, [f'{location}: exception {legacy!r} lists no files', 'listed.ps1:1: shortened product reference']),
    }
    results = {}
    for label, (exceptions, files, expected) in cases.items():
        with tempfile.TemporaryDirectory() as folder:
            temporary = Path(folder)
            manifest = temporary / location
            manifest.parent.mkdir(parents=True)
            manifest.write_text(json.dumps({'exceptions': exceptions}), encoding='utf-8')
            for relative, source in files.items():
                (temporary / relative).write_text(source, encoding='utf-8')
            results[label] = check(temporary) == expected
    return results


def path_lint_failures(root: Path):
    update = root / 'tools/validation/Update'
    if not (update / 'run_harness_checks.py').is_file():
        return []
    lint_tree = runpy.run_path(str(update / 'run_harness_checks.py'))['lint_tree']
    failures = []
    for folder in ('Update', 'Tour'):
        try:
            lint_tree(root / 'tools/validation' / folder)
        except RuntimeError as error:
            failures.append(f'Path lint tools/validation/{folder}: {error}')
    return failures


def path_lint_negative_controls():
    lint_tree = runpy.run_path(str(Path(__file__).with_name('Update') / 'run_harness_checks.py'))['lint_tree']
    target = 'tools/validation/Update/x.ps1'
    line = 'Remove-' + 'Item -LiteralPath $x'
    entry = {'file': target, 'line': 1, 'text': line, 'reason': 'fixture'}
    cases = {
        'forbidden token': ({target: line}, None, True),
        'clean file': ({target: '$x = 1'}, None, False),
        'allowlisted line': ({target: line}, [entry], False),
        'allowlist entry without a reason': ({target: line}, [dict(entry, reason='')], True),
        'allowlist entry for another line': ({target: '$x = 1\n' + line}, [entry], True),
        'build output ignored': ({target: '$x = 1', 'tools/validation/Update/bin/Release/x.dll': line, 'tools/validation/Update/obj/x.ps1': line}, None, False),
    }
    results = {}
    for label, (files, allowlist, should_fail) in cases.items():
        with tempfile.TemporaryDirectory() as folder:
            temporary = Path(folder)
            stubs = {'tools/validation/windows_ssh.py': '', 'tools/validation/LoadTimes/CleanupOwnership.Common.ps1': ''}
            for relative, source in {**stubs, **files}.items():
                (temporary / relative).parent.mkdir(parents=True, exist_ok=True)
                (temporary / relative).write_text(source, encoding='utf-8')
            if allowlist is not None:
                (temporary / 'tools/validation/path-lint-allowlist.json').write_text(json.dumps(allowlist), encoding='utf-8')
            try:
                lint_tree(temporary / 'tools/validation/Update')
                failed = False
            except RuntimeError as error:
                failed = any(relative in str(error) for relative in files)
            results[label] = failed == should_fail
    return results


def public_surface_negative_controls():
    check = runpy.run_path(str(Path(__file__).with_name('check_public_surface.py')))['check']
    sid = 'S-1-5-21-'
    users = 'C:\\Users\\'
    computer = '$env:COMPUTER' + 'NAME'
    cases = {
        'real account SID': ({'a.ps1': "$s='" + sid + "1234567890-1234567890-1234567890-1001'"}, ['a.ps1:1: account SID']),
        'fake account SIDs': ({'a.ps1': sid + '1-2-3-1001 ' + sid + '111-222-333-1002 ' + sid + '111111111-222222222-333333333-1001'}, []),
        'user folder name': ({'a.json': '"' + users.replace('\\', '\\\\') + 'jdoe\\\\x"\n' + users + 'jdoe\nC:/Users/' + 'jdoe/x'}, ['a.json:1: user folder name', 'a.json:2: user folder name', 'a.json:3: user folder name']),
        'placeholder user folders': ({'a.txt': users + 'Public\\x ' + users + 'Default User\\x ' + users + 'Client\\x ' + users + 'John Smith\\x' + ' ' + users + "J'+[char]0xFC"}, []),
        'home folder name': ({'a.sh': '/home/' + 'jdoe/x\n/Users/' + 'jdoe/y'}, ['a.sh:1: home folder name', 'a.sh:2: home folder name']),
        'placeholder home folders': ({'a.sh': '/home/' + 'runner/x /Users/' + 'example/y'}, []),
        'tailnet address': ({'a.md': '100.' + '101.2.3\n100.' + '63.1.1 100.' + '128.1.1'}, ['a.md:1: tailnet address']),
        'private network address': ({'a.md': '192.' + '168.1.20\n10.' + '0.19041.1'}, ['a.md:1: private network address']),
        'tailnet host name': ({'a.md': 'box.tail1234.ts' + '.net'}, ['a.md:1: tailnet host name']),
        'email address': ({'a.txt': 'ok\nok\njdoe@' + 'gmail.com\nme@example.com GetTickCount@kernel32.dll'}, ['a.txt:3: email address']),
        'computer name literal': ({'a.ps1': 'if(' + computer + " -cne 'PC-1'){}\nif('PC-1' -ieq " + computer + '){}\nif(' + computer + ' -cne $ExpectedMachine){}' + "\nparam([string]$Expected" + "Machine='PC-1')\nparam([string]$Expected" + "Computer='')"}, ['a.ps1:1: computer name literal', 'a.ps1:2: computer name literal', 'a.ps1:4: computer name literal']),
        'remote host literal': ({'a.py': 'w.inv' + "oke('test-pc', m, s)\n" + 'HO' + "ST = 'test-pc'\nhost = 'must-not-connect.invalid' if x else args.host\nw.inv" + "oke(args.host, m, s)" + "\nself.inv" + "oke('& ' + w.ps_literal(x), timeout=5)", 'a.ps1': 'w.inv' + "oke('test-pc', m, s)"}, ['a.py:1: remote host literal', 'a.py:2: remote host literal']),
    }
    results = {}
    for label, (files, expected) in cases.items():
        with tempfile.TemporaryDirectory() as folder:
            temporary = Path(folder)
            for relative, source in files.items():
                (temporary / relative).write_text(source, encoding='utf-8')
            results[label] = sorted(check(temporary)) == sorted(expected)
    return results


def product_name_negative_controls():
    check = runpy.run_path(str(Path(__file__).with_name('check_product_name.py')))['check']
    name = 'Ro' + 'o Industries'
    location = 'tools/validation/product-name-exceptions.json'
    shipped = 'backend/scripts/Shipped.ps1'
    kept = "'" + name + " kept'"
    exception = {'text': kept, 'files': [shipped], 'reason': 'fixture'}
    cases = {
        'product name in shipped text': ([], {shipped: name + ' checked it'}, [f'{shipped}:1: product name in shipped text']),
        'website in shipped text': ([], {shipped: 'rooindustries' + '.com'}, [f'{shipped}:1: product name in shipped text']),
        'product name in a test script': ([], {'backend/scripts/Test-Shipped.ps1': name + ' fixture'}, []),
        'product name outside shipped folders': ([], {'docs/notes.md': name}, []),
        'listed exception': ([exception], {shipped: kept}, []),
        'another product name on an excepted line': ([exception], {shipped: kept + ' ' + name}, [f'{shipped}:1: product name in shipped text']),
        'stale exception': ([exception], {shipped: 'unchanged'}, [f'{location}: stale exception {kept!r} in {shipped}']),
        'empty exception reason': ([dict(exception, reason='')], {shipped: kept}, [f'{location}: exception {kept!r} has an empty reason']),
    }
    results = {}
    for label, (exceptions, files, expected) in cases.items():
        with tempfile.TemporaryDirectory() as folder:
            temporary = Path(folder)
            manifest = temporary / location
            manifest.parent.mkdir(parents=True)
            manifest.write_text(json.dumps({'exceptions': exceptions}), encoding='utf-8')
            for relative, source in files.items():
                (temporary / relative).parent.mkdir(parents=True, exist_ok=True)
                (temporary / relative).write_text(source, encoding='utf-8')
            results[label] = check(temporary) == expected
    return results


def fixture_cleanup_negative_controls():
    check = runpy.run_path(str(Path(__file__).with_name('check_fixture_cleanup.py')))['check']
    location = 'tools/validation/fixture-cleanup-allowlist.json'
    cs = 'tools/validation/Example/Checks.cs'
    ps = 'backend/scripts/Test-Example.ps1'
    parent = 'hive.DeleteSubKey("Software\\\\RooIndustriesExampleTests", false);'
    entry = {'file': cs, 'target': '"Software\\\\RooIndustriesExampleTests"', 'reason': 'fixture'}
    cases = {
        'fixed registry parent': ([], {cs: parent}, [f'{cs}:1:']),
        'unique registry key': ([], {cs: 'var name = "Software\\\\X\\\\" + Guid.NewGuid().ToString("N");\nhive.DeleteSubKeyTree(name, false);'}, []),
        'helper-owned registry key': ([], {cs: 'owned?.Dispose();\nhive.DeleteSubKey(created[index], false);'}, []),
        'class constant': ([], {cs: 'static class Other { public const string Root = @"Software\\X"; }\nstatic class Uses { void Run() { hive.DeleteSubKeyTree(Other.Root, false); game.Root.Delete(); Directory.Delete(game.Root, true); } }'}, [f'{cs}:2:']),
        'fixed task through a variable': ([], {ps: "$task='RooIndustriesExample'\nUnregister-ScheduledTask -TaskName $task -Confirm:$false"}, [f'{ps}:2:']),
        'fixed folder from environment': ([], {ps: "$work=Join-Path $env:ProgramData 'RooIndustriesExample'\nRemove-Item -LiteralPath $work -Recurse -Force"}, [f'{ps}:2:']),
        'unique folder': ([], {ps: "$work=Join-Path $env:TEMP ('roo-industries-'+[Guid]::NewGuid().ToString('N'))\nRemove-Item -LiteralPath $work -Recurse -Force"}, []),
        'fixed task through a wrapper': ([], {ps: "function Remove-Task([string]$Name){Unregister-ScheduledTask -TaskName $Name -Confirm:$false}\n$stray='RooIndustriesExample'\nRemove-Task $stray"}, [f'{ps}:3:']),
        'fixed task from a case table': ([], {ps: "$cases=@(\n@{name='RooIndustriesExample';exe='x.exe'}\n)\nforeach($case in $cases){Unregister-ScheduledTask -TaskName $case.name -Confirm:$false}"}, [f'{ps}:4:']),
        'fixed account': ([], {ps: "$account='rooexample'\n& net.exe user $account /delete"}, [f'{ps}:2:']),
        'process environment variable': ([], {ps: "Remove-Item -LiteralPath 'Env:\\ROO_INDUSTRIES_EXAMPLE'"}, []),
        'listed proof': ([entry], {cs: parent}, []),
        'listed proof without a reason': ([dict(entry, reason=' ')], {cs: parent}, [f'{location}:']),
        'stale listed proof': ([entry], {cs: 'owned?.Dispose();'}, [f'{location}: stale']),
    }
    results = {}
    for label, (entries, files, expected) in cases.items():
        with tempfile.TemporaryDirectory() as folder:
            temporary = Path(folder)
            for relative, source in {location: json.dumps(entries), **files}.items():
                (temporary / relative).parent.mkdir(parents=True, exist_ok=True)
                (temporary / relative).write_text(source, encoding='utf-8')
            failures = check(temporary)
            results[label] = len(failures) == len(expected) and all(any(f.startswith(e) for f in failures) for e in expected)
    return results


def validate(root: Path, contracts_only: bool = False):
    failures = []
    failures.extend(code_loading_failures(root))
    for label, rejected in code_loading_negative_controls(root).items():
        if not rejected:
            failures.append(f'Negative control failed: a {label} passed the clearing check')
    failures.extend(runpy.run_path(str(Path(__file__).with_name('check_windows_tweaks.py')))['check'](root))
    if not contracts_only:
        failures.extend(runpy.run_path(str(Path(__file__).with_name('check_tweak_reads.py')))['check'](root))
        failures.extend(runpy.run_path(str(Path(__file__).with_name("check_branding.py")))["check"](root))
        for label, passed in branding_negative_controls().items():
            if not passed:
                failures.append(f'Negative control failed: {label} did not match the branding check result')
        failures.extend(path_lint_failures(root))
        for label, passed in path_lint_negative_controls().items():
            if not passed:
                failures.append(f'Negative control failed: {label} did not match the path lint result')
        failures.extend(runpy.run_path(str(Path(__file__).with_name('check_public_surface.py')))['check'](root))
        for label, passed in public_surface_negative_controls().items():
            if not passed:
                failures.append(f'Negative control failed: {label} did not match the public surface check result')
        failures.extend(runpy.run_path(str(Path(__file__).with_name('check_product_name.py')))['check'](root))
        for label, passed in product_name_negative_controls().items():
            if not passed:
                failures.append(f'Negative control failed: {label} did not match the product name check result')
        failures.extend(runpy.run_path(str(Path(__file__).with_name('check_fixture_cleanup.py')))['check'](root))
        for label, passed in fixture_cleanup_negative_controls().items():
            if not passed:
                failures.append(f'Negative control failed: {label} did not match the fixture cleanup check result')
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
