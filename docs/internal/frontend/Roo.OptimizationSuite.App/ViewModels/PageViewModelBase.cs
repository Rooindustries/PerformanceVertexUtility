using System;
using System.Threading.Tasks;
using CommunityToolkit.Mvvm.ComponentModel;
using Roo.OptimizationSuite.Services;

namespace Roo.OptimizationSuite.ViewModels;

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

    public async Task InitializeAsync()
    {
        if (_initialized)
        {
            return;
        }

        _initialized = true;
        await ReloadAsync();
    }

    public async Task ReloadAsync()
    {
        IsLoading = true;
        IsReady = false;
        IsEmpty = false;
        ErrorMessage = null;

        try
        {
            await LoadCoreAsync();
        }
        catch (Exception ex)
        {
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
