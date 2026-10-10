using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Reflection;
using System.Security.AccessControl;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using RooIndustries.Optimizer;

namespace RooIndustries.OptimizationSuite.Services;

public sealed record UpdateState(string Status, string Notes = "", bool Busy = false, bool Ready = false, bool CanDownload = false,
    string Banner = "", string BannerKind = "", bool Installing = false);
public sealed record PendingUpdate([property: JsonRequired] string FromVersion, [property: JsonRequired] string ToVersion,
    [property: JsonRequired] DateTime StartedAtUtc, [property: JsonRequired] string LogPath);

public sealed class UpdateService
{
    private const string Blocked = "Stop your game session and turn off the timer setting first. The update can't install while they run.";
    private const string Mismatch = "The download didn't match the signed release, so it was deleted. The app will try again later.";
    private readonly Uri? _feed;
    private readonly HttpClient _http = new(new HttpClientHandler { AllowAutoRedirect = false, UseCookies = false }) { Timeout = Timeout.InfiniteTimeSpan };
    private readonly SettingsStore _settings = new();
    private readonly SemaphoreSlim _gate = new(1, 1);
    private readonly CancellationTokenSource _stop = new();
    private DispatcherQueue? _dispatcher;
    private PolicyRootLease? _storageLease;
    private string? _root;
    private UpdateRelease? _release;
    private byte[]? _envelope;
    private FileStream? _installerHandle;
    private bool _started;
    private bool _later;
    private bool _handoff;
    public event Action? Changed;
    public UpdateState State { get; private set; }
    public bool Enabled => _feed is not null;
    public static string CurrentVersion => typeof(App).Assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion ?? "";

    public UpdateService()
    {
        using var stream = typeof(App).Assembly.GetManifestResourceStream("RooIndustries.UpdateFeed");
        using var reader = stream is null ? null : new StreamReader(stream);
        var line = reader?.ReadToEnd().TrimStart('\uFEFF').Trim();
        var url = line is not null && line.StartsWith("url=", StringComparison.Ordinal) ? line[4..].Trim() : "";
        if (Uri.TryCreate(url, UriKind.Absolute, out var feed) && feed.Scheme == Uri.UriSchemeHttps) _feed = feed;
        State = new(url.Length == 0 ? "This build doesn't check for updates." : _feed is null ? "Couldn't check for updates. This build's feed URL is invalid." : "Updates are checked automatically.");
    }

    public bool AutomaticDownloads
    {
        get => _settings.Get("downloadUpdatesAutomatically") != "0";
        set
        {
            if (_settings.Set("downloadUpdatesAutomatically", value ? "1" : "0") is { } error)
            {
                Status("Couldn't save this setting: " + error);
                return;
            }
            Notify();
            if (value && State.CanDownload) _ = DownloadAsync();
        }
    }

    public bool ShowBanner => !_later && State.Banner.Length > 0;
    public void Later() { _later = true; Notify(); }
    public void Stop() => _stop.Cancel();

    private void Notify() => _dispatcher?.TryEnqueue(() => Changed?.Invoke());
    private void Set(UpdateState state) { State = state; Notify(); }
    private void Status(string text) { Set(State with { Status = text }); AppLog.Write("update", text); }

    public void Start(DispatcherQueue dispatcher)
    {
        if (_started) return;
        _started = true;
        _dispatcher = dispatcher;
        _ = ScheduleAsync();
    }

    private async Task ScheduleAsync()
    {
        try
        {
            await _gate.WaitAsync(_stop.Token);
            try { await RecoverAsync(); }
            finally { _gate.Release(); }
            if (!Enabled) return;
            await Task.Delay(TimeSpan.FromSeconds(20), _stop.Token);
            while (!_stop.IsCancellationRequested)
            {
                await CheckAsync();
                await Task.Delay(TimeSpan.FromHours(6), _stop.Token);
            }
        }
        catch (OperationCanceledException) { }
        catch (Exception error) { Status("Couldn't check for updates. " + error.Message); }
    }

