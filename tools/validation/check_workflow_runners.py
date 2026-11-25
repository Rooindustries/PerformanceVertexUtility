import re

RUNNERS = {"ubuntu-24.04", "windows-2025"}
ALLOWED = "use exactly ubuntu-24.04 or windows-2025"
KEY = re.compile(r"^( *)([^\s#:][^:]*):(.*)$")


def check(root):
    failures = []
    for path in sorted((root / ".github/workflows").glob("*.y*ml")):
        relative = path.relative_to(root).as_posix()
        jobs = []
        job = None
        in_jobs = False
        job_indent = None
        property_indent = None
        for number, line in enumerate(path.read_text(encoding="utf-8-sig").splitlines(), 1):
            match = KEY.match(line)
            if not match:
                continue
            indent = len(match.group(1))
            key = match.group(2).strip()
            if indent == 0:
                in_jobs = key == "jobs"
                job_indent = None
                job = None
            elif in_jobs and job_indent in (None, indent):
                job_indent = indent
                property_indent = None
                job = {"name": key, "line": number, "runs_on": None}
                jobs.append(job)
            elif job and indent > job_indent:
                property_indent = property_indent or indent
                if indent == property_indent and key == "runs-on":
                    job["runs_on"] = (number, match.group(3).split(" #")[0].strip())
        for job in jobs:
            if job["runs_on"] is None:
                failures.append(f"{relative}:{job['line']}: job {job['name']} has no runs-on; {ALLOWED}")
                continue
            number, value = job["runs_on"]
            if value.strip("'\"") not in RUNNERS:
                failures.append(f"{relative}:{number}: job {job['name']} runs on {value or 'a nested value'}; {ALLOWED}")
    return failures
