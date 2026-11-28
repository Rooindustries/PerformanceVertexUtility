. (Join-Path $PSScriptRoot 'ProcessProfile.Common.ps1')

function Wait-RooIndustriesValidationProcess {
    param([System.Diagnostics.Process]$Process, [int]$TimeoutSeconds = 5)
    if ($null -eq $Process) { return }
    if (-not $Process.WaitForExit($TimeoutSeconds * 1000)) { throw "Validation process $($Process.Id) did not exit within $TimeoutSeconds seconds." }
}

function Stop-RooIndustriesValidationProcess {
    param([System.Diagnostics.Process]$Process)
    if ($null -eq $Process) { return }
    $Process.Refresh()
    if (-not $Process.HasExited) { $Process.Kill() }
    Wait-RooIndustriesValidationProcess $Process 5
}

function Set-RooIndustriesValidationNormalPriority {
    $current = [System.Diagnostics.Process]::GetCurrentProcess()
    $current.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::Normal
    Set-RooIndustriesProcessIoPriority $current 'Normal'
    $current.Dispose()
}

function Start-RooIndustriesFixtureGuard {
    param([string[]]$CurrentUserKeys=@(),[string]$MachineKey='',[string[]]$MachineValues=@(),[string[]]$Files=@(),
        [string[]]$Folders=@(),[string[]]$EmptyFolders=@(),[string]$ReceiptFolder='')
    $current=[Diagnostics.Process]::GetCurrentProcess()
    $plan=@{processId=$current.Id;started=$current.StartTime.ToUniversalTime().Ticks;keys=@($CurrentUserKeys);machineKey=$MachineKey
        values=@($MachineValues);files=@($Files);folders=@($Folders);emptyFolders=@($EmptyFolders);receipts=$ReceiptFolder}
    $payload=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($plan|ConvertTo-Json -Compress)))
    $guard=@'
$plan=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('PLAN'))|ConvertFrom-Json
try {$test=[Diagnostics.Process]::GetProcessById($plan.processId)} catch [ArgumentException] {$test=$null}
if($test -and $test.StartTime.ToUniversalTime().Ticks -eq $plan.started){$test.WaitForExit()}
$keys=@($plan.keys)
if($plan.receipts -and [IO.Directory]::Exists($plan.receipts)){
    foreach($preview in [IO.Directory]::GetFiles($plan.receipts,'*-registry-preview.json')){
        $receipt=[string]([IO.File]::ReadAllText($preview)|ConvertFrom-Json).receipt.keyPath
        if($receipt -match '^Software\\RooIndustriesOptimizationSuite\.Receipt\.[0-9a-f]{32}$'){$keys+=$receipt}
    }
}
foreach($key in $keys){[Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($key,$false)}
if($plan.machineKey){
    $machine=[Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($plan.machineKey,$true)
    if($machine){try{foreach($value in @($plan.values)){$machine.DeleteValue($value,$false)}}finally{$machine.Dispose()}}
}
foreach($file in @($plan.files)){if([IO.File]::Exists($file)){[IO.File]::Delete($file)}}
foreach($folder in @($plan.folders)){if([IO.Directory]::Exists($folder)){Remove-Item -LiteralPath $folder -Recurse -Force}}
foreach($folder in @($plan.emptyFolders)){
    if([IO.Directory]::Exists($folder) -and [IO.Directory]::GetFileSystemEntries($folder).Length -eq 0){[IO.Directory]::Delete($folder)}
}
'@
    $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($guard.Replace('PLAN',$payload)))
    $shell=Join-Path $PSHOME 'powershell.exe'
    $line='"'+$shell+'" -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -EncodedCommand '+$encoded
    $started=Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{CommandLine=$line}
    if($started.ReturnValue -ne 0){throw ('The fixture guard did not start (Win32_Process.Create returned '+$started.ReturnValue+').')}
}
