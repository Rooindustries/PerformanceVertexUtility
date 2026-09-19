namespace RooIndustries.OptimizationSuite.ViewModels;

public sealed record MetricTile(string Label, string Value, string? Caption);

public sealed record SafetyRow(string Label, string Value, string State);

public sealed record StatusLine(string Label, string Value, string State);

public sealed record UsageLine(string Name, string Detail, string Value);

public sealed record AppRow(string Name, string Role, string Cpu, string Ram);

public sealed record GameAppRow(string Name, string Role, string Priority, string Cpu, string Ram, string Plan, string PlanState)
{
    public string PlanWithRam => Plan + " / " + Ram;
}

public sealed record AuditRow(
    string Time,
    string Action,
    string ActionState,
    string Target,
    string Change,
    string RestoreText,
    string RestoreState);

public sealed record DashboardCard(string? CardId, string Title, string PrimaryMetric, string Detail, string State);

public sealed record CleanupBackupLine(string Label, string Value, string State);

public sealed record GateRow(string Label, string Detail, string State);

public sealed record StutterToolRow(string OptimizationId, int Rank, string Title, string Why, string StateLine, string State, string ActionLabel, string Caption);

public sealed record FindingRow(string Title, string Detail, string Evidence, string State);

public sealed record NextActionRow(string ActionId, string Label, string Reason, string Risk, string Route);
