from __future__ import annotations

import argparse
import base64
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import subprocess
import uuid

ROOT = Path(__file__).resolve().parents[3]
SPEC = importlib.util.spec_from_file_location('historical_windows_ssh', ROOT / 'tools/validation/windows_ssh.py')
WIN = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(WIN)
HOST = 'blackwell-lan'
MACHINE = 'CS2-GEN4'
SID = 'S-1-5-21-1846494563-3099854232-4004002307-1001'


def invoke(script):
    return WIN.invoke(HOST, MACHINE, f"if([Security.Principal.WindowsIdentity]::GetCurrent().User.Value -cne '{SID}'){{throw 'Wrong SID'}}\n" + script)


def prepare():
    frame = 'C:\\ProgramData\\RooRecoveryBlackwell-' + uuid.uuid4().hex
    paths = {
        'runner.ps1': ROOT / 'tools/validation/Release/Invoke-IntegrationVerification.ps1',
        'ownership.ps1': ROOT / 'tools/validation/LoadTimes/CleanupOwnership.Common.ps1',
    }
    for name in ('HistoricalBlackwell.Common.ps1', 'Invoke-HistoricalBlackwell.ps1', 'Test-HistoricalBlackwell.ps1', 'Probe-HistoricalBlackwell.ps1', 'Stage-HistoricalBlackwell.ps1'):
        paths[name] = ROOT / 'tools/validation/Release' / name
    contents = {n: p.read_bytes() for n, p in paths.items()}
    data = base64.b64encode(contents['runner.ps1']).decode()
    script = f"$runner=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('{data}')).TrimStart([char]0xfeff);$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseInput($runner,[ref]$tokens,[ref]$errors);if($errors.Count){{$errors|ForEach-Object {{$_.Message}};throw 'Runner parse failed'}}\n"
    script += "foreach($name in 'Assert-PlainRecoveryPath','New-SealedDirectory','Assert-SealedRecovery'){ $node=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$true));if($node.Count -ne 1){throw 'Bootstrap helper missing'};. ([scriptblock]::Create($node[0].Extent.Text))}\n"
    script += f"$backup={WIN.ps_literal(frame)};New-SealedDirectory $backup\n"
    manifest = {n: hashlib.sha256(b).hexdigest().upper() for n, b in contents.items()}
    for name, content in contents.items():
        script += f"$bytes=[Convert]::FromBase64String('{base64.b64encode(content).decode()}');$path=Join-Path $backup '{name}';$file=[IO.File]::Open($path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None);try{{$file.Write($bytes,0,$bytes.Length);$file.Flush($true)}}finally{{$file.Dispose()}}\n"
    script += "Assert-SealedRecovery $backup;'prepared'"
    receipt = {'frame': frame, 'machine': MACHINE, 'sid': SID, 'files': manifest}
    out = ROOT / 'artifacts/continuation/blackwell-historical-frame.json'
    if out.exists():
        out = out.with_name('blackwell-historical-frame-' + frame.rsplit('-', 1)[1] + '.json')
    out.write_text(json.dumps(receipt, indent=2) + '\n')
    try:
        invoke(script)
    except subprocess.CalledProcessError as error:
        out.with_suffix('.failure.log').write_text((error.stdout or '') + (error.stderr or ''))
        print((error.stdout or '') + (error.stderr or ''))
        raise SystemExit(error.returncode)
    print(json.dumps({'receipt': str(out), **receipt}, indent=2))
    return out


def refresh(receipt_path):
    receipt = json.loads(Path(receipt_path).read_text())
    frame = receipt['frame']
    if not re.fullmatch(r'C:\\ProgramData\\RooRecoveryBlackwell-[a-f0-9]{32}', frame):
        raise ValueError('Wrong existing frame')
    directory = 'code-' + uuid.uuid4().hex
    script = WIN.REMOTE_GUARDS + f"\nNew-ProtectedFrame {WIN.ps_literal(frame + '/' + directory)}\n"
    files = receipt['files'].copy()
    for name in ('HistoricalBlackwell.Common.ps1', 'Invoke-HistoricalBlackwell.ps1', 'Test-HistoricalBlackwell.ps1', 'Probe-HistoricalBlackwell.ps1', 'Stage-HistoricalBlackwell.ps1'):
        data = (ROOT / 'tools/validation/Release' / name).read_bytes()
        relative = directory + '/' + name
        encoded = base64.b64encode(data).decode()
        script += f"$b=[Convert]::FromBase64String('{encoded}');$f=[IO.File]::Open({WIN.ps_literal(frame + '/' + relative)},[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None);try{{$f.Write($b,0,$b.Length);$f.Flush($true)}}finally{{$f.Dispose()}}\n"
        files[relative] = hashlib.sha256(data).hexdigest().upper()
    invoke(script)
    updated = {**receipt, 'codeDir': directory, 'files': files}
    output = Path(receipt_path).with_name('blackwell-historical-active-frame-' + directory[5:] + '.json')
    output.write_text(json.dumps(updated, indent=2) + '\n')
    print(output)
    return output


