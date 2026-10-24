from __future__ import annotations

from pathlib import Path
import re
import subprocess
import tempfile

AGENT_FILES = re.compile(r'\b(?:' + '|'.join(('AGENTS', 'CLA' + 'UDE', 'GEMINI')) + r')\.md\b', re.IGNORECASE)
CODE = {'.cs', '.csproj', '.props', '.targets', '.ps1', '.psm1', '.psd1', '.py', '.sh', '.cmd', '.json', '.yml', '.yaml', '.xaml'}
SKIP = {'bin', 'obj', '.git', '__pycache__'}


def files(root: Path) -> list[Path]:
    if (root / '.git').exists():
        listed = subprocess.run(['git', '-C', str(root), 'ls-files', '-z'], capture_output=True, check=True).stdout.decode('utf-8')
        return [root / name for name in listed.split('\0') if name]
    return [path for path in root.rglob('*') if path.is_file() and not SKIP.intersection(path.relative_to(root).parts)]


def check(root: Path | str) -> list[str]:
    root = Path(root)
    failures = []
    for path in files(root):
        if path.suffix.lower() not in CODE or not path.is_file():
            continue
        for number, line in enumerate(path.read_text(encoding='utf-8-sig', errors='replace').splitlines(), 1):
            if AGENT_FILES.search(line):
                failures.append(f"{path.relative_to(root).as_posix()}:{number}: code depends on an agent instruction file, which isn't part of the product; find the files it needs by their own paths")
    return failures


def negative_controls() -> dict[str, bool]:
    marker = 'AGENTS' + '.md'
    cases = {
        'a check that finds the repository by an agent file': ({'tools/validation/X/Checks.cs': 'while (!File.Exists(Path.Combine(dir, "' + marker + '"))) dir = dir.Parent;'}, True),
        'a script that reads an agent file': ({'tools/x.ps1': "Get-Content (Join-Path $root 'GEMINI" + ".md')"}, True),
        'a check that finds the files it reads': ({'tools/validation/X/Checks.cs': 'while (!File.Exists(Path.Combine(dir, "docs", "Views", "Panel.xaml"))) dir = dir.Parent;'}, False),
        'prose that names an agent file': ({'docs/notes.md': marker}, False),
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
