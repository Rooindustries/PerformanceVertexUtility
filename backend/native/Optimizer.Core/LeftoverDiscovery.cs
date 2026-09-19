#nullable enable
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using Microsoft.Win32;
using Microsoft.Win32.SafeHandles;

namespace RooIndustries.Optimizer;

public sealed record CleanupApplication
{
    public required string AppId { get; init; }
    public required string DisplayName { get; init; }
    public required string? Publisher { get; init; }
    public required string? InstallLocation { get; init; }
    public required string? PackageFamilyName { get; init; }
}

public sealed class LeftoverCandidate
{
    public required string ItemId { get; init; }
    public required string Kind { get; init; }
    public required string Target { get; init; }
    public RegistryAddress? Registry { get; init; }
    public required bool? Exists { get; set; }
    public required List<string> Evidence { get; init; }
    public required List<string> SharedOwners { get; init; }
    public required bool Protected { get; set; }
    public required bool UserData { get; init; }
    public bool OwnershipComplete { get; set; } = true;
    public string? Error { get; set; }
}

public sealed record LeftoverDiscoveryResult(string AppId, bool Complete, LeftoverCandidate[] Candidates, string[] Errors, int RegistryKeysVisited);

public sealed class LeftoverDiscovery
{
    private const int RegistryKeyLimit = 1000000;
    private const string RegistryLimitMessage = "Registry scan reached its key limit. Completed subtrees remain available for review.";
    private readonly CleanupApplication _app;
    private readonly CleanupApplication[] _peers;
    private readonly HashSet<string> _names;
    private readonly (CleanupApplication App, HashSet<string> Names)[] _peerNames;
    private readonly (string Name, string Path)[] _peerPaths;
    private readonly string? _installPath;
    private readonly Dictionary<string, LeftoverCandidate> _found = new(StringComparer.OrdinalIgnoreCase);
    private readonly List<string> _errors = [];
    private readonly Dictionary<string, HashSet<string>> _registryOwners = new(StringComparer.OrdinalIgnoreCase);
    private readonly Dictionary<string, string> _nativeNames = new(StringComparer.OrdinalIgnoreCase);
    private readonly List<RegistryAddress> _incomplete = [];
    private int _visited;

    public LeftoverDiscovery(CleanupApplication application, IEnumerable<CleanupApplication> otherApplications)
    {
        if (string.IsNullOrWhiteSpace(application.AppId) || string.IsNullOrWhiteSpace(application.DisplayName)) throw new InvalidDataException("A named app identity is required for leftover discovery.");
        _app = application;
        _peers = otherApplications.Where(app => app.AppId != application.AppId).ToArray();
        _names = NameKeys(application.DisplayName);
        _peerNames = _peers.Select(peer => (peer, NameKeys(peer.DisplayName))).ToArray();
        _peerPaths = _peers.Where(peer => !string.IsNullOrWhiteSpace(peer.InstallLocation)).Select(peer => (peer.DisplayName, ExpandPath(peer.InstallLocation!))).ToArray();
        _installPath = string.IsNullOrWhiteSpace(application.InstallLocation) ? null : ExpandPath(application.InstallLocation);
    }

