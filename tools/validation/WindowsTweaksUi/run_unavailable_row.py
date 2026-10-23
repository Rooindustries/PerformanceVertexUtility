"""Stage this checkout on a Windows test PC, run the missing-command checks and film the Defender row with Defender's PowerShell module hidden."""
import argparse
import json
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import windows_ssh as windows

CHECKS = r"""
$ErrorActionPreference='Continue'
$source=__SOURCE__
Set-Location -LiteralPath $source
$env:MSBUILDDISABLENODEREUSE='1';$env:DOTNET_CLI_USE_MSBUILD_SERVER='0';$env:DOTNET_CLI_TELEMETRY_OPTOUT='1';$env:UseSharedCompilation='false'
$dotnet=@((Join-Path $env:LOCALAPPDATA 'Microsoft\dotnet\dotnet.exe'),(Join-Path $env:USERPROFILE '.dotnet\dotnet.exe'),(Join-Path $env:ProgramFiles 'dotnet\dotnet.exe')|Where-Object {Test-Path -LiteralPath $_ -PathType Leaf}|Where-Object {@(& $_ --list-sdks 2>$null).Count}|Select-Object -First 1)[0]
& (Join-Path ([Environment]::SystemDirectory) 'WindowsPowerShell\v1.0\powershell.exe') -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $source 'backend\scripts\Test-WindowsControlOutput.ps1') 2>&1
'ROO_INDUSTRIES_CHECK output '+$LASTEXITCODE
& (Join-Path ([Environment]::SystemDirectory) 'WindowsPowerShell\v1.0\powershell.exe') -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $source 'backend\scripts\Test-OptimizerCore.ps1') -DotNetPath $dotnet -Area control-reads 2>&1
'ROO_INDUSTRIES_CHECK control-reads '+$LASTEXITCODE
& $dotnet run --project (Join-Path $source 'tools\validation\WindowsTweaksUi\WindowsTweaksUi.csproj') --configuration Release --disable-build-servers -- --freshness 2>&1
'ROO_INDUSTRIES_CHECK freshness '+$LASTEXITCODE
"""


def lease(args, receipt):
    deadline = time.monotonic() + args.lease_minutes * 60
    while True:
        try:
            return windows.enter_host_lease(args.host, args.expected_machine, receipt)
        except subprocess.CalledProcessError as error:
            text = (error.stdout or '') + (error.stderr or '')
            if 'leased by frame' not in text or time.monotonic() > deadline:
                raise
            print('host lease busy; waiting', flush=True)
            time.sleep(60)


def encode(capture: Path, frames: Path, output: Path):
    rows = json.loads(capture.read_text(encoding='utf-8-sig'))['data']['frames']
    listing = frames / 'frames.txt'
    lines = []
    for row in rows:
        lines += [f"file '{row['file']}'", f"duration {max(float(row['duration']), 0.04):.3f}"]
    lines.append(f"file '{rows[-1]['file']}'")
    listing.write_text('\n'.join(lines) + '\n')
    subprocess.run(['ffmpeg', '-v', 'error', '-y', '-f', 'concat', '-safe', '0', '-i', str(listing), '-vf', 'scale=trunc(min(iw\\,1920)/2)*2:-2', '-r', '30',
                    '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-crf', '20', '-movflags', '+faststart', str(output)], check=True, timeout=600)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--host', required=True)
    parser.add_argument('--expected-machine', required=True)
    parser.add_argument('--label', required=True)
    parser.add_argument('--out-dir', type=Path, required=True)
    parser.add_argument('--parent', required=True, help='Existing admin-protected staging parent')
    parser.add_argument('--lease-minutes', type=float, default=40)
    parser.add_argument('--skip-checks', action='store_true')
    args = parser.parse_args()
    args.out_dir.mkdir(parents=True, exist_ok=False)
    receipt = windows.upload_frame(args.host, args.expected_machine, 'roo-industries-unavailable-row', True, args.parent)
    (args.out_dir / 'frame.json').write_text(json.dumps(receipt, indent=2))
    status = 'fail'
    try:
        lease(args, receipt)
        prepare = '. ' + windows.ps_literal(receipt['stagingPath'] + r'\tools\validation\Update\Harness.Common.ps1')
        prepare += '; Open-HarnessRun ' + ' '.join(windows.ps_literal(receipt[key]) for key in ('runRoot', 'frameId', 'manifestSha256', 'frameId'))
        prepare += '; Initialize-HarnessBuildFolders ' + windows.ps_literal(receipt['stagingPath'])
        prepare += '; Ensure-HarnessOutputDirectory ' + windows.ps_literal(receipt['stagingPath'] + r'\backend\bin')
        windows.invoke(args.host, args.expected_machine, prepare, timeout=windows.SOURCE_TIMEOUT)
        if not args.skip_checks:
            checks = windows.invoke(args.host, args.expected_machine, CHECKS.replace('__SOURCE__', windows.ps_literal(receipt['stagingPath'])), timeout=1800)
            (args.out_dir / 'checks.log').write_text(checks.stdout)
            print('\n'.join(line for line in checks.stdout.splitlines() if line.startswith(('PASS', 'FAIL', 'ROO_INDUSTRIES_CHECK', 'Completed', 'Exception'))), flush=True)
            markers = [line.split() for line in checks.stdout.splitlines() if line.startswith('ROO_INDUSTRIES_CHECK')]
            expected = {'output', 'control-reads', 'freshness'}
            if (len(markers) != len(expected)
                    or any(len(marker) != 3 or marker[1] not in expected or marker[2] != '0' for marker in markers)
                    or {marker[1] for marker in markers} != expected):
                raise RuntimeError('Remote checks failed or returned incomplete results: ' + json.dumps(markers))
        result = windows.interactive_frame(args.host, args.expected_machine, receipt, 'tools/validation/WindowsTweaksUi/Capture-UnavailableRow.ps1',
                                           {'Source': receipt['stagingPath'], 'OutRoot': receipt['runRoot'] + r'\capture', 'Label': args.label}, 30)
        (args.out_dir / 'capture.log').write_text(result.stdout)
        evidence = next(line.split(' ', 2)[2] for line in result.stdout.splitlines() if line.startswith('ROO_INDUSTRIES_ROW_CAPTURE pass '))
        windows.run_transport(args.host, 'scp', ['-r', args.host + ':' + evidence.replace('\\', '/'), str(args.out_dir / 'evidence')],
                              timeout=windows.TRANSFER_TIMEOUT, capture_output=True)
        capture = next((args.out_dir / 'evidence').glob('capture-*.json'))
        encode(capture, args.out_dir / 'evidence' / 'frames', args.out_dir / (args.label + '.mp4'))
        status = 'pass'
    finally:
        clear = '& ' + windows.ps_literal(receipt['stagingPath'] + r'\tools\validation\Update\Clear-UpdateFrame.ps1') + ' -Frame ' + windows.ps_literal(receipt['runRoot']) + ' -ExpectedMachine ' + windows.ps_literal(args.expected_machine)
        closed = windows.invoke(args.host, args.expected_machine, clear, timeout=windows.CLEANUP_TIMEOUT)
        (args.out_dir / 'cleanup.log').write_text(closed.stdout)
        print('capture ' + status + ': ' + str(args.out_dir), flush=True)


if __name__ == '__main__':
    main()
