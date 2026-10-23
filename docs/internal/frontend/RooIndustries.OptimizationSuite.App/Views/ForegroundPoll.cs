using System;
using System.Threading.Tasks;
using Microsoft.UI.Xaml;
using RooIndustries.OptimizationSuite.Services;

namespace RooIndustries.OptimizationSuite.Views;

internal sealed class ForegroundPoll
{
    private static readonly TimeSpan Interval = TimeSpan.FromSeconds(2);
    private readonly DispatcherTimer _timer = new() { Interval = Interval };
    private readonly Func<Task> _read;
    private long _lastRead;
    private bool _running;

    public ForegroundPoll(Func<Task> read)
    {
        _read = read;
        _timer.Tick += async (_, _) => await ReadAsync();
    }

    public void Start()
    {
        if (_running) return;
        _running = true;
        _lastRead = Environment.TickCount64;
        MemoryRelief.ActiveChanged += OnActiveChanged;
        if (MemoryRelief.Active) _timer.Start();
    }

    public void Stop()
    {
        _running = false;
        MemoryRelief.ActiveChanged -= OnActiveChanged;
        _timer.Stop();
    }

    private async void OnActiveChanged()
    {
        if (!MemoryRelief.Active) { _timer.Stop(); return; }
        if (!_running || _timer.IsEnabled) return;
        _timer.Start();
        if (Environment.TickCount64 - _lastRead >= (long)Interval.TotalMilliseconds) await ReadAsync();
    }

    private async Task ReadAsync()
    {
        if (!_running || !MemoryRelief.Active) return;
        _lastRead = Environment.TickCount64;
        await _read();
    }
}
