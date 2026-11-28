import json
import os
from pathlib import Path
import re
import runpy
import sys
import tempfile

HERE = Path(__file__).resolve().parent
local_tree = runpy.run_path(str(HERE / 'local_tree.py'))['entries']
ALLOWLIST = 'tools/validation/reparse-walk-allowlist.json'
SHARP = 'using System; using System.Diagnostics; using System.Runtime.InteropServices; {0}\nstatic class Control {{\n  [DllImport("kernel32.dll")] static extern uint GetCurrentProcessId();\n  [DllImport("kernel32.dll")] static extern void Zqvx();\n  static async System.Threading.Tasks.Task M(string dir, object x, string zq) {{ {1} }}\n}}'


class Cases:
    def __init__(self):
        self.files, self.expect, self.reasoned, self.known = {}, {}, [], []

    def add(self, label, extension, source, refused, line=None, known=None, reasoned=None, folder=None):
        folder = folder if folder is not None else '.github/workflows/' if extension == 'yml' else 'tools/validation/Control/'
        relative = f'{folder}c{len(self.files)}.{extension}'
        self.files[relative] = source
        self.expect[label] = (relative, line, refused)
        lines = re.split(r'\r\n|\r|\n', source if isinstance(source, str) else '')
        text = next((l.strip() for l in lines if line and l.strip() == line.strip()), None) or next((l.strip() for l in lines if line and line in l), source.strip() if isinstance(source, str) else '')
        if known:
            self.known.append({'file': relative, 'line': text, 'row': known})
        if reasoned:
            self.reasoned.append({'file': relative, 'line': text, 'reason': reasoned})
        return relative


def cs(body, using=''):
    return SHARP.format(using, body)


def implicit(parameter, body):
    return 'static class Control { static void N(' + parameter + ') { ' + body + ' } }'


def option_values(spec):
    return ['zq'] * spec if isinstance(spec, int) else [] if spec == 'flag' else [spec[0]] if isinstance(spec, list) else ['zq']


def program_lines(name, tokens):
    sh = ' '.join([name] + ['"$zq"' if t is None else t for t in tokens])
    ps1 = ' '.join([f"& '{name}'"] + ['$zq' if t is None else t for t in tokens])
    py = 'import subprocess\nsubprocess.run([' + ', '.join([repr(name)] + ['zq' if t is None else repr(t) for t in tokens]) + '])'
    sharp = cs('Process.Start("' + name + '", "' + ' '.join('" + zq + "' if t is None else t.replace('"', '\\"') for t in tokens) + '");')
    return {'sh': (sh, name), 'ps1': (ps1, name), 'py': (py, 'subprocess.run('), 'cs': (sharp, 'Process.Start(')}


def sample(row):
    tokens = []
    for option, spec in list(row.get('options', {}).items())[:3]:
        tokens.append(option)
        tokens += ['zq'] * spec if isinstance(spec, int) else [spec[0]] if isinstance(spec, list) else [] if spec == 'flag' else ['zq']
    if row.get('operands'):
        tokens.append(row['operands'][0] if isinstance(row['operands'], list) else 'zq')
    return tokens


def program_cases(cases, table):
    for name, row in table['programs'].items():
        subs = row.get('subcommands') or {None: row}
        for sub, inner in subs.items():
            label = f'{name} {sub}' if sub else name
            lead = [sub] if sub else []
            good = lead + sample(inner)
            switch = inner.get('switch', '-')[0]
            variants = [('matching its row with a known entry passes', good, False, label), ('matching its row without an entry is refused', good, True, None),
                        ('with an unlisted option is refused', good + [switch + 'zqvx'], True, label)]
            if inner.get('operands') and inner['operands'] != 'any':
                variants.append(('with a computed operand is refused', lead + [t for t in sample(inner)[:-1]] + [None], True, label))
            if inner.get('operands') == 'any':
                variants.append(('with a computed operand passes', lead + sample(inner)[:-1] + [None], False, label))
            if not inner.get('operands'):
                variants.append(('with an operand is refused', good + ['zq'], True, label))
            cased = next((o for o in inner.get('options', {}) if o != o.swapcase() and o.swapcase() not in inner['options']), None)
            if cased:
                variants.append((f'with an option in another case {"is refused" if row.get("case") == "sensitive" else "passes"}', lead + [cased.swapcase()] + option_values(inner['options'][cased]), row.get('case') == 'sensitive', label))
            for option, spec in inner.get('options', {}).items():
                if spec not in ('flag', 'any') and not isinstance(spec, int):
                    variants.append((f'with a computed value for {option} is refused', lead + [option, None], True, label))
                if isinstance(spec, list):
                    variants.append((f'with an unlisted value for {option} is refused', lead + [option, 'Zqvx'], True, label))
                if spec == 'flag' or isinstance(spec, int):
                    variants.append((f'with a value after = on {option} is refused', lead + [option + '=zq'], True, label))
                else:
                    value = spec[0] if isinstance(spec, list) else 'zq'
                    variants.append((f'with the value of {option} after = passes', lead + [f'{option}={value}'], False, label))
                    if len(option) == 2:
                        variants.append((f'with the value of {option} attached passes', lead + [option + value], False, label))
                if isinstance(spec, int):
                    variants.append((f'with {option} given fewer than {spec} values is refused', lead + [option] + ['zq'] * (spec - 1), True, label))
            if inner.get('literal'):
                variants.append(('with a computed first argument is refused', lead + [None] + sample(inner)[1:], True, label))
            if sub:
                variants += [('with an unlisted subcommand is refused', ['zqvx'] + good[1:], True, f'{name} zqvx'), ('with a computed subcommand is refused', [None] + good[1:], True, label)]
            for what, tokens, refused, known in variants:
                for extension, (source, line) in program_lines(name, tokens).items():
                    if extension == 'cs' and what != 'matching its row with a known entry passes':
                        continue
                    if extension == 'sh' and switch == '/' or extension == 'py' and None in tokens[:1]:
                        continue
                    cases.add(f'program row {label} {what} in {extension}', extension, source, refused, line, known)
        cases.add(f'program row {name} in a computed folder is refused', 'ps1', f"& \"$zq\\{name}.exe\" " + ' '.join(t for t in sample(next(iter(subs.values()))) if t), True, known=name)


