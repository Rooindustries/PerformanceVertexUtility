param([Parameter(Mandatory=$true)][string]$Runner,[Parameter(Mandatory=$true)][string]$SourceTree,[Parameter(Mandatory=$true)][string]$OutDir,[Parameter(Mandatory=$true)][string]$ExpectedMachine)
$ErrorActionPreference='Stop'
if($env:COMPUTERNAME -ine $ExpectedMachine){throw 'Wrong machine'}
$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($Runner,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Runner does not parse'}
foreach($node in $ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst]},$false)){. ([scriptblock]::Create($node.Extent.Text))}
$backup=[IO.Path]::GetFullPath($OutDir)
Assert-RecoveryEvidenceParent
New-SealedDirectory $backup
$log=Join-Path $backup 'clone.log'
$env:PATH=[Environment]::GetFolderPath('System')+';'+[Environment]::GetFolderPath('Windows')+';'+$PSHOME
$sourceRows=@(Get-RecoveryRows $SourceTree)
Save-RecoveryJson (Join-Path $backup 'source-before.json') $sourceRows
$legacy=$backup+'-legacy'
$verified=$backup+'-verified'
if(Test-Path -LiteralPath $legacy){throw 'Legacy destination exists'}
if(Test-Path -LiteralPath $verified){throw 'Verified destination exists'}
$legacyResult=Invoke-Native (Join-Path ([Environment]::GetFolderPath('System')) 'robocopy.exe') @($SourceTree,$legacy,'/E','/COPYALL','/DCOPY:DAT','/XJ','/R:0','/W:0','/NFL','/NDL','/NP')
if($legacyResult.Exit -lt 0 -or $legacyResult.Exit -ge 8){throw 'Legacy copy failed'}
$legacyRows=@(Get-RecoveryRows $legacy)
$legacyDifference=@(Compare-Object (Recovery-Lines $sourceRows) (Recovery-Lines $legacyRows) -CaseSensitive)
Save-RecoveryJson (Join-Path $backup 'legacy-before-seal.json') $legacyRows
Save-RecoveryJson (Join-Path $backup 'legacy-differences.json') $legacyDifference
Restore-RecoveryDescriptors $legacyRows $legacy -Seal
Assert-SealedRecovery $legacy
Copy-VerifiedTree $SourceTree $verified|Out-Null
$verifiedRows=@(Get-RecoveryRows $verified)
Assert-RecoveryEqual (Recovery-Lines $sourceRows) (Recovery-Lines $verifiedRows) 'verified clone versus initial source'
Save-RecoveryJson (Join-Path $backup 'verified-before-seal.json') $verifiedRows
Restore-RecoveryDescriptors $verifiedRows $verified -Seal
Assert-SealedRecovery $verified
Assert-RecoveryEqual (Recovery-Lines $sourceRows) (Recovery-Lines @(Get-RecoveryRows $SourceTree)) 'live source remains unchanged'
$proof=[ordered]@{machine=$env:COMPUTERNAME;source=$SourceTree;sourceItems=$sourceRows.Count;sourceRootSddl=$sourceRows[0].sddl;legacyCopyExit=$legacyResult.Exit;legacyMatches=($legacyDifference.Count -eq 0);legacyDifferenceRows=$legacyDifference.Count;verifiedMatches=$true;sourceUnchanged=$true;copiesSealed=$true;runnerHash=(Get-FileHash -LiteralPath $Runner).Hash;testHash=(Get-FileHash -LiteralPath $PSCommandPath).Hash}
Save-RecoveryJson (Join-Path $backup 'proof.json') $proof
$proof|ConvertTo-Json -Depth 4
