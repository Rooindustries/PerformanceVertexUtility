param(
    [Parameter(Mandatory=$true)][ValidateSet('Catalog','Status','Preview','Apply','Restore','CreateFixture')][string]$Action,
    [string]$ProfileId='', [string]$SelectionsPath='', [string]$PresetId='',
    [string]$PreviewPath='', [string]$ReviewHash='', [string]$OutputPath='',
    [string]$FixturePath='', [switch]$ConfirmApply, [switch]$AcceptDataLoss, [string]$DotNetPath=$env:ROO_INDUSTRIES_DOTNET_EXE
)
$ErrorActionPreference='Stop'
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$hostPath=Join-Path $root 'backend/bin/optimizer/Optimizer.Host.dll'
if(-not(Test-Path -LiteralPath $hostPath)){throw 'Build the optimizer helper with backend/scripts/Build-OptimizerHost.ps1 first.'}
$hostArgs=@($hostPath)
if(-not $DotNetPath -and (Test-Path -LiteralPath (Join-Path (Split-Path $hostPath -Parent) 'hostpolicy.dll'))){$DotNetPath=Join-Path (Split-Path $hostPath -Parent) 'Optimizer.Host.exe';$hostArgs=@()}
if(-not $DotNetPath){$candidate=Join-Path $env:USERPROFILE '.dotnet/dotnet.exe';$DotNetPath=if(Test-Path $candidate){$candidate}else{(Get-Command dotnet.exe -ErrorAction Stop).Source}}
foreach($name in @('SelectionsPath','PreviewPath','OutputPath','FixturePath')){
    $value=Get-Variable -Name $name -ValueOnly
    if($value){Set-Variable -Name $name -Value $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($value)}
}
$request=@{schemaVersion=1;repoRoot=$root}
if($FixturePath){$request.fixturePath=[IO.Path]::GetFullPath($FixturePath)}
if($Action -in @('Apply','Restore','CreateFixture') -and -not $ConfirmApply){throw 'This action requires ConfirmApply.'}
if($ConfirmApply){$request.confirm=$true}
if($AcceptDataLoss){$request.acceptDataLoss=$true}
switch($Action){
    'Catalog' {$command='tweak-catalog'}
    'Status' {$command='tweak-status'}
    'CreateFixture' {$command='tweak-fixture-create'}
    'Preview' {
        $command='tweak-preview';$request.profileId=$ProfileId;$request.outputPath=$OutputPath
        if($SelectionsPath -and $PresetId){throw 'Provide SelectionsPath or PresetId, not both.'}
        if($PresetId){$request.presetId=$PresetId}
        elseif($SelectionsPath){
            $document=('{"selections":'+[IO.File]::ReadAllText($SelectionsPath)+'}')|ConvertFrom-Json
            if($document.selections -isnot [Array]){throw 'Selections must be a JSON array.'}
            $request.selections=$document.selections
        }else{throw 'Provide explicit selections or a preset. Use an empty JSON array to review restoring a profile.'}
    }
    default {$command='tweak-'+$Action.ToLowerInvariant();$request.previewPath=$PreviewPath;$request.reviewHash=$ReviewHash}
}
$inputFile=Join-Path ([IO.Path]::GetTempPath()) ('roo-industries-tweak-request-'+[guid]::NewGuid().ToString('N')+'.json')
try {
    [IO.File]::WriteAllText($inputFile,($request|ConvertTo-Json -Depth 20),[Text.UTF8Encoding]::new($false))
    & $DotNetPath @hostArgs $command $inputFile
    if($LASTEXITCODE -ne 0){throw "Tweak command failed with exit code $LASTEXITCODE."}
}finally{Remove-Item -LiteralPath $inputFile -Force -ErrorAction SilentlyContinue}
