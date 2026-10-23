using System.Diagnostics;
using System.Globalization;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text.Json;
using RooIndustries.Optimizer;

if (!OperatingSystem.IsWindows()) throw new PlatformNotSupportedException("This fixture requires Windows.");
if (args.Length != 2) throw new ArgumentException("Expected request path and its SHA256.");
var requestPath = Path.GetFullPath(args[0]);
if (!string.Equals(OperationFiles.HashFile(requestPath), args[1], StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("Request hash changed.");
var request = JsonSerializer.Deserialize<Request>(File.ReadAllText(requestPath), OperationFiles.Json) ?? throw new InvalidDataException("Missing request.");
var root = Path.GetFullPath(request.OwnedRoot).TrimEnd(Path.DirectorySeparatorChar);
string Owned(string path)
{
    var full = Path.GetFullPath(path);
    if (!full.StartsWith(root + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("Path escapes owned fixture.");
    for (var directory = Path.GetDirectoryName(full); directory is not null && directory.Length >= root.Length; directory = Path.GetDirectoryName(directory))
        if (Directory.Exists(directory) && (File.GetAttributes(directory) & FileAttributes.ReparsePoint) != 0) throw new InvalidDataException("Fixture link refused.");
    return full;
}
Owned(requestPath);
var output = Owned(request.OutputPath);
var release = Owned(request.ReleasePath);
var marker = JsonSerializer.Deserialize<Frame>(File.ReadAllText(Path.Combine(root, "owner.json")), OperationFiles.Json) ?? throw new InvalidDataException("Missing frame identity.");
if (marker.Nonce != request.Nonce || marker.SourceCommit != request.SourceCommit || request.SourceCommit.Length != 40 || !request.SourceCommit.All(Uri.IsHexDigit)) throw new InvalidDataException("Frame/source identity changed.");
var expectedPath = Owned(request.ExecutablePath);
if (Path.GetFileName(expectedPath) != "RestoreTarget.exe") throw new InvalidDataException("Only the owned RestoreTarget image is allowed.");
if (!string.Equals(OperationFiles.HashFile(expectedPath), request.ImageSha256, StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("Fixture image changed.");
using var self = Process.GetCurrentProcess();
using var target = Process.GetProcessById(request.ProcessId);
if (self.SessionId != request.RestoreSessionId || target.SessionId != request.RestoreSessionId) throw new InvalidDataException("Actor, target and restore must share the actual terminal session.");
if (target.HasExited || target.StartTime.ToUniversalTime().ToFileTimeUtc().ToString(CultureInfo.InvariantCulture) != request.NativeBirth || !string.Equals(target.MainModule?.FileName, expectedPath, StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("Target identity changed.");
var mutexName = @"Local\RooProcessControls-" + request.ProcessId.ToString(CultureInfo.InvariantCulture) + "-" + request.NativeBirth;
if (!long.TryParse(request.NativeBirth, NumberStyles.None, CultureInfo.InvariantCulture, out var birth) || birth <= 0) throw new InvalidDataException("Invalid native birth.");
object Receipt(string outcome, object? result = null) => new
{
    schemaVersion = 1, sourceCommit = request.SourceCommit, request.Nonce, outcome,
    actorPid = self.Id, actorBirth = self.StartTime.ToUniversalTime().ToFileTimeUtc().ToString(CultureInfo.InvariantCulture),
    actorSessionId = self.SessionId, restoreSessionId = request.RestoreSessionId, targetSessionId = target.SessionId,
    targetPid = target.Id, nativeBirth = request.NativeBirth, executablePath = expectedPath, mutexName, result,
};
void AwaitRelease()
{
    var watch = Stopwatch.StartNew();
    while (!File.Exists(release))
    {
        if (watch.Elapsed > TimeSpan.FromSeconds(15)) throw new TimeoutException("Owned actor release was not received.");
        Thread.Sleep(10);
    }
}
try
{
    if (request.Mode == "identity-denied")
    {
        var original = KernelAcl.Deny(target.Handle, 0x1000);
        try
        {
            OperationFiles.Write(output, Receipt("query-denied-held"));
            AwaitRelease();
        }
        finally { KernelAcl.Restore(target.Handle, original); }
    }
    else if (request.Mode is "busy" or "abandoned" or "denied")
    {
        using var mutex = new Mutex(false, mutexName);
        var held = false;
        byte[]? original = null;
        try
        {
            try { held = mutex.WaitOne(0); } catch (AbandonedMutexException) { held = true; }
            if (!held) throw new InvalidOperationException("Fixture could not own its mutex.");
            if (request.Mode == "denied") original = KernelAcl.Deny(mutex.SafeWaitHandle.DangerousGetHandle());
            OperationFiles.Write(output, Receipt("held"));
            AwaitRelease();
        }
        finally
        {
            try { if (original is not null) KernelAcl.Restore(mutex.SafeWaitHandle.DangerousGetHandle(), original); }
            finally { if (held) mutex.ReleaseMutex(); }
        }
    }
    else if (request.Mode == "wrong-type")
    {
        using var collision = new EventWaitHandle(false, EventResetMode.ManualReset, mutexName);
        OperationFiles.Write(output, Receipt("wrong-type-held"));
        AwaitRelease();
    }
    else
    {
        var name = request.Control switch { "priorityClass" => "cpuPriority", "affinityMask" => "affinity", "ioPriority" or "memoryPriority" or "gpuPriority" => request.Control, _ => throw new InvalidDataException("Unknown control.") };
        object value = request.Control switch
        {
            "priorityClass" => request.Value.GetString() == "RealTime" ? "Realtime" : request.Value.GetString() ?? throw new InvalidDataException("Missing priority."),
            "affinityMask" => new AffinityState(0, unchecked((ulong)request.Value.GetInt64()).ToString(CultureInfo.InvariantCulture)),
            "ioPriority" => request.Value.GetString() switch { "VeryLow" or "Idle" => 0, "Low" => 1, "Normal" => 2, "High" => 3, _ => throw new InvalidDataException("Unknown I/O name.") },
            "gpuPriority" => request.Value.GetString() switch { "Idle" => 0, "BelowNormal" => 1, "Normal" => 2, "AboveNormal" => 3, "High" => 4, "Realtime" or "RealTime" => 5, _ => throw new InvalidDataException("Unknown GPU name.") },
            "memoryPriority" => request.Value.GetInt32(),
            _ => throw new InvalidDataException("Unknown control."),
        };
        var engine = new ProcessControlEngine(identity => identity.ProcessId != request.ProcessId || identity.CreationTimeFileTimeUtc != request.NativeBirth || !string.Equals(identity.ExecutablePath, expectedPath, StringComparison.OrdinalIgnoreCase));
        var previewPath = Owned(request.PreviewPath);
        var journalPath = Owned(request.JournalPath);
        if (request.Mode == "apply")
        {
            var preview = engine.Preview(request.ProcessId, new() { [name] = JsonSerializer.SerializeToElement(value, OperationFiles.Json) });
            if (preview.Identity.CreationTimeFileTimeUtc != request.NativeBirth || preview.Desired.Count != 1 || !preview.Desired.ContainsKey(name)) throw new InvalidDataException("Preview identity/control changed.");
            OperationFiles.Write(previewPath, preview);
            var result = engine.Apply(previewPath, OperationFiles.HashFile(previewPath), journalPath);
            if (result.Status != "applied" || result.Changes.Count != 1 || result.Changes[0].Status != "applied") throw new InvalidDataException("Native apply was not verified.");
            OperationFiles.Write(output, Receipt("applied", result));
        }
        else if (request.Mode == "restore")
        {
            var result = engine.Restore(journalPath);
            if (result.Status is not ("restored" or "expired")) throw new InvalidDataException("Native restore remains pending.");
            OperationFiles.Write(output, Receipt("restored", result));
        }
        else throw new InvalidDataException("Unknown actor mode.");
    }
    Console.WriteLine("ROO_INDUSTRIES_NATIVE_RESTORE_ACTOR_COMPLETE");
    return 0;
}
catch (InstanceBusyException error)
{
    OperationFiles.Write(output, Receipt("instance-busy", new { exceptionType = error.GetType().FullName }));
    Console.Error.WriteLine(typeof(InstanceBusyException).FullName);
    return 10;
}
catch (Exception error)
{
    OperationFiles.Write(output, Receipt("failed", new { exceptionType = error.GetType().FullName, error.Message }));
    Console.Error.WriteLine(error);
    return 1;
}

sealed record Frame(string Nonce, string SourceCommit);
sealed record Request(string OwnedRoot, string Nonce, string SourceCommit, string Mode, int ProcessId, string NativeBirth,
    string ExecutablePath, string ImageSha256, int RestoreSessionId, string Control, JsonElement Value,
    string PreviewPath, string JournalPath, string OutputPath, string ReleasePath);
static class KernelAcl
{
    [DllImport("advapi32.dll", SetLastError = true)] private static extern bool GetKernelObjectSecurity(IntPtr handle, uint info, byte[]? bytes, uint size, out uint needed);
    [DllImport("advapi32.dll", SetLastError = true)] private static extern bool SetKernelObjectSecurity(IntPtr handle, uint info, byte[] bytes);
    public static byte[] Deny(IntPtr handle, int rights = 0x100001)
    {
        GetKernelObjectSecurity(handle, 4, null, 0, out var needed);
        var original = new byte[needed];
        if (!GetKernelObjectSecurity(handle, 4, original, needed, out _)) throw new System.ComponentModel.Win32Exception();
        var acl = new RawSecurityDescriptor(original, 0);
        acl.DiscretionaryAcl!.InsertAce(0, new CommonAce(AceFlags.None, AceQualifier.AccessDenied, rights, WindowsIdentity.GetCurrent().User!, false, null));
        var changed = new byte[acl.BinaryLength];
        acl.GetBinaryForm(changed, 0);
        Restore(handle, changed);
        return original;
    }
    public static void Restore(IntPtr handle, byte[] bytes)
    {
        if (!SetKernelObjectSecurity(handle, 4, bytes)) throw new System.ComponentModel.Win32Exception();
    }
}
