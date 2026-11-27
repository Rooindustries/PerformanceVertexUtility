import argparse
import ast
import builtins
import fnmatch
import io
import json
import os
import posixpath
from pathlib import Path
import re
import runpy
import subprocess
import tempfile
import tokenize
import xml.parsers.expat

import yaml

HERE = Path(__file__).resolve().parent
local_tree = runpy.run_path(str(HERE / 'local_tree.py'))['entries']
ALLOWLIST = 'tools/validation/reparse-walk-allowlist.json'
CLASSES = json.loads((HERE / 'reparse-walk-calls.json').read_text(encoding='utf-8'))
SCOPE = ('tools/validation/', 'tools/scripts/', 'backend/scripts/', '.github/')
PRODUCT = ('backend/native/', 'docs/internal/frontend/')
HOLE, PATH, SELF, BLOCK, ROOT = '\0', '\1', '\2', '\3', '\4'
MARKERS = (HOLE, PATH, SELF, BLOCK, ROOT)
PROJECTS = ('.csproj', '.props', '.targets')
UNREADABLE_FILE = ('Python cannot read this file', 'PowerShell cannot read this:', 'bash cannot read this', 'MSBuild cannot read this project', 'MSBuild cannot give the compiler arguments',
                   'YAML cannot read this workflow', 'the check has no reader for the', 'cmd reads this file in the console code page', 'the compiler cannot read this',
                   'no reader reads this file type')


def fact(file, line, text, kind, name, args=None, **extra):
    return {'file': file, 'line': line, 'text': text, 'kind': kind, 'name': name, 'args': args, **extra}


def tagged(facts, language):
    return [dict(f, language=f.get('language', language)) for f in facts]


def lines_of(text):
    return re.split(r'\r\n|\r|\n', text)


def concat(left, right):
    if len(left) * len(right) > 16:
        return [[HOLE]]
    out = []
    for a in left:
        for b in right:
            merged = list(a)
            for piece in b:
                if merged and piece and merged[-1] and piece not in MARKERS and merged[-1] not in MARKERS:
                    merged[-1] += piece
                elif piece:
                    merged.append(piece)
            out.append(merged)
    return out


def union(*values):
    out = [v for value in values for v in value]
    return out if len(out) <= 16 else [[HOLE]]


def as_path(values):
    return [[PATH if piece == HOLE else piece for piece in value] for value in values]


def pieces_of(text):
    return [p for p in re.split('([\0-\4])', text) if p]


def anchored(file, pieces, files):
    if len(pieces) < 2 or pieces[0] != ROOT or any(p in MARKERS for p in pieces[1:]):
        return None
    path = posixpath.normpath(posixpath.join(posixpath.dirname(file), ''.join(pieces[1:]).replace('\\', '/').lstrip('/')))
    return path if path in files else None


def program_of(pieces):
    if pieces == [SELF]:
        return '<self>'
    if not pieces or pieces[-1] in MARKERS:
        return None
    last = pieces[-1]
    cut = max(last.rfind('\\'), last.rfind('/'))
    if cut < 0 and len(pieces) > 1:
        return None
    return last[cut + 1:] or None


def token_of(pieces):
    if all(p not in MARKERS for p in pieces):
        return ''.join(pieces)
    name = program_of(pieces)
    if pieces and pieces[0] == PATH:
        return {'path': True, 'name': name}
    if pieces and pieces[0] not in (HOLE, SELF, BLOCK):
        return {'prefix': pieces[0], 'name': name}
    return None


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


