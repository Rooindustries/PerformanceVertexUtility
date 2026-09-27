param(
    [Parameter(Mandatory=$true)][string]$RepoRoot,
    [Parameter(Mandatory=$true)][string]$ArtifactDir
)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
New-Item -ItemType Directory -Force $ArtifactDir | Out-Null
$scripts=Join-Path $RepoRoot 'backend\scripts'
$folder=Join-Path $env:ProgramFiles '7-Zip'
$result=[ordered]@{startedAtUtc=(Get-Date).ToUniversalTime().ToString('o');machine=$env:COMPUTERNAME;status='failed'}
function Get-SevenZipEntries {
    $entries=@()
    foreach($source in @(@{hive='LocalMachine';view='Registry64'},@{hive='LocalMachine';view='Registry32'},@{hive='CurrentUser';view='Registry64'})){
        $base=[Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]$source.hive,[Microsoft.Win32.RegistryView]$source.view)
        try {
            $uninstall=$base.OpenSubKey('Software\Microsoft\Windows\CurrentVersion\Uninstall')
            if($null -eq $uninstall){continue}
            try {
                foreach($name in $uninstall.GetSubKeyNames()){
                    $key=$uninstall.OpenSubKey($name)
                    try {if([string]$key.GetValue('DisplayName') -like '7-Zip*'){$entries+=[pscustomobject]@{hive=$source.hive;view=$source.view;key=$name;displayName=[string]$key.GetValue('DisplayName');windowsInstaller=$key.GetValue('WindowsInstaller')}}}
                    finally {$key.Dispose()}
                }
            } finally {$uninstall.Dispose()}
        } finally {$base.Dispose()}
    }
    return @($entries|Sort-Object key -Unique)
}
function Save-Result {($result|ConvertTo-Json -Depth 12)|Set-Content -LiteralPath (Join-Path $ArtifactDir 'real-msi-removal.json') -Encoding UTF8}
$installedByCheck=$false
try {
    $existing=@(Get-SevenZipEntries)
    if($existing.Count -gt 0 -or (Test-Path -LiteralPath $folder)){$result.status='skipped-existing-install';$result.existing=$existing;return}
    $winget=(Get-Command winget -ErrorAction Stop).Source
    $ErrorActionPreference='Continue'
    $install=& $winget install --id 7zip.7zip -e --silent --accept-source-agreements --accept-package-agreements 2>&1
    $result.wingetInstallExitCode=$LASTEXITCODE
    $ErrorActionPreference='Stop'
    $installed=@(Get-SevenZipEntries)
    $installedByCheck=$installed.Count -gt 0
    $result.installed=[ordered]@{entries=$installed;folderExists=(Test-Path -LiteralPath $folder)}
    if($installed.Count -ne 1 -or $installed[0].windowsInstaller -ne 1 -or -not $result.installed.folderExists){throw ('7-Zip did not install as one MSI registration: '+(@($install)-join ' '))}
    $inventory=(& (Join-Path $scripts 'Get-InstalledAppInventory.ps1'))|ConvertFrom-Json
    $apps=@($inventory.apps|Where-Object {$_.sourceType -eq 'msi' -and $_.packageId -ieq $installed[0].key})
    if($apps.Count -ne 1){throw 'The product inventory did not return exactly one MSI record for 7-Zip.'}
    $result.appId=$apps[0].appId
    $planPath=Join-Path $ArtifactDir 'plan.json';$journalPath=Join-Path $ArtifactDir 'journal.json'
    $plan=((& (Join-Path $scripts 'New-BulkUninstallPlan.ps1') -AppId @($apps[0].appId) -Quiet -OutputPath $planPath) -join "`n")|ConvertFrom-Json
    if($plan.status -ne 'preview'){throw ('Plan failed: '+($plan.errors|ConvertTo-Json -Compress))}
    $result.reviewedCommandLine=$plan.data.entries[0].commandLine
    $start=[Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME 'powershell.exe'))
    $start.Arguments='-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+(Join-Path $scripts 'Invoke-BulkUninstall.ps1')+'" -Action Apply -InputPath "'+$planPath+'" -ReviewSha256 '+(Get-FileHash -LiteralPath $planPath).Hash+' -JournalPath "'+$journalPath+'" -TimeoutSeconds 600 -ConfirmApply -ManualReviewApproved'
    $start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardInput=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
    $apply=[Diagnostics.Process]::Start($start);$apply.StandardInput.Close()
    $stdoutTask=$apply.StandardOutput.ReadToEndAsync();$stderrTask=$apply.StandardError.ReadToEndAsync()
    $observed=@();$applyDeadline=(Get-Date).AddMinutes(12)
    while(-not $apply.HasExited){
        if((Get-Date) -gt $applyDeadline){$apply.Kill();throw 'The removal queue did not finish within 12 minutes.'}
        $observed+=@(Get-CimInstance Win32_Process -Filter "Name='msiexec.exe'"|Where-Object {$_.ParentProcessId -eq $apply.Id}|ForEach-Object {$_.CommandLine})
        Start-Sleep -Milliseconds 200
    }
    $observed=@($observed|Select-Object -Unique)
    $result.executedCommandLines=$observed
    $result.executedMatchesReview=($observed.Count -eq 1 -and $observed[0] -ceq $result.reviewedCommandLine)
    $stdoutTask.Result|Set-Content -LiteralPath (Join-Path $ArtifactDir 'apply.stdout.json') -Encoding UTF8
    $result.applyStderr=$stderrTask.Result
    $run=$stdoutTask.Result|ConvertFrom-Json
    $result.run=[ordered]@{status=$run.status;entry=($run.data.entries[0]|Select-Object state,registrationAbsent,outcome,error,invocation)}
    $after=@(Get-SevenZipEntries)
    $result.after=[ordered]@{entries=$after;folderExists=(Test-Path -LiteralPath $folder)}
    $result.status=if($result.executedMatchesReview -and $run.status -eq 'cleanup-review-required' -and $run.data.entries[0].state -eq 'removed' -and $after.Count -eq 0 -and -not $result.after.folderExists){'passed'}else{'failed'}
} catch {
    $result.error=$_.Exception.Message
} finally {
    if($installedByCheck -and @(Get-SevenZipEntries).Count -gt 0){
        $ErrorActionPreference='Continue'
        & (Get-Command winget).Source uninstall --id 7zip.7zip -e --silent --disable-interactivity 2>&1|Out-Null
        $result.fallbackCleanup=[ordered]@{entries=@(Get-SevenZipEntries);folderExists=(Test-Path -LiteralPath $folder)}
    }
    $result.completedAtUtc=(Get-Date).ToUniversalTime().ToString('o')
    Save-Result
}
