import fnmatch
import json
import posixpath
from pathlib import Path
import re
import xml.parsers.expat

HERE = Path(__file__).resolve().parent
TABLE = json.loads((HERE / 'reparse-walk-calls.json').read_text(encoding='utf-8'))
APPROVED, PROGRAMS = TABLE['approved'], TABLE['programs']
SCOPE = ('tools/validation/', 'tools/scripts/', 'backend/scripts/', '.github/', 'LeanClientOptimizer.ps1')
PRODUCT = ('backend/native/', 'docs/internal/frontend/')
HOLE, PATH, SELF, BLOCK, ROOT = '\0', '\1', '\2', '\3', '\4'
MARKERS = (HOLE, PATH, SELF, BLOCK, ROOT)
UNREADABLE_FILE = ('Python cannot read this file', 'PowerShell cannot read this:', 'bash cannot read this', 'MSBuild cannot read this project', 'MSBuild cannot give the compiler arguments',
                   'YAML cannot read this workflow', 'the compiler cannot read this', 'cmd reads this file in the console code page', 'the check has no reader for the')


def fact(file, line, text, kind, name, args=None, **extra):
    return {'file': file, 'line': line, 'text': text, 'kind': kind, 'name': name, 'args': args, **extra}


def tagged(facts, language):
    return [dict(f, language=f.get('language', language)) for f in facts]


def lines_of(text):
    return re.split(r'\r\n|\r|\n', text)


def literal(pieces):
    return ''.join(pieces) if isinstance(pieces, list) and pieces and all(p not in MARKERS for p in pieces) else pieces if isinstance(pieces, str) and not any(m in pieces for m in MARKERS) else None


def split_command_line(pieces):
    tokens, current, quoted = [], None, False
    for piece in pieces:
        if piece in MARKERS:
            current = (current or []) + [piece]
            continue
        for letter in piece:
            if letter == '"':
                quoted = not quoted
                current = current or []
            elif letter.isspace() and not quoted:
                if current is not None:
                    tokens.append(current)
                current = None
            else:
                current = current or []
                if current and current[-1] not in MARKERS:
                    current[-1] += letter
                else:
                    current.append(letter)
    if current is not None:
        tokens.append(current)
    return tokens


def cmd_facts(relative, line, text, source):
    out = []
    if re.search(r'[%^!`\r\n]', source):
        return [fact(relative, line, text, 'unreadable', 'cmd expands %, ! or ^ or breaks at a new line in this command line, so the check cannot read it')]
    for part in re.split(r'&&|\|\||[&|]', source):
        words = [''.join(w) for w in split_command_line([re.sub(r'\d?>>?\s*\S+|<\s*\S+', ' ', part)]) if w]
        while words and words[0].lower().lstrip('@') == 'if':
            words = words[1:]
            while words and words[0].lower() in ('/i', 'not'):
                words = words[1:]
            first = words[0].lower() if words else ''
            if first in ('exist', 'defined', 'errorlevel', 'cmdextversion'):
                words = words[2:]
            elif len(words) > 2 and words[1].lower() in ('==', 'equ', 'neq', 'lss', 'leq', 'gtr', 'geq'):
                words = words[3:]
            elif '==' in first:
                words = words[1:]
            else:
                out.append(fact(relative, line, text, 'unreadable', 'cmd runs a command after a condition the check cannot read', language='cmd'))
                words = []
        if not words or words[0].startswith(':'):
            continue
        if words[0].startswith('('):
            out.append(fact(relative, line, text, 'unreadable', 'cmd runs a parenthesized block the check does not read', language='cmd'))
            continue
        name = words[0].lstrip('@').lower()
        head = re.match(r'[^/]+', name)
        if head and head.group(0) in APPROVED['cmd'] and head.group(0) != name:
            words = [head.group(0), name[len(head.group(0)):]] + words[1:]
            name = head.group(0)
        out.append(fact(relative, line, text, 'command', name, words[1:], shell='cmd', language='cmd', path=words[0].lstrip('@')))
    return out


