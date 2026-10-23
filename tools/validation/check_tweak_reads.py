import json
import os
from pathlib import Path
import subprocess
import tempfile
import time


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


def negative_controls(root):
    if os.name == 'nt':
        return {}
    saved = {name: os.environ.get(name) for name in ('DOTNET', 'TWEAK_READS_TIMEOUT')}
    with tempfile.TemporaryDirectory() as folder:
        stub, child = Path(folder) / 'dotnet', Path(folder) / 'child'
        stub.write_text(f'#!/bin/sh\nsleep 30 &\necho $! > "{child}"\nwait\n')
        stub.chmod(0o755)
        os.environ.update(DOTNET=str(stub), TWEAK_READS_TIMEOUT='1')
        started = time.monotonic()
        try:
            failures = check(root)
        finally:
            for name, value in saved.items():
                if value is None:
                    os.environ.pop(name, None)
                else:
                    os.environ[name] = value
        stopped = time.monotonic() - started < 15 and gone(int(child.read_text()))
    return {'a hung read walk': stopped and len(failures) == 1 and failures[0].startswith('The Windows Tweaks read walk did not finish within 1 seconds')}


def gone(pid):
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return True
        time.sleep(0.05)
    return False


if __name__ == '__main__':
    errors = check(Path(__file__).resolve().parents[2])
    print(json.dumps({'failures': errors}, indent=2))
    raise SystemExit(bool(errors))
