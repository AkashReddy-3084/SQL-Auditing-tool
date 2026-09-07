using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Net;
using System.Text;
using System.Text.Json;

namespace SqlAuditor.Reporting;

/// <summary>
/// Renders the four companion documents from <see cref="AuditWorkbookModel"/> — the same model
/// the workbook is written from — so every artifact reports identical scores and findings.
/// </summary>
public static class AuditWorkbookDocuments
{
    private const string DerivedNote =
        "> Generated from the audit workbook for this run. Every score, finding and risk below is the same data the workbook contains.";

    // -- Audit Checklist.md --------------------------------------------------

    public static string RenderAuditChecklist(AuditWorkbookModel model)
    {
        var sb = new StringBuilder();
        var calculator = new ScoreCalculator();

        sb.AppendLine($"# Audit Checklist — {model.Target}");
        sb.AppendLine();
        sb.AppendLine(DerivedNote);
        sb.AppendLine();
        sb.AppendLine("## Document Control");
        sb.AppendLine();
        AppendKeyValues(sb, new (string, string)[]
        {
            ("Target", model.Target),
            ("Report date", model.GeneratedDate),
            ("Deployment mode", model.DeploymentMode),
            ("Overall score", AuditWorkbookBuilder.Percent(model.OverallScore)),
            ("Risk rating", model.OverallRating.Label),
            ("Source workbook", ReportSuiteGenerator.ExcelReportFileName),
        });

        sb.AppendLine();
        sb.AppendLine("## Scoring Legend");
        sb.AppendLine();
        sb.AppendLine("| Value | Meaning |");
        sb.AppendLine("|------:|---------|");
        sb.AppendLine("| 0 | Not implemented / ineffective |");
        sb.AppendLine("| 1 | Partially implemented / major gaps |");
        sb.AppendLine("| 2 | Implemented / improvement remains |");
        sb.AppendLine("| 3 | Best practice / fully implemented |");
        sb.AppendLine($"| {AuditWorkbookBuilder.NoValue} | Excluded from score: not applicable or awaiting validation |");

        sb.AppendLine();
        sb.AppendLine("## Checklist Statistics");
        sb.AppendLine();
        sb.AppendLine("| Metric | Count |");
        sb.AppendLine("|--------|------:|");
        var coverage = model.Coverage;
        sb.AppendLine($"| Total controls | {coverage.Total} |");
        sb.AppendLine($"| Deterministic | {coverage.Deterministic} |");
        sb.AppendLine($"| AI analysis | {coverage.AiAssisted} |");
        sb.AppendLine($"| Manual attestation | {coverage.ManualAttestation} |");
        sb.AppendLine($"| Needs review | {coverage.NeedsReview} |");
        sb.AppendLine($"| Awaiting validation | {coverage.AwaitingValidation} |");
        sb.AppendLine($"| Not applicable | {coverage.NotApplicable} |");

        sb.AppendLine();
        sb.AppendLine("### Area Summary");
        sb.AppendLine();
        sb.AppendLine("| Area | Weight | Score | Rating | Controls | Validated | Not validated |");
        sb.AppendLine("|------|-------:|------:|--------|---------:|----------:|--------------:|");
        foreach (var area in model.Areas)
        {
            var notValidated = area.Items.Count - area.ScoredCount;
            sb.AppendLine(
                $"| {area.Area.Number}. {Md(model.AreaName(area.Area.Number))} | {area.Area.Weight:0.#}% | " +
                $"{AuditWorkbookBuilder.Percent(area.ScorePercent)} | {calculator.GetRiskRating(area.ScorePercent).Label} | " +
                $"{area.Items.Count} | {area.ScoredCount} | {notValidated} |");
        }

        sb.AppendLine();
        sb.AppendLine("### Database Scope");
        sb.AppendLine();
        if (model.Databases.Count == 0)
        {
            sb.AppendLine("No database-scoped evidence was recorded for this run.");
        }
        else
        {
            sb.AppendLine("| Database ID | Database |");
            sb.AppendLine("|-------------|----------|");
            foreach (var database in model.Databases)
                sb.AppendLine($"| {database.Id} | {Md(database.Name)} |");
        }

        sb.AppendLine();
        sb.AppendLine("## Detailed Checklist");

        foreach (var area in model.Areas.Where(a => a.Items.Count > 0))
        {
            sb.AppendLine();
            sb.AppendLine($"## Area {area.Area.Number}: {Md(model.AreaName(area.Area.Number))} (Weight: {area.Area.Weight:0.#}%)");
            sb.AppendLine();
            sb.AppendLine($"**Area score: {AuditWorkbookBuilder.Percent(area.ScorePercent)} | Rating: {calculator.GetRiskRating(area.ScorePercent).Label}**");

            foreach (var category in area.Categories)
            {
                sb.AppendLine();
                sb.AppendLine($"### {Md(model.CategoryLabel(category.CategoryId))}");
                sb.AppendLine();

                var header = new StringBuilder("| Ref | Checklist Item | Status | Score | Severity | Produced By | Rationale |");
                var divider = new StringBuilder("|-----|----------------|--------|------:|----------|-------------|-----------|");
                foreach (var database in model.Databases)
                {
                    header.Append($" {database.Id} {Md(database.Name)} |");
                    divider.Append("------|");
                }
                sb.AppendLine(header.ToString());
                sb.AppendLine(divider.ToString());

                foreach (var item in category.Items.OrderBy(i => i.Id, ChecklistIdComparer.Instance))
                {
                    var names = AuditWorkbookBuilder.DatabasesOf(item);
                    var row = new StringBuilder(
                        $"| {Md(item.Id)} | {Md(item.Description)} | {AuditWorkbookModel.Status(item)} | " +
                        $"{ScoreText(item)} | {Md(AuditWorkbookBuilder.Text(item.Severity))} | " +
                        $"{AuditWorkbookModel.ProducedBy(item)} | {Md(AuditWorkbookBuilder.Text(item.Finding))} |");

                    foreach (var database in model.Databases)
                    {
                        var applies = names.Contains(database.Name, StringComparer.OrdinalIgnoreCase);
                        row.Append($" {(applies ? ScoreText(item) : AuditWorkbookBuilder.NoValue)} |");
                    }
                    sb.AppendLine(row.ToString());
                }
            }
        }

        return sb.ToString();
    }