class PythonReader:
    LAUNCHERS = {'subprocess.run', 'subprocess.call', 'subprocess.check_call', 'subprocess.check_output', 'subprocess.Popen', 'os.system'}
    SCOPES = (ast.FunctionDef, ast.AsyncFunctionDef, ast.Lambda, ast.ListComp, ast.SetComp, ast.DictComp, ast.GeneratorExp)
    repo_modules = set()
    files = set()

    def __init__(self, relative, data):
        self.relative = relative
        self.facts = []
        try:
            encoding, _ = tokenize.detect_encoding(io.BytesIO(data).readline)
            self.lines = lines_of(data.decode(encoding))
            self.tree = ast.parse(data, relative)
        except (SyntaxError, ValueError, UnicodeDecodeError) as error:
            self.facts.append(fact(relative, getattr(error, 'lineno', None) or 1, '', 'unreadable', f'Python cannot read this file: {error}'))
            return
        self.parent = {child: node for node in ast.walk(self.tree) for child in ast.iter_child_nodes(node)}
        self.scopes = {}
        self.read()

    def add(self, node, kind, name, args=None, **extra):
        line = getattr(node, 'lineno', 1)
        self.facts.append(fact(self.relative, line, self.lines[line - 1] if line <= len(self.lines) else '', kind, name, args, **extra))

    def scope_of(self, node):
        node = self.parent.get(node)
        while node is not None and not isinstance(node, self.SCOPES + (ast.Module,)):
            node = self.parent.get(node)
        return node

    def own(self, scope):
        pending = list(ast.iter_child_nodes(scope))
        while pending:
            node = pending.pop()
            yield node
            if not isinstance(node, self.SCOPES):
                pending += list(ast.iter_child_nodes(node))

    def binds(self, scope):
        if scope in self.scopes:
            return self.scopes[scope]
        found = {}
        def bind(name, value):
            found.setdefault(name, []).append(value)
        if isinstance(scope, (ast.ListComp, ast.SetComp, ast.DictComp, ast.GeneratorExp)):
            for generator in scope.generators:
                for name in ast.walk(generator.target):
                    if isinstance(name, ast.Name) and isinstance(name.ctx, ast.Store):
                        for element in generator.iter.elts if isinstance(generator.iter, (ast.List, ast.Tuple)) and name is generator.target else [None]:
                            bind(name.id, ('value', element) if element is not None else ('unknown',))
        elif isinstance(scope, self.SCOPES):
            arguments = scope.args
            for argument in arguments.posonlyargs + arguments.args + arguments.kwonlyargs + [a for a in (arguments.vararg, arguments.kwarg) if a]:
                bind(argument.arg, ('param', scope))
        for node in self.own(scope):
            if isinstance(node, ast.Import):
                for alias in node.names:
                    module = alias.name if alias.asname else alias.name.split('.')[0]
                    bind(alias.asname or alias.name.split('.')[0], ('repo', node) if module.split('.')[0] in self.repo_modules else ('module', module))
            elif isinstance(node, ast.ImportFrom):
                for alias in node.names:
                    if alias.name == '*' or node.level:
                        self.add(node, 'unreadable', 'a star or relative import binds names the check cannot list')
                    else:
                        bind(alias.asname or alias.name, ('repo', node) if node.module.split('.')[0] in self.repo_modules else ('import', f'{node.module}.{alias.name}'))
            elif isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)) and node is not scope:
                bind(node.name, ('repo', node))
            elif isinstance(node, (ast.Assign, ast.AnnAssign, ast.AugAssign, ast.NamedExpr)) and getattr(node, 'value', None) is not None:
                for target in node.targets if isinstance(node, ast.Assign) else [node.target]:
                    for name in ast.walk(target):
                        if isinstance(name, ast.Name) and isinstance(name.ctx, ast.Store):
                            bind(name.id, ('value', node.value) if name is target and not isinstance(node, ast.AugAssign) else ('unknown',))
            elif isinstance(node, (ast.For, ast.AsyncFor)):
                for name in ast.walk(node.target):
                    if isinstance(name, ast.Name) and isinstance(name.ctx, ast.Store):
                        for element in node.iter.elts if isinstance(node.iter, (ast.List, ast.Tuple)) and name is node.target else [None]:
                            bind(name.id, ('value', element) if element is not None else ('unknown',))
            elif isinstance(node, (ast.With, ast.AsyncWith)):
                for item in node.items:
                    for name in ast.walk(item.optional_vars) if item.optional_vars else []:
                        if isinstance(name, ast.Name) and isinstance(name.ctx, ast.Store):
                            bind(name.id, ('unknown',))
            elif isinstance(node, ast.ExceptHandler) and node.name:
                bind(node.name, ('unknown',))
            elif isinstance(node, (ast.Global, ast.Nonlocal)):
                for name in node.names:
                    found[name] = [('outer',)]
        self.scopes[scope] = found
        return found

    def lookup(self, name, node):
        scope = self.scope_of(node)
        while scope is not None:
            bindings = self.binds(scope).get(name)
            if bindings and bindings != [('outer',)]:
                return bindings
            scope = self.scope_of(scope) if not isinstance(scope, ast.Module) else None
        return None

    def qualified(self, node, seen=frozenset()):
        if len(seen) > 40:
            return {None}
        if isinstance(node, ast.Name):
            bindings = self.lookup(node.id, node)
            if bindings is None:
                return {'builtins.' + node.id} if hasattr(builtins, node.id) else {None}
            found = set()
            for binding in bindings:
                if binding[0] in ('import', 'module'):
                    found.add(binding[1])
                elif binding[0] == 'repo':
                    found.add('<repo>')
                elif binding[0] == 'value' and (id(binding[1])) not in seen:
                    found |= self.callable(binding[1], seen | {id(binding[1])})
                else:
                    found.add(None)
            return found
        if isinstance(node, ast.Attribute):
            if isinstance(node.value, ast.Name):
                libraries = self.libraries(node.value, seen)
                if libraries:
                    return {f'{library}!{node.attr}' for library in libraries}
                if node.value.id in ('self', 'cls'):
                    return {'<repo>'} if self.method_defined(node.attr) else {'.' + node.attr}
                bindings = self.lookup(node.value.id, node.value) or []
                if bindings and self.method_defined(node.attr) and all(b[0] == 'value' and isinstance(b[1], ast.Call) and id(b[1]) not in seen
                                                                      and self.qualified(b[1].func, seen | {id(b[1])}) == {'<repo>'} for b in bindings):
                    return {'<repo>'}
            base = self.qualified(node.value, seen) if isinstance(node.value, (ast.Name, ast.Attribute)) else {None}
            if isinstance(node.value, ast.Name) and self.lookup(node.value.id, node.value) is None and not hasattr(builtins, node.value.id):
                return {None}
            if base == {'<repo>'} and isinstance(node.value, ast.Name) and all(b[0] == 'repo' and isinstance(b[1], (ast.Import, ast.ImportFrom)) for b in self.lookup(node.value.id, node.value) or []):
                return {'<repo>'}
            if base and None not in base and '<repo>' not in base and all('!' not in b and not b.startswith('.') for b in base):
                return {b + '.' + node.attr for b in base}
            return {'.' + node.attr}
        return {None}

    def libraries(self, name, seen=frozenset()):
        found = set()
        for binding in self.lookup(name.id, name) or []:
            value = binding[1] if binding[0] == 'value' else None
            if isinstance(value, ast.Call) and id(value) not in seen and value.args and isinstance(value.args[0], ast.Constant) \
                    and self.qualified(value.func, seen | {id(value)}) & {'ctypes.WinDLL', 'ctypes.CDLL', 'ctypes.OleDLL'}:
                found.add(Path(str(value.args[0].value)).stem.lower())
        return found

    def method_defined(self, name):
        return any(isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef)) and n.name == name for c in ast.walk(self.tree) if isinstance(c, ast.ClassDef) for n in c.body)

    def callable(self, value, seen):
        if isinstance(value, ast.Lambda):
            return {'<repo>'}
        if isinstance(value, (ast.Name, ast.Attribute)):
            return self.qualified(value, seen)
        if isinstance(value, ast.IfExp):
            return self.callable(value.body, seen) | self.callable(value.orelse, seen)
        if isinstance(value, ast.BoolOp):
            return set().union(*(self.callable(v, seen) for v in value.values))
        if isinstance(value, ast.Subscript) and self.loaded(value.value, seen):
            return {'<repo>'}
        if isinstance(value, ast.Call) and self.qualified(value.func, seen) == {'functools.partial'} and value.args:
            return self.callable(value.args[0], seen)
        return {None}

    def loaded(self, node, seen=frozenset()):
        values = [b[1] if b[0] == 'value' else None for b in self.lookup(node.id, node) or [('unknown',)]] if isinstance(node, ast.Name) else [node]
        return all(isinstance(v, ast.Call) and id(v) not in seen and self.qualified(v.func, seen | {id(v)}) == {'runpy.run_path'} and self.repo_path(v.args[0] if v.args else None) for v in values)

    def traced(self, node, seen=frozenset()):
        if id(node) in seen:
            return False
        seen = seen | {id(node)}
        if isinstance(node, (ast.IfExp, ast.BoolOp)):
            return all(self.traced(v, seen) for v in ([node.body, node.orelse] if isinstance(node, ast.IfExp) else node.values))
        if isinstance(node, ast.Lambda):
            return True
        if isinstance(node, ast.Subscript):
            return self.loaded(node.value)
        if isinstance(node, ast.Call) and self.qualified(node.func) == {'functools.partial'} and node.args:
            return self.traced(node.args[0], seen)
        if isinstance(node, ast.Call) and self.callable(node, frozenset()) != {None}:
            names = self.callable(node, frozenset())
            for name in names - {None, '<repo>'}:
                self.add(node, 'native' if '!' in name else 'method' if name.startswith('.') else 'call', name, None, reference=True)
            return None not in names
        if not isinstance(node, (ast.Name, ast.Attribute)):
            return False
        names = self.qualified(node)
        for name in names - {None, '<repo>'}:
            self.add(node, 'native' if '!' in name else 'method' if name.startswith('.') else 'call', name, None, reference=True)
        if None not in names:
            return True
        if not isinstance(node, ast.Name) or self.lookup(node.id, node) is None:
            return False
        for binding in self.lookup(node.id, node):
            if binding[0] == 'value':
                if not self.traced(binding[1], seen):
                    return False
            elif binding[0] == 'param':
                function = binding[1]
                if isinstance(function, ast.Lambda):
                    return False
                names = [a.arg for a in function.args.posonlyargs + function.args.args]
                index = names.index(node.id) if node.id in names else None
                calls = [c for c in ast.walk(self.tree) if isinstance(c, ast.Call) and (
                    isinstance(c.func, ast.Name) and any(b == ('repo', function) for b in self.lookup(c.func.id, c.func) or [])
                    or isinstance(c.func, ast.Attribute) and c.func.attr == function.name)]
                if not calls:
                    return False
                for call in calls:
                    if any(isinstance(a, ast.Starred) for a in call.args) or any(k.arg is None for k in call.keywords):
                        return False
                    offset = 1 if isinstance(call.func, ast.Attribute) and names[:1] in (['self'], ['cls']) else 0
                    value = next((k.value for k in call.keywords if k.arg == node.id), None)
                    if value is None and index is not None and 0 <= index - offset < len(call.args):
                        value = call.args[index - offset]
                    if value is not None and not self.traced(value, seen):
                        return False
            elif binding[0] != 'repo':
                return False
        return True

    def repo_path(self, node):
        return all(anchored(self.relative, v, self.files) for v in self.resolve(node))

    def resolve(self, node, depth=0, seen=frozenset()):
        if node is None or depth > 12:
            return [[HOLE]]
        if isinstance(node, ast.Constant):
            value = node.value.decode('utf-8', 'replace') if isinstance(node.value, bytes) else node.value
            return [[value]] if isinstance(value, str) else [[HOLE]]
        if isinstance(node, ast.JoinedStr):
            out = [[]]
            for part in node.values:
                if isinstance(part, ast.FormattedValue):
                    out = concat(out, self.resolve(part.value, depth + 1, seen) if part.format_spec is None and part.conversion == -1 else [[HOLE]])
                else:
                    out = concat(out, self.resolve(part, depth + 1, seen))
            return out
        if isinstance(node, ast.BinOp) and isinstance(node.op, ast.Add):
            return concat(self.resolve(node.left, depth + 1, seen), self.resolve(node.right, depth + 1, seen))
        if isinstance(node, ast.BinOp) and isinstance(node.op, ast.Div):
            return concat(concat(as_path(self.resolve(node.left, depth + 1, seen)), [['\\']]), self.resolve(node.right, depth + 1, seen))
        if isinstance(node, ast.IfExp):
            return union(self.resolve(node.body, depth + 1, seen), self.resolve(node.orelse, depth + 1, seen))
        if isinstance(node, ast.BoolOp) and isinstance(node.op, ast.Or):
            return union(*(self.resolve(v, depth + 1, seen) for v in node.values))
        if isinstance(node, ast.Name):
            if node.id == '__file__':
                return [[ROOT, '\\' + Path(self.relative).name]]
            bindings = self.lookup(node.id, node) or []
            if bindings and id(node) not in seen and all(b[0] == 'value' for b in bindings):
                return union(*(self.resolve(b[1], depth + 1, seen | {id(node)}) for b in bindings))
            return [[HOLE]]
        if isinstance(node, ast.Attribute):
            if self.qualified(node) == {'sys.executable'}:
                return [['python']]
            if node.attr == 'parent':
                return self.up(self.resolve(node.value, depth + 1, seen), 1)
        if isinstance(node, ast.Subscript) and isinstance(node.value, ast.Attribute) and node.value.attr == 'parents':
            level = node.slice.value if isinstance(node.slice, ast.Constant) and isinstance(node.slice.value, int) else None
            return self.up(self.resolve(node.value.value, depth + 1, seen), level + 1) if level is not None else [[PATH]]
        if isinstance(node, ast.Call):
            function = self.qualified(node.func)
            if function & {'builtins.str', 'os.fspath', 'pathlib.Path', 'os.path.abspath', 'os.path.realpath', 'os.path.normpath'} and len(node.args) == 1:
                return self.resolve(node.args[0], depth + 1, seen)
            if function == {'pathlib.Path'} and not node.args:
                return [[PATH]]
            if function == {'os.path.join'}:
                out = as_path(self.resolve(node.args[0], depth + 1, seen)) if node.args else [[HOLE]]
                for part in node.args[1:]:
                    out = concat(concat(out, [['\\']]), self.resolve(part, depth + 1, seen))
                return out
            if isinstance(node.func, ast.Attribute) and node.func.attr in ('resolve', 'absolute') and not node.args:
                return as_path(self.resolve(node.func.value, depth + 1, seen))
            if function == {'os.path.dirname'} and len(node.args) == 1:
                return self.up(self.resolve(node.args[0], depth + 1, seen), 1)
            if isinstance(node.func, ast.Attribute) and node.func.attr in ('with_name', 'joinpath') and node.args:
                head = self.up(self.resolve(node.func.value, depth + 1, seen), 1) if node.func.attr == 'with_name' else as_path(self.resolve(node.func.value, depth + 1, seen))
                return concat(concat(head, [['\\']]), self.resolve(node.args[-1], depth + 1, seen))
            if function & {'tempfile.gettempdir', 'tempfile.mkdtemp', 'os.getcwd'}:
                return [[PATH]]
        return [[HOLE]]

    @staticmethod
    def up(values, levels):
        return [v + ['\\..'] * levels if v and v[0] == ROOT else [PATH] for v in values]

    def arguments(self, node):
        args = [{'i': index, 'value': self.constant(value)} for index, value in enumerate(node.args) if not isinstance(value, ast.Starred)]
        args += [{'name': keyword.arg, 'value': self.constant(keyword.value)} for keyword in node.keywords if keyword.arg]
        if any(isinstance(value, ast.Starred) for value in node.args) or any(keyword.arg is None for keyword in node.keywords):
            args.append({'splat': True})
        return [a if a.get('value') != {'unknown': True} else {k: v for k, v in a.items() if k != 'value'} for a in args]

    @staticmethod
    def constant(node):
        return node.value if isinstance(node, ast.Constant) and isinstance(node.value, (str, bool, int, float, type(None))) else {'unknown': True}

    def read(self):
        skipped = set()
        for node in ast.walk(self.tree):
            if isinstance(node, ast.Attribute):
                skipped.add(id(node.value))
            if not isinstance(node, ast.Call):
                continue
            skipped.add(id(node.func))
            names = self.qualified(node.func)
            if None in names and not self.traced(node.func):
                self.add(node, 'unreadable', 'this calls a value the check cannot trace to a function it can classify')
            for name in names - {None, '<repo>'}:
                if name in self.LAUNCHERS:
                    self.launch(node, name)
                else:
                    self.add(node, 'native' if '!' in name else 'method' if name.startswith('.') else 'call', name, self.arguments(node))
        for node in ast.walk(self.tree):
            if isinstance(node, (ast.Name, ast.Attribute)) and id(node) not in skipped and isinstance(node.ctx, ast.Load):
                if isinstance(node, ast.Name) and all(b[0] == 'module' for b in self.lookup(node.id, node) or [('none',)]):
                    continue
                for name in self.qualified(node) - {None, '<repo>'}:
                    if not name.startswith('.') and not (isinstance(node, ast.Name) and name.startswith('builtins.') and not hasattr(builtins, node.id)):
                        self.add(node, 'native' if '!' in name else 'call', name, None, reference=True)

    def launch(self, node, name):
        first = node.args[0] if node.args else next((k.value for k in node.keywords if k.arg in ('args', 'command')), None)
        shell = name == 'os.system' or any(k.arg == 'shell' and not (isinstance(k.value, ast.Constant) and k.value.value is False) for k in node.keywords)
        executable = next((k.value for k in node.keywords if k.arg == 'executable'), None)
        if any(k.arg is None for k in node.keywords) or any(isinstance(a, ast.Starred) for a in node.args):
            self.add(node, 'unreadable', 'arguments passed with * or ** hide the program this starts')
            return
        candidates = [first]
        if isinstance(first, ast.Name):
            bindings = self.lookup(first.id, first) or []
            if bindings and all(b[0] == 'value' for b in bindings) and not self.changed(first):
                candidates = [b[1] for b in bindings]
            elif bindings:
                self.add(node, 'unreadable', 'the program list this starts is changed or built where the check cannot follow it')
                return
        for value in candidates:
            if isinstance(value, (ast.List, ast.Tuple)):
                if any(isinstance(e, ast.Starred) for e in value.elts):
                    self.add(node, 'unreadable', 'a starred program list hides what this starts')
                    continue
                pieces = [t[0] if len(t) == 1 else [HOLE] for t in (self.resolve(e) for e in value.elts)]
                if shell:
                    self.command(node, ['<shell>'], [], None)
                else:
                    self.command(node, self.resolve(executable)[0] if executable else (pieces[0] if pieces else [HOLE]), [token_of(p) for p in pieces[1:]], None)
            else:
                for text in self.resolve(value):
                    if shell:
                        self.command(node, ['<shell>'], [], None)
                    else:
                        split = split_command_line(text)
                        self.command(node, self.resolve(executable)[0] if executable else (split[0] if split else [HOLE]), [token_of(t) for t in split[1:]], None)

    def changed(self, name):
        for node in ast.walk(self.tree):
            target = node.value if isinstance(node, ast.Subscript) and isinstance(node.ctx, (ast.Store, ast.Del)) else \
                node.func.value if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute) and node.func.attr in ('append', 'extend', 'insert', 'remove', 'pop', 'clear', 'reverse', 'sort', '__setitem__') else \
                node.target if isinstance(node, ast.AugAssign) else None
            if isinstance(target, ast.Name) and target.id == name.id:
                return True
        return False

    def command(self, node, program, tokens, raw):
        name = program_of(program)
        if name is None:
            self.add(node, 'unreadable', 'the program this starts is built from values the check cannot read')
        else:
            self.add(node, 'command', name, tokens, raw=raw)


