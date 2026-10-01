using System;
using System.Threading;
using System.Threading.Tasks;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
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

    [ObservableProperty]
    private string _outOfDateNotice = "";

    private readonly SeenGeneration _seen = new();
    private bool _initialized;
    private bool _attempted;
    private Task? _load;

    protected virtual bool RefreshOnRevisit => true;
    protected virtual bool HasUserWork => false;
    protected virtual bool IsWorking => false;
    private const string ChangedNotice = "Settings changed elsewhere. Your selection is kept; clear it to load the current list.";
    private const string RefreshFailedNotice = "Couldn't refresh this page. What you see may be out of date.";
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
        else if (!_seen.IsCurrent)
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

    protected void StartOwn() => _seen.BeginOwn();

    protected bool FinishOwn()
    {
        switch (_seen.EndOwn(StaleNotice.Length == 0 && OutOfDateNotice.Length == 0, out var bumps))
        {
            case OwnEnd.Accepted: return bumps > 0;
            case OwnEnd.Stale: _ = RevalidateAsync(); return false;
            default: return false;
        }
    }

    protected void KeepStale() => _keepStale = true;
    protected void MarkStale() => _seen.Invalidate();

    protected async Task RefreshIfStaleAsync()
    {
        if (!_initialized || DataGeneration.Changing || _seen.IsCurrent) return;
        while (_load is { IsCompleted: false }) await _load;
        if (!HasUserWork && !_seen.IsCurrent) await RunAsync(quiet: true);
    }

    public Task ReloadAsync() => RunAsync(quiet: false);

    [RelayCommand]
    private Task RetryAsync() => ReloadAsync();

    public async Task RevalidateAsync()
    {
        if (!_initialized) return;
        while (_load is { IsCompleted: false }) await _load;
        if (DataGeneration.Changing || IsWorking || _seen.IsCurrent) return;
        if (!IsReady) await ReloadAsync();
        else await RefreshChangedAsync();
    }

    private bool _revalidate;
    protected void RevalidateAfterLoad() => _revalidate = true;

    private readonly SemaphoreSlim _running = new(1, 1);

    private async Task RunAsync(bool quiet)
    {
        await _running.WaitAsync();
        try
        {
            _load = LoadAsync(quiet);
            await _load;
            if (!_revalidate || !IsReady) { _revalidate = false; return; }
            _revalidate = false;
            _load = LoadAsync(quiet: true);
            await _load;
            _revalidate = false;
        }
        finally { _running.Release(); }
    }

    private async Task LoadAsync(bool quiet)
    {
        Fresh = _attempted;
        _attempted = true;
        Quiet = quiet;
        var keepShown = quiet && IsReady;
        var started = _seen.BeginRead();
        if (!quiet) { IsLoading = true; IsReady = false; OutOfDateNotice = ""; }
        IsEmpty = false;
        ErrorMessage = null;
        StaleNotice = "";
        var threw = false;

        try
        {
            await LoadCoreAsync();
        }
        catch (Exception ex)
        {
            threw = true;
            AppLog.Write(GetType().Name, ex.ToString());
            ErrorMessage = ex.Message;
        }
        finally
        {
            var kept = keepShown && ErrorMessage is not null;
            if (kept)
            {
                if (!threw) AppLog.Write(GetType().Name, ErrorMessage);
                ErrorMessage = null;
                IsEmpty = false;
                OutOfDateNotice = RefreshFailedNotice;
            }
            else OutOfDateNotice = "";
            _seen.EndRead(started, seen: !kept);
            if (_keepStale) _seen.Invalidate();
            if (_keepStale && HasUserWork) StaleNotice = ChangedNotice;
            _keepStale = false;
            IsLoading = false;
            IsReady = ErrorMessage is null && !IsEmpty;
        }
    }

    protected abstract Task LoadCoreAsync();
}
