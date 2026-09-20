using System;
using System.Collections.Generic;
using System.IO;
using System.Text.Json;
using CommunityToolkit.Mvvm.ComponentModel;
using RooIndustries.Optimizer;

namespace RooIndustries.OptimizationSuite.ViewModels;

public partial class TweakSection : ObservableObject
{
    public string Id { get; }
    public string Name { get; }
    public string Description { get; }
    public string Icon => "ms-appx:///Assets/Icons/tweak-" + Id + ".svg";
    [ObservableProperty] private int _count;
    [ObservableProperty] private int _selectedCount;
    public string Selection => SelectedCount == 0 ? "" : SelectedCount + " selected";
    partial void OnSelectedCountChanged(int value) => OnPropertyChanged(nameof(Selection));
    public TweakSection(string id, string name, string description) { Id = id; Name = name; Description = description; }
    public override string ToString() => Name;
}

public sealed record TweakPresentation(string Section, string? Name = null, string? Description = null, string? Topic = null, Dictionary<string, string>? Choices = null, string? Summary = null);

public static class WindowsTweakPresentation
{
    private static readonly Lazy<Dictionary<string, TweakPresentation>> Entries = new(() =>
    {
        using var stream = typeof(WindowsTweakPresentation).Assembly.GetManifestResourceStream("RooIndustries.TweakPresentation.json") ?? throw new FileNotFoundException("The setting descriptions are missing.");
        return JsonSerializer.Deserialize<Dictionary<string, TweakPresentation>>(stream, OperationFiles.Json) ?? throw new InvalidDataException("The setting descriptions are incomplete.");
    });
    private static readonly Lazy<Dictionary<string, string>> Icons = new(() =>
    {
        using var stream = typeof(WindowsTweakPresentation).Assembly.GetManifestResourceStream("RooIndustries.TweakIcons.json") ?? throw new FileNotFoundException("The setting icons are missing.");
        return JsonSerializer.Deserialize<Dictionary<string, string>>(stream) ?? throw new InvalidDataException("The setting icons are incomplete.");
    });
    public static string Icon(TweakDefinition definition) => Icons.Value.TryGetValue(definition.Id, out var asset)
        ? "ms-appx:///Assets/Icons/Settings/" + asset
        : "ms-appx:///Assets/Icons/tweak-" + For(definition).Section + ".svg";
    public static TweakSection[] Sections() =>
    [
        new("all", "All tweaks", "Search every setting in one place."),
        new("gaming", "Gaming", "Game, display, and processor preferences."),
        new("network", "Network", "Connection preferences, DNS, and network protection."),
        new("debloat", "Debloat", "Remove unwanted apps and reduce bundled extras and suggestions."),
        new("apps", "Apps", "Browser and application preferences."),
        new("privacy", "Privacy", "Choose what Windows and your apps can access or share."),
        new("windows", "Windows", "Desktop, File Explorer, and system preferences."),
        new("updates", "Updates", "Choose how Windows downloads and installs updates."),
        new("devices", "Devices", "Input, sound, and connected-device preferences."),
        new("security", "Security", "Windows protection and sign-in settings."),
        new("services", "Services", "Background services and scheduled activity."),
    ];
    public static TweakPresentation For(TweakDefinition definition) => Entries.Value.GetValueOrDefault(definition.Id) ?? new(definition.Category switch
    {
        "Network" => "network", "Privacy" => "privacy", "Security" => "security", "Services" or "Scheduled tasks" => "services",
        "Gaming and display" => "gaming", "Devices" => "devices", "Windows Update" => "updates", "Apps and browsers" => "apps", _ => "windows",
    });
    public static string Choice(TweakDefinition definition, TweakOption option) => For(definition).Choices?.GetValueOrDefault(option.Id) ?? option.Name;
}
