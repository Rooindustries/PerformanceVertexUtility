param([Parameter(Mandatory)][string]$Source,[Parameter(Mandatory)][string]$OutRoot,
 [Parameter(Mandatory)][ValidateSet('build','start-governor','verify-A','verify-B','negative','cleanup')][string]$Scenario,
 [string]$FeedUrl='',[string]$VersionA='',[string]$VersionB='')
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$subject='CN=Roo Industries Test Signing ROO-64'
. (Join-Path $Source 'tools\validation\Update\Harness.Common.ps1')
$nonce=Initialize-HarnessInvocation ('signing-'+$Scenario) $OutRoot
Enter-HarnessHostLease
Ensure-HarnessOutputDirectory $OutRoot
$directory=New-HarnessEvidenceDirectory $OutRoot ('signing-'+$Scenario)
$utf8=[Text.UTF8Encoding]::new($false)
[IO.Directory]::CreateDirectory((Get-HarnessLongPath $OutRoot))|Out-Null
. (Join-Path $Source 'backend\scripts\BrandCompatibility.Common.ps1')
$install=Join-Path $env:ProgramFiles 'Roo Industries\Optimization Suite'
$peFiles=@('app\RooIndustries.OptimizationSuite.App.exe','app\RooIndustries.OptimizationSuite.App.dll','app\Optimizer.Core.dll',
 'backend\bin\optimizer\Optimizer.Host.exe','backend\bin\optimizer\Optimizer.Host.dll','backend\bin\optimizer\Optimizer.Core.dll',
 'backend\bin\optimizer\session\RooIndustries.SessionHost.exe','backend\bin\optimizer\session\RooIndustries.SessionHost.dll','backend\bin\optimizer\session\Optimizer.Core.dll','unins000.exe')
