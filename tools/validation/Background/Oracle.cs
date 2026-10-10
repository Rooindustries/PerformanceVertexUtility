using System;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;

public static class RooBackgroundOracle
{
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool GetProcessInformation(IntPtr h, int kind, out uint value, int size);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool SetProcessInformation(IntPtr h, int kind, ref uint value, int size);
    [DllImport("ntdll.dll")] static extern int NtQueryInformationProcess(IntPtr h, int kind, out int value, int size, IntPtr length);
    [DllImport("ntdll.dll")] static extern int NtSetInformationProcess(IntPtr h, int kind, ref int value, int size);
    [DllImport("advapi32.dll", SetLastError=true)] static extern bool GetKernelObjectSecurity(IntPtr h, uint info, byte[] bytes, uint size, out uint needed);
    [DllImport("advapi32.dll", SetLastError=true)] static extern bool SetKernelObjectSecurity(IntPtr h, uint info, byte[] bytes);
    [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr CreateJobObject(IntPtr attributes, string name);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool SetInformationJobObject(IntPtr job, int kind, ref Limits limits, uint size);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
    [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr handle);
    [StructLayout(LayoutKind.Sequential)] struct Luid { public uint low; public int high; }
    [StructLayout(LayoutKind.Sequential)] struct TokenPrivilege { public uint count; public Luid luid; public uint attributes; }
    [DllImport("advapi32.dll", SetLastError=true)] static extern bool OpenProcessToken(IntPtr process, uint rights, out IntPtr token);
    [DllImport("advapi32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool LookupPrivilegeValue(string system, string name, out Luid value);
    [DllImport("advapi32.dll", SetLastError=true)] static extern bool AdjustTokenPrivileges(IntPtr token, bool all, ref TokenPrivilege value, int size, out TokenPrivilege prior, out int needed);
    [DllImport("advapi32.dll", EntryPoint="AdjustTokenPrivileges", SetLastError=true)] static extern bool RestorePrivilege(IntPtr token, bool all, ref TokenPrivilege value, int size, IntPtr prior, IntPtr needed);
    [DllImport("advapi32.dll", SetLastError=true)] static extern bool GetTokenInformation(IntPtr token, int kind, IntPtr buffer, int size, out int needed);
    [StructLayout(LayoutKind.Sequential)] struct Limits { public long processTime, jobTime; public uint flags; public UIntPtr minimumWs, maximumWs; public uint active; public UIntPtr affinity; public uint priority, scheduling; }
    public static int Io(Process p) { int value; int status=NtQueryInformationProcess(p.Handle,33,out value,4,IntPtr.Zero); if(status!=0) throw new Exception("I/O read NTSTATUS "+status); return value; }
    public static uint Memory(Process p) { uint value; if(!GetProcessInformation(p.Handle,0,out value,4)) throw new Win32Exception(); return value; }
    public static void SetIo(Process p,int value) {
        IntPtr token=IntPtr.Zero;var prior=new TokenPrivilege();
        try {
            if(value==3) {
                Luid luid;int needed;
                if(!OpenProcessToken(new IntPtr(-1),0x28,out token) || !LookupPrivilegeValue(null,"SeIncreaseBasePriorityPrivilege",out luid)) throw new Win32Exception();
                var request=new TokenPrivilege {count=1,luid=luid,attributes=2};
                if(!AdjustTokenPrivileges(token,false,ref request,16,out prior,out needed))throw new Win32Exception();
                int error=Marshal.GetLastWin32Error();if(error!=0)throw new Win32Exception(error);
            }
            int status=NtSetInformationProcess(p.Handle,33,ref value,4);if(status!=0)throw new Exception("I/O write NTSTATUS "+status);
        } finally {
            try {if(prior.count!=0 && (!RestorePrivilege(token,false,ref prior,0,IntPtr.Zero,IntPtr.Zero) || Marshal.GetLastWin32Error()!=0))throw new Win32Exception();}
            finally {if(token!=IntPtr.Zero)CloseHandle(token);}
        }
    }
    public static uint IoPrivilegeAttributes() {
        IntPtr token,buffer=IntPtr.Zero;Luid luid;int needed;
        if(!OpenProcessToken(new IntPtr(-1),8,out token))throw new Win32Exception();
        try {
            if(!LookupPrivilegeValue(null,"SeIncreaseBasePriorityPrivilege",out luid))throw new Win32Exception();
            GetTokenInformation(token,3,IntPtr.Zero,0,out needed);buffer=Marshal.AllocHGlobal(needed);
            if(!GetTokenInformation(token,3,buffer,needed,out needed))throw new Win32Exception();
            int count=Marshal.ReadInt32(buffer);
            for(int i=0;i<count;i++) {int offset=4+i*12;if((uint)Marshal.ReadInt32(buffer,offset)==luid.low && Marshal.ReadInt32(buffer,offset+4)==luid.high)return (uint)Marshal.ReadInt32(buffer,offset+8);}
            return uint.MaxValue;
        } finally {if(buffer!=IntPtr.Zero)Marshal.FreeHGlobal(buffer);CloseHandle(token);}
    }
    public static void SetMemory(Process p,uint value) { if(!SetProcessInformation(p.Handle,0,ref value,4)) throw new Win32Exception(); }
    public static byte[] DenySetInformation(Process p) {
        uint needed; GetKernelObjectSecurity(p.Handle,4,null,0,out needed); var original=new byte[needed];
        if(!GetKernelObjectSecurity(p.Handle,4,original,needed,out needed)) throw new Win32Exception();
        var descriptor=new RawSecurityDescriptor(original,0); var sid=WindowsIdentity.GetCurrent().User;
        descriptor.DiscretionaryAcl.InsertAce(0,new CommonAce(AceFlags.None,AceQualifier.AccessDenied,0x200,sid,false,null));
        var changed=new byte[descriptor.BinaryLength];descriptor.GetBinaryForm(changed,0);
        if(!SetKernelObjectSecurity(p.Handle,4,changed)) throw new Win32Exception();return original;
    }
    public static void RestoreDacl(Process p,byte[] bytes) { if(!SetKernelObjectSecurity(p.Handle,4,bytes)) throw new Win32Exception(); }
    public static IntPtr PinNormal(Process p) { return PinPriority(p,0x20); }
    public static IntPtr PinPriority(Process p,uint priority) {
        var job=CreateJobObject(IntPtr.Zero,null);if(job==IntPtr.Zero)throw new Win32Exception();
        var limits=new Limits { flags=0x20, priority=priority };
        if(!SetInformationJobObject(job,2,ref limits,(uint)Marshal.SizeOf(typeof(Limits))) || !AssignProcessToJobObject(job,p.Handle)) { CloseHandle(job); throw new Win32Exception(); }
        return job;
    }
    public static void ChangeJobPriority(IntPtr job,uint priority) {
        var limits=new Limits { flags=priority==0 ? 0u : 0x20u, priority=priority };
        if(!SetInformationJobObject(job,2,ref limits,(uint)Marshal.SizeOf(typeof(Limits)))) throw new Win32Exception();
    }
}
