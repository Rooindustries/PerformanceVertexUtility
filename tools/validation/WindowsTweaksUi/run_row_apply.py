"""Stage this checkout on a Windows test PC, run the named Tweaks and Windows settings page suites, then drive one setting choice through Apply and Undo in the real app and read Windows back after each step."""
import argparse
import json
import re
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
$ErrorActionPreference='Continue'
$failed=@()
foreach($mode in @(__TWEAKS__)){
 $arguments=@('run','--project',(Join-Path $source 'tools\validation\Tweaks\Tweaks.csproj'),'--configuration','Release','--disable-build-servers','-p:UseSharedCompilation=false','--',$source)
 if($mode -ne 'default'){$arguments+=$mode}
 & $dotnet @arguments 2>&1|ForEach-Object {[string]$_}
 'ROO_INDUSTRIES_CHECK tweaks '+$mode+' '+$LASTEXITCODE
 if($LASTEXITCODE -ne 0){$failed+=$mode}
}
foreach($mode in @(__UI__)){
 $arguments=@('run','--project',(Join-Path $source 'tools\validation\WindowsTweaksUi\WindowsTweaksUi.csproj'),'--configuration','Release','--disable-build-servers','-p:UseSharedCompilation=false','--')
 if($mode -eq 'catalog'){$arguments+=$source}else{$arguments+=$mode}
 if($mode -eq '--policy-editions'){$arguments+=$source}
 & $dotnet @arguments 2>&1|ForEach-Object {[string]$_}
 'ROO_INDUSTRIES_CHECK ui '+$mode+' '+$LASTEXITCODE
 if($LASTEXITCODE -ne 0){$failed+=$mode}
}
if($failed.Count){'ROO_INDUSTRIES_CHECKS failed '+($failed -join ',');exit 1}
'ROO_INDUSTRIES_CHECKS passed'
"""

SCENARIO_KEYS = {'Label', 'Search', 'SettingId', 'Choice', 'Seed', 'SettingsUri', 'SettingsGroup', 'SettingsToggle', 'SettingsApplied', 'SettingsRestored', 'ReadOnly', 'TurnOff', 'Reads'}


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


def scenario(text):
    value = json.loads(text)
    if not isinstance(value, dict) or not {'Label', 'Search', 'SettingId', 'Choice'} <= set(value) or set(value) - SCENARIO_KEYS:
        raise argparse.ArgumentTypeError('A scenario needs Label, Search, SettingId and Choice, and only these keys: ' + ', '.join(sorted(SCENARIO_KEYS)))
    if not isinstance(value['Label'], str) or not re.fullmatch('[a-z][a-z0-9-]{0,30}', value['Label']):
        raise argparse.ArgumentTypeError('Label must match [a-z][a-z0-9-]{0,30}, the pattern Capture-RowApply.ps1 accepts')
    return value


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--host', required=True)
    parser.add_argument('--expected-machine', required=True)
    parser.add_argument('--out-dir', type=Path, required=True)
    parser.add_argument('--parent', required=True, help='Existing admin-protected staging parent')
    parser.add_argument('--lease-minutes', type=float, default=40)
    parser.add_argument('--tweaks', default='--catalog-integration', help='Comma-separated Tweaks suite modes; empty skips them')
    parser.add_argument('--ui', default='--policy-editions,--freshness', help='Comma-separated Windows settings page suite modes, "catalog" for the full suite against this checkout; empty skips them')
    parser.add_argument('--scenario', type=scenario, action='append', default=[], help='JSON object with the Capture-RowApply.ps1 parameters for one Apply and Undo run')
    args = parser.parse_args()
    args.out_dir.mkdir(parents=True, exist_ok=False)
    include_frontend = bool(args.scenario or args.ui)
    receipt = windows.upload_frame(args.host, args.expected_machine, 'roo-industries-ra', include_frontend, args.parent)
    (args.out_dir / 'frame.json').write_text(json.dumps(receipt, indent=2))
    results = {}
    try:
        lease(args, receipt)
        tweaks = [mode for mode in args.tweaks.split(',') if mode]
        ui = [mode for mode in args.ui.split(',') if mode]
        if tweaks or ui:
            script = (CHECKS.replace('__SOURCE__', windows.ps_literal(receipt['stagingPath']))
                      .replace('__TWEAKS__', ','.join(windows.ps_literal(mode) for mode in tweaks))
                      .replace('__UI__', ','.join(windows.ps_literal(mode) for mode in ui)))
            try:
                output = windows.invoke(args.host, args.expected_machine, script, timeout=3600).stdout
            except subprocess.CalledProcessError as error:
                output = (error.stdout or '') + (error.stderr or '')
            (args.out_dir / 'checks.log').write_text(output)
            print('\n'.join(line for line in output.splitlines() if line.startswith(('FAIL', 'ROO_INDUSTRIES_CHECK', 'Completed', 'Unhandled', 'System.InvalidOperationException'))), flush=True)
            results['checks'] = 'pass' if 'ROO_INDUSTRIES_CHECKS passed' in output else 'fail'
        for item in args.scenario:
            label = item['Label']
            try:
                output = windows.interactive_frame(args.host, args.expected_machine, receipt, 'tools/validation/WindowsTweaksUi/Capture-RowApply.ps1',
                                                   {'Source': receipt['stagingPath'], 'OutRoot': receipt['runRoot'] + '\\capture-' + label, **item}, 40).stdout
            except subprocess.CalledProcessError as error:
                output = (error.stdout or '') + (error.stderr or '')
            (args.out_dir / (label + '.log')).write_text(output)
            print('\n'.join(line for line in output.splitlines() if line.startswith(('PASS', 'FAIL', 'ROO_INDUSTRIES_ROW_APPLY'))), flush=True)
            marker = next((line.split(' ', 2) for line in output.splitlines() if line.startswith('ROO_INDUSTRIES_ROW_APPLY ')), None)
            results[label] = marker[1] if marker else 'fail'
            if marker:
                windows.run_transport(args.host, 'scp', ['-r', args.host + ':' + marker[2].replace('\\', '/'), str(args.out_dir / label)],
                                      timeout=windows.TRANSFER_TIMEOUT, capture_output=True)
    finally:
        clear = '& ' + windows.ps_literal(receipt['stagingPath'] + r'\tools\validation\Update\Clear-UpdateFrame.ps1') + ' -Frame ' + windows.ps_literal(receipt['runRoot']) + ' -ExpectedMachine ' + windows.ps_literal(args.expected_machine)
        try:
            closed = windows.invoke(args.host, args.expected_machine, clear, timeout=windows.CLEANUP_TIMEOUT)
            (args.out_dir / 'cleanup.log').write_text(closed.stdout)
            results['cleanup'] = 'pass'
        except subprocess.CalledProcessError as error:
            (args.out_dir / 'cleanup.log').write_text((error.stdout or '') + (error.stderr or ''))
            results['cleanup'] = 'fail'
        (args.out_dir / 'results.json').write_text(json.dumps(results, indent=2))
        print('row apply results: ' + json.dumps(results) + ' in ' + str(args.out_dir), flush=True)
    if any(value != 'pass' for value in results.values()):
        sys.exit(1)


if __name__ == '__main__':
    main()
