#nullable enable
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Xml.Linq;
using Microsoft.Win32;
using System.Security.Principal;

namespace RooIndustries.Optimizer;

public sealed record TimerStartupReceipt([property: JsonRequired] OperationOwner Owner, [property: JsonRequired] string TaskName, [property: JsonRequired] string Phase, [property: JsonRequired] string DefinitionHash, [property: JsonRequired] string ScriptHash);

public static class TimerStartupControl
{
    private static (string Root, string Name) Target(ControlAddress address)
    {
        if (address.Property != "enabled") throw new InvalidDataException("Unknown timer startup control.");
        var root = TimerControl.Root(new("timer", address.Target, "half-millisecond"));
        var name = address.Target == "system" ? "RooIndustries.Timer." + OperationFiles.Hash(Encoding.UTF8.GetBytes(OperationOwner.Current().UserSid))[..16]
            : "RooIndustriesTweakProbe_ec3d917cb672498785218eb3d0aa790f";
        return (root, name);
    }
    private static string ReceiptPath(string root) => Path.Combine(root, "startup.json");
    private static TimerStartupReceipt? Receipt(string root, string name)
    {
        if (!File.Exists(ReceiptPath(root))) return null;
        var receipt = OperationFiles.Read<TimerStartupReceipt>(ReceiptPath(root)); receipt.Owner.Verify();
        if (receipt.TaskName != name || receipt.Phase is not ("creating" or "created")) throw new InvalidDataException("Timer startup ownership is incomplete.");
        return receipt;
    }
    private static object ConnectScheduler()
    {
        var scheduler = Activator.CreateInstance(Type.GetTypeFromProgID("Schedule.Service", true)!)!;
        try { CallTaskMember(scheduler, "Connect"); return scheduler; }
        catch { Marshal.FinalReleaseComObject(scheduler); throw; }
    }
    internal static string StartupScript(string assembly, string launcher, bool bundled, string root)
    {
        static string Literal(string value) => "'" + value.Replace("'", "''", StringComparison.Ordinal) + "'";
        static string Verify(string file) => "if((Get-FileHash -LiteralPath " + Literal(file) + " -Algorithm SHA256).Hash -cne " + Literal(OperationFiles.HashFile(file)) + "){throw 'The timer helper changed; review its startup registration again.'}\n";
        return "$ErrorActionPreference='Stop'\n" + Verify(assembly) + (bundled ? Verify(launcher) : "") + "& " + Literal(launcher) + (bundled ? "" : " " + Literal(assembly)) + " '--timer-autostart' " + Literal(root) + "\nexit $LASTEXITCODE\n";
    }
    private static object? Find(object scheduler, string name)
    {
        object? folder = null;
        try { folder = CallTaskMember(scheduler, "GetFolder", @"\")!; return CallTaskMember(folder, "GetTask", name); }
        catch (FileNotFoundException) { return null; }
        catch (COMException error) when (error.HResult == unchecked((int)0x80070002)) { return null; }
        finally { if (folder is not null) Marshal.FinalReleaseComObject(folder); }
    }
    private static string Fingerprint(object registered)
    {
        var xml = XDocument.Parse((string)GetTaskProperty(registered, "Xml")!); var ns = xml.Root!.Name.Namespace;
        xml.Root.Element(ns + "Settings")?.Element(ns + "Enabled")?.Remove();
        return OperationFiles.Hash(Encoding.UTF8.GetBytes(xml.ToString(SaveOptions.DisableFormatting) + "\n" + (string)CallTaskMember(registered, "GetSecurityDescriptor", 7)!));
    }
    public static string[] RemoveInstalled() => RemoveForInstall(Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", "..", "..")));

    public static string[] RemoveForInstall(string install)
    {
        if (!PolicyRootSecurity.Elevated()) throw new UnauthorizedAccessException(OperationsFolder.NotAdministrator);
        install = PolicyRootSecurity.Normalize(install);
        using var markers = Registry.LocalMachine.OpenSubKey(PolicyRootSecurity.MarkerKey);
        var roots = (markers?.GetValueNames() ?? []).Where(root => !root.Contains('|') && Path.IsPathFullyQualified(root) &&
            (string.Equals(Path.GetFileName(root), BrandCompatibility.LegacyDataFolder, StringComparison.OrdinalIgnoreCase) || string.Equals(Path.GetFileName(root), "RooIndustriesOptimizationSuite", StringComparison.OrdinalIgnoreCase)))
            .Select(root => (Root: root, Sid: markers!.GetValue(root, null, RegistryValueOptions.DoNotExpandEnvironmentNames) as string)).Where(row => row.Sid is not null).ToArray();
        var messages = new List<string>();
        var scheduler = ConnectScheduler();
        object folder = CallTaskMember(scheduler, "GetFolder", @"\")!;
        object tasks = CallTaskMember(folder, "GetTasks", 1)!;
        try
        {
            for (var index = 1; index <= (int)GetTaskProperty(tasks, "Count")!; index++)
            {
                object found = GetTaskProperty(tasks, "Item", index)!;
                try
                {
                    var name = (string)GetTaskProperty(found, "Name")!;
                    if (!name.StartsWith("RooIndustries.Timer.", StringComparison.Ordinal)) continue;
                    var candidates = roots.Where(row => name == "RooIndustries.Timer." + OperationFiles.Hash(Encoding.UTF8.GetBytes(row.Sid!))[..16]).ToArray();
                    var removed = false;
                    var older = candidates.Length == 0;
                    foreach (var candidate in candidates)
                    {
                        try
                        {
                            var dataRoot = PolicyRootSecurity.CanonicalPath(candidate.Root);
                            using var rootLease = PolicyRootLease.Acquire(dataRoot, DataFolder.Kind, deep: false);
                            var operations = Path.Combine(dataRoot, "operations");
                            var root = Path.Combine(operations, OperationsFolder.TimerFolder);
                            if (!PolicyRootSecurity.AdministratorOnlyEntry(operations, true) || !PolicyRootSecurity.AdministratorOnlyEntry(root, true)) { older = true; continue; }
                            using var operationLease = PolicyRootLease.Acquire(operations, OperationsFolder.Kind, deep: false);
                            using var guard = OperationFiles.Lock(Path.Combine(root, "startup"));
                            var receiptPath = ReceiptPath(root); var scriptPath = Path.Combine(root, "startup.ps1");
                            if (!File.Exists(receiptPath) || !PolicyRootSecurity.AdministratorOnlyEntry(receiptPath, false) || !PolicyRootSecurity.AdministratorOnlyEntry(scriptPath, false)) { older = true; continue; }
                            var receipt = OperationFiles.Read<TimerStartupReceipt>(receiptPath);
                            static bool Digest(string value) => value is { Length: 64 } && value.All(char.IsAsciiHexDigit);
                            if (receipt.Owner.Machine != Environment.MachineName || receipt.Owner.UserSid != candidate.Sid || receipt.TaskName != name || receipt.Phase != "created" || !Digest(receipt.ScriptHash) || !Digest(receipt.DefinitionHash)) throw new InvalidDataException("The timer receipt does not match its Windows owner and task.");
                            if (!string.Equals(Fingerprint(found), receipt.DefinitionHash, StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("The timer task fingerprint differs from its receipt.");
                            var startupRoot = root;
                            var com = new List<object>();
                            object ReadCom(object target, string member, params object[] arguments)
                            {
                                var value = GetTaskProperty(target, member, arguments);
                                if (value is null) return null!;
                                if (Marshal.IsComObject(value) && !com.Any(prior => ReferenceEquals(prior, value))) com.Add(value);
                                return value;
                            }
                            try
                            {
                                var definition = ReadCom(found, "Definition");
                                var principal = ReadCom(definition, "Principal");
                                var registration = ReadCom(definition, "RegistrationInfo");
                                var actions = ReadCom(definition, "Actions");
                                var triggers = ReadCom(definition, "Triggers");
                                var system = Environment.GetFolderPath(Environment.SpecialFolder.System);
                                static string Sid(string value)
                                {
                                    try { return new SecurityIdentifier(value).Value; }
                                    catch (ArgumentException) { return ((SecurityIdentifier)new NTAccount(value).Translate(typeof(SecurityIdentifier))).Value; }
                                }
                                if ((string)ReadCom(registration, "Description") != "Roo Industries timer request at Windows sign-in" || Sid((string)ReadCom(principal, "UserId")) != candidate.Sid || (int)ReadCom(principal, "LogonType") != 3 || (int)ReadCom(principal, "RunLevel") != 0 || (int)ReadCom(actions, "Count") != 1 || (int)ReadCom(triggers, "Count") != 1) throw new InvalidDataException("The timer principal or description differs from the native definition.");
                                var action = ReadCom(actions, "Item", 1); var trigger = ReadCom(triggers, "Item", 1);
                                var prefix = "--headless \"" + Path.Combine(system, @"WindowsPowerShell\v1.0\powershell.exe") + "\" -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File \"";
                                var arguments = prefix + scriptPath + "\"";
                                if ((int)ReadCom(action, "Type") != 0 || !string.Equals((string)ReadCom(action, "Path"), Path.Combine(system, "conhost.exe"), StringComparison.OrdinalIgnoreCase) || !string.Equals((string)ReadCom(action, "Arguments"), arguments, StringComparison.OrdinalIgnoreCase) || !string.IsNullOrEmpty((string)ReadCom(action, "WorkingDirectory")) || (int)ReadCom(trigger, "Type") != 9 || Sid((string)ReadCom(trigger, "UserId")) != candidate.Sid) throw new InvalidDataException("The timer action or trigger differs from the native definition.");
                                startupRoot = Path.GetDirectoryName(((string)ReadCom(action, "Arguments"))[prefix.Length..^1])!;
                            }
                            finally { for (var member = com.Count - 1; member >= 0; member--) Marshal.FinalReleaseComObject(com[member]); }
                            var binary = Path.Combine(install, "backend", "bin", "optimizer");
                            var assembly = Path.Combine(binary, "Optimizer.Host.dll"); var launcher = Path.Combine(binary, "Optimizer.Host.exe");
                            if (!PolicyRootSecurity.AdministratorOnlyEntry(install, true) || !PolicyRootSecurity.AdministratorOnlyEntry(binary, true) || !PolicyRootSecurity.AdministratorOnlyEntry(assembly, false) || !PolicyRootSecurity.AdministratorOnlyEntry(launcher, false)) throw new InvalidDataException("The installed timer helper files are not administrator-owned plain files.");
                            using var scriptFile = NativeFiles.OpenFile(scriptPath);
                            if (NativeFiles.Info(scriptFile).Links != 1) throw new InvalidDataException("The timer startup script has another hard link.");
                            using var receiptFile = NativeFiles.OpenFile(receiptPath);
                            if (NativeFiles.Info(receiptFile).Links != 1) throw new InvalidDataException("The timer startup receipt has another hard link.");
                            var bytes = File.ReadAllBytes(scriptPath);
                            if (!string.Equals(OperationFiles.Hash(bytes), receipt.ScriptHash, StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("The timer startup script hash differs from its receipt.");
                            if (!bytes.AsSpan().SequenceEqual(new UTF8Encoding(false).GetBytes(StartupScript(assembly, launcher, true, startupRoot)))) throw new InvalidDataException("The timer startup script bytes differ from this install.");
                            if (!string.Equals(Fingerprint(found), receipt.DefinitionHash, StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("The timer task fingerprint differs from its receipt.");
                            if (rootLease.Moved || operationLease.Moved) throw new IOException("The timer recovery folder moved while its ownership was checked.");
                            CallTaskMember(folder, "DeleteTask", name, 0);
                            var remaining = Find(scheduler, name);
                            if (remaining is not null) { Marshal.FinalReleaseComObject(remaining); throw new IOException("The owned timer task remains after removal."); }
                            messages.Add("removed: timer task " + name); removed = true; break;
                        }
                        catch (Exception error) when (error is IOException or InvalidDataException or UnauthorizedAccessException or InvalidOperationException or JsonException or ArgumentException or COMException or IdentityNotMappedException)
                        { messages.Add("kept: timer task " + name + ": " + error.Message); }
                    }
                    if (!removed) messages.Add((older ? "kept: older-version timer task " : "kept: timer task with different ownership ") + name);
                }
                finally { Marshal.FinalReleaseComObject(found); }
            }
            return messages.ToArray();
        }
        finally { Marshal.FinalReleaseComObject(tasks); Marshal.FinalReleaseComObject(folder); Marshal.FinalReleaseComObject(scheduler); }
    }

    private static object? GetTaskProperty(object target, string member, params object[] arguments) => InvokeTaskMember(target, member, BindingFlags.GetProperty, arguments);
    private static object? CallTaskMember(object target, string member, params object[] arguments) => InvokeTaskMember(target, member, BindingFlags.InvokeMethod, arguments);
    private static object? InvokeTaskMember(object target, string member, BindingFlags kind, params object[] arguments)
    {
        try { return target.GetType().InvokeMember(member, kind | BindingFlags.Public | BindingFlags.Instance, null, target, arguments); }
        catch (TargetInvocationException error) when (error.InnerException is { } inner) { throw inner; }
    }

    public static TweakControlRead Read(ControlAddress address)
    {
        var target = Target(address); var receipt = Receipt(target.Root, target.Name);
        var scheduler = ConnectScheduler(); object? found = null;
        try
        {
            found = Find(scheduler, target.Name); dynamic task = found!;
            if (found is not null)
            {
                if (receipt is not { Phase: "created" }) throw new InvalidDataException("The timer startup task exists without confirmed ownership and was left intact.");
                if (Fingerprint(found) != receipt.DefinitionHash || !File.Exists(Path.Combine(target.Root, "startup.ps1")) || OperationFiles.HashFile(Path.Combine(target.Root, "startup.ps1")) != receipt.ScriptHash)
                    throw new InvalidDataException("The timer startup task or its script changed and was left intact.");
            }
            return new(address, "timer-startup:" + target.Name, OperationOwner.Current().UserSid, ControlValues.From(found is not null && (bool)task.Enabled),
                "Start the timer request at Windows sign-in", LostLease: found is null && receipt is not null);
        }
        finally { if (found is not null) Marshal.FinalReleaseComObject(found); Marshal.FinalReleaseComObject(scheduler); }
    }
    public static void Write(TweakControlRead before, JsonElement desired)
    {
        var target = Target(before.Address);
        if (before.Address.Target == "system") OperationsFolder.Ensure(Path.GetDirectoryName(target.Root)!);
        Directory.CreateDirectory(target.Root);
        if (before.Address.Target == "system") OperationsFolder.RequireControlFolder(target.Root);
        using var guard = OperationFiles.Lock(Path.Combine(target.Root, "startup"));
        if (!Read(before.Address).Same(before)) throw new InvalidDataException("Timer startup state changed after review.");
        var scheduler = ConnectScheduler(); dynamic service = scheduler; object? found = null;
        try
        {
            found = Find(scheduler, target.Name);
            void RemoveOwned()
            {
                var existingReceipt = Receipt(target.Root, target.Name); var existingScript = Path.Combine(target.Root, "startup.ps1");
                if (File.Exists(existingScript) && (existingReceipt is null || OperationFiles.HashFile(existingScript) != existingReceipt.ScriptHash)) throw new InvalidDataException("The startup script has outside changes and was retained.");
                if (found is not null) { service.GetFolder(@"\").DeleteTask(target.Name, 0); Marshal.FinalReleaseComObject(found); found = null; }
                var retained = Find(scheduler, target.Name);
                if (retained is not null) { Marshal.FinalReleaseComObject(retained); throw new IOException("The owned startup task remains after removal."); }
                File.Delete(existingScript); File.Delete(ReceiptPath(target.Root));
            }
            if (!desired.GetBoolean()) { RemoveOwned(); return; }
            var (assembly, dotnet, bundled) = StartupLauncher();
            var script = StartupScript(assembly, dotnet, bundled, target.Root);
            var scriptPath = Path.Combine(target.Root, "startup.ps1");
            if (found is not null)
            {
                if (File.ReadAllBytes(scriptPath).AsSpan().SequenceEqual(new UTF8Encoding(false).GetBytes(script))) { ((dynamic)found).Enabled = true; return; }
                RemoveOwned();
            }
            if (File.Exists(scriptPath))
            {
                var leftover = Receipt(target.Root, target.Name);
                if (leftover is null || leftover.Owner.UserSid != OperationOwner.Current().UserSid || leftover.Owner.Machine != Environment.MachineName || OperationFiles.HashFile(scriptPath) != leftover.ScriptHash)
                    throw new IOException("A timer startup script already exists without an active owned task. Review its retained state before replacing it.");
                File.Delete(scriptPath); File.Delete(ReceiptPath(target.Root));
            }
            var receipt = new TimerStartupReceipt(OperationOwner.Current(), target.Name, "creating", "", OperationFiles.Hash(Encoding.UTF8.GetBytes(script)));
            OperationFiles.Write(ReceiptPath(target.Root), receipt);
            using (var output = new FileStream(scriptPath, FileMode.CreateNew, FileAccess.Write, FileShare.None)) output.Write(new UTF8Encoding(false).GetBytes(script));
            dynamic definition = service.NewTask(0);
            try
            {
                definition.RegistrationInfo.Description = "Roo Industries timer request at Windows sign-in";
                definition.Principal.UserId = receipt.Owner.UserSid; definition.Principal.LogonType = 3; definition.Principal.RunLevel = 0;
                definition.Settings.Enabled = true; definition.Settings.ExecutionTimeLimit = "PT0S"; definition.Settings.MultipleInstances = 2;
                definition.Settings.DisallowStartIfOnBatteries = false; definition.Settings.StopIfGoingOnBatteries = false; definition.Settings.StartWhenAvailable = true;
                dynamic trigger = definition.Triggers.Create(9); trigger.UserId = receipt.Owner.UserSid;
                dynamic action = definition.Actions.Create(0);
                var system = Environment.GetFolderPath(Environment.SpecialFolder.System);
                action.Path = Path.Combine(system, "conhost.exe");
                action.Arguments = "--headless \"" + Path.Combine(system, @"WindowsPowerShell\v1.0\powershell.exe") + "\" -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File \"" + scriptPath + "\"";
                object created = service.GetFolder(@"\").RegisterTaskDefinition(target.Name, definition, 2, receipt.Owner.UserSid, null, 3, null);
                try { OperationFiles.Write(ReceiptPath(target.Root), receipt with { Phase = "created", DefinitionHash = Fingerprint(created) }); }
                finally { Marshal.FinalReleaseComObject(created); }
            }
            finally { Marshal.FinalReleaseComObject(definition); }
        }
        finally { if (found is not null) Marshal.FinalReleaseComObject(found); Marshal.FinalReleaseComObject(scheduler); }
    }
    private static (string Assembly, string DotNet, bool Bundled) StartupLauncher()
    {
        var assembly = Assembly.GetEntryAssembly()?.Location ?? throw new InvalidDataException("The timer startup helper assembly is missing.");
        var dotnet = Environment.ProcessPath!;
        var bundled = Path.GetFileNameWithoutExtension(dotnet).Equals(Path.GetFileNameWithoutExtension(assembly), StringComparison.OrdinalIgnoreCase) && File.Exists(Path.Combine(Path.GetDirectoryName(assembly)!, "hostpolicy.dll"));
        if (!bundled && !Path.GetFileNameWithoutExtension(dotnet).Equals("dotnet", StringComparison.OrdinalIgnoreCase)) dotnet = Path.Combine(Environment.GetEnvironmentVariable("DOTNET_ROOT") ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".dotnet"), "dotnet.exe");
        if (!File.Exists(dotnet)) throw new FileNotFoundException("Install the .NET runtime or provide DOTNET_ROOT before configuring timer startup.", dotnet);
        return (assembly, dotnet, bundled);
    }
    public static string RefreshInstalled()
    {
        if (!PolicyRootSecurity.Elevated()) throw new UnauthorizedAccessException(OperationsFolder.NotAdministrator);
        var address = new ControlAddress("timer-startup", "system", "enabled");
        var target = Target(address);
        if (!File.Exists(ReceiptPath(target.Root))) return "timer startup is not set up";
        var before = Read(address);
        if (!before.Value.GetBoolean()) return "timer startup is off";
        var (assembly, dotnet, bundled) = StartupLauncher();
        if (File.ReadAllBytes(Path.Combine(target.Root, "startup.ps1")).AsSpan().SequenceEqual(new UTF8Encoding(false).GetBytes(StartupScript(assembly, dotnet, bundled, target.Root)))) return "timer startup is current";
        using (var on = JsonDocument.Parse("true")) Write(before, on.RootElement);
        return "refreshed: timer startup " + target.Name;
    }
    public static void RequireOwned(string root)
    {
        var address = new ControlAddress("timer-startup", TimerControl.IsSystemControl(root) ? "system" : "fixture:" + root, "enabled");
        if (!Read(address).Value.GetBoolean()) throw new InvalidDataException("An owned enabled startup task is required to start this timer session.");
    }
}
