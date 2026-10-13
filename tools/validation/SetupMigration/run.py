from pathlib import Path
import importlib.util
import subprocess
import tarfile
import tempfile
import uuid
import json
import hashlib

ROOT = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location('windows_ssh', ROOT / 'tools/validation/windows_ssh.py')
w = importlib.util.module_from_spec(spec)
spec.loader.exec_module(w)
HOST, MACHINE = 'optimizer-9070', 'SERVI-WINDOWS-D'
RUN = 'roo-industries-setup-migration-' + uuid.uuid4().hex
remote = 'C:\\Windows\\Temp\\' + RUN
out = ROOT / 'artifacts/continuation/setup-migration-evidence' / RUN
out.mkdir(parents=True)
identity = w.inspect(HOST, MACHINE)
if not identity['admin']:
    raise RuntimeError('The fixture requires an elevated token')
script = r'''
$cpu=(Get-CimInstance Win32_Processor).Name
$gpu=@((Get-CimInstance Win32_VideoController).Name)
if($cpu -notmatch '14600K' -or -not($gpu -match 'RX 9070 XT')){throw 'Unexpected hardware'}
$root=REMOTE
if(Test-Path -LiteralPath $root){throw 'Fixture collision'}
$acl=[Security.AccessControl.DirectorySecurity]::new()
$acl.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))
$acl.SetAccessRuleProtection($true,$false)
foreach($sid in @('S-1-5-18','S-1-5-32-544')){$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sid),'FullControl','ContainerInherit,ObjectInherit','None','Allow'))}
[IO.Directory]::CreateDirectory($root,$acl)|Out-Null
$a=Get-Acl -LiteralPath $root
if(-not $a.AreAccessRulesProtected -or $a.Owner -notmatch 'Administrators' -or @($a.Access|Where-Object {$_.IdentityReference -notmatch 'SYSTEM|Administrators'}).Count){throw 'Fixture ACL is not admin-only'}
[IO.File]::WriteAllText((Join-Path $root 'fixture-owner.txt'),'setup-migration-f12')
'''.replace('REMOTE', w.ps_literal(remote))
w.invoke(HOST, MACHINE, script)
files = subprocess.check_output(['git','ls-files','-z'], cwd=ROOT).decode().split('\0')
files += [str(p.relative_to(ROOT)) for p in (ROOT/'tools/validation/SetupMigration').glob('*') if p.is_file()]
files = sorted(set(p for p in files if p and (ROOT/p).is_file() and not p.startswith('docs/internal/frontend/')))
files.append('docs/internal/frontend/RooIndustries.OptimizationSuite.App/Services/DataFolderGate.cs')
manifest = {'files':{p:hashlib.sha256((ROOT/p).read_bytes()).hexdigest() for p in set(files)}}
(out/'source-hashes.json').write_text(json.dumps(manifest,indent=2))
with tempfile.TemporaryDirectory(prefix='roo-f12-') as td:
    archive=Path(td)/'source.tar.gz'
    with tarfile.open(archive,'w:gz') as t:
        for p in sorted(set(files)): t.add(ROOT/p,arcname=p,recursive=False)
    subprocess.run(['scp','-q',*w.SSH_OPTIONS,str(archive),HOST+':'+remote.replace('\\','/')+'/source.tar.gz'],check=True)
w.invoke(HOST,MACHINE,'Set-Location -LiteralPath '+w.ps_literal(remote)+'; tar.exe -xzf source.tar.gz; if($LASTEXITCODE){throw "Extract failed"}',timeout=w.SOURCE_TIMEOUT)
(out/'remote-path.txt').write_text(remote)
command='& '+w.ps_literal(remote+'\\tools\\validation\\SetupMigration\\Test-SetupMigration.ps1')+' -Work '+w.ps_literal(remote)
try:
    result=w.invoke(HOST,MACHINE,command,timeout=1800)
except subprocess.CalledProcessError as error:
    result=error
(out/'run-output.txt').write_text(result.stdout or '')
(out/'run-stderr.txt').write_text(result.stderr or '')
w.invoke(HOST,MACHINE,'Set-Location -LiteralPath '+w.ps_literal(remote)+"; $files=@(Get-ChildItem -File|Where-Object {$_.Extension -in @('.txt','.json','.log')}|ForEach-Object {$_.Name}); tar.exe -czf evidence.tar.gz evidence identities @files; if($LASTEXITCODE){throw 'Evidence archive failed'}",timeout=w.EVIDENCE_TIMEOUT)
subprocess.run(['scp','-q',*w.SSH_OPTIONS,HOST+':'+remote.replace('\\','/')+'/evidence.tar.gz',str(out/'evidence.tar.gz')],check=True)
with tarfile.open(out/'evidence.tar.gz') as t:t.extractall(out,filter='data')
print(json.dumps({'returncode':result.returncode,'remote':remote,'evidence':str(out),'output':result.stdout},indent=2))

if result.returncode:
    raise SystemExit(result.returncode)
