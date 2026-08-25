using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace SqlAuditor.Reporting;

// =============================================================================
// MODELS
// =============================================================================

/// <summary>
/// Represents a single evaluated checklist item as persisted in
/// <c>checklist_results.json</c>.
/// </summary>
public sealed class ChecklistItemResult
{
    // ---- Fields currently emitted by the assessment engine ----------------
    public string Id { get; set; } = string.Empty;
    public string Description { get; set; } = string.Empty;
    public string Outcome { get; set; } = string.Empty;
    public string ScriptFile { get; set; } = string.Empty;
    public string Technique { get; set; } = string.Empty;

    // ---- Report enrichment fields (nullable — filled by enricher when absent)
    public int? Score { get; set; }
    public bool? NotApplicable { get; set; }
    public string? NotApplicableJustification { get; set; }
    public string? Severity { get; set; }
    public string? Finding { get; set; }
    public string? Recommendation { get; set; }
    public string? Effort { get; set; }
    public string? RiskImpact { get; set; }
    public double? ScoreImpact { get; set; }
    public string? Evidence { get; set; }

    // Persisted under the JSON key "Databases Verified" (note the space). Consumed
    // by the Excel report; the Markdown generator ignores it.
    [JsonPropertyName("Databases Verified")]
    public string? DatabasesVerified { get; set; }

    // ---- Derived helpers (not serialized) ---------------------------------
    [JsonIgnore]
    public int AreaNumber
    {
        get
        {
            var dot = Id.IndexOf('.');
            var head = dot >= 0 ? Id[..dot] : Id;
            return int.TryParse(head, out var n) ? n : 0;
        }
    }

    [JsonIgnore]
    public string CategoryId
    {
        get
        {
            var parts = Id.Split('.');
            return parts.Length >= 2 ? $"{parts[0]}.{parts[1]}" : Id;
        }
    }

    [JsonIgnore]
    public bool IsScored => !IsNotApplicable && Score.HasValue;

    /// <summary>
    /// The control does not exist to be assessed (Outcome "Not Applicable"). Such items are
    /// reported under "Items Not Applicable" and take no part in any score, whatever Score
    /// they carry.
    /// </summary>
    [JsonIgnore]
    public bool IsNotApplicable =>
        NotApplicable == true || SQLAuditor.Lib.NotApplicableEvidence.IsNotApplicableOutcome(Outcome);
}

/// <summary>Report-level metadata supplied by the WPF UI or defaults.</summary>
public sealed class ReportMetadata
{
    public string Client { get; set; } = "MLC";
    public string Solution { get; set; } = "SQL Server / Azure SQL Data Warehouse";
    public string AuditPeriodStart { get; set; } = "[Start Date]";
    public string AuditPeriodEnd { get; set; } = "[End Date]";
    public string ReportDate { get; set; } = DateTime.UtcNow.ToString("yyyy-MM-dd");
    public string Auditors { get; set; } = "[Name(s)]";
    public string ReportVersion { get; set; } = "1.0";
    public string Classification { get; set; } = "Confidential";
    public string Distribution { get; set; } = "[List of recipients]";
    public int TotalChecklistItems { get; set; } = 328;
    public List<ComplianceGroup> ComplianceGroups { get; set; } = new();
}

public sealed class ComplianceGroup
{
    public string Name { get; set; } = string.Empty;
    public double? ScorePercent { get; set; }
    public string KeyGaps { get; set; } = string.Empty;
}

/// <summary>Static definition of an audit area.</summary>
public sealed record AreaDefinition(int Number, string Name, double Weight, string RadarLabel);

/// <summary>Score for a single checklist category (rubric §2).</summary>
public sealed class CategoryScore
{
    public required string CategoryId { get; init; }
    public List<ChecklistItemResult> Items { get; init; } = new();
    public int ScoredCount => Items.Count(i => i.IsScored);
    public int ScoreSum => Items.Where(i => i.IsScored).Sum(i => i.Score!.Value);
    public int MaxScore => ScoredCount * 3;
    public double? ScorePercent => ScoredCount == 0 ? null : (double)ScoreSum / MaxScore * 100.0;
}

/// <summary>Aggregated scoring result for one of the 14 audit areas.</summary>
public sealed class AreaScore
{
    public required AreaDefinition Area { get; init; }
    public List<ChecklistItemResult> Items { get; init; } = new();
    public int ScoredCount => Items.Count(i => i.IsScored);
    public int NotApplicableCount => Items.Count(i => i.IsNotApplicable);

    public IReadOnlyList<CategoryScore> Categories =>
        Items
            .GroupBy(i => i.CategoryId)
            .OrderBy(g => g.Key, StringComparer.Ordinal)
            .Select(g => new CategoryScore { CategoryId = g.Key, Items = g.ToList() })
            .ToList();

    /// <summary>Area score = average of category scores (rubric §3).</summary>
    public double? ScorePercent
    {
        get
        {
            var scoredCategories = Categories
                .Where(c => c.ScorePercent.HasValue)
                .Select(c => c.ScorePercent!.Value)
                .ToList();
            return scoredCategories.Count == 0 ? null : scoredCategories.Average();
        }
    }

    public double? WeightedContribution =>
        ScorePercent is null ? null : ScorePercent.Value * Area.Weight / 100.0;
}

public readonly record struct RiskRating(string Icon, string Label);

// =============================================================================
// AREA CATALOG
// =============================================================================

public static class AreaCatalog
{
    public static readonly IReadOnlyList<AreaDefinition> Areas = new List<AreaDefinition>
    {
        new(1,  "Architecture & Design",              8,  "Architecture"),
        new(2,  "Data Integration & ETL",             10, "ETL"),
        new(3,  "T-SQL Code Quality",                 8,  "TSQL"),
        new(4,  "Data Modeling & Storage",            9,  "Modeling"),
        new(5,  "Data Quality Framework",             9,  "Quality"),
        new(6,  "Security & Access Control",          12, "Security"),
        new(7,  "Compliance & Regulatory",            7,  "Compliance"),
        new(8,  "Data Governance",                    4,  "Governance"),
        new(9,  "Reliability & Resilience",           6,  "Reliability"),
        new(10, "Monitoring & Observability",         5,  "Monitoring"),
        new(11, "DevOps & Deployment",                6,  "DevOps"),
        new(12, "Cost Management & Capacity",         4,  "CostMgmt"),
        new(13, "Documentation & Knowledge Mgmt",     3,  "Documentation"),
        new(14, "Performance & Query Tuning",         9,  "Performance"),
    };

    public static AreaDefinition Get(int number) =>
        Areas.FirstOrDefault(a => a.Number == number)
        ?? new AreaDefinition(number, $"Area {number}", 0, $"Area{number}");
}

// =============================================================================
// SCORE CALCULATOR
// =============================================================================

public sealed class ScoreCalculator
{
    public IReadOnlyList<AreaScore> ComputeAreaScores(IEnumerable<ChecklistItemResult> items)
    {
        var byArea = items.GroupBy(i => i.AreaNumber).ToDictionary(g => g.Key, g => g.ToList());
        return AreaCatalog.Areas
            .Select(def => new AreaScore
            {
                Area = def,
                Items = byArea.TryGetValue(def.Number, out var list) ? list : new List<ChecklistItemResult>()
            })
            .ToList();
    }

    /// <summary>Overall score per rubric §4: Σ(Area Score × Area Weight), renormalized.</summary>
    public double? ComputeOverallScore(IReadOnlyList<AreaScore> areaScores)
    {
        var scored = areaScores.Where(a => a.ScorePercent.HasValue).ToList();
        if (scored.Count == 0) return null;
        var weightSum = scored.Sum(a => a.Area.Weight);
        if (weightSum <= 0) return null;
        var weighted = scored.Sum(a => a.ScorePercent!.Value * a.Area.Weight);
        return weighted / weightSum;
    }

    /// <summary>Risk rating per rubric §5.</summary>
    public RiskRating GetRiskRating(double? percent)
    {
        if (percent is null) return new RiskRating("⚪", "Not Assessed");
        return percent switch
        {
            > 90 => new RiskRating("🔵", "Excellent"),
            > 75 => new RiskRating("🟢", "Good"),
            > 60 => new RiskRating("🟡", "Medium"),
            > 40 => new RiskRating("🟠", "High"),
            _    => new RiskRating("🔴", "Critical"),
        };
    }
}

// =============================================================================
// ENRICHER — fills missing fields with dummy values for testing
// =============================================================================

public sealed class ReportInputEnricher
{
    public bool UsedDummyValues { get; private set; }

    public IReadOnlyList<ChecklistItemResult> Enrich(IEnumerable<ChecklistItemResult> items)
    {
        var list = items.ToList();
        foreach (var item in list)
            EnrichItem(item);
        return list;
    }

    private void EnrichItem(ChecklistItemResult item)
    {
        var notApplicable = item.IsNotApplicable;

        if (item.Score is null && !notApplicable)
        {
            item.Score = item.Outcome?.Trim().ToLowerInvariant() switch
            {
                "pass" => 3,
                "fail" => 0,
                "needsreview" or "needs review" => 1,
                _ => 2,
            };
            UsedDummyValues = true;
        }

        if (string.IsNullOrWhiteSpace(item.Severity))
        {
            item.Severity = notApplicable
                ? "Informational"
                : item.Score switch
                {
                    0 => "High",
                    1 => "Medium",
                    2 => "Low",
                    _ => "Informational",
                };
            UsedDummyValues = true;
        }

        if (string.IsNullOrWhiteSpace(item.Finding))
        {
            item.Finding = item.Score >= 2
                ? $"Control satisfied: {item.Description}"
                : $"Gap identified: {item.Description}";
            UsedDummyValues = true;
        }

        if (string.IsNullOrWhiteSpace(item.Evidence))
        {
            item.Evidence = string.IsNullOrWhiteSpace(item.ScriptFile)
                ? $"Assessed via {item.Technique}."
                : $"Assessed via {item.Technique}; script: {item.ScriptFile}.";
        }

        // N/A items need no remediation, effort, risk or score impact: they are outside
        // the scored population entirely.
        if (notApplicable) return;

        if (string.IsNullOrWhiteSpace(item.Recommendation) && item.Score < 2)
        {
            item.Recommendation = $"Remediate '{item.Description}' to meet the target standard.";
            UsedDummyValues = true;
        }

        if (string.IsNullOrWhiteSpace(item.Effort))
        {
            item.Effort = item.Score switch { 0 => "High", 1 => "Medium", _ => "Low" };
            UsedDummyValues = true;
        }

        if (string.IsNullOrWhiteSpace(item.RiskImpact))
        {
            item.RiskImpact = item.Score switch
            {
                0 => "High — control absent",
                1 => "Medium — partial coverage",
                _ => "Low — control in place",
            };
            UsedDummyValues = true;
        }

        if (item.ScoreImpact is null && item.Score.HasValue)
        {
            item.ScoreImpact = 3 - item.Score.Value;
            UsedDummyValues = true;
        }
    }
}

// =============================================================================
// CHECKLIST RESULTS LOADER
// =============================================================================

public static class ChecklistResultsLoader
{
    private static readonly JsonSerializerOptions Options = new()
    {
        PropertyNameCaseInsensitive = true,
        ReadCommentHandling = JsonCommentHandling.Skip,
        AllowTrailingCommas = true,
    };

    public static List<ChecklistItemResult> Load(string path)
    {
        if (!File.Exists(path))
            throw new FileNotFoundException($"Checklist results file not found: {path}", path);
        var json = File.ReadAllText(path);
        return LoadFromJson(json);
    }

    public static List<ChecklistItemResult> LoadFromJson(string json)
    {
        var items = JsonSerializer.Deserialize<List<ChecklistItemResult>>(json, Options);
        return items ?? new List<ChecklistItemResult>();
    }
}

// =============================================================================
// SUMMARY REPORT GENERATOR
// =============================================================================

/// <summary>
/// Produces the Summary Report markdown from checklist results.
/// WPF integration: new SummaryReportGenerator().GenerateFromFile(path, output, metadata);
/// </summary>
public sealed class SummaryReportGenerator
{
    private readonly ScoreCalculator _calculator = new();
    private readonly ReportInputEnricher _enricher = new();