def msbuild_facts(relative, data, files=()):
    facts, stack, texts, properties = [], [], [], {}

    def expanded(value, depth=0):
        if depth > 8:
            return value
        return re.sub(r'\$\((\w+)\)', lambda m: '' if m.group(1) in TABLE['msbuild path properties'] else expanded(properties[m.group(1)], depth + 1) if m.group(1) in properties else m.group(0), value)
    lines = lines_of(data.decode('utf-8-sig', 'replace'))
    parser = xml.parsers.expat.ParserCreate()

    def functions(value, line, source):
        for named in re.finditer(r'\$\(\s*\[([\w.]+)\]::(\w+)|\$\(\s*\[', value):
            if named.group(1):
                facts.append(fact(relative, line, source, 'call', named.group(1) + '.' + named.group(2), None))
            else:
                facts.append(fact(relative, line, source, 'unreadable', 'an MSBuild property function is written in a form the check cannot read'))

    def start(name, attributes):
        line = parser.CurrentLineNumber
        source = lines[line - 1] if line <= len(lines) else ''
        texts.append([])
        project = attributes.get('Project', '')
        local = posixpath.normpath(posixpath.join(posixpath.dirname(relative), re.sub(r'^\$\(MSBuildThisFileDirectory\)', '', project).replace('\\', '/'))) if name == 'Import' else None
        if name == 'UsingTask':
            facts.append(fact(relative, line, source, 'unreadable', 'an MSBuild task defined here runs code the check cannot read'))
        elif name == 'Import' and not ('$' not in project.replace('$(MSBuildThisFileDirectory)', '') and '*' not in project and local in files) or name == 'Sdk' or (
                name in ('Project', 'Import') and 'Sdk' in attributes and not re.fullmatch(r'Microsoft\.NET\.Sdk(\.\w+)*', attributes['Sdk'])):
            facts.append(fact(relative, line, source, 'call', 'msbuild:import', None))
        elif name == 'Project' and 'Sdk' in attributes:
            facts.append(fact(relative, line, source, 'call', 'msbuild:sdk default items', None))
        elif stack and stack[-1] == 'ItemGroup' and any(re.search(r'\$\(|[*?]', expanded(attributes.get(key, ''))) for key in ('Include', 'Exclude', 'Remove', 'Update')):
            facts.append(fact(relative, line, source, 'call', 'msbuild:item pattern', None))
        elif stack and stack[-1] == 'Target' and name not in ('PropertyGroup', 'ItemGroup', 'OnError'):
            if name == 'Exec':
                facts.append(fact(relative, line, source, 'command', 'cmd', [], language='cmd'))
                facts.extend(cmd_facts(relative, line, source, attributes.get('Command', '')))
            else:
                facts.append(fact(relative, line, source, 'call', 'msbuild:' + name, None))
        if name == 'Target' and any(re.search(r'\$\(|[*?]', expanded(attributes.get(key, ''))) for key in ('Inputs', 'Outputs')):
            facts.append(fact(relative, line, source, 'call', 'msbuild:item pattern', None))
        for value in attributes.values():
            functions(value, line, source)
        stack.append(name)

    def end(name):
        stack.pop()
        content = ''.join(texts.pop())
        if stack and stack[-1] == 'PropertyGroup':
            properties[name] = content
        line = parser.CurrentLineNumber
        functions(content, line, lines[line - 1] if line <= len(lines) else '')

    parser.StartElementHandler = start
    parser.EndElementHandler = end
    parser.CharacterDataHandler = lambda content: texts[-1].append(content)
    try:
        parser.Parse(data, True)
    except xml.parsers.expat.ExpatError as error:
        return [fact(relative, error.lineno, '', 'unreadable', f'MSBuild cannot read this project: {error}')]
    return facts


