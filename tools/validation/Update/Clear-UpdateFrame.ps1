param([Parameter(Mandatory)][string]$Frame,[string]$ExpectedMachine=$env:ROO_TEST_COMPUTER)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Harness.Common.ps1')
if(-not$ExpectedMachine -or $env:COMPUTERNAME -cne $ExpectedMachine){throw 'ExpectedMachine is required and must match.'}
$root=(Get-HarnessPlainPath $Frame).TrimEnd('\')
if($root -cnotmatch '^C:\\RooBuild\\roo-industries-[A-Za-z0-9_-]+-[a-f0-9]{32}$'){throw 'Update frame scope differs'}
if(-not[IO.Directory]::Exists((Get-HarnessLongPath $root))){throw 'Frame is missing; no ledger identity can be verified.'}
for($ancestor=$root;$ancestor;$ancestor=[IO.Path]::GetDirectoryName($ancestor)){
 if((Get-HarnessItem $ancestor).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Linked update frame ancestry retained'}
 if($ancestor -ieq 'C:\RooBuild'){break}
}
$receipt=[IO.File]::ReadAllText((Get-HarnessLongPath (Join-Path $root 'source\source-verification.json')))|ConvertFrom-Json
$manifestHash=(Get-HarnessFileSha256 (Join-Path $root 'source\source-verification.json')).ToLowerInvariant()
Open-HarnessRun $root $receipt.frameId $manifestHash ''
Assert-HarnessFrameIdle $root
$entries=@(Get-HarnessEntries|Where-Object {$_.state -in 'active','error'})
$rootEntry=@($entries|Where-Object {$_.kind -eq 'folder' -and $_.identity.path -ieq $root})
if($rootEntry.Count -ne 1){throw 'Frame root has no unique creation identity; retained.'}
$source=Join-Path $root 'source'
foreach($expected in $receipt.files.PSObject.Properties){
 $path=Join-Path $source $expected.Name
 if(-not[IO.File]::Exists((Get-HarnessLongPath $path)) -or (Get-HarnessFileSha256 $path) -ine $expected.Value){throw ('Source file changed; retained: '+$expected.Name)}
}
foreach($item in @(Get-HarnessTree $root)){
 if($item.IsDirectory){
  $known=@($entries|Where-Object {$_.kind -eq 'folder' -and $_.identity.path -ieq $item.FullName}).Count
  $container=@($entries|Where-Object {$_.kind -eq 'folder' -and $_.purpose -ne 'source-frame' -and $item.FullName.StartsWith($_.identity.path+'\',[StringComparison]::OrdinalIgnoreCase)}).Count
  $manifestDirectory=$item.FullName.StartsWith($source+'\',[StringComparison]::OrdinalIgnoreCase) -and @($receipt.files.PSObject.Properties|Where-Object {$_.Name.StartsWith($item.FullName.Substring($source.Length+1).Replace('\','/')+'/',[StringComparison]::OrdinalIgnoreCase)}).Count
  if(-not$known -and -not$container -and -not$manifestDirectory){throw ('Unrecorded frame directory retained; ledger kept: '+$item.FullName)}
  continue
 }
 $path=$item.FullName;$relative=$path.Substring($source.Length+1).Replace('\','/')
 $manifestFile=$path.StartsWith($source+'\',[StringComparison]::OrdinalIgnoreCase) -and ($relative -eq 'source-verification.json' -or $receipt.files.PSObject.Properties[$relative])
 $tracked=@($entries|Where-Object {$_.kind -eq 'file' -and $_.identity.path -ieq $path}).Count
 $container=@($entries|Where-Object {$_.kind -eq 'folder' -and $_.purpose -ne 'source-frame' -and $path.StartsWith($_.identity.path+'\',[StringComparison]::OrdinalIgnoreCase)}).Count
 if(-not$manifestFile -and -not$tracked -and -not$container -and $path -ine (Join-Path $root 'ledger.json')){throw ('Unrecorded frame file retained: '+$path)}
}
[array]::Reverse($entries)
$lease=@($entries|Where-Object purpose -EQ 'host-lease')
foreach($entry in $entries){
 if($entry.purpose -eq 'host-lease' -or $entry.id -ceq $rootEntry[0].id -or $entry.lifetime -eq 'retained'){continue}
 Remove-HarnessEntry $entry
}
foreach($entry in $lease){Remove-HarnessEntry $entry}
$actual=Get-HarnessFolderIdentity $root
if($actual.creationTimeFileTimeUtc -cne $rootEntry[0].identity.creationTimeFileTimeUtc){throw 'Frame identity changed; retained.'}
$saved=[IO.File]::ReadAllBytes((Get-HarnessLongPath $script:Harness.LedgerPath))
$final=[Text.Encoding]::UTF8.GetString($saved)|ConvertFrom-Json
if(@(Get-HarnessTree $root|Where-Object FullName -INE $script:Harness.LedgerPath).Count){throw 'Frame is not empty after cleanup; ledger kept.'}
$final.entries|Where-Object id -CEQ $rootEntry[0].id|ForEach-Object {$_.state='removed'}
[IO.File]::Delete((Get-HarnessLongPath $script:Harness.LedgerPath))
try{[IO.Directory]::Delete((Get-HarnessLongPath $root),$false)}catch{
 if([IO.Directory]::Exists((Get-HarnessLongPath $root)) -and (Get-HarnessFolderIdentity $root).creationTimeFileTimeUtc -ceq $rootEntry[0].identity.creationTimeFileTimeUtc -and -not(Test-HarnessPath $script:Harness.LedgerPath)){
  $stream=[IO.FileStream]::new((Get-HarnessLongPath $script:Harness.LedgerPath),[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
  try{$stream.Write($saved,0,$saved.Length);$stream.Flush($true)}finally{$stream.Dispose()}
 }
 throw
}
$final|ConvertTo-Json -Depth 60 -Compress
