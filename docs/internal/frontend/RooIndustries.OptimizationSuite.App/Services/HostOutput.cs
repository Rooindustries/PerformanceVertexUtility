using System;
using System.IO;
using System.Threading;
using System.Threading.Tasks;

namespace RooIndustries.OptimizationSuite.Services;

public static class HostOutput
{
    private static ReadOnlySpan<byte> PartialPrefix => "ROO-PARTIAL "u8;
    private static ReadOnlySpan<byte> Bom => "\uFEFF"u8;

    public static async Task<bool> TryWriteRequestAsync(Stream input, ReadOnlyMemory<byte> payload, CancellationToken cancellationToken)
    {
        try
        {
            await input.WriteAsync(payload, cancellationToken).ConfigureAwait(false);
            await input.FlushAsync(cancellationToken).ConfigureAwait(false);
            input.Close();
            return true;
        }
        catch (IOException)
        {
            try { input.Close(); } catch (IOException) { }
            return false;
        }
    }

    public static async Task<ReadOnlyMemory<byte>> ReadAsync(Stream stream, Action<ReadOnlyMemory<byte>>? partial, Func<bool>? stopped = null, CancellationToken abandon = default)
    {
        var abandoned = Task.Delay(Timeout.Infinite, abandon);
        var kept = new MemoryStream();
        var line = new MemoryStream();
        var chunk = new byte[81920];
        var atStart = true;
        var decided = false;
        var isPartial = false;
        void Decide(bool final)
        {
            var span = new ReadOnlySpan<byte>(line.GetBuffer(), 0, (int)line.Length);
            if (!final && atStart && span.Length < 3 && Bom.StartsWith(span)) return;
            var body = atStart && span.StartsWith(Bom) ? span[3..] : span;
            if (!final && body.Length < PartialPrefix.Length && PartialPrefix.StartsWith(body)) return;
            decided = true;
            isPartial = body.StartsWith(PartialPrefix);
            if (isPartial) return;
            kept.Write(body);
            line.SetLength(0);
        }
        void EndLine()
        {
            if (isPartial)
            {
                var span = new ReadOnlyMemory<byte>(line.GetBuffer(), 0, (int)line.Length);
                var body = atStart && span.Span.StartsWith(Bom) ? span[3..] : span;
                var payload = body[PartialPrefix.Length..];
                if (payload.Span.EndsWith("\n"u8)) payload = payload[..^1];
                if (stopped?.Invoke() != true)
                {
                    try { partial!(payload.ToArray()); }
                    catch (Exception error) { AppLog.Write("helper", "Partial result ignored: " + error.Message); }
                }
            }
            line.SetLength(0); atStart = false; decided = false; isPartial = false;
        }
        void Take(int read)
        {
            var span = chunk.AsSpan(0, read);
            while (span.Length > 0)
            {
                var newline = span.IndexOf((byte)'\n');
                var piece = newline < 0 ? span : span[..(newline + 1)];
                span = span[piece.Length..];
                if (decided && !isPartial) kept.Write(piece);
                else
                {
                    line.Write(piece);
                    if (!decided) Decide(newline >= 0);
                }
                if (newline >= 0) EndLine();
            }
        }
        while (true)
        {
            var pending = stream.ReadAsync(chunk).AsTask();
            if (await Task.WhenAny(pending, abandoned).ConfigureAwait(false) != pending) { _ = pending.ContinueWith(task => task.Exception, TaskScheduler.Default); break; }
            var read = await pending.ConfigureAwait(false);
            if (read <= 0) break;
            if (partial is null) kept.Write(chunk, 0, read);
            else Take(read);
        }
        if (partial is not null && line.Length > 0 && !decided) Decide(true);
        var bytes = new ReadOnlyMemory<byte>(kept.GetBuffer(), 0, (int)kept.Length);
        return partial is null && bytes.Span.StartsWith(Bom) ? bytes[3..] : bytes;
    }
}
