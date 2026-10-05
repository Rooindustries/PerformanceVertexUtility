using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Security.Cryptography;
using System.Web.Script.Serialization;

class BlackwellReadmeLaunch
{
    static int Main()
    {
        string folder=AppDomain.CurrentDomain.BaseDirectory;var json=new JavaScriptSerializer();
        try {
            var native=json.Deserialize<Dictionary<string,object>>(BlackwellNativeProbe.Inspect(Process.GetCurrentProcess().Id));
            using(var stream=new FileStream(Path.Combine(folder,"probe-report.json.tmp"),FileMode.CreateNew,FileAccess.Write,FileShare.None))using(var writer=new StreamWriter(stream)){writer.Write(json.Serialize(native));}
            File.Move(Path.Combine(folder,"probe-report.json.tmp"),Path.Combine(folder,"probe-report.json"));
            if((string)native["integrity"]!="Medium"||(bool)native["elevated"])throw new InvalidOperationException("Normal installer caller was not Medium");
            string installer=File.ReadAllText(Path.Combine(folder,"installer-path.txt")).Trim();string hash;
            using(var stream=File.OpenRead(installer))using(var sha=SHA256.Create()){hash=BitConverter.ToString(sha.ComputeHash(stream)).Replace("-","");}
            if(hash!="6C7970601D0A877F3A2A476C2091C4F11154195CE8973E8D28E10070E77B32F2")throw new InvalidOperationException("Installer bytes differ");
            using(var process=Process.Start(new ProcessStartInfo(installer){UseShellExecute=true})) {
                File.WriteAllText(Path.Combine(folder,"setup-started.json.tmp"),json.Serialize(new{pid=process.Id,observedUtc=DateTime.UtcNow.ToString("o")}));
                File.Move(Path.Combine(folder,"setup-started.json.tmp"),Path.Combine(folder,"setup-started.json"));
            }
            return 0;
        } catch(Exception error) {File.WriteAllText(Path.Combine(folder,"setup-error.json"),json.Serialize(new{error=error.Message,observedUtc=DateTime.UtcNow.ToString("o")}));return 1;}
    }
}
