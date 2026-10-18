using System;
using System.Collections.Generic;
using System.Globalization;
using System.Management;

public sealed class RooIndustriesHarnessProcessTrace : IDisposable
{
    public sealed class StartRecord
    {
        public string EventNonce, TraceNonce, ProcessName, TimeCreatedFileTimeUtc, ReceivedAtUtc;
        public int ProcessId, ParentProcessId;
    }
    readonly object gate = new object();
    readonly Queue<StartRecord> pending = new Queue<StartRecord>();
    readonly ManagementEventWatcher watcher;
    readonly string traceNonce;
    volatile bool stopping;
    volatile string error;
    public string Error { get { return error; } }
    public RooIndustriesHarnessProcessTrace(string traceNonce)
    {
        this.traceNonce = traceNonce;
        watcher = new ManagementEventWatcher(new ManagementScope("\\\\.\\root\\cimv2"),
            new WqlEventQuery("SELECT * FROM Win32_ProcessStartTrace"));
        watcher.EventArrived += Capture;
        watcher.Stopped += Stopped;
        try { watcher.Start(); }
        catch { watcher.Dispose(); throw; }
    }
    void Capture(object sender, EventArrivedEventArgs args)
    {
        try
        {
            var value = args.NewEvent;
            var record = new StartRecord {
                EventNonce = Guid.NewGuid().ToString("N"), TraceNonce = traceNonce,
                ProcessId = Convert.ToInt32(value["ProcessID"], CultureInfo.InvariantCulture),
                ParentProcessId = Convert.ToInt32(value["ParentProcessID"], CultureInfo.InvariantCulture),
                ProcessName = Convert.ToString(value["ProcessName"], CultureInfo.InvariantCulture),
                TimeCreatedFileTimeUtc = Convert.ToInt64(value["TIME_CREATED"], CultureInfo.InvariantCulture).ToString(CultureInfo.InvariantCulture),
                ReceivedAtUtc = DateTime.UtcNow.ToString("o")
            };
            lock (gate) pending.Enqueue(record);
        }
        catch (Exception failure) { error = failure.ToString(); }
    }
    void Stopped(object sender, StoppedEventArgs args)
    {
        if (!stopping) error = "Process-start subscription stopped: " + args.Status;
    }
    public StartRecord[] Pending() { lock (gate) return pending.ToArray(); }
    public void Acknowledge(int count)
    {
        lock (gate) { for (int index = 0; index < count; index++) pending.Dequeue(); }
    }
    public void Stop() { if (!stopping) { stopping = true; watcher.Stop(); } }
    public void Dispose() { Stop(); watcher.Dispose(); }
}
