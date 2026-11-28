    $loadFile=Join-Path $root 'load.ps1'
    [IO.File]::WriteAllText($loadFile,@'
param([string]$Mode,[string]$Dir)
if($Mode -eq 'burn'){while($true){}}
$b=New-Object byte[] 4194304
while($true){$s=[IO.FileStream]::new((Join-Path $Dir ([string]$PID+'.bin')),'Create','Write','None',4096,[IO.FileOptions]::WriteThrough);$s.Write($b,0,$b.Length);$s.Flush($true);$s.Dispose()}
'@)
    $loaders=New-Object System.Collections.Generic.List[Diagnostics.Process]
    $failing=0
    try{
        foreach($i in 1..([Environment]::ProcessorCount*2)){$loaders.Add((Start-Process powershell.exe -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "'+$loadFile+'" -Mode burn') -WindowStyle Hidden -PassThru))}
        foreach($i in 1..2){$loaders.Add((Start-Process powershell.exe -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "'+$loadFile+'" -Mode disk -Dir "'+$root+'"') -WindowStyle Hidden -PassThru))}
        Start-Sleep -Seconds 3
        foreach($n in 1..20){
            $p=Start-Probe
            $seconds=Wait-Until {Same (Read-Controls $p) $wanted} 30
            $script:check=$null
            $null=Wait-Until {($script:check=Get-NewProcessCheck $p).complete} 30
            $fc=$check.sevenInFirstCheck -eq $true;$gpu=$check.gpuOnTime -eq $true;$cpu=$check.processorSeconds
            $ok=$fc -and $gpu -and $null -ne $cpu -and $cpu -le 1.0
            if(-not $ok){$failing++}
            $records=@($check.records|ForEach-Object {[ordered]@{check=$_.checkStarted;previous=$_.previousCheckStarted;applied=@($_.applied).Count;refused=$_.refused;cpu=$_.processorSeconds}})
            Write-Output ('SCORE '+(([ordered]@{n=$n;ok=$ok;seconds=$seconds;sevenInFirstCheck=$fc;gpuOnTime=$gpu;processorSeconds=$cpu;created=$records.Count;records=$records})|ConvertTo-Json -Compress -Depth 5))
            $p.Kill();$p.WaitForExit()
            $null=Wait-Until {@((Core 'policy-status').state.instances|Where-Object {$_.process.processId -eq $p.Id -and $_.status -notin @('restored','expired')}).Count -eq 0} 30
        }
    } finally {foreach($l in $loaders){try{$l.Kill();$l.WaitForExit()}catch{}}}
    Write-Output ('SCORE failing '+$failing+' of 20')
    if($failing -gt 0){throw ('SCORE '+$failing+' of 20 launches failed a timing check')}
    return