def ps_value(kind):
    return None if kind == 'switch' else '{ }' if kind == 'block' else '$zq' if kind == 'any' else 'zq' if kind == 'name' else "'zq'" if kind in ('plain', 'literal') else kind[0]


def cmdlet_cases(cases, table):
    for name, row in table['approved']['powershell'].items():
        title = '-'.join(part.capitalize() for part in name.split('-'))
        if isinstance(row, str):
            cases.add(f'cmdlet row {name} takes a splat', 'ps1', f'{title} @zq', False)
            cases.add(f'cmdlet row {name} takes any parameter from the pipeline', 'ps1', f'$zq | {title} -Zqvx $zq', False)
            continue
        params = row.get('params', {})
        line = lambda chosen: ' '.join([title] + [f'-{p}' + ('' if ps_value(params[p]) is None else ' ' + ps_value(params[p])) for p in chosen])
        good = line(list(params))
        cases.add(f'cmdlet row {name} with every listed parameter passes', 'ps1', good, False)
        cases.add(f'cmdlet row {name} with an unlisted parameter is refused', 'ps1', good + ' -Zqvx $zq', True)
        cases.add(f'cmdlet row {name} with a splat is refused', 'ps1', good + ' @zq', True)
        cases.add(f'cmdlet row {name} from the pipeline {"passes" if row.get("pipeline") else "is refused"}', 'ps1', f'$zq | {good}', not row.get('pipeline'))
        cases.add(f'cmdlet row {name} with a common parameter passes', 'ps1', good + ' -ErrorAction $zq', False)
        cased = next((p for p in params if p != p.swapcase()), None)
        if cased:
            cases.add(f'cmdlet row {name} with -{cased} in another case passes', 'ps1', good.replace(f'-{cased}', f'-{cased.swapcase()}', 1), False)
        for p, kind in params.items():
            if kind == 'plain':
                cases.add(f'cmdlet row {name} with a wildcard in -{p} is refused', 'ps1', good.replace(f"-{p} 'zq'", f"-{p} 'zq*'", 1), True)
            if kind == 'name':
                cases.add(f'cmdlet row {name} with -{p} naming PATH is refused', 'ps1', good.replace(f'-{p} zq', f'-{p} PATH', 1), True)
        long = next((p for p in params if len(p) > 3 and not any(q != p and q.lower().startswith(p[:3].lower()) for q in params)), None)
        if long:
            cases.add(f'cmdlet row {name} with -{long} shortened is refused', 'ps1', good.replace(f'-{long}', f'-{long[:3]}', 1), True)
        for p, kind in params.items():
            if kind not in ('any', 'switch'):
                cases.add(f'cmdlet row {name} with a computed -{p} is refused', 'ps1', good.replace(f'-{p} {ps_value(kind)}', f'-{p} $zq', 1), True)
            if isinstance(kind, list):
                cases.add(f'cmdlet row {name} with an unlisted -{p} value is refused', 'ps1', good.replace(f'-{p} {ps_value(kind)}', f'-{p} Zqvx', 1), True)
        if row.get('bound'):
            cases.add(f'cmdlet row {name} with no path bound is refused', 'ps1', line([p for p in params if p not in row['bound'] and params[p] != 'block' and p not in row.get('positional', [])]), True)
        positional = row.get('positional', [])
        if not positional:
            cases.add(f'cmdlet row {name} with a positional argument is refused', 'ps1', f'{title} zq', True)
        if positional:
            first = params[positional[0]]
            cases.add(f'cmdlet row {name} with positional arguments passes', 'ps1', f'{title} ' + ' '.join(ps_value(params[p]) or 'zq' for p in positional), False)
            if first not in ('any', 'switch'):
                cases.add(f'cmdlet row {name} with a computed positional argument is refused', 'ps1', f'{title} $zq', True)
            if row.get('remaining'):
                cases.add(f'cmdlet row {name} takes the remaining arguments', 'ps1', f'{title} ' + ' '.join([ps_value(params[p]) or 'zq' for p in positional] * 2), False)
            else:
                cases.add(f'cmdlet row {name} with an extra positional argument is refused', 'ps1', f'{title} ' + ' '.join([ps_value(params[p]) or 'zq' for p in positional + positional[-1:]]), True)


