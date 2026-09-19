#nullable enable
namespace RooIndustries.Optimizer;

public static class TweakDataEffects
{
    public static string[] Warnings(TweakClaim[] registry, ControlClaim[] controls)
    {
        var recall = registry.Any(claim => claim.Target.Address.Hive is "CurrentUser" or "LocalMachine" && claim.Target.Address.KeyPath.Equals(@"SOFTWARE\Policies\Microsoft\Windows\WindowsAI", StringComparison.OrdinalIgnoreCase) && claim.Desired is { Type: 4, Bytes.Length: 4 } value &&
            (claim.Target.Address.ValueName!.Equals("DisableAIDataAnalysis", StringComparison.OrdinalIgnoreCase) && BitConverter.ToUInt32(value.Bytes) == 1 || claim.Target.Address.Hive == "LocalMachine" && claim.Target.Address.ValueName!.Equals("AllowRecallEnablement", StringComparison.OrdinalIgnoreCase) && BitConverter.ToUInt32(value.Bytes) == 0));
        recall |= controls.Any(claim => claim.Target.Address.Kind == "windows-features" && claim.Desired.TryGetProperty("Recall", out var value) && value.GetString() != "Enabled");
        return recall ? ["Windows deletes saved Recall snapshots when this change takes effect. Restoring the setting cannot restore those snapshots."] : [];
    }
}
