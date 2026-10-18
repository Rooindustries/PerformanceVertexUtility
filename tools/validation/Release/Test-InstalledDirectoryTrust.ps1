param([Parameter(Mandatory=$true)][string]$Source,[Parameter(Mandatory=$true)][string]$OutDir,[Parameter(Mandatory=$true)][string[]]$Directories,[string]$ExpectedMachine='SERVI-WINDOWS-D')
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
. (Join-Path $Source 'tools\validation\LoadTimes\CleanupOwnership.Common.ps1')
if($env:COMPUTERNAME -ine $ExpectedMachine){throw 'Wrong native proof machine'}
function Protected([string]$Path){
 $p=[IO.Path]::GetFullPath($Path)
 while($p){if((Get-Item -LiteralPath $p -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Linked proof path'};$p=[IO.Path]::GetDirectoryName($p)}
 $a=Get-Acl -LiteralPath $Path
 if($a.GetOwner([Security.Principal.SecurityIdentifier]).Value -notin 'S-1-5-18','S-1-5-32-544'){throw 'Unprotected proof owner'}
 foreach($r in $a.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])){if($r.AccessControlType -eq 'Allow' -and $r.IdentityReference.Value -notin 'S-1-5-18','S-1-5-32-544' -and ([long]$r.FileSystemRights -band 0x500D0156)){throw 'Unprotected proof writer'}}
}
Protected $Source;Protected (Split-Path $OutDir -Parent)
if(Test-Path -LiteralPath $OutDir){throw 'Existing proof evidence retained'}
[IO.Directory]::CreateDirectory($OutDir)|Out-Null
$dotnet=Join-Path $env:USERPROFILE '.dotnet\dotnet.exe'
$invocations=[Collections.Generic.List[object]]::new()
function Run([string[]]$Arguments,[string]$Label){
 $psi=[Diagnostics.ProcessStartInfo]::new($dotnet,(($Arguments|ForEach-Object {if($_ -match '["\r\n]'){throw 'Invalid proof argument'};'"'+$_+'"'}) -join ' '));$psi.UseShellExecute=$false;$psi.CreateNoWindow=$true;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true;$psi.WorkingDirectory=$OutDir
 foreach($name in @($psi.EnvironmentVariables.Keys)){if($name -match '^(DOTNET_|COMPlus_|CORECLR_|COR_|COREHOST_)'){$psi.EnvironmentVariables.Remove($name)}}
 $p=[Diagnostics.Process]::Start($psi)
 try{
  $handle=$p.Handle;$id=[ordered]@{pid=$p.Id;creationTimeFileTimeUtc=[RooIndustriesValidationOwnership.Native]::Created($handle).ToString();image=[RooIndustriesValidationOwnership.Native]::Image($handle)};$stdout=$p.StandardOutput.ReadToEndAsync();$stderr=$p.StandardError.ReadToEndAsync()
  if(-not$p.WaitForExit(300000)){$p.Kill();$p.WaitForExit();throw 'Owned native trust proof timed out'}
  [IO.File]::WriteAllText((Join-Path $OutDir ($Label+'.log')),$stdout.Result+"`n"+$stderr.Result,[Text.UTF8Encoding]::new($false));$invocations.Add(@{label=$Label;identity=$id;status='completed';exit=$p.ExitCode})
  if($p.ExitCode -ne 0){throw ('Native trust '+$Label+' failed; see retained log')}
  return [string]$stdout.Result
 }finally{$p.Dispose()}
}
try{
 $core=Join-Path $Source 'backend\native\Optimizer.Core\Optimizer.Core.csproj';$proof=Join-Path $Source 'tools\validation\Release\InstalledTrustProof\InstalledTrustProof.csproj'
 $product=Join-Path $OutDir 'product';$probe=Join-Path $OutDir 'probe'
 $null=Run @('build',$core,'-c','Release','-p:RooIndustriesRelease=true','--disable-build-servers','-p:UseSharedCompilation=false','-m:1','-nodeReuse:false','-o',$product,'--nologo') 'product-build'
 $null=Run @('build',$proof,'-c','Release','--disable-build-servers','-p:UseSharedCompilation=false','-m:1','-nodeReuse:false','-o',$probe,'--nologo') 'probe-build'
 $arguments=@((Join-Path $probe 'InstalledTrustProof.dll'),(Join-Path $product 'Optimizer.Core.dll'),(Join-Path $product 'Optimizer.Core.pdb'),(Join-Path $Source 'backend\native\Optimizer.Core\PolicyRootSecurity.cs'))+$Directories
 $text=Run $arguments 'native-proof';$result=$text|ConvertFrom-Json
 if(-not$result.passed -or -not$result.checks -or @($result.checks|Where-Object {-not$_.passed}).Count){throw 'Native product trust checks absent or failed'}
 $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $Source 'tools\validation\Release\Test-InstalledOwnershipMenu.ps1'),[ref]$tokens,[ref]$errors)
 if($errors){throw 'Installed ownership guard source malformed'}
 foreach($name in 'Assert-Plain','Assert-Protected'){$function=$ast.Find({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name},$true);if(-not$function){throw 'Installed ownership guard missing'};Invoke-Expression $function.Extent.Text}
 foreach($directory in $Directories){Assert-Protected $directory -Installed;$result.checks+=@{passed=$true;check='Installed harness accepts exact real directory ACL: '+$directory};$refused=$false;try{Assert-Protected $directory}catch{$refused=$true};if(-not$refused){throw 'Evidence guard widened to installed ACL'};$result.checks+=@{passed=$true;check='Evidence guard still refuses installed TI/CO descriptor: '+$directory}}
 Assert-Protected $Source;$result.checks+=@{passed=$true;check='SYSTEM/Admin-only source remains accepted by evidence guard'}
 foreach($check in $result.checks){'PASS '+$check.check}
 $result|Add-Member -NotePropertyName invocations -NotePropertyValue $invocations.ToArray()
 $result|ConvertTo-Json -Depth 20|Set-Content -LiteralPath (Join-Path $OutDir 'result.json') -Encoding UTF8
}catch{
 'FAIL product trust proof: '+$_.Exception.Message
 [ordered]@{phase='product-installed-directory-trust';machine=$env:COMPUTERNAME;passed=$false;checks=@(@{passed=$false;check=$_.Exception.Message});invocations=$invocations.ToArray()}|ConvertTo-Json -Depth 10|Set-Content -LiteralPath (Join-Path $OutDir 'result.json') -Encoding UTF8
 exit 1
}
