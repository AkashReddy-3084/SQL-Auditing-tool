using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json.Serialization;
using System.Threading;
using System.Threading.Tasks;

namespace SQLAuditor.Lib;

public enum EvidenceCategory
{
    Other,
    Pipeline,
    Documentation,
    SqlProject,
    Migration,
    Config,
    Iac,
    Test,
    Policy,
}

public sealed record EvidenceFileEntry
{
    /// <summary>Label of the source, then the path relative to that source's root.</summary>
    public string Path { get; init; } = string.Empty;

    public string AbsolutePath { get; init; } = string.Empty;

    public string SourceLabel { get; init; } = string.Empty;

    [JsonConverter(typeof(JsonStringEnumConverter))]
    public EvidenceCategory Category { get; init; }

    public long SizeBytes { get; init; }

    public DateTime LastModified { get; init; }
}

/// <summary>Repository facts that no single file states, read from local git metadata.</summary>
public sealed record EvidenceGitSignals
{
    public string SourceLabel { get; init; } = string.Empty;
    public string? CurrentBranch { get; init; }
    public IReadOnlyList<string> Branches { get; init; } = Array.Empty<string>();
    public IReadOnlyList<string> RecentCommitSubjects { get; init; } = Array.Empty<string>();
    public int CommitsInspected { get; init; }
    public int MergeCommits { get; init; }
    public int CommitsReferencingWorkItems { get; init; }
    public bool HasCodeOwners { get; init; }
    public bool HasPullRequestTemplate { get; init; }
    public bool HasSecretScanningConfig { get; init; }
}

public sealed record EvidenceManifest
{
    public static EvidenceManifest Empty { get; } = new();

    public DateTime GeneratedAt { get; init; } = DateTime.Now;

    public IReadOnlyList<EvidenceFileEntry> Files { get; init; } = Array.Empty<EvidenceFileEntry>();

    public IReadOnlyList<EvidenceGitSignals> GitSignals { get; init; } = Array.Empty<EvidenceGitSignals>();

    /// <summary>Set when a cap was hit, so a verdict is never drawn from a silently partial index.</summary>
    public IReadOnlyList<string> Warnings { get; init; } = Array.Empty<string>();

    public IReadOnlyDictionary<string, int> CountsByCategory =>
        Files.GroupBy(f => f.Category.ToString())
             .ToDictionary(g => g.Key, g => g.Count(), StringComparer.OrdinalIgnoreCase);
}

/// <summary>
/// Walks the resolved evidence sources and records what is there. It reads file names, sizes and
/// git metadata only; file contents are read on demand by <see cref="EvidenceTextExtractor"/>.
/// </summary>
public static class EvidenceIndexer
{
    public const int MaxFiles = 5000;
    public const long MaxIndexedFileBytes = 2 * 1024 * 1024;
    private const int MaxCommitsInspected = 100;

    private static readonly HashSet<string> SkippedDirectories = new(StringComparer.OrdinalIgnoreCase)
    {
        "node_modules", "bin", "obj", "packages", "dist", "build", "out", "target",
        ".vs", ".vscode", ".idea", "__pycache__", ".venv", "venv", ".terraform",
        "TestResults", "coverage", ".next", ".nuget",
    };

    private static readonly HashSet<string> BinaryExtensions = new(StringComparer.OrdinalIgnoreCase)
    {
        ".exe", ".dll", ".pdb", ".zip", ".7z", ".gz", ".tar", ".jpg", ".jpeg", ".png", ".gif",
        ".bmp", ".ico", ".mp4", ".mov", ".bak", ".dacpac", ".bacpac", ".nupkg", ".so", ".dylib",
    };

