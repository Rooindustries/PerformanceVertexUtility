using System.IO.Compression;
using System.Net;
using RooIndustries.Optimizer;

static class ScewinSetupChecks
{
    public static async Task Run(Action<bool, string> check, string fixture)
    {
        if (File.ReadAllText(Path.Combine(fixture, "fixture-authority.txt")) != "roo-industries-firmware-cli-fixture/v1")
            throw new InvalidDataException("SCEWIN setup checks require the file-only helper fixture.");
        var root = Path.Combine(Path.GetTempPath(), "roo-industries-scewin-setup-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            var extractor = Zip(("innoextract.exe", new byte[] { 1, 2, 3 }));
            var engine = Zip(("app/Lib/SCEWIN/5.05.01.0002/SCEWIN64.exe", File.ReadAllBytes(Path.Combine(fixture, "SCEWIN64.exe"))),
                ("app/Lib/SCEWIN/5.05.01.0002/BIOSData.txt", new byte[] { 4, 5, 6 }),
                ("app/Lib/SCEWIN/5.05.01.0002/SCEWIN.bat", new byte[] { 7, 8, 9 }));
            var sdk = Zip(("tmp/PrePackage/Engine Lib_3.0.0.74.exe", engine));
            var appx = Zip(("DCv2/Package/MSI%20Center%20SDK.exe", sdk));
            var bundle = Zip(("MSI%20Center_2.0.74.0_x64.appx", appx));
            var center = Zip(("app/fixture.appxbundle", bundle));
            var package = Zip(("MSI Center_2.0.74.0.exe", center));
            ScewinDownload Download(string name, byte[] bytes) => new("https://example.invalid/" + name, OperationFiles.Hash(bytes), bytes.Length);
            var extractorSource = Download("extractor.zip", extractor);
            var packageSource = Download("source.zip", package);
            var response = new Handler(request => new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = new ByteArrayContent(request.RequestUri!.AbsolutePath.EndsWith("extractor.zip", StringComparison.Ordinal) ? extractor : package)
            });
            using var client = new HttpClient(response);
            var extracted = new List<string>();
            Task Extract(string executable, string source, string destination, string include, CancellationToken cancellation)
            {
                cancellation.ThrowIfCancellationRequested();
                if (!File.ReadAllBytes(executable).SequenceEqual(new byte[] { 1, 2, 3 })) throw new InvalidDataException("The fixture extractor changed.");
                extracted.Add(include);
                ZipFile.ExtractToDirectory(source, destination);
                return Task.CompletedTask;
            }
            var setup = new ScewinSetup(client, extractorSource, packageSource, Extract);
            var packages = Path.Combine(root, "packages");
            var installed = await setup.InstallAsync(packages);
            var manifest = OperationFiles.Read<FirmwarePackage>(Path.Combine(installed, "package.json"));
            check(manifest.Files.Length == 1 && manifest.Files[0].Name == "SCEWIN64.exe"
                && manifest.Files[0].Hash == OperationFiles.HashFile(Path.Combine(fixture, "SCEWIN64.exe")),
                "Automatic setup downloads, extracts and publishes the verified helper with its package manifest");
            check(extracted.SequenceEqual(new[] { "app", "tmp/PrePackage/Engine Lib_3.0.0.74.exe", "app/Lib/SCEWIN" })
                && !File.Exists(Path.Combine(installed, "BIOSData.txt")) && !File.Exists(Path.Combine(installed, "SCEWIN.bat"))
                && !File.Exists(Path.Combine(installed, "calls.log")),
                "Setup extracts only the required installer layers and never runs SCEWIN, vendor scripts or sample BIOS settings");
            check(Directory.GetDirectories(packages).SequenceEqual(new[] { installed }) && !File.Exists(Path.Combine(packages, "setup.lock")),
                "Successful setup removes download and extraction files and releases the setup lock");
            check(File.ReadAllText(Path.Combine(installed, "source.json")).Contains(packageSource.Hash, StringComparison.Ordinal)
                && new ScewinProvider(installed).PackageFingerprint.Length == 64,
                "The installed package retains download provenance and passes the existing provider checks");
            using (OperationFiles.Lock(Path.Combine(packages, "setup")))
                await Reject(() => setup.InstallAsync(packages), "Concurrent setup cannot publish a second package", check);

            var before = response.Calls;
            await Reject(() => new ScewinSetup(client, extractorSource, packageSource with { Hash = new string('0', 64) }, Extract).InstallAsync(packages),
                "A changed package digest is rejected before any installer layer runs", check);
            check(extracted.Count == 3 && Directory.GetDirectories(packages).SequenceEqual(new[] { installed }) && response.Calls == before + 2,
                "Failed setup preserves the installed package and removes every partial download");
            var calls = 0;
            var failedExtraction = new ScewinSetup(client, extractorSource, packageSource, (_, _, _, _, _) =>
            {
                calls++; throw new InvalidDataException("Fixture extraction failure");
            });
            await Reject(() => failedExtraction.InstallAsync(packages), "An extraction failure cannot activate an incomplete package", check);
            check(calls == 1 && Directory.GetDirectories(packages).Length == 1, "Extraction failure leaves a clean retry path");
            var retry = await setup.InstallAsync(packages);
            check(new ScewinProvider(retry).PackageFingerprint == new ScewinProvider(installed).PackageFingerprint,
                "Retry after a failed extraction produces the same complete verified package");

            var path = Path.Combine(root, "download.zip");
            await setup.DownloadAsync(packageSource, path, "Fixture", null, CancellationToken.None);
            check(File.ReadAllBytes(path).SequenceEqual(package), "Download validation accepts the exact pinned bytes");
            File.Delete(path);
            await Reject(() => setup.DownloadAsync(packageSource with { Length = package.Length + 1 }, path, "Fixture", null, CancellationToken.None),
                "Changed Content-Length rejects the source before writing a download", check);
            await Reject(() => setup.DownloadAsync(packageSource with { Url = "http://example.invalid/source.zip" }, path, "Fixture", null, CancellationToken.None),
                "Setup refuses an insecure initial source", check);
            using var redirectClient = new HttpClient(new Handler(_ => new(HttpStatusCode.OK)
            {
                RequestMessage = new(HttpMethod.Get, "http://example.invalid/redirect"), Content = new ByteArrayContent(package)
            }));
            await Reject(() => new ScewinSetup(redirectClient, extractorSource, packageSource, Extract).DownloadAsync(packageSource, path, "Fixture", null, CancellationToken.None),
                "A valid digest cannot excuse an insecure redirect", check);
            using var missingClient = new HttpClient(new Handler(_ => new(HttpStatusCode.NotFound)));
            await Reject(() => new ScewinSetup(missingClient, extractorSource, packageSource, Extract).InstallAsync(packages),
                "A missing official download does not activate a package", check);
            using var truncatedClient = new HttpClient(new Handler(_ => new(HttpStatusCode.OK) { Content = new StreamContent(new UnreportedStream(package[..^1])) }));
            await Reject(() => new ScewinSetup(truncatedClient, extractorSource, packageSource, Extract).DownloadAsync(packageSource, path, "Fixture", null, CancellationToken.None),
                "A truncated stream is rejected even without Content-Length", check);
            using var oversizedClient = new HttpClient(new Handler(_ => new(HttpStatusCode.OK) { Content = new StreamContent(new UnreportedStream(package.Concat(new byte[] { 0 }).ToArray())) }));
            await Reject(() => new ScewinSetup(oversizedClient, extractorSource, packageSource, Extract).DownloadAsync(packageSource, path, "Fixture", null, CancellationToken.None),
                "An oversized stream cannot write beyond the pinned download length", check);
            using var cancellation = new CancellationTokenSource();
            using var cancelledClient = new HttpClient(new Handler(_ => new(HttpStatusCode.OK) { Content = new StreamContent(new UnreportedStream(package, cancellation.Cancel)) }));
            await Reject(() => new ScewinSetup(cancelledClient, extractorSource, packageSource, Extract).DownloadAsync(packageSource, path, "Fixture", null, cancellation.Token),
                "Cancelling an in-progress download removes its partial file", check);
            check(!File.Exists(path), "Rejected downloads leave no reusable partial bytes");

            var archive = Path.Combine(root, "duplicate.zip");
            File.WriteAllBytes(archive, Zip(("innoextract.exe", new byte[] { 1 }), ("innoextract.exe", new byte[] { 2 })));
            await Reject(() => { ScewinSetup.ExtractZip(archive, e => e.FullName == "innoextract.exe", path); return Task.CompletedTask; },
                "Duplicate selected archive members cannot choose an arbitrary executable", check);
            await Reject(() => { ScewinSetup.ExtractZip(archive, e => e.FullName == "absent.exe", path); return Task.CompletedTask; },
                "A missing archive member cannot be reported as installed", check);
        }
        finally { Directory.Delete(root, true); }
        check(!Directory.Exists(root), "SCEWIN setup checks remove every package and download fixture");
    }

    private static async Task Reject(Func<Task> action, string message, Action<bool, string> check)
    {
        var rejected = false;
        try { await action(); }
        catch (Exception error) when (error is IOException or InvalidDataException or HttpRequestException or OperationCanceledException) { rejected = true; }
        check(rejected, message);
    }

    private static byte[] Zip(params (string Name, byte[] Bytes)[] entries)
    {
        using var memory = new MemoryStream();
        using (var zip = new ZipArchive(memory, ZipArchiveMode.Create, true))
            foreach (var entry in entries)
            {
                using var output = zip.CreateEntry(entry.Name).Open();
                output.Write(entry.Bytes);
            }
        return memory.ToArray();
    }

    private sealed class Handler(Func<HttpRequestMessage, HttpResponseMessage> respond) : HttpMessageHandler
    {
        public int Calls { get; private set; }
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            Calls++;
            var response = respond(request);
            response.RequestMessage ??= request;
            return Task.FromResult(response);
        }
    }

    private sealed class UnreportedStream(byte[] bytes, Action? onRead = null) : MemoryStream(bytes)
    {
        public override bool CanSeek => false;
        public override ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken cancellationToken = default)
        {
            var read = base.ReadAsync(buffer, cancellationToken);
            onRead?.Invoke();
            return read;
        }
    }
}