def git(root, *arguments):
    return subprocess.check_output(['git', *arguments], cwd=root).decode('utf-8')


def read_powershell(root, files, texts, definitions=()):
    with tempfile.TemporaryDirectory() as folder:
        request = Path(folder, 'request.json')
        request.write_text(json.dumps({'root': str(root), 'files': files, 'texts': texts, 'definitions': list(definitions),
                                       'passthrough': list(CLASSES['powershell path functions']), 'joiners': list(CLASSES['powershell argument joiners'])}), encoding='utf-8')
        output = subprocess.run(['pwsh', '-NoProfile', '-NonInteractive', '-File', str(HERE / 'read_powershell.ps1'), str(request)], capture_output=True, text=True, encoding='utf-8')
    if output.returncode:
        raise SystemExit('The PowerShell reader failed: ' + output.stdout + output.stderr)
    return json.loads(output.stdout)


def compiler_arguments(root, project, properties):
    output = subprocess.run(['dotnet', 'msbuild', project, '-restore', '-t:Compile', '-nologo', '-p:Configuration=Release', '-p:EnableWindowsTargeting=true',
                             '-p:SkipCompilerExecution=true', '-p:ProvideCommandLineArgs=true', '-p:NonExistentFile=__reader_missing__', '-p:BuildProjectReferences=false', '-getItem:CscCommandLineArgs', *properties],
                            cwd=root, capture_output=True, text=True)
    if output.returncode:
        return None, output.stdout + output.stderr
    return [item['Identity'] for item in json.loads(output.stdout)['Items']['CscCommandLineArgs']], None


