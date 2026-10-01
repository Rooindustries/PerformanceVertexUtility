using System;
using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Linq;
using System.Threading.Tasks;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using RooIndustries.OptimizationSuite.Models;
using RooIndustries.OptimizationSuite.Helpers;

namespace RooIndustries.OptimizationSuite.ViewModels;

public sealed record CpuProcessChoice(int Id, string Name)
{
    public override string ToString() => $"{Naming.FriendlyName(Name)} · PID {Id}";
}

public partial class CpuChoice : ObservableObject
{
    public CpuSetInfo Cpu { get; }
    [ObservableProperty] private bool _selected;
    public CpuChoice(CpuSetInfo cpu, bool selected) { Cpu = cpu; _selected = selected; }
}

public partial class CpuSetsViewModel : ObservableObject
{
    public ObservableCollection<CpuProcessChoice> Processes { get; } = new();
    public ObservableCollection<CpuChoice> Cpus { get; } = new();
    [ObservableProperty] private CpuProcessChoice? _selectedProcess;
    [ObservableProperty] private bool _useWindowsDefault = true;
    [ObservableProperty] private bool _busy;
    [ObservableProperty] private bool _hasReview;
    [ObservableProperty] private bool _restoreAvailable;
    [ObservableProperty] private string _status = "Choose an application to inspect its CPU selection.";
    [ObservableProperty] private string _detail = "CPU preferences use Windows scheduling controls. Some applications may deny changes.";
    [ObservableProperty] private string _reviewSummary = "";
    [ObservableProperty] private string _restoreLabel = "Restore";
    private CpuSetReview? _review;
    private string? _journal;
    private bool _loadingSelection;
    private int _selectionVersion;

    public bool CanChooseProcess => !Busy && !RestoreAvailable;
    public bool CanChooseCpus => !Busy && !RestoreAvailable && !UseWindowsDefault && SelectedProcess is not null;
    public bool CanPreview => !Busy && !RestoreAvailable && SelectedProcess is not null && (UseWindowsDefault || Cpus.Any(cpu => cpu.Selected));
    public bool CanApply => !Busy && HasReview && !RestoreAvailable;
    public bool CanRestore => !Busy && RestoreAvailable;
    partial void OnBusyChanged(bool value) => RefreshCommands();
    partial void OnHasReviewChanged(bool value) => RefreshCommands();
    partial void OnRestoreAvailableChanged(bool value) => RefreshCommands();
    partial void OnUseWindowsDefaultChanged(bool value) { InvalidateReview(); RefreshCommands(); }
    public void NoteChanged()
    {
        Status = "Settings changed elsewhere";
        Detail = "Choose the application again, or clear it, to read its current CPU selection.";
    }
    partial void OnSelectedProcessChanged(CpuProcessChoice? value)
    {
        InvalidateReview();
        _ = ReadSelectionAsync(value, ++_selectionVersion);
    }

    public async Task InitializeAsync()
    {
        try
        {
            await RefreshAsync();
            _journal = App.Operations.FindLastJournal("cpu");
            if (_journal is not null)
            {
                var saved = await Services.OptimizerService.ReadJournalAsync<CpuSetJournal>(_journal);
                RestoreAvailable = saved?.Status is "applied" or "apply-intent" or "restore-intent" or "needs-reconciliation";
                if (RestoreAvailable)
                {
                    if (await App.Operations.ReleaseEndedCpuSessionAsync(_journal)) ShowEndedSession();
                    else
                    {
                        RestoreLabel = "Restore " + saved!.Preview.Identity.DisplayName;
                        Status = "A previous CPU selection can be restored.";
                        Detail = "Restore the saved selection before applying another one.";
                    }
                }
            }
        }
        catch (Exception error) { Status = "Couldn't read saved CPU controls."; Detail = error.Message; }
    }

    [RelayCommand]
    private async Task RefreshAsync()
    {
        if (Busy) return;
        Busy = true;
        try
        {
            var inventory = await App.Live.GetProcessInventoryAsync();
            if (inventory?.Processes is null) throw new InvalidOperationException(App.Live.LastError ?? "The process list is unavailable.");
            Processes.Clear();
            foreach (var process in inventory.Processes.Where(p => p.Pid > 0 && p.Pid != Environment.ProcessId && p.Category != "windowsCore" && !p.Protected && !p.Blocked).OrderBy(p => p.Name, StringComparer.OrdinalIgnoreCase))
                Processes.Add(new CpuProcessChoice(process.Pid, process.Name ?? "Process"));
        }
        catch (Exception error) { Status = "Couldn't refresh processes."; Detail = error.Message; }
        finally { Busy = false; }
    }

