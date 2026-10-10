param(
    [Parameter(Mandatory=$true)][string[]]$AppId,
    [string]$InventoryPath='',
    [switch]$Quiet,
    [switch]$IncludeAllAppxUsers,
    [string]$FixtureRoot='',
    [string]$OutputPath=''
)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'BulkUninstall.Common.ps1')
$result=[pscustomobject]@{schemaVersion=1; actionId='apps.bulkUninstall.preview'; status='failed'; dryRun=$true; data=$null; errors=@()}
$outputSafe=$false
try {
    Assert-RooIndustriesDistinctOperationPaths @($InventoryPath,$OutputPath)
    $outputSafe=$true
    if (@($AppId|Select-Object -Unique).Count -ne $AppId.Count -or $AppId.Count -eq 0) {throw 'Select each app exactly once.'}
    if ($FixtureRoot) {$FixtureRoot=Assert-RooIndustriesBulkFixtureRoot $FixtureRoot}
    $inventory=Get-RooIndustriesInstalledAppInventory $InventoryPath -IncludeAllAppxUsers:$IncludeAllAppxUsers
    if($IncludeAllAppxUsers -and $inventory.complete -ne $true){throw 'All-user package inventory is incomplete. Refresh it before reviewing other accounts.'}
    $policy=Read-RooIndustriesUninstallPolicy ''; $protected=Read-RooIndustriesProtectedAppsCatalog ''
    $entries=New-Object System.Collections.Generic.List[object]
    foreach($id in $AppId) {
        $matches=@($inventory.apps|Where-Object {$_.appId -ceq $id})
        if($matches.Count -ne 1){throw "App identity must resolve to exactly one installed record: $id"}
        $app=$matches[0];$identity=Get-RooIndustriesUninstallPropertyValue $app 'sourceIdentity' $null
        Assert-RooIndustriesBulkIdentity $identity $FixtureRoot
        if ($FixtureRoot -and $identity.kind -ne 'fixture') {throw 'Fixture plans may contain only disposable fixture identities.'}
        if (-not (Test-RooIndustriesBulkAppPresent $identity $FixtureRoot)) {throw "The selected app registration is no longer present: $id"}
        $registration=Get-RooIndustriesBulkRegistrationState $identity $FixtureRoot
        Assert-RooIndustriesBulkInventoryBinding $app $registration
        $classification=Get-RooIndustriesAppClassification $app $protected $policy
        $arguments=@();$rawArguments='';$mode='tokens';$exitPolicy='generic'
        if ($app.sourceType -eq 'msi') {
            $productCode=[guid]::Empty
            if(-not [guid]::TryParseExact([string]$app.packageId,'B',[ref]$productCode)){throw 'MSI plan requires a valid ProductCode.'}
            if(@($inventory.apps|Where-Object {$_.sourceType -eq 'msi' -and $_.packageId -ieq $app.packageId}).Count -ne 1){throw 'MSI ProductCode is registered in multiple contexts; its uninstall context needs review.'}
            $exe=Join-Path ([Environment]::SystemDirectory) 'msiexec.exe'
            $rawArguments=Get-RooIndustriesMsiUninstallArguments $productCode -Quiet:$Quiet;$mode='raw'
            $exitPolicy='windows-installer'
        } elseif ($identity.kind -eq 'appx') {
            $exe=Join-Path ([Environment]::SystemDirectory) 'WindowsPowerShell\v1.0\powershell.exe'
            $command='$ProgressPreference=''SilentlyContinue''; try { '+(Get-RooIndustriesAppxRemoveCommand $identity)+'; exit 0 } catch { [Console]::Error.WriteLine((@{message=$_.Exception.Message;hresult=$_.Exception.HResult;errorId=$_.FullyQualifiedErrorId;details=$_.ErrorDetails.Message}|ConvertTo-Json -Compress)); exit 1 }'
            $arguments=@('-NoProfile','-NonInteractive','-EncodedCommand',[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command)))
        } else {
            $command=[string](Get-RooIndustriesUninstallPropertyValue $app 'uninstallString' '')
            if($Quiet){$command=[string](Get-RooIndustriesUninstallPropertyValue $app 'quietUninstallString' '');if(-not $command){throw 'This app did not publish a quiet removal command.'}}
            $resolved=Resolve-RooIndustriesUninstallCommandLine $command
            if($null -eq $resolved){throw "The removal command does not start with an existing program path, so it cannot be reviewed exactly: $command"}
            $exe=$resolved.executable
            $rawArguments=[string]$resolved.arguments;$mode='raw'
        }
        $hash=Get-RooIndustriesBulkExecutableHash $exe
        if ($FixtureRoot -and -not (Test-RooIndustriesCleanupPathWithin $exe $FixtureRoot)) {throw 'Fixture executable is outside the fixture directory.'}
        $entry=[pscustomobject]@{
            entryId=[guid]::NewGuid().ToString('N'); appId=$id; displayName=$app.displayName; sourceType=$app.sourceType; identity=$identity
            appSnapshot=$app
            registrationFingerprint=$registration.fingerprint
            executable=[IO.Path]::GetFullPath($exe); executableSha256=$hash; argumentMode=$mode; arguments=@($arguments); rawArguments=$rawArguments; commandLine=$null
            workingDirectory=[IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($exe)); exitCodePolicy=$exitPolicy
            protected=[bool]$classification.protected; reviewRequired=[bool]$classification.reviewRequired
            risk=$classification.risk; dependencyReasons=@($classification.reasons)
        }
        $entry.commandLine=Get-RooIndustriesBulkCommandLine $entry
        $entries.Add($entry)|Out-Null
    }
    $result.status='preview'
    $result.data=[pscustomobject]@{schemaVersion=1;kind='bulk-uninstall-plan';queueId=[guid]::NewGuid().ToString('N');owner=Get-RooIndustriesOperationOwner;
        createdAtUtc=Get-RooIndustriesUtcStamp;fixtureRoot=$FixtureRoot;entries=@($entries.ToArray());cleanupMode='fresh-review-after-removal';
        limits=@('Completion verifies the selected app registration is absent; vendor removal is not reversible.',
            'Canceled, interrupted or uncertain invocations are never automatically repeated.',
            'Leftover deletion requires a fresh scan and separate review.')}
} catch {$result.errors=@([pscustomobject]@{code='BULK_PLAN_REJECTED';message=$_.Exception.Message})}
if($OutputPath -and $outputSafe){Write-RooIndustriesOperationJson $result $OutputPath}
$result|ConvertTo-Json -Depth 32
if($result.status -eq 'failed'){exit 1}
