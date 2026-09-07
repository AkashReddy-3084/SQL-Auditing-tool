using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text.RegularExpressions;

namespace SqlAuditor.Reporting;

/// <summary>Database identity used across the workbook (DB001, DB002, ...).</summary>
public sealed record WorkbookDatabase(string Id, string Name);

/// <summary>Severity-derived risk attributes. Severity itself is never recalculated here.</summary>
public sealed record SeverityProfile(int RiskScore, string Likelihood, string Impact, string Sla, int? SlaDays);

/// <summary>One row of the Findings / Risk Register sheets.</summary>
public sealed class WorkbookFinding
{
    public required string RiskId { get; init; }
    public required ChecklistItemResult Item { get; init; }
    public required string AuditPhase { get; init; }
    public required string Scope { get; init; }
    public required IReadOnlyList<WorkbookDatabase> ImpactedDatabases { get; init; }
    public required IReadOnlyList<WorkbookDatabase> NonImpactedDatabases { get; init; }
    public required SeverityProfile Severity { get; init; }
    public string Status => "Open";
}

/// <summary>A control that could not be assessed because evidence collection failed.</summary>
public sealed class WorkbookAccessIssue
{
    public required ChecklistItemResult Item { get; init; }
    public required string FailureType { get; init; }
    public required string Detail { get; init; }
}

/// <summary>Coverage tallies shown on the Summary sheet.</summary>
public sealed class WorkbookCoverage
{
    public int Deterministic { get; init; }
    public int AiAssisted { get; init; }
    public int ManualAttestation { get; init; }
    public int NeedsReview { get; init; }
    public int AwaitingValidation { get; init; }
    public int NotApplicable { get; init; }
    public int Total { get; init; }
    public double? DeterministicCoverage =>
        Total == 0 ? null : (double)Deterministic / Total;
}

/// <summary>
/// The single source of truth for every generated artifact. The workbook is rendered directly
/// from this model, and the Markdown/HTML documents are rendered from the same instance so all
/// five outputs always agree.
/// </summary>
public sealed class AuditWorkbookModel
{
    public required string Target { get; init; }
    public required string GeneratedDate { get; init; }
    public required ReportMetadata Metadata { get; init; }
    public required ChecklistCatalog Catalog { get; init; }
    public required IReadOnlyList<ChecklistItemResult> Items { get; init; }
    public required IReadOnlyList<AreaScore> Areas { get; init; }
    public required IReadOnlyList<WorkbookDatabase> Databases { get; init; }
    public required IReadOnlyList<WorkbookFinding> Findings { get; init; }
    public required IReadOnlyList<WorkbookAccessIssue> AccessIssues { get; init; }
    public required WorkbookCoverage Coverage { get; init; }
    public double? OverallScore { get; init; }
    public required RiskRating OverallRating { get; init; }

    /// <summary>Not captured by the evaluation engine; surfaced as N/A rather than guessed.</summary>
    public string DeploymentMode => AuditWorkbookBuilder.NotAvailable;

    public string CategoryLabel(string categoryId)
    {
        var name = Catalog.CategoryName(categoryId);
        return string.Equals(name, categoryId, StringComparison.OrdinalIgnoreCase)
            ? categoryId
            : $"{categoryId} {name}";
    }

    public string AreaName(int number) => Catalog.AreaName(number);

    public IReadOnlyList<ChecklistItemResult> ItemsForDatabase(WorkbookDatabase database) =>
        Items.Where(i => AuditWorkbookBuilder.DatabasesOf(i).Contains(database.Name, StringComparer.OrdinalIgnoreCase))
             .OrderBy(i => i.Id, ChecklistIdComparer.Instance)
             .ToList();

    public static string Status(ChecklistItemResult item)
    {
        if (item.IsNotApplicable) return "Na";
        if (item.IsSkipped) return "Awaiting validation";
        var outcome = item.Outcome?.Trim();
        if (string.Equals(outcome, "NeedsReview", StringComparison.OrdinalIgnoreCase)
            || string.Equals(outcome, "Needs Review", StringComparison.OrdinalIgnoreCase))
            return "Needs review";
        return "Scored";
    }

    public static string ProducedBy(ChecklistItemResult item)
    {
        var technique = item.Technique ?? string.Empty;
        if (technique.Contains("Script", StringComparison.OrdinalIgnoreCase)) return "Deterministic";
        if (technique.Contains("Manual", StringComparison.OrdinalIgnoreCase)) return "Manual attestation";
        if (technique.Contains("MCP", StringComparison.OrdinalIgnoreCase)
            || technique.Contains("AI", StringComparison.OrdinalIgnoreCase)) return "AI analysis";
        return AuditWorkbookBuilder.NotAvailable;
    }
}

