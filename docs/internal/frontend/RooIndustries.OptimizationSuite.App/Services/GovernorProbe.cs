using System;
using System.Collections;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using System.Text.Json;
using System.Xml.Linq;
using RooIndustries.Optimizer;
using static RooIndustries.OptimizationSuite.Services.TaskStart;

namespace RooIndustries.OptimizationSuite.Services;

public enum TaskStart { Promises, Failed, Unconfirmed }

public sealed record GovernorTaskState(string Name, bool Registered, bool Enabled, bool RestartsEveryMinute, int LastResult = 0x00041303, bool WorkerRunning = false)
{
    public bool LastStartFailed => GovernorProbe.StartOf(LastResult, WorkerRunning) == Failed;
    public bool Restarts => Registered && Enabled && RestartsEveryMinute && GovernorProbe.StartOf(LastResult, WorkerRunning) == Promises;
}

public sealed record GovernorTaskFacts(string Name, string Xml, bool Enabled, int LastResult);

public sealed record GovernorTaskExpectation(string OwnerSid, string SystemDirectory, string InstallRoot, string PolicyRoot);

public static class GovernorProbe
{
    public const string TaskPrefix = "RooIndustriesOptimizationSuite.ProcessRules.";
    public const string LegacyTaskPrefix = BrandCompatibility.LegacyPolicyTaskPrefix;
    public const string TaskDescription = "Roo Industries process rules | ";
    public const string LegacyTaskDescription = BrandCompatibility.LegacyPolicyTaskDescription;

    private static readonly (string Meaning, uint From, uint To, TaskStart Stopped, TaskStart Running)[] StartResults =
    [
        ("exit code 0: the worker exited cleanly, which a stopped worker with no live process cannot be told apart from a launcher that did nothing", 0x00000000, 0x00000000, Unconfirmed, Promises),
        ("SCHED_S_TASK_READY, SCHED_S_TASK_RUNNING, SCHED_S_TASK_DISABLED, SCHED_S_TASK_HAS_NOT_RUN", 0x00041300, 0x00041303, Promises, Promises),
        ("SCHED_S_TASK_NO_MORE_RUNS, SCHED_S_TASK_NOT_SCHEDULED", 0x00041304, 0x00041305, Unconfirmed, Unconfirmed),
        ("SCHED_S_TASK_TERMINATED", 0x00041306, 0x00041306, Promises, Promises),
        ("SCHED_S_TASK_NO_VALID_TRIGGERS", 0x00041307, 0x00041307, Unconfirmed, Unconfirmed),
        ("SCHED_S_EVENT_TRIGGER", 0x00041308, 0x00041308, Promises, Promises),
        ("SCHED_S_SOME_TRIGGERS_FAILED, SCHED_S_BATCH_LOGON_PROBLEM", 0x0004131B, 0x0004131C, Unconfirmed, Unconfirmed),
        ("SCHED_S_TASK_QUEUED", 0x00041325, 0x00041325, Promises, Promises),
        ("SCHED_E_TASK_NOT_RUNNING", 0x8004130B, 0x8004130B, Unconfirmed, Unconfirmed),
        ("SCHED_E_ALREADY_RUNNING, a launch ignored by IgnoreNew", 0x8004131F, 0x8004131F, Promises, Promises),
        ("SCHED_E_TASK_ATTEMPTED", 0x80041324, 0x80041324, Unconfirmed, Unconfirmed),
        ("ERROR_REQUEST_REFUSED, a launch ignored while an instance runs", 0x800710E0, 0x800710E0, Promises, Promises),
    ];

    public static TaskStart StartOf(int lastResult, bool workerRunning = false)
    {
        var code = unchecked((uint)lastResult);
        foreach (var (_, from, to, stopped, running) in StartResults)
            if (code >= from && code <= to) return workerRunning ? running : stopped;
        return Failed;
    }

    private static readonly object TaskLock = new();
    private static (string Key, long At, GovernorTaskState? State)? _task;
    private static long _generation;
    private const long TaskAge = 30000;

    public static GovernorTaskState? Cached(string key, long now, Func<GovernorTaskState?> read)
    {
        long generation;
        lock (TaskLock)
        {
            if (_task is { } known && known.Key == key && now - known.At >= 0 && now - known.At < TaskAge) return known.State;
            generation = _generation;
        }
        var state = read();
        lock (TaskLock)
            if (generation == _generation) _task = (key, now, state);
        return state;
    }

    public static void ForgetTask()
    {
        lock (TaskLock)
        {
            _task = null;
            _generation++;
        }
    }

