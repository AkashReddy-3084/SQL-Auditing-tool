using System;
using System.Collections.Generic;
using System.IO;
using System.Text;

namespace SqlAuditor.Reporting;

/// <summary>
/// Generates the client report suite for one audit run. A single <see cref="AuditWorkbookModel"/>
/// is built from the persisted checklist results, written to the workbook, and reused to render the
/// four companion documents, so every artifact reports the same scores, findings and risks.
/// </summary>
public sealed class ReportSuiteGenerator
{
    public const string AuditChecklistFileName = "Audit Checklist.md";
    public const string AuditReportFileName = "Audit Report.md";
    public const string ExcelReportFileName = "audit-report-vrsvpsql1c-mlcot-local.xlsx";
    public const string HtmlReportFileName = "OT Server SQL Assessment Readout 3.html";
    public const string RiskRegisterFileName = "Risk Register.md";

    public static readonly IReadOnlyList<string> FileNames = new[]
    {
        ExcelReportFileName,
        AuditChecklistFileName,
        AuditReportFileName,
        RiskRegisterFileName,
        HtmlReportFileName,
    };

    public IReadOnlyList<string> GenerateFromFile(
        string resultsJsonPath,
        string outputDirectory,
        ReportMetadata? metadata = null,
        Action<string>? reportError = null)
    {
        var model = AuditWorkbookBuilder.Build(
            resultsJsonPath, outputDirectory, metadata ?? new ReportMetadata());
        var messages = new List<string>();

        Directory.CreateDirectory(outputDirectory);

        // The workbook is written first: it is the artifact the four documents are derived from.
        GenerateIndependently(ExcelReportFileName, () =>
            new AuditWorkbookWriter().Write(model, Path.Combine(outputDirectory, ExcelReportFileName)),
            messages, reportError);

        GenerateIndependently(AuditChecklistFileName, () =>
            WriteTextAtomically(
                Path.Combine(outputDirectory, AuditChecklistFileName),
                AuditWorkbookDocuments.RenderAuditChecklist(model)),
            messages, reportError);

        GenerateIndependently(AuditReportFileName, () =>
            WriteTextAtomically(
                Path.Combine(outputDirectory, AuditReportFileName),
                AuditWorkbookDocuments.RenderAuditReport(model)),
            messages, reportError);

        GenerateIndependently(RiskRegisterFileName, () =>
            WriteTextAtomically(
                Path.Combine(outputDirectory, RiskRegisterFileName),
                AuditWorkbookDocuments.RenderRiskRegister(model)),
            messages, reportError);

        GenerateIndependently(HtmlReportFileName, () =>
            WriteTextAtomically(
                Path.Combine(outputDirectory, HtmlReportFileName),
                AuditWorkbookDocuments.RenderHtmlReadout(model)),
            messages, reportError);

        return messages;
    }

    private static void GenerateIndependently(
        string fileName,
        Action generate,
        ICollection<string> messages,
        Action<string>? reportError)
    {
        try
        {
            generate();
            messages.Add($"{fileName} generated.");
        }
        catch (Exception ex)
        {
            var message = $"{fileName} generation error: {ex.Message}";
            messages.Add(message);
            reportError?.Invoke(message);
        }
    }

    private static void WriteTextAtomically(string outputPath, string contents)
    {
        var temporaryPath = outputPath + ".tmp";
        File.WriteAllText(temporaryPath, contents, new UTF8Encoding(false));
        File.Move(temporaryPath, outputPath, true);
    }

}