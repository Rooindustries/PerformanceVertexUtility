#nullable enable
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace RooIndustries.Optimizer;

public sealed record PowerPlanReceipt([property: JsonRequired] OperationOwner Owner, [property: JsonRequired] Guid Plan, [property: JsonRequired] string Phase, [property: JsonRequired] string Fingerprint, [property: JsonRequired] Guid OriginalActive);

public static class PowerPlanControl
{
    public static readonly Guid Template = new("e9a42b02-d5df-448d-aa00-03f14749eb61");
    private static (Guid Id, string Receipt) Target(ControlAddress address)
    {
        if (address.Property != "selection") throw new InvalidDataException("Unknown power plan control.");
        if (address.Target.StartsWith("fixture:", StringComparison.Ordinal))
        {
            var root = FileAccessControl.FixturePath(address.Target[8..]);
            return (new("98472f39-9146-5073-8c16-73ea66ded98f"), Path.Combine(root, "power-plan.json"));
        }
        if (address.Target != "ultimate") throw new InvalidDataException("Unknown power plan target.");
        var owner = OperationOwner.Current();
        var id = new Guid(Convert.FromHexString(OperationFiles.Hash(Encoding.UTF8.GetBytes("RooIndustries:Ultimate:v1:" + owner)))[..16]);
        return (id, Path.Combine(BrandCompatibility.LocalDataRoot, "operations", "ultimate-plan.json"));
    }
    private static PowerPlanReceipt? Receipt(string path, Guid id)
    {
        if (!File.Exists(path)) return null;
        var receipt = OperationFiles.Read<PowerPlanReceipt>(path); receipt.Owner.Verify();
        if (receipt.Plan != id || receipt.Phase is not ("creating" or "created") || receipt.Fingerprint.Length != 64) throw new InvalidDataException("Power plan ownership evidence is incomplete.");
        return receipt;
    }
    public static TweakControlRead Read(ControlAddress address)
    {
        var target = Target(address); var exists = PowerSchemes.Schemes().Contains(target.Id); var receipt = Receipt(target.Receipt, target.Id);
        if (exists && receipt?.Phase != "created") throw new InvalidDataException("The destination power plan exists without confirmed Roo Industries creation. It will not be adopted or deleted.");
        return new(address, "power-selection:" + OperationOwner.Current().UserSid, target.Id.ToString("D"), ControlValues.From(new
        {
            active = PowerSchemes.Active().ToString("D"), plan = exists ? PowerSchemes.Fingerprint(target.Id) : null, template = PowerSchemes.Fingerprint(Template), original = (receipt?.OriginalActive ?? PowerSchemes.Active()).ToString("D"),
        }), "Ultimate Performance power plan");
    }
    public static JsonElement Expand(TweakControlRead before, JsonElement requested)
    {
        if (!requested.GetProperty("enabled").GetBoolean()) return ControlValues.From(new { active = before.Value.GetProperty("original").GetString(), plan = (string?)null });
        return ControlValues.From(new { active = before.Binding, plan = before.Value.GetProperty("template").GetString() });
    }
    public static void Write(TweakControlRead before, JsonElement desired)
    {
        var target = Target(before.Address); Directory.CreateDirectory(Path.GetDirectoryName(target.Receipt)!);
        using var guard = OperationFiles.Lock(target.Receipt);
        if (!Read(before.Address).Same(before)) throw new InvalidDataException("Power plan state changed after review.");
        var wanted = desired.GetProperty("plan").GetString(); var active = Guid.Parse(desired.GetProperty("active").GetString()!);
        var present = PowerSchemes.Schemes().Contains(target.Id);
        if (wanted is not null && !present)
        {
            if (PowerSchemes.Fingerprint(Template) != wanted) throw new InvalidDataException("The Ultimate template changed before duplication.");
            var intent = new PowerPlanReceipt(OperationOwner.Current(), target.Id, "creating", wanted, Guid.Parse(before.Value.GetProperty("original").GetString()!));
            OperationFiles.Write(target.Receipt, intent);
            try { PowerSchemes.Duplicate(Template, target.Id); }
            catch { if (!PowerSchemes.Schemes().Contains(target.Id)) File.Delete(target.Receipt); throw; }
            var actual = PowerSchemes.Fingerprint(target.Id);
            OperationFiles.Write(target.Receipt, intent with { Phase = "created", Fingerprint = actual });
            if (actual != wanted) throw new IOException("The duplicate power scheme differs from the reviewed template; its ownership receipt was retained.");
        }
        if (!PowerSchemes.Schemes().Contains(active)) throw new InvalidDataException("The requested original power scheme is no longer available.");
        if (PowerSchemes.Active() != Guid.Parse(before.Value.GetProperty("active").GetString()!)) throw new InvalidDataException("Another application selected a power scheme before activation.");
        if (PowerSchemes.Active() != active) PowerSchemes.Select(active);
        if (wanted is null && PowerSchemes.Schemes().Contains(target.Id))
        {
            var receipt = Receipt(target.Receipt, target.Id);
            if (receipt?.Phase != "created" || PowerSchemes.Fingerprint(target.Id) != receipt.Fingerprint) throw new InvalidDataException("The owned power scheme has outside changes and was retained.");
            PowerSchemes.Delete(target.Id); File.Delete(target.Receipt);
        }
    }
}
