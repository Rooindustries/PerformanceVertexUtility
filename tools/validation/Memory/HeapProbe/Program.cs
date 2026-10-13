using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text.Json;
using Microsoft.Diagnostics.Runtime;

var pid = int.Parse(args[0]);
var output = args[1];
var dac = args[2];
var clock = Stopwatch.StartNew();
using var process = Process.GetProcessById(pid);
process.Refresh();
var privateBytes = process.PrivateMemorySize64;
var workingSetBytes = process.WorkingSet64;
using var target = DataTarget.AttachToProcess(pid, suspend: true);
using var runtime = target.ClrVersions[0].CreateRuntime(dac);
var heap = runtime.Heap;
if (!heap.CanWalkHeap) throw new InvalidOperationException("GC structures are not currently walkable.");
var all = new Dictionary<string, TypeCount>();
var retained = new Dictionary<string, TypeCount>();
ulong allocatedBytes = 0;
ulong freeBytes = 0;
var objects = 0;
foreach (var obj in heap.EnumerateObjects())
{
    if (!obj.IsValid) throw new InvalidOperationException("Heap contains an unreadable object.");
    if (obj.IsFree) { freeBytes += obj.Size; continue; }
    allocatedBytes += obj.Size;
    objects++;
    Add(all, obj);
}
var seen = new HashSet<ulong>();
var queue = new Queue<ulong>();
var roots = 0;
foreach (var root in heap.EnumerateRoots())
{
    roots++;
    if (root.Object.Address != 0 && seen.Add(root.Object.Address)) queue.Enqueue(root.Object.Address);
}
ulong retainedBytes = 0;
while (queue.TryDequeue(out var address))
{
    if (clock.Elapsed.TotalSeconds > 70) throw new TimeoutException("Heap reference walk exceeded seventy seconds.");
    var obj = heap.GetObject(address);
    if (!obj.IsValid || obj.IsFree) continue;
    retainedBytes += obj.Size;
    Add(retained, obj);
    foreach (var child in obj.EnumerateReferences(carefully: true, considerDependantHandles: true))
        if (child.Address != 0 && seen.Add(child.Address)) queue.Enqueue(child.Address);
}
var segments = heap.Segments.Select(s => new
{
    kind = s.Kind.ToString(),
    objectRangeBytes = s.Length,
    committedBytes = s.CommittedMemory.Length,
    reservedBytes = s.ReservedMemory.Length
}).ToArray();
var committed = segments.Aggregate(0UL, (sum, s) => sum + s.committedBytes);
var native = Native.Regions(process.Handle);
var nativePrivateCommitted = native.Where(r => r.type == "private").Sum(r => r.bytes);
var result = new
{
    nonce = Environment.GetEnvironmentVariable("ROO_HARNESS_NONCE") ?? throw new InvalidOperationException("A harness nonce is required."),
    pid,
    utc = DateTime.UtcNow,
    collector = "Microsoft.Diagnostics.Runtime 3.1.512801; live suspended attach; local installed DAC; no dump or forced GC",
    runtimeVersion = target.ClrVersions[0].Version.ToString(),
    heapCanWalk = heap.CanWalkHeap,
    serverGc = heap.IsServer,
    privateBytes,
    workingSetBytes,
    managedObjectBytes = allocatedBytes,
    managedRootReachableBytes = retainedBytes,
    managedFreeObjectBytes = freeBytes,
    managedHeapCommittedBytes = committed,
    estimatedPrivateBytesOutsideGcSegments = (long)privateBytes - (long)committed,
    nativePrivateCommittedBytes = nativePrivateCommitted,
    objectCount = objects,
    rootCount = roots,
    rootReachableObjectCount = seen.Count,
    segments,
    virtualMemoryRegions = native,
    topAllocatedTypes = all.Values.OrderByDescending(t => t.Bytes).Take(40),
    topRootReachableTypes = retained.Values.OrderByDescending(t => t.Bytes).Take(40),
    pageAndViewModelTypes = retained.Values.Where(t => t.Name.StartsWith("RooIndustries.OptimizationSuite.Views.") || t.Name.StartsWith("RooIndustries.OptimizationSuite.ViewModels.")).OrderByDescending(t => t.Bytes),
    elapsedSeconds = clock.Elapsed.TotalSeconds,
    limitations = "Outside-GC private bytes includes CLR loader/JIT and native allocations; it is not solely WinUI. Root reachability is conservative because stack roots may be conservative. Object values and strings were never copied or reported. No induced GC; allocated totals include currently unreachable objects."
};
using (var file = new FileStream(output, FileMode.CreateNew, FileAccess.Write, FileShare.None))
{
    JsonSerializer.Serialize(file, result, new JsonSerializerOptions { WriteIndented = true, PropertyNamingPolicy = JsonNamingPolicy.CamelCase });
}
Console.WriteLine($"Heap objects={objects} bytes={allocatedBytes} rootedBytes={retainedBytes} committed={committed} outsideGc={privateBytes-(long)committed} seconds={clock.Elapsed.TotalSeconds:F2}");

static void Add(Dictionary<string, TypeCount> counts, ClrObject obj)
{
    var name = obj.Type?.Name ?? "<unknown>";
    if (!counts.TryGetValue(name, out var count)) counts[name] = count = new TypeCount { Name = name };
    count.Count++;
    count.Bytes += obj.Size;
}

sealed class TypeCount
{
    public required string Name { get; init; }
    public long Count { get; set; }
    public ulong Bytes { get; set; }
}

static class Native
{
    [StructLayout(LayoutKind.Sequential)]
    struct MemoryInfo
    {
        public nint BaseAddress;
        public nint AllocationBase;
        public uint AllocationProtect;
        public ushort PartitionId;
        public nuint RegionSize;
        public uint State;
        public uint Protect;
        public uint Type;
    }
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern nuint VirtualQueryEx(nint process, nint address, out MemoryInfo buffer, nuint size);
    public sealed record Region(string type, string protection, long bytes, int regions);
    public static Region[] Regions(nint process)
    {
        var totals = new Dictionary<(uint Type, uint Protect), (long Bytes, int Regions)>();
        ulong address = 0;
        while (VirtualQueryEx(process, (nint)address, out var info, (nuint)Marshal.SizeOf<MemoryInfo>()) != 0)
        {
            if (info.State == 0x1000)
            {
                var key = (info.Type, info.Protect);
                var previous = totals.GetValueOrDefault(key);
                totals[key] = (previous.Bytes + (long)info.RegionSize, previous.Regions + 1);
            }
            var next = (ulong)info.BaseAddress + (ulong)info.RegionSize;
            if (next <= address) break;
            address = next;
        }
        return totals.Select(t => new Region(t.Key.Type switch { 0x20000 => "private", 0x40000 => "mapped", 0x1000000 => "image", _ => "0x" + t.Key.Type.ToString("X") }, "0x" + t.Key.Protect.ToString("X"), t.Value.Bytes, t.Value.Regions)).OrderByDescending(r => r.bytes).ToArray();
    }
}