    // -- Audit Report.md -----------------------------------------------------

    public static string RenderAuditReport(AuditWorkbookModel model)
    {
        var sb = new StringBuilder();
        var calculator = new ScoreCalculator();

        sb.AppendLine($"# SQL Server Audit Report — {model.Target}");
        sb.AppendLine();
        sb.AppendLine(DerivedNote);
        sb.AppendLine();
        sb.AppendLine("## Document Control");
        sb.AppendLine();
        AppendKeyValues(sb, new (string, string)[]
        {
            ("Client", model.Metadata.Client),
            ("Target", model.Target),
            ("Solution", model.Metadata.Solution),
            ("Deployment mode", model.DeploymentMode),
            ("Report date", model.GeneratedDate),
            ("Auditor", model.Metadata.Auditors),
            ("Report version", model.Metadata.ReportVersion),
            ("Classification", model.Metadata.Classification),
            ("Source workbook", ReportSuiteGenerator.ExcelReportFileName),
        });

        sb.AppendLine();
        sb.AppendLine("### Report Suite");
        sb.AppendLine();
        sb.AppendLine($"- [Audit Checklist]({Link(ReportSuiteGenerator.AuditChecklistFileName)}) — every evaluated control and its outcome.");
        sb.AppendLine($"- [Risk Register]({Link(ReportSuiteGenerator.RiskRegisterFileName)}) — all active risks and remediation tracking fields.");
        sb.AppendLine($"- `{ReportSuiteGenerator.ExcelReportFileName}` — editable workbook and the source of every figure in this suite.");
        sb.AppendLine($"- `{ReportSuiteGenerator.HtmlReportFileName}` — interactive readout.");

        sb.AppendLine();
        sb.AppendLine("## 1. Executive Summary");
        sb.AppendLine();
        sb.AppendLine("### 1.1 Overall Health Score");
        sb.AppendLine();
        var coverage = model.Coverage;
        AppendKeyValues(sb, new (string, string)[]
        {
            ("**Overall Score**", $"**{AuditWorkbookBuilder.Percent(model.OverallScore)}**"),
            ("**Risk Rating**", $"{model.OverallRating.Icon} **{model.OverallRating.Label}**"),
            ("Total Checklist Items", coverage.Total.ToString(CultureInfo.InvariantCulture)),
            ("Items Scored (validated)", (coverage.Deterministic + coverage.AiAssisted + coverage.ManualAttestation).ToString(CultureInfo.InvariantCulture)),
            ("Items Awaiting Validation", coverage.AwaitingValidation.ToString(CultureInfo.InvariantCulture)),
            ("Items N/A", coverage.NotApplicable.ToString(CultureInfo.InvariantCulture)),
            ("Critical Findings", CountSeverity(model, "Critical").ToString(CultureInfo.InvariantCulture)),
            ("High Findings", CountSeverity(model, "High").ToString(CultureInfo.InvariantCulture)),
        });
        sb.AppendLine();
        sb.AppendLine("> The score is calculated from validated items only. Items that are not applicable or awaiting validation are excluded from the arithmetic and shown as \"—\" rather than zero.");

        sb.AppendLine();
        sb.AppendLine("### 1.2 Area Scorecard");
        sb.AppendLine();
        sb.AppendLine("| # | Area | Weight | Score | Weighted | Rating |");
        sb.AppendLine("|---|------|--------|-------|----------|--------|");
        foreach (var area in model.Areas)
        {
            var weighted = area.WeightedContribution.HasValue
                ? area.WeightedContribution.Value.ToString("0.0", CultureInfo.InvariantCulture)
                : AuditWorkbookBuilder.NoValue;
            sb.AppendLine(
                $"| {area.Area.Number} | {Md(model.AreaName(area.Area.Number))} | {area.Area.Weight:0.#}% | " +
                $"{AuditWorkbookBuilder.Percent(area.ScorePercent)} | {weighted} | " +
                $"{calculator.GetRiskRating(area.ScorePercent).Icon} {calculator.GetRiskRating(area.ScorePercent).Label} |");
        }
        sb.AppendLine($"| | **Overall** | **100%** | **{AuditWorkbookBuilder.Percent(model.OverallScore)}** | | {model.OverallRating.Icon} **{model.OverallRating.Label}** |");

        sb.AppendLine();
        sb.AppendLine("### 1.3 Radar Chart");
        sb.AppendLine();
        sb.AppendLine("```mermaid");
        sb.AppendLine("radar-beta");
        sb.AppendLine("  axis " + string.Join(", ", model.Areas.Select(a => a.Area.RadarLabel)));
        sb.AppendLine("  curve ScorePct[\"% Score\"] { " +
            string.Join(", ", model.Areas.Select(a => Math.Round(a.ScorePercent ?? 0).ToString(CultureInfo.InvariantCulture))) + " }");
        sb.AppendLine("```");

        sb.AppendLine();
        sb.AppendLine("### 1.4 Top Priority Findings");
        sb.AppendLine();
        sb.AppendLine("| # | Ref | Finding | Area | Severity | Scope |");
        sb.AppendLine("|---|-----|---------|------|----------|-------|");
        var top = model.Findings.Take(5).ToList();
        if (top.Count == 0)
        {
            sb.AppendLine($"| — | — | No active findings were raised. | — | — | — |");
        }
        else
        {
            for (var i = 0; i < top.Count; i++)
            {
                var finding = top[i];
                sb.AppendLine(
                    $"| {i + 1} | {Md(finding.Item.Id)} | {Md(AuditWorkbookBuilder.Text(finding.Item.Finding))} | " +
                    $"{Md(model.AreaName(finding.Item.AreaNumber))} | {Md(AuditWorkbookBuilder.Text(finding.Item.Severity))} | {finding.Scope} |");
            }
        }

        sb.AppendLine();
        sb.AppendLine("### 1.5 Top Priority Recommendations");
        sb.AppendLine();
        sb.AppendLine("| # | Recommendation | Addresses | Severity | Target SLA |");
        sb.AppendLine("|---|----------------|-----------|----------|------------|");
        if (top.Count == 0)
        {
            sb.AppendLine("| — | No remediation is outstanding. | — | — | — |");
        }
        else
        {
            for (var i = 0; i < top.Count; i++)
            {
                var finding = top[i];
                sb.AppendLine(
                    $"| {i + 1} | {Md(AuditWorkbookBuilder.Text(finding.Item.Recommendation))} | {Md(finding.Item.Id)} | " +
                    $"{Md(AuditWorkbookBuilder.Text(finding.Item.Severity))} | {finding.Severity.Sla} |");
            }
        }

        sb.AppendLine();
        sb.AppendLine("## 2. Detailed Findings by Area");

        foreach (var area in model.Areas.Where(a => a.Items.Count > 0))
        {
            var areaFindings = model.Findings.Where(f => f.Item.AreaNumber == area.Area.Number).ToList();
            sb.AppendLine();
            sb.AppendLine($"### Area {area.Area.Number}: {Md(model.AreaName(area.Area.Number))}");
            sb.AppendLine();
            sb.AppendLine($"**Area Score: {AuditWorkbookBuilder.Percent(area.ScorePercent)} | Rating: {calculator.GetRiskRating(area.ScorePercent).Label}**");
            sb.AppendLine();
            sb.AppendLine("| Category | Score | Rating | Validated | Items |");
            sb.AppendLine("|----------|------:|--------|----------:|------:|");
            foreach (var category in area.Categories)
            {
                sb.AppendLine(
                    $"| {Md(model.CategoryLabel(category.CategoryId))} | {AuditWorkbookBuilder.Percent(category.ScorePercent)} | " +
                    $"{calculator.GetRiskRating(category.ScorePercent).Label} | {category.ScoredCount} | {category.Items.Count} |");
            }

            sb.AppendLine();
            sb.AppendLine($"#### Findings ({areaFindings.Count})");
            sb.AppendLine();
            if (areaFindings.Count == 0)
            {
                sb.AppendLine("No active findings in this area.");
                continue;
            }

            sb.AppendLine("| Ref | Finding | Severity | Score | Impacted Databases | Recommendation |");
            sb.AppendLine("|-----|---------|----------|------:|--------------------|----------------|");
            foreach (var finding in areaFindings)
            {
                sb.AppendLine(
                    $"| {Md(finding.Item.Id)} | {Md(AuditWorkbookBuilder.Text(finding.Item.Finding))} | " +
                    $"{Md(AuditWorkbookBuilder.Text(finding.Item.Severity))} | {ScoreText(finding.Item)} | " +
                    $"{Md(AuditWorkbookBuilder.DatabaseList(finding.ImpactedDatabases, AuditWorkbookBuilder.InstanceScope))} | " +
                    $"{Md(AuditWorkbookBuilder.Text(finding.Item.Recommendation))} |");
            }
        }

        if (model.AccessIssues.Count > 0)
        {
            sb.AppendLine();
            sb.AppendLine("## 3. Access & Collection Issues");
            sb.AppendLine();
            sb.AppendLine("| Ref | Title | Failure Type | Status |");
            sb.AppendLine("|-----|-------|--------------|--------|");
            foreach (var issue in model.AccessIssues)
            {
                sb.AppendLine(
                    $"| {Md(issue.Item.Id)} | {Md(AuditWorkbookBuilder.Text(issue.Item.Description))} | " +
                    $"{issue.FailureType} | {AuditWorkbookModel.Status(issue.Item)} |");
            }
        }

        return sb.ToString();
    }

