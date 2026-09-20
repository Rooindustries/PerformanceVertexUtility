#nullable enable
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace RooIndustries.Optimizer;

public sealed record WindowsRestorePoint(uint Sequence, string Description, DateTime CreatedAtUtc);
public sealed record RestorePointPreview([property: JsonRequired] OperationOwner Owner, [property: JsonRequired] string OperationId, [property: JsonRequired] string Description,
    [property: JsonRequired] WindowsRestorePoint[] Before, [property: JsonRequired] TweakPlan? Frequency);
public sealed record RestorePointResult(bool Created, WindowsRestorePoint? Point, bool AvailableNow, string Message, bool Pending = false);
public sealed record RestorePointJournal([property: JsonRequired] string ReviewHash, [property: JsonRequired] string Phase, [property: JsonRequired] long Sequence, [property: JsonRequired] bool EndConfirmed, RestorePointResult? Result = null, bool FrequencyRestored = false);

public static class RestorePoints
{
    public static WindowsRestorePoint[] List() => PowerShellControls.Invoke(new { action = "restore-points" }).Deserialize<WindowsRestorePoint[]>(OperationFiles.Json)
        ?? throw new InvalidDataException("Windows restore-point enumeration was incomplete.");
    private static TweakEngine FrequencyEngine() => new(new TweakCatalog(1, "restore-point-frequency-v1", [new("restore-point-frequency", "Restore-point creation frequency", "Recovery",
        "Temporarily allow a new restore point and restore the previous policy afterward.", 10240, 26200, ["*"], "none",
        [new("allow", "Allow creation", [new(new("LocalMachine", "Registry64", @"SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore", "value", "SystemRestorePointCreationFrequency"), 0)])],
        [new("Microsoft", "https://learn.microsoft.com/en-us/windows/win32/sr/createrestorepoint-systemrestore", "Restore-point creation frequency")])], []), new RegistryTweakStore());
    public static RestorePointPreview Preview(bool allowFresh)
    {
        var id = Guid.NewGuid().ToString("N"); var before = List();
        return new(OperationOwner.Current(), id, "Roo Industries settings " + id, before, allowFresh ? FrequencyEngine().Preview("restore-point-" + id, [new("restore-point-frequency", "allow")]) : null);
    }
    public static RestorePointResult Verify(WindowsRestorePoint[] before, WindowsRestorePoint[] after, string description, long sequence, bool ended)
    {
        var matches = after.Where(point => point.Description == description && point.Sequence == sequence && before.All(prior => prior.Sequence != point.Sequence)).ToArray();
        return ended && matches.Length == 1 ? new(true, matches[0], true, "Windows restore point created and verified.")
            : new(false, null, false, "Windows did not produce a verified new restore point. A recent point or Windows protection policy may have prevented creation.");
    }
    public static RestorePointResult VerifyUntil(RestorePointPreview plan, long sequence, bool ended, Func<WindowsRestorePoint[]> read, Action pause, int attempts)
    {
        if (attempts < 1 || attempts > 60) throw new ArgumentOutOfRangeException(nameof(attempts));
        if (sequence > uint.MaxValue) throw new InvalidDataException("Windows returned a restore-point sequence outside the supported enumeration range.");
        for (var attempt = 0; ; attempt++)
        {
            var result = Verify(plan.Before, read(), plan.Description, sequence, ended);
            if (result.Created || !ended || sequence <= 0 || plan.Before.Any(point => point.Sequence == sequence)) return result;
            if (attempt + 1 == attempts) return result with { Pending = true, Message = "Windows accepted the request. The new restore point is still being verified; check this request again." };
            pause();
        }
    }
    public static RestorePointResult Create(string previewPath, string hash, string journalPath)
    {
        var plan = OperationFiles.Read<RestorePointPreview>(previewPath, hash); plan.Owner.Verify();
        if (!Guid.TryParseExact(plan.OperationId, "N", out _) || plan.Description != "Roo Industries settings " + plan.OperationId) throw new InvalidDataException("Invalid restore-point review identity.");
        var directory = Path.GetDirectoryName(Path.GetFullPath(journalPath))!;
        if (new[] { Path.GetFullPath(previewPath), Path.GetFullPath(journalPath), Path.Combine(directory, "frequency-review.json"), Path.Combine(directory, "frequency-restore.json") }.Distinct(StringComparer.OrdinalIgnoreCase).Count() != 4)
            throw new InvalidDataException("Restore-point review, journal and temporary policy files must have distinct paths.");
        using var guard = OperationFiles.Lock(journalPath);
        var journal = File.Exists(journalPath) ? OperationFiles.Read<RestorePointJournal>(journalPath) : new(hash, "prepared", 0, false);
        if (journal.ReviewHash != hash) throw new InvalidDataException("The restore-point journal belongs to another review.");
        if (journal.Result is { } result && (result.Created || !journal.EndConfirmed || journal.Sequence <= 0))
        {
            if (!journal.FrequencyRestored)
            {
                RestoreFrequency(plan, journalPath);
                journal = journal with { FrequencyRestored = true }; OperationFiles.Write(journalPath, journal);
            }
            var available = result.Point is not null && List().Any(point => point.Sequence == result.Point.Sequence && point.Description == result.Point.Description);
            return result with { AvailableNow = available };
        }
        OperationFiles.Write(journalPath, journal);
        var frequencyFile = Path.Combine(Path.GetDirectoryName(Path.GetFullPath(journalPath))!, "frequency-review.json");
        try
        {
            if (plan.Frequency is not null)
            {
                if (!File.Exists(frequencyFile)) OperationFiles.Write(frequencyFile, plan.Frequency);
                FrequencyEngine().Apply(frequencyFile, OperationFiles.Hash(JsonSerializer.SerializeToUtf8Bytes(plan.Frequency, OperationFiles.Json)));
            }
            if (journal.Phase == "prepared")
            {
                journal = journal with { Phase = "creating" }; OperationFiles.Write(journalPath, journal);
                var begin = new RestoreInfo { EventType = 100, PointType = 12, Description = plan.Description };
                Set(ref begin, out var status);
                journal = journal with { Sequence = status.Sequence }; OperationFiles.Write(journalPath, journal);
            }
            else if (journal.Sequence == 0) throw new InvalidOperationException("Creation was interrupted before its Windows sequence was recorded. Inspect System Protection before starting another request.");
            if (journal.Sequence > 0 && !journal.EndConfirmed)
            {
                var end = new RestoreInfo { EventType = 101, PointType = 12, Sequence = journal.Sequence, Description = plan.Description };
                Set(ref end, out _); journal = journal with { EndConfirmed = true }; OperationFiles.Write(journalPath, journal);
            }
            var verified = VerifyUntil(plan, journal.Sequence, journal.EndConfirmed, List, () => Thread.Sleep(1000), 30);
            journal = journal with { Phase = verified.Pending ? "awaiting-verification" : "finished", Result = verified.Pending ? null : verified }; OperationFiles.Write(journalPath, journal);
            return verified;
        }
        finally
        {
            RestoreFrequency(plan, journalPath);
            journal = journal with { FrequencyRestored = true }; OperationFiles.Write(journalPath, journal);
        }
    }
    private static void RestoreFrequency(RestorePointPreview plan, string journalPath)
    {
        if (plan.Frequency is null) return;
        var engine = FrequencyEngine(); var state = new RegistryTweakStore().ReadState();
        if (state?.Profiles.Any(profile => profile.Id == plan.Frequency.ProfileId) != true) return;
        var restore = engine.Preview(plan.Frequency.ProfileId, []); var path = Path.Combine(Path.GetDirectoryName(Path.GetFullPath(journalPath))!, "frequency-restore.json");
        OperationFiles.Write(path, restore); engine.Apply(path, OperationFiles.HashFile(path));
    }
    private static void Set(ref RestoreInfo info, out RestoreStatus status)
    {
        var ok = SRSetRestorePoint(ref info, out status);
        if (!ok || status.Status != 0) { var error = status.Status != 0 ? (int)status.Status : Marshal.GetLastWin32Error(); throw new Win32Exception(error, "SRSetRestorePointW failed with Win32 " + error + ". Check System Protection for the Windows drive."); }
    }
    [StructLayout(LayoutKind.Sequential, Pack = 1, CharSet = CharSet.Unicode)] private struct RestoreInfo { public uint EventType, PointType; public long Sequence; [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string Description; }
    [StructLayout(LayoutKind.Sequential, Pack = 1)] private struct RestoreStatus { public uint Status; public long Sequence; }
    [DllImport("srclient.dll", EntryPoint = "SRSetRestorePointW", CharSet = CharSet.Unicode, SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool SRSetRestorePoint(ref RestoreInfo info, out RestoreStatus status);
}
