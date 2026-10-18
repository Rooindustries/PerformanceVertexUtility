param([Parameter(Mandatory=$true)][string]$Frame,[Parameter(Mandatory=$true)][string]$Repo,[Parameter(Mandatory=$true)][string]$Dotnet,[Parameter(Mandatory)][string]$ExpectedMachine,[Parameter(Mandatory)][string]$ExpectedUserSid)
$ErrorActionPreference='Stop'
$i=[Security.Principal.WindowsIdentity]::GetCurrent()
if($env:COMPUTERNAME -ine $ExpectedMachine -or $i.User.Value -cne $ExpectedUserSid -or -not[Security.Principal.WindowsPrincipal]::new($i).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'Native target identity differs'}
if($Frame -notmatch '^C:\\RooBuild\\roo-industries-fixture-cleanup-[a-f0-9]{32}$'){throw 'Fresh fixture frame required'}
$project=Join-Path $Repo 'tools\validation\ProtectedSessions\ProtectedSessions.csproj'
$out=Join-Path $Frame 'bin'
& $Dotnet build $project -c Release -o $out --nologo *> (Join-Path $Frame 'build.log')
if($LASTEXITCODE -ne 0){throw 'Fixture build failed; inspect build.log'}
Get-ChildItem $out -File|Get-FileHash -Algorithm SHA256|Select-Object Path,Hash|ConvertTo-Json|Set-Content (Join-Path $Frame 'binary-hashes.json')
& $Dotnet (Join-Path $out 'RooIndustriesLaunchPolicyProbe.dll') --fixture-cleanup-checks $Frame *> (Join-Path $Frame 'checks.log')
$code=$LASTEXITCODE
if($code -ne 0){Get-Content (Join-Path $Frame 'checks.log');throw ('Fixture cleanup E2E failed '+$code)}
$left=@(Get-CimInstance Win32_Process|Where-Object {$_.CommandLine -and $_.CommandLine.IndexOf($Frame,[StringComparison]::OrdinalIgnoreCase) -ge 0}|Select-Object ProcessId,CreationDate,ExecutablePath,CommandLine)
ConvertTo-Json -InputObject $left -Depth 6|Set-Content (Join-Path $Frame 'process-leftovers.json')
if($left.Count -ne 0){throw 'Fixture processes remain; exact receipts retained'}
Get-Content (Join-Path $Frame 'checks.log')
Get-Content (Join-Path $Frame 'cleanup-result.json')
