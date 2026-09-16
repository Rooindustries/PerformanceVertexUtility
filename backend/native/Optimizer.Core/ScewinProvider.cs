#nullable enable
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Roo.Optimizer;

public sealed record FirmwarePackageFile([property: JsonRequired] string Name, [property: JsonRequired] string Hash);
public sealed record FirmwarePackage([property: JsonRequired] string Executable, [property: JsonRequired] string Version,
    [property: JsonRequired] string Publisher, [property: JsonRequired] string Signature,
    [property: JsonRequired] FirmwarePackageFile[] Files);

public sealed class ScewinProvider : IFirmwareProvider
{
    private readonly string _directory;
    private readonly FirmwarePackage _package;
    public ScewinProvider(string directory)
    {
        _directory = Path.GetFullPath(directory);
        _package = OperationFiles.Read<FirmwarePackage>(Path.Combine(_directory, "package.json"));
        _ = PackageFingerprint;
    }
    public static FirmwareIdentity CurrentIdentity()
    {
        var output = PowerShell("$ErrorActionPreference='Stop'; $c=Get-CimInstance Win32_ComputerSystemProduct; $b=Get-CimInstance Win32_BaseBoard; $f=Get-CimInstance Win32_BIOS; $o=Get-CimInstance Win32_OperatingSystem; [ordered]@{machineId=([string]$c.UUID);board=($b.Manufacturer+' '+$b.Product+' '+$b.Version);bios=($f.Manufacturer+' '+$f.SMBIOSBIOSVersion+' '+$f.ReleaseDate.ToUniversalTime().ToString('o'));boot=$o.LastBootUpTime.ToUniversalTime().ToString('o')}|ConvertTo-Json -Compress");
        var identity = JsonSerializer.Deserialize<FirmwareIdentity>(output, OperationFiles.Json) ?? throw new InvalidDataException("The firmware identity is empty.");
        identity.Validate();
        if (!Guid.TryParse(identity.MachineId, out var id) || id == Guid.Empty || id == new Guid("ffffffff-ffff-ffff-ffff-ffffffffffff"))
            throw new InvalidDataException("The motherboard does not expose a unique machine identifier. Firmware writes need a board-specific identity provider.");
        return identity;
    }
    public FirmwareIdentity ReadIdentity() => CurrentIdentity();
    public string PackageFingerprint
    {
        get
        {
            if (_package.Files.Length == 0 || !_package.Files.Any(f => f.Name == _package.Executable)) throw new InvalidDataException("The firmware package is incomplete.");
            foreach (var file in _package.Files)
                if (Path.GetFileName(file.Name) != file.Name || OperationFiles.HashFile(Path.Combine(_directory, file.Name)) != file.Hash)
                    throw new InvalidDataException("The SCEWIN package was modified. Choose the original package again.");
            var actual = Directory.GetFiles(_directory).Where(IsComponent).Select(Path.GetFileName).Order().ToArray();
            if (!actual.SequenceEqual(_package.Files.Select(f => f.Name).Order())) throw new InvalidDataException("Unexpected files were added to the SCEWIN package.");
            return OperationFiles.Hash(JsonSerializer.SerializeToUtf8Bytes(_package, OperationFiles.Json));
        }
    }

    public static FirmwarePackage Inspect(string directory)
    {
        var executable = Directory.GetFiles(directory, "*.exe").FirstOrDefault(p => Path.GetFileName(p).Equals("SCEWIN_64.exe", StringComparison.OrdinalIgnoreCase))
            ?? Directory.GetFiles(directory, "*.exe").FirstOrDefault(p => Path.GetFileName(p).Equals("SCEWIN64.exe", StringComparison.OrdinalIgnoreCase))
            ?? Directory.GetFiles(directory, "*.exe").FirstOrDefault(p => Path.GetFileName(p).Equals("SCEWIN.exe", StringComparison.OrdinalIgnoreCase))
            ?? throw new FileNotFoundException("Select the folder containing SCEWIN_64.exe, SCEWIN64.exe or SCEWIN.exe and its matching driver files. DL_SCEWIN.exe is a downloader, not the firmware helper.");
        using (var pe = new BinaryReader(File.OpenRead(executable)))
        {
            if (pe.ReadUInt16() != 0x5a4d) throw new InvalidDataException("SCEWIN is not a Windows executable.");
            pe.BaseStream.Position = 0x3c; var header = pe.ReadUInt32(); pe.BaseStream.Position = header;
            if (pe.ReadUInt32() != 0x4550 || pe.ReadUInt16() != 0x8664 || RuntimeInformation.OSArchitecture != Architecture.X64)
                throw new InvalidDataException("This workflow requires the Windows x64 SCEWIN package on an x64 PC.");
        }
        var version = FileVersionInfo.GetVersionInfo(executable);
        var files = Directory.GetFiles(directory).Where(p => p.Equals(executable, StringComparison.OrdinalIgnoreCase)
            || Path.GetExtension(p).Equals(".sys", StringComparison.OrdinalIgnoreCase) || Path.GetExtension(p).Equals(".dll", StringComparison.OrdinalIgnoreCase)).Order(StringComparer.OrdinalIgnoreCase).ToArray();
        var info = JsonSerializer.Deserialize<SignatureInfo[]>(PowerShell("$ErrorActionPreference='Stop'; $files=@(" + string.Join(",", files.Select(Quote)) + "); ConvertTo-Json -InputObject @($files|ForEach-Object{$s=Get-AuthenticodeSignature -LiteralPath $_; [ordered]@{name=[IO.Path]::GetFileName($_); status=[string]$s.Status; publisher=[string]$s.SignerCertificate.Subject}}) -Compress"), new JsonSerializerOptions { PropertyNameCaseInsensitive = true })!;
        foreach (var driver in info.Where(f => f.Name.EndsWith(".sys", StringComparison.OrdinalIgnoreCase)))
            if (driver.Status != "Valid") throw new InvalidDataException(driver.Name + " has signature status " + driver.Status + ". Obtain the matching signed driver package from your motherboard vendor.");
        var signature = info.Single(f => f.Name == Path.GetFileName(executable));
        if (signature.Status is not "Valid" and not "NotSigned") throw new InvalidDataException("SCEWIN signature verification failed: " + signature.Status + ". Use the original vendor package.");
        return new(Path.GetFileName(executable), version.FileVersion ?? "Not specified", signature.Publisher.Length > 0 ? signature.Publisher : version.CompanyName ?? "Not specified", signature.Status,
            files.Select(p => new FirmwarePackageFile(Path.GetFileName(p), OperationFiles.HashFile(p))).ToArray());
    }
    private static bool IsComponent(string path) => Path.GetExtension(path).ToLowerInvariant() is ".exe" or ".sys" or ".dll";
    private sealed record SignatureInfo(string Name, string Status, string Publisher);