    // -- Risk Register.md ----------------------------------------------------

    public static string RenderRiskRegister(AuditWorkbookModel model)
    {
        var sb = new StringBuilder();
        var total = model.Findings.Count;

        sb.AppendLine($"# Risk Register — {model.Target}");
        sb.AppendLine();
        sb.AppendLine(DerivedNote);
        sb.AppendLine();
        sb.AppendLine("## Document Control");
        sb.AppendLine();
        AppendKeyValues(sb, new (string, string)[]
        {
            ("Target", model.Target),
            ("Report date", model.GeneratedDate),
            ("Risks logged", total.ToString(CultureInfo.InvariantCulture)),
            ("Overall score", AuditWorkbookBuilder.Percent(model.OverallScore)),
            ("Overall rating", model.OverallRating.Label),
            ("Editable source", ReportSuiteGenerator.ExcelReportFileName + " — Risk Register sheet"),
        });

        sb.AppendLine();
        sb.AppendLine("## Risk Scoring Guide");
        sb.AppendLine();
        sb.AppendLine("| Severity | Risk score | Likelihood | Impact | Remediation SLA |");
        sb.AppendLine("|----------|-----------:|------------|--------|-----------------|");
        foreach (var severity in new[] { "Critical", "High", "Medium", "Low", "Informational" })
        {
            var profile = AuditWorkbookBuilder.ProfileFor(severity);
            sb.AppendLine($"| {severity} | {profile.RiskScore} | {profile.Likelihood} | {profile.Impact} | {profile.Sla} |");
        }

        sb.AppendLine();
        sb.AppendLine("## Risk Summary Dashboard");
        sb.AppendLine();
        sb.AppendLine("| Severity | Count | % of Total | SLA |");
        sb.AppendLine("|----------|------:|-----------:|-----|");
        foreach (var severity in new[] { "Critical", "High", "Medium", "Low", "Informational" })
        {
            var count = CountSeverity(model, severity);
            var share = total == 0 ? 0 : (double)count / total * 100;
            sb.AppendLine($"| {severity} | {count} | {share.ToString("0.0", CultureInfo.InvariantCulture)}% | {AuditWorkbookBuilder.ProfileFor(severity).Sla} |");
        }
        sb.AppendLine($"| **Total** | **{total}** | **{(total == 0 ? "0.0" : "100.0")}%** | — |");

        if (total > 0)
        {
            sb.AppendLine();
            sb.AppendLine("```mermaid");
            sb.AppendLine("pie showData");
            sb.AppendLine("  title Risks by Severity");
            foreach (var severity in new[] { "Critical", "High", "Medium", "Low" })
            {
                var count = CountSeverity(model, severity);
                if (count > 0) sb.AppendLine($"  \"{severity}\" : {count}");
            }
            sb.AppendLine("```");
        }

        sb.AppendLine();
        sb.AppendLine("### Risk Distribution by Area");
        sb.AppendLine();
        sb.AppendLine("| Area | Critical | High | Medium | Low | Total |");
        sb.AppendLine("|------|---------:|-----:|-------:|----:|------:|");
        foreach (var area in model.Areas.Where(a => a.Items.Count > 0))
        {
            var areaFindings = model.Findings.Where(f => f.Item.AreaNumber == area.Area.Number).ToList();
            sb.AppendLine(
                $"| {area.Area.Number}. {Md(model.AreaName(area.Area.Number))} | " +
                $"{CountSeverity(areaFindings, "Critical")} | {CountSeverity(areaFindings, "High")} | " +
                $"{CountSeverity(areaFindings, "Medium")} | {CountSeverity(areaFindings, "Low")} | {areaFindings.Count} |");
        }

        var critical = model.Findings
            .Where(f => string.Equals(f.Item.Severity, "Critical", StringComparison.OrdinalIgnoreCase))
            .ToList();
        if (critical.Count > 0)
        {
            sb.AppendLine();
            sb.AppendLine("## Critical Risks");
            sb.AppendLine();
            sb.AppendLine("| Risk ID | Area | Checklist Ref | Finding | Likelihood | Impact | Recommendation |");
            sb.AppendLine("|---------|------|---------------|---------|------------|--------|----------------|");
            foreach (var finding in critical)
            {
                sb.AppendLine(
                    $"| {finding.RiskId} | {Md(model.AreaName(finding.Item.AreaNumber))} | {Md(finding.Item.Id)} | " +
                    $"{Md(AuditWorkbookBuilder.Text(finding.Item.Finding))} | {finding.Severity.Likelihood} | " +
                    $"{finding.Severity.Impact} | {Md(AuditWorkbookBuilder.Text(finding.Item.Recommendation))} |");
            }
        }

        sb.AppendLine();
        sb.AppendLine("## Full Risk Register");
        sb.AppendLine();
        sb.AppendLine("| Risk ID | Audit Phase | Area | Category | Checklist Ref | Finding | Scope | Impacted Databases | Severity | Likelihood | Impact | Risk Score | SLA | Recommendation | Treatment | Status |");
        sb.AppendLine("|---------|-------------|------|----------|---------------|---------|-------|--------------------|----------|------------|--------|-----------:|-----|----------------|-----------|--------|");
        if (total == 0)
        {
            sb.AppendLine("| — | — | — | — | — | No active risks were raised for this run. | — | — | — | — | — | — | — | — | — | — |");
        }
        else
        {
            foreach (var finding in model.Findings)
            {
                var item = finding.Item;
                sb.AppendLine(
                    $"| {finding.RiskId} | {finding.AuditPhase} | {Md(model.AreaName(item.AreaNumber))} | " +
                    $"{Md(model.CategoryLabel(item.CategoryId))} | {Md(item.Id)} | {Md(AuditWorkbookBuilder.Text(item.Finding))} | " +
                    $"{finding.Scope} | {Md(AuditWorkbookBuilder.DatabaseList(finding.ImpactedDatabases, AuditWorkbookBuilder.InstanceScope))} | " +
                    $"{Md(AuditWorkbookBuilder.Text(item.Severity))} | {finding.Severity.Likelihood} | {finding.Severity.Impact} | " +
                    $"{finding.Severity.RiskScore} | {finding.Severity.Sla} | {Md(AuditWorkbookBuilder.Text(item.Recommendation))} | " +
                    $"Remediate | {finding.Status} |");
            }
        }

        return sb.ToString();
    }

