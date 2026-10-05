param([Parameter(Mandatory)][string]$Source,[Parameter(Mandatory)][string]$RunRoot,[Parameter(Mandatory)][string]$OutDir,[string]$ExpectedMachine='SERVI-WINDOWS-D')
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$started=[DateTime]::UtcNow;$deadline=$started.AddMinutes(30)
if($env:COMPUTERNAME -ine $ExpectedMachine -or [IntPtr]::Size -ne 8){throw 'Wrong private ownership proof machine'}
. (Join-Path $Source 'tools\validation\LoadTimes\CleanupOwnership.Common.ps1')
. (Join-Path $Source 'tools\validation\LoadTimes\LoadTimesHandoff.Common.ps1')
Assert-HandoffProtected $RunRoot;Assert-HandoffProtected (Split-Path $OutDir -Parent)
if(Test-Path -LiteralPath $OutDir){throw 'Existing ownership fallback proof retained'}
[IO.Directory]::CreateDirectory($OutDir)|Out-Null
$proofChecks=[Collections.Generic.List[object]]::new();$cases=[Collections.Generic.List[object]]::new()
function Proof([bool]$Ok,[string]$Name){$proofChecks.Add(@{passed=$Ok;check=$Name});if(-not$Ok){throw $Name};'PASS '+$Name}
$harness=Join-Path $Source 'tools\validation\Release\Test-InstalledOwnershipMenu.ps1'
$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($harness,[ref]$tokens,[ref]$errors)
if($errors){throw 'Ownership harness parser failed'}
$native=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -ceq 'Add-Type'},$true))
if($native.Count -ne 1){throw 'Ownership native helper seam changed'}
Invoke-Expression $native[0].Extent.Text
foreach($name in 'State-Bytes','Stamp','State-Object','Same-Object','Menu-Rows','Menu-Absent','Call-Host','Observe-OwnedState','Undo-OwnProfile'){
 $function=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$true))
 if($function.Count -ne 1){throw ('Ownership harness function seam changed: '+$name)}
 Invoke-Expression $function[0].Extent.Text
}
$fallback=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.TryStatementAst] -and $n.Finally -and $n.Finally.Extent.Text.Contains('$applyAttempted -and -not$undoCompleted')},$true))
if($fallback.Count -ne 1){throw 'Ownership fallback finally seam changed'}
$fallbackBlock=[scriptblock]::Create(($fallback[0].Finally.Statements.Extent.Text -join "`n"))
Add-Type @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32;
public static class RooPrivateOwnershipMount {
 [DllImport("advapi32.dll")] static extern int RegOverridePredefKey(IntPtr key,IntPtr replacement);
 static RegistryKey root;
 public static void Mount(string path) {
  if(root!=null||!System.Text.RegularExpressions.Regex.IsMatch(path,@"^Software\\RooIndustriesTweakTests\\[a-f0-9]{32}$"))throw new InvalidOperationException("Private hive scope differs.");
  using(var user=RegistryKey.OpenBaseKey(RegistryHive.CurrentUser,RegistryView.Registry64))root=user.OpenSubKey(path,true);
  if(root==null)throw new InvalidOperationException("Private hive missing.");
  int error=RegOverridePredefKey(new IntPtr(unchecked((int)0x80000002)),root.Handle.DangerousGetHandle());
  if(error!=0){root.Dispose();root=null;throw new Win32Exception(error);}
 }
 public static void Unmount(){int error=RegOverridePredefKey(new IntPtr(unchecked((int)0x80000002)),IntPtr.Zero);if(root!=null){root.Dispose();root=null;}if(error!=0)throw new Win32Exception(error);}
}
'@
function Open-ClassesKey([string]$Path){
 $logical='Software\Classes\';$privatePrefix=$fixtureRegistryRoot+'\Menus\'
 if($Path.StartsWith($logical,[StringComparison]::OrdinalIgnoreCase)){$Path=$privatePrefix+$Path}
 if(-not$Path.StartsWith($privatePrefix,[StringComparison]::OrdinalIgnoreCase)){throw 'Private menu seam refused an outside address'}
 [RooInstalledOwnershipProof]::Open([Microsoft.Win32.RegistryHive]::CurrentUser,$Path)
}
function Own-MenuStamp {
 $key=Open-ClassesKey $commandKey
 if(-not$key){return @{missing=$true}}
 try{[uint32]$type=0;$bytes=[RooInstalledOwnershipProof]::Read($key,'',[ref]$type);@{missing=$false;type=$type;length=$bytes.Length;sha256=[RooInstalledOwnershipProof]::Hash($bytes)}}finally{$key.Dispose()}
}
function Preview-Apply([string]$Id,[string]$Setting){
 $path=Join-Path $private ([Guid]::NewGuid().ToString('N')+'.json')
 $plan=Call-Host 'tweak-preview' @{profileId=$Id;selections=@(@{settingId=$Setting;optionId=$choice});outputPath=$path}
 $hash=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
 $reply=Call-Host 'tweak-apply' @{previewPath=$path;reviewHash=$hash;acceptEarlierVersion=$true}
 $plan|Add-Member -NotePropertyName reviewHash -NotePropertyValue $hash
 [pscustomobject]@{plan=$plan;reply=$reply}
}
$privateRoot=Join-Path $RunRoot ('rf3-fallback-private-'+[Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($privateRoot)|Out-Null;Assert-HandoffProtected $privateRoot
$InstallRoot=Join-Path $privateRoot 'Roo Industries fixture install';$hostFolder=Join-Path $InstallRoot 'backend\bin\optimizer';$catalogFolder=Join-Path $InstallRoot 'backend\catalogs'
[IO.Directory]::CreateDirectory($catalogFolder)|Out-Null
Copy-Item -LiteralPath (Join-Path $Source 'backend\profiles') -Destination (Join-Path $InstallRoot 'backend') -Recurse
$uiExe=Join-Path $InstallRoot 'app\RooIndustries.OptimizationSuite.App.exe';[IO.Directory]::CreateDirectory((Split-Path $uiExe))|Out-Null;Copy-Item -LiteralPath (Join-Path $PSHOME 'powershell.exe') -Destination $uiExe
$programSource=Join-Path $Source 'backend\native\Optimizer.Host\Program.cs';$program=[IO.File]::ReadAllText($programSource)
$seam='request.FixturePath is null ? new RegistryTweakStore() :'
if([regex]::Matches($program,[regex]::Escape($seam)).Count -ne 1){throw 'Host RegistryTweakStore fixture seam changed'}
$replacement='request.FixturePath is null ? new RegistryTweakStore(new RegistryAddress("CurrentUser", "Registry64", System.Text.Json.JsonDocument.Parse(System.IO.File.ReadAllBytes(System.IO.Path.Combine(AppContext.BaseDirectory, "release-host-fixture.json"))).RootElement.GetProperty("statePath").GetString()!, "value", "State")) :'
$fixtureProgram=Join-Path $privateRoot 'FixtureProgram.cs';[IO.File]::WriteAllText($fixtureProgram,$program.Replace($seam,$replacement),[Text.UTF8Encoding]::new($false))
$hostExe=Join-Path $hostFolder 'Optimizer.Host.exe';$dotnet=Join-Path $env:USERPROFILE '.dotnet\dotnet.exe'
$buildArgs=@('publish',(Join-Path $Source 'tools\validation\Release\ReleaseHostFixture\ReleaseHostFixture.csproj'),'-c','Release','-r','win-x64','--self-contained','true','--disable-build-servers','-p:UseSharedCompilation=false','-p:RooIndustriesRelease=true','-p:EnableWindowsTargeting=true',('-p:FixtureProgram='+$fixtureProgram),'-o',$hostFolder)
$psi=[Diagnostics.ProcessStartInfo]::new($dotnet,(@($buildArgs|ForEach-Object {'"'+$_+'"'}) -join ' '));$psi.UseShellExecute=$false;$psi.CreateNoWindow=$true;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true
$build=[Diagnostics.Process]::Start($psi);$buildOwned=New-OwnedProcess $build
try{
 $stdout=$build.StandardOutput.ReadToEndAsync();$stderr=$build.StandardError.ReadToEndAsync()
 if(-not$build.WaitForExit([int][Math]::Min(600000,($deadline-[DateTime]::UtcNow).TotalMilliseconds))){Stop-OwnedProcess $buildOwned;throw 'Private Host fixture build exceeded its bound'}
 [IO.File]::WriteAllText((Join-Path $privateRoot 'build.log'),$stdout.Result+"`n"+$stderr.Result)
 if($build.ExitCode -ne 0){throw 'Private Host fixture build failed; retained private build.log'}
}finally{$build.Dispose()}
$filesId='windows.13b6c0d8fb231462';$foldersId='windows.c26219e8cf004354';$choice='choice-9bcf07ce29d33486';$expected='"'+$uiExe+'" --ownership-review "%1"'
try{
 foreach($caseName in 'lost-response','foreign-shared-profile','foreign-menu','foreign-unrelated-profile'){
  if([DateTime]::UtcNow -gt $deadline){throw 'Private fallback proof exceeded30minutes'}
  $caseRoot=Join-Path $privateRoot $caseName;[IO.Directory]::CreateDirectory($caseRoot)|Out-Null
  $local=Join-Path $caseRoot 'local';$private=Join-Path $caseRoot 'payloads';[IO.Directory]::CreateDirectory($local)|Out-Null;[IO.Directory]::CreateDirectory($private)|Out-Null
  [IO.File]::WriteAllText((Join-Path $caseRoot 'fixture-owner.txt'),[Guid]::NewGuid().ToString('N'))
  $fixtureRegistryRoot='Software\RooIndustriesTweakTests\'+[Guid]::NewGuid().ToString('N')
  $existing=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($fixtureRegistryRoot)
  if($existing){$existing.Dispose();throw 'Private registry GUID already exists; retained'}
  $root=[Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($fixtureRegistryRoot);$root.Dispose()
  [IO.File]::WriteAllText((Join-Path $hostFolder 'release-host-fixture.json'),(@{work=$caseRoot;local=$local;statePath=($fixtureRegistryRoot+'\Recovery')}|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
  $catalog=Get-Content -Raw -LiteralPath (Join-Path $Source 'backend\catalogs\windows-tweaks.json')|ConvertFrom-Json
  $catalog.settings=@($catalog.settings|Where-Object {$_.id -in $filesId,$foldersId});$catalog.presets=@();$catalog.incompatible=@()
  foreach($setting in $catalog.settings){foreach($option in $setting.options){foreach($change in $option.changes){if($change.address.hive -cne 'CurrentUser' -or -not$change.address.keyPath.StartsWith('Software\Classes\',[StringComparison]::OrdinalIgnoreCase)){throw 'Fixture catalog contains an outside assignment'};$change.address.keyPath=$fixtureRegistryRoot+'\Menus\'+$change.address.keyPath}}}
  [IO.File]::WriteAllText((Join-Path $catalogFolder 'windows-tweaks.json'),($catalog|ConvertTo-Json -Depth 64),[Text.UTF8Encoding]::new($false))
  $baselineProfile='baseline-'+[Guid]::NewGuid().ToString('N');$null=Preview-Apply $baselineProfile $foldersId
  [RooPrivateOwnershipMount]::Mount($fixtureRegistryRoot)
  try{
   $stateKey='Recovery';$profile='rf3-'+[Guid]::NewGuid().ToString('N');$menu='Software\Classes\*\shell\RooIndustries.TakeOwnership';$commandKey=$fixtureRegistryRoot+'\Menus\'+$menu+'\command'
   $beforeBytes=State-Bytes;$before=State-Object $beforeBytes;$menus=Menu-Rows;$ownedBytes=$null;$applyAttempted=$false;$undoCompleted=$false;$stateRestored=$false;$cleanupFailure=$null;$originalFailure='Injected private lost apply response'
   $k=[RooInstalledOwnershipProof]::Open([Microsoft.Win32.RegistryHive]::LocalMachine,$stateKey)
   try{$stateDescriptor=$k.GetAccessControl().GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]'Access, Owner, Group');$stateOther=[RooInstalledOwnershipProof]::OtherValues($k)}finally{$k.Dispose()}
   $context=@{storeId=$before.context.storeId};$result=[ordered]@{apply=$null;undo=$null}
   $applyPath=Join-Path $private 'apply.json';$plan=Call-Host 'tweak-preview' @{profileId=$profile;selections=@(@{settingId=$filesId;optionId=$choice});outputPath=$applyPath}
   $applyHash=(Get-FileHash -LiteralPath $applyPath -Algorithm SHA256).Hash;$result.apply=@{operationId=$plan.operationId;reviewHash=$applyHash}
   $receipt=Join-Path $caseRoot 'receipt.json';$result|ConvertTo-Json -Depth 10|Set-Content -LiteralPath $receipt;$receiptHash=(Get-FileHash -LiteralPath $receipt).Hash
   $applyAttempted=$true;$reply=Call-Host 'tweak-apply' @{previewPath=$applyPath;reviewHash=$applyHash;acceptEarlierVersion=$true}
   $live=State-Object (State-Bytes)
   Proof (@($live.profiles|Where-Object id -CEQ $profile).Count -eq 1 -and $reply.changed -eq $true) ($caseName+': native RegistryTweakStore apply committed its exact GUID')
   $reply=$null;$ownedBytes=$null
   $foreignId=$null;$foreignProfile=$null
   if($caseName -in 'foreign-shared-profile','foreign-unrelated-profile'){
    $foreignId='foreign-'+[Guid]::NewGuid().ToString('N');$null=Preview-Apply $foreignId $(if($caseName -ceq 'foreign-shared-profile'){$filesId}else{$foldersId})
    $foreignProfile=@((State-Object (State-Bytes)).profiles|Where-Object id -CEQ $foreignId)[0]
   }
   if($caseName -ceq 'foreign-menu'){$k=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($commandKey,$true);try{$k.SetValue('','private foreign command',[Microsoft.Win32.RegistryValueKind]::String)}finally{$k.Dispose()}}
   $stateAtFallback=Stamp (State-Bytes);$menusAtFallback=Menu-Rows;$ownMenuAtFallback=Own-MenuStamp
   . $fallbackBlock
   $afterBytes=State-Bytes;$after=State-Object $afterBytes
   Proof ((Get-FileHash -LiteralPath $receipt).Hash -ceq $receiptHash) ($caseName+': retained operation receipt is unchanged')
   if($caseName -ceq 'lost-response'){
    Proof ($undoCompleted -and $stateRestored -and -not$cleanupFailure) 'lost-response: actual fallback undo and transactional fixture cleanup complete'
    Proof ((Stamp $afterBytes).sha256 -ceq (Stamp $beforeBytes).sha256 -and $afterBytes.Length -eq $beforeBytes.Length -and (Menu-Absent) -and (Same-Object (Menu-Rows) $menus)) 'lost-response: fixture State and every menu row restore exactly'
    Proof (@($after.profiles|Where-Object id -CEQ $profile).Count -eq 0 -and @($after.profiles|Where-Object id -CEQ $baselineProfile).Count -eq 1) 'lost-response: only the live owned GUID profile is undone'
   }elseif($caseName -ceq 'foreign-unrelated-profile'){
    Proof ($undoCompleted -and -not$stateRestored -and $cleanupFailure -like 'State fixture cleanup: Other profiles*') 'foreign-unrelated-profile: original State overwrite is refused after own GUID undo'
    $afterForeign=@($after.profiles|Where-Object id -CEQ $foreignId)[0]
    Proof ((Same-Object $afterForeign $foreignProfile) -and (Same-Object (Menu-Rows) $menus) -and (Menu-Absent)) 'foreign-unrelated-profile: foreign profile and menu rows survive exact own undo'
   }else{
    Proof (-not$undoCompleted -and -not$stateRestored -and $cleanupFailure -like 'Host undo: Undo review exceeds*') ($caseName+': actual fallback refuses the changed or shared menu')
    Proof ((Stamp $afterBytes).sha256 -ceq $stateAtFallback.sha256 -and $afterBytes.Length -eq $stateAtFallback.length -and (Same-Object (Menu-Rows) $menusAtFallback) -and (Same-Object (Own-MenuStamp) $ownMenuAtFallback)) ($caseName+': foreign State and menu data remain unchanged')
   }
   $cases.Add(@{name=$caseName;privateRegistryRoot=$fixtureRegistryRoot;ownProfile=$profile;foreignProfile=$foreignId;beforeState=(Stamp $beforeBytes);stateAtFallback=$stateAtFallback;afterState=(Stamp $afterBytes);ownMenuAtFallback=$ownMenuAtFallback;ownMenuAfter=(Own-MenuStamp);undoCompleted=$undoCompleted;stateRestored=$stateRestored;cleanupRefusal=$cleanupFailure;receiptSha256=$receiptHash;receiptPath=$receipt;privatePayloadsRetained=$true})
  }finally{[RooPrivateOwnershipMount]::Unmount()}
 }
}catch{$proofChecks.Add(@{passed=$false;check=$_.Exception.Message});'FAIL '+($_.Exception.Message)}
$summary=@{phase='rf3-ownership-fallback-private';machine=$env:COMPUTERNAME;passed=($cases.Count -eq 4 -and @($proofChecks|Where-Object {-not$_.passed}).Count -eq 0);checks=$proofChecks.ToArray();cases=$cases.ToArray();privateRoot=$privateRoot;realStateAccessed=$false;installedProductUsed=$false;harnessSha256=(Get-FileHash -LiteralPath $harness).Hash;hostProgramSha256=(Get-FileHash -LiteralPath $programSource).Hash;fixtureProgramSha256=(Get-FileHash -LiteralPath $fixtureProgram).Hash;durationSeconds=([DateTime]::UtcNow-$started).TotalSeconds}
$summary|ConvertTo-Json -Depth 20|Set-Content -LiteralPath (Join-Path $OutDir 'result.json')
exit [int](-not$summary.passed)
