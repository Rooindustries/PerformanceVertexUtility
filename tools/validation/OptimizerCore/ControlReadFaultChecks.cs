using System.Diagnostics;
using System.Text;
using System.Text.Json;
using RooIndustries.Optimizer;

static class ControlReadFaultChecks
{
    const string Helper = """
$ErrorActionPreference='Stop'
$request=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($env:ROO_INDUSTRIES_CONTROL_REQUEST))|ConvertFrom-Json
function Result($item,[string]$prefix){
    $name=[string]$item.target
    if($name -like 'stray-lf*'){[Console]::Out.Write("fixture notice for $name`n")}
    elseif($name -like 'stray*'){[Console]::Out.WriteLine("fixture notice for $name")}
    if($name -like 'noisy*'){[Console]::Error.WriteLine("noise from $name")}
    if($name -like 'crash-out*'){[Console]::Out.WriteLine("fixture partial output for $name")}
    if($name -like 'crash*'){[Console]::Error.WriteLine("fixture crash for $name");exit 7}
    if($name -like 'silent*'){exit 0}
    if($name -like 'truncated*'){[Console]::Out.Write($prefix+'{"address":{"kind":');exit 0}
    $text=if($name -like 'inband*'){@{error="fixture in-band error for $name"}|ConvertTo-Json -Compress}else{[ordered]@{address=$item;identity="fixture:$name";binding='fixture';value=$name}|ConvertTo-Json -Compress -Depth 5}
    $prefix+$text
}
if($request.action -eq 'read-batch'){
    $index=0
    foreach($item in @($request.addresses)){
        $line=Result $item ('ROO-CONTROL '+$index+' ')
        [Console]::Out.WriteLine($line);[Console]::Out.Flush();$index++
    }
    exit 0
}
[Console]::Out.Write((Result $request.address ''))
""";

    static Process Launch(object request)
    {
        var start = new ProcessStartInfo(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), @"WindowsPowerShell\v1.0\powershell.exe"))
        {
            UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true, RedirectStandardInput = true,
        };
        foreach (var argument in new[] { "-NoLogo", "-NoProfile", "-NonInteractive", "-EncodedCommand", Convert.ToBase64String(Encoding.Unicode.GetBytes("& ([ScriptBlock]::Create($env:ROO_INDUSTRIES_FAKE_HELPER))")) }) start.ArgumentList.Add(argument);
        start.Environment["ROO_INDUSTRIES_FAKE_HELPER"] = Helper;
        start.Environment["ROO_INDUSTRIES_CONTROL_REQUEST"] = Convert.ToBase64String(JsonSerializer.SerializeToUtf8Bytes(request, OperationFiles.Json));
        return Process.Start(start) ?? throw new IOException("Could not start the fake control helper.");
    }

    static string Describe((TweakControlRead? Read, Exception? Error) result)
        => result.Error is { } error ? "error " + error.GetType().Name + ": " + error.Message : JsonSerializer.Serialize(result.Read, OperationFiles.Json);

    public static void Run(Action<bool, string> check)
    {
        var original = PowerShellControls.Launcher;
        PowerShellControls.Launcher = Launch;
        try
        {
            string[] names = ["ok-1", "noisy-1", "ok-2", "inband-1", "stray-1", "ok-3", "stray-lf-1", "ok-4", "noisy-2", "crash-1", "ok-5", "crash-out-1", "ok-6", "truncated-1", "ok-7", "silent-1", "ok-8"];
            var addresses = names.Select(name => new ControlAddress("fixture", name, "value")).ToArray();
            var batched = PowerShellControls.ReadMany(addresses);
            check(batched.Count == addresses.Length, "A batched read of " + addresses.Length + " fixture addresses resolves every one of them: " + batched.Count);
            var different = new List<string>();
            foreach (var address in addresses)
            {
                (TweakControlRead?, Exception?) single;
                try { single = (PowerShellControls.Read(address), null); } catch (Exception error) { single = (null, error); }
                if (Describe(single) != Describe(batched[address])) different.Add(address.Target + ": batch=" + Describe(batched[address]) + " single=" + Describe(single));
            }
            check(different.Count == 0, "Every batched fixture read, including crashes, stray output, truncated and missing results, equals the per-address read of the same address: " + string.Join(" | ", different));
            var crash = Describe(batched[addresses.Single(address => address.Target == "crash-1")]);
            check(crash.Contains("exited 7", StringComparison.Ordinal) && crash.Contains("fixture crash for crash-1", StringComparison.Ordinal) && !crash.Contains("noise from", StringComparison.Ordinal),
                "A helper crash reports only the crashing address's own error text, not noise from addresses read earlier in the same helper: " + crash);
            var good = names.Where(name => name.StartsWith("ok-", StringComparison.Ordinal)).All(name => batched[addresses.Single(address => address.Target == name)].Read?.Value.GetString() == name);
            check(good, "Addresses read before and after a failing address keep their own values");
        }
        finally { PowerShellControls.Launcher = original; }
    }
}
