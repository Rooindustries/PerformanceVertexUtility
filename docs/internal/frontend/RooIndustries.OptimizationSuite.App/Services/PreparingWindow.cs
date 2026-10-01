using System;
using System.Runtime.InteropServices;
using System.Threading;

namespace RooIndustries.OptimizationSuite.Services;

public sealed class PreparingWindow : IDisposable
{
    private const uint WsPopup = 0x80000000, WsCaption = 0x00C00000, WsVisible = 0x10000000, WsChild = 0x40000000, SsCenter = 0x1;
    private const uint ExTopmost = 0x8, ExToolWindow = 0x80;
    private const int SwShow = 5, WmSetFont = 0x30, WmSetText = 0xC, DefaultGuiFont = 17;
    private readonly ManualResetEventSlim _stop = new(false);
    private readonly Thread _thread;
    private volatile string _text = "";
    private IntPtr _status;

    public PreparingWindow(TimeSpan delay)
    {
        _thread = new Thread(() => Run(delay)) { IsBackground = true, Name = "Preparing window" };
        _thread.SetApartmentState(ApartmentState.STA);
        _thread.Start();
    }

    public void Report(string text)
    {
        _text = text;
        var status = _status;
        if (status != IntPtr.Zero) SendMessageTimeout(status, WmSetText, IntPtr.Zero, text, 0x2, 500, out _);
    }

    private void Run(TimeSpan delay)
    {
        if (_stop.Wait(delay)) return;
        var scale = Math.Max(1.0, GetDpiForSystem() / 96.0);
        int Scaled(int value) => (int)Math.Round(value * scale);
        var width = Scaled(460); var height = Scaled(190);
        var window = CreateWindowEx(ExTopmost | ExToolWindow, "#32770", "Roo Industries Optimization Suite", WsPopup | WsCaption, (GetSystemMetrics(0) - width) / 2, (GetSystemMetrics(1) - height) / 2, width, height, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
        if (window == IntPtr.Zero) return;
        var font = GetStockObject(DefaultGuiFont);
        var heading = CreateWindowEx(0, "STATIC", "Preparing your saved settings", WsChild | WsVisible | SsCenter, Scaled(16), Scaled(18), width - Scaled(48), Scaled(24), window, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
        var note = CreateWindowEx(0, "STATIC", "This happens once after an update and can take a few minutes. Please keep this window open. The app opens when it is done.", WsChild | WsVisible | SsCenter, Scaled(16), Scaled(52), width - Scaled(48), Scaled(48), window, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
        _status = CreateWindowEx(0, "STATIC", _text, WsChild | WsVisible | SsCenter, Scaled(16), Scaled(110), width - Scaled(48), Scaled(36), window, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
        foreach (var child in new[] { heading, note, _status }) SendMessage(child, WmSetFont, font, (IntPtr)1);
        ShowWindow(window, SwShow);
        UpdateWindow(window);
        while (!_stop.IsSet)
        {
            while (PeekMessage(out var message, IntPtr.Zero, 0, 0, 1)) { TranslateMessage(ref message); DispatchMessage(ref message); }
            MsgWaitForMultipleObjects(0, IntPtr.Zero, false, 100, 0x4FF);
        }
        DestroyWindow(window);
    }

    public void Dispose()
    {
        _stop.Set();
        _thread.Join(TimeSpan.FromSeconds(3));
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct Message { public IntPtr Window; public uint Id; public IntPtr WParam, LParam; public uint Time; public int X, Y; }

    [DllImport("user32.dll", EntryPoint = "CreateWindowExW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateWindowEx(uint exStyle, string className, string text, uint style, int x, int y, int width, int height, IntPtr parent, IntPtr menu, IntPtr instance, IntPtr parameter);
    [DllImport("user32.dll")] private static extern bool ShowWindow(IntPtr window, int command);
    [DllImport("user32.dll")] private static extern bool UpdateWindow(IntPtr window);
    [DllImport("user32.dll")] private static extern bool DestroyWindow(IntPtr window);
    [DllImport("user32.dll", EntryPoint = "PeekMessageW")] private static extern bool PeekMessage(out Message message, IntPtr window, uint min, uint max, uint remove);
    [DllImport("user32.dll")] private static extern bool TranslateMessage(ref Message message);
    [DllImport("user32.dll", EntryPoint = "DispatchMessageW")] private static extern IntPtr DispatchMessage(ref Message message);
    [DllImport("user32.dll")] private static extern uint MsgWaitForMultipleObjects(uint count, IntPtr handles, bool all, uint milliseconds, uint mask);
    [DllImport("user32.dll", EntryPoint = "SendMessageW")] private static extern IntPtr SendMessage(IntPtr window, int message, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll", EntryPoint = "SendMessageTimeoutW", CharSet = CharSet.Unicode)] private static extern IntPtr SendMessageTimeout(IntPtr window, int message, IntPtr wParam, string lParam, uint flags, uint timeout, out IntPtr result);
    [DllImport("user32.dll")] private static extern int GetSystemMetrics(int index);
    [DllImport("user32.dll")] private static extern uint GetDpiForSystem();
    [DllImport("gdi32.dll")] private static extern IntPtr GetStockObject(int index);
}
