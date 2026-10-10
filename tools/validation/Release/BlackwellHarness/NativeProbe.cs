using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

public static class BlackwellNativeProbe
{
    [StructLayout(LayoutKind.Sequential)] struct Pbi { public IntPtr Exit, Peb, Affinity, Priority, Pid, Parent; }
    [DllImport("advapi32.dll", SetLastError=true)] static extern bool OpenProcessToken(IntPtr process,uint access,out IntPtr token);
    [DllImport("advapi32.dll", SetLastError=true)] static extern bool GetTokenInformation(IntPtr token,int kind,IntPtr buffer,int length,out int needed);
    [DllImport("advapi32.dll")] static extern IntPtr GetSidSubAuthorityCount(IntPtr sid);
    [DllImport("advapi32.dll")] static extern IntPtr GetSidSubAuthority(IntPtr sid,uint index);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
    [DllImport("kernel32.dll",SetLastError=true)] static extern IntPtr OpenProcess(uint access,bool inherit,int pid);
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool GetProcessTimes(IntPtr handle,out long creation,out long exit,out long kernel,out long user);
    [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool QueryFullProcessImageName(IntPtr handle,int flags,StringBuilder path,ref int size);
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool ProcessIdToSessionId(int pid,out uint session);
    [DllImport("kernel32.dll")] static extern int GetCurrentProcessId();
    [DllImport("ntdll.dll")] static extern int NtQueryInformationProcess(IntPtr handle,int kind,ref Pbi info,int size,out int returned);

    static Dictionary<string,object> InspectRow(int processId)
    {
        var handle=OpenProcess(0x1400,false,processId);
        if(handle==IntPtr.Zero)throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        try {
            IntPtr token;
            if(!OpenProcessToken(handle,8,out token))throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
            var buffer=Marshal.AllocHGlobal(4096);
            try {
                int needed;
                if(!GetTokenInformation(token,20,buffer,4,out needed))throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
                bool elevated=Marshal.ReadInt32(buffer)!=0;
                if(!GetTokenInformation(token,18,buffer,4,out needed))throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
                int elevationType=Marshal.ReadInt32(buffer);
                if(!GetTokenInformation(token,25,buffer,4096,out needed))throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
                IntPtr sid=Marshal.ReadIntPtr(buffer);uint rid=(uint)Marshal.ReadInt32(GetSidSubAuthority(sid,(uint)(Marshal.ReadByte(GetSidSubAuthorityCount(sid))-1)));
                var pbi=new Pbi();int returned;
                if(NtQueryInformationProcess(handle,0,ref pbi,Marshal.SizeOf(typeof(Pbi)),out returned)!=0)throw new InvalidOperationException("Native parent lookup failed");
                var parent=new Dictionary<string,object>{{"pid",pbi.Parent.ToInt32()}};
                long creation,exit,kernel,user;uint session;
                if(!GetProcessTimes(handle,out creation,out exit,out kernel,out user)||!ProcessIdToSessionId(processId,out session))throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
                try {
                    var p=OpenProcess(0x1000,false,pbi.Parent.ToInt32());if(p==IntPtr.Zero)throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
                    try {
                        long pc,pe,pk,pu;uint ps;
                        if(!GetProcessTimes(p,out pc,out pe,out pk,out pu)||!ProcessIdToSessionId(pbi.Parent.ToInt32(),out ps))throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
                        if(pc>creation)throw new InvalidOperationException("Parent PID recycled");
                        parent["imagePath"]=Image(p);parent["creationTimeFileTimeUtc"]=pc.ToString();parent["session"]=ps;
                    } finally {CloseHandle(p);}
                } catch(Exception error) {parent["lookupError"]=error.Message;}
                return new Dictionary<string,object>{{"pid",processId},{"creationTimeFileTimeUtc",creation.ToString()},{"imagePath",Image(handle)},{"session",session},{"parent",parent},{"elevated",elevated},{"elevationType",elevationType},{"integrityRid",rid},{"integrity",rid>=0x4000?"System":rid>=0x3000?"High":rid>=0x2000?"Medium":rid>=0x1000?"Low":"Untrusted"}};
            } finally {Marshal.FreeHGlobal(buffer);CloseHandle(token);}
        } finally {CloseHandle(handle);}
    }
    static string Image(IntPtr handle){var path=new StringBuilder(32768);int size=path.Capacity;if(!QueryFullProcessImageName(handle,0,path,ref size))throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());return path.ToString();}
    static string Json(object value){if(value==null)return "null";var text=value as string;if(text!=null){var b=new StringBuilder("\"");foreach(char c in text){if(c=='\\'||c=='\"')b.Append('\\').Append(c);else if(c<' ')b.Append("\\u").Append(((int)c).ToString("x4"));else b.Append(c);}return b.Append('"').ToString();}if(value is bool)return(bool)value?"true":"false";var row=value as Dictionary<string,object>;if(row!=null){var b=new StringBuilder("{");bool first=true;foreach(var pair in row){if(!first)b.Append(',');first=false;b.Append(Json(pair.Key)).Append(':').Append(Json(pair.Value));}return b.Append('}').ToString();}return Convert.ToString(value,CultureInfo.InvariantCulture);}
    public static string Inspect(int processId){return Json(InspectRow(processId));}
    static int Main()
    {
        try {
            var row=InspectRow(GetCurrentProcessId());
            row["TEMP"]=Environment.GetEnvironmentVariable("TEMP");row["TMP"]=Environment.GetEnvironmentVariable("TMP");
            string path=Path.Combine(AppDomain.CurrentDomain.BaseDirectory,"probe-report.json");
            using(var stream=new FileStream(path+".tmp",FileMode.CreateNew,FileAccess.Write,FileShare.None))using(var writer=new StreamWriter(stream)){writer.Write(Json(row));}
            File.Move(path+".tmp",path);
            return 0;
        } catch(Exception e) {File.WriteAllText(Path.Combine(AppDomain.CurrentDomain.BaseDirectory,"probe-error.txt"),e.ToString());return 1;}
    }
}
