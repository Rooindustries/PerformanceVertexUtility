import argparse
import importlib.util
import json
from pathlib import Path
import statistics

ROOT = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location('trace_windows', ROOT / 'tools/validation/windows_ssh.py')
windows = importlib.util.module_from_spec(spec)
spec.loader.exec_module(windows)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--host', required=True)
    parser.add_argument('--expected-machine', required=True)
    parser.add_argument('--out-dir', type=Path, required=True)
    args = parser.parse_args()
    args.out_dir.mkdir(parents=True, exist_ok=False)
    receipt = windows.upload_frame(args.host, args.expected_machine, 'roo-industries-trace-series', True, r'C:\RooBuild')
    (args.out_dir / 'frame.json').write_text(json.dumps(receipt, indent=2))
    rows = []
    loaded = False
    failure = None
    try:
        windows.enter_host_lease(args.host, args.expected_machine, receipt)
        for number in range(1, 9):
            if number == 6:
                result = windows.interactive_frame(args.host, args.expected_machine, receipt, 'tools/validation/Update/Invoke-TraceLoad.ps1', {'Source': receipt['stagingPath'], 'OutRoot': receipt['runRoot'] + r'\checks', 'Action': 'start'}, 4)
                (args.out_dir / 'load-start.log').write_text(result.stdout)
                loaded = True
                nonce = windows.completion(result.stdout)['nonce']
                load = windows.read_result(args.host, args.expected_machine, receipt, 'load.json', nonce)
                (args.out_dir / 'load.json').write_text(json.dumps(load, indent=2))
            if loaded:
                counters = windows.invoke(args.host, args.expected_machine, "$samples=Get-Counter '\\Processor(*)\\% Processor Time' -SampleInterval 1 -MaxSamples 3;$rows=@($samples|ForEach-Object {$_.CounterSamples|ForEach-Object {@{path=$_.Path;value=$_.CookedValue}}});$rows|ConvertTo-Json -Depth 5", timeout=30)
                (args.out_dir / ('load-counters-' + str(number) + '.json')).write_text(counters.stdout)
                totals = [row['value'] for row in json.loads(counters.stdout) if '(_total)' in row['path'].lower()]
                if not totals or statistics.mean(totals) < 85:
                    raise RuntimeError('Owned CPU load did not saturate the PC: ' + str(totals))
            result = windows.interactive_frame(args.host, args.expected_machine, receipt, 'tools/validation/Update/Invoke-TraceOwnershipChecks.ps1', {'Source': receipt['stagingPath'], 'OutRoot': receipt['runRoot'] + r'\checks'}, 6)
            (args.out_dir / ('trace-' + str(number) + '.log')).write_text(result.stdout)
            nonce = windows.completion(result.stdout)['nonce']
            observed = windows.read_result(args.host, args.expected_machine, receipt, 'receipt.json', nonce)
            if observed['status'] != 'pass' or len(observed['checks']) != 4 or any(row['status'] != 'pass' for row in observed['checks']):
                raise RuntimeError('Trace ownership checks failed: ' + str(number))
            rows.append({'run': number, 'load': loaded, 'nonce': nonce, 'receipt': observed})
            (args.out_dir / ('trace-' + str(number) + '.json')).write_text(json.dumps(observed, indent=2))
            print('PASS trace run ' + str(number) + ' ' + nonce, flush=True)
    except Exception as error:
        failure = str(error)
        raise
    finally:
        errors = []
        if loaded:
            try:
                result = windows.interactive_frame(args.host, args.expected_machine, receipt, 'tools/validation/Update/Invoke-TraceLoad.ps1', {'Source': receipt['stagingPath'], 'OutRoot': receipt['runRoot'] + r'\checks', 'Action': 'stop'}, 4)
                (args.out_dir / 'load-stop.log').write_text(result.stdout)
            except Exception as error:
                errors.append(str(error))
        scope = '. ' + windows.ps_literal(receipt['stagingPath'] + r'\tools\validation\Update\Harness.Common.ps1') + ';Open-HarnessRun ' + ' '.join(windows.ps_literal(receipt[key]) for key in ('runRoot', 'frameId', 'manifestSha256')) + " '' -ReadOnly;"
        lags = []
        try:
            ledger = json.loads(windows.invoke(args.host, args.expected_machine, scope + 'Invoke-HarnessLedger {param($l) $l} -NoWrite|ConvertTo-Json -Depth 60', timeout=windows.EVIDENCE_TIMEOUT).stdout)
            (args.out_dir / 'ledger-before-cleanup.json').write_text(json.dumps(ledger, indent=2))
            lags = [entry['metadata']['ownershipProof']['lagMs'] for entry in ledger['entries'] if entry.get('metadata') and entry['metadata'].get('ownershipProof', {}).get('kind') == 'trace']
            clear = '& ' + windows.ps_literal(receipt['stagingPath'] + r'\tools\validation\Update\Clear-UpdateFrame.ps1') + ' -Frame ' + windows.ps_literal(receipt['runRoot']) + ' -ExpectedMachine ' + windows.ps_literal(args.expected_machine)
            closed = windows.invoke(args.host, args.expected_machine, clear, timeout=windows.CLEANUP_TIMEOUT)
            (args.out_dir / 'cleanup.json').write_text(closed.stdout)
        except Exception as error:
            errors.append(str(error))
        status = 'pass' if len(rows) == 8 and not failure and not errors else 'fail'
        summary = {'status': status, 'runs': rows, 'failure': failure, 'cleanupErrors': errors, 'lagMs': {'count': len(lags), 'min': min(lags) if lags else None, 'median': statistics.median(lags) if lags else None, 'max': max(lags) if lags else None}}
        (args.out_dir / 'receipt.json').write_text(json.dumps(summary, indent=2))
        if errors:
            raise RuntimeError('Trace series cleanup failed: ' + '; '.join(errors))


if __name__ == '__main__':
    main()
