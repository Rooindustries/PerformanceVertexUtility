using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;

namespace RooIndustries.OptimizationSuite.Services;

public static class DataGeneration
{
    private static long _value;
    private static int _changing;
    private static long _settledTicks;
    public static long SettledTicks => Interlocked.Read(ref _settledTicks);
    public static long Current => Interlocked.Read(ref _value);
    public static bool Changing => Volatile.Read(ref _changing) > 0;
    public sealed class OwnChanges
    {
        private long _bumps;
        public long Bumps => Interlocked.Read(ref _bumps);
        internal void Add() => Interlocked.Add(ref _bumps, 2);
    }
    private static readonly AsyncLocal<OwnChanges?> Owner = new();
    public static OwnChanges BeginOwn() { var own = new OwnChanges(); Owner.Value = own; return own; }
    public static void EndOwn() => Owner.Value = null;
    public static bool OwnAccepted(long before, OwnChanges own) => before >= 0 && !Changing && Current == before + own.Bumps;
    public static IDisposable BeginChange()
    {
        var running = RunningChanges.Begin();
        Interlocked.Increment(ref _changing);
        Interlocked.Increment(ref _value);
        return new Change(Owner.Value, running);
    }
    public static bool IsCurrent(long generation) => !Changing && generation == Current;
    public static long Snapshot() => Changing ? -1 : Current;
    public static event Action? Settled;
    private sealed class Change(OwnChanges? own, IDisposable running) : IDisposable
    {
        private int _done;
        public void Dispose()
        {
            if (Interlocked.Exchange(ref _done, 1) != 0) return;
            Interlocked.Increment(ref _value);
            own?.Add();
            if (Interlocked.Decrement(ref _changing) == 0)
            {
                Interlocked.Exchange(ref _settledTicks, Environment.TickCount64);
                foreach (var handler in Settled?.GetInvocationList() ?? [])
                {
                    try { ((Action)handler)(); }
                    catch (Exception error) { AppLog.Write("refresh", error.ToString()); }
                }
            }
            running.Dispose();
        }
    }
}

public static class RunningChanges
{
    public const string Installing = "The app is closing to install an update. Make this change after it opens again.";
    private static readonly object Gate = new();
    private static int _count;
    private static bool _held;
    public static bool Any { get { lock (Gate) return _count > 0; } }
    public static event Action? Finished;

    public static IDisposable Begin()
    {
        lock (Gate)
        {
            if (_held) throw new InvalidOperationException(Installing);
            _count++;
        }
        return new Running();
    }

    public static IDisposable? TryHold()
    {
        lock (Gate)
        {
            if (_count > 0 || _held) return null;
            _held = true;
        }
        return new Hold();
    }

    private sealed class Running : IDisposable
    {
        private int _done;
        public void Dispose()
        {
            if (Interlocked.Exchange(ref _done, 1) != 0) return;
            bool idle;
            lock (Gate) idle = --_count == 0;
            if (!idle) return;
            foreach (var handler in Finished?.GetInvocationList() ?? [])
            {
                try { ((Action)handler)(); }
                catch (Exception error) { AppLog.Write("change", error.ToString()); }
            }
        }
    }

    private sealed class Hold : IDisposable
    {
        private int _done;
        public void Dispose()
        {
            if (Interlocked.Exchange(ref _done, 1) != 0) return;
            lock (Gate) _held = false;
        }
    }
}

public enum OwnEnd { None, Accepted, Stale }

public sealed class SeenGeneration
{
    private long _value = -2;
    private int _reads;
    private long _ownBefore = -1;
    private DataGeneration.OwnChanges? _own;

    public long Value => Interlocked.Read(ref _value);
    public bool IsCurrent => DataGeneration.IsCurrent(Value);
    public bool Reading => Volatile.Read(ref _reads) > 0;
    public void Mark() => Interlocked.Exchange(ref _value, DataGeneration.Snapshot());
    public void Invalidate() => Interlocked.Exchange(ref _value, -1);

    public long BeginRead()
    {
        Interlocked.Increment(ref _reads);
        return DataGeneration.Snapshot();
    }

    public void EndRead(long started, bool seen)
    {
        if (seen) Interlocked.Exchange(ref _value, started == DataGeneration.Current ? started : -1);
        Interlocked.Decrement(ref _reads);
    }

    public void BeginOwn()
    {
        _ownBefore = Value >= 0 ? DataGeneration.Snapshot() : -1;
        _own = DataGeneration.BeginOwn();
    }

    public OwnEnd EndOwn(bool mayAccept, out long bumps)
    {
        var own = _own;
        bumps = 0;
        if (own is null) return OwnEnd.None;
        _own = null;
        DataGeneration.EndOwn();
        bumps = own.Bumps;
        if (!mayAccept || Reading || Value < 0 || Value != _ownBefore || !DataGeneration.OwnAccepted(_ownBefore, own)) return OwnEnd.Stale;
        Interlocked.Exchange(ref _value, _ownBefore + bumps);
        return OwnEnd.Accepted;
    }
}

public sealed class SharedReads
{
    private sealed record Entry(Task<object?> Read, long Generation, long StartedTicks, Func<object?, bool> Good, bool Provisional = false)
    {
        public long CompletedTicks;
    }
    private readonly Dictionary<string, Entry> _entries = new(StringComparer.Ordinal);
    private readonly object _gate = new();

    public async Task<T?> GetAsync<T>(string key, TimeSpan maxAge, Func<Task<T>> read, Func<T, bool>? good = null) where T : class
        => (await ReadAsync(key, maxAge, read, good).ConfigureAwait(false)).Value;

    public async Task<(T? Value, TimeSpan Age)> ReadAsync<T>(string key, TimeSpan maxAge, Func<Task<T>> read, Func<T, bool>? good = null, TimeSpan settle = default) where T : class
    {
        Func<object?, bool> keep = value => value is T typed && (good is null || good(typed));
        Entry entry;
        lock (_gate)
        {
            if (!_entries.TryGetValue(key, out entry!) || !Usable(entry, maxAge))
            {
                var generation = DataGeneration.Snapshot();
                var now = Environment.TickCount64;
                var provisional = settle > TimeSpan.Zero && DataGeneration.SettledTicks > 0 && now - DataGeneration.SettledTicks < settle.TotalMilliseconds;
                entry = new(Wrap(read), generation, now, keep, provisional);
                _entries[key] = entry;
            }
        }
        try
        {
            var value = await entry.Read.ConfigureAwait(false);
            if (!keep(value)) Remove(key, entry);
            var now = Environment.TickCount64;
            Interlocked.CompareExchange(ref entry.CompletedTicks, now, 0);
            return (value as T, TimeSpan.FromMilliseconds(now - Interlocked.Read(ref entry.CompletedTicks)));
        }
        catch
        {
            Remove(key, entry);
            throw;
        }
    }

    private void Remove(string key, Entry entry)
    {
        lock (_gate) { if (_entries.TryGetValue(key, out var current) && ReferenceEquals(current, entry)) _entries.Remove(key); }
    }

    private static bool Usable(Entry entry, TimeSpan maxAge) => DataGeneration.IsCurrent(entry.Generation)
        && maxAge > TimeSpan.Zero && !entry.Provisional && (!entry.Read.IsCompleted || entry.Read.IsCompletedSuccessfully && entry.Good(entry.Read.Result) && TimeSpan.FromMilliseconds(Environment.TickCount64 - entry.StartedTicks) < maxAge);

    private static async Task<object?> Wrap<T>(Func<Task<T>> read) where T : class
    {
        await Task.Yield();
        return await read().ConfigureAwait(false);
    }
}
