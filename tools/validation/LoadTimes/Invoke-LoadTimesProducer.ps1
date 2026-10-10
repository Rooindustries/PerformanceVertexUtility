param([Parameter(Mandatory)][string]$RequestPath,[int]$Minutes=45)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'CleanupOwnership.Common.ps1')
. (Join-Path $PSScriptRoot 'LoadTimesHandoff.Common.ps1')
$request=Read-HandoffJson $RequestPath;$r=$request.value
$context=New-HandoffContext (Split-Path $r.outDir -Parent) $r.leasePath
if($context.leaseHash -cne $r.leaseHash -or $r.scenario -cnotin 'migration-before','migration-timer-on' -or $r.outDir -cne (Join-Path $context.root $r.scenario) -or (Get-FileHash -LiteralPath $r.scriptPath -Algorithm SHA256).Hash -cne $r.scriptHash){throw 'Producer request differs from protected installed epoch'}
Assert-HandoffProtected $r.scriptPath
$p=$null;$owned=$null;$exit=1;$status='failed';$started=[DateTime]::UtcNow.ToString('o')
try{
    $literal="'"+$RequestPath.Replace("'","''")+"'"
    $command='$ErrorActionPreference=''Stop'';try{$request=Get-Content -Raw -LiteralPath '+$literal+'|ConvertFrom-Json;$args=@{};foreach($property in $request.arguments.PSObject.Properties){$args[$property.Name]=$property.Value};& $request.scriptPath @args;if(-not$?){exit 1};exit 0}catch{$_|Out-String|Write-Output;exit 1}'
    $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $psi=[Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME 'powershell.exe'),('-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand '+$encoded));$psi.UseShellExecute=$false;$psi.CreateNoWindow=$true;$psi.WorkingDirectory=$r.outDir;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true
    foreach($name in @($psi.EnvironmentVariables.Keys)){if($name -match '^(DOTNET_|COMPlus_|CORECLR_|COR_|COREHOST_)'){$psi.EnvironmentVariables.Remove($name)}}
    $p=[Diagnostics.Process]::Start($psi);$handle=$p.Handle
    $identity=[pscustomobject][ordered]@{pid=$p.Id;creationTimeFileTimeUtc=[RooValidationOwnership.Native]::Created($handle).ToString();imagePath=[RooValidationOwnership.Native]::Image($handle)}
    $owned=[pscustomobject]@{process=$p;handle=$handle;Identity=$identity}
    Save-HandoffJson (Join-Path $r.outDir 'producer-child.json') $identity -Create
    $stdout=$p.StandardOutput.ReadToEndAsync();$stderr=$p.StandardError.ReadToEndAsync()
    if(-not$p.WaitForExit($Minutes*60000)){Stop-OwnedProcess $owned;throw 'Own producer child timeout; resources retained for recovery'}
    $p.WaitForExit();$exit=$p.ExitCode
    [IO.File]::WriteAllText((Join-Path $r.outDir 'producer-native.log'),$stdout.Result+"`n"+$stderr.Result,[Text.UTF8Encoding]::new($false))
    if($exit -ne 0){throw 'Producer child failed'}
    if(-not(Test-Path -LiteralPath (Join-Path $r.outDir ($r.scenario+'.done')))){throw 'Producer child did not publish done'}
    $log=[IO.File]::ReadAllText((Join-Path $r.outDir ($r.scenario+'.log')))
    if($log -notmatch '(?m)^\S+ RESULT failures=0\s*$' -or $log -match '(?m)^\S+ (FAIL|FATAL|ERROR)\b|CLEANUP NEEDED'){throw 'Producer checks or cleanup failed'}
    $resources=Read-HandoffJson (Join-Path $r.outDir 'persistent-resources.json')
    $child=Read-HandoffJson (Join-Path $r.outDir 'producer-child.json')
    $status='completed'
    Save-HandoffJson (Join-Path $r.outDir 'completed-child.json') ([ordered]@{protocol='roo-loadtimes-completed/v1';scenario=$r.scenario;status=$status;exit=$exit;identity=$identity;requestHash=$request.hash;childHash=$child.hash;resourcesHash=$resources.hash;startedUtc=$started;completedUtc=[DateTime]::UtcNow.ToString('o')}) -Create
}catch{
    $_|Out-String|Set-Content -LiteralPath (Join-Path $r.outDir 'producer-error.log')
    $exit=1
}finally{if($owned -and -not$p.HasExited){Stop-OwnedProcess $owned};if($p){$p.Dispose()}}
exit $exit
