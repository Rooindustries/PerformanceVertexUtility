from pathlib import Path
import re
import tempfile

HEAD_REF = re.compile(r'^\s*(?:-\s+)?ref:.*(?:github\.event\.pull_request\.head\.|github\.head_ref)')


def check(root):
    failures = []
    folder = root / '.github/workflows'
    for path in sorted([*folder.glob('*.yml'), *folder.glob('*.yaml')]):
        for number, line in enumerate(path.read_text(encoding='utf-8').splitlines(), 1):
            if HEAD_REF.search(line):
                relative = path.relative_to(root).as_posix()
                failures.append(f'{relative}:{number}: checks out the pull request head, so a branch older than'
                                ' a script the workflow runs lacks it; check out the default merge ref')
    return failures


def negative_controls():
    workflow = '.github/workflows/x.yml'
    cases = {
        'head sha checkout': ('          ref: ${{ github.event.pull_request.head.sha }}', True),
        'head branch checkout': ('        - ref: "${{ github.head_ref }}"', True),
        'commented out head checkout': ('          # ref: ${{ github.head_ref }}', False),
        'base sha checkout': ('          ref: ${{ github.event.pull_request.base.sha }}', False),
        'head sha outside a checkout ref': ('          HEAD_SHA: ${{ github.event.pull_request.head.sha }}', False),
    }
    results = {}
    for label, (line, should_fail) in cases.items():
        with tempfile.TemporaryDirectory() as folder:
            temporary = Path(folder)
            (temporary / workflow).parent.mkdir(parents=True)
            (temporary / workflow).write_text('steps:\n' + line + '\n', encoding='utf-8')
            results[label] = bool(check(temporary)) == should_fail
    return results
