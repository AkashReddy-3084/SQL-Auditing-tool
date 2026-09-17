using System;
using System.Collections.Generic;
using System.Linq;

namespace SQLAuditor.Lib;

/// <summary>
/// Picks the evidence files most likely to answer one checklist item. Ranking is deterministic and
/// keyword-based so the same run always feeds the AI layer the same candidates.
/// </summary>
public static class EvidenceRelevanceSelector
{
    private static readonly char[] Separators = { ' ', '\t', '\n', '\r', '/', '\\', '.', '-', '_', '(', ')', ',', ';', ':', '"', '\'' };

    private static readonly HashSet<string> StopWords = new(StringComparer.OrdinalIgnoreCase)
    {
        "the", "and", "for", "with", "are", "is", "of", "to", "in", "on", "or", "a", "an", "be",
        "that", "this", "per", "not", "no", "where", "when", "has", "have", "its", "it", "by",
        "exists", "defined", "documented", "appropriate", "required", "applicable",
    };

    // Category weighting keeps a checklist item's own subject area at the top of the candidate list.
    private static readonly Dictionary<EvidenceCategory, string[]> CategoryKeywords = new()
    {
        [EvidenceCategory.Pipeline] = new[] { "pipeline", "deploy", "deployment", "build", "release", "ci", "cd", "rollback", "promotion", "stage", "approval" },
        [EvidenceCategory.Migration] = new[] { "migration", "schema", "dacpac", "version", "source", "control", "change" },
        [EvidenceCategory.SqlProject] = new[] { "schema", "procedure", "script", "index", "table", "query" },
        [EvidenceCategory.Documentation] = new[] { "document", "documentation", "runbook", "architecture", "diagram", "glossary", "onboarding", "procedure", "escalation", "lineage", "mapping", "policy", "strategy", "ownership", "steward" },
        [EvidenceCategory.Policy] = new[] { "policy", "agreement", "compliance", "retention", "regulation", "approval", "dpa", "standard" },
        [EvidenceCategory.Config] = new[] { "config", "configuration", "secret", "connection", "environment", "parity", "variable", "setting" },
        [EvidenceCategory.Iac] = new[] { "infrastructure", "environment", "tier", "provision", "topology", "capacity", "network", "backup", "zone" },
        [EvidenceCategory.Test] = new[] { "test", "testing", "validation", "regression", "performance", "quality" },
    };

    public static IReadOnlyList<EvidenceFileEntry> SelectFor(
        EvidenceManifest manifest,
        string itemDescription,
        string itemCategory,
        int maxFiles = 12)
    {
        if (manifest.Files.Count == 0) return Array.Empty<EvidenceFileEntry>();

        var terms = Tokenize(itemDescription + " " + itemCategory);
        if (terms.Count == 0) return Array.Empty<EvidenceFileEntry>();

        return manifest.Files
            .Where(f => EvidenceTextExtractor.IsExtractable(f.AbsolutePath))
            .Select(f => (File: f, Score: Score(f, terms)))
            .Where(x => x.Score > 0)
            .OrderByDescending(x => x.Score)
            .ThenBy(x => x.File.Path.Count(c => c == '/'))
            .ThenBy(x => x.File.Path, StringComparer.OrdinalIgnoreCase)
            .Take(maxFiles)
            .Select(x => x.File)
            .ToList();
    }

    private static int Score(EvidenceFileEntry file, HashSet<string> terms)
    {
        var score = 0;
        var pathTokens = Tokenize(file.Path);

        foreach (var token in pathTokens)
        {
            if (terms.Contains(token)) score += 6;
        }

        if (CategoryKeywords.TryGetValue(file.Category, out var keywords))
        {
            if (keywords.Any(terms.Contains)) score += 8;
        }

        // A top-level README or an architecture doc is worth considering for almost any
        // documentation item, even when its filename shares no term with the description.
        if (file.Category == EvidenceCategory.Documentation && file.Path.Count(c => c == '/') <= 2) score += 2;
        if (file.Category == EvidenceCategory.Pipeline) score += 1;

        return score;
    }

    private static HashSet<string> Tokenize(string? text)
    {
        var set = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        if (string.IsNullOrWhiteSpace(text)) return set;

        foreach (var raw in text.Split(Separators, StringSplitOptions.RemoveEmptyEntries))
        {
            var token = raw.Trim().ToLowerInvariant();
            if (token.Length < 3 || StopWords.Contains(token)) continue;
            set.Add(token);
            // Crude singularisation so "pipelines" matches "pipeline".
            if (token.Length > 4 && token.EndsWith("s", StringComparison.Ordinal))
                set.Add(token[..^1]);
        }

        return set;
    }
}