    // -- OT Server SQL Assessment Readout 3.html -----------------------------

    public static string RenderHtmlReadout(AuditWorkbookModel model)
    {
        var calculator = new ScoreCalculator();
        var payload = new
        {
            target = model.Target,
            generated = model.GeneratedDate,
            workbook = ReportSuiteGenerator.ExcelReportFileName,
            deploymentMode = model.DeploymentMode,
            overallScore = model.OverallScore,
            rating = model.OverallRating.Label,
            coverage = new
            {
                total = model.Coverage.Total,
                deterministic = model.Coverage.Deterministic,
                ai = model.Coverage.AiAssisted,
                manual = model.Coverage.ManualAttestation,
                needsReview = model.Coverage.NeedsReview,
                awaiting = model.Coverage.AwaitingValidation,
                notApplicable = model.Coverage.NotApplicable,
                risks = model.Findings.Count,
            },
            databases = model.Databases.Select(d => new { id = d.Id, name = d.Name }),
            areas = model.Areas.Select(a => new
            {
                number = a.Area.Number,
                name = model.AreaName(a.Area.Number),
                weight = a.Area.Weight,
                score = a.ScorePercent,
                rating = calculator.GetRiskRating(a.ScorePercent).Label,
                items = a.Items.Count,
                validated = a.ScoredCount,
                categories = a.Categories.Select(c => new
                {
                    id = model.CategoryLabel(c.CategoryId),
                    score = c.ScorePercent,
                    rating = calculator.GetRiskRating(c.ScorePercent).Label,
                    validated = c.ScoredCount,
                    items = c.Items.Count,
                }),
            }),
            controls = model.Items.Select(i => new
            {
                id = i.Id,
                area = i.AreaNumber,
                category = model.CategoryLabel(i.CategoryId),
                title = i.Description,
                status = AuditWorkbookModel.Status(i),
                score = i.IsScored ? i.Score : null,
                producedBy = AuditWorkbookModel.ProducedBy(i),
                severity = AuditWorkbookBuilder.Text(i.Severity),
                rationale = AuditWorkbookBuilder.Text(i.Finding),
                databases = AuditWorkbookBuilder.DatabasesOf(i),
            }),
            risks = model.Findings.Select(f => new
            {
                riskId = f.RiskId,
                id = f.Item.Id,
                area = model.AreaName(f.Item.AreaNumber),
                severity = AuditWorkbookBuilder.Text(f.Item.Severity),
                risk = f.Severity.RiskScore,
                likelihood = f.Severity.Likelihood,
                impact = f.Severity.Impact,
                sla = f.Severity.Sla,
                scope = f.Scope,
                impacted = AuditWorkbookBuilder.DatabaseList(f.ImpactedDatabases, AuditWorkbookBuilder.InstanceScope),
                finding = AuditWorkbookBuilder.Text(f.Item.Finding),
                recommendation = AuditWorkbookBuilder.Text(f.Item.Recommendation),
                status = f.Status,
            }),
            accessIssues = model.AccessIssues.Select(a => new
            {
                id = a.Item.Id,
                title = AuditWorkbookBuilder.Text(a.Item.Description),
                failureType = a.FailureType,
                status = AuditWorkbookModel.Status(a.Item),
                detail = a.Detail,
            }),
        };

        return HtmlTemplate
            .Replace("__TARGET__", WebUtility.HtmlEncode(model.Target), StringComparison.Ordinal)
            .Replace("__GENERATED__", WebUtility.HtmlEncode(model.GeneratedDate), StringComparison.Ordinal)
            .Replace("__PAYLOAD__", JsonSerializer.Serialize(payload), StringComparison.Ordinal);
    }

