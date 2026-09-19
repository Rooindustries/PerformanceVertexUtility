$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'BrandCompatibility.Common.ps1')
$script:fixtureTasks=@()
function Get-ScheduledTask {
    [CmdletBinding()]param([string[]]$TaskName)
    return @($script:fixtureTasks|Where-Object{$_.TaskName -in $TaskName})
}
$current='Roo Industries Protected Session fixture'
$legacy='Roo Protected Session fixture'
$description='Roo Industries protected game session | owner | root'
$oldDescription='Roo protected game session | owner | root'
function Check([bool]$Passed,[string]$Message){if(-not $Passed){throw $Message};Write-Output ('PASS '+$Message)}
Check ($null -eq (Find-RooIndustriesCompatibleTask $current $legacy $description $oldDescription)) 'Missing worker registrations do not invent a session'
$script:fixtureTasks=@([pscustomobject]@{TaskName=$current;Description=$description})
Check ((Find-RooIndustriesCompatibleTask $current $legacy $description $oldDescription).TaskName -ceq $current) 'The current worker name is recognized'
$script:fixtureTasks=@([pscustomobject]@{TaskName=$legacy;Description=$oldDescription})
Check ((Find-RooIndustriesCompatibleTask $current $legacy $description $oldDescription).TaskName -ceq $legacy) 'Legacy worker registrations remain addressable'
$script:fixtureTasks[0].Description='another owner or folder'
$rejected=$false;try{Find-RooIndustriesCompatibleTask $current $legacy $description $oldDescription|Out-Null}catch{$rejected=$true}
Check $rejected 'A matching legacy name does not authorize a different owner or state folder'
$script:fixtureTasks=@([pscustomobject]@{TaskName=$legacy;Description=$oldDescription},[pscustomobject]@{TaskName=$current;Description=$description})
$rejected=$false;try{Find-RooIndustriesCompatibleTask $current $legacy $description $oldDescription|Out-Null}catch{$rejected=$true}
Check $rejected 'Ambiguous old and new registrations cannot silently select a worker'
