"""Validation cleanup may remove only what the fixture created: a delete of a fixed name needs a recorded proof of creation."""
import argparse
import json
from pathlib import Path
import re
import subprocess

ALLOWLIST = 'tools/validation/fixture-cleanup-allowlist.json'
SCOPE = re.compile(r'^tools/validation/.+\.(?:cs|ps1)$|^backend/scripts/(?:Test-[^/]+\.ps1|GovernorScenarios/[^/]+\.(?:cs|ps1))$|^tools/scripts/Test-[^/]+\.ps1$')
PS_DELETES = [
    (re.compile(r'(?<![\w-])Remove-Item(?:Property)?(?![\w-])', re.I), ('LiteralPath', 'Path')),
    (re.compile(r'(?<![\w-])Unregister-ScheduledTask(?![\w-])', re.I), ('TaskName',)),
    (re.compile(r'(?<![\w-])Remove-LocalUser(?![\w-])', re.I), ('Name', 'SID')),
    (re.compile(r'(?<![\w-])Remove-(?:Service|NetFirewallRule)(?![\w-])', re.I), ('Name', 'DisplayName')),
    (re.compile(r'\.DeleteSubKey(?:Tree)?\(\s*|\.DeleteTask\(\s*|\[(?:System\.)?IO\.(?:Directory|File)\]::Delete\(\s*', re.I), None),
    (re.compile(r'schtasks(?:\.exe)?\W[^;\n]*?/Delete\b[^;\n]*?/TN\s+|(?<![\w-])sc(?:\.exe)?\'?\)?\s+delete\s+|(?<![\w-])powercfg(?:\.exe)?\'?\)?\s+[-/](?:delete|d)\s+|(?<![\w-])net(?:\.exe)?\s+user\s+(?=\S+\s+/delete)', re.I), ()),
]
CS_DELETES = re.compile(r'\b(?:Directory|File)\.Delete\(\s*|\.DeleteSubKey(?:Tree)?\(\s*|\.DeleteTask\(\s*|"sc(?:\.exe)?",\s*"delete",\s*|/Delete /TN \\"" \+\s*')
PS_ATOMS = re.compile(r"'(?:[^']|'')*'|\"(?:[^\"`$]|`.|\"\"|\$env:\w+)*\"|\$env:\w+|\[(?:System\.)?Environment\]::GetFolderPath\([^()]*\)|\[(?:System\.)?IO\.Path\]::GetTempPath\(\)", re.I)
CS_ATOMS = re.compile(r'@"(?:[^"]|"")*"|"(?:[^"\\]|\\.)*"|Environment\.GetFolderPath\(Environment\.SpecialFolder\.\w+\)|Path\.GetTempPath\(\)')
SYNTAX = re.compile(r'Join-Path|-ChildPath|-LiteralPath|-Path|(?:\[(?:System\.)?IO\.Path\]::|Path\.)Combine|\bnew\s*(?:string)?\s*\[\s*\]|\.To(?:Upper|Lower)Invariant\(\)', re.I)
PS_NAME = re.compile(r'\$(?:script:|global:|local:)?(\w+)((?:\.\w+)*)(\s*\()?', re.I)
CS_NAME = re.compile(r'(?<![\w.])([A-Za-z_]\w*)((?:\.[A-Za-z_]\w*)*)(\s*[(<])?')


def skip_string(text, i, ps):
    if ps and text.startswith(("@'", '@"'), i) and text[i + 2:i + 3] in '\r\n':
        end = text.find('\n' + text[i + 1] + '@', i)
        return len(text) if end < 0 else end + 3
    verbatim = not ps and text.startswith('@"', i)
    i += 2 if verbatim else 1
    quote = text[i - 1]
    while i < len(text):
        c = text[i]
        if ps and c == '`' or not ps and not verbatim and c == '\\':
            i += 2
            continue
        if c == quote:
            if (ps or verbatim) and text[i + 1:i + 2] == quote:
                i += 2
                continue
            return i + 1
        i += 1
    return i


def scan(text, i, stops, ps):
    depth, j = 0, i
    while j < len(text):
        c = text[j]
        if c in '\'"' or c == '@' and text[j + 1:j + 2] in '\'"':
            j = skip_string(text, j, ps)
            continue
        if c in '([{':
            depth += 1
        elif c in ')]}':
            if depth == 0:
                break
            depth -= 1
        elif depth == 0 and c in stops:
            break
        j += 1
    return text[i:j].strip(), j