    public static string SetUp(string source, FirmwarePackage reviewed, string packagesRoot)
    {
        var current = Inspect(source);
        if (JsonSerializer.Serialize(current, OperationFiles.Json) != JsonSerializer.Serialize(reviewed, OperationFiles.Json)) throw new InvalidDataException("The selected package changed during review.");
        var destination = Path.Combine(packagesRoot, Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(destination);
        try
        {
            foreach (var file in reviewed.Files) File.Copy(Path.Combine(source, file.Name), Path.Combine(destination, file.Name));
            OperationFiles.Write(Path.Combine(destination, "package.json"), reviewed);
            _ = new ScewinProvider(destination).PackageFingerprint;
            return destination;
        }
        catch { Directory.Delete(destination, recursive: true); throw; }
    }

    public byte[] Export(string workingDirectory)
    {
        var path = Path.Combine(workingDirectory, "export-" + Guid.NewGuid().ToString("N") + ".txt");
        try
        {
            var result = Run(["/o", "/s", path, "/v"]);
            File.WriteAllText(Path.Combine(workingDirectory, "last-export-output.txt"), result.Output + Environment.NewLine + result.Error);
            if (!result.Succeeded) throw new InvalidOperationException("SCEWIN export exited " + result.ExitCode + ". " + result.Output.Trim() + " " + result.Error.Trim());
            if (!File.Exists(path)) throw new InvalidDataException("SCEWIN did not produce an export. " + result.Output.Trim());
            return File.ReadAllBytes(path);
        }
        finally { File.Delete(path); }
    }
    public FirmwareCommandResult Import(string scriptPath) => Run(["/i", "/s", Path.GetFullPath(scriptPath), "/r"]);

    private FirmwareCommandResult Run(string[] arguments)
    {
        foreach (var name in new[] { "SCEWIN", "SCEWIN64", "SCEWIN_64" })
            foreach (var process in Process.GetProcessesByName(name))
                using (process)
                    if (!process.HasExited) throw new InvalidOperationException("Another SCEWIN operation is running (PID " + process.Id + "). Wait for it to finish before reading or writing firmware.");
        _ = PackageFingerprint;
        var leases = new List<FileStream>();
        try
        {
            foreach (var file in _package.Files) leases.Add(new FileStream(Path.Combine(_directory, file.Name), FileMode.Open, FileAccess.Read, FileShare.Read));
            _ = PackageFingerprint;
            return Command(Path.Combine(_directory, _package.Executable), arguments, _directory);
        }
        finally { foreach (var lease in leases) lease.Dispose(); }
    }
    private static string Quote(string value) => "'" + value.Replace("'", "''") + "'";
    private static string PowerShell(string script)
    {
        var result = Command(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "WindowsPowerShell", "v1.0", "powershell.exe"),
            ["-NoProfile", "-NonInteractive", "-EncodedCommand", Convert.ToBase64String(Encoding.Unicode.GetBytes(script))], Environment.GetFolderPath(Environment.SpecialFolder.System));
        if (result.ExitCode != 0) throw new InvalidOperationException("Firmware inspection exited " + result.ExitCode + ": " + result.Error.Trim());
        return result.Output;
    }
    private static FirmwareCommandResult Command(string executable, string[] arguments, string directory)
    {
        var start = new ProcessStartInfo(executable) { WorkingDirectory = directory, UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true };
        foreach (var argument in arguments) start.ArgumentList.Add(argument);
        try
        {
            using var process = Process.Start(start) ?? throw new InvalidOperationException("The firmware helper did not start.");
            var output = process.StandardOutput.ReadToEndAsync(); var error = process.StandardError.ReadToEndAsync();
            process.WaitForExit();
            return new(process.ExitCode, output.GetAwaiter().GetResult(), error.GetAwaiter().GetResult());
        }
        catch (Win32Exception ex)
        {
            using var identity = WindowsIdentity.GetCurrent();
            var admin = new WindowsPrincipal(identity).IsInRole(WindowsBuiltInRole.Administrator);
            throw new InvalidOperationException(Path.GetFileName(executable) + " could not start: Win32 " + ex.NativeErrorCode + " (0x" + ex.NativeErrorCode.ToString("X") + "), admin token=" + admin + ". " + ex.Message, ex);
        }
    }
}
