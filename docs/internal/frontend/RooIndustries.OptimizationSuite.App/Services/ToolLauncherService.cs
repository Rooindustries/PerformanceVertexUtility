using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Text.Json;
using System.Threading.Tasks;

namespace RooIndustries.OptimizationSuite.Services;

public sealed record ToolDefinition(string Id, string Name, string Description, string Category, string Website,
    string ArchivePath, string[] InstalledPaths, string BundleAction, string? Icon);
public sealed record ToolTarget(string Action, string? Path, bool FromArchive);

public sealed class ToolLauncherService
{
    private readonly string _root;
    public ToolLauncherService(string root) => _root = root;
    private string Archive => Path.Combine(_root, "vendor", "Utilities.zip");
    private static string Cache => Path.Combine(RooIndustries.Optimizer.BrandCompatibility.LocalDataRoot, "tools");

    public async Task<IReadOnlyList<ToolDefinition>> ReadAsync()
    {
        using var file = File.OpenRead(Path.Combine(_root, "modules", "tool-launchers.json"));
        using var json = await JsonDocument.ParseAsync(file);
        return json.RootElement.GetProperty("tools").Deserialize<ToolDefinition[]>(new JsonSerializerOptions { PropertyNameCaseInsensitive = true })
            ?? throw new InvalidDataException("The tool list is empty.");
    }

    public ToolTarget Resolve(ToolDefinition tool)
    {
        foreach (var parent in new[] { Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86) })
            foreach (var relative in tool.InstalledPaths)
            {
                var installed = Inside(parent, relative);
                if (File.Exists(installed)) return new("Open", installed, false);
            }
        var utilities = RooIndustries.Optimizer.BrandCompatibility.EnvironmentValue("ROO_INDUSTRIES_UTILITIES_ROOT");
        if (string.IsNullOrWhiteSpace(utilities)) utilities = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory), "Utilities");
        var bundled = Inside(utilities, tool.ArchivePath["Utilities/".Length..]);
        if (File.Exists(bundled)) return new(tool.BundleAction == "install" ? "Install" : "Open", bundled, false);
        var extracted = Inside(Path.Combine(Cache, tool.Id), tool.ArchivePath);
        if (File.Exists(extracted) && File.Exists(Path.Combine(Cache, tool.Id, ".complete"))) return new(tool.BundleAction == "install" ? "Install" : "Open", extracted, false);
        if (File.Exists(Archive))
        {
            using var zip = ZipFile.OpenRead(Archive);
            if (zip.GetEntry(tool.ArchivePath) is not null) return new(tool.BundleAction == "install" ? "Install" : "Open", null, true);
        }
        return new("Get", null, false);
    }

    public async Task<string> OpenAsync(ToolDefinition tool)
    {
        var target = Resolve(tool);
        if (target.Action == "Get")
        {
            if (!Uri.TryCreate(tool.Website, UriKind.Absolute, out var uri) || uri.Scheme != "https")
                throw new InvalidDataException("The official download address is invalid.");
            using var browser = Process.Start(new ProcessStartInfo(uri.AbsoluteUri) { UseShellExecute = true });
            return "Opened the " + tool.Name + " download page.";
        }
        var path = target.FromArchive ? await Task.Run(() => Extract(tool)) : target.Path!;
        using var process = Process.Start(new ProcessStartInfo(path) { UseShellExecute = true, WorkingDirectory = Path.GetDirectoryName(path)! });
        return target.Action == "Install" ? "Opened the " + tool.Name + " installer. Complete its setup, then refresh this list."
            : "Opened " + tool.Name + ".";
    }

    private string Extract(ToolDefinition tool)
    {
        var directory = Path.Combine(Cache, tool.Id);
        var target = Inside(directory, tool.ArchivePath);
        using var zip = ZipFile.OpenRead(Archive);
        if (zip.GetEntry(tool.ArchivePath) is null) throw new FileNotFoundException("This tool is missing from Utilities.zip.");
        var prefix = tool.ArchivePath[..(tool.ArchivePath.LastIndexOf('/') + 1)];
        var folder = (tool.BundleAction == "open" && prefix is not "Utilities/" and not "Utilities/Stock Only (otherwise not necessary)/")
            || tool.Id is "intel-network" or "directx-runtime";
        var staging = directory + "." + Guid.NewGuid().ToString("N") + ".tmp";
        Directory.CreateDirectory(staging);
        try
        {
            foreach (var entry in zip.Entries.Where(e => e.FullName == tool.ArchivePath || (folder && e.FullName.StartsWith(prefix, StringComparison.Ordinal))))
            {
                if (string.IsNullOrEmpty(entry.Name)) continue;
                var destination = Inside(staging, entry.FullName);
                Directory.CreateDirectory(Path.GetDirectoryName(destination)!);
                entry.ExtractToFile(destination);
            }
            File.WriteAllText(Path.Combine(staging, ".complete"), tool.ArchivePath);
            try { Directory.Move(staging, directory); }
            catch (IOException) when (File.Exists(target) && File.Exists(Path.Combine(directory, ".complete"))) { }
        }
        finally { if (Directory.Exists(staging)) Directory.Delete(staging, recursive: true); }
        return target;
    }

    private static string Inside(string parent, string relative)
    {
        var root = Path.GetFullPath(parent).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
        var path = Path.GetFullPath(Path.Combine(root, relative.Replace('/', Path.DirectorySeparatorChar)));
        if (!path.StartsWith(root, StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("A tool path leaves its package folder.");
        return path;
    }
}
