using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using ClosedXML.Excel;

namespace SqlAuditor.Reporting;

/// <summary>
/// Writes the audit workbook from <see cref="AuditWorkbookModel"/>, matching the client
/// workbook layout: Inventory, Summary, Area Detail, Checklist, one sheet per database,
/// Access Issues, Findings and Risk Register.
/// </summary>
public sealed class AuditWorkbookWriter
{
    private static readonly XLColor TitleFill = XLColor.FromHtml("#12355B");
    private static readonly XLColor HeaderFill = XLColor.FromHtml("#1F4E79");
    private static readonly XLColor SectionFill = XLColor.FromHtml("#EEF2F5");
    private static readonly XLColor GridBorder = XLColor.FromHtml("#D0D5DD");
    private const double MaxColumnWidth = 60d;

    private const string PercentFormat = "0.0%";

    public void Write(AuditWorkbookModel model, string outputPath)
    {
        using var workbook = new XLWorkbook();

        WriteInventory(workbook, model);
        WriteSummary(workbook, model);
        WriteAreaDetail(workbook, model);
        WriteChecklist(workbook, model);
        foreach (var database in model.Databases) WriteDatabaseSheet(workbook, model, database);
        WriteAccessIssues(workbook, model);
        WriteFindings(workbook, model);
        WriteRiskRegister(workbook, model);

        Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(outputPath))!);
        workbook.SaveAs(outputPath);
    }

    // -- Inventory -----------------------------------------------------------

    private static void WriteInventory(XLWorkbook workbook, AuditWorkbookModel model)
    {
        var sheet = workbook.Worksheets.Add("Inventory");
        WriteHeaderRow(sheet, 1, new[] { "Database ID", "Database Name" });

        var row = 2;
        foreach (var database in model.Databases)
        {
            sheet.Cell(row, 1).Value = database.Id;
            sheet.Cell(row, 1).Style.Font.Bold = true;
            sheet.Cell(row, 2).Value = database.Name;
            row++;
        }

        if (model.Databases.Count == 0) WriteNote(sheet, 2, 1, "No database-scoped evidence was recorded for this run.");

        Finalize(sheet, freezeRows: 1, autoFilter: sheet.Range(1, 1, Math.Max(row - 1, 1), 2));
    }

    // -- Summary -------------------------------------------------------------

    private static void WriteSummary(XLWorkbook workbook, AuditWorkbookModel model)
    {
        var sheet = workbook.Worksheets.Add("Summary");
        WriteTitle(sheet, 1, 1, 5, $"SQL Audit — {model.Target}");

        var row = 3;
        WriteLabel(sheet, row, 1, "Overall Score");
        WritePercent(sheet, row++, 2, AuditWorkbookBuilder.Fraction(model.OverallScore));

        WriteLabel(sheet, row, 1, "Risk Rating");
        sheet.Cell(row++, 2).Value = $"{model.OverallRating.Icon} {model.OverallRating.Label}";

        WriteLabel(sheet, row, 1, "Deployment Mode");
        sheet.Cell(row++, 2).Value = model.DeploymentMode;

        WriteLabel(sheet, row, 1, "Report Date");
        sheet.Cell(row++, 2).Value = model.GeneratedDate;

        row++;
        WriteSection(sheet, row++, 1, 5, "Area Scorecard");
        WriteHeaderRow(sheet, row++, new[] { "#", "Area", "Weight", "Score", "Rating" });

        var calculator = new ScoreCalculator();
        foreach (var area in model.Areas)
        {
            sheet.Cell(row, 1).Value = area.Area.Number;
            sheet.Cell(row, 2).Value = model.AreaName(area.Area.Number);
            WritePercent(sheet, row, 3, area.Area.Weight / 100.0);
            WritePercent(sheet, row, 4, AuditWorkbookBuilder.Fraction(area.ScorePercent));
            sheet.Cell(row, 5).Value = calculator.GetRiskRating(area.ScorePercent).Label;
            row++;
        }

        row++;
        WriteSection(sheet, row++, 1, 5, "Coverage");
        var coverage = model.Coverage;
        row = WriteCoverageRow(sheet, row, "Scored — deterministic", coverage.Deterministic);
        row = WriteCoverageRow(sheet, row, "Scored — AI analysis", coverage.AiAssisted);
        row = WriteCoverageRow(sheet, row, "Scored — manual attestation", coverage.ManualAttestation);
        row = WriteCoverageRow(sheet, row, "Needs review", coverage.NeedsReview);
        row = WriteCoverageRow(sheet, row, "Awaiting validation (excluded from score)", coverage.AwaitingValidation);
        row = WriteCoverageRow(sheet, row, "N/A (excluded from score)", coverage.NotApplicable);
        row = WriteCoverageRow(sheet, row, "Total evaluated controls", coverage.Total);

        WriteLabel(sheet, row, 1, "Deterministic coverage");
        WritePercent(sheet, row, 2, coverage.DeterministicCoverage);

        sheet.Column(1).Width = 42;
        sheet.Column(2).Width = 34;
        Finalize(sheet, freezeRows: 0, autoFilter: null, autoFit: false);
    }

    private static int WriteCoverageRow(IXLWorksheet sheet, int row, string label, int value)
    {
        WriteLabel(sheet, row, 1, label);
        sheet.Cell(row, 2).Value = value;
        return row + 1;
    }

    // -- Area Detail ---------------------------------------------------------

    private static void WriteAreaDetail(XLWorkbook workbook, AuditWorkbookModel model)
    {
        var sheet = workbook.Worksheets.Add("Area Detail");
        var calculator = new ScoreCalculator();
        var row = 1;

        foreach (var area in model.Areas.Where(a => a.Items.Count > 0))
        {
            WriteTitle(sheet, row++, 1, 8, $"Area {area.Area.Number}: {model.AreaName(area.Area.Number)}");

            WriteLabel(sheet, row, 1, "Area score");
            WritePercent(sheet, row, 2, AuditWorkbookBuilder.Fraction(area.ScorePercent));
            sheet.Cell(row, 3).Value = calculator.GetRiskRating(area.ScorePercent).Label;
            WriteLabel(sheet, row, 4, "Weight");
            WritePercent(sheet, row, 5, area.Area.Weight / 100.0);
            row += 2;

            WriteHeaderRow(sheet, row++, new[] { "Category", "Score", "Rating", "Validated", "Items" });
            foreach (var category in area.Categories)
            {
                sheet.Cell(row, 1).Value = model.CategoryLabel(category.CategoryId);
                WritePercent(sheet, row, 2, AuditWorkbookBuilder.Fraction(category.ScorePercent));
                sheet.Cell(row, 3).Value = calculator.GetRiskRating(category.ScorePercent).Label;
                sheet.Cell(row, 4).Value = category.ScoredCount;
                sheet.Cell(row, 5).Value = category.Items.Count;
                row++;
            }

            var findings = model.Findings.Where(f => f.Item.AreaNumber == area.Area.Number).ToList();
            row++;
            WriteSection(sheet, row++, 1, 8, $"Findings ({findings.Count})");
            WriteHeaderRow(sheet, row++, new[]
            {
                "Ref", "Finding", "Severity", "Overall Score", "Impacted Database IDs",
                "Non-Impacted Database IDs", "Not Assessed / Reason", "Recommendation",
            });

            if (findings.Count == 0)
            {
                WriteNote(sheet, row++, 1, "No active findings in this area.");
            }
            else
            {
                foreach (var finding in findings)
                {
                    var item = finding.Item;
                    sheet.Cell(row, 1).Value = item.Id;
                    sheet.Cell(row, 2).Value = AuditWorkbookBuilder.Text(item.Finding);
                    sheet.Cell(row, 3).Value = AuditWorkbookBuilder.Text(item.Severity);
                    if (item.Score.HasValue) sheet.Cell(row, 4).Value = item.Score.Value;
                    else sheet.Cell(row, 4).Value = AuditWorkbookBuilder.NoValue;
                    sheet.Cell(row, 5).Value = AuditWorkbookBuilder.DatabaseList(finding.ImpactedDatabases, AuditWorkbookBuilder.InstanceScope);
                    sheet.Cell(row, 6).Value = AuditWorkbookBuilder.DatabaseList(finding.NonImpactedDatabases, AuditWorkbookBuilder.NoValue);
                    sheet.Cell(row, 7).Value = AuditWorkbookBuilder.NoValue;
                    sheet.Cell(row, 8).Value = AuditWorkbookBuilder.Text(item.Recommendation);
                    row++;
                }
            }
            row += 2;
        }

        if (row == 1) WriteNote(sheet, 1, 1, "No areas were evaluated in this run.");
        Finalize(sheet, freezeRows: 0, autoFilter: null);
    }

    // -- Checklist -----------------------------------------------------------

    private static void WriteChecklist(XLWorkbook workbook, AuditWorkbookModel model)
    {
        var sheet = workbook.Worksheets.Add("Checklist");

        var headers = new List<string>
        {
            "Ref", "Area", "Category", "Title", "Status", "Score",
            "ProducedBy", "Confidence", "Severity", "Rationale",
        };
        headers.AddRange(model.Databases.Select(d => d.Id));
        WriteHeaderRow(sheet, 1, headers);

        var row = 2;
        foreach (var item in model.Items)
        {
            var names = AuditWorkbookBuilder.DatabasesOf(item);

            sheet.Cell(row, 1).Value = item.Id;
            sheet.Cell(row, 2).Value = item.AreaNumber;
            sheet.Cell(row, 3).Value = model.CategoryLabel(item.CategoryId);
            sheet.Cell(row, 4).Value = AuditWorkbookBuilder.Text(item.Description);
            sheet.Cell(row, 5).Value = AuditWorkbookModel.Status(item);
            if (item.IsScored) sheet.Cell(row, 6).Value = item.Score!.Value;
            else sheet.Cell(row, 6).Value = AuditWorkbookBuilder.NoValue;
            sheet.Cell(row, 7).Value = AuditWorkbookModel.ProducedBy(item);
            sheet.Cell(row, 8).Value = AuditWorkbookBuilder.NotAvailable;
            sheet.Cell(row, 9).Value = AuditWorkbookBuilder.Text(item.Severity);
            sheet.Cell(row, 10).Value = AuditWorkbookBuilder.Text(item.Finding);

            for (var i = 0; i < model.Databases.Count; i++)
            {
                var cell = sheet.Cell(row, 11 + i);
                var applies = names.Contains(model.Databases[i].Name, StringComparer.OrdinalIgnoreCase);
                if (applies && item.IsScored) cell.Value = item.Score!.Value;
                else cell.Value = AuditWorkbookBuilder.NoValue;
            }
            row++;
        }

        sheet.Column(4).Width = MaxColumnWidth;
        sheet.Column(10).Width = MaxColumnWidth;
        sheet.Column(4).Style.Alignment.WrapText = true;
        sheet.Column(10).Style.Alignment.WrapText = true;
        Finalize(sheet, freezeRows: 1, autoFilter: sheet.Range(1, 1, Math.Max(row - 1, 1), headers.Count));
    }

    // -- Per-database sheets -------------------------------------------------

    private static void WriteDatabaseSheet(XLWorkbook workbook, AuditWorkbookModel model, WorkbookDatabase database)
    {
        var sheet = workbook.Worksheets.Add(database.Id);
        var headers = new[]
        {
            "Check ID", "Checklist Ref", "Area", "Category", "Check Title", "Status",
            "Database Score", "Severity", "Object Name", "Object Type", "Object Evidence",
            "Assessment Details",
        };
        WriteHeaderRow(sheet, 1, headers);

        var row = 2;
        foreach (var item in model.ItemsForDatabase(database))
        {
            sheet.Cell(row, 1).Value = AuditWorkbookBuilder.Text(item.ScriptFile);
            sheet.Cell(row, 2).Value = item.Id;
            sheet.Cell(row, 3).Value = item.AreaNumber;
            sheet.Cell(row, 4).Value = model.CategoryLabel(item.CategoryId);
            sheet.Cell(row, 5).Value = AuditWorkbookBuilder.Text(item.Description);
            sheet.Cell(row, 6).Value = AuditWorkbookModel.Status(item);
            if (item.IsScored) sheet.Cell(row, 7).Value = item.Score!.Value;
            else sheet.Cell(row, 7).Value = AuditWorkbookBuilder.NoValue;
            sheet.Cell(row, 8).Value = AuditWorkbookBuilder.Text(item.Severity);
            sheet.Cell(row, 9).Value = database.Name;
            sheet.Cell(row, 10).Value = "Database";
            sheet.Cell(row, 11).Value = "The control applies to the database as a whole.";
            sheet.Cell(row, 12).Value = AuditWorkbookBuilder.Text(item.Finding);
            row++;
        }

        if (row == 2) WriteNote(sheet, 2, 1, $"No controls recorded database-scoped evidence for {database.Name}.");

        sheet.Column(5).Width = MaxColumnWidth;
        sheet.Column(12).Width = MaxColumnWidth;
        sheet.Column(5).Style.Alignment.WrapText = true;
        sheet.Column(12).Style.Alignment.WrapText = true;
        Finalize(sheet, freezeRows: 1, autoFilter: sheet.Range(1, 1, Math.Max(row - 1, 1), headers.Length));
    }

    // -- Access Issues -------------------------------------------------------

    private static void WriteAccessIssues(XLWorkbook workbook, AuditWorkbookModel model)
    {
        var sheet = workbook.Worksheets.Add("Access Issues");
        var headers = new[]
        {
            "Ref", "Check ID", "Area", "Title", "Database ID", "Failure Type", "Status",
            "Exact SQL Error", "Required Capability", "Read-Only Query That Failed", "Suggested Action",
        };
        WriteHeaderRow(sheet, 1, headers);

        var row = 2;
        foreach (var issue in model.AccessIssues)
        {
            var item = issue.Item;
            sheet.Cell(row, 1).Value = item.Id;
            sheet.Cell(row, 2).Value = AuditWorkbookBuilder.Text(item.ScriptFile);
            sheet.Cell(row, 3).Value = item.AreaNumber;
            sheet.Cell(row, 4).Value = AuditWorkbookBuilder.Text(item.Description);
            sheet.Cell(row, 5).Value = AuditWorkbookBuilder.InstanceScope;
            sheet.Cell(row, 6).Value = issue.FailureType;
            sheet.Cell(row, 7).Value = AuditWorkbookModel.Status(item);
            sheet.Cell(row, 8).Value = AuditWorkbookBuilder.NotAvailable;
            sheet.Cell(row, 9).Value = AuditWorkbookBuilder.NotAvailable;
            sheet.Cell(row, 10).Value = AuditWorkbookBuilder.NotAvailable;
            sheet.Cell(row, 11).Value = issue.Detail;
            row++;
        }

        if (row == 2) WriteNote(sheet, 2, 1, "No access or collection failures were recorded for this run.");

        Finalize(sheet, freezeRows: 1, autoFilter: sheet.Range(1, 1, Math.Max(row - 1, 1), headers.Length));
    }

    // -- Findings ------------------------------------------------------------

    private static void WriteFindings(XLWorkbook workbook, AuditWorkbookModel model)
    {
        var sheet = workbook.Worksheets.Add("Findings");
        var headers = new[]
        {
            "Ref", "Severity", "Risk", "Likelihood", "Impact", "Impacted Database IDs",
            "Non-Impacted Database IDs", "Not Assessed / Reason", "Finding", "Recommendation", "Status",
        };
        WriteHeaderRow(sheet, 1, headers);

        var row = 2;
        foreach (var finding in model.Findings)
        {
            var item = finding.Item;
            sheet.Cell(row, 1).Value = item.Id;
            sheet.Cell(row, 2).Value = AuditWorkbookBuilder.Text(item.Severity);
            sheet.Cell(row, 3).Value = finding.Severity.RiskScore;
            sheet.Cell(row, 4).Value = finding.Severity.Likelihood;
            sheet.Cell(row, 5).Value = finding.Severity.Impact;
            sheet.Cell(row, 6).Value = AuditWorkbookBuilder.DatabaseList(finding.ImpactedDatabases, AuditWorkbookBuilder.InstanceScope);
            sheet.Cell(row, 7).Value = AuditWorkbookBuilder.DatabaseList(finding.NonImpactedDatabases, AuditWorkbookBuilder.NoValue);
            sheet.Cell(row, 8).Value = AuditWorkbookBuilder.NoValue;
            sheet.Cell(row, 9).Value = AuditWorkbookBuilder.Text(item.Finding);
            sheet.Cell(row, 10).Value = AuditWorkbookBuilder.Text(item.Recommendation);
            sheet.Cell(row, 11).Value = finding.Status;
            row++;
        }

        if (row == 2) WriteNote(sheet, 2, 1, "No active findings were raised for this run.");

        sheet.Column(9).Width = MaxColumnWidth;
        sheet.Column(10).Width = MaxColumnWidth;
        sheet.Column(9).Style.Alignment.WrapText = true;
        sheet.Column(10).Style.Alignment.WrapText = true;
        Finalize(sheet, freezeRows: 1, autoFilter: sheet.Range(1, 1, Math.Max(row - 1, 1), headers.Length));
    }

    // -- Risk Register -------------------------------------------------------

    private static void WriteRiskRegister(XLWorkbook workbook, AuditWorkbookModel model)
    {
        var sheet = workbook.Worksheets.Add("Risk Register");
        WriteTitle(sheet, 1, 1, 8, $"Risk Register — {model.Target}");

        WriteLabel(sheet, 2, 1, "Generated");
        sheet.Cell(2, 2).Value = model.GeneratedDate;
        WriteLabel(sheet, 2, 3, "Overall score");
        WritePercent(sheet, 2, 4, AuditWorkbookBuilder.Fraction(model.OverallScore));
        WriteLabel(sheet, 2, 5, "Overall rating");
        sheet.Cell(2, 6).Value = model.OverallRating.Label;

        WriteSection(sheet, 4, 1, 4, "Risk Summary");
        sheet.Cell(4, 5).Value = "Usage: assign an owner and treatment, then track closure evidence per row.";
        sheet.Cell(4, 5).Style.Font.Italic = true;

        WriteHeaderRow(sheet, 5, new[] { "Severity", "Count", "% of findings", "Remediation SLA" });

        var row = 6;
        var total = model.Findings.Count;
        foreach (var severity in new[] { "Critical", "High", "Medium", "Low", "Informational" })
        {
            var count = model.Findings.Count(f =>
                string.Equals(f.Item.Severity, severity, StringComparison.OrdinalIgnoreCase));
            sheet.Cell(row, 1).Value = severity;
            sheet.Cell(row, 2).Value = count;
            WritePercent(sheet, row, 3, total == 0 ? 0 : (double)count / total);
            sheet.Cell(row, 4).Value = AuditWorkbookBuilder.ProfileFor(severity).Sla;
            row++;
        }
        WriteLabel(sheet, row, 1, "Total");
        sheet.Cell(row, 2).Value = total;
        WritePercent(sheet, row, 3, total == 0 ? 0 : 1);
        row += 2;

        var headers = new[]
        {
            "Risk ID", "Audit Phase", "Area #", "Area", "Category", "Checklist Ref", "Check ID",
            "Finding / Current Evidence", "Scope", "Impacted Database IDs", "Non-Impacted Database IDs",
            "Not Assessed / Reason", "Severity", "Likelihood", "Impact", "Risk Score", "Remediation SLA",
            "Recommendation", "Owner", "Target Date", "Treatment", "Status", "Actual Closure Date",
            "Closure Evidence", "Verification Status", "Notes",
        };
        var headerRow = row;
        WriteHeaderRow(sheet, headerRow, headers);
        row++;

        DateTime.TryParse(model.GeneratedDate, CultureInfo.InvariantCulture, DateTimeStyles.None, out var generated);

        foreach (var finding in model.Findings)
        {
            var item = finding.Item;
            sheet.Cell(row, 1).Value = finding.RiskId;
            sheet.Cell(row, 2).Value = finding.AuditPhase;
            sheet.Cell(row, 3).Value = item.AreaNumber;
            sheet.Cell(row, 4).Value = model.AreaName(item.AreaNumber);
            sheet.Cell(row, 5).Value = model.CategoryLabel(item.CategoryId);
            sheet.Cell(row, 6).Value = item.Id;
            sheet.Cell(row, 7).Value = AuditWorkbookBuilder.Text(item.ScriptFile);
            sheet.Cell(row, 8).Value = AuditWorkbookBuilder.Text(item.Finding);
            sheet.Cell(row, 9).Value = finding.Scope;
            sheet.Cell(row, 10).Value = AuditWorkbookBuilder.DatabaseList(finding.ImpactedDatabases, AuditWorkbookBuilder.InstanceScope);
            sheet.Cell(row, 11).Value = AuditWorkbookBuilder.DatabaseList(finding.NonImpactedDatabases, AuditWorkbookBuilder.NoValue);
            sheet.Cell(row, 12).Value = AuditWorkbookBuilder.NoValue;
            sheet.Cell(row, 13).Value = AuditWorkbookBuilder.Text(item.Severity);
            sheet.Cell(row, 14).Value = finding.Severity.Likelihood;
            sheet.Cell(row, 15).Value = finding.Severity.Impact;
            sheet.Cell(row, 16).Value = finding.Severity.RiskScore;
            sheet.Cell(row, 17).Value = finding.Severity.Sla;
            sheet.Cell(row, 18).Value = AuditWorkbookBuilder.Text(item.Recommendation);
            sheet.Cell(row, 19).Value = string.Empty;
            if (generated != default && finding.Severity.SlaDays is int days)
            {
                sheet.Cell(row, 20).Value = generated.AddDays(days);
                sheet.Cell(row, 20).Style.DateFormat.Format = "yyyy-mm-dd";
            }
            else
            {
                sheet.Cell(row, 20).Value = AuditWorkbookBuilder.NoValue;
            }
            sheet.Cell(row, 21).Value = "Remediate";
            sheet.Cell(row, 22).Value = finding.Status;
            sheet.Cell(row, 23).Value = string.Empty;
            sheet.Cell(row, 24).Value = string.Empty;
            sheet.Cell(row, 25).Value = "Not Verified";
            sheet.Cell(row, 26).Value = string.Empty;
            row++;
        }

        if (model.Findings.Count == 0) WriteNote(sheet, row, 1, "No active risks were raised for this run.");

        sheet.Column(8).Width = MaxColumnWidth;
        sheet.Column(18).Width = MaxColumnWidth;
        sheet.Column(8).Style.Alignment.WrapText = true;
        sheet.Column(18).Style.Alignment.WrapText = true;
        Finalize(sheet, freezeRows: 0, autoFilter: sheet.Range(headerRow, 1, Math.Max(row - 1, headerRow), headers.Length));
    }

    // -- Shared formatting ---------------------------------------------------

    private static void WriteTitle(IXLWorksheet sheet, int row, int column, int span, string text)
    {
        var range = sheet.Range(row, column, row, column + span - 1);
        range.Merge();
        var cell = sheet.Cell(row, column);
        cell.Value = text;
        cell.Style.Font.Bold = true;
        cell.Style.Font.FontSize = 13;
        cell.Style.Font.FontColor = XLColor.White;
        cell.Style.Fill.BackgroundColor = TitleFill;
        cell.Style.Alignment.Vertical = XLAlignmentVerticalValues.Center;
        sheet.Row(row).Height = 22;
    }

    private static void WriteSection(IXLWorksheet sheet, int row, int column, int span, string text)
    {
        var range = sheet.Range(row, column, row, column + span - 1);
        range.Merge();
        var cell = sheet.Cell(row, column);
        cell.Value = text;
        cell.Style.Font.Bold = true;
        cell.Style.Fill.BackgroundColor = SectionFill;
    }

    private static void WriteHeaderRow(IXLWorksheet sheet, int row, IReadOnlyList<string> headers)
    {
        for (var i = 0; i < headers.Count; i++)
        {
            var cell = sheet.Cell(row, i + 1);
            cell.Value = headers[i];
            cell.Style.Font.Bold = true;
            cell.Style.Font.FontColor = XLColor.White;
            cell.Style.Fill.BackgroundColor = HeaderFill;
            cell.Style.Alignment.WrapText = false;
            cell.Style.Border.BottomBorder = XLBorderStyleValues.Thin;
            cell.Style.Border.BottomBorderColor = GridBorder;
        }
    }

    private static void WriteLabel(IXLWorksheet sheet, int row, int column, string text)
    {
        var cell = sheet.Cell(row, column);
        cell.Value = text;
        cell.Style.Font.Bold = true;
    }

    private static void WritePercent(IXLWorksheet sheet, int row, int column, double? fraction)
    {
        var cell = sheet.Cell(row, column);
        if (fraction.HasValue)
        {
            cell.Value = fraction.Value;
            cell.Style.NumberFormat.Format = PercentFormat;
        }
        else
        {
            cell.Value = AuditWorkbookBuilder.NotAvailable;
        }
    }

    private static void WriteNote(IXLWorksheet sheet, int row, int column, string text)
    {
        var cell = sheet.Cell(row, column);
        cell.Value = text;
        cell.Style.Font.Italic = true;
        cell.Style.Font.FontColor = XLColor.FromHtml("#667085");
    }

    private static void Finalize(IXLWorksheet sheet, int freezeRows, IXLRange? autoFilter, bool autoFit = true)
    {
        if (autoFit)
        {
            sheet.Columns().AdjustToContents(1, 200, 8, MaxColumnWidth);
        }
        if (freezeRows > 0) sheet.SheetView.FreezeRows(freezeRows);
        if (autoFilter is not null) autoFilter.SetAutoFilter();
    }
}
