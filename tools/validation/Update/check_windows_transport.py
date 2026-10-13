import argparse
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import time

root = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location('windows_ssh', root / 'tools/validation/windows_ssh.py')
windows = importlib.util.module_from_spec(spec)
spec.loader.exec_module(windows)
parser = argparse.ArgumentParser(description='Real SSH/SCP refusal against an unreachable test address; no Windows action.')
parser.add_argument('--host', required=True)
parser.add_argument('--expected-machine', required=True)
parser.add_argument('--live-host')
parser.add_argument('--out-dir', type=Path, required=True)
args = parser.parse_args()
args.out_dir.mkdir(parents=True, exist_ok=False)
rows = []
if args.live_host:
    started = time.monotonic()
    try:
        windows.invoke(args.live_host, args.expected_machine, 'Start-Sleep 20', timeout=5)
    except windows.RemoteTimeout as error:
        message = error.stderr
        elapsed = time.monotonic() - started
        if isinstance(error, windows.HostUnreachable):
            raise RuntimeError('RemoteTimeout must not inherit HostUnreachable.')
        followup = windows.invoke(args.live_host, args.expected_machine, "'live after timeout'")
        passed = followup.stdout.strip() == 'live after timeout' and 5 <= elapsed < 15
        rows.append({'check': 'live command deadline and follow-up', 'status': 'pass' if passed else 'fail',
                     'seconds': elapsed, 'exception': type(error).__name__, 'message': message,
                     'followup': followup.stdout.strip(), 'cleanup': 'No frame or product object created; SSH lifetime guard terminates its own PowerShell.'})
    else:
        raise RuntimeError('Live slow operation did not raise RemoteTimeout.')
for kind in ('ssh', 'scp'):
    started = time.monotonic()
    message = ''
    try:
        if kind == 'ssh':
            command = [sys.executable, '-I', str(root / 'tools/validation/windows_ssh.py'), '--host', args.host,
                       '--expected-machine', args.expected_machine, 'inspect']
            result = subprocess.run(command, capture_output=True, text=True, timeout=90)
            message = result.stdout + result.stderr
            refused = result.returncode != 0
        else:
            with tempfile.TemporaryDirectory(prefix='roo-unreachable-') as folder:
                source = Path(folder) / 'probe.txt'
                source.write_text('owned unreachable transport fixture')
                windows.run_transport(args.host, 'scp', [source, args.host + ':/unreachable-probe'],
                                      capture_output=True, text=True)
            refused = False
    except windows.HostUnreachable as error:
        message = error.stderr
        refused = True
    except windows.RemoteTimeout as error:
        message = error.stderr
        refused = False
    elapsed = time.monotonic() - started
    passed = refused and 'host unreachable' in message.casefold() and elapsed < 90
    rows.append({'check': kind + ' unreachable bound', 'status': 'pass' if passed else 'fail',
                 'host': args.host, 'seconds': elapsed, 'message': message, 'options': windows.SSH_OPTIONS})
    (args.out_dir / (kind + '.log')).write_text(message)
status = 'pass' if all(row['status'] == 'pass' for row in rows) else 'fail'
(args.out_dir / 'receipt.json').write_text(json.dumps({'status': status, 'checks': rows}, indent=2))
print(json.dumps({'status': status, 'checks': rows}, indent=2))
raise SystemExit(0 if status == 'pass' else 1)
