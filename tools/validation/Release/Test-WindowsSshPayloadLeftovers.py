import argparse
import base64
import hashlib
import importlib.util
import json
import re
import subprocess
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('--host', required=True)
parser.add_argument('--expected-machine', required=True)
parser.add_argument('--receipt', type=Path, required=True)
parser.add_argument('--evidence', type=Path, action='append', required=True)
parser.add_argument('--out', type=Path, required=True)
args = parser.parse_args()
root = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location('windows_ssh', root / 'tools/validation/windows_ssh.py')
t = importlib.util.module_from_spec(spec)
spec.loader.exec_module(t)
receipt = json.loads(args.receipt.read_text())
t.validate_receipt(args.expected_machine, receipt)
if args.host.startswith('-') or any(c.isspace() for c in args.host):
    raise ValueError('Unsafe host')
tokens = set()
identities = {}


def add_command(command):
    tokens.update(hashlib.sha256(token.encode('ascii')).hexdigest() for token in re.findall(r'-EncodedCommand\s+([A-Za-z0-9+/=]+)', command[-1]))


for directory in args.evidence:
    for path in directory.glob('*-command.json'):
        artifact = json.loads(path.read_text())
        add_command(artifact['target'])
        add_command(artifact['controller'])
    for line in (directory / 'setup.jsonl').read_text().splitlines():
        add_command(json.loads(line)['command'])
    for row in json.loads((directory / 'checks.json').read_text()):
        for observed in row['native']['receipts']:
            identity = observed['identity']
            identities[(identity['pid'], identity['creationTimeFileTimeUtc'])] = identity
p = t.ps_literal
helper = receipt['stagingPath'] + '/tools/validation/LoadTimes/CleanupOwnership.Common.ps1'
helper_hash = hashlib.sha256((root / 'tools/validation/LoadTimes/CleanupOwnership.Common.ps1').read_bytes()).hexdigest()
checks = []
hashes = sorted(tokens)
ids = list(identities.values())
for offset in range(0, max(len(hashes), len(ids)), 20):
    script = "$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue';" + f"if($env:COMPUTERNAME -ine {p(args.expected_machine)} -or [Security.Principal.WindowsIdentity]::GetCurrent().User.Value -cne {p(receipt['sid'])}){{throw 'Scope differs'}};" + t.REMOTE_GUARDS
    script += f"\nAssert-ProtectedFrame {p(receipt['stagingPath'])};Assert-PlainAncestry {p(helper)};if((Get-FileHash -LiteralPath {p(helper)} -Algorithm SHA256).Hash -ine {p(helper_hash)}){{throw 'Helper differs'}};. {p(helper)};$hashes={p(json.dumps(hashes[offset:offset + 20]))}|ConvertFrom-Json;$ids={p(json.dumps(ids[offset:offset + 20]))}|ConvertFrom-Json;" + r'''
$found=@();$sha=[Security.Cryptography.SHA256]::Create()
try {
 foreach($row in @(Get-CimInstance Win32_Process)){
  if(-not$row.CommandLine){continue}
  foreach($m in [regex]::Matches($row.CommandLine,'(?i)-EncodedCommand\s+([A-Za-z0-9+/=]+)')){
   $hash=([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::ASCII.GetBytes($m.Groups[1].Value)))).Replace('-','').ToLowerInvariant()
   if($hashes -notcontains $hash){continue}
   $process=Get-Process -Id $row.ProcessId -ErrorAction SilentlyContinue
   if($process){try{$owned=New-OwnedProcess $process;if($owned){$found+=@($owned.Identity)}}finally{$process.Dispose()}}
  }
 }
 foreach($id in $ids){
  $process=Get-Process -Id $id.pid -ErrorAction SilentlyContinue
  if(-not$process){continue}
  try{$owned=New-OwnedProcess $process;if($owned -and $owned.Identity.creationTimeFileTimeUtc -ceq $id.creationTimeFileTimeUtc -and $owned.Identity.imagePath -ieq $id.imagePath){$found+=@($owned.Identity)}}finally{$process.Dispose()}
 }
 @{leftovers=$found;tokensChecked=@($hashes).Count;identitiesChecked=@($ids).Count}|ConvertTo-Json -Depth 8 -Compress
} finally {$sha.Dispose()}
'''
    command = ['ssh', '-T', *t.SSH_OPTIONS, args.host, 'powershell.exe -NoProfile -NonInteractive -OutputFormat Text -ExecutionPolicy Bypass -EncodedCommand ' + base64.b64encode(script.encode('utf-16le')).decode()]
    result = subprocess.run(command, stdin=subprocess.DEVNULL, text=True, capture_output=True, timeout=12)
    result.check_returncode()
    observed = json.loads(result.stdout)
    checks.append({'command': command, 'exit': result.returncode, 'stdout': result.stdout, 'stderr': result.stderr, 'observed': observed})
report = {'tokenCount': len(tokens), 'nativeIdentityCount': len(identities), 'checks': checks, 'passed': all(not check['observed']['leftovers'] for check in checks)}
with args.out.open('x') as output:
    json.dump(report, output, indent=2)
print(json.dumps({key: report[key] for key in ('tokenCount', 'nativeIdentityCount', 'passed')}))
raise SystemExit(int(not report['passed']))
