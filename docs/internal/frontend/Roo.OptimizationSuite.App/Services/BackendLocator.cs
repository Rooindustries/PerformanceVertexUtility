using System;
using System.IO;

namespace Roo.OptimizationSuite.Services;

public sealed class BackendLocator
{
    public string? RepoRoot { get; }
    public string? SamplesDirectory => RepoRoot is null ? null : Path.Combine(RepoRoot, "backend", "samples");
    public string? CatalogsDirectory => RepoRoot is null ? null : Path.Combine(RepoRoot, "backend", "catalogs");
    public string? ScriptsDirectory => RepoRoot is null ? null : Path.Combine(RepoRoot, "backend", "scripts");
    public string? BrandDirectory => RepoRoot is null ? null : Path.Combine(RepoRoot, "assets", "brand", "roo-industries");

    public BackendLocator()
    {
        RepoRoot = ResolveRepoRoot();
    }

    public bool SamplesAvailable => SamplesDirectory is not null && Directory.Exists(SamplesDirectory);
    public bool ScriptsAvailable => ScriptsDirectory is not null && Directory.Exists(ScriptsDirectory);

    private static string? ResolveRepoRoot()
    {
        var overrideRoot = Environment.GetEnvironmentVariable("ROO_BACKEND_ROOT");
        if (!string.IsNullOrWhiteSpace(overrideRoot) && IsRepoRoot(overrideRoot))
        {
            return overrideRoot;
        }

        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir is not null)
        {
            if (IsRepoRoot(dir.FullName))
            {
                return dir.FullName;
            }

            dir = dir.Parent;
        }

        return null;
    }

    private static bool IsRepoRoot(string path)
    {
        return Directory.Exists(Path.Combine(path, "backend", "samples"));
    }
}