    public static async Task<EvidenceManifest> BuildAsync(
        IEnumerable<EvidenceSourceRecord> sources,
        CancellationToken cancellationToken = default)
    {
        var files = new List<EvidenceFileEntry>();
        var signals = new List<EvidenceGitSignals>();
        var warnings = new List<string>();

        foreach (var source in sources.Where(s => s.IsResolved))
        {
            cancellationToken.ThrowIfCancellationRequested();

            if (source.Kind == EvidenceSourceKind.File)
            {
                var info = new FileInfo(source.ResolvedPath);
                files.Add(Describe(source.Label, info.Name, info, source.Label));
                continue;
            }

            var truncated = IndexFolder(source, files, cancellationToken);
            if (truncated)
                warnings.Add($"Source '{source.Label}' was truncated at {MaxFiles} files; a verdict drawn from it may be incomplete.");

            var git = await ReadGitSignalsAsync(source, cancellationToken);
            if (git != null) signals.Add(git);
        }

        return new EvidenceManifest
        {
            Files = files,
            GitSignals = signals,
            Warnings = warnings,
        };
    }

    private static bool IndexFolder(EvidenceSourceRecord source, List<EvidenceFileEntry> files, CancellationToken cancellationToken)
    {
        var root = source.ResolvedPath;
        var pending = new Stack<string>();
        pending.Push(root);
        var added = 0;

        while (pending.Count > 0)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var current = pending.Pop();

            // This tool's own run output is not evidence about the platform under audit, and it
            // would otherwise crowd the real artefacts out of the index.
            if (IsAuditOutputDirectory(current)) continue;

            IEnumerable<string> children;
            try { children = Directory.EnumerateDirectories(current); }
            catch { continue; }

            foreach (var child in children)
            {
                var name = Path.GetFileName(child);
                if (SkippedDirectories.Contains(name)) continue;
                // .git is kept out of the file index; its metadata is read through git itself.
                if (string.Equals(name, ".git", StringComparison.OrdinalIgnoreCase)) continue;
                try
                {
                    if (new DirectoryInfo(child).LinkTarget != null) continue;
                }
                catch { continue; }
                pending.Push(child);
            }

            IEnumerable<string> entries;
            try { entries = Directory.EnumerateFiles(current); }
            catch { continue; }

            foreach (var file in entries)
            {
                if (added >= MaxFiles) return true;

                FileInfo info;
                try { info = new FileInfo(file); }
                catch { continue; }

                if (info.LinkTarget != null) continue;
                if (info.Length > MaxIndexedFileBytes) continue;
                if (BinaryExtensions.Contains(info.Extension)) continue;

                var relative = Path.GetRelativePath(root, file).Replace('\\', '/');
                files.Add(Describe(source.Label, relative, info, source.Label));
                added++;
            }
        }