def read_csharp(root, paths, sources):
    facts, units, compiled = [], [], set()
    with tempfile.TemporaryDirectory() as folder:
        stand_in = Path(folder, 'binding.cs')
        stand_in.write_text('namespace Roo70Fixture; public static class BuildBinding { public const string SourceCommit = "", AppLogSha256 = "", RedactorSha256 = "", MainWindowSha256 = ""; }',
                            encoding='utf-8')
        declared = {}
        for path in (p for p in paths if p.endswith('.cs')):
            for name in re.findall(r'\b(?:class|struct|record|interface|enum)\s+(\w+)', (root / path).read_text(encoding='utf-8-sig', errors='replace')):
                declared.setdefault(name, set()).add(path)
        template, _ = compiler_arguments(HERE.parents[1], 'tools/validation/OptimizerCore/OptimizerCore.csproj', [])
        for project in sorted(p for p in paths if p.endswith('.csproj')):
            if not project.startswith(SCOPE + PRODUCT):
                continue
            arguments, error = compiler_arguments(root, project, [f'-p:RooIndustriesBindingFile={stand_in}'])
            if arguments is None:
                facts.append(fact(project, 1, '', 'unreadable', 'MSBuild cannot give the compiler arguments for this project: ' + error[-400:]))
                continue
            directory = (root / project).parent
            files = {str((directory / a).resolve()) for a in arguments if not a.startswith('/')}
            report = {path: {'file': Path(path).relative_to(root).as_posix(), 'offset': 0} for path in files
                      if Path(path).is_relative_to(root) and Path(path).relative_to(root).as_posix() in sources and Path(path).relative_to(root).as_posix() not in compiled}
            compiled |= {item['file'] for item in report.values()}
            units.append({'args': arguments, 'dir': str(directory), 'report': report})
        loose = [s for s in sources if s not in compiled]
        for item in [{'file': s, 'line': 1} for s in loose]:
            path = str(root / item['file'])
            text = (root / item['file']).read_text(encoding='utf-8-sig', errors='replace')
            own = set(re.findall(r'\b(?:class|struct|record|interface|enum)\s+(\w+)', text))
            providers = sorted({str(root / f) for name in set(re.findall(r'\b([A-Z]\w+)\s*[.(<]', text)) - own for f in declared.get(name, ()) if f != item['file']})
            options = [a for a in template if a.startswith('/') and not a.startswith(('/target:', '/out:', '/refout:', '/embed', '/doc', '/sourcelink', '/warnaserror', '/nullable', '/analyzer'))]
            usings = [str((HERE / 'OptimizerCore' / a).resolve()) for a in template if a.endswith('GlobalUsings.g.cs')]
            units.append({'args': options + ['/target:library', path, *providers, *usings], 'dir': str(HERE / 'OptimizerCore'), 'report': {path: {'file': item['file'], 'offset': item['line'] - 1}},
                          'framework': [a for a in options if not a.startswith(('/reference', '/define', '/langversion'))] + ['/target:library', '/unsafe+', path, *providers]})
        request = Path(folder, 'request.json')
        request.write_text(json.dumps({'root': str(root), 'units': units}), encoding='utf-8')
        output = subprocess.run(['dotnet', 'run', '--project', str(HERE / 'CallReader'), '-c', 'Release', '--', str(request)], capture_output=True, text=True, encoding='utf-8')
    if output.returncode:
        raise SystemExit('The C# reader failed: ' + output.stdout + output.stderr)
    found = json.loads(output.stdout)
    texts = {}
    for item in found:
        if item['file'] not in texts:
            texts[item['file']] = lines_of((root / item['file']).read_bytes().decode('utf-8-sig', 'replace'))
        lines = texts[item['file']]
        item['text'] = lines[item['line'] - 1] if item['line'] <= len(lines) else ''
    return facts + found


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
        if head and head.group(0) in CLASSES['cmd'] and head.group(0) != name:
            words = [head.group(0), name[len(head.group(0)):]] + words[1:]
            name = head.group(0)
        out.append(fact(relative, line, text, 'command', name, words[1:], shell='cmd', language='cmd'))
    return out