def items(expr, ps):
    expr = expr.strip()
    if expr.startswith('@(') and expr.endswith(')'):
        expr = expr[2:-1]
    elif not ps and re.match(r'new\s*(?:string)?\s*\[\s*\]\s*\{', expr) and expr.endswith('}'):
        expr = expr[expr.index('{') + 1:-1]
    found, i = [], 0
    while i <= len(expr):
        item, i = scan(expr, i, ',', ps)
        if item:
            found.append(item)
        i += 1
    return found


class Source:
    def __init__(self, text, ps, constants):
        self.ps, self.constants = ps, constants
        self.assigned, self.loops = {}, {}
        self.aliases = dict(re.findall(r'^\s*using\s+(\w+)\s*=\s*([\w.]+)\s*;', text, re.M)) if not ps else {}
        if ps:
            for match in re.finditer(r'(?<![\w$.])\$(?:script:|global:|local:)?(\w+)\s*=(?![=])', text, re.I):
                self.assigned.setdefault(match.group(1).lower(), []).append(scan(text, match.end(), ';\n|', ps)[0])
            for match in re.finditer(r'(?<![\w$.])\$(?:script:|global:|local:)?(\w+)\s*[-+*/]=', text, re.I):
                self.assigned.setdefault(match.group(1).lower(), []).append('?')
            for match in re.finditer(r'\bforeach\s*\(\s*\$(\w+)\s+in\s+', text, re.I):
                source = scan(text, match.end(), '', ps)[0]
                self.loops.setdefault(match.group(1).lower(), []).append(source)
                self.assigned.setdefault(match.group(1).lower(), []).extend(items(source, ps) or [source])
        else:
            for match in re.finditer(r'\b(?:const\s+string|string|var)\s+(\w+)\s*=(?![=>])', text):
                self.assigned.setdefault(match.group(1), []).append(scan(text, match.end(), ';,', ps)[0])
            for match in re.finditer(r'\bforeach\s*\(\s*(?:var|string)\s+(\w+)\s+in\s+', text):
                source = scan(text, match.end(), '', ps)[0]
                self.assigned.setdefault(match.group(1), []).extend(items(source, ps) or [source])

    def fixed(self, expr, seen=frozenset()):
        expr = expr.strip()
        if not expr:
            return False
        residue = SYNTAX.sub(' ', (PS_ATOMS if self.ps else CS_ATOMS).sub(' ', expr))
        residue = (PS_NAME if self.ps else CS_NAME).sub(lambda m: ' ' if self.named(m, seen) else m.group(0), residue)
        return not re.sub(r'[@+,()\[\]{}\s]', '', residue)

    def named(self, match, seen):
        name, members = match.group(1), match.group(2)
        if match.group(3):
            return False
        key = name.lower() if self.ps else name
        if key in seen:
            return False
        seen = seen | {key}
        if self.ps and members:
            prop = members.split('.')[1]
            values = []
            for source in self.loops.get(key, []):
                for collection in [source] + self.assigned.get(source.lstrip('$').lower(), []):
                    for entry in re.finditer(r'(?<![\w.$])' + re.escape(prop) + r'\s*=\s*', collection, re.I):
                        values.append(scan(collection, entry.end(), ';}\n', True)[0])
            return bool(values) and all(self.fixed(value, seen) for value in values)
        if not self.ps and members:
            values = self.constants.get((self.aliases.get(name, name).split('.')[-1], members[1:]), [])
        else:
            values = self.assigned.get(key, [])
        return bool(values) and all(self.fixed(value, seen) for value in values)


VALUE_PARAMETERS = {'literalpath', 'path', 'name', 'taskname', 'taskpath', 'sid', 'displayname', 'erroraction', 'filter', 'include', 'exclude'}


def ps_target(text, end, names):
    if names is None:
        return [scan(text, end, ',', True)[0]]
    statement, tokens, i = scan(text, end, ';\n|', True)[0], [], 0
    while i < len(statement):
        token, i = scan(statement, i, ' \t', True)
        if token:
            tokens.append(token)
        i += 1
    if not names:
        return tokens[:1]
    wanted, positional, k = {n.lower() for n in names}, None, 0
    while k < len(tokens):
        named = re.fullmatch(r'-(\w+)(?::(.+))?', tokens[k], re.S)
        if named:
            value = named.group(2)
            if value is None and named.group(1).lower() in VALUE_PARAMETERS and k + 1 < len(tokens):
                k += 1
                value = tokens[k]
            if named.group(1).lower() in wanted and value:
                return items(value, True)
        elif positional is None:
            positional = tokens[k]
        k += 1
    return items(positional, True) if positional else []


