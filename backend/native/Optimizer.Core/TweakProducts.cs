#nullable enable
using System.Diagnostics;
using System.Runtime.InteropServices;
using Microsoft.Win32;

namespace RooIndustries.Optimizer;

public static class TweakProducts
{
    public static void Check(string requirement)
    {
        if (requirement == "local-session") { if (GetSystemMetrics(0x1000) != 0) throw new InvalidDataException("This setting requires a local Windows session."); return; }
        if (requirement == "office16")
        {
            using var machine = RegistryKey.OpenBaseKey(RegistryHive.LocalMachine, RegistryView.Registry64);
            using var key = machine.OpenSubKey(@"SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\Winword.exe");
            if (key?.GetValue("Path") is not string path || !path.Contains("Office16", StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("This source setting requires the Office16 Word installation path.");
            return;
        }
        int? major = null;
        if (requirement.StartsWith("edge-profile:", StringComparison.Ordinal))
        {
            using var user = RegistryKey.OpenBaseKey(RegistryHive.CurrentUser, RegistryView.Registry64);
            using var key = user.OpenSubKey(@"SOFTWARE\Microsoft\Edge\BLBeacon"); major = Major(key?.GetValue("version") as string);
        }
        else if (requirement == "legacy-edge" || requirement.StartsWith("edge:", StringComparison.Ordinal))
        {
            foreach (var folder in new[] { Environment.SpecialFolder.ProgramFilesX86, Environment.SpecialFolder.ProgramFiles, Environment.SpecialFolder.LocalApplicationData })
            {
                var path = Path.Combine(folder == Environment.SpecialFolder.LocalApplicationData ? RuntimeEnvironment.LocalAppData : Environment.GetFolderPath(folder), @"Microsoft\Edge\Application\msedge.exe");
                if (File.Exists(path)) { major = Major(FileVersionInfo.GetVersionInfo(path).ProductVersion); break; }
            }
        }
        else throw new InvalidDataException("Unknown installed-product requirement: " + requirement);
        CheckEdge(requirement, major);
    }
    public static void CheckEdge(string requirement, int? major)
    {
        if (requirement == "legacy-edge") { if (major is >= 77) throw new InvalidDataException("This legacy Edge setting is not available with Chromium Edge installed."); return; }
        var parts = requirement.Split(':');
        if (parts.Length != 3 || parts[0] is not ("edge" or "edge-profile") || !int.TryParse(parts[1], out var minimum) || !int.TryParse(parts[2], out var maximum) || minimum < 1 || maximum < minimum) throw new InvalidDataException("Invalid Edge version requirement.");
        if (major is null || major < minimum || major > maximum) throw new InvalidDataException("This setting requires installed Microsoft Edge version " + minimum + " through " + maximum + ".");
    }
    private static int? Major(string? version) => int.TryParse(version?.Split('.')[0], out var major) && major > 0 ? major : null;
    [DllImport("user32.dll")] private static extern int GetSystemMetrics(int index);
}