    private async Task ReadSelectionAsync(CpuProcessChoice? process, int version)
    {
        Cpus.Clear();
        if (process is null) { RefreshCommands(); return; }
        Busy = true;
        try
        {
            var result = await App.Operations.ReadCpuSetsAsync(process.Id);
            if (version != _selectionVersion) return;
            var snapshot = result.Data ?? throw new InvalidOperationException("CPU information was not returned.");
            _loadingSelection = true;
            UseWindowsDefault = snapshot.CpuSetIds.Length == 0;
            foreach (var cpu in snapshot.Topology.OrderBy(cpu => cpu.Group).ThenBy(cpu => cpu.LogicalProcessorIndex))
            {
                var choice = new CpuChoice(cpu, cpu.Available && (UseWindowsDefault || snapshot.CpuSetIds.Contains(cpu.Id)));
                choice.PropertyChanged += SelectionChanged;
                Cpus.Add(choice);
            }
            Status = "CPU selection for " + process.Name;
            Detail = snapshot.Compatibility.Protected ? "This process is protected. Choose another application." : "Choose Windows default or select CPUs, then preview the change.";
            if (snapshot.Compatibility.Protected) SelectedProcess = null;
        }
        catch (Exception error) { if (version == _selectionVersion) { Status = "CPU selection is unavailable."; Detail = error.Message; SelectedProcess = null; } }
        finally { _loadingSelection = false; if (version == _selectionVersion || SelectedProcess is null) Busy = false; }
    }

    private void SelectionChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (!_loadingSelection && e.PropertyName == nameof(CpuChoice.Selected)) { InvalidateReview(); RefreshCommands(); }
    }

    [RelayCommand]
    private async Task PreviewAsync()
    {
        if (!CanPreview) return;
        Busy = true;
        try
        {
            var ids = UseWindowsDefault ? Array.Empty<uint>() : Cpus.Where(cpu => cpu.Selected && cpu.Cpu.Available).Select(cpu => cpu.Cpu.Id).ToArray();
            _review = await App.Operations.PreviewCpuSetsAsync(SelectedProcess!.Id, ids, UseWindowsDefault);
            ReviewSummary = _review.Plan.Identity.DisplayName + "\nCurrent: " + _review.Plan.Describe(_review.Plan.OriginalCpuSetIds) + "\nRequested: " + _review.Plan.Describe(_review.Plan.DesiredCpuSetIds);
            HasReview = true; Status = "Review the CPU selection."; Detail = "Apply changes only this running process. Restore returns its saved selection.";
        }
        catch (Exception error) { Status = "Couldn't preview this selection."; Detail = error.Message; InvalidateReview(); }
        finally { Busy = false; }
    }

    [RelayCommand]
    private async Task ApplyAsync()
    {
        if (!CanApply || _review is null) return;
        Busy = true;
        try
        {
            _journal = _review.JournalPath;
            var result = await App.Operations.ApplyCpuSetsAsync(_review);
            RestoreAvailable = result.RestoreAvailable;
            RestoreLabel = "Restore " + _review.Plan.Identity.DisplayName;
            Status = result.Changed ? "CPU selection applied." : "The process already has this CPU selection.";
            Detail = "Windows reported the requested assignment. Thread-specific choices and hard affinity can still take precedence.";
            HasReview = false;
        }
        catch (Exception error) { Status = "CPU selection was not confirmed."; Detail = error.Message; RestoreAvailable = _journal is not null && System.IO.File.Exists(_journal); }
        finally { Busy = false; }
    }

    [RelayCommand]
    private async Task RestoreAsync()
    {
        if (!CanRestore || _journal is null) return;
        Busy = true;
        try
        {
            if (await App.Operations.ReleaseEndedCpuSessionAsync(_journal)) { ShowEndedSession(); return; }
            var result = await App.Operations.RestoreCpuSetsAsync(_journal);
            RestoreAvailable = result.RestoreAvailable;
            if (!RestoreAvailable)
            {
                _loadingSelection = true;
                var original = result.Data?.Preview.OriginalCpuSetIds ?? Array.Empty<uint>();
                UseWindowsDefault = original.Length == 0;
                foreach (var cpu in Cpus) cpu.Selected = cpu.Cpu.Available && (UseWindowsDefault || original.Contains(cpu.Cpu.Id));
                _loadingSelection = false;
            }
            Status = "Original CPU selection restored."; Detail = "The saved assignment was verified in Windows.";
            InvalidateReview();
        }
        catch (Exception error) { Status = "Couldn't restore this selection."; Detail = error.Message; }
        finally { Busy = false; }
    }

    private void ShowEndedSession()
    {
        RestoreAvailable = false;
        _journal = null;
        SelectedProcess = null;
        InvalidateReview();
        Status = "The saved application has exited.";
        Detail = "Its CPU selection ended with that process. Choose another running application.";
    }

    private void InvalidateReview() { _review = null; HasReview = false; ReviewSummary = ""; }
    private void RefreshCommands()
    {
        foreach (var property in new[] { nameof(CanChooseProcess), nameof(CanChooseCpus), nameof(CanPreview), nameof(CanApply), nameof(CanRestore) }) OnPropertyChanged(property);
    }
}
