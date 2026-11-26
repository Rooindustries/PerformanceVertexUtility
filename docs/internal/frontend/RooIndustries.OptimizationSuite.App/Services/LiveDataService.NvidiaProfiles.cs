using System;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.Json;
using System.Threading.Tasks;

namespace RooIndustries.OptimizationSuite.Services;

public sealed partial class LiveDataService
{
    private async Task<string?> CurrentNvidiaProfileIdAsync(NvidiaProfileRecovery recovery)
    {
        if (NvidiaCatalogProfileId(recovery.ProfileId) is not { } profileId) return null;
        var current = await ReadNvidiaProfileRecoveryAsync(profileId).ConfigureAwait(false);
        return ValidNvidiaRecovery(recovery, profileId) && current == recovery ? profileId : null;
    }

    private bool ValidNvidiaRecovery(NvidiaProfileRecovery? recovery, string profileId)
        => recovery is not null && NvidiaCatalogProfileId(recovery.ProfileId) == profileId
            && ValidateNvidiaRecovery(recovery, recovery.ProfileId);

    private string? NvidiaCatalogProfileId(string savedId)
    {
        if (_locator.CatalogsDirectory is not { } catalogs) return savedId;
        var bytes = Encoding.UTF8.GetBytes(savedId);
        var digest = Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(bytes));
        try
        {
            var path = Path.Combine(catalogs, "nvidia-profile-inspector-nip-catalog.json");
            using var doc = JsonDocument.Parse(File.ReadAllText(path));
            foreach (var profile in doc.RootElement.GetProperty("profiles").EnumerateArray())
            {
                var current = NvidiaString(profile, "profileId");
                if (current == savedId) return current;
                if (profile.TryGetProperty("formerProfileIdSha256", out var former)
                    && former.EnumerateArray()
                        .Any(item => digest.Equals(item.GetString(), StringComparison.OrdinalIgnoreCase)))
                    return current;
            }
            return null;
        }
        catch
        {
            return savedId;
        }
    }
}