    public LeftoverDiscoveryResult Scan(CancellationToken cancellationToken, IEnumerable<string>? fileRoots = null,
        IEnumerable<RegistryAddress>? registryRoots = null)
    {
        _found.Clear(); _errors.Clear(); _registryOwners.Clear(); _nativeNames.Clear(); _incomplete.Clear(); _visited = 0;
        if (!string.IsNullOrWhiteSpace(_app.InstallLocation)) AddFile(_app.InstallLocation, "Published installation location", false);
        var roots = fileRoots?.ToArray() ?? new[]
        {
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "AppData", "LocalLow"),
            Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),
            Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles),
            Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86),
        };
        foreach (var root in roots.Where(path => !string.IsNullOrWhiteSpace(path)).Distinct(StringComparer.OrdinalIgnoreCase))
        {
            cancellationToken.ThrowIfCancellationRequested();
            SearchFolders(root, 0, cancellationToken);
        }
        if (!string.IsNullOrWhiteSpace(_app.PackageFamilyName))
            AddFile(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Packages", _app.PackageFamilyName), "Exact package-family data directory", true);
        var scopes = registryRoots?.ToArray() ?? new[]
        {
            new RegistryAddress("CurrentUser", "Registry64", "Software", "key", null),
            new RegistryAddress("CurrentUser", "Registry32", "Software\\Classes", "key", null),
            new RegistryAddress("LocalMachine", "Registry64", "Software", "key", null),
            new RegistryAddress("LocalMachine", "Registry32", "Software", "key", null),
        };
        foreach (var scope in scopes)
        {
            cancellationToken.ThrowIfCancellationRequested();
            SearchRegistry(scope, cancellationToken);
        }
        foreach (var parent in _found.Values.Where(item => item.Registry?.Kind == "key"))
        {
            foreach (var child in _registryOwners.Where(pair => Within(pair.Key, _nativeNames[parent.ItemId])))
                foreach (var owner in child.Value) if (!parent.SharedOwners.Contains(owner)) parent.SharedOwners.Add(owner);
            parent.OwnershipComplete = !_incomplete.Any(address => address.Hive == parent.Registry!.Hive &&
                (address.View == parent.Registry.View || address.Hive == "CurrentUser") &&
                (Within(address.KeyPath, parent.Registry.KeyPath) || Within(parent.Registry.KeyPath, address.KeyPath)));
        }
        return new(_app.AppId, _errors.Count == 0, _found.Values.OrderBy(item => item.Kind).ThenBy(item => item.Target, StringComparer.OrdinalIgnoreCase).ToArray(), _errors.ToArray(), _visited);
    }

    private void SearchFolders(string root, int depth, CancellationToken cancellationToken)
    {
        try
        {
            _ = File.GetAttributes(root);
            foreach (var directory in Directory.EnumerateDirectories(root))
            {
                cancellationToken.ThrowIfCancellationRequested();
                var name = Path.GetFileName(directory);
                var match = _names.Contains(Compact(name));
                if (match) AddFile(directory, "Directory name matches the selected product", true);
                var publisher = !string.IsNullOrWhiteSpace(_app.Publisher) && NameKeys(_app.Publisher).Contains(Compact(name));
                if (depth == 0 && (publisher || name.Equals("Programs", StringComparison.OrdinalIgnoreCase)))
                {
                    if ((File.GetAttributes(directory) & FileAttributes.ReparsePoint) == 0) SearchFolders(directory, 1, cancellationToken);
                }
            }
        }
        catch (OperationCanceledException) { throw; }
        catch (DirectoryNotFoundException) { }
        catch (FileNotFoundException) { }
        catch (Exception error) { _errors.Add(root + ": " + error.Message); }
    }

    private void AddFile(string path, string evidence, bool userData)
    {
        try
        {
            path = FileLease.NormalizePath(path);
            var attributes = File.GetAttributes(path);
            var id = Id("path", path);
            if (_found.TryGetValue(id, out var present)) { if (!present.Evidence.Contains(evidence)) present.Evidence.Add(evidence); return; }
            var owners = _peers.Where(peer => NameKeys(peer.DisplayName).Overlaps(_names) ||
                !string.IsNullOrWhiteSpace(peer.InstallLocation) && (Within(peer.InstallLocation, path) || Within(path, peer.InstallLocation)) ||
                !string.IsNullOrWhiteSpace(_app.PackageFamilyName) && peer.PackageFamilyName == _app.PackageFamilyName).Select(peer => peer.DisplayName).Distinct().ToList();
            var protectedPath = FileCleanupEngine.IsProtectedPath(path) || (attributes & FileAttributes.ReparsePoint) != 0;
            _found.Add(id, new()
            {
                ItemId = id, Kind = (attributes & FileAttributes.Directory) != 0 ? "folder" : "file", Target = path, Exists = true,
                Evidence = [evidence], SharedOwners = owners, Protected = protectedPath, UserData = userData,
            });
        }
        catch (DirectoryNotFoundException) { }
        catch (FileNotFoundException) { }
        catch (Exception error) { _errors.Add(path + ": " + error.Message); }
    }

    private void SearchRegistry(RegistryAddress scope, CancellationToken cancellationToken)
    {
        try
        {
            using var handle = RegistryNative.OpenRead(scope);
            if (handle is not null) VisitRegistry(scope, handle, 0, cancellationToken);
        }
        catch (OperationCanceledException) { throw; }
        catch (Exception error) { _errors.Add(scope.Hive + "\\" + scope.KeyPath + ": " + error.Message); _incomplete.Add(scope); }
    }

    private void VisitRegistry(RegistryAddress address, SafeRegistryHandle handle, int depth, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (_visited >= RegistryKeyLimit)
        {
            if (!_errors.Contains(RegistryLimitMessage)) _errors.Add(RegistryLimitMessage);
            _incomplete.Add(address);
            return;
        }
        _visited++;
        try
        {
            using var key = RegistryKey.FromHandle(handle, address.View == "Registry32" ? RegistryView.Registry32 : RegistryView.Registry64);
            var leaf = Compact(address.KeyPath.Split('\\')[^1]);
            var productNameMatch = _names.Contains(leaf);
            var nativeName = RegistryNative.NativeName(handle);
            var referencedOwners = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (var peer in _peerNames.Where(peer => peer.Names.Contains(leaf))) referencedOwners.Add(peer.App.DisplayName);
            if (productNameMatch) AddRegistry(address, nativeName, "Key name matches the selected product; review its subtree ownership", _peerNames.Where(peer => peer.Names.Overlaps(_names)).Select(peer => peer.App.DisplayName).ToList());
            foreach (var valueName in key.GetValueNames())
            {
                var data = key.GetValue(valueName, null, RegistryValueOptions.DoNotExpandEnvironmentNames);
                var strings = (data switch { string text => new[] { text }, string[] list => list, _ => [] }).Select(Environment.ExpandEnvironmentVariables).ToArray();
                if (strings.Length == 0) continue;
                var owners = _peerPaths.Where(peer => strings.Any(text => ReferencesPath(text, peer.Path))).Select(peer => peer.Name).Distinct().ToList();
                foreach (var owner in owners) referencedOwners.Add(owner);
                if (_installPath is null || !strings.Any(text => ReferencesPath(text, _installPath))) continue;
                AddRegistry(address with { Kind = "value", ValueName = valueName }, nativeName, "Value references the selected installation path", owners);
            }
            if (referencedOwners.Count != 0)
            {
                if (_registryOwners.TryGetValue(nativeName, out var existingOwners)) existingOwners.UnionWith(referencedOwners);
                else _registryOwners.Add(nativeName, referencedOwners);
            }
            var children = key.GetSubKeyNames();
            if (depth >= 64 && children.Length != 0)
            {
                _errors.Add(address.Hive + "\\" + address.KeyPath + ": scan depth limit reached.");
                _incomplete.Add(address);
                return;
            }
            foreach (var name in children)
            {
                cancellationToken.ThrowIfCancellationRequested();
                var childAddress = address with { KeyPath = address.KeyPath + "\\" + name };
                if (_visited >= RegistryKeyLimit)
                {
                    if (!_errors.Contains(RegistryLimitMessage)) _errors.Add(RegistryLimitMessage);
                    _incomplete.Add(childAddress);
                    continue;
                }
                try
                {
                    using var child = RegistryNative.OpenReadChild(handle, name, address.View);
                    if (child is not null) VisitRegistry(childAddress, child, depth + 1, cancellationToken);
                }
                catch (OperationCanceledException) { throw; }
                catch (Exception error) { _errors.Add(address.Hive + "\\" + childAddress.KeyPath + ": " + error.Message); _incomplete.Add(childAddress); }
            }
        }
        catch (OperationCanceledException) { throw; }
        catch (Exception error) { _errors.Add(address.Hive + "\\" + address.KeyPath + ": " + error.Message); _incomplete.Add(address); }
    }

    private void AddRegistry(RegistryAddress address, string nativeName, string evidence, List<string> owners)
    {
        var identity = nativeName + "|" + address.Kind + "|" + address.ValueName;
        var id = Id("registry", identity);
        _nativeNames[id] = nativeName;
        if (_found.TryGetValue(id, out var current))
        {
            if (!current.Evidence.Contains(evidence)) current.Evidence.Add(evidence);
            foreach (var owner in owners) if (!current.SharedOwners.Contains(owner)) current.SharedOwners.Add(owner);
            return;
        }
        var protectedKey = false;
        try { address.RequireDeletionScope(); } catch (InvalidDataException) { protectedKey = true; }
        _found.Add(id, new()
        {
            ItemId = id, Kind = address.Kind == "key" ? "registryKey" : "registryValue", Registry = address,
            Target = address.Hive + "\\" + address.KeyPath + (address.Kind == "value" ? " :: " + (address.ValueName == "" ? "(Default)" : address.ValueName) : ""),
            Exists = true, Evidence = [evidence], SharedOwners = owners, Protected = protectedKey, UserData = true,
        });
    }

    private static bool ReferencesPath(string text, string path)
    {
        if (path.Length < 4) return false;
        if (!text.Contains(path, StringComparison.OrdinalIgnoreCase)) return false;
        return Regex.IsMatch(text, "(?:^|[@\\\"'=\\s])" + Regex.Escape(path) + "(?:[\\\\/\\\"'\\s]|$)", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant, TimeSpan.FromMilliseconds(50));
    }

    private static string ExpandPath(string path) => Environment.ExpandEnvironmentVariables(path).TrimEnd('\\', '/');

    private string Id(string kind, string path) => kind + ":" + Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(_app.AppId + "|" + path.ToUpperInvariant())));
    private static bool Within(string path, string root) => !string.IsNullOrWhiteSpace(root) && (string.Equals(path.TrimEnd('\\'), root.TrimEnd('\\'), StringComparison.OrdinalIgnoreCase) || path.StartsWith(root.TrimEnd('\\') + "\\", StringComparison.OrdinalIgnoreCase));
    private static string Compact(string text) => new(text.Where(char.IsLetterOrDigit).Select(char.ToLowerInvariant).ToArray());
    private static HashSet<string> NameKeys(string name)
    {
        var clean = Regex.Replace(name, @"\s*[\(\[]?(?:x64|x86|64-bit|32-bit)[\)\]]?", "", RegexOptions.IgnoreCase);
        clean = Regex.Replace(clean, @"\s+\d+(?:\.\d+)+(?:\s.*)?$", "");
        string[] generic = ["windows", "microsoft", "software", "application", "runtime", "update", "programs", "system", "settings", "classes"];
        return new[] { Compact(name), Compact(clean) }.Where(value => value.Length >= 3 && !generic.Contains(value)).ToHashSet(StringComparer.OrdinalIgnoreCase);
    }
}
