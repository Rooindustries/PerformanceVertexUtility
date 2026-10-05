param([Parameter(Mandatory=$true)][string]$Frame,[Parameter(Mandatory=$true)][string]$Runner)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'HistoricalBlackwell.Common.ps1')
Initialize-HistoricalBlackwell $Frame $Runner
$sw=[Diagnostics.Stopwatch]::StartNew()
function Stamp([string]$Stage){Write-Output ($Stage+' '+$sw.ElapsedMilliseconds+' ms '+(Get-Process -Id $PID).WorkingSet64+' bytes')}
function HashBytes([byte[]]$bytes){$sha=[Security.Cryptography.SHA256]::Create();try{[BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-','')}finally{$sha.Dispose()}}
$rows=[Collections.Generic.List[object]]::new()
foreach($path in 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\RooIndustriesOptimizationSuite','Registry::HKEY_LOCAL_MACHINE\SOFTWARE\RooIndustries'){
    Stamp 'before-provider-keys'
    $k=Get-Item -LiteralPath $path
    $nodes=@($k)+@(Get-ChildItem -LiteralPath $path -Recurse)
    Stamp ('after-provider-keys '+$nodes.Count)
    foreach($r in $nodes){
        $values=[Collections.Generic.List[object]]::new()
        foreach($name in @($r.GetValueNames()|Sort-Object)){
            $v=$r.GetValue($name,$null,'DoNotExpandEnvironmentNames')
            [byte[]]$bytes=$null
            if($v -is [byte[]]){$bytes=$v}else{$bytes=[Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $v -Compress))}
            Stamp ('before-hash '+$r.Name+' '+$bytes.Length)
            $hash=HashBytes $bytes
            Stamp 'after-hash'
            $values.Add(@{nameSha256=(Hash-HistoricalText $name);kind=[string]$r.GetValueKind($name);bytes=$bytes.Length;sha256=$hash})
        }
        $rows.Add(@{key=$r.Name;values=$values.ToArray()})
    }
}
Stamp 'before-provider-summary-json'
$json=ConvertTo-Json -InputObject $rows.ToArray() -Depth 15
Stamp ('after-provider-summary-json '+$json.Length)
Save-HistoricalBinary (Join-Path $Frame 'provider-summary.json') ([Text.Encoding]::UTF8.GetBytes($json))
$provider=Get-Item -LiteralPath ('Registry::HKEY_LOCAL_MACHINE\SOFTWARE\RooIndustriesOptimizationSuite\Tweaks\'+[Security.Principal.WindowsIdentity]::GetCurrent().User.Value)
$v=$provider.GetValue('State',$null,'DoNotExpandEnvironmentNames')
Stamp 'before-if-expression-binary'
$bytes=if($v -is [byte[]]){$v}else{[Text.Encoding]::UTF8.GetBytes((@($v)-join "`n"))}
Stamp ('after-if-expression-binary '+$bytes.GetType().FullName)
$h=HashBytes $bytes
Stamp ('after-if-expression-hash '+$h)

$backupSource=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Temp\roo-industries-integration-evidence\backup'
$fp=Join-Path $backupSource 'RooIndustriesOptimizationSuite.fingerprint.txt'
$root=Join-Path $backupSource 'RooIndustriesOptimizationSuite'
$originalRows=@(Get-RecoveryRows $root)
$actual=@($originalRows|ForEach-Object {$_.relative+'|'+$(if($_.directory){'dir'}else{[string]$_.length})+'|'+[DateTime]::new([long]$_.write,[DateTimeKind]::Utc).ToString('o')+'|'+[string][IO.FileAttributes][int]$_.attributes+'|'+$_.sddl}|Sort-Object)
$providerExpected=@(Get-Content -LiteralPath $fp -Encoding UTF8)
$rawExpected=@([IO.File]::ReadAllLines($fp,[Text.Encoding]::UTF8))
$badDiff=@(Compare-Object $actual $providerExpected -CaseSensitive|Select-Object -First 3)
$safeDiff=@(Compare-Object $actual $rawExpected -CaseSensitive|Select-Object -First 3)
$proof=@{providerInputMembers=@($badDiff[0].InputObject.PSObject.Properties|ForEach-Object Name);rawInputMembers=@($safeDiff[0].InputObject.PSObject.Properties|ForEach-Object Name);providerGraphWouldBeSerialized=($badDiff[0].InputObject.PSObject.Properties.Name -contains 'PSProvider');rawHasProviderGraph=($safeDiff[0].InputObject.PSObject.Properties.Name -contains 'PSProvider');unsafeSerializationNotExecuted=$true}
Save-RecoveryJson (Join-Path $Frame 'metadata-summary-provider-proof.json') $proof
$proof|ConvertTo-Json -Depth 3
Stamp 'provider-metadata-diagnosis-completed'
