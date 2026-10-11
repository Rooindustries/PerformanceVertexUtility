param([Parameter(Mandatory)][string]$Source,[Parameter(Mandatory)][string]$OutRoot,
 [Parameter(Mandatory)][ValidateSet('build','start-governor','verify-A','verify-B','negative','cleanup')][string]$Scenario,
 [string]$FeedUrl='',[string]$VersionA='',[string]$VersionB='')
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$subject='CN=Roo Industries Test Signing ROO-64'
$certificatePath=Join-Path $OutRoot 'signing-certificate.json'
$utf8=[Text.UTF8Encoding]::new($false)
[IO.Directory]::CreateDirectory($OutRoot)|Out-Null
. (Join-Path $Source 'backend\scripts\BrandCompatibility.Common.ps1')
$install=Join-Path $env:ProgramFiles 'Roo Industries\Optimization Suite'
$peFiles=@('app\RooIndustries.OptimizationSuite.App.exe','app\RooIndustries.OptimizationSuite.App.dll','app\Optimizer.Core.dll',
 'backend\bin\optimizer\Optimizer.Host.exe','backend\bin\optimizer\Optimizer.Host.dll','backend\bin\optimizer\Optimizer.Core.dll',
 'backend\bin\optimizer\session\RooIndustries.SessionHost.exe','backend\bin\optimizer\session\RooIndustries.SessionHost.dll','backend\bin\optimizer\session\Optimizer.Core.dll','unins000.exe')
