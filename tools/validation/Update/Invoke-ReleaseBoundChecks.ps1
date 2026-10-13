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
 $stage=Join-Path $directory 'stage';New-HarnessDirectory $stage 'output-bound-fixture'|Out-Null
 $work=Join-Path $directory 'work';New-HarnessDirectory $work 'output-bound-fixture'|Out-Null
 $wasdk=Join-Path $work 'wasdk';New-HarnessDirectory $wasdk 'output-bound-fixture'|Out-Null
 $tokens=$null;$errors=$null
 $ast=[Management.Automation.Language.Parser]::ParseInput([IO.File]::ReadAllText((Get-HarnessLongPath (Join-Path $Source 'tools\scripts\Build-Release.ps1'))),[ref]$tokens,[ref]$errors)
 $assignments=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -ceq '$boundedOutputs'},$true))
 if($errors -or $assignments.Count -ne 1){throw 'Release output roots have multiple writers or invalid syntax.'}
 . ([scriptblock]::Create($assignments[0].Extent.Text))
 if($boundedOutputs.Count -ne 2 -or $boundedOutputs[0] -ine $stage -or $boundedOutputs[1] -ine $wasdk){throw 'Release output roots are not stage and wasdk.'}
 $folder=Join-Path $stage ('a'*80);New-HarnessDirectory $folder 'output-bound-fixture'|Out-Null
 $file=Join-Path $folder (('b'*120)+'.dll');$entry=New-HarnessText $file 'owned output fixture' 'output-bound-fixture'
 $message=$null;try{Assert-ReleasePathBound -OutputRoots $boundedOutputs}catch{$message=$_.Exception.Message}
 if($file.Length -lt 300 -or $message -notlike 'Release output path reaches the 260-character limit:*' -or -not$message.Contains($file)){throw ('Staged output bound did not see the long file: '+$message)}
 $rows+=@{check='300+ character staged file is refused';status='pass';observed=@{path=$file;length=$file.Length;message=$message;roots=$boundedOutputs}}
 Remove-HarnessEntry $entry
 $project=Join-Path $directory 'project';New-HarnessDirectory $project 'compiler-bound-fixture'|Out-Null
 $obj=Join-Path $project 'obj';New-HarnessDirectory $obj 'compiler-bound-fixture'|Out-Null
 $folder=Join-Path $obj ('c'*80);New-HarnessDirectory $folder 'compiler-bound-fixture'|Out-Null
 $objFile=Join-Path $folder (('d'*120)+'.editorconfig');New-HarnessText $objFile 'owned compiler fixture' 'compiler-bound-fixture'|Out-Null
 if($objFile.Length -lt 300){throw 'Compiler fixture did not reach 300 characters.'}
 Assert-ReleasePathBound -OutputRoots $boundedOutputs
 if(-not(Test-HarnessPath $objFile)){throw 'The compiler fixture was removed.'}
 $rows+=@{check='300+ character obj-only file is outside the tool output bound';status='pass';observed=@{path=$objFile;length=$objFile.Length;roots=$boundedOutputs;hash=Get-HarnessFileSha256 $objFile}}
 $status='pass'
}finally{
 $status=Complete-HarnessInvocation $status -Cleanup
 Write-HarnessResult $directory 'receipt.json' @{status=$status;checks=$rows}|Out-Null
}