    public static string Key(RunningProcess process) => process.ProcessId + "|" + process.CreationTimeFileTimeUtc;

    public static GovernorSnapshot Read(string policyRoot, string? installRoot = null)
    {
        var store = new ProcessPolicyStore(policyRoot);
        var summary = store.Summary(deep: false);
        PolicyWorkerStatus worker;
        try { worker = store.Status(); }
        catch (Exception error) { worker = new(null, null, error.Message); }
        SavedProcessRule[] rules = [];
        if (summary.RulesError is null)
        {
            try { rules = store.ReadRules(null, []).Select(pair => pair.Rule).ToArray(); }
            catch (Exception error) { summary = summary with { RulesError = error.Message }; }
        }
        var open = worker.State?.Instances.Where(instance => instance.Status is "active" or "applying" or "conflict").ToArray() ?? [];
        var tracked = open.Concat(worker.State?.Instances.Where(instance => instance.Status == "restored" && instance.ErrorKind == "leftAsSet") ?? []).ToArray();
        var journals = new Dictionary<string, ProcessControlJournal>(StringComparer.OrdinalIgnoreCase);
        foreach (var instance in tracked)
        {
            try { if (File.Exists(instance.JournalPath)) journals[instance.JournalPath] = OperationFiles.Read<ProcessControlJournal>(instance.JournalPath); }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
            catch (InvalidDataException) { }
            catch (JsonException) { }
        }
        var unapplied = open.Where(instance => instance.Status == "applying" && !File.Exists(instance.JournalPath)).Select(instance => instance.JournalPath)
            .ToHashSet(StringComparer.OrdinalIgnoreCase);
        GovernorTaskState? task = null;
        if (!summary.Paused && summary.EnabledRules > 0 && worker.HostRunning is { } alive)
            task = alive ? Cached(policyRoot + "|" + installRoot, Environment.TickCount64, () => ReadTask(policyRoot, installRoot, true)) : ReadTask(policyRoot, installRoot);
        var running = rules.Length > 0 || tracked.Length > 0 ? Running() : null;
        return new GovernorSnapshot(summary, worker, rules, journals, task, ExitedKeys(tracked.Select(instance => instance.Process), running), unapplied,
            running?.Values.Select(process => process.ImageName).ToHashSet(StringComparer.OrdinalIgnoreCase),
            running is null ? null : rules.Where(rule => rule.MatchMode == "path").Select(rule => rule.ExecutablePath).Distinct(StringComparer.OrdinalIgnoreCase)
                .ToDictionary(path => path, path => PathRunning(running, path), StringComparer.OrdinalIgnoreCase));
    }

    private static bool? PathRunning(Dictionary<int, SnapshotProcess> running, string executablePath)
    {
        var name = Path.GetFileName(executablePath);
        var unknown = false;
        foreach (var process in running.Values.Where(process => string.Equals(process.ImageName, name, StringComparison.OrdinalIgnoreCase)))
        {
            if (ProcessSnapshot.ImagePath(process.ProcessId) is not { } path) { unknown = true; continue; }
            if (string.Equals(path, executablePath, StringComparison.OrdinalIgnoreCase)) return true;
        }
        return unknown ? null : false;
    }

    private static Dictionary<int, SnapshotProcess>? Running()
    {
        try { return ProcessSnapshot.Take(); }
        catch (Exception) { return null; }
    }

    public static HashSet<string> ExitedKeys(IEnumerable<RunningProcess> processes) => ExitedKeys(processes, processes.Any() ? Running() : null);

    private static HashSet<string> ExitedKeys(IEnumerable<RunningProcess> processes, Dictionary<int, SnapshotProcess>? running)
    {
        var exited = new HashSet<string>(StringComparer.Ordinal);
        if (running is null) return exited;
        foreach (var process in processes.DistinctBy(Key))
            if (!running.TryGetValue(process.ProcessId, out var found) || found.CreationTimeFileTimeUtc != process.CreationTimeFileTimeUtc) exited.Add(Key(process));
        return exited;
    }

