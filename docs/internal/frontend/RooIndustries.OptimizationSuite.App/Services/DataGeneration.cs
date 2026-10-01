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
        Interlocked.Increment(ref _changing);
        Interlocked.Increment(ref _value);
        return new Change(Owner.Value);
    }
    public static bool IsCurrent(long generation) => !Changing && generation == Current;
    public static long Snapshot() => Changing ? -1 : Current;
    public static event Action? Settled;
    private sealed class Change(OwnChanges? own) : IDisposable
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
        }
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
