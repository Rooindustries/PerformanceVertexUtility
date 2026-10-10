using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Security.Cryptography;
using System.Text.RegularExpressions;
using System.Web.Script.Serialization;

class BlackwellReadmeLaunch
{
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool GetProcessTimes(IntPtr handle,out long creation,out long exit,out long kernel,out long user);
    [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool QueryFullProcessImageName(IntPtr handle,int flags,StringBuilder path,ref int size);
    static object StartedIdentity(Process process,string expectedImage)
    {
        var handle=process.Handle;long creation,exit,kernel,user;var image=new StringBuilder(32768);int size=image.Capacity;
        if(!GetProcessTimes(handle,out creation,out exit,out kernel,out user)||!QueryFullProcessImageName(handle,0,image,ref size))throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        if(!String.Equals(image.ToString(),Path.GetFullPath(expectedImage),StringComparison.OrdinalIgnoreCase))throw new InvalidOperationException("Started installer image differs");
        return new {pid=process.Id,creationTimeFileTimeUtc=creation.ToString(),imagePath=image.ToString(),observedUtc=DateTime.UtcNow.ToString("o")};
    }
    static int Main()
    {
        string folder=AppDomain.CurrentDomain.BaseDirectory;var json=new JavaScriptSerializer();
        try {
            var native=json.Deserialize<Dictionary<string,object>>(BlackwellNativeProbe.Inspect(Process.GetCurrentProcess().Id));
            using(var stream=new FileStream(Path.Combine(folder,"probe-report.json.tmp"),FileMode.CreateNew,FileAccess.Write,FileShare.None))using(var writer=new StreamWriter(stream)){writer.Write(json.Serialize(native));}
            File.Move(Path.Combine(folder,"probe-report.json.tmp"),Path.Combine(folder,"probe-report.json"));
            if((string)native["integrity"]!="Medium"||(bool)native["elevated"])throw new InvalidOperationException("Normal installer caller was not Medium");
            string expected=File.ReadAllText(Path.Combine(folder,"expected-sha256.txt"));
            if(!Regex.IsMatch(expected,"\\A[A-Fa-f0-9]{64}\\z"))throw new InvalidOperationException("Expected installer SHA256 is malformed");
            string installer=File.ReadAllText(Path.Combine(folder,"installer-path.txt")).Trim();string hash;
            using(var stream=File.OpenRead(installer))using(var sha=SHA256.Create()){hash=BitConverter.ToString(sha.ComputeHash(stream)).Replace("-","");}
            if(!String.Equals(hash,expected,StringComparison.OrdinalIgnoreCase))throw new InvalidOperationException("Installer bytes differ");
            using(var process=Process.Start(new ProcessStartInfo(installer){UseShellExecute=true})) {
                File.WriteAllText(Path.Combine(folder,"setup-started.json.tmp"),json.Serialize(StartedIdentity(process,installer)));
                File.Move(Path.Combine(folder,"setup-started.json.tmp"),Path.Combine(folder,"setup-started.json"));
            }
            return 0;
        } catch(Exception error) {File.WriteAllText(Path.Combine(folder,"setup-error.json"),json.Serialize(new{error=error.Message,observedUtc=DateTime.UtcNow.ToString("o")}));return 1;}
    }
}