    private string Storage()
    {
        if (!PolicyRootSecurity.Elevated()) throw new UnauthorizedAccessException("Open the app as an administrator to download and install updates.");
        var data = DataFolder.Require();
        if (!DataFolder.Secured(data)) throw new UnauthorizedAccessException("The app's update data folder is not protected.");
        _root ??= Path.Combine(data, "updates");
        if (!Directory.Exists(_root))
        {
            var security = new DirectoryInfo(data).GetAccessControl();
            security.SetAccessRuleProtection(true, true);
            new DirectoryInfo(_root).Create(security);
        }
        _storageLease ??= PolicyRootLease.Acquire(_root, DataFolder.Kind, deep: true);
        PolicyRootSecurity.RequireSecured(_root, DataFolder.Kind, deep: true);
        if (_storageLease.Moved) throw new UnauthorizedAccessException("The update folder moved while it was being used.");
        return _root;
    }

    private string Folder(UpdateRelease release) => Path.Combine(Storage(), release.Version);
    private string Installer(UpdateRelease release) => Path.Combine(Folder(release), "RooIndustries-OptimizationSuite-" + release.Version + "-setup.exe");
    private string InstallLog(string version) => Path.Combine(Storage(), "install-" + version + ".log");

    private void KeepVersion(string version)
    {
        var root = Storage();
        foreach (var folder in Directory.EnumerateDirectories(root))
            if (Path.GetFileName(folder) != version && SemanticVersion.TryParse(Path.GetFileName(folder), out _)) Directory.Delete(folder, true);
    }

    private async Task RecoverAsync()
    {
        try
        {
            if (!PolicyRootSecurity.Elevated()) return;
            var root = Storage();
            var pendingPath = Path.Combine(root, "pending-install.json");
            PendingUpdate? pending = null;
            if (File.Exists(pendingPath))
            {
                pending = OperationFiles.Read<PendingUpdate>(pendingPath);
                if (!SemanticVersion.TryParse(pending.FromVersion, out _) || !SemanticVersion.TryParse(pending.ToVersion, out _) ||
                    !string.Equals(pending.LogPath, InstallLog(pending.ToVersion), StringComparison.OrdinalIgnoreCase))
                    throw new InvalidDataException("The pending update record is inconsistent. Check the update folder before trying again.");
                var success = CurrentVersion == pending.ToVersion;
                var message = success ? "Updated to version " + CurrentVersion : "The update to " + pending.ToVersion + " didn't finish. Setup log: " + pending.LogPath;
                Set(State with { Status = message, Banner = message, BannerKind = success ? "updated" : "failed" });
                AppLog.Write("update", message);
                File.Delete(pendingPath);
                if (success)
                {
                    try
                    {
                        var installedFolder = Path.Combine(root, CurrentVersion);
                        if (Directory.Exists(installedFolder)) Directory.Delete(installedFolder, true);
                        foreach (var log in Directory.EnumerateFiles(root, "install-*.log").Select(path => new FileInfo(path))
                            .OrderByDescending(file => file.LastWriteTimeUtc).ThenByDescending(file => file.Name, StringComparer.Ordinal).Skip(3))
                            log.Delete();
                    }
                    catch (Exception error) { AppLog.Write("update", "Couldn't clean up the installed update: " + error.Message); }
                }
            }
            if (_feed is null) return;
            var candidates = Directory.EnumerateDirectories(root).Select(folder => new { Folder = folder, Name = Path.GetFileName(folder) })
                .Where(item => SemanticVersion.TryParse(item.Name, out _)).OrderByDescending(item => { SemanticVersion.TryParse(item.Name, out var value); return value; });
            foreach (var candidate in candidates)
            {
                var path = Path.Combine(candidate.Folder, "manifest.json");
                if (!File.Exists(path) || new FileInfo(path).Length > UpdateFeed.MaximumBodyBytes) continue;
                var bytes = await File.ReadAllBytesAsync(path, _stop.Token);
                var result = UpdateFeed.Verify(bytes, 200, _feed, CurrentVersion);
                if (result.Kind != UpdateFeedKind.Available || result.Release is not { } release || release.Version != candidate.Name) continue;
                var installer = Installer(release);
                if (!File.Exists(installer)) continue;
                UpdateFileResult verified;
                using (var input = new FileStream(installer, FileMode.Open, FileAccess.Read, FileShare.Read, 128 * 1024, FileOptions.Asynchronous))
                    verified = await Task.Run(() => UpdateFeed.VerifyInstallerAsync(input, release, _stop.Token));
                if (!verified.Verified)
                {
                    if (verified.Failure == UpdateFileFailure.Canceled) _stop.Token.ThrowIfCancellationRequested();
                    if (verified.Failure == UpdateFileFailure.Mismatch) File.Delete(installer);
                    AppLog.Write("update", verified.Reason);
                    continue;
                }
                _release = release; _envelope = bytes;
                var failed = pending is not null && CurrentVersion != pending.ToVersion && pending.ToVersion == release.Version;
                Set(State with { Ready = true, Notes = release.Notes, Status = failed ? State.Status : "Version " + release.Version + " is ready to install",
                    Banner = failed ? State.Banner : "Version " + release.Version + " is ready to install", BannerKind = failed ? "failed" : "ready" });
                KeepVersion(release.Version);
                break;
            }
        }
        catch (OperationCanceledException) { }
        catch (Exception error) { Status("Couldn't recover the update. " + error.Message); }
    }