def holds(condition, args):
    if args is None or any('splat' in a for a in args):
        return False
    found = [a for a in args if a.get('i') == condition['arg'] or a.get('name') == condition['arg']]
    if not found:
        return condition.get('absent', False)
    if condition.get('absent') and not condition.get('in') and 'value' not in condition:
        return False
    if 'literal not in' in condition:
        return isinstance(found[0].get('value'), str) and found[0]['value'].lower() not in (v.lower() for v in condition['literal not in'])
    if 'one folder' in condition:
        value = found[0].get('value')
        return isinstance(value, str) and '**' not in value and not any(re.search(r'[*?[]', part) for part in re.split(r'[\\/]', value)[:-1])
    if 'type' in condition and found[0].get('type') not in (None, condition['type']):
        return bool(found[0].get('created'))
    return 'value' in found[0] and found[0]['value'] in condition['in']


def fits(kind, value):
    if kind == 'any':
        return True
    if value is None:
        return False
    if kind == 'literal':
        return True
    if kind == 'plain':
        return not re.search(r'[*?[`]', value)
    if kind == 'name':
        return bool(re.fullmatch(r'[A-Za-z_]\w*', value)) and value.lower() != 'psdefaultparametervalues' and value not in ('PATH', 'PATHEXT', 'BASH_ENV', 'ENV')
    return value.lower() in (v.lower() for v in kind)


def program_tokens(row, tokens):
    case = (lambda t: t) if row.get('case') == 'sensitive' else str.lower
    options = {case(k): v for k, v in row.get('options', {}).items()}
    operands, at = row.get('operands'), 0
    if any(t is None or t.startswith('-') for t in tokens[:row.get('literal', 0)]):
        return False
    while at < len(tokens):
        token = tokens[at]
        if token is not None and token[:1] in row.get('switch', '-') and token not in ('-', '--'):
            key, _, attached = case(token).partition('=')
            if '=' not in token or key not in options:
                key, attached = case(token), None
            if key not in options and len(key) > 2 and options.get(key[:2]) not in (None, 'flag') and not isinstance(options.get(key[:2]), int):
                key, attached = key[:2], token[2:]
            spec = options.get(key)
            if spec is None or attached is not None and (spec == 'flag' or isinstance(spec, int)):
                return False
            if isinstance(spec, int):
                at += spec
            elif spec != 'flag':
                value = attached if attached is not None else tokens[at + 1] if at + 1 < len(tokens) else None
                at += attached is None
                if not fits(spec, value):
                    return False
        elif not (token == '--' and operands) and not (operands and fits(operands, token)):
            return False
        at += 1
    return at == len(tokens)


def program_row(path, tokens):
    if path is None or not re.fullmatch(r'[^\\/]+|([A-Za-z]:)?[\\/].*', path):
        return None
    base = re.sub(r'\.(exe|com)$', '', re.split(r'[\\/]', path.lower())[-1])
    row = PROGRAMS.get(base)
    if row is None or tokens is None:
        return None
    if 'subcommands' in row:
        first = tokens[0] if tokens else None
        sub = row['subcommands'].get(first if row.get('case') == 'sensitive' or first is None else first.lower())
        return f'{base} {first.lower()}' if sub is not None and program_tokens({'case': row.get('case'), **sub}, tokens[1:]) else None
    return base if program_tokens(row, tokens) else None


COMMON = {'erroraction': 'any', 'warningaction': 'any', 'informationaction': 'any', 'errorvariable': 'any', 'warningvariable': 'any', 'informationvariable': 'any',
          'outvariable': 'any', 'outbuffer': 'any', 'pipelinevariable': 'any', 'verbose': 'switch', 'debug': 'switch', 'whatif': 'switch', 'confirm': 'switch'}


def element_values(element):
    if 'many' in element:
        return [v if isinstance(v, str) and not any(m in v for m in MARKERS) else None for v in element['many']]
    values = element.get('values') or [element.get('pieces')]
    return [v if isinstance(v, str) and not any(m in v for m in MARKERS) else None for v in values]


