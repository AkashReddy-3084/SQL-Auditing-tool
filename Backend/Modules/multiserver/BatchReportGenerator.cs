using System.Text.Json;
using SqlAuditor.Reporting;

namespace SQLAuditor.Lib;

/// <summary>
/// Consolidates a multi-server batch into the same artifact set a single-server run produces:
/// a merged <c>checklist_results.json</c> plus the standard five-file report suite, written to the
/// batch folder. Each per-server run keeps its own untouched copies.
/// </summary>
public static class BatchReportGenerator
{
    public const string ResultsFileName = "checklist_results.json";

    private static readonly JsonSerializerOptions WriteOptions = new() { WriteIndented = true };

    public static IReadOnlyList<string> Generate(string batchDirectory)
    {
        var messages = new List<string>();
        var batch = MultiServerRunner.ReadManifest(batchDirectory);
        if (batch is null)
        {
            messages.Add($"No {MultiServerRunner.ManifestFileName} found in {batchDirectory}.");
            return messages;
        }

        Directory.CreateDirectory(batchDirectory);

        var merged = MergeResults(batch, messages, out var serverCount);
        if (merged.Count == 0)
        {
            messages.Add("No server results were available to consolidate.");
            return messages;
        }

        var mergedPath = Path.Combine(batchDirectory, ResultsFileName);
        try
        {
            File.WriteAllText(mergedPath, JsonSerializer.Serialize(merged, WriteOptions));
            messages.Add($"{ResultsFileName} merged ({merged.Count} result(s) from {serverCount} server(s)).");
        }
        catch (Exception ex)
        {
            messages.Add($"{ResultsFileName} could not be written: {ex.Message}");
            return messages;
        }

        var metadata = new ReportMetadata
        {
            ReportDate = DateTime.UtcNow.ToString("yyyy-MM-dd"),
            Auditors = "SQL Auditor Tool (automated, multi-server)",
            TotalChecklistItems = merged.Count,
        };

        try
        {
            var suite = new ReportSuiteGenerator();
            foreach (var message in suite.GenerateFromFile(
                mergedPath,
                batchDirectory,
                metadata,
                error => messages.Add(error),
                targetOverride: BuildTargetLabel(batch, serverCount)))
            {
                messages.Add(message);
            }
        }
        catch (Exception ex)
        {
            messages.Add($"Consolidated report suite failed: {ex.Message}");
        }

        // Replaces the single-server HTML the suite just wrote: a batch needs the estate readout,
        // which keeps each server's scores separate instead of merging them.
        try
        {
            var model = AuditWorkbookBuilder.Build(mergedPath, batchDirectory, metadata, BuildTargetLabel(batch, serverCount));
            EstateReadoutGenerator.TryGenerate(batch, batchDirectory, model.CategoryLabel, messages);
        }
        catch (Exception ex)
        {
            messages.Add($"{EstateReadoutGenerator.FileName} could not be generated: {ex.Message}");
        }

        return messages;
    }

    /// <summary>
    /// Every server's controls are kept as separate rows so the consolidated scores cover the whole
    /// estate. Server identity is carried in the evidence text and in the database labels, because
    /// the checklist ID alone repeats across servers.
    /// </summary>
    private static List<ChecklistItemResult> MergeResults(
        BatchRunResult batch,
        List<string> messages,
        out int serverCount)
    {
        var merged = new List<ChecklistItemResult>();
        serverCount = 0;

        foreach (var server in batch.Servers)
        {
            var resultsPath = string.IsNullOrWhiteSpace(server.RunDirectory)
                ? null
                : Path.Combine(server.RunDirectory, ResultsFileName);

            if (resultsPath is null || !File.Exists(resultsPath))
            {
                messages.Add($"[{server.DisplayName}] no results to consolidate ({server.Status}).");
                continue;
            }

            try
            {
                foreach (var item in ChecklistResultsLoader.Load(resultsPath))
                {
                    item.Evidence = Prefix(server.DisplayName, item.Evidence);
                    item.Finding = Prefix(server.DisplayName, item.Finding);
                    item.DatabasesVerified = QualifyDatabases(server.DisplayName, item.DatabasesVerified);
                    merged.Add(item);
                }
                serverCount++;
            }
            catch (Exception ex)
            {
                messages.Add($"[{server.DisplayName}] results could not be read: {ex.Message}");
            }
        }

        return merged;
    }

    private static string? Prefix(string server, string? text) =>
        string.IsNullOrWhiteSpace(text) ? text : $"[{server}] {text}";

    private static string? QualifyDatabases(string server, string? databases)
    {
        if (string.IsNullOrWhiteSpace(databases)) return databases;

        var parts = databases
            .Split(new[] { ';', ',', '\n', '\r' }, StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            .Select(db => $"{server} / {db}");

        return string.Join("; ", parts);
    }

    private static string BuildTargetLabel(BatchRunResult batch, int serverCount)
    {
        var names = batch.Servers
            .Where(s => !string.IsNullOrWhiteSpace(s.RunDirectory))
            .Select(s => s.DisplayName)
            .ToList();

        if (names.Count == 0) return batch.BatchId;
        if (names.Count <= 3) return string.Join(", ", names);
        return $"{serverCount} servers ({string.Join(", ", names.Take(3))}, +{names.Count - 3} more)";
    }
}
