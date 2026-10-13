using System;
using System.Runtime;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;

namespace RooIndustries.OptimizationSuite.Services;

public static class MemoryRelief
{
    private static readonly TimeSpan MinimizedDelay = TimeSpan.FromSeconds(3);
    private static readonly TimeSpan BackgroundDelay = TimeSpan.FromSeconds(30);
    private static readonly TimeSpan ForegroundIdle = TimeSpan.FromSeconds(10);
    private static int _foreground;
    private static Window? _window;
    private static int _generation;

    public static bool Minimized { get; private set; }

    public static void Attach(Window window)
    {
        Detach();
        _window = window;
        window.AppWindow.Changed += OnChanged;
        window.Activated += OnActivated;
    }

    public static void Detach(Window? window = null)
    {
        if (_window is null || window is not null && !ReferenceEquals(window, _window)) return;
        _window.AppWindow.Changed -= OnChanged;
        _window.Activated -= OnActivated;
        _window = null;
        Minimized = false;
        Interlocked.Increment(ref _generation);
        Interlocked.Increment(ref _foreground);
    }

    public static void PageShown()
    {
        var generation = Interlocked.Increment(ref _foreground);
        _ = Task.Run(async () =>
        {
            for (var waited = 0; waited < 120; waited += 2)
            {
                await Task.Delay(TimeSpan.FromSeconds(2)).ConfigureAwait(false);
                if (generation != Volatile.Read(ref _foreground) || Minimized) return;
                if (IdleTime() < ForegroundIdle) continue;
                try
                {
                    GCSettings.LargeObjectHeapCompactionMode = GCLargeObjectHeapCompactionMode.CompactOnce;
                    GC.Collect(GC.MaxGeneration, GCCollectionMode.Aggressive, blocking: true, compacting: true);
                }
                catch (Exception error) { AppLog.Write("memory", "Freeing memory failed: " + error.Message); }
                return;
            }
        });
    }

    private static TimeSpan IdleTime()
    {
        var info = new LastInputInfo { Size = (uint)Marshal.SizeOf<LastInputInfo>() };
        return GetLastInputInfo(ref info) ? TimeSpan.FromMilliseconds(unchecked((uint)Environment.TickCount - info.Time)) : TimeSpan.Zero;
    }

    [StructLayout(LayoutKind.Sequential)] private struct LastInputInfo { public uint Size; public uint Time; }
    [DllImport("user32.dll")] private static extern bool GetLastInputInfo(ref LastInputInfo info);

    private static void OnChanged(AppWindow sender, AppWindowChangedEventArgs args)
    {
        if (!args.DidPresenterChange && !args.DidSizeChange && !args.DidVisibilityChange) return;
        var minimized = !sender.IsVisible || sender.Presenter is OverlappedPresenter { State: OverlappedPresenterState.Minimized };
        if (minimized == Minimized) return;
        Minimized = minimized;
        var generation = Interlocked.Increment(ref _generation);
        if (minimized) Schedule(generation, MinimizedDelay);
    }

    private static void OnActivated(object sender, WindowActivatedEventArgs args)
    {
        var generation = Interlocked.Increment(ref _generation);
        if (args.WindowActivationState == WindowActivationState.Deactivated) Schedule(generation, Minimized ? MinimizedDelay : BackgroundDelay);
    }

    private static void Schedule(int generation, TimeSpan delay)
        => _ = Task.Run(async () =>
        {
            await Task.Delay(delay).ConfigureAwait(false);
            if (generation != Volatile.Read(ref _generation)) return;
            try
            {
                GCSettings.LargeObjectHeapCompactionMode = GCLargeObjectHeapCompactionMode.CompactOnce;
                GC.Collect(GC.MaxGeneration, GCCollectionMode.Aggressive, blocking: true, compacting: true);
                if (generation != Volatile.Read(ref _generation)) return;
                if (!SetProcessWorkingSetSize(GetCurrentProcess(), -1, -1)) AppLog.Write("memory", "Windows did not trim the app's memory (Win32 " + Marshal.GetLastWin32Error() + ").");
            }
            catch (Exception error) { AppLog.Write("memory", "Freeing memory failed: " + error.Message); }
        });

    [DllImport("kernel32.dll")] private static extern IntPtr GetCurrentProcess();
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool SetProcessWorkingSetSize(IntPtr process, nint minimum, nint maximum);
}
