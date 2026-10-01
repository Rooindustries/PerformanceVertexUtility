using System;
using System.Collections;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using System.Text.Json;
using System.Xml.Linq;
using RooIndustries.Optimizer;

namespace RooIndustries.OptimizationSuite.Services;

public sealed record GovernorTaskState(string Name, bool Registered, bool Enabled, bool RestartsEveryMinute, int LastResult = 0)
{
    public bool LastStartFailed => LastResult == 1 || unchecked((uint)LastResult) is >= 0x80070000 and <= 0x8007FFFF and not 0x800710E0;
    public bool Restarts => Registered && Enabled && RestartsEveryMinute && !LastStartFailed;
}

public static class GovernorProbe
{
    public const string TaskPrefix = "RooIndustriesOptimizationSuite.ProcessRules.";
    public const string LegacyTaskPrefix = BrandCompatibility.LegacyPolicyTaskPrefix;
    public const string TaskDescription = "Roo Industries process rules | ";
    public const string LegacyTaskDescription = BrandCompatibility.LegacyPolicyTaskDescription;

    public static string Key(RunningProcess process) => process.ProcessId + "|" + process.CreationTimeFileTimeUtc;

    public static GovernorSnapshot Read(string policyRoot)
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
        var journals = new Dictionary<string, ProcessControlJournal>(StringComparer.OrdinalIgnoreCase);
        foreach (var instance in open)
        {
            try { if (File.Exists(instance.JournalPath)) journals[instance.JournalPath] = OperationFiles.Read<ProcessControlJournal>(instance.JournalPath); }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
            catch (InvalidDataException) { }
            catch (JsonException) { }
        }
        var unapplied = open.Where(instance => instance.Status == "applying" && !File.Exists(instance.JournalPath)).Select(instance => instance.JournalPath)
            .ToHashSet(StringComparer.OrdinalIgnoreCase);
        var task = worker.HostRunning == false && !summary.Paused && summary.EnabledRules > 0 ? ReadTask(policyRoot) : null;
        return new GovernorSnapshot(summary, worker, rules, journals, task, ExitedKeys(open.Select(instance => instance.Process)), unapplied);
    }

    public static HashSet<string> ExitedKeys(IEnumerable<RunningProcess> processes)
    {
        var exited = new HashSet<string>(StringComparer.Ordinal);
        var wanted = processes.DistinctBy(Key).ToArray();
        if (wanted.Length == 0) return exited;
        Dictionary<int, SnapshotProcess> running;
        try { running = ProcessSnapshot.Take(); }
        catch (Exception) { return exited; }
        foreach (var process in wanted)
            if (!running.TryGetValue(process.ProcessId, out var found) || found.CreationTimeFileTimeUtc != process.CreationTimeFileTimeUtc) exited.Add(Key(process));
        return exited;
    }

    public static string Suffix(string userSid, string policyRoot)
        => Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(userSid + "|" + Path.GetFullPath(policyRoot).ToUpperInvariant())))[..20];

    public static GovernorTaskState? ReadTask(string policyRoot)
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
            string Expected(string name) => (name.StartsWith(TaskPrefix, StringComparison.Ordinal) ? TaskDescription : LegacyTaskDescription) + sid + " | " + root;
            var service = Activator.CreateInstance(type)!;
            com.Add(service);
            ((dynamic)service).Connect();
            object folder = ((dynamic)service).GetFolder("\\");
            com.Add(folder);
            var found = new List<GovernorTaskState>();
            foreach (var name in new[] { TaskPrefix + suffix, LegacyTaskPrefix + suffix })
                if (Find(folder, name, com) is { } task && Describe(task, name, Expected(name)) is { } state) found.Add(state);
            if (found.Count == 0)
            {
                object tasks = ((dynamic)folder).GetTasks(1);
                com.Add(tasks);
                foreach (object task in (IEnumerable)tasks)
                {
                    com.Add(task);
                    string name = ((dynamic)task).Name;
                    if ((name.StartsWith(TaskPrefix, StringComparison.Ordinal) || name.StartsWith(LegacyTaskPrefix, StringComparison.Ordinal)) && Describe(task, name, Expected(name)) is { } state)
                        found.Add(state);
                }
            }
            return found.Count switch { 0 => new GovernorTaskState(TaskPrefix + suffix, false, false, false), 1 => found[0], _ => null };
        }
        catch (Exception) { return null; }
        finally
        {
            for (var index = com.Count - 1; index >= 0; index--)
                if (Marshal.IsComObject(com[index])) Marshal.FinalReleaseComObject(com[index]);
        }
    }

    private static object? Find(object folder, string name, List<object> com)
    {
        try
        {
            object task = ((dynamic)folder).GetTask(name);
            com.Add(task);
            return task;
        }
        catch (COMException error) when (error.HResult is unchecked((int)0x80070002) or unchecked((int)0x80070003)) { return null; }
        catch (FileNotFoundException) { return null; }
        catch (DirectoryNotFoundException) { return null; }
    }

    private static GovernorTaskState? Describe(object task, string name, string description)
    {
        string xml = ((dynamic)task).Xml;
        bool enabled = ((dynamic)task).Enabled;
        int lastResult = ((dynamic)task).LastTaskResult;
        return Description(xml) == description ? new GovernorTaskState(name, true, enabled, RepeatsEveryMinute(xml, DateTime.Now), lastResult) : null;
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
