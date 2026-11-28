#nullable enable
using System.Diagnostics;
using System.Text.Json;

namespace RooIndustries.Optimizer;

public sealed partial class ProcessPolicyHost
{
    private static readonly JsonSerializerOptions CheckJson = new(OperationFiles.Json) { WriteIndented = false };
    private readonly Dictionary<string, TimeSpan> _launches = new(StringComparer.Ordinal);
    private long _checkStarted, _previousCheckStarted;

    private static TimeSpan ProcessorTime()
    {
        using var self = Process.GetCurrentProcess();
        return self.TotalProcessorTime;
    }

    private void Seen(SnapshotProcess running)
    {
        var key = Key(running);
        if (!_launches.ContainsKey(key)) _launches[key] = ProcessorTime();
    }

    private void LogCheck(RunningProcess identity, List<(string Field, string Key)> fields, List<string> applied)
    {
        var refused = new Dictionary<string, int>(StringComparer.Ordinal);
        foreach (var (field, key) in fields)
            if (_retries.TryGetValue(key, out var retry) && retry.Check == _checkStarted) refused[field] = retry.Attempt + 1;
        var check = new
        {
            identity.ProcessId,
            Created = identity.CreationTimeFileTimeUtc,
            CheckStarted = _checkStarted,
            PreviousCheckStarted = _previousCheckStarted,
            Applied = applied,
            Refused = refused,
            ProcessorSeconds = (ProcessorTime() - _launches[Key(identity)]).TotalSeconds,
        };
        GovernorLog.Write(_store.Root, "Checked a matching process: " + JsonSerializer.Serialize(check, CheckJson));
    }
}
