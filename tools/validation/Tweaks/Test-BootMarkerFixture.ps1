param([string]$DotNetPath=(Join-Path $env:USERPROFILE '.dotnet\dotnet.exe'))
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
. (Join-Path $PSScriptRoot 'BootMarkerFixture.Common.ps1')
$original=Get-TweakBootMarkerSnapshot
if(-not $original.parentExists -or $original.rows.Count){throw 'BootMarker fixture requires an existing product parent with no BootMarker; preserved'}
$evidence=Join-Path $root ('artifacts\validation\boot-marker-fixture-'+[Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($evidence)|Out-Null
$checks=[Collections.Generic.List[string]]::new()
function Check([bool]$Ok,[string]$Name){if(-not$Ok){throw $Name};$checks.Add($Name);Write-Output ('PASS '+$Name)}
function Same($A,$B){(ConvertTo-Json -InputObject $A -Depth 30 -Compress) -ceq (ConvertTo-Json -InputObject $B -Depth 30 -Compress)}
& (Join-Path $root 'backend\scripts\Build-OptimizerHost.ps1') -DotNetPath $DotNetPath *> (Join-Path $evidence 'build-host.log')
if($LASTEXITCODE -ne 0){throw 'The BootMarker fixture optimizer helper did not build.'}
& (Join-Path $root 'backend\scripts\Test-Tweaks.ps1') -DotNetPath $DotNetPath *> (Join-Path $evidence 'absent-suite.log')
Check (Same $original (Get-TweakBootMarkerSnapshot)) 'Native full Tweaks suite restores an absent BootMarker exactly'
$machine=[Microsoft.Win32.RegistryKey]::OpenBaseKey('LocalMachine','Registry64')
try{
 $parent=$machine.OpenSubKey('SOFTWARE\RooIndustriesOptimizationSuite',$true)
 try{
  $marker=$parent.CreateSubKey('BootMarker',[Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree,[Microsoft.Win32.RegistryOptions]::Volatile)
  try{
   $marker.SetValue('id',[int]17,[Microsoft.Win32.RegistryValueKind]::DWord)
   $marker.SetValue('Binary',[byte[]]@(0,255,1),[Microsoft.Win32.RegistryValueKind]::Binary)
   $marker.SetValue('Expand','%USERPROFILE%\must-stay-unexpanded',[Microsoft.Win32.RegistryValueKind]::ExpandString)
   $marker.SetValue('Multi',[string[]]@('first','second'),[Microsoft.Win32.RegistryValueKind]::MultiString)
   $marker.SetValue('QWord',[long]::MinValue,[Microsoft.Win32.RegistryValueKind]::QWord)
   $marker.SetValue('None',[byte[]]@(9,0),[Microsoft.Win32.RegistryValueKind]::None)
   $security=$marker.GetAccessControl([Security.AccessControl.AccessControlSections]::All)
   $security.AddAccessRule([Security.AccessControl.RegistryAccessRule]::new([Security.Principal.WindowsIdentity]::GetCurrent().User,[Security.AccessControl.RegistryRights]::QueryValues,[Security.AccessControl.AccessControlType]::Allow))
   $marker.SetAccessControl($security)
   $child=$marker.CreateSubKey('FixtureChild',[Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree,[Microsoft.Win32.RegistryOptions]::Volatile)
   try{$child.SetValue('Id','child-owned',[Microsoft.Win32.RegistryValueKind]::String)}finally{$child.Dispose()}
  }finally{$marker.Dispose()}
  $seed=Get-TweakBootMarkerSnapshot
  $seed|ConvertTo-Json -Depth 30|Set-Content -LiteralPath (Join-Path $evidence 'typed-before.json') -Encoding UTF8
  try{
   & (Join-Path $root 'backend\scripts\Test-Tweaks.ps1') -DotNetPath $DotNetPath *> (Join-Path $evidence 'typed-suite.log')
   $after=Get-TweakBootMarkerSnapshot
   $after|ConvertTo-Json -Depth 30|Set-Content -LiteralPath (Join-Path $evidence 'typed-after.json') -Encoding UTF8
   Check (Same $seed $after) 'Native full Tweaks suite restores lowercase typed Id, all value kinds, child Id, and exact security'
  }finally{
   if(-not (Same $seed (Get-TweakBootMarkerSnapshot))){throw 'Typed fixture differs from its exact receipt; retained'}
   $gate=[Threading.Mutex]::new($false,'Global\RooIndustriesBootMarker');$held=$false
   try{$held=$gate.WaitOne(30000)}catch [Threading.AbandonedMutexException]{$held=$true}
   if(-not$held){$gate.Dispose();throw 'Typed fixture cleanup mutex timeout'}
   try{
    if(-not (Same $seed (Get-TweakBootMarkerSnapshot))){throw 'Typed fixture drifted before cleanup; retained'}
    $marker=$parent.OpenSubKey('BootMarker',$true)
    try{$child=$marker.OpenSubKey('FixtureChild',$true);try{$child.DeleteValue('Id',$true)}finally{$child.Dispose()};$marker.DeleteSubKey('FixtureChild',$true);foreach($value in $seed.rows[0].values){$marker.DeleteValue($value.name,$true)};if($marker.ValueCount -or $marker.SubKeyCount){throw 'Typed fixture has new neighbors; retained'}}finally{$marker.Dispose()}
    $parent.DeleteSubKey('BootMarker',$true)
   }finally{$gate.ReleaseMutex();$gate.Dispose()}
  }
 }finally{$parent.Dispose()}
}finally{$machine.Dispose()}
Check (Same $original (Get-TweakBootMarkerSnapshot)) 'Typed fixture leaves the original product parent and absent marker unchanged'
$fake=Join-Path $evidence 'fail-after-current-boot.cmd'
$dll=Join-Path $root 'tools\validation\Tweaks\bin\Release\net8.0-windows\Tweaks.dll'
if(-not(Test-Path -LiteralPath $dll)){throw 'Actual native Tweaks assembly missing'}
[IO.File]::WriteAllText($fake,"@echo off`r`n`"$DotNetPath`" `"$dll`" `"$root`" --boot-identity`r`nexit /b 17`r`n")
$failed=$false
try{& (Join-Path $root 'backend\scripts\Test-Tweaks.ps1') -DotNetPath $fake *> (Join-Path $evidence 'forced-native-failure.log')}catch{if($_.Exception.Message -cne 'Tweak engine checks failed'){throw};$failed=$true}
Check $failed 'Actual CurrentBoot child runs before a forced exit 17 reaches the validator failure path'
Check (Same $original (Get-TweakBootMarkerSnapshot)) 'Validator finally restores an absent marker after the actual native child fails'
[ordered]@{passed=$true;checks=@($checks.ToArray());original=$original;final=(Get-TweakBootMarkerSnapshot);evidence=$evidence}|ConvertTo-Json -Depth 30|Set-Content -LiteralPath (Join-Path $evidence 'result.json') -Encoding UTF8
Write-Output ('BootMarker fixture evidence: '+$evidence)
