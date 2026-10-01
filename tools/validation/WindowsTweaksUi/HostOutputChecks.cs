using System.Text;
using RooIndustries.OptimizationSuite.Services;

static class HostOutputChecks
{
    sealed class ChunkStream(params byte[][] chunks) : Stream
    {
        public bool HangAtEnd { get; init; }
        private int _next;
        public Action<int>? BeforeChunk { get; set; }
        public override bool CanRead => true;
        public override bool CanSeek => false;
        public override bool CanWrite => false;
        public override long Length => throw new NotSupportedException();
        public override long Position { get => throw new NotSupportedException(); set => throw new NotSupportedException(); }
        public override void Flush() { }
        public override int Read(byte[] buffer, int offset, int count) => Read(buffer.AsSpan(offset, count));
        public override int Read(Span<byte> buffer)
        {
            if (_next >= chunks.Length) return 0;
            BeforeChunk?.Invoke(_next);
            var chunk = chunks[_next++]; chunk.CopyTo(buffer); return chunk.Length;
        }
        public override ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken cancellationToken = default)
            => HangAtEnd && _next >= chunks.Length ? new ValueTask<int>(new TaskCompletionSource<int>().Task) : ValueTask.FromResult(Read(buffer.Span));
        public override Task<int> ReadAsync(byte[] buffer, int offset, int count, CancellationToken cancellationToken) => Task.FromResult(Read(buffer.AsSpan(offset, count)));
        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
        public override void SetLength(long value) => throw new NotSupportedException();
        public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
    }

    sealed class BrokenPipe : Stream
    {
        public override bool CanRead => false;
        public override bool CanSeek => false;
        public override bool CanWrite => true;
        public override long Length => throw new NotSupportedException();
        public override long Position { get => throw new NotSupportedException(); set => throw new NotSupportedException(); }
        public override void Flush() => throw new IOException("Pipe is broken.");
        public override int Read(byte[] buffer, int offset, int count) => throw new NotSupportedException();
        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
        public override void SetLength(long value) => throw new NotSupportedException();
        public override void Write(byte[] buffer, int offset, int count) => throw new IOException("Pipe is broken.");
        public override ValueTask WriteAsync(ReadOnlyMemory<byte> buffer, CancellationToken cancellationToken = default) => ValueTask.FromException(new IOException("Pipe is broken."));
    }

    public static async Task Run(Action<bool, string> check)
    {
        var failures = new List<string>();
        async Task Scenario(string name, Func<Task<bool>> body)
        {
            bool passed;
            try { passed = await body(); }
            catch (Exception error) { passed = false; name += " (" + error.GetType().Name + ": " + error.Message + ")"; }
            Console.WriteLine((passed ? "PASS " : "FAIL ") + name);
            if (!passed) failures.Add(name);
        }
        static byte[] B(string text) => Encoding.UTF8.GetBytes(text);
        static byte[][] Split(byte[] all, params int[] cuts)
        {
            var parts = new List<byte[]>(); var start = 0;
            foreach (var cut in cuts.Append(all.Length)) { parts.Add(all[start..cut]); start = cut; }
            return parts.ToArray();
        }
        static async Task<(List<string> Partials, string Final)> Read(Stream stream, Func<bool>? stopped = null)
        {
            var partials = new List<string>();
            var final = await HostOutput.ReadAsync(stream, bytes => partials.Add(Encoding.UTF8.GetString(bytes.Span)), stopped);
            return (partials, Encoding.UTF8.GetString(final.Span));
        }
        const string Final = "{\"status\":\"completed\",\"data\":{\"note\":\"ROO-PARTIAL inside a value\"}}";

        await Scenario("A partial line after a byte order mark is delivered and the final JSON is returned", async () =>
        {
            var (partials, final) = await Read(new ChunkStream([.. "\uFEFF"u8, .. B("ROO-PARTIAL {\"a\":1}\n" + Final)]));
            return partials.SequenceEqual(["{\"a\":1}"]) && final == Final;
        });
        await Scenario("A prefix and a partial line split across reads are delivered whole", async () =>
        {
            var all = B("ROO-PARTIAL {\"a\":12345}\r\nROO-PARTIAL {\"b\":2}\n" + Final);
            var (partials, final) = await Read(new ChunkStream(Split(all, 3, 9, 17, 25, 30)));
            return partials.Count == 2 && partials[0].TrimEnd('\r') == "{\"a\":12345}" && partials[1] == "{\"b\":2}" && final == Final;
        });
        await Scenario("A partial line after stray output is still delivered and the stray text is kept with the final output", async () =>
        {
            var (partials, final) = await Read(new ChunkStream(B("runtime notice\nROO-PARTIAL {\"a\":1}\n" + Final)));
            return partials.SequenceEqual(["{\"a\":1}"]) && final == "runtime notice\n" + Final;
        });
        await Scenario("Text that only contains the prefix inside the final JSON is not taken as a partial", async () =>
        {
            var (partials, final) = await Read(new ChunkStream(B(Final)));
            return partials.Count == 0 && final == Final;
        });
        await Scenario("A partial line cut off by the helper exiting is dropped instead of becoming the final output", async () =>
        {
            var (partials, final) = await Read(new ChunkStream(B("ROO-PARTIAL {\"a\":1}\nROO-PARTIAL {\"b\":")));
            return partials.SequenceEqual(["{\"a\":1}"]) && final.Trim().Length == 0;
        });
        await Scenario("No partial line is delivered after the read was stopped by a timeout", async () =>
        {
            var stop = false;
            var stream = new ChunkStream(B("ROO-PARTIAL {\"a\":1}\n"), B("ROO-PARTIAL {\"b\":2}\n"), B(Final)) { BeforeChunk = index => { if (index == 1) stop = true; } };
            var (partials, _) = await Read(stream, () => stop);
            return partials.SequenceEqual(["{\"a\":1}"]);
        });
        await Scenario("A partial handler that throws does not stop the read", async () =>
        {
            var calls = 0;
            var final = await HostOutput.ReadAsync(new ChunkStream(B("ROO-PARTIAL {\"a\":1}\nROO-PARTIAL {\"b\":2}\n" + Final)), _ => { calls++; throw new InvalidOperationException("handler"); });
            return calls == 2 && Encoding.UTF8.GetString(final.Span) == Final;
        });
        await Scenario("Output without a partial handler is returned unchanged apart from a leading byte order mark", async () =>
        {
            var final = await HostOutput.ReadAsync(new ChunkStream([.. "\uFEFF"u8, .. B("ROO-PARTIAL x\n" + Final)]), null);
            return Encoding.UTF8.GetString(final.Span) == "ROO-PARTIAL x\n" + Final;
        });
        await Scenario("Output that stays open after the helper exits is returned once the read is abandoned", async () =>
        {
            using var abandon = new CancellationTokenSource();
            var read = HostOutput.ReadAsync(new ChunkStream(B("ROO-PARTIAL {\"a\":1}\n" + Final)) { HangAtEnd = true }, _ => { }, null, abandon.Token);
            if (await Task.WhenAny(read, Task.Delay(500)) == read) return false;
            abandon.Cancel();
            if (await Task.WhenAny(read, Task.Delay(5000)) != read) return false;
            return Encoding.UTF8.GetString((await read).Span) == Final;
        });
        await Scenario("Writing a request to a pipe that is already broken reports that it was not read instead of throwing", async () =>
        {
            var written = new MemoryStream();
            var ok = await HostOutput.TryWriteRequestAsync(written, B("{}"), CancellationToken.None);
            var broken = await HostOutput.TryWriteRequestAsync(new BrokenPipe(), B("{}"), CancellationToken.None);
            return ok && !broken;
        });
        await Scenario("A real helper that exits before reading a large request is reported as not having read it, without an exception", async () =>
        {
            using var helper = System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(Path.Combine(Environment.SystemDirectory, "cmd.exe"), "/c exit 3") { UseShellExecute = false, CreateNoWindow = true, RedirectStandardInput = true })!;
            await helper.WaitForExitAsync();
            using var other = System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(Path.Combine(Environment.SystemDirectory, "cmd.exe"), "/c exit 3") { UseShellExecute = false, CreateNoWindow = true, RedirectStandardInput = true })!;
            await other.WaitForExitAsync();
            var naive = false;
            try { await other.StandardInput.BaseStream.WriteAsync(new byte[1 << 20]); } catch (IOException) { naive = true; }
            var written = await HostOutput.TryWriteRequestAsync(helper.StandardInput.BaseStream, new byte[1 << 20], CancellationToken.None);
            return naive && !written && helper.ExitCode == 3;
        });
        check(failures.Count == 0, "Helper output parsing (" + failures.Count + " failed: " + string.Join("; ", failures) + ")");
    }
}
