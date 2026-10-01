#nullable enable
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Xml.Linq;

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
        dynamic scheduler = Activator.CreateInstance(Type.GetTypeFromProgID("Schedule.Service", true)!)!;
        try { scheduler.Connect(); return scheduler; }
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
        dynamic service = scheduler;
        try { return service.GetFolder(@"\").GetTask(name); }
        catch (FileNotFoundException) { return null; }
        catch (COMException error) when (error.HResult == unchecked((int)0x80070002)) { return null; }
    }
    private static string Fingerprint(object registered)
    {
        dynamic task = registered;
        var xml = XDocument.Parse((string)task.Xml); var ns = xml.Root!.Name.Namespace;
        xml.Root.Element(ns + "Settings")?.Element(ns + "Enabled")?.Remove();
        return OperationFiles.Hash(Encoding.UTF8.GetBytes(xml.ToString(SaveOptions.DisableFormatting) + "\n" + (string)task.GetSecurityDescriptor(7)));
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
            if (!desired.GetBoolean())
            {
                var existingReceipt = Receipt(target.Root, target.Name); var existingScript = Path.Combine(target.Root, "startup.ps1");
                if (File.Exists(existingScript) && (existingReceipt is null || OperationFiles.HashFile(existingScript) != existingReceipt.ScriptHash)) throw new InvalidDataException("The startup script has outside changes and was retained.");
                if (found is not null) service.GetFolder(@"\").DeleteTask(target.Name, 0);
                var retained = Find(scheduler, target.Name);
                if (retained is not null) { Marshal.FinalReleaseComObject(retained); throw new IOException("The owned startup task remains after removal."); }
                File.Delete(ReceiptPath(target.Root)); File.Delete(existingScript); return;
            }
            if (found is not null) { ((dynamic)found).Enabled = true; return; }
            var assembly = Assembly.GetEntryAssembly()?.Location ?? throw new InvalidDataException("The timer startup helper assembly is missing.");
            var dotnet = Environment.ProcessPath!;
            var bundled = Path.GetFileNameWithoutExtension(dotnet).Equals(Path.GetFileNameWithoutExtension(assembly), StringComparison.OrdinalIgnoreCase) && File.Exists(Path.Combine(Path.GetDirectoryName(assembly)!, "hostpolicy.dll"));
            if (!bundled && !Path.GetFileNameWithoutExtension(dotnet).Equals("dotnet", StringComparison.OrdinalIgnoreCase)) dotnet = Path.Combine(Environment.GetEnvironmentVariable("DOTNET_ROOT") ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".dotnet"), "dotnet.exe");
            if (!File.Exists(dotnet)) throw new FileNotFoundException("Install the .NET runtime or provide DOTNET_ROOT before configuring timer startup.", dotnet);
            var script = StartupScript(assembly, dotnet, bundled, target.Root);
            var scriptPath = Path.Combine(target.Root, "startup.ps1");
            if (File.Exists(scriptPath)) throw new IOException("A timer startup script already exists without an active owned task. Review its retained state before replacing it.");
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
    public static void RequireOwned(string root)
    {
        var address = new ControlAddress("timer-startup", TimerControl.IsSystemControl(root) ? "system" : "fixture:" + root, "enabled");
        if (!Read(address).Value.GetBoolean()) throw new InvalidDataException("An owned enabled startup task is required to start this timer session.");
    }
}
