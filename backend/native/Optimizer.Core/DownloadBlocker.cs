#nullable enable
using System.ComponentModel;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace RooIndustries.Optimizer;

public sealed record DownloadBlockerReceipt([property: JsonRequired] OperationOwner Owner, [property: JsonRequired] string Path, [property: JsonRequired] string Phase, [property: JsonRequired] bool CreatedDirectory,
    [property: JsonRequired] TweakControlRead? Original, [property: JsonRequired] JsonElement? Applied, [property: JsonRequired] uint Attributes);

public static class DownloadBlocker
{
    private static (string Path, string Receipt, ControlAddress Policy) Target(ControlAddress address)
    {
        if (address.Property != "blocked" || address.Target is not ("razer-downloads" or "logitech-downloads") && !address.Target.StartsWith("fixture:", StringComparison.Ordinal)) throw new InvalidDataException("Unknown download-folder blocker.");
        var policy = new ControlAddress("file-acl", address.Target, "permissions"); var path = FileAccessControl.Target(policy);
        var receipt = address.Target.StartsWith("fixture:", StringComparison.Ordinal) ? Path.Combine(Path.GetDirectoryName(path)!, Path.GetFileName(path) + ".blocker.json")
            : Path.Combine(OperationsFolder.DefaultRoot, "download-blockers", address.Target + ".json");
        return (path, receipt, policy);
    }
    private static DownloadBlockerReceipt? Receipt(string file, string path)
    {
        try
        {
            var receipt = OperationFiles.Read<DownloadBlockerReceipt>(file); receipt.Owner.Verify();
            if (receipt.Path != path || receipt.Phase is not ("creating" or "created" or "active" or "restoring" or "retained")) throw new InvalidDataException("Download-folder ownership is incomplete.");
            if (receipt.Phase == "creating")
            {
                if (!receipt.CreatedDirectory || receipt.Original is not null || receipt.Applied is not null || receipt.Attributes != 0) throw new InvalidDataException("Download-folder creation ownership is incomplete.");
            }
            else
            {
                if (receipt.Original is null || receipt.Applied is null || (receipt.Attributes & 16) == 0) throw new InvalidDataException("Download-folder ownership is incomplete.");
                receipt.Original.Validate();
                try
                {
                    var original = receipt.Original;
                    if (original.Address.Kind != "file-acl" || FileAccessControl.Target(original.Address) != path || original.Value.EnumerateObject().Count() != 4 ||
                        original.Value.GetProperty("flags").GetInt32() is < 0 or > ushort.MaxValue) throw new InvalidDataException("Download-folder original permissions are incomplete.");
                    _ = new System.Security.Principal.SecurityIdentifier(original.Value.GetProperty("owner").GetString()!);
                    _ = new System.Security.Principal.SecurityIdentifier(original.Value.GetProperty("group").GetString()!);
                    if (!ControlValues.Equal(receipt.Applied.Value, original.Expand(ControlValues.From(new { denyMask = 0x116 })))) throw new InvalidDataException("Download-folder applied permissions differ from their original receipt.");
                }
                catch (Exception error) when (error is ArgumentException or InvalidOperationException or KeyNotFoundException or FormatException or OverflowException)
                { throw new InvalidDataException("Download-folder original permissions are incomplete.", error); }
            }
            return receipt;
        }
        catch (FileNotFoundException) { return null; }
        catch (DirectoryNotFoundException) { return null; }
    }
    private static (TweakControlRead? Policy, uint Attributes) Policy(ControlAddress address, string path)
    {
        try
        {
            using var lease = FileLease.OpenPolicy(path); var info = lease.ReadPolicy();
            if ((info.Attributes & 16) == 0) throw new TweakResourceChangedException("The download-folder target is a file, not a directory.");
            return (FileAccessControl.Snapshot(address, lease), info.Attributes);
        }
        catch (Win32Exception error) when (error.NativeErrorCode is 2 or 3) { return (null, 0); }
    }
    public static TweakControlRead Read(ControlAddress address)
    {
        var target = Target(address); using var privileges = PrivilegeScope.FilePolicy();
        using var parent = FileLease.OpenPolicy(Path.GetDirectoryName(target.Path)!); var parentId = parent.ReadPolicy().Identity;
        var current = Policy(target.Policy, target.Path); var receipt = Receipt(target.Receipt, target.Path); var active = false;
        if (receipt is not null && receipt.Phase != "retained")
        {
            if (receipt.Phase == "creating" && current.Policy is not null) throw new TweakResourceChangedException("The folder exists without a confirmed creation receipt. Its contents and permissions were left intact.");
            if (receipt.Phase != "creating")
            {
                if (receipt.Original is null || receipt.Applied is null) throw new InvalidDataException("Download-folder ownership is incomplete.");
                if (current.Policy?.Id != receipt.Original.Id) throw new TweakResourceChangedException("The owned download folder is missing or was replaced.");
                active = ControlValues.Equal(current.Policy.Value, receipt.Applied.Value);
                if (!active && !ControlValues.Equal(current.Policy.Value, receipt.Original.Value)) throw new TweakResourceChangedException("Download-folder permissions changed outside this profile.");
            }
        }
        return new(address, "download-blocker:" + target.Path.ToUpperInvariant(), parentId.Volume + ":" + parentId.Id, ControlValues.From(active),
            receipt?.Phase == "retained" ? "Restriction removed; the folder was kept because it contains data or changed attributes" : "Restrict new writes to " + Path.GetFileName(target.Path),
            LostLease: !active && receipt?.Phase is "creating" or "created" or "restoring",
            EvidenceHash: OperationFiles.Hash(JsonSerializer.SerializeToUtf8Bytes(new { current.Policy, current.Attributes }, OperationFiles.Json)));
    }
    public static void Write(TweakControlRead before, JsonElement desired)
    {
        var target = Target(before.Address);
        if (!before.Address.Target.StartsWith("fixture:", StringComparison.Ordinal)) OperationsFolder.Ensure(OperationsFolder.DefaultRoot);
        Directory.CreateDirectory(Path.GetDirectoryName(target.Receipt)!);
        using var guard = OperationFiles.Lock(target.Receipt); using var privileges = PrivilegeScope.FilePolicy();
        if (!Read(before.Address).Same(before)) throw new InvalidDataException("The download folder changed after review.");
        var receipt = Receipt(target.Receipt, target.Path); var current = Policy(target.Policy, target.Path);
        if (desired.GetBoolean())
        {
            if (receipt is null || receipt.Phase == "retained")
            {
                receipt = new(OperationOwner.Current(), target.Path, current.Policy is null ? "creating" : "created", current.Policy is null, current.Policy,
                    current.Policy?.Expand(ControlValues.From(new { denyMask = 0x116 })), current.Attributes);
                OperationFiles.Write(target.Receipt, receipt);
                if (current.Policy is null)
                {
                    using var created = FileLease.Create(target.Path, directory: true);
                    current = (FileAccessControl.Snapshot(target.Policy, created), created.ReadPolicy().Attributes);
                    var applied = current.Policy.Expand(ControlValues.From(new { denyMask = 0x116 }));
                    receipt = receipt with { Phase = "created", Original = current.Policy, Applied = applied, Attributes = current.Attributes };
                    OperationFiles.Write(target.Receipt, receipt);
                    created.SetDacl(Convert.FromBase64String(applied.GetProperty("dacl").GetString()!));
                    if (!ControlValues.Equal(FileAccessControl.Snapshot(target.Policy, created).Value, applied)) throw new IOException("Created folder permission readback differs.");
                    OperationFiles.Write(target.Receipt, receipt with { Phase = "active" }); return;
                }
            }
            if (receipt.Original is null || receipt.Applied is null || current.Policy?.Id != receipt.Original.Id) throw new InvalidDataException("The folder's original permissions are unavailable.");
            if (!ControlValues.Equal(current.Policy.Value, receipt.Applied.Value)) FileAccessControl.Write(current.Policy, receipt.Applied.Value);
            OperationFiles.Write(target.Receipt, receipt with { Phase = "active" }); return;
        }
        if (receipt is null || receipt.Phase == "retained") return;
        if (receipt.Phase == "creating" && current.Policy is null) { File.Delete(target.Receipt); return; }
        if (receipt.Original is null || current.Policy?.Id != receipt.Original.Id) throw new InvalidDataException("The original folder identity is unavailable for restoration.");
        OperationFiles.Write(target.Receipt, receipt with { Phase = "restoring" });
        if (!ControlValues.Equal(current.Policy.Value, receipt.Original.Value)) FileAccessControl.Write(current.Policy, receipt.Original.Value);
        if (receipt.CreatedDirectory)
        {
            using var folder = FileLease.OpenForRestore(target.Path);
            if (!FileAccessControl.Snapshot(target.Policy, folder).Same(receipt.Original)) throw new InvalidDataException("The folder changed before cleanup.");
            if (folder.ReadPolicy().Attributes != receipt.Attributes || folder.Children().Length != 0)
            {
                OperationFiles.Write(target.Receipt, receipt with { Phase = "retained" }); return;
            }
            try { folder.MarkDelete(); }
            catch (Win32Exception error) when (error.NativeErrorCode == 145) { OperationFiles.Write(target.Receipt, receipt with { Phase = "retained" }); return; }
        }
        File.Delete(target.Receipt);
    }
}
