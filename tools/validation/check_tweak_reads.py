import contextlib
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time


def check(root):
    project = root / 'tools/validation/TweakReads/TweakReads.csproj'
    command = [os.environ.get('DOTNET', 'dotnet'), 'run', '--project', str(project), '--configuration', 'Release', '-p:EnableWindowsTargeting=true', '--', str(root)]
    timeout = int(os.environ.get('TWEAK_READS_TIMEOUT', '600'))
    marker = os.urandom(16).hex()
    try:
        process = subprocess.Popen(command, cwd=root, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, start_new_session=True, env=dict(os.environ, ROO_TWEAK_READS_RUN=marker))
    except FileNotFoundError:
        return ['The Windows Tweaks read walk needs the .NET 8 SDK (dotnet).']
    try:
        stdout, stderr = process.communicate(timeout=timeout)
    except BaseException as error:
        stop(process, marker)
        if not isinstance(error, subprocess.TimeoutExpired):
            raise
        return [f'The Windows Tweaks read walk did not finish within {timeout} seconds, so it was stopped. Run it alone to see where it hangs: dotnet run --project tools/validation/TweakReads/TweakReads.csproj --configuration Release -p:EnableWindowsTargeting=true -- .']
    if process.returncode == 0:
        return []
    failures = [line for line in stdout.splitlines() if line.startswith('FAIL ')]
    return failures or ['The Windows Tweaks read walk did not finish: ' + (stdout + stderr)[-2000:]]


def stop(process, marker):
    if os.name == 'nt':
        subprocess.run(['taskkill', '/F', '/T', '/PID', str(process.pid)], capture_output=True)
    else:
        with contextlib.suppress(ProcessLookupError):
            os.killpg(process.pid, signal.SIGKILL)
        for _ in range(3):
            for pid in marked(marker):
                with contextlib.suppress(ProcessLookupError):
                    os.kill(pid, signal.SIGKILL)
    process.kill()
    process.wait()


def negative_controls(root):
    if os.name == 'nt':
        return {}
    saved = {name: os.environ.get(name) for name in ('DOTNET', 'TWEAK_READS_TIMEOUT')}
    results = {}
    for label, spawn in (('a hung read walk', 'sleep 30 &'), ('a hung read walk whose child left its process group', 'setsid sleep 30 &')):
        with tempfile.TemporaryDirectory() as folder:
            stub, child = Path(folder) / 'dotnet', Path(folder) / 'child'
            stub.write_text(f'#!/bin/sh\n{spawn}\necho $! > "{child}"\nwait\n')
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
            pid = int(child.read_text())
            stopped = time.monotonic() - started < 15 and gone(pid)
            with contextlib.suppress(ProcessLookupError):
                os.kill(pid, signal.SIGKILL)
        results[label] = stopped and len(failures) == 1 and failures[0].startswith('The Windows Tweaks read walk did not finish within 1 seconds')
    return results


def marked(marker):
    needle = ('ROO_TWEAK_READS_RUN=' + marker).encode()
    pids = []
    for entry in Path('/proc').iterdir():
        if entry.name.isdigit() and int(entry.name) != os.getpid():
            with contextlib.suppress(OSError):
                if needle in (entry / 'environ').read_bytes().split(b'\0'):
                    pids.append(int(entry.name))
    return pids


def gone(pid):
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return True
        with contextlib.suppress(FileNotFoundError):
            if Path(f'/proc/{pid}/stat').read_text().rsplit(')', 1)[1].split()[0] == 'Z':
                return True
        time.sleep(0.05)
    return False


if __name__ == '__main__':
    errors = check(Path(__file__).resolve().parents[2])
    print(json.dumps({'failures': errors}, indent=2))
    raise SystemExit(bool(errors))
