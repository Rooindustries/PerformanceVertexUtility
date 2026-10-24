. (Join-Path $PSScriptRoot 'BrandCompatibility.Common.ps1')
. (Join-Path $PSScriptRoot 'OperationState.Common.ps1')
$script:RooIndustriesGovernorManaged='Managed by the governor'
$script:RooIndustriesGovernorOwnership=$null
$script:RooIndustriesGovernorOwnershipFailedAtUtc=[DateTime]::MinValue
$script:RooIndustriesGovernorOwnershipLoggedAtUtc=[DateTime]::MinValue
$script:RooIndustriesGovernorDamagedLoggedAtUtc=[DateTime]::MinValue
$script:RooIndustriesGovernorAllControls=@('cpuPriority','affinity','cpuSets','ioPriority','gpuPriority','memoryPriority','executionQoS','priorityBoost')
$script:RooIndustriesProcessOperationPreview=$null

function Write-RooIndustriesGovernorOwnershipLog([string]$Message) {
    $root=Join-Path (Get-RooIndustriesLocalDataRoot) 'process-rules'
    if(-not (Test-Path -LiteralPath $root)){return}
    for($attempt=0;$attempt -lt 5;$attempt++){
        try {
            $directory=Join-Path $root 'logs'
            [IO.Directory]::CreateDirectory($directory)|Out-Null
            $path=Join-Path $directory 'governor.log'
            if((Test-Path -LiteralPath $path) -and (Get-Item -LiteralPath $path).Length -gt 262144){Move-Item -LiteralPath $path -Destination ($path+'.1') -Force}
            [IO.File]::AppendAllText($path,[DateTime]::UtcNow.ToString('o')+' '+$Message+[Environment]::NewLine)
            return
        } catch {Start-Sleep -Milliseconds 20}
    }
}

