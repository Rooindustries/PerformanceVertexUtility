function New-HistoricalStage([string]$Source,$SourceRows,[string]$Fingerprint,[string]$Stage,[string]$Quarantine,[string]$Fallback='',$FallbackRows=$null) {
    Assert-SealedRecovery $Source
    $original=@{};$expected=[Collections.Generic.List[object]]::new();$sourceBy=@{};$fallbackBy=@{};$replacements=[Collections.Generic.List[object]]::new()
    if($Fallback){Assert-SealedRecovery $Fallback;foreach($r in $FallbackRows){$fallbackBy[$r.relative]=$r}}
    foreach($r in $SourceRows){$sourceBy[$r.relative]=$r}
    foreach($line in [IO.File]::ReadAllLines($Fingerprint,[Text.Encoding]::UTF8)){
        $parts=$line.Split('|');if($parts.Length -ne 5 -or $original.ContainsKey($parts[0])){throw 'Ambiguous historical fingerprint'}
        $relative=$parts[0];if($relative -and ($relative -notmatch '^\\' -or $relative.Split('\') -contains '..')){throw 'Historical relative path is invalid'}
        $r=$sourceBy[$relative];if(-not$r){throw 'Historical path unavailable in archive; retained'}
        if([bool]$r.directory -ne ($parts[1] -ceq 'dir')){throw 'Historical entry type differs'}
        if(-not$r.directory -and ([DateTime]::new([long]$r.write,[DateTimeKind]::Utc).ToString('o') -cne $parts[2] -or [string][IO.FileAttributes][int]$r.attributes -cne $parts[3] -or [string]$r.length -cne $parts[1])){
            $fallbackRow=$fallbackBy[$relative]
            if(-not$fallbackRow -or $fallbackRow.directory -or [string]$fallbackRow.length -cne $parts[1] -or [DateTime]::new([long]$fallbackRow.write,[DateTimeKind]::Utc).ToString('o') -cne $parts[2] -or [string][IO.FileAttributes][int]$fallbackRow.attributes -cne $parts[3]){throw 'No retained source matches historical file metadata; retained'}
            $replacements.Add(@{relative=$relative;archive=$r;fallback=$fallbackRow});$r=$fallbackRow
        }
        $other=$fallbackBy[$relative]
        if(-not$r.directory -and $other -and -not$other.directory -and [string]$other.length -ceq $parts[1] -and [DateTime]::new([long]$other.write,[DateTimeKind]::Utc).ToString('o') -ceq $parts[2] -and [string][IO.FileAttributes][int]$other.attributes -ceq $parts[3] -and $other.sha256 -cne $r.sha256){throw 'Conflicting retained file hashes with equal historical metadata; both copies retained'}
        $raw=[Security.AccessControl.RawSecurityDescriptor]::new($parts[4]);$raw.SetFlags($raw.ControlFlags -bor [Security.AccessControl.ControlFlags]([int]$r.control -band 0x2A3B));$descriptor=New-Object byte[] $raw.BinaryLength;$raw.GetBinaryForm($descriptor,0)
        $row=[pscustomobject][ordered]@{relative=$relative;directory=$r.directory;length=$r.length;creation=$r.creation;write=[DateTime]::Parse($parts[2]).ToUniversalTime().Ticks.ToString();attributes=[int][IO.FileAttributes]([Enum]::Parse([IO.FileAttributes],$parts[3]));sha256=$r.sha256;sddl=$parts[4];control=[int]$raw.ControlFlags;descriptor=[Convert]::ToBase64String($descriptor)}
        $original[$relative]=$row;$expected.Add($row)
    }
    if(-not$original.ContainsKey('') -or -not$original[''].directory){throw 'Historical root is absent'}
    New-SealedDirectory $Quarantine
    Copy-VerifiedTree $Source $Stage -OriginalRows $SourceRows -SealTarget|Out-Null
    if($replacements.Count){
        $compiler=Join-Path $backup ('probe-compiler-'+[Guid]::NewGuid().ToString('N'));New-SealedDirectory $compiler;$oldTemp=$env:TEMP;$oldTmp=$env:TMP
        try{$env:TEMP=$compiler;$env:TMP=$compiler;. (Join-Path $backup 'ownership.ps1')}finally{$env:TEMP=$oldTemp;$env:TMP=$oldTmp}
    }
    foreach($replace in $replacements){
        $relative=$replace.relative;$path=$Stage+$relative;$kept=Join-Path $Quarantine ('replaced-original'+$relative)
        $parent=[IO.Path]::GetDirectoryName($kept);$parents=[Collections.Generic.Stack[string]]::new();while(-not(Test-Path -LiteralPath $parent)){$parents.Push($parent);$parent=[IO.Path]::GetDirectoryName($parent)};while($parents.Count){New-SealedDirectory $parents.Pop()}
        $archiveRow=ConvertTo-Json -InputObject $replace.archive -Compress|ConvertFrom-Json;$archiveRow.relative=''
        Assert-RecoveryEqual (Recovery-Lines @($archiveRow) -DataOnly) (Recovery-Lines @(Get-RecoveryRows $path) -DataOnly) 'different private archive file before retention'
        [IO.File]::Move($path,$kept);Restore-RecoveryDescriptors @($archiveRow) $kept -Seal
        $fallbackRow=ConvertTo-Json -InputObject $replace.fallback -Compress|ConvertFrom-Json;$fallbackRow.relative=''
        Assert-RecoveryEqual (Recovery-Lines @($fallbackRow) -DataOnly) (Recovery-Lines @(Get-RecoveryRows ($Fallback+$relative)) -DataOnly) 'fallback immediately before copy'
        $probe=Copy-OwnedProbe ($Fallback+$relative) $path;try{if($probe.Identity.hash -cne $fallbackRow.sha256){throw 'Native fallback bytes differ'}}finally{$probe.Dispose()}
    }
    $extra=@($SourceRows|Where-Object {-not$original.ContainsKey($_.relative)}|Sort-Object {$_.relative.Length})
    $moved=[Collections.Generic.List[string]]::new()
    foreach($r in $extra){
        if(@($moved|Where-Object {$r.relative.StartsWith($_+'\',[StringComparison]::OrdinalIgnoreCase)}).Count){continue}
        if($r.directory -and @($original.Keys|Where-Object {$_.StartsWith($r.relative+'\',[StringComparison]::OrdinalIgnoreCase)}).Count){throw 'Extra archive directory contains historical data; retained'}
        $sourcePath=$Stage+$r.relative;$targetPath=$Quarantine+$r.relative
        $parent=[IO.Path]::GetDirectoryName($targetPath)
        $parents=[Collections.Generic.Stack[string]]::new();while(-not(Test-Path -LiteralPath $parent)){$parents.Push($parent);$parent=[IO.Path]::GetDirectoryName($parent)}
        while($parents.Count){New-SealedDirectory $parents.Pop()}
        $observed=@(Get-RecoveryRows $sourcePath);$bound=@($SourceRows|Where-Object {$_.relative -ceq $r.relative -or ($r.directory -and $_.relative.StartsWith($r.relative+'\',[StringComparison]::Ordinal))}|ForEach-Object {$v=ConvertTo-Json -InputObject $_ -Compress|ConvertFrom-Json;$v.relative=$v.relative.Substring($r.relative.Length);$v})
        Assert-RecoveryEqual (Recovery-Lines $bound -DataOnly) (Recovery-Lines $observed -DataOnly) 'private extra before quarantine'
        if($r.directory){[IO.Directory]::Move($sourcePath,$targetPath)}else{[IO.File]::Move($sourcePath,$targetPath)}
        Restore-RecoveryDescriptors $bound $targetPath -Seal
        Assert-RecoveryEqual (Recovery-Lines $bound -DataOnly) (Recovery-Lines @(Get-RecoveryRows $targetPath) -DataOnly) 'private extra quarantine exact'
        $moved.Add($r.relative)
    }
    foreach($r in $expected|Sort-Object {$_.relative.Length} -Descending){$path=$Stage+$r.relative;$item=Get-Item -LiteralPath $path -Force;$item.CreationTimeUtc=[DateTime]::new([long]$r.creation,[DateTimeKind]::Utc);$item.LastWriteTimeUtc=[DateTime]::new([long]$r.write,[DateTimeKind]::Utc);$item.Attributes=[IO.FileAttributes][int]$r.attributes}
    Restore-RecoveryDescriptors $expected.ToArray() $Stage
    Assert-RecoveryEqual (Recovery-Lines $expected.ToArray()) (Recovery-Lines @(Get-RecoveryRows $Stage)) 'assembled historical bytes metadata descriptors'
    Assert-HistoricalMetadata $Stage $Fingerprint|Out-Null
    Restore-RecoveryDescriptors $expected.ToArray() $Stage -Seal
    Assert-SealedRecovery $Stage
    Assert-RecoveryEqual (Recovery-Lines $expected.ToArray() -DataOnly) (Recovery-Lines @(Get-RecoveryRows $Stage) -DataOnly) 'sealed assembled metadata'
    $proof=@{stage=$Stage;quarantine=$Quarantine;rows=$expected.ToArray();extraPaths=$moved.ToArray();metadataMatchesHistorical=$true;earliestByteHashesAvailable=$false;creationTimesFromRetainedSources=$true;fallbackFiles=$replacements.Count}
    Save-RecoveryJson ($Stage+'.assembled.json') $proof
    return $proof
}
