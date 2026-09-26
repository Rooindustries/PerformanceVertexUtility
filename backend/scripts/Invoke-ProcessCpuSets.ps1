param(
    [ValidateSet('Status','Preview','Apply','Restore')][string]$Action='Status',
    [int]$TargetProcessId=0,
    [uint32[]]$CpuSetId=@(),
    [switch]$ResetDefault,
    [string]$InputPath='',
    [string]$ReviewSha256='',
    [string]$JournalPath='',
    [string]$OutputPath='',
    [switch]$ConfirmApply
)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'CpuSets.Common.ps1')
$result=[pscustomobject]@{
    schemaVersion=1; actionId='performance.cpuSets.'+$Action.ToLowerInvariant(); status='failed'; dryRun=$true
    capturedAtUtc=Get-RooIndustriesUtcStamp; data=$null; journalPath=$null; changed=$false; restoreAvailable=$false; errors=@()
}
$target=$null; $lease=$null; $processLease=$null; $processLocked=$false; $journal=$null
$outputSafe=$false
try {
    Assert-RooIndustriesDistinctOperationPaths @($InputPath,$JournalPath,$OutputPath)
    $outputSafe=$true
    Initialize-RooIndustriesCpuSets
    if ($Action -eq 'Status') {
        if ($TargetProcessId -gt 0) {
            $target=[RooIndustries.Optimization.CpuSets.Target]::new($TargetProcessId,$false)
            $identity=$target.Identity()
            $result.data=[pscustomobject]@{ identity=$identity; cpuSetIds=@($target.Read()); topology=@($target.Topology()); compatibility=Get-RooIndustriesCpuSetProtection $identity ($target.Protection()) }
        } else { $result.data=[pscustomobject]@{ topology=@([RooIndustries.Optimization.CpuSets.TopologyReader]::ReadSystem()) } }
        $result.status='detected'
    } elseif ($Action -eq 'Preview') {
        if (-not $ResetDefault -and $CpuSetId.Count -eq 0) { throw 'Select CPU Set IDs or explicitly request ResetDefault.' }
        if ($ResetDefault -and $CpuSetId.Count -gt 0) { throw 'ResetDefault and CPU Set IDs cannot be combined.' }
        $result.data=New-RooIndustriesCpuSetPreview $TargetProcessId $CpuSetId
        $result.status='preview'
    } else {
        if ([string]::IsNullOrWhiteSpace($JournalPath)) { throw 'JournalPath is required for apply and restore.' }
        $JournalPath=[IO.Path]::GetFullPath($JournalPath)
        $result.journalPath=$JournalPath
        if ($Action -eq 'Apply') {
            if (-not $InputPath -or $ReviewSha256 -notmatch '^[a-fA-F0-9]{64}$') { throw 'Apply requires a reviewed preview and its SHA-256.' }
            $input=Read-RooIndustriesOperationJson $InputPath $ReviewSha256
            $preview=$input.data.data
            if ($input.data.status -ne 'preview' -or $preview.kind -ne 'cpu-set-preview') { throw 'Input is not a successful CPU Set preview.' }
            Assert-RooIndustriesOperationOwner $preview.owner
        } else {
            $journal=(Read-RooIndustriesOperationJson $JournalPath).data
            if ($journal.kind -ne 'cpu-set-journal') { throw 'Input is not a CPU Set journal.' }
            $preview=$journal.preview
            Assert-RooIndustriesOperationOwner $preview.owner
        }
        if (-not $ConfirmApply) {
            $result.status='preview'; $result.data=$preview
        } else {
            $lease=Lock-RooIndustriesOperation $JournalPath
            if (Test-RooIndustriesOperationFile $JournalPath) {
                $journal=(Read-RooIndustriesOperationJson $JournalPath).data
                if ($journal.kind -ne 'cpu-set-journal' -or $journal.preview.operationId -cne $preview.operationId -or
                    ($Action -eq 'Apply' -and $journal.reviewSha256 -ine $ReviewSha256)) { throw 'Journal belongs to a different reviewed operation.' }
                $preview=$journal.preview
                Assert-RooIndustriesOperationOwner $preview.owner
            } elseif ($Action -eq 'Restore') { throw 'Restore journal no longer exists.' }
            $processLease=[Threading.Mutex]::new($false,('Local\RooIndustriesCpuSets-'+$preview.identity.processId+'-'+$preview.identity.creationTimeFileTimeUtc))
            try { $processLocked=$processLease.WaitOne(0) } catch [Threading.AbandonedMutexException] { $processLocked=$true }
            if (-not $processLocked) { throw 'Another CPU Set operation is controlling this process.' }
            $target=[RooIndustries.Optimization.CpuSets.Target]::new([int]$preview.identity.processId,$true)
            $identity=$target.Identity()
            Assert-RooIndustriesCpuSetIdentity $preview.identity $identity
            $compatibility=Get-RooIndustriesCpuSetProtection $identity ($target.Protection())
            if ($compatibility.protected) { throw 'The target is now protected; leave its controls unchanged.' }
            $current=@($target.Read())
            $original=[uint32[]]@($preview.originalCpuSetIds)
            $desired=[uint32[]]@($preview.desiredCpuSetIds)
            if ($Action -eq 'Apply' -and $null -ne $journal -and $journal.status -eq 'restored') {
                $result.status='restored'; $result.data=$journal
            } elseif ($Action -eq 'Apply' -and $null -ne $journal -and (Test-RooIndustriesCpuSetIdsEqual $current $desired)) {
                $journal.status='applied'; Write-RooIndustriesOperationJson $journal $JournalPath
                $result.status='applied'; $result.data=$journal
            } elseif ($Action -eq 'Restore' -and (Test-RooIndustriesCpuSetIdsEqual $current $original)) {
                $journal.status='restored'; Write-RooIndustriesOperationJson $journal $JournalPath
                $result.status='restored'; $result.data=$journal
            } else {
                $expected=if ($Action -eq 'Apply') { $original } else { $desired }
                if (-not (Test-RooIndustriesCpuSetIdsEqual $current $expected)) { throw 'CPU Set assignment was changed externally; this operation will not overwrite it.' }
                if ($Action -eq 'Apply' -and $null -ne $journal) { throw 'An attempted operation no longer owns the current state; create a fresh preview.' }
                if ($null -eq $journal) {
                    $journal=[pscustomobject]@{ schemaVersion=1; kind='cpu-set-journal'; reviewSha256=$input.sha256; preview=$preview; status='apply-intent'; observedCpuSetIds=$current; updatedAtUtc=Get-RooIndustriesUtcStamp }
                } else { $journal.status='restore-intent' }
                Write-RooIndustriesOperationJson $journal $JournalPath
                $newIds=if ($Action -eq 'Apply') { $desired } else { $original }
                # Windows has no compare-and-set API; check again immediately before mutation.
                if (-not (Test-RooIndustriesCpuSetIdsEqual @($target.Read()) $expected)) { throw 'CPU Set assignment changed during apply; retry from a fresh preview.' }
                $result.dryRun=$false
                $target.Write([uint32[]]@($newIds))
                $result.changed=-not (Test-RooIndustriesCpuSetIdsEqual $current $newIds)
                $readback=@($target.Read())
                $journal.observedCpuSetIds=$readback; $journal.updatedAtUtc=Get-RooIndustriesUtcStamp
                if (-not (Test-RooIndustriesCpuSetIdsEqual $readback $newIds)) {
                    $journal.status='needs-reconciliation'; Write-RooIndustriesOperationJson $journal $JournalPath
                    throw 'Windows assignment readback differs; inspect the journal and live state.'
                }
                $journal.status=if ($Action -eq 'Apply') { 'applied' } else { 'restored' }
                Write-RooIndustriesOperationJson $journal $JournalPath
                $result.status=$journal.status; $result.data=$journal
            }
        }
    }
} catch {
    $result.errors=@(Get-RooIndustriesCpuSetError $_.Exception)
    $result.data=$journal
} finally {
    if ($null -ne $target) { $target.Dispose() }
    if ($processLocked) { $processLease.ReleaseMutex() }
    if ($null -ne $processLease) { $processLease.Dispose() }
    if ($null -ne $lease) { $lease.Dispose() }
}
$result.restoreAvailable=($null -ne $journal -and $journal.status -in @('applied','apply-intent','restore-intent','needs-reconciliation'))
if ($OutputPath -and $outputSafe) { Write-RooIndustriesOperationJson $result $OutputPath }
$result | ConvertTo-Json -Depth 32
if ($result.status -eq 'failed') { exit 1 }
