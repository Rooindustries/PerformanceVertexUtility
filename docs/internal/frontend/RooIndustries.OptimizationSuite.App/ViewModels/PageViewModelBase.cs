using System;
using System.Threading.Tasks;
using CommunityToolkit.Mvvm.ComponentModel;
using RooIndustries.OptimizationSuite.Services;

namespace RooIndustries.OptimizationSuite.ViewModels;

public abstract partial class PageViewModelBase : ObservableObject
{
    protected SampleDataService Data => App.Data;

    [ObservableProperty]
    private bool _isLoading;

    [ObservableProperty]
    private bool _isReady;

    [ObservableProperty]
    private bool _isEmpty;

    [ObservableProperty]
    private string? _errorMessage;

    private bool _initialized;
    private long _loadedGeneration = -2;
    private Task? _load;

    protected virtual bool RefreshOnRevisit => true;
    protected bool Fresh { get; private set; }
    protected bool Quiet { get; private set; }

    public async Task InitializeAsync()
    {
        if (!_initialized)
        {
            _initialized = true;
            await ReloadAsync();
            return;
        }
        while (_load is { IsCompleted: false }) await _load;
        if (!DataGeneration.IsCurrent(_loadedGeneration) || !IsReady) await ReloadAsync();
        else if (RefreshOnRevisit) await RunAsync(quiet: true);
    }

    public Task ReloadAsync() => RunAsync(quiet: false);

    public async Task RevalidateAsync()
    {
        if (!_initialized) return;
        while (_load is { IsCompleted: false }) await _load;
        if (_loadedGeneration == -1) await ReloadAsync();
    }

    private bool _revalidate;
    protected void RevalidateAfterLoad() => _revalidate = true;

    private async Task RunAsync(bool quiet)
    {
        while (_load is { IsCompleted: false }) await _load;
        _load = LoadAsync(quiet);
        await _load;
        if (!_revalidate || !IsReady) { _revalidate = false; return; }
        _revalidate = false;
        _load = LoadAsync(quiet: true);
        await _load;
        _revalidate = false;
    }

    private async Task LoadAsync(bool quiet)
    {
        Fresh = _loadedGeneration != -2;
        Quiet = quiet;
        _loadedGeneration = DataGeneration.Changing ? -1 : DataGeneration.Current;
        if (!quiet) { IsLoading = true; IsReady = false; }
        IsEmpty = false;
        ErrorMessage = null;

        try
        {
            await LoadCoreAsync();
        }
        catch (Exception ex)
        {
            AppLog.Write(GetType().Name, ex.ToString());
            ErrorMessage = ex.Message;
        }
        finally
        {
            if (_loadedGeneration != DataGeneration.Current) _loadedGeneration = -1;
            IsLoading = false;
            IsReady = ErrorMessage is null && !IsEmpty;
        }
    }

    protected abstract Task LoadCoreAsync();
}
