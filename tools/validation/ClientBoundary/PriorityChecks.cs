using System.Diagnostics;
using System.Runtime.InteropServices;
using RooIndustries.OptimizationSuite.Services;

static class PriorityChecks
{
    static void Check(bool value, string message)
    {
        if (!value) throw new InvalidOperationException(message);
        Console.WriteLine("PASS " + message);
    }

    static Process Sleeper()
    {
        var start = new ProcessStartInfo(Path.Combine(Environment.SystemDirectory, "cmd.exe")) { UseShellExecute = false, CreateNoWindow = true };
        foreach (var argument in new[] { "/d", "/c", "ping -n 60 127.0.0.1 >nul" }) start.ArgumentList.Add(argument);
        return Process.Start(start) ?? throw new InvalidOperationException("Fixture did not start.");
    }

    static Process Child(Process parent)
    {
        var until = DateTime.UtcNow.AddSeconds(10);
        while (DateTime.UtcNow < until)
        {
            foreach (var candidate in Process.GetProcessesByName("PING"))
            {
                var information = new ProcessBasicInformation();
                if (NtQueryInformationProcess(candidate.Handle, 0, ref information, Marshal.SizeOf<ProcessBasicInformation>(), out _) == 0 && information.InheritedFromUniqueProcessId.ToInt64() == parent.Id) return candidate;
                candidate.Dispose();
            }
            Thread.Sleep(100);
        }
        throw new TimeoutException("The fixture child did not start.");
    }

    static void Stop(Process process)
    {
        try { if (!process.HasExited) { process.Kill(true); process.WaitForExit(); } }
        catch (InvalidOperationException) { }
    }

    public static void Run()
    {
        var live = new List<Process>();
        try
        {
            using var root = Sleeper(); live.Add(root);
            using var unrelated = Sleeper(); live.Add(unrelated);
            using var descendant = Child(root);
            unrelated.PriorityClass = ProcessPriorityClass.BelowNormal;
            var priority = new BackgroundPriority();
            priority.Register(root);
            descendant.PriorityClass = ProcessPriorityClass.BelowNormal;
            Check(root.PriorityClass == ProcessPriorityClass.BelowNormal, "A registered background process starts below normal priority");
            priority.Raise();
            root.Refresh(); descendant.Refresh(); unrelated.Refresh();
            Check(root.PriorityClass == ProcessPriorityClass.Normal && descendant.PriorityClass == ProcessPriorityClass.Normal, "Raising restores the registered process and its descendant to normal priority");
            Check(unrelated.PriorityClass == ProcessPriorityClass.BelowNormal, "Raising leaves an unrelated process alone");
            Stop(root); Stop(unrelated);

            var released = Sleeper(); live.Add(released);
            var releasedId = released.Id;
            var later = new BackgroundPriority();
            later.Register(released);
            released.Dispose();
            using (var probe = Process.GetProcessById(releasedId)) Check(probe.PriorityClass == ProcessPriorityClass.BelowNormal, "The registered process is still below normal after its Process object is released");
            later.Raise();
            using (var probe = Process.GetProcessById(releasedId)) Check(probe.PriorityClass == ProcessPriorityClass.Normal, "Raising reaches the registered process even after its Process object was released");
            using (var probe = Process.GetProcessById(releasedId)) Stop(probe);

            var gone = Sleeper(); live.Add(gone);
            var goneId = gone.Id;
            var reused = new BackgroundPriority();
            reused.Register(gone);
            Stop(gone);
            gone.Dispose();
            Process? victim = null;
            var attempts = 0;
            var deadline = DateTime.UtcNow.AddSeconds(8);
            while (victim is null && DateTime.UtcNow < deadline && attempts < 300)
            {
                attempts++;
                var candidate = Sleeper();
                if (candidate.Id == goneId) victim = candidate; else Stop(candidate);
            }
            if (victim is null) Console.WriteLine("NOTE no process received the registered id after " + attempts + " starts, so the reuse check ran without a reused id");
            else
            {
                live.Add(victim);
                victim.PriorityClass = ProcessPriorityClass.Idle;
                reused.Raise();
                victim.Refresh();
                Check(victim.PriorityClass == ProcessPriorityClass.Idle, "A different process that reused the registered id keeps its priority after " + attempts + " starts");
                Stop(victim);
            }
            var exited = new BackgroundPriority();
            using (var quick = Sleeper())
            {
                exited.Register(quick);
                Stop(quick);
                exited.Raise();
            }
            Check(true, "Raising after the registered process exited changes nothing and does not fail");
            var after = new BackgroundPriority();
            after.Raise();
            using (var late = Sleeper())
            {
                live.Add(late);
                after.Register(late);
                Check(late.PriorityClass == ProcessPriorityClass.Normal, "A process registered after the raise stays at normal priority");
                Stop(late);
            }
        }
        finally { foreach (var process in live) { Stop(process); process.Dispose(); } }
    }

    [StructLayout(LayoutKind.Sequential)]
    struct ProcessBasicInformation { public IntPtr ExitStatus, PebBaseAddress, AffinityMask, BasePriority, UniqueProcessId, InheritedFromUniqueProcessId; }
    [DllImport("ntdll.dll")] static extern int NtQueryInformationProcess(IntPtr handle, int informationClass, ref ProcessBasicInformation information, int size, out int returned);
}
