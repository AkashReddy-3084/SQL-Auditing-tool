using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text.Json;
using ClosedXML.Excel;

namespace SqlAuditor.Reporting;

// =============================================================================
// CHECKLIST CATALOG — resolves human-readable Area / Category names
// =============================================================================

/// <summary>
/// Loads Area and Category (sub-area) display names from
/// <c>master-checklist.json</c> so the Excel report can show real titles
/// (e.g. "1.2" → "Data Architecture (Staging / ODS / DW / Marts)") instead of
/// bare id fragments. Falls back to <see cref="AreaCatalog"/> when the file is
/// absent or unparsable.
/// </summary>
public sealed class ChecklistCatalog
{
    private readonly Dictionary<int, string> _areaNames = new();
    private readonly Dictionary<string, string> _categoryNames = new(StringComparer.OrdinalIgnoreCase);

    public string AreaName(int number) =>
        _areaNames.TryGetValue(number, out var name) && !string.IsNullOrWhiteSpace(name)
            ? name
            : AreaCatalog.Get(number).Name;

    public string CategoryName(string categoryId) =>
        _categoryNames.TryGetValue(categoryId, out var name) && !string.IsNullOrWhiteSpace(name)
            ? name
            : categoryId;

    /// <summary>Loads a catalog from an explicit path, or an empty catalog if the file is missing.</summary>
    public static ChecklistCatalog Load(string? masterChecklistPath)
    {
        var catalog = new ChecklistCatalog();
        if (string.IsNullOrWhiteSpace(masterChecklistPath) || !File.Exists(masterChecklistPath))
            return catalog;

        try
        {
            using var doc = JsonDocument.Parse(File.ReadAllText(masterChecklistPath));
            var root = doc.RootElement;
            if (root.ValueKind != JsonValueKind.Object ||
                !root.TryGetProperty("areas", out var areas) ||
                areas.ValueKind != JsonValueKind.Array)
                return catalog;

            foreach (var area in areas.EnumerateArray())
            {
                var areaId = area.TryGetProperty("id", out var aid) ? aid.GetString() : null;
                var areaTitle = area.TryGetProperty("title", out var at) ? at.GetString() : null;
                if (int.TryParse(areaId, out var num) && !string.IsNullOrWhiteSpace(areaTitle))
                    catalog._areaNames[num] = CleanTitle(areaTitle!);

                if (area.TryGetProperty("sub_areas", out var subs) && subs.ValueKind == JsonValueKind.Array)
                {
                    foreach (var sub in subs.EnumerateArray())
                    {
                        var subId = sub.TryGetProperty("id", out var sid) ? sid.GetString() : null;
                        var subTitle = sub.TryGetProperty("title", out var st) ? st.GetString() : null;
                        if (!string.IsNullOrWhiteSpace(subId) && !string.IsNullOrWhiteSpace(subTitle))
                            catalog._categoryNames[subId!] = CleanTitle(subTitle!);
                    }
                }
            }
        }
        catch
        {
            // Malformed catalog — fall back to AreaCatalog / raw ids.
        }
        return catalog;
    }

    /// <summary>Discovers <c>master-checklist.json</c> by walking up from a start directory.</summary>
    public static ChecklistCatalog Discover(string? startDirectory)
    {
        var dir = string.IsNullOrWhiteSpace(startDirectory) ? null : new DirectoryInfo(startDirectory);
        while (dir != null)
        {
            foreach (var name in new[] { "master-checklist.json", "master_checklist.json" })
            {
                var candidate = Path.Combine(dir.FullName, "Backend", "checklist", name);
                if (File.Exists(candidate)) return Load(candidate);
            }
            dir = dir.Parent;
        }
        return new ChecklistCatalog();
    }

    // Strips a trailing " (Weight: 8%)" style suffix from an area title.
    private static string CleanTitle(string title)
    {
        var idx = title.IndexOf(" (Weight", StringComparison.OrdinalIgnoreCase);
        return (idx >= 0 ? title[..idx] : title).Trim();
    }
}

// =============================================================================
// EXCEL REPORT GENERATOR
// =============================================================================

