import argparse
import json
from pathlib import Path
import re
import runpy
import subprocess

local_tree = runpy.run_path(str(Path(__file__).with_name('local_tree.py')))['entries']

ALLOWLIST = 'tools/validation/reparse-walk-allowlist.json'
TABLE = json.loads(Path(__file__).with_name('reparse-walk-names.json').read_text(encoding='utf-8'))
SCANNED = set(TABLE['scanned'])
DATA = set(TABLE['data'])
DATA_FILES = set(TABLE['data files'])
SHELLS = set(TABLE['shell types'])
HELPERS = {
    'backend/native/Optimizer.Core/LocalTree.cs': {'recursive walk, copy, delete, permission and ownership'},
    'tools/validation/OptimizerCore/TestFixtures.cs': {'drive mapping and drive letters', 'links', 'mount points and access paths', 'virtual disk attach'},
    'tools/validation/check_reparse_walks.py': {row['category'] for row in TABLE['rows']},
}
SHELL_LINE = re.compile(r'new-item|(?<![\w-])ni(?![\w-])|itemtype|(?<![\w-])-it(?![\w-])|(?<![\w-])-type(?![\w-])')
COMMAND = re.compile(r'(?:^|[(,&|;={\[]|run:|(?<![\w-])(?:-c|/c|-command|call|start))\s*$')


def extension(relative):
    name = relative.rsplit('/', 1)[-1]
    return name.rsplit('.', 1)[-1].lower() if '.' in name else ''


def decode(data):
    if data.startswith(b'\xef\xbb\xbf'):
        return data[3:].decode('utf-8')
    if data.startswith((b'\xff\xfe', b'\xfe\xff')):
        return data.decode('utf-16')
    if b'\x00' in data:
        for codec in ('utf-16-le', 'utf-16-be'):
            text = data.decode(codec, errors='replace')
            if '\x00' not in text and '�' not in text:
                return text
        raise ValueError('it decodes as neither UTF-8 nor UTF-16')
    return data.decode('utf-8')


def rewrite(text, origin, pattern, replace):
    out, lines, last = [], [], 0
    for match in pattern.finditer(text):
        out.append(text[last:match.start()])
        lines.extend(origin[last:match.start()])
        new = replace(match)
        out.append(new)
        lines.extend([origin[match.start()]] * len(new))
        last = match.end()
    out.append(text[last:])
    lines.extend(origin[last:])
    return ''.join(out), lines


def clean(text):
    text = text.lower()
    imported = {}
    for module, names in re.findall(r'^[ \t]*from[ \t]+([\w.]+)[ \t]+import[ \t]+\(?([\w \t,]+)\)?[ \t]*$', text, re.M):
        for part in names.split(','):
            words = part.split()
            if words:
                imported[words[-1]] = module + '.' + words[0]
    for module, alias in re.findall(r'^[ \t]*import[ \t]+([\w.]+)[ \t]+as[ \t]+(\w+)', text, re.M):
        imported[alias + '.'] = module + '.'
    out, origin, line, index = [], [], 1, 0
    while index < len(text):
        char = text[index]
        rest = text[index + 1:index + 3]
        if char in '`^\\' and (rest.startswith('\n') or rest == '\r\n'):
            out.append(' ')
            origin.append(line)
            line += 1
            index += 2 if rest.startswith('\n') else 3
            continue
        if char not in '`^"\'':
            out.append('-' if char in '–—―' else char)
            origin.append(line)
        line += char == '\n'
        index += 1
    cleaned = ''.join(out)
    cleaned, origin = rewrite(cleaned, origin, re.compile(r'(?<=\w)\.(?:exe|com|cmd|bat)(?!\w)'), lambda match: '')
    cleaned, origin = rewrite(cleaned, origin, re.compile(r'[ \t]+(?=[(.])|(?<=\.)[ \t]+'), lambda match: '')
    if imported:
        names = '|'.join(re.escape(name) for name in sorted(imported, key=len, reverse=True))
        pattern = re.compile(r'(?<![\w.])(?:' + names + r')(?=\(|(?<=\.))')
        cleaned, origin = rewrite(cleaned, origin, pattern, lambda match: imported[match.group(0)])
    return cleaned, origin


def statement(text, start, nested=True):
    depth = 0
    index = start
    while index < len(text):
        char = text[index]
        if char in '([{':
            depth += 1
        elif char in ')]}':
            if depth == 0 and nested:
                break
            depth = max(depth - 1, 0)
        elif char in ';|' and depth == 0:
            break
        elif char == '\n' and depth == 0:
            break
        index += 1
    return text[start:index]


