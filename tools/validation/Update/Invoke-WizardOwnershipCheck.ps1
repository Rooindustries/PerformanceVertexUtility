param([Parameter(Mandatory)][string]$Source,[Parameter(Mandatory)][string]$OutRoot,[Parameter(Mandatory)][string]$Installer,[Parameter(Mandatory)][string]$ReleasePath,[Parameter(Mandatory)][string]$FrameId)
$ErrorActionPreference='Stop'
. (Join-Path $Source 'tools\validation\Update\Invoke-ShippedScenario.ps1') -Source $Source -OutRoot $OutRoot -Part p2 -ReleasePath $ReleasePath -FrameId $FrameId -HarnessOnly
try{
 Wizard $Installer 'ownership' $release.payload.version
 $script:receiptStatus='pass'
}catch{
 Save 'failure.json' @{error=$_.Exception.Message;stack=$_.ScriptStackTrace;position=$_.InvocationInfo.PositionMessage;owned=@($script:ownedHandles.Values|ForEach-Object {@{identity=$_.Identity;hasProcess=[bool]$_.process;hasHandle=[bool]$_.handle;fields=@($_.PSObject.Properties.Name)}})}
 $script:receiptStatus='fail';throw
}finally{
 foreach($entry in @($script:extraProcesses)+@($script:setupReceipts)){Stop-HarnessProcess $entry}
 $script:receiptStatus=Complete-HarnessInvocation $script:receiptStatus -Cleanup
 Receipt
}
