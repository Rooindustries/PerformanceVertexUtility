import argparse
import importlib.util
import json
from pathlib import Path
import subprocess

REPO = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location('windows_ssh', REPO / 'tools/validation/windows_ssh.py')
windows = importlib.util.module_from_spec(spec)
spec.loader.exec_module(windows)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--machine', choices=['9070', 'blackwell'], default='9070')
    parser.add_argument('--receipt', type=Path, required=True)
    parser.add_argument('--scenario', required=True, choices=['build', 'presets', 'placement-origins', 'game-memory', 'limits-memory', 'identity', 'memory-controls', 'memory-ownership', 'fix-round', 'priority', 'games', 'guides', 'services', 'background-ui', 'memory', 'install'])
    parser.add_argument('--out-root')
    parser.add_argument('--arguments', default='{}')
    args = parser.parse_args()
    host, machine = {'9070': ('optimizer-9070', 'SERVI-WINDOWS-D'), 'blackwell': ('blackwell-lan', 'CS2-GEN4')}[args.machine]
    receipt = json.loads(args.receipt.read_text())
    source = receipt['stagingPath']
    output = args.out_root or receipt['runRoot'] + '\\evidence'
    fields = {'Source': source, 'OutRoot': output}
    fields.update(json.loads(args.arguments))
    scripts = {'build': 'Build-Merged.ps1', 'memory': 'Measure-MemoryBaseline.ps1', 'memory-ownership': 'Test-MemoryOwnership.ps1', 'fix-round': 'Test-FixRound.ps1'}
    if args.scenario in ('presets', 'placement-origins', 'game-memory', 'limits-memory', 'identity', 'memory-controls'):
        script = 'Invoke-BackgroundScenario.ps1'
        fields['Scenario'] = args.scenario
    elif args.scenario in ('priority', 'games', 'guides', 'services', 'background-ui'):
        script = 'Invoke-DesktopScenario.ps1'
        fields['Scenario'] = args.scenario
    else:
        script = scripts.get(args.scenario)
    if args.scenario == 'install':
        script = 'tools/validation/Update/Invoke-UpdateScenario.ps1'
        fields['Scenario'] = 'manual-install'
        fields['EvidenceName'] = 'slice3-install'
        if 'InstallerPath' not in fields:
            fields['InstallerPath'] = output + '\\build\\release\\RooIndustries-OptimizationSuite-0.11.0-beta-setup.exe'
    else:
        script = 'tools/validation/Background/' + script
    if args.scenario == 'memory':
        fields['FocusSamples'] = True
    minutes = 35 if args.scenario == 'memory' else 10
    try:
        result = windows.interactive(host, machine, receipt, script, fields, minutes, 'RooIndustries_Roo20_Background_' + args.machine + '_' + args.scenario)
        print(result.stdout, end='')
    except subprocess.CalledProcessError as error:
        print(error.stdout or '', end='')
        print(error.stderr or '', end='')
        raise SystemExit(error.returncode)


if __name__ == '__main__':
    main()
