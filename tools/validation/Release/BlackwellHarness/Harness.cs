using System.Diagnostics;
using System.Text.Json;
using RooIndustries.Optimizer;
using RooIndustries.OptimizationSuite.Services;

if(args.Length!=3)throw new ArgumentException("mode, probe path and metadata path are required");
if(!PolicyRootSecurity.Elevated())throw new InvalidOperationException("Harness parent must be elevated");
var mode=args[0];var probe=Path.GetFullPath(args[1]);var directory=Path.GetDirectoryName(probe)!;
var parent=Process.GetCurrentProcess();var report=Path.Combine(directory,"probe-report.json");
var expectedTemp=Path.Combine(RuntimeEnvironment.Profile,"AppData","Local","Temp");
string? protectedTemp=null;string? assignedTemp=null;
if(mode=="fallback") {
    var utilities=Path.GetFullPath(Path.Combine(directory,"..",".."));
    var previous=Environment.GetEnvironmentVariable("ROO_INDUSTRIES_UTILITIES_ROOT");
    try {
        Environment.SetEnvironmentVariable("ROO_INDUSTRIES_UTILITIES_ROOT",utilities);
        var service=new ToolLauncherService(Path.Combine(directory,"absent-package"),Path.Combine(directory,"absent-cache"));
        var tool=new ToolDefinition("blackwell-probe","Integrity probe","Native token probe","Diagnostics","https://example.invalid/","Utilities/Other/Probe/IntegrityProbe.exe",[],"open",null);
        var target=service.Resolve(tool);
        if(target.Path!=probe||target.FromArchive||target.Action!="Open")throw new InvalidOperationException("Fixture did not select Utilities fallback");
        await service.OpenAsync(tool);
    } finally {Environment.SetEnvironmentVariable("ROO_INDUSTRIES_UTILITIES_ROOT",previous);}
} else if(mode=="direct") RuntimeEnvironment.OpenInExplorer(probe);
else if(mode=="temp") {
    var start=new ProcessStartInfo(probe){UseShellExecute=false};
    RuntimeEnvironment.Apply(start);protectedTemp=start.Environment["TEMP"];
    start.Environment["TEMP"]=start.Environment["TMP"]=RuntimeEnvironment.ExpandUserVariables("%TEMP%");
    assignedTemp=start.Environment["TEMP"];
    using var child=Process.Start(start)??throw new InvalidOperationException("TEMP probe did not start");
    if(!child.WaitForExit(15000))throw new TimeoutException("TEMP probe did not finish");
    if(child.ExitCode!=0)throw new InvalidOperationException("TEMP probe failed");
} else throw new ArgumentException("Unknown mode");
var deadline=DateTime.UtcNow.AddSeconds(25);
while(!File.Exists(report)&&DateTime.UtcNow<deadline)await Task.Delay(50);
if(!File.Exists(report))throw new TimeoutException("Native probe did not produce evidence");
var text=File.ReadAllText(report);using var json=JsonDocument.Parse(text);var data=json.RootElement;
if(data.GetProperty("session").GetInt32()!=parent.SessionId)throw new InvalidOperationException("Probe session differs from elevated parent");
var integrity=data.GetProperty("integrity").GetString();
File.WriteAllText(args[2],JsonSerializer.Serialize(new{mode,parentPid=parent.Id,parentSession=parent.SessionId,parentElevated=true,expectedUserTemp=expectedTemp,protectedTemp,assignedTemp,probe=data.Clone()},new JsonSerializerOptions{WriteIndented=true}));
if(mode!="temp"&&(integrity!="Medium"||data.GetProperty("elevated").GetBoolean()))throw new InvalidOperationException("Unsafe shell handoff: "+integrity);
if(mode=="temp"&&(data.GetProperty("TEMP").GetString()!=expectedTemp||data.GetProperty("TMP").GetString()!=expectedTemp||expectedTemp==protectedTemp))throw new InvalidOperationException("Disk Cleanup TEMP harness differs from real user TEMP or equals protected TEMP");
Console.WriteLine("PASS "+mode+" native probe "+integrity+" session "+parent.SessionId);
