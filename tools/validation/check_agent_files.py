from __future__ import annotations

from pathlib import Path
import re
import runpy
import subprocess
import tempfile

local_tree = runpy.run_path(str(Path(__file__).with_name('local_tree.py')))['entries']

AGENT_FILES = re.compile(r'\b(?:AGENTS|CL[A]UDE|GEMINI)(?:\.md\b|["\']\s*\+\s*["\']\.md\b)', re.IGNORECASE)
DOCS = {'.md'}
IGNORED = {'.gitignore'}
SKIP = {'bin', 'obj', '.git', '__pycache__'}
SELF = 'tools/validation/check_agent_files.py'


def files(root: Path) -> list[Path]:
    if (root / '.git').exists():
        listed = subprocess.run(['git', '-C', str(root), 'ls-files', '-z'], capture_output=True, check=True).stdout.decode('utf-8')
        return [root / name for name in listed.split('\0') if name]
    return [path for path in local_tree(root) if path.is_file() and not SKIP.intersection(path.relative_to(root).parts)]


def check(root: Path | str) -> list[str]:
    root = Path(root)
    failures = []
    for path in files(root):
        relative = path.relative_to(root).as_posix()
        if relative == SELF or path.suffix.lower() in DOCS or path.name in IGNORED or not path.is_file():
            continue
        data = path.read_bytes()
        if b'\0' in data[:8192]:
            continue
        for number, line in enumerate(data.decode('utf-8-sig', errors='replace').splitlines(), 1):
            if AGENT_FILES.search(line):
                failures.append(f"{relative}:{number}: code depends on an agent instruction file, which isn't part of the product; find the files it needs by their own paths")
    return failures


def negative_controls() -> dict[str, bool]:
    marker = 'AGENTS' + '.md'
    cases = {
        'a check that finds the repository by an agent file': ({'tools/validation/X/Checks.cs': 'while (!File.Exists(Path.Combine(dir, "' + marker + '"))) dir = dir.Parent;'}, True),
        'a script that reads an agent file': ({'tools/x.ps1': "Get-Content (Join-Path $root 'GEMINI" + ".md')"}, True),
        'a check that finds the files it reads': ({'tools/validation/X/Checks.cs': 'while (!File.Exists(Path.Combine(dir, "docs", "Views", "Panel.xaml"))) dir = dir.Parent;'}, False),
        'a check that builds an agent file name in two parts': ({'tools/validation/X/Checks.cs': 'File.Exists(Path.Combine(dir, "AGENTS" + ".md"))'}, True),
        'an installer script that names an agent file': ({'tools/release/Setup.iss': 'Source: "' + marker + '"'}, True),
        'a file type no one listed': ({'tools/x.nsi': 'File ' + marker}, True),
        'a build file that names an agent file': ({'native/CMakeLists.txt': 'configure_file(' + marker + ' out)'}, True),
        'a requirements file that names an agent file': ({'tools/requirements.txt': '-r ' + marker}, True),
        'prose that names an agent file': ({'docs/notes.md': marker}, False),
        'the ignore list': ({'.gitignore': marker}, False),
        'a binary file': ({'assets/x.bin': '\0' + marker}, False),
        'the agent file check itself': ({SELF: marker}, False),
        'build output': ({'tools/validation/X/bin/Debug/x.json': marker}, False),
    }
    results = {}
    for label, (sources, should_fail) in cases.items():
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            for relative, source in sources.items():
                (root / relative).parent.mkdir(parents=True, exist_ok=True)
                (root / relative).write_text(source, encoding='utf-8')
            results[label] = bool(check(root)) == should_fail
    return results


if __name__ == '__main__':
    found = check(Path(__file__).resolve().parents[2])
    print('\n'.join(found) if found else 'Agent file references: OK')
    raise SystemExit(1 if found else 0)