    public async Task CheckAsync()
    {
        if (_feed is null || !await _gate.WaitAsync(0)) return;
        try
        {
            Set(State with { Busy = true, Status = "Checking for updates..." });
            using var deadline = CancellationTokenSource.CreateLinkedTokenSource(_stop.Token);
            deadline.CancelAfter(TimeSpan.FromSeconds(20));
            var builder = new UriBuilder(_feed);
            builder.Query = (builder.Query.Length > 1 ? builder.Query[1..] + "&" : "") + "t=" + DateTimeOffset.UtcNow.ToUnixTimeSeconds();
            using var response = await GetAsync(builder.Uri, deadline.Token);
            if (response.StatusCode != HttpStatusCode.OK)
            {
                Status("Couldn't check for updates. The update server returned HTTP " + (int)response.StatusCode + " instead of 200.");
                return;
            }
            if (response.Content.Headers.ContentLength > UpdateFeed.MaximumBodyBytes) throw new InvalidDataException("The update feed is larger than 64 KiB.");
            using var input = await response.Content.ReadAsStreamAsync(deadline.Token);
            using var output = new MemoryStream();
            var buffer = new byte[8192];
            while (output.Length <= UpdateFeed.MaximumBodyBytes)
            {
                var read = await input.ReadAsync(buffer.AsMemory(0, (int)Math.Min(buffer.Length, UpdateFeed.MaximumBodyBytes + 1 - output.Length)), deadline.Token);
                if (read == 0) break;
                await output.WriteAsync(buffer.AsMemory(0, read), deadline.Token);
            }
            var bytes = output.ToArray();
            var result = UpdateFeed.Verify(bytes, (int)response.StatusCode, _feed, CurrentVersion);
            if (result.Kind == UpdateFeedKind.Refused) { Status("Couldn't verify the update. " + result.Reason); return; }
            if (result.Kind == UpdateFeedKind.Current)
            {
                _release = null; _envelope = null;
                Set(State with { Ready = false, CanDownload = false, Notes = "", Status = result.Reason, Banner = State.BannerKind == "ready" ? "" : State.Banner });
                AppLog.Write("update", result.Reason);
                return;
            }
            var release = result.Release!;
            var same = _release == release && State.Ready;
            _release = release; _envelope = bytes;
            Set(State with { Ready = same, CanDownload = !same, Notes = release.Notes, Status = same ? State.BannerKind == "failed" ? State.Banner : "Version " + release.Version + " is ready to install" : result.Reason,
                Banner = same ? State.Banner : "", BannerKind = same ? State.BannerKind : "" });
            if (AutomaticDownloads && !same) await DownloadCoreAsync();
        }
        catch (OperationCanceledException) { if (!_stop.IsCancellationRequested) Status("Couldn't check for updates. The request timed out."); }
        catch (Exception error) { Status("Couldn't check for updates. " + error.Message); }
        finally { Set(State with { Busy = false }); _gate.Release(); }
    }

