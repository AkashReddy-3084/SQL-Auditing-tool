using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Threading;
using System.Threading.Tasks;

namespace SQLAuditor.Lib;

/// <summary>
/// Attaches evidence to the active run: resolves the sources, indexes them, persists the manifest
/// next to the results, and renders the summary the AI layer reads.
/// </summary>
public static class EvidenceStore
{
    public const string ManifestFileName = "evidence-manifest.json";

    private static readonly JsonSerializerOptions Json = new()
    {
        WriteIndented = true,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
    };

    public static async Task<EvidenceContext> AttachAsync(
        IEnumerable<string>? localPaths,
        string? gitUrl,
        string? gitRef,
        IEnumerable<string>? files,
        CancellationToken cancellationToken = default)
    {
        var sources = await EvidenceWorkspace.ResolveAsync(localPaths, gitUrl, gitRef, files, cancellationToken);
        var manifest = await EvidenceIndexer.BuildAsync(sources, cancellationToken);
        var context = new EvidenceContext { Sources = sources, Manifest = manifest };

        Save(context);
        return context;
    }

    public static void Save(EvidenceContext context)
    {
        try
        {
            var dir = AuditOutputPaths.CurrentRunDirectory;
            Directory.CreateDirectory(dir);
            File.WriteAllText(Path.Combine(dir, ManifestFileName), JsonSerializer.Serialize(context, Json));
        }
        catch { }
    }

    public static EvidenceContext? Load()
    {
        try
        {
            var path = Path.Combine(AuditOutputPaths.CurrentRunDirectory, ManifestFileName);
            if (!File.Exists(path)) return null;
            return JsonSerializer.Deserialize<EvidenceContext>(File.ReadAllText(path), Json);
        }
        catch { return null; }
    }

    /// <summary>Human- and AI-readable summary of what was attached and what is inside it.</summary>
    public static string Describe(EvidenceContext context)
    {
        var sb = new StringBuilder();
        sb.AppendLine("EVIDENCE SOURCES");

        foreach (var source in context.Sources)
        {
            sb.Append("- ").Append(source.Label).Append(" [").Append(source.Kind).Append("] ");
            if (!source.IsResolved)
            {
                sb.Append("UNRESOLVED: ").AppendLine(source.Error);
                continue;
            }

            sb.Append("-> ").Append(source.ResolvedPath);
            if (!string.IsNullOrWhiteSpace(source.GitRef)) sb.Append(" @ ").Append(source.GitRef);
            if (!string.IsNullOrWhiteSpace(source.GitCommit)) sb.Append(" (").Append(source.GitCommit[..Math.Min(8, source.GitCommit.Length)]).Append(')');
            sb.AppendLine();
        }

        if (context.Sources.All(s => !s.IsResolved))
        {
            sb.AppendLine();
            sb.AppendLine("No source resolved, so there is no evidence to review. Ask the user to correct the location.");
            return sb.ToString().TrimEnd();
        }

        sb.AppendLine();
        sb.Append("INDEXED FILES: ").AppendLine(context.Manifest.Files.Count.ToString());
        foreach (var pair in context.Manifest.CountsByCategory.OrderByDescending(p => p.Value))
            sb.Append("- ").Append(pair.Key).Append(": ").AppendLine(pair.Value.ToString());

        var highlights = context.Manifest.Files
            .Where(f => f.Category is EvidenceCategory.Pipeline or EvidenceCategory.Documentation or EvidenceCategory.Policy or EvidenceCategory.Iac)
            .OrderBy(f => f.Path.Count(c => c == '/'))
            .ThenBy(f => f.Path, StringComparer.OrdinalIgnoreCase)
            .Take(60)
            .ToList();
        if (highlights.Count > 0)
        {
            sb.AppendLine();
            sb.AppendLine("KEY FILES");
            foreach (var file in highlights)
                sb.Append("- ").Append(file.Path).Append("  (").Append(file.Category).AppendLine(")");
        }

        foreach (var git in context.Manifest.GitSignals)
        {
            sb.AppendLine();
            sb.Append("GIT SIGNALS for ").AppendLine(git.SourceLabel);
            sb.Append("- current branch: ").AppendLine(git.CurrentBranch ?? "(unknown)");
            if (git.Branches.Count > 0)
                sb.Append("- branches: ").AppendLine(string.Join(", ", git.Branches.Take(20)));
            sb.Append("- commits inspected: ").Append(git.CommitsInspected)
              .Append(" | merge commits: ").Append(git.MergeCommits)
              .Append(" | referencing a work item: ").AppendLine(git.CommitsReferencingWorkItems.ToString());
            sb.Append("- CODEOWNERS: ").Append(git.HasCodeOwners)
              .Append(" | PR template: ").Append(git.HasPullRequestTemplate)
              .Append(" | secret-scanning config: ").AppendLine(git.HasSecretScanningConfig.ToString());
            if (git.RecentCommitSubjects.Count > 0)
            {
                sb.AppendLine("- recent commit subjects:");
                foreach (var subject in git.RecentCommitSubjects.Take(15))
                    sb.Append("    ").AppendLine(subject);
            }
        }

        foreach (var warning in context.Manifest.Warnings)
            sb.Append("\nWARNING: ").AppendLine(warning);

        return sb.ToString().TrimEnd();
    }
}
