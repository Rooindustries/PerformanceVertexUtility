import argparse
import json
from pathlib import Path
import re
import subprocess

COMPATIBILITY = {
    "backend/native/Optimizer.Core/BrandCompatibility.cs",
    "backend/scripts/BrandCompatibility.Common.ps1",
    "backend/scripts/Test-BrandCompatibility.ps1",
    "tools/validation/OptimizerCore/BrandCompatibilityChecks.cs",
    "tools/validation/brand_compatibility.py",
    "tools/validation/test_brand_compatibility.py",
    "tools/validation/check_branding.py",
}
SHORT_NAME = re.compile(r"\bRoo(?!Industries|industries| Industries)(?:\b|[A-Z])|(?<=\w)Roo(?=[A-Z])(?!Industries)|\bROO(?:_(?!INDUSTRIES_)|\b(?! INDUSTRIES))|\broo(?!industries|-industries)(?:[-_.]|\b)")

def shortened(text):
    return SHORT_NAME.search(text.replace("Roo Code", "External product").replace("RooCode", "ExternalProduct")) is not None

def check(root):
    failures = []
    if (root / ".git").exists():
        paths = subprocess.check_output(["git", "ls-files", "-z"], cwd=root).decode().split("\0")
    elif (root / "source-verification.json").exists():
        paths = json.loads((root / "source-verification.json").read_text(encoding="utf-8-sig"))["files"]
    else:
        paths = [path.relative_to(root).as_posix() for path in root.rglob("*") if path.is_file() and not {"bin", "obj", "artifacts", "state", "__pycache__", ".git"}.intersection(path.parts)]
    for relative in paths:
        path = root / relative
        if not relative or not path.is_file() or relative in COMPATIBILITY:
            continue
        if shortened(relative):
            failures.append(relative + ": shortened product name in path")
        try:
            source = path.read_text(encoding="utf-8-sig")
        except UnicodeError:
            continue
        for number, line in enumerate(source.splitlines(), 1):
            if shortened(line):
                failures.append(f"{relative}:{number}: shortened product reference")
    return failures

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[2])
    problems = check(parser.parse_args().root)
    for problem in problems:
        print(problem)
    if not problems:
        print("Roo Industries naming check passed")
    raise SystemExit(bool(problems))
