import yaml

RUNNERS = {"ubuntu-24.04", "windows-2025"}
ALLOWED = "use exactly ubuntu-24.04 or windows-2025"
STRING = "tag:yaml.org,2002:str"


def entries(node):
    if not isinstance(node, yaml.MappingNode):
        return None
    names = [key.value for key, _ in node.value if isinstance(key, yaml.ScalarNode) and key.tag == STRING]
    if len(names) < len(node.value) or len(set(names)) < len(names):
        return None
    return {key.value: (key, value) for key, value in node.value}


def check(root):
    failures = []
    for path in sorted((root / ".github/workflows").glob("*.y*ml")):
        relative = path.relative_to(root).as_posix()
        text = path.read_text(encoding="utf-8-sig")
        try:
            document = yaml.compose(text, Loader=yaml.BaseLoader)
        except yaml.YAMLError as error:
            mark = getattr(error, "problem_mark", None)
            failures.append(f"{relative}:{mark.line + 1 if mark else 1}: cannot be read as YAML; {ALLOWED}")
            continue
        workflow = entries(document)
        if workflow is None or "jobs" not in workflow:
            failures.append(f"{relative}:1: has no jobs mapping with unique plain names; {ALLOWED}")
            continue
        jobs_key, jobs_node = workflow["jobs"]
        jobs = entries(jobs_node)
        if jobs is None:
            failures.append(f"{relative}:{jobs_key.start_mark.line + 1}: jobs are not unique plain names; {ALLOWED}")
            continue
        for name, (job_key, job_node) in jobs.items():
            job = entries(job_node)
            where = f"{relative}:{job_key.start_mark.line + 1}: job {name}"
            if job is None:
                failures.append(f"{where} is not a mapping with unique plain names; {ALLOWED}")
                continue
            if "runs-on" not in job:
                failures.append(f"{where} has no runs-on; {ALLOWED}")
                continue
            runs_on_key, runs_on = job["runs-on"]
            if isinstance(runs_on, yaml.ScalarNode) and runs_on.tag == STRING and runs_on.value in RUNNERS:
                continue
            value = " ".join(text[runs_on.start_mark.index:runs_on.end_mark.index].split())
            failures.append(f"{relative}:{runs_on_key.start_mark.line + 1}: job {name} runs on {value}; {ALLOWED}")
    return failures
