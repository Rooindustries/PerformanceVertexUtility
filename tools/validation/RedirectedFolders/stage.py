from pathlib import Path
import sys,json,hashlib,subprocess,tarfile,io,tempfile
root=Path(__file__).resolve().parents[3]
sys.path.insert(0,str(root/'tools/validation'));import windows_ssh as w
host,machine='blackwell-lan','CS2-GEN4';remote=r'C:\Windows\Temp\roo-industries-f10-implementation';phase=sys.argv[1]
files=[p for area in ['backend/native/Optimizer.Core','backend/native/CpuSets','backend/catalogs','tools/validation/RedirectedFolders'] for p in (root/area).rglob('*') if p.is_file() and not any(x in p.parts for x in ['bin','obj','__pycache__'])]
files += [root/p for p in ['backend/scripts/BrandCompatibility.Common.ps1','backend/scripts/Invoke-GovernorSetup.ps1','tools/release/SetupProcess.iss','tools/release/SetupProcess.Test.iss','tools/validation/Governor/Test-GovernorSetupFallbacks.ps1']]
manifest={str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for p in files}
local=root/'artifacts/continuation/redirected-folders-implementation';local.mkdir(exist_ok=True)
(local/(phase+'-source-hashes.json')).write_text(json.dumps(manifest,indent=2))
print(w.inspect(host,machine))
w.invoke(host,machine,"$root="+w.ps_literal(remote)+";if((Test-Path -LiteralPath $root) -and -not(Test-Path -LiteralPath (Join-Path $root 'fixture-owner.txt'))){throw 'Unowned scratch'};[IO.Directory]::CreateDirectory($root)|Out-Null;Set-Content -LiteralPath (Join-Path $root 'fixture-owner.txt') -Value 'F10 implementation owned scratch';[IO.Directory]::CreateDirectory((Join-Path $root 'redir\\Local'))|Out-Null;[IO.Directory]::CreateDirectory((Join-Path $root 'redir\\Roaming'))|Out-Null")
with tempfile.TemporaryDirectory() as td:
 archive=Path(td)/'f10.tar.gz'
 with tarfile.open(archive,'w:gz') as t:
  for p in files:t.add(p,arcname=str(p.relative_to(root)),recursive=False)
 subprocess.run(['scp','-q',*w.SSH_OPTIONS,str(archive),host+':'+remote.replace('\\','/')+'/f10.tar.gz'],check=True)
w.invoke(host,machine,"$root="+w.ps_literal(remote)+";tar.exe -xzf (Join-Path $root 'f10.tar.gz') -C $root;if($LASTEXITCODE){throw 'Extract failed'}",timeout=w.SOURCE_TIMEOUT)
print(remote)
