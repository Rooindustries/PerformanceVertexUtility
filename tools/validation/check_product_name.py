import argparse
import json
from pathlib import Path
import re
import subprocess

SHIPPED = (
    "docs/internal/frontend/RooIndustries.OptimizationSuite.App/",
    "backend/native/",
    "backend/scripts/",
    "backend/capabilities/",
    "backend/profiles/",
    "backend/uninstall/",
    "backend/contracts/",
    "backend/catalogs/",
    "modules/",
    "tools/release/",
    "LeanClientOptimizer.ps1",
)
RESEARCH = (
    "backend/catalogs/upstream-settings-inventory.json",
    "backend/catalogs/fsosx-",
    "backend/catalogs/sources/fsos.json",
)
TEST_SCRIPT = re.compile(r"^backend/scripts/(?:.*/)?(?:Test-[^/]*|[^/]*\.Tests)\.ps1$|^backend/scripts/GovernorScenarios/")
PRODUCT = re.compile(r"Roo Industries|rooindustries\.com|Lean Client Optimizer")
EXCEPTIONS = "tools/validation/product-name-exceptions.json"

def shipped(relative):
    return relative.startswith(SHIPPED) and not relative.startswith(RESEARCH) and not TEST_SCRIPT.search(relative)

def check(root):
    failures = []
    exceptions = {}
    used = set()
    manifest = root / EXCEPTIONS
    if manifest.exists():
        for entry in json.loads(manifest.read_text(encoding="utf-8-sig"))["exceptions"]:
            text = entry["text"]
            if not PRODUCT.search(text):
                failures.append(f"{EXCEPTIONS}: exception {text!r} has no product name")
            if not entry["reason"].strip():
                failures.append(f"{EXCEPTIONS}: exception {text!r} has an empty reason")
            if not entry["files"]:
                failures.append(f"{EXCEPTIONS}: exception {text!r} lists no files")
            for relative in entry["files"]:
                exceptions.setdefault(relative, set()).add(text)
    if (root / ".git").exists():
        paths = subprocess.check_output(["git", "ls-files", "-z"], cwd=root).decode().split("\0")
    else:
        paths = [path.relative_to(root).as_posix() for path in root.rglob("*") if path.is_file() and not {"bin", "obj", "artifacts", "state", "__pycache__", ".git"}.intersection(path.parts)]
    for relative in paths:
        path = root / relative
        if not relative or not shipped(relative) or not path.is_file():
            continue
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
            if PRODUCT.search(filtered):
                failures.append(f"{relative}:{number}: product name in shipped text")
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
        print("Product name check passed")
    raise SystemExit(bool(problems))
