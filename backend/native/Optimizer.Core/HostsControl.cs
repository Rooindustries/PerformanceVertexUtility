#nullable enable
using System.Text.Json;

namespace RooIndustries.Optimizer;

public static class HostsControl
{
    private static string Target(ControlAddress address)
    {
        if (address.Property != "adobe-block") throw new InvalidDataException("Unknown hosts control.");
        return address.Target == "system" ? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), @"drivers\etc\hosts")
            : address.Target.StartsWith("fixture:", StringComparison.Ordinal) ? FileAccessControl.FixturePath(address.Target[8..])
            : throw new InvalidDataException("Unknown hosts target.");
    }
    private static string Binding(FileLease lease)
    {
        var file = lease.Capture();
        return OperationFiles.Hash(JsonSerializer.SerializeToUtf8Bytes(new { file.Identity, file.CreationTime, file.Security, file.Attributes, Streams = file.Streams.Where(stream => stream.Name != "::$DATA").ToArray() }));
    }
    private static TweakControlRead Snapshot(ControlAddress address, FileLease lease) => new(address, "hosts:" + lease.Path.ToUpperInvariant(), Binding(lease), HostsBlock.Read(lease.ReadContent()));
    public static TweakControlRead Read(ControlAddress address)
    {
        using var lease = FileLease.OpenContent(Target(address));
        return Snapshot(address, lease);
    }
    public static void Write(TweakControlRead before, JsonElement desired)
    {
        using var lease = FileLease.OpenContent(Target(before.Address), writable: true);
        if (!Snapshot(before.Address, lease).Same(before)) throw new InvalidDataException("The hosts file changed after review.");
        var original = lease.ReadContent(); var bytes = HostsBlock.Bytes(desired);
        _ = HostsBlock.Read(bytes);
        try
        {
            lease.WriteContent(bytes);
            if (!lease.ReadContent().SequenceEqual(bytes)) throw new IOException("Hosts readback differs from the reviewed bytes.");
        }
        catch
        {
            if (!HostsBlock.KnownPartial(lease.ReadContent(), original, bytes)) throw new IOException("Hosts recovery needs review because the file has an unknown intermediate value.");
            lease.WriteContent(original);
            if (!lease.ReadContent().SequenceEqual(original)) throw new IOException("Hosts restoration readback differs; the recovery journal remains available.");
            throw;
        }
    }
    public static void Rollback(ControlMutation change)
    {
        using var lease = FileLease.OpenContent(Target(change.Before.Address), writable: true);
        if (Binding(lease) != change.Before.Binding) throw new InvalidDataException("Hosts identity, permissions or alternate streams changed.");
        var current = lease.ReadContent(); var before = HostsBlock.Bytes(change.Before.Value); var after = HostsBlock.Bytes(change.After);
        byte[] restore;
        try
        {
            var parsed = HostsBlock.Read(current);
            var block = parsed.GetProperty("block");
            if (!ControlValues.Equal(block, change.Before.Value.GetProperty("block")) && !ControlValues.Equal(block, change.After.GetProperty("block"))) throw new InvalidDataException("The owned hosts block changed.");
            if (ControlValues.Equal(block, change.Before.Value.GetProperty("block")) && !ControlValues.Equal(block, change.After.GetProperty("block")) && !current.SequenceEqual(before)) throw new InvalidDataException("The owned hosts block is missing or was restored alongside other edits.");
            restore = HostsBlock.Bytes(ControlValues.From(new { block = change.Before.Value.GetProperty("block"), outside = parsed.GetProperty("outside") }));
        }
        catch (InvalidDataException)
        {
            if (!HostsBlock.KnownPartial(current, before, after)) throw;
            restore = before;
        }
        if (!current.SequenceEqual(restore)) lease.WriteContent(restore);
        if (!lease.ReadContent().SequenceEqual(restore)) throw new IOException("Hosts recovery readback differs.");
    }
}
