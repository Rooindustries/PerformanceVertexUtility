using System;
using System.Threading.Tasks;
using Microsoft.UI.Dispatching;
using RooIndustries.OptimizationSuite.Services;

namespace RooIndustries.OptimizationSuite.Views;

internal sealed class ChangeWatch
{
    private long _seen = -2;
    private bool _refreshing;
    private readonly DispatcherQueue _queue;
    private readonly Func<bool, Task> _catchUp;
    private bool _watching;

    public ChangeWatch(DispatcherQueue queue, Func<bool, Task> catchUp) { _queue = queue; _catchUp = catchUp; }

    public bool Changed => !DataGeneration.IsCurrent(_seen);
    public void MarkSeen() => _seen = DataGeneration.Snapshot();

    public void Start()
    {
        if (_watching) return;
        _watching = true;
        DataGeneration.Settled += OnSettled;
    }

    public void Stop()
    {
        _watching = false;
        DataGeneration.Settled -= OnSettled;
    }

    public async Task RefreshAsync(Func<Task> refresh)
        => await RefreshAsync(async () => { await refresh(); return true; });

    public async Task RefreshAsync(Func<Task<bool>> refresh)
    {
        var before = DataGeneration.Snapshot();
        var succeeded = false;
        _refreshing = true;
        try { succeeded = await refresh(); }
        finally { _refreshing = false; }
        if (succeeded) _seen = before;
    }

    private DataGeneration.OwnChanges? _own;
    private long _ownBefore = -1;

    public void OperationStarted()
    {
        _ownBefore = DataGeneration.Snapshot();
        _own = DataGeneration.BeginOwn();
    }

    public void OperationEnded()
    {
        var own = _own;
        if (own is null) return;
        _own = null;
        DataGeneration.EndOwn();
        if (!_refreshing && _seen == _ownBefore && DataGeneration.OwnAccepted(_ownBefore, own)) _seen = DataGeneration.Current;
    }

    public void Run(bool revisit) => _queue.TryEnqueue(async () =>
    {
        try { await _catchUp(revisit); }
        catch (Exception error) { AppLog.Write("refresh", error.ToString()); }
    });

    private void OnSettled() => Run(revisit: false);
}
