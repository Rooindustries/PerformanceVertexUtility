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

    [ObservableProperty]
    private string _staleNotice = "";

    private bool _initialized;
    private long _loadedGeneration = -2;
    private Task? _load;

    protected virtual bool RefreshOnRevisit => true;
    protected virtual bool HasUserWork => false;
    protected virtual bool IsWorking => false;
    private const string ChangedNotice = "Settings changed elsewhere. Your selection is kept; clear it to load the current list.";
    private bool _keepStale;
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
        if (!IsReady) await ReloadAsync();
        else if (!DataGeneration.IsCurrent(_loadedGeneration))
        {
            if (HasUserWork) StaleNotice = ChangedNotice;
            else await ReloadAsync();
        }
        else if (RefreshOnRevisit) await RunAsync(quiet: true);
    }

    private async Task RefreshChangedAsync()
    {
        if (HasUserWork) { StaleNotice = ChangedNotice; return; }
        await RunAsync(quiet: true);
    }

    private DataGeneration.OwnChanges? _own;
    private long _ownBefore = -1;

    protected void StartOwn()
    {
        _ownBefore = _loadedGeneration >= 0 ? DataGeneration.Snapshot() : -1;
        _own = DataGeneration.BeginOwn();
    }

    protected void FinishOwn()
    {
        var own = _own;
        if (own is null) return;
        _own = null;
        DataGeneration.EndOwn();
        if (_loadedGeneration >= 0 && _loadedGeneration == _ownBefore && StaleNotice.Length == 0 && DataGeneration.OwnAccepted(_ownBefore, own)) _loadedGeneration = DataGeneration.Current;
    }

    protected void KeepStale() => _keepStale = true;

    protected async Task RefreshIfStaleAsync()
    {
        if (!_initialized || DataGeneration.Changing || DataGeneration.IsCurrent(_loadedGeneration)) return;
        while (_load is { IsCompleted: false }) await _load;
        if (!HasUserWork && !DataGeneration.IsCurrent(_loadedGeneration)) await RunAsync(quiet: true);
    }

    public Task ReloadAsync() => RunAsync(quiet: false);

    public async Task RevalidateAsync()
    {
        if (!_initialized) return;
        while (_load is { IsCompleted: false }) await _load;
        if (DataGeneration.Changing || IsWorking || DataGeneration.IsCurrent(_loadedGeneration)) return;
        if (!IsReady) await ReloadAsync();
        else await RefreshChangedAsync();
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
        StaleNotice = "";

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
            if (_loadedGeneration != DataGeneration.Current || _keepStale) _loadedGeneration = -1;
            if (_keepStale && HasUserWork) StaleNotice = ChangedNotice;
            _keepStale = false;
            IsLoading = false;
            IsReady = ErrorMessage is null && !IsEmpty;
        }
    }

    protected abstract Task LoadCoreAsync();
}
