import argparse
import json
from pathlib import Path
import re
import runpy
import subprocess

local_tree = runpy.run_path(str(Path(__file__).with_name('local_tree.py')))['entries']

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
EXCEPTIONS = "tools/validation/branding-exceptions.json"

def shortened(text):
    return SHORT_NAME.search(text.replace("Roo Code", "External product").replace("RooCode", "ExternalProduct")) is not None

def check(root):
    failures = []
    exceptions = {}
    used = set()
    manifest = root / EXCEPTIONS
    if manifest.exists():
        for entry in json.loads(manifest.read_text(encoding="utf-8-sig"))["exceptions"]:
            text = entry["text"]
            if not shortened(text):
                failures.append(f"{EXCEPTIONS}: exception {text!r} is not shortened")
            if not entry["reason"].strip():
                failures.append(f"{EXCEPTIONS}: exception {text!r} has an empty reason")
            if not entry["files"]:
                failures.append(f"{EXCEPTIONS}: exception {text!r} lists no files")
            for relative in entry["files"]:
                exceptions.setdefault(relative, set()).add(text)
    if (root / ".git").exists():
        paths = subprocess.check_output(["git", "ls-files", "-z"], cwd=root).decode().split("\0")
    elif (root / "source-verification.json").exists():
        paths = json.loads((root / "source-verification.json").read_text(encoding="utf-8-sig"))["files"]
    else:
        paths = [path.relative_to(root).as_posix() for path in local_tree(root) if path.is_file() and not {"bin", "obj", "artifacts", "state", "__pycache__", ".git"}.intersection(path.parts)]
    for relative in paths:
        path = root / relative
        if not relative or not path.is_file() or relative in COMPATIBILITY | {EXCEPTIONS}:
            continue
        if shortened(relative):
            failures.append(relative + ": shortened product name in path")
        try:
            source = path.read_text(encoding="utf-8-sig")
        except UnicodeError:
            continue
        for number, line in enumerate(source.splitlines(), 1):
            filtered = line
            for text in sorted(exceptions.get(relative, ()), key=len, reverse=True):
                if text in line:
                    used.add((text, relative))
                    filtered = filtered.replace(text, " ")
            if shortened(filtered):
                failures.append(f"{relative}:{number}: shortened product reference")
    for relative, texts in exceptions.items():
        for text in sorted(texts):
            if (text, relative) not in used:
                failures.append(f"{EXCEPTIONS}: stale exception {text!r} in {relative}")
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
