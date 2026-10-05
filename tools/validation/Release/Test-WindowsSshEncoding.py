import argparse
import importlib.util
import json
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument('--out', required=True, type=Path)
parser.add_argument('--receipt', type=Path)
parser.add_argument('--before', action='store_true')
args = parser.parse_args()
args.out.mkdir(parents=True, exist_ok=False)
spec = importlib.util.spec_from_file_location('w', Path(__file__).resolve().parents[1] / 'windows_ssh.py')
w = importlib.util.module_from_spec(spec)
spec.loader.exec_module(w)
host, machine = 'optimizer-9070', 'SERVI-WINDOWS-D'
text = 'middot · arrow → pound £ accent é'
script = "$t='middot '+[char]0x00B7+' arrow '+[char]0x2192+' pound '+[char]0x00A3+' accent '+[char]0x00E9;"
proof = {'passed': False, 'checks': []}
try:
    encoding = w.invoke(host, machine, '[Console]::OutputEncoding.CodePage').stdout.strip()
    proof['consoleCodePage'] = encoding
    try:
        output = w.invoke(host, machine, script + "Write-Output ('PASS direct '+$t)").stdout
    except UnicodeDecodeError as error:
        if not args.before:
            raise
        proof['checks'].append({'name': 'Original direct Unicode output fails strict decoding', 'passed': True, 'error': str(error)})
    else:
        if args.before:
            raise AssertionError('Original decoder failure was not reproduced')
        assert 'PASS direct ' + text in output and encoding == '65001'
        (args.out / 'direct.log').write_text(output)
        proof['checks'].append({'name': 'Direct Unicode output is exact UTF-8', 'passed': True})
    if not args.before:
        try:
            w.invoke(host, machine, script + "Write-Output ('FATAL direct '+$t);exit 17")
        except subprocess.CalledProcessError as error:
            (args.out / 'direct-failure.log').write_text((error.stdout or '') + '\n' + (error.stderr or ''))
            assert error.returncode != 0 and 'FATAL direct ' + text in error.stdout
            proof['checks'].append({'name': 'Direct failure preserves exact Unicode FATAL and a nonzero transport exit', 'passed': True, 'transportExit': error.returncode})
        else:
            raise AssertionError('Direct failure was hidden')
        if not args.receipt:
            raise ValueError('Native interactive proof needs a fresh source receipt')
        receipt = json.loads(args.receipt.read_text())
        relative = 'tools/validation/Release/Test-WindowsSshEncodingChild.ps1'
        for fail in (False, True):
            try:
                result = w.interactive(host, machine, receipt, relative, {'Fail': True} if fail else {}, 2)
            except subprocess.CalledProcessError as error:
                if not fail:
                    raise
                output = error.stdout
                assert error.returncode == 1 and 'FATAL native child ' + text in output
            else:
                assert not fail
                output = result.stdout
            assert 'PASS native child ' + text in output
            completion = json.loads(output.splitlines()[-1])
            assert completion['passed'] is (not fail)
            assert completion['completion']['childExit'] == (1 if fail else 0)
            (args.out / ('interactive-failure.log' if fail else 'interactive.log')).write_text(output)
            proof['checks'].append({'name': 'Native redirected child preserves Unicode, FATAL and completion' if fail else 'Native redirected child preserves Unicode and completion', 'passed': True, 'completion': completion})
    proof['passed'] = True
finally:
    (args.out / 'result.json').write_text(json.dumps(proof, indent=2))
print(json.dumps(proof, indent=2))
