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

    public async Task InitializeAsync()
    {
        if (!_initialized)
        {
            _initialized = true;
            await ReloadAsync();
            return;
        }
        if (_load is { IsCompleted: false }) await _load;
        if (!DataGeneration.IsCurrent(_loadedGeneration) || !IsReady) await ReloadAsync();
        else if (RefreshOnRevisit) await RunAsync(quiet: true);
    }

    public Task ReloadAsync() => RunAsync(quiet: false);

    public async Task RevalidateAsync()
    {
        if (!_initialized) return;
        if (_load is { IsCompleted: false }) await _load;
        if (_loadedGeneration == -1) await ReloadAsync();
    }

    private async Task RunAsync(bool quiet)
    {
        if (_load is { IsCompleted: false }) await _load;
        _load = LoadAsync(quiet);
        await _load;
    }

    private async Task LoadAsync(bool quiet)
    {
        Fresh = _loadedGeneration != -2;
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
            IsLoading = false;
            IsReady = ErrorMessage is null && !IsEmpty;
        }
    }

    protected abstract Task LoadCoreAsync();
}