/// <summary>
/// Produces <c>audit_report.xlsx</c> — a 4-tab workbook (Summary, Area Detail,
/// Checklists, Risk Register) — from the enriched <c>checklist_results.json</c>.
/// Scoring, weighting and risk ratings are computed with the exact same
/// <see cref="ScoreCalculator"/> / <see cref="ReportInputEnricher"/> logic used
/// by <see cref="SummaryReportGenerator"/> for <c>final_report.md</c>.
/// </summary>
public sealed class ExcelReportGenerator
{
    private readonly ScoreCalculator _calculator = new();
    private readonly ReportInputEnricher _enricher = new();

    // ---- Palette ------------------------------------------------------------
    private static readonly XLColor HeaderFill = XLColor.FromHtml("#1F4E79"); // navy/slate
    private static readonly XLColor HeaderFont = XLColor.White;
    private static readonly XLColor Zebra = XLColor.FromHtml("#F2F4F7");
    private static readonly XLColor GridBorder = XLColor.FromHtml("#D0D5DD");
    private static readonly XLColor TitleFill = XLColor.FromHtml("#12355B");

    private static readonly XLColor SoftRedFill = XLColor.FromHtml("#F8D7DA");
    private static readonly XLColor SoftRedFont = XLColor.FromHtml("#842029");
    private static readonly XLColor SoftAmberFill = XLColor.FromHtml("#FFF3CD");
    private static readonly XLColor SoftAmberFont = XLColor.FromHtml("#664D03");
    private static readonly XLColor SoftGreenFill = XLColor.FromHtml("#D1E7DD");
    private static readonly XLColor SoftGreenFont = XLColor.FromHtml("#0F5132");

    private const double MaxColumnWidth = 60d;

    /// <summary>
    /// Generates the workbook from a results JSON file.
    /// </summary>
    /// <param name="resultsJsonPath">Path to <c>checklist_results.json</c>.</param>
    /// <param name="outputPath">Destination <c>.xlsx</c> path.</param>
    /// <param name="metadata">Optional report metadata (date / auditors).</param>
    /// <param name="masterChecklistPath">
    /// Optional explicit path to <c>master-checklist.json</c>; when null it is
    /// auto-discovered relative to the results file.
    /// </param>
    public string GenerateFromFile(
        string resultsJsonPath,
        string outputPath,
        ReportMetadata? metadata = null,
        string? masterChecklistPath = null)
    {
        var items = ChecklistResultsLoader.Load(resultsJsonPath);
        var catalog = masterChecklistPath != null
            ? ChecklistCatalog.Load(masterChecklistPath)
            : ChecklistCatalog.Discover(Path.GetDirectoryName(Path.GetFullPath(resultsJsonPath)));

        Generate(items, metadata ?? new ReportMetadata(), catalog, outputPath);
        return outputPath;
    }

