import argparse
import json
from pathlib import Path
import re
import runpy
import subprocess

local_tree = runpy.run_path(str(Path(__file__).with_name('local_tree.py')))['entries']

ALLOWLIST = 'tools/validation/reparse-walk-allowlist.json'
SCOPE = re.compile(r'.*\.(cs|ps1|psm1|py)$')
WALK = 'this recursive walk follows junctions, symbolic links and mount points'
FOLLOWS = re.compile('|'.join([
    r'\bAllDirectories\b',
    r'\bRecurseSubdirectories\s*=\s*\$?true\b',
    r'\bos\.f?walk\(',
    r'\.rglob\(',
    r'\brecursive\s*=\s*True\b',
    r'\bcopytree\(',
    r'\bCopy-Item\b[^\n;|]*\s-Recurse\b',
    r'\bicacls(?:\.exe)?\b[^\n]*[\s\'"]/T(?![A-Za-z:])',
    r'\btakeown(?:\.exe)?\b[^\n]*[\s\'"]/R(?![A-Za-z:])',
    r'\bxcopy(?:\.exe)?\b',
    r'\bdir\s+/s\b',
]), re.IGNORECASE)
ROBOCOPY = re.compile(r'\brobocopy(?:\.exe)?\b[^\n;|]*', re.IGNORECASE)
VOLUME = re.compile(r'GetVolumeNameForVolumeMountPoint|SetVolumeMountPoint|\bmountvol\b|\\\?\?\\Volume\{|'
                    r'assign\s+mount|Mount-DiskImage|New-VHD\b|AttachVirtualDisk', re.IGNORECASE)
HELPERS = {
    'backend/native/Optimizer.Core/LocalTree.cs': 'walk',
    'tools/validation/OptimizerCore/TestFixtures.cs': 'volume',
    'tools/validation/check_reparse_walks.py': 'all',
}


def findings(relative, text):
    exempt = HELPERS.get(relative, '')
    found = []
    if exempt not in ('walk', 'all'):
        for match in FOLLOWS.finditer(text):
            found.append((match.start(), match.group(0), WALK))
        for match in ROBOCOPY.finditer(text):
            flags = {flag.upper() for flag in re.findall(r'(?<![\w:])/([A-Za-z]+)\b', match.group(0))}
            if flags & {'MIR', 'PURGE'} or (flags & {'E', 'S'} and 'XJ' not in flags):
                found.append((match.start(), match.group(0), WALK))
    if exempt not in ('volume', 'all'):
        for match in VOLUME.finditer(text):
            found.append((match.start(), match.group(0), 'a fixture reaches a real volume; mount TestFixtures.Volume instead'))
    return [(text.count('\n', 0, start) + 1, ' '.join(walk.split()), message) for start, walk, message in found]


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
                failures.append(f'{ALLOWLIST}: {entry.get("file")} {entry.get("walk")!r} needs the reason its root holds no link')
            allowed.append(entry)
    used = set()
    for relative in sorted(path for path in paths if path and SCOPE.match(path)):
        if {'bin', 'obj'}.intersection(relative.split('/')) or not (root / relative).is_file():
            continue
        for line, walk, message in findings(relative, (root / relative).read_text(encoding='utf-8-sig', errors='replace')):
            matches = [i for i, e in enumerate(allowed) if e.get('file') == relative and ' '.join(str(e.get('walk', '')).split()) == walk]
            used.update(matches)
            if not matches:
                failures.append(f'{relative}:{line}: {message}: {walk}; use LocalTree.Entries, local_tree.entries or Get-ChildItem -Recurse, or list why its root holds no link in {ALLOWLIST}')
    for i, entry in enumerate(allowed):
        if i not in used:
            failures.append(f'{ALLOWLIST}: stale entry {entry.get("file")} {entry.get("walk")!r}')
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
