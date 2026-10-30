import argparse
import ast
import base64
import hashlib
import importlib.util
import json
import re
import selectors
import subprocess
import sys
import time
import uuid
from pathlib import Path

root = Path(__file__).resolve().parents[3]
parser = argparse.ArgumentParser()
parser.add_argument('--out', type=Path, required=True)
parser.add_argument('--receipt', type=Path, required=True)
parser.add_argument('--host', required=True)
parser.add_argument('--expected-machine', required=True)
parser.add_argument('--expected-sid', required=True)
parser.add_argument('--original', type=Path)
parser.add_argument('--case', action='append', help='Run only the named scenario (repeatable)')
parser.add_argument('--payload-from', type=Path, help='Replay a retained harmless canary command artifact')
parser.add_argument('--framing', choices=('production', 'eof', 'line'), default='production')
args = parser.parse_args()
out = args.out.resolve()
out.mkdir(parents=True, exist_ok=False)
spec = importlib.util.spec_from_file_location('windows_ssh', root / 'tools/validation/windows_ssh.py')
t = importlib.util.module_from_spec(spec)
spec.loader.exec_module(t)
receipt = json.loads(args.receipt.read_text())
t.validate_receipt(args.expected_machine, receipt)
if receipt['sid'] != args.expected_sid:
    raise ValueError('Receipt SID differs')
if args.host.startswith('-') or any(c.isspace() for c in args.host):
    raise ValueError('Unsafe host')
p = t.ps_literal
helper = receipt['stagingPath'] + '/tools/validation/LoadTimes/CleanupOwnership.Common.ps1'
scope = (
    "$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue';"
    f"if($env:COMPUTERNAME -ine {p(args.expected_machine)}){{throw 'Machine differs'}};"
    f"if([Security.Principal.WindowsIdentity]::GetCurrent().User.Value -cne {p(args.expected_sid)}){{throw 'SID differs'}};"
)


def ssh_command(script):
    encoded = base64.b64encode(script.encode('utf-16le')).decode()
    command = 'powershell.exe -NoProfile -NonInteractive -OutputFormat Text -ExecutionPolicy Bypass -EncodedCommand ' + encoded
    return ['ssh', '-T', *t.SSH_OPTIONS, args.host, command]


def direct(script):
    command = ssh_command(scope + script)
    result = subprocess.run(command, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=12)
    with (out / 'setup.jsonl').open('a') as log:
        log.write(json.dumps({'command': command, 'exit': result.returncode, 'stdout': result.stdout, 'stderr': result.stderr}) + '\n')
    result.check_returncode()
    return result.stdout


direct(t.REMOTE_GUARDS + f"\n$m=Assert-SourceSnapshot {p(receipt['stagingPath'])} {p(receipt['manifestSha256'])};'source verified'")
cases = []
if args.original:
    original_bytes = args.original.read_bytes()
    original = original_bytes.decode('utf-8')
    expected_hash = '0bc9e9dc9ad04443337f7e113c3783c37a6b2bcb95fd2cd008e6c9a66499c86d'
    if len(original_bytes) != 5446 or hashlib.sha256(original_bytes).hexdigest() != expected_hash:
        raise ValueError('Original payload bytes differ')
    original_out = re.search(r"^\$out='([^']+)'$", original, re.M).group(1)
    if original.index('New-ProtectedFrame $out') > original.index("$project=Join-Path"):
        raise ValueError('Output refusal is after build setup')
    proof = json.loads(direct(t.REMOTE_GUARDS + f"\nAssert-ProtectedFrame {p(original_out)};@{{exists=[IO.Directory]::Exists({p(original_out)});output={p(original_out)}}}|ConvertTo-Json -Compress"))
    if not proof['exists']:
        raise ValueError('Original output absent; replay forbidden')
    (out / 'replay-safety.json').write_text(json.dumps(proof, indent=2))
    cases.extend([('original', 'direct', original, False), ('original-newline', 'direct', original, True), ('original-file', 'direct', original, False)])

