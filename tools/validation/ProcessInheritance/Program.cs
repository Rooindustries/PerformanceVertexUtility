using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text.Json;
using Microsoft.Win32.SafeHandles;
using Roo.Optimizer;

try
{
    if (args is ["--launcher", var directory, var eventName]) { Fixture.Launcher(directory, eventName); return; }
    if (args is ["--child", var resultPath, var childEvent, var restricted]) { Fixture.Child(resultPath, childEvent, bool.Parse(restricted)); return; }
    if (args.Length != 0) throw new ArgumentException("Unknown inheritance fixture mode.");
    Fixture.CheckInheritance();
}
catch (Exception error) { Console.Error.WriteLine(error); Environment.ExitCode = 1; }

sealed record ChildState(RunningProcess Identity, ulong Affinity, bool ControlDenied);

static class Fixture
{
    public static void CheckInheritance()
    {
        var root = Path.Combine(Path.GetTempPath(), "roo-inheritance-" + Guid.NewGuid().ToString("N"));
        var eventName = "Local\\RooInheritance-" + Guid.NewGuid().ToString("N");
        using var exit = new EventWaitHandle(false, EventResetMode.ManualReset, eventName);
        Directory.CreateDirectory(root);
        using var launcher = Start("--launcher", root, eventName);
        try
        {
            WaitFor(Path.Combine(root, "launcher-ready.json"), launcher);
            var original = Affinity.Read(launcher.Id);
            var choices = Enumerable.Range(0, 64).Where(index => (original & (1ul << index)) != 0).ToArray();
            if (choices.Length < 2) throw new InvalidOperationException("The inheritance fixture needs at least two available logical processors.");
            var selected = 1ul << choices[0];
            ChildState Launch(int index, bool denyControl)
            {
                OperationFiles.Write(Path.Combine(root, "request-" + index + ".json"), denyControl);
                var result = Path.Combine(root, "child-" + index + ".json");
                WaitFor(result, launcher);
                return OperationFiles.Read<ChildState>(result);
            }
            var baseline = Launch(0, false);
            Check(baseline.Affinity == original && Affinity.Read(baseline.Identity.ProcessId) == original, "An untreated child inherits the launcher's original affinity");

            var engine = new ProcessControlEngine(identity => identity.ProcessId != launcher.Id);
            using var target = new ProcessTarget(launcher.Id);
            var current = target.Read("affinity").Require().Deserialize<AffinityState>(OperationFiles.Json)!;
            var preview = engine.Preview(launcher.Id, new() { ["affinity"] = JsonSerializer.SerializeToElement(new AffinityState(current.Group, "0x" + selected.ToString("X")), OperationFiles.Json) });
            var path = Path.Combine(root, "preview.json");
            var journal = Path.Combine(root, "journal.json");
            OperationFiles.Write(path, preview);
            Check(engine.Apply(path, OperationFiles.HashFile(path), journal).Status == "applied" && Affinity.Read(launcher.Id) == selected, "The reviewed launcher affinity reaches Windows before child creation");

            var child = Launch(1, true);
            Check(child.ControlDenied && child.Affinity == selected && Affinity.Read(child.Identity.ProcessId) == selected, "A child with denied control access inherits the selected launcher affinity");
            using (var readable = new ProcessTarget(child.Identity.ProcessId)) child.Identity.Verify(readable.Identity());
            var denied = false;
            try { using var blocked = new ProcessTarget(child.Identity.ProcessId, ["affinity"]); }
            catch (Roo.Optimization.CpuSets.NativeFailure error) when (error.Api == "OpenProcess" && error.NativeErrorCode == 5) { denied = true; }
            Check(denied && Affinity.Read(child.Identity.ProcessId) == selected, "The real control adapter preserves access denial without a privilege retry");

            Check(engine.Restore(journal).Status == "restored" && Affinity.Read(launcher.Id) == original, "The launcher restores its original affinity");
            Check(Affinity.Read(child.Identity.ProcessId) == selected, "Restoring a launcher does not pretend to reset an already running child's inherited affinity");
            var after = Launch(2, false);
            Check(after.Affinity == original && Affinity.Read(after.Identity.ProcessId) == original, "A later child inherits the restored launcher affinity");
        }
        finally
        {
            exit.Set();
            if (!launcher.WaitForExit(10000)) { launcher.Kill(); launcher.WaitForExit(); }
            Directory.Delete(root, true);
        }
        Check(launcher.ExitCode == 0 && !Directory.Exists(root), "All owned launcher/child processes and operation files are cleaned up");
    }

