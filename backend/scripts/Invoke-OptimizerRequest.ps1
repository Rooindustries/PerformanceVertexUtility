param(
    [Parameter(Mandatory=$true)][ValidateSet('CpuSets','BulkUninstall')][string]$Feature,
    [Parameter(Mandatory=$true)][ValidateSet('Preview','Apply','Restore')][string]$Action,
    [string]$RequestPath='', [int]$TargetProcessId=0, [switch]$ConfirmApply
)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'OperationState.Common.ps1')
try {
    if(-not $RequestPath) {
        if($Action -ne 'Preview'){throw 'RequestPath is required for this action.'}
        if($Feature -eq 'CpuSets'){& (Join-Path $PSScriptRoot 'Invoke-ProcessCpuSets.ps1') -Action Status -TargetProcessId $TargetProcessId}
        else {[pscustomobject]@{schemaVersion=1;actionId='apps.bulkUninstall.preview';status='preview';dryRun=$true;
            requiredInput=@('appIds');optionalInput=@('inventoryPath','quiet','outputPath');
            behavior='Select exact installed app IDs to create a reviewed sequential removal plan. Leftover deletion requires a separate fresh review.'}|ConvertTo-Json}
        return
    }
    $request=(Read-RooOperationJson $RequestPath).data
    if($request.schemaVersion -ne 1){throw 'Optimizer request schemaVersion must be 1.'}
    foreach($name in @('resetDefault','quiet','manualReviewApproved','allowFixtureExecution')) {
        $property=$request.PSObject.Properties[$name]
        if($null -ne $property -and $property.Value -isnot [bool]){throw "Request field $name must be a JSON boolean."}
    }
    foreach($name in @('cpuSetIds','appIds')) {
        $property=$request.PSObject.Properties[$name]
        if($null -ne $property -and $property.Value -isnot [Array]){throw "Request field $name must be a JSON array."}
    }
    $args=@{}
    if($Feature -eq 'CpuSets') {
        $scriptName='Invoke-ProcessCpuSets.ps1';$args.Action=$Action
        if($Action -eq 'Preview') {
            $allowed=@('schemaVersion','targetProcessId','cpuSetIds','resetDefault','outputPath')
            $args.TargetProcessId=[int]$request.targetProcessId
            if($request.resetDefault){$args.ResetDefault=$true}else{$args.CpuSetId=[uint32[]]@($request.cpuSetIds)}
        } else {
            $allowed=@('schemaVersion','inputPath','reviewSha256','journalPath','outputPath')
            $args.InputPath=[string]$request.inputPath;$args.ReviewSha256=[string]$request.reviewSha256;$args.JournalPath=[string]$request.journalPath
            $args.ConfirmApply=[bool]$ConfirmApply
        }
    } else {
        if($Action -eq 'Restore'){throw 'Vendor removal is not reversible. Use a separately reviewed cleanup restore journal when applicable.'}
        if($Action -eq 'Preview') {
            $scriptName='New-BulkUninstallPlan.ps1';$allowed=@('schemaVersion','appIds','inventoryPath','quiet','fixtureRoot','outputPath')
            $args.AppId=[string[]]@($request.appIds);$args.InventoryPath=[string]$request.inventoryPath;$args.Quiet=[bool]$request.quiet;$args.FixtureRoot=[string]$request.fixtureRoot
        } else {
            $scriptName='Invoke-BulkUninstall.ps1';$allowed=@('schemaVersion','inputPath','reviewSha256','journalPath','manualReviewApproved','allowFixtureExecution','timeoutSeconds','outputPath')
            $args.Action='Apply';$args.InputPath=[string]$request.inputPath;$args.ReviewSha256=[string]$request.reviewSha256;$args.JournalPath=[string]$request.journalPath
            $args.ConfirmApply=[bool]$ConfirmApply;$args.ManualReviewApproved=[bool]$request.manualReviewApproved;$args.AllowFixtureExecution=[bool]$request.allowFixtureExecution
            if($request.timeoutSeconds){$args.TimeoutSeconds=[int]$request.timeoutSeconds}
        }
    }
    foreach($property in $request.PSObject.Properties){if($allowed -notcontains $property.Name){throw "Unknown optimizer request field: $($property.Name)"}}
    Assert-RooDistinctOperationPaths @($RequestPath,[string]$request.outputPath)
    if($request.outputPath){$args.OutputPath=[string]$request.outputPath}
    & (Join-Path $PSScriptRoot $scriptName) @args
} catch {
    [pscustomobject]@{schemaVersion=1;actionId='optimizer.request';status='failed';dryRun=$true;errors=@(@{code='INVALID_OPTIMIZER_REQUEST';message=$_.Exception.Message})}|ConvertTo-Json -Depth 8
    exit 1
}
