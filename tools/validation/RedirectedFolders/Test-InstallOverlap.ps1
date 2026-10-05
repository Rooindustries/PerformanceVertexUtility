param([string]$Repo,[string]$Scratch,[string]$Phase='overlap')
$ErrorActionPreference='Stop'
[Reflection.Assembly]::LoadFrom((Join-Path $Scratch 'FolderFixture.dll'))|Out-Null
[FolderFixture]::Begin($Scratch,'install-root','core');$folders=[FolderFixture]::Folders;[FolderFixture]::End()
$scripts=Join-Path $folders 'custom-install\backend\scripts';[IO.Directory]::CreateDirectory($scripts)|Out-Null
Copy-Item -LiteralPath (Join-Path $Repo 'backend\scripts\BrandCompatibility.Common.ps1') -Destination $scripts -Force
$dotnet=Join-Path ([Environment]::GetFolderPath('UserProfile')) '.dotnet\dotnet.exe'
$rows=@()
foreach($case in @('install-root','short-system')){
foreach($suffix in @('backend\bin\optimizer','backend\bin\optimizer\session','app')){
$layout=Join-Path $folders ('custom-install\'+$suffix);[IO.Directory]::CreateDirectory($layout)|Out-Null
Copy-Item -Path (Join-Path $Repo 'tools\validation\RedirectedFolders\bin\Debug\net8.0-windows\*') -Destination $layout -Force
$out=& $dotnet (Join-Path $layout 'RedirectedFolders.dll') $Scratch $case
$row=$out|ConvertFrom-Json;$row|Add-Member -NotePropertyName layout -NotePropertyValue $suffix;$rows+=$row
}
$out=& (Join-Path $PSHOME 'powershell.exe') -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $Repo 'tools\validation\RedirectedFolders\Invoke-RedirectedFolderChild.ps1') -Scratch $Scratch -Scenario $case -Common (Join-Path $scripts 'BrandCompatibility.Common.ps1') -Fixture (Join-Path $Scratch 'FolderFixture.dll')
$rows+=($out|ConvertFrom-Json)
}
$rows|ForEach-Object {$_|ConvertTo-Json -Compress}|Set-Content -LiteralPath (Join-Path $Scratch ($Phase+'.jsonl')) -Encoding UTF8
'RESULT '+$Phase+' passed='+@($rows|Where-Object passed).Count+'/'+$rows.Count
exit [int](@($rows|Where-Object {-not $_.passed}).Count -gt 0)
