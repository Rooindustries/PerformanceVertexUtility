param([Parameter(Mandatory = $true)][ValidateRange(0, 255)][int]$Index)
$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class RooIndustriesDiskKind
{
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern SafeFileHandle CreateFile(string name, int access, int share, IntPtr security, int disposition, int flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool DeviceIoControl(SafeFileHandle device, int code, int[] input, int inputSize, byte[] output, int outputSize, out int returned, IntPtr overlapped);
    private static byte[] Query(SafeFileHandle handle, int property, int size, int needed)
    {
        var output = new byte[size];
        int returned;
        return DeviceIoControl(handle, 0x2D1400, new[] { property, 0, 0 }, 12, output, size, out returned, IntPtr.Zero) && returned >= needed ? output : null;
    }
    public static string Describe(int index)
    {
        using (var handle = CreateFile(@"\\.\PhysicalDrive" + index, 0, 3, IntPtr.Zero, 3, 0, IntPtr.Zero))
        {
            if (handle.IsInvalid) return null;
            string bus = null;
            var adapter = Query(handle, 1, 32, 25);
            if (adapter != null)
            {
                switch (adapter[24])
                {
                    case 17: bus = "NVMe"; break;
                    case 11: bus = "SATA"; break;
                    case 7: bus = "USB"; break;
                    case 8: bus = "RAID"; break;
                    case 10: bus = "SAS"; break;
                    case 3: bus = "ATA"; break;
                }
            }
            var seek = Query(handle, 7, 12, 9);
            var kind = seek == null ? null : seek[8] == 0 ? "SSD" : "HDD";
            return (bus + " " + kind).Trim();
        }
    }
}
'@
[RooIndustriesDiskKind]::Describe($Index)
