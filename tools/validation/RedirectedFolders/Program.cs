using System.Text.Json;
using RooIndustries.Optimizer;
using Microsoft.Win32;
var scratch=args[0]; var scenario=args[1];
FolderFixture.Begin(scratch,scenario,"core");
Directory.CreateDirectory(Path.Combine(scratch,"protected-temp"));
typeof(RuntimeEnvironment).GetField("_protectedTemp",System.Reflection.BindingFlags.NonPublic|System.Reflection.BindingFlags.Static)!.SetValue(null,Path.Combine(scratch,"protected-temp"));
var oracle=scenario is "clean" or "redirect" or "redirect-string" or "absent" or "guid-only"?FolderFixture.Oracle(false):"not applicable";
if(scenario=="cache-poison")Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
string? local=null,roaming=null,root=null,temp=null;bool refused=false;string message="";string? architecture=null;bool pins=true;
try {
    local=RuntimeEnvironment.LocalAppData;roaming=RuntimeEnvironment.ExpandUserVariables("%APPDATA%");temp=RuntimeEnvironment.ExpandUserVariables("%TEMP%");
    if(scenario=="launcher-poison") {
        var start=new System.Diagnostics.ProcessStartInfo(Path.Combine(Environment.SystemDirectory,@"WindowsPowerShell\v1.0\powershell.exe")){UseShellExecute=false,CreateNoWindow=true,RedirectStandardOutput=true,RedirectStandardError=true,WorkingDirectory=scratch};
        RuntimeEnvironment.Apply(start);
        start.ArgumentList.Add("-NoProfile");start.ArgumentList.Add("-NonInteractive");start.ArgumentList.Add("-Command");
        start.ArgumentList.Add("[Environment]::GetFolderPath('UserProfile'); $env:LOCALAPPDATA; $env:APPDATA; [IntPtr]::Size; $env:DOTNET_EnableDiagnostics; $env:COMPlus_EnableDiagnostics");
        using var child=System.Diagnostics.Process.Start(start)!;var output=child.StandardOutput.ReadToEnd();var error=child.StandardError.ReadToEnd();child.WaitForExit();var lines=output.Split(new[]{'\r','\n'},StringSplitOptions.RemoveEmptyEntries);
        if(child.ExitCode!=0||lines.Length!=6||lines[0]!=FolderFixture.Profile||lines[1]!=local||lines[2]!=roaming||lines[3]!="8"||lines[4]!="0"||lines[5]!="0")throw new Exception("Rebuilt child environment failed: "+error+output);
        if(Directory.Exists(@"C:\RooIndustriesF10Missing"))throw new Exception("Clean launcher created the poisoned profile");
        root=BrandCompatibility.DataRoot(local);
    }
    else if(scenario.StartsWith("other-")) {
        root=Path.Combine(FolderFixture.Folders,"other-root",scenario,"process-rules");
        if(scenario=="other-default"||scenario=="other-loaded"||scenario=="other-percent"){
            var profile=Path.Combine(FolderFixture.Folders,scenario=="other-percent"?"other%profile":"other-profile");var data=Path.Combine(profile,"AppData","Local");Directory.CreateDirectory(data);
            if(scenario=="other-loaded"){data=Path.Combine(FolderFixture.Folders,"other-loaded","Local");Directory.CreateDirectory(data);}
            using var p=Registry.LocalMachine.CreateSubKey(@"SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\"+FolderFixture.OtherSid);p.SetValue("ProfileImagePath",profile);
            using var u=Registry.Users.CreateSubKey(FolderFixture.OtherSid+@"\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders");u.SetValue("Local AppData",data);
            root=Path.Combine(data,"process-rules");
        }
        FolderFixture.Protect(root);
        using var markers=Registry.LocalMachine.OpenSubKey(PolicyRootSecurity.MarkerKey,true)!;
        if(scenario is not ("other-unmarked" or "other-default" or "other-loaded" or "other-percent"))markers.SetValue(PolicyRootSecurity.MarkerName(root),scenario=="other-mismatch"?FolderFixture.Sid:FolderFixture.OtherSid);
        var requested=scenario=="other-principal"?FolderFixture.OtherSid.Replace("1001","1002"):FolderFixture.OtherSid;
        PolicyRootSecurity.Secure(root,requested);
    }
    else if(scenario=="short-path") {
        root=Path.Combine(local,"RooIndustriesOptimizationSuite");FolderFixture.Protect(root);
        using var markers=Registry.LocalMachine.OpenSubKey(PolicyRootSecurity.MarkerKey,true)!;markers.SetValue(PolicyRootSecurity.MarkerName(root),FolderFixture.Sid);
        var chosen=BrandCompatibility.LocalDataRoot;
        if(PolicyRootSecurity.MarkerName(chosen)!=PolicyRootSecurity.MarkerName(root))throw new Exception("Short marker differs");
    }
    else if(scenario=="redirect-protected") {
        if(!local.StartsWith(FolderFixture.Folders+"\\",StringComparison.OrdinalIgnoreCase)||local!=FolderFixture.Local)throw new Exception("Resolver escaped the owned fixture before protection");
        root=Path.Combine(local,"RooIndustriesOptimizationSuite");
        PolicyRootSecurity.Secure(root,DataFolder.Kind);
        if(PolicyRootSecurity.Problem(root,DataFolder.Kind,deep:false)!=null)throw new Exception("Protected root ACL check failed");
        root=BrandCompatibility.LocalDataRoot;
    }
    else if(scenario is "protected-move" or "marker-missing" or "marker-damaged" or "marker-other-sid" or "marker-ambiguous")root=BrandCompatibility.LocalDataRoot;
    else root=BrandCompatibility.DataRoot(Path.Combine(FolderFixture.Folders,"redir","Local"));
    if(scenario is "machine-percent" or "machine-unknown") {
        var block=RuntimeEnvironment.ChildEnvironment();
        var programData=scenario=="machine-percent"?Path.Combine(FolderFixture.Folders,"machine%folder","ProgramData"):Path.Combine(Path.GetPathRoot(Environment.SystemDirectory)!,"ProgramData");
        var publicFolder=scenario=="machine-percent"?Path.Combine(FolderFixture.Folders,"machine%folder","Public"):Path.Combine(Path.GetDirectoryName(FolderFixture.Profile)!,"Public");
        if(block["ProgramData"]!=programData||block["PUBLIC"]!=publicFolder)throw new Exception("Machine folder differs: "+block["ProgramData"]+"; "+block["PUBLIC"]);
    }
    if(scenario.StartsWith("redirect")) {var block=RuntimeEnvironment.ChildEnvironment();architecture=block["PROCESSOR_ARCHITECTURE"];pins=RuntimeEnvironment.Pinned.All(n=>block[n]=="0");}
} catch(Exception e){refused=true;message=e.Message;}
bool expectedRefusal=new[]{"install-root","short-system","reparse-parent","missing","relative","empty","unknown","unknown-absolute","system-poison","unc","dword","drive-root","windows","protected-move","marker-missing","marker-damaged","marker-other-sid","marker-ambiguous","other-mismatch","other-unmarked","other-principal"}.Contains(scenario);
var expectedMessage=scenario is "protected-move" or "marker-ambiguous"?"folder setting changed":scenario is "marker-missing" or "marker-damaged"?"missing or damaged":scenario=="marker-other-sid"?"marker belongs":scenario is "other-mismatch" or "other-principal"?"marker belongs":scenario=="other-unmarked"?"folder settings":"AppData folder settings";
var kept=scenario!="protected-move"||!Directory.Exists(Path.Combine(FolderFixture.Local,"RooIndustriesOptimizationSuite"))&&File.ReadAllText(Path.Combine(FolderFixture.Folders,"old","Local","RooIndustriesOptimizationSuite","keep.txt"))=="Keep original protected data";
var passed=kept&&(!refused||message.Contains(expectedMessage))&&refused==expectedRefusal&&(refused||(local==FolderFixture.Local&&roaming==FolderFixture.Roaming&&temp==Path.Combine(FolderFixture.Profile,"AppData","Local","Temp")&&pins&&(architecture==null||architecture=="AMD64")))&&(oracle=="not applicable"||refused||oracle==local);
Console.WriteLine(JsonSerializer.Serialize(new{host="core",scenario,localAppData=local,roamingAppData=roaming,profile=FolderFixture.Profile,dataRoot=root,temp,refused,message,oracle,architecture,pins,kept,passed}));FolderFixture.End();return passed?0:1;
