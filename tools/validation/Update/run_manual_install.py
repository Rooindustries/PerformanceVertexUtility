import importlib.util
import json
from pathlib import Path
import subprocess
import uuid

ROOT = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location('manual_install_windows', ROOT / 'tools/validation/windows_ssh.py')
windows = importlib.util.module_from_spec(spec)
spec.loader.exec_module(windows)


def install(host, machine, legacy_receipt, fields, out_dir,
            scenario_script='tools/validation/Update/Invoke-UpdateScenario.ps1'):
    windows.validate_receipt(machine, legacy_receipt)
    if not fields.get('InstallerPath'):
        raise ValueError('InstallerPath is required for the Background install scenario.')
    windows.verify_source(host, machine, legacy_receipt)
    out_dir = Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=False)
    receipt = windows.upload_frame(host, machine, 'roo-industries-background-install', True, r'C:\RooBuild')
    (out_dir / 'frame.json').write_text(json.dumps(receipt, indent=2))
    failure = None
    cleanup_errors = []
    invocation = None
    try:
        windows.enter_host_lease(host, machine, receipt)
        arguments = dict(fields, Source=receipt['stagingPath'], OutRoot=receipt['runRoot'] + r'\install',
                         Scenario='manual-install', CurrentData=True)
        result = windows.interactive_frame(host, machine, receipt, scenario_script, arguments, 10)
        (out_dir / 'install.log').write_text(result.stdout)
        invocation = windows.completion(result.stdout)
        if not invocation['passed']:
            raise RuntimeError('Background install did not complete its invocation cleanup.')
        return result
    except Exception as error:
        failure = str(error)
        if isinstance(error, subprocess.CalledProcessError):
            (out_dir / 'install.log').write_text((error.stdout or '') + (error.stderr or ''))
        raise
    finally:
        scope = '. ' + windows.ps_literal(receipt['stagingPath'] + r'\tools\validation\Update\Harness.Common.ps1') + ';Open-HarnessRun ' + ' '.join(windows.ps_literal(receipt[key]) for key in ('runRoot', 'frameId', 'manifestSha256')) + ' ' + windows.ps_literal(receipt['frameId']) + ';'
        try:
            destination = receipt['runRoot'] + '\\evidence-' + uuid.uuid4().hex + '.zip'
            script = scope + '$root=' + windows.ps_literal(receipt['runRoot']) + ';New-HarnessArchive $root ' + windows.ps_literal(destination) + " {param($item,$relative) $relative -notlike 'source\\*' -and [IO.Path]::GetExtension($item.FullName) -in '.json','.png','.log'}|Out-Null"
            windows.invoke(host, machine, script, timeout=windows.EVIDENCE_TIMEOUT)
            windows.run_transport(host, 'scp', [host + ':' + destination.replace('\\', '/'), str(out_dir / 'evidence.zip')], timeout=windows.TRANSFER_TIMEOUT, capture_output=True)
        except Exception as error:
            cleanup_errors.append('Evidence collection: ' + str(error))
        try:
            script = '& ' + windows.ps_literal(receipt['stagingPath'] + r'\tools\validation\Update\Clear-UpdateFrame.ps1') + ' -Frame ' + windows.ps_literal(receipt['runRoot']) + ' -ExpectedMachine ' + windows.ps_literal(machine)
            closed = windows.invoke(host, machine, script, timeout=windows.CLEANUP_TIMEOUT)
            (out_dir / 'cleanup.json').write_text(closed.stdout)
        except Exception as error:
            cleanup_errors.append('Frame cleanup: ' + str(error))
        (out_dir / 'receipt.json').write_text(json.dumps({'status': 'pass' if invocation and not failure and not cleanup_errors else 'fail',
                                                       'invocation': invocation, 'failure': failure, 'cleanupErrors': cleanup_errors}, indent=2))
        if cleanup_errors:
            raise RuntimeError('; '.join(cleanup_errors))