def compile_rows(rows):
    rules = []
    for row in rows:
        if 'pattern' in row:
            rules.append((row, [re.compile(row['pattern'])]))
            continue
        word = row.get('word', False) or 'switch' in row or 'parameter' in row or 'where' in row
        patterns = []
        for name in [row['name'], *row.get('aliases', [])]:
            body = r'[\s,]*'.join(re.escape(clean(part)[0]) for part in name.split())
            patterns.append(re.compile((r'(?<![\w.$-])' + body + r'(?![\w-])') if word else body))
        rules.append((row, patterns))
    return rules


RULES = compile_rows(TABLE['rows'])


def named(row, patterns, text, shell):
    for pattern in patterns:
        for match in pattern.finditer(text):
            begin = text.rfind('\n', 0, match.start()) + 1
            line = text[begin:text.find('\n', match.start()) % (len(text) + 1)]
            if row.get('where') == 'powershell' and not (shell or SHELL_LINE.search(line)):
                continue
            if row.get('where') == 'command' and not (COMMAND.search(text[begin:match.start()]) and text[match.end():match.end() + 1] in (' ', '\t', ',')):
                continue
            tail = statement(text, match.end(), nested=False)
            if 'switch' in row and row['switch'] not in re.findall(r'[/-]([a-z]+)', tail) and not re.search(r'@\w', tail):
                continue
            if 'parameter' in row:
                parameter = row['parameter'].lower()
                prefixes = '|'.join(re.escape(parameter[:size]) for size in range(1, len(parameter) + 1))
                if not re.search(r'(?<![\w-])-(?:' + prefixes + r')(?![\w-])|@\w', statement(text, match.end())):
                    continue
            yield match.start()


def findings(relative, raw, rules=None):
    exempt = HELPERS.get(relative, set())
    shell = extension(relative) in SHELLS
    text, origin = clean(raw)
    found = {}
    for row, patterns in rules or RULES:
        if row['category'] in exempt:
            continue
        for start in named(row, patterns, text, shell):
            found.setdefault(origin[start], row['category'] + ' name ' + row['name'])
    lines = raw.splitlines()
    return [(number, lines[number - 1].strip(), message) for number, message in sorted(found.items())]


def check(root, rows=None):
    root = Path(root)
    rules = compile_rows(rows) if rows is not None else RULES
    failures = []
    if (root / '.git').exists():
        paths = subprocess.check_output(['git', 'ls-files', '-z'], cwd=root).decode().split('\0')
        staged = subprocess.check_output(['git', 'ls-files', '-s', '-z'], cwd=root).decode().split('\0')
        failures += [f'{row.split(chr(9))[1]}: a tracked link lets a copy of the repo reach outside it' for row in staged if row.startswith('120000 ')]
    else:
        paths = [p.relative_to(root).as_posix() for p in local_tree(root) if p.is_file() and not {'bin', 'obj', '.git'}.intersection(p.parts)]
    allowed = []
    manifest = root / ALLOWLIST
    if manifest.exists():
        for entry in json.loads(manifest.read_text(encoding='utf-8-sig')):
            if not str(entry.get('reason', '')).strip():
                failures.append(f'{ALLOWLIST}: {entry.get("file")} {entry.get("line")!r} needs the reason its root or target stays inside a fixture')
            allowed.append(entry)
    used = set()
    for relative in sorted(path for path in paths if path):
        if {'bin', 'obj'}.intersection(relative.split('/')) or not (root / relative).is_file():
            continue
        if relative in DATA_FILES or extension(relative) in DATA:
            continue
        if extension(relative) not in SCANNED:
            failures.append(f'{relative}: its file type is neither scanned nor listed as data in reparse-walk-names.json')
            continue
        try:
            raw = decode((root / relative).read_bytes())
        except (ValueError, UnicodeDecodeError) as error:
            failures.append(f'{relative}: it cannot be scanned because {error}')
            continue
        for number, line, message in findings(relative, raw, rules):
            match = next((i for i, e in enumerate(allowed) if i not in used and e.get('file') == relative and e.get('line') == line), None)
            if match is None:
                failures.append(f'{relative}:{number}: this names a {message}: {line[:160]}; use LocalTree.Entries, local_tree, '
                                f'TestFixtures.Junction or TestFixtures.Symlink, or list why it stays inside a fixture in {ALLOWLIST}')
            else:
                used.add(match)
    for i, entry in enumerate(allowed):
        if i not in used:
            failures.append(f'{ALLOWLIST}: stale entry {entry.get("file")} {entry.get("line")!r}')
    return failures


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument('--rules', action='store_true', help='print the cleaning rules every scanned file goes through')
    arguments = parser.parse_args()
    if arguments.rules:
        for rule in TABLE['cleaning']:
            print('- ' + rule['rule'])
        raise SystemExit(0)
    problems = check(arguments.root)
    for problem in problems:
        print(problem)
    if not problems:
        print('Reparse walk check passed')
    raise SystemExit(bool(problems))
