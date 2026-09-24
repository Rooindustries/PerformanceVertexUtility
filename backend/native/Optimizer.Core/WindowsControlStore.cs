#nullable enable
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Xml.Linq;
using Microsoft.Win32.SafeHandles;

namespace RooIndustries.Optimizer;

public sealed class WindowsControlStore : IControlStore
{
    public TweakControlRead Read(ControlAddress address)
    {
        address.Validate();
        return address.Kind switch
        {
            "service" => ServiceControls.Read(address),
            "mitigations" => MitigationControl.Read(address),
            "windows-features" => WindowsFeatures.Read(address),
            "hibernation" => HibernationControl.Read(address),
            "file-acl" or "file-ownership" => FileAccessControl.Read(address),
            "download-blocker" => DownloadBlocker.Read(address),
            "hosts" => HostsControl.Read(address),
            "timer" => TimerControl.Read(address),
            "timer-startup" => TimerStartupControl.Read(address),
            "power-plan" => PowerPlanControl.Read(address),
            "scheduled-task" => TaskRead(address),
            _ => PowerShellControls.Read(address),
        };
    }
    public void Write(TweakControlRead before, JsonElement after)
    {
        if (!Read(before.Address).Same(before)) throw new InvalidDataException("Windows control changed before execution: " + before.Address.Target);
        switch (before.Address.Kind)
        {
            case "service": ServiceControls.Write(before.Address, after); break;
            case "mitigations": MitigationControl.Write(before, after); break;
            case "windows-features": WindowsFeatures.Write(before, after); break;
            case "hibernation": HibernationControl.Write(before, after); break;
            case "file-acl": case "file-ownership": FileAccessControl.Write(before, after); break;
            case "download-blocker": DownloadBlocker.Write(before, after); break;
            case "hosts": HostsControl.Write(before, after); break;
            case "timer": TimerControl.Write(before, after); break;
            case "timer-startup": TimerStartupControl.Write(before, after); break;
            case "power-plan": PowerPlanControl.Write(before, after); break;
            case "scheduled-task":
                dynamic scheduler = ConnectTasks();
                try { scheduler.GetFolder(@"\").GetTask(before.Address.Target).Enabled = after.GetBoolean(); }
                finally { Marshal.FinalReleaseComObject(scheduler); }
                break;
            default: PowerShellControls.Write(before, after); break;
        }
    }
    private static object ConnectTasks()
    {
        dynamic scheduler = Activator.CreateInstance(Type.GetTypeFromProgID("Schedule.Service", true)!)!;
        try { scheduler.Connect(); return scheduler; }
        catch { Marshal.FinalReleaseComObject(scheduler); throw; }
    }
    private static TweakControlRead TaskRead(ControlAddress address)
    {
        if (address.Property != "enabled" || !address.Target.StartsWith('\\') || address.Target.IndexOfAny(['*', '?']) >= 0)
            throw new InvalidDataException("Task control requires an exact path and enabled property.");
        dynamic scheduler = ConnectTasks();
        try
        {
            dynamic task = scheduler.GetFolder(@"\").GetTask(address.Target);
            var xml = XDocument.Parse((string)task.Xml);
            var ns = xml.Root!.Name.Namespace;
            xml.Root.Element(ns + "Settings")?.Element(ns + "Enabled")?.Remove();
            var identity = "scheduled-task:" + ((string)task.Path).ToUpperInvariant();
            return new(address, identity, OperationFiles.Hash(System.Text.Encoding.UTF8.GetBytes(xml.ToString(SaveOptions.DisableFormatting) + "\n" + (string)task.GetSecurityDescriptor(7))), ControlValues.From((bool)task.Enabled));
        }
        finally { Marshal.FinalReleaseComObject(scheduler); }
    }
}

static class ServiceControls
{
    private const uint Unchanged = uint.MaxValue;
    public static TweakControlRead Read(ControlAddress address)
    {
        using var manager = Manager(); using var service = Open(manager, address.Target, 1 | 4);
        QueryServiceConfig(service, IntPtr.Zero, 0, out var needed);
        if (needed == 0) Error("QueryServiceConfig(size)");
        var memory = Marshal.AllocHGlobal(checked((int)needed));
        try
        {
            Check(QueryServiceConfig(service, memory, needed, out _), "QueryServiceConfig");
            var config = Marshal.PtrToStructure<ServiceConfig>(memory);
            var binding = OperationFiles.Hash(JsonSerializer.SerializeToUtf8Bytes(new { config.Type, Binary = Marshal.PtrToStringUni(config.Binary), Account = Marshal.PtrToStringUni(config.Account) }));
            JsonElement value;
            switch (address.Property)
            {
                case "startup": value = ControlValues.From(config.Start); break;
                case "delayed-start":
                    Check(QueryServiceConfig2(service, 3, memory, needed, out _), "QueryServiceConfig2(delayed start)");
                    value = ControlValues.From(Marshal.ReadInt32(memory) != 0); break;
                case "running":
                    if ((config.Type & 3) != 0) throw new InvalidDataException("This is a Windows driver. It cannot be started or stopped while Windows is running: " + address.Target);
                    Check(QueryServiceStatus(service, out var status), "QueryServiceStatus");
                    if (status.State is not (1 or 4)) throw new InvalidDataException("The service is transitioning. Try again after it settles: " + address.Target);
                    value = ControlValues.From(status.State == 4); break;
                default: throw new InvalidDataException("Unknown service setting: " + address.Property);
            }
            var allowed = address.Property == "startup" ? ((config.Type & 3) != 0 ? new uint[] { 0, 1, 2, 3, 4 } : new uint[] { 2, 3, 4 }).Select(ControlValues.From).ToArray() : null;
            if (allowed is not null && !allowed.Any(choice => ControlValues.Equal(choice, value))) throw new InvalidDataException("The service has a startup value that its service type cannot restore through Windows APIs.");
            return new(address, "service:" + address.Target.ToUpperInvariant() + ":" + address.Property, binding, value,
                Marshal.PtrToStringUni(config.DisplayName) + ": " + address.Property.Replace('-', ' '), allowed);
        }
        finally { Marshal.FreeHGlobal(memory); }
    }
    public static void Write(ControlAddress address, JsonElement value)
    {
        using var manager = Manager(); using var service = Open(manager, address.Target, 1 | 2 | 4 | 16 | 32);
        switch (address.Property)
        {
            case "startup":
                var start = value.GetUInt32();
                if (start > 4) throw new InvalidDataException("Invalid service startup type.");
                Check(ChangeServiceConfig(service, Unchanged, start, Unchanged, null, null, IntPtr.Zero, null, null, null, null), "ChangeServiceConfig(startup)"); break;
            case "delayed-start":
                var delayed = value.GetBoolean() ? 1 : 0;
                Check(ChangeServiceConfig2(service, 3, ref delayed), "ChangeServiceConfig2(delayed start)"); break;
            case "running":
                var running = value.GetBoolean();
                var accepted = running ? StartService(service, 0, IntPtr.Zero) : ControlService(service, 1, out _);
                var code = Marshal.GetLastWin32Error();
                if (!accepted)
                {
                    Check(QueryServiceStatus(service, out var current), "QueryServiceStatus(after control)");
                    if (current.State != (running ? 4u : 1u) && current.State != (running ? 2u : 3u))
                        throw new Win32Exception(code, (running ? "StartService" : "ControlService(stop)") + " failed (Win32 " + code + ").");
                }
                var timeout = Stopwatch.StartNew();
                while (true)
                {
                    Check(QueryServiceStatus(service, out var status), "QueryServiceStatus");
                    if (status.State == (running ? 4u : 1u)) break;
                    if (timeout.Elapsed > TimeSpan.FromSeconds(20)) throw new IOException("The service did not reach its requested state within 20 seconds: " + address.Target);
                    Thread.Sleep(100);
                }
                break;
            default: throw new InvalidDataException("Unknown service setting.");
        }
    }
    private static ServiceHandle Manager()
    {
        var handle = OpenSCManager(null, null, 1); if (handle.IsInvalid) Error("OpenSCManager"); return handle;
    }
    private static ServiceHandle Open(ServiceHandle manager, string name, uint access)
    {
        if (string.IsNullOrWhiteSpace(name) || name.IndexOfAny(['\\', '/', '*', '?', '\0']) >= 0) throw new InvalidDataException("An exact service name is required.");
        var handle = OpenService(manager, name, access); if (handle.IsInvalid) Error("OpenService(" + name + ")"); return handle;
    }
    private static void Check(bool result, string operation) { if (!result) Error(operation); }
    private static void Error(string operation) { var code = Marshal.GetLastWin32Error(); throw new Win32Exception(code, operation + " failed (Win32 " + code + ")."); }
    [StructLayout(LayoutKind.Sequential)] private struct ServiceConfig { public uint Type, Start, Error; public IntPtr Binary, Group; public uint Tag; public IntPtr Dependencies, Account, DisplayName; }
    [StructLayout(LayoutKind.Sequential)] private struct ServiceStatus { public uint Type, State, Accepted, Win32Exit, ServiceExit, Checkpoint, WaitHint; }
    private sealed class ServiceHandle : SafeHandleZeroOrMinusOneIsInvalid
    {
        public ServiceHandle() : base(true) { }
        protected override bool ReleaseHandle() => CloseServiceHandle(handle);
    }
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern ServiceHandle OpenSCManager(string? machine, string? database, uint access);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern ServiceHandle OpenService(ServiceHandle manager, string name, uint access);
    [DllImport("advapi32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool CloseServiceHandle(IntPtr service);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool QueryServiceConfig(ServiceHandle service, IntPtr config, uint size, out uint needed);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool QueryServiceConfig2(ServiceHandle service, uint level, IntPtr config, uint size, out uint needed);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool ChangeServiceConfig(ServiceHandle service, uint type, uint start, uint error, string? binary, string? group, IntPtr tag, string? dependencies, string? account, string? password, string? displayName);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool ChangeServiceConfig2(ServiceHandle service, uint level, ref int value);
    [DllImport("advapi32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool QueryServiceStatus(ServiceHandle service, out ServiceStatus status);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool StartService(ServiceHandle service, uint count, IntPtr arguments);
    [DllImport("advapi32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool ControlService(ServiceHandle service, uint control, out ServiceStatus status);
}
