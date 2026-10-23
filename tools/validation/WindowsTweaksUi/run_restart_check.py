"""Stage this checkout on a Windows test PC, run the named Tweaks suites and film the Windows settings restart check against a simulated Windows feature state."""
import argparse
import json
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import windows_ssh as windows

CHECKS = r"""
$ErrorActionPreference='Stop'
$source=__SOURCE__
Set-Location -LiteralPath $source
. (Join-Path $source 'tools\validation\Update\Harness.Common.ps1')
$manifestPath=Join-Path $source 'source-verification.json'
$manifest=Get-Content -Raw -LiteralPath $manifestPath|ConvertFrom-Json
Open-HarnessRun (Split-Path $source -Parent) $manifest.frameId (Get-HarnessFileSha256 $manifestPath).ToLowerInvariant() $manifest.frameId
Assert-HarnessHostLease
Initialize-HarnessBuildFolders $source
$env:MSBUILDDISABLENODEREUSE='1';$env:DOTNET_CLI_USE_MSBUILD_SERVER='0';$env:DOTNET_CLI_TELEMETRY_OPTOUT='1';$env:UseSharedCompilation='false'
$dotnet=@((Join-Path $env:LOCALAPPDATA 'Microsoft\dotnet\dotnet.exe'),(Join-Path $env:USERPROFILE '.dotnet\dotnet.exe'),(Join-Path $env:ProgramFiles 'dotnet\dotnet.exe')|Where-Object {Test-Path -LiteralPath $_ -PathType Leaf}|Where-Object {@(& $_ --list-sdks 2>$null).Count}|Select-Object -First 1)[0]
. (Join-Path $source 'tools\validation\Tweaks\BootMarkerFixture.Common.ps1')
$marker=Get-TweakBootMarkerSnapshot
try{
 foreach($mode in @(__MODES__)){
  $arguments=@('run','--project',(Join-Path $source 'tools\validation\Tweaks\Tweaks.csproj'),'--configuration','Release','--disable-build-servers','-p:UseSharedCompilation=false','--',$source)
  if($mode -ne 'default'){$arguments+=$mode}
  & $dotnet @arguments 2>&1
  'ROO_INDUSTRIES_CHECK '+$mode+' '+$LASTEXITCODE
  if($LASTEXITCODE -ne 0){throw ('Tweak checks failed: '+$mode)}
 }
}finally{Restore-TweakBootMarkerSnapshot $marker;'ROO_INDUSTRIES_CHECK boot-marker restored'}
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


def encode(args, evidence):
    script = '$directory=' + windows.ps_literal(evidence) + r"""
$capture=@(Get-ChildItem -LiteralPath $directory -Filter 'capture-*.json')
if($capture.Count -ne 1){throw 'A single capture receipt is required.'}
$rows=(Get-Content -Raw -LiteralPath $capture[0].FullName|ConvertFrom-Json).data.frames
if(-not$rows.Count){throw 'No recorded frames were found.'}
$lines=@(foreach($row in $rows){"file '"+$row.file+"'";'duration '+[Math]::Max([double]$row.duration,0.04).ToString('0.000',[Globalization.CultureInfo]::InvariantCulture)})
$lines+="file '"+$rows[-1].file+"'"
$listing=Join-Path $directory 'frames\frames.txt'
[IO.File]::WriteAllLines($listing,$lines,[Text.UTF8Encoding]::new($false))
$ffmpeg=(Get-Command ffmpeg.exe -CommandType Application -ErrorAction Stop).Source
& $ffmpeg -v error -y -f concat -safe 0 -i $listing -vf 'scale=trunc(min(iw\,1920)/2)*2:-2' -r 30 -c:v libx264 -pix_fmt yuv420p -crf 20 -movflags +faststart (Join-Path $directory 'interaction.mp4')
if($LASTEXITCODE -ne 0){throw 'Windows video encoding failed.'}
"""
    windows.invoke(args.host, args.expected_machine, script, timeout=300)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--host', required=True)
    parser.add_argument('--expected-machine', required=True)
    parser.add_argument('--label', required=True)
    parser.add_argument('--out-dir', type=Path, required=True)
    parser.add_argument('--parent', required=True, help='Existing admin-protected staging parent')
    parser.add_argument('--lease-minutes', type=float, default=40)
    parser.add_argument('--checks', default='default,--feature-checks,--feature-restart-fixture,--registry-fixture,--controls-fixture',
                        help='Comma-separated Tweaks suite modes; empty skips them')
    parser.add_argument('--skip-capture', action='store_true')
    parser.add_argument('--expected-outcome', choices=['undone', 'refused'], default='undone')
    args = parser.parse_args()
    args.out_dir.mkdir(parents=True, exist_ok=False)
    receipt = windows.upload_frame(args.host, args.expected_machine, 'roo-industries-restart-check', True, args.parent)
    (args.out_dir / 'frame.json').write_text(json.dumps(receipt, indent=2))
    status = 'fail'
    try:
        lease(args, receipt)
        modes = [mode for mode in args.checks.split(',') if mode]
        if modes:
            script = CHECKS.replace('__SOURCE__', windows.ps_literal(receipt['stagingPath'])).replace('__MODES__', ','.join(windows.ps_literal(mode) for mode in modes))
            try:
                checks = windows.invoke(args.host, args.expected_machine, script, timeout=2400)
            except subprocess.CalledProcessError as error:
                (args.out_dir / 'checks.log').write_text((error.stdout or '') + (error.stderr or ''))
                raise
            (args.out_dir / 'checks.log').write_text(checks.stdout)
            print('\n'.join(line for line in checks.stdout.splitlines() if line.startswith(('PASS', 'FAIL', 'ROO_INDUSTRIES_CHECK', 'Completed', 'Unhandled'))), flush=True)
        if not args.skip_capture:
            result = windows.interactive_frame(args.host, args.expected_machine, receipt, 'tools/validation/WindowsTweaksUi/Capture-RestartCheck.ps1',
                                               {'Source': receipt['stagingPath'], 'OutRoot': receipt['runRoot'] + r'\capture', 'Label': args.label, 'ExpectedOutcome': args.expected_outcome}, 30)
            (args.out_dir / 'capture.log').write_text(result.stdout)
            evidence = next(line.split(' ', 2)[2] for line in result.stdout.splitlines() if line.startswith('ROO_INDUSTRIES_RESTART_CAPTURE pass '))
            encode(args, evidence)
            windows.run_transport(args.host, 'scp', ['-r', args.host + ':' + evidence.replace('\\', '/'), str(args.out_dir / 'evidence')],
                                  timeout=windows.TRANSFER_TIMEOUT, capture_output=True)
        status = 'pass'
    finally:
        clear = '& ' + windows.ps_literal(receipt['stagingPath'] + r'\tools\validation\Update\Clear-UpdateFrame.ps1') + ' -Frame ' + windows.ps_literal(receipt['runRoot']) + ' -ExpectedMachine ' + windows.ps_literal(args.expected_machine)
        try:
            closed = windows.invoke(args.host, args.expected_machine, clear, timeout=windows.CLEANUP_TIMEOUT)
        except subprocess.CalledProcessError as error:
            (args.out_dir / 'cleanup.log').write_text((error.stdout or '') + (error.stderr or ''))
            raise
        (args.out_dir / 'cleanup.log').write_text(closed.stdout)
        print('restart check ' + status + ': ' + str(args.out_dir), flush=True)


if __name__ == '__main__':
    main()