def builtin_cases(cases, table):
    for shell, extension in (('bash', 'sh'), ('cmd', 'cmd')):
        for name, row in table['approved'][shell].items():
            if isinstance(row, str):
                cases.add(f'{shell} builtin {name} passes', extension, f'{"if 1==1 " if shell == "cmd" else ""}{name} zq', False)
                continue
            good = sample(row)
            cases.add(f'{shell} builtin {name} matching its row passes', extension, ' '.join([name] + good), False)
            cases.add(f'{shell} builtin {name} with an unlisted option is refused', extension, ' '.join([name] + good + ['-zqvx']), True)
            if row.get('literal'):
                cases.add(f'{shell} builtin {name} with a computed first argument is refused', extension, ' '.join([name, '"$zq"'] + good[1:]), True)
            if row.get('operands') not in (None, 'any'):
                cases.add(f'{shell} builtin {name} with a computed operand is refused', extension, ' '.join([name] + good[:-1] + ['"$zq"']), True)
            if row.get('operands') == 'name':
                cases.add(f'{shell} builtin {name} with an operand that is not a plain name is refused', extension, ' '.join([name] + good[:-1] + ["'a[x]'"]), True)
            for option, spec in row.get('options', {}).items():
                if spec not in ('flag', 'any') and not isinstance(spec, int):
                    cases.add(f'{shell} builtin {name} with a computed value for {option} is refused', extension, ' '.join([name, option, '"$zq"']), True)
            cased = next((o for o in row.get('options', {}) if o != o.swapcase() and o.swapcase() not in row['options']), None)
            if row.get('case') == 'sensitive' and cased:
                cases.add(f'{shell} builtin {name} with an option in another case is refused', extension, ' '.join([name, cased.swapcase()] + option_values(row['options'][cased])), True)


def runner_cases(cases, table):
    for number, runner in enumerate(table['runners']):
        call = f'Zqvx-Run{number} zq'
        cases.add(f'runner {runner}: a function that gives its parameter to it is a launcher, so its call is refused', 'ps1', f"function Zqvx-Run{number}($p) {{ & '{runner}' $p }}\n{call}", True, line=call)
        cases.add(f'runner {runner}: a bash function that gives its arguments to it is a launcher, so its call is refused', 'sh', f"zqvxrun{number}() {{ '{runner}' \"$@\"; }}\nzqvxrun{number} zq", True, line=f'zqvxrun{number} zq')


def name_cases(cases, table):
    cmdlets = table['approved']['powershell']
    for alias, target in table['powershell aliases'].items():
        row = cmdlets.get(target)
        params = {} if row is None or isinstance(row, str) else row.get('params', {})
        arguments = ' '.join(f'-{p}' + ('' if ps_value(k) is None else ' ' + ps_value(k)) for p, k in params.items()) if isinstance(row, dict) else '@zq'
        matches = row is not None and alias not in table['powershell platform aliases']
        piped = '$zq | ' if not isinstance(row, dict) or row.get('pipeline') else ''
        cases.add(f'alias {alias} of {target} {"matches its row" if matches else "is refused"}', 'ps1', f'{piped}{alias} {arguments}', not matches)
        if matches and isinstance(row, dict):
            cases.add(f'alias {alias} of {target} with an unlisted parameter is refused', 'ps1', f'{piped}{alias} {arguments} -Zqvx $zq', True)


def reader_cases(cases, table):
    title = lambda name: '-'.join(part.capitalize() for part in name.split('-'))
    for name in list(table['powershell path functions']) + ['zqvx-path']:
        call = f"& ({title(name)} 'C:\\T\\whoami.exe') /user"
        listed = name in table['powershell path functions']
        cases.add(f'path function {name} {"passes the path on" if listed else "is not listed, so its program is refused"}', 'ps1', f'function {title(name)}($p) {{ $p }}\n{call}', not listed, line=call, known='whoami')
    for name in list(table['powershell argument joiners']) + ['zqvx-join']:
        call = '[System.Diagnostics.Process]::Start($i)'
        source = f"function {title(name)}($a) {{ $a -join ' ' }}\n$i = [System.Diagnostics.ProcessStartInfo]::new('C:\\T\\whoami.exe')\n$i.Arguments = {title(name)} @('/user', '/priv')\n{call}"
        listed = name in table['powershell argument joiners']
        cases.add(f'argument joiner {name} {"passes its items on" if listed else "is not listed, so its arguments are refused"}', 'ps1', source, not listed, line=call, known='whoami')
    for name in table['msbuild path properties']:
        cases.add(f'msbuild path property {name} reads as a plain folder', 'targets', f'<Project><ItemGroup><I Include="$({name})zq.cs" /></ItemGroup></Project>', False)
    for extension in table['data']:
        cases.add(f'data file type {extension} is not read', extension, 'zqvx a', False)


