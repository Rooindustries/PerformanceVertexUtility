#nullable enable
using System.Globalization;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;

namespace RooIndustries.Optimizer;

public sealed record LaunchPreset([property: JsonRequired] string Id, [property: JsonRequired] string Name, [property: JsonRequired] string Description,
    [property: JsonRequired] Dictionary<string, JsonElement> Settings)
{
    public Dictionary<string, JsonElement> Controls() => Settings.ToDictionary(pair => pair.Key, pair => pair.Key == "executionQoS"
        ? JsonSerializer.SerializeToElement(new PowerThrottling(0, 0).WithExecutionMode(pair.Value.GetString()!), OperationFiles.Json) : pair.Value);
}

public sealed record LaunchPresetCatalog([property: JsonRequired] int SchemaVersion, [property: JsonRequired] LaunchPreset[] Presets)
{
    public static readonly string[] SettingNames = ["cpuPriority", "ioPriority", "memoryPriority", "gpuPriority", "executionQoS", "priorityBoost"];
    public const string Custom = "Custom";

    public static LaunchPresetCatalog Read(string path)
    {
        var catalog = OperationFiles.Read<LaunchPresetCatalog>(path);
        if (catalog.SchemaVersion != 1) throw new InvalidDataException("The launch presets use an unsupported version.");
        if (catalog.Presets is not { Length: > 0 } presets || presets.Any(preset => preset is null)) throw new InvalidDataException("The launch preset catalog has no presets.");
        foreach (var preset in presets) Validate(preset);
        Unique(presets.Select(preset => preset.Id), StringComparer.Ordinal, "id");
        Unique(presets.Select(preset => preset.Name), StringComparer.OrdinalIgnoreCase, "name");
        Unique(presets.Select(preset => string.Join(",", preset.Settings.OrderBy(pair => pair.Key, StringComparer.Ordinal).Select(pair => pair.Key + "=" + pair.Value.GetRawText()))), StringComparer.Ordinal, "settings");
        return catalog;
    }

    private static void Validate(LaunchPreset preset)
    {
        if (preset.Id is null || !Regex.IsMatch(preset.Id, @"\A[a-z][a-z0-9-]*\z")) throw new InvalidDataException("A launch preset id must be lowercase letters, digits and dashes.");
        InvalidDataException Refused(string reason) => new("Launch preset " + preset.Id + " " + reason);
        if (string.IsNullOrWhiteSpace(preset.Name) || preset.Name != preset.Name.Trim() || preset.Name.Length > 32 || string.Equals(preset.Name, Custom, StringComparison.OrdinalIgnoreCase))
            throw Refused("needs a short name other than " + Custom + ".");
        if (string.IsNullOrWhiteSpace(preset.Description) || preset.Description.Length > 200) throw Refused("needs a short description.");
        if (preset.Settings is not { Count: > 0 }) throw Refused("changes no settings.");
        foreach (var (name, value) in preset.Settings)
            if (!SettingNames.Contains(name) || !Canonical(value)) throw Refused("sets " + name + " to a value the game session form doesn't offer.");
        try { ProtectedSessions.ValidateControls(preset.Controls()); }
        catch (Exception error) when (error is InvalidDataException or InvalidOperationException or FormatException) { throw Refused("isn't a valid game session: " + error.Message); }
    }

    private static bool Canonical(JsonElement value) => value.ValueKind switch
    {
        JsonValueKind.String => JsonSerializer.Serialize(value.GetString()) == value.GetRawText(),
        JsonValueKind.Number => value.TryGetInt32(out var number) && number.ToString(CultureInfo.InvariantCulture) == value.GetRawText(),
        JsonValueKind.True or JsonValueKind.False => true,
        _ => false,
    };

    private static void Unique(IEnumerable<string> values, StringComparer comparer, string label)
    {
        var seen = new HashSet<string>(comparer);
        foreach (var value in values)
            if (!seen.Add(value)) throw new InvalidDataException("Two launch presets have the same " + label + ": " + value);
    }
}