def run(receipt_path, phase, capture_hash='', stage_hash='', seconds=300):
    receipt = json.loads(Path(receipt_path).read_text())
    frame = receipt['frame']
    if not re.fullmatch(r'C:\\ProgramData\\RooRecoveryBlackwell-[a-f0-9]{32}', frame) or receipt['machine'] != MACHINE or receipt['sid'] != SID:
        raise ValueError('Wrong bounded historical frame receipt')
    if phase not in ('Capture', 'Stage', 'Verify', 'Diagnose', 'Test', 'TestPrepared', 'Probe') or seconds < 1 or seconds > 600:
        raise ValueError('Driver never executes live Restore; phase/deadline invalid')
    for value in (capture_hash, stage_hash):
        if value and not re.fullmatch('[A-F0-9]{64}', value):
            raise ValueError('Invalid bound hash')
    run_id = phase.lower() + '-' + uuid.uuid4().hex
    code_path = frame + '/' + receipt.get('codeDir', '')
    command = f"$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue';try{{& {WIN.ps_literal(code_path + '/' + ('Test-HistoricalBlackwell.ps1' if phase in ('Test', 'TestPrepared') else 'Probe-HistoricalBlackwell.ps1' if phase == 'Probe' else 'Invoke-HistoricalBlackwell.ps1'))} -Frame {WIN.ps_literal(frame)} -Runner {WIN.ps_literal(frame + '/runner.ps1')}"
    if phase == 'TestPrepared':
        command += ' -PreparedPrivateOnly'
    if phase not in ('Test', 'TestPrepared', 'Probe'):
        command += f" -Phase '{phase}' -CaptureHash '{capture_hash}' -StageHash '{stage_hash}'"
    command += ";exit 0}catch{Write-Output ('FAIL '+$_.Exception.Message);Write-Output $_.ScriptStackTrace;exit 1}"
    encoded = base64.b64encode(command.encode('utf-16le')).decode()
    script = f"$frame={WIN.ps_literal(frame)};$run='{run_id}';\n"
    for name, digest in receipt['files'].items():
        if not re.fullmatch('[A-Za-z0-9./-]+', name) or '..' in name.split('/') or not re.fullmatch('[A-F0-9]{64}', digest):
            raise ValueError('Invalid source manifest')
        script += f"if((Get-FileHash -LiteralPath (Join-Path $frame '{name}')).Hash -cne '{digest}'){{throw 'Historical source hash changed'}}\n"
    script += "$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $frame 'runner.ps1'),[ref]$tokens,[ref]$errors);foreach($name in 'Assert-PlainRecoveryPath','New-SealedDirectory','Assert-SealedRecovery'){$node=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$true));. ([scriptblock]::Create($node[0].Extent.Text))};Assert-SealedRecovery $frame\n"
    script += "$compiler=Join-Path $frame ('controller-compiler-'+[Guid]::NewGuid().ToString('N'));New-SealedDirectory $compiler;$oldTemp=$env:TEMP;$oldTmp=$env:TMP;try{$env:TEMP=$compiler;$env:TMP=$compiler;. (Join-Path $frame 'ownership.ps1')}finally{$env:TEMP=$oldTemp;$env:TMP=$oldTmp}\n"
    script += "$controller=New-OwnedProcess (Get-Process -Id $PID);$controller.Identity|ConvertTo-Json -Compress|Set-Content -LiteralPath (Join-Path $frame ($run+'-controller.json'))\n"
    script += f"$child=Start-Process -FilePath (Join-Path ([Environment]::SystemDirectory) 'WindowsPowerShell\\v1.0\\powershell.exe') -ArgumentList '-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand {encoded}' -RedirectStandardOutput (Join-Path $frame ($run+'.stdout.log')) -RedirectStandardError (Join-Path $frame ($run+'.stderr.log')) -PassThru;$owned=New-OwnedProcess $child;$owned.Identity|ConvertTo-Json -Compress|Set-Content -LiteralPath (Join-Path $frame ($run+'-child.json'))\n"
    script += f"$timedOut=$false;try{{if(-not$child.WaitForExit({seconds * 1000})){{$timedOut=$true;Stop-OwnedProcess $owned}};$child.Refresh();$code=$child.ExitCode;@{{phase='{phase}';run=$run;frame=$frame;child=$owned.Identity;timedOut=$timedOut;exit=$code;workingSetPeak=$child.PeakWorkingSet64;cpuMs=$child.TotalProcessorTime.TotalMilliseconds;childExited=$child.HasExited}}|ConvertTo-Json -Depth 5|Set-Content -LiteralPath (Join-Path $frame ($run+'-receipt.json'));[IO.File]::ReadAllText((Join-Path $frame ($run+'.stdout.log')));[IO.File]::ReadAllText((Join-Path $frame ($run+'.stderr.log')));[IO.File]::ReadAllText((Join-Path $frame ($run+'-receipt.json')));if($timedOut -or $code -ne 0){{throw 'Historical child failed; exact receipt and logs retained'}}}}finally{{if(-not$child.HasExited){{Stop-OwnedProcess $owned}};$child.Dispose();$controller.process.Dispose()}}"
    try:
        result = invoke(script)
        stdout, stderr, code = result.stdout, result.stderr, result.returncode
    except subprocess.CalledProcessError as error:
        stdout, stderr, code = error.stdout or '', error.stderr or '', error.returncode
    output = ROOT / 'artifacts/continuation' / ('blackwell-historical-' + run_id + '.log')
    output.write_text(stdout + stderr)
    print(str(output))
    print(stdout + stderr)
    if code:
        raise SystemExit(code)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('phase', choices=['prepare', 'refresh', 'Capture', 'Stage', 'Verify', 'Diagnose', 'Test', 'TestPrepared', 'Probe'])
    parser.add_argument('--receipt')
    parser.add_argument('--capture-hash', default='')
    parser.add_argument('--stage-hash', default='')
    parser.add_argument('--seconds', type=int, default=300)
    args = parser.parse_args()
    if args.phase == 'prepare':
        prepare()
    elif args.phase == 'refresh':
        if not args.receipt:
            parser.error('--receipt required')
        refresh(args.receipt)
    else:
        if not args.receipt:
            parser.error('--receipt required')
        run(args.receipt, args.phase, args.capture_hash, args.stage_hash, args.seconds)
