param([Parameter(Mandatory=$true)][string]$Source,[Parameter(Mandatory=$true)][string]$OutDir,[ValidateSet('capture','direct','contexts','performance','large-worker')][string]$Mode='capture',[string]$PrivateKey='',[Parameter(Mandatory)][string]$ExpectedMachine)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
if($env:COMPUTERNAME -cne $ExpectedMachine){throw 'Wrong fixture machine'}
. (Join-Path $Source 'tools\validation\LoadTimes\CleanupOwnership.Common.ps1')
$errors=$null;$tokens=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $Source 'tools\validation\Release\Invoke-IntegrationVerification.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Runner parse failed'}
foreach($name in 'Get-MachineState','Get-VerificationInvocationTask','Assert-SealedRecovery','Assert-PlainRecoveryPath','Invoke-Native','Get-RegistryFingerprint','Get-RecoveryRegistry','Resolve-RecoveryRegistryKey','Get-RecoveryRegistryHandleValue','Get-RecoveryRegistryValue','Restore-RecoveryRegistryField','Assert-RecoveryEqual','New-RecoveryScope','Assert-RecoveryEvidenceParent','New-SealedDirectory','Get-RecoveryNames','Get-TreeFingerprint','Save-RecoveryJson','Get-RecoveryAuxiliaryBaseline'){
    $f=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$true))
    if($f.Count -eq 1){. ([scriptblock]::Create($f[0].Extent.Text))}elseif($name -cne 'Get-VerificationInvocationTask'){throw ('Missing function '+$name)}
}
$personalize='HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
$productKeys=@('HKLM:\SOFTWARE\RooIndustries\OptimizationSuite','HKLM:\SOFTWARE\RooIndustries')
$ifeoProbe='HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\RooIndustriesProtectedGameProbe.exe'
$blockerFolder=Join-Path $env:ProgramFiles 'LogiDownloadAssistant'
$local=[Environment]::GetFolderPath('LocalApplicationData')
$userEnvironment='HKCU:\Environment'
function Assert([bool]$Ok,[string]$Text){if(-not$Ok){throw $Text}}
function Refuses([scriptblock]$Body,[string]$Name){$failed=$false;try{& $Body|Out-Null}catch{$failed=$true;[IO.File]::AppendAllText((Join-Path $OutDir 'refusals.log'),$Name+': '+$_.Exception.Message+"`n")};Assert $failed ($Name+' accepted')}
if($Mode -eq 'large-worker'){
    $deadline=[DateTime]::UtcNow.AddSeconds(10)
    while(-not(Test-Path -LiteralPath (Join-Path $OutDir 'go'))){if([DateTime]::UtcNow -gt $deadline){throw 'Missing retained worker receipt gate'};Start-Sleep -Milliseconds 50}
    $measure=[ordered]@{}
    foreach($stage in 'fingerprint','capture','serialize','baseline','large-restore'){
        [IO.File]::WriteAllText((Join-Path $OutDir 'stage.txt'),$stage)
        $watch=[Diagnostics.Stopwatch]::StartNew()
        switch($stage){
            'fingerprint' {$measure.fingerprint=Get-RegistryFingerprint $PrivateKey}
            'capture' {$rows=@(Get-RecoveryRegistry $PrivateKey);$measure.rows=$rows.Count}
            'serialize' {$json=ConvertTo-Json -InputObject $rows -Depth 30 -Compress;$measure.jsonLength=$json.Length;[IO.File]::WriteAllText((Join-Path $OutDir 'private-baseline.json'),$json)}
            'baseline' {
                $rows=$null;$json=$null
                $backup=Join-Path $OutDir 'private-recovery';$local=Join-Path $OutDir 'absent-private-data'
                $rooHklm=$PrivateKey;$stateKey=$PrivateKey+'\Absent'
                $personalize='Registry::'+$PrivateKey+'\AbsentPersonalize';$userEnvironment='Registry::'+$PrivateKey+'\AbsentEnvironment';$plantedName='FixtureOnly'
                function Log([string]$Text){[IO.File]::AppendAllText((Join-Path $OutDir 'private-capture.log'),$Text+"`n")}
                New-RecoveryScope ([ordered]@{fixture=$true})
                $measure.baselineBytes=(Get-Item -LiteralPath (Join-Path $backup 'recovery-scope.json')).Length
            }
            'large-restore' {
                $before=Get-RecoveryRegistryValue $PrivateKey 'State'
                $path=$PrivateKey.Substring('HKEY_LOCAL_MACHINE\'.Length)
                $k=[Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($path,$true);$k.SetValue('State',[byte[]]@(2,5,9),[Microsoft.Win32.RegistryValueKind]::Binary);$k.Dispose()
                $expected=Get-RecoveryRegistryValue $PrivateKey 'State'
                Restore-RecoveryRegistryField @{identity=@{key=$PrivateKey;name='State'};original=@($before);expected=@($expected)}
                Assert ((Get-RecoveryRegistryValue $PrivateKey 'State') -ceq $before) 'Large binary restoration differs'
                Refuses {Restore-RecoveryRegistryField @{identity=@{key=$PrivateKey;name='State'};original=@($before);expected=@($expected)}} 'changed-field large State'
                $measure.largeRestoreExact=$true
            }
        }
        $measure[$stage+'Ms']=$watch.ElapsedMilliseconds
        [IO.File]::WriteAllText((Join-Path $OutDir 'timings.json'),(ConvertTo-Json -InputObject $measure -Compress))
    }
    exit 0
}
[IO.Directory]::CreateDirectory($OutDir)|Out-Null
if($Mode -eq 'direct'){
    Assert ($null -eq (Get-Variable RooIndustriesVerificationInvocationContext -Scope Global -ErrorAction SilentlyContinue)) 'Direct fixture unexpectedly wrapped'
    $foreign=Get-Content -Raw (Join-Path $OutDir 'foreign-task.json')|ConvertFrom-Json
    $state=Get-MachineState
    Assert ($state.tasks -ccontains ($foreign.path+$foreign.name)) 'Direct SSH call hid foreign task'
    Assert-OwnedTaskUnchanged $foreign
    $state|ConvertTo-Json -Depth 10|Set-Content (Join-Path $OutDir 'machine-state.json')
    'PASS actual-direct-unwrapped-machine-state'
    exit 0
}
if($Mode -eq 'capture'){
    $state=Get-MachineState
    $own=if($global:RooIndustriesVerificationInvocationContext){$global:RooIndustriesVerificationInvocationContext.task.name}else{Split-Path $OutDir -Leaf}
    $state|ConvertTo-Json -Depth 10|Set-Content -LiteralPath (Join-Path $OutDir 'machine-state.json')
    Assert ($state.tasks -cnotcontains ('\'+$own)) 'Current real wrapper was captured in its own baseline'
    'PASS actual-machine-state-capture'
    exit 0
}
if($Mode -eq 'contexts'){
    $saved=Get-Variable RooIndustriesVerificationInvocationContext -Scope Global -ErrorAction SilentlyContinue
    Assert ($null -ne $saved) 'Missing bootstrap invocation context'
    $original=$saved.Value
    $foreign=Get-Content -Raw (Join-Path $OutDir 'foreign-task.json')|ConvertFrom-Json
    $results=[Collections.Generic.List[string]]::new()
    try{
        $state=Get-MachineState
        Assert ($state.tasks -ccontains ($foreign.path+$foreign.name)) 'Foreign GUID wrapper hidden'
        Assert ($state.tasks -cnotcontains ($original.task.path+$original.task.name)) 'Current wrapper included'
        $results.Add('verified-current-only')
        $global:RooIndustriesVerificationInvocationContext=$null
        Refuses {Get-MachineState} 'missing explicit context';$results.Add('missing-context-refuses')
        foreach($field in 'task','wrapper'){
            $bad=$original|ConvertTo-Json -Depth 15|ConvertFrom-Json
            $bad.$field=$null;$global:RooIndustriesVerificationInvocationContext=$bad
            Refuses {Get-MachineState} ('missing '+$field);$results.Add('missing-'+$field+'-refuses')
        }
        $bad=$original|ConvertTo-Json -Depth 15|ConvertFrom-Json;$bad.task=$foreign;$global:RooIndustriesVerificationInvocationContext=$bad
        Refuses {Get-MachineState} 'foreign task context';$results.Add('foreign-task-refuses')
        foreach($field in 'pid','creationTimeFileTimeUtc','imagePath'){
            $bad=$original|ConvertTo-Json -Depth 15|ConvertFrom-Json
            switch($field){'pid'{$bad.wrapper.pid=$PID};'creationTimeFileTimeUtc'{$bad.wrapper.creationTimeFileTimeUtc=([long]$bad.wrapper.creationTimeFileTimeUtc+1).ToString()};'imagePath'{$bad.wrapper.imagePath=[RooIndustriesValidationOwnership.Native]::Canonical((Join-Path ([Environment]::SystemDirectory) 'cmd.exe'))}}
            $global:RooIndustriesVerificationInvocationContext=$bad;Refuses {Get-MachineState} ('substituted parent '+$field);$results.Add('parent-'+$field+'-refuses')
            $retained=Join-Path $original.run 'wrapper.json';$text=[IO.File]::ReadAllText($retained)
            try{
                [IO.File]::WriteAllText($retained,(ConvertTo-Json -InputObject $bad.wrapper -Compress))
                Refuses {Get-MachineState} ('native substituted parent '+$field);$results.Add('native-parent-'+$field+'-refuses')
            }finally{[IO.File]::WriteAllText($retained,$text)}
        }
        $bad=$original|ConvertTo-Json -Depth 15|ConvertFrom-Json;$bad.task.xml=$bad.task.xml.Replace('Roo Industries validation ownership','substituted ownership');$global:RooIndustriesVerificationInvocationContext=$bad
        Refuses {Get-MachineState} 'changed task XML';$results.Add('task-xml-refuses')
        $bad=$original|ConvertTo-Json -Depth 15|ConvertFrom-Json;$bad.task.sddl='changed';$global:RooIndustriesVerificationInvocationContext=$bad
        Refuses {Get-MachineState} 'changed task SDDL';$results.Add('task-sddl-refuses')
        $global:RooIndustriesVerificationInvocationContext=$original
        $originalInvoke=(Get-Item Function:Invoke-Native).ScriptBlock
        try{
            function Invoke-Native([string]$File,[string[]]$Arguments,[string[]]$Stdin=@()){
                $result=& $originalInvoke $File $Arguments $Stdin
                $global:RooIndustriesVerificationInvocationContext=$original|ConvertTo-Json -Depth 15|ConvertFrom-Json
                $global:RooIndustriesVerificationInvocationContext.task.sddl='changed after initial verification'
                return $result
            }
            Refuses {Get-MachineState} 'context changes after initial proof';$results.Add('context-change-during-capture-refuses')
        }finally{Set-Item Function:Invoke-Native $originalInvoke;$global:RooIndustriesVerificationInvocationContext=$original}
        Remove-Variable RooIndustriesVerificationInvocationContext -Scope Global
        $direct=Get-MachineState
        Assert ($direct.tasks -ccontains ($foreign.path+$foreign.name) -and $direct.tasks -ccontains ($original.task.path+$original.task.name)) 'Direct unwrapped capture excluded a discovered task'
        $results.Add('direct-unwrapped-includes-all')
        Assert-OwnedTaskUnchanged $foreign
        $results|ConvertTo-Json|Set-Content (Join-Path $OutDir 'context-checks.json')
        'PASS exact-context-cases '+$results.Count
    }finally{$global:RooIndustriesVerificationInvocationContext=$original}
    exit 0
}
$fixture='SOFTWARE\RooIndustriesPreflightFixture_'+[Guid]::NewGuid().ToString('N')
$key=[Microsoft.Win32.Registry]::LocalMachine.CreateSubKey($fixture)
$private='HKEY_LOCAL_MACHINE\'+$fixture
$owned=$null;$worker=$null
try{
    $bytes=[byte[]]::new(7529986);for($i=0;$i -lt $bytes.Length;$i++){$bytes[$i]=[byte]($i%251)}
    $key.SetValue('State',$bytes,[Microsoft.Win32.RegistryValueKind]::Binary)
    $key.Dispose();$key=$null
    [IO.File]::WriteAllText((Join-Path $OutDir 'private-key.json'),(ConvertTo-Json @{key=$private;length=$bytes.Length}))
    $arguments='-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+$PSCommandPath+'" -ExpectedMachine "'+$ExpectedMachine+'" -Source "'+$Source+'" -OutDir "'+$OutDir+'" -Mode large-worker -PrivateKey "'+$private+'"'
    $worker=Start-Process (Join-Path ([Environment]::SystemDirectory) 'WindowsPowerShell\v1.0\powershell.exe') -ArgumentList $arguments -WindowStyle Hidden -RedirectStandardOutput (Join-Path $OutDir 'worker.log') -RedirectStandardError (Join-Path $OutDir 'worker-error.log') -PassThru
    $owned=New-OwnedProcess $worker
    Assert ($null -ne $owned) 'Worker exited before retained identity'
    $owned.Identity|ConvertTo-Json|Set-Content (Join-Path $OutDir 'worker-native.json')
    [IO.File]::WriteAllText((Join-Path $OutDir 'go'),'receipt retained')
    $watch=[Diagnostics.Stopwatch]::StartNew();$peak=0L;$reason='';$peaks=@{}
    while(-not$worker.HasExited){
        $worker.Refresh();$peak=[Math]::Max($peak,$worker.PrivateMemorySize64)
        $at=if(Test-Path (Join-Path $OutDir 'stage.txt')){[IO.File]::ReadAllText((Join-Path $OutDir 'stage.txt'))}else{'startup'}
        $peaks[$at]=[Math]::Max([long]$peaks[$at],$worker.PrivateMemorySize64)
        if($watch.Elapsed.TotalSeconds -gt 40){$reason='40-second elapsed bound';break};if($peak -gt 2GB){$reason='2-GiB private-memory bound';break};Start-Sleep -Milliseconds 100
    }
    if($reason){Stop-OwnedProcess $owned}else{$worker.Refresh()}
    $stage=if(Test-Path (Join-Path $OutDir 'stage.txt')){[IO.File]::ReadAllText((Join-Path $OutDir 'stage.txt'))}else{'startup'}
    @{elapsedMs=$watch.ElapsedMilliseconds;peakPrivateBytes=$peak;stagePeaks=$peaks;bound=$reason;stage=$stage;exit=$worker.ExitCode;passed=(-not$reason -and $worker.ExitCode -eq 0)}|ConvertTo-Json|Set-Content (Join-Path $OutDir 'bound.json')
    Assert (-not$reason) ('Large State exceeded '+$reason+' in '+$stage)
    Assert ($worker.ExitCode -eq 0) ('Worker exit '+$worker.ExitCode)
    $k=[Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($fixture,$true)
    $k.SetValue('Expand','%USERPROFILE%\raw',[Microsoft.Win32.RegistryValueKind]::ExpandString)
    $k.SetValue('Multi',[string[]]@('first','','last'),[Microsoft.Win32.RegistryValueKind]::MultiString)
    $k.SetValue('Small',[byte[]]@(0,1,255),[Microsoft.Win32.RegistryValueKind]::Binary)
    $k.SetValue('Empty',[byte[]]@(),[Microsoft.Win32.RegistryValueKind]::Binary)
    $k.CreateSubKey('EmptyKey').Dispose();$k.Dispose()
    Assert ((Get-RegistryFingerprint $private) -match '^[A-F0-9]{64}$') 'Empty binary fingerprint failed'
    foreach($name in 'Small','Empty','Expand','Multi'){
        $before=Get-RecoveryRegistryValue $private $name
        $raw=$before|ConvertFrom-Json
        switch($name){
            'Small' {Assert ($raw.kind -ceq 'Binary' -and ($raw.value -join ',') -ceq '0,1,255') 'Small binary bytes differ'}
            'Empty' {Assert ($raw.kind -ceq 'Binary' -and @($raw.value).Count -eq 0) 'Empty binary value lost'}
            'Expand' {Assert ($raw.kind -ceq 'ExpandString' -and $raw.value -ceq '%USERPROFILE%\raw') 'ExpandString was expanded'}
            'Multi' {Assert ($raw.kind -ceq 'MultiString' -and ($raw.value -join '|') -ceq 'first||last') 'MultiString raw values differ'}
        }
        $k=[Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($fixture,$true);$k.SetValue($name,'changed',[Microsoft.Win32.RegistryValueKind]::String);$k.Dispose()
        $expected=Get-RecoveryRegistryValue $private $name
        $plan=@{identity=@{key=$private;name=$name};original=@($before);expected=@($expected)}
        Restore-RecoveryRegistryField $plan;Assert ((Get-RecoveryRegistryValue $private $name) -ceq $before) ('Restore differs '+$name)
        Refuses {Restore-RecoveryRegistryField $plan} ('changed-field '+$name)
    }
    Assert ((Get-RecoveryRegistryValue ($private+'\Absent') 'absent') -ceq '<missing>') 'Missing key differs'
    Assert ((Get-RecoveryRegistryValue $private 'absent') -ceq '<missing>') 'Missing value differs'
    $k=[Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($fixture,$true);$k.SetValue('PreviouslyAbsent','temporary',[Microsoft.Win32.RegistryValueKind]::String);$k.Dispose()
    Restore-RecoveryRegistryField @{identity=@{key=$private;name='PreviouslyAbsent'};original=@('<missing>');expected=@(Get-RecoveryRegistryValue $private 'PreviouslyAbsent')}
    Assert ((Get-RecoveryRegistryValue $private 'PreviouslyAbsent') -ceq '<missing>') 'Absent original value was not removed exactly'
    Assert (@(Get-RecoveryRegistry ($private+'\EmptyKey')).Count -eq 1) 'Empty key lost'
    'PASS private-large-state-bound-and-raw-restoration'
}finally{
    if($owned){Stop-OwnedProcess $owned;$worker.Dispose()};if($key){$key.Dispose()}
    [Microsoft.Win32.Registry]::LocalMachine.DeleteSubKeyTree($fixture,$false)
    Assert ($null -eq [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($fixture)) 'Private hive remains'
    @{privateHiveAbsent=$true;ownedWorkerStopped=$true}|ConvertTo-Json|Set-Content (Join-Path $OutDir 'leftovers.json')
}