    private async Task<HttpResponseMessage> GetAsync(Uri uri, CancellationToken cancellation)
    {
        for (var redirects = 0; redirects <= 10; redirects++)
        {
            if (uri.Scheme != Uri.UriSchemeHttps) throw new InvalidDataException("The update server redirected to an insecure URL.");
            using var request = new HttpRequestMessage(HttpMethod.Get, uri);
            request.Headers.CacheControl = new CacheControlHeaderValue { NoCache = true };
            var response = await _http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, cancellation);
            if ((int)response.StatusCode is not (301 or 302 or 303 or 307 or 308)) return response;
            var location = response.Headers.Location;
            response.Dispose();
            if (location is null) throw new InvalidDataException("The update redirect has no destination.");
            uri = location.IsAbsoluteUri ? location : new Uri(uri, location);
        }
        throw new InvalidDataException("The update server redirected too many times.");
    }

    private void DownloadFailed(string reason)
    {
        var message = "Couldn't download the update: " + reason.TrimEnd('.') + ". The app will try again later.";
        Set(State with { Ready = false, CanDownload = true, Status = message, Banner = "", BannerKind = "" });
        AppLog.Write("update", message);
    }

    public async Task DownloadAsync()
    {
        if (!State.CanDownload || !await _gate.WaitAsync(0)) return;
        try { Set(State with { Busy = true }); await DownloadCoreAsync(); }
        catch (OperationCanceledException) { if (!_stop.IsCancellationRequested) DownloadFailed("The download timed out"); }
        catch (Exception error) { DownloadFailed(error.Message); }
        finally { Set(State with { Busy = false }); _gate.Release(); }
    }

    private async Task DownloadCoreAsync()
    {
        if (_release is not { } release || _envelope is null) return;
        string? partial = null;
        try
        {
            var folder = Folder(release);
            Directory.CreateDirectory(folder);
            KeepVersion(release.Version);
            using (var document = JsonDocument.Parse(_envelope)) OperationFiles.Write(Path.Combine(folder, "manifest.json"), document.RootElement);
            var installer = Installer(release);
            partial = installer + ".partial";
            Status("Downloading version " + release.Version + "...");
            File.Delete(partial);
            using var deadline = CancellationTokenSource.CreateLinkedTokenSource(_stop.Token);
            deadline.CancelAfter(TimeSpan.FromMinutes(20));
            using var response = await GetAsync(release.InstallerUrl, deadline.Token);
            if (response.StatusCode != HttpStatusCode.OK) throw new IOException("The installer server returned HTTP " + (int)response.StatusCode + ".");
            using var input = await response.Content.ReadAsStreamAsync(deadline.Token);
            UpdateFileResult result;
            using (var output = new FileStream(partial, FileMode.CreateNew, FileAccess.Write, FileShare.None, 128 * 1024, FileOptions.Asynchronous))
            {
                result = await Task.Run(() => UpdateFeed.VerifyInstallerAsync(input, release, deadline.Token, output));
                if (result.Verified)
                {
                    await output.FlushAsync(deadline.Token);
                    output.Flush(true);
                }
            }
            if (!result.Verified)
            {
                File.Delete(partial);
                if (result.Failure == UpdateFileFailure.Mismatch)
                {
                    Set(State with { Ready = false, CanDownload = true, Status = Mismatch, Banner = "", BannerKind = "" });
                    AppLog.Write("update", Mismatch + " " + result.Reason);
                }
                else if (result.Failure != UpdateFileFailure.Canceled || !_stop.IsCancellationRequested)
                    DownloadFailed(result.Failure == UpdateFileFailure.Canceled ? "The download timed out" : result.Reason);
                return;
            }
            File.Move(partial, installer, overwrite: true);
            Set(State with { Ready = true, CanDownload = false, Status = "Version " + release.Version + " is ready to install", Banner = "Version " + release.Version + " is ready to install", BannerKind = "ready" });
            AppLog.Write("update", State.Status);
        }
        catch (OperationCanceledException) { if (!_stop.IsCancellationRequested) DownloadFailed("The download timed out"); }
        catch (Exception error) { DownloadFailed(error.Message); }
        finally
        {
            if (partial is not null)
            {
                try { File.Delete(partial); }
                catch (Exception error) { AppLog.Write("update", "Couldn't remove the partial download: " + error.Message); }
            }
        }
    }

    private static async Task<bool> ActiveSettingsAsync()
    {
        var sessions = await App.Operations.ReadGameSessionsAsync();
        if (sessions.Any(entry => entry.Worker.HostRunning == true)) return true;
        if (sessions.Any(entry => entry.Worker.HostRunning is null || entry.Worker.Error is not null))
            throw new InvalidDataException("Couldn't confirm that all game sessions have stopped. Check Games and Undo changes first.");
        var game = await App.Live.GetGameTuneSessionStatusResultAsync();
        if (game.Error is not null || game.Value is null) throw new InvalidDataException("Couldn't read the game priority session. Check Games first.");
        using var data = JsonDocument.Parse(game.Value);
        if (data.RootElement.GetProperty("active").GetBoolean()) return true;
        try
        {
            var timer = await Task.Run(() => TimerControl.Read(new ControlAddress("timer", "system", "half-millisecond")));
            return timer.Value.GetBoolean();
        }
        catch (Exception error)
        {
            AppLog.Write("update", "Couldn't read the timer setting; treating it as stopped: " + error.Message);
            return false;
        }
    }

    public async Task InstallAsync(XamlRoot xamlRoot)
    {
        if (!State.Ready || _release is not { } release || !await _gate.WaitAsync(0)) return;
        try
        {
            Set(State with { Busy = true, Installing = true });
            if (await ActiveSettingsAsync()) { Status(Blocked); return; }
            var installDrive = new DriveInfo(Path.GetPathRoot(AppContext.BaseDirectory)!);
            if (UpdateFeed.InstallDriveSpaceReason(installDrive.Name, installDrive.AvailableFreeSpace) is { } spaceReason) { Status(spaceReason); return; }
            var dialog = new ContentDialog { XamlRoot = xamlRoot, Title = "Install version " + release.Version + " now?",
                Content = "The app closes, installs the update and opens again. It takes about a minute. Your settings, saved rules and undo information are kept.",
                PrimaryButtonText = "Install", CloseButtonText = "Not now", DefaultButton = ContentDialogButton.Close };
            if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
            var installer = Installer(release);
            _installerHandle = new FileStream(installer, FileMode.Open, FileAccess.Read, FileShare.Read, 128 * 1024, FileOptions.Asynchronous);
            var verification = await Task.Run(() => UpdateFeed.VerifyInstallerAsync(_installerHandle, release, _stop.Token));
            if (!verification.Verified) throw new InvalidDataException(verification.Reason);
            if (FileVersionInfo.GetVersionInfo(installer).ProductVersion?.TrimEnd(' ') != release.Version)
                throw new InvalidDataException("The installer's product version does not match the signed release.");
            if (await ActiveSettingsAsync()) { Status(Blocked); return; }
            if (UpdateFeed.InstallDriveSpaceReason(installDrive.Name, installDrive.AvailableFreeSpace) is { } finalSpaceReason) { Status(finalSpaceReason); return; }
            var root = Storage();
            var log = InstallLog(release.Version);
            OperationFiles.Write(Path.Combine(root, "pending-install.json"), new PendingUpdate(CurrentVersion, release.Version, DateTime.UtcNow, log));
            var start = new ProcessStartInfo(installer) { UseShellExecute = false, WorkingDirectory = Folder(release),
                Arguments = "/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /CLOSEAPPLICATIONS /LOG=\"" + log + "\" /ROORELAUNCH=1 /ROOWAITPID=" + Environment.ProcessId };
            RuntimeEnvironment.Apply(start);
            using var setup = Process.Start(start) ?? throw new InvalidOperationException("Windows did not start the update installer.");
            _handoff = true;
            AppLog.Write("update", "Started installer PID " + setup.Id + " for " + release.Version + ". Setup log: " + log);
            Stop();
            App.MainWindow?.Close();
            Application.Current.Exit();
        }
        catch (Exception error)
        {
            Status("Couldn't install the update. " + error.Message);
            if (!_handoff && _root is not null)
            {
                try { File.Delete(Path.Combine(_root, "pending-install.json")); }
                catch (Exception cleanup) when (cleanup is IOException or UnauthorizedAccessException) { AppLog.Write("update", "The pending update record could not be removed: " + cleanup.Message); }
            }
        }
        finally
        {
            if (!_handoff) { _installerHandle?.Dispose(); _installerHandle = null; Set(State with { Busy = false, Installing = false }); }
            _gate.Release();
        }
    }
}
