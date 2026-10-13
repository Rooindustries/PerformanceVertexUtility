param([Parameter(Mandatory)][string]$Source,[Parameter(Mandatory)][string]$OutRoot)
$ErrorActionPreference='Stop'
. (Join-Path $Source 'tools\validation\Update\Harness.Common.ps1')
$nonce=Initialize-HarnessInvocation 'release-bound' $OutRoot
Assert-HarnessHostLease
Ensure-HarnessOutputDirectory $OutRoot
$directory=New-HarnessEvidenceDirectory $OutRoot 'release-bound'
$status='fail'
try{
 . (Join-Path $Source 'tools\scripts\Release.Checks.ps1')
 $deep=Join-Path $directory ('source-'+('a'*80))
 New-HarnessDirectory $deep 'deep-build-fixture'|Out-Null
 foreach($relative in @('tools\scripts\Build-Release.ps1','tools\scripts\Release.Checks.ps1','docs\internal\frontend\RooIndustries.OptimizationSuite.App\RooIndustries.OptimizationSuite.App.csproj')){
  $destination=Join-Path $deep $relative
  $parent=[IO.Path]::GetDirectoryName($destination)
  if(-not(Test-HarnessPath $parent)){New-HarnessDirectory $parent 'deep-build-fixture'|Out-Null}
  Copy-HarnessFile (Join-Path $Source $relative) $destination 'deep-build-fixture'|Out-Null
 }
 $xaml=Get-ReleaseXamlIntermediatePath $deep
 if($xaml.Length -lt 260){throw 'Deep fixture did not reach the build bound.'}
 $output=Join-Path $deep 'release-output'
 $message=$null
 try{& (Join-Path $deep 'tools\scripts\Build-Release.ps1') -OutputRoot $output -UpdateFeedUrl ''}catch{$message=$_.Exception.Message}
 if($message -notlike 'Release XAML path reaches the 260-character limit:*' -or (Test-HarnessPath $output)){throw ('Deep build did not refuse before output: '+$message)}
 $rows=@(@{check='CR8 deep Build-Release refuses before output';status='pass';observed=@{root=$deep;xamlPath=$xaml;xamlLength=$xaml.Length;outputAbsent=$true;message=$message}})
 $payload=Join-Path $directory 'payload';New-HarnessDirectory $payload 'output-bound-fixture'|Out-Null
 $folder=Join-Path (Join-Path $payload ('a'*90)) ('b'*90);New-HarnessDirectory $folder 'output-bound-fixture'|Out-Null
 $file=Join-Path $folder 'long-payload.dll';New-HarnessText $file 'owned output fixture' 'output-bound-fixture'|Out-Null
 $message=$null;try{Assert-ReleasePathBound -OutputRoots @($payload)}catch{$message=$_.Exception.Message}
 if($file.Length -lt 300 -or $message -notlike 'Release output path reaches the 260-character limit:*'){throw ('Published output bound did not see the long path: '+$message)}
 $rows+=@{check='CR8 output walker sees a 300+ character payload';status='pass';observed=@{path=$file;length=$file.Length;message=$message}}
 $status='pass'
}finally{
 $status=Complete-HarnessInvocation $status -Cleanup
 Write-HarnessResult $directory 'receipt.json' @{status=$status;checks=$rows}|Out-Null
}
