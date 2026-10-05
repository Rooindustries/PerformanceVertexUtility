import argparse,importlib.util,json,subprocess,sys,uuid
from pathlib import Path
root=Path(__file__).resolve().parents[3]
spec=importlib.util.spec_from_file_location('windows_ssh',root/'tools/validation/windows_ssh.py')
t=importlib.util.module_from_spec(spec);spec.loader.exec_module(t)
parser=argparse.ArgumentParser()
parser.add_argument('--out',type=Path,required=True)
args=parser.parse_args()
out=args.out.resolve();out.mkdir(parents=True,exist_ok=False)
guard=t.REMOTE_GUARDS+"\n$parent='C:\\Windows\\Temp\\roo-industries-percent-folders';Assert-ProtectedFrame $parent;if([IO.File]::ReadAllText((Join-Path $parent 'fixture-owner.txt')).Trim() -cne 'Roo Industries percent folders owned scratch'){throw 'Wrong fixture parent'};'PASS protected fixture parent'"
(out/'parent-guard.log').write_text(t.invoke('blackwell-lan','CS2-GEN4',guard).stdout)
receipt=t.upload('blackwell-lan','CS2-GEN4','roo-industries-preflight-readiness',False,r'C:\Windows\Temp\roo-industries-percent-folders')
(out/'stage.json').write_text(json.dumps(receipt,indent=2))
p=lambda s:t.ps_literal(s)
helper=receipt['stagingPath']+'/tools/validation/LoadTimes/CleanupOwnership.Common.ps1'
foreign='RooIndustries_Verify_'+uuid.uuid4().hex
setup=t.REMOTE_GUARDS+f"\n. {p(helper)};$r=Register-OwnedProbeTask {p(foreign)} (Join-Path ([Environment]::SystemDirectory) 'PING.EXE') '-n 1 127.0.0.1' {p(receipt['runRoot'])} ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value) 4 3;$r|ConvertTo-Json -Depth 12"
r=json.loads(t.invoke('blackwell-lan','CS2-GEN4',setup).stdout)
(out/'foreign-before.json').write_text(json.dumps(r,indent=2))
results=[]
try:
    for mode in ['capture','capture','direct','contexts','performance']:
        name='RooIndustries_Verify_'+uuid.uuid4().hex
        remote=receipt['runRoot']+'/'+name
        setup=t.REMOTE_GUARDS+f"\nNew-ProtectedFrame {p(remote)};"
        if mode in ('contexts','direct'):
            setup+=f"[IO.File]::WriteAllText((Join-Path {p(remote)} 'foreign-task.json'),[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('{t.base64.b64encode(json.dumps(r).encode()).decode()}')))"
        t.invoke('blackwell-lan','CS2-GEN4',setup)
        success=True
        try:
            if mode=='direct':
                run=t.invoke('blackwell-lan','CS2-GEN4',f"& {p(receipt['stagingPath']+'/tools/validation/Release/Test-PreflightReadiness.ps1')} -Source {p(receipt['stagingPath'])} -OutDir {p(remote)} -Mode direct")
            else:
                run=t.interactive('blackwell-lan','CS2-GEN4',receipt,'tools/validation/Release/Test-PreflightReadiness.ps1',{'Source':receipt['stagingPath'],'OutDir':remote,'Mode':mode},3,name)
            output=run.stdout
        except subprocess.CalledProcessError as e:
            output=(e.stdout or '')+(e.stderr or '');success=False
        prefix=f'{len(results)}-{mode}'
        (out/(prefix+'.log')).write_text(output)
        for file in ['machine-state.json','context-checks.json','refusals.log','timings.json','bound.json','leftovers.json','worker-error.log','worker-native.json']:
            contents=t.invoke('blackwell-lan','CS2-GEN4',f"$p={p(remote+'/'+file)};if(Test-Path -LiteralPath $p){{Get-Content -Raw -LiteralPath $p}}").stdout
            if contents:(out/(prefix+'-'+file)).write_text(contents)
        if success and mode=='contexts':
            cases=json.loads((out/(prefix+'-context-checks.json')).read_text(encoding='utf-8-sig'))
            expected={'verified-current-only','missing-context-refuses','missing-task-refuses','missing-wrapper-refuses','foreign-task-refuses','parent-pid-refuses','native-parent-pid-refuses','parent-creationTimeFileTimeUtc-refuses','native-parent-creationTimeFileTimeUtc-refuses','parent-imagePath-refuses','native-parent-imagePath-refuses','task-xml-refuses','task-sddl-refuses','context-change-during-capture-refuses','direct-unwrapped-includes-all'}
            success=len(cases)==len(expected) and set(cases)==expected
        if success and mode=='performance':
            bound=json.loads((out/(prefix+'-bound.json')).read_text(encoding='utf-8-sig'))
            timings=json.loads((out/(prefix+'-timings.json')).read_text(encoding='utf-8-sig'))
            left=json.loads((out/(prefix+'-leftovers.json')).read_text(encoding='utf-8-sig'))
            success=bound['passed'] is True and bound['bound']=='' and timings['largeRestoreExact'] is True and timings['baselineBytes']>7529986 and left=={'ownedWorkerStopped':True,'privateHiveAbsent':True}
        results.append({'mode':mode,'passed':success,'task':name if mode!='direct' else None,'remote':remote})
        print(prefix,success,flush=True)
    captures=[json.loads((out/(str(i)+'-capture-machine-state.json')).read_text(encoding='utf-8-sig'))['tasks'] for i in range(2)]
    results.append({'mode':'sequential-stable-tasks','passed':captures[0]==captures[1] and ('\\'+foreign) in captures[0]})
finally:
    after=json.loads(t.invoke('blackwell-lan','CS2-GEN4',f". {p(helper)};Get-OwnedTaskReceipt {p(foreign)}|ConvertTo-Json -Depth 12").stdout)
    (out/'foreign-after.json').write_text(json.dumps(after,indent=2))
    assert after==r,'Foreign task changed'
    raw=t.base64.b64encode(json.dumps(r).encode()).decode()
    cleanup=f". {p(helper)};$r=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('{raw}'))|ConvertFrom-Json;Remove-OwnedTask $r;Assert-OwnedTaskAbsent $r.name;"
    for row in results:
        if row.get('task'):cleanup+=f"Assert-OwnedTaskAbsent {p(row['task'])};"
    cleanup+="'PASS exact owned tasks absent; foreign XML/SDDL preserved before fixture cleanup'"
    (out/'task-leftovers.log').write_text(t.invoke('blackwell-lan','CS2-GEN4',cleanup).stdout)
    (out/'checks.json').write_text(json.dumps(results,indent=2))
sys.exit(int(any(not r['passed'] for r in results)))
