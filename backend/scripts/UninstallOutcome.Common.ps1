function Get-RooUninstallOutcome {
    param([ValidateSet('generic','windows-installer')][string]$Policy, [int]$ExitCode)
    $state='failed'; $success=$false; $reboot=$false; $stop=$true
    if ($ExitCode -eq 0) {$state='removed'; $success=$true; $stop=$false}
    if ($Policy -eq 'windows-installer') {
        switch ($ExitCode) {
            3010 {$state='reboot-required'; $success=$true; $reboot=$true; $stop=$true}
            1641 {$state='restart-initiated'; $success=$true; $reboot=$true; $stop=$true}
            1602 {$state='canceled'}
            1618 {$state='installer-busy'}
            1605 {$state='already-absent'; $success=$true; $stop=$false}
            1614 {$state='already-absent'; $success=$true; $stop=$false}
        }
    }
    return [pscustomobject]@{ policy=$Policy; exitCode=$ExitCode; state=$state; success=$success; rebootRequired=$reboot; stopQueue=$stop }
}

function Get-RooPostUninstallReview {
    param([object[]]$Items)
    $evidence=New-Object System.Collections.Generic.List[object]
    foreach ($item in $Items) {
        $path=[IO.Path]::GetFullPath([string]$item.target)
        $records=New-Object System.Collections.Generic.List[object]
        $pending=New-Object System.Collections.Generic.Queue[string]
        $pending.Enqueue($path)
        while ($pending.Count -gt 0) {
            if ($records.Count -ge 100000) {throw 'Fresh cleanup review exceeded 100000 entries; narrow the selected targets.'}
            $entryPath=$pending.Dequeue()
            if (-not (Test-Path -LiteralPath $entryPath)) {continue}
            $entry=Get-Item -LiteralPath $entryPath -Force
            $reparse=($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
            $record=[pscustomobject]@{path=$entry.FullName; kind=if($entry.PSIsContainer){'folder'}else{'file'};
                reparsePoint=$reparse; sizeBytes=$null; sha256=$null; lastWriteTimeUtc=$entry.LastWriteTimeUtc.ToString('o')}
            if (-not $reparse) {
                if ($entry.PSIsContainer) {foreach($child in Get-ChildItem -LiteralPath $entry.FullName -Force){$pending.Enqueue($child.FullName)}}
                else {$record.sizeBytes=$entry.Length; $record.sha256=(Get-FileHash -LiteralPath $entry.FullName -Algorithm SHA256).Hash.ToLowerInvariant()}
            }
            $records.Add($record) | Out-Null
        }
        $evidence.Add([pscustomobject]@{itemId=$item.itemId; target=$path; exists=(Test-Path -LiteralPath $path);
            ownershipConfirmed=$false; selectedForDeletion=$false; entries=@($records.ToArray())}) | Out-Null
    }
    return [pscustomobject]@{capturedAtUtc=(Get-Date).ToUniversalTime().ToString('o'); reviewRequired=$true;
        reason='The vendor removal invalidated the earlier cleanup selection. Review current contents and shared ownership before creating a new cleanup manifest.';
        targets=@($evidence.ToArray())}
}