    // -- helpers -------------------------------------------------------------

    private static int CountSeverity(AuditWorkbookModel model, string severity) =>
        model.Findings.Count(f => string.Equals(f.Item.Severity, severity, StringComparison.OrdinalIgnoreCase));

    private static int CountSeverity(IEnumerable<WorkbookFinding> findings, string severity) =>
        findings.Count(f => string.Equals(f.Item.Severity, severity, StringComparison.OrdinalIgnoreCase));

    private static string ScoreText(ChecklistItemResult item) =>
        item.IsScored ? item.Score!.Value.ToString(CultureInfo.InvariantCulture) : AuditWorkbookBuilder.NoValue;

    private static void AppendKeyValues(StringBuilder sb, IReadOnlyList<(string Key, string Value)> rows)
    {
        sb.AppendLine("| Field | Value |");
        sb.AppendLine("|-------|-------|");
        foreach (var (key, value) in rows) sb.AppendLine($"| {key} | {Md(value)} |");
    }

    private static string Link(string fileName) => Uri.EscapeDataString(fileName);

    private static string Md(string? value) =>
        AuditWorkbookBuilder.Text(value)
            .Replace("|", "\\|", StringComparison.Ordinal)
            .Replace("\r", " ", StringComparison.Ordinal)
            .Replace("\n", "<br>", StringComparison.Ordinal);