    public string GenerateFromFile(string resultsJsonPath, string outputPath, ReportMetadata? metadata = null)
    {
        var items = ChecklistResultsLoader.Load(resultsJsonPath);
        var markdown = Generate(items, metadata ?? new ReportMetadata());
        Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(outputPath))!);
        File.WriteAllText(outputPath, markdown, new UTF8Encoding(false));
        return markdown;
    }

    public string Generate(IEnumerable<ChecklistItemResult> rawItems, ReportMetadata metadata)
    {
        var items = _enricher.Enrich(rawItems);
        var areaScores = _calculator.ComputeAreaScores(items);
        var overall = _calculator.ComputeOverallScore(areaScores);
        var rating = _calculator.GetRiskRating(overall);

        var sb = new StringBuilder();
        WriteHeader(sb, metadata);
        WriteExecutiveSummary(sb, metadata, items, areaScores, overall, rating);
        WriteDetailedFindings(sb, areaScores);
        WriteRoadmap(sb, items);
        WriteAppendices(sb);

        if (_enricher.UsedDummyValues)
            WriteDummyCaveat(sb);

        return sb.ToString();
    }

    // -------------------------------------------------------------------------

    private static void WriteHeader(StringBuilder sb, ReportMetadata m)
    {
        sb.AppendLine("# Audit Report — MLC SQL (SQL Server / Azure SQL) Solution");
        sb.AppendLine();
        sb.AppendLine("---");
        sb.AppendLine();
        sb.AppendLine("## Document Control");
        sb.AppendLine();
        sb.AppendLine("| Field | Value |");
        sb.AppendLine("|-------|-------|");
        sb.AppendLine($"| **Client** | {m.Client} |");
        sb.AppendLine($"| **Solution** | {m.Solution} |");
        sb.AppendLine($"| **Audit Period** | {m.AuditPeriodStart} – {m.AuditPeriodEnd} |");
        sb.AppendLine($"| **Report Date** | {m.ReportDate} |");
        sb.AppendLine($"| **Auditor(s)** | {m.Auditors} |");
        sb.AppendLine($"| **Report Version** | {m.ReportVersion} |");
        sb.AppendLine($"| **Classification** | {m.Classification} |");
        sb.AppendLine($"| **Distribution** | {m.Distribution} |");
        sb.AppendLine();
        sb.AppendLine("### Revision History");
        sb.AppendLine();
        sb.AppendLine("| Version | Date | Author | Changes |");
        sb.AppendLine("|---------|------|--------|---------|");
        sb.AppendLine("| 0.1 | | | Initial draft |");
        sb.AppendLine($"| 1.0 | {m.ReportDate} | {m.Auditors} | Final report |");
        sb.AppendLine();
        sb.AppendLine("---");
        sb.AppendLine();
    }

    private void WriteExecutiveSummary(
        StringBuilder sb, ReportMetadata m,
        IReadOnlyList<ChecklistItemResult> items,
        IReadOnlyList<AreaScore> areaScores,
        double? overall, RiskRating rating)
    {
        var scored = items.Count(i => i.IsScored);
        var na = items.Count(i => i.IsNotApplicable);
        var critical = items.Count(i => IsCritical(i));
        var high = items.Count(i => string.Equals(i.Severity, "High", StringComparison.OrdinalIgnoreCase));

        sb.AppendLine("## 1. Executive Summary");
        sb.AppendLine();
        sb.AppendLine("### 1.1 Overall Health Score");
        sb.AppendLine();
        sb.AppendLine("| Metric | Value |");
        sb.AppendLine("|--------|-------|");
        sb.AppendLine($"| **Overall Score** | **{Pct(overall)}** |");
        sb.AppendLine($"| **Risk Rating** | {rating.Icon} **{rating.Label}** |");
        sb.AppendLine($"| **Total Checklist Items** | {m.TotalChecklistItems} |");
        sb.AppendLine($"| **Items Scored** | {scored} |");
        sb.AppendLine($"| **Items Not Applicable** | {na} |");
        sb.AppendLine($"| **Critical Findings** | {critical} |");
        sb.AppendLine($"| **High Findings** | {high} |");
        sb.AppendLine();

        // 1.2 Area Scorecard
        sb.AppendLine("### 1.2 Area Scorecard");
        sb.AppendLine();
        sb.AppendLine("| # | Area | Weight | Score | Weighted | Rating |");
        sb.AppendLine("|---|------|--------|-------|----------|--------|");
        foreach (var a in areaScores)
        {
            var r = _calculator.GetRiskRating(a.ScorePercent);
            var ratingCell = a.ScorePercent is null ? "—" : $"{r.Icon} {r.Label}";
            sb.AppendLine(
                $"| {a.Area.Number} | {a.Area.Name} | {a.Area.Weight:0}% | " +
                $"{Pct(a.ScorePercent)} | {Weighted(a.WeightedContribution)} | {ratingCell} |");
        }
        sb.AppendLine($"| | **Overall** | **100%** | | **{Pct(overall)}** | {rating.Icon} {rating.Label} |");
        sb.AppendLine();

        // 1.3 Radar chart
        sb.AppendLine("### 1.3 Radar Chart");
        sb.AppendLine();
        sb.AppendLine("```mermaid");
        sb.AppendLine("radar-beta");
        sb.AppendLine("  axis " + string.Join(", ", AreaCatalog.Areas.Select(a => a.RadarLabel)));
        var curve = string.Join(", ", areaScores.Select(a => (a.ScorePercent ?? 0).ToString("0", CultureInfo.InvariantCulture)));
        sb.AppendLine($"  curve ScorePct[\"% Score\"] {{ {curve} }}");
        sb.AppendLine("```");
        sb.AppendLine();

        // 1.4 Top 5 critical findings
        sb.AppendLine("### 1.4 Top 5 Critical Findings");
        sb.AppendLine();
        sb.AppendLine("| # | Finding | Area | Severity | Checklist Ref |");
        sb.AppendLine("|---|---------|------|----------|---------------|");
        var topFindings = items
            .Where(IsCritical)
            .OrderBy(i => i.Score ?? 0)
            .ThenBy(i => i.Id)
            .Take(5)
            .ToList();
        if (topFindings.Count == 0)
        {
            sb.AppendLine("| — | No critical findings identified in the assessed items. | | | |");
        }
        else
        {
            var n = 1;
            foreach (var f in topFindings)
                sb.AppendLine($"| {n++} | {Clean(f.Finding)} | {f.AreaNumber}. {AreaCatalog.Get(f.AreaNumber).Name} | {f.Severity} | {f.Id} |");
        }
        sb.AppendLine();

        // 1.5 Top 5 priority recommendations
        sb.AppendLine("### 1.5 Top 5 Priority Recommendations");
        sb.AppendLine();
        sb.AppendLine("| # | Recommendation | Addresses | Effort | Risk Impact | Score Impact |");
        sb.AppendLine("|---|---------------|-----------|--------|------------|-------------|");
        var topRecs = TopRecommendations(items, 5);
        if (topRecs.Count == 0)
        {
            sb.AppendLine("| — | No remediation required for the assessed items. | | | | |");
        }
        else
        {
            var n = 1;
            foreach (var r in topRecs)
                sb.AppendLine($"| {n++} | {Clean(r.Recommendation)} | {r.Id} | {r.Effort} | {Clean(r.RiskImpact)} | +{r.ScoreImpact:0} pts |");
        }
        sb.AppendLine();

        sb.AppendLine("---");
        sb.AppendLine();
    }

    private void WriteDetailedFindings(StringBuilder sb, IReadOnlyList<AreaScore> areaScores)
    {
        sb.AppendLine("## 2. Detailed Findings by Area");
        sb.AppendLine();
        sb.AppendLine("> Areas with no assessed items are omitted. Full checklist scores are in [02-audit-checklist.md](02-audit-checklist.md).");
        sb.AppendLine();

        var sectionNumber = 1;
        foreach (var a in areaScores.Where(a => a.Items.Count > 0))
        {
            var r = _calculator.GetRiskRating(a.ScorePercent);
            sb.AppendLine($"### 2.{sectionNumber++} Area {a.Area.Number}: {a.Area.Name}");
            sb.AppendLine();
            sb.AppendLine($"**Area Score: {Pct(a.ScorePercent)} | Rating: {r.Icon} {r.Label}**");
            sb.AppendLine();

            // Category breakdown (rubric §2)
            sb.AppendLine("| Category | Score | Rating |");
            sb.AppendLine("|----------|-------|--------|");
            foreach (var cat in a.Categories)
            {
                var cr = _calculator.GetRiskRating(cat.ScorePercent);
                var crCell = cat.ScorePercent is null ? "—" : $"{cr.Icon} {cr.Label}";
                sb.AppendLine($"| {cat.CategoryId} | {Pct(cat.ScorePercent)} | {crCell} |");
            }
            sb.AppendLine();

            // Findings
            sb.AppendLine("#### Findings");
            sb.AppendLine();
            sb.AppendLine("| # | Checklist Ref | Finding | Severity | Score |");
            sb.AppendLine("|---|--------------|---------|----------|-------|");
            var n = 1;
            foreach (var i in a.Items.OrderBy(i => i.Id))
            {
                var score = i.IsNotApplicable ? "N/A" : (i.Score?.ToString() ?? "—");
                sb.AppendLine($"| {n++} | {i.Id} | {Clean(i.Finding)} | {i.Severity} | {score} |");
            }
            sb.AppendLine();

            // Recommendations
            var recs = a.Items.Where(i => !string.IsNullOrWhiteSpace(i.Recommendation)).OrderBy(i => i.Id).ToList();
            sb.AppendLine("#### Recommendations");
            sb.AppendLine();
            sb.AppendLine("| # | Recommendation | Addresses | Effort | Risk Impact | Score Impact |");
            sb.AppendLine("|---|---------------|-----------|--------|------------|-------------|");
            if (recs.Count == 0)
            {
                sb.AppendLine("| — | No remediation required for the assessed items in this area. | | | | |");
            }
            else
            {
                var rn = 1;
                foreach (var i in recs)
                    sb.AppendLine($"| {rn++} | {Clean(i.Recommendation)} | {i.Id} | {i.Effort} | {Clean(i.RiskImpact)} | +{i.ScoreImpact:0} pts |");
            }
            sb.AppendLine();
            sb.AppendLine("---");
            sb.AppendLine();
        }
    }

    private void WriteRoadmap(StringBuilder sb, IReadOnlyList<ChecklistItemResult> items)
    {
        sb.AppendLine("## 3. Consolidated Recommendations Roadmap");
        sb.AppendLine();
        sb.AppendLine("| Priority | Recommendation | Area(s) | Effort | Severity Addressed | Target Window |");
        sb.AppendLine("|----------|---------------|---------|--------|--------------------|---------------|");
        var recs = TopRecommendations(items, 10);
        if (recs.Count == 0)
        {
            sb.AppendLine("| — | No remediation required for the assessed items. | | | | |");
        }
        else
        {
            var p = 1;
            foreach (var r in recs)
            {
                var window = r.Score == 0 ? "0–7 days" : r.Score == 1 ? "30 days" : "90 days";
                sb.AppendLine($"| {p++} | {Clean(r.Recommendation)} | {r.AreaNumber}. {AreaCatalog.Get(r.AreaNumber).Name} | {r.Effort} | {r.Severity} | {window} |");
            }
        }
        sb.AppendLine();
        sb.AppendLine("---");
        sb.AppendLine();
    }

    private static void WriteAppendices(StringBuilder sb)
    {
        sb.AppendLine("## 4. Appendices");
        sb.AppendLine();
        sb.AppendLine("- **Appendix A**: Full checklist scores — [02-audit-checklist.md](02-audit-checklist.md)");
        sb.AppendLine("- **Appendix B**: Compliance matrix — [03-compliance-matrix.md](03-compliance-matrix.md)");
        sb.AppendLine("- **Appendix C**: Risk register — [06-risk-register-template.md](06-risk-register-template.md)");
        sb.AppendLine("- **Appendix D**: Evidence index — [DMV outputs, execution plans, config exports collected]");
        sb.AppendLine();
    }

    private static void WriteDummyCaveat(StringBuilder sb)
    {
        sb.AppendLine("---");
        sb.AppendLine();
        sb.AppendLine("> ⚠️ **Testing caveat:** Some fields required by the report template are not yet");
        sb.AppendLine("> emitted by the assessment engine and were populated with **dummy values**");
        sb.AppendLine("> (Score, Severity, Finding, Recommendation, Effort, Risk Impact, Score Impact).");
        sb.AppendLine("> Ask the POC to persist these fields in `checklist_results.json` for accurate reporting.");
        sb.AppendLine();
    }

    // ---- helpers ------------------------------------------------------------

    private static bool IsCritical(ChecklistItemResult i) =>
        !i.IsNotApplicable &&
        (string.Equals(i.Severity, "Critical", StringComparison.OrdinalIgnoreCase)
         || i.Score == 0
         || string.Equals(i.Outcome, "Fail", StringComparison.OrdinalIgnoreCase));

    private static List<ChecklistItemResult> TopRecommendations(IEnumerable<ChecklistItemResult> items, int take) =>
        items
            .Where(i => !i.IsNotApplicable
                        && !string.IsNullOrWhiteSpace(i.Recommendation)
                        && (i.Score ?? 3) < 2)
            .OrderByDescending(i => i.ScoreImpact ?? 0)
            .ThenBy(i => i.Score ?? 3)
            .ThenBy(i => i.Id)
            .Take(take)
            .ToList();

    private static string Pct(double? value) =>
        value is null ? "N/A" : $"{value.Value.ToString("0.0", CultureInfo.InvariantCulture)}%";

    private static string Weighted(double? value) =>
        value is null ? "—" : value.Value.ToString("0.0", CultureInfo.InvariantCulture);

    private static string Clean(string? text) =>
        string.IsNullOrWhiteSpace(text) ? "" : text.Replace("|", "\\|").Replace("\r", " ").Replace("\n", " ").Trim();
}
