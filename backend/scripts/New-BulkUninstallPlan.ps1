param(
    [Parameter(Mandatory=$true)][string[]]$AppId,
    [string]$InventoryPath='',
    [switch]$Quiet,
    [string]$FixtureRoot='',
    [string]$OutputPath=''
)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'BulkUninstall.Common.ps1')
$result=[pscustomobject]@{schemaVersion=1; actionId='apps.bulkUninstall.preview'; status='failed'; dryRun=$true; data=$null; errors=@()}
$outputSafe=$false
try {
    Assert-RooDistinctOperationPaths @($InventoryPath,$OutputPath)
    $outputSafe=$true
    if (@($AppId|Select-Object -Unique).Count -ne $AppId.Count -or $AppId.Count -eq 0) {throw 'Select each app exactly once.'}
    if ($FixtureRoot) {$FixtureRoot=Assert-RooBulkFixtureRoot $FixtureRoot}
    $inventory=Get-RooInstalledAppInventory $InventoryPath
    $policy=Read-RooUninstallPolicy ''; $protected=Read-RooProtectedAppsCatalog ''
    $entries=New-Object System.Collections.Generic.List[object]
    foreach($id in $AppId) {
        $matches=@($inventory.apps|Where-Object {$_.appId -ceq $id})
        if($matches.Count -ne 1){throw "App identity must resolve to exactly one installed record: $id"}
        $app=$matches[0];$identity=Get-RooUninstallPropertyValue $app 'sourceIdentity' $null
        Assert-RooBulkIdentity $identity $FixtureRoot
        if ($FixtureRoot -and $identity.kind -ne 'fixture') {throw 'Fixture plans may contain only disposable fixture identities.'}
        if (-not (Test-RooBulkAppPresent $identity $FixtureRoot)) {throw "The selected app registration is no longer present: $id"}
        $registration=Get-RooBulkRegistrationState $identity $FixtureRoot
        Assert-RooBulkInventoryBinding $app $registration
        $classification=Get-RooAppClassification $app $protected $policy
        $arguments=@();$rawArguments='';$mode='tokens';$exitPolicy='generic'
        if ($app.sourceType -eq 'msi') {
            $productCode=[guid]::Empty
            if(-not [guid]::TryParseExact([string]$app.packageId,'B',[ref]$productCode)){throw 'MSI plan requires a valid ProductCode.'}
            if(@($inventory.apps|Where-Object {$_.sourceType -eq 'msi' -and $_.packageId -ieq $app.packageId}).Count -ne 1){throw 'MSI ProductCode is registered in multiple contexts; its uninstall context needs review.'}
            $exe=Join-Path ([Environment]::SystemDirectory) 'msiexec.exe'
            $arguments=@('/x',$productCode.ToString('B'),'/norestart');if($Quiet){$arguments+=@('/qn')}
            $exitPolicy='windows-installer'
        } elseif ($identity.kind -eq 'appx') {
            $exe=Join-Path ([Environment]::SystemDirectory) 'WindowsPowerShell\v1.0\powershell.exe'
            $command="try { Remove-AppxPackage -Package '"+([string]$identity.packageFullName).Replace("'","''")+"' -ErrorAction Stop; exit 0 } catch { exit 1 }"
            $arguments=@('-NoProfile','-NonInteractive','-EncodedCommand',[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command)))
        } else {
            $command=[string](Get-RooUninstallPropertyValue $app 'uninstallString' '')
            if($Quiet){$command=[string](Get-RooUninstallPropertyValue $app 'quietUninstallString' '');if(-not $command){throw 'This app did not publish a quiet removal command.'}}
            $parsed=Split-RooUninstallCommandLine $command
            $exe=[Environment]::ExpandEnvironmentVariables([string]$parsed.executable)
            $rawArguments=[string]$parsed.arguments;$mode='raw'
        }
        $hash=Get-RooBulkExecutableHash $exe
        if ($FixtureRoot -and -not (Test-RooCleanupPathWithin $exe $FixtureRoot)) {throw 'Fixture executable is outside the fixture directory.'}
        $entries.Add([pscustomobject]@{
            entryId=[guid]::NewGuid().ToString('N'); appId=$id; displayName=$app.displayName; sourceType=$app.sourceType; identity=$identity
            appSnapshot=$app
            registrationFingerprint=$registration.fingerprint
            executable=[IO.Path]::GetFullPath($exe); executableSha256=$hash; argumentMode=$mode; arguments=@($arguments); rawArguments=$rawArguments
            workingDirectory=[IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($exe)); exitCodePolicy=$exitPolicy
            protected=[bool]$classification.protected; reviewRequired=[bool]$classification.reviewRequired
            risk=$classification.risk; dependencyReasons=@($classification.reasons)
        })|Out-Null
    }
    $result.status='preview'
    $result.data=[pscustomobject]@{schemaVersion=1;kind='bulk-uninstall-plan';queueId=[guid]::NewGuid().ToString('N');owner=Get-RooOperationOwner;
        createdAtUtc=Get-RooUtcStamp;fixtureRoot=$FixtureRoot;entries=@($entries.ToArray());cleanupMode='fresh-review-after-removal';
        limits=@('Completion verifies the selected app registration is absent; vendor removal is not reversible.',
            'Canceled, interrupted or uncertain invocations are never automatically repeated.',
            'Leftover deletion requires a fresh scan and separate review.')}
} catch {$result.errors=@([pscustomobject]@{code='BULK_PLAN_REJECTED';message=$_.Exception.Message})}
if($OutputPath -and $outputSafe){Write-RooOperationJson $result $OutputPath}
$result|ConvertTo-Json -Depth 32
if($result.status -eq 'failed'){exit 1}
