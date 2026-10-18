param([Parameter(Mandatory)][string]$Runner,[Parameter(Mandatory)][string]$Evidence,[string]$ExpectedMachine='CS2-GEN4')
$ErrorActionPreference='Stop'
if($env:COMPUTERNAME -cne $ExpectedMachine){throw 'Wrong fixture computer'}
if(Test-Path -LiteralPath $Evidence){throw 'Retain prior evidence and use a new path'}
[IO.Directory]::CreateDirectory($Evidence)|Out-Null
$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($Runner,[ref]$tokens,[ref]$errors)
if($errors.Count){throw ($errors|Out-String)}
$names=@('Log','Check','Get-DataFolderState','Run')
$functions=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -in $names},$false))
if($functions.Count -ne $names.Count){throw 'Exact runner guard functions are missing'}
foreach($function in $functions){. ([scriptblock]::Create($function.Extent.Text))}
$fixture=Join-Path $Evidence ('private-'+[Guid]::NewGuid().ToString('N'));[IO.Directory]::CreateDirectory($fixture)|Out-Null
$local=$fixture;$markerKey='HKEY_CURRENT_USER\Software\RooIndustriesGuardEvidence-'+[Guid]::NewGuid().ToString('N');$Phase='guard-fixture';$log=Join-Path $Evidence 'guard-fixture.log';$script:Failures=0
$root=Join-Path $fixture 'RooIndustriesOptimizationSuite';[IO.Directory]::CreateDirectory($root)|Out-Null
$path=Join-Path $root 'harmless.txt';[IO.File]::WriteAllText($path,'baseline');$write=(Get-Item -LiteralPath $path).LastWriteTimeUtc
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
namespace RooIndustriesGuardEvidence {
 public static class Native {
  [DllImport("kernel32.dll",EntryPoint="CreateFileW",CharSet=CharSet.Unicode,SetLastError=true)]
  static extern SafeFileHandle Open(string path,uint access,uint share,IntPtr security,uint creation,uint flags,IntPtr template);
  public static SafeFileHandle Hold(string path) { return Open(path,0,7,IntPtr.Zero,3,0x02200000,IntPtr.Zero); }
 }
}
'@
$heldDirectory=Join-Path $root 'held-directory';[IO.Directory]::CreateDirectory($heldDirectory)|Out-Null
[IO.Directory]::SetLastWriteTimeUtc($heldDirectory,[DateTime]::UtcNow.AddMinutes(-5))
$held=[RooIndustriesGuardEvidence.Native]::Hold($heldDirectory)
if($held.IsInvalid){$held.Dispose();throw 'Private directory could not be held open'}
$originalHash=(Get-FileHash -LiteralPath $path).Hash;$results=[Collections.Generic.List[object]]::new();$failure=$null;$removed=$false
try {
    Run 'unchanged' {Write-Output 'PASS the private fixture suite ran'} -GuardData
    if($script:Failures -ne 0){throw 'Unchanged private fixture guard failed'}
    Run 'planted-same-size' {[IO.File]::WriteAllText($path,'changed!');(Get-Item -LiteralPath $path).LastWriteTimeUtc=$write;Write-Output 'PASS the harmless private change was planted'} -GuardData
    if($script:Failures -ne 1){throw 'A content-only private delta did not cause exactly one guard failure'}
    $beforeFiles=@(Get-ChildItem -LiteralPath $Evidence -Filter '*-before.json');$afterFiles=@(Get-ChildItem -LiteralPath $Evidence -Filter '*-after.json');$diffFiles=@(Get-ChildItem -LiteralPath $Evidence -Filter '*-diff.json')
    if($beforeFiles.Count -ne 2 -or $afterFiles.Count -ne 2 -or $diffFiles.Count -ne 1){throw 'Guard did not retain both snapshots and the exact failing diff'}
    $parsedDiff=Get-Content -Raw -LiteralPath $diffFiles[0].FullName|ConvertFrom-Json;$diff=@($parsedDiff)
    if($diff.Count -ne 2 -or @($diff|Where-Object {$_.row.root -cne 'RooIndustriesOptimizationSuite' -or $_.row.relative -cne '\harmless.txt' -or $_.row.kind -cne 'file' -or $_.row.size -ne 8 -or $_.row.lastWriteFileTimeUtc -cne $write.ToFileTimeUtc().ToString()}).Count){throw 'Named diff rows do not match the planted exact path, kind, size and unchanged FILETIME'}
    $before=@($diff|Where-Object side -ceq 'before');$after=@($diff|Where-Object side -ceq 'after')
    if($before.Count -ne 1 -or $after.Count -ne 1 -or $before[0].row.sha256 -cne $originalHash -or $after[0].row.sha256 -cne (Get-FileHash -LiteralPath $path).Hash -or $before[0].row.sha256 -ceq $after[0].row.sha256){throw 'Diff content hashes do not identify the exact private mutation'}
    $line=@(Get-Content -LiteralPath $log|Where-Object {$_ -match ' FAIL .*left the real data folders'})
    if($line.Count -ne 1 -or $line[0] -notmatch 'harmless' -or $line[0] -notmatch [regex]::Escape($originalHash) -or $line[0] -notmatch [regex]::Escape($after[0].row.sha256)){throw 'The FAIL evidence line omitted the exact differing row/hash'}
    $results.Add(@{name='unchanged fixture suite passes strict guard';passed=$true})
    $results.Add(@{name='same-size content delta with restored FILETIME remains FAIL and names both rows';passed=$true;diff=$diff})
    $temporary=Join-Path $heldDirectory 'created-then-deleted.txt'
    Run 'planted-created-deleted-held' {[IO.File]::WriteAllText($temporary,'private transient entry');[IO.File]::Delete($temporary);Write-Output 'PASS the private entry was created and deleted while its directory stayed open'} -GuardData
    if($script:Failures -ne 2 -or [IO.File]::Exists($temporary) -or $held.IsClosed){throw 'A transient entry in a held private directory did not cause exactly one additional guard failure'}
    $transientFiles=@(Get-ChildItem -LiteralPath $Evidence -Filter '*planted-created-deleted-held*-diff.json')
    if($transientFiles.Count -ne 1){throw 'The transient directory delta lacks an exact diff'}
    $parsedTransient=Get-Content -Raw -LiteralPath $transientFiles[0].FullName|ConvertFrom-Json;$transient=@($parsedTransient)
    if($transient.Count -ne 2 -or @($transient|Where-Object {$_.row.root -cne 'RooIndustriesOptimizationSuite' -or $_.row.relative -cne '\held-directory' -or $_.row.kind -cne 'directory' -or $_.row.size -ne 0 -or $_.row.sha256 -cne ''}).Count){throw 'Transient diff does not name only the exact held directory'}
    $transientBefore=@($transient|Where-Object side -CEQ 'before');$transientAfter=@($transient|Where-Object side -CEQ 'after')
    if($transientBefore.Count -ne 1 -or $transientAfter.Count -ne 1 -or [long]$transientAfter[0].row.lastWriteFileTimeUtc -le [long]$transientBefore[0].row.lastWriteFileTimeUtc){throw 'The fresh directory timestamp did not change after the transient entry'}
    foreach($row in $transient.row){$ticks=[DateTime]::FromFileTimeUtc([long]$row.lastWriteFileTimeUtc).Ticks;if($row.hashInput -cne ('\held-directory|dir|'+$ticks)){throw 'Directory row and aggregate hash input disagree on the fresh timestamp'}}
    if(@(Get-ChildItem -LiteralPath $Evidence -Filter '*-before.json').Count -ne 3 -or @(Get-ChildItem -LiteralPath $Evidence -Filter '*-after.json').Count -ne 3 -or @(Get-ChildItem -LiteralPath $Evidence -Filter '*-diff.json').Count -ne 2){throw 'The three guards did not retain their exact evidence'}
    $results.Add(@{name='created then deleted entry in a held directory remains FAIL and names both directory timestamps';passed=$true;diff=$transient})
} catch {$failure=$_}
finally {
    $held.Dispose()
    $unknown=@(Get-ChildItem -LiteralPath $fixture -File -Recurse -Force|Where-Object {$_.FullName -cne $path})
    if($unknown.Count -or @(Get-ChildItem -LiteralPath $fixture -Recurse -Force|Where-Object {$_.Attributes -band [IO.FileAttributes]::ReparsePoint}).Count){$failure='Unknown fixture resources retained'}else{Remove-Item -LiteralPath $fixture -Recurse -Force;$removed=-not(Test-Path -LiteralPath $fixture)}
    @{machine=$env:COMPUTERNAME;runner=$Runner;runnerSha256=(Get-FileHash -LiteralPath $Runner).Hash;realRootsRead=$false;registryWritten=$false;privateFixture=$fixture;fixtureRemoved=$removed;expectedGuardFailures=2;actualGuardFailures=$script:Failures;checks=@($results);passed=(-not$failure -and $removed);error=[string]$failure}|ConvertTo-Json -Depth 12|Set-Content -LiteralPath (Join-Path $Evidence 'result.json') -Encoding UTF8
}
if($failure){throw $failure}
Write-Output 'PASS strict guard names private content and transient directory changes and leaves no fixture leftovers'
