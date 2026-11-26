import argparse
import json
from pathlib import Path
import re
import runpy
import subprocess

local_tree = runpy.run_path(str(Path(__file__).with_name('local_tree.py')))['entries']

ALLOWLIST = 'tools/validation/reparse-walk-allowlist.json'
SCOPE = re.compile(r'.*\.(cs|ps1|psm1|py)$')
WALK = 'this names a recursive walk that can follow junctions, symbolic links and mount points'
LINKED = 'this names a link, mount or drive mapping primitive outside the TestFixtures helpers'
WALKS = re.compile('|'.join([
    r'alldirectories', r'recursesubdirectories', r'\.f?walk\(', r'rglob', r'copytree', r'xcopy', r'robocopy',
    r'(?<![a-z])i?cacls(?![a-z])', r'(?<![a-z])takeown(?![a-z])', r'\bfor\s+/r\b', r'\bdir\b[^\n]*\s/s\b',
    r'\.i?glob\(\s*[rbf]*[\'"][^\'"\n]*\*\*', r'\brecursive\s*=\s*True\b',
]), re.IGNORECASE)
NUMBERED = re.compile(r'\b(?:Get|Enumerate)(?:Files|Directories|FileSystemEntries|FileSystemInfos)\s*\(', re.IGNORECASE)
COPY = re.compile(r'(?<![\w.$-])(?:Copy-Item|cpi|cp|copy)(?![\w-])', re.IGNORECASE)
LINKS = re.compile('|'.join([
    r'symbolic_?link', r'symlink', r'hard_?link', r'mount_?point', r'access_?path', r'dos_?device', r'createjunction', r'mklink',
    r'mountvol', r'(?<![a-z])subst(?:\.exe)?(?![a-z])', r'ps_?drive', r'vhdx?(?![a-z])', r'vdisk', r'disk_?image',
    r'virtual_?disk', r'0x0*900a4', r'set_?reparse_?point', r'assign\s+mount',
]), re.IGNORECASE)
JUNCTION = re.compile(r'junction', re.IGNORECASE)
POWERSHELL = re.compile(r'itemtype|new-item|(?<![\w-])-it(?![\w-])', re.IGNORECASE)
HELPERS = {
    'backend/native/Optimizer.Core/LocalTree.cs': {WALK},
    'tools/validation/OptimizerCore/TestFixtures.cs': {LINKED},
    'tools/validation/check_reparse_walks.py': {WALK, LINKED},
}


def statement(text, start):
    depth = 0
    index = start
    while index < len(text):
        char = text[index]
        if char in '([{':
            depth += 1
        elif char in ')]}':
            if depth == 0:
                break
            depth -= 1
        elif char in ';|' and depth == 0:
            break
        elif char == '\n' and depth == 0 and not text[:index].rstrip('\r').endswith('`'):
            break
        index += 1
    return text[start:index]


def findings(relative, text):
    exempt = HELPERS.get(relative, set())
    powershell = relative.endswith(('.ps1', '.psm1'))
    found = {}
    if WALK not in exempt:
        for match in WALKS.finditer(text):
            found.setdefault(match.start(), WALK)
        for match in NUMBERED.finditer(text):
            if re.search(r',\s*(?:\(\s*[\w.]*SearchOption\s*\)\s*)?1\s*\)$', statement(text, match.start())):
                found.setdefault(match.start(), WALK)
        for match in COPY.finditer(text):
            if re.search(r'\s(?:-r[a-z]*\b|@[A-Za-z_]\w*)', statement(text, match.start()), re.IGNORECASE):
                found.setdefault(match.start(), WALK)
    if LINKED not in exempt:
        for match in LINKS.finditer(text):
            found.setdefault(match.start(), LINKED)
        for match in JUNCTION.finditer(text):
            line = text[text.rfind('\n', 0, match.start()) + 1:text.find('\n', match.start()) % (len(text) + 1)]
            if powershell or POWERSHELL.search(line):
                found.setdefault(match.start(), LINKED)
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
    for relative in sorted(path for path in paths if path and SCOPE.match(path)):
        if {'bin', 'obj'}.intersection(relative.split('/')) or not (root / relative).is_file():
            continue
        for number, line, message in findings(relative, (root / relative).read_text(encoding='utf-8-sig', errors='replace')):
            match = next((i for i, e in enumerate(allowed) if i not in used and e.get('file') == relative and e.get('line') == line), None)
            if match is None:
                failures.append(f'{relative}:{number}: {message}: {line[:160]}; use LocalTree.Entries, local_tree, TestFixtures.Junction, '
                                f'TestFixtures.Symlink or Get-ChildItem -Recurse, or list why it stays inside a fixture in {ALLOWLIST}')
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
