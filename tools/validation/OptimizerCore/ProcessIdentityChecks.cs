using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using Roo.Optimizer;

static class ProcessIdentityChecks
{
    public static void Run(Action<bool, string> check)
    {
        var root = Path.Combine(Path.GetTempPath(), "roo-image-path-" + Guid.NewGuid().ToString("N"));
        var directory = Path.Combine(root, new string('a', 100), new string('b', 100));
        ProcessInfo created = default;
        try
        {
            Directory.CreateDirectory(directory);
            var executable = Path.Combine(directory, Path.GetFileName(Environment.ProcessPath)!);
            File.Copy(Environment.ProcessPath!, executable);
            check(executable.Length > 260, "The executable path fixture exceeds the initial image-query buffer");
            var startup = new StartupInfo { Size = Marshal.SizeOf<StartupInfo>() };
            if (!CreateProcess(@"\\?\" + executable, null, IntPtr.Zero, IntPtr.Zero, false, 0x08000004, IntPtr.Zero, null, ref startup, out created))
                throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
            var shortBuffer = new StringBuilder(260);
            uint shortLength = (uint)shortBuffer.Capacity;
            var shortRead = QueryFullProcessImageName(created.Process, 0, shortBuffer, ref shortLength);
            var error = Marshal.GetLastWin32Error();
            check(!shortRead && error == 122, "An independent small-buffer Windows query proves that this process needs growth");
            var complete = new StringBuilder(32768);
            uint length = (uint)complete.Capacity;
            if (!QueryFullProcessImageName(created.Process, 0, complete, ref length)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
            using var probe = Process.GetProcessById(created.ProcessId);
            using var target = new ProcessTarget(created.ProcessId);
            var identity = target.Identity();
            check(identity.ProcessId == created.ProcessId && identity.ExecutablePath == complete.ToString() && identity.CreationTimeFileTimeUtc == probe.StartTime.ToUniversalTime().ToFileTimeUtc().ToString(System.Globalization.CultureInfo.InvariantCulture),
                "Growing identity queries retain the complete native path and exact process lifetime");
            using var self = new ProcessTarget(Environment.ProcessId);
            check(self.Identity().ExecutablePath == Environment.ProcessPath, "Ordinary process paths remain exact with the smaller buffer");
        }
        finally
        {
            try
            {
                if (created.Process != IntPtr.Zero)
                {
                    if (!TerminateProcess(created.Process, 0)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
                    if (WaitForSingleObject(created.Process, 10000) != 0) throw new InvalidOperationException("Long-path fixture shutdown failed.");
                }
            }
            finally
            {
                if (created.Thread != IntPtr.Zero) CloseHandle(created.Thread);
                if (created.Process != IntPtr.Zero) CloseHandle(created.Process);
            }
            if (Directory.Exists(root)) Directory.Delete(root, true);
        }
        check(!Directory.Exists(root), "Image-path validation removes its suspended fixture and copied executable");
    }

    [StructLayout(LayoutKind.Sequential)]
    struct StartupInfo
    {
        public int Size;
        public IntPtr Reserved, Desktop, Title;
        public uint X, Y, Width, Height, XChars, YChars, Fill, Flags;
        public ushort Show, ReservedSize;
        public IntPtr ReservedBytes, Input, Output, Error;
    }
    [StructLayout(LayoutKind.Sequential)]
    struct ProcessInfo { public IntPtr Process, Thread; public int ProcessId, ThreadId; }
    [DllImport("kernel32.dll", EntryPoint = "CreateProcessW", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool CreateProcess(string application, StringBuilder? command, IntPtr processAttributes, IntPtr threadAttributes, bool inherit, uint flags, IntPtr environment, string? directory, ref StartupInfo startup, out ProcessInfo process);
    [DllImport("kernel32.dll", EntryPoint = "QueryFullProcessImageNameW", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool QueryFullProcessImageName(IntPtr process, uint flags, StringBuilder path, ref uint size);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool TerminateProcess(IntPtr process, uint exitCode);
    [DllImport("kernel32.dll", SetLastError = true)] static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
}