def call_results(rows, table):
    results = {}
    classifier = rows['Classifier']([], {'functions': {}, 'aliases': {}})
    kinds = {'dotnet': ('call', 'csharp'), 'python': ('call', 'python'), 'python methods': ('method', 'python'), 'powershell methods': ('method', 'powershell'), 'native': ('native', 'csharp'), 'workflow': ('call', 'workflow')}

    def good(condition):
        if condition.get('absent') and condition.get('in') == []:
            return None
        value = 'zq/x.txt' if 'one folder' in condition else 'Zqvx' if 'literal not in' in condition else condition['in'][0]
        return {'i': condition['arg'], 'name': condition['arg'], 'value': value}

    def bad(condition):
        if 'one folder' in condition:
            return [{'i': condition['arg'], 'name': condition['arg'], 'value': '*/x'}, {'i': condition['arg'], 'name': condition['arg']}]
        if 'literal not in' in condition:
            return [{'i': condition['arg'], 'name': condition['arg'], 'value': condition['literal not in'][0]}, {'i': condition['arg'], 'name': condition['arg']}]
        return [{'i': condition['arg'], 'name': condition['arg'], 'value': 'zqvx'}, {'i': condition['arg'], 'name': condition['arg']}]
    for section, (kind, language) in kinds.items():
        for name, entry in table['approved'][section].items():
            fact = lambda args: {'file': 'x', 'line': 1, 'text': '', 'kind': kind, 'name': name, 'args': args, 'language': language}
            conditions = [] if isinstance(entry, str) else entry.get('args', [])
            given = [a for a in (good(c) for c in conditions) if a]
            results[f'{section} row {name} matching its row is approved'] = not classifier.classify(fact(given))
            if conditions:
                results[f'{section} row {name} with a splatted argument is refused'] = bool(classifier.classify(fact(given + [{'splat': True}])))
            for index, condition in enumerate(conditions):
                others = [a for i, a in enumerate(good(c) for c in conditions) if i != index and a]
                for broken in bad(condition):
                    results[f'{section} row {name} with condition {index + 1} broken ({json.dumps(broken)}) is refused'] = bool(classifier.classify(fact(others + [broken])))
                if not condition.get('absent'):
                    results[f'{section} row {name} with argument {condition["arg"]} left out is refused'] = bool(classifier.classify(fact(others)))
                if 'type' in condition:
                    other = {'i': condition['arg'], 'name': condition['arg'], 'type': 'Zqvx'}
                    results[f'{section} row {name} with argument {condition["arg"]} of another type is refused'] = bool(classifier.classify(fact(others + [other])))
                    results[f'{section} row {name} with argument {condition["arg"]} of another type made in the call is approved'] = not classifier.classify(fact(others + [dict(other, created=True)]))
    members = [(section, name) for section in ('dotnet', 'python') for name in table['approved'][section]]
    unapproved = [section + ' ' + name for section, name in members
                  if not classifier.classify({'file': 'x', 'line': 1, 'text': '', 'kind': 'call', 'name': name + '.Zqvx', 'args': [], 'language': 'python' if section == 'python' else 'csharp'})]
    results[f'a member under any of the {len(members)} approved names is refused'] = not unapproved
    for section, (kind, language) in kinds.items():
        results[f'{section}: a name the table does not list is refused'] = bool(classifier.classify({'file': 'x', 'line': 1, 'text': '', 'kind': kind, 'name': '.zqvx' if 'methods' in section else 'zqvx!zqvx' if kind == 'native' else 'Zqvx.Zqvx', 'args': [], 'language': language}))
    return results


