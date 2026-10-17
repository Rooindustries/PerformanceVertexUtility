param([Parameter(Mandatory=$true)][string]$Script,[Parameter(Mandatory=$true)][string]$OutDir)
$ErrorActionPreference='Stop'
[IO.Directory]::CreateDirectory($OutDir)|Out-Null
$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($Script,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Launcher source does not parse'}
foreach($node in $ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]},$false)){if($node.Name -in @('Get-UserEnvironmentValue','Use-UserEnvironment','Set-UserEnvironment')){. ([scriptblock]::Create($node.Extent.Text))}}
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class RooIndustriesGovernorEnvBroadcast { public static void Send() {} }
public sealed class RooIndustriesEnvironmentFixture : IDisposable {
 [DllImport("advapi32.dll",CharSet=CharSet.Unicode)] static extern int RegLoadAppKeyW(string path,out IntPtr key,int access,int options,int reserved);
 [DllImport("advapi32.dll")] static extern int RegOverridePredefKey(IntPtr root,IntPtr replacement);
 [DllImport("advapi32.dll")] static extern int RegCloseKey(IntPtr key);
 IntPtr key;
 static readonly IntPtr CurrentUser=new IntPtr(unchecked((int)0x80000001));
 public RooIndustriesEnvironmentFixture(string file) { int result=RegLoadAppKeyW(file,out key,0xF003F,1,0);if(result!=0)throw new System.ComponentModel.Win32Exception(result);result=RegOverridePredefKey(CurrentUser,key);if(result!=0){RegCloseKey(key);key=IntPtr.Zero;throw new System.ComponentModel.Win32Exception(result);} }
 public void Dispose(){RegOverridePredefKey(CurrentUser,IntPtr.Zero);if(key!=IntPtr.Zero){RegCloseKey(key);key=IntPtr.Zero;}}
}
'@
function Initialize-EnvironmentBroadcast {}
function Fingerprint($Key){
 $rows=foreach($name in @($Key.GetValueNames()|Sort-Object)){@{name=$name;kind=[string]$Key.GetValueKind($name);value=$Key.GetValue($name,$null,'DoNotExpandEnvironmentNames')}}
 $bytes=[Text.Encoding]::UTF8.GetBytes(($rows|ConvertTo-Json -Depth 4 -Compress));[BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($bytes))
}
$real=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment')
$before=Fingerprint $real
$rows=@()
try {
 foreach($case in @('unrelated-new-name','changed-owned-value','deleted-owned-value','changed-between-mutations','owned-only-restore')){
  $file=Join-Path $OutDir ($case+'-'+[Guid]::NewGuid().ToString('N')+'.hive')
  $fixture=[RooIndustriesEnvironmentFixture]::new($file)
  $key=$null
  try {
   $key=[Microsoft.Win32.Registry]::CurrentUser.CreateSubKey('Environment')
   $key.SetValue('Original',[string[]]@('first','second'),[Microsoft.Win32.RegistryValueKind]::MultiString)
   $key.SetValue('Untouched','keep',[Microsoft.Win32.RegistryValueKind]::String)
   $script:cleanups=New-Object System.Collections.Generic.List[scriptblock]
   Use-UserEnvironment
   Set-UserEnvironment ([ordered]@{Original='fixture';Created='fixture-created'})
   if($case -eq 'unrelated-new-name'){$key.SetValue('UnrelatedNew','outside')}
   if($case -eq 'changed-owned-value'){$key.SetValue('Original','outside-changed')}
   if($case -eq 'deleted-owned-value'){$key.DeleteValue('Original')}
   $setError=''
   if($case -eq 'changed-between-mutations'){
    $key.SetValue('Original','outside-changed')
    try {Set-UserEnvironment ([ordered]@{Original='fixture-again'})}catch{$setError=$_.Exception.Message}
   }
   if($case -eq 'owned-only-restore'){Set-UserEnvironment ([ordered]@{original='fixture-again'}) -Remove @('Created');Set-UserEnvironment ([ordered]@{Created='fixture-final'})}
   $message=''
   try {foreach($cleanup in $script:cleanups){& $cleanup}}catch{$message=$_.Exception.Message}
   $hasOriginal=$key.GetValueNames() -contains 'Original'
   $original=$key.GetValue('Original',$null,'DoNotExpandEnvironmentNames')
   $restored=$hasOriginal -and $key.GetValueKind('Original') -eq 'MultiString' -and @($original).Count -eq 2 -and $original[0] -ceq 'first' -and $original[1] -ceq 'second'
   $passed=($key.GetValueNames() -notcontains 'Created') -and $key.GetValue('Untouched') -ceq 'keep'
   $passed=$passed -and $(switch($case){
    'unrelated-new-name' {$key.GetValue('UnrelatedNew') -ceq 'outside' -and $restored -and -not$message}
    'changed-owned-value' {$original -ceq 'outside-changed' -and $message -like '*changed outside*'}
    'deleted-owned-value' {-not$hasOriginal -and $message -like '*changed outside*'}
    'changed-between-mutations' {$original -ceq 'outside-changed' -and $setError -like '*changed outside*' -and $message -like '*changed outside*'}
    'owned-only-restore' {$restored -and -not$message}
   })
   $rows+=@{case=$case;passed=[bool]$passed;alert=$message;setAlert=$setError;originalKind=$(if($hasOriginal){[string]$key.GetValueKind('Original')}else{'missing'});unrelated=$key.GetValue('UnrelatedNew');createdPresent=($key.GetValueNames() -contains 'Created')}
  }finally{if($key){$key.Dispose()};$fixture.Dispose()}
 }
 $after=Fingerprint $real
 $rows+=@{case='real-user-environment-preserved';passed=($before -ceq $after);beforeHash=$before;afterHash=$after}
}finally{$real.Dispose()}
$rows|ConvertTo-Json -Depth 5|Set-Content -LiteralPath (Join-Path $OutDir 'environment-cleanup.json') -Encoding UTF8
foreach($row in $rows){$(if($row.passed){'PASS '}else{'FAIL '})+$row.case}
exit [int](@($rows|Where-Object {-not$_.passed}).Count -gt 0)