function Read-RooIndustriesGovernorJson {
    param([string]$Path,[int]$Budget,[Diagnostics.Stopwatch]$Clock,[bool]$RetryContent=$false)
    while($true){
        $text=$null;$failure=$null;$content=$false
        try {
            $stream=[IO.FileStream]::new($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
            try {$text=[IO.StreamReader]::new($stream,[Text.UTF8Encoding]::new($false),$true).ReadToEnd()} finally {$stream.Dispose()}
        } catch {
            $failure=$_.Exception
            while($failure -is [Management.Automation.MethodInvocationException] -and $failure.InnerException){$failure=$failure.InnerException}
        }
        if($null -eq $failure){
            try {
                $data=$text.TrimStart([char]0xfeff)|ConvertFrom-Json -ErrorAction Stop
                if($null -eq $data){throw [IO.InvalidDataException]::new('The file holds no JSON value.')}
                return [pscustomobject]@{state='read';data=$data;message=$null;objectRoot=$text.TrimStart([char]0xfeff).TrimStart().StartsWith('{',[StringComparison]::Ordinal)}
            } catch {$failure=$_.Exception;$content=$true}
        }
        if($failure -is [IO.FileNotFoundException] -or $failure -is [IO.DirectoryNotFoundException]){return [pscustomobject]@{state='missing';data=$null;message=$failure.Message}}
        $expired=$Clock.ElapsedMilliseconds -ge $Budget
        if($content -and (-not $RetryContent -or $expired)){return [pscustomobject]@{state='damaged';data=$null;message=$failure.Message}}
        if($expired){return [pscustomobject]@{state='unreadable';data=$null;message=$failure.Message}}
        Start-Sleep -Milliseconds 50
    }
}

function Get-RooIndustriesProcessOperationDirectories {
    param([string]$Path)
    try {
        $attributes = [IO.File]::GetAttributes($Path)
        if (($attributes -band [IO.FileAttributes]::Directory) -eq 0) { throw [IO.InvalidDataException]::new('The saved operations path is not a directory.') }
        foreach ($directory in [IO.Directory]::EnumerateDirectories($Path)) { [IO.DirectoryInfo]::new($directory) }
    } catch {
        $failure = $_.Exception
        while ($failure -is [Management.Automation.MethodInvocationException] -and $failure.InnerException) { $failure = $failure.InnerException }
        if ($failure -is [IO.FileNotFoundException] -or $failure -is [IO.DirectoryNotFoundException]) { return }
        throw $failure
    }
}

function New-RooIndustriesDamagedOperation([string]$Path, [string]$Reason) {
    $data = (Get-RooIndustriesLocalDataRoot).TrimEnd([char[]]'\/')
    $shown = if ($Path.StartsWith($data, [StringComparison]::OrdinalIgnoreCase)) { $Path.Substring($data.Length).TrimStart([char[]]'\/') } else { $Path }
    return [IO.InvalidDataException]::new('A saved change file is damaged: ' + $shown + ' (' + $Reason + ').')
}

function Get-RooIndustriesProcessOperationJournals {
    $journals = New-Object System.Collections.Generic.List[string]
    $root = Join-Path (Get-RooIndustriesLocalDataRoot) 'operations'
    foreach ($operation in @(Get-RooIndustriesProcessOperationDirectories $root)) {
        if ($operation.Name -like 'process-*') {
            $journals.Add((Join-Path $operation.FullName 'journal.json')) | Out-Null
        } elseif ($operation.Name -like 'game-session-*') {
            $session = Join-Path $operation.FullName 'session'
            $journals.Add((Join-Path $session 'launcher-journal.json')) | Out-Null
            foreach ($instance in @(Get-RooIndustriesProcessOperationDirectories (Join-Path $session 'games'))) {
                foreach ($field in @(Get-RooIndustriesProcessOperationDirectories $instance.FullName)) {
                    $journals.Add((Join-Path $field.FullName 'journal.json')) | Out-Null
                }
            }
        }
    }
    return @($journals.ToArray())
}

function Read-RooIndustriesProcessOperationReleases {
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $releases = New-Object System.Collections.Generic.List[object]
    try { $journals = @(Get-RooIndustriesProcessOperationJournals) } catch { return @() }
    foreach ($path in $journals) {
        try {
            $read = Read-RooIndustriesGovernorJson $path 800 $clock $true
            if ($read.state -ne 'read' -or -not $read.objectRoot -or $read.data -isnot [pscustomobject]) { continue }
            $journal = $read.data
            $identity = if ($journal.preview -is [pscustomobject]) { $journal.preview.identity } else { $null }
            $created = 0L
            if ($identity -isnot [pscustomobject] -or ($identity.processId -isnot [int] -and $identity.processId -isnot [long]) -or
                $identity.creationTimeFileTimeUtc -isnot [string] -or -not [long]::TryParse($identity.creationTimeFileTimeUtc, [ref]$created)) { continue }
            foreach ($change in @(@($journal.changes) | Where-Object { $_ -is [pscustomobject] -and $_.status -ceq 'restored' -and $_.name -is [string] -and $null -ne $_.PSObject.Properties['released'] })) {
                $control = switch -CaseSensitive ($change.name) { 'priorityClass' { 'cpuPriority' } 'affinityMask' { 'affinity' } default { $change.name } }
                foreach ($claim in @($change.released)) {
                    if ($claim -is [pscustomobject] -and $claim.feature -is [string] -and $claim.record -is [string] -and $claim.record) {
                        $releases.Add([pscustomobject]@{ processId = [long]$identity.processId; creationTimeFileTimeUtc = $created; control = $control; feature = $claim.feature; original = $claim.original; record = $claim.record }) | Out-Null
                    }
                }
            }
        } catch { continue }
    }
    return @($releases.ToArray())
}

function Read-RooIndustriesProcessOperationOwnership {
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $claims = New-Object System.Collections.Generic.List[object]
    foreach ($path in @(Get-RooIndustriesProcessOperationJournals)) {
        $read = Read-RooIndustriesGovernorJson $path 800 $clock $true
        if ($read.state -eq 'missing') { continue }
        if ($read.state -ne 'read') { throw (New-RooIndustriesDamagedOperation $path ('it could not be read: ' + $read.message)) }
        $journal = $read.data
        if (-not $read.objectRoot -or $journal -isnot [pscustomobject] -or ($journal.schemaVersion -isnot [int] -and $journal.schemaVersion -isnot [long]) -or $journal.schemaVersion -ne 1 -or
            $journal.status -isnot [string] -or $journal.status -cnotin @('applying','applied','needsReconciliation','restored','expired')) {
            throw (New-RooIndustriesDamagedOperation $path 'unknown schema or state')
        }
        if ($journal.status -cin @('restored','expired')) { continue }
        if ($journal.changes -isnot [array] -or $journal.preview -isnot [pscustomobject] -or $journal.preview.identity -isnot [pscustomobject]) {
            throw (New-RooIndustriesDamagedOperation $path 'no complete identity or change list')
        }
        $identity = $journal.preview.identity
        $creation = 0L
        $processId = $identity.processId
        $executable = $identity.executablePath
        if (($processId -isnot [int] -and $processId -isnot [long]) -or $processId -le 0 -or $processId -gt [int]::MaxValue -or
            $identity.creationTimeFileTimeUtc -isnot [string] -or -not [long]::TryParse($identity.creationTimeFileTimeUtc, [ref]$creation) -or $creation -le 0 -or
            $executable -isnot [string] -or [string]::IsNullOrWhiteSpace($executable) -or -not [IO.Path]::IsPathRooted($executable) -or
            ([IO.Path]::DirectorySeparatorChar -eq '\' -and $executable -notmatch '^(?:[A-Za-z]:[\\/]|\\\\[^\\]+\\[^\\]+(?:\\|$))')) {
            throw (New-RooIndustriesDamagedOperation $path 'invalid process identity')
        }
        $attempted = New-Object 'System.Collections.Generic.HashSet[string]'
        foreach ($change in $journal.changes) {
            if ($change -isnot [pscustomobject] -or $change.name -isnot [string] -or $change.status -isnot [string] -or
                $change.status -cnotin @('pending','unchanged','applyIntent','applied','restoreIntent','restored','leftAsSet')) {
                throw (New-RooIndustriesDamagedOperation $path 'unknown change state')
            }
            $control = switch -CaseSensitive ($change.name) { 'priorityClass' { 'cpuPriority' } 'affinityMask' { 'affinity' } default { $change.name } }
            if ($script:RooIndustriesGovernorAllControls -cnotcontains $control) { throw (New-RooIndustriesDamagedOperation $path 'unknown control') }
            if ($change.status -cin @('applyIntent','applied','restoreIntent') -or ($change.status -ceq 'pending' -and $journal.status -ceq 'applying')) {
                [void]$attempted.Add($control)
            }
        }
        $claims.Add([pscustomobject]@{ processId = [int]$processId; creationTimeFileTimeUtc = $creation; controls = @($attempted) }) | Out-Null
    }
    return [pscustomobject]@{ claims = @($claims.ToArray()); failure = $null }
}

function Get-RooIndustriesProcessOperationControls {
    param([System.Diagnostics.Process]$Process, [switch]$ForPreview)
    if ($null -eq $Process) { throw [IO.InvalidDataException]::new('The live process identity could not be read.') }
    if ($ForPreview) {
        if ($null -eq $script:RooIndustriesProcessOperationPreview) {
            try { $script:RooIndustriesProcessOperationPreview = Read-RooIndustriesProcessOperationOwnership }
            catch { $script:RooIndustriesProcessOperationPreview = [pscustomobject]@{ claims = @(); failure = $_.Exception } }
        }
        $snapshot = $script:RooIndustriesProcessOperationPreview
    } else {
        $snapshot = Read-RooIndustriesProcessOperationOwnership
    }
    if ($null -ne $snapshot.failure) { throw $snapshot.failure }
    $owned = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($claim in $snapshot.claims) {
        if ($claim.processId -ne $Process.Id) { continue }
        $liveCreation = $Process.StartTime.ToUniversalTime().ToFileTimeUtc()
        if ($liveCreation -le 0) { throw [IO.InvalidDataException]::new('The live process identity could not be read.') }
        if ($claim.creationTimeFileTimeUtc -ne $liveCreation) { continue }
        foreach ($control in $claim.controls) { [void]$owned.Add($control) }
    }
    return @($owned)
}

function Get-RooIndustriesGovernorOwnership {
    $now=[DateTime]::UtcNow
    $cached=$script:RooIndustriesGovernorOwnership
    if($null -ne $cached -and ($now-$cached.readAtUtc).TotalMilliseconds -lt 1000 -and ($now-$cached.readAtUtc).TotalMilliseconds -ge 0){return $cached}
    $root=Join-Path (Get-RooIndustriesLocalDataRoot) 'process-rules'
    $sinceFailure=($now-$script:RooIndustriesGovernorOwnershipFailedAtUtc).TotalMilliseconds
    $budget=if($sinceFailure -ge 0 -and $sinceFailure -lt 10000){0}else{800}
    $clock=[Diagnostics.Stopwatch]::StartNew()
    $attempts=0
    while($true){
    $attempts++
    $readAtUtc=[DateTime]::UtcNow
    $rules=New-Object System.Collections.Generic.List[object]
    $instances=New-Object System.Collections.Generic.List[object]
    $damaged=New-Object System.Collections.Generic.List[string]
    $unreadable=New-Object System.Collections.Generic.List[string]
    $unknown=New-Object System.Collections.Generic.List[string]
    $hostFailure=$null
    $failure=$null
    try {
        $rulesPath=Join-Path $root 'rules'
        if(Test-Path -LiteralPath $rulesPath){
            foreach($file in @(Get-ChildItem -LiteralPath $rulesPath -Filter '*.json' -File)){
                $read=Read-RooIndustriesGovernorJson $file.FullName $budget $clock
                if($read.state -eq 'missing'){continue}
                if($read.state -eq 'unreadable'){$unreadable.Add($file.Name+' ('+$read.message+')');continue}
                try {
                    if($read.state -ne 'read'){throw $read.message}
                    $rule=$read.data
                    if($rule.enabled -isnot [bool]){throw ('The saved rule '+$file.Name+' has no enabled state.')}
                    if(-not $rule.enabled){continue}
                    $controls=@($rule.controls.PSObject.Properties|ForEach-Object {$_.Name})
                    if($null -ne $rule.cpuSelection){$controls+='cpuSets'}
                    $rules.Add([pscustomobject]@{matchMode=[string]$rule.matchMode;executablePath=[string]$rule.executablePath;controls=$controls})
                } catch {$damaged.Add($file.Name)}
            }
        }
        $statePath=Join-Path $root 'host.json'
        if(Test-Path -LiteralPath $statePath){
            $hostRead=Read-RooIndustriesGovernorJson $statePath $budget $clock $true
            if($hostRead.state -in @('unreadable','damaged')){$hostFailure=$hostRead.message}
            elseif($hostRead.state -eq 'read'){
                try {
                    foreach($instance in @($hostRead.data.instances)){
                        if([string]$instance.status -notin @('applying','active','conflict')){continue}
                        if($instance.PSObject.Properties['field'] -and $instance.field){$fields=@([string]$instance.field)}
                        else {
                            $preview=Read-RooIndustriesGovernorJson ([string]$instance.previewPath) $budget $clock $true
                            if($preview.state -eq 'read'){$fields=@($preview.data.desired.PSObject.Properties|ForEach-Object {$_.Name})}
                            else {$fields=$script:RooIndustriesGovernorAllControls;$unknown.Add([IO.Path]::GetFileName([string]$instance.previewPath)+' ('+$preview.message+')')}
                        }
                        $instances.Add([pscustomobject]@{processId=[int]$instance.process.processId;creationTimeFileTimeUtc=[string]$instance.process.creationTimeFileTimeUtc;controls=$fields})
                    }
                } catch {$hostFailure=if($_.Exception.Message){$_.Exception.Message}else{$_.Exception.GetType().FullName}}
            }
        }
    } catch {$failure=if($_.Exception.Message){$_.Exception.Message}else{$_.Exception.GetType().FullName}}
    if(-not $failure -or $clock.ElapsedMilliseconds -ge $budget){break}
    Start-Sleep -Milliseconds 50
    }
    $ownership=[pscustomobject]@{readAtUtc=$readAtUtc;rules=@($rules.ToArray());instances=@($instances.ToArray());failure=$failure;hostFailure=$hostFailure}
    if($failure -or $hostFailure -or $unreadable.Count -gt 0 -or $unknown.Count -gt 0){
        $script:RooIndustriesGovernorOwnershipFailedAtUtc=[DateTime]::UtcNow
        $sinceLog=([DateTime]::UtcNow-$script:RooIndustriesGovernorOwnershipLoggedAtUtc).TotalSeconds
        if($sinceLog -lt 0 -or $sinceLog -ge 60){
            $script:RooIndustriesGovernorOwnershipLoggedAtUtc=[DateTime]::UtcNow
            $parts=New-Object System.Collections.Generic.List[string]
            if($failure){$parts.Add('the folder failed after '+$attempts+' attempts over '+$clock.ElapsedMilliseconds+' ms, so this change treats every process setting as managed by the governor ('+$failure+')')}
            if($hostFailure){$parts.Add('host.json is unreadable ('+$hostFailure+'), so this change treats every setting of an app a saved rule matches as managed by the governor')}
            if($unknown.Count -gt 0){$parts.Add('these records of changed processes are unreadable, so this change treats every setting of those processes as managed by the governor ('+($unknown -join '; ')+')')}
            if($unreadable.Count -gt 0){$parts.Add('these rule files are unreadable and claim nothing until they can be read ('+($unreadable -join '; ')+')')}
            Write-RooIndustriesGovernorOwnershipLog ('Could not read the saved rules in '+$root+': '+($parts -join '; '))}
        return $ownership
    }
    if($damaged.Count -gt 0){
        $sinceDamaged=([DateTime]::UtcNow-$script:RooIndustriesGovernorDamagedLoggedAtUtc).TotalSeconds
        if($sinceDamaged -lt 0 -or $sinceDamaged -ge 60){
            $script:RooIndustriesGovernorDamagedLoggedAtUtc=[DateTime]::UtcNow
            Write-RooIndustriesGovernorOwnershipLog ('Skipped a damaged saved rule while checking which process settings the governor manages: '+($damaged -join ', '))}
    }
    $script:RooIndustriesGovernorOwnership=$ownership
    return $ownership
}

function Enter-RooIndustriesGovernorGate([double]$Seconds=30) {
    $name='Global\RooIndustriesGovernorGate-'+[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $clock=[Diagnostics.Stopwatch]::StartNew()
    while($true){
        $mutex=$null
        try {$mutex=[Threading.Mutex]::new($false,$name)}
        catch {
            $failure=$_.Exception
            while($failure -is [Management.Automation.MethodInvocationException] -and $failure.InnerException){$failure=$failure.InnerException}
            if($failure -isnot [UnauthorizedAccessException]){throw}
            if($clock.Elapsed.TotalSeconds -ge $Seconds){return $null}
            Start-Sleep -Milliseconds 100
            continue
        }
        $held=$false
        try {$held=$mutex.WaitOne([TimeSpan]::FromSeconds([Math]::Max(0,$Seconds-$clock.Elapsed.TotalSeconds)))}
        catch {
            $failure=$_.Exception
            while($failure -is [Management.Automation.MethodInvocationException] -and $failure.InnerException){$failure=$failure.InnerException}
            if($failure -isnot [Threading.AbandonedMutexException]){$mutex.Dispose();throw}
            $held=$true
        }
        if(-not $held){$mutex.Dispose();return $null}
        $script:RooIndustriesGovernorOwnership=$null
        return $mutex
    }
}

function Exit-RooIndustriesGovernorGate($Gate) {
    if($null -eq $Gate){return}
    try {$Gate.ReleaseMutex()} finally {$Gate.Dispose()}
}

function Get-RooIndustriesGovernorOwnedControls {
    param([int]$ProcessId,[string]$ExecutablePath,[string]$ImageName,[string]$CreationTimeFileTimeUtc)
    $ownership=Get-RooIndustriesGovernorOwnership
    if($ownership.failure){return $script:RooIndustriesGovernorAllControls}
    $owned=New-Object 'System.Collections.Generic.HashSet[string]'
    $matched=$false
    if(-not $ImageName -and $ExecutablePath){$ImageName=[IO.Path]::GetFileName($ExecutablePath)}
    foreach($rule in $ownership.rules){
        $ruleName=[IO.Path]::GetFileName($rule.executablePath)
        $match=if($rule.matchMode -eq 'filename' -or -not $ExecutablePath){$ruleName -ieq $ImageName}else{$rule.executablePath -ieq $ExecutablePath}
        if($match){$matched=$true;foreach($control in $rule.controls){[void]$owned.Add([string]$control)}}
    }
    if($ownership.hostFailure -and $matched){return $script:RooIndustriesGovernorAllControls}
    foreach($instance in $ownership.instances){
        if($instance.processId -eq $ProcessId -and (-not $CreationTimeFileTimeUtc -or $instance.creationTimeFileTimeUtc -eq $CreationTimeFileTimeUtc)){
            foreach($control in $instance.controls){[void]$owned.Add([string]$control)}
        }
    }
    return @($owned)
}

function Get-RooIndustriesGovernorProcessControls {
    param([System.Diagnostics.Process]$Process)
    if($null -eq $Process){return @()}
    $path=$null;try{$path=$Process.Path}catch{}
    $created=$null;try{$created=[string]$Process.StartTime.ToUniversalTime().ToFileTimeUtc()}catch{}
    $image=$null;try{$image=if($path){[IO.Path]::GetFileName($path)}else{$Process.ProcessName+'.exe'}}catch{}
    return @(Get-RooIndustriesGovernorOwnedControls -ProcessId $Process.Id -ExecutablePath $path -ImageName $image -CreationTimeFileTimeUtc $created)
}

function Test-RooIndustriesGovernorOwnsControl {
    param([System.Diagnostics.Process]$Process,[string]$Control)
    if($null -eq $Process){return $false}
    $native=switch($Control){'priorityClass'{'cpuPriority'} 'affinityMask'{'affinity'} default{$Control}}
    return @(Get-RooIndustriesGovernorProcessControls $Process) -contains $native
}
