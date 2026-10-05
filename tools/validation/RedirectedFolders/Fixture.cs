using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Security.AccessControl;
using Microsoft.Win32;
using Microsoft.Win32.SafeHandles;

public static class FolderFixture {
    public static string Profile, Local, Roaming, Sid, Scenario, Scratch;
    static IntPtr users, machine;
    public static string Folders;
    const string Usf = @"Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders";
    [DllImport("advapi32.dll", CharSet=CharSet.Unicode)] static extern int RegLoadAppKeyW(string path, out IntPtr key, int access, int options, int reserved);
    [DllImport("advapi32.dll")] static extern int RegOverridePredefKey(IntPtr root, IntPtr key);
    [DllImport("advapi32.dll")] static extern int RegCloseKey(IntPtr key);
    [DllImport("shell32.dll")] static extern int SHGetKnownFolderPath(ref Guid id, uint flags, IntPtr token, out IntPtr path);
    public static string Oracle(bool roaming) {
        var id=new Guid(roaming?"3EB685DB-65F9-4CF6-A03A-E3EF65729F3D":"F1B32785-6FBA-4FCF-9D55-7B8E7F157091");
        IntPtr result; using(var token=WindowsIdentity.GetCurrent()) {
            int hr=SHGetKnownFolderPath(ref id,0x4000,token.Token,out result);
            if(hr!=0)return "HRESULT="+hr.ToString("X8");
            try{return Marshal.PtrToStringUni(result);}finally{Marshal.FreeCoTaskMem(result);}
        }
    }
    static IntPtr Overlay(string path, uint root) {
        IntPtr key; int rc=RegLoadAppKeyW(path,out key,0xF003F,0,0);if(rc!=0)throw new Exception("RegLoadAppKey "+rc);
        rc=RegOverridePredefKey(new IntPtr(unchecked((int)root)),key);if(rc!=0)throw new Exception("RegOverridePredefKey "+rc);return key;
    }
    public static void Begin(string scratch,string scenario,string host) {
        Scratch=scratch;Scenario=scenario;Profile=Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);Sid=WindowsIdentity.GetCurrent().User.Value;
        Local=Path.Combine(Profile,"AppData","Local");Roaming=Path.Combine(Profile,"AppData","Roaming");
        if(!Directory.Exists(scratch)||!File.Exists(Path.Combine(scratch,"fixture-owner.txt")))throw new Exception("Unowned fixture");
        Folders=File.ReadAllText(Path.Combine(scratch,"fixture-folders.txt")).Trim();
        users=Overlay(Path.Combine(scratch,scenario+"-"+host+"-users.hive"),0x80000003);
        using(var key=Registry.Users.CreateSubKey(Sid+"\\"+Usf)) {
            key.SetValue("Local AppData",@"%USERPROFILE%\AppData\Local",RegistryValueKind.ExpandString);key.SetValue("AppData",@"%USERPROFILE%\AppData\Roaming",RegistryValueKind.ExpandString);
            if(scenario.StartsWith("redirect")||scenario=="protected-move"||scenario=="marker-missing"||scenario=="marker-damaged"||scenario=="marker-other-sid"||scenario=="marker-ambiguous"||scenario=="short-path"||scenario=="roaming-unc"||scenario.StartsWith("other-")||scenario=="launcher-poison") {
                Local=Path.Combine(Folders,"redir","Local");Roaming=Path.Combine(Folders,"redir","Roaming");
                key.SetValue("Local AppData",Local,scenario=="redirect-string"?RegistryValueKind.String:RegistryValueKind.ExpandString);key.SetValue("AppData",Roaming,RegistryValueKind.ExpandString);
            }
            if(scenario=="reparse-parent"){
                var link=Path.Combine(Folders,"linked-local");
                if(!Directory.Exists(link)&&!CreateSymbolicLinkW(link,Path.Combine(Folders,"redir"),1))throw new Exception("Fixture symlink failed "+Marshal.GetLastWin32Error());
                key.SetValue("Local AppData",Path.Combine(link,"Local"));
            }
            if(scenario=="missing")key.SetValue("Local AppData",Path.Combine(scratch,"redir-missing","Local"));
            if(scenario=="relative")key.SetValue("Local AppData",@"relative\Local");
            if(scenario=="empty")key.SetValue("Local AppData","");
            if(scenario=="unknown")key.SetValue("Local AppData",@"%ROO_F10_NOPE%\Local");
            if(scenario=="single-percent"||scenario=="single-percent-expand"||scenario=="unknown-absolute") {
                var folder=scenario=="unknown-absolute"?"percent%ROO_F10_NOPE%folder":"percent%folder";
                Local=Path.Combine(Folders,folder,"Local");Roaming=Path.Combine(Folders,folder,"Roaming");
                Directory.CreateDirectory(Local);Directory.CreateDirectory(Roaming);
                key.SetValue("Local AppData",scenario=="single-percent-expand"?"%USERPROFILE%"+Local.Substring(Profile.Length):Local,RegistryValueKind.ExpandString);
                key.SetValue("AppData",Roaming,RegistryValueKind.ExpandString);
            }
            if(scenario=="system-poison")key.SetValue("Local AppData",@"%SystemRoot%\RooF10\Local");
            if(scenario=="unc")key.SetValue("Local AppData",@"\\127.0.0.1\roo-f10-none\Local");
            if(scenario=="dword")key.SetValue("Local AppData",42,RegistryValueKind.DWord);
            if(scenario=="drive-root")key.SetValue("Local AppData",@"C:\");
            if(scenario=="install-root"){Local=Path.Combine(Folders,"custom-install");Directory.CreateDirectory(Local);key.SetValue("Local AppData",Local);}
            if(scenario=="download-local"){Local=Path.Combine(Folders,"download-local");Directory.CreateDirectory(Local);key.SetValue("Local AppData",Local);}
            if(scenario=="short-system")key.SetValue("Local AppData",Short(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles)));
            if(scenario=="windows")key.SetValue("Local AppData",Environment.GetFolderPath(Environment.SpecialFolder.Windows));
            if(scenario=="roaming-unc") {Roaming=@"\\127.0.0.1\roo-f10-none\Roaming";key.SetValue("AppData",Roaming);}
            if(scenario=="absent"||scenario=="guid-only") {key.DeleteValue("Local AppData");key.DeleteValue("AppData");if(scenario=="guid-only")key.SetValue("{F1B32785-6FBA-4FCF-9D55-7B8E7F157091}",Path.Combine(Folders,"redir","Local"));}
            if(scenario=="profile-expand") {Local=Path.Combine(Folders,"redir","Local");key.SetValue("Local AppData","%uSeRpRoFiLe%"+Local.Substring(Profile.Length));}
            if(scenario=="protected-move"){Local=Path.Combine(Folders,"new-redirect","Local");Directory.CreateDirectory(Local);key.SetValue("Local AppData",Local);}
            if(scenario=="marker-damaged"||scenario=="marker-other-sid"){Local=Path.Combine(Folders,scenario,"Local");Directory.CreateDirectory(Local);Directory.CreateDirectory(Path.Combine(Local,"RooIndustriesOptimizationSuite"));key.SetValue("Local AppData",Local);}
            if(scenario=="marker-missing"){Local=Path.Combine(Folders,"missing-fixture","Local");Directory.CreateDirectory(Local);key.SetValue("Local AppData",Local);}
            if(scenario=="short-path"){Local=Path.Combine(Folders,"short-fixture","Local");Directory.CreateDirectory(Local);var shortPath=Short(Local);key.SetValue("Local AppData",shortPath);Local=Path.GetFullPath(shortPath);}
            if(scenario=="redirect-protected"){Local=Path.Combine(Folders,"protected-fixture","Local");Directory.CreateDirectory(Local);key.SetValue("Local AppData",Local);}
        }
        if(scenario=="environment"||scenario=="volatile")using(var key=Registry.Users.CreateSubKey(Sid+"\\"+(scenario=="environment"?"Environment":"Volatile Environment"))) {
            foreach(var name in new[]{"USERPROFILE","LOCALAPPDATA","APPDATA","TEMP"})key.SetValue(name,Path.Combine(scratch,scenario=="environment"?"henv":"hvol",name));
        }
        machine=Overlay(Path.Combine(scratch,scenario+"-"+host+"-machine.hive"),0x80000002);
        using(var key=Registry.LocalMachine.CreateSubKey(@"SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\"+Sid))key.SetValue("ProfileImagePath",Profile);
        if(scenario.StartsWith("other-")){var otherProfile=Path.Combine(Folders,scenario=="other-percent"?"other%profile":"other-profile");Directory.CreateDirectory(otherProfile);using(var key=Registry.LocalMachine.CreateSubKey(@"SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\"+OtherSid))key.SetValue("ProfileImagePath",otherProfile);}
        using(var key=Registry.LocalMachine.CreateSubKey(@"SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList")){key.SetValue("Public",Path.Combine(Path.GetDirectoryName(Profile),"Public"));key.SetValue("ProgramData",@"%SystemDrive%\ProgramData");}
        if(scenario=="machine-percent"||scenario=="machine-unknown")using(var key=Registry.LocalMachine.OpenSubKey(@"SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList",true)) {
            var folder=Path.Combine(Folders,scenario=="machine-percent"?"machine%folder":"machine%ROO_F10_NOPE%folder");Directory.CreateDirectory(folder);
            key.SetValue("Public",Path.Combine(folder,"Public"));key.SetValue("ProgramData",Path.Combine(folder,"ProgramData"));
        }
        using(var key=Registry.LocalMachine.CreateSubKey(@"SYSTEM\CurrentControlSet\Control\Session Manager\Environment"))key.SetValue("PROCESSOR_ARCHITECTURE","ARM64");
        using(var key=Registry.LocalMachine.CreateSubKey(@"SOFTWARE\RooIndustries\OptimizationSuite\GovernorRoots")) {
            foreach(var name in key.GetValueNames())key.DeleteValue(name);
            if(scenario=="protected-move"){var old=Path.Combine(Folders,"old","Local","RooIndustriesOptimizationSuite");Protect(old);File.WriteAllText(Path.Combine(old,"keep.txt"),"Keep original protected data");}
            if(scenario=="protected-move")key.SetValue(Path.Combine(Folders,"old","Local","RooIndustriesOptimizationSuite").ToUpperInvariant(),Sid);
            if(scenario=="marker-missing"||scenario=="marker-damaged")key.SetValue(Path.Combine(Local,"RooIndustriesOptimizationSuite").ToUpperInvariant(),Sid);
            if(scenario=="marker-other-sid")key.SetValue(Path.Combine(Local,"RooIndustriesOptimizationSuite").ToUpperInvariant(),OtherSid);
            if(scenario=="marker-ambiguous")foreach(var name in new[]{"old","other"})key.SetValue(Path.Combine(Folders,name,"Local","RooIndustriesOptimizationSuite").ToUpperInvariant(),Sid);
        }
    }
    public static void Protect(string root) {
        if(!root.StartsWith(Folders+"\\",StringComparison.OrdinalIgnoreCase))throw new Exception("Fixture root escaped");
        Directory.CreateDirectory(root);
        var acl=new DirectorySecurity();acl.SetAccessRuleProtection(true,false);acl.SetOwner(new SecurityIdentifier("S-1-5-32-544"));
        foreach(var sid in new[]{"S-1-5-32-544","S-1-5-18","S-1-3-4",Sid})acl.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier(sid),sid=="S-1-5-32-544"||sid=="S-1-5-18"?FileSystemRights.FullControl:FileSystemRights.ReadAndExecute|FileSystemRights.Synchronize,InheritanceFlags.ContainerInherit|InheritanceFlags.ObjectInherit,PropagationFlags.None,AccessControlType.Allow));
        new DirectoryInfo(root).SetAccessControl(acl);
    }
    [DllImport("kernel32.dll",CharSet=CharSet.Unicode)] static extern uint GetShortPathNameW(string path,System.Text.StringBuilder buffer,uint length);
    [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool CreateSymbolicLinkW(string link,string target,int flags);
    public static string Short(string path){var buffer=new System.Text.StringBuilder(32768);uint size=GetShortPathNameW(path,buffer,(uint)buffer.Capacity);if(size==0||size>=buffer.Capacity)throw new Exception("Short path unavailable");return buffer.ToString();}
    public const string OtherSid="S-1-5-21-111111111-222222222-333333333-1001";
    public static void End(){RegOverridePredefKey(new IntPtr(unchecked((int)0x80000003)),IntPtr.Zero);RegOverridePredefKey(new IntPtr(unchecked((int)0x80000002)),IntPtr.Zero);if(users!=IntPtr.Zero)RegCloseKey(users);if(machine!=IntPtr.Zero)RegCloseKey(machine);}
}