        return false;
    }

    private static EvidenceFileEntry Describe(string sourceLabel, string relativePath, FileInfo info, string label)
        => new()
        {
            Path = $"{label}/{relativePath}",
            AbsolutePath = info.FullName,
            SourceLabel = sourceLabel,
            Category = Classify(relativePath),
            SizeBytes = info.Length,
            LastModified = info.LastWriteTime,
        };

    public static EvidenceCategory Classify(string relativePath)
    {
        var path = relativePath.Replace('\\', '/').ToLowerInvariant();
        var name = System.IO.Path.GetFileName(path);
        var ext = System.IO.Path.GetExtension(path);

        if (path.Contains(".github/workflows/") || path.Contains(".gitlab-ci")
            || name.StartsWith("azure-pipelines") || name == "jenkinsfile"
            || path.Contains("/pipelines/") || name.EndsWith("-pipeline.yml") || name.EndsWith("-pipeline.yaml"))
            return EvidenceCategory.Pipeline;

        if (ext is ".tf" or ".tfvars" or ".bicep" || name.EndsWith(".arm.json") || path.Contains("/infra/") || path.Contains("/iac/"))
            return EvidenceCategory.Iac;

        if (ext is ".sqlproj" || path.Contains("/migrations/") || path.Contains("/migration/")
            || path.Contains("/dbup/") || path.Contains("/flyway/") || path.Contains("/liquibase/"))
            return EvidenceCategory.Migration;

        if (ext is ".sql")
            return EvidenceCategory.SqlProject;

        if (path.Contains("/test/") || path.Contains("/tests/") || name.Contains(".test.") || name.Contains(".spec.")
            || name.EndsWith("tests.csproj") || path.Contains("/tsqlt/"))
            return EvidenceCategory.Test;

        if (ext is ".pdf" or ".docx" or ".xlsx" or ".pptx")
            return EvidenceCategory.Policy;

        if (ext is ".md" or ".rst" or ".adoc" or ".txt" || path.Contains("/docs/") || path.Contains("/documentation/")
            || path.Contains("/wiki/") || name.StartsWith("readme") || name.StartsWith("runbook"))
            return EvidenceCategory.Documentation;

        if (ext is ".json" or ".yml" or ".yaml" or ".xml" or ".config" or ".ini" or ".env" or ".props" or ".toml")
            return EvidenceCategory.Config;

        return EvidenceCategory.Other;
    }

    private static async Task<EvidenceGitSignals?> ReadGitSignalsAsync(EvidenceSourceRecord source, CancellationToken cancellationToken)
    {
        var root = source.ResolvedPath;
        if (!Directory.Exists(Path.Combine(root, ".git"))) return null;

        var branchResult = await EvidenceWorkspace.RunGitAsync(new[] { "rev-parse", "--abbrev-ref", "HEAD" }, root, cancellationToken);
        var branchList = await EvidenceWorkspace.RunGitAsync(new[] { "branch", "-a", "--format=%(refname:short)" }, root, cancellationToken);
        var log = await EvidenceWorkspace.RunGitAsync(
            new[] { "log", $"-{MaxCommitsInspected}", "--pretty=format:%p\u001f%s" }, root, cancellationToken);

        var commits = log.ExitCode == 0
            ? log.Output.Split('\n', StringSplitOptions.RemoveEmptyEntries)
            : Array.Empty<string>();

        var subjects = new List<string>();
        var merges = 0;
        var withWorkItems = 0;
        foreach (var line in commits)
        {
            var parts = line.Split('\u001f', 2);
            var parents = parts.Length > 0 ? parts[0].Trim() : string.Empty;
            var subject = parts.Length > 1 ? parts[1].Trim() : string.Empty;

            if (parents.Split(' ', StringSplitOptions.RemoveEmptyEntries).Length > 1) merges++;
            if (System.Text.RegularExpressions.Regex.IsMatch(subject, @"(#\d+|\bAB#\d+|\b[A-Z][A-Z0-9]+-\d+\b)"))
                withWorkItems++;
            if (subjects.Count < 30 && !string.IsNullOrWhiteSpace(subject))
                subjects.Add(SecretRedactor.Redact(subject));
        }

        return new EvidenceGitSignals
        {
            SourceLabel = source.Label,
            CurrentBranch = branchResult.ExitCode == 0 ? branchResult.Output.Trim() : null,
            Branches = branchList.ExitCode == 0
                ? branchList.Output.Split('\n', StringSplitOptions.RemoveEmptyEntries).Select(b => b.Trim()).Take(50).ToArray()
                : Array.Empty<string>(),
            RecentCommitSubjects = subjects,
            CommitsInspected = commits.Length,
            MergeCommits = merges,
            CommitsReferencingWorkItems = withWorkItems,
            HasCodeOwners = FileExistsAny(root, ".github/CODEOWNERS", "CODEOWNERS", "docs/CODEOWNERS"),
            HasPullRequestTemplate = FileExistsAny(root, ".github/pull_request_template.md", ".github/PULL_REQUEST_TEMPLATE.md", ".azuredevops/pull_request_template.md"),
            HasSecretScanningConfig = FileExistsAny(root, ".github/secret_scanning.yml", ".gitleaks.toml", ".gitleaksignore", ".github/workflows/secret-scan.yml"),
        };
    }

    private static bool FileExistsAny(string root, params string[] relativePaths)
        => relativePaths.Any(p => File.Exists(Path.Combine(root, p.Replace('/', Path.DirectorySeparatorChar))));

    private static bool IsAuditOutputDirectory(string directory)
        => File.Exists(Path.Combine(directory, "run-metadata.json"))
        || File.Exists(Path.Combine(directory, "checklist_results.json"));
}