def fixed_cases(cases):
    helper = cases.add('py a plain module passes', 'py', 'x = 1', False).rpartition('/')[2]
    language = {
        'ps1': {'command': ('Zqvx-Item $a', 'Write-Host $a'), 'pipeline': ('$a | Zqvx-Item', '$a | Write-Host'), 'alias': ('Set-Alias q zqvx; q $a', 'function r { Write-Host $args }; r $a'),
                'continuation': ('Zqvx-Item `\n  $a', 'Write-Host `\n  $a'), 'static .NET call': ('[System.Data.DataTable]::new()', '[System.Math]::Abs(1)'),
                'static member on a type variable': ('$t = [System.Data.DataTable]; $t::new()', '$t = [System.Math]; $t::Abs(1)'), 'instance method': ('$x.zqvx()', '$x.ToString()'),
                'ForEach-Object member': ('$x | ForEach-Object zqvx', '$x | ForEach-Object ToString'), 'command named by a string': ("& 'Zqvx-Item' $a", "& 'Write-Host' $a"),
                'parameter default': ('function f { param($c = "Zqvx-Item") & $c }; f', 'function f { param($c = "Write-Host") & $c hi }; f'), 'alias of an approved cmdlet': ('$x | zqvx -First 1', '$x | select -First 1')},
        'py': {'imported module member': ('import os\nos.zqvx(a)', 'import os\nos.getpid()'), 'from-import alias': ('from os import zqvx as w\nw(a)', 'from os import getpid as w\nw()'),
               'method on an unknown value': ('x.zqvx()', 'x = []\nx.append(1)'), 'reference passed as a value': ('import os\nlist(map(os.zqvx, a))', 'import os\nlist(map(os.fspath, a))'),
               'name bound nowhere': ('zqvx(a)', 'print(a)'), 'glob folder wildcard': ("import glob\nglob.glob('*/zqvx')", "import glob\nglob.glob('zqvx/*.txt')"),
               'repo script run by path': ("import runpy\nrunpy.run_path('zqvx.py')", "import runpy\nfrom pathlib import Path\nrunpy.run_path(str(Path(__file__).with_name('" + helper + "')))")},
        'cs': {'call': (cs('new System.Data.DataTable();'), cs('Math.Abs(1);')), 'method group': (cs('Func<System.Data.DataTable> f = System.Data.Common.DbProviderFactories.GetFactoryClasses;'), cs('Func<int, int> f = Math.Abs;')),
               'using alias': (cs('new Q();', 'using Q = System.Data.DataTable;'), cs('Q.Abs(1);', 'using Q = System.Math;')), 'dynamic': (cs('dynamic d = x; d.Zqvx();'), cs('object d = x; d.ToString();')),
               'native entry point': (cs('Zqvx();'), cs('GetCurrentProcessId();')), 'code the compiler cannot read': (cs('Zqvx.Run();'), cs('Math.Abs(1);')),
               'operation the reader has no rule for': (implicit('int p', 'var b = __makeref(p);'), implicit('int p', 'var b = p;')),
               'foreach over a collection': (implicit('System.Data.DataRowCollection p', 'foreach (var r in p) { }'), implicit('string p', 'foreach (var c in p) { }')),
               'operator method': (implicit('System.Data.SqlTypes.SqlInt32 p', 'var b = p + p;'), implicit('DateTime p', 'var b = p - p;')),
               'conversion method': (implicit('int p', 'System.Data.SqlTypes.SqlInt32 b = p;'), implicit('int p', 'long b = p;')),
               'using': (implicit('System.Data.DataTable p', 'using (p) { }'), implicit('System.IO.MemoryStream p', 'using (p) { }')),
               'deconstruction': (implicit('System.Collections.Generic.KeyValuePair<int, int> p', 'var (a, b) = p;'), implicit('(int, int) p', 'var (a, b) = p;')),
               'implicit index': (implicit('System.Data.DataRowCollection p', 'var b = p[^1];'), implicit('string p', 'var b = p[^1];')),
               'collection expression': (implicit('int p', 'System.Collections.Immutable.ImmutableList<int> b = [p];'), implicit('int p', 'int[] b = [p];')),
               'generic new': ('static class Control { static T Q<T>() where T : new() => new T(); }', implicit('int p', 'var b = p;'))},
        'sh': {'command': ('zqvx a', 'echo a'), 'arithmetic on a variable': ('x=$((y + 1))', 'x=$((1 + 1))'), 'arithmetic on a parameter that is always a number': ('x=$((y + $#))', 'x=$(($# + $?))'), 'arithmetic comparison': ('[[ $a -eq 1 ]]', '[[ $a == b ]]'),
               'array index': ('echo "${a[$i]}"', 'echo "${a[0]}"'), 'prompt expansion': ('echo "${p@P}"', 'echo "${p@Q}"'), 'indirect expansion': ('echo "${!p}"', 'echo "${!a[@]}"'),
               'integer declaration': ('declare -i n=1', 'local -r n=1'), 'command in a here-document': ('echo <<EOF\n$(zqvx)\nEOF', 'echo <<EOF\n$(echo a)\nEOF'),
               'function defined later': ('zqvx\nzqvx() { :; }', 'zqvx() { :; }\nzqvx'), 'function defined in a branch': ('if true; then zqvx() { :; }; fi\nzqvx', 'zqvx() { :; }\nzqvx'),
               'function unset': ('zqvx() { :; }\nunset -f zqvx\nzqvx', 'zqvx() { :; }\nzqvx'), 'glob with a wildcard folder': ('for f in "$a"/*/*; do echo "$f"; done', 'for f in "$a"/*; do echo "$f"; done'),
               'a pattern that only trims text': ('for f in "$a"/*/*; do echo "${f##*/}"; done', 'echo "${f##*/}"'), 'a pattern that only compares text': ('ls "$a"/x*/y', '[[ $a == */x ]]')},
        'targets': {'task': ('<Project><Target Name="T"><Zqvx /></Target></Project>', '<Project><Target Name="T"><Message Text="hi" /></Target></Project>'),
                    'item pattern': ('<Project><ItemGroup><I Include="zq\\*.cs" /></ItemGroup></Project>', '<Project><ItemGroup><I Include="zq.cs" /></ItemGroup></Project>'),
                    'target inputs': ('<Project><Target Name="T" Inputs="zq\\*.cs" Outputs="zq.txt" /></Project>', '<Project><Target Name="T" Inputs="zq.cs" Outputs="zq.txt" /></Project>'),
                    'SDK default items': ('<Project Sdk="Microsoft.NET.Sdk" />', '<Project />')},
        'yml': {'action': ('jobs:\n  j:\n    runs-on: ubuntu-24.04\n    steps:\n      - uses: zq/zqvx@v1', 'jobs:\n  j:\n    runs-on: ubuntu-24.04\n    steps:\n      - run: echo a'),
                'job key the check has no rule for': ('jobs:\n  j:\n    runs-on: ubuntu-24.04\n    container: zq\n    steps:\n      - run: echo a', 'jobs:\n  j:\n    runs-on: ubuntu-24.04\n    steps:\n      - run: echo a'),
                'step key the check has no rule for': ('jobs:\n  j:\n    runs-on: ubuntu-24.04\n    steps:\n      - run: echo a\n        zqvx: a', 'jobs:\n  j:\n    runs-on: ubuntu-24.04\n    steps:\n      - run: echo a\n        name: a')},
    }
    for extension, kinds in language.items():
        for kind, (refused, kept) in kinds.items():
            cases.add(f'{extension} {kind}: refused', extension, refused, True)
            cases.add(f'{extension} {kind}: passes', extension, kept, False)
    functions = {'a function defined earlier in the file': ('function Zqvx-Item { }\nWrite-Host 1\nZqvx-Item', False, 'Zqvx-Item'),
                 'a function called before its definition once code has run': ('Write-Host 1\nZqvx-Item\nfunction Zqvx-Item { }', True, None),
                 'a function defined before any code runs, called from an earlier function': ('function A { Zqvx-Item }\nfunction Zqvx-Item { }\nA', False, None),
                 'a nested function called after it in the same body': ('function A { function Zqvx-Item { }; Zqvx-Item }\nA', False, None),
                 'a nested function called outside its body': ('function A { function Zqvx-Item { } }\nA\nZqvx-Item', True, None),
                 'a function defined in a branch': ('if ($x) { function Zqvx-Item { } }\nZqvx-Item', True, None),
                 'a function defined in a branch, called in that branch': ('if ($x) { function Zqvx-Item { }\n  Zqvx-Item }', True, 'Zqvx-Item }'),
                 'a function renamed by Set-Alias': ('function Zqvx-Item { }\nSet-Alias Zqvx-Item zqvx\nZqvx-Item', True, 'Zqvx-Item'),
                 'a function renamed through a computed function: path': ('function Zqvx-Item { }\nSet-Item -LiteralPath ("function:" + $n) -Value { }\nZqvx-Item', True, 'Zqvx-Item'),
                 'a cmdlet shadowed by a nested definition still matches its row': ('function A { function Get-Date { } }\nA\nGet-Date', False, None),
                 'a module-qualified cmdlet': ('Microsoft.PowerShell.Utility\\Zqvx-Item', True, None),
                 'a platform alias names a program': ('ls $zq', True, None),
                 'a class that derives from another type': ('class A : System.Object { A() : base() { } }', True, None),
                 'a using assembly statement': ('using assembly System.Data\nWrite-Host 1', True, None),
                 'a run-time function: definition': ('${function:Zqvx} = { }', True, None)}
    for label, (source, refused, line) in functions.items():
        cases.add(f'ps1 {label}: {"refused" if refused else "passes"}', 'ps1', source, refused, line=line and source.split('\n')[-1])
    launchers = {'ps1': ('function Zqvx-Run($p) { & $p }\nZqvx-Run whoami', 'function Zqvx-Show($p) { Write-Host $p }\nZqvx-Show whoami', 'whoami'),
                 'py': ("import subprocess\ndef run(a):\n    subprocess.run(a)\nrun(['whoami'])", 'def show(a):\n    print(a)\nshow([1])', '(['),
                 'sh': ('f() { "$@"; }\nf whoami', 'g() { echo "$1"; }\ng a', ' '),
                 'cs': ('static class Runs {\n  static void R(string p) { System.Diagnostics.Process.Start(p); }\n  static void N() { R("whoami.exe"); }\n}', 'static class Shows {\n  static void R(string p) { System.Console.WriteLine(p); }\n  static void N() { R("whoami.exe"); }\n}', 'static void N()')}
    for extension, (refused, kept, line) in launchers.items():
        cases.add(f'{extension} a call to a repo function that starts a program from its parameter: refused', extension, refused, True, line=refused.split('\n')[-1 if extension != 'cs' else 2])
        cases.add(f'{extension} a call to a repo function that only uses its parameter: passes', extension, kept, False, line=kept.split('\n')[-1 if extension != 'cs' else 2])
    forwards = {'ps1': ('function Zqvx-Run($p) { & $p }', 'function Zqvx-Pass($q) { Zqvx-Run $q }', 'Zqvx-Pass whoami'), 'py': ('def run(a):\n    subprocess.run(a)', 'def passes(b):\n    run(b)', "passes(['whoami'])"),
                'sh': ('f() { "$@"; }', 'g() { f "$@"; }', 'g whoami')}
    for extension, (launcher, passer, call) in forwards.items():
        head = 'import subprocess\n' if extension == 'py' else ''
        for order, (first, second) in (('', (launcher, passer)), (', defined after it', (passer, launcher))):
            cases.add(f'{extension} a call to a repo function that passes its parameters on to a launcher{order}: refused', extension, f'{head}{first}\n{second}\n{call}', True, line=call)
    cases.add('a program in a relative folder is refused', 'ps1', "& '.\\T\\whoami.exe' /user", True, known='whoami')
    cases.add('a known entry cannot clear a line that also has a refused call', 'ps1', "& 'whoami' /user; Copy-Item -Recurse $a $b", True, known='whoami')
    unreadable = cases.add('a reasoned exception cannot clear a file a reader cannot read', 'py', 'def (', True)
    cases.reasoned.append({'file': unreadable, 'line': '', 'reason': 'control'})
    unreadable = cases.add('a reasoned exception cannot clear a cmd file that is not ASCII', 'cmd', 'echo \u00e9', True)
    cases.reasoned.append({'file': unreadable, 'line': '', 'reason': 'control'})
    cases.add('a reasoned exception cannot clear a run step in a shell the check has no reader for', 'yml', 'jobs:\n  j:\n    runs-on: ubuntu-24.04\n    steps:\n      - run: echo a\n        shell: zsh', True, line='- run: echo a', reasoned='control')
    other = cases.add('an entry for another line of the file clears nothing', 'ps1', 'Copy-Item -Recurse $a $b', True)
    cases.reasoned.append({'file': other, 'line': 'Copy-Item -Recurse $c $d', 'reason': 'control'})
    wrappers = {'a call through a second repo wrapper': ('static void T(string p) { R(p); }\n  static void N() { T("whoami.exe"); }', 'static void N()'),
                'a method group of a repo launcher': ('static void N() { System.Action<string> a = R; a("whoami.exe"); }', 'static void N()'),
                'a call from a lambda that passes its method\'s parameter': ('static void T(string p) { System.Action a = () => R(p); a(); }\n  static void N() { T("whoami.exe"); }', 'static void N()')}
    for number, (label, (body, line)) in enumerate(wrappers.items()):
        for starts in (True, False):
            inner = 'System.Diagnostics.Process.Start(p)' if starts else 'System.Console.WriteLine(p)'
            cases.add(f'cs {label}: {"refused" if starts else "passes"}', 'cs', f'static class Wraps{number}{starts} {{\n  static void R(string p) {{ {inner}; }}\n  {body}\n}}', starts, line=line)
    for starts in (True, False):
        inner = 'System.Diagnostics.Process.Start(p)' if starts else 'System.Console.WriteLine(p)'
        cases.add(f'cs creating a repo type whose constructor starts a program from its parameter: {"refused" if starts else "passes"}', 'cs', f'class Made{starts} {{\n  public Made{starts}(string p) {{ {inner}; }}\n  static void N() {{ new Made{starts}("whoami.exe"); }}\n}}', starts, line='static void N()')
    common = cases.add('ps1 a dot-sourced helper passes', 'ps1', 'function Zqvx-Helper { }', False)
    cases.add('ps1 a function of a script dot-sourced earlier passes', 'ps1', f". (Join-Path $PSScriptRoot '{common.rpartition('/')[2]}')\nZqvx-Helper", False, line='Zqvx-Helper')
    cases.add('ps1 a function of a script dot-sourced later is refused', 'ps1', f"Write-Host 1\nZqvx-Helper\n. (Join-Path $PSScriptRoot '{common.rpartition('/')[2]}')", True, line='Zqvx-Helper')
    cases.add('ps1 a script dot-sourced from a folder the check cannot read is refused', 'ps1', f". (Join-Path $zq '{common}')\nZqvx-Helper", True, line='. (Join-Path')
    cases.add('ps1 its functions still resolve', 'ps1', f". (Join-Path $zq '{common}')\nZqvx-Helper", False, line='Zqvx-Helper')
    always = {'ps1': {'Add-Type': "Add-Type -TypeDefinition 'public class Q {}'", 'Invoke-Expression': "Invoke-Expression 'Write-Host hi'", 'script block from text': "& ([scriptblock]::Create('Write-Host hi'))",
                      'default parameter values': "$PSDefaultParameterValues['Copy-Item:Recurse'] = $true", 'method group invoke': "[System.IO.Directory]::GetFiles.Invoke('a')",
                      'program named by a value': '& $zq a', 'COM object': 'New-Object -ComObject Shell.Application', 'Set-Variable of the default parameter values': "Set-Variable -Name PSDefaultParameterValues -Value $zq"},
              'py': {'getattr': "import os\ngetattr(os, 'getpid')()", 'eval': "eval('1')", 'changed program list': "import subprocess\nc = ['whoami']\nc[0] = 'find'\nsubprocess.run(c)",
                     'shell text': "import subprocess\nsubprocess.run('whoami', shell=True)", 'self that is not a method parameter': 'class A:\n    def zqvx(self): pass\nself = object()\nself.zqvx()'},
              'cs': {'reflection': cs('typeof(System.IO.Directory).GetMethod("GetFiles")!.Invoke(null, null);'), 'compiled expression': cs('System.Linq.Expressions.Expression.Lambda(System.Linq.Expressions.Expression.Empty()).Compile();'),
                     'start settings changed through the argument list indexer': cs('var p = new ProcessStartInfo("whoami.exe"); p.ArgumentList.Add("a"); p.ArgumentList[0] = "b"; Process.Start(p);')},
              'sh': {'trap': "trap 'echo a' EXIT", 'eval': 'eval x', 'command': 'command whoami', 'bash given text': "bash -c 'echo a'"},
              'cmd': {'parenthesized block': '(echo a)', 'percent expansion': 'echo %a%'},
              'targets': {'Exec': '<Project><Target Name="T"><Exec Command="echo hi" /></Target></Project>', 'item from an unknown property': '<Project><ItemGroup><I Include="$(Zqvx)" /></ItemGroup></Project>'},
              'yml': {'expression in a run step': 'jobs:\n  j:\n    runs-on: ubuntu-24.04\n    steps:\n      - run: echo ${{ env.X }}', 'job-level workflow': 'jobs:\n  j:\n    uses: zq/x/.github/workflows/y.yml@v1'}}
    for extension, kinds in always.items():
        for kind, source in kinds.items():
            cases.add(f'{extension} {kind}: refused', extension, source, True)
    walk = cs('System.IO.Directory.GetFiles(dir, "*", System.IO.SearchOption.AllDirectories);')
    for folder in ('tools/validation/OptimizerCore/', 'backend/native/Control/', 'docs/internal/frontend/Control/'):
        cases.add(f'a recursive walk under {folder} is refused', 'cs', walk, True, folder=folder)
        cases.add(f'a one-folder listing under {folder} passes', 'cs', cs('System.IO.Directory.GetFiles(dir, "*", System.IO.SearchOption.TopDirectoryOnly);'), False, folder=folder)
        cases.add(f'a recursive walk written as a number under {folder} is refused', 'cs', cs('System.IO.Directory.GetFiles(dir, "*", (System.IO.SearchOption)1);'), True, folder=folder)
    cases.add('a PowerShell file in product code is read', 'ps1', 'Zqvx-Item $a', True, folder='backend/native/Control/')
    cases.add('a file type with no reader is refused', 'foo', 'zqvx a', True)
    cases.add('an extensionless file is refused', '', '#!/bin/sh\nzqvx a', True)
    cases.add('a file Python cannot read is refused', 'py', 'def (', True)
    cases.add('a file PowerShell cannot read is refused', 'ps1', 'function {', True)
    cases.add('a file with NUL bytes and no byte order mark is refused', 'cmd', b'rem \x00\r\n', True)
    cases.add('a UTF-16 file without a byte order mark is refused', 'ps1', 'whoami'.encode('utf-16-be'), True)
    cases.add('a script outside the read scope passes', 'ps1', 'Zqvx-Item $a', False, folder='')
    cases.add('a reasoned exception clears a refused line', 'ps1', 'Copy-Item -Recurse $a $b', False, reasoned='control')
    cases.add('a known entry cannot clear a refused line', 'ps1', 'Copy-Item -Recurse $a $b', True, known='copy-item')
    cases.add('a known entry that names the wrong row is refused', 'ps1', "& 'whoami' /user", True, known='hostname')
    cases.add('a known entry on an approved line is stale', 'ps1', 'Write-Host a', True, known='whoami')
    cases.add('an entry without a reason is refused', 'ps1', 'Copy-Item -Recurse $a $b', True, reasoned=' ')
    twice = cases.add('a listed line is listed once', 'ps1', 'Copy-Item -Recurse $a $b\nCopy-Item -Recurse $a $b', True)
    cases.reasoned.append({'file': twice, 'line': 'Copy-Item -Recurse $a $b', 'reason': 'control'})
    cases.reasoned.append({'file': 'tools/validation/Control/missing.ps1', 'line': 'Copy-Item -Recurse $a $b', 'reason': 'control'})


