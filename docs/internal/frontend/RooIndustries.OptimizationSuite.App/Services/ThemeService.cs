using System;
using System.Collections.Generic;
using System.Linq;
using Microsoft.UI.Xaml;

namespace RooIndustries.OptimizationSuite.Services;

public sealed record ThemeOption(string Id, string Name, string ResourceUri);

public sealed class ThemeService
{
    private const string ThemeKey = "themeId";
    private const string EffectsKey = "reducedEffects";
    private const string ProbeBrushKey = "RooIndustriesCanvasBrush";
    private const string StylesUri = "ms-appx:///Resources/Styles.xaml";
    private const string StylesProbeKey = "PanelBorderStyle";

    public static readonly ThemeOption RooIndustriesBlue = new("roo-industries-blue", "Roo Industries Blue", "ms-appx:///Resources/Theme.RooIndustriesBlue.xaml");
    public static readonly ThemeOption BlackoutGold = new("black-gold", "Blackout Gold", "ms-appx:///Resources/Theme.BlackoutGold.xaml");

    private readonly SettingsStore _settings;

    public IReadOnlyList<ThemeOption> Options { get; } = new[] { RooIndustriesBlue, BlackoutGold };
    public string CurrentThemeId { get; private set; } = BlackoutGold.Id;
    public bool ReducedEffects { get; private set; }

    public event Action? ThemeChanged;
    public event Action? EffectsChanged;

    public ThemeService(SettingsStore settings)
    {
        _settings = settings;
    }

    public void ApplyPersistedTheme()
    {
        var stored = _settings.Get(ThemeKey);
        if (stored == RooIndustries.Optimizer.BrandCompatibility.LegacyTheme) stored = RooIndustriesBlue.Id;
        var option = Options.FirstOrDefault(o => o.Id == stored) ?? BlackoutGold;
        CurrentThemeId = option.Id;
        ReducedEffects = _settings.Get(EffectsKey) == "1";
        if (option.Id != BlackoutGold.Id)
        {
            SwapDictionary(option);
        }
    }

    public void SetReducedEffects(bool reduced)
    {
        if (reduced == ReducedEffects)
        {
            return;
        }

        ReducedEffects = reduced;
        _settings.Set(EffectsKey, reduced ? "1" : "0");
        EffectsChanged?.Invoke();
    }

    public void SetTheme(string themeId)
    {
        if (themeId == CurrentThemeId)
        {
            return;
        }

        var option = Options.FirstOrDefault(o => o.Id == themeId);
        if (option is null)
        {
            return;
        }

        SwapDictionary(option);
        CurrentThemeId = option.Id;
        _settings.Set(ThemeKey, option.Id);
        ThemeChanged?.Invoke();
    }

    private static void SwapDictionary(ThemeOption option)
    {
        var merged = Application.Current.Resources.MergedDictionaries;
        var replacement = new ResourceDictionary { Source = new Uri(option.ResourceUri) };

        var swapped = false;
        for (var i = 0; i < merged.Count; i++)
        {
            if (merged[i].ContainsKey(ProbeBrushKey))
            {
                merged[i] = replacement;
                swapped = true;
                break;
            }
        }

        if (!swapped)
        {
            merged.Add(replacement);
        }

        ReloadStyles(merged);
    }

    private static void ReloadStyles(IList<ResourceDictionary> merged)
    {
        for (var i = 0; i < merged.Count; i++)
        {
            if (!merged[i].ContainsKey(StylesProbeKey))
            {
                continue;
            }

            var fresh = new ResourceDictionary();
            merged[i] = fresh;
            fresh.Source = new Uri(StylesUri);
            return;
        }
    }
}
