using System;
using System.Runtime.InteropServices;

public static class RooIndustriesStandbyMemoryHelper
{
    private enum SYSTEM_MEMORY_LIST_COMMAND
    {
        MemoryCaptureAccessedBits = 0,
        MemoryCaptureAndResetAccessedBits = 1,
        MemoryEmptyWorkingSets = 2,
        MemoryFlushModifiedList = 3,
        MemoryPurgeStandbyList = 4,
        MemoryPurgeLowPriorityStandbyList = 5,
        MemoryCommandMax = 6
    }

    [DllImport("ntdll.dll")]
    private static extern int NtSetSystemInformation(
        int systemInformationClass,
        ref SYSTEM_MEMORY_LIST_COMMAND command,
        int commandLength);

    public static int Main(string[] args)
    {
        if (args.Length != 1 || !String.Equals(args[0], "--purge-standby-list", StringComparison.OrdinalIgnoreCase))
        {
            Console.Error.WriteLine("Usage: RooIndustriesStandbyMemoryHelper --purge-standby-list");
            return 64;
        }

        var command = SYSTEM_MEMORY_LIST_COMMAND.MemoryPurgeStandbyList;
        int status = NtSetSystemInformation(80, ref command, Marshal.SizeOf(typeof(SYSTEM_MEMORY_LIST_COMMAND)));
        Console.WriteLine("NtSetSystemInformation(SystemMemoryListInformation) status=0x" + status.ToString("X8"));
        return status == 0 ? 0 : 1;
    }
}
