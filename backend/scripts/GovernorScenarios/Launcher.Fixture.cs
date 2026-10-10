using System.Diagnostics;
using System.Reflection;
using System.Text.Json;
using RooIndustries.Optimizer;

var before = Environment.GetEnvironmentVariable("USERPROFILE");
var beforeVariables = new[] { "USERPROFILE", "LOCALAPPDATA", "windir", "SystemRoot", "ComSpec", "PATH", "PATHEXT", "APPDATA", "TEMP", "TMP" }.ToDictionary(name => name, Environment.GetEnvironmentVariable);
using var overlay = new RooIndustriesClaimsHive(args[0], args[1]);
var controls = typeof(RuntimeEnvironment).Assembly.GetType("RooIndustries.Optimizer.PowerShellControls", true)!;
var launcher = controls.GetMethod("Start", BindingFlags.Static | BindingFlags.NonPublic)!;
using var process = (Process)launcher.Invoke(null, new object[] { new { action = "read", address = new ControlAddress("filesystem", "ntfs", "last-access") } })!;
try
{
    var seen = ProcessEnvironmentReader.Read(process.Id);
    process.StandardInput.Close();
    var output = process.StandardOutput.ReadToEndAsync();
    var error = process.StandardError.ReadToEndAsync();
    if (!process.WaitForExit(60000)) throw new TimeoutException("The real Windows control helper did not exit.");
    Console.WriteLine(JsonSerializer.Serialize(new { beforeUserProfile = before, beforeVariables, exitCode = process.ExitCode, output = output.Result.Trim(), error = error.Result.Trim(), variables = seen.Variables.Where(pair => !pair.Key.StartsWith("ROO_INDUSTRIES_CONTROL_", StringComparison.Ordinal)).ToDictionary(pair => pair.Key, pair => pair.Value), parentAssembly = controls.Assembly.Location }));
    Environment.ExitCode = process.ExitCode;
}
finally { if (!process.HasExited) { process.Kill(true); process.WaitForExit(10000); } }
