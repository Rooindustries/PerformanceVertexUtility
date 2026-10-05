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
        object scheduler = Activator.CreateInstance(Type.GetTypeFromProgID("Schedule.Service", true)!)!;
        object folder;
        try { CallTaskMember(scheduler, "Connect"); folder = CallTaskMember(scheduler, "GetFolder", @"\")!; }
        catch { Marshal.FinalReleaseComObject(scheduler); throw; }
        object? Find()
        {
            try { return CallTaskMember(folder, "GetTask", name); }
            catch (COMException error) when (error.HResult == unchecked((int)0x80070002)) { return null; }
            catch (FileNotFoundException) { return null; }
        }
        object? existing;
        try { existing = Find(); }
        catch { Marshal.FinalReleaseComObject(folder); Marshal.FinalReleaseComObject(scheduler); throw; }
        if (existing is not null) { Marshal.FinalReleaseComObject(existing); Marshal.FinalReleaseComObject(folder); Marshal.FinalReleaseComObject(scheduler); throw new InvalidOperationException("The exact timer fixture name was already present; it was left intact."); }
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
                var parts = new List<object>();
                object Own(object value) { if (!parts.Any(item => ReferenceEquals(item, value))) parts.Add(value); return value; }
                object Part(object target, string member) => Own(GetTaskProperty(target, member)!);
                object task;
                try
                {
                    var definition = Own(CallTaskMember(scheduler, "NewTask", 0)!);
                    SetTaskProperty(Part(definition, "RegistrationInfo"), "Description", "Roo Industries timer request at Windows sign-in");
                    var principal = Part(definition, "Principal");
                    SetTaskProperty(principal, "UserId", owner.UserSid); SetTaskProperty(principal, "LogonType", 3); SetTaskProperty(principal, "RunLevel", 0);
                    var settings = Part(definition, "Settings");
                    SetTaskProperty(settings, "Enabled", false); SetTaskProperty(settings, "ExecutionTimeLimit", "PT0S"); SetTaskProperty(settings, "MultipleInstances", 2);
                    SetTaskProperty(settings, "DisallowStartIfOnBatteries", false); SetTaskProperty(settings, "StopIfGoingOnBatteries", false); SetTaskProperty(settings, "StartWhenAvailable", true);
                    var trigger = Own(CallTaskMember(Part(definition, "Triggers"), "Create", 9)!); SetTaskProperty(trigger, "UserId", owner.UserSid);
                    var action = Own(CallTaskMember(Part(definition, "Actions"), "Create", 0)!);
                    var system = Environment.GetFolderPath(Environment.SpecialFolder.System);
                    SetTaskProperty(action, "Path", Path.Combine(system, "conhost.exe"));
                    var selected = scenario is "different-root" or "older-version" ? Path.Combine(parent, scenario, "startup.ps1") : scriptPath;
                    SetTaskProperty(action, "Arguments", "--headless \"" + Path.Combine(system, @"WindowsPowerShell\v1.0\powershell.exe") + "\" -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File \"" + selected + "\"");
                    task = CallTaskMember(folder, "RegisterTaskDefinition", name, definition, 2, owner.UserSid, null, 3, null)!;
                    registered = true;
                }
                finally { foreach (var part in parts.AsEnumerable().Reverse()) Marshal.FinalReleaseComObject(part); }
                var receiptPath = Path.Combine(timer, "startup.json");
                string originalXml, originalSddl;
                try
                {
                    OperationFiles.Write(receiptPath, new TimerStartupReceipt(owner, name, "created", (string)fingerprint.Invoke(null, [task])!, OperationFiles.HashFile(scriptPath)));
                    originalXml = (string)GetTaskProperty(task, "Xml")!;
                    originalSddl = (string)CallTaskMember(task, "GetSecurityDescriptor", 7)!;
                    if (scenario == "exact")
                    {
                        parts.Clear();
                        try
                        {
                            var actual = Own(GetTaskProperty(task, "Definition")!);
                            var principal = Part(actual, "Principal");
                            var trigger = Own(GetTaskProperty(Part(actual, "Triggers"), "Item", 1)!);
                            Console.WriteLine("MEASURE native principal=" + (string)GetTaskProperty(principal, "UserId")! + " logon=" + (int)GetTaskProperty(principal, "LogonType")! + " level=" + (int)GetTaskProperty(principal, "RunLevel")! + " trigger=" + (string)GetTaskProperty(trigger, "UserId")!);
                            Console.WriteLine("MEASURE canonical script equal=" + (script == (string)generate.Invoke(null, [assembly, launcher, true, PolicyRootSecurity.CanonicalPath(timer)])!));
                            Console.WriteLine("MEASURE install protection=" + PolicyRootSecurity.Problem(install, DataFolder.Kind, false) + " operations protection=" + PolicyRootSecurity.Problem(Path.Combine(root, "operations"), OperationsFolder.Kind, false));
                        }
                        finally { foreach (var part in parts.AsEnumerable().Reverse()) Marshal.FinalReleaseComObject(part); }
                    }
                }
                finally { Marshal.FinalReleaseComObject(task); }
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
                try
                {
                    check(scenario == "exact" ? remaining is null : remaining is not null, "Timer uninstall " + scenario + (scenario == "exact" ? " removes the exact protected task" : " keeps the task"));
                    if (scenario == "older-version") check(messages.Any(message => message.Contains("kept: older-version timer task", StringComparison.Ordinal)), "An older-version timer task is explicitly logged as kept");
                    if (remaining is not null && ((string)GetTaskProperty(remaining, "Xml")! != originalXml || (string)CallTaskMember(remaining, "GetSecurityDescriptor", 7)! != originalSddl)) throw new InvalidOperationException("The timer fixture changed unexpectedly; cleanup refused.");
                }
                finally { if (remaining is not null) Marshal.FinalReleaseComObject(remaining); }
                if (remaining is not null) CallTaskMember(folder, "DeleteTask", name, 0);
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
            Marshal.FinalReleaseComObject(folder); Marshal.FinalReleaseComObject(scheduler);
            if (registered)
            {
                if (originalFailure is not null) Console.Error.WriteLine(originalFailure);
                throw new InvalidOperationException("An incomplete timer fixture needs receipt-based recovery: " + parent);
            }
            H.Delete(parent);
        }
        check(!Directory.Exists(parent) && FindTaskAbsent(name), "Timer uninstall fixtures, private hive and exact task are removed");
    }

    private static object? GetTaskProperty(object target, string member, params object?[] arguments) => InvokeTaskMember(target, member, BindingFlags.GetProperty, arguments);
    private static object? SetTaskProperty(object target, string member, object value) => InvokeTaskMember(target, member, BindingFlags.SetProperty, value);
    private static object? CallTaskMember(object target, string member, params object?[] arguments) => InvokeTaskMember(target, member, BindingFlags.InvokeMethod, arguments);
    private static object? InvokeTaskMember(object target, string member, BindingFlags kind, params object?[] arguments)
    {
        try { return target.GetType().InvokeMember(member, kind | BindingFlags.Public | BindingFlags.Instance, null, target, arguments); }
        catch (TargetInvocationException error) when (error.InnerException is { } inner) { throw inner; }
    }

    private static bool FindTaskAbsent(string name)
    {
        var run = H.Run("powershell.exe", "-NoProfile -NonInteractive -Command \"if(Get-ScheduledTask -TaskName '" + name + "' -ErrorAction SilentlyContinue){exit 1}\"");
        return run.Exit == 0;
    }
}