for profile, target, body_target in [('direct', 5446, False), ('direct', 5446, True), ('direct', 65536, False), ('outer-powershell', 5446, False), ('outer-powershell', 5446, True), ('outer-powershell', 65536, False)]:
    cases.append((f'{profile}-{target}-' + ('body' if body_target else 'guarded'), profile, (target, body_target), False))
if args.case:
    missing = set(args.case) - {case[0] for case in cases}
    if missing:
        raise ValueError('Unknown scenarios: ' + ', '.join(sorted(missing)))
    cases = [case for case in cases if case[0] in args.case]

guard = (
    "$ErrorActionPreference='Stop'; $ProgressPreference='SilentlyContinue'\n"
    f"if ($env:COMPUTERNAME -ine {p(args.expected_machine)}) {{throw 'Unexpected Windows computer'}}\n"
)
invoke_tree = next(node for node in ast.parse((root / 'tools/validation/windows_ssh.py').read_text()).body if isinstance(node, ast.FunctionDef) and node.name == 'invoke')
original_bootstrap = next(ast.literal_eval(node.value) for node in invoke_tree.body if isinstance(node, ast.Assign) and any(isinstance(target, ast.Name) and target.id == 'bootstrap' for target in node.targets))
bootstrap = original_bootstrap
if args.framing == 'line':
    bootstrap = bootstrap.replace('[Console]::In.ReadToEnd()', '[Console]::In.ReadLine()')
elif args.framing == 'eof':
    bootstrap = bootstrap.replace('[Console]::In.ReadLine()', '[Console]::In.ReadToEnd()')
line_framing = '[Console]::In.ReadLine()' in bootstrap
if args.payload_from:
    retained = json.loads(args.payload_from.read_text())
    payload = base64.b64decode(retained['stdin'], validate=True).decode('utf-8')
    if not payload.startswith(guard):
        raise ValueError('Retained payload machine guard differs')
    script = payload[len(guard):]
    harmless = re.fullmatch(r"\[IO.File\]::WriteAllText\('([^']+)',\s*'harmless payload evaluated'\);'PASS payload evaluated';Start-Sleep -Milliseconds 500\n *", script)
    if not harmless or not re.fullmatch(re.escape(receipt['runRoot']) + r'/transport-[0-9a-f]{32}/evaluated\.txt', harmless.group(1)):
        raise ValueError('Only the retained harmless canary can be replayed')
    direct(t.REMOTE_GUARDS + f'\nAssert-ProtectedFrame {p(harmless.group(1).rsplit("/", 1)[0])}')
    cases = [(f'replay-{index}-' + ('newline' if newline else 'exact'), 'outer-powershell', script, newline) for index in range(3) for newline in (False, True)]
