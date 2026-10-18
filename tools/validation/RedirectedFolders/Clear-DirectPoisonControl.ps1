param([string]$Scratch,[Parameter(Mandatory)][string]$ExpectedMachine)
$ErrorActionPreference='Stop'
if($env:COMPUTERNAME -ne $ExpectedMachine -or -not(Test-Path -LiteralPath (Join-Path $Scratch 'fixture-owner.txt'))){throw 'Not our fixture'}
$before=Get-Content -LiteralPath (Join-Path $Scratch 'live-before.json') -Raw|ConvertFrom-Json
if($before.'missing-poison-exists' -ne 'False'){throw 'Poison control path existed before this test'}
$root='C:\RooIndustriesF10Missing'
$files=@(Get-ChildItem -LiteralPath $root -Force -Recurse -File -ErrorAction SilentlyContinue)
$expected=$root+'\profile\AppData\Local\Microsoft\Windows\PowerShell\StartupProfileData-NonInteractive'
if(@($files|Where-Object {$_.FullName -ine $expected}).Count){throw 'Unexpected file in direct control; retaining it'}
$files|ForEach-Object {@{path=$_.FullName;length=$_.Length;sha256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash}}|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $Scratch 'direct-poison-startup.json') -Encoding UTF8
foreach($file in $files){[IO.File]::Delete($file.FullName)}
foreach($directory in @(Get-ChildItem -LiteralPath $root -Force -Recurse -Directory -ErrorAction SilentlyContinue|Sort-Object {$_.FullName.Length} -Descending)){[IO.Directory]::Delete($directory.FullName,$false)}
if(Test-Path -LiteralPath $root){[IO.Directory]::Delete($root,$false)}
if(Test-Path -LiteralPath $root){throw 'Direct control remains'}
'PASS direct PowerShell control cache removed; no unexpected file found'