    public static void Launcher(string root, string eventName)
    {
        using var exit = EventWaitHandle.OpenExisting(eventName);
        var children = new List<Process>();
        try
        {
            OperationFiles.Write(Path.Combine(root, "launcher-ready.json"), Environment.ProcessId);
            for (var index = 0; !exit.WaitOne(0);)
            {
                var path = Path.Combine(root, "request-" + index + ".json");
                if (!File.Exists(path)) { Thread.Sleep(20); continue; }
                var restricted = OperationFiles.Read<bool>(path);
                children.Add(Start("--child", Path.Combine(root, "child-" + index + ".json"), eventName, restricted.ToString()));
                index++;
            }
        }
        finally
        {
            var failures = new List<Exception>();
            foreach (var child in children)
            {
                try
                {
                    using (child)
                    {
                        if (!child.WaitForExit(5000)) { child.Kill(); child.WaitForExit(); }
                        if (child.ExitCode != 0) throw new InvalidOperationException("Inheritance child failed: " + child.StandardError.ReadToEnd());
                    }
                }
                catch (Exception error) { failures.Add(error); }
            }
            if (failures.Count != 0) throw new AggregateException("Inheritance fixture shutdown was incomplete.", failures);
        }
    }

    public static void Child(string resultPath, string eventName, bool restricted)
    {
        using var exit = EventWaitHandle.OpenExisting(eventName);
        if (restricted) Affinity.DenyControlForCurrentProcess();
        using var target = new ProcessTarget(Environment.ProcessId);
        OperationFiles.Write(resultPath, new ChildState(target.Identity(), Affinity.Read(Environment.ProcessId), restricted));
        if (!exit.WaitOne(TimeSpan.FromMinutes(2))) throw new TimeoutException("Inheritance fixture was not released.");
    }

    static Process Start(params string[] arguments)
    {
        var start = new ProcessStartInfo(Environment.ProcessPath!) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardError = true };
        foreach (var argument in arguments) start.ArgumentList.Add(argument);
        return Process.Start(start) ?? throw new InvalidOperationException("Inheritance fixture did not start.");
    }
    static void WaitFor(string path, Process launcher)
    {
        var clock = Stopwatch.StartNew();
        while (!File.Exists(path))
        {
            if (launcher.HasExited) throw new InvalidOperationException("Launcher exited early: " + launcher.StandardError.ReadToEnd());
            if (clock.Elapsed > TimeSpan.FromSeconds(10)) throw new TimeoutException("The inheritance fixture did not report readiness.");
            Thread.Sleep(20);
        }
    }
    static void Check(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
        Console.WriteLine("PASS " + message);
    }
}

static class Affinity
{
    public static ulong Read(int processId)
    {
        using var process = OpenProcess(0x1000, false, processId);
        if (process.IsInvalid || !GetProcessAffinityMask(process, out var current, out _)) throw new Win32Exception(Marshal.GetLastWin32Error());
        return current.ToUInt64();
    }
    public static void DenyControlForCurrentProcess()
    {
        using var identity = WindowsIdentity.GetCurrent();
        var user = identity.User ?? throw new InvalidOperationException("Current user SID unavailable.");
        var acl = new RawAcl(2, 2);
        acl.InsertAce(0, new CommonAce(AceFlags.None, AceQualifier.AccessDenied, 0x2200, user, false, null));
        acl.InsertAce(1, new CommonAce(AceFlags.None, AceQualifier.AccessAllowed, 0x1fffff, user, false, null));
        var descriptor = new RawSecurityDescriptor(ControlFlags.DiscretionaryAclPresent, user, null, null, acl);
        var bytes = new byte[descriptor.BinaryLength]; descriptor.GetBinaryForm(bytes, 0);
        if (!SetKernelObjectSecurity(new IntPtr(-1), 4, bytes)) throw new Win32Exception(Marshal.GetLastWin32Error(), "Fixture process DACL could not be set.");
    }
    [DllImport("kernel32.dll", SetLastError = true)] static extern SafeProcessHandle OpenProcess(uint access, bool inherit, int processId);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool GetProcessAffinityMask(SafeProcessHandle process, out UIntPtr current, out UIntPtr system);
    [DllImport("advapi32.dll", SetLastError = true)] static extern bool SetKernelObjectSecurity(IntPtr handle, uint information, byte[] descriptor);
}