    public static string Suffix(string userSid, string policyRoot)
        => Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(userSid + "|" + Path.GetFullPath(policyRoot).ToUpperInvariant())))[..20];

    public static GovernorTaskState? ReadTask(string policyRoot, string? installRoot = null, bool workerRunning = false)
    {
        if (!OperatingSystem.IsWindows()) return null;
        var com = new List<object>();
        try
        {
            var sid = WindowsIdentity.GetCurrent().User?.Value;
            var type = Type.GetTypeFromProgID("Schedule.Service");
            if (sid is null || type is null) return null;
            var root = Path.GetFullPath(policyRoot);
            var suffix = Suffix(sid, root);
            var install = installRoot is null ? null : new GovernorTaskExpectation(sid, Environment.GetFolderPath(Environment.SpecialFolder.System), Path.GetFullPath(installRoot), root);
            string Expected(string name) => (name.StartsWith(TaskPrefix, StringComparison.Ordinal) ? TaskDescription : LegacyTaskDescription) + sid + " | " + root;
            var service = Activator.CreateInstance(type)!;
            com.Add(service);
            Call(service, "Connect");
            var folder = Call(service, "GetFolder", "\\")!;
            com.Add(folder);
            var found = new List<GovernorTaskFacts>();
            foreach (var name in new[] { TaskPrefix + suffix, LegacyTaskPrefix + suffix })
                if (Find(folder, name, com) is { } task && Describe(task, name, Expected(name)) is { } state) found.Add(state);
            if (found.Count == 0)
            {
                var tasks = Call(folder, "GetTasks", 1)!;
                com.Add(tasks);
                foreach (object task in (IEnumerable)tasks)
                {
                    com.Add(task);
                    var name = (string)Get(task, "Name")!;
                    if ((name.StartsWith(TaskPrefix, StringComparison.Ordinal) || name.StartsWith(LegacyTaskPrefix, StringComparison.Ordinal)) && Describe(task, name, Expected(name)) is { } state)
                        found.Add(state);
                }
            }
            return found.Count switch { 0 => new GovernorTaskState(TaskPrefix + suffix, false, false, false), 1 => State(found[0], install, DateTime.Now, workerRunning), _ => null };
        }
        catch (Exception) { return null; }
        finally
        {
            for (var index = com.Count - 1; index >= 0; index--)
                if (Marshal.IsComObject(com[index])) Marshal.FinalReleaseComObject(com[index]);
        }
    }

    private static object? Get(object target, string member) => Invoke(target, member, BindingFlags.GetProperty);

    private static object? Call(object target, string member, params object[] arguments) => Invoke(target, member, BindingFlags.InvokeMethod, arguments);

    private static object? Invoke(object target, string member, BindingFlags kind, params object[] arguments)
    {
        try { return target.GetType().InvokeMember(member, kind | BindingFlags.Public | BindingFlags.Instance, null, target, arguments); }
        catch (TargetInvocationException error) when (error.InnerException is { } inner) { throw inner; }
    }

    private static object? Find(object folder, string name, List<object> com)
    {
        try
        {
            var task = Call(folder, "GetTask", name)!;
            com.Add(task);
            return task;
        }
        catch (COMException error) when (error.HResult is unchecked((int)0x80070002) or unchecked((int)0x80070003)) { return null; }
        catch (FileNotFoundException) { return null; }
        catch (DirectoryNotFoundException) { return null; }
    }

    private static GovernorTaskFacts? Describe(object task, string name, string description)
    {
        var xml = (string)Get(task, "Xml")!;
        var enabled = (bool)Get(task, "Enabled")!;
        var lastResult = (int)Get(task, "LastTaskResult")!;
        return Description(xml) == description ? new GovernorTaskFacts(name, xml, enabled, lastResult) : null;
    }

    public static GovernorTaskState? State(GovernorTaskFacts task, GovernorTaskExpectation? expected, DateTime now, bool workerRunning = false)
    {
        var state = new GovernorTaskState(task.Name, true, task.Enabled, RepeatsEveryMinute(task.Xml, now), task.LastResult, workerRunning);
        if (!state.Enabled || !state.RestartsEveryMinute) return state;
        return expected is not null && StartOf(task.LastResult, workerRunning) != Unconfirmed && RunsGovernor(task.Xml, expected) ? state : null;
    }

    public static bool RunsGovernor(string xml, GovernorTaskExpectation expected)
    {
        XElement root;
        try { root = XElement.Parse(xml); }
        catch (System.Xml.XmlException) { return false; }
        XNamespace ns = root.Name.Namespace;
        string Text(XElement? element) => element?.Value.Trim() ?? "";
        bool Same(string left, string right) => string.Equals(left, right, StringComparison.OrdinalIgnoreCase);
        if (root.Element(ns + "Principals")?.Elements().ToArray() is not [{ } principal] || principal.Name != ns + "Principal"
            || !Same(Text(principal.Element(ns + "RunLevel")), "HighestAvailable") || !OwnedBy(Text(principal.Element(ns + "UserId")), expected.OwnerSid)) return false;
        var settings = root.Element(ns + "Settings");
        if (Text(settings?.Element(ns + "ExecutionTimeLimit")) != "PT0S" || Text(settings?.Element(ns + "MultipleInstancesPolicy")) is not ("" or "IgnoreNew")) return false;
        if (root.Element(ns + "Actions")?.Elements().ToArray() is not [{ } exec] || exec.Name != ns + "Exec") return false;
        var hostDirectory = Path.Combine(expected.InstallRoot, "backend", "bin", "optimizer");
        var launcher = Path.Combine(expected.InstallRoot, "backend", "scripts", "Start-RooIndustriesHelper.cmd");
        var prefix = "--headless \"" + Path.Combine(expected.SystemDirectory, "cmd.exe") + "\" /d /e:on /v:off /c set \"SystemRoot=" + Path.GetDirectoryName(expected.SystemDirectory) + "\"&call \"" + launcher + "\" \" ?";
        var arguments = Text(exec.Element(ns + "Arguments"));
        if (!Same(Text(exec.Element(ns + "Command")).Trim('"'), Path.Combine(expected.SystemDirectory, "conhost.exe")) || !Same(Text(exec.Element(ns + "WorkingDirectory")), hostDirectory)
            || !arguments.StartsWith(prefix, StringComparison.OrdinalIgnoreCase) || !arguments.EndsWith('"')) return false;
        var parts = arguments[prefix.Length..^1].Split('?');
        var request = Path.Combine(expected.PolicyRoot, "worker-request.json");
        return parts is [var host, "policy-run", var bundledRequest] && Same(host, Path.Combine(hostDirectory, "Optimizer.Host.exe")) && Same(bundledRequest, request)
            || parts is [var dotnet, var dll, "policy-run", var developmentRequest] && Same(Path.GetFileName(dotnet), "dotnet.exe") && Same(dll, Path.Combine(hostDirectory, "Optimizer.Host.dll")) && Same(developmentRequest, request);
    }

    private static bool OwnedBy(string user, string sid)
    {
        if (string.Equals(user, sid, StringComparison.OrdinalIgnoreCase)) return true;
        if (user.Length == 0 || user.StartsWith("S-1-", StringComparison.OrdinalIgnoreCase) || !OperatingSystem.IsWindows()) return false;
        try { return string.Equals(new NTAccount(user).Translate(typeof(SecurityIdentifier)).Value, sid, StringComparison.OrdinalIgnoreCase); }
        catch (Exception) { return false; }
    }

    public static string? Description(string xml)
    {
        try
        {
            var root = XElement.Parse(xml);
            return root.Element(root.Name.Namespace + "RegistrationInfo")?.Element(root.Name.Namespace + "Description")?.Value;
        }
        catch (System.Xml.XmlException) { return null; }
    }

    public static bool RepeatsEveryMinute(string xml, DateTime now)
    {
        XElement root;
        try { root = XElement.Parse(xml); }
        catch (System.Xml.XmlException) { return false; }
        XNamespace ns = root.Name.Namespace;
        var triggers = root.Element(ns + "Triggers");
        if (triggers is null) return false;
        return triggers.Elements(ns + "TimeTrigger").Any(trigger =>
        {
            if (!Flag(trigger.Element(ns + "Enabled"), true)) return false;
            var repetition = trigger.Element(ns + "Repetition");
            if (repetition?.Element(ns + "Interval")?.Value.Trim() != "PT1M") return false;
            if (repetition.Element(ns + "Duration") is { } duration && !string.IsNullOrWhiteSpace(duration.Value)) return false;
            if (!Moment(trigger.Element(ns + "StartBoundary"), out var start) || start > now) return false;
            if (trigger.Element(ns + "EndBoundary") is { } end && !string.IsNullOrWhiteSpace(end.Value) && (!Moment(end, out var until) || until <= now)) return false;
            return true;
        });
    }

    private static bool Flag(XElement? element, bool missing)
        => element is null || string.IsNullOrWhiteSpace(element.Value) ? missing : bool.TryParse(element.Value.Trim(), out var value) && value;

    private static bool Moment(XElement? element, out DateTime value)
    {
        value = default;
        if (element is null || string.IsNullOrWhiteSpace(element.Value)) return false;
        if (!DateTime.TryParse(element.Value.Trim(), CultureInfo.InvariantCulture, DateTimeStyles.AllowWhiteSpaces, out value)) return false;
        if (value.Kind == DateTimeKind.Utc) value = value.ToLocalTime();
        return true;
    }
}
