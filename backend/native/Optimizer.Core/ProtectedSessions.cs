#nullable enable
using System.Diagnostics;
using System.Text.Json;

namespace RooIndustries.Optimizer;

public sealed record ProtectedSessionPreview
{
    public required int SchemaVersion { get; init; }
    public required string OperationId { get; init; }
    public required OperationOwner Owner { get; init; }
    public required RunningProcess Launcher { get; init; }
    public required string LauncherHash { get; init; }
    public required string GamePath { get; init; }
    public required string GameHash { get; init; }
    public required long GameLength { get; init; }
    public required DateTime GameModifiedAtUtc { get; init; }
    public required string TopologyHash { get; init; }
    public required AffinityState OriginalAffinity { get; init; }
    public required Dictionary<string, JsonElement> Controls { get; init; }
    public required LaunchPrioritySnapshot OriginalLaunchSettings { get; init; }
    public required ProcessControlPreview? LauncherChanges { get; init; }
    public required bool AcceptLauncherScope { get; init; }
}
public sealed class ProtectedFieldState
{
    public required string Name { get; init; }
    public required string Route { get; init; }
    public required string Status { get; set; }
    public ControlRead? Observed { get; set; }
    public string? JournalPath { get; set; }
    public string? Error { get; set; }
    public int Reapplications { get; set; }
}
public sealed class ProtectedGameState
{
    public required RunningProcess Identity { get; init; }
    public required List<ProtectedFieldState> Fields { get; init; }
    public bool Exited { get; set; }
}
public sealed class ProtectedSessionState
{
    public required int SchemaVersion { get; init; }
    public required ProtectedSessionPreview Preview { get; init; }
    public required string PreviewPath { get; init; }
    public required string ReviewHash { get; init; }
    public required RunningProcess Host { get; init; }
    public required string Status { get; set; }
    public required string RegistryStatus { get; set; }
    public required string JobStatus { get; set; }
    public required AffinityState DesiredAffinity { get; set; }
    public required string? LauncherJournal { get; set; }
    public required List<ProtectedGameState> Games { get; init; }
    public required List<string> Errors { get; set; }
    public required DateTime UpdatedAtUtc { get; set; }
}
public sealed record ProtectedSessionStatus(ProtectedSessionState? State, bool? HostRunning, string? Error);
public sealed record ProtectedSessionCommand(OperationOwner Owner, string OperationId, RunningProcess Host, string Action, AffinityState? Affinity);
public sealed record ProtectedWatchReady(OperationOwner Owner, string OperationId, RunningProcess Host, RunningProcess Watcher, bool HoldingJob);

public sealed class ProtectedSessions
{
    private readonly Func<RunningProcess, bool> _excluded;
    private readonly ProcessControlEngine _controls;
    private string? _lastStatePath;
    private byte[]? _lastSavedState;
    public ProtectedSessions(Func<RunningProcess, bool> excluded) { _excluded = excluded; _controls = new(excluded); }
    private static string StatePath(string root) => Path.Combine(Path.GetFullPath(root), "session.json");
    private static string CommandPath(string root) => Path.Combine(Path.GetFullPath(root), "command.json");
    private static JsonElement Value<T>(T value) => JsonSerializer.SerializeToElement(value, OperationFiles.Json);
    private static readonly string[] StartupFields = ["cpuPriority", "ioPriority", "memoryPriority"];
    private static readonly string[] NativeFields = ["gpuPriority", "executionQoS", "priorityBoost"];

