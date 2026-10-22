param([Parameter(Mandatory)][string]$Source,[Parameter(Mandatory)][string]$FixtureRoot,[Parameter(Mandatory)][string]$BuildOut,[Parameter(Mandatory)][string]$OutRoot)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Phase.Common.ps1')
$binding=Enter-RooIndustriesPhase $Source $FixtureRoot $BuildOut $OutRoot
$leafCreated=$false
$leaf=Join-Path $script:Harness.Root ('pvu70-applog-'+$binding.uiNonce)
try{
 $null=New-HarnessDirectory $leaf 'roo70-applog-owned-root' 'frame'
 $leafCreated=$true
 Assert-RooIndustries (@(Get-HarnessTree $leaf).Count -eq 0) 'AppLog owned leaf is not empty.'
 $build=Get-RooIndustriesBuild $BuildOut $OutRoot 'applog'
 $dll=Join-Path $BuildOut 'applog\Roo70LogProof.dll';$null=Get-RooIndustriesOriginalFile $dll
 $native=Invoke-RooIndustriesOwnedCommand (Join-Path $env:USERPROFILE '.dotnet\dotnet.exe') @($dll,$script:Harness.Root,$leaf,$binding.uiNonce) (Join-Path $BuildOut 'applog') $OutRoot 'roo70-applog' 30
 $lines=@($native.stdout -split '\r?\n'|Where-Object {-not[string]::IsNullOrWhiteSpace($_)})
 Assert-RooIndustries ($lines.Count -eq 1) 'Expected exactly one AppLog JSON receipt.'
 $receipt=$lines[0]|ConvertFrom-Json
 Assert-RooIndustries ($receipt.native -eq $true -and $receipt.productionStartupProved -eq $false -and $receipt.sourceCommit -ceq $script:RooIndustriesCommit -and $receipt.nonce -ceq $binding.uiNonce -and $receipt.positiveMarker -ceq 'ROO_INDUSTRIES_BUG_REPORT_APPLOG_9PASS' -and $receipt.caseCount -eq 9 -and $receipt.passCount -eq 9 -and @($receipt.cases).Count -eq 9) 'No positive nine-case exact-source native AppLog proof.'
 Assert-RooIndustries ((ConvertTo-RooIndustriesSha256 $receipt.sourceHashes.appLog) -ceq $binding.appLogSha256 -and (ConvertTo-RooIndustriesSha256 $receipt.sourceHashes.redactor) -ceq $binding.redactorSha256) 'AppLog linked source hashes differ.'
 Assert-RooIndustries ($receipt.path -ieq (Join-Path $leaf 'logs\app.log') -and $receipt.ownedLogRoot -ieq $leaf -and $receipt.frameRoot -ieq $script:Harness.Root -and (ConvertTo-RooIndustriesSha256 $receipt.assemblySha256) -ceq (Get-RooIndustriesFileSha256 $dll)) 'AppLog sink/assembly escaped original binding.'
 $profile=[Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile);$user=[Environment]::UserName;$machine=[Environment]::MachineName
 Assert-RooIndustries ($receipt.environment.profile -ceq $profile -and $receipt.environment.user -ceq $user -and $receipt.environment.machine -ceq $machine) 'Private native environment binding differs.'
 $userExpected=[regex]::Replace($user,'(?<![\p{L}\p{N}_])'+[regex]::Escape($machine)+'(?![\p{L}\p{N}_])','<pc-name>',[Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [Text.RegularExpressions.RegexOptions]::CultureInvariant)
 if($userExpected -ceq $user){$userExpected='<user>'}
 $expectedCases=@(
  @('raw',('C:\Users\'+"Zqx Bob O'Neil\AppData\x.log"),'C:\Users\<user>\AppData\x.log'),
  @('forward',('C:/Users/'+'Zqxbob/AppData/x.log'),'C:/Users/<user>/AppData/x.log'),
  @('r9','C:/Users/\u003Cuser\u003E%USERPROFILE%\u003Cuser\u003EZqxbob/x','C:/Users/<user>/x'),
  @('own',($profile+'\AppData\x.log'),'%USERPROFILE%\AppData\x.log'),
  @('user',$user,$userExpected),@('machine',$machine,'<pc-name>'),
  @('sid','S-1-5-21-11-22-33-44','<sid>'),
  @('shared','C:/Users/Public/x.log','C:/Users/Public/x.log'),
  @('already-redacted','C:/Users/<user>/x.log','C:/Users/<user>/x.log'))
 for($i=0;$i -lt 9;$i++){
  $case=$receipt.cases[$i];$expected=$expectedCases[$i]
  Assert-RooIndustries ($case.id -ceq $expected[0] -and $case.input -ceq $expected[1] -and $case.expected -ceq $expected[2] -and $case.passed -eq $true -and $case.actualPayload -ceq $expected[2]) 'Independent AppLog nine-case values differ.'
  Assert-RooIndustriesScalars $case.actualPayload
 }
 $files=@(Get-HarnessTree $leaf -FilesOnly);Assert-RooIndustries ($files.Count -eq 1 -and $files[0].FullName -ieq $receipt.path) 'Unexpected AppLog file or rotation.'
 Assert-RooIndustries ((Get-RooIndustriesFileSha256 $receipt.path) -ceq (ConvertTo-RooIndustriesSha256 $receipt.fileSha256) -and $files[0].Length -eq $receipt.fileLength -and $receipt.fileLength -gt 0 -and $receipt.fileLength -lt $receipt.maxBytes) 'Actual log hash/length differs.'
 $bytes=[IO.File]::ReadAllBytes((Get-HarnessLongPath $receipt.path));Assert-RooIndustries ([Convert]::ToBase64String($bytes) -ceq $receipt.fileBytesBase64) 'Actual disk bytes differ from receipt.'
 $utf8=[Text.UTF8Encoding]::new($false,$true);$log=$utf8.GetString($bytes);Assert-RooIndustriesScalars $log;$logLines=@($log.TrimEnd("`r","`n") -split '\r?\n');Assert-RooIndustries ($logLines.Count -eq 9) 'Actual log does not contain nine writes.'
 for($i=0;$i -lt 9;$i++){Assert-RooIndustries ($logLines[$i] -ceq ($receipt.cases[$i].timestamp+' [roo70-fixture] '+$receipt.cases[$i].expected)) 'Actual timestamp/tag/payload line differs.'}
 $null=Register-RooIndustriesTree $leaf 'roo70-applog-file'
 $null=Copy-HarnessFile $receipt.path (Join-Path $OutRoot 'app.log') 'roo70-private-applog-evidence' 'frame'
 $null=New-HarnessText (Join-Path $OutRoot 'applog-private-receipt.json') $lines[0] 'roo70-private-environment-evidence' 'frame'
 Write-HarnessResult $OutRoot 'applog-proof.json' @{readerAdverse=$native.readerAdverse;sourceCommit=$script:RooIndustriesCommit;sourceManifestSha256=(ConvertTo-RooIndustriesSha256 $script:Harness.Manifest);binaryFiles=$build.files;uiNonce=$binding.uiNonce;invocationNonce=$binding.invocationNonce;caseCount=9;passCount=9;fileSha256=(ConvertTo-RooIndustriesSha256 $receipt.fileSha256);nativeExit=$native.exit;native=$true;productionStartupProved=$false;privateReceipt='applog-private-receipt.json'}|Out-Null
}finally{
 if($leafCreated -and (Test-HarnessPath $leaf)){$null=Register-RooIndustriesTree $leaf 'roo70-applog-retained-output'}
 $null=Assert-RooIndustriesSource $Source;Assert-HarnessHostLease
}
