using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;

namespace RooIndustries.OptimizationSuite.Services;

public static class DataGeneration
{
    private static long _value;
    private static int _changing;
    public static long Current => Interlocked.Read(ref _value);
    public static bool Changing => Volatile.Read(ref _changing) > 0;
    public static IDisposable BeginChange()
    {
        Interlocked.Increment(ref _changing);
        Interlocked.Increment(ref _value);
        return new Change();
    }
    public static bool IsCurrent(long generation) => !Changing && generation == Current;
    public static event Action? Settled;
    private sealed class Change : IDisposable
    {
        private int _done;
        public void Dispose()
        {
            if (Interlocked.Exchange(ref _done, 1) != 0) return;
            Interlocked.Increment(ref _value);
            if (Interlocked.Decrement(ref _changing) == 0) Settled?.Invoke();
        }
    }
}

public sealed class SharedReads
{
    private sealed record Entry(Task<object?> Read, long Generation, long StartedTicks, Func<object?, bool> Good);
    private readonly Dictionary<string, Entry> _entries = new(StringComparer.Ordinal);
    private readonly object _gate = new();

    public async Task<T?> GetAsync<T>(string key, TimeSpan maxAge, Func<Task<T>> read, Func<T, bool>? good = null) where T : class
    {
        Func<object?, bool> keep = value => value is T typed && (good is null || good(typed));
        Entry entry;
        lock (_gate)
        {
            if (!_entries.TryGetValue(key, out entry!) || !Usable(entry, maxAge))
            {
                var generation = DataGeneration.Changing ? -1 : DataGeneration.Current;
                entry = new(Wrap(read), generation, Environment.TickCount64, keep);
                _entries[key] = entry;
            }
        }
        try
        {
            var value = await entry.Read.ConfigureAwait(false);
            if (!keep(value)) Remove(key, entry);
            return value as T;
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
        && maxAge > TimeSpan.Zero && (!entry.Read.IsCompleted || entry.Read.IsCompletedSuccessfully && entry.Good(entry.Read.Result) && TimeSpan.FromMilliseconds(Environment.TickCount64 - entry.StartedTicks) < maxAge);

    private static async Task<object?> Wrap<T>(Func<Task<T>> read) where T : class
    {
        await Task.Yield();
        return await read().ConfigureAwait(false);
    }
}
