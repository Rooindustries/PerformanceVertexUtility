import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import time
import uuid

parser = argparse.ArgumentParser()
parser.add_argument('--host', required=True)
parser.add_argument('--expected-machine', required=True)
parser.add_argument('--expected-sid', required=True)
parser.add_argument('--out', type=Path, required=True)
parser.add_argument('--refusal-only', action='store_true')
args = parser.parse_args()
args.out.mkdir(parents=True, exist_ok=False)
root = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location('windows_ssh', root / 'tools/validation/windows_ssh.py')
w = importlib.util.module_from_spec(spec)
spec.loader.exec_module(w)
machine = args.expected_machine
host = 'must-not-connect.invalid' if args.refusal_only else args.host
guard = "$ErrorActionPreference='Stop'; $ProgressPreference='SilentlyContinue'\n" + f"if ($env:COMPUTERNAME -ine {w.ps_literal(machine)}) {{throw 'Unexpected Windows computer'}}\n"
proof = {'passed': False, 'checks': [], 'toolHash': hashlib.sha256(Path(w.__file__).read_bytes()).hexdigest()}

def sized(body, size, character=' '):
    count = size - len((guard + body).encode())
    return body + character * (count // len(character.encode())) + ' ' * (count % len(character.encode()))

try:
    for size, character in [(65537, ' '), (65537, 'é'), (178205, ' ')]:
        script = sized("throw 'Oversized input must never execute'\n", size, character)
        started = time.monotonic()
        try:
            w.invoke(host, machine, script)
        except ValueError as error:
            if '65536' not in str(error) or 'protected file' not in str(error):
                raise
        else:
            raise AssertionError('Oversized inline script was accepted')
        proof['checks'].append({'bytes': len((guard + script).encode()), 'character': character, 'refused': True, 'seconds': time.monotonic() - started})
    if not args.refusal_only:
        frame = 'C:\\RooBuild\\inline-limit-' + uuid.uuid4().hex
        p = w.ps_literal
        w.invoke(host, machine, w.REMOTE_GUARDS + f"\nif([Security.Principal.WindowsIdentity]::GetCurrent().User.Value -cne {p(args.expected_sid)}){{throw 'SID differs'}};New-ProtectedFrame {p(frame)}")
        proof['frame'] = frame
        boundary = sized(f"[IO.File]::WriteAllText({p(frame + '/boundary.txt')},'MAX');'PASS exact inline boundary'\n", 65536)
        started = time.monotonic()
        boundary_result = w.invoke(host, machine, boundary)
        assert 'PASS exact inline boundary' in boundary_result.stdout
        proof['checks'].append({'bytes': len((guard + boundary).encode()), 'accepted': True, 'seconds': time.monotonic() - started})
        bulk = sized(f"[IO.File]::WriteAllText({p(frame + '/bulk.txt')},'FILE');'PASS protected bulk file'\n", 178205)
        payload = args.out / 'bulk.ps1'
        payload.write_text(guard + bulk)
        digest = hashlib.sha256(payload.read_bytes()).hexdigest()
        remote = frame.replace('\\', '/') + '/bulk.ps1'
        subprocess.run(['scp', *w.SSH_OPTIONS, str(payload), host + ':' + remote], capture_output=True, text=True, check=True)
        result = w.invoke(host, machine, w.REMOTE_GUARDS + f"\nAssert-ProtectedFrame {p(frame)};if((Get-FileHash -LiteralPath {p(remote)}).Hash -ine {p(digest)}){{throw 'Bulk hash differs'}};& {p(remote)};if([IO.File]::ReadAllText({p(frame + '/boundary.txt')}) -cne 'MAX' -or [IO.File]::ReadAllText({p(frame + '/bulk.txt')}) -cne 'FILE'){{throw 'Markers differ'}};'PASS both native markers'")
        assert 'PASS both native markers' in result.stdout and 'PASS protected bulk file' in result.stdout
        proof['checks'].append({'fileBytes': payload.stat().st_size, 'fileHash': digest, 'accepted': True})
    proof['passed'] = True
finally:
    (args.out / 'proof.json').write_text(json.dumps(proof, indent=2))
print(json.dumps(proof, indent=2))