function Save($name,$value){Write-HarnessResult $directory $name $value|Out-Null}
function SigningEnvironment($record){
 $env:ROO_INDUSTRIES_SIGNTOOL=$record.signtool
 $env:ROO_INDUSTRIES_SIGN_ARGS_JSON=@('/fd','SHA256','/sha1',$record.thumbprint)|ConvertTo-Json -Compress
 $env:ROO_INDUSTRIES_SIGN_SUBJECT=$subject
 $env:ROO_INDUSTRIES_SIGN_ALLOW_UNTRUSTED='1'
}
function Governor($action){
 Assert-HarnessHostLease
 $root=Join-Path (Get-RooIndustriesLocalDataRoot) 'process-rules'
 $text=@(& (Join-Path $install 'backend\scripts\Invoke-ProcessPolicyWorker.ps1') -Action $action -PolicyRoot $root -ConfirmApply) -join "`n"
 $result=$text|ConvertFrom-Json
 if($result.status -ne 'completed'){throw ('Governor '+$action+' failed: '+$text)}
 return $root
}
$status='fail'
try{switch($Scenario){
 'build'{
  if(-not$FeedUrl -or -not$VersionA -or -not$VersionB){throw 'Signed pair requires FeedUrl, VersionA and VersionB.'}
  $project=[xml][IO.File]::ReadAllText((Get-HarnessLongPath (Join-Path $Source 'docs\internal\frontend\RooIndustries.OptimizationSuite.App\RooIndustries.OptimizationSuite.App.csproj')))
  $framework=$project.SelectSingleNode('//TargetFramework').InnerText;$assembly=$project.SelectSingleNode('//AssemblyName').InnerText
  $intermediate=Join-Path $OutRoot ('builds\source-B\docs\internal\frontend\RooIndustries.OptimizationSuite.App\obj\x64\Release\'+$framework+'\win-x64\intermediatexaml\'+$assembly+'.dll')
  if((Get-HarnessPlainPath $intermediate).Length -ge 260){throw 'The signed build path exceeds the XAML compiler limit. Use a short output root, such as <frame>\s.'}
  if(@(Get-HarnessEntries|Where-Object {$_.kind -eq 'cert' -and $_.state -eq 'active'}).Count){throw 'This run already has a test certificate; preserve it.'}
  if(@(Get-ChildItem Cert:\CurrentUser\My|Where-Object Subject -ceq $subject).Count){throw 'An unrelated test certificate already exists; preserve it.'}
  $cert=New-SelfSignedCertificate -Type CodeSigningCert -Subject $subject -KeyAlgorithm RSA -KeyLength 3072 -CertStoreLocation Cert:\CurrentUser\My -NotAfter (Get-Date).AddDays(2)
  $certEntry=Add-HarnessEntry 'cert' @{thumbprint=$cert.Thumbprint;store='Cert:\CurrentUser\My';subject=$cert.Subject} 'signing' 'run'
  $record=@{ledgerId=$certEntry.id;thumbprint=$cert.Thumbprint;subject=$cert.Subject;createdAtUtc=[DateTime]::UtcNow.ToString('o');signtool=$null;privateKeyExported=$false;rootTrustChanged=$false}
  Save 'signing-certificate.json' $record
  $sdk=Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\bin'
  $tool=Get-ChildItem -Path (Join-Path $sdk '10.*\x64\signtool.exe') -File -ErrorAction SilentlyContinue|Sort-Object {[Version]$_.Directory.Parent.Name} -Descending|Select-Object -First 1
  if(-not$tool){
   $index=Invoke-WebRequest -UseBasicParsing 'https://api.nuget.org/v3-flatcontainer/microsoft.windows.sdk.buildtools/index.json'
   Save 'sdk-package-index.json' ($index.Content|ConvertFrom-Json)
   $version=@(($index.Content|ConvertFrom-Json).versions|Where-Object {$_ -notlike '*-*'}|Sort-Object {[Version]$_} -Descending)[0]
   $package=Get-HarnessOutputPath $directory 'sdk-buildtools.zip'
   Invoke-WebRequest -UseBasicParsing ('https://api.nuget.org/v3-flatcontainer/microsoft.windows.sdk.buildtools/'+$version+'/microsoft.windows.sdk.buildtools.'+$version+'.nupkg') -OutFile (Get-HarnessLongPath $package)
   $sdkDirectory=Join-Path $directory 'sdk-buildtools';Register-HarnessFile $package 'sdk-package'|Out-Null;New-HarnessDirectory $sdkDirectory 'sdk-tools'|Out-Null;Expand-Archive -LiteralPath (Get-HarnessLongPath $package) -DestinationPath (Get-HarnessLongPath $sdkDirectory)
   $tool=Get-HarnessTree $sdkDirectory -FilesOnly|Where-Object {(Test-HarnessVisiblePath $_ $sdkDirectory) -and $_.FullName.EndsWith('\x64\signtool.exe',[StringComparison]::OrdinalIgnoreCase)}|Select-Object -First 1
   $record.packageVersion=$version
  }
  if(-not$tool){throw 'The owned Windows SDK package contains no x64 signtool.exe.'}
  $record.signtool=$tool.FullName;Save 'signing-certificate.json' $record
  SigningEnvironment $record
  & (Join-Path $Source 'tools\validation\Update\Build-UpdatePair.ps1') -Source $Source -OutputRoot (Join-Path $OutRoot 'builds') -FeedUrl $FeedUrl -VersionA $VersionA -VersionB $VersionB
  if(-not$?){throw 'Signed pair build failed.'}
  Save 'signed-build.json' @{status='pass';certificate=$record;versionA=$VersionA;versionB=$VersionB}
 }
 {$_ -in 'verify-A','verify-B'}{
  $record=Read-HarnessLatestResult 'signing-certificate.json' 'signing-build'
  $rows=@()
  foreach($relative in $peFiles){
   $path=Join-Path $install $relative
   if(-not(Test-HarnessPath $path -PathType Leaf)){throw ('Installed signing file is missing: '+$relative)}
   $sig=Get-AuthenticodeSignature -LiteralPath $path
   $row=@{path=$relative;subject=$sig.SignerCertificate.Subject;thumbprint=$sig.SignerCertificate.Thumbprint;status=[string]$sig.Status}
   if($row.subject -cne $subject -or $row.thumbprint -cne $record.thumbprint -or $row.status -notin @('Valid','UnknownError','NotTrusted')){throw ('Installed signature differs: '+$relative)}
   $rows+=@($row)
  }
  foreach($version in $VersionA,$VersionB){
   $build=if($version -eq $VersionA){'A'}else{'B'}
   $setup=Join-Path $OutRoot ('builds\'+$build+'\RooIndustries-OptimizationSuite-'+$version+'-setup.exe')
   $sig=Get-AuthenticodeSignature -LiteralPath $setup
   if($sig.SignerCertificate.Subject -cne $subject -or $sig.SignerCertificate.Thumbprint -cne $record.thumbprint -or [string]$sig.Status -notin @('Valid','UnknownError','NotTrusted')){throw 'Setup signature differs.'}
   $rows+=@(@{path=$setup;subject=$sig.SignerCertificate.Subject;thumbprint=$sig.SignerCertificate.Thumbprint;status=[string]$sig.Status})
  }
  $root=Join-Path (Get-RooIndustriesLocalDataRoot) 'process-rules';$signedHost=Join-Path $install 'backend\bin\optimizer\Optimizer.Host.exe'
  $until=[DateTime]::UtcNow.AddSeconds(60);$status=$null
  do{$result=Invoke-HarnessHost $signedHost 'policy-status' @{schemaVersion=1;repoRoot=$install;policyRoot=$root};if($result.status -ne 'completed'){throw 'Signed governor status read failed.'};$status=$result.data;if($status.hostRunning){break};Start-Sleep -Milliseconds 200}while([DateTime]::UtcNow -lt $until)
  if(-not$status.hostRunning){throw 'Signed governor did not run.'}
  $worker=Get-CimInstance Win32_Process -Filter ('ProcessId='+$status.state.host.processId)
  $sig=Get-AuthenticodeSignature -LiteralPath $worker.ExecutablePath
  if($worker.ExecutablePath -ine $signedHost -or $sig.SignerCertificate.Subject -cne $subject){throw 'Governor does not run from signed installed Host.'}
  Save ($Scenario+'.json') @{status='pass';signatures=$rows;governor=$status;governorPath=$worker.ExecutablePath;governorSubject=$sig.SignerCertificate.Subject}
 }
 'start-governor'{
  $root=Governor 'Resume'
  Save 'governor-before-signed-seed.json' @{policyRoot=$root;action='Resume';timeUtc=[DateTime]::UtcNow.ToString('o')}
 }
 'negative'{
  $record=Read-HarnessLatestResult 'signing-certificate.json' 'signing-build';SigningEnvironment $record;$env:ROO_INDUSTRIES_SIGN_SUBJECT='CN=Wrong Subject'
  $negativeOutput=Join-Path $directory 'wrong-subject';New-HarnessDirectory $negativeOutput 'negative-build'|Out-Null
  $message=$null
  $arguments='-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+(Join-Path $Source 'tools\scripts\Build-Release.ps1')+'" -OutputRoot "'+$negativeOutput+'" -UpdateFeedUrl "'+$FeedUrl+'"'
  try{Invoke-HarnessProcess (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') $arguments 'negative-signing-build'|Out-Null}catch{$message=$_.Exception.Message}
  $installers=@(Get-HarnessChildren $negativeOutput -File -Filter '*-setup.exe' -ErrorAction SilentlyContinue)
  if(-not$message -or -not$message.Contains('Signer subject differs from SignSubject:') -or $installers.Count){throw 'Wrong subject did not fail before writing an installer.'}
  Save 'negative.json' @{status='pass';error=$message;installerCount=$installers.Count;beforeISCC=$true}
 }
 'cleanup'{
  if(Test-HarnessPath (Join-Path $install 'backend\bin\optimizer\Optimizer.Host.exe')){
   $root=Governor 'Pause';$signedHost=Join-Path $install 'backend\bin\optimizer\Optimizer.Host.exe'
   $until=[DateTime]::UtcNow.AddSeconds(40)
   do{$result=Invoke-HarnessHost $signedHost 'policy-status' @{schemaVersion=1;repoRoot=$install;policyRoot=$root};if($result.status -ne 'completed'){throw 'Signed governor status read failed.'};$status=$result.data;if(-not$status.hostRunning){break};Start-Sleep -Milliseconds 200}while([DateTime]::UtcNow -lt $until)
   if($status.hostRunning){throw 'Owned signed governor did not pause.'}
  }
  $entries=@(Get-HarnessEntries|Where-Object {$_.kind -eq 'cert' -and $_.purpose -eq 'signing'})
  if($entries.Count -ne 1 -or $entries[0].identity.store -cne 'Cert:\CurrentUser\My' -or $entries[0].identity.subject -cne $subject){throw 'No unique owned signing certificate is recorded; retained.'}
  $entry=$entries[0];$path=$entry.identity.store+'\'+$entry.identity.thumbprint
  Remove-HarnessEntry $entry
  if(Test-HarnessPath $path){throw 'Owned certificate remains.'}
  Save 'certificate-cleanup.json' @{status='pass';thumbprint=$entry.identity.thumbprint;exists=$false;rootTrustChanged=$false;privateKeyExported=$false}
 }
}

$status='pass'
}finally{$status=Complete-HarnessInvocation $status -Cleanup;Save 'invocation.json' @{status=$status;nonce=$nonce}}