/// <summary>Orders checklist ids numerically (1.2.10 after 1.2.9) instead of lexically.</summary>
public sealed class ChecklistIdComparer : IComparer<string>
{
    public static readonly ChecklistIdComparer Instance = new();

    public int Compare(string? x, string? y)
    {
        var left = Parse(x);
        var right = Parse(y);
        for (var i = 0; i < Math.Max(left.Length, right.Length); i++)
        {
            var a = i < left.Length ? left[i] : -1;
            var b = i < right.Length ? right[i] : -1;
            if (a != b) return a.CompareTo(b);
        }
        return string.Compare(x, y, StringComparison.OrdinalIgnoreCase);
    }

    private static int[] Parse(string? id) =>
        string.IsNullOrWhiteSpace(id)
            ? Array.Empty<int>()
            : id.Split('.').Select(p => int.TryParse(p, out var n) ? n : 0).ToArray();
}

/// <summary>
/// Builds <see cref="AuditWorkbookModel"/> from a persisted <c>checklist_results.json</c>.
/// Enrichment, scoring, weighting and risk ratings all run through the existing
/// <see cref="ReportInputEnricher"/> and <see cref="ScoreCalculator"/>, so no scored value changes.
/// </summary>
public static class AuditWorkbookBuilder
{
    public const string NotAvailable = "N/A";
    public const string NoValue = "—";
    public const string InstanceScope = "Instance / cross-database";

    // Tokens that name an evaluation scope rather than a real user database.
    private static readonly string[] NonDatabaseTokens = { "SERVER", "INSTANCE", "N/A", "NONE", "ALL" };

    private static readonly Regex RunDirectoryPrefix = new(
        @"^\d{8}_\d{6}_\d{3}_", RegexOptions.CultureInvariant);

    public static AuditWorkbookModel Build(
        string resultsJsonPath,
        string outputDirectory,
        ReportMetadata metadata)
    {
        var items = new ReportInputEnricher()
            .Enrich(ChecklistResultsLoader.Load(resultsJsonPath))
            .OrderBy(i => i.Id, ChecklistIdComparer.Instance)
            .ToList();

        var calculator = new ScoreCalculator();
        var areas = calculator.ComputeAreaScores(items);
        var overall = calculator.ComputeOverallScore(areas);

        var databases = BuildInventory(items);
        var findings = BuildFindings(items, databases);

        return new AuditWorkbookModel
        {
            Target = ResolveTarget(outputDirectory),
            GeneratedDate = metadata.ReportDate,
            Metadata = metadata,
            Catalog = ChecklistCatalog.Discover(Path.GetDirectoryName(Path.GetFullPath(resultsJsonPath))),
            Items = items,
            Areas = areas,
            Databases = databases,
            Findings = findings,
            AccessIssues = BuildAccessIssues(items),
            Coverage = BuildCoverage(items),
            OverallScore = overall,
            OverallRating = calculator.GetRiskRating(overall),
        };
    }

    /// <summary>The audited target, taken from the timestamped run directory name.</summary>
    private static string ResolveTarget(string outputDirectory)
    {
        var name = new DirectoryInfo(Path.GetFullPath(outputDirectory)).Name;
        var target = RunDirectoryPrefix.Replace(name, string.Empty);
        return string.IsNullOrWhiteSpace(target) ? NotAvailable : target;
    }

    /// <summary>Database names recorded against a control, excluding instance-scope tokens.</summary>
    public static IReadOnlyList<string> DatabasesOf(ChecklistItemResult item)
    {
        if (string.IsNullOrWhiteSpace(item.DatabasesVerified)) return Array.Empty<string>();

        return item.DatabasesVerified
            .Split(new[] { ';', ',', '\n', '\r' }, StringSplitOptions.RemoveEmptyEntries)
            .Select(part => part.Trim())
            .Where(part => part.Length > 0)
            .Where(part => !NonDatabaseTokens.Contains(part, StringComparer.OrdinalIgnoreCase))
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToList();
    }

    private static IReadOnlyList<WorkbookDatabase> BuildInventory(IEnumerable<ChecklistItemResult> items)
    {
        var names = items
            .SelectMany(DatabasesOf)
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .OrderBy(name => name, StringComparer.OrdinalIgnoreCase)
            .ToList();

        return names
            .Select((name, index) => new WorkbookDatabase($"DB{index + 1:000}", name))
            .ToList();
    }

