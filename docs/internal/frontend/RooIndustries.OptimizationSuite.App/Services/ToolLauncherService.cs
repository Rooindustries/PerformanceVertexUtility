using System;
using System.Collections.Generic;
using System.ComponentModel;
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
    public const string MissingFiles = "Some app files are missing. Reinstall the app.";
    private readonly string _root;
    private readonly string? _cacheRoot;
    private readonly Func<string>? _requireProtected;
    public ToolLauncherService(string root, string? cacheRoot = null, Func<string>? requireProtected = null) { _root = root; _cacheRoot = cacheRoot; _requireProtected = requireProtected; }
    private string Archive => Path.Combine(_root, "vendor", "Utilities.zip");
    private string Cache => _cacheRoot ?? Path.Combine(RooIndustries.Optimizer.BrandCompatibility.LocalDataRoot, "tool-cache");
    private string RequireProtected() => _requireProtected is { } fixture ? fixture() : RooIndustries.Optimizer.DataFolder.Require();

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
        var extracted = Inside(Path.Combine(Cache, tool.Id), tool.ArchivePath);
        if (File.Exists(extracted) && File.Exists(Path.Combine(Cache, tool.Id, ".complete"))) return new(tool.BundleAction == "install" ? "Install" : "Open", extracted, false);
        if (File.Exists(Archive))
        {
            using var zip = ZipFile.OpenRead(Archive);
            if (zip.GetEntry(tool.ArchivePath) is not null) return new(tool.BundleAction == "install" ? "Install" : "Open", null, true);
        }
        var utilities = RooIndustries.Optimizer.BrandCompatibility.EnvironmentValue("ROO_INDUSTRIES_UTILITIES_ROOT");
        if (string.IsNullOrWhiteSpace(utilities)) utilities = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory), "Utilities");
        var bundled = Inside(utilities, tool.ArchivePath["Utilities/".Length..]);
        if (File.Exists(bundled)) return new(tool.BundleAction == "install" ? "Install" : "Open", bundled, false);
        return new("Get", null, false);
    }

    public async Task<string> OpenAsync(ToolDefinition tool)
    {
        var target = Resolve(tool);
        if (target.Action == "Get")
        {
            if (!Uri.TryCreate(tool.Website, UriKind.Absolute, out var uri) || uri.Scheme != "https")
                throw new UriFormatException("The official download address is invalid.");
            RooIndustries.Optimizer.RuntimeEnvironment.OpenInExplorer(uri.AbsoluteUri);
            return "Opened the " + tool.Name + " download page.";
        }
        var path = target.FromArchive ? await Task.Run(() => Extract(tool)) : target.Path!;
        using var process = Start(path);
        return target.Action == "Install" ? "Opened the " + tool.Name + " installer. Finish setup, then click Refresh."
            : "Opened " + tool.Name + ".";
    }

    public static string Explain(ToolDefinition tool, Exception error) => error switch
    {
        Win32Exception { NativeErrorCode: 225 or 226 } => "Your antivirus or Windows Security blocked " + tool.Name + ". Allow it there, then try again.",
        Win32Exception { NativeErrorCode: 1260 } => "A Windows policy on this PC blocks " + tool.Name + ". Ask whoever manages this PC to allow it.",
        Win32Exception { NativeErrorCode: 4551 } => "Windows app control blocked " + tool.Name + ". Check Smart App Control in Windows Security, or ask whoever manages this PC.",
        Win32Exception { NativeErrorCode: 5 or 740 } or UnauthorizedAccessException => tool.Name + " needs admin rights. Reopen the app as an administrator, then try again.",
        Win32Exception { NativeErrorCode: 2 or 3 } => tool.Name + "'s files are missing. Your antivirus may have removed them. Allow " + tool.Name + " there, then try again.",
        FileNotFoundException or DirectoryNotFoundException => tool.Name + " is missing from the app's files. Reinstall the app to get it back.",
        Win32Exception { NativeErrorCode: 193 or 216 } or InvalidDataException => "The app's copy of " + tool.Name + " is damaged. Reinstall the app to fix it.",
        UriFormatException => tool.Name + "'s download link is broken. Update the app to fix it.",
        IOException { HResult: unchecked((int)0x80070070) or unchecked((int)0x80070027) } => "Couldn't unpack " + tool.Name + ". Your drive is full. Free up some space, then try again.",
        IOException => "Couldn't unpack " + tool.Name + ". Details are in the app log (Settings, Open logs folder).",
        InvalidOperationException { Message: RooIndustries.Optimizer.RuntimeEnvironment.ExplorerNotRunning } => "Windows Explorer isn't running. Sign in to Windows, then try again.",
        _ => "Couldn't open " + tool.Name + ". Details are in the app log (Settings, Open logs folder)."
    };

    public static string ExplainList(Exception error) => error switch
    {
        FileNotFoundException or DirectoryNotFoundException => MissingFiles,
        IOException or UnauthorizedAccessException => "Couldn't read the tool list. Click Refresh to try again.",
        _ => "The tool list is damaged. Reinstall the app to fix it."
    };

    private Process? Start(string path)
    {
        if (!RooIndustries.Optimizer.PolicyRootSecurity.Elevated() || AdministratorsOnly(path))
        {
            var start = new ProcessStartInfo(path) { UseShellExecute = false, WorkingDirectory = Path.GetDirectoryName(path)! };
            RooIndustries.Optimizer.RuntimeEnvironment.Apply(start);
            return Process.Start(start);
        }
        RooIndustries.Optimizer.RuntimeEnvironment.OpenInExplorer(path);
        return null;
    }

    private bool AdministratorsOnly(string path)
    {
        var full = Path.GetFullPath(path);
        foreach (var parent in new[] { Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86) })
            if (!string.IsNullOrEmpty(parent) && Contained(parent, full)) return true;
        if (!Contained(Cache, full)) return false;
        try { RequireProtected(); return true; }
        catch (Exception error) when (error is UnauthorizedAccessException or IOException) { return false; }
    }

    private static bool Contained(string parent, string full)
    {
        var root = Path.GetFullPath(parent).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
        if (!full.StartsWith(root, StringComparison.OrdinalIgnoreCase)) return false;
        try
        {
            FileSystemInfo item = new FileInfo(full);
            while (!string.Equals(item.FullName + Path.DirectorySeparatorChar, root, StringComparison.OrdinalIgnoreCase))
            {
                if (item.Attributes.HasFlag(FileAttributes.ReparsePoint)) return false;
                item = item is FileInfo file ? file.Directory! : ((DirectoryInfo)item).Parent!;
            }
            return true;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { return false; }
    }

    private string Extract(ToolDefinition tool)
    {
        RequireProtected();
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