    public ProtectedSessionPreview Preview(int launcherId, string gamePath, Dictionary<string, JsonElement> desired, bool acceptLauncherScope)
    {
        if (!acceptLauncherScope) throw new InvalidDataException("Review the scope: job limits and launcher defaults also affect other new launcher descendants.");
        if (!Path.IsPathFullyQualified(gamePath) || !File.Exists(gamePath) || !gamePath.EndsWith(".exe", StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException("Select an installed game executable.");
        gamePath = Path.GetFullPath(gamePath);
        if (desired.Count == 0 || desired.Keys.Any(name => !StartupFields.Concat(NativeFields).Append("affinity").Contains(name)))
            throw new InvalidDataException("Select supported protected-session controls.");
        foreach (var pair in desired) ProcessControlEngine.ValidateValue(pair.Key, pair.Value);
        if (desired.TryGetValue("gpuPriority", out var gpu) && gpu.GetInt32() == 5) throw new InvalidDataException("Real-time GPU priority is not supported by this session.");
        using var launcher = new ProcessTarget(launcherId);
        var identity = launcher.Identity();
        if (_excluded(identity) || _excluded(new(launcherId, identity.CreationTimeFileTimeUtc, gamePath))) throw new InvalidOperationException("An application is excluded by the protection policy.");
        launcher.RequireUnprotected();
        if (launcher.UserSid() != OperationOwner.Current().UserSid) throw new InvalidOperationException("The launcher belongs to another Windows user.");
        var topology = launcher.Topology();
        if (topology.Select(cpu => cpu.Group).Distinct().Count() != 1) throw new InvalidDataException("This job implementation requires a single processor group.");
        var originalAffinity = launcher.Read("affinity").Require().Deserialize<AffinityState>(OperationFiles.Json)!;
        var affinity = desired.TryGetValue("affinity", out var mask) ? mask.Deserialize<AffinityState>(OperationFiles.Json)! : originalAffinity;
        ValidateAffinity(affinity, originalAffinity);
        if (Processes(gamePath).Length != 0) throw new InvalidOperationException("Close the game before arming its launch session.");
        var launcherDesired = desired.Where(pair => pair.Key is "ioPriority" or "memoryPriority").ToDictionary(pair => pair.Key, pair => pair.Value);
        var launch = new LaunchPriorities(gamePath, desired);
        return new()
        {
            SchemaVersion = 1, OperationId = Guid.NewGuid().ToString("N"), Owner = OperationOwner.Current(), Launcher = identity,
            LauncherHash = OperationFiles.HashFile(identity.ExecutablePath), GamePath = gamePath, GameHash = OperationFiles.HashFile(gamePath), GameLength = new FileInfo(gamePath).Length, GameModifiedAtUtc = File.GetLastWriteTimeUtc(gamePath),
            TopologyHash = CpuSelection.Fingerprint(topology), OriginalAffinity = originalAffinity, Controls = new(desired),
            OriginalLaunchSettings = launch.Read(), LauncherChanges = launcherDesired.Count == 0 ? null : _controls.Preview(launcherId, launcherDesired), AcceptLauncherScope = true,
        };
    }

    public ProtectedSessionPreview Check(string path, string hash)
    {
        var plan = OperationFiles.Read<ProtectedSessionPreview>(path, hash); VerifyLaunch(plan); return plan;
    }
    public ProtectedSessionStatus Status(string root)
    {
        if (!File.Exists(StatePath(root))) return new(null, false, null);
        var state = ReadState(root);
        try { var alive = Alive(state.Host); return new(state, alive, !alive && state.Status is not ("stopped" or "stoppedWithErrors") ? "The worker exited; saved state requires recovery." : alive && DateTime.UtcNow - state.UpdatedAtUtc > TimeSpan.FromSeconds(15) ? "The worker heartbeat is stale." : null); }
        catch (Exception error) { return new(state, null, error.Message); }
    }
    public void Command(string root, string action, AffinityState? affinity = null)
    {
        if (action is not ("stop" or "affinity")) throw new InvalidDataException("Unknown session command.");
        var status = Status(root);
        if (status.HostRunning != true) throw new InvalidOperationException(status.Error ?? "The session worker is not running. Recover its saved state before starting again.");
        if (action == "affinity" && !status.State!.Preview.Controls.ContainsKey("affinity")) throw new InvalidDataException("Affinity was not part of the reviewed session.");
        if (action == "affinity") ValidateAffinity(affinity ?? throw new InvalidDataException("Select an affinity."), status.State!.Preview.OriginalAffinity);
        using var lease = OperationFiles.Lock(CommandPath(root));
        if (File.Exists(CommandPath(root))) throw new InvalidOperationException("A session command is still pending.");
        OperationFiles.Write(CommandPath(root), new ProtectedSessionCommand(OperationOwner.Current(), status.State!.Preview.OperationId, status.State.Host, action, affinity));
    }

    public ProtectedSessionState Run(string previewPath, string reviewHash, string root, Action<string, string> startWatch, CancellationToken cancellation, TimeSpan? duration = null)
    {
        cancellation.ThrowIfCancellationRequested();
        if (duration < TimeSpan.Zero) throw new InvalidDataException("Session duration cannot be negative.");
        root = Path.GetFullPath(root); previewPath = Path.GetFullPath(previewPath);
        using var lease = OperationFiles.Lock(Path.Combine(root, "worker"));
        if (File.Exists(StatePath(root))) throw new InvalidOperationException("Use a new session directory; recover the previous session before rearming.");
        var plan = OperationFiles.Read<ProtectedSessionPreview>(previewPath, reviewHash); ValidatePlan(plan);
        var governor = new ProcessPolicyStore(ProcessPolicyStore.RootFor(root));
        using var gate = ProcessPolicyStore.Gate();
        governor.RequireUnownedLaunch(plan.GamePath, plan.Controls.Keys);
        governor.RequireUnowned(plan.Launcher.ExecutablePath, plan.Controls.Keys);
#if GOVERNOR_TEST_HOOKS
        var gatePauseFile = Path.Combine(root, "gate-pause.request");
        if (File.Exists(gatePauseFile) && int.TryParse(File.ReadAllText(gatePauseFile), out var gatePause) && gatePause > 0)
        {
            File.WriteAllText(Path.Combine(root, "gate-paused"), "");
            Thread.Sleep(Math.Min(gatePause, 10000));
        }
#endif
        using var launcherLease = OperationFiles.Lock(Path.Combine(Path.GetTempPath(), BrandCompatibility.LauncherLeasePrefix + plan.Launcher.ProcessId + "-" + plan.Launcher.CreationTimeFileTimeUtc));
        using var imageLease = ImageMutex(plan.GamePath);
        AcquireImage(imageLease, recovering: false);
        try
        {
            VerifyLaunch(plan);
            var authority = Path.Combine(root, "reviewed-preview.json");
            if (!string.Equals(previewPath, authority, StringComparison.OrdinalIgnoreCase))
            {
                var reviewedBytes = File.ReadAllBytes(previewPath);
                if (!string.Equals(OperationFiles.Hash(reviewedBytes), reviewHash, StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("The reviewed preview changed before it could be retained.");
                using var retained = new FileStream(authority, FileMode.CreateNew, FileAccess.Write, FileShare.None);
                retained.Write(reviewedBytes); retained.Flush(flushToDisk: true);
            }
            previewPath = authority;
            using var self = new ProcessTarget(Environment.ProcessId);
            var state = new ProtectedSessionState
            {
                SchemaVersion = 1, Preview = plan, PreviewPath = previewPath, ReviewHash = reviewHash, Host = self.Identity(), Status = "starting",
                RegistryStatus = "pending", JobStatus = "pending", DesiredAffinity = plan.Controls.TryGetValue("affinity", out var mask) ? mask.Deserialize<AffinityState>(OperationFiles.Json)! : plan.OriginalAffinity,
                LauncherJournal = null, Games = [], Errors = [], UpdatedAtUtc = DateTime.UtcNow,
            };
            Save(root, state);
            gate.Dispose();
            ProcessJob? job = null;
            LaunchGpuHandles? gpuHandles = null;
            try
            {
                startWatch(root, plan.OperationId);
                AwaitWatch(root, state, false);
                job = ProcessJob.Create(plan.OperationId);
                state.JobStatus = "created"; Save(root, state);
                AwaitWatch(root, state, true);
                VerifyLaunch(plan);
                if (plan.Controls.ContainsKey("gpuPriority") && LaunchGpuHandles.Supported)
                {
                    var watcher = OperationFiles.Read<ProtectedWatchReady>(Path.Combine(root, "watch.json"));
                    gpuHandles = new(root, state, watcher.Watcher);
                    gpuHandles.Start();
                }
                state.JobStatus = "attachIntent"; Save(root, state);
                job.Attach(plan.Launcher);
                job.SetAffinity(ProcessTarget.ParseMask(state.DesiredAffinity.Mask)); state.JobStatus = "applied"; Save(root, state);
                if (plan.LauncherChanges is { } launcherPlan)
                {
                    var path = Path.Combine(root, "launcher-preview.json"); OperationFiles.Write(path, launcherPlan);
                    state.LauncherJournal = Path.Combine(root, "launcher-journal.json"); Save(root, state);
                    var result = _controls.Apply(path, OperationFiles.HashFile(path), state.LauncherJournal);
                    if (result.Status != "applied") throw new InvalidOperationException("Launcher defaults were not applied: " + JsonSerializer.Serialize(result.Changes, OperationFiles.Json));
                }
                state.RegistryStatus = "applyIntent"; Save(root, state);
                var launch = new LaunchPriorities(plan.GamePath, plan.Controls);
                launch.Apply(plan.OriginalLaunchSettings); state.RegistryStatus = "applied"; Save(root, state);
                var clock = Stopwatch.StartNew();
                while (!cancellation.IsCancellationRequested && (duration is null || clock.Elapsed < duration))
                {
                    if (!Alive(plan.Launcher)) break;
                    CheckWatch(root, state);
                    gpuHandles?.Check();
                    if (ReadCommand(root, state, job)) break;
                    launch.VerifyApplied();
                    MaintainLauncher(state);
                    if (job.ReadAffinity() != ProcessTarget.ParseMask(state.DesiredAffinity.Mask)) throw new InvalidOperationException("The job affinity changed outside this session.");
                    var gameFile = new FileInfo(plan.GamePath);
                    if (!gameFile.Exists || gameFile.Length != plan.GameLength || gameFile.LastWriteTimeUtc != plan.GameModifiedAtUtc) throw new InvalidOperationException("The game binary changed; review its updated launch settings.");
                    ObserveGames(root, state, job, gpuHandles);
                    state.Status = state.Games.All(game => game.Exited) ? "armed" : state.Games.Where(game => !game.Exited).All(game => game.Fields.All(field => field.Status == "applied")) ? "active" : "partial";
                    Save(root, state);
                    cancellation.WaitHandle.WaitOne(2000);
                }
            }
            catch (Exception error) { state.Errors.Add(error.Message); Save(root, state); }
            finally
            {
                try { Release(root, state, job, gpuHandles); }
                finally { gpuHandles?.Dispose(); job?.Dispose(); File.Delete(CommandPath(root)); }
            }
            return state;
        }
        finally { imageLease.ReleaseMutex(); }
    }

    public ProtectedSessionState Recover(string root, string operationId) => Recover(root, operationId, null);

    private ProtectedSessionState Recover(string root, string operationId, LaunchGpuHandles? gpuHandles)
    {
        var initial = ReadState(root);
        if (Alive(initial.Host)) throw new InvalidOperationException("The worker is still running; request stop first.");
        using var lease = RecoveryLease(Path.Combine(Path.GetFullPath(root), "worker"));
        var state = ReadState(root);
        if (state.Preview.OperationId != operationId) throw new InvalidDataException("Recovery belongs to another session.");
        if (Alive(state.Host)) throw new InvalidOperationException("The worker is still running; request stop first.");
        if ((state.Status is "stopped" or "stoppedWithErrors") && state.RegistryStatus == "restored" && state.JobStatus == "cleared") return state;
        using var imageLease = ImageMutex(state.Preview.GamePath);
        AcquireImage(imageLease, recovering: true);
        try
        {
            using var job = ProcessJob.Open(operationId);
            Release(root, state, job, gpuHandles);
        }
        finally { imageLease.ReleaseMutex(); }
        return state;
    }

    public void Watch(string root, string operationId)
    {
        var state = ReadState(root);
        if (state.Preview.OperationId != operationId || !Alive(state.Host)) throw new InvalidDataException("Recovery watch identity is stale.");
        using var imageReference = ImageMutex(state.Preview.GamePath);
        using var self = new ProcessTarget(Environment.ProcessId);
        var ready = new ProtectedWatchReady(OperationOwner.Current(), operationId, state.Host, self.Identity(), false);
        using var gpuHandles = state.Preview.Controls.ContainsKey("gpuPriority") && LaunchGpuHandles.Supported ? new LaunchGpuHandles(root, state, ready.Watcher) : null;
        OperationFiles.Write(Path.Combine(root, "watch.json"), ready);
        ProcessJob? retained = null;
        try
        {
            while (Alive(state.Host))
            {
                var current = ReadState(root);
                if (current.Preview.OperationId != operationId || current.Host != state.Host) throw new InvalidDataException("The watched session was replaced.");
                gpuHandles?.Receive();
                if (retained is null && current.JobStatus is not "pending")
                {
                    retained = ProcessJob.Open(operationId);
                    if (retained is not null) OperationFiles.Write(Path.Combine(root, "watch.json"), ready with { HoldingJob = true });
                }
                Thread.Sleep(250);
            }
            gpuHandles?.Receive();
            OperationFiles.Write(Path.Combine(root, "recovery-result.json"), Recover(root, operationId, gpuHandles));
        }
        catch (Exception error) { OperationFiles.Write(Path.Combine(root, "recovery-error.json"), new { operationId, error = error.Message }); throw; }
        finally { retained?.Dispose(); }
    }

    private static void MaintainLauncher(ProtectedSessionState state)
    {
        if (state.Preview.LauncherChanges is not { } plan) return;
        using var launcher = new ProcessTarget(plan.Identity.ProcessId, plan.Desired.Keys);
        plan.Identity.Verify(launcher.Identity());
        foreach (var pair in plan.Desired)
        {
            var actual = launcher.Read(pair.Key).Require();
            if (ProcessTarget.Equivalent(pair.Key, actual, pair.Value)) continue;
            var original = plan.Original[pair.Key].Require();
            if (!ProcessTarget.Equivalent(pair.Key, actual, original)) throw new InvalidOperationException("Launcher defaults changed to a value outside this session.");
            if (!ProcessTarget.Equivalent(pair.Key, launcher.Read(pair.Key).Require(), original)) throw new InvalidOperationException("Launcher defaults changed before reapplication.");
            launcher.Write(pair.Key, pair.Value);
            if (!ProcessTarget.Equivalent(pair.Key, launcher.Read(pair.Key).Require(), pair.Value)) throw new InvalidOperationException("Launcher priority reapplication was not verified.");
        }
    }

    private void ObserveGames(string root, ProtectedSessionState state, ProcessJob job, LaunchGpuHandles? gpuHandles)
    {
        foreach (var old in state.Games.Where(game => !game.Exited)) if (!Alive(old.Identity)) old.Exited = true;
        foreach (var processId in Processes(state.Preview.GamePath))
        {
            try { Observe(processId); }
            catch (ProcessEndedException) { }
            catch (RooIndustries.Optimization.CpuSets.NativeFailure error) when (error.Api == "OpenProcess" && error.NativeErrorCode == 87) { }
        }
        void Observe(int processId)
        {
            using var target = new ProcessTarget(processId);
            var identity = ReadIdentity(target);
            if (!string.Equals(identity.ExecutablePath, state.Preview.GamePath, StringComparison.OrdinalIgnoreCase) || !job.Contains(processId)) return;
            var game = state.Games.SingleOrDefault(item => item.Identity == identity);
            if (game is null)
            {
                if (OperationFiles.HashFile(state.Preview.GamePath) != state.Preview.GameHash) throw new InvalidDataException("The launched game binary differs from the reviewed executable.");
                game = new() { Identity = identity, Fields = state.Preview.Controls.Keys.Select(name => new ProtectedFieldState { Name = name, Route = name == "affinity" ? "job" : StartupFields.Contains(name) ? "launch" : "native", Status = "pending" }).ToList() };
                state.Games.Add(game); Save(root, state);
            }
            foreach (var field in game.Fields)
            {
                var desired = field.Name == "affinity" ? Value(state.DesiredAffinity) : state.Preview.Controls[field.Name];
                if (field.Route == "native" && (field.Status is "unavailable" or "conflict")) continue;
                var retained = field.Name == "gpuPriority" ? gpuHandles?.Find(identity) : null;
                if (field.Name == "gpuPriority" && gpuHandles is not null && retained is null)
                {
                    field.Status = "unavailable"; field.Error = "No launch handle was retained for this game instance."; continue;
                }
                var reader = retained ?? target;
                var controls = retained is null ? _controls : _controls.WithTarget(retained);
                field.Observed = reader.Read(field.Name);
                if (field.Route != "native")
                {
                    field.Status = field.Observed.Known && ProcessTarget.Equivalent(field.Name, field.Observed.Require(), desired) ? "applied" : "notApplied";
                    continue;
                }
                try
                {
                    if (field.Name == "gpuPriority" && LaunchGpuHandles.Initializing(field.Observed, identity)) { field.Status = "initializing"; continue; }
                    if (!field.Observed.Known) { field.Status = "unavailable"; field.Error = field.Observed.Error?.Message ?? "Original value unavailable."; continue; }
                    if (field.JournalPath is null)
                    {
                        if (retained is not null && !gpuHandles!.RecoveryMatches(identity, field.Observed)) { field.Status = "awaitingRecovery"; continue; }
                        var folder = Path.Combine(root, "games", identity.ProcessId + "-" + identity.CreationTimeFileTimeUtc, field.Name);
                        var path = Path.Combine(folder, "preview.json");
                        var preview = controls.Preview(processId, new() { [field.Name] = desired });
                        identity.Verify(preview.Identity); OperationFiles.Write(path, preview);
                        field.JournalPath = Path.Combine(folder, "journal.json"); Save(root, state);
                        var result = controls.Apply(path, OperationFiles.HashFile(path), field.JournalPath);
                        if (result.Status != "applied") throw new InvalidOperationException(string.Join("; ", result.Changes.Select(change => change.Error)));
                    }
                    else if (!ProcessTarget.Equivalent(field.Name, field.Observed.Require(), desired))
                    {
                        var journal = OperationFiles.Read<ProcessControlJournal>(field.JournalPath);
                        var preview = OperationFiles.Read<ProcessControlPreview>(journal.PreviewPath, journal.ReviewHash);
                        identity.Verify(preview.Identity);
                        if (!ProcessTarget.Equivalent(field.Name, field.Observed.Require(), preview.Original[field.Name].Require())) throw new InvalidOperationException("The observed control differs from both the original and requested values.");
                        using var writable = retained?.Borrow([field.Name]) ?? new ProcessTarget(processId, [field.Name]); identity.Verify(writable.Identity());
                        field.Status = "reapplyIntent"; Save(root, state);
                        if (!ProcessTarget.Equivalent(field.Name, writable.Read(field.Name).Require(), preview.Original[field.Name].Require())) throw new InvalidOperationException("The control changed before reapplication.");
                        writable.Write(field.Name, desired); field.Reapplications++;
                    }
                    field.Observed = reader.Read(field.Name);
                    if (!ProcessTarget.Equivalent(field.Name, field.Observed.Require(), desired)) throw new InvalidOperationException("Native readback differs from requested priority.");
                    field.Status = "applied"; field.Error = null;
                }
                catch (Exception error) { field.Status = "conflict"; field.Error = error.Message; }
                Save(root, state);
            }
        }
    }

    private void Release(string root, ProtectedSessionState state, ProcessJob? job, LaunchGpuHandles? gpuHandles)
    {
        var errors = new List<string>();
        foreach (var game in state.Games)
        {
            foreach (var field in game.Fields.Where(field => field.JournalPath is not null && File.Exists(field.JournalPath)))
                try { var saved = OperationFiles.Read<ProcessControlJournal>(field.JournalPath!); game.Identity.Verify(saved.Preview.Identity);
                    if (saved.Preview.Desired.Count != 1 || !saved.Preview.Desired.TryGetValue(field.Name, out var savedDesired) || !ProcessTarget.Equivalent(field.Name, savedDesired, state.Preview.Controls[field.Name])) throw new InvalidDataException("Native recovery belongs to another control.");
                    var retained = field.Name == "gpuPriority" ? gpuHandles?.Find(game.Identity) : null;
                    var result = (retained is null ? _controls : _controls.WithTarget(retained)).Restore(field.JournalPath!); field.Status = result.Status;
                    var last = result.Changes.Single(change => change.Name == field.Name);
                    field.Observed = last.Observed is { } observed ? ControlRead.From(observed) : null; field.Error = last.Error; if (result.Status is not ("restored" or "expired")) errors.Add("Native restoration needs reconciliation: " + field.Name); }
                catch (Exception error) { errors.Add(error.Message); }
            try { game.Exited = !Alive(game.Identity); }
            catch (Exception error) { errors.Add(error.Message); }
            foreach (var field in game.Fields.Where(field => field.Route == "launch")) field.Status = game.Exited ? "expired" : "restartRequired";
        }
        try
        {
            if (state.RegistryStatus is not ("pending" or "restored")) new LaunchPriorities(state.Preview.GamePath, state.Preview.Controls).Restore(state.Preview.OriginalLaunchSettings);
            state.RegistryStatus = "restored";
        }
        catch (Exception error) { errors.Add(error.Message); }
        try
        {
            if (job is not null) job.Clear(ProcessTarget.ParseMask(state.Preview.OriginalAffinity.Mask));
            else if ((state.JobStatus is "attachIntent" or "applied") && (Alive(state.Preview.Launcher) || Processes(state.Preview.GamePath).Length != 0)) throw new InvalidOperationException("The session job is unavailable; recovery cannot confirm its limits were cleared.");
            state.JobStatus = "cleared";
            foreach (var field in state.Games.SelectMany(game => game.Fields).Where(field => field.Route == "job")) field.Status = "released";
        }
        catch (Exception error) { errors.Add(error.Message); }
        if (state.LauncherJournal is { } journal && File.Exists(journal))
            try { var result = _controls.Restore(journal); if (result.Status is not ("restored" or "expired")) errors.Add("Launcher restoration needs reconciliation."); }
            catch (Exception error) { errors.Add(error.Message); }
        state.Errors = state.Errors.Concat(errors).Distinct(StringComparer.Ordinal).ToList();
        state.Status = errors.Count != 0 ? "recoveryRequired" : state.Errors.Count != 0 ? "stoppedWithErrors" : "stopped";
        Save(root, state);
    }
    private bool ReadCommand(string root, ProtectedSessionState state, ProcessJob job)
    {
        if (!File.Exists(CommandPath(root))) return false;
        using var lease = TryCommandLease(CommandPath(root));
        if (lease is null) return false;
        ProtectedSessionCommand command;
        try
        {
            command = OperationFiles.Read<ProtectedSessionCommand>(CommandPath(root)); command.Owner.Verify();
            if (command.OperationId != state.Preview.OperationId || command.Host != state.Host) throw new InvalidDataException("Session command identity changed.");
            if (command.Action is not ("stop" or "affinity")) throw new InvalidDataException("Invalid session command.");
            if (command.Action == "affinity")
            {
                if (!state.Preview.Controls.ContainsKey("affinity") || command.Affinity is null) throw new InvalidDataException("Affinity was not reviewed for this session.");
                ValidateAffinity(command.Affinity, state.Preview.OriginalAffinity);
            }
        }
        catch (Exception error) when (error is InvalidDataException or JsonException or FormatException or OverflowException)
        {
            OperationFiles.Write(Path.Combine(root, "command-rejected.json"), new { state.Preview.OperationId, error = error.Message, atUtc = DateTime.UtcNow });
            File.Delete(CommandPath(root)); return false;
        }
        if (command.Action == "stop") { File.Delete(CommandPath(root)); return true; }
        foreach (var field in state.Games.SelectMany(game => game.Fields).Where(field => field.Name == "affinity")) field.Status = "pending";
        state.DesiredAffinity = command.Affinity!; Save(root, state);
        job.SetAffinity(ProcessTarget.ParseMask(command.Affinity!.Mask)); File.Delete(CommandPath(root)); return false;
    }
    private void VerifyLaunch(ProtectedSessionPreview plan)
    {
        ValidatePlan(plan);
        using var launcher = new ProcessTarget(plan.Launcher.ProcessId); plan.Launcher.Verify(launcher.Identity()); launcher.RequireUnprotected();
        if (launcher.UserSid() != plan.Owner.UserSid || CpuSelection.Fingerprint(launcher.Topology()) != plan.TopologyHash || _excluded(plan.Launcher)) throw new InvalidDataException("Launcher ownership, topology or exclusion changed.");
        if (OperationFiles.HashFile(plan.GamePath) != plan.GameHash || OperationFiles.HashFile(plan.Launcher.ExecutablePath) != plan.LauncherHash) throw new InvalidDataException("An executable changed after review.");
        if (Processes(plan.GamePath).Length != 0) throw new InvalidOperationException("The game started before the session was armed.");
        new LaunchPriorities(plan.GamePath, plan.Controls).VerifyOriginal(plan.OriginalLaunchSettings);
        if (!ProcessTarget.Equivalent("affinity", launcher.Read("affinity").Require(), Value(plan.OriginalAffinity))) throw new InvalidOperationException("The launcher affinity changed after review.");
    }
    private static void ValidatePlan(ProtectedSessionPreview plan)
    {
        if (plan.Owner is null || plan.Launcher is null || plan.Controls is null || plan.OriginalAffinity is null || plan.OriginalLaunchSettings?.Values is null ||
            string.IsNullOrWhiteSpace(plan.GamePath) || plan.GameHash is not { Length: 64 } || plan.LauncherHash is not { Length: 64 } || plan.TopologyHash is not { Length: 64 })
            throw new InvalidDataException("Required session identity or original state is missing.");
        plan.Owner.Verify();
        if (plan.SchemaVersion != 1 || !Guid.TryParseExact(plan.OperationId, "N", out _) || !plan.AcceptLauncherScope || !Path.IsPathFullyQualified(plan.GamePath) || plan.Controls.Count == 0)
            throw new InvalidDataException("Incomplete protected-session preview.");
        foreach (var pair in plan.Controls)
        {
            if (!StartupFields.Concat(NativeFields).Append("affinity").Contains(pair.Key)) throw new InvalidDataException("Unknown protected-session control.");
            ProcessControlEngine.ValidateValue(pair.Key, pair.Value);
        }
        if (plan.GameLength <= 0 || plan.GameModifiedAtUtc == default || plan.Controls.TryGetValue("gpuPriority", out var gpu) && gpu.GetInt32() == 5)
            throw new InvalidDataException("Unsupported game image or GPU priority.");
        var launcherFields = plan.Controls.Where(pair => pair.Key is "ioPriority" or "memoryPriority").ToDictionary(pair => pair.Key, pair => pair.Value);
        if (launcherFields.Count == 0 && plan.LauncherChanges is not null || launcherFields.Count != 0 && plan.LauncherChanges is null)
            throw new InvalidDataException("Launcher defaults disagree with the reviewed game controls.");
        if (plan.LauncherChanges is { } launcher)
        {
            plan.Launcher.Verify(launcher.Identity); launcher.Owner.Verify();
            if (launcher.TopologyHash != plan.TopologyHash || launcher.Desired.Count != launcherFields.Count || launcherFields.Any(pair =>
                !launcher.Desired.TryGetValue(pair.Key, out var requested) || !ProcessTarget.Equivalent(pair.Key, pair.Value, requested)))
                throw new InvalidDataException("Launcher defaults were changed independently of the reviewed game policy.");
        }
        _ = new LaunchPriorities(plan.GamePath, plan.Controls);
        ValidateAffinity(plan.OriginalAffinity, plan.OriginalAffinity);
    }
    private static ProtectedSessionState ReadState(string root)
    {
        var state = OperationFiles.Read<ProtectedSessionState>(StatePath(root));
        if (state.Preview is null || state.Host is null || state.Games is null || state.Errors is null || string.IsNullOrWhiteSpace(state.PreviewPath) || string.IsNullOrWhiteSpace(state.ReviewHash)) throw new InvalidDataException("Incomplete session recovery state.");
        ValidatePlan(state.Preview);
        var plan = OperationFiles.Read<ProtectedSessionPreview>(state.PreviewPath, state.ReviewHash);
        if (state.SchemaVersion != 1 || JsonSerializer.Serialize(plan, OperationFiles.Json) != JsonSerializer.Serialize(state.Preview, OperationFiles.Json)) throw new InvalidDataException("Session recovery no longer matches its reviewed source.");
        if (state.LauncherJournal is not null && !string.Equals(Path.GetFullPath(state.LauncherJournal), Path.Combine(Path.GetFullPath(root), "launcher-journal.json"), StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException("Launcher recovery path escaped this session.");
        foreach (var game in state.Games)
        {
            if (game.Identity is null || game.Fields is null) throw new InvalidDataException("Game recovery identity is missing.");
            if (!string.Equals(game.Identity.ExecutablePath, plan.GamePath, StringComparison.OrdinalIgnoreCase) ||
                game.Fields.Select(field => field.Name).Distinct().Count() != plan.Controls.Count || game.Fields.Count != plan.Controls.Count)
                throw new InvalidDataException("Game recovery fields or identity are incomplete.");
            foreach (var field in game.Fields)
            {
                if (!plan.Controls.ContainsKey(field.Name)) throw new InvalidDataException("An unreviewed game control was added.");
                var route = field.Name == "affinity" ? "job" : StartupFields.Contains(field.Name) ? "launch" : "native";
                var expectedPath = Path.Combine(Path.GetFullPath(root), "games", game.Identity.ProcessId + "-" + game.Identity.CreationTimeFileTimeUtc, field.Name, "journal.json");
                if (field.Status == "applied")
                {
                    var expected = field.Name == "affinity" ? Value(state.DesiredAffinity) : plan.Controls[field.Name];
                    if (field.Observed is null || !field.Observed.Known || !ProcessTarget.Equivalent(field.Name, field.Observed.Require(), expected))
                        throw new InvalidDataException("An applied control lacks matching independent readback.");
                }
                if (field.Route != route || field.JournalPath is not null && (route != "native" || !string.Equals(Path.GetFullPath(field.JournalPath), expectedPath, StringComparison.OrdinalIgnoreCase)))
                    throw new InvalidDataException("A recovery control or path escaped the reviewed game session.");
            }
        }
        ValidateAffinity(state.DesiredAffinity, plan.OriginalAffinity);
        if (state.Status == "active" && (state.Games.All(game => game.Exited) || state.Games.Where(game => !game.Exited).Any(game => game.Fields.Any(field => field.Status != "applied")))) throw new InvalidDataException("Active session status disagrees with its control evidence.");
        return state;
    }
    private static void CheckWatch(string root, ProtectedSessionState state)
    {
        var ready = OperationFiles.Read<ProtectedWatchReady>(Path.Combine(root, "watch.json")); ready.Owner.Verify();
        if (!ready.HoldingJob || ready.OperationId != state.Preview.OperationId || ready.Host != state.Host || ready.Watcher.ProcessId == state.Host.ProcessId ||
            ready.Watcher.ExecutablePath != state.Host.ExecutablePath || !Alive(ready.Watcher))
            throw new InvalidOperationException("The recovery watcher is no longer protecting this session.");
    }
    private static void AwaitWatch(string root, ProtectedSessionState state, bool holdingJob)
    {
        var clock = Stopwatch.StartNew(); var path = Path.Combine(root, "watch.json");
        while (clock.Elapsed < TimeSpan.FromSeconds(15))
        {
            if (File.Exists(path))
            {
                var ready = OperationFiles.Read<ProtectedWatchReady>(path); ready.Owner.Verify();
                if (ready.OperationId != state.Preview.OperationId || ready.Host != state.Host) throw new InvalidDataException("Recovery watcher identity mismatch.");
                if (ready.HoldingJob == holdingJob && Alive(ready.Watcher)) return;
            }
            Thread.Sleep(50);
        }
        throw new TimeoutException("The recovery watcher did not acknowledge the session job.");
    }
    private static int[] Processes(string path)
    {
        var processes = Process.GetProcessesByName(Path.GetFileNameWithoutExtension(path));
        try { return processes.Select(process => process.Id).ToArray(); }
        finally { foreach (var process in processes) process.Dispose(); }
    }
    private static bool Alive(RunningProcess identity)
    {
        try { using var process = new ProcessTarget(identity.ProcessId); var actual = ReadIdentity(process); if (actual.CreationTimeFileTimeUtc != identity.CreationTimeFileTimeUtc) return false; identity.Verify(actual); return true; }
        catch (ProcessEndedException) { return false; }
        catch (RooIndustries.Optimization.CpuSets.NativeFailure error) when (error.Api == "OpenProcess" && error.NativeErrorCode == 87) { return false; }
    }
    private static RunningProcess ReadIdentity(ProcessTarget process)
    {
        try { return process.Identity(); }
        catch (RooIndustries.Optimization.CpuSets.NativeFailure error)
        {
            if (error.Api == "QueryFullProcessImageName" && error.NativeErrorCode == 5)
            {
                // Windows can deny the image query during teardown before signaling the process handle.
                var timer = Stopwatch.StartNew();
                while (!process.HasExited && timer.Elapsed < TimeSpan.FromSeconds(2)) Thread.Sleep(20);
            }
            if (process.HasExited) throw new ProcessEndedException();
            throw;
        }
    }
    private static void ValidateAffinity(AffinityState value, AffinityState original)
    {
        if (value is null || original is null || string.IsNullOrWhiteSpace(value.Mask) || string.IsNullOrWhiteSpace(original.Mask)) throw new InvalidDataException("Affinity evidence is missing.");
        var mask = ProcessTarget.ParseMask(value.Mask); var allowed = ProcessTarget.ParseMask(original.Mask);
        if (value.Group != original.Group || mask == 0 || (mask & ~allowed) != 0) throw new InvalidDataException("Affinity must be a nonempty subset of the launcher's reviewed processor group.");
    }
    private static Mutex ImageMutex(string gamePath) => new(false, BrandCompatibility.LaunchMutexPrefix + OperationFiles.Hash(System.Text.Encoding.UTF8.GetBytes(Path.GetFileName(gamePath).ToUpperInvariant())));
    private static void AcquireImage(Mutex mutex, bool recovering)
    {
        try
        {
            if (!mutex.WaitOne(recovering ? TimeSpan.FromSeconds(10) : TimeSpan.Zero))
                throw new InvalidOperationException("Another session owns this game's launch settings.");
        }
        catch (AbandonedMutexException)
        {
            if (!recovering) { mutex.ReleaseMutex(); throw new InvalidOperationException("The previous launch-policy owner exited; recover its saved session before starting another."); }
        }
    }
    private static FileStream? TryCommandLease(string path)
    {
        try { return OperationFiles.Lock(path); }
        catch (IOException error) when ((error.HResult & 0xffff) is 32 or 33) { return null; }
    }
    private static FileStream RecoveryLease(string path)
    {
        var timer = Stopwatch.StartNew();
        while (true)
        {
            try { return OperationFiles.Lock(path); }
            catch (IOException error) when ((error.HResult & 0xffff) is 32 or 33 && timer.Elapsed < TimeSpan.FromSeconds(10)) { Thread.Sleep(100); }
        }
    }
    private void Save(string root, ProtectedSessionState state)
    {
        if (state.Status is "armed" or "active" or "partial")
            state.Status = state.Games.All(game => game.Exited) ? "armed" : state.Games.Where(game => !game.Exited).All(game => game.Fields.All(field => field.Status == "applied")) ? "active" : "partial";
        var path = StatePath(root);
        var bytes = JsonSerializer.SerializeToUtf8Bytes(state, OperationFiles.Json);
        if (_lastStatePath == path && _lastSavedState is not null && bytes.AsSpan().SequenceEqual(_lastSavedState) && DateTime.UtcNow - state.UpdatedAtUtc < TimeSpan.FromSeconds(5)) return;
        state.UpdatedAtUtc = DateTime.UtcNow; OperationFiles.Write(path, state);
        _lastStatePath = path; _lastSavedState = JsonSerializer.SerializeToUtf8Bytes(state, OperationFiles.Json);
    }
}
