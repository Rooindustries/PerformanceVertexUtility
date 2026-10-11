function Assert-ShippedFreshApp($Process,[DateTime]$After){
 if($Process.StartTime.ToUniversalTime() -lt $After){throw 'App instance predates this owned launch; retained.'}
}
function Assert-ShippedNoApp([string]$Image){
 $found=@(Get-CimInstance Win32_Process|Where-Object {$_.ExecutablePath -ieq $Image})
 if($found.Count){throw 'An app instance is already running that this run did not start; retained.'}
}
function Get-ShippedFixture([string]$Path,[DateTime]$After){
 $matches=@(Get-CimInstance Win32_Process|Where-Object {$_.ExecutablePath -ieq $Path})
 if($matches.Count -ne 1){throw 'Saved-rule fixture identity is ambiguous or missing; retained.'}
 $match=$matches[0]
 if($match.CreationDate.ToUniversalTime() -lt $After){throw 'Saved-rule fixture predates the Explorer launch; retained.'}
 $parent=Get-CimInstance Win32_Process -Filter ('ProcessId='+$match.ParentProcessId)
 if(-not$parent -or [IO.Path]::GetFileName($parent.ExecutablePath) -ine 'explorer.exe' -or $parent.CreationDate -gt $match.CreationDate){throw 'Fixture was not launched by desktop Explorer.'}
 return $match
}
function Move-ShippedFreshData([string]$ActiveRoot,$Before,[string]$Destination){
 $root=@($Before.dataRoots|Where-Object {$_.path -ieq $ActiveRoot})
 if($root.Count -ne 1 -or $root[0].exists){throw 'The active data root was present before this run or is unknown; retained.'}
 for($folder=$ActiveRoot;$folder;$folder=[IO.Path]::GetDirectoryName($folder)){
  if((Get-Item -LiteralPath $folder -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Linked data ancestry retained.'}
 }
 if(@(Get-ChildItem -LiteralPath $ActiveRoot -Recurse -Force|Where-Object {$_.Attributes -band [IO.FileAttributes]::ReparsePoint}).Count){throw 'Data includes a reparse point; retained.'}
 [IO.Directory]::Move($ActiveRoot,$Destination)
}
function New-ShippedFirewall([string]$Name,[string]$Nonce,[string]$Image){
 if(Get-NetFirewallRule -Name $Name -ErrorAction SilentlyContinue){throw 'Offline rule already exists; retained.'}
 New-NetFirewallRule -Name $Name -DisplayName $Name -Description $Nonce -Direction Outbound -Action Block -Program $Image -Enabled True|Out-Null
}
function Remove-ShippedFirewall([string]$Name,[string]$Nonce,[bool]$Created){
 if(-not$Created){return}
 $rule=Get-NetFirewallRule -Name $Name -ErrorAction SilentlyContinue
 if(-not$rule){return}
 if($rule.Description -cne $Nonce){throw 'Firewall ownership changed; retained.'}
 $rule|Remove-NetFirewallRule
 if(Get-NetFirewallRule -Name $Name -ErrorAction SilentlyContinue){throw 'Owned firewall rule remains.'}
}
function Get-ShippedLogCursor([string]$Path){
 $text=if(Test-Path $Path){[IO.File]::ReadAllText($Path)}else{''}
 return @{path=$Path;prefix=$text;length=$text.Length}
}
function Read-ShippedLog($Cursor){
 $text=if(Test-Path $Cursor.path){[IO.File]::ReadAllText($Cursor.path)}else{''}
 if($text.Length -ge $Cursor.length -and $text.StartsWith($Cursor.prefix,[StringComparison]::Ordinal)){return $text.Substring($Cursor.length)}
 $old=if(Test-Path ($Cursor.path+'.old')){[IO.File]::ReadAllText($Cursor.path+'.old')}else{''}
 if($Cursor.length -and -not$old.StartsWith($Cursor.prefix,[StringComparison]::Ordinal)){throw 'App-log history rotated more than once; keep evidence and rerun in a fresh window.'}
 return $old.Substring($Cursor.length)+$text
}

function Test-ShippedGovernorReplacement($Before,$After){
 return $Before -and $After -and $After.pid -ne $Before.pid -and $After.creationTimeUtc -ne $Before.creationTimeUtc
}
function Get-ShippedFinalStatus([string]$Status,$CleanupErrors){
 if(@($CleanupErrors).Count){return 'fail'}
 return $Status
}
