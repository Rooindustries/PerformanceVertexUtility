using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Linq;
using System.Threading.Tasks;
using CommunityToolkit.Mvvm.ComponentModel;
using RooIndustries.OptimizationSuite.Services;

namespace RooIndustries.OptimizationSuite.ViewModels;

public partial class ToolsDiagnosticsViewModel : PageViewModelBase
{
    private ToolLauncherService? _launcher;
    private readonly List<ToolRow> _all = new();
    [ObservableProperty] private string _search = "";
    [ObservableProperty] private string _category = "All tools";
    [ObservableProperty] private string _status = "";
    [ObservableProperty] private string _count = "";
    [ObservableProperty] private bool _busy;
    public string[] Categories { get; } = ["All tools", "Diagnostics", "Tuning", "System", "Drivers", "Game support"];
    public ObservableCollection<ToolRow> ToolRows { get; } = new();
    partial void OnSearchChanged(string value) => Filter();
    partial void OnCategoryChanged(string value) => Filter();

    protected override async Task LoadCoreAsync()
    {
        _launcher = new ToolLauncherService(App.Live.RepoRoot ?? throw new InvalidOperationException(ToolLauncherService.MissingFiles));
        _all.Clear();
        try { foreach (var tool in await _launcher.ReadAsync()) _all.Add(new(tool, _launcher.Resolve(tool))); }
        catch (Exception ex) { throw new InvalidOperationException(ToolLauncherService.ExplainList(ex), ex); }
        Filter();
    }

    private void Filter()
    {
        ToolRows.Clear();
        foreach (var row in _all.Where(t => (Category == "All tools" || t.Category == Category)
            && (t.Name + " " + t.Description).Contains(Search.Trim(), StringComparison.OrdinalIgnoreCase))) ToolRows.Add(row);
        Count = ToolRows.Count switch { 0 => "No tools match. Try another search or category.", 1 => "1 tool", var count => count + " tools" };
    }

    public async Task OpenAsync(ToolRow row)
    {
        if (_launcher is null || Busy) return;
        Busy = true;
        try { Status = await _launcher.OpenAsync(row.Definition); }
        catch (Exception ex)
        {
            AppLog.Write(nameof(ToolsDiagnosticsViewModel), row.Definition.Id + ": " + ex);
            Status = ToolLauncherService.Explain(row.Definition, ex);
        }
        finally { Busy = false; }
    }
}

public sealed class ToolRow
{
    public ToolDefinition Definition { get; }
    public string Name => Definition.Name;
    public string Description => Definition.Description;
    public string Category => Definition.Category;
    public string Action { get; }
    public string AccessibleAction => Action + " " + Name;
    public bool HasIcon => Definition.Icon is not null;
    public string Icon => "ms-appx:///Assets/Tools/" + Definition.Icon;
    public ToolRow(ToolDefinition definition, ToolTarget target) { Definition = definition; Action = target.Action; }
}
