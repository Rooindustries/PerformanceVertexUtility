import argparse
import json
from pathlib import Path
import re
import runpy
import subprocess

local_tree = runpy.run_path(str(Path(__file__).with_name('local_tree.py')))['entries']

FAKE_SIDS = {"S-1-5-21-111111111-222222222-333333333"}
PLACEHOLDER_USERS = {"alice", "all users", "bob", "carol", "client", "default", "default user", "example", "fixture", "jos", "josé", "john smith", "jsmith", "public"}
PLACEHOLDER_HOMES = {"example", "runner", "user"}
EMAIL_DOMAINS = {"example.com", "example.net", "example.org", "rooindustries.com"}
SID = re.compile(r"S-1-5-21-(\d+)-(\d+)-(\d+)-\d+")
USER_FOLDER = re.compile(r"(?i:[a-z]:(?:\\+|/)users(?:\\+|/))([\w.-]+(?: [A-Z][\w.-]*)*)")
HOME_FOLDER = re.compile(r"(?<![\w.~:])/(?:home|Users)/([a-z_][a-z0-9._-]*)")
TAILNET_ADDRESS = re.compile(r"(?<![\d.])100\.(?:6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.\d{1,3}\.\d{1,3}(?!\.?\d)")
PRIVATE_ADDRESS = re.compile(r"(?<![\d.])(?:10\.\d{1,3}|192\.168|172\.(?:1[6-9]|2\d|3[01]))\.\d{1,3}\.\d{1,3}(?!\.?\d)")
TAILNET_NAME = re.compile(r"(?i)\b[\w-]+\.ts\.net\b")
EMAIL = re.compile(r"\b[\w.%+-]+@([A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,})\b")
COMPUTER_LITERAL = re.compile(r"(?i)\$env:COMPUTERNAME\s*-[ci]?(?:eq|ne)\s*['\"]|['\"]\s*-[ci]?(?:eq|ne)\s*\$env:COMPUTERNAME")
COMPUTER_DEFAULT = re.compile(r"(?i)\$(?:Expected)?(?:Machine|Computer)(?:Name)?\s*=\s*['\"][^'\"\n]+['\"]")
HOST_CALL = re.compile(r"\.(?:invoke|upload|interactive|verify_source)\(\s*(['\"])(?![^'\"\n]*\.invalid\1)[A-Za-z0-9][A-Za-z0-9.-]*\1\s*,")
HOST_ASSIGNMENT = re.compile(r"(?m)^\s*(?:HOST|MACHINE|host|machine)(?:\s*,\s*\w+)*\s*=\s*(['\"])(?![^'\"\n]*\.invalid\1)[A-Za-z0-9][A-Za-z0-9.-]*\1")


def tracked_paths(root):
    if (root / ".git").exists():
        return subprocess.check_output(["git", "ls-files", "-z"], cwd=root).decode().split("\0")
    if (root / "source-verification.json").exists():
        return json.loads((root / "source-verification.json").read_text(encoding="utf-8-sig"))["files"]
    return [path.relative_to(root).as_posix() for path in local_tree(root) if path.is_file() and not {"bin", "obj", "artifacts", "state", "__pycache__", ".git"}.intersection(path.parts)]


def findings(relative, source):
    for match in SID.finditer(source):
        if match.group().rsplit("-", 1)[0] not in FAKE_SIDS and any(len(part) >= 5 for part in match.groups()):
            yield source.count("\n", 0, match.start()) + 1, "account SID"
    for match in USER_FOLDER.finditer(source):
        name = match.group(1)
        if len(name) > 1 and name.lower() not in PLACEHOLDER_USERS:
            yield source.count("\n", 0, match.start()) + 1, "user folder name"
    for match in HOME_FOLDER.finditer(source):
        if match.group(1) not in PLACEHOLDER_HOMES:
            yield source.count("\n", 0, match.start()) + 1, "home folder name"
    for pattern, kind in ((TAILNET_ADDRESS, "tailnet address"), (PRIVATE_ADDRESS, "private network address"), (TAILNET_NAME, "tailnet host name"), (COMPUTER_LITERAL, "computer name literal"), (COMPUTER_DEFAULT, "computer name literal")):
        for match in pattern.finditer(source):
            yield source.count("\n", 0, match.start()) + 1, kind
    for match in EMAIL.finditer(source):
        domain = match.group(1).lower()
        if domain not in EMAIL_DOMAINS and domain.rsplit(".", 1)[-1] not in {"dll", "exe"}:
            yield source.count("\n", 0, match.start()) + 1, "email address"
    if relative.endswith(".py"):
        for pattern in (HOST_CALL, HOST_ASSIGNMENT):
            for match in pattern.finditer(source):
                yield source.count("\n", 0, match.start()) + 1, "remote host literal"


def check(root):
    problems = set()
    for relative in tracked_paths(root):
        path = root / relative
        if not relative or not path.is_file():
            continue
        try:
            source = path.read_text(encoding="utf-8-sig")
        except UnicodeError:
            continue
        problems.update((relative, line, kind) for line, kind in findings(relative, source))
    return [f"{relative}:{line}: {kind}" for relative, line, kind in sorted(problems)]


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[2])
    problems = check(parser.parse_args().root)
    for problem in problems:
        print(problem)
    if not problems:
        print("Public surface check passed")
    raise SystemExit(bool(problems))
