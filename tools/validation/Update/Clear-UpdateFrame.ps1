param([Parameter(Mandatory)][string]$Frame,[string]$ExpectedMachine=$env:ROO_TEST_COMPUTER)
$ErrorActionPreference='Stop'
if(-not$ExpectedMachine -or $env:COMPUTERNAME -cne $ExpectedMachine){throw 'ExpectedMachine is required and must match.'}
$root=[IO.Path]::GetFullPath($Frame).TrimEnd('\')
if($root -cnotmatch '^C:\\RooBuild\\roo-industries-[A-Za-z0-9_-]+-[a-f0-9]{32}$'){throw 'Update frame scope differs'}
if(-not[IO.Directory]::Exists($root)){throw 'Frame is missing; no ledger identity can be verified.'}
for($ancestor=$root;$ancestor;$ancestor=[IO.Path]::GetDirectoryName($ancestor)){
 if((Get-Item -LiteralPath $ancestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Linked update frame ancestry retained'}
 if($ancestor -ieq 'C:\RooBuild'){break}
}
. (Join-Path $PSScriptRoot 'Harness.Common.ps1')
$receipt=Get-Content -Raw (Join-Path $root 'source\source-verification.json')|ConvertFrom-Json
$manifestHash=(Get-FileHash (Join-Path $root 'source\source-verification.json')).Hash.ToLowerInvariant()
Open-HarnessRun $root $receipt.frameId $manifestHash ''
Assert-HarnessFrameIdle $root
$entries=@(Get-HarnessEntries|Where-Object state -EQ 'active')
$rootEntry=@($entries|Where-Object {$_.kind -eq 'folder' -and $_.identity.path -ieq $root})
if($rootEntry.Count -ne 1){throw 'Frame root has no unique creation identity; retained.'}
$source=Join-Path $root 'source'
foreach($expected in $receipt.files.PSObject.Properties){
 $path=Join-Path $source $expected.Name
 if(-not(Test-Path $path -PathType Leaf) -or (Get-FileHash $path).Hash -ine $expected.Value){throw ('Source file changed; retained: '+$expected.Name)}
}
foreach($item in @(Get-ChildItem $root -Force -Recurse)){
 if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Linked update frame entry retained'}
 if($item.PSIsContainer){continue}
 $path=$item.FullName;$relative=$path.Substring($source.Length+1).Replace('\','/')
 $manifestFile=$path.StartsWith($source+'\',[StringComparison]::OrdinalIgnoreCase) -and ($relative -eq 'source-verification.json' -or $receipt.files.PSObject.Properties[$relative])
 $tracked=@($entries|Where-Object {$_.kind -eq 'file' -and $_.identity.path -ieq $path}).Count
 $container=@($entries|Where-Object {$_.kind -eq 'folder' -and $_.purpose -ne 'source-frame' -and $path.StartsWith($_.identity.path+'\',[StringComparison]::OrdinalIgnoreCase)}).Count
 if(-not$manifestFile -and -not$tracked -and -not$container -and $path -ine (Join-Path $root 'ledger.json')){throw ('Unrecorded frame file retained: '+$path)}
}
[array]::Reverse($entries)
foreach($entry in $entries){
 if($entry.id -ceq $rootEntry[0].id -or $entry.kind -eq 'window' -or $entry.lifetime -eq 'retained'){continue}
 Remove-HarnessEntry $entry
}
$actual=Get-HarnessFolderIdentity $root
if($actual.creationTimeFileTimeUtc -cne $rootEntry[0].identity.creationTimeFileTimeUtc){throw 'Frame identity changed; retained.'}
$final=Get-Content -Raw $script:Harness.LedgerPath|ConvertFrom-Json
$final.entries|Where-Object id -CEQ $rootEntry[0].id|ForEach-Object {$_.state='removed'}
$final|ConvertTo-Json -Depth 60 -Compress
[IO.File]::Delete($script:Harness.LedgerPath);[IO.Directory]::Delete($root,$false)
