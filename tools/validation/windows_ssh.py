"""Inspect, stage, and validate a Windows development host directly over SSH."""
from __future__ import annotations

import argparse
import base64
import hashlib
import io
import json
from pathlib import Path, PureWindowsPath
import re
import subprocess
import tarfile
import tempfile
import uuid


SSH_OPTIONS = [
    '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=8',
    '-o', 'ServerAliveInterval=15', '-o', 'ServerAliveCountMax=2',
    '-o', 'ProxyCommand=none', '-o', 'ProxyJump=none',
]


def ps_literal(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


def invoke(host: str, machine: str, script: str, capture: bool = True):
    guarded = (
        "$ErrorActionPreference='Stop'; $ProgressPreference='SilentlyContinue'\n"
        f"if ($env:COMPUTERNAME -ine {ps_literal(machine)}) {{throw 'Unexpected Windows computer'}}\n"
        + script
    )
    payload = guarded.encode('utf-8')
    if len(payload) > 65536:
        raise ValueError('Inline Windows SSH scripts are limited to 65536 UTF-8 bytes; transfer bulk data to a protected file and invoke its verified path.')
    bootstrap = (
        "$ErrorActionPreference='Stop';[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false);$OutputEncoding=[Console]::OutputEncoding;try{"
        "$a=[AppDomain]::CurrentDomain.DefineDynamicAssembly([Reflection.AssemblyName]::new('S'),1);$b=$a.DefineDynamicModule('S').DefineType('RooSshLifetime',385);$ready=$b.DefineField('Ready',[bool],22);"
        "$m=$b.DefinePInvokeMethod('Info','ntdll.dll','NtQueryInformationProcess',8214,1,[int],[type[]]@([IntPtr],[int],[IntPtr],[int],[int].MakeByRefType()),1,3);$m.SetImplementationFlags(128);"
        "$d=[Diagnostics.Process];$m=$b.DefineMethod('Watch',22,[void],[type[]]@($d));$il=$m.GetILGenerator();$loop=$il.DefineLabel();$quit=$il.DefineLabel();$count=$il.DeclareLocal([int]);$o=[Reflection.Emit.OpCodes];$il.Emit($o::Ldc_I4,20);$il.Emit($o::Stloc_0);$il.MarkLabel($loop);"
        "$il.Emit($o::Ldarg_0);$il.Emit($o::Ldc_I4,250);$il.Emit($o::Callvirt,$d.GetMethod('WaitForExit',[type[]]@([int])));$il.Emit($o::Brtrue,$quit);$il.Emit($o::Volatile);$il.Emit($o::Ldsfld,$ready);$il.Emit($o::Brtrue,$loop);"
        "$il.Emit($o::Ldloc_0);$il.Emit($o::Ldc_I4_1);$il.Emit($o::Sub);$il.Emit($o::Stloc_0);$il.Emit($o::Ldloc_0);$il.Emit($o::Ldc_I4_0);$il.Emit($o::Bgt,$loop);$il.MarkLabel($quit);"
        "$il.Emit($o::Ldc_I4_1);$il.Emit($o::Call,[Environment].GetMethod('Exit',[type[]]@([int])));$il.Emit($o::Ret);$native=$b.CreateType();"
        "$child=$d::GetCurrentProcess();$ssh=$null;$size=[IntPtr]::Size*6;$z=[Runtime.InteropServices.Marshal];$buf=$z::AllocHGlobal($size);"
        "try{for($i=0;$i -lt 12;$i++){[int]$written=0;if([RooSshLifetime]::Info($child.Handle,0,$buf,$size,[ref]$written) -ne 0 -or $written -ne $size){throw 'SSH ancestry unavailable'};"
        "$parent=$d::GetProcessById($z::ReadIntPtr($buf,[IntPtr]::Size*5).ToInt32());$held=$parent.Handle;if($parent.StartTime -gt $child.StartTime){throw 'SSH ancestor identity changed'};"
        "if([IO.Path]::GetFileName($parent.MainModule.FileName) -in 'sshd.exe','sshd-session.exe'){$ssh=$parent;break};$child=$parent}}finally{$z::FreeHGlobal($buf)};"
        "if(-not$ssh){throw 'SSH session ancestor missing'};$watch=[Threading.Thread]::new([Delegate]::CreateDelegate([Threading.ThreadStart],$ssh,$native.GetMethod('Watch')));$watch.IsBackground=$true;$watch.Start();"
        "$inputStream=[IO.BufferedStream]::new([Console]::OpenStandardInput(),4096);$line=[Text.StringBuilder]::new();"
        "while($true){$c=$inputStream.ReadByte();if($c -lt 0){throw 'SSH payload ended before newline'};if($c -eq 10){break};if($line.Length -ge 87384){throw 'SSH payload exceeds 65536 bytes'};[void]$line.Append([char]$c)};"
        "$native.GetField('Ready').SetValue($null,$true);$bytes=[Convert]::FromBase64String($line.ToString());if($bytes.Length -gt 65536){throw 'SSH payload exceeds 65536 bytes'};$s=[Text.Encoding]::UTF8.GetString($bytes);& ([scriptblock]::Create($s));if(-not$?){exit 1};exit 0"
        "}catch{[Console]::Error.WriteLine($_.Exception.Message.Substring(0,[Math]::Min(2048,$_.Exception.Message.Length)));exit 1}"
    )
    encoded = base64.b64encode(bootstrap.encode('utf-16le')).decode()
    command = 'powershell.exe -NoProfile -NonInteractive -OutputFormat Text -ExecutionPolicy Bypass -EncodedCommand ' + encoded
    return subprocess.run(['ssh', '-T', *SSH_OPTIONS, host, command],
                          input=base64.b64encode(payload).decode() + '\n',
                          capture_output=capture, text=True, encoding='utf-8', check=True)



def inspect(host: str, machine: str):
    script = (
        "$identity=[Security.Principal.WindowsIdentity]::GetCurrent(); "
        "@{machine=$env:COMPUTERNAME;user=$identity.Name;temp=[IO.Path]::GetTempPath();"
        "admin=[Security.Principal.WindowsPrincipal]::new($identity).IsInRole("
        "[Security.Principal.WindowsBuiltInRole]::Administrator)}|ConvertTo-Json -Compress"
    )
    return json.loads(invoke(host, machine, script).stdout)


REMOTE_GUARDS = r"""
function Assert-PlainAncestry([string]$Path) {
 $p=[IO.Path]::GetFullPath($Path)
 while($p){$i=Get-Item -LiteralPath $p -Force;if($i.Attributes -band [IO.FileAttributes]::ReparsePoint){throw ('Reparse ancestry: '+$p)};$p=[IO.Path]::GetDirectoryName($p)}
}
function Assert-ProtectedFrame([string]$Path) {
 Assert-PlainAncestry $Path
 $acl=Get-Acl -LiteralPath $Path
 if($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -notin 'S-1-5-18','S-1-5-32-544'){throw 'Source frame owner is not admin'}
 foreach($ace in $acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])){if($ace.AccessControlType -eq 'Allow' -and $ace.IdentityReference.Value -notin 'S-1-5-18','S-1-5-32-544' -and ([long]$ace.FileSystemRights -band 0x500D0156)){throw ('Source frame writable by '+$ace.IdentityReference.Value)}}
}
function New-ProtectedFrame([string]$Path,[string]$ReadSid) {
 if($PSBoundParameters.ContainsKey('ReadSid') -and $ReadSid -cne [Security.Principal.WindowsIdentity]::GetCurrent().User.Value){throw 'Source reader SID is not the current test user'}
 if(Test-Path -LiteralPath $Path){throw 'Existing source frame retained; allocate another GUID'}
 Assert-ProtectedFrame ([IO.Path]::GetDirectoryName($Path))
 $acl=[Security.AccessControl.DirectorySecurity]::new();$acl.SetAccessRuleProtection($true,$false);$acl.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))
 foreach($sid in 'S-1-5-18','S-1-5-32-544'){$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sid),'FullControl','ContainerInherit,ObjectInherit','None','Allow'))}
 $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new('S-1-3-4'),'ReadAndExecute','ContainerInherit,ObjectInherit','None','Allow'))
 if($PSBoundParameters.ContainsKey('ReadSid')){$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($ReadSid),'ReadAndExecute','ContainerInherit,ObjectInherit','None','Allow'))}
 [IO.Directory]::CreateDirectory($Path,$acl)|Out-Null
 Assert-ProtectedFrame $Path
}
function Assert-SourceSnapshot([string]$Source,[string]$Expected) {
 Assert-ProtectedFrame $Source
 $manifestPath=Join-Path $Source 'source-verification.json'
 if((Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash -ine $Expected){throw 'Source manifest receipt changed'}
 $m=Get-Content -Raw -LiteralPath $manifestPath|ConvertFrom-Json
 if($m.protocol -cne 'roo-industries-source-snapshot/v2' -or $m.machine -ine $env:COMPUTERNAME -or $m.sid -cne [Security.Principal.WindowsIdentity]::GetCurrent().User.Value){throw 'Source scope changed'}
 if(-not$m.files -or @($m.files.PSObject.Properties).Count -eq 0){throw 'Empty source manifest'}
 foreach($f in $m.files.PSObject.Properties){$p=[IO.Path]::GetFullPath((Join-Path $Source $f.Name));if(-not$p.StartsWith($Source.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Manifest traversal'};Assert-PlainAncestry $p;if((Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash -ine $f.Value){throw ('Staged bytes changed: '+$f.Name)}}
 return $m
}
"""


def validate_receipt(machine: str, receipt: dict):
    fields = ('machine', 'sid', 'frameId', 'runRoot', 'stagingPath', 'manifestSha256')
    if not isinstance(receipt, dict) or any(not isinstance(receipt.get(key), str) or not receipt[key] for key in fields):
        raise ValueError('Incomplete source frame receipt.')
    if receipt['machine'].casefold() != machine.casefold() or not re.fullmatch('[0-9a-f]{32}', receipt['frameId']) or not re.fullmatch('[0-9a-fA-F]{64}', receipt['manifestSha256']):
        raise ValueError('Source receipt identity differs.')
    source, frame = PureWindowsPath(receipt['stagingPath']), PureWindowsPath(receipt['runRoot'])
    if source.parent != frame or source.name != 'source' or not frame.name.endswith('-' + receipt['frameId']) or not frame.name.startswith('roo-industries-'):
        raise ValueError('Source paths are outside their retained GUID frame.')


def verify_source(host: str, machine: str, receipt: dict):
    validate_receipt(machine, receipt)
    invoke(host, machine, REMOTE_GUARDS + f"\n$m=Assert-SourceSnapshot {ps_literal(receipt['stagingPath'])} {ps_literal(receipt['manifestSha256'])}; 'source verified'")


def upload(host: str, machine: str, directory: str, include_frontend: bool = False,
           parent: str | None = None):
    if not re.fullmatch(r'roo-industries-[a-z0-9-]{1,70}', directory):
        raise ValueError('Use a roo-industries- prefixed source frame name.')
    if not parent:
        raise ValueError('Specify an existing verified admin-protected staging parent.')
    identity = inspect(host, machine)
    if not identity['admin']:
        raise ValueError('Protected staging requires an administrator token.')
    scope = json.loads(invoke(host, machine, "$i=[Security.Principal.WindowsIdentity]::GetCurrent();@{sid=$i.User.Value;system=[Environment]::SystemDirectory}|ConvertTo-Json -Compress").stdout)
    frame_id = uuid.uuid4().hex
    remote_root = parent.rstrip('\\/') + '\\' + directory + '-' + frame_id
    remote_source = remote_root + '\\source'
    root = Path(__file__).resolve().parents[2]
    names = subprocess.check_output(['git', 'ls-files', '-z', '--cached', '--others', '--exclude-standard'], cwd=root).decode().split('\0')
    files = sorted(set(name for name in names if name and (include_frontend or not name.startswith('docs/internal/frontend/')) and (root / name).is_file()))
    for name in files:
        if (root / name).is_symlink() or '..' in Path(name).parts or Path(name).is_absolute():
            raise ValueError('Unsafe snapshot source: ' + name)
    contents = {name: (root / name).read_bytes() for name in files}
    manifest = {
        'protocol': 'roo-industries-source-snapshot/v2', 'machine': identity['machine'],
        'sid': scope['sid'], 'frameId': frame_id,
        'commit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root).decode().strip(),
        'files': {name: hashlib.sha256(data).hexdigest() for name, data in contents.items()},
    }
    data = json.dumps(manifest, sort_keys=True).encode()
    receipt = {'machine': identity['machine'], 'sid': scope['sid'], 'frameId': frame_id,
               'runRoot': remote_root, 'stagingPath': remote_source,
               'manifestSha256': hashlib.sha256(data).hexdigest(),
               'sourceCommit': manifest['commit'], 'sourceFileCount': len(files),
               'frontendIncluded': include_frontend}
    invoke(host, machine, REMOTE_GUARDS + f"\nNew-ProtectedFrame {ps_literal(remote_root)};New-ProtectedFrame {ps_literal(remote_source)} {ps_literal(scope['sid'])}")
    with tempfile.TemporaryDirectory(prefix='roo-industries-source-upload-') as staging:
        archive = Path(staging) / 'source.tar.gz'
        with tarfile.open(archive, 'w:gz') as bundle:
            for name, content in contents.items():
                entry = tarfile.TarInfo(name); entry.size = len(content)
                bundle.addfile(entry, io.BytesIO(content))
            entry = tarfile.TarInfo('source-verification.json'); entry.size = len(data)
            bundle.addfile(entry, io.BytesIO(data))
        destination = host + ':' + remote_root.replace('\\', '/') + '/source.tar.gz'
        subprocess.run(['scp', *SSH_OPTIONS, str(archive), destination], check=True, capture_output=True)
        invoke(host, machine, REMOTE_GUARDS + f"\n$source={ps_literal(remote_source)};Set-Location -LiteralPath $source;& (Join-Path ([Environment]::SystemDirectory) 'tar.exe') -xzf {ps_literal(remote_root + '/source.tar.gz')};if($LASTEXITCODE -ne 0){{throw 'Source extraction failed'}};$m=Assert-SourceSnapshot $source {ps_literal(receipt['manifestSha256'])};'source verified'")
    return receipt


def interactive(host: str, machine: str, receipt: dict, script: str, arguments: dict,
                minutes: float, task_name: str | None = None, logon_type: int = 3):
    validate_receipt(machine, receipt)
    relative = Path(script.replace('\\', '/'))
    if relative.is_absolute() or '..' in relative.parts:
        raise ValueError('Script must be relative to the verified source.')
    if minutes <= 0 or minutes > 240 or logon_type not in (3, 5):
        raise ValueError('Invalid bounded task duration or logon type.')
    if not all(re.fullmatch('[A-Za-z][A-Za-z0-9]*', key) for key in arguments):
        raise ValueError('Invalid parameter name.')
    task_name = task_name or 'RooIndustries_Verify_' + uuid.uuid4().hex
    if not re.fullmatch('[A-Za-z0-9_-]{1,120}', task_name):
        raise ValueError('Invalid private task name.')
    run = receipt['runRoot'] + '\\execution-' + uuid.uuid4().hex
    payload = base64.b64encode(json.dumps(arguments).encode()).decode()
    child = f"$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue';[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false);$OutputEncoding=[Console]::OutputEncoding;try{{$run={ps_literal(run)};$global:RooVerificationInvocationContext=[pscustomobject]@{{protocol='roo-industries-verification-invocation/v1';run=$run;taskName={ps_literal(task_name)};task=(Get-Content -Raw -LiteralPath (Join-Path $run 'task.json')|ConvertFrom-Json);wrapper=(Get-Content -Raw -LiteralPath (Join-Path $run 'wrapper.json')|ConvertFrom-Json)}};$p=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('{payload}'))|ConvertFrom-Json;$a=@{{}};foreach($v in $p.PSObject.Properties){{$a[$v.Name]=$v.Value}};& {ps_literal(receipt['stagingPath'] + '/' + str(relative))} @a;if(-not$?){{exit 1}};exit 0}}catch{{Write-Output ('FAIL child exception :: '+$_.Exception.Message);exit 1}}"
    child_encoded = base64.b64encode(child.encode('utf-16le')).decode()
    wrapper = "\n".join([
        "$ErrorActionPreference='Stop'",
        f". {ps_literal(receipt['stagingPath'] + '/tools/validation/LoadTimes/CleanupOwnership.Common.ps1')}",
        f"$run={ps_literal(run)}",
        "$self=New-OwnedProcess (Get-Process -Id $PID);$self.Identity|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $run 'wrapper.json')",
        "$p=$null;$r=$null;$exit=1;$status='failed'",
        "try{",
        f"$p=Start-Process -FilePath (Join-Path ([Environment]::SystemDirectory) 'WindowsPowerShell\\v1.0\\powershell.exe') -ArgumentList '-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand {child_encoded}' -WindowStyle Hidden -RedirectStandardOutput (Join-Path $run 'child.log') -RedirectStandardError (Join-Path $run 'child-error.log') -PassThru",
        "$r=New-OwnedProcess $p;if($r){$r.Identity|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $run 'child.json')}",
        f"if(-not$p.WaitForExit({int(minutes * 60000)})){{Stop-OwnedProcess $r;throw 'Child timeout'}}",
        "$p.Refresh();$exit=$p.ExitCode;if($exit -eq 0){$status='completed'}",
        "}catch{$_|Out-String|Set-Content -LiteralPath (Join-Path $run 'wrapper-error.log')}finally{",
        "if($r -and -not$p.HasExited){Stop-OwnedProcess $r}",
        "@{status=$status;childExit=$exit;childIdentity=$(if($r){$r.Identity}else{$null})}|ConvertTo-Json -Depth 10|Set-Content -LiteralPath (Join-Path $run 'done.json.pending')",
        "[IO.File]::Move((Join-Path $run 'done.json.pending'),(Join-Path $run 'done.json'))",
        "}",
        "exit $exit",
    ])
    encoded = base64.b64encode(wrapper.encode('utf-16le')).decode()
    args = '--headless "' + 'SYSTEM_POWERSHELL' + '" -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand ' + encoded
    setup = REMOTE_GUARDS + f"\n$m=Assert-SourceSnapshot {ps_literal(receipt['stagingPath'])} {ps_literal(receipt['manifestSha256'])};if($m.frameId -cne {ps_literal(receipt['frameId'])} -or $m.sid -cne {ps_literal(receipt['sid'])}){{throw 'Source run receipt scope differs'}};New-ProtectedFrame {ps_literal(run)};"
    setup += f"\n. {ps_literal(receipt['stagingPath'] + '/tools/validation/LoadTimes/CleanupOwnership.Common.ps1')}\n"
    setup += f"$name={ps_literal(task_name)};$run={ps_literal(run)};$receipt=$null;$completed=$null\n"
    setup += "$user=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value;$system=[Environment]::SystemDirectory\n"
    setup += f"$arguments={ps_literal(args)}.Replace('SYSTEM_POWERSHELL',(Join-Path $system 'WindowsPowerShell\\v1.0\\powershell.exe'))\n"
    setup += "try{\n"
    setup += f"$receipt=Register-OwnedProbeTask $name (Join-Path $system 'conhost.exe') $arguments $run $(if({logon_type} -eq 5){{'S-1-5-18'}}else{{$user}}) {max(1,int(minutes)+2)} {logon_type};$receipt|ConvertTo-Json -Depth 10|Set-Content (Join-Path $run 'task.json');Assert-OwnedTaskUnchanged $receipt\n"
    setup += "[void](Get-OwnedTaskFolder '\\').GetTask($name).Run($null)\n"
    setup += f"$deadline=[DateTime]::UtcNow.AddMinutes({minutes+1});while([DateTime]::UtcNow -lt $deadline -and -not(Test-Path -LiteralPath (Join-Path $run 'done.json'))){{Start-Sleep -Milliseconds 250}}\n"
    setup += "if(Test-Path -LiteralPath (Join-Path $run 'done.json')){$completed=Get-Content -Raw (Join-Path $run 'done.json')|ConvertFrom-Json}\n"
    setup += "}finally{if($receipt){$taskError=$null;try{Assert-OwnedTaskUnchanged $receipt}catch{$taskError=$_};foreach($f in 'child.json','wrapper.json'){$p=Join-Path $run $f;if(Test-Path -LiteralPath $p){Stop-OwnedProcessIdentity (Get-Content -Raw $p|ConvertFrom-Json)}};if($taskError){throw $taskError};Remove-OwnedTask $receipt}}\n"
    setup += "foreach($f in 'child.log','child-error.log','wrapper-error.log'){$p=Join-Path $run $f;if(Test-Path -LiteralPath $p){Get-Content -LiteralPath $p -Encoding UTF8}}\n"
    setup += "$ok=$completed -and $completed.status -ceq 'completed' -and $completed.childExit -eq 0;@{run=$run;task=$name;completion=$completed;passed=[bool]$ok}|ConvertTo-Json -Depth 15 -Compress\nif(-not$ok){exit 1}"
    return invoke(host, machine, setup)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--host', required=True, help='An SSH alias with direct Windows authentication')
    parser.add_argument('--expected-machine', required=True, help='The Windows COMPUTERNAME to verify')
    commands = parser.add_subparsers(dest='action', required=True)
    commands.add_parser('inspect')
    stage = commands.add_parser('upload')
    stage.add_argument('--directory', default='roo-industries-backend-validation')
    stage.add_argument('--parent', required=True, help='Existing admin-protected staging parent')
    stage.add_argument('--include-frontend', action='store_true', help='Include desktop sources for an authorized UI validation run')
    run = commands.add_parser('run')
    run.add_argument('script', type=Path, help='A trusted local PowerShell validation script')
    task = commands.add_parser('interactive')
    task.add_argument('--receipt', type=Path, required=True)
    task.add_argument('--script', required=True)
    task.add_argument('--arguments', default='{}')
    task.add_argument('--minutes', type=float, default=45)
    task.add_argument('--task')
    args = parser.parse_args()
    if args.host.startswith('-') or any(char.isspace() for char in args.host):
        parser.error('Use an SSH hostname or alias; configure usernames with spaces in SSH config.')
    try:
        if args.action == 'inspect':
            print(json.dumps(inspect(args.host, args.expected_machine), indent=2))
        elif args.action == 'upload':
            print(json.dumps(upload(args.host, args.expected_machine, args.directory, args.include_frontend, args.parent), indent=2))
        elif args.action == 'interactive':
            result = interactive(args.host, args.expected_machine, json.loads(args.receipt.read_text()), args.script, json.loads(args.arguments), args.minutes, args.task)
            print(result.stdout, end='')
        else:
            invoke(args.host, args.expected_machine, args.script.read_text(encoding='utf-8-sig'), capture=False)
    except subprocess.CalledProcessError as error:
        if error.stdout:
            print(error.stdout.strip())
        if error.stderr:
            print(error.stderr.strip())
        raise SystemExit(error.returncode)


if __name__ == '__main__':
    main()
