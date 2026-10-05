#nullable enable
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text.Json;

namespace RooIndustries.Optimizer;

public static class FileAccessControl
{
    internal static string Target(ControlAddress address)
    {
        if (address.Property != "permissions") throw new InvalidDataException("Unknown file permission control.");
        if (address.Kind == "file-ownership" && address.Target.StartsWith("selected:", StringComparison.Ordinal)) return FileLease.NormalizePath(address.Target[9..]);
        return address.Target switch
        {
            "store-search" => Path.Combine(RuntimeEnvironment.LocalAppData, @"Packages\Microsoft.WindowsStore_8wekyb3d8bbwe\LocalState\store.db"),
            "razer-downloads" => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), @"Installer\Razer"),
            "logitech-downloads" => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "LogiDownloadAssistant"),
            "telemetry-consent" => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "wsqmcons.exe"),
            "compatibility-telemetry" => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "compattelrunner.exe"),
            "diagnostic-runner" => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), @"compattel\DiagTrackRunner.exe"),
            "application-telemetry" => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "aitagent.exe"),
            "device-census" => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "devicecensus.exe"),
            _ when address.Target.StartsWith("fixture:", StringComparison.Ordinal) => FixturePath(address.Target[8..]),
            _ => throw new InvalidDataException("Unknown file permission target."),
        };
    }
    internal static string FixturePath(string path)
    {
        path = FileLease.NormalizePath(path);
        var relative = Path.GetRelativePath(Path.GetTempPath(), path).Split(Path.DirectorySeparatorChar);
        if (relative.Length < 2 || !System.Text.RegularExpressions.Regex.IsMatch(relative[0], "^roo-industries-file-controls-[a-f0-9]{32}$")) throw new InvalidDataException("File permission fixtures must remain in their disposable temporary root.");
        return path;
    }
    internal static TweakControlRead Snapshot(ControlAddress address, FileLease lease)
    {
        var state = lease.ReadPolicy();
        var descriptor = new RawSecurityDescriptor(state.Security, 0);
        if (descriptor.DiscretionaryAcl is null || descriptor.Owner is null || descriptor.Group is null) throw new InvalidDataException("A complete, non-null file DACL is required.");
        return new(address, "file-acl:" + state.Identity.Volume + ":" + state.Identity.Id, state.Identity.Volume + ":" + state.Identity.Id + ":" + state.CreationTime,
            ControlValues.From(new { owner = descriptor.Owner.Value, group = descriptor.Group.Value, flags = (int)descriptor.ControlFlags, dacl = Convert.ToBase64String(Bytes(descriptor.DiscretionaryAcl)) }));
    }
    public static TweakControlRead Read(ControlAddress address)
    {
        var path = Target(address);
        if (new DriveInfo(Path.GetPathRoot(path)!).DriveFormat != "NTFS") throw new InvalidDataException("File permission controls currently require NTFS.");
        using var privileges = PrivilegeScope.FilePolicy();
        using var lease = FileLease.OpenPolicy(path);
        return Snapshot(address, lease);
    }
    public static JsonElement Expand(TweakControlRead before, JsonElement requested)
    {
        var ownership = before.Address.Kind == "file-ownership";
        if (ownership && (!requested.GetProperty("takeOwnership").GetBoolean() || (before.Value.GetProperty("flags").GetInt32() & (int)ControlFlags.OwnerDefaulted) != 0)) throw new InvalidDataException("This ownership request or default-owner flag cannot be restored through the supported owner operation.");
        var mask = ownership ? 0x1f01ff : requested.GetProperty("denyMask").GetInt32();
        if (mask is not (0x20 or 0x116 or 0x1f01ff)) throw new InvalidDataException("Unknown reviewed file restriction.");
        var enabled = !requested.TryGetProperty("enabled", out var choice) || choice.GetBoolean();
        var acl = new RawAcl(Convert.FromBase64String(before.Value.GetProperty("dacl").GetString()!), 0);
        var sid = new SecurityIdentifier(ownership ? OperationOwner.Current().UserSid : "S-1-1-0");
        var ace = new CommonAce(AceFlags.None, ownership ? AceQualifier.AccessAllowed : AceQualifier.AccessDenied, mask, sid, false, null);
        var bytes = new byte[ace.BinaryLength]; ace.GetBinaryForm(bytes, 0);
        var indices = Enumerable.Range(0, acl.Count).Where(index =>
        {
            var existing = new byte[acl[index].BinaryLength]; acl[index].GetBinaryForm(existing, 0); return existing.SequenceEqual(bytes);
        }).ToArray();
        if (enabled && indices.Length == 0)
        {
            var at = 0;
            if (ownership) while (at < acl.Count && acl[at] is CommonAce prior && prior.AceQualifier == AceQualifier.AccessDenied && (prior.AceFlags & AceFlags.Inherited) == 0) at++;
            acl.InsertAce(at, ace);
        }
        if (!enabled) foreach (var index in indices.Reverse()) acl.RemoveAce(index);
        var fields = before.Value.EnumerateObject().ToDictionary(property => property.Name, property => property.Value);
        fields["dacl"] = ControlValues.From(Convert.ToBase64String(Bytes(acl)));
        if (ownership) fields["owner"] = ControlValues.From(sid.Value);
        return ControlValues.From(fields);
    }
    public static void Write(TweakControlRead before, JsonElement desired)
    {
        var ownership = before.Address.Kind == "file-ownership";
        foreach (var field in ownership ? new[] { "group", "flags" } : new[] { "owner", "group", "flags" })
            if (!ControlValues.Equal(before.Value.GetProperty(field), desired.GetProperty(field))) throw new InvalidDataException("File permission controls cannot change the owner, group or inheritance flags.");
        var acl = new RawAcl(Convert.FromBase64String(desired.GetProperty("dacl").GetString()!), 0);
        using var privileges = PrivilegeScope.FilePolicy();
        using var lease = FileLease.OpenPolicy(Target(before.Address), writable: true, owner: ownership);
        if (!Snapshot(before.Address, lease).Same(before)) throw new InvalidDataException("The file or its permissions changed after review.");
        if (ownership && !ControlValues.Equal(before.Value.GetProperty("owner"), desired.GetProperty("owner")))
        {
            var sid = new SecurityIdentifier(desired.GetProperty("owner").GetString()!); var bytes = new byte[sid.BinaryLength]; sid.GetBinaryForm(bytes, 0); lease.SetOwner(bytes);
        }
        lease.SetDacl(Bytes(acl));
        if (!ControlValues.Equal(Snapshot(before.Address, lease).Value, desired)) throw new IOException("File permission readback differs from the reviewed DACL.");
    }
    private static byte[] Bytes(RawAcl acl) { var bytes = new byte[acl.BinaryLength]; acl.GetBinaryForm(bytes, 0); return bytes; }
}