def cmd_script(relative, source, offset=0, lines=None):
    try:
        text = source if isinstance(source, str) else source.decode('ascii')
    except UnicodeDecodeError:
        return [fact(relative, 1, '', 'unreadable', 'cmd reads this file in the console code page, so only ASCII is readable')]
    lines = lines or lines_of(text)
    facts = []
    for number, line in enumerate(lines_of(text), 1 + offset):
        stripped = line.strip().lstrip('@')
        if stripped and not re.match(r'(?i)(rem\b|::|:)', stripped):
            facts += cmd_facts(relative, number, lines[number - 1] if number <= len(lines) else line, stripped)
    return facts


def bash_facts(relative, text, offset=0, lines=None):
    shfmt = os.environ.get('SHFMT', 'shfmt')
    output = subprocess.run([shfmt, '--to-json', '--filename', relative], input=text, capture_output=True, text=True, encoding='utf-8')
    if output.returncode:
        return [fact(relative, 1 + offset, '', 'unreadable', 'bash cannot read this: ' + output.stderr.strip()[:200])]
    tree = json.loads(output.stdout)
    lines = lines or lines_of(text)
    functions, calls = {}, []
    pending = [tree]
    while pending:
        node = pending.pop()
        if isinstance(node, list):
            pending += node
        elif isinstance(node, dict):
            if node.get('Type') == 'FuncDecl':
                functions.setdefault(node['Name'].get('Value', ''), []).append((node['Pos']['Offset'], node['End']['Offset']))
            if node.get('Type') == 'CallExpr' and node.get('Args'):
                calls.append(node)
            pending += [v for k, v in node.items() if k not in ('Pos', 'End')]

    def pieces(word):
        out = [[]]
        for part in word.get('Parts', []):
            kind = part.get('Type')
            value = [[part.get('Value', '')]] if kind in ('Lit', 'SglQuoted') else pieces(part) if kind == 'DblQuoted' else [[HOLE]]
            out = concat(out, value)
        return out[0] if len(out) == 1 else [HOLE]

    facts = []
    for call in calls:
        line = call['Pos']['Line'] + offset
        words = [pieces(word) for word in call['Args']]
        program = program_of(words[0]) if words[0] and all(p not in (HOLE, PATH) for p in words[0]) else None
        source = lines[line - 1] if line <= len(lines) else ''
        if program is None:
            facts.append(fact(relative, line, source, 'unreadable', 'bash runs a command built from values the check cannot read'))
        elif not any(start < call['Pos']['Offset'] or start <= call['Pos']['Offset'] < end for start, end in functions.get(program, [])) and not (
                program in functions and any(start <= call['Pos']['Offset'] < end for spans in functions.values() for start, end in spans)):
            facts.append(fact(relative, line, source, 'command', program, [token_of(w) for w in words[1:]], shell='bash', language='bash'))
    return facts


def msbuild_facts(relative, data, files=()):
    facts, stack, texts = [], [], []
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
        elif name == 'Import' and not ('$' not in project.replace('$(MSBuildThisFileDirectory)', '') and '*' not in project and local in files) or (
                name in ('Project', 'Import', 'Sdk') and 'Sdk' in attributes and not re.fullmatch(r'Microsoft\.NET\.Sdk(\.\w+)*', attributes['Sdk'])):
            facts.append(fact(relative, line, source, 'call', 'msbuild:import', None))
        elif stack and stack[-1] == 'ItemGroup' and any(re.search(r'\*\*|[*?][^\\/;]*[\\/]', attributes.get(key, '')) for key in ('Include', 'Exclude', 'Remove', 'Update')):
            facts.append(fact(relative, line, source, 'call', 'msbuild:item glob', None))
        elif stack and stack[-1] == 'Target' and name not in ('PropertyGroup', 'ItemGroup', 'OnError'):
            if name == 'Exec':
                facts.append(fact(relative, line, source, 'command', 'cmd', [], language='cmd'))
                facts.extend(cmd_facts(relative, line, source, attributes.get('Command', '')))
            else:
                facts.append(fact(relative, line, source, 'call', 'msbuild:' + name, None))
        for value in attributes.values():
            functions(value, line, source)
        stack.append(name)

    def end(name):
        stack.pop()
        content = ''.join(texts.pop())
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


def workflow_facts(relative, data, texts):
    source = data.decode('utf-8')
    lines = lines_of(source)
    try:
        document = yaml.compose(source)
    except yaml.YAMLError as error:
        return [fact(relative, 1, '', 'unreadable', f'YAML cannot read this workflow: {error}')]
    facts = []
    mapping = lambda node: {k.value: v for k, v in node.value} if isinstance(node, yaml.MappingNode) else {}
    jobs = mapping(document).get('jobs')
    if not isinstance(jobs, yaml.MappingNode) or any(not isinstance(job, yaml.MappingNode) for _, job in jobs.value):
        return [fact(relative, 1, '', 'unreadable', 'YAML cannot read this workflow: it has no jobs mapping the check can read')]
    for job in mapping(jobs).values():
        fields = mapping(job)
        if 'steps' in fields and (not isinstance(fields['steps'], yaml.SequenceNode) or any(not isinstance(step, yaml.MappingNode) for step in fields['steps'].value)):
            return [fact(relative, fields['steps'].start_mark.line + 1, '', 'unreadable', 'YAML cannot read this workflow: a job has steps the check cannot read')]
        runner = fields['runs-on'].value if isinstance(fields.get('runs-on'), yaml.ScalarNode) else ''
        default = mapping(mapping(fields.get('defaults')).get('run')).get('shell') or mapping(mapping(mapping(document).get('defaults')).get('run')).get('shell')
        if 'uses' in fields:
            line = fields['uses'].start_mark.line + 1
            facts.append(fact(relative, line, lines[line - 1], 'call', 'action:' + fields['uses'].value.split('@')[0], None, language='workflow'))
        for step in fields.get('steps').value if isinstance(fields.get('steps'), yaml.SequenceNode) else []:
            step = mapping(step)
            if 'uses' in step:
                line = step['uses'].start_mark.line + 1
                facts.append(fact(relative, line, lines[line - 1], 'call', 'action:' + step['uses'].value.split('@')[0], None, language='workflow'))
            if 'run' not in step:
                continue
            node = step['run']
            offset = node.start_mark.line + (1 if node.style in ('|', '>') else 0)
            shell = (step.get('shell') or default).value.split()[0] if (step.get('shell') or default) else ('pwsh' if 'windows' in runner else 'bash')
            text = re.sub(r'\$\{\{.*?\}\}', '$GITHUB_EXPRESSION', node.value)
            if shell == 'cmd':
                facts += tagged(cmd_script(relative, text.replace('$GITHUB_EXPRESSION', 'GITHUB_EXPRESSION'), offset, lines), 'cmd')
            elif shell in ('bash', 'sh'):
                facts += tagged(bash_facts(relative, text, offset, lines), 'bash')
            elif shell in ('pwsh', 'powershell'):
                texts.append({'file': relative, 'line': offset + 1, 'source': text})
            elif shell == 'python':
                facts += [dict(f, line=f['line'] + offset, text=lines[f['line'] + offset - 1]) for f in tagged(PythonReader(relative, text.encode('utf-8')).facts, 'python')]
            else:
                facts.append(fact(relative, offset + 1, lines[offset], 'unreadable', f'the check has no reader for the {shell} shell'))
    return facts


