#nullable enable
using System.Text.Json;
using System.Text.Json.Serialization;

namespace RooIndustries.Optimizer;

public sealed record TweakSavedChoices([property: JsonRequired] string Id, [property: JsonRequired] TweakSelection[] Selections);
public sealed record TweakChoiceFile([property: JsonRequired] int SchemaVersion, [property: JsonRequired] OperationOwner Owner, [property: JsonRequired] string? Revision, [property: JsonRequired] TweakSavedChoices[] Profiles);

public sealed class TweakChoiceStore(string path)
{
    public TweakChoiceFile Read()
    {
        if (!File.Exists(path)) return new(1, OperationOwner.Current(), null, []);
        if (new FileInfo(path).Length > 8388608) throw new InvalidDataException("Saved Windows choices exceed 8 MiB.");
        var file = OperationFiles.Read<TweakChoiceFile>(path); file.Owner.Verify();
        if (file.SchemaVersion != 1 || file.Revision is null || !Guid.TryParseExact(file.Revision, "N", out _) || file.Profiles is null ||
            file.Profiles.Length > 100 || file.Profiles.Select(profile => profile.Id).Distinct(StringComparer.Ordinal).Count() != file.Profiles.Length)
            throw new InvalidDataException("Saved Windows choices are incomplete.");
        foreach (var profile in file.Profiles) Validate(profile.Id, profile.Selections);
        return file;
    }
    public TweakChoiceFile Save(TweakCatalog catalog, string profileId, TweakSelection[] selections, string? expectedRevision)
    {
        Validate(profileId, selections);
        foreach (var selection in selections) _ = catalog.Resolve(selection);
        if ((catalog.Incompatible ?? []).FirstOrDefault(rule => rule.Selections.All(selections.Contains)) is { } rule)
            throw new InvalidDataException(string.Join(" and ", rule.Selections.Select(item => catalog.Resolve(item).Definition.Name)) + " cannot be used together. " + rule.Reason);
        using var guard = OperationFiles.Lock(path);
        var file = Read();
        if (file.Revision != expectedRevision) throw new InvalidDataException("Saved choices changed in another window. Refresh before saving.");
        var profiles = file.Profiles.Where(profile => profile.Id != profileId).ToList();
        if (selections.Length > 0) profiles.Add(new(profileId, selections.OrderBy(selection => selection.SettingId, StringComparer.Ordinal).ToArray()));
        if (profiles.Count == 0)
        {
            File.Delete(path);
            return new(1, file.Owner, null, []);
        }
        if (profiles.Count > 100) throw new InvalidDataException("At most 100 Windows choice profiles can be saved.");
        var next = file with { Revision = Guid.NewGuid().ToString("N"), Profiles = profiles.OrderBy(profile => profile.Id, StringComparer.Ordinal).ToArray() };
        if (JsonSerializer.SerializeToUtf8Bytes(next, OperationFiles.Json).Length > 8388608) throw new InvalidDataException("Saved Windows choices exceed 8 MiB.");
        OperationFiles.Write(path, next);
        return next;
    }
    private static void Validate(string profileId, TweakSelection[] selections)
    {
        if (string.IsNullOrWhiteSpace(profileId) || profileId.Length > 100 || profileId != profileId.Trim() || selections is null || selections.Length > 4096 ||
            selections.Any(selection => string.IsNullOrWhiteSpace(selection.SettingId) || string.IsNullOrWhiteSpace(selection.OptionId)) ||
            selections.GroupBy(selection => selection.SettingId).Any(group => group.Count() != 1))
            throw new InvalidDataException("A profile name and unambiguous setting choices are required.");
    }
}
