using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Threading.Tasks;
using CommunityToolkit.Mvvm.ComponentModel;

namespace Roo.OptimizationSuite.ViewModels;

public partial class ToolsDiagnosticsViewModel : PageViewModelBase
{
    [ObservableProperty] private string _bundleSummary = "Reading the utilities review…";
    [ObservableProperty] private int _toolCount;
    [ObservableProperty] private int _nativeCount;
    [ObservableProperty] private int _manualCount;

    public ObservableCollection<ToolRow> ToolRows { get; } = new();

    protected override async Task LoadCoreAsync()
    {
        var manifest = await LoadManifestAsync();
        var tools = manifest?.Tools ?? new List<UtilityTool>();
        var counts = await LoadCatalogCountsAsync();

        ToolCount = tools.Count;
        NativeCount = tools.Count(t => t.ExecutionClass == "native-replacement");
        ManualCount = tools.Count(t => t.ExecutionClass is "manual-launcher" or "dangerous-manual-only");
        BundleSummary = counts is null
            ? tools.Count + " bundled tools reviewed and classified. Nothing on this page launches anything."
            : counts.Value.entries + " files in the utilities bundle · " + counts.Value.executables
              + " executables and scripts · every one reviewed and classified. Nothing on this page launches anything.";

        ToolRows.Clear();
        foreach (var tool in tools
            .OrderBy(t => ClassRank(t.ExecutionClass))
            .ThenBy(t => t.Name, StringComparer.OrdinalIgnoreCase))
        {
            ToolRows.Add(new ToolRow(
                string.IsNullOrWhiteSpace(tool.Name) ? tool.Id ?? "Tool" : tool.Name!,
                string.IsNullOrWhiteSpace(tool.IntegrationPlan) ? "Reviewed for this bundle." : tool.IntegrationPlan!,
                ClassLabel(tool.ExecutionClass),
                ClassState(tool.ExecutionClass)));
        }

        IsEmpty = ToolRows.Count == 0;
    }

    private static string ClassLabel(string? cls) => cls switch
    {
        "native-replacement" => "Roo does this natively",
        "read-only-detector" => "Read-only detector",
        "controlled-reversible-executor" => "Controlled · reversible",
        "manual-launcher" => "Manual tool",
        "dangerous-manual-only" => "Dangerous — manual only",
        "excluded" => "Excluded",
        _ => "Reviewed",
    };

    private static string ClassState(string? cls) => cls switch
    {
        "native-replacement" => "safe",
        "read-only-detector" => "low",
        "controlled-reversible-executor" => "low",
        "manual-launcher" => "neutral",
        "dangerous-manual-only" => "high",
        "excluded" => "high",
        _ => "neutral",
    };

    private static int ClassRank(string? cls) => cls switch
    {
        "native-replacement" => 0,
        "controlled-reversible-executor" => 1,
        "read-only-detector" => 2,
        "manual-launcher" => 3,
        "dangerous-manual-only" => 4,
        "excluded" => 5,
        _ => 6,
    };

    private static async Task<UtilityManifest?> LoadManifestAsync()
    {
        var root = App.Live.RepoRoot;
        if (root is null)
        {
            return null;
        }

        var path = Path.Combine(root, "modules", "utilities_manifest.json");
        if (!File.Exists(path))
        {
            return null;
        }

        try
        {
            await using var stream = File.OpenRead(path);
            return await JsonSerializer.DeserializeAsync<UtilityManifest>(stream,
                new JsonSerializerOptions { PropertyNameCaseInsensitive = true });
        }
        catch
        {
            return null;
        }
    }

    private static async Task<(int entries, int executables)?> LoadCatalogCountsAsync()
    {
        var root = App.Live.RepoRoot;
        if (root is null)
        {
            return null;
        }

        foreach (var candidate in new[]
        {
            Path.Combine(root, "backend", "catalogs", "utilities-bundle-catalog.json"),
            Path.Combine(root, "backend", "samples", "utilities-bundle-catalog.sample.json"),
        })
        {
            if (!File.Exists(candidate))
            {
                continue;
            }

            try
            {
                await using var stream = File.OpenRead(candidate);
                var header = await JsonSerializer.DeserializeAsync<UtilityCatalogHeader>(stream,
                    new JsonSerializerOptions { PropertyNameCaseInsensitive = true });
                if (header is { EntryCount: > 0 })
                {
                    return (header.EntryCount, header.ExecutableScriptCount);
                }
            }
            catch
            {
            }
        }

        return null;
    }
}

public sealed record ToolRow(string Name, string Plan, string ClassText, string State);

public sealed class UtilityManifest
{
    [JsonPropertyName("tools")] public List<UtilityTool>? Tools { get; set; }
}

public sealed class UtilityTool
{
    [JsonPropertyName("id")] public string? Id { get; set; }
    [JsonPropertyName("name")] public string? Name { get; set; }
    [JsonPropertyName("executionClass")] public string? ExecutionClass { get; set; }
    [JsonPropertyName("risk")] public string? Risk { get; set; }
    [JsonPropertyName("integrationPlan")] public string? IntegrationPlan { get; set; }
}

public sealed class UtilityCatalogHeader
{
    [JsonPropertyName("entryCount")] public int EntryCount { get; set; }
    [JsonPropertyName("executableScriptCount")] public int ExecutableScriptCount { get; set; }
}
