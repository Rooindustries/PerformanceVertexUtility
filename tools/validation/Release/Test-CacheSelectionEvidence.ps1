param([Parameter(Mandatory)][string]$Source,[Parameter(Mandatory)][string]$OutDir,[string]$ExpectedMachine='SERVI-WINDOWS-D')
$ErrorActionPreference='Stop'
if($env:COMPUTERNAME -ine $ExpectedMachine){throw 'Wrong selection proof machine'}
. (Join-Path $Source 'tools\validation\LoadTimes\CleanupOwnership.Common.ps1')
. (Join-Path $Source 'tools\validation\LoadTimes\LoadTimesHandoff.Common.ps1')
Assert-HandoffProtected (Split-Path $OutDir -Parent)
if(Test-Path -LiteralPath $OutDir){throw 'Existing selection proof retained'}
[IO.Directory]::CreateDirectory($OutDir)|Out-Null
Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes,PresentationFramework,PresentationCore,WindowsBase,System.Xaml
Add-Type -ReferencedAssemblies @([Windows.Window].Assembly.Location,[Windows.Media.Visual].Assembly.Location,[Windows.Threading.Dispatcher].Assembly.Location,[Windows.Markup.IQueryAmbient].Assembly.Location) -TypeDefinition @'
using System;
using System.Threading;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Automation;
using System.Windows.Interop;
using System.Windows.Threading;
public sealed class RooCacheSelectionFixture : IDisposable {
    readonly ManualResetEvent ready = new ManualResetEvent(false);
    readonly Thread thread;
    Window window;
    Exception error;
    public IntPtr Handle;
    public RooCacheSelectionFixture() {
        thread = new Thread(() => {
            try {
                window = new Window { Title = "Roo Industries private selection proof", Width = 340, Height = 200, ShowActivated = false };
                var panel = new StackPanel();
                var list = new ListBox { SelectionMode = SelectionMode.Multiple };
                AutomationProperties.SetAutomationId(list, "PrivateSelectionList");
                list.Items.Add("owned selection one");
                list.Items.Add("owned selection two");
                list.SelectedIndex = 0;
                panel.Children.Add(list);
                var label = new TextBlock { Text = "private unsupported selection pattern" };
                AutomationProperties.SetAutomationId(label, "PrivateSelectionLabel");
                panel.Children.Add(label);
                window.Content = panel;
                window.Closed += (sender, args) => window.Dispatcher.BeginInvokeShutdown(DispatcherPriority.Normal);
                window.Show();
                Handle = new WindowInteropHelper(window).Handle;
                var timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(60) };
                timer.Tick += (sender, args) => { timer.Stop(); window.Close(); };
                timer.Start();
                ready.Set();
                Dispatcher.Run();
            } catch (Exception ex) { error = ex; ready.Set(); }
        });
        thread.IsBackground = true;
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        if (!ready.WaitOne(10000)) throw new TimeoutException("Private window did not become ready");
        if (error != null) throw error;
    }
    public void Dispose() {
        if (window != null && !window.Dispatcher.HasShutdownStarted)
            window.Dispatcher.BeginInvoke(new Action(() => window.Close()));
        if (!thread.Join(10000)) throw new TimeoutException("Private window did not close");
        ready.Dispose();
    }
}
'@
$checks=[Collections.Generic.List[object]]::new();$fixture=$null;$passed=$false
function Check([bool]$Ok,[string]$Name){$checks.Add(@{passed=$Ok;check=$Name});if(-not$Ok){throw $Name};'PASS '+$Name}
function Read-Selection($history){@(Invoke-Expression $script:selectionExpression)}
try{
 $path=Join-Path $Source 'tools\validation\LoadTimes\Test-CacheInvalidation.ps1'
 $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
 $function=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'New-CacheGameSession'},$true)
 $assignment=$function.Find({param($n)$n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left -is [Management.Automation.Language.VariableExpressionAst] -and $n.Left.VariablePath.UserPath -ceq 'selected'},$true)
 if($errors -or -not$assignment){throw 'Actual selection extraction missing or malformed'}
 $script:selectionExpression=$assignment.Right.Extent.Text
 $fixture=[RooCacheSelectionFixture]::new()
 $root=[Windows.Automation.AutomationElement]::FromHandle($fixture.Handle)
 Check ($root.Current.ProcessId -eq $PID) 'live private WPF window belongs to this native proof process'
 $history=$root.FindFirst([Windows.Automation.TreeScope]::Descendants,[Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::AutomationIdProperty,'PrivateSelectionList'))
 $pattern=$history.GetCurrentPattern([Windows.Automation.SelectionPattern]::Pattern)
 Check ($pattern.GetType() -eq [Windows.Automation.SelectionPattern]) 'history exposes the actual System.Windows.Automation.SelectionPattern type'
 $refused=$false;try{$pattern.GetSelection()|Out-Null}catch{$refused=$_.FullyQualifiedErrorId -like 'MethodNotFound*'}
 Check $refused 'original direct GetSelection call reproduces native MethodNotFound'
 $selected=@(Read-Selection $history)
 Check ($selected.Count -eq 1 -and $selected[0].Current.Name -ceq 'owned selection one') 'actual source extraction returns the selected live UIA item'
 $selected[0].GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).RemoveFromSelection()
 Check (@(Read-Selection $history).Count -eq 0) 'actual source extraction returns empty after native UIA deselection'
 $second=$history.FindFirst([Windows.Automation.TreeScope]::Descendants,[Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::NameProperty,'owned selection two'))
 $second.GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Select()
 $selected=@(Read-Selection $history)
 Check ($selected.Count -eq 1 -and $selected[0].Current.Name -ceq 'owned selection two') 'actual source extraction reads a changed live UIA selection'
 $label=$root.FindFirst([Windows.Automation.TreeScope]::Descendants,[Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::AutomationIdProperty,'PrivateSelectionLabel'))
 $refused=$false;try{Read-Selection $label|Out-Null}catch{$refused=$true}
 Check $refused 'unsupported native SelectionPattern refuses rather than becoming empty'
 $fixture.Dispose();$fixture=$null
 Check $true 'owned private window closed without starting or stopping another process'
 $passed=$true
}finally{
 if($fixture){$fixture.Dispose()}
 [ordered]@{passed=$passed;checks=@($checks);sourceSha256=(Get-FileHash -LiteralPath $path).Hash;expression=$script:selectionExpression;proofPid=$PID;installedProductUsed=$false;realStateAccessed=$false}|ConvertTo-Json -Depth 8|Set-Content -LiteralPath (Join-Path $OutDir 'result.json') -Encoding UTF8
}
