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
HELPERS = {
    'backend/native/Optimizer.Core/LocalTree.cs': {'recursive walk, copy, delete, permission and ownership'},
    'tools/validation/OptimizerCore/TestFixtures.cs': {'drive mapping and drive letters', 'links', 'mount points and access paths', 'virtual disk attach'},
    'tools/validation/check_reparse_walks.py': {row['category'] for row in TABLE['rows']},
}
SHAPES = [
    re.compile(r'\.i?glob\(\s*[rbf]*[\'"][^\'"\n]*\*\*'),
    re.compile(r'\brecursive\s*=\s*True\b', re.IGNORECASE),
]
NUMBERED = re.compile(r'\b(?:Get|Enumerate)(?:Files|Directories|FileSystemEntries|FileSystemInfos)\s*\(', re.IGNORECASE)
POWERSHELL = re.compile(r'itemtype|new-item|(?<![\w-])-it(?![\w-])', re.IGNORECASE)


def extension(relative):
    name = relative.rsplit('/', 1)[-1]
    return name.rsplit('.', 1)[-1].lower() if '.' in name else ''


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
        elif char == '\n' and depth == 0 and not text[:index].rstrip('\r').endswith(('`', '^')):
            break
        index += 1
    return text[start:index]


def spelled(name, word):
    pattern = r'[\s\'",]*'.join(re.escape(part) for part in name.split())
    return re.compile((r'(?<![\w-])' + pattern + r'(?![\w-])') if word else pattern, re.IGNORECASE)


RULES = []
for row in TABLE['rows']:
    names = [row['name'], *row.get('aliases', [])]
    word = row.get('word', False) or 'switch' in row or 'parameter' in row
    RULES.append((row, [spelled(name, word) for name in names]))


def named(row, patterns, text, powershell):
    for pattern in patterns:
        for match in pattern.finditer(text):
            line = text[text.rfind('\n', 0, match.start()) + 1:text.find('\n', match.start()) % (len(text) + 1)]
            tail = statement(text, match.end(), nested=False)
            if row.get('where') == 'powershell' and not (powershell or POWERSHELL.search(line)):
                continue
            if 'switch' in row and row['switch'] not in {flag.lower() for flag in re.findall(r'/([A-Za-z]+)', tail)}:
                continue
            if 'parameter' in row:
                prefixes = '|'.join(re.escape(row['parameter'][:size]) for size in range(1, len(row['parameter']) + 1))
                if not re.search(r'(?<![\w-])-(?:' + prefixes + r')(?![\w-])|\s@[A-Za-z_]\w*', statement(text, match.end()), re.IGNORECASE):
                    continue
            yield match.start()


def findings(relative, text):
    exempt = HELPERS.get(relative, set())
    powershell = extension(relative) in ('ps1', 'psm1', 'psd1', 'cmd', 'bat')
    found = {}
    for row, patterns in RULES:
        if row['category'] in exempt:
            continue
        for start in named(row, patterns, text, powershell):
            found.setdefault(start, row['category'] + ' name ' + row['name'])
    if 'recursive walk, copy, delete, permission and ownership' not in exempt:
        for shape in SHAPES:
            for match in shape.finditer(text):
                found.setdefault(match.start(), 'recursive walk shape')
        for match in NUMBERED.finditer(text):
            if re.search(r',\s*(?:\(\s*[\w.]*SearchOption\s*\)\s*)?1\s*\)$', statement(text, match.start())):
                found.setdefault(match.start(), 'recursive walk shape')
    lines = text.splitlines()
    rows = {}
    for start, message in sorted(found.items()):
        number = text.count('\n', 0, start) + 1
        rows.setdefault(number, (number, lines[number - 1].strip(), message))
    return list(rows.values())


def check(root):
    root = Path(root)
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
        if extension(relative) not in SCANNED:
            if extension(relative) not in DATA:
                failures.append(f'{relative}: its file type is neither scanned nor listed as data in reparse-walk-names.json')
            continue
        for number, line, message in findings(relative, (root / relative).read_text(encoding='utf-8-sig', errors='replace')):
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
    problems = check(parser.parse_args().root)
    for problem in problems:
        print(problem)
    if not problems:
        print('Reparse walk check passed')
    raise SystemExit(bool(problems))
