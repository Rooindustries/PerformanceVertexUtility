from __future__ import annotations
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import uuid

root = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location('windows_ssh', root / 'tools/validation/windows_ssh.py')
transport = importlib.util.module_from_spec(spec)
spec.loader.exec_module(transport)


def driver_checks(out):
    shell = root/'tools/validation/Release/Run-FinalVerification.sh'
    run = out/'shell-run';run.mkdir()
    env = dict(os.environ, HOST='blackwell-lan', MACHINE='CS2-GEN4', OUT=str(run.resolve()), PY=sys.executable)
    for key in ('OLD_INSTALLER','NEW_INSTALLER','FROM','SKIP'): env.pop(key,None)
    receipt = {'machine':'CS2-GEN4','stagingPath':r'C:\Windows\Temp\roo-industries-percent-folders\roo-industries-driver-private\source','runRoot':r'C:\Windows\Temp\roo-industries-percent-folders\roo-industries-driver-private','manifestSha256':'0'*64,'frameId':'0'*32}
    results = []
    def refuses(name, command, expected, changes=None):
        result=subprocess.run(['bash',str(shell),*command],env=dict(env,**(changes or {})),capture_output=True,text=True)
        (out/(name+'.log')).write_text(result.stdout+result.stderr)
        passed=result.returncode != 0 and expected in result.stdout+result.stderr
        results.append({'name':name,'passed':passed,'exit':result.returncode})
    refuses('driver-missing-baseline-refuses',['gi','cleanup','cleanup'],'Missing explicit source/run receipt')
    receipt_file=run/'stage.json';receipt_file.write_text(json.dumps(dict(receipt,machine='OTHER')))
    refuses('driver-other-machine-refuses',['all'],'Source receipt belongs to another machine')
    receipt_file.write_text(json.dumps(receipt))
    refuses('driver-missing-old-installer-refuses',['all'],'Set OLD_INSTALLER')
    old=r'C:\retained\RooIndustries-OptimizationSuite-0.9.0-beta-setup.exe'
    refuses('driver-wrong-old-version-refuses',['all'],'Explicit old/new installer versions do not match',{'OLD_INSTALLER':old.replace('0.9.0','0.8.0')})
    refuses('driver-wrong-new-version-refuses',['lifecycle',old],'Expected 0.10.0-beta installer')
    refuses('driver-required-scenarios-cannot-skip',['all'],'Required verification phases cannot be skipped',{'OLD_INSTALLER':old,'SKIP':'invalidation'})
    refuses('driver-unknown-start-refuses',['all'],'Unknown starting phase',{'OLD_INSTALLER':old,'FROM':'unknown'})
    (out/'checks.json').write_text(json.dumps(results,indent=2))
    print(f"Driver refusal cases: {sum(row['passed'] for row in results)}/{len(results)}")
    return int(any(not row['passed'] for row in results))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--only', choices=('stage', 'wrapper', 'gi', 'driver', 'all'), default='all')
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=False)
    if args.only == 'driver': return driver_checks(args.out)
    host, machine = 'blackwell-lan', 'CS2-GEN4'
    parent = r'C:\Windows\Temp\roo-industries-percent-folders'
    guard = transport.REMOTE_GUARDS + f"\n$frame={transport.ps_literal(parent)};Assert-ProtectedFrame $frame;if([IO.File]::ReadAllText((Join-Path $frame 'fixture-owner.txt')).Trim() -cne 'Roo Industries percent folders owned scratch'){{throw 'Wrong parent identity'}};$cpu=(Get-CimInstance Win32_Processor).Name;$gpu=@(Get-CimInstance Win32_VideoController|ForEach-Object {{$_.Name}});if($cpu -notmatch '9950X3D' -or ($gpu -join ',') -notmatch 'RTX.*6000'){{throw 'Wrong fixture hardware'}};@{{cpu=$cpu;gpu=$gpu;tasks=@(Get-ScheduledTask -TaskName '*CS2*' -ErrorAction SilentlyContinue|ForEach-Object {{$r=Get-OwnedTaskReceipt $_.TaskName $_.TaskPath;$r}})}}|ConvertTo-Json -Depth 12"
    guard = guard.replace("$r=Get-OwnedTaskReceipt $_.TaskName $_.TaskPath;$r", "$s=New-Object -ComObject Schedule.Service;$s.Connect();$t=$s.GetFolder($_.TaskPath).GetTask($_.TaskName);@{name=$_.TaskName;path=$_.TaskPath;xml=$t.Xml;sddl=$t.GetSecurityDescriptor(7)}")
    before = transport.invoke(host, machine, guard, timeout=transport.SOURCE_TIMEOUT).stdout
    (args.out / 'machine-before.json').write_text(before)
    results = []
    extra_frames = []
    receipt = transport.upload(host, machine, 'roo-industries-installed-ownership', True, parent)
    (args.out / 'stage.json').write_text(json.dumps(receipt, indent=2))
    manifest = json.loads(transport.invoke(host, machine, f"Get-Content -Raw -LiteralPath {transport.ps_literal(receipt['stagingPath'] + '/source-verification.json')}").stdout)
    (args.out / 'source-manifest.json').write_text(json.dumps(manifest, indent=2))
    def case(name, body):
        try:
            detail = body()
            results.append({'name': name, 'passed': True, 'detail': detail})
            print('PASS ' + name, flush=True)
        except Exception as error:
            results.append({'name': name, 'passed': False, 'error': str(error)})
            if isinstance(error, subprocess.CalledProcessError): (args.out/(name+'-failure.log')).write_text((error.stdout or '')+(error.stderr or ''))
            print('FAIL ' + name + ': ' + str(error), flush=True)
    def require(ok, text):
        if not ok: raise AssertionError(text)
    script = 'tools/validation/Governor/Test-InstalledFixtureOwnership.ps1'
    if args.only in ('stage', 'all'):
        def staged_helpers():
            for name in ('tools/validation/LoadTimes/CleanupOwnership.Common.ps1', script):
                require(name in manifest['files'], 'Untracked helper missing: ' + name)
                require(manifest['files'][name] == hashlib.sha256((root/name).read_bytes()).hexdigest(), 'Source hash differs')
            transport.verify_source(host, machine, receipt)
            return len(manifest['files'])
        case('tracked-and-untracked-staged-and-hash-verified', staged_helpers)
        def repeat():
            second = transport.upload(host, machine, 'roo-industries-installed-ownership', True, parent)
            (args.out/'second-stage.json').write_text(json.dumps(second, indent=2))
            require(second['runRoot'] != receipt['runRoot'], 'Frame reused')
            transport.verify_source(host, machine, receipt)
            return second['runRoot']
        case('repeated-stage-retains-first-source', repeat)
        def substituted():
            marker = receipt['runRoot'] + '/unknown-marker-directory'
            transport.invoke(host, machine, transport.REMOTE_GUARDS + f"\nNew-ProtectedFrame {transport.ps_literal(marker)};[IO.File]::WriteAllText((Join-Path {transport.ps_literal(marker)} 'source-verification.json'),'unknown marker');[IO.File]::WriteAllText((Join-Path {transport.ps_literal(marker)} 'keep.txt'),'keep')")
            third=transport.upload(host, machine, 'roo-industries-installed-ownership', True, parent)
            extra_frames.append(third)
            (args.out/'third-stage.json').write_text(json.dumps(third,indent=2))
            transport.invoke(host, machine, f"if([IO.File]::ReadAllText({transport.ps_literal(marker + '/keep.txt')}) -cne 'keep'){{throw 'Foreign marked directory changed'}}")
            return marker
        case('unknown-marker-directory-retained', substituted)
    if args.only in ('wrapper', 'all'):
        def wrapper(mode):
            kwargs = {'Source': receipt['stagingPath'], 'OutDir': receipt['runRoot']+'/unused', 'Mode': mode, 'Value': "space and O'Brien"}
            try:
                result = transport.interactive(host, machine, receipt, script, kwargs, 1, logon_type=5)
                (args.out/('wrapper-'+mode+'.log')).write_text(result.stdout)
                require(mode == 'arguments', 'Failed child accepted')
            except subprocess.CalledProcessError as error:
                (args.out/('wrapper-'+mode+'.log')).write_text((error.stdout or '') + (error.stderr or ''))
                require(mode != 'arguments', 'Exact arguments failed')
                output = error.stdout or ''
                done = json.loads(output.splitlines()[-1])['completion']
                require(done is not None and done['childExit'] == 1 and done['status'] == 'failed', 'Done flag was not failure with exact child exit1')
            return mode
        for mode in ('arguments', 'exit1', 'exception'):
            case('interactive-' + mode, lambda mode=mode: wrapper(mode))
        def changed_task():
            name='RooIndustries_InstalledOwnership_'+uuid.uuid4().hex
            with ThreadPoolExecutor(max_workers=1) as executor:
                future=executor.submit(transport.interactive,host,machine,receipt,script,{'Source':receipt['stagingPath'],'OutDir':receipt['runRoot']+'/unused','Mode':'wait'},1,name,5)
                body=transport.REMOTE_GUARDS + f"\n. {transport.ps_literal(receipt['stagingPath']+'/tools/validation/LoadTimes/CleanupOwnership.Common.ps1')};$name={transport.ps_literal(name)};$root={transport.ps_literal(receipt['runRoot'])};"
                body+=r'''$deadline=[DateTime]::UtcNow.AddSeconds(30);$run=$null;while([DateTime]::UtcNow -lt $deadline -and -not$run){foreach($dir in Get-ChildItem -LiteralPath $root -Directory -Filter execution-*){$p=Join-Path $dir.FullName 'task.json';if((Test-Path -LiteralPath $p) -and (Test-Path -LiteralPath (Join-Path $dir.FullName 'child.json')) -and (Get-Content -Raw $p|ConvertFrom-Json).name -ceq $name){$run=$dir.FullName;break}};if(-not$run){Start-Sleep -Milliseconds 100}};if(-not$run){throw 'Private task did not launch'};$before=Get-OwnedTaskReceipt $name;$folder=Get-OwnedTaskFolder '\';$d=$folder.GetTask($name).Definition;$d.RegistrationInfo.Description='foreign substituted fixture';[void]$folder.RegisterTaskDefinition($name,$d,4,'S-1-5-18',$null,5,$null);$after=Get-OwnedTaskReceipt $name;@{run=$run;before=$before;after=$after}|ConvertTo-Json -Depth 12'''
                native=json.loads(transport.invoke(host,machine,body).stdout)
                (args.out/'wrapper-task-substitution.json').write_text(json.dumps(native,indent=2))
                refused=False
                try: future.result()
                except subprocess.CalledProcessError as error:
                    refused=True
                    (args.out/'wrapper-task-substitution.log').write_text((error.stdout or '')+(error.stderr or ''))
                    require('task definition changed' in ((error.stdout or '')+(error.stderr or '')).lower(),'Wrong task substitution refusal')
                require(refused,'Substituted task accepted')
                encoded=transport.base64.b64encode(json.dumps(native['after']).encode()).decode()
                cleanup=f". {transport.ps_literal(receipt['stagingPath']+'/tools/validation/LoadTimes/CleanupOwnership.Common.ps1')};$r=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('{encoded}'))|ConvertFrom-Json;Assert-OwnedTaskUnchanged $r;Remove-OwnedTask $r;Assert-OwnedTaskAbsent $r.name;'changed private task preserved by wrapper then exact fixture cleanup'"
                transport.invoke(host,machine,cleanup,timeout=transport.CLEANUP_TIMEOUT)
            return name
        case('interactive-substituted-task-retained',changed_task)
    if args.only in ('gi', 'all'):
        def gi():
            out = receipt['runRoot']+'/gi-private-'+uuid.uuid4().hex
            failure = None
            try:
                result = transport.interactive(host, machine, receipt, script, {'Source':receipt['stagingPath'],'OutDir':out}, 3, logon_type=3)
                (args.out/'gi.log').write_text(result.stdout)
            except subprocess.CalledProcessError as error:
                failure = error
            for artifact in ('checks.json','leftovers.json','refusals.log','task-before.json','task-after.json','scope-tasks.json','scope-real-response.json','scope-foreigncwd.json','scope-foreignroot.json'):
                result = transport.invoke(host, machine, f"$p={transport.ps_literal(out+'/'+artifact)};if(Test-Path -LiteralPath $p){{Get-Content -Raw -LiteralPath $p}}")
                if result.stdout: (args.out/('gi-'+artifact)).write_text(result.stdout)
            if failure: raise failure
            checks = json.loads((args.out/'gi-checks.json').read_text(encoding='utf-8-sig'))
            require(len(checks) == 15 and all(row.get('passed') is True for row in checks), 'Missing or failed named GI cases')
            leftovers = json.loads((args.out/'gi-leftovers.json').read_text(encoding='utf-8-sig'))
            require(leftovers == {'registryUnchanged': True, 'tasksRemaining': 0, 'processesRemaining': 0}, 'Native fixture baseline or cleanup differs')
            return out
        case('exact-GI-entry-ownership-cases', gi)
    if args.only in ('stage', 'all'):
        def substituted_marker():
            require(bool(extra_frames),'Missing private substitute source')
            changed=extra_frames[0]
            path=changed['stagingPath']+'/source-verification.json'
            transport.invoke(host,machine,f"[IO.File]::WriteAllText({transport.ps_literal(path)},'{{}}')")
            try: transport.verify_source(host,machine,changed)
            except subprocess.CalledProcessError as error:
                require('Source manifest receipt changed' in (error.stdout or '')+(error.stderr or ''),'Wrong source marker refusal')
                (args.out/'substituted-source-marker.log').write_text((error.stdout or '')+(error.stderr or ''))
                return 'substituted source marker refused'
            raise AssertionError('Source marker accepted')
        case('substituted-source-marker-refused',substituted_marker)
        def altered():
            path = receipt['stagingPath']+'/tools/validation/LoadTimes/CleanupOwnership.Common.ps1'
            transport.invoke(host, machine, f"[IO.File]::AppendAllText({transport.ps_literal(path)},'changed fixture bytes')")
            try: transport.verify_source(host, machine, receipt)
            except subprocess.CalledProcessError as error:
                require('Staged bytes changed' in (error.stderr or '')+(error.stdout or ''), 'Wrong refusal')
                (args.out/'altered-refusal.log').write_text((error.stdout or '')+(error.stderr or ''))
                return 'altered helper refused before execution; retained in source frame'
            raise AssertionError('Altered source accepted')
        case('altered-staged-untracked-helper-refused', altered)
    after = transport.invoke(host, machine, guard, timeout=transport.SOURCE_TIMEOUT).stdout
    (args.out/'machine-after.json').write_text(after)
    require(json.loads(before) == json.loads(after), 'Machine identity or unrelated CS2 task XML/SDDL changed')
    (args.out/'checks.json').write_text(json.dumps(results,indent=2))
    return int(not results or any(not row['passed'] for row in results))


if __name__ == '__main__':
    sys.exit(main())
