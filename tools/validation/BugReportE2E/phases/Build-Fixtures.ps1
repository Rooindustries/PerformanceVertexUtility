param([Parameter(Mandatory)][string]$Source,[Parameter(Mandatory)][string]$FixtureRoot,[Parameter(Mandatory)][string]$BuildOut,[Parameter(Mandatory)][string]$OutRoot)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Phase.Common.ps1')
$binding=Enter-RooIndustriesPhase $Source $FixtureRoot $BuildOut $OutRoot
$mainWindowSha256=''
if($script:RooIndustriesScenario -in @('All','Rendered')){
 $mainWindowSha256=Get-RooIndustriesFileSha256 (Join-Path $Source 'docs\internal\frontend\RooIndustries.OptimizationSuite.App\MainWindow.xaml')
 Assert-RooIndustries ($mainWindowSha256 -cmatch '^[a-f0-9]{64}$') 'Original MainWindow compile binding invalid.'
}
$buildBodyError=$null
try{
 Assert-RooIndustries (@(Get-HarnessTree $BuildOut).Count -eq 0) 'BuildOut must be fresh; never rebuild in place.'
 Assert-RooIndustries ($script:RooIndustriesCommit -cmatch '^[a-f0-9]{40}$' -and $binding.appLogSha256 -cmatch '^[a-f0-9]{64}$' -and $binding.redactorSha256 -cmatch '^[a-f0-9]{64}$') 'Compile binding values invalid.'
 $folder=Join-Path $BuildOut 'binding';$null=New-HarnessDirectory $folder 'report-e2e-compile-binding' 'frame'
 $bindingFile=Join-Path $folder 'SourceBinding.cs'
 $code=@"
namespace Roo70Fixture;
public static class BuildBinding {
    public const string SourceCommit = "$script:RooIndustriesCommit";
    public const string AppLogSha256 = "$($binding.appLogSha256)";
    public const string RedactorSha256 = "$($binding.redactorSha256)";
    public const string MainWindowSha256 = "$mainWindowSha256";
}
"@
 $null=New-HarnessText $bindingFile $code 'report-e2e-compile-binding' 'frame'
 $dotnet=Join-Path $env:USERPROFILE '.dotnet\dotnet.exe'
 Assert-RooIndustries (Test-HarnessPath $dotnet -PathType Leaf) 'Existing user-local .NET SDK missing; install nothing.'
 Assert-RooIndustries ($script:RooIndustriesScenario -in @('All','AppLog','Rendered')) 'Selected build scenario is unbound.'
 $kinds=if($script:RooIndustriesScenario -ceq 'All'){@('applog','desktop')}elseif($script:RooIndustriesScenario -ceq 'AppLog'){@('applog')}elseif($script:RooIndustriesReaderAdverseRequested){@('applog','desktop')}else{@('desktop')}
 foreach($kind in $kinds){
  $output=Join-Path $BuildOut $kind;$null=New-HarnessDirectory $output ('report-e2e-'+$kind+'-build') 'frame'
  $intermediate=Join-Path $BuildOut ('intermediate\'+$kind);$null=New-HarnessDirectory $intermediate ('report-e2e-'+$kind+'-intermediate') 'frame'
  $project=if($kind -ceq 'applog'){'applog\Roo70LogProof.csproj'}else{'desktop\RenderedBugReport.csproj'}
  $arguments=@('build',(Join-Path $FixtureRoot $project),'-c','Release','--disable-build-servers','-p:EnableWindowsTargeting=true',('-p:RooIndustriesBindingFile='+$bindingFile),'-o',($output+[IO.Path]::DirectorySeparatorChar),'--artifacts-path',$intermediate)
  if($kind -ceq 'desktop'){$arguments+=@('-p:Platform=x64','-r','win-x64')}
  $native=Invoke-RooIndustriesOwnedCommand $dotnet $arguments $FixtureRoot $OutRoot ('report-e2e-'+$kind+'-build') 600
  $expected=if($kind -ceq 'applog'){'Roo70LogProof.dll'}else{'Roo70.RenderedBugReportFixture.exe'}
  $matches=@(Get-HarnessTree $output -FilesOnly|Where-Object {[IO.Path]::GetFileName($_.FullName) -ceq $expected})
  Assert-RooIndustries ($matches.Count -eq 1 -and $matches[0].FullName -ieq (Join-Path $output $expected)) 'Unique expected fixture binary missing; prerequisites may be unavailable.'
  $files=Register-RooIndustriesTree $BuildOut 'report-e2e-build-output'
  if($kind -ceq 'desktop'){
   $xbfPaths=@('App.xbf','Views\BugReportPage.xbf','Resources\Theme.BlackoutGold.xbf','Resources\Brand.xbf','Resources\Styles.xbf')
   foreach($relative in $xbfPaths){Assert-RooIndustries (Test-HarnessPath (Join-Path $output $relative) -PathType Leaf) ('Expected fixture XBF path missing: '+$relative)}
   $pri=Join-Path $output 'Roo70.RenderedBugReportFixture.pri';Assert-RooIndustries (Test-HarnessPath $pri -PathType Leaf) 'Fixture PRI missing.'
   $lists=@(Get-HarnessTree $intermediate -FilesOnly|Where-Object {[IO.Path]::GetFileName($_.FullName) -ceq 'embed.resfiles'})
   Assert-RooIndustries ($lists.Count -eq 1) 'Unique fixture embedded-resource list missing.'
   $embedded=@((Read-HarnessInputText $lists[0].FullName) -split '\r?\n'|Where-Object {$_ -cne ''}|ForEach-Object {$_.Replace('/','\')})
   Assert-RooIndustries ($embedded.Count -eq $xbfPaths.Count -and @($embedded|Sort-Object -Unique).Count -eq $xbfPaths.Count -and @(Compare-Object $xbfPaths $embedded -CaseSensitive).Count -eq 0) 'Fixture embedded XBF paths differ from the actual XAML resource paths.'
   $null=New-HarnessText (Join-Path $OutRoot 'build-desktop-xaml-layout.json') (@{sourceCommit=$script:RooIndustriesCommit;uiNonce=$binding.uiNonce;invocationNonce=$binding.invocationNonce;pri=$pri;resourceList=$lists[0].FullName;resourceListSha256=(Get-RooIndustriesOriginalFile $lists[0].FullName).identity.hash;xbfPaths=$xbfPaths;embeddedXbfPaths=$embedded}|ConvertTo-Json -Depth 10) 'report-e2e-xaml-layout' 'frame'
  }
  $build=@{schemaVersion=1;kind=$kind;helperBuild=($kind -ceq 'applog' -and $script:RooIndustriesScenario -ceq 'Rendered' -and $script:RooIndustriesReaderAdverseRequested);sourceCommit=$script:RooIndustriesCommit;sourceManifestSha256=(ConvertTo-RooIndustriesSha256 $script:Harness.Manifest);uiNonce=$binding.uiNonce;invocationNonce=$binding.invocationNonce;nativeExit=$native.exit;files=$files;generatedBinding=$bindingFile;appLogSha256=$binding.appLogSha256;redactorSha256=$binding.redactorSha256;nativeExecuted=$false}
  $null=New-HarnessText (Join-Path $OutRoot ('build-'+$kind+'-binding.json')) ($build|ConvertTo-Json -Depth 15) 'report-e2e-build-binding' 'frame'
  Write-HarnessResult $OutRoot ('build-'+$kind+'-result.json') $build|Out-Null
 }
}
catch{$buildBodyError=$_;throw}
finally{
try{$null=Register-RooIndustriesTree $BuildOut 'report-e2e-retained-build';$null=Assert-RooIndustriesSource $Source;Assert-HarnessHostLease}
catch{
 if($null -ne $buildBodyError){throw [AggregateException]::new('Report build failed; original failure is first, followed by cleanup failure',[Exception[]]@($buildBodyError.Exception,$_.Exception))}
 throw
}
}
