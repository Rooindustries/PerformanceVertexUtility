using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Threading.Tasks;
using CommunityToolkit.Mvvm.ComponentModel;
using Roo.OptimizationSuite.Models;
using Roo.OptimizationSuite.Services;

namespace Roo.OptimizationSuite.ViewModels;

public partial class SettingsViewModel : PageViewModelBase
{
    [ObservableProperty] private string _selectedThemeId;
    [ObservableProperty] private bool _reducedEffects;
    [ObservableProperty] private string? _productName;
    [ObservableProperty] private string? _versionText;
    [ObservableProperty] private string? _engineStatus;

    public string Tagline => "Precision Performance Engineering";
    public IReadOnlyList<ThemeOption> Themes => App.Theme.Options;
    public ObservableCollection<SafetyRow> SafetyRows { get; } = new();
    public ObservableCollection<StatusLine> EngineRows { get; } = new();

    public SettingsViewModel()
    {
        _selectedThemeId = App.Theme.CurrentThemeId;
        _reducedEffects = App.Theme.ReducedEffects;
    }

    protected override async Task LoadCoreAsync()
    {
        var product = await Data.GetProductStatusAsync();
        ProductName = string.IsNullOrWhiteSpace(product.ProductName) ? "Roo Industries Optimization Suite" : product.ProductName;
        VersionText = "Version " + (product.BackendPackageVersion?.Replace("-contracts", string.Empty) ?? "0.1.0");
        EngineStatus = ReadyLabel(product.Status) + " / Engine " + (product.BackendPackageVersion?.Replace("-contracts", string.Empty) ?? "0.1.0");
        BuildSafetyRows(product.Safety);
        BuildEngineRows(product.WorkflowReadiness);
    }

    private void BuildEngineRows(System.Collections.Generic.IReadOnlyList<WorkflowReadiness>? readiness)
    {
        EngineRows.Clear();
        if (readiness is null)
        {
            return;
        }

        foreach (var workflow in readiness)
        {
            var (label, value, state) = DescribeWorkflow(workflow);
            EngineRows.Add(new StatusLine(label, value, state));
        }
    }

    private static (string label, string value, string state) DescribeWorkflow(WorkflowReadiness workflow)
    {
        var label = (workflow.WorkflowId ?? string.Empty) switch
        {
            "performanceProfiles" => "Game Tune",
            "processGovernor" => "ProBalance guard",
            "persistentProcessPolicy" => "Process rules",
            "uninstallCleanup" => "Apps & Cleanup",
            "driversProfiles" => "Drivers & GPU",
            _ => string.IsNullOrWhiteSpace(workflow.Name) ? "Workflow" : workflow.Name!,
        };

        var (value, state) = (workflow.ImplementationStatus ?? string.Empty) switch
        {
            "preview-dry-run-confirmed-process-controls-and-live-restore" => ("Check, apply, restore", "safe"),
            "bounded-session-preview-confirmed-restraint-status-and-restore" => ("Start, watch, restore", "safe"),
            "bounded-session-preview-confirmed-launch-watcher-status-and-restore" => ("Launch watch and restore", "safe"),
            "sample-and-read-only-inventory" => ("Path, scan, approve", "safe"),
            "sample-and-read-only-hardware-inventory" => ("Hardware gate and profile check", "safe"),
            _ => ("In development", "low"),
        };

        return (label, value, state);
    }

    private static string ReadyLabel(string? status) => (status ?? string.Empty) switch
    {
        "preview-ready" => "Action paths ready",
        "ready" => "Ready",
        "" => "Status unavailable",
        _ => status!,
    };

    private void BuildSafetyRows(SafetyStatus? safety)
    {
        SafetyRows.Clear();
        if (safety is null)
        {
            return;
        }

        SafetyRows.Add(new SafetyRow("Default mode", "Review first", "safe"));
        SafetyRows.Add(new SafetyRow("Ask before changes", safety.RequiresExplicitConfirmation ? "On" : "Off", safety.RequiresExplicitConfirmation ? "safe" : "high"));
        SafetyRows.Add(new SafetyRow("Back up before changes", safety.BackupRequiredBeforeApply ? "On" : "Off", safety.BackupRequiredBeforeApply ? "safe" : "high"));
        SafetyRows.Add(new SafetyRow("One-click undo", safety.RollbackVisible ? "On" : "Off", safety.RollbackVisible ? "safe" : "medium"));
        SafetyRows.Add(new SafetyRow("Remote scripts", safety.RemoteScriptExecutionAllowed ? "Allowed" : "Blocked", safety.RemoteScriptExecutionAllowed ? "high" : "safe"));
        SafetyRows.Add(new SafetyRow("Automatic driver changes", safety.DriverAutomationAllowed ? "Allowed" : "Blocked", safety.DriverAutomationAllowed ? "high" : "safe"));
        SafetyRows.Add(new SafetyRow("Leftover removal", safety.LeftoverDeletionAllowedByDefault ? "On" : "Approve first", safety.LeftoverDeletionAllowedByDefault ? "high" : "safe"));
    }

    partial void OnSelectedThemeIdChanged(string value) => App.Theme.SetTheme(value);

    partial void OnReducedEffectsChanged(bool value) => App.Theme.SetReducedEffects(value);
}
