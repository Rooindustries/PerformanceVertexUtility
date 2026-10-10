using System;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;

public static class LauncherFixture
{
    [DllImport("d3d11.dll")] static extern int D3D11CreateDevice(IntPtr adapter, int driverType, IntPtr software, uint flags, IntPtr levels, uint count, uint sdk, out IntPtr device, out uint level, out IntPtr context);
    public static void Main(string[] args)
    {
        IntPtr device = IntPtr.Zero, context = IntPtr.Zero;
        if (args.Length == 3 && args[2] == "--gpu")
        {
            uint level;
            int result = D3D11CreateDevice(IntPtr.Zero, 1, IntPtr.Zero, 0, IntPtr.Zero, 0, 7, out device, out level, out context);
            if (result < 0) Marshal.ThrowExceptionForHR(result);
            File.WriteAllText(args[0] + ".gpu-ready", level.ToString());
        }
        while (true)
        {
            if (File.Exists(args[0]))
            {
                var output = File.ReadAllText(args[0]);
                File.Delete(args[0]);
                var child = Process.Start(new ProcessStartInfo(args[1], "-t 127.0.0.1") { UseShellExecute = false, CreateNoWindow = true });
                File.WriteAllText(output, child.Id.ToString());
                child.Dispose();
            }
            Thread.Sleep(100);
        }
    }
}
