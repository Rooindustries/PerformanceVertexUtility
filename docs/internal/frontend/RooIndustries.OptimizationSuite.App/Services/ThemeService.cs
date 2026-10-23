using System;
using System.Collections.Generic;
using System.Linq;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;

namespace RooIndustries.OptimizationSuite.Services;

public sealed record ThemeOption(string Id, string Name, string ResourceUri);

public sealed class ThemeService
{
    private const string ThemeKey = "themeId";
    private const string EffectsKey = "reducedEffects";
    private const string SimpleModeKey = "simpleMode";
    private const string ProbeBrushKey = "RooIndustriesCanvasBrush";

    public static readonly ThemeOption RooIndustriesBlue = new("roo-industries-blue", "Blue", "ms-appx:///Resources/Theme.RooIndustriesBlue.xaml");
    public static readonly ThemeOption BlackoutGold = new("black-gold", "Blackout Gold", "ms-appx:///Resources/Theme.BlackoutGold.xaml");

    private readonly SettingsStore _settings;

    public IReadOnlyList<ThemeOption> Options { get; } = new[] { RooIndustriesBlue, BlackoutGold };
    public string CurrentThemeId { get; private set; } = BlackoutGold.Id;
    public bool ReducedEffects { get; private set; }

    public event Action? ThemeChanged;
    public event Action? EffectsChanged;
    public event Action? SimpleModeChanged;
    public bool SimpleMode { get; private set; } = true;

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
        SimpleMode = _settings.Get(SimpleModeKey) != "0";
        var live = LiveTheme();
        if (option.Id != BlackoutGold.Id)
        {
            Repaint(live, option);
        }
#if ROO_INDUSTRIES_TEST_HOOKS
        RecordThemeKeys("start");
#endif
    }

    public void SetSimpleMode(bool simple)
    {
        if (simple == SimpleMode)
        {
            return;
        }

        SimpleMode = simple;
        _settings.Set(SimpleModeKey, simple ? "1" : "0");
        SimpleModeChanged?.Invoke();
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

        Repaint(LiveTheme(), option);
        CurrentThemeId = option.Id;
#if ROO_INDUSTRIES_TEST_HOOKS
        RecordThemeKeys("switch");
#endif
        _settings.Set(ThemeKey, option.Id);
        ThemeChanged?.Invoke();
    }

    private static ResourceDictionary LiveTheme()
    {
        var merged = Application.Current.Resources.MergedDictionaries;
        var index = Enumerable.Range(0, merged.Count).First(i => merged[i].ContainsKey(ProbeBrushKey));
        var loaded = merged[index];
        if (loaded.Source is null)
        {
            return loaded;
        }

        var live = new ResourceDictionary();
        foreach (var (key, value) in loaded.ToArray())
        {
            loaded.Remove(key);
            live[key] = value;
        }

        merged[index] = live;
        return live;
    }

#if ROO_INDUSTRIES_TEST_HOOKS
    private void RecordThemeKeys(string when)
    {
        if (Environment.GetEnvironmentVariable("ROO_INDUSTRIES_TEST_THEME_KEYS") is not { Length: > 0 } path) return;
        var keys = LiveTheme().Keys.Select(key => key.ToString()).Order(StringComparer.Ordinal);
        System.IO.File.AppendAllText(path, when + "\t" + CurrentThemeId + "\t" + string.Join(",", keys) + Environment.NewLine);
    }
#endif

    private static void Repaint(ResourceDictionary live, ThemeOption option)
    {
        var next = new ResourceDictionary { Source = new Uri(option.ResourceUri) };
        var liveKeys = live.Keys.ToHashSet();
        var nextKeys = next.Keys.ToHashSet();
        foreach (var key in liveKeys.Where(key => !nextKeys.Contains(key)))
        {
            live.Remove(key);
        }

        foreach (var (key, value) in next.ToArray())
        {
            if (liveKeys.Contains(key) && Copy(value, live[key]))
            {
                continue;
            }

            next.Remove(key);
            live[key] = value;
        }
    }

    private static bool Copy(object source, object target)
    {
        switch (source, target)
        {
            case (SolidColorBrush from, SolidColorBrush to):
                to.Color = from.Color;
                to.Opacity = from.Opacity;
                return true;
            case (LinearGradientBrush from, LinearGradientBrush to):
                to.StartPoint = from.StartPoint;
                to.EndPoint = from.EndPoint;
                to.Opacity = from.Opacity;
                CopyStops(from.GradientStops, to.GradientStops);
                return true;
            case (RadialGradientBrush from, RadialGradientBrush to):
                to.Center = from.Center;
                to.GradientOrigin = from.GradientOrigin;
                to.RadiusX = from.RadiusX;
                to.RadiusY = from.RadiusY;
                to.Opacity = from.Opacity;
                CopyStops(from.GradientStops, to.GradientStops);
                return true;
            default:
                return false;
        }
    }

    private static void CopyStops(IList<GradientStop> from, IList<GradientStop> to)
    {
        to.Clear();
        foreach (var stop in from)
        {
            to.Add(new GradientStop { Color = stop.Color, Offset = stop.Offset });
        }
    }
}
