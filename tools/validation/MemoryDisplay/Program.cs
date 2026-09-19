using RooIndustries.OptimizationSuite.Models;

const long gb = 1L << 30;
(long? total, long? available, int? expected, string name)[] cases =
[
    (32 * gb, 24 * gb, 25, "Physical capacity determines RAM use"),
    (16 * gb, 4 * gb, 75, "Partially used RAM"),
    (32 * gb, 0, 100, "Zero available RAM is a valid full reading"),
    (32 * gb, 32 * gb, 0, "All RAM available"),
    (null, 24 * gb, null, "Missing capacity stays unavailable"),
    (32 * gb, null, null, "Missing available memory stays unavailable"),
    (0, 0, null, "Zero capacity stays unavailable"),
    (-1, 0, null, "Negative capacity stays unavailable"),
    (32 * gb, -1, null, "Negative available memory stays unavailable"),
    (32 * gb, 33 * gb, null, "Conflicting readings stay unavailable"),
    (long.MaxValue, 0, 100, "Large readings do not overflow"),
];
foreach (var (total, available, expected, name) in cases)
{
    var actual = MemoryUsage.UsedPercent(total, available);
    if (actual != expected) throw new InvalidOperationException($"{name}: expected {expected}, got {actual}");
    Console.WriteLine("PASS " + name);
}

var jsonOptions = RooIndustries.OptimizationSuite.Services.JsonTolerance.CreateOptions();
(string json, int? expected, string name)[] payloads =
[
    ("{\"availableMemoryBytes\":25769803776,\"commitUsedBytes\":68719476736}", 25, "Commit is independent of physical RAM"),
    ("{\"availableMemoryBytes\":0}", 100, "Explicit zero survives deserialization"),
    ("{}", null, "Missing field stays unavailable"),
    ("{\"availableMemoryBytes\":null}", null, "Null field stays unavailable"),
    ("{\"availableMemoryBytes\":\"unknown\"}", null, "Invalid string stays unavailable"),
    ("{\"availableMemoryBytes\":\"25769803776\"}", 25, "Numeric string remains supported"),
    ("{\"availableMemoryBytes\":-1}", null, "Negative field stays unavailable"),
    ("{\"availableMemoryBytes\":9223372036854775808}", null, "Out-of-range field stays unavailable"),
    ("{\"availableMemoryBytes\":true}", null, "Wrong field type stays unavailable"),
];
foreach (var (json, expected, name) in payloads)
{
    var summary = System.Text.Json.JsonSerializer.Deserialize<ProcessInventorySummary>(json, jsonOptions)!;
    var actual = MemoryUsage.UsedPercent(32 * gb, summary.AvailableMemoryBytes);
    if (actual != expected) throw new InvalidOperationException($"{name}: expected {expected}, got {actual}");
    Console.WriteLine("PASS " + name);
}
