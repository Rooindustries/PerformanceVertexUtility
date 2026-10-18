function Assert-HandoffProtected([string]$Path) {
    $p=[IO.Path]::GetFullPath($Path)
    while($p){if((Get-Item -LiteralPath $p -Force -ErrorAction Stop).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Handoff path has reparse ancestry'};$p=[IO.Path]::GetDirectoryName($p)}
    $acl=Get-Acl -LiteralPath $Path
    if($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -notin 'S-1-5-18','S-1-5-32-544'){throw 'Handoff evidence owner is not SYSTEM/Admin'}
    foreach($ace in $acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])){if($ace.AccessControlType -eq 'Allow' -and $ace.IdentityReference.Value -notin 'S-1-5-18','S-1-5-32-544' -and ([long]$ace.FileSystemRights -band 0x500D0156)){throw 'Handoff evidence has an untrusted writer'}}
}
function Read-HandoffJson([string]$Path) {
    Assert-HandoffProtected $Path
    $stream=[IO.File]::Open($Path,'Open','Read','Read')
    try{
        if($stream.Length -lt 2 -or $stream.Length -gt 4194304){throw 'Handoff JSON size invalid'}
        $reader=[IO.StreamReader]::new($stream,[Text.UTF8Encoding]::new($false,$true),$true)
        $hash=[BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($stream)).Replace('-','');$stream.Position=0
        $text=$reader.ReadToEnd()
        $value=$text|ConvertFrom-Json -ErrorAction Stop
        if($null -eq $value){throw 'Handoff JSON is empty'}
        [pscustomobject]@{value=$value;hash=$hash}
    }finally{$stream.Dispose()}
}
function Assert-HandoffFields($Value,[string[]]$Names) {
    if($null -eq $Value -or @(Compare-Object @($Value.PSObject.Properties.Name|Sort-Object) @($Names|Sort-Object) -CaseSensitive).Count){throw 'Handoff JSON schema differs'}
}
function Handoff-Json($Value){ConvertTo-Json -InputObject $Value -Depth 30 -Compress}
function Save-HandoffJson([string]$Path,$Value,[switch]$Create) {
    Assert-HandoffProtected (Split-Path $Path -Parent)
    $bytes=[Text.UTF8Encoding]::new($false).GetBytes((Handoff-Json $Value))
    if($Create){$stream=[IO.File]::Open($Path,'CreateNew','Write','None');try{$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()};return}
    Assert-HandoffProtected $Path
    $temp=$Path+'.pending-'+[Guid]::NewGuid().ToString('N')
    Save-HandoffJson $temp $Value -Create
    [IO.File]::Replace($temp,$Path,[Management.Automation.Language.NullString]::Value)
}
function Assert-HandoffContext($Context) {
    Assert-HandoffProtected $Context.root
    $lease=Read-HandoffJson $Context.leasePath
    if($lease.hash -cne $Context.leaseHash -or $lease.value.label -cne 'installed' -or $lease.value.sid -cne [Security.Principal.WindowsIdentity]::GetCurrent().User.Value){throw 'Handoff installed lease changed'}
    foreach($name in 'restore-journal.json','restore-complete.json'){if(Test-Path -LiteralPath (Join-Path (Split-Path $Context.leasePath -Parent) $name)){throw 'Handoff installed epoch is recovering or completed'}}
}
function New-HandoffContext([string]$Root,[string]$LeasePath) {
    Assert-HandoffProtected $Root
    $lease=Read-HandoffJson $LeasePath
    if($lease.value.label -cne 'installed' -or $lease.value.sid -cne [Security.Principal.WindowsIdentity]::GetCurrent().User.Value -or -not$lease.value.startUtc -or -not$lease.value.baselineHash){throw 'Handoff lease is incomplete or not installed'}
    $context=[pscustomobject]@{root=[IO.Path]::GetFullPath($Root);leasePath=[IO.Path]::GetFullPath($LeasePath);leaseHash=$lease.hash;ledgerPath=(Join-Path $Root ('persistent-ledger-'+$lease.hash+'.json'))}
    Assert-HandoffContext $context
    $context
}
function Invoke-HandoffLocked($Context,[scriptblock]$Body) {
    Assert-HandoffContext $Context
    $path=$Context.ledgerPath+'.lock';$lock=$null
    if(Test-Path -LiteralPath $path){Assert-HandoffProtected $path}
    try{$lock=[IO.File]::Open($path,'OpenOrCreate','ReadWrite','None');Assert-HandoffProtected $path;& $Body}finally{if($lock){$lock.Dispose()}}
}
function Assert-HandoffResource([ValidateSet('process','task')][string]$Kind,$Resource) {
    if($Kind -ceq 'process'){
        Assert-HandoffFields $Resource @('pid','creationTimeFileTimeUtc','imagePath')
        if([string]$Resource.pid -notmatch '^[1-9][0-9]*$' -or [string]$Resource.creationTimeFileTimeUtc -notmatch '^[1-9][0-9]*$' -or [string]$Resource.imagePath -notmatch '^\\\\\?\\[A-Za-z]:\\'){throw 'Handoff process identity invalid'}
        return
    }
    Assert-HandoffFields $Resource @('name','path','xml','sddl')
    if(-not$Resource.name -or [string]$Resource.path -notmatch '^\\(?:.*\\)?$' -or -not$Resource.xml -or -not$Resource.sddl){throw 'Handoff task identity invalid'}
    $definition=[xml]$Resource.xml
    if(-not$definition.Task.Actions.Exec.Command){throw 'Handoff task action missing'}
    $null=[Security.AccessControl.RawSecurityDescriptor]::new([string]$Resource.sddl)
}
function Get-HandoffResourceState([ValidateSet('process','task')][string]$Kind,$Resource) {
    Assert-HandoffResource $Kind $Resource
    if($Kind -ceq 'process'){
        try{$process=Get-Process -Id ([int]$Resource.pid) -ErrorAction Stop}catch{if($_.FullyQualifiedErrorId -like 'NoProcessFoundForGivenId,*'){return 'gone'};throw}
        try{
            $handle=$process.Handle
            if([RooIndustriesValidationOwnership.Native]::Created($handle).ToString() -cne [string]$Resource.creationTimeFileTimeUtc){return 'gone'}
            if([RooIndustriesValidationOwnership.Native]::Image($handle) -cne [string]$Resource.imagePath){throw 'Handoff live process identity changed'}
            if($process.HasExited){return 'gone'}
            return 'live'
        }finally{$process.Dispose()}
    }
    $folder=Get-OwnedTaskFolder $Resource.path
    try{$task=$folder.GetTask($Resource.name)}catch{if($_.Exception.HResult -eq -2147024894){return 'gone'};throw}
    if($task.Name -cne [string]$Resource.name -or $task.Xml -cne [string]$Resource.xml -or $task.GetSecurityDescriptor(7) -cne [string]$Resource.sddl){throw 'Handoff live task XML/security/action changed'}
    return 'live'
}
function New-HandoffProducerRequest($Context,[string]$Scenario,[string]$OutDir,[string]$ScriptPath,$Arguments,$Task) {
    Assert-HandoffContext $Context
    if($Scenario -cnotin 'migration-before','migration-timer-on' -or [IO.Path]::GetFullPath($OutDir) -cne (Join-Path $Context.root $Scenario)){throw 'Handoff producer is outside scenario scope'}
    Assert-HandoffProtected $OutDir;Assert-HandoffProtected $ScriptPath
    $path=Join-Path $OutDir 'producer-request.json'
    Save-HandoffJson $path ([ordered]@{protocol='roo-loadtimes-producer/v1';scenario=$Scenario;outDir=$OutDir;leasePath=$Context.leasePath;leaseHash=$Context.leaseHash;scriptPath=$ScriptPath;scriptHash=(Get-FileHash -LiteralPath $ScriptPath -Algorithm SHA256).Hash;arguments=$Arguments;task=$Task}) -Create
    $path
}
function Get-HandoffProducer($Context,[string]$Scenario) {
    if($Scenario -cnotin 'migration-before','migration-timer-on'){throw 'Unknown handoff producer'}
    $dir=Join-Path $Context.root $Scenario
    $request=Read-HandoffJson (Join-Path $dir 'producer-request.json');$r=$request.value
    Assert-HandoffFields $r @('protocol','scenario','outDir','leasePath','leaseHash','scriptPath','scriptHash','arguments','task')
    if($r.protocol -cne 'roo-loadtimes-producer/v1' -or $r.scenario -cne $Scenario -or $r.outDir -cne $dir -or $r.leasePath -cne $Context.leasePath -or $r.leaseHash -cne $Context.leaseHash -or (Get-FileHash -LiteralPath $r.scriptPath -Algorithm SHA256).Hash -cne $r.scriptHash){throw 'Handoff producer request scope/source differs'}
    Assert-HandoffProtected $r.scriptPath
    Assert-HandoffFields $r.task @('name','path','xml','sddl')
    $child=Read-HandoffJson (Join-Path $dir 'producer-child.json')
    Assert-HandoffFields $child.value @('pid','creationTimeFileTimeUtc','imagePath')
    $completion=Read-HandoffJson (Join-Path $dir 'completed-child.json');$c=$completion.value
    Assert-HandoffFields $c @('protocol','scenario','status','exit','identity','requestHash','childHash','resourcesHash','startedUtc','completedUtc')
    if($c.protocol -cne 'roo-loadtimes-completed/v1' -or $c.scenario -cne $Scenario -or $c.status -cne 'completed' -or $c.exit -ne 0 -or $c.requestHash -cne $request.hash -or $c.childHash -cne $child.hash -or (Handoff-Json $c.identity) -cne (Handoff-Json $child.value)){throw 'Handoff native completed-child receipt differs'}
    if([string]$c.identity.pid -notmatch '^[1-9][0-9]*$' -or [string]$c.identity.creationTimeFileTimeUtc -notmatch '^[1-9][0-9]*$' -or $c.identity.imagePath -cne [RooIndustriesValidationOwnership.Native]::Canonical((Join-Path $PSHOME 'powershell.exe')) -or [DateTime]::Parse($c.completedUtc).ToUniversalTime() -lt [DateTime]::FromFileTimeUtc([long]$c.identity.creationTimeFileTimeUtc) -or [DateTime]::Parse($c.startedUtc).ToUniversalTime() -gt [DateTime]::FromFileTimeUtc([long]$c.identity.creationTimeFileTimeUtc)){throw 'Handoff native child identity/time invalid'}
    if(-not(Test-Path -LiteralPath (Join-Path $dir ($Scenario+'.done')))){throw 'Handoff producer done marker missing'}
    $resources=Read-HandoffJson (Join-Path $dir 'persistent-resources.json')
    Assert-HandoffFields $resources.value @('scenario','tasks','processes')
    if($resources.hash -cne $c.resourcesHash -or $resources.value.scenario -cne $Scenario -or @($resources.value.tasks).Count+@($resources.value.processes).Count -eq 0 -or @($resources.value.tasks).Count+@($resources.value.processes).Count -gt 64){throw 'Handoff producer resource receipt differs'}
    [pscustomobject]@{receiptHash=$completion.hash;resources=$resources.value}
}
function Read-HandoffLedgerUnlocked($Context,[switch]$Prune,[switch]$ProvenanceOnly) {
    if(-not(Test-Path -LiteralPath $Context.ledgerPath)){
        foreach($scenario in 'migration-before','migration-timer-on'){if(Test-Path -LiteralPath (Join-Path (Join-Path $Context.root $scenario) 'completed-child.json')){throw 'Handoff ledger missing after completed producer'}}
        return [pscustomobject]@{protocol='roo-loadtimes-ledger/v1';leaseHash=$Context.leaseHash;entries=@()}
    }
    $ledger=(Read-HandoffJson $Context.ledgerPath).value
    Assert-HandoffFields $ledger @('protocol','leaseHash','entries')
    if($ledger.protocol -cne 'roo-loadtimes-ledger/v1' -or $ledger.leaseHash -cne $Context.leaseHash -or $null -eq $ledger.entries -or @($ledger.entries).Count -gt 128){throw 'Handoff ledger scope/schema invalid'}
    $live=[Collections.Generic.List[object]]::new();$seen=@{}
    foreach($entry in @($ledger.entries)){
        Assert-HandoffFields $entry @('producer','childReceiptHash','kind','index','resource')
        $producer=Get-HandoffProducer $Context $entry.producer
        $source=@(switch -CaseSensitive ($entry.kind){'task'{@($producer.resources.tasks)};'process'{@($producer.resources.processes)};default{throw 'Handoff resource kind invalid'}})
        if([string]$entry.index -notmatch '^(0|[1-9][0-9]*)$' -or [int]$entry.index -ge $source.Count -or $entry.childReceiptHash -cne $producer.receiptHash -or (Handoff-Json $entry.resource) -cne (Handoff-Json $source[[int]$entry.index])){throw 'Handoff ledger entry provenance differs'}
        $key=$entry.producer+'|'+$entry.kind+'|'+$entry.index
        if($seen.ContainsKey($key)){throw 'Duplicate handoff provenance'};$seen[$key]=$true
        Assert-HandoffResource $entry.kind $entry.resource
        if($ProvenanceOnly){continue}
        $state=Get-HandoffResourceState $entry.kind $entry.resource
        if($state -ceq 'live'){$live.Add($entry)}
    }
    if($Prune -and -not$ProvenanceOnly -and $live.Count -ne @($ledger.entries).Count){$ledger.entries=$live.ToArray();Save-HandoffJson $Context.ledgerPath $ledger}
    $ledger
}
function Read-HandoffLedger($Context,[switch]$Prune){Invoke-HandoffLocked $Context {Read-HandoffLedgerUnlocked $Context -Prune:$Prune}}
function Initialize-HandoffLedger($Context) {
    Invoke-HandoffLocked $Context {$ledger=Read-HandoffLedgerUnlocked $Context -ProvenanceOnly;if(-not(Test-Path -LiteralPath $Context.ledgerPath)){Save-HandoffJson $Context.ledgerPath $ledger -Create}}
}
function Add-HandoffProducer($Context,[string]$Scenario,[string]$OutDir) {
    if([IO.Path]::GetFullPath($OutDir) -cne (Join-Path $Context.root $Scenario)){throw 'Handoff producer output differs'}
    Invoke-HandoffLocked $Context {
        $ledger=Read-HandoffLedgerUnlocked $Context -Prune
        $producer=Get-HandoffProducer $Context $Scenario
        $entries=[Collections.Generic.List[object]]::new();foreach($existing in @($ledger.entries)){$entries.Add($existing)}
        foreach($kind in 'task','process'){
            $resources=@(if($kind -ceq 'task'){@($producer.resources.tasks)}else{@($producer.resources.processes)})
            for($i=0;$i -lt $resources.Count;$i++){
                if((Get-HandoffResourceState $kind $resources[$i]) -cne 'live'){continue}
                $entry=[pscustomobject][ordered]@{producer=$Scenario;childReceiptHash=$producer.receiptHash;kind=$kind;index=$i;resource=$resources[$i]}
                $same=@($entries|Where-Object {$_.producer -ceq $Scenario -and $_.kind -ceq $kind -and $_.index -eq $i})
                if($same.Count){if($same.Count -ne 1 -or (Handoff-Json $same[0]) -cne (Handoff-Json $entry)){throw 'Changed handoff producer entry'};continue}
                $entries.Add($entry)
            }
        }
        $ledger.entries=$entries.ToArray();Save-HandoffJson $Context.ledgerPath $ledger
    }
}
function Test-HandoffProcess($Ledger,$Process) {
    foreach($entry in @($Ledger.entries|Where-Object {$_.kind -ceq 'process' -and [int]$_.resource.pid -eq $Process.Id})){if((Get-HandoffResourceState 'process' $entry.resource) -ceq 'live'){return $true}}
    return $false
}
function Test-HandoffTask($Ledger,[string]$Name,[string]$Path,[switch]$Require) {
    foreach($entry in @($Ledger.entries|Where-Object {$_.kind -ceq 'task' -and $_.resource.name -ceq $Name -and $_.resource.path -ceq $Path})){if((Get-HandoffResourceState 'task' $entry.resource) -ceq 'live'){return $true}}
    if($Require){throw 'Task has no completed-producer ledger entry'}
    return $false
}
