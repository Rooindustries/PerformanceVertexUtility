param([Parameter(Mandatory)][string]$Installer,[Parameter(Mandatory)][string]$Evidence,[Parameter(Mandatory)][ValidatePattern('\A[A-Fa-f0-9]{64}\z')][string]$ExpectedSha256,[string]$DotNetPath=$env:ROO_INDUSTRIES_DOTNET_EXE,[ValidateRange(1,45)][int]$Minutes=45)
$ErrorActionPreference='Stop'
if($env:COMPUTERNAME -cne 'CS2-GEN4'){throw 'Blackwell-only interactive check'}
if((Get-FileHash -LiteralPath $Installer).Hash -cne $ExpectedSha256.ToUpperInvariant()){throw 'Sealed new installer hash differs'}
if(Test-Path -LiteralPath $Evidence){throw 'Evidence exists; choose a new path'}
[IO.Directory]::CreateDirectory($Evidence)|Out-Null
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
. (Join-Path $root 'tools\validation\LoadTimes\CleanupOwnership.Common.ps1')
Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes,System.Drawing,System.Windows.Forms,System.Web.Extensions
Add-Type -Path (Join-Path $root 'tools\validation\Release\BlackwellHarness\NativeProbe.cs') -ReferencedAssemblies 'System.dll','System.Core.dll','System.Web.Extensions.dll'
Add-Type @'
using System;using System.Runtime.InteropServices;using System.Text;
public static class BlackwellReadmeDesktop {
 [DllImport("user32.dll",SetLastError=true)] static extern IntPtr OpenInputDesktop(uint flags,bool inherit,uint access);
 [DllImport("user32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool GetUserObjectInformation(IntPtr h,int index,StringBuilder value,int bytes,out int needed);
 [DllImport("user32.dll")] static extern bool CloseDesktop(IntPtr h);
 public static string Name(){var h=OpenInputDesktop(0,false,1);if(h==IntPtr.Zero)return "unavailable:"+Marshal.GetLastWin32Error();try{var b=new StringBuilder(256);int n;if(!GetUserObjectInformation(h,2,b,512,out n))return "unavailable:"+Marshal.GetLastWin32Error();return b.ToString();}finally{CloseDesktop(h);}}
}
'@
if(-not$DotNetPath){$DotNetPath=Join-Path ([Environment]::GetFolderPath('UserProfile')) '.dotnet\dotnet.exe'}
$fixture=Join-Path ([Environment]::GetFolderPath('UserProfile')) ('AppData\Local\Temp\roo-blackwell-readme-'+[Guid]::NewGuid().ToString('N'))
if(Test-Path -LiteralPath $fixture){throw 'Fixture already exists'}
[IO.Directory]::CreateDirectory($fixture)|Out-Null
$readLeases=[Collections.Generic.List[object]]::new();$owned=[Collections.Generic.List[object]]::new();$copies=[Collections.Generic.List[object]]::new();$rows=[Collections.Generic.List[object]]::new();$deadline=[DateTime]::UtcNow.AddMinutes($Minutes).AddSeconds(-30);$session=(Get-Process -Id $PID).SessionId;$failure=$null
$app='C:\Program Files\Roo Industries\Optimization Suite';$readme=Join-Path $app 'README-BETA.txt';$system=[Environment]::SystemDirectory
$result=[ordered]@{machine=$env:COMPUTERNAME;installer=$Installer;installerSha256=(Get-FileHash -LiteralPath $Installer).Hash;expectedInstallerSha256=$ExpectedSha256.ToUpperInvariant();maximumMinutes=$Minutes;cases=@();passed=$false;cleanupPassed=$false;error='';restore='Runner phases must restore this installed epoch after the check';fixture=$fixture;ownedFiles=@();ownedProcesses=@()}
function Save-Result {$result.cases=@($rows);$result|ConvertTo-Json -Depth 15|Set-Content -LiteralPath (Join-Path $Evidence 'interactive-readme.json') -Encoding UTF8}
function Button($Window,[string]$Pattern) {@($Window.FindAll([Windows.Automation.TreeScope]::Descendants,[Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ControlTypeProperty,[Windows.Automation.ControlType]::Button))|Where-Object {$_.Current.IsEnabled -and -not$_.Current.IsOffscreen -and $_.Current.Name -match $Pattern})|Select-Object -First 1}
function Invoke-Button($Button) {$Button.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()}
function Capture([string]$Label) {$bounds=[Windows.Forms.Screen]::PrimaryScreen.Bounds;$bitmap=[Drawing.Bitmap]::new($bounds.Width,$bounds.Height);$graphics=[Drawing.Graphics]::FromImage($bitmap);try{$graphics.CopyFromScreen($bounds.Location,[Drawing.Point]::Empty,$bounds.Size);$bitmap.Save((Join-Path $Evidence ($Label+'.png')),[Drawing.Imaging.ImageFormat]::Png)}finally{$graphics.Dispose();$bitmap.Dispose()}}
function Own($Process) {$receipt=New-OwnedProcess $Process;if($receipt){$owned.Add($receipt);$result.ownedProcesses=@($owned|ForEach-Object Identity);Save-Result};$receipt}
function Own-Copy($Receipt) {
    try{$identity=$Receipt.Identity;$copies.Add($identity);$result.ownedFiles=@($copies);Save-Result;return $identity}finally{$Receipt.Dispose()}
}
function Seal-Readable($Identity) {
    $acl=[Security.AccessControl.FileSecurity]::new();$acl.SetAccessRuleProtection($true,$false);$acl.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))
    foreach($sid in 'S-1-5-18','S-1-5-32-544'){$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sid),'FullControl','Allow'))}
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.WindowsIdentity]::GetCurrent().User,'ReadAndExecute','Allow'));Set-Acl -LiteralPath $Identity.path -AclObject $acl
    $readLeases.Add([IO.File]::Open($Identity.path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read))
}
try {
    Add-Type -AssemblyName System.Windows.Forms
    $compiler=Join-Path ([Environment]::GetFolderPath('Windows')) 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    & $compiler /nologo /target:winexe /platform:x64 /reference:System.Web.Extensions.dll /main:BlackwellReadmeLaunch ('/out:'+(Join-Path $fixture 'compiled-launcher.exe')) (Join-Path $PSScriptRoot 'BlackwellReadmeLaunch.cs') (Join-Path $root 'tools\validation\Release\BlackwellHarness\NativeProbe.cs') > (Join-Path $Evidence 'build-launcher.log') 2>&1
    if($LASTEXITCODE -ne 0){throw 'Normal-launcher build failed'}
    foreach($variant in 'already-elevated','normal-uac'){
        if([DateTime]::UtcNow -ge $deadline){throw 'Overall45-minute bound reached'}
        $started=[DateTime]::UtcNow;$caseDeadline=$started.AddMinutes(20);if($caseDeadline -gt $deadline){$caseDeadline=$deadline}
        $case=[ordered]@{name=$variant;startedUtc=$started.ToString('o');status='missing-proof';caller=$null;setupPid=$null;wizardProcess=$null;readmeChecked=$false;finishInvoked=$false;notepad=$null;notepadCommandLine=$null;steps=@();error=''}
        $steps=[Collections.Generic.List[object]]::new();$before=@(Get-Process -ErrorAction SilentlyContinue|ForEach-Object {$_.Id});$setup=$null;$launcher=$null;$dir=$null;$lastAction='';$lastActionUtc=[DateTime]::MinValue
        if($variant -ceq 'normal-uac'){
            $dir=Join-Path $fixture $variant;[IO.Directory]::CreateDirectory($dir)|Out-Null;$exe=Join-Path $dir 'IntegrityProbe.exe'
            $sealedInstaller=Join-Path $dir ([IO.Path]::GetFileName($Installer));$installerIdentity=Own-Copy (Copy-OwnedProbe $Installer $sealedInstaller)
            if($installerIdentity.hash -cne $ExpectedSha256.ToUpperInvariant()){throw 'Readable installer copy differs'}
            Seal-Readable $installerIdentity
            $exeIdentity=Own-Copy (Copy-OwnedProbe (Join-Path $fixture 'compiled-launcher.exe') $exe);Seal-Readable $exeIdentity
            $pathIdentity=Own-Copy (New-OwnedTextFile (Join-Path $dir 'installer-path.txt') $sealedInstaller);Seal-Readable $pathIdentity
            $shaIdentity=Own-Copy (New-OwnedTextFile (Join-Path $dir 'expected-sha256.txt') $ExpectedSha256.ToUpperInvariant());Seal-Readable $shaIdentity
            $metadata=Join-Path $Evidence 'normal-caller.json'
            & $DotNetPath (Join-Path $root 'tools\validation\Release\BlackwellHarness\bin\Release\net8.0-windows\BlackwellHarness.dll') direct $exe $metadata > (Join-Path $Evidence 'normal-caller.log') 2>&1
            if($LASTEXITCODE -ne 0){throw 'Normal caller did not prove Medium shell handoff'}
            $native=(Get-Content -Raw -LiteralPath $metadata|ConvertFrom-Json).probe;$case.caller=$native;$launcher=Get-Process -Id $native.pid -ErrorAction SilentlyContinue
            if($launcher){$ownedLauncher=Own $launcher;if($ownedLauncher -and ($ownedLauncher.Identity.creationTimeFileTimeUtc -cne $native.creationTimeFileTimeUtc -or $ownedLauncher.Identity.imagePath -ine [RooValidationOwnership.Native]::Canonical($exe))){throw 'Normal caller identity changed'}}
        }else{$setup=Start-Process -FilePath $Installer -PassThru;$null=Own $setup;$case.setupPid=$setup.Id;$case.caller=[BlackwellNativeProbe]::Inspect($PID)|ConvertFrom-Json}
        while([DateTime]::UtcNow -lt $caseDeadline){
            $desktop=[BlackwellReadmeDesktop]::Name()
            if($desktop -ne 'Default'){
                $steps.Add(@{action='input-desktop';name=$desktop;observedUtc=[DateTime]::UtcNow.ToString('o')})
                Start-Sleep -Seconds 3
                if([BlackwellReadmeDesktop]::Name() -ne 'Default'){$case.error='The UAC input desktop is unavailable to UIAutomation; no security setting was changed.';break}
            }
            if($variant -ceq 'normal-uac' -and -not$setup -and (Test-Path -LiteralPath (Join-Path $dir 'setup-started.json'))){$request=Get-Content -Raw -LiteralPath (Join-Path $dir 'setup-started.json')|ConvertFrom-Json;$setup=Get-Process -Id $request.pid -ErrorAction SilentlyContinue;if($setup){$null=Own $setup;$case.setupPid=$setup.Id}}
            $notepads=@(Get-CimInstance Win32_Process -Filter "Name='notepad.exe'"|Where-Object {$_.SessionId -eq $session -and $before -notcontains [int]$_.ProcessId -and $_.CreationDate.ToUniversalTime() -ge $started -and [string]$_.CommandLine -match [regex]::Escape($readme)})
            if($case.finishInvoked -and $notepads.Count -eq 1){$p=Get-Process -Id $notepads[0].ProcessId -ErrorAction Stop;$null=Own $p;$case.notepad=[BlackwellNativeProbe]::Inspect($p.Id)|ConvertFrom-Json;$case.notepadCommandLine=$notepads[0].CommandLine;if(-not$case.notepad.parent.imagePath){$known=@($owned|Where-Object Identity|Where-Object {$_.Identity.pid -eq $case.notepad.parent.pid});if($known.Count -eq 1){$case.notepad.parent|Add-Member -NotePropertyName imagePath -NotePropertyValue $known[0].Identity.imagePath;$case.notepad.parent|Add-Member -NotePropertyName imageEvidence -NotePropertyValue 'owned native setup receipt captured before its exit'}};$case.status=if($case.notepad.integrity -ceq 'Medium' -and -not$case.notepad.elevated -and $case.notepad.imagePath -ieq (Join-Path $system 'notepad.exe')){'passed'}else{'failed'};Capture ($variant+'-readme');break}
            $desktopRoot=[Windows.Automation.AutomationElement]::RootElement
            $windows=@($desktopRoot.FindAll([Windows.Automation.TreeScope]::Children,[Windows.Automation.Condition]::TrueCondition)|Where-Object {$_.Current.ProcessId -gt 0 -and $before -notcontains $_.Current.ProcessId -and $_.Current.Name -match 'Roo Industries' -and $_.Current.Name -match 'Setup'})
            if($windows.Count -gt 1){throw 'Ambiguous installer windows; refuse input'}
            if($windows.Count -eq 1){
                $window=$windows[0];$wp=Get-Process -Id $window.Current.ProcessId -ErrorAction Stop
                if($wp.SessionId -ne $session -or $wp.StartTime.ToUniversalTime() -lt $started){throw 'Wizard process not from this desktop attempt'}
                $snapshot=@(Get-CimInstance Win32_Process);$cursor=@($snapshot|Where-Object ProcessId -eq $wp.Id);$seen=[Collections.Generic.HashSet[int]]::new();$belongs=$false
                while($cursor.Count -eq 1 -and $seen.Add([int]$cursor[0].ProcessId)){
                    $ancestor=@($owned|Where-Object {$_.Identity.pid -eq $cursor[0].ProcessId -and [DateTime]::FromFileTimeUtc([long]$_.Identity.creationTimeFileTimeUtc) -eq $cursor[0].CreationDate.ToUniversalTime()})
                    if($ancestor.Count -eq 1){$belongs=$true;break}
                    $parent=@($owned|Where-Object {$_.Identity.pid -eq $cursor[0].ParentProcessId -and [DateTime]::FromFileTimeUtc([long]$_.Identity.creationTimeFileTimeUtc) -le $cursor[0].CreationDate.ToUniversalTime()})
                    if($parent.Count -eq 1){$belongs=$true;break};$cursor=@($snapshot|Where-Object ProcessId -eq $cursor[0].ParentProcessId)
                }
                if(-not$belongs){throw 'Wizard lacks an owned native caller/setup ancestry; refuse input'}
                if(-not$case.wizardProcess){$null=Own $wp;$case.wizardProcess=[BlackwellNativeProbe]::Inspect($wp.Id)|ConvertFrom-Json;Capture ($variant+'-wizard')}
                $radios=@($window.FindAll([Windows.Automation.TreeScope]::Descendants,[Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ControlTypeProperty,[Windows.Automation.ControlType]::RadioButton))|Where-Object {$_.Current.Name -match 'accept.*agreement' -and $_.Current.Name -notmatch 'not accept'})
                foreach($radio in $radios){$radio.GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Select()}
                $finish=Button $window '^&?Finish$'
                if($finish){
                    $boxes=@($window.FindAll([Windows.Automation.TreeScope]::Descendants,[Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ControlTypeProperty,[Windows.Automation.ControlType]::CheckBox)))
                    $readmeBox=@($boxes|Where-Object {$_.Current.Name -match 'beta tester guide'})
                    if($readmeBox.Count -ne 1){throw 'README checkbox missing or ambiguous'}
                    $toggle=$readmeBox[0].GetCurrentPattern([Windows.Automation.TogglePattern]::Pattern);if($toggle.Current.ToggleState -ne [Windows.Automation.ToggleState]::On){$toggle.Toggle()};$case.readmeChecked=$toggle.Current.ToggleState -eq [Windows.Automation.ToggleState]::On
                    foreach($box in @($boxes|Where-Object {$_.Current.Name -match '^(Launch|Open) '})){$t=$box.GetCurrentPattern([Windows.Automation.TogglePattern]::Pattern);if($t.Current.ToggleState -eq [Windows.Automation.ToggleState]::On){$t.Toggle()}}
                    Capture ($variant+'-finish-checked');$case.finishInvoked=$true;Invoke-Button $finish;$steps.Add(@{action='Finish with README checked';observedUtc=[DateTime]::UtcNow.ToString('o')});Start-Sleep -Milliseconds 100;continue
                }
                $button=Button $window '^(&?Next\s*>?|&?Install|&?OK)$'
                if($button){$identity=$window.Current.ProcessId.ToString()+'|'+$button.Current.Name+'|'+(@($window.FindAll([Windows.Automation.TreeScope]::Descendants,[Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ControlTypeProperty,[Windows.Automation.ControlType]::Text)))|ForEach-Object {$_.Current.Name}) -join '|';if($identity -cne $lastAction -or ([DateTime]::UtcNow-$lastActionUtc).TotalSeconds -ge 5){Invoke-Button $button;$lastAction=$identity;$lastActionUtc=[DateTime]::UtcNow;$steps.Add(@{action=$button.Current.Name;observedUtc=$lastActionUtc.ToString('o')})}}
            }
            Start-Sleep -Milliseconds 200
        }
        if(-not$case.error -and $case.status -ceq 'missing-proof'){$case.error='The wizard/README evidence did not complete within the per-case/overall bound.'}
        $case.steps=@($steps);$rows.Add($case);Save-Result
        foreach($receipt in $owned){Stop-OwnedProcess $receipt}
        if($variant -ceq 'normal-uac' -and [BlackwellReadmeDesktop]::Name() -ne 'Default'){Start-Sleep -Seconds 3;if([BlackwellReadmeDesktop]::Name() -ne 'Default'){throw 'Own Medium caller stopped, but UAC input desktop remains; retained evidence, no arbitrary consent process was killed'}}
    }
    $result.passed=@($rows).Count -eq 2 -and @($rows|Where-Object {$_.status -cne 'passed'}).Count -eq 0
}catch{$failure=$_;$result.error=$_.Exception.Message;$result.passed=$false}
finally {
    $clean=$true
    foreach($identity in @($copies|Where-Object {$_.path -like '*\IntegrityProbe.exe'})){
        try{
            $handle=[RooValidationOwnership.Native]::CreateFile($identity.path,0,7,[IntPtr]::Zero,3,0x00200000,[IntPtr]::Zero)
            try{if($handle.IsInvalid -or [RooValidationOwnership.Native]::FileId($handle) -cne $identity.id -or (Get-FileHash -LiteralPath $identity.path).Hash -cne $identity.hash){throw 'Pending launcher file differs; retained'}}finally{$handle.Dispose()}
            foreach($p in @(Get-Process -ErrorAction SilentlyContinue|Where-Object {try{$_.Path -ieq $identity.path}catch{$false}})){$processReceipt=New-OwnedProcess $p;if($processReceipt){$owned.Add($processReceipt)}}
        }catch{$clean=$false;$result.error+='; pending launcher identity: '+$_.Exception.Message}
    }
    $result.ownedProcesses=@($owned|ForEach-Object Identity)
    foreach($receipt in $owned){try{Stop-OwnedProcess $receipt;$receipt.process.Dispose()}catch{$clean=$false;$result.error+='; exact process cleanup: '+$_.Exception.Message}}
    foreach($lease in $readLeases){$lease.Dispose()}
    foreach($identity in $copies){try{$copy=Open-OwnedProbe $identity;try{Remove-OwnedProbe $copy}finally{$copy.Dispose()}}catch{$clean=$false;$result.error+='; exact file cleanup: '+$_.Exception.Message}}
    try{if(@(Get-ChildItem -LiteralPath $fixture -Recurse -Force|Where-Object {$_.Attributes -band [IO.FileAttributes]::ReparsePoint}).Count){throw 'Reparse fixture retained'};$unknown=@(Get-ChildItem -LiteralPath $fixture -File -Recurse -Force|Where-Object {$_.Name -notin 'compiled-launcher.exe','probe-report.json','probe-report.json.tmp','setup-started.json','setup-started.json.tmp','setup-error.json','probe-error.txt'});if($unknown.Count){throw 'Unknown fixture entries retained'};Remove-Item -LiteralPath $fixture -Recurse -Force}catch{$clean=$false;$result.error+='; fixture cleanup: '+$_.Exception.Message}
    $result.cleanupPassed=$clean;Save-Result
}
if($failure){Write-Output ('FAIL interactive README check: '+$result.error);throw $failure}
if(@($rows|Where-Object {$_.status -ceq 'failed'}).Count){Write-Output ('FAIL native interactive README identity or integrity: '+(Join-Path $Evidence 'interactive-readme.json'));exit 1}
if(-not$result.passed){Write-Output ('MISSING PROOF interactive README: '+(Join-Path $Evidence 'interactive-readme.json'));exit 2}
Write-Output ('PASS both native interactive installer README checks: '+(Join-Path $Evidence 'interactive-readme.json'))
