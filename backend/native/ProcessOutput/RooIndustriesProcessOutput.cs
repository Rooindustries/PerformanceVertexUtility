using System;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Threading.Tasks;

namespace RooIndustries.Optimization.ProcessOutput
{
    // Drain both pipes without accumulating unbounded vendor output in memory.
    public sealed class Capture : IDisposable
    {
        private sealed class Buffer
        {
            internal readonly StringBuilder Text = new StringBuilder();
            internal bool Truncated;
            internal string Error;
        }
        private readonly StreamReader output, error;
        private readonly Buffer outBuffer = new Buffer(), errorBuffer = new Buffer();
        private readonly Task outTask, errorTask;
        private readonly int limit;

        public Capture(Stream stdout, Stream stderr, int characterLimit)
            : this(new StreamReader(stdout, ConsoleEncoding()), new StreamReader(stderr, ConsoleEncoding()), characterLimit) { }

        private Capture(StreamReader stdout, StreamReader stderr, int characterLimit)
        {
            if (characterLimit < 1) throw new ArgumentOutOfRangeException("characterLimit");
            limit = characterLimit;
            output = stdout;
            error = stderr;
            outTask = Pump(output, outBuffer);
            errorTask = Pump(error, errorBuffer);
        }

        private static Encoding ConsoleEncoding()
        {
            try { return Console.OutputEncoding; }
            catch (IOException) { return Encoding.Default; }
        }

        private async Task Pump(StreamReader reader, Buffer buffer)
        {
            char[] chars = new char[4096];
            try
            {
                int count;
                while ((count = await reader.ReadAsync(chars, 0, chars.Length).ConfigureAwait(false)) != 0)
                {
                    lock (buffer)
                    {
                        int retained = Math.Min(count, limit - buffer.Text.Length);
                        if (retained > 0) buffer.Text.Append(chars, 0, retained);
                        if (retained != count) buffer.Truncated = true;
                    }
                }
            }
            catch (Exception ex) { lock (buffer) { buffer.Error = ex.Message; } }
        }

        public bool Complete(int timeoutMilliseconds)
        {
            if (!Task.WaitAll(new Task[] { outTask, errorTask }, timeoutMilliseconds)) return false;
            lock (outBuffer) lock (errorBuffer) return outBuffer.Error == null && errorBuffer.Error == null;
        }
        public string Stdout { get { lock (outBuffer) return outBuffer.Text.ToString(); } }
        public string Stderr { get { lock (errorBuffer) return errorBuffer.Text.ToString(); } }
        public bool Truncated { get { lock (outBuffer) lock (errorBuffer) return outBuffer.Truncated || errorBuffer.Truncated; } }
        public void Dispose() { output.Dispose(); error.Dispose(); }
    }
}