results = []
for name, profile, script, newline in cases:
    frame = receipt['runRoot'] + '/transport-' + uuid.uuid4().hex
    direct(t.REMOTE_GUARDS + f'\nNew-ProtectedFrame {p(frame)}')
    if name == 'original-file':
        destination = frame + '/payload.ps1'
        content = base64.b64encode(script.encode('utf-8')).decode()
        observed_hash = direct(t.REMOTE_GUARDS + f"\nAssert-ProtectedFrame {p(frame)};$bytes=[Convert]::FromBase64String({p(content)});$file=[IO.FileStream]::new({p(destination)},[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read);try{{$file.Write($bytes,0,$bytes.Length);$file.Flush($true)}}finally{{$file.Dispose()}};(Get-FileHash -LiteralPath {p(destination)} -Algorithm SHA256).Hash").strip()
        if observed_hash.lower() != hashlib.sha256(script.encode('utf-8')).hexdigest():
            raise ValueError('Protected file bytes differ')
        script = '& ' + p(destination)
    if isinstance(script, tuple):
        target, body_target = script
        script = f"[IO.File]::WriteAllText({p(frame + '/evaluated.txt')},'harmless payload evaluated');'PASS payload evaluated';Start-Sleep -Milliseconds 500\n"
        script += ' ' * (target - len((script if body_target else guard + script).encode()))
        assert len((script if body_target else guard + script).encode()) == target
    evaluated_path = harmless.group(1) if args.payload_from else frame + '/evaluated.txt'
    token = base64.b64encode((bootstrap + '\n# ' + uuid.uuid4().hex).encode('utf-16le')).decode()
    command = t.REMOTE_INPUT + 'powershell.exe -NoProfile -NonInteractive -OutputFormat Text -ExecutionPolicy Bypass -EncodedCommand ' + token
    if profile == 'outer-powershell':
        command = 'powershell.exe -NoProfile -NonInteractive -Command "' + command.replace('$', '`$') + '"'
    wire = base64.b64encode((guard + script).encode()).decode() + ('\n' if newline or line_framing else '')
    controller_script = scope + f". {p(helper)};$frame={p(frame)};$token={p(token)};$evaluated={p(evaluated_path)};" + r'''
$held=@{};$rows=@();$lower=[DateTime]::UtcNow.ToFileTimeUtc();$deadline=[DateTime]::UtcNow.AddSeconds(14)
$expected=[RooIndustriesValidationOwnership.Native]::Canonical((Join-Path ([Environment]::SystemDirectory) 'WindowsPowerShell\v1.0\powershell.exe'))
$outerImage=[RooIndustriesValidationOwnership.Native]::Canonical((Join-Path ([Environment]::SystemDirectory) 'cmd.exe'))
$childSuffix=' -NoProfile -NonInteractive -OutputFormat Text -ExecutionPolicy Bypass -EncodedCommand '+$token
[Console]::Out.WriteLine('READY');[Console]::Out.Flush()
try {
 while([DateTime]::UtcNow -lt $deadline){
  foreach($row in @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='cmd.exe'")){
   if($row.ProcessId -eq $PID -or -not $row.CommandLine -or $row.CommandLine -notmatch ('(?i)-EncodedCommand\s+'+[regex]::Escape($token)+'(?=[\s"'']|$)')){continue}
   $process=Get-Process -Id $row.ProcessId -ErrorAction SilentlyContinue
   if(-not$process){continue}
   $owned=New-OwnedProcess $process
   if(-not$owned){$process.Dispose();continue}
   $id=$owned.Identity
   $again=Get-CimInstance Win32_Process -Filter ('ProcessId='+$id.pid)
   if(-not$again -or $again.CommandLine -cne $row.CommandLine -or $again.CreationDate -ne $row.CreationDate -or $process.HasExited){$process.Dispose();continue}
   if([long]$id.creationTimeFileTimeUtc -lt $lower -or [long]$id.creationTimeFileTimeUtc -gt $deadline.ToFileTimeUtc() -or $id.imagePath -notin @($expected,$outerImage)){$process.Dispose();throw 'Candidate native scope differs'}
   $key=$id.pid.ToString()+':'+$id.creationTimeFileTimeUtc
   if($held.ContainsKey($key)){$process.Dispose();continue}
   $held[$key]=$owned;$rows+=@([pscustomobject]@{identity=$id;commandLine=$row.CommandLine;parentPid=$row.ParentProcessId;inner=($id.imagePath -ieq $expected -and $row.CommandLine.EndsWith($childSuffix,[StringComparison]::Ordinal))})
   ConvertTo-Json -InputObject @($rows) -Depth 8|Set-Content -LiteralPath (Join-Path $frame 'receipts.json')
  }
  if($held.Count -ge 2 -and @($held.Values|Where-Object {-not$_.process.HasExited}).Count -eq 0){break}
  Start-Sleep -Milliseconds 50
 }
} finally {
 foreach($owned in $held.Values){Stop-OwnedProcess $owned}
 $left=@($held.Values|Where-Object {-not$_.process.HasExited}|ForEach-Object {$_.Identity})
 $report=[pscustomobject]@{receipts=$rows;leftovers=$left;lowerFileTime=$lower.ToString();upperFileTime=$deadline.ToFileTimeUtc().ToString();evaluated=[IO.File]::Exists($evaluated);evaluatedPath=$evaluated}
 $report|ConvertTo-Json -Depth 12 -Compress|Set-Content -LiteralPath (Join-Path $frame 'controller.json')
 $report|ConvertTo-Json -Depth 12 -Compress
 foreach($owned in $held.Values){$owned.process.Dispose()}
}
'''
    controller_command = ssh_command(controller_script)
    controller = subprocess.Popen(controller_command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    ready = selectors.DefaultSelector()
    ready.register(controller.stdout, selectors.EVENT_READ)
    if not ready.select(12) or controller.stdout.readline().strip() != 'READY':
        controller.kill()
        stdout, stderr = controller.communicate(timeout=5)
        raise RuntimeError('Controller not ready: ' + stdout + stderr)
    ready.close()
    started = time.monotonic()
    error = None
    target_command = ['ssh', '-T', *t.SSH_OPTIONS, args.host, command]
    saved_run = subprocess.run
    saved_encode = base64.b64encode

    def identify(data):
        return token.encode('ascii') if data == original_bootstrap.encode('utf-16le') else saved_encode(data)

    def bounded(actual_command, **kwargs):
        if actual_command[-1] != t.REMOTE_INPUT + 'powershell.exe -NoProfile -NonInteractive -OutputFormat Text -ExecutionPolicy Bypass -EncodedCommand ' + token or kwargs['input'].rstrip('\n') != wire.rstrip('\n'):
            raise ValueError('Actual invoke transport differs from the retained reproduction')
        kwargs['input'] = wire
        kwargs['timeout'] = 12
        return saved_run(target_command, **kwargs)

    try:
        t.base64.b64encode = identify
        t.subprocess.run = bounded
        result = t.invoke(args.host, args.expected_machine, script)
        target_output = {'exit': result.returncode, 'stdout': result.stdout, 'stderr': result.stderr}
    except subprocess.TimeoutExpired as exc:
        error = 'target timeout after 12 seconds'
        target_output = {'exit': None, 'stdout': (exc.stdout or b'').decode(), 'stderr': (exc.stderr or b'').decode()}
    except subprocess.CalledProcessError as exc:
        target_output = {'exit': exc.returncode, 'stdout': exc.stdout, 'stderr': exc.stderr}
    finally:
        t.base64.b64encode = saved_encode
        t.subprocess.run = saved_run
    elapsed = time.monotonic() - started
    try:
        native_stdout, native_stderr = controller.communicate(timeout=20)
    except subprocess.TimeoutExpired:
        controller.kill()
        controller.communicate(timeout=5)
        raise RuntimeError('Controller exceeded its bound; inspect retained receipts before further work')
    native = json.loads(native_stdout.strip().splitlines()[-1])
    expected = target_output['exit'] == 1 and 'Existing source frame retained; allocate another GUID' in target_output['stderr'] if name.startswith('original') else target_output['exit'] == 0 and 'PASS payload evaluated' in target_output['stdout'] and native['evaluated']
    children = [row for row in native['receipts'] if row['inner']]
    chain_proven = len(children) == 1 and any(row['identity']['pid'] == children[0]['parentPid'] for row in native['receipts'])
    passed = error is None and expected and controller.returncode == 0 and chain_proven and not native['leftovers']
    entry = {'name': name, 'profile': profile, 'scriptUtf8Bytes': len(script.encode()), 'guardedUtf8Bytes': len((guard + script).encode()), 'wireBytes': len(wire), 'wireSha256': hashlib.sha256(wire.encode()).hexdigest(), 'newline': newline, 'elapsedSeconds': round(elapsed, 3), 'error': error, 'frame': frame, 'target': target_output, 'native': native, 'controllerStderr': native_stderr, 'passed': passed}
    (out / (name + '-command.json')).write_text(json.dumps({'target': target_command, 'controller': controller_command, 'stdin': wire}, indent=2))
    (out / (name + '-native.json')).write_text(json.dumps(entry, indent=2))
    results.append(entry)
    (out / 'checks.json').write_text(json.dumps(results, indent=2))
    print(json.dumps({key: entry[key] for key in ('name', 'wireBytes', 'elapsedSeconds', 'error', 'passed')}), flush=True)
sys.exit(int(any(not row['passed'] for row in results)))