def cmdlet_fits(row, args, piped):
    if isinstance(row, str):
        return True
    if piped and not row.get('pipeline'):
        return False
    params = {**COMMON, **{k.lower(): v for k, v in row.get('params', {}).items()}}
    named, bound, positional, at = set(), set(), 0, 0
    remaining = row.get('remaining', '').lower()
    args = list(args or [])
    while at < len(args):
        element = args[at]
        if 'splat' in element:
            return False
        if 'param' in element:
            name = element['param'].lower()
            kind = params.get(name)
            if kind is None:
                return False
            named.add(name)
            bound.add(name)
            if kind != 'switch':
                if 'value' in element:
                    values = [element['value'] if isinstance(element['value'], str) and not any(m in element['value'] for m in MARKERS) else None]
                elif at + 1 < len(args) and 'param' not in args[at + 1] and 'splat' not in args[at + 1]:
                    at += 1
                    if kind == 'block':
                        if 'block' not in args[at]:
                            return False
                        at += 1
                        continue
                    values = element_values(args[at])
                else:
                    return False
                if kind == 'block' or not all(fits(kind, v) for v in values):
                    return False
            at += 1
            continue
        names = [n.lower() for n in row.get('positional', []) if n.lower() not in named or n.lower() == remaining]
        if positional >= len(names) and not (names and names[-1] == remaining):
            return False
        bound.add(names[min(positional, len(names) - 1)])
        kind = params[names[min(positional, len(names) - 1)]]
        if kind == 'block' and 'block' not in element or kind != 'block' and ('block' in element or not all(fits(kind, v) for v in element_values(element))):
            return False
        positional += 1
        at += 1
    return not row.get('bound') or bool(bound & {n.lower() for n in row['bound']})


def call_fits(entry, args):
    return isinstance(entry, str) or all(holds(c, args) for c in entry.get('args', []))


