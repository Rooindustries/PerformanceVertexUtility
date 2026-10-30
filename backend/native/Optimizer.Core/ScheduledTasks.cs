#nullable enable
using System.Reflection;
using System.Runtime.InteropServices;

namespace RooIndustries.Optimizer;

internal static class ScheduledTasks
{
    // True when the task exists in Task Scheduler's root folder, false when Task Scheduler says it doesn't, null when it couldn't be read.
    public static bool? Registered(string name)
    {
        object? scheduler = null, folder = null, task = null;
        try
        {
            scheduler = Activator.CreateInstance(Type.GetTypeFromProgID("Schedule.Service", true)!)!;
            Call(scheduler, "Connect");
            folder = Call(scheduler, "GetFolder", @"\")!;
            task = Call(folder, "GetTask", name);
            return task is not null;
        }
        catch (Exception error) when (error is FileNotFoundException or DirectoryNotFoundException || error is COMException { HResult: unchecked((int)0x80070002) or unchecked((int)0x80070003) }) { return false; }
        catch (Exception error) when (error is COMException or UnauthorizedAccessException or PlatformNotSupportedException or TypeLoadException) { return null; }
        finally { foreach (var item in new[] { task, folder, scheduler }) if (item is not null && Marshal.IsComObject(item)) Marshal.FinalReleaseComObject(item); }
    }

    private static object? Call(object target, string member, params object[] arguments)
    {
        try { return target.GetType().InvokeMember(member, BindingFlags.InvokeMethod | BindingFlags.Public | BindingFlags.Instance, null, target, arguments); }
        catch (TargetInvocationException error) when (error.InnerException is { } inner) { throw inner; }
    }
}
