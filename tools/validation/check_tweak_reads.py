import json
import os
from pathlib import Path
import subprocess


def check(root):
    project = root / 'tools/validation/TweakReads/TweakReads.csproj'
    command = [os.environ.get('DOTNET', 'dotnet'), 'run', '--project', str(project), '--configuration', 'Release', '-p:EnableWindowsTargeting=true', '--', str(root)]
    try:
        result = subprocess.run(command, cwd=root, capture_output=True, text=True)
    except FileNotFoundError:
        return ['The Windows Tweaks read walk needs the .NET 8 SDK (dotnet).']
    if result.returncode == 0:
        return []
    failures = [line for line in result.stdout.splitlines() if line.startswith('FAIL ')]
    return failures or ['The Windows Tweaks read walk did not finish: ' + (result.stdout + result.stderr)[-2000:]]


if __name__ == '__main__':
    errors = check(Path(__file__).resolve().parents[2])
    print(json.dumps({'failures': errors}, indent=2))
    raise SystemExit(bool(errors))