def findings(relative, text, constants):
    ps = relative.endswith('.ps1')
    source = Source(text, ps, constants)
    found = []

    def add(position, target):
        if not re.match(r'^[\'"]?(?:Env|Variable|Function|Alias):', target, re.I) and source.fixed(target):
            found.append((relative, text.count('\n', 0, position) + 1, ' '.join(target.split())))

    if ps:
        wrappers = {}
        for function in re.finditer(r'\bfunction\s+([\w-]+)\s*(?:\(([^)]*)\))?\s*\{', text, re.I):
            body, _ = scan(text, function.end(), '', True)
            header = function.group(2) or (re.match(r'\s*param\s*\(([^)]*)\)', body, re.I) or [None, ''])[1]
            parameters = [p.lower() for p in re.findall(r'\$(\w+)', header or '')]
            for pattern, names in PS_DELETES:
                for match in pattern.finditer(body):
                    for target in ps_target(body, match.end(), names):
                        variable = re.fullmatch(r'\$(\w+)', target.strip())
                        if variable and variable.group(1).lower() in parameters:
                            wrappers[function.group(1).lower()] = parameters.index(variable.group(1).lower())
        for pattern, names in PS_DELETES:
            for match in pattern.finditer(text):
                for target in ps_target(text, match.end(), names):
                    add(match.start(), target)
        for name, index in wrappers.items():
            for call in re.finditer(r'(?<![\w$-])' + re.escape(name) + r'(?![\w-])(?!\s*[({])', text, re.I):
                if re.search(r'\bfunction\s+$', text[max(0, call.start() - 20):call.start()], re.I):
                    continue
                statement, _ = scan(text, call.end(), ';\n|', True)
                arguments, i = [], 0
                while i < len(statement):
                    token, i = scan(statement, i, ' \t', True)
                    if token:
                        arguments.append(token)
                    i += 1
                if index < len(arguments):
                    add(call.start(), arguments[index])
    else:
        for match in CS_DELETES.finditer(text):
            add(match.start(), scan(text, match.end(), ',', False)[0])
    return found


def check(root):
    failures = []
    if (root / '.git').exists():
        paths = subprocess.check_output(['git', 'ls-files', '-z'], cwd=root).decode().split('\0')
    else:
        paths = [p.relative_to(root).as_posix() for p in root.rglob('*') if p.is_file() and not {'bin', 'obj', '.git'}.intersection(p.parts)]
    sources = {}
    for relative in paths:
        if relative and SCOPE.match(relative) and not {'bin', 'obj'}.intersection(relative.split('/')) and (root / relative).is_file():
            sources[relative] = (root / relative).read_text(encoding='utf-8-sig', errors='replace')
    constants = {}
    for relative, text in sources.items():
        if relative.endswith('.cs'):
            classes = [(m.start(), m.group(1)) for m in re.finditer(r'\bclass\s+(\w+)', text)]
            for match in re.finditer(r'\b(?:const\s+string|static\s+readonly\s+string)\s+(\w+)\s*=', text):
                owner = [name for start, name in classes if start < match.start()]
                if owner:
                    constants.setdefault((owner[-1], match.group(1)), []).append(scan(text, match.end(), ';', False)[0])
    entries = []
    manifest = root / ALLOWLIST
    if manifest.exists():
        for entry in json.loads(manifest.read_text(encoding='utf-8-sig')):
            if not str(entry.get('reason', '')).strip():
                failures.append(f'{ALLOWLIST}: {entry.get("file")} {entry.get("target")!r} needs the proof that the fixture created it')
            entries.append(entry)
    used = set()
    for relative in sorted(sources):
        for path, line, target in findings(relative, sources[relative], constants):
            matches = [i for i, e in enumerate(entries) if e.get('file') == path and ' '.join(str(e.get('target', '')).split()) == target]
            used.update(matches)
            if not matches:
                failures.append(f'{path}:{line}: cleanup removes the fixed name {target}; prove the fixture created it or list the proof in {ALLOWLIST}')
    for i, entry in enumerate(entries):
        if i not in used:
            failures.append(f'{ALLOWLIST}: stale entry {entry.get("file")} {entry.get("target")!r}')
    return failures


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parents[2])
    problems = check(parser.parse_args().root)
    for problem in problems:
        print(problem)
    if not problems:
        print('Fixture cleanup check passed')
    raise SystemExit(bool(problems))