class Classifier:
    def __init__(self, paths, defined, types=(), includes=None, read=()):
        self.files = set(paths)
        self.read = set(read)
        self.defined = {file: [(n.lower(), plain, at, start, end, top) for n, plain, at, start, end, top in found] for file, found in defined['functions'].items()}
        self.starts = defined.get('starts', {})
        self.changed = {file: {n.lower() for n in names} for file, names in defined['aliases'].items()}
        self.includes = includes or {}
        self.includers = {}
        for file, found in self.includes.items():
            for target, kind, at in found:
                if kind in ('dot', 'call'):
                    self.includers.setdefault(target, []).append((file, at))
        self.types = {name.lower() for name in types}
        self.scopes = {}
        self.launchers = set()

    def down(self, file):
        found, pending = {file}, [file]
        while pending:
            for target, kind, _ in self.includes.get(pending.pop(), ()):
                if kind in ('dot', 'module') and target not in found:
                    found.add(target)
                    pending.append(target)
        return found

    def scope(self, file):
        if file not in self.scopes:
            up, pending = {file}, [file]
            while pending:
                for caller, _ in self.includers.get(pending.pop(), ()):
                    if caller not in up:
                        up.add(caller)
                        pending.append(caller)
            self.scopes[file] = set().union(*(self.down(f) for f in up))
        return self.scopes[file]

    def ready(self, file, offset, where, at, seen=frozenset()):
        if file == where:
            return at < offset or at < self.starts.get(file, 0)
        if file in seen:
            return False
        seen = seen | {file}
        if any(on < offset and where in self.down(target) for target, kind, on in self.includes.get(file, ()) if kind in ('dot', 'module')):
            return True
        return any(self.ready(caller, on, where, at, seen) for caller, on in self.includers.get(file, ()))

    def function(self, file, offset, name):
        scope = self.scope(file)
        found = [(f, plain, at, start, end, top) for f in scope for n, plain, at, start, end, top in self.defined.get(f, ()) if n == name]
        if not found:
            return None
        changed = set().union(*(self.changed.get(f, set()) for f in scope))
        return [] if name in changed or '*' in changed else [f for f, plain, at, start, end, top in found if plain and (self.ready(file, offset, f, at) if top else f == file and start <= offset < end and at < offset)]

    def scripts(self, file, pieces):
        if len(pieces) == 2 and pieces[0] in (HOLE, PATH) and pieces[1] not in MARKERS:
            tail = pieces[1].replace('\\', '/').strip('/')
            found = [p for p in self.files if re.search(r'\.(ps1|psm1)$', tail.lower()) and (p == tail or p.endswith('/' + tail))]
            return found if len(found) == 1 else []
        if len(pieces) < 2 or pieces[0] != ROOT or any(p in MARKERS for p in pieces[1:]):
            return []
        rest = ''.join(pieces[1:]).replace('\\', '/').lstrip('/')
        folder, _, name = posixpath.normpath(posixpath.join(posixpath.dirname(file), rest)).rpartition('/')
        if not re.search(r'\.(ps1|psm1|psd1)$', name.lower()) or re.search(r'[*?\[]', folder):
            return []
        return [p for p in self.files if p.rpartition('/')[0] == folder and fnmatch.fnmatchcase(p.rpartition('/')[2].lower(), name.lower())]

    @staticmethod
    def call(section, name, args, what):
        entry = APPROVED[section].get(name)
        if entry is None:
            return [(f'{what}, which the safe table does not list', 'reason', '')]
        return [] if call_fits(entry, args) else [(f'{what} in a form its row does not allow', 'reason', '')]

    @staticmethod
    def launch(path, name, tokens):
        if not name:
            return [('this starts a program named by a value the check cannot read', 'reason', '')]
        row = program_row(path, tokens)
        if row:
            return [(f'this starts {name}', 'known', row)]
        return [(f'this starts {name}, which no program row allows in this form', 'reason', '')]

    @staticmethod
    def tokens(item):
        out = []
        for a in item['args'] or []:
            if a is None or isinstance(a, str):
                out.append(a)
            elif 'param' in a:
                out.append(None if 'value' in a and literal(a['value']) is None else '-' + a['param'] + (':' + a['value'] if 'value' in a else ''))
            elif 'line' in a:
                text = literal(a['line'])
                if text is None:
                    return None
                out += [literal(t) for t in split_command_line([text])]
            elif 'many' in a:
                out += [literal(v) for v in a['many']]
            elif 'pieces' in a:
                out.append(literal(a['pieces']))
            elif 'splat' in a or 'block' in a:
                return None
            else:
                out.append(None)
        return out

    def classify(self, item):
        kind, name, language = item['kind'], item['name'], item.get('language', '')
        if kind == 'unreadable':
            return [(name, 'file' if name.startswith(UNREADABLE_FILE) else 'reason', '')]
        if kind == 'native':
            return self.call('native', name.lower(), item['args'], f'this calls native code {name}')
        if kind == 'call' and name.startswith('com:'):
            return [(f'this uses the COM class {name[4:]}', 'reason', '')]
        if kind == 'call' and name.startswith(('glob:', 'msbuild:item', 'msbuild:sdk', 'msbuild:import')):
            return [({'glob:wildcard folder': 'this glob has a wildcard folder, so it walks every folder it matches',
                      'msbuild:item pattern': 'this MSBuild item or target names files by a wildcard or a property, which can walk every folder it matches when the project is evaluated',
                      'msbuild:sdk default items': 'the .NET SDK lists this project folder with recursive wildcards when the project is evaluated',
                      'msbuild:import': 'this imports MSBuild code the check does not read'}[name], 'reason', '')]
        if kind == 'call' and language == 'powershell' and re.sub(r'\.(\.ctor|[^.]+)$', '', name).lower() in self.types:
            return []
        if kind == 'call' and name.startswith('repo:'):
            return [(f'this runs a repo function that starts a program from what its caller passes: {name[5:]}', 'reason', '')] if (language, name[5:].lower()) in self.launchers else []
        if kind in ('call', 'method'):
            section = 'workflow' if name.startswith(('action:', 'msbuild:')) else f'{language} methods' if kind == 'method' else 'python' if language == 'python' else 'dotnet'
            return self.call(section, name.lower() if kind == 'method' else name, item['args'], f'this calls {name}')
        if kind != 'command':
            return [(f'the check does not know the kind {kind}', 'file', '')]
        if language == 'powershell':
            return self.powershell(item)
        if language in ('bash', 'cmd') and name in APPROVED[language]:
            row, tokens = APPROVED[language][name], self.tokens(item)
            return [] if isinstance(row, str) or tokens is not None and program_tokens(row, tokens) else [(f'{language} {name} in a form its row does not allow', 'reason', '')]
        return self.launch(item.get('path'), name, self.tokens(item))

    def powershell(self, item):
        name, file = item['name'], item['file']
        if not name:
            pieces = [p for p in re.split('([\0-\4])', item['pieces']) if p]
            targets = self.scripts(file, pieces) if item.get('operator') in ('Dot', 'Ampersand') else []
            if targets and any(t not in self.read for t in targets):
                return [(f'this runs {", ".join(sorted(t for t in targets if t not in self.read))}, a script the check does not read', 'file', '')]
            if targets:
                return [] if pieces[0] == ROOT else [(f'this runs {targets[0]} from a folder the check cannot read', 'reason', '')]
            if item.get('operator') in ('Dot', 'Ampersand') and len(pieces) == 1 and re.fullmatch(r'[A-Za-z]+-\w+', pieces[0]):
                return self.powershell(dict(item, name=pieces[0]))
            path = literal(pieces)
            return self.launch(path, path and re.split(r'[\\/]', path)[-1], self.tokens(item))
        lowered = name.lower()
        if re.search(r'[\\/]|\.\w+$', lowered):
            return self.launch(name, re.split(r'[\\/]', name)[-1], self.tokens(item))
        own = self.function(file, item.get('offset', 0), lowered)
        if own:
            return [(f'this runs a repo function that starts a program from what its caller passes: {name}', 'reason', '')] if any(('powershell', f, lowered) in self.launchers for f in own) else []
        changed = set().union(*(self.changed.get(f, set()) for f in self.scope(file)))
        if lowered in changed or '*' in changed:
            return [(f'{name} may be renamed by Set-Alias or the function: drive in this scope', 'reason', '')]
        cmdlet = TABLE['powershell aliases'].get(lowered, lowered) if lowered not in TABLE['powershell platform aliases'] else lowered
        row = APPROVED['powershell'].get(cmdlet)
        if row is not None:
            return [] if cmdlet_fits(row, item['args'], item.get('piped')) else [(f'{name} in a form its row does not allow', 'reason', '')]
        if own is not None:
            return [(f'this runs {name}, a function defined conditionally, nested, more than once or after this line, which runs a command no row allows where that definition is not in effect', 'reason', '')]
        if any(lowered == n for found in self.defined.values() for n, *_ in found):
            return [(f'this runs {name}, a function of another repo file that this file does not load where the check can see it', 'reason', '')]
        if re.fullmatch(r'[a-z]+-[a-z0-9]+', cmdlet):
            return [(f'this runs {name}, a command the safe table does not list', 'reason', '')]
        return self.launch(name, name, self.tokens(item))

    def run(self, facts):
        self.launchers, before = set(), None
        while before != len(self.launchers):
            before = len(self.launchers)
            for item in facts:
                if not item.get('fromParameter'):
                    continue
                found = [message for message, outcome, _ in self.classify(item) if outcome in ('reason', 'known')]
                named = 'invoke-expression' if item['kind'] == 'unreadable' and item['name'].startswith('Invoke-Expression') else item.get('path') or item.get('name') or ''
                runner = re.sub(r'\.(exe|com)$', '', re.split(r'[\\/]', named.lower())[-1]) in TABLE['runners']
                forwards = any(m.startswith('this runs a repo function that starts') for m in found)
                if forwards or found and runner or any(m.startswith(('this starts', 'the program', 'arguments passed', 'a starred')) for m in found) and item.get('programFromParameter'):
                    self.launchers.add(('powershell', item['file'], item['within'].lower()) if item.get('language') == 'powershell' else (item.get('language'), item['within'].lower()))
        findings = {}
        for item in facts:
            found = self.classify(item)
            if found:
                findings.setdefault((item['file'], item['line']), (item['text'], []))[1].extend(found)
        return findings