LAUNCHERS = set("""
cmd command powershell powershell_ise pwsh bash sh dash zsh ksh csh tcsh fish wsl wslhost python python3 py pythonw node nodejs deno bun perl ruby php lua
tclsh java javaw dotnet msbuild csc vbc fsi cscript wscript mshta rundll32 regsvr32 regasm installutil msiexec conhost runas sudo doas su pkexec env nice
nohup timeout stdbuf ionice setsid chroot xargs parallel watch time exec eval source . trap call start explorer schtasks at sc wmic psexec winrs ssh rsh
telnet iscc makensis winget choco scoop apt apt-get dpkg rpm yum dnf pip pip3 pipx npm npx yarn pnpm make cmake ninja git gh awk gawk mawk nawk sed gsed
docker podman kubectl for <shell>
""".split())
TREE_TOOLS = set("""
robocopy xcopy copy move del erase rd rmdir mklink junction linkd subst mountvol diskpart fsutil icacls cacls xcacls takeown attrib compact cipher expand
extrac32 makecab tar bsdtar 7z 7za 7zr 7zz unzip zip gzip gunzip bzip2 bunzip2 xz unxz zstd cpio pax rar unrar winrar forfiles where tree dir ls du find
findstr grep egrep fgrep rg ag ack diff rm cp mv ln rsync scp sftp install ditto shred sdelete chmod chown chgrp chattr chflags setfacl getfacl mount umount
losetup mkfs format label chkdsk defrag convert net reg regini vssadmin wbadmin esentutl bitsadmin innoextract lessmsi msidb dism pnputil bcdboot
""".split())
SCRIPTS = ('.cmd', '.bat', '.ps1', '.psm1', '.psd1', '.py', '.pyw', '.sh', '.vbs', '.vbe', '.js', '.jse', '.wsf', '.wsh', '.msi', '.msc', '.lnk', '.url', '.hta',
           '.cpl', '.scr', '.jar')
PS_ALIASES = dict(pair.split('=') for pair in """
ac=add-content cat=get-content cd=set-location chdir=set-location clc=clear-content clear=clear-host cli=clear-item clp=clear-itemproperty cls=clear-host
clv=clear-variable compare=compare-object copy=copy-item cp=copy-item cpi=copy-item cpp=copy-itemproperty curl=invoke-webrequest cvpa=convert-path
del=remove-item diff=compare-object dir=get-childitem echo=write-output epal=export-alias epcsv=export-csv erase=remove-item etsn=enter-pssession
fc=format-custom fl=format-list foreach=foreach-object %=foreach-object ft=format-table fw=format-wide gal=get-alias gc=get-content gci=get-childitem
gcm=get-command gdr=get-psdrive ghy=get-history gi=get-item gjb=get-job gl=get-location gm=get-member gmo=get-module gp=get-itemproperty gps=get-process
group=group-object gsv=get-service gu=get-unique gv=get-variable gwmi=get-wmiobject h=get-history history=get-history icm=invoke-command iex=invoke-expression
ihy=invoke-history ii=invoke-item ipal=import-alias ipcsv=import-csv ipmo=import-module irm=invoke-restmethod iwmi=invoke-wmimethod iwr=invoke-webrequest
kill=stop-process ls=get-childitem man=help md=mkdir measure=measure-object mi=move-item mount=new-psdrive move=move-item mp=move-itemproperty mv=move-item
nal=new-alias ndr=new-psdrive ni=new-item nmo=new-module nv=new-variable ogv=out-gridview oh=out-host popd=pop-location ps=get-process pushd=push-location
pwd=get-location r=invoke-history rd=remove-item rdr=remove-psdrive ren=rename-item ri=remove-item rjb=remove-job rm=remove-item rmdir=remove-item
rmo=remove-module rni=rename-item rnp=rename-itemproperty rp=remove-itemproperty rv=remove-variable rvpa=resolve-path rwmi=remove-wmiobject sajb=start-job
sal=set-alias saps=start-process sasv=start-service sc=set-content select=select-object set=set-variable si=set-item sl=set-location sleep=start-sleep
sls=select-string sort=sort-object sp=set-itemproperty spjb=stop-job spps=stop-process spsv=stop-service start=start-process sv=set-variable swmi=set-wmiinstance
tee=tee-object type=get-content wget=invoke-webrequest where=where-object ?=where-object wjb=wait-job write=write-output
""".split())


DANGER = re.compile(r'(?i)delet|remov|rmtree|unlink|rmdir|erase|purge|clean|cop(y|ies)|move|renam|replac|link|junction|mount|volume|vdisk|vhd|subst|dosdevice|acl\b|acl[A-Z_]|'
                    r'securit|owner|permission|grant|revoke|accesscontrol|enumerat|getfiles|getdirectories|filesystem|walk|glob|scandir|listdir|iterdir|recurs|tree|'
                    r'extract|archive|zip|tar[a-z]*file|compress|start|exec|spawn|popen|system|shell|invoke|load|compile|emit|reflect|assembly|activator|delegate|'
                    r'expression|marshal|native|interop|process|kill|install|restore|reset|sync|mirror|format|reparse|fsctl|deviceiocontrol|createfile|registry|'
                    r'regkey|hive|service|task|schedul|wmi|cim|dynamic|getmethod|getproperty|getfield|getmember|getvalue|setvalue|createinstance|callsite|elevat|'
                    r'impersonat|token|privilege|ctypes|runpy|importlib|__import__|getattr|setattr|eval|pickle|marshal|script|definetype|createtype|encrypt|spec_from_file|'
                    r'transport|^\.?run$|simplehttp')
RISKY_TYPES = re.compile(r'(?i)^(System\.Reflection(?!\.Metadata|\.PortableExecutable)|System\.Type\.|System\.Activator|System\.Delegate|System\.Runtime\.CompilerServices\.RuntimeHelpers|'
                         r'System\.Runtime\.Loader|System\.Management|Microsoft\.Diagnostics\.Runtime|Microsoft\.CodeAnalysis\.(Diagnostics|GeneratorDriver|CSharp\.CSharpGeneratorDriver)|'
                         r'ctypes|importlib|runpy|sys\.path|http\.server)')


def unlisted(name, what):
    parts = re.sub(r'\.\.ctor$', '', name).split('.')
    if RISKY_TYPES.search(name) or DANGER.search(parts[-1] if name.endswith('..ctor') or len(parts) < 2 else parts[-2] + '.' + parts[-1]):
        return (f'{what}, which the table does not list and which may work on trees, links, permissions, processes or loaded code', 'other', None)
    return (f'{what}, which the table does not list', 'launch', name.lower())


def launch(program):
    if not program:
        return ('this starts a program the check cannot name', 'other', None)
    base = re.sub(r'\.(exe|com)$', '', program.lower())
    if base in LAUNCHERS or program.lower().endswith(SCRIPTS):
        return (f'this starts {program}, a shell, interpreter or launcher that runs what it is given', 'risky', base)
    if base in TREE_TOOLS or re.fullmatch(r'unins\d+', base):
        return (f'this starts {program}, a tool for folder trees, links, volumes or permissions', 'risky', base)
    return (f'this starts {program}', 'launch', base)


