"""Validate maintained data contracts and repository structure without running the app."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import runpy
import sys
import tempfile
import xml.etree.ElementTree as ET

local_tree = runpy.run_path(str(Path(__file__).with_name('local_tree.py')))['entries']

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


def reparse_walk_negative_controls():
    module = runpy.run_path(str(Path(__file__).with_name('check_reparse_walks.py')), run_name='controls')
    table = module['CLASSES']
    sharp = 'using System; using System.Diagnostics; using System.Runtime.InteropServices; {0}\nstatic class Control {{\n  [DllImport("kernel32.dll")] static extern uint GetCurrentProcessId();\n  [DllImport("kernel32.dll")] static extern void {1}();\n  static void M(string dir, object x) {{ {2} }}\n}}'
    cs = lambda body, using='', native='Zqvx': sharp.format(using, native, body)
    language = {
        'ps1': {
            'command': ('{0}-Item $a', 'Write-Host $a'),
            'pipeline': ('$a | {0}-Item', '$a | Write-Host'),
            'splat': ('$p = @{{Path = $a}}; {0}-Item @p', '$p = @{{Object = $a}}; Write-Host @p'),
            'alias': ('Set-Alias q {0}; q $a', 'function r {{ Write-Host $args }}; r $a'),
            'continuation': ('{0}-Item `\n  $a', 'Write-Host `\n  $a'),
            'static .NET call': ('[System.Data.DataTable]::new()', '[System.Math]::Abs(1)'),
            'static member on a type variable': ('$t = [System.Data.DataTable]; $t::new()', '$t = [System.Math]; $t::Abs(1)'),
            'instance method': ('$x.{0}()', '$x.ToString()'),
            'ForEach-Object member': ('$x | ForEach-Object {0}', '$x | ForEach-Object ToString'),
            'command named by a string': ("& '{0}-Item' $a", "& 'Write-Host' $a"),
            'parameter default': ('function f {{ param($c = "{0}-Item") & $c }}; f', 'function f {{ param($c = "Write-Host") & $c hi }}; f'),
        },
        'py': {
            'imported module member': ('import os\nos.{0}(a)', 'import os\nos.getpid()'),
            'from-import alias': ('from os import {0} as w\nw(a)', 'from os import getpid as w\nw()'),
            'method on an unknown value': ('x.{0}()', 'x = []\nx.append(1)'),
            'reference passed as a value': ('import os\nlist(map(os.{0}, a))', 'import os\nlist(map(os.fspath, a))'),
            'continuation': ('import os\nos.{0}(\n    a)', 'import os\nos.getpid(\n    )'),
            'name bound nowhere': ('{0}(a)', 'print(a)'),
            'glob folder wildcard': ("import glob\nglob.glob('*/{0}')", "import glob\nglob.glob('{0}/*.txt')"),
        },
        'cs': {
            'call': (cs('new System.Data.DataTable();'), cs('Math.Abs(1);')),
            'method group': (cs('Func<System.Data.DataTable> f = System.Data.Common.DbProviderFactories.GetFactoryClasses;'), cs('Func<int, int> f = Math.Abs;')),
            'using alias': (cs('new Q();', 'using Q = System.Data.DataTable;'), cs('Q.Abs(1);', 'using Q = System.Math;')),
            'using static': (cs('GetFactoryClasses();', 'using static System.Data.Common.DbProviderFactories;'), cs('Abs(1);', 'using static System.Math;')),
            'dynamic': (cs('dynamic d = x; d.{0}();'), cs('object d = x; d.ToString();')),
            'native entry point': (cs('{0}();', native='{0}'), cs('Math.Abs(1);')),
            'code the compiler cannot read': (cs('{0}.Run();'), cs('Math.Abs(1);')),
        },
        'targets': {'task': ('<Project><Target Name="T"><{0} /></Target></Project>', '<Project><Target Name="T"><Message Text="hi" /></Target></Project>')},
        'yml': {'action': ('jobs:\n  j:\n    runs-on: ubuntu-24.04\n    steps:\n      - uses: zq/{0}@v1', 'jobs:\n  j:\n    runs-on: ubuntu-24.04\n    steps:\n      - uses: actions/checkout@v4')},
    }
    siblings = {
        'ps1': ('[System.Math]::BigMul(1, 2)', 'System.Math.BigMul'),
        'py': ('import os\nos.getppid()', 'os.getppid'),
        'cs': (cs('Math.BigMul(1, 2);'), 'System.Math.BigMul'),
    }
    for _, (source, name) in siblings.items():
        assert name.rpartition('.')[0] + '.Abs' in table['dotnet'] or name.startswith('os.') and 'os.getpid' in table['python']
        assert name not in table['dotnet'] and name not in table['python']
    launches = {
        'ps1': {'call operator': "& '{0}.exe' $a", 'bare program': '{0}.exe $a', 'Start-Process': 'Start-Process {0}.exe', 'Process.Start': "[Diagnostics.Process]::Start('{0}.exe', 'x')"},
        'py': {'program list': "import subprocess\nsubprocess.run(['{0}', a])"},
        'cs': {'Process.Start': cs('Process.Start("{0}.exe");'), 'start settings': cs('Process.Start(new ProcessStartInfo("{0}.exe"));')},
        'cmd': {'command': '{0} a', 'after a condition': 'if exist a {0} a', 'after echo off': '@echo off & {0} a'},
        'sh': {'command': '{0} a', 'command substitution': 'x=$({0} a)'},
        'yml': {'bash step': 'jobs:\n  j:\n    runs-on: ubuntu-24.04\n    steps:\n      - run: {0} a', 'cmd step': 'jobs:\n  j:\n    runs-on: windows-2025\n    steps:\n      - shell: cmd\n        run: {0} a'},
    }
    always = {
        'ps1': {'Add-Type source': "Add-Type -TypeDefinition 'public class Q {}'", 'Add-Type path': 'Add-Type -Path a.cs', 'Add-Type native': "Add-Type -Name N -MemberDefinition '[DllImport(\"kernel32.dll\")] public static extern bool SetVolumeMountPointW(string a, string b);'",
                'Invoke-Expression': "Invoke-Expression 'Write-Host hi'", 'script block from text': "& ([scriptblock]::Create('Write-Host hi'))", 'default parameter values': "$PSDefaultParameterValues['Copy-Item:Recurse'] = $true",
                'method group invoke': "[System.IO.Directory]::GetFiles.Invoke('a')", 'function drive': "Set-Item -Path function:Write-Output -Value { }", 'module-qualified COM': 'Microsoft.PowerShell.Utility\\New-Object -ComObject WScript.Shell',
                'renamed cmdlet': "Set-Alias -Name Write-Output -Value find\nWrite-Output $a", 'parameter prefix with a value': 'Invoke-Command -FileP:x.ps1', 'recursive listing': 'Get-ChildItem -Rec $a'},
        'py': {'getattr': "import os\ngetattr(os, 'getpid')()", 'ctypes': "import ctypes\nctypes.windll.kernel32.CreateSymbolicLinkW('a', 'b', 1)", 'runpy': "import runpy\nrunpy.run_path('x.py')",
               'eval': "eval('1')", 'operator': "import operator\noperator.methodcaller('walk')", 'changed program list': "import subprocess\nc = ['whoami']\nc[0] = 'find'\nsubprocess.run(c)"},
        'cs': {'reflection': cs('typeof(System.IO.Directory).GetMethod("GetFiles")!.Invoke(null, null);'), 'compiled expression': cs('System.Linq.Expressions.Expression.Lambda(System.Linq.Expressions.Expression.Empty()).Compile();')},
        'sh': {'trap': "trap 'rm -rf a' EXIT", 'eval': 'eval x', 'command': 'command find -L a', 'function defined later': 'find a\nfind() { :; }'},
        'targets': {'Exec of a builtin': '<Project><Target Name="T"><Exec Command="echo hi" /></Target></Project>', 'entity in a property function': '<Project><PropertyGroup><P>$([System.IO.Directory]::&#x47;etFiles(\'a\'))</P></PropertyGroup></Project>', 'item glob': '<Project><ItemGroup><I Include="$(TEMP)\\**\\*" /></ItemGroup></Project>'},
        'yml': {'job-level workflow': 'jobs:\n  j:\n    uses: zq/x/.github/workflows/y.yml@v1', 'expression in a run step': 'jobs:\n  j:\n    runs-on: ubuntu-24.04\n    steps:\n      - run: echo ${{ env.X }}'},
    }
    always['ps1'].update({'wildcard folder in a path': "Remove-Item -Path (Join-Path $a '*\\*') -Force", 'function drive assignment': "${function:Zqvx} = 'Write-Output'",
                          'dot-source of a script the check does not read': ". (Join-Path $PSScriptRoot '..\\..\\..\\Zqvx.ps1')"})
    always['sh'].update({'glob with a wildcard folder': 'for f in "$a"/*/*; do echo "$f"; done'})
    always['py'].update({'self that is not a method parameter': 'class A:\n    def zqvx(self): pass\nself = object()\nself.zqvx()',
                         'value from a repo function': 'class A:\n    def zqvx(self): pass\ndef make():\n    return object()\nm = make()\nm.zqvx()'})
    always['cs'].update({'options object made elsewhere': cs('var o = System.Text.Json.JsonSerializer.Deserialize<System.IO.EnumerationOptions>("{}")!; System.IO.Directory.GetFiles(dir, "*", o);')})
    always['targets'].update({'item from an unknown property': '<Project><ItemGroup><I Include="$(Zqvx)" /></ItemGroup></Project>'})
    harmless = {
        'yml': {'workflow default python shell': 'defaults:\n  run:\n    shell: python\njobs:\n  j:\n    runs-on: ubuntu-24.04\n    steps:\n      - run: print(1)'},
        'ps1': {'later assignment': "$c = 'Write-Output'\n& $c hi\n$c = 'Zqvx-Item'", 'a tool word in a message': "Write-Output 'could not move the folder'"},
        'yml': {'runs-on list for Windows': 'jobs:\n  j:\n    runs-on: [self-hosted, windows-2025]\n    steps:\n      - run: Write-Output hi'},
        'py': {'a method of the class it is in': 'class A:\n    def zqvx(self):\n        return 1\n    def other(self):\n        return self.zqvx()'},
    }
    allowlist = 'tools/validation/reparse-walk-allowlist.json'
    cases, reasoned, known = {}, [], []
    def folder(extension):
        return '.github/workflows/' if extension == 'yml' else 'tools/validation/Control/'
    fill = lambda extension, text, name: text.replace('{0}', name) if extension == 'cs' else text.format(name)
    for extension, kinds in language.items():
        for kind, (refused, kept) in kinds.items():
            name = kind.replace(' ', '-')
            cases[f'{extension} {kind}: an unknown name is refused'] = (f'{folder(extension)}{name}-unknown.{extension}', fill(extension, refused, 'zqvx'), True)
            cases[f'{extension} {kind}: a listed name passes'] = (f'{folder(extension)}{name}-known.{extension}', fill(extension, kept, 'zqvx'), False)
    for extension, (source, _) in siblings.items():
        cases[f'{extension}: a member of an approved type is refused'] = (f'tools/validation/Control/sibling.{extension}', source, True)
    for extension, kinds in launches.items():
        for kind, template in kinds.items():
            name = kind.replace(' ', '-')
            cases[f'{extension} {kind}: an unlisted launch is refused'] = (f'{folder(extension)}{name}-launch.{extension}', fill(extension, template, 'zqvx'), True)
            listed = f'{folder(extension)}{name}-listed.{extension}'
            cases[f'{extension} {kind}: a listed launch passes'] = (listed, fill(extension, template, 'zqvx'), False)
            for program, why, refused in (('zqvx', None, False), ('robocopy', 'a tree tool', True), ('icacls', 'a permission tool', True), ('mountvol', 'a mount tool', True), ('pwsh', 'a shell', False)):
                path = f'{folder(extension)}{name}-{program}.{extension}' if why else listed
                if why:
                    cases[f'{extension} {kind}: {why} on the known list {"is refused" if refused else "passes"}'] = (path, fill(extension, template, program), refused)
                line = next(l.strip() for l in module['lines_of'](fill(extension, template, program)) if program in l)
                known.append({'file': path, 'line': line, 'kind': 'program', 'starts': program + '.exe' if '{0}.exe' in template else program})
    for extension, kinds in always.items():
        for kind, source in kinds.items():
            cases[f'{extension} {kind}: refused'] = (f'{folder(extension)}{kind.replace(" ", "-")}-always.{extension}', source, True)
    for extension, kinds in harmless.items():
        for kind, source in kinds.items():
            cases[f'{extension} {kind}: passes'] = (f'{folder(extension)}{kind.replace(" ", "-")}-harmless.{extension}', source, False)
    cases['a line in a helper file is refused'] = ('tools/validation/OptimizerCore/TestFixtures.cs', cs('System.IO.Directory.GetFiles(dir, "*", System.IO.SearchOption.AllDirectories);'), True)
    cases['a line in the Python walk helper is refused'] = ('tools/validation/local_tree.py', "import os\nos.walk('a')", True)
    cases['a recursive walk in product code is refused'] = ('backend/native/Control/Walk.cs', cs('System.IO.Directory.GetFiles(dir, "*", System.IO.SearchOption.AllDirectories);'), True)
    cases['a recursive walk in product code that names no tool is refused'] = ('backend/native/Control/Cast.cs', cs('System.IO.Directory.GetFiles(dir, "*", (System.IO.SearchOption)1);'), True)
    cases['a one-folder listing in product code passes'] = ('backend/native/Control/List.cs', cs('System.IO.Directory.GetFiles(dir, "*", System.IO.SearchOption.TopDirectoryOnly);'), False)
    cases['a file type with no reader is refused'] = ('tools/validation/Control/run.foo', 'zqvx a', True)
    cases['a script outside the read scope is written'] = ('Zqvx.ps1', 'Write-Output hi', False)
    cases['an extensionless file is refused'] = ('tools/validation/Control/run', '#!/bin/sh\nzqvx a', True)
    cases['a file Python cannot read is refused'] = ('tools/validation/Control/broken.py', 'def (', True)
    cases['a file PowerShell cannot read is refused'] = ('tools/validation/Control/broken.ps1', 'function {', True)
    cases['a file with NUL bytes and no byte order mark is refused'] = ('tools/validation/Control/nul.cmd', b'rem \x00\r\n', True)
    cases['a UTF-16 file without a byte order mark is refused'] = ('tools/validation/Control/wide.ps1', 'robocopy C:\\ D:\\x /MIR'.encode('utf-16-be'), True)
    listed = 'tools/validation/Control/listed.ps1'
    cases['a reasoned line passes'] = (listed, 'Get-ChildItem -Recurse $a', False)
    reasoned.append({'file': listed, 'line': 'Get-ChildItem -Recurse $a', 'reason': 'control'})
    cases['a listed line is listed once'] = ('tools/validation/Control/twice.ps1', 'Get-ChildItem -Recurse $a\nGet-ChildItem -Recurse $a', True)
    reasoned.append({'file': 'tools/validation/Control/twice.ps1', 'line': 'Get-ChildItem -Recurse $a', 'reason': 'control'})
    cases['an entry without a reason is refused'] = ('tools/validation/Control/unexplained.ps1', 'Get-ChildItem -Recurse $a', True)
    reasoned.append({'file': 'tools/validation/Control/unexplained.ps1', 'line': 'Get-ChildItem -Recurse $a', 'reason': ' '})
    tree_tool = table['names']['R1']['anywhere'][0]
    for label, extension, source, line, kind, starts, refused in (
            ('a walk that follows links', 'ps1', 'Copy-Item -Recurse $a $b', None, 'R1', 'copy-item', True),
            ('a measured tree delete', 'ps1', 'Remove-Item -Recurse $a', None, 'tree delete, does not follow links (measured)', 'remove-item', False),
            ('a measured tree listing', 'ps1', 'Get-ChildItem -Recurse $a', None, 'tree listing, does not follow links (measured)', 'get-childitem', False),
            ('a line naming a link tool', 'ps1', "$x = 'mklink'; zqvx.exe $a", None, 'program', 'zqvx.exe', True),
            ('an entry with the wrong kind', 'ps1', 'Remove-Item -Recurse $b', None, 'program', 'remove-item', True),
            ('an entry with the wrong start', 'ps1', 'zqvx.exe $b', None, 'program', 'whoami', True),
            ('a shortened long option', 'sh', 'rm --recur -f a', None, 'program', 'rm', True),
            ('a recursive short switch', 'sh', 'ls -lR a', None, 'program', 'ls', True),
            ('a switch joined to its command', 'cmd', 'attrib/s a', None, 'program', 'attrib/s', True),
            ('a link tool on a later argument line', 'py', "import subprocess\nsubprocess.run(['powershell', '-c', 'zqvx', a,\n    'mklink'])", "subprocess.run(['powershell', '-c', 'zqvx', a,", 'program', 'powershell', True),
            ('a first word that makes a tree tool', 'sh', 'git clean -fdx a', None, 'program', 'git', True),
            ('an unreadable file', 'ps1', 'function {', None, 'file', '', True),
            ('an alias for a tree tool', 'ps1', 'Set-Alias -Name q -Value cpio', None, 'command the table does not list', 'set-alias', True),
            ('a tree listing whose shortened switch follows links', 'ps1', 'Get-ChildItem -Recurse -Fol $a', None, 'tree listing, does not follow links (measured)', 'get-childitem', True),
            ('a full program path joined to its switch', 'cmd', 'C:\\Windows\\System32\\attrib.exe/s a', None, 'program', 'c:\\windows\\system32\\attrib.exe/s', True),
            ('start settings changed through the argument list indexer', 'cs', cs('var p = new ProcessStartInfo("zqvx.exe"); p.ArgumentList.Add("a"); p.ArgumentList[0] = "b"; Process.Start(p);'), 'Process.Start(p);', 'program', 'zqvx.exe', True),
            ('a tree tool started through a variable', 'ps1', "$p = '" + tree_tool + "'\n& $p a b", '& $p a b', 'program', tree_tool, True),
            ('a folder move called through a using alias', 'cs', cs('L.Move(dir, dir + "x");', 'using L = System.IO.Directory;'), 'L.Move(', 'call the table does not list', 'system.io.directory.move', True),
            ('a full program path joined to its switch, started from C#', 'cs', cs('Process.Start(@"C:\\Windows\\System32\\attrib.exe/s");'), 'Process.Start(', 'program', 's', True),
            ('an archive add on a typed value', 'py', "import tarfile\nt = tarfile.open(a, 'w')\nt.add(b)", "t = tarfile.open(a, 'w')", 'call the table does not list', 'tarfile.open', True),
            ('a type name built from values the check cannot read, reported on its own line', 'ps1', 'New-Object System.Data.DataTable -Property @{ TableName = $a }', None, 'the type name is built from values the check cannot read', '', False)):
        path = f'tools/validation/Control/known-{label.replace(" ", "-")}.{extension}'
        cases[f'{label} on the known list {"is refused" if refused else "passes"}'] = (path, source, refused)
        known.append({'file': path, 'line': next(l.strip() for l in module['lines_of'](source) if line in l) if line else source, 'kind': kind, 'starts': starts})
    for extension, source, line, harm, starts in (('py', 'import os\nos.link(a, b)', 'os.link(a, b)', 'R3', 'os.link'),
                                                  ('ps1', "[System.IO.File]::CreateSymbolicLink('a', 'b')", "[System.IO.File]::CreateSymbolicLink('a', 'b')", 'R3', 'system.io.file.createsymboliclink'),
                                                  ('cs', cs('new System.IO.DirectoryInfo(dir).SetAccessControl(null!);', 'using System.IO;'), 'SetAccessControl', 'R2', 'system.io.filesystemaclextensions.setaccesscontrol')):
        cases[f'{extension}: a {harm} call on the known list is refused'] = (f'tools/validation/Control/{harm}-call.{extension}', source, True)
        line = next(l.strip() for l in module['lines_of'](source) if line in l)
        known.append({'file': f'tools/validation/Control/{harm}-call.{extension}', 'line': line, 'kind': 'call the table does not list', 'starts': starts})
    reasoned.append({'file': 'tools/validation/Control/missing.ps1', 'line': 'Get-ChildItem -Recurse', 'reason': 'control'})
    reasoned.append({'file': 'tools/validation/Control/known-a-tree-tool-started-through-a-variable.ps1', 'line': "$p = '" + tree_tool + "'", 'reason': 'control'})
    results = {}
    for projects in (True, False):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            chosen = {label: case for label, case in cases.items() if case[0].endswith('.targets') == projects}
            for relative, source, _ in chosen.values():
                (root / relative).parent.mkdir(parents=True, exist_ok=True)
                (root / relative).write_bytes(source if isinstance(source, bytes) else source.encode('utf-8'))
            (root / allowlist).write_text(json.dumps({'reasoned exceptions': [e for e in reasoned if e['file'].endswith('.targets') == projects],
                                                      'known': [e for e in known if e['file'].endswith('.targets') == projects]}), encoding='utf-8')
            failures = module['verify'](root)
            for label, (relative, _, refused) in chosen.items():
                hit = any(f.startswith(relative + ':') for f in failures)
                if label == 'an entry without a reason is refused':
                    hit = any(f.startswith(allowlist + ':') and 'unexplained.ps1' in f for f in failures)
                if label == 'start settings changed through the argument list indexer on the known list is refused':
                    hit = any(f.startswith(relative + ':') and 'the program this starts is built from values the check cannot read' in f for f in failures)
                results[label] = hit == refused
            if projects:
                results['a refused project file stops the check before any project is evaluated'] = any('stopped before evaluating any project' in f for f in failures)
            else:
                results['a stale entry is refused'] = any('stale entry' in f and 'missing.ps1' in f for f in failures)
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        classifier = module['Classifier']([], {'functions': {}, 'aliases': {}})
        kinds = {'dotnet': ('call', 'csharp'), 'python': ('call', 'python'), 'python methods': ('method', 'python'), 'powershell methods': ('method', 'powershell'), 'powershell': ('command', 'powershell')}
        for section, entries in table.items():
            for name, entry in entries.items() if section in kinds else []:
                for index, condition in enumerate(entry.get('safe', []) if isinstance(entry, dict) else []):
                    if 'without' in condition:
                        args = [{'param': condition['without'][0][:3]}]
                    elif 'param' in condition:
                        args = [{'param': condition['param'][0], 'value': 'zqvx'}]
                    elif 'blocks' in condition:
                        args = [{'param': 'FileP'}]
                    elif 'one folder' in condition:
                        args = [{'i': condition['arg'], 'value': '*/x'}]
                    else:
                        args = [{'i': condition['arg'], 'name': condition['arg'], 'value': 'zqvx', 'type': condition.get('type', 'zqvx')}]
                    kind, lang = kinds[section]
                    found = classifier.classify({'file': 'x', 'line': 1, 'text': '', 'kind': kind, 'name': name, 'args': args, 'language': lang})
                    results[f'table rule {index + 1} of {section} {name} refuses when broken'] = bool(found)
        members = [(section, name) for section in ('dotnet', 'python') for name in table[section]]
        unapproved = [section + ' ' + name for section, name in members
                      if not classifier.classify({'file': 'x', 'line': 1, 'text': '', 'kind': 'call', 'name': name + '.Zqvx', 'args': [], 'language': 'python' if section == 'python' else 'csharp'})]
        results[f'a member under any of the {len(members)} approved names is refused'] = not unapproved
        outside = root / 'outside'
        (outside / 'deep').mkdir(parents=True)
        (outside / 'deep' / 'kept.txt').write_text('outside', encoding='utf-8')
        walked = root / 'walked'
        walked.mkdir()
        (walked / 'own.txt').write_text('own', encoding='utf-8')
        link = walked / 'link'
        if sys.platform == 'win32':
            import _winapi
            _winapi.CreateJunction(str(outside), str(link))
        else:
            link.symlink_to(outside, target_is_directory=True)
        (walked / 'leaf').symlink_to(outside / 'deep' / 'kept.txt')
        seen = sorted(path.relative_to(walked).as_posix() for path in local_tree(walked))
        results['local tree neither enters nor yields a link'] = seen == ['own.txt']
        named = sorted(path.relative_to(walked).as_posix() for path in local_tree(walked, links=True))
        results['local tree names links only when asked'] = named == ['leaf', 'link', 'own.txt']
        for spelling, start in (('', str(link)), (' written with a trailing separator', str(link) + os.sep), (' written with a trailing dot', os.path.join(str(link), '.'))):
            try:
                entered = list(local_tree(start))
            except NotADirectoryError:
                entered = None
            results['local tree refuses a root that is a link' + spelling] = entered is None
    return results


def reparse_name_controls(module):
    named = module['NAMED']
    wrap = {'ps1': "$x = '{0}'", 'py': "x = '{0}'", 'cs': '    static string X{1} = "{0}";', 'sh': ": '{0}'", 'cmd': 'echo {0}', 'yml': "          : '{0}'", 'targets': '    <Message Text="{0}" />'}
    head = {'cs': 'static class Control {', 'yml': 'jobs:\n  j:\n    runs-on: ubuntu-24.04\n    steps:\n      - run: |', 'targets': '<Project><Target Name="T">'}
    tail = {'cs': '}', 'targets': '</Target></Project>'}
    shells = {'ps1': 'powershell', 'sh': 'bash', 'cmd': 'cmd', 'yml': 'bash', 'targets': 'cmd'}
    rows = {extension: [] for extension in wrap}
    for harm in ('R1', 'R2', 'R3'):
        rules = named[harm]
        for name in rules['anywhere']:
            for extension in rows:
                rows[extension] += [(f'{harm} {name} in {extension}', name, name), (f'{harm} {name} glued in {extension}', name, '9' + name + 'zq')]
        for name, rule in list(rules['words'].items()) + list(rules['switched'].items()):
            languages = rule if isinstance(rule, list) else rule['languages']
            switch = '' if isinstance(rule, list) else ' -' + rule['letters'][0] if 'letters' in rule else ' /' + rule['switches'][0] if 'switches' in rule else ' ' + rule['first'][0]
            for extension in rows:
                if shells.get(extension, 'bash' if extension in ('py', 'cs') else None) in languages or extension in ('py', 'cs'):
                    rows[extension] += [(f'{harm} {name} in {extension}', name, f'{name}{switch} a'), (f'{harm} {name} glued in {extension}', name, f'{name}.exe{switch} a' if extension == 'cs' else f'/zq/{name}.exe{switch} a')]
        for label, rule in rules['patterns'].items():
            for extension, language in (('ps1', 'powershell'), ('py', 'python'), ('cs', 'csharp'), ('sh', 'bash'), ('cmd', 'cmd')):
                if language in rule['languages'] or 'all' in rule['languages']:
                    rows[extension].append((f'{harm} {label} in {extension}', label, rule['example']))
    results = {}
    for projects in (True, False):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            places = {}
            for extension, lines in rows.items():
                if (extension == 'targets') != projects:
                    continue
                relative = ('.github/workflows/names.yml' if extension == 'yml' else f'tools/validation/Control/names.{extension}')
                text = head[extension].split('\n') if extension in head else []
                for index, (label, name, value) in enumerate(lines):
                    places[label] = (relative, len(text) + 1, name)
                    text.append(wrap[extension].format(value, index))
                text += [tail[extension]] if extension in tail else []
                (root / relative).parent.mkdir(parents=True, exist_ok=True)
                (root / relative).write_text('\n'.join(text) + '\n', encoding='utf-8')
            failures = module['verify'](root)
            for label, (relative, line, name) in places.items():
                results[f'name control {label} is refused'] = any(f.startswith(f'{relative}:{line}:') and f'names {name},' in f for f in failures)
    return results


def validate(root: Path, contracts_only: bool = False):
    failures = []
    failures.extend(code_loading_failures(root))
    for label, rejected in code_loading_negative_controls(root).items():
        if not rejected:
            failures.append(f'Negative control failed: a {label} passed the clearing check')
    failures.extend(runpy.run_path(str(Path(__file__).with_name('check_windows_tweaks.py')))['check'](root))
    if not contracts_only:
        tweak_reads = runpy.run_path(str(Path(__file__).with_name('check_tweak_reads.py')))
        failures.extend(tweak_reads['check'](root))
        for label, passed in tweak_reads['negative_controls'](root).items():
            if not passed:
                failures.append(f'Negative control failed: {label} was not stopped at the read walk timeout')
        failures.extend(runpy.run_path(str(Path(__file__).with_name('check_launch_presets.py')))['check'](root))
        failures.extend(runpy.run_path(str(Path(__file__).with_name('check_tool_words.py')))['check'](root))
        memory_words = runpy.run_path(str(Path(__file__).with_name('check_memory_words.py')))
        failures.extend(memory_words['check'](root))
        for label, caught in memory_words['negative_controls'](root).items():
            if not caught:
                failures.append(f'Negative control failed: {label} passed the Memory plain words check')
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
        agent_files = runpy.run_path(str(Path(__file__).with_name('check_agent_files.py')))
        failures.extend(agent_files['check'](root))
        for label, passed in agent_files['negative_controls']().items():
            if not passed:
                failures.append(f'Negative control failed: {label} did not match the agent file check result')
        failures.extend(runpy.run_path(str(Path(__file__).with_name('check_fixture_cleanup.py')))['check'](root))
        for label, passed in fixture_cleanup_negative_controls().items():
            if not passed:
                failures.append(f'Negative control failed: {label} did not match the fixture cleanup check result')
        failures.extend(runpy.run_path(str(Path(__file__).with_name('check_reparse_walks.py')), run_name='walks')['verify'](root))
        controls = reparse_walk_negative_controls()
        controls.update(reparse_name_controls(runpy.run_path(str(Path(__file__).with_name('check_reparse_walks.py')), run_name='controls')))
        for label, passed in controls.items():
            if not passed:
                failures.append(f'Negative control failed: {label} did not match the reparse walk check result')
        failures.extend(runpy.run_path(str(Path(__file__).with_name('check_workflow_runners.py')))['check'](root))
    documents = {}
    for folder in ('backend/contracts', 'backend/samples', 'backend/profiles', 'backend/uninstall', 'backend/catalogs', 'backend/capabilities', 'modules'):
        for path in sorted(local_tree(root / folder, '*.json')):
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
            for path in local_tree(frontend, extension):
                if {'bin', 'obj'}.intersection(path.parts):
                    continue
                try:
                    ET.parse(path)
                    xml_count += 1
                except ET.ParseError as error:
                    failures.append(f'{path.relative_to(root)}: {error}')
        for folder in ('backend', 'modules', 'tools', 'docs'):
            for path in local_tree(root / folder):
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
        if any(local_tree(root / 'backend/state', links=True)):
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
