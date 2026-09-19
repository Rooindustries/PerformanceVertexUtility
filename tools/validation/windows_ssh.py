"""Inspect, stage, and validate a Windows development host directly over SSH."""
from __future__ import annotations

import argparse
import base64
import hashlib
import io
import json
from pathlib import Path
import re
import subprocess
import tarfile
import tempfile


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
    encoded = base64.b64encode(('& {\n' + guarded + '\n} 6>&1').encode('utf-16le')).decode()
    command = 'powershell.exe -NoProfile -NonInteractive -OutputFormat Text -ExecutionPolicy Bypass -EncodedCommand ' + encoded
    return subprocess.run(['ssh', '-T', *SSH_OPTIONS, host, command],
                          capture_output=capture, text=True, check=True)


def inspect(host: str, machine: str):
    script = (
        "$identity=[Security.Principal.WindowsIdentity]::GetCurrent(); "
        "@{machine=$env:COMPUTERNAME;user=$identity.Name;temp=[IO.Path]::GetTempPath();"
        "admin=[Security.Principal.WindowsPrincipal]::new($identity).IsInRole("
        "[Security.Principal.WindowsBuiltInRole]::Administrator)}|ConvertTo-Json -Compress"
    )
    return json.loads(invoke(host, machine, script).stdout)


def upload(host: str, machine: str, directory: str, include_frontend: bool = False):
    if not re.fullmatch(r'roo-industries-[a-z0-9-]{1,70}', directory):
        raise ValueError('The staging directory must be a roo-industries- prefixed name beneath Windows Temp.')
    identity = inspect(host, machine)  # Confirm the target before creating or copying anything.
    remote_root = identity['temp'].rstrip('\\/') + '\\' + directory
    root = Path(__file__).resolve().parents[2]
    tracked = subprocess.check_output(['git', 'ls-files', '-z'], cwd=root).decode().split('\0')
    files = sorted(name for name in tracked if name and (include_frontend or not name.startswith('docs/internal/frontend/')) and (root / name).is_file())
    manifest = {
        'protocol': 'roo-industries-source-snapshot/v1', 'machine': identity['machine'],
        'commit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root).decode().strip(),
        'files': {name: hashlib.sha256((root / name).read_bytes()).hexdigest() for name in files},
    }
    path = ps_literal(remote_root)
    invoke(host, machine, f"$root={path}; if ((Test-Path -LiteralPath $root) -and "
           "@(Get-ChildItem -LiteralPath $root -Force).Count -gt 0 -and "
           "-not(Test-Path -LiteralPath (Join-Path $root 'source-verification.json'))) "
           "{throw 'Existing directory has no source snapshot marker'}; "
           "[IO.Directory]::CreateDirectory($root)|Out-Null")
    with tempfile.TemporaryDirectory(prefix='roo-industries-source-upload-') as staging:
        archive = Path(staging) / 'source.tar.gz'
        with tarfile.open(archive, 'w:gz') as bundle:
            for name in files:
                bundle.add(root / name, arcname=name, recursive=False)
            data = json.dumps(manifest).encode()
            entry = tarfile.TarInfo('source-verification.json')
            entry.size = len(data)
            bundle.addfile(entry, io.BytesIO(data))
        destination = host + ':' + remote_root.replace('\\', '/') + '/source.tar.gz'
        subprocess.run(['scp', *SSH_OPTIONS, str(archive), destination], check=True)
        invoke(host, machine, f"Set-Location -LiteralPath {path}; tar.exe -xzf source.tar.gz; "
               "if($LASTEXITCODE -ne 0){throw 'Source extraction failed'}; Remove-Item -LiteralPath source.tar.gz")
    return {'machine': identity['machine'], 'stagingPath': remote_root,
            'sourceCommit': manifest['commit'], 'sourceFileCount': len(files), 'frontendIncluded': include_frontend}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--host', required=True, help='An SSH alias with direct Windows authentication')
    parser.add_argument('--expected-machine', required=True, help='The Windows COMPUTERNAME to verify')
    commands = parser.add_subparsers(dest='action', required=True)
    commands.add_parser('inspect')
    stage = commands.add_parser('upload')
    stage.add_argument('--directory', default='roo-industries-backend-validation')
    stage.add_argument('--include-frontend', action='store_true', help='Include desktop sources for an authorized UI validation run')
    run = commands.add_parser('run')
    run.add_argument('script', type=Path, help='A trusted local PowerShell validation script')
    args = parser.parse_args()
    if args.host.startswith('-') or any(char.isspace() for char in args.host):
        parser.error('Use an SSH hostname or alias; configure usernames with spaces in SSH config.')
    try:
        if args.action == 'inspect':
            print(json.dumps(inspect(args.host, args.expected_machine), indent=2))
        elif args.action == 'upload':
            print(json.dumps(upload(args.host, args.expected_machine, args.directory, args.include_frontend), indent=2))
        else:
            invoke(args.host, args.expected_machine, args.script.read_text(encoding='utf-8-sig'), capture=False)
    except subprocess.CalledProcessError as error:
        if error.stderr:
            print(error.stderr.strip())
        raise SystemExit(error.returncode)


if __name__ == '__main__':
    main()
