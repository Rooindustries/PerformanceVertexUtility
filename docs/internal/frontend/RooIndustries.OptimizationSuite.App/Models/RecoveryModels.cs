using System;
using System.IO;
using System.Linq;
using System.Text.Json;

namespace RooIndustries.OptimizationSuite.Models;

public sealed record RecoveryOperationGeneration(string Id);

public sealed record GameTuneReview(string Path, string Sha256);

public sealed record ProcessProfileRecovery(string Path, string Id, string? Generation = null)
{
    public bool Valid()
    {
        try { return ValidationError() is null; }
        catch { return false; }
    }

    public string? ValidationError()
    {
        if (string.IsNullOrWhiteSpace(Path) || string.IsNullOrWhiteSpace(Id)) return "The recovery reference is incomplete.";
        try
        {
            using var document = JsonDocument.Parse(File.ReadAllText(Path));
            var root = document.RootElement;
            return Text(root, "actionId") == "performance.applyProfile"
                && Text(root, "backupId") == Id
                && !string.IsNullOrWhiteSpace(Text(root, "profileId"))
                && Boolean(root, "dryRun") == false
                && Count(root, "snapshots") is > 0 ? null : "The process backup does not match its recovery reference.";
        }
        catch (FileNotFoundException) { return "The process backup is missing."; }
        catch (DirectoryNotFoundException) { return "The process backup is missing."; }
        catch (JsonException) { return "The process backup contains invalid JSON."; }
        catch (ArgumentException) { return "The process backup path is invalid."; }
    }

    public bool RestoreCompleted(string? json)
    {
        if (string.IsNullOrWhiteSpace(json)) return false;
        try
        {
            using var document = JsonDocument.Parse(json);
            var root = document.RootElement;
            return Text(root, "actionId") == "performance.rollbackProfile"
                && Boolean(root, "dryRun") == false
                && Text(root, "status") == "success"
                && Text(root, "result", "status") == "success"
                && Count(root, "result", "changedItems") is not null
                && (!root.GetProperty("result").TryGetProperty("restorePendingCount", out var pending)
                    || pending.ValueKind == JsonValueKind.Number && pending.TryGetInt32(out var count) && count == 0)
                && Text(root, "backup", "backupId") == Id
                && SamePath(Text(root, "backup", "location"), Path)
                && !BlockingErrors(root);
        }
        catch { return false; }
    }

    public static ProcessProfileRecovery? FromApply(string? json, string? generation = null)
    {
        if (string.IsNullOrWhiteSpace(json)) return null;
        try
        {
            using var document = JsonDocument.Parse(json);
            var root = document.RootElement;
            if (Text(root, "actionId") != "performance.applyProfile" || Boolean(root, "dryRun") != false
                || Boolean(root, "backup", "rollbackSupported") != true) return null;
            var recovery = new ProcessProfileRecovery(Text(root, "backup", "location") ?? "", Text(root, "backup", "backupId") ?? "", generation);
            return recovery.Valid() ? recovery : null;
        }
        catch { return null; }
    }

    private static string? Text(JsonElement root, params string[] path)
    {
        var current = root;
        foreach (var segment in path)
            if (current.ValueKind != JsonValueKind.Object || !current.TryGetProperty(segment, out current)) return null;
        return current.ValueKind == JsonValueKind.String ? current.GetString() : null;
    }

    private static bool? Boolean(JsonElement root, params string[] path)
    {
        var current = root;
        foreach (var segment in path)
            if (current.ValueKind != JsonValueKind.Object || !current.TryGetProperty(segment, out current)) return null;
        return current.ValueKind is JsonValueKind.True or JsonValueKind.False ? current.GetBoolean() : null;
    }

    private static int? Count(JsonElement root, params string[] path)
    {
        var current = root;
        foreach (var segment in path)
            if (current.ValueKind != JsonValueKind.Object || !current.TryGetProperty(segment, out current)) return null;
        return current.ValueKind == JsonValueKind.Array ? current.GetArrayLength() : null;
    }

    private static bool BlockingErrors(JsonElement root)
        => root.TryGetProperty("errors", out var errors) &&
            (errors.ValueKind != JsonValueKind.Array || errors.EnumerateArray().Any(error => Boolean(error, "blocking") == true));

    private static bool SamePath(string? first, string second)
    {
        if (string.IsNullOrWhiteSpace(first)) return false;
        try { return string.Equals(System.IO.Path.GetFullPath(first), System.IO.Path.GetFullPath(second), StringComparison.OrdinalIgnoreCase); }
        catch { return false; }
    }
}
