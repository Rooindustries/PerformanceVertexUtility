using System.Text;
using RooIndustries.Optimizer;

static class HostsChecks
{
    public static void Run(string root, Action<bool, string> check, Action<Action, string> reject)
    {
        var address = new ControlAddress("hosts", "system", "adobe-block");
        byte[] original = [0xef, 0xbb, 0xbf, .. Encoding.UTF8.GetBytes("# café\r\n127.0.0.1 localhost\n# no final newline")];
        var read = new TweakControlRead(address, address.Key, "file", HostsBlock.Read(original));
        var claim = new ControlClaim("hosts", "block", read, read.Expand(ControlValues.From(new { enabled = true })), true);
        var desired = ControlComposition.Resolve(read, null, [], [claim]).Desired;
        var bytes = HostsBlock.Bytes(desired);
        check(bytes.AsSpan(0, 3).SequenceEqual(original.AsSpan(0, 3)) && HostsBlock.Read(bytes).GetProperty("outside").GetString() == Convert.ToBase64String(original), "Hosts insertion preserves BOM, mixed newlines, non-ASCII comments and final-newline absence");
        check(Encoding.ASCII.GetString(bytes).Split("0.0.0.0 ").Length == 899, "The reviewed hosts payload contains exactly 898 accepted names");
        check(HostsBlock.Bytes(ControlComposition.Resolve(read with { Value = desired }, new(read, desired, read.Value), [claim], []).Desired).SequenceEqual(original), "Hosts restore removes only its exact owned block");
        var tampered = bytes.ToArray(); var position = Array.IndexOf(tampered, (byte)'0', 120); tampered[position] = (byte)'1';
        reject(() => HostsBlock.Read(tampered), "Editing an owned hosts payload fails its hash check");
        reject(() => HostsBlock.Read([.. bytes, .. bytes]), "Duplicate hosts markers are rejected");
        reject(() => HostsBlock.Read(Encoding.Unicode.GetBytes("127.0.0.1 localhost")), "UTF-16 hosts content is not silently re-encoded");
        var domain = Encoding.ASCII.GetString(bytes).Split('\n').First(line => line.StartsWith("0.0.0.0 ")).Split(' ')[1].Trim();
        var conflict = read with { Value = HostsBlock.Read(Encoding.ASCII.GetBytes("127.0.0.2 " + domain)) };
        reject(() => conflict.Expand(ControlValues.From(new { enabled = true })), "A conflicting pre-existing hosts mapping is preserved");
        var duplicate = read with { Value = HostsBlock.Read(Encoding.ASCII.GetBytes("0.0.0.0 " + domain)) };
        var filtered = duplicate.Expand(ControlValues.From(new { enabled = true }));
        check(!Encoding.ASCII.GetString(Convert.FromBase64String(filtered.GetProperty("block").GetString()!)).Contains("0.0.0.0 " + domain + "\r\n"), "Pre-existing matching hosts entries stay outside app ownership");
        var prefix = bytes.Take(1000).ToArray();
        check(HostsBlock.KnownPartial(prefix, original, bytes), "A known growing prefix is recognized as an interrupted hosts write");
        prefix[10] ^= 7;
        check(!HostsBlock.KnownPartial(prefix, original, bytes), "An unrelated edit cannot be treated as an interrupted hosts write");
        var path = Path.Combine(root, "hosts-profile.json"); var store = FileTweakStore.Create(path);
        var fixture = OperationFiles.Read<TweakFixture>(path); fixture.Controls.Add(address.Key, read); OperationFiles.Write(path, fixture);
        var catalog = new TweakCatalog(1, "hosts", [new("hosts", "Hosts", "Fixture", "Fixture", 10240, 26200, ["*"], "none", [new("on", "Block", [], Controls: [new(address, ControlValues.From(new { enabled = true }), true)])], [new("Roo Industries", "fixture", "hosts ownership")])], []);
        var engine = new TweakEngine(catalog, store);
        void Apply(string profile, params TweakSelection[] choices)
        {
            var plan = engine.Preview(profile, choices); var file = Path.Combine(root, plan.OperationId + ".json"); OperationFiles.Write(file, plan); engine.Apply(file, OperationFiles.HashFile(file));
        }
        Apply("one", new TweakSelection("hosts", "on")); Apply("two", new TweakSelection("hosts", "on")); Apply("one");
        check(store.ReadControl(address).Value.GetProperty("block").ValueKind == System.Text.Json.JsonValueKind.String, "Hosts block stays active until its last profile releases ownership");
        fixture = OperationFiles.Read<TweakFixture>(path);
        fixture.Controls[address.Key] = fixture.Controls[address.Key] with { Value = ControlValues.From(new { block = desired.GetProperty("block"), outside = Convert.ToBase64String(original.Concat(Encoding.ASCII.GetBytes("\r\n# external edit")).ToArray()) }) };
        OperationFiles.Write(path, fixture); Apply("two");
        check(Encoding.UTF8.GetString(HostsBlock.Bytes(store.ReadControl(address).Value)).EndsWith("# external edit"), "Last hosts owner preserves outside edits made after apply");
    }
    public static void Native(Action<bool, string> check, Action<Action, string> reject)
    {
        var root = Path.Combine(Path.GetTempPath(), "roo-industries-file-controls-" + Guid.NewGuid().ToString("N")); Directory.CreateDirectory(root);
        var path = Path.Combine(root, "hosts"); var original = Encoding.ASCII.GetBytes("127.0.0.1 localhost\r\n# original"); File.WriteAllBytes(path, original);
        File.WriteAllText(path + ":retained", "alternate stream");
        var address = new ControlAddress("hosts", "fixture:" + path, "adobe-block"); var store = new WindowsControlStore(); var before = store.Read(address);
        var claim = new ControlClaim("hosts", "on", before, before.Expand(ControlValues.From(new { enabled = true })), true);
        var desired = ControlComposition.Resolve(before, null, [], [claim]).Desired; var change = new ControlMutation(before, desired, ["block"]);
        var plan = new ControlPlan([before], [change], []);
        void Overwrite(byte[] bytes)
        {
            using var output = new FileStream(path, FileMode.Open, FileAccess.Write, FileShare.None);
            output.Write(bytes); output.SetLength(bytes.Length); output.Flush(true);
        }
        try
        {
            ControlExecution.Apply(plan, store, _ => { });
            check(store.Read(address).Binding == before.Binding && ControlValues.Equal(store.Read(address).Value, desired), "Native hosts write preserves file identity, permissions, attributes and alternate streams");
            File.AppendAllText(path, "\r\n# outside edit");
            ControlExecution.Rollback(plan, 1, store);
            check(File.ReadAllBytes(path).SequenceEqual(original.Concat(Encoding.ASCII.GetBytes("\r\n# outside edit"))), "Native hosts undo retains unrelated outside edits byte-for-byte");
            Overwrite(original);
            var partial = HostsBlock.Bytes(desired).Take(1000).ToArray(); Overwrite(partial);
            ControlExecution.Rollback(plan, 1, store);
            check(File.ReadAllBytes(path).SequenceEqual(original), "Native hosts recovery repairs a known interrupted prefix write");
            Overwrite(HostsBlock.Bytes(desired));
            var tampered = File.ReadAllBytes(path); tampered[140] ^= 1; Overwrite(tampered);
            var failed = false; try { ControlExecution.Rollback(plan, 1, store); } catch (InvalidOperationException) { failed = true; }
            check(failed && File.ReadAllBytes(path).SequenceEqual(tampered), "Native hosts recovery refuses an edited owned block without overwriting it");
            check(File.ReadAllText(path + ":retained") == "alternate stream", "Hosts round trip leaves alternate stream contents intact");
        }
        finally { Directory.Delete(root, true); }
        check(!Directory.Exists(root), "Native hosts fixture is removed after validation");
    }
}
