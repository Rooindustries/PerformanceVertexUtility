. (Join-Path $PSScriptRoot 'Contract.Common.ps1')
function Get-RooIndustriesOriginalFile([string]$Path){
 $plain=Get-HarnessPlainPath $Path
 $entries=@(Get-HarnessEntries|Where-Object {$_.kind -eq 'file' -and $_.state -eq 'active' -and $_.identity.path -ieq $plain})
 Assert-RooIndustries ($entries.Count -eq 1 -and -not[string]::IsNullOrEmpty($entries[0].identity.id)) ('Missing original file ledger: '+$plain)
 $probe=[RooIndustriesValidationOwnership.ProbeFile]::Open((Get-HarnessLongPath $plain),$entries[0].identity.id,$entries[0].identity.hash)
 $probe.Dispose()
 return $entries[0]
}
function Publish-RooIndustriesText([string]$Path,[string]$Text,[string]$Purpose){
 $pendingPath=$Path+'.'+[guid]::NewGuid().ToString('N')+'.pending'
 $pending=New-HarnessText $pendingPath $Text ($Purpose+'-pending') 'frame'
 $pendingAgain=Get-RooIndustriesOriginalFile $pendingPath
 Assert-RooIndustries ($pendingAgain.id -ceq $pending.id -and $pendingAgain.identity.id -ceq $pending.identity.id -and $pendingAgain.identity.hash -ceq $pending.identity.hash) 'Original pending file changed before publication.'
 [IO.File]::Move((Get-HarnessLongPath $pendingPath),(Get-HarnessLongPath $Path))
 $published=Register-HarnessFile $Path $Purpose 'frame'
 Assert-RooIndustries ($published.identity.id -ceq $pending.identity.id -and $published.identity.hash -ceq $pending.identity.hash -and -not(Test-HarnessPath $pendingPath)) 'Closed publication lost original file identity.'
 Set-HarnessEntryState $pending.id 'absent'
 return $published
}
function Assert-RooIndustriesOwnedDirectory([string]$Path){
 $plain=Get-HarnessPlainPath $Path
 Assert-RooIndustries (Test-RooIndustriesBelow $plain $script:Harness.Root) 'Directory is outside original frame.'
 $entry=@(Get-HarnessEntries|Where-Object {$_.kind -eq 'folder' -and $_.state -eq 'active' -and $_.identity.path -ieq $plain})
 Assert-RooIndustries ($entry.Count -eq 1 -and $entry[0].lifetime -ceq 'frame') ('Missing original frame directory creation: '+$plain)
 $identity=Get-HarnessFolderIdentity $plain
 Assert-RooIndustries ($identity.creationTimeFileTimeUtc -ceq $entry[0].identity.creationTimeFileTimeUtc) 'Original directory creation identity changed.'
 for($current=$plain;$current;$current=[IO.Path]::GetDirectoryName($current)){Assert-RooIndustries (-not((Get-HarnessItem $current).Attributes -band [IO.FileAttributes]::ReparsePoint)) 'Reparse ancestor refused.'}
 return $entry[0]
}
function Assert-RooIndustriesSource([string]$Source){
 $context=$global:RooIndustriesVerificationInvocationContext
 Assert-RooIndustries ($null -ne $context -and $context.protocol -ceq 'roo-industries-verification-invocation/v2') 'Original protocol-v2 context required.'
 Assert-RooIndustries ($script:RooIndustriesCommit -cmatch '^[a-f0-9]{40}$' -and $context.frame.sourceCommit -ceq $script:RooIndustriesCommit) 'Expected commit is not bound to the original context.'
 Assert-RooIndustries ((Get-HarnessPlainPath $Source) -ieq (Join-Path $script:Harness.Root 'source') -and (Get-HarnessPlainPath $Source) -ieq $context.frame.stagingPath) 'Source is not the original frame source.'
 Assert-RooIndustries ($context.frame.runRoot -ieq $script:Harness.Root -and $context.frame.frameId -ceq $script:Harness.FrameId -and $context.nonce -ceq $script:Harness.Nonce -and $context.frame.manifestSha256 -ceq $script:Harness.Manifest) 'Original context and Harness identities differ.'
 $manifestPath=Join-Path $Source 'source-verification.json'
 Assert-RooIndustries ((Get-RooIndustriesFileSha256 $manifestPath) -ceq (ConvertTo-RooIndustriesSha256 $script:Harness.Manifest)) 'Original source manifest changed.'
 $manifest=Get-Content -LiteralPath $manifestPath -Raw|ConvertFrom-Json
 Assert-RooIndustriesSourceBinding $manifest.commit $manifest.frameId $script:Harness.FrameId (Get-RooIndustriesFileSha256 $manifestPath) $script:Harness.Manifest
 Assert-RooIndustries ($manifest.protocol -ceq 'roo-industries-source-snapshot/v2' -and $manifest.machine -ceq $context.frame.machine -and $env:COMPUTERNAME -ieq $manifest.machine -and $manifest.sid -ceq $context.frame.sid) 'Original source machine/SID differs.'
 foreach($expected in $manifest.files.PSObject.Properties){Assert-RooIndustriesRelative $expected.Name;Assert-RooIndustries ((Get-RooIndustriesFileSha256 (Join-Path $Source $expected.Name)) -ceq (ConvertTo-RooIndustriesSha256 $expected.Value)) ('Tracked source changed: '+$expected.Name)}
 $files=@(Get-HarnessTree $Source -FilesOnly)
 Assert-RooIndustries ($files.Count -eq @($manifest.files.PSObject.Properties).Count+1 -and $context.frame.sourceFileCount -eq @($manifest.files.PSObject.Properties).Count) 'Immutable source file count differs.'
 return $manifest
}
function Read-RooIndustriesSourceText([string]$Source,[string]$Relative,$Manifest){
 Assert-RooIndustriesRelative $Relative
 $context=$global:RooIndustriesVerificationInvocationContext
 Assert-RooIndustries ($null -ne $context -and (Get-HarnessPlainPath $Source) -ieq $context.frame.stagingPath -and $Manifest.commit -ceq $script:RooIndustriesCommit -and $Manifest.frameId -ceq $script:Harness.FrameId) 'Original source text binding differs.'
 $expected=@($Manifest.files.PSObject.Properties|Where-Object {$_.Name -ceq $Relative})
 Assert-RooIndustries ($expected.Count -eq 1) ('Source text is not in the original manifest: '+$Relative)
 $hash=ConvertTo-RooIndustriesSha256 $expected[0].Value
 $stream=[IO.File]::Open((Get-HarnessLongPath (Join-Path $Source $Relative)),[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
 $sha=[Security.Cryptography.SHA256]::Create();$reader=$null
 try{
  $actual=[BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-','').ToLowerInvariant()
  Assert-RooIndustries ($actual -ceq $hash) ('Original source text hash differs: '+$Relative)
  $stream.Position=0
  $reader=[IO.StreamReader]::new($stream,[Text.UTF8Encoding]::new($false,$true),$true,4096,$true)
  return $reader.ReadToEnd()
 }finally{if($reader){$reader.Dispose()};$sha.Dispose();$stream.Dispose()}
}
function Enter-RooIndustriesPhase([string]$Source,[string]$FixtureRoot,[string]$BuildOut,[string]$OutRoot){
 Assert-RooIndustries ($null -ne $script:Harness -and $PSVersionTable.PSVersion.Major -eq 5 -and $PSVersionTable.PSVersion.Minor -eq 1 -and [IntPtr]::Size -eq 8) 'Original Windows PowerShell 5.1 x64 Harness invocation required.'
 Assert-HarnessHostLease
 $manifest=Assert-RooIndustriesSource $Source
 Assert-RooIndustries ($script:Harness.FrameId -cmatch '^[a-f0-9]{32}$' -and $script:Harness.Nonce -cmatch '^[a-f0-9]{32}$' -and $script:Harness.Root.EndsWith('-'+$script:Harness.FrameId,[StringComparison]::Ordinal)) 'Original frame/invocation binding failed.'
 Assert-RooIndustries ((Get-HarnessPlainPath $FixtureRoot) -ieq (Join-Path $Source 'tools\validation\BugReportE2E')) 'FixtureRoot must be the verified tracked report E2E subtree.'
 Assert-RooIndustries ((Get-HarnessPlainPath $BuildOut) -ieq (Join-Path $script:Harness.Root 'build') -and (Get-HarnessPlainPath $OutRoot) -ieq (Join-Path $script:Harness.Root 'report-e2e-results')) 'Fixed build/result roots differ.'
 foreach($path in @($BuildOut,$OutRoot)){
  Assert-RooIndustries (-not(Test-RooIndustriesBelow $path $Source) -and $path -ine $Source) 'Mutable path overlaps immutable source.'
  $null=Assert-RooIndustriesOwnedDirectory $path
 }
 Assert-RooIndustries ($BuildOut -ine $OutRoot -and -not(Test-RooIndustriesBelow $BuildOut $OutRoot) -and -not(Test-RooIndustriesBelow $OutRoot $BuildOut)) 'Build/result roots overlap.'
 $appLog=ConvertTo-RooIndustriesSha256 $manifest.files.'docs/internal/frontend/RooIndustries.OptimizationSuite.App/Services/AppLog.cs'
 $redactor=ConvertTo-RooIndustriesSha256 $manifest.files.'docs/internal/frontend/RooIndustries.OptimizationSuite.App/Services/BugRedactor.cs'
 Assert-RooIndustries ($appLog -cmatch '^[a-f0-9]{64}$' -and $redactor -cmatch '^[a-f0-9]{64}$') 'Verified production source hashes missing.'
 return @{manifest=$manifest;uiNonce=$script:Harness.FrameId;invocationNonce=$script:Harness.Nonce;appLogSha256=$appLog;redactorSha256=$redactor}
}
function Invoke-RooIndustriesOwnedCommand([string]$Image,[string[]]$Arguments,[string]$Working,[string]$Output,[string]$Purpose,[int]$TimeoutSeconds){
 . (Join-Path $script:Harness.Root 'source\backend\scripts\ProcessProfile.Common.ps1')
 $start=[Diagnostics.ProcessStartInfo]::new($Image);$start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true;$start.WorkingDirectory=$Working;$start.Arguments=Join-RooIndustriesWindowsArguments $Arguments
 Set-RooIndustriesReaderEnvironment $start $Purpose
 $owned=$null;$stdout=$null;$stderr=$null
 try{
  $owned=Start-OwnedProcess -StartInfo $start -Purpose $Purpose
  $stdout=$owned.process.StandardOutput.ReadToEndAsync();$stderr=$owned.process.StandardError.ReadToEndAsync()
  Write-HarnessResult $Output ($Purpose+'-process.json') @{identity=$owned.Identity;ledgerId=$owned.LedgerId;uiNonce=$script:Harness.FrameId;invocationNonce=$script:Harness.Nonce}|Out-Null
  Assert-RooIndustries ($owned.process.WaitForExit($TimeoutSeconds*1000)) ($Purpose+' timed out; no retry.')
  $exit=$owned.process.ExitCode
  $read=Read-RooIndustriesOwnedStreams $owned $stdout $stderr $Purpose $Output
  $text=$read.stdout;$errorText=$read.stderr
  $null=New-HarnessText (Join-Path $Output ($Purpose+'-stdout.log')) $text $Purpose 'frame'
  $null=New-HarnessText (Join-Path $Output ($Purpose+'-stderr.log')) $errorText $Purpose 'frame'
  Write-HarnessResult $Output ($Purpose+'-exit.json') @{nativeExit=$exit;identity=$owned.Identity;stdoutSha256=(Get-RooIndustriesStringHash $text);stderrSha256=(Get-RooIndustriesStringHash $errorText)}|Out-Null
  Assert-RooIndustries ($exit -eq 0) ($Purpose+' native exit was '+$exit)
  return @{stdout=$text;stderr=$errorText;exit=$exit;identity=$owned.Identity;readerAdverse=$read.readerAdverse}
 }finally{
  if($owned){
   Stop-OwnedProcess $owned
   Assert-RooIndustries ($owned.process.WaitForExit(5000)) 'Original process handle did not end.'
   Set-HarnessEntryState $owned.LedgerId 'absent'
   foreach($stream in @(@($stdout,'stdout'),@($stderr,'stderr'))){
    $path=Join-Path $Output ($Purpose+'-'+$stream[1]+'.log')
    if($stream[0] -and $stream[0].Wait(3000) -and -not(Test-HarnessPath $path)){$null=New-HarnessText $path ($stream[0].GetAwaiter().GetResult()) 'roo70-retained-command-output' 'frame'}
   }
  }
 }
}
function Register-RooIndustriesTree([string]$Root,[string]$Purpose){
 $null=Assert-RooIndustriesOwnedDirectory $Root
 $files=@(foreach($file in Get-HarnessTree $Root -FilesOnly){$old=@(Get-HarnessEntries|Where-Object {$_.kind -eq 'file' -and $_.state -eq 'active' -and $_.identity.path -ieq $file.FullName});if($old.Count){$entry=Get-RooIndustriesOriginalFile $file.FullName}else{$entry=Register-HarnessFile $file.FullName $Purpose 'frame'};@{path=$file.FullName;ledgerId=$entry.id;id=$entry.identity.id;sha256=$entry.identity.hash}})
 return $files
}
function Get-RooIndustriesBuild([string]$BuildOut,[string]$OutRoot,[string]$Kind){
 $path=Join-Path $OutRoot ('build-'+$Kind+'-binding.json');$null=Get-RooIndustriesOriginalFile $path
 $build=Get-Content -LiteralPath $path -Raw|ConvertFrom-Json
 Assert-RooIndustries ($build.kind -ceq $Kind -and $build.nativeExit -eq 0 -and $build.sourceCommit -ceq $script:RooIndustriesCommit -and (ConvertTo-RooIndustriesSha256 $build.sourceManifestSha256) -ceq (ConvertTo-RooIndustriesSha256 $script:Harness.Manifest) -and $build.uiNonce -ceq $script:Harness.FrameId -and $build.invocationNonce -ceq $script:Harness.Nonce) 'Original build receipt differs.'
 foreach($file in $build.files){Assert-RooIndustries (Test-RooIndustriesBelow $file.path $BuildOut) 'Build dependency escaped BuildOut.';$entry=Get-RooIndustriesOriginalFile $file.path;Assert-RooIndustries ($entry.id -ceq $file.ledgerId -and $entry.identity.id -ceq $file.id -and $entry.identity.hash -ceq $file.sha256) 'Build dependency lost original receipt identity.'}
 Assert-RooIndustries (@(Get-HarnessTree (Join-Path $BuildOut $Kind) -FilesOnly).Count -eq @($build.files|Where-Object {Test-RooIndustriesBelow $_.path (Join-Path $BuildOut $Kind)}).Count) 'Build contains unrecorded dependencies.'
 return $build
}
function Assert-RooIndustriesReaderFields($Value,[string[]]$Fields,[string[]]$Strings,[string[]]$Numbers,[string[]]$Flags){
 $keys=@(Get-RooIndustriesProperties $Value)
 Assert-RooIndustries ($keys.Count -eq $Fields.Count) 'Reader record field count differs.'
 foreach($name in $Fields){Assert-RooIndustries ($keys -ccontains $name) ('Reader record missing '+$name)}
 foreach($name in $Strings){Assert-RooIndustries ($Value.$name -is [string]) ('Reader field must be a string: '+$name)}
 foreach($name in $Numbers){Assert-RooIndustries (($Value.$name -is [int] -or $Value.$name -is [long]) -and $Value.$name -gt 0) ('Reader field must be a positive integer: '+$name)}
 foreach($name in $Flags){Assert-RooIndustries ($Value.$name -is [bool] -and $Value.$name) ('Reader native flag missing: '+$name)}
}
function Assert-RooIndustriesReaderHolder($Owned,[string]$ImageSha256){
 Assert-RooIndustries ($null -ne $Owned -and -not$Owned.process.HasExited) 'Original reader holder is no longer live.'
 $entry=@(Get-HarnessEntries|Where-Object {$_.id -ceq $Owned.LedgerId -and $_.kind -eq 'process' -and $_.state -eq 'active' -and $_.nonce -ceq $script:Harness.Nonce})
 Assert-RooIndustries ($entry.Count -eq 1 -and $entry[0].identity.pid -eq $Owned.Identity.pid -and $entry[0].identity.creationTimeFileTimeUtc -ceq $Owned.Identity.creationTimeFileTimeUtc -and $entry[0].identity.imagePath -ceq $Owned.Identity.imagePath) 'Reader holder lost original process ledger identity.'
 Assert-RooIndustries ([RooIndustriesValidationOwnership.Native]::Created($Owned.handle).ToString() -ceq $Owned.Identity.creationTimeFileTimeUtc -and [RooIndustriesValidationOwnership.Native]::Image($Owned.handle) -ceq $Owned.Identity.imagePath) 'Retained reader holder handle identity differs.'
 Assert-RooIndustries ((Get-RooIndustriesFileSha256 $Owned.Identity.imagePath) -ceq (ConvertTo-RooIndustriesSha256 $ImageSha256)) 'Original reader holder image hash changed.'
}
function Start-RooIndustriesReaderHolder([string]$Kind,[string]$Source,[string]$FixtureRoot,[string]$BuildOut,[string]$OutRoot){
 Assert-RooIndustries ($script:RooIndustriesReaderAdverseRequested -and $Kind -in @('applog','rendered') -and $null -eq $script:RooIndustriesReaderContext) 'Reader holder requires one explicit selected phase.'
 $binding=Enter-RooIndustriesPhase $Source $FixtureRoot $BuildOut $OutRoot
 $null=Get-RooIndustriesBuild $BuildOut $OutRoot 'applog'
 $parentKind=if($Kind -ceq 'applog'){'applog'}else{'desktop'}
 $null=Get-RooIndustriesBuild $BuildOut $OutRoot $parentKind
 $dll=Join-Path $BuildOut 'applog\Roo70LogProof.dll';$dllEntry=Get-RooIndustriesOriginalFile $dll
 $assembly=if($Kind -ceq 'applog'){$dll}else{Join-Path $BuildOut 'desktop\Roo70.RenderedBugReportFixture.dll'}
 $assemblyEntry=Get-RooIndustriesOriginalFile $assembly
 $leaf=Join-Path $script:Harness.Root ('reader-'+$Kind)
 foreach($other in @($Source,$BuildOut,$OutRoot,(Join-Path $script:Harness.Root 'ui-data'),(Join-Path $script:Harness.Root 'ui-output'),(Join-Path $script:Harness.Root 'capture'))){Assert-RooIndustries ($leaf -ine $other -and -not(Test-RooIndustriesBelow $leaf $other) -and -not(Test-RooIndustriesBelow $other $leaf)) 'Reader leaf overlaps a fixture root.'}
 $null=New-HarnessDirectory $leaf 'report-e2e-reader-holder' 'frame';$script:RooIndustriesReaderLeaves.Add($leaf)
 $null=Assert-RooIndustriesOwnedDirectory $leaf
 Assert-RooIndustries (@(Get-HarnessTree $leaf).Count -eq 0) 'Reader holder leaf is not empty.'
 . (Join-Path $Source 'backend\scripts\ProcessProfile.Common.ps1')
 $start=[Diagnostics.ProcessStartInfo]::new((Join-Path $env:USERPROFILE '.dotnet\dotnet.exe'))
 $start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.WorkingDirectory=Join-Path $BuildOut 'applog'
 $start.EnvironmentVariables.Remove('ROO_INDUSTRIES_REPORT_READER_HOLDER')
 $start.Arguments=Join-RooIndustriesWindowsArguments @($dll,'--reader-holder',$script:Harness.Root,$leaf,$binding.uiNonce,$Kind)
 $owned=Start-OwnedProcess -StartInfo $start -Purpose ('report-e2e-reader-'+$Kind)
 $script:RooIndustriesReaderHolders.Add($owned)
 $imageHash=Get-RooIndustriesFileSha256 $owned.Identity.imagePath
 Write-HarnessResult $OutRoot ('reader-'+$Kind+'-holder-process.json') @{identity=$owned.Identity;ledgerId=$owned.LedgerId;sourceCommit=$script:RooIndustriesCommit;sourceManifestSha256=(ConvertTo-RooIndustriesSha256 $script:Harness.Manifest);uiNonce=$binding.uiNonce;invocationNonce=$binding.invocationNonce;holderDll=$dllEntry;imageSha256=$imageHash;leaf=$leaf}|Out-Null
 $stagedPath=Join-Path $leaf 'ready-staged.json';$path=Join-Path $leaf 'ready.json';$releasePath=Join-Path $leaf 'release-ready.json';$deadline=[DateTime]::UtcNow.AddSeconds(10)
 while(-not(Test-HarnessPath $stagedPath)){Assert-RooIndustries (-not$owned.process.HasExited -and [DateTime]::UtcNow -lt $deadline) 'Original reader holder did not stage readiness within ten seconds.';Start-Sleep -Milliseconds 25}
 Assert-RooIndustries ([DateTime]::UtcNow -le $deadline) 'Original reader readiness exceeded ten seconds.'
 Assert-RooIndustriesReaderHolder $owned $imageHash
 Assert-RooIndustries (@(Get-HarnessTree $leaf -FilesOnly).Count -eq 1 -and -not(Test-HarnessPath $path) -and -not(Test-HarnessPath $releasePath)) 'Final readiness must remain absent before owner release.'
 $staged=Register-HarnessFile $stagedPath 'report-e2e-reader-staged' 'frame'
 $ready=Read-HarnessInputText $stagedPath|ConvertFrom-Json
 $strings=@('sourceCommit','frameRoot','nonce','kind','creationTimeFileTimeUtc','imageSha256','readyMarker')
 Assert-RooIndustriesReaderFields $ready @($strings+@('schemaVersion','pid')) $strings @('schemaVersion','pid') @()
 Assert-RooIndustries ($ready.schemaVersion -eq 1 -and $ready.sourceCommit -ceq $script:RooIndustriesCommit -and $ready.frameRoot -ceq $script:Harness.Root -and $ready.nonce -ceq $binding.uiNonce -and $ready.kind -ceq $Kind -and $ready.pid -eq $owned.Identity.pid -and $ready.creationTimeFileTimeUtc -ceq $owned.Identity.creationTimeFileTimeUtc -and (ConvertTo-RooIndustriesSha256 $ready.imageSha256) -ceq $imageHash -and $ready.readyMarker -ceq 'ROO_INDUSTRIES_REPORT_READER_HOLDER_READY') 'Original reader staged binding differs.'
 $stagedAgain=Get-RooIndustriesOriginalFile $stagedPath
 Assert-RooIndustries ($stagedAgain.id -ceq $staged.id -and $stagedAgain.identity.id -ceq $staged.identity.id -and $stagedAgain.identity.hash -ceq $staged.identity.hash) 'Original staged file changed before owner release.'
 $release=@{protocol='roo-industries-report-ready-release/v1';sourceCommit=$script:RooIndustriesCommit;nonce=$binding.uiNonce;kind=$Kind;pid=[int]$owned.Identity.pid;stagedSha256=(ConvertTo-RooIndustriesSha256 $staged.identity.hash)}
 $releaseEntry=Publish-RooIndustriesText $releasePath ($release|ConvertTo-Json -Compress) 'report-e2e-reader-release'
 $pendingEntries=@(Get-HarnessEntries|Where-Object {$_.kind -ceq 'file' -and $_.state -ceq 'absent' -and $_.nonce -ceq $script:Harness.Nonce -and $_.purpose -ceq 'report-e2e-reader-release-pending' -and $_.identity.id -ceq $releaseEntry.identity.id -and $_.identity.hash -ceq $releaseEntry.identity.hash})
 Assert-RooIndustries ($pendingEntries.Count -eq 1 -and -not(Test-HarnessPath $pendingEntries[0].identity.path)) 'Original closed release pending ledger differs.'
 $pending=$pendingEntries[0]
 while(-not(Test-HarnessPath $path)){Assert-RooIndustries (-not$owned.process.HasExited -and [DateTime]::UtcNow -lt $deadline) 'Original reader holder did not publish readiness within ten seconds.';Start-Sleep -Milliseconds 25}
 Assert-RooIndustries ([DateTime]::UtcNow -le $deadline) 'Original reader readiness exceeded ten seconds.'
 Assert-RooIndustriesReaderHolder $owned $imageHash
 $entry=Register-HarnessFile $path 'report-e2e-reader-ready' 'frame'
 Assert-RooIndustries ($entry.identity.id -ceq $staged.identity.id -and $entry.identity.hash -ceq $staged.identity.hash -and -not(Test-HarnessPath $stagedPath)) 'Final readiness lost the original staged file identity.'
 Set-HarnessEntryState $staged.id 'absent'
 $releaseAgain=Get-RooIndustriesOriginalFile $releasePath
 Assert-RooIndustries ($releaseAgain.id -ceq $releaseEntry.id -and $releaseAgain.identity.id -ceq $releaseEntry.identity.id -and $releaseAgain.identity.hash -ceq $releaseEntry.identity.hash -and @(Get-HarnessTree $leaf -FilesOnly).Count -eq 2) 'Final reader leaf or original release identity differs.'
 $publication=@{beforeReleaseReadyAbsent=$true;stagedOriginal=$staged;releasePendingOriginal=$pending;releaseOriginal=$releaseEntry;readyOriginal=$entry;stagedToReadySameFileIdAndHash=$true;pendingToReleaseSameFileIdAndHash=$true;stagedPathAbsent=$true;pendingPathAbsent=$true;native=$true}
 $purpose=if($Kind -ceq 'applog'){'roo70-applog'}else{'roo70-rendered-ui'}
 return @{Kind=$Kind;ExpectedPurpose=$purpose;Holder=$owned;Leaf=$leaf;ReadyEntry=$entry;ReleaseEntry=$releaseEntry;Publication=$publication;Ready=$ready;ImageSha256=$imageHash;Assembly=$assemblyEntry;Consumed=$false;Proof=$null}
}
function Set-RooIndustriesReaderEnvironment([Diagnostics.ProcessStartInfo]$Start,[string]$Purpose){
 $Start.EnvironmentVariables.Remove('ROO_INDUSTRIES_REPORT_READER_HOLDER')
 $context=$script:RooIndustriesReaderContext
 if(-not$script:RooIndustriesReaderAdverseRequested -or $null -eq $context -or $context.ExpectedPurpose -cne $Purpose){return}
 Assert-RooIndustries (-not$context.Consumed -and (($context.Kind -ceq 'applog' -and $Purpose -ceq 'roo70-applog') -or ($context.Kind -ceq 'rendered' -and $Purpose -ceq 'roo70-rendered-ui'))) 'Reader injection purpose or consumption differs.'
 Assert-RooIndustriesReaderHolder $context.Holder $context.ImageSha256
 $ready=Get-RooIndustriesOriginalFile (Join-Path $context.Leaf 'ready.json')
 Assert-RooIndustries ($ready.id -ceq $context.ReadyEntry.id -and $ready.identity.id -ceq $context.ReadyEntry.identity.id -and $ready.identity.hash -ceq $context.ReadyEntry.identity.hash) 'Reader ready identity changed before injection.'
 $release=Get-RooIndustriesOriginalFile (Join-Path $context.Leaf 'release-ready.json')
 Assert-RooIndustries ($release.id -ceq $context.ReleaseEntry.id -and $release.identity.id -ceq $context.ReleaseEntry.identity.id -and $release.identity.hash -ceq $context.ReleaseEntry.identity.hash) 'Reader release identity changed before injection.'
 $Start.EnvironmentVariables['ROO_INDUSTRIES_REPORT_READER_HOLDER']=@{protocol='roo-industries-report-reader/v1';sourceCommit=$script:RooIndustriesCommit;frameRoot=$script:Harness.Root;nonce=$script:Harness.FrameId;kind=$context.Kind;holderPid=[int]$context.Holder.Identity.pid;holderCreationTimeFileTimeUtc=[string]$context.Holder.Identity.creationTimeFileTimeUtc;holderImageSha256=$context.ImageSha256;readySha256=(ConvertTo-RooIndustriesSha256 $context.ReadyEntry.identity.hash)}|ConvertTo-Json -Compress
}
function Read-RooIndustriesOwnedStreams($Owned,$Stdout,$Stderr,[string]$Purpose,[string]$Output){
 $watch=[Diagnostics.Stopwatch]::StartNew()
 $ended=[Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($Stdout,$Stderr),10000)
 $waitMs=$watch.ElapsedMilliseconds
 $context=$script:RooIndustriesReaderContext
 if(-not$script:RooIndustriesReaderAdverseRequested -or $null -eq $context -or $context.ExpectedPurpose -cne $Purpose){
  Assert-RooIndustries $ended 'Owned stdout/stderr readers did not complete within ten seconds; retain evidence and stop without retry.'
  return @{stdout=$Stdout.GetAwaiter().GetResult();stderr=$Stderr.GetAwaiter().GetResult();readerAdverse=$null}
 }
 try{
  Assert-RooIndustries (-not$context.Consumed -and -not$ended -and -not$Stdout.IsCompleted -and -not$Stderr.IsCompleted -and $waitMs -ge 9000 -and $waitMs -le 15000) 'Expected both actual readers incomplete during the ten-second writer hold.'
  Assert-RooIndustries ($Owned.process.HasExited -and $Owned.process.ExitCode -eq 0 -and [RooIndustriesValidationOwnership.Native]::Created($Owned.handle).ToString() -ceq $Owned.Identity.creationTimeFileTimeUtc) 'Actual reader fixture parent did not exit zero under its original birth.'
  Assert-RooIndustriesReaderHolder $context.Holder $context.ImageSha256
  $ready=Get-RooIndustriesOriginalFile (Join-Path $context.Leaf 'ready.json')
  Assert-RooIndustries ($ready.id -ceq $context.ReadyEntry.id -and $ready.identity.id -ceq $context.ReadyEntry.identity.id -and $ready.identity.hash -ceq $context.ReadyEntry.identity.hash) 'Original ready file changed before reader proof.'
  $path=Join-Path $context.Leaf 'attached.json'
  Assert-RooIndustries ((Test-HarnessPath $path -PathType Leaf) -and @(Get-HarnessTree $context.Leaf -FilesOnly).Count -eq 3) 'Reader duplication receipt is missing or leaf contains unexpected files.'
  $attachedEntry=Register-HarnessFile $path 'report-e2e-reader-attached' 'frame'
  $attached=Read-HarnessInputText $path|ConvertFrom-Json
  $strings=@('protocol','sourceCommit','frameRoot','nonce','kind','holderCreationTimeFileTimeUtc','holderImageSha256','readySha256','parentCreationTimeFileTimeUtc','parentAssemblySha256','stdoutRemoteHandle','stderrRemoteHandle','utc')
  $numbers=@('holderPid','parentPid');$flags=@('stdoutIsPipe','stderrIsPipe','stdoutDuplicated','stderrDuplicated','readyShareDeleteVerified')
  Assert-RooIndustriesReaderFields $attached @($strings+$numbers+$flags) $strings $numbers $flags
  Assert-RooIndustries ($attached.protocol -ceq 'roo-industries-report-reader/v1' -and $attached.sourceCommit -ceq $script:RooIndustriesCommit -and $attached.frameRoot -ceq $script:Harness.Root -and $attached.nonce -ceq $script:Harness.FrameId -and $attached.kind -ceq $context.Kind) 'Reader duplication source/frame binding differs.'
  Assert-RooIndustries ($attached.holderPid -eq $context.Holder.Identity.pid -and $attached.holderCreationTimeFileTimeUtc -ceq $context.Holder.Identity.creationTimeFileTimeUtc -and (ConvertTo-RooIndustriesSha256 $attached.holderImageSha256) -ceq $context.ImageSha256 -and (ConvertTo-RooIndustriesSha256 $attached.readySha256) -ceq (ConvertTo-RooIndustriesSha256 $ready.identity.hash) -and $attached.parentPid -eq $Owned.Identity.pid -and $attached.parentCreationTimeFileTimeUtc -ceq $Owned.Identity.creationTimeFileTimeUtc) 'Reader duplication process/file identities differ.'
  $assembly=Get-RooIndustriesOriginalFile $context.Assembly.identity.path
  Assert-RooIndustries ($assembly.id -ceq $context.Assembly.id -and $assembly.identity.id -ceq $context.Assembly.identity.id -and $assembly.identity.hash -ceq $context.Assembly.identity.hash -and (ConvertTo-RooIndustriesSha256 $attached.parentAssemblySha256) -ceq (ConvertTo-RooIndustriesSha256 $assembly.identity.hash)) 'Reader parent assembly differs from selected original build.'
  Assert-RooIndustries ($attached.stdoutRemoteHandle -cmatch '^[1-9][0-9]*$' -and $attached.stderrRemoteHandle -cmatch '^[1-9][0-9]*$' -and $attached.stdoutRemoteHandle -cne $attached.stderrRemoteHandle) 'Reader remote handle declarations invalid.'
  $timestamp=[DateTime]::ParseExact($attached.utc,'o',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind)
  Assert-RooIndustries ($timestamp.ToFileTimeUtc() -ge [long]$context.Holder.Identity.creationTimeFileTimeUtc -and $timestamp.ToUniversalTime() -le [DateTime]::UtcNow) 'Reader duplication timestamp differs from original lifetime.'
  $again=Get-RooIndustriesOriginalFile $path
  Assert-RooIndustries ($again.id -ceq $attachedEntry.id -and $again.identity.id -ceq $attachedEntry.identity.id -and $again.identity.hash -ceq $attachedEntry.identity.hash) 'Attached original file changed before release.'
  $readyAgain=Get-RooIndustriesOriginalFile (Join-Path $context.Leaf 'ready.json')
  Assert-RooIndustries ($readyAgain.id -ceq $ready.id -and $readyAgain.identity.id -ceq $ready.identity.id -and $readyAgain.identity.hash -ceq $ready.identity.hash) 'Ready original file changed before release.'
  $releaseEntry=Get-RooIndustriesOriginalFile (Join-Path $context.Leaf 'release-ready.json')
  Assert-RooIndustries ($releaseEntry.id -ceq $context.ReleaseEntry.id -and $releaseEntry.identity.id -ceq $context.ReleaseEntry.identity.id -and $releaseEntry.identity.hash -ceq $context.ReleaseEntry.identity.hash) 'Release original file changed before reader proof.'
  Assert-RooIndustriesReaderHolder $context.Holder $context.ImageSha256
  $release=[Diagnostics.Stopwatch]::StartNew()
  Stop-OwnedProcess $context.Holder
  Assert-RooIndustries ($context.Holder.process.WaitForExit(5000) -and $context.Holder.process.ExitCode -eq 1) 'Original holder did not end by controlled stop; natural expiry never passes.'
  Set-HarnessEntryState $context.Holder.LedgerId 'absent'
  $eofWatch=[Diagnostics.Stopwatch]::StartNew()
  Assert-RooIndustries ([Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($Stdout,$Stderr),5000)) 'Actual readers did not reach EOF within five seconds after original holder stop.'
  $releaseMs=$release.ElapsedMilliseconds
  $text=$Stdout.GetAwaiter().GetResult();$errorText=$Stderr.GetAwaiter().GetResult()
  $proof=@{protocol='roo-industries-report-reader/v1';kind=$context.Kind;purpose=$Purpose;sourceCommit=$script:RooIndustriesCommit;sourceManifestSha256=(ConvertTo-RooIndustriesSha256 $script:Harness.Manifest);uiNonce=$script:Harness.FrameId;invocationNonce=$script:Harness.Nonce;parent=$Owned.Identity;parentExit=0;holder=$context.Holder.Identity;holderLedgerId=$context.Holder.LedgerId;readyOriginal=$ready;releaseOriginal=$releaseEntry;publication=$context.Publication;attachedOriginal=$attachedEntry;attached=$attached;parentAssemblyOriginal=$assembly;initialWaitAll=$ended;initialStdoutCompleted=$false;initialStderrCompleted=$false;initialWaitMs=$waitMs;holderAliveBeforeRelease=$true;holderStopped=$true;holderExit=$context.Holder.process.ExitCode;eofAfterRelease=$true;releaseAndEofMs=$releaseMs;eofWaitMs=$eofWatch.ElapsedMilliseconds;stdoutStatus=[string]$Stdout.Status;stderrStatus=[string]$Stderr.Status;stdoutSha256=(Get-RooIndustriesStringHash $text);stderrSha256=(Get-RooIndustriesStringHash $errorText);actualDuplicatedWriters=$true;actualInheritedLaunchProved=$false;normalStreamCompletionProved=$false;native=$true}
  Write-HarnessResult $Output ($Purpose+'-reader-proof.json') $proof|Out-Null
  $context.Consumed=$true;$context.Proof=$proof
  return @{stdout=$text;stderr=$errorText;readerAdverse=$proof}
 }catch{
  Write-HarnessResult $Output ($Purpose+'-reader-failure.json') @{error=$_.Exception.ToString();sourceCommit=$script:RooIndustriesCommit;kind=$context.Kind;parent=$Owned.Identity;holder=$context.Holder.Identity;waitAll=$ended;waitMs=$waitMs;stdoutStatus=[string]$Stdout.Status;stderrStatus=[string]$Stderr.Status;consumed=$context.Consumed}|Out-Null
  throw
 }
}
