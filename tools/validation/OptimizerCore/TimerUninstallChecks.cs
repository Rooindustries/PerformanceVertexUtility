using System.Reflection;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using Microsoft.Win32;
using RooIndustries.Optimizer;
using H = DataRootHarness;

static partial class DataFolderChecks
{
    private static void TimerUninstall(Action<bool, string> check)
    {
        var parent = Path.Combine(H.Local, H.Name("timer-uninstall"));
        var root = Path.Combine(parent, "RooIndustriesOptimizationSuite");
        var install = Path.Combine(parent, "install");
        var binary = Path.Combine(install, "backend", "bin", "optimizer");
        var timer = Path.Combine(root, "operations", "windows-timer");
        var owner = OperationOwner.Current();
        var name = "RooIndustries.Timer." + OperationFiles.Hash(Encoding.UTF8.GetBytes(owner.UserSid))[..16];
        _ = DataFolder.Root;
        Directory.CreateDirectory(parent);
        dynamic scheduler = Activator.CreateInstance(Type.GetTypeFromProgID("Schedule.Service", true)!)!;
        scheduler.Connect();
        dynamic folder = scheduler.GetFolder(@"\");
        object? Find()
        {
            try { return folder.GetTask(name); }
            catch (COMException error) when (error.HResult == unchecked((int)0x80070002)) { return null; }
            catch (FileNotFoundException) { return null; }
        }
        var existing = Find();
        if (existing is not null) { Marshal.FinalReleaseComObject(existing); throw new InvalidOperationException("The exact timer fixture name was already present; it was left intact."); }
        var registered = false;
        Exception? originalFailure = null;
        try
        {
            using var isolated = new DataRootPrivateHive(Path.Combine(parent, "machine.hive"));
            PolicyRootSecurity.Secure(root, DataFolder.Kind);
            OperationsFolder.Secure(Path.Combine(root, "operations"));
            Directory.CreateDirectory(timer);
            PolicyRootSecurity.Secure(install, DataFolder.Kind);
            Directory.CreateDirectory(binary);
            var assembly = Path.Combine(binary, "Optimizer.Host.dll");
            var launcher = Path.Combine(binary, "Optimizer.Host.exe");
            File.Copy(Assembly.GetEntryAssembly()!.Location, assembly);
            File.Copy(Environment.ProcessPath!, launcher);
            var generate = typeof(TimerStartupControl).GetMethod("StartupScript", BindingFlags.NonPublic | BindingFlags.Static)!;
            var fingerprint = typeof(TimerStartupControl).GetMethod("Fingerprint", BindingFlags.NonPublic | BindingFlags.Static)!;
            var script = (string)generate.Invoke(null, [assembly, launcher, true, timer])!;
            foreach (var scenario in new[] { "exact", "different-byte", "unprotected-receipt", "different-root", "older-version" })
            {
                var scriptPath = Path.Combine(timer, "startup.ps1");
                File.WriteAllText(scriptPath, scenario == "different-byte" ? script + "\n" : script, new UTF8Encoding(false));
                dynamic definition = scheduler.NewTask(0);
                definition.RegistrationInfo.Description = "Roo Industries timer request at Windows sign-in";
                definition.Principal.UserId = owner.UserSid; definition.Principal.LogonType = 3; definition.Principal.RunLevel = 0;
                definition.Settings.Enabled = false; definition.Settings.ExecutionTimeLimit = "PT0S"; definition.Settings.MultipleInstances = 2;
                definition.Settings.DisallowStartIfOnBatteries = false; definition.Settings.StopIfGoingOnBatteries = false; definition.Settings.StartWhenAvailable = true;
                dynamic trigger = definition.Triggers.Create(9); trigger.UserId = owner.UserSid;
                dynamic action = definition.Actions.Create(0);
                var system = Environment.GetFolderPath(Environment.SpecialFolder.System);
                action.Path = Path.Combine(system, "conhost.exe");
                var selected = scenario is "different-root" or "older-version" ? Path.Combine(parent, scenario, "startup.ps1") : scriptPath;
                action.Arguments = "--headless \"" + Path.Combine(system, @"WindowsPowerShell\v1.0\powershell.exe") + "\" -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File \"" + selected + "\"";
                object task = folder.RegisterTaskDefinition(name, definition, 2, owner.UserSid, null, 3, null);
                registered = true;
                Marshal.FinalReleaseComObject(definition);
                var receiptPath = Path.Combine(timer, "startup.json");
                OperationFiles.Write(receiptPath, new TimerStartupReceipt(owner, name, "created", (string)fingerprint.Invoke(null, [task])!, OperationFiles.HashFile(scriptPath)));
                var originalXml = (string)((dynamic)task).Xml;
                var originalSddl = (string)((dynamic)task).GetSecurityDescriptor(7);
                if (scenario == "exact")
                {
                    dynamic actual = ((dynamic)task).Definition;
                    Console.WriteLine("MEASURE native principal=" + (string)actual.Principal.UserId + " logon=" + (int)actual.Principal.LogonType + " level=" + (int)actual.Principal.RunLevel + " trigger=" + (string)actual.Triggers[1].UserId);
                    Console.WriteLine("MEASURE canonical script equal=" + (script == (string)generate.Invoke(null, [assembly, launcher, true, PolicyRootSecurity.CanonicalPath(timer)])!));
                    Console.WriteLine("MEASURE install protection=" + PolicyRootSecurity.Problem(install, DataFolder.Kind, false) + " operations protection=" + PolicyRootSecurity.Problem(Path.Combine(root, "operations"), OperationsFolder.Kind, false));
                    Marshal.FinalReleaseComObject(actual);
                }
                Marshal.FinalReleaseComObject(task);
                if (scenario == "older-version") File.Delete(receiptPath);
                if (scenario == "unprotected-receipt")
                {
                    var acl = new FileInfo(receiptPath).GetAccessControl();
                    acl.AddAccessRule(new FileSystemAccessRule(WindowsIdentity.GetCurrent().User!, FileSystemRights.Modify, AccessControlType.Allow));
                    new FileInfo(receiptPath).SetAccessControl(acl);
                }
                var messages = H.Has(typeof(TimerStartupControl), "RemoveForInstall") ? (string[])H.Api(typeof(TimerStartupControl), "RemoveForInstall", install)! : Array.Empty<string>();
                foreach (var message in messages) Console.WriteLine("MEASURE " + scenario + " " + message);
                var remaining = Find();
                check(scenario == "exact" ? remaining is null : remaining is not null, "Timer uninstall " + scenario + (scenario == "exact" ? " removes the exact protected task" : " keeps the task"));
                if (scenario == "older-version") check(messages.Any(message => message.Contains("kept: older-version timer task", StringComparison.Ordinal)), "An older-version timer task is explicitly logged as kept");
                if (remaining is not null)
                {
                    dynamic retained = remaining;
                    if ((string)retained.Xml != originalXml || (string)retained.GetSecurityDescriptor(7) != originalSddl) throw new InvalidOperationException("The timer fixture changed unexpectedly; cleanup refused.");
                    Marshal.FinalReleaseComObject(remaining);
                    folder.DeleteTask(name, 0);
                }
                registered = false;
                File.Delete(receiptPath); File.Delete(scriptPath);
            }
        }
        catch (Exception error)
        {
            originalFailure = error;
            throw;
        }
        finally
        {
            if (registered)
            {
                if (originalFailure is not null) Console.Error.WriteLine(originalFailure);
                throw new InvalidOperationException("An incomplete timer fixture needs receipt-based recovery: " + parent);
            }
            Marshal.FinalReleaseComObject(folder); Marshal.FinalReleaseComObject(scheduler);
            H.Delete(parent);
        }
        check(!Directory.Exists(parent) && FindTaskAbsent(name), "Timer uninstall fixtures, private hive and exact task are removed");
    }

    private static bool FindTaskAbsent(string name)
    {
        var run = H.Run("powershell.exe", "-NoProfile -NonInteractive -Command \"if(Get-ScheduledTask -TaskName '" + name + "' -ErrorAction SilentlyContinue){exit 1}\"");
        return run.Exit == 0;
    }
}
