using System;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;

// Disposable CLI fixture. It only reads and writes files in its own directory.
class FirmwareHelperFixture
{
    static int Main(string[] args)
    {
        var root = AppDomain.CurrentDomain.BaseDirectory;
        var authority = Path.Combine(root, "fixture-authority.txt");
        if (!File.Exists(authority) || File.ReadAllText(authority) != "roo-industries-firmware-cli-fixture/v1") return 200;
        if (args.Length == 1 && args[0] == "--hold") { System.Threading.Thread.Sleep(10000); return 0; }
        File.AppendAllText(Path.Combine(root, "calls.log"), string.Join("|", args) + "\n");
        if (args.Length != 4 || args[1] != "/s" || (args[0] == "/o" ? args[3] != "/v" : args[0] != "/i" || args[3] != "/r")) return 201;
        Console.Error.WriteLine("AMISCE file fixture status: reading or updating a disposable file.");
        var state = Path.Combine(root, "fixture-state.txt");
        var parts = (File.Exists(state) ? File.ReadAllText(state) : "00|5").Split('|');
        var value = parts[0];
        var delay = parts[1];
        if (args[0] == "/o")
        {
            File.WriteAllText(args[2], "HIICrc32 = A1B2C3D4\r\r\n\r\nSetup Question = Fixture option\r\nHelp String = File fixture only\r\nToken =10\r\nOffset =20\r\nWidth =01\r\nOptions =" + (value == "00" ? "*" : "") + "[00]Off\r\n         " + (value == "01" ? "*" : "") + "[01]On\r\n\r\nSetup Question = Fixture delay\r\nHelp String = File-only numeric setting\r\nToken =11\r\nOffset =21\r\nWidth =01\r\nValue =<" + delay + ">\r\n", Encoding.ASCII);
            return 0;
        }
        var script = File.ReadAllText(args[2]);
        if (!script.Contains("HIICrc32 = A1B2C3D4")) return 23;
        var selected = Regex.Match(script, @"\*\[(00|01)\]");
        var numeric = Regex.Match(script, @"Value =<(\d+)>");
        if (!selected.Success && !numeric.Success) return 13;
        File.WriteAllText(state, (selected.Success ? selected.Groups[1].Value : value) + "|" + (numeric.Success ? numeric.Groups[1].Value : delay));
        Console.WriteLine("File fixture updated; no firmware was accessed.");
        return 0;
    }
}
