#nullable enable
using System.Diagnostics;

namespace Roo.Optimizer;

internal static class ProcessNames
{
    public static Dictionary<string, List<int>> Find(IEnumerable<string> names)
    {
        var found = names.Distinct(StringComparer.OrdinalIgnoreCase).ToDictionary(name => name, _ => new List<int>(), StringComparer.OrdinalIgnoreCase);
        if (found.Count == 0) return found;
        var processes = found.Count == 1 ? Process.GetProcessesByName(found.Keys.Single()) : Process.GetProcesses();
        foreach (var process in processes)
        {
            using (process)
                if (found.TryGetValue(process.ProcessName, out var matches)) matches.Add(process.Id);
        }
        return found;
    }
}