def controls():
    rows = runpy.run_path(str(HERE / 'reparse_rows.py'))
    module = runpy.run_path(str(HERE / 'check_reparse_walks.py'), run_name='controls')
    table = rows['TABLE']
    cases = Cases()
    fixed_cases(cases)
    program_cases(cases, table)
    cmdlet_cases(cases, table)
    builtin_cases(cases, table)
    runner_cases(cases, table)
    name_cases(cases, table)
    reader_cases(cases, table)
    results = call_results(rows, table)
    awaited = cases.add('cs await calls the awaiter of what it awaits', 'cs', 'static class Control { static async System.Threading.Tasks.Task N() { await System.Threading.Tasks.Task.Yield(); } }', False)
    seen = []
    run = module['Classifier'].run
    module['Classifier'].run = lambda self, facts: seen.extend(facts) or run(self, facts)
    for projects in (True, False):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            chosen = {label: case for label, case in cases.expect.items() if case[0].endswith('.targets') == projects}
            for relative in {case[0] for case in chosen.values()}:
                (root / relative).parent.mkdir(parents=True, exist_ok=True)
                source = cases.files[relative]
                (root / relative).write_bytes(source if isinstance(source, bytes) else (source + '\n').encode('utf-8'))
            pick = lambda entries: [e for e in entries if e['file'].endswith('.targets') == projects]
            (root / ALLOWLIST).parent.mkdir(parents=True, exist_ok=True)
            (root / ALLOWLIST).write_text(json.dumps({'reasoned exceptions': pick(cases.reasoned), 'known': pick(cases.known)}), encoding='utf-8')
            failures = module['verify'](root)
            for label, (relative, line, refused) in chosen.items():
                text = re.split(r'\r\n|\r|\n', cases.files[relative]) if isinstance(cases.files[relative], str) else []
                number = next((n for n, l in enumerate(text, 1) if line and l.strip() == line.strip()), None) or next((n for n, l in enumerate(text, 1) if line and line in l), None)
                hit = any(f.startswith(f'{relative}:{number}:' if number else f'{relative}:') or f.startswith(ALLOWLIST) and relative in f for f in failures)
                results[label] = hit == refused
            if projects:
                results['a refused project file stops the check before any project is evaluated'] = any('stopped before evaluating any project' in f for f in failures)
            else:
                results['a stale entry is refused'] = any('stale entry' in f and 'missing.ps1' in f for f in failures)
    module['Classifier'].run = run
    results['cs await emits the awaiter call it makes'] = any(f['file'] == awaited and f['name'] == 'System.Runtime.CompilerServices.YieldAwaitable.GetAwaiter' for f in seen)
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
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
        results['local tree neither enters nor yields a link'] = sorted(p.relative_to(walked).as_posix() for p in local_tree(walked)) == ['own.txt']
        results['local tree names links only when asked'] = sorted(p.relative_to(walked).as_posix() for p in local_tree(walked, links=True)) == ['leaf', 'link', 'own.txt']
        for spelling, start in (('', str(link)), (' written with a trailing separator', str(link) + os.sep), (' written with a trailing dot', os.path.join(str(link), '.'))):
            try:
                entered = list(local_tree(start))
            except NotADirectoryError:
                entered = None
            results['local tree refuses a root that is a link' + spelling] = entered is None
    return results
