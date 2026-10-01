using System;
using System.Threading.Tasks;
using RooIndustries.Optimizer;

namespace RooIndustries.OptimizationSuite.Services;

public static class EarlierVersionConsent
{
    public static Func<string, Task<bool>>? Ask { get; set; }

    public static async Task<bool> RequireAsync(string file)
    {
        if (!PolicyRootSecurity.SavedBeforeProtection(file)) return false;
        var ask = Ask;
        if (ask is not null && await ask(EarlierVersion.Line + "\n\nOnly continue if you made these changes yourself with this app.").ConfigureAwait(false)) return true;
        throw new EarlierVersionException(EarlierVersion.Refusal);
    }
}