    public void Generate(
        IEnumerable<ChecklistItemResult> rawItems,
        ReportMetadata metadata,
        ChecklistCatalog catalog,
        string outputPath)
    {
        // Identical enrichment + scoring path as the Markdown report.
        var items = _enricher.Enrich(rawItems);
        var areaScores = _calculator.ComputeAreaScores(items);
        var overall = _calculator.ComputeOverallScore(areaScores);
        var overallRating = _calculator.GetRiskRating(overall);

        using var wb = new XLWorkbook();
        BuildSummarySheet(wb, metadata, items, areaScores, overall, overallRating);
        BuildAreaDetailSheet(wb, areaScores, catalog);
        BuildChecklistsSheet(wb, items, areaScores, catalog);
        BuildRiskRegisterSheet(wb, items);

        Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(outputPath))!);
        wb.SaveAs(outputPath);
    }

    // =========================================================================
    // TAB 1 — SUMMARY
    // =========================================================================

    private void BuildSummarySheet(
        XLWorkbook wb,
        ReportMetadata m,
        IReadOnlyList<ChecklistItemResult> items,
        IReadOnlyList<AreaScore> areaScores,
        double? overall,
        RiskRating overallRating)
    {
        var ws = wb.Worksheets.Add("Summary");

        // ---- Title band -----------------------------------------------------
        ws.Range(1, 1, 1, 9).Merge();
        var title = ws.Cell(1, 1);
        title.Value = "SQL Audit — Executive Summary";
        title.Style.Fill.BackgroundColor = TitleFill;
        title.Style.Font.FontColor = XLColor.White;
        title.Style.Font.Bold = true;
        title.Style.Font.FontSize = 16;
        title.Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Center;
        title.Style.Alignment.Vertical = XLAlignmentVerticalValues.Center;
        ws.Row(1).Height = 26;

        ws.Range(2, 1, 2, 9).Merge();
        var subtitle = ws.Cell(2, 1);
        subtitle.Value = $"Report Date: {m.ReportDate}    •    Auditor(s): {m.Auditors}";
        subtitle.Style.Font.Italic = true;
        subtitle.Style.Font.FontColor = XLColor.FromHtml("#475467");
        subtitle.Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Center;

        // ---- KPI cards ------------------------------------------------------
        var passed = CountOutcome(items, "pass");
        var failed = CountOutcome(items, "fail");
        var needs = CountOutcome(items, "needsreview") + CountOutcome(items, "needs review");
        var evaluated = items.Count;

        WriteKpiCard(ws, 4, 1, 3, "Overall Score", Pct(overall), NeutralStatus());
        WriteKpiCard(ws, 4, 4, 3, "Overall Risk Rating", overallRating.Label, StatusFor(overallRating.Label));
        WriteKpiCard(ws, 4, 7, 3, "Total Checks Evaluated",
            $"{evaluated}", NeutralStatus(),
            subText: $"Passed {passed}  /  Failed {failed}  /  Needs Review {needs}");

        // ---- Area Scorecard -------------------------------------------------
        var row = 8;
        row = SectionLabel(ws, row, 1, 5, "Area Scorecard");
        var scHeaderRow = row;
        var scRows = new List<string[]>();
        foreach (var a in areaScores)
        {
            var rating = _calculator.GetRiskRating(a.ScorePercent);
            var ratingLabel = a.ScorePercent is null ? "Not Assessed" : rating.Label;
            scRows.Add(new[]
            {
                a.Area.Number.ToString(CultureInfo.InvariantCulture),
                a.Area.Name, // canonical short name — matches final_report.md scorecard
                a.Area.Weight.ToString("0", CultureInfo.InvariantCulture) + "%",
                Pct(a.ScorePercent),
                ratingLabel,
            });
        }

        var scAligns = new[]
        {
            XLAlignmentHorizontalValues.Center, XLAlignmentHorizontalValues.Left,
            XLAlignmentHorizontalValues.Right, XLAlignmentHorizontalValues.Right,
            XLAlignmentHorizontalValues.Center,
        };
        var scLast = WriteTable(ws, scHeaderRow, 1,
            new[] { "#", "Area", "Weight (%)", "Score", "Rating" },
            scRows,
            scAligns,
            wrap: new[] { false, false, false, false, false },
            statusColumns: new[] { 5 });

        // Summary rows: total weight + overall weighted score.
        var totalWeight = areaScores.Sum(a => a.Area.Weight);
        var sumRow = scLast + 1;
        WriteSummaryRow(ws, sumRow, 1, 5, new[]
        {
            "", "Total Weight", totalWeight.ToString("0", CultureInfo.InvariantCulture) + "%", "", "",
        });
        WriteSummaryRow(ws, sumRow + 1, 1, 5, new[]
        {
            "", "Overall Weighted Score", "", Pct(overall), overallRating.Label,
        });
        ApplyStatusColor(ws.Cell(sumRow + 1, 5), overallRating.Label);

        // ---- Coverage by technique -----------------------------------------
        row = sumRow + 3;
        row = SectionLabel(ws, row, 1, 6, "Coverage by Technique");
        var covHeaderRow = row;
        var techniques = new[] { "Script", "AI-MCP", "AI-Manual", "Manual" };
        var covRows = new List<string[]>();
        foreach (var tech in techniques)
        {
            var techItems = items.Where(i => NormalizeTechnique(i.Technique) == tech).ToList();
            covRows.Add(TechniqueRow(tech, techItems));
        }
        covRows.Add(TechniqueRow("Total", items.ToList()));

        var covAligns = new[]
        {
            XLAlignmentHorizontalValues.Left, XLAlignmentHorizontalValues.Right,
            XLAlignmentHorizontalValues.Right, XLAlignmentHorizontalValues.Right,
            XLAlignmentHorizontalValues.Right, XLAlignmentHorizontalValues.Right,
        };
        var covLast = WriteTable(ws, covHeaderRow, 1,
            new[] { "Technique", "Total Executed", "Passed", "Failed", "Needs Review", "Pass Rate (%)" },
            covRows,
            covAligns,
            wrap: new[] { false, false, false, false, false, false },
            statusColumns: Array.Empty<int>());
        // Emphasize the trailing Total row.
        ws.Range(covLast, 1, covLast, 6).Style.Font.Bold = true;

        Finalize(ws, freezeRows: 3, autoFilterRange: null);
    }

    private string[] TechniqueRow(string label, List<ChecklistItemResult> techItems)
    {
        var total = techItems.Count;
        var p = CountOutcome(techItems, "pass");
        var f = CountOutcome(techItems, "fail");
        var nr = CountOutcome(techItems, "needsreview") + CountOutcome(techItems, "needs review");
        var rate = total == 0 ? (double?)null : (double)p / total * 100.0;
        return new[]
        {
            label,
            total.ToString(CultureInfo.InvariantCulture),
            p.ToString(CultureInfo.InvariantCulture),
            f.ToString(CultureInfo.InvariantCulture),
            nr.ToString(CultureInfo.InvariantCulture),
            Pct(rate),
        };
    }

    // =========================================================================
    // TAB 2 — AREA DETAIL
    // =========================================================================

    private void BuildAreaDetailSheet(
        XLWorkbook wb,
        IReadOnlyList<AreaScore> areaScores,
        ChecklistCatalog catalog)
    {
        var ws = wb.Worksheets.Add("Area Detail");
        var row = 1;

        foreach (var a in areaScores)
        {
            var areaName = catalog.AreaName(a.Area.Number);
            var rating = _calculator.GetRiskRating(a.ScorePercent);
            var ratingLabel = a.ScorePercent is null ? "Not Assessed" : rating.Label;

            // Area banner.
            ws.Range(row, 1, row, 5).Merge();
            var banner = ws.Cell(row, 1);
            banner.Value = $"Area {a.Area.Number}: {areaName}";
            banner.Style.Fill.BackgroundColor = TitleFill;
            banner.Style.Font.FontColor = XLColor.White;
            banner.Style.Font.Bold = true;
            banner.Style.Font.FontSize = 13;
            banner.Style.Alignment.Vertical = XLAlignmentVerticalValues.Center;
            ws.Row(row).Height = 20;
            row += 2;

            // Area Summary Table.
            var evaluated = a.ScoredCount;
            var passed = a.Items.Count(i => i.IsScored && IsOutcome(i, "pass"));
            var areaPassRate = evaluated == 0 ? (double?)null : (double)passed / evaluated * 100.0;
            var summaryHeader = row;
            var summaryLast = WriteTable(ws, summaryHeader, 1,
                new[] { "Area", "Score", "Rating", "# Evaluated Checks", "Pass Rate (%)" },
                new[]
                {
                    new[]
                    {
                        areaName, Pct(a.ScorePercent), ratingLabel,
                        evaluated.ToString(CultureInfo.InvariantCulture), Pct(areaPassRate),
                    },
                },
                new[]
                {
                    XLAlignmentHorizontalValues.Left, XLAlignmentHorizontalValues.Right,
                    XLAlignmentHorizontalValues.Center, XLAlignmentHorizontalValues.Right,
                    XLAlignmentHorizontalValues.Right,
                },
                wrap: new[] { false, false, false, false, false },
                statusColumns: new[] { 3 });
            row = summaryLast + 2;

            if (a.Items.Count == 0)
            {
                var note = ws.Cell(row, 1);
                note.Value = "No evaluated checks for this area.";
                note.Style.Font.Italic = true;
                note.Style.Font.FontColor = XLColor.FromHtml("#667085");
                row += 2;
                continue;
            }

            // Category Breakdown Table.
            row = SectionLabel(ws, row, 1, 4, "Category Breakdown");
            var catHeader = row;
            var catRows = new List<string[]>();
            foreach (var cat in a.Categories)
            {
                var cr = _calculator.GetRiskRating(cat.ScorePercent);
                catRows.Add(new[]
                {
                    $"{cat.CategoryId} — {catalog.CategoryName(cat.CategoryId)}",
                    Pct(cat.ScorePercent),
                    cat.ScorePercent is null ? "Not Assessed" : cr.Label,
                    cat.ScoredCount.ToString(CultureInfo.InvariantCulture),
                });
            }
            var catLast = WriteTable(ws, catHeader, 1,
                new[] { "Category", "Score", "Rating", "# Evaluated Checks" },
                catRows,
                new[]
                {
                    XLAlignmentHorizontalValues.Left, XLAlignmentHorizontalValues.Right,
                    XLAlignmentHorizontalValues.Center, XLAlignmentHorizontalValues.Right,
                },
                wrap: new[] { true, false, false, false },
                statusColumns: new[] { 3 });
            row = catLast + 2;

            // Checklist Items Status Table.
            row = SectionLabel(ws, row, 1, 5, "Checklist Items");
            var itemHeader = row;
            var itemRows = new List<string[]>();
            foreach (var i in a.Items.OrderBy(i => i.Id, StringComparer.Ordinal))
            {
                var score = i.NotApplicable == true ? "N/A" : (i.Score?.ToString(CultureInfo.InvariantCulture) ?? "N/A");
                itemRows.Add(new[]
                {
                    i.Id,
                    i.Description,
                    NA(i.Outcome),
                    score,
                    NA(i.Severity),
                });
            }
            var itemLast = WriteTable(ws, itemHeader, 1,
                new[] { "Item Id", "Checklist Item (Description)", "Outcome", "Score", "Severity" },
                itemRows,
                new[]
                {
                    XLAlignmentHorizontalValues.Center, XLAlignmentHorizontalValues.Left,
                    XLAlignmentHorizontalValues.Center, XLAlignmentHorizontalValues.Right,
                    XLAlignmentHorizontalValues.Center,
                },
                wrap: new[] { false, true, false, false, false },
                statusColumns: new[] { 3, 5 });
            row = itemLast + 3;
        }

        Finalize(ws, freezeRows: 0, autoFilterRange: null);
    }

    // =========================================================================
    // TAB 3 — CHECKLISTS
    // =========================================================================

    private void BuildChecklistsSheet(
        XLWorkbook wb,
        IReadOnlyList<ChecklistItemResult> items,
        IReadOnlyList<AreaScore> areaScores,
        ChecklistCatalog catalog)
    {
        var ws = wb.Worksheets.Add("Checklists");

        var headers = new[]
        {
            "Item Id", "Area Name", "Category Name", "Checklist Name", "Evaluation Type",
            "Outcome", "Score", "Severity", "Findings", "Evidence", "Recommendations", "Databases Verified",
        };

        var rows = new List<string[]>();
        foreach (var i in items.OrderBy(i => i.Id, StringComparer.Ordinal))
        {
            var score = i.NotApplicable == true ? "N/A" : (i.Score?.ToString(CultureInfo.InvariantCulture) ?? "N/A");
            rows.Add(new[]
            {
                i.Id,
                catalog.AreaName(i.AreaNumber),
                catalog.CategoryName(i.CategoryId),
                NA(i.Description),
                NA(i.Technique),
                NA(i.Outcome),
                score,
                NA(i.Severity),
                NA(i.Finding),
                NA(i.Evidence),
                NA(i.Recommendation),
                NA(i.DatabasesVerified),
            });
        }

        var aligns = new[]
        {
            XLAlignmentHorizontalValues.Center, // Item Id
            XLAlignmentHorizontalValues.Left,   // Area Name
            XLAlignmentHorizontalValues.Left,   // Category Name
            XLAlignmentHorizontalValues.Left,   // Checklist Name
            XLAlignmentHorizontalValues.Center, // Evaluation Type
            XLAlignmentHorizontalValues.Center, // Outcome
            XLAlignmentHorizontalValues.Right,  // Score
            XLAlignmentHorizontalValues.Center, // Severity
            XLAlignmentHorizontalValues.Left,   // Findings
            XLAlignmentHorizontalValues.Left,   // Evidence
            XLAlignmentHorizontalValues.Left,   // Recommendations
            XLAlignmentHorizontalValues.Left,   // Databases Verified
        };
        var wrap = new[] { false, false, false, true, false, false, false, false, true, true, true, true };

        var last = WriteTable(ws, 1, 1, headers, rows, aligns, wrap, statusColumns: new[] { 6, 8 });

        var filterRange = last >= 1 ? ws.Range(1, 1, Math.Max(last, 1), headers.Length) : null;
        Finalize(ws, freezeRows: 1, autoFilterRange: filterRange);
    }

    // =========================================================================
    // TAB 4 — RISK REGISTER
    // =========================================================================

    private void BuildRiskRegisterSheet(
        XLWorkbook wb,
        IReadOnlyList<ChecklistItemResult> items)
    {
        var ws = wb.Worksheets.Add("Risk Register");

        var headers = new[]
        {
            "Item Id", "Checklist Item", "Severity", "Risk Impact", "Databases Verified",
            "Findings", "Evidence", "Recommendations",
        };

        var risks = items
            .Where(IsActiveRisk)
            .OrderByDescending(i => SeverityRank(i.Severity))
            .ThenBy(i => i.Id, StringComparer.Ordinal)
            .ToList();

        var rows = new List<string[]>();
        foreach (var i in risks)
        {
            rows.Add(new[]
            {
                i.Id,
                NA(i.Description),
                NA(i.Severity),
                NA(i.RiskImpact),
                NA(i.DatabasesVerified),
                NA(i.Finding),
                NA(i.Evidence),
                NA(i.Recommendation),
            });
        }

        var aligns = new[]
        {
            XLAlignmentHorizontalValues.Center, // Item Id
            XLAlignmentHorizontalValues.Left,   // Checklist Item
            XLAlignmentHorizontalValues.Center, // Severity
            XLAlignmentHorizontalValues.Left,   // Risk Impact
            XLAlignmentHorizontalValues.Left,   // Databases Verified
            XLAlignmentHorizontalValues.Left,   // Findings
            XLAlignmentHorizontalValues.Left,   // Evidence
            XLAlignmentHorizontalValues.Left,   // Recommendations
        };
        var wrap = new[] { false, true, false, true, true, true, true, true };

        if (rows.Count == 0)
        {
            // Still render headers so the sheet is not blank / filterable.
            WriteTable(ws, 1, 1, headers, new List<string[]>(), aligns, wrap, statusColumns: Array.Empty<int>());
            var note = ws.Cell(2, 1);
            note.Value = "No active risks: no items failed or carry Critical/High/Medium severity or a score below 3.";
            note.Style.Font.Italic = true;
            note.Style.Font.FontColor = XLColor.FromHtml("#667085");
            Finalize(ws, freezeRows: 1, autoFilterRange: ws.Range(1, 1, 1, headers.Length));
            return;
        }

        var last = WriteTable(ws, 1, 1, headers, rows, aligns, wrap, statusColumns: new[] { 3 });
        Finalize(ws, freezeRows: 1, autoFilterRange: ws.Range(1, 1, last, headers.Length));
    }

    // Active risk filter: Outcome == Fail OR Severity in {Critical, High, Medium} OR Score < 3.
    private static bool IsActiveRisk(ChecklistItemResult i)
    {
        if (IsOutcome(i, "fail")) return true;
        if (i.Severity is not null)
        {
            var s = i.Severity.Trim();
            if (s.Equals("Critical", StringComparison.OrdinalIgnoreCase) ||
                s.Equals("High", StringComparison.OrdinalIgnoreCase) ||
                s.Equals("Medium", StringComparison.OrdinalIgnoreCase))
                return true;
        }
        if (i.Score.HasValue && i.Score.Value < 3) return true;
        return false;
    }

    // =========================================================================
    // TABLE / STYLE PRIMITIVES
    // =========================================================================

    /// <summary>
    /// Writes a styled table (navy header + zebra body + borders + alignment)
    /// and returns the last body row written (or the header row when no data).
    /// </summary>
    private int WriteTable(
        IXLWorksheet ws,
        int headerRow,
        int startCol,
        string[] headers,
        IEnumerable<string[]> rows,
        XLAlignmentHorizontalValues[] aligns,
        bool[] wrap,
        int[] statusColumns)
    {
        var cols = headers.Length;

        // Header.
        for (var c = 0; c < cols; c++)
        {
            var cell = ws.Cell(headerRow, startCol + c);
            cell.Value = headers[c];
            cell.Style.Fill.BackgroundColor = HeaderFill;
            cell.Style.Font.FontColor = HeaderFont;
            cell.Style.Font.Bold = true;
            cell.Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Center;
            cell.Style.Alignment.Vertical = XLAlignmentVerticalValues.Center;
            cell.Style.Alignment.WrapText = true;
        }

        var r = headerRow;
        var statusSet = new HashSet<int>(statusColumns);
        foreach (var row in rows)
        {
            r++;
            for (var c = 0; c < cols; c++)
            {
                var cell = ws.Cell(r, startCol + c);
                cell.Value = c < row.Length ? row[c] : string.Empty;
                cell.Style.Alignment.Horizontal = aligns[c];
                cell.Style.Alignment.Vertical = XLAlignmentVerticalValues.Top;
                if (wrap[c]) cell.Style.Alignment.WrapText = true;

                // Zebra striping on even body rows.
                if ((r - headerRow) % 2 == 0)
                    cell.Style.Fill.BackgroundColor = Zebra;

                // Conditional status colour overrides zebra for status columns.
                if (statusSet.Contains(c + 1))
                    ApplyStatusColor(cell, cell.GetString());
            }
        }

        var lastRow = r == headerRow ? headerRow : r;

        // Borders across the whole table.
        var range = ws.Range(headerRow, startCol, lastRow, startCol + cols - 1);
        range.Style.Border.InsideBorder = XLBorderStyleValues.Thin;
        range.Style.Border.OutsideBorder = XLBorderStyleValues.Thin;
        range.Style.Border.InsideBorderColor = GridBorder;
        range.Style.Border.OutsideBorderColor = GridBorder;

        return r == headerRow ? headerRow : r;
    }

    private static void WriteSummaryRow(IXLWorksheet ws, int row, int startCol, int cols, string[] values)
    {
        for (var c = 0; c < cols; c++)
        {
            var cell = ws.Cell(row, startCol + c);
            cell.Value = c < values.Length ? values[c] : string.Empty;
            cell.Style.Font.Bold = true;
            cell.Style.Fill.BackgroundColor = XLColor.FromHtml("#E7EDF5");
            cell.Style.Alignment.Horizontal = c <= 1
                ? XLAlignmentHorizontalValues.Left
                : XLAlignmentHorizontalValues.Right;
        }
        var range = ws.Range(row, startCol, row, startCol + cols - 1);
        range.Style.Border.OutsideBorder = XLBorderStyleValues.Thin;
        range.Style.Border.InsideBorder = XLBorderStyleValues.Thin;
        range.Style.Border.OutsideBorderColor = GridBorder;
        range.Style.Border.InsideBorderColor = GridBorder;
    }

    private static int SectionLabel(IXLWorksheet ws, int row, int startCol, int cols, string text)
    {
        ws.Range(row, startCol, row, startCol + cols - 1).Merge();
        var cell = ws.Cell(row, startCol);
        cell.Value = text;
        cell.Style.Font.Bold = true;
        cell.Style.Font.FontSize = 12;
        cell.Style.Font.FontColor = XLColor.FromHtml("#1F4E79");
        cell.Style.Alignment.Vertical = XLAlignmentVerticalValues.Center;
        return row + 1; // header of the following table goes on the next row
    }

    private static void WriteKpiCard(
        IXLWorksheet ws, int row, int startCol, int span,
        string label, string value, (XLColor fill, XLColor font)? valueStatus,
        string? subText = null)
    {
        // Label band.
        ws.Range(row, startCol, row, startCol + span - 1).Merge();
        var labelCell = ws.Cell(row, startCol);
        labelCell.Value = label;
        labelCell.Style.Fill.BackgroundColor = HeaderFill;
        labelCell.Style.Font.FontColor = HeaderFont;
        labelCell.Style.Font.Bold = true;
        labelCell.Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Center;
        labelCell.Style.Alignment.Vertical = XLAlignmentVerticalValues.Center;

        // Value band (spans two rows).
        ws.Range(row + 1, startCol, row + 2, startCol + span - 1).Merge();
        var valueCell = ws.Cell(row + 1, startCol);
        valueCell.Value = value;
        valueCell.Style.Font.Bold = true;
        valueCell.Style.Font.FontSize = 18;
        valueCell.Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Center;
        valueCell.Style.Alignment.Vertical = XLAlignmentVerticalValues.Center;
        if (valueStatus is { } vs)
        {
            valueCell.Style.Fill.BackgroundColor = vs.fill;
            valueCell.Style.Font.FontColor = vs.font;
        }
        else
        {
            valueCell.Style.Fill.BackgroundColor = XLColor.FromHtml("#EAEEF4");
        }

        // Optional sub-text under the value.
        if (subText != null)
        {
            ws.Range(row + 3, startCol, row + 3, startCol + span - 1).Merge();
            var subCell = ws.Cell(row + 3, startCol);
            subCell.Value = subText;
            subCell.Style.Font.FontSize = 9;
            subCell.Style.Font.FontColor = XLColor.FromHtml("#475467");
            subCell.Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Center;
        }

        // Card border.
        var range = ws.Range(row, startCol, row + 2, startCol + span - 1);
        range.Style.Border.OutsideBorder = XLBorderStyleValues.Medium;
        range.Style.Border.OutsideBorderColor = HeaderFill;
    }

    /// <summary>Applies auto-fit (clamped to 60), freeze panes and an optional auto-filter.</summary>
    private static void Finalize(IXLWorksheet ws, int freezeRows, IXLRange? autoFilterRange)
    {
        ws.Columns().AdjustToContents();
        foreach (var col in ws.ColumnsUsed())
        {
            if (col.Width > MaxColumnWidth) col.Width = MaxColumnWidth;
        }
        ws.Rows().AdjustToContents();

        if (autoFilterRange != null)
            autoFilterRange.SetAutoFilter();

        if (freezeRows > 0)
            ws.SheetView.FreezeRows(freezeRows);
    }

    // =========================================================================
    // STATUS COLOURS
    // =========================================================================

    private void ApplyStatusColor(IXLCell cell, string value)
    {
        var status = StatusFor(value);
        if (status is { } s)
        {
            cell.Style.Fill.BackgroundColor = s.fill;
            cell.Style.Font.FontColor = s.font;
        }
    }

    // Maps an Outcome / Severity / Rating label to a soft Red/Amber/Green swatch.
    private static (XLColor fill, XLColor font)? StatusFor(string? value)
    {
        if (string.IsNullOrWhiteSpace(value)) return null;
        var v = value.Trim().ToLowerInvariant();

        // Red — failures / critical / high.
        if (v is "fail" or "critical" or "high") return (SoftRedFill, SoftRedFont);
        // Amber — partial / medium / needs review.
        if (v is "medium" or "needsreview" or "needs review" or "partial") return (SoftAmberFill, SoftAmberFont);
        // Green — passes / low / best practice / benign.
        if (v is "pass" or "low" or "best practice" or "informational" or "excellent" or "good")
            return (SoftGreenFill, SoftGreenFont);

        return null; // "Not Assessed", numbers, etc. — leave as-is.
    }

    private static (XLColor fill, XLColor font)? NeutralStatus() => null;

    // =========================================================================
    // SMALL HELPERS
    // =========================================================================

    private static int SeverityRank(string? severity) => (severity?.Trim().ToLowerInvariant()) switch
    {
        "critical" => 5,
        "high" => 4,
        "medium" => 3,
        "low" => 2,
        "informational" => 1,
        _ => 0,
    };

    private static string NormalizeTechnique(string? technique)
    {
        var t = technique?.Trim();
        if (string.IsNullOrWhiteSpace(t)) return string.Empty;
        return t.ToLowerInvariant() switch
        {
            "script" => "Script",
            "ai-mcp" or "aimcp" or "mcp" => "AI-MCP",
            "ai-manual" or "aimanual" => "AI-Manual",
            "manual" => "Manual",
            _ => t,
        };
    }

    private static bool IsOutcome(ChecklistItemResult i, string outcome) =>
        string.Equals(i.Outcome?.Trim(), outcome, StringComparison.OrdinalIgnoreCase);

    private static int CountOutcome(IEnumerable<ChecklistItemResult> items, string outcome) =>
        items.Count(i => IsOutcome(i, outcome));

    private static string Pct(double? value) =>
        value is null ? "N/A" : value.Value.ToString("0.0", CultureInfo.InvariantCulture) + "%";

    private static string NA(string? value) =>
        string.IsNullOrWhiteSpace(value) ? "N/A" : value.Trim();
}