class Classifier:
    def __init__(self, paths, defined, types=(), includes=None):
        self.files = set(paths)
        self.defined = {file: {name.lower() for name in names} for file, names in defined['functions'].items()}
        self.aliases = {file: {name.lower() for name in names} for file, names in defined['aliases'].items()}
        self.includes = {file: {target for target, _ in found} for file, found in (includes or {}).items()}
        self.includers = {}
        for file, found in (includes or {}).items():
            for target, shared in found:
                if shared:
                    self.includers.setdefault(target, set()).add(file)
        self.scopes = {}
        self.types = {name.lower() for name in types}

    def scope(self, file):
        if file not in self.scopes:
            up, pending = {file}, [file]
            while pending:
                for caller in self.includers.get(pending.pop(), ()):
                    if caller not in up:
                        up.add(caller)
                        pending.append(caller)
            down, pending = set(up), list(up)
            while pending:
                for target in self.includes.get(pending.pop(), ()):
                    if target not in down:
                        down.add(target)
                        pending.append(target)
            self.scopes[file] = down
        return self.scopes[file]

    def aliased(self, file):
        return set().union(*(self.aliases.get(f, set()) for f in self.scope(file)))

    def visible(self, file):
        aliased = self.aliased(file)
        return set() if '*' in aliased else set().union(*(self.defined.get(f, set()) for f in self.scope(file))) - aliased

    def scripts(self, file, pieces):
        if len(pieces) < 2 or pieces[0] != ROOT or any(p in MARKERS for p in pieces[1:]):
            return []
        rest = ''.join(pieces[1:]).replace('\\', '/').lstrip('/')
        folder, _, name = posixpath.normpath(posixpath.join(posixpath.dirname(file), rest)).rpartition('/')
        if not re.search(r'\.(ps1|psm1|psd1)$', name.lower()) or re.search(r'[*?\[]', folder):
            return []
        return [p for p in self.files if p.rpartition('/')[0] == folder and fnmatch.fnmatchcase(p.rpartition('/')[2].lower(), name.lower())]

    @staticmethod
    def lookup(section, name):
        return CLASSES.get(section, {}).get(name)

    @staticmethod
    def holds(condition, args, tokens):
        if 'without' in condition:
            return args is not None and not any('splat' in a or 'param' in a and any(w.lower().startswith(a['param'].lower()) for w in condition['without']) for a in args)
        if 'one folder' in condition:
            found = [a for a in args or [] if a.get('i') == condition['arg']]
            value = found[0].get('value') if found else None
            if not isinstance(value, str) or any(m in value for m in (HOLE, SELF, BLOCK)) or '**' in value:
                return False
            return not any(re.search(r'[*?[]', part) for part in re.split(r'[\\/]', value)[:-1])
        if args is None or any('splat' in a for a in args):
            return False
        if 'blocks' in condition:
            return all('block' in a or 'param' in a and not any(n.startswith(a['param'].lower()) for n in ('membername', 'filepath', 'file', 'argumentlist')) for a in args)
        if 'param' in condition:
            for index, a in enumerate(args):
                if 'param' in a and any(n.lower().startswith(a['param'].lower()) for n in condition['param']):
                    value = a.get('value') if 'value' in a else args[index + 1].get('pieces') if index + 1 < len(args) else None
                    return isinstance(value, str) and value.lower() in condition['in']
            return condition.get('absent', False)
        found = [a for a in args if a.get('i') == condition['arg'] or a.get('name') == condition['arg']]
        if not found:
            return condition.get('absent', False)
        if 'types' in condition:
            return found[0].get('type') in condition['types']
        if 'type' in condition and found[0].get('type') not in (None, condition['type']):
            return True
        return 'value' in found[0] and found[0]['value'] in condition['in']

    def verdict(self, entry, args=None):
        if isinstance(entry, str) or 'safe' in entry and all(self.holds(c, args, None) for c in entry['safe']):
            return None
        return entry['does']

    def called(self, section, name, args):
        entry = self.lookup(section, name)
        if entry is None:
            return [unlisted(name, f'this calls {name}')]
        does = self.verdict(entry, args)
        return [(f'this calls {name}, which {does}', 'other', None)] if does else []

    def classify(self, item):
        kind, name, language = item['kind'], item['name'], item.get('language', '')
        if kind == 'unreadable':
            return [(name, 'file' if name.startswith(UNREADABLE_FILE) else 'other', None)]
        if kind == 'native':
            return [(f'this calls native code {name}', 'other', None)]
        if kind == 'call' and name.startswith('com:'):
            return [(f'this uses the COM class {name[4:]}', 'other', None)]
        if kind == 'call' and name == 'msbuild:item glob':
            return [('this MSBuild item glob walks every folder its wildcard folder matches when the project is evaluated', 'other', None)]
        if kind == 'call' and name == 'msbuild:import':
            return [('this imports MSBuild code the check does not read', 'other', None)]
        if kind == 'call' and language == 'powershell' and re.sub(r'\.(\.ctor|[^.]+)$', '', name).lower() in self.types:
            return []
        if kind in ('call', 'method'):
            section = 'workflow' if name.startswith(('action:', 'msbuild:')) else f'{language} methods' if kind == 'method' else 'python' if language == 'python' else 'dotnet'
            return self.called(section, name.lower() if kind == 'method' else name, item['args'])
        if kind != 'command':
            return [(f'the check does not know the kind {kind}', 'other', None)]
        if language == 'powershell':
            if not name:
                pieces = pieces_of(item['pieces'])
                if item.get('operator') in ('Dot', 'Ampersand') and self.scripts(item['file'], pieces):
                    return []
                if item.get('operator') in ('Dot', 'Ampersand') and len(pieces) == 1 and re.fullmatch(r'[A-Za-z]+-\w+', pieces[0]):
                    return self.classify(dict(item, name=pieces[0]))
                return [launch(program_of(pieces))]
            lowered = name.lower()
            if re.search(r'[\\/]|\.\w+$', lowered):
                return [launch(Path(name.replace('\\', '/')).name)]
            if lowered in self.visible(item['file']):
                return []
            cmdlet = PS_ALIASES.get(lowered, lowered)
            if lowered in self.aliased(item['file']) or '*' in self.aliased(item['file']):
                return [(f'{name} may be renamed by Set-Alias in this scope', 'other', None)]
            if cmdlet in CLASSES['powershell']:
                does = self.verdict(CLASSES['powershell'][cmdlet], item['args'])
                return [(f'{name} {does}', 'other', None)] if does else []
            if any(lowered in names for names in self.defined.values()):
                found = launch(lowered)
                return [found if found[1] == 'risky' else (f'this runs {name}, a function defined in another checked repo file that this file reaches through its caller', 'launch', lowered)]
            if re.fullmatch(r'[a-z]+-[a-z0-9]+', cmdlet):
                return [(f'this runs {name}, a command the table does not list and the check cannot find defined in the repo', 'other', None)]
            return [launch(name)]
        if language in ('bash', 'cmd') and name in CLASSES[language]:
            does = self.verdict(CLASSES[language][name], None)
            return [(f'{language} {name} {does}', 'other', None)] if does else []
        return [launch(name)]

    def run(self, facts):
        findings = {}
        for item in facts:
            if item['file'].startswith(PRODUCT) and item.get('language') != 'msbuild':
                entry = self.lookup('dotnet', item['name']) if item['kind'] == 'call' else None
                found = [(f'this calls {item["name"]}, which {entry["does"]}', 'other', None)] if isinstance(entry, dict) and entry.get('walk') and self.verdict(entry, item['args']) else []
            else:
                found = self.classify(item)
            if found:
                findings.setdefault((item['file'], item['line']), (item['text'], []))[1].extend(found)
        return findings


