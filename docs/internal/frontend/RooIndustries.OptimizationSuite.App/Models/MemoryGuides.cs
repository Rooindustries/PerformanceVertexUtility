using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using RooIndustries.Optimizer;

namespace RooIndustries.OptimizationSuite.Models;

public sealed record MemoryGuide(string Id, string Title, string Summary, IReadOnlyList<string> Steps, string? Note = null)
{
    public IReadOnlyList<string> NumberedSteps => Steps.Select((step, index) => (index + 1) + ". " + step).ToArray();
    public string NoteText => Note ?? "";
}

public sealed record MemoryGuideSet(int SchemaVersion, string Title, string Intro, IReadOnlyList<MemoryGuide> Guides)
{
    private static MemoryGuideSet? _current;
    public static MemoryGuideSet Current => _current ??= Load();

    private static MemoryGuideSet Load()
    {
        using var stream = typeof(MemoryGuideSet).Assembly.GetManifestResourceStream("RooIndustries.MemoryGuides.json") ?? throw new FileNotFoundException("The memory guides are missing.");
        var set = JsonSerializer.Deserialize<MemoryGuideSet>(stream, OperationFiles.Json) ?? throw new InvalidDataException("The memory guides are incomplete.");
        if (set.SchemaVersion != 1 || set.Guides is not { Count: > 0 } || set.Guides.Any(guide => string.IsNullOrWhiteSpace(guide.Title) || guide.Steps is not { Count: > 0 }))
            throw new InvalidDataException("The memory guides are incomplete.");
        return set;
    }
}