function Save($name,$value){[IO.File]::WriteAllText((Join-Path $OutRoot $name),($value|ConvertTo-Json -Depth 30),$utf8)}
function SigningEnvironment($record){
 $env:ROO_INDUSTRIES_SIGNTOOL=$record.signtool
 $env:ROO_INDUSTRIES_SIGN_ARGS_JSON=@('/fd','SHA256','/sha1',$record.thumbprint)|ConvertTo-Json -Compress
 $env:ROO_INDUSTRIES_SIGN_SUBJECT=$subject
 $env:ROO_INDUSTRIES_SIGN_ALLOW_UNTRUSTED='1'
}
function Governor($action){
 $root=Join-Path (Get-RooIndustriesLocalDataRoot) 'process-rules'
 $text=@(& (Join-Path $install 'backend\scripts\Invoke-ProcessPolicyWorker.ps1') -Action $action -PolicyRoot $root -ConfirmApply) -join "`n"
 $result=$text|ConvertFrom-Json
 if($result.status -ne 'completed'){throw ('Governor '+$action+' failed: '+$text)}
 return $root
}
switch($Scenario){
 'build'{
  if(-not$FeedUrl -or -not$VersionA -or -not$VersionB){throw 'Signed pair requires FeedUrl, VersionA and VersionB.'}
  if(Test-Path $certificatePath){throw 'This certificate receipt already exists; preserve it.'}
  if(@(Get-ChildItem Cert:\CurrentUser\My|Where-Object Subject -ceq $subject).Count){throw 'An unrelated test certificate already exists; preserve it.'}
  $cert=New-SelfSignedCertificate -Type CodeSigningCert -Subject $subject -KeyAlgorithm RSA -KeyLength 3072 -CertStoreLocation Cert:\CurrentUser\My -NotAfter (Get-Date).AddDays(2)
  $record=@{thumbprint=$cert.Thumbprint;subject=$cert.Subject;createdAtUtc=[DateTime]::UtcNow.ToString('o');signtool=$null;privateKeyExported=$false;rootTrustChanged=$false}
  Save 'signing-certificate.json' $record
  $sdk=Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\bin'
  $tool=Get-ChildItem -Path (Join-Path $sdk '10.*\x64\signtool.exe') -File -ErrorAction SilentlyContinue|Sort-Object {[Version]$_.Directory.Parent.Name} -Descending|Select-Object -First 1
  if(-not$tool){
   $index=Invoke-WebRequest -UseBasicParsing 'https://api.nuget.org/v3-flatcontainer/microsoft.windows.sdk.buildtools/index.json'
   [IO.File]::WriteAllText((Join-Path $OutRoot 'sdk-package-index.json'),$index.Content,$utf8)
   $version=@(($index.Content|ConvertFrom-Json).versions|Where-Object {$_ -notlike '*-*'}|Sort-Object {[Version]$_} -Descending)[0]
   $package=Join-Path $OutRoot 'sdk-buildtools.zip'
   Invoke-WebRequest -UseBasicParsing ('https://api.nuget.org/v3-flatcontainer/microsoft.windows.sdk.buildtools/'+$version+'/microsoft.windows.sdk.buildtools.'+$version+'.nupkg') -OutFile $package
   $directory=Join-Path $OutRoot 'sdk-buildtools';Expand-Archive -LiteralPath $package -DestinationPath $directory
   $tool=Get-ChildItem $directory -Recurse -File -Filter signtool.exe|Where-Object {$_.FullName.EndsWith('\x64\signtool.exe',[StringComparison]::OrdinalIgnoreCase)}|Select-Object -First 1
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
  $record=Get-Content -Raw $certificatePath|ConvertFrom-Json
  $rows=@()
  foreach($relative in $peFiles){
   $path=Join-Path $install $relative
   if(-not(Test-Path -LiteralPath $path -PathType Leaf)){throw ('Installed signing file is missing: '+$relative)}
   $sig=Get-AuthenticodeSignature -LiteralPath $path
   $row=@{path=$relative;subject=$sig.SignerCertificate.Subject;thumbprint=$sig.SignerCertificate.Thumbprint;status=[string]$sig.Status}
   if($row.subject -cne $subject -or $row.thumbprint -cne $record.thumbprint){throw ('Installed signature differs: '+$relative)}
   $rows+=@($row)
  }
  foreach($version in $VersionA,$VersionB){
   $build=if($version -eq $VersionA){'A'}else{'B'}
   $setup=Join-Path $OutRoot ('builds\'+$build+'\RooIndustries-OptimizationSuite-'+$version+'-setup.exe')
   $sig=Get-AuthenticodeSignature -LiteralPath $setup
   if($sig.SignerCertificate.Subject -cne $subject -or $sig.SignerCertificate.Thumbprint -cne $record.thumbprint){throw 'Setup signature differs.'}
   $rows+=@(@{path=$setup;subject=$sig.SignerCertificate.Subject;thumbprint=$sig.SignerCertificate.Thumbprint;status=[string]$sig.Status})
  }
  $root=Join-Path (Get-RooIndustriesLocalDataRoot) 'process-rules';$signedHost=Join-Path $install 'backend\bin\optimizer\Optimizer.Host.exe'
  $until=[DateTime]::UtcNow.AddSeconds(60);$status=$null
  do{$request=@{schemaVersion=1;policyRoot=$root}|ConvertTo-Json;$OutputEncoding=$utf8;$status=(@($request|& $signedHost 'policy-status' '-') -join "`n"|ConvertFrom-Json).data;if($status.hostRunning){break};Start-Sleep -Milliseconds 200}while([DateTime]::UtcNow -lt $until)
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
  $record=Get-Content -Raw $certificatePath|ConvertFrom-Json;SigningEnvironment $record;$env:ROO_INDUSTRIES_SIGN_SUBJECT='CN=Wrong Subject'
  $directory=Join-Path $OutRoot 'wrong-subject'
  $message=$null
  try{& (Join-Path $Source 'tools\scripts\Build-Release.ps1') -OutputRoot $directory -UpdateFeedUrl $FeedUrl}catch{$message=$_.Exception.Message}
  $installers=@(Get-ChildItem $directory -File -Filter '*-setup.exe' -ErrorAction SilentlyContinue)
  if(-not$message -or $message -notlike 'Signer subject differs from SignSubject:*' -or $installers.Count){throw 'Wrong subject did not fail before writing an installer.'}
  Save 'negative.json' @{status='pass';error=$message;installerCount=$installers.Count;beforeISCC=$true}
 }
 'cleanup'{
  if(Test-Path (Join-Path $install 'backend\bin\optimizer\Optimizer.Host.exe')){
   $root=Governor 'Pause';$signedHost=Join-Path $install 'backend\bin\optimizer\Optimizer.Host.exe'
   $until=[DateTime]::UtcNow.AddSeconds(40)
   do{$OutputEncoding=$utf8;$status=(@((@{schemaVersion=1;policyRoot=$root}|ConvertTo-Json)|& $signedHost 'policy-status' '-') -join "`n"|ConvertFrom-Json).data;if(-not$status.hostRunning){break};Start-Sleep -Milliseconds 200}while([DateTime]::UtcNow -lt $until)
   if($status.hostRunning){throw 'Owned signed governor did not pause.'}
  }
  $record=Get-Content -Raw $certificatePath|ConvertFrom-Json
  $path='Cert:\CurrentUser\My\'+$record.thumbprint
  if(Test-Path $path){if((Get-Item $path).Subject -cne $subject){throw 'Certificate identity changed; retained.'};Remove-Item -LiteralPath $path -DeleteKey}
  if(Test-Path $path){throw 'Owned certificate remains.'}
  Save 'certificate-cleanup.json' @{status='pass';thumbprint=$record.thumbprint;exists=$false;rootTrustChanged=$false;privateKeyExported=$false}
 }
}