def check(root):
    root = Path(root).resolve()
    failures = []
    if (root / '.git').exists():
        staged = git(root, 'ls-files', '-s', '-z').split('\0')
        failures += [f'{row.split(chr(9))[1]}: a tracked link lets a copy of the repo reach outside it' for row in staged if row.startswith('120000 ')]
        paths = sorted(row.split('\t', 1)[1] for row in staged if row and not row.startswith('120000 '))
    else:
        entries = [p for p in local_tree(root, links=True) if p.is_symlink() or p.is_file()]
        failures += [f'{p.relative_to(root).as_posix()}: a link lets a copy of the repo reach outside it' for p in entries if p.is_symlink()]
        paths = sorted(p.relative_to(root).as_posix() for p in entries if not p.is_symlink())
    PythonReader.repo_modules = {Path(p).stem for p in paths if p.endswith('.py') and p.startswith(SCOPE)}
    PythonReader.files = set(paths)
    projects = [f for p in paths if p.lower().endswith(PROJECTS) for f in tagged(msbuild_facts(p, (root / p).read_bytes(), set(paths)), 'msbuild')]
    classifier = Classifier(paths, {'functions': {}, 'aliases': {}})
    findings = classifier.run(projects)
    allowed = listed(root)
    if any((file, text.strip()) not in allowed for (file, _), (text, _) in findings.items()):
        failures.append('the check stopped before evaluating any project, because a project file runs something no list clears')
        return failures, findings, False
    facts, powershell, csharp, texts = [], [], [], []
    for relative in paths:
        if relative.lower().endswith(PROJECTS):
            continue
        if relative.startswith('.github/workflows/') and relative.endswith(('.yml', '.yaml')):
            facts += workflow_facts(relative, (root / relative).read_bytes(), texts)
            continue
        if not relative.startswith(SCOPE + PRODUCT):
            continue
        extension = relative.rsplit('.', 1)[-1].lower() if '.' in relative.rsplit('/', 1)[-1] else ''
        data = (root / relative).read_bytes()
        if relative.startswith(PRODUCT):
            if extension == 'cs':
                csharp.append(relative)
            continue
        if extension == 'py':
            facts += tagged(PythonReader(relative, data).facts, 'python')
        elif extension in ('ps1', 'psm1', 'psd1'):
            powershell.append(relative)
        elif extension == 'cs':
            csharp.append(relative)
        elif extension == 'sh':
            facts += tagged(bash_facts(relative, data.decode('utf-8')), 'bash')
        elif extension in ('cmd', 'bat'):
            facts += tagged(cmd_script(relative, data), 'cmd')
        elif extension not in CLASSES['data']:
            failures.append(f'{relative}: no reader reads this file type, so the check cannot see what it runs')
    read = read_powershell(root, powershell, texts, [p for p in paths if p.lower().endswith(('.ps1', '.psm1')) and p not in powershell])
    facts += tagged(read['facts'], 'powershell')
    facts += tagged(read_csharp(root, paths, set(csharp)), 'csharp')
    workflow_lines = {}
    for item in facts:
        if item['file'].startswith('.github/workflows/'):
            lines = workflow_lines.setdefault(item['file'], lines_of((root / item['file']).read_text(encoding='utf-8')))
            item['text'] = lines[item['line'] - 1] if item['line'] <= len(lines) else ''
    classifier = Classifier(paths, read)
    includes = {}
    for item in facts:
        if item['kind'] != 'command' or item.get('language') != 'powershell' or item['name']:
            continue
        if item.get('operator') in ('Dot', 'Ampersand'):
            for target in classifier.scripts(item['file'], pieces_of(item['pieces'])):
                includes.setdefault(item['file'], set()).add((target, True))
    for item in facts:
        if item['kind'] == 'command' and item.get('language') == 'powershell' and (item['name'] or '').lower() in ('import-module', 'ipmo'):
            for element in item['args'] or []:
                for target in classifier.scripts(item['file'], pieces_of(element['pieces'])) if 'pieces' in element else []:
                    includes.setdefault(item['file'], set()).add((target, False))
    classifier = Classifier(paths, read, {f['name'] for f in facts if f['kind'] == 'type'}, includes)
    findings.update(classifier.run([f for f in facts if f['kind'] != 'type']))
    return failures, findings, True


def lists(root):
    data = json.loads((root / ALLOWLIST).read_text(encoding='utf-8-sig')) if (root / ALLOWLIST).exists() else {}
    return data.get('reasoned exceptions', []), data.get('known launches', [])


def listed(root):
    reasoned, launches = lists(root)
    return {(e.get('file'), e.get('line')) for e in reasoned + launches}


def report(root, failures, findings, complete=True, cleared=None):
    reasoned, launches = lists(root)
    failures += [f'{ALLOWLIST}: {e.get("file")} {e.get("line")!r} needs the reason it is safe, written for that line' for e in reasoned if not str(e.get('reason', '')).strip()]
    used = {'reasoned': set(), 'launches': set()}
    for (file, number), (text, found) in sorted(findings.items()):
        messages = list(dict.fromkeys(m for m, _, _ in found))
        where = f'{file}:{number}: {"; ".join(messages)}: {text.strip()[:160]}'
        if any(kind == 'file' for _, kind, _ in found):
            failures.append(f'{where}; no list can clear a file the check cannot read')
            continue
        hits = {}
        for name, entries in (('reasoned', reasoned), ('launches', launches)):
            hits[name] = next((i for i, e in enumerate(entries) if i not in used[name] and e.get('file') == file and e.get('line') == text.strip()), None)
            if hits[name] is not None:
                used[name].add(hits[name])
        plain = all(kind == 'launch' for _, kind, _ in found)
        programs = ', '.join(sorted({program for _, _, program in found if program}))
        if hits['reasoned'] is not None:
            cleared is not None and cleared.append(f'{file}:{number}: cleared by a reasoned exception')
        elif hits['launches'] is not None and plain and launches[hits['launches']].get('program') == programs:
            cleared is not None and cleared.append(f'{file}:{number}: cleared by known launches ({programs})')
        elif hits['launches'] is not None and plain:
            failures.append(f'{where}; its known-launch entry names {launches[hits["launches"]].get("program")!r}, but the line starts {programs}')
        elif hits['launches'] is not None:
            failures.append(f'{where}; a known launch cannot clear this, so it needs a reasoned exception in {ALLOWLIST} or a fix')
        elif plain:
            failures.append(f'{where}; list it in known launches in {ALLOWLIST} with the program {programs!r} if it was in the repo before this check')
        else:
            failures.append(f'{where}; move it onto LocalTree.Entries, local_tree or a TestFixtures helper, or give it a reasoned exception in {ALLOWLIST}')
    if complete:
        failures += [f'{ALLOWLIST}: stale entry in {name}: {e.get("file")} {e.get("line")!r}' for name, entries in (('reasoned', reasoned), ('launches', launches))
                     for i, e in enumerate(entries) if i not in used[name]]
    return failures


def verify(root, cleared=None):
    failures, findings, complete = check(root)
    return report(Path(root).resolve(), failures, findings, complete, cleared)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--root', type=Path, default=HERE.parents[1])
    arguments = parser.parse_args()
    cleared = []
    problems = verify(arguments.root, cleared)
    for line in cleared + problems:
        print(line)
    if not problems:
        print(f'Reparse walk check passed: {sum("reasoned" in c for c in cleared)} lines cleared by reasoned exceptions, {sum("known launches" in c for c in cleared)} by known launches')
    raise SystemExit(bool(problems))
