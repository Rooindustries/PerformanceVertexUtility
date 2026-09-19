using System;
using System.Collections.Generic;
using System.Globalization;

namespace RooIndustries.OptimizationSuite.Helpers;

public static class Naming
{
    private static readonly Dictionary<string, string> KnownApps = new(StringComparer.OrdinalIgnoreCase)
    {
        ["FortniteClient-Win64-Shipping"] = "Fortnite",
        ["Marvel-Win64-Shipping"] = "Marvel Rivals",
        ["discord"] = "Discord",
        ["discordcanary"] = "Discord Canary",
        ["discordptb"] = "Discord PTB",
        ["vivaldi"] = "Vivaldi",
        ["chrome"] = "Google Chrome",
        ["msedge"] = "Microsoft Edge",
        ["msedgewebview2"] = "Microsoft Edge WebView2",
        ["firefox"] = "Firefox",
        ["brave"] = "Brave",
        ["opera"] = "Opera",
        ["obs64"] = "OBS Studio",
        ["obs32"] = "OBS Studio",
        ["streamlabs desktop"] = "Streamlabs",
        ["steam"] = "Steam",
        ["steamwebhelper"] = "Steam",
        ["battle.net"] = "Battle.net",
        ["epicgameslauncher"] = "Epic Games Launcher",
        ["riotclientservices"] = "Riot Client",
        ["explorer"] = "Windows Explorer",
        ["spotify"] = "Spotify",
        ["tailscale-ipn"] = "Tailscale",
        ["tailscale"] = "Tailscale",
    };

    private static readonly HashSet<string> NonActionable = new(StringComparer.OrdinalIgnoreCase)
    {
        "memory compression", "system", "system idle process", "registry", "secure system",
        "smss", "csrss", "wininit", "winlogon", "services", "lsass", "fontdrvhost", "dwm",
        "sihost", "taskhostw", "runtimebroker", "searchindexer", "searchhost", "ctfmon",
        "shellexperiencehost", "startmenuexperiencehost", "textinputhost", "applicationframehost",
        "rooindustries.optimizationsuite.app", "dotnet", "conhost", "powershell", "pwsh",
        "windowsterminal", "openconsole", "node", "msbuild",
    };

    public static string FriendlyName(string? rawName)
    {
        if (string.IsNullOrWhiteSpace(rawName))
        {
            return "Unknown app";
        }

        var name = rawName.Trim();
        if (name.EndsWith(".exe", StringComparison.OrdinalIgnoreCase))
        {
            name = name[..^4];
        }

        if (KnownApps.TryGetValue(name, out var known))
        {
            return known;
        }

        if (name.Length == 0)
        {
            return rawName;
        }

        if (name.Length <= 3)
        {
            return name.ToUpperInvariant();
        }

        return char.ToUpper(name[0], CultureInfo.InvariantCulture) + name[1..];
    }

    public static bool IsNonActionable(string? rawName)
    {
        if (string.IsNullOrWhiteSpace(rawName))
        {
            return true;
        }

        var name = rawName.Trim();
        if (name.EndsWith(".exe", StringComparison.OrdinalIgnoreCase))
        {
            name = name[..^4];
        }

        return NonActionable.Contains(name);
    }

    public static string CategoryLabel(string? category) => category switch
    {
        "foregroundGame" => "Game",
        "captureStreaming" => "Capture",
        "voiceChat" => "Voice chat",
        "launcher" => "Launcher",
        "browserWebView" => "Browser",
        "vendorUtility" => "Vendor app",
        "security" => "Security",
        "network" => "Network",
        "audioInput" => "Audio",
        "windowsCore" => "Windows",
        _ => "Background",
    };
}