    private const string HtmlTemplate = """
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>OT Server SQL Assessment Readout — __TARGET__</title>
<style>
:root{--ink:#17283a;--line:#dce2e8;--bg:#f5f7f9;--red:#b4232f;--amber:#d96318;--green:#168256;--blue:#1967a3;--muted:#687583}
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:"Segoe UI",Tahoma,sans-serif;background:var(--bg);color:var(--ink);font-size:14px;line-height:1.55}
header{background:var(--ink);color:#fff;padding:26px max(20px,calc((100vw - 1240px)/2));border-bottom:4px solid #e31837}
header h1{font-size:24px}header p{color:#b6c5d3;font-size:12.5px;margin-top:6px}
nav{display:flex;flex-wrap:wrap;background:#fff;border-bottom:1px solid var(--line);padding:0 max(16px,calc((100vw - 1240px)/2));position:sticky;top:0;z-index:5}
nav button{border:0;background:none;padding:12px 14px;font:inherit;font-size:12px;font-weight:600;color:#66727f;border-bottom:3px solid transparent;cursor:pointer}
nav button.active{color:var(--ink);border-bottom-color:#e31837}
main{max-width:1240px;margin:0 auto;padding:22px 18px 48px}
.panel{display:none}.panel.active{display:block}
h2{font-size:18px;margin-bottom:12px}
.hero{display:grid;grid-template-columns:220px 1fr;background:#fff;border:1px solid var(--line)}
.hero .score{background:var(--ink);color:#fff;padding:22px;font-size:44px;font-weight:700}
.hero .score small{display:block;font-size:12px;margin-top:6px;font-weight:600}
.kpis{display:grid;grid-template-columns:repeat(4,1fr)}
.kpi{padding:16px;border-right:1px solid var(--line);border-bottom:1px solid var(--line)}
.kpi b{display:block;font-size:20px}.kpi span{font-size:10px;text-transform:uppercase;color:var(--muted);font-weight:700}
.card{background:#fff;border:1px solid var(--line);padding:16px;margin-top:18px}
.filters{display:flex;flex-wrap:wrap;gap:10px;margin-bottom:12px}
input,select{padding:7px 9px;border:1px solid #c9d1d9;border-radius:3px;font:inherit}
.tablewrap{overflow:auto;max-height:70vh}
table{width:100%;border-collapse:collapse;min-width:720px}
th{background:var(--ink);color:#fff;font-size:10.5px;text-transform:uppercase;text-align:left;padding:9px;position:sticky;top:0}
td{padding:9px;border-bottom:1px solid var(--line);font-size:12px;vertical-align:top}
tbody tr:hover{background:#f8fafc}
.badge{display:inline-block;padding:2px 8px;border-radius:10px;font-size:10.5px;font-weight:700;background:#edf0f2;color:#59636d}
.sev-Critical{background:#fce8ea;color:#a41f2b}.sev-High{background:#fff0e6;color:#b94e0c}
.sev-Medium{background:#fff5d7;color:#715500}.sev-Low{background:#e8f5ef;color:#147a52}
.chip{display:inline-block;min-width:26px;text-align:center;padding:2px 7px;border-radius:4px;color:#fff;font-weight:700;font-size:10.5px}
.s0{background:#b4232f}.s1{background:#d96318}.s2{background:#c89a00;color:#17283a}.s3{background:#168256}.sna{background:#87929c}
.empty{padding:24px;text-align:center;color:var(--muted)}
@media(max-width:760px){.hero{grid-template-columns:1fr}.kpis{grid-template-columns:1fr 1fr}}
</style>
</head>
<body>
<header>
  <h1>OT Server SQL Assessment Readout</h1>
  <p><strong>__TARGET__</strong> &middot; generated __GENERATED__ &middot; derived from the audit workbook</p>
</header>
<nav id="tabs"></nav>
<main>
  <section class="panel active" id="panel-summary">
    <div class="hero"><div class="score" id="heroScore"></div><div class="kpis" id="heroKpis"></div></div>
    <div class="card"><h2>Area Scorecard</h2><div class="tablewrap"><table><thead><tr><th>#</th><th>Area</th><th>Weight</th><th>Score</th><th>Rating</th><th>Validated</th><th>Items</th></tr></thead><tbody id="areaBody"></tbody></table></div></div>
    <div class="card"><h2>Database Inventory</h2><div class="tablewrap"><table><thead><tr><th>Database ID</th><th>Database Name</th></tr></thead><tbody id="dbBody"></tbody></table></div></div>
  </section>
  <section class="panel" id="panel-checklist">
    <div class="card">
      <h2>Checklist</h2>
      <div class="filters">
        <input id="ctlSearch" type="search" placeholder="Search ref, title or rationale">
        <select id="ctlArea"><option value="">All areas</option></select>
        <select id="ctlStatus"><option value="">All statuses</option></select>
      </div>
      <div class="tablewrap"><table><thead><tr><th>Ref</th><th>Category</th><th>Title</th><th>Status</th><th>Score</th><th>Produced By</th><th>Severity</th><th>Rationale</th></tr></thead><tbody id="ctlBody"></tbody></table></div>
    </div>
  </section>
  <section class="panel" id="panel-risks">
    <div class="card">
      <h2>Risk Register</h2>
      <div class="filters">
        <input id="riskSearch" type="search" placeholder="Search finding or recommendation">
        <select id="riskSeverity"><option value="">All severities</option><option>Critical</option><option>High</option><option>Medium</option><option>Low</option></select>
      </div>
      <div class="tablewrap"><table><thead><tr><th>Risk ID</th><th>Ref</th><th>Area</th><th>Severity</th><th>Risk</th><th>Likelihood</th><th>Impact</th><th>SLA</th><th>Scope</th><th>Finding</th><th>Recommendation</th><th>Status</th></tr></thead><tbody id="riskBody"></tbody></table></div>
    </div>
  </section>
  <section class="panel" id="panel-access">
    <div class="card"><h2>Access &amp; Collection Issues</h2><div class="tablewrap"><table><thead><tr><th>Ref</th><th>Title</th><th>Failure Type</th><th>Status</th><th>Detail</th></tr></thead><tbody id="accessBody"></tbody></table></div></div>
  </section>
</main>
<script>
const data = __PAYLOAD__;
const esc = v => String(v ?? "N/A").replace(/[&<>"']/g, c => ({"&":"&amp;","<":"&lt;",">":"&gt;","\"":"&quot;","'":"&#39;"}[c]));
const pct = v => v === null || v === undefined ? "N/A" : v.toFixed(1) + "%";
const chip = s => s === null || s === undefined ? '<span class="chip sna">-</span>' : '<span class="chip s' + s + '">' + s + '</span>';
const sev = s => '<span class="badge sev-' + esc(s) + '">' + esc(s) + '</span>';

const tabs = [["summary","Assessment Summary"],["checklist","Checklist"],["risks","Risk Register"],["access","Access Issues"]];
document.getElementById("tabs").innerHTML = tabs.map(([id,label],i) =>
  '<button data-panel="' + id + '"' + (i === 0 ? ' class="active"' : '') + '>' + label + '</button>').join("");
document.querySelectorAll("nav button").forEach(btn => btn.addEventListener("click", () => {
  document.querySelectorAll("nav button").forEach(b => b.classList.remove("active"));
  document.querySelectorAll(".panel").forEach(p => p.classList.remove("active"));
  btn.classList.add("active");
  document.getElementById("panel-" + btn.dataset.panel).classList.add("active");
}));

document.getElementById("heroScore").innerHTML = pct(data.overallScore) + "<small>" + esc(data.rating) + "</small>";
document.getElementById("heroKpis").innerHTML = [
  [data.coverage.total, "Controls"], [data.coverage.deterministic, "Deterministic"],
  [data.coverage.manual, "Manual"], [data.coverage.ai, "AI analysis"],
  [data.coverage.risks, "Active risks"], [data.coverage.needsReview, "Needs review"],
  [data.coverage.awaiting, "Awaiting"], [data.coverage.notApplicable, "Not applicable"]
].map(([v, l]) => '<div class="kpi"><b>' + v + '</b><span>' + l + '</span></div>').join("");

document.getElementById("areaBody").innerHTML = data.areas.map(a =>
  "<tr><td>" + a.number + "</td><td>" + esc(a.name) + "</td><td>" + a.weight + "%</td><td>" + pct(a.score) +
  "</td><td>" + esc(a.rating) + "</td><td>" + a.validated + "</td><td>" + a.items + "</td></tr>").join("");

document.getElementById("dbBody").innerHTML = data.databases.length
  ? data.databases.map(d => "<tr><td>" + esc(d.id) + "</td><td>" + esc(d.name) + "</td></tr>").join("")
  : '<tr><td colspan="2" class="empty">No database-scoped evidence was recorded.</td></tr>';

const areaSelect = document.getElementById("ctlArea");
[...new Set(data.controls.map(c => c.area))].sort((a, b) => a - b).forEach(a => {
  const o = document.createElement("option"); o.value = a; o.textContent = "Area " + a; areaSelect.appendChild(o);
});
const statusSelect = document.getElementById("ctlStatus");
[...new Set(data.controls.map(c => c.status))].sort().forEach(s => {
  const o = document.createElement("option"); o.value = s; o.textContent = s; statusSelect.appendChild(o);
});

function renderControls() {
  const q = document.getElementById("ctlSearch").value.toLowerCase();
  const area = areaSelect.value, status = statusSelect.value;
  const rows = data.controls.filter(c =>
    (!area || String(c.area) === area) && (!status || c.status === status) &&
    (!q || (c.id + " " + c.title + " " + c.rationale).toLowerCase().includes(q)));
  document.getElementById("ctlBody").innerHTML = rows.length ? rows.map(c =>
    "<tr><td>" + esc(c.id) + "</td><td>" + esc(c.category) + "</td><td>" + esc(c.title) + "</td><td>" +
    esc(c.status) + "</td><td>" + chip(c.score) + "</td><td>" + esc(c.producedBy) + "</td><td>" +
    sev(c.severity) + "</td><td>" + esc(c.rationale) + "</td></tr>").join("")
    : '<tr><td colspan="8" class="empty">No controls match the current filters.</td></tr>';
}
["ctlSearch","ctlArea","ctlStatus"].forEach(id =>
  document.getElementById(id).addEventListener("input", renderControls));
renderControls();

function renderRisks() {
  const q = document.getElementById("riskSearch").value.toLowerCase();
  const severity = document.getElementById("riskSeverity").value;
  const rows = data.risks.filter(r => (!severity || r.severity === severity) &&
    (!q || (r.id + " " + r.finding + " " + r.recommendation).toLowerCase().includes(q)));
  document.getElementById("riskBody").innerHTML = rows.length ? rows.map(r =>
    "<tr><td>" + esc(r.riskId) + "</td><td>" + esc(r.id) + "</td><td>" + esc(r.area) + "</td><td>" +
    sev(r.severity) + "</td><td>" + r.risk + "</td><td>" + esc(r.likelihood) + "</td><td>" + esc(r.impact) +
    "</td><td>" + esc(r.sla) + "</td><td>" + esc(r.scope) + "</td><td>" + esc(r.finding) + "</td><td>" +
    esc(r.recommendation) + "</td><td>" + esc(r.status) + "</td></tr>").join("")
    : '<tr><td colspan="12" class="empty">No risks match the current filters.</td></tr>';
}
["riskSearch","riskSeverity"].forEach(id =>
  document.getElementById(id).addEventListener("input", renderRisks));
renderRisks();

document.getElementById("accessBody").innerHTML = data.accessIssues.length
  ? data.accessIssues.map(a => "<tr><td>" + esc(a.id) + "</td><td>" + esc(a.title) + "</td><td>" +
      esc(a.failureType) + "</td><td>" + esc(a.status) + "</td><td>" + esc(a.detail) + "</td></tr>").join("")
  : '<tr><td colspan="5" class="empty">No access or collection failures were recorded.</td></tr>';
</script>
</body>
</html>
""";
}
