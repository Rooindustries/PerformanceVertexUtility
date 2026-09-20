using System.Text.Json;
using RooIndustries.Optimizer;

static class MitigationChecks
{
    public static void Run(Action<bool, string> check, Action<Action, string> reject)
    {
        var address = new ControlAddress("mitigations", "system", "policy");
        var original = new TweakControlRead(address, address.Key, "fixture", MitigationControl.Snapshot(null, null, null));
        JsonElement Change(TweakControlRead before, Dictionary<string, object> patch) => ControlComposition.Resolve(before, null, [],
            [new("test", "set", before, before.Expand(ControlValues.From(patch)), true)]).Desired;
        var bottomUp = Change(original, new() { ["Aslr.BottomUp"] = "ON", ["Aslr.OverrideBottomUp"] = false });
        var raw = bottomUp.GetProperty(MitigationControl.SnapshotField);
        var bytes = raw.GetProperty("MitigationOptions").GetProperty("bytes").GetBytesFromBase64();
        check(bytes.Length == 24 && bytes[2] == 1 && bytes.Where((_, index) => index != 2).All(value => value == 0) &&
            raw.GetProperty("MitigationAuditOptions").ValueKind == JsonValueKind.Null && raw.GetProperty("EAFModules").ValueKind == JsonValueKind.Null,
            "ASLR updates only the selected normal-policy slot and retains audit and EAF absence");
        check(ControlValues.Equal(MitigationControl.RestoreFields(bottomUp, original.Value, ["Aslr.BottomUp", "Aslr.OverrideBottomUp"]), original.Value),
            "Mitigation recovery restores exact raw absence, not a zero-filled substitute");
        var seeded = new byte[24]; seeded[0] = 0x83; seeded[2] = 0x8b; seeded[9] = 0x52; seeded[23] = 0xc1;
        var eaf = new RegistryValueData("EAFModules", 1, [65, 0, 0, 0]);
        var existing = original with { Value = MitigationControl.Snapshot(new("MitigationOptions", 3, seeded), null, eaf) };
        check(existing.Value.GetProperty("Dep.Enable").GetString() == "ON" && existing.Value.GetProperty("Dep.EmulateAtlThunks").GetString() == "ON" &&
            existing.Value.GetProperty("Aslr.BottomUp").GetString() == "NOTSET", "Option-bearing and reserved state-three slots retain their distinct native meanings");
        check(ControlValues.Equal(MitigationControl.Reconcile(existing.Value), existing.Value), "Reading and reconciling a policy preserves unknown bits, bytes and native option flags");
        var changed = Change(existing, new() { ["Aslr.BottomUp"] = "ON", ["Aslr.OverrideBottomUp"] = true });
        var changedBytes = changed.GetProperty(MitigationControl.SnapshotField).GetProperty("MitigationOptions").GetProperty("bytes").GetBytesFromBase64();
        var expected = seeded.ToArray(); expected[2] = 0x8d;
        check(changedBytes.SequenceEqual(expected) && ControlValues.Equal(changed.GetProperty(MitigationControl.SnapshotField).GetProperty("EAFModules"), existing.Value.GetProperty(MitigationControl.SnapshotField).GetProperty("EAFModules")),
            "A mitigation change preserves reserved slot bits, CFG siblings, trailing bytes and original EAF content");
        check(ControlValues.Equal(MitigationControl.RestoreFields(changed, existing.Value, ["Aslr.BottomUp", "Aslr.OverrideBottomUp"]), existing.Value),
            "Recovery restores raw state-three slots even when typed readings cannot distinguish them from zero");
        var audit = Change(existing, new() { ["DynamicCode.Audit"] = "ON", ["DynamicCode.OverrideDynamicCode"] = false });
        var auditRaw = audit.GetProperty(MitigationControl.SnapshotField);
        var auditBytes = auditRaw.GetProperty("MitigationAuditOptions").GetProperty("bytes").GetBytesFromBase64();
        check(auditBytes[4] == 0x10 && auditBytes.Where((_, index) => index != 4).All(value => value == 0) && auditRaw.GetProperty("MitigationOptions").GetProperty("bytes").GetBytesFromBase64().SequenceEqual(seeded),
            "Audit selection updates the audit value without rewriting the normal policy");
        var subordinate = original.Expand(ControlValues.From(new Dictionary<string, object> { ["Aslr.RequireInfo"] = "ON" }));
        check(subordinate.GetProperty("Aslr.ForceRelocateImages").GetString() == "ON", "A subordinate mitigation reviews its required parent before execution");
        reject(() => original.Expand(ControlValues.From(new Dictionary<string, object> { ["Aslr.RequireInfo"] = "ON", ["Aslr.ForceRelocateImages"] = "OFF" })),
            "Contradictory parent and subordinate mitigation choices fail before writing");
        var disabled = existing.Expand(ControlValues.From(new Dictionary<string, object> { ["Dep.Enable"] = "OFF" }));
        check(disabled.GetProperty("Dep.EmulateAtlThunks").GetString() == "OFF", "Disabling a parent includes its dependent option in the review");
        var externalBytes = bottomUp.GetProperty(MitigationControl.SnapshotField).GetProperty("MitigationOptions").GetProperty("bytes").GetBytesFromBase64(); externalBytes[9] = 1;
        var external = MitigationControl.Snapshot(new("MitigationOptions", 3, externalBytes), null, eaf);
        var restored = MitigationControl.RestoreFields(external, original.Value, ["Aslr.BottomUp"]);
        var restoredRaw = restored.GetProperty(MitigationControl.SnapshotField);
        check(restoredRaw.GetProperty("MitigationOptions").GetProperty("bytes").GetBytesFromBase64()[9] == 1 && restored.GetProperty("Aslr.BottomUp").GetString() == "NOTSET" &&
            restoredRaw.GetProperty("EAFModules").GetProperty("bytes").GetBytesFromBase64().SequenceEqual(eaf.Bytes), "Field recovery retains newer independent policy and EAF edits");
    }
}
