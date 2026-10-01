using System;
using System.Threading.Tasks;
using RooIndustries.OptimizationSuite.Services;

namespace RooIndustries.OptimizationSuite.Views;

internal sealed class ChangeWatch
{
    private readonly SeenGeneration _seen = new();
    private readonly Func<Func<Task>, bool> _enqueue;
    private readonly Func<bool, Task> _catchUp;
    private bool _watching;

    public ChangeWatch(Func<Func<Task>, bool> enqueue, Func<bool, Task> catchUp) { _enqueue = enqueue; _catchUp = catchUp; }

    public bool Changed => !_seen.IsCurrent;
    public void MarkSeen() => _seen.Mark();

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

    public async Task RefreshAsync(Func<Task<bool>> refresh)
    {
        var started = _seen.BeginRead();
        var succeeded = false;
        try { succeeded = await refresh(); }
        finally { _seen.EndRead(started, succeeded); }
        if (succeeded && Changed && !DataGeneration.Changing) Run(revisit: false);
    }

    public void OperationStarted() => _seen.BeginOwn();

    public void OperationEnded()
    {
        if (_seen.EndOwn(true, out _) == OwnEnd.Stale && !_seen.Reading) Run(revisit: false);
    }

    public void Run(bool revisit) => _enqueue(async () =>
    {
        try { await _catchUp(revisit); }
        catch (Exception error) { AppLog.Write("refresh", error.ToString()); }
    });

    private void OnSettled() => Run(revisit: false);
}
