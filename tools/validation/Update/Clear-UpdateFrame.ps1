param([Parameter(Mandatory)][string]$Frame,[string]$ExpectedMachine=$env:ROO_TEST_COMPUTER)
$ErrorActionPreference='Stop'
if([string]::IsNullOrWhiteSpace($ExpectedMachine)){throw 'ExpectedMachine is required; pass -ExpectedMachine or set ROO_TEST_COMPUTER.'}
if($env:COMPUTERNAME -cne $ExpectedMachine){throw 'Wrong cleanup machine'}
$root=[IO.Path]::GetFullPath($Frame).TrimEnd('\')
if($root -cnotmatch '^C:\\RooBuild\\roo-industries-roo20-ota(?:-ui)?-[a-f0-9]{32}$'){throw 'Update frame scope differs'}
if(-not[IO.Directory]::Exists($root)){return}
if(@(Get-CimInstance Win32_Process|Where-Object {$_.ExecutablePath -and $_.ExecutablePath.StartsWith($root+'\',[StringComparison]::OrdinalIgnoreCase)}).Count){throw 'Update frame still has running processes; retained'}
$queue=[Collections.Generic.Stack[string]]::new();$queue.Push('\\?\'+$root)
$folders=[Collections.Generic.List[string]]::new();$files=[Collections.Generic.List[string]]::new()
while($queue.Count){
 $folder=$queue.Pop();$folders.Add($folder)
 foreach($entry in [IO.Directory]::EnumerateFileSystemEntries($folder)){
  $attributes=[IO.File]::GetAttributes($entry)
  if($attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Linked update frame entry retained'}
  if($attributes -band [IO.FileAttributes]::Directory){$queue.Push($entry)}else{$files.Add($entry)}
 }
}
foreach($file in $files){$attributes=[IO.File]::GetAttributes($file);if($attributes -band [IO.FileAttributes]::ReadOnly){[IO.File]::SetAttributes($file,($attributes -band (-bnot [IO.FileAttributes]::ReadOnly)))};[IO.File]::Delete($file)}
foreach($folder in @($folders|Sort-Object Length -Descending)){[IO.Directory]::Delete($folder,$false)}
@{frame=$root;absent=(-not[IO.Directory]::Exists($root));files=$files.Count;folders=$folders.Count}|ConvertTo-Json -Compress