    /// <summary>
    /// Active risk filter, unchanged from the previous workbook: a failed control, a
    /// Critical/High/Medium severity, or any score below 3. Not Applicable controls are excluded.
    /// </summary>
    public static bool IsActiveRisk(ChecklistItemResult item)
    {
        if (item.IsNotApplicable) return false;
        if (string.Equals(item.Outcome?.Trim(), "Fail", StringComparison.OrdinalIgnoreCase)) return true;
        if (item.Severity is not null)
        {
            var severity = item.Severity.Trim();
            if (severity.Equals("Critical", StringComparison.OrdinalIgnoreCase)
                || severity.Equals("High", StringComparison.OrdinalIgnoreCase)
                || severity.Equals("Medium", StringComparison.OrdinalIgnoreCase))
                return true;
        }
        return item.Score.HasValue && item.Score.Value < 3;
    }

    public static int SeverityRank(string? severity) => severity?.Trim().ToLowerInvariant() switch
    {
        "critical" => 5,
        "high" => 4,
        "medium" => 3,
        "low" => 2,
        "informational" => 1,
        _ => 0,
    };

    /// <summary>Risk score, likelihood, impact and SLA follow the rubric's severity bands.</summary>
    public static SeverityProfile ProfileFor(string? severity) => severity?.Trim().ToLowerInvariant() switch
    {
        "critical" => new SeverityProfile(9, "Likely", "Major", "0–7 days", 7),
        "high" => new SeverityProfile(7, "Likely", "Major", "30 days", 30),
        "medium" => new SeverityProfile(5, "Possible", "Moderate", "90 days", 90),
        "low" => new SeverityProfile(3, "Unlikely", "Minor", "Next planning cycle", null),
        _ => new SeverityProfile(0, "Unlikely", "Minor", "No SLA", null),
    };

    private static IReadOnlyList<WorkbookFinding> BuildFindings(
        IReadOnlyList<ChecklistItemResult> items,
        IReadOnlyList<WorkbookDatabase> databases)
    {
        var ordered = items
            .Where(IsActiveRisk)
            .OrderByDescending(i => SeverityRank(i.Severity))
            .ThenBy(i => i.Id, ChecklistIdComparer.Instance)
            .ToList();

        var findings = new List<WorkbookFinding>(ordered.Count);
        for (var index = 0; index < ordered.Count; index++)
        {
            var item = ordered[index];
            var names = DatabasesOf(item);
            var impacted = databases.Where(d => names.Contains(d.Name, StringComparer.OrdinalIgnoreCase)).ToList();
            var nonImpacted = impacted.Count == 0
                ? new List<WorkbookDatabase>()
                : databases.Except(impacted).ToList();

            findings.Add(new WorkbookFinding
            {
                RiskId = $"R-{index + 1:000}",
                Item = item,
                AuditPhase = AuditWorkbookModel.ProducedBy(item) == "Manual attestation"
                    ? "Manual review"
                    : "Automated assessment",
                Scope = impacted.Count > 0 ? "Database" : InstanceScope,
                ImpactedDatabases = impacted,
                NonImpactedDatabases = nonImpacted,
                Severity = ProfileFor(item.Severity),
            });
        }
        return findings;
    }

    private static IReadOnlyList<WorkbookAccessIssue> BuildAccessIssues(IReadOnlyList<ChecklistItemResult> items) =>
        items
            .Where(i => i.IsSkipped)
            .OrderBy(i => i.Id, ChecklistIdComparer.Instance)
            .Select(i => new WorkbookAccessIssue
            {
                Item = i,
                FailureType = "Evaluation deferred",
                Detail = string.IsNullOrWhiteSpace(i.Evidence) ? NotAvailable : i.Evidence.Trim(),
            })
            .ToList();

    private static WorkbookCoverage BuildCoverage(IReadOnlyList<ChecklistItemResult> items)
    {
        var scored = items.Where(i => i.IsScored).ToList();
        return new WorkbookCoverage
        {
            Total = items.Count,
            Deterministic = scored.Count(i => AuditWorkbookModel.ProducedBy(i) == "Deterministic"),
            AiAssisted = scored.Count(i => AuditWorkbookModel.ProducedBy(i) == "AI analysis"),
            ManualAttestation = scored.Count(i => AuditWorkbookModel.ProducedBy(i) == "Manual attestation"),
            NeedsReview = items.Count(i => AuditWorkbookModel.Status(i) == "Needs review"),
            AwaitingValidation = items.Count(i => i.IsSkipped),
            NotApplicable = items.Count(i => i.IsNotApplicable),
        };
    }

    public static string Text(string? value) =>
        string.IsNullOrWhiteSpace(value) ? NotAvailable : value.Trim();

    public static string DatabaseList(IReadOnlyList<WorkbookDatabase> databases, string emptyText) =>
        databases.Count == 0 ? emptyText : string.Join(" ", databases.Select(d => d.Id));

    public static double? Fraction(double? percent) => percent.HasValue ? percent.Value / 100.0 : null;

    public static string Percent(double? percent) =>
        percent.HasValue ? percent.Value.ToString("0.0", CultureInfo.InvariantCulture) + "%" : NotAvailable;
}
