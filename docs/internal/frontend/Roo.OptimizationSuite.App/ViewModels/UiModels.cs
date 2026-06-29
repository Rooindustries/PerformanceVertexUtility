namespace Roo.OptimizationSuite.ViewModels;

public sealed record MetricTile(string Label, string Value, string? Caption);

public sealed record SafetyRow(string Label, string Value, string State);

public sealed record StatusLine(string Label, string Value, string State);

public sealed record UsageLine(string Name, string Detail, string Value);

public sealed record AppRow(string Name, string Role, string Cpu, string Ram);

public sealed record GameAppRow(string Name, string Role, string Priority, string Cpu, string Ram, string Plan, string PlanState);
