import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import time

parser = argparse.ArgumentParser()
parser.add_argument('--host', required=True)
parser.add_argument('--expected-machine', required=True)
parser.add_argument('--out', type=Path, required=True)
parser.add_argument('--runner', type=Path, help='windows_ssh.py to test; defaults to the one in this checkout')
args = parser.parse_args()
args.out.mkdir(parents=True, exist_ok=False)
root = Path(__file__).resolve().parents[3]
runner = args.runner or root / 'tools/validation/windows_ssh.py'
spec = importlib.util.spec_from_file_location('windows_ssh', runner)
w = importlib.util.module_from_spec(spec)
spec.loader.exec_module(w)
proof = {'passed': False, 'checks': [], 'runner': str(runner), 'toolHash': hashlib.sha256(runner.read_bytes()).hexdigest()}
saved_run = subprocess.run


def late_payload(delay, withhold=False):
    # Stands in for a slow link: SSH and PowerShell start at once, the script bytes arrive late or never.
    def run(command, *, input, timeout, check, capture_output, text, encoding):
        process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=text, encoding=encoding)
        try:
            time.sleep(delay)
            # A withheld script ends the input after the old 5 second wait would have run out.
            stdout, stderr = process.communicate(None if withhold else input, timeout=timeout + 30)
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
            for stream in (process.stdin, process.stdout, process.stderr):
                stream.close()
        if check and process.returncode:
            raise subprocess.CalledProcessError(process.returncode, command, stdout, stderr)
        return subprocess.CompletedProcess(command, process.returncode, stdout, stderr)
    return run


def attempt(name, script, delay, timeout, withhold=False):
    started = time.monotonic()
    w.subprocess.run = late_payload(delay, withhold)
    try:
        result = w.invoke(args.host, args.expected_machine, script, timeout=timeout)
        outcome = {'exit': result.returncode, 'stdout': result.stdout, 'stderr': result.stderr}
    except subprocess.CalledProcessError as error:
        outcome = {'exit': error.returncode, 'stdout': error.stdout, 'stderr': error.stderr}
    finally:
        w.subprocess.run = saved_run
    outcome['stderr'] = '\n'.join(line for line in (outcome['stderr'] or '').splitlines() if not line.startswith('** '))
    return {'name': name, 'delaySeconds': delay, 'timeoutSeconds': timeout, 'seconds': round(time.monotonic() - started, 2), **outcome}


def check(entry, passed):
    entry['passed'] = bool(passed)
    proof['checks'].append(entry)
    (args.out / 'proof.json').write_text(json.dumps(proof, indent=2))
    print(json.dumps({key: entry[key] for key in ('name', 'exit', 'seconds', 'passed')}), flush=True)


try:
    slow = attempt('payload arrives 8 seconds late', "'PASS late payload ran'", 8, 30)
    check(slow, slow['exit'] == 0 and 'PASS late payload ran' in slow['stdout'] and slow['seconds'] >= 8)
    missing = attempt('payload never arrives', "'payload must not run'", 15, 30, withhold=True)
    check(missing, missing['exit'] == 1 and 'SSH payload ended before newline' in missing['stderr'] and 'must not run' not in missing['stdout'])
    forwarding, w.REMOTE_INPUT = getattr(w, 'REMOTE_INPUT', None), ''
    try:
        direct = attempt('payload withheld from a PowerShell started without forwarding', "'payload must not run'", 8, 30, withhold=True)
    finally:
        w.REMOTE_INPUT = forwarding
    check(direct, direct['exit'] == 1 and 'SSH payload did not arrive within 5 seconds of PowerShell starting' in direct['stderr'])
    proof['passed'] = all(entry['passed'] for entry in proof['checks'])
finally:
    (args.out / 'proof.json').write_text(json.dumps(proof, indent=2))
raise SystemExit(0 if proof['passed'] else 1)
