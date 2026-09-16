using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.Json;
using System.Threading.Tasks;

namespace SQLAuditor.Lib;

/// <summary>A manual checklist item as written to the export CSV.</summary>
public sealed class ManualCheckExportRow
{
    public string Id { get; init; } = string.Empty;
    public string Area { get; init; } = string.Empty;
    public string Description { get; init; } = string.Empty;
    public string Verification { get; init; } = string.Empty;
    public string ManualSteps { get; init; } = string.Empty;
    public string Status { get; init; } = string.Empty;
    public string Decision { get; init; } = string.Empty;
    public string Evidence { get; init; } = string.Empty;
}

/// <summary>A reviewer decision read back from the filled CSV.</summary>
public sealed class ManualCheckImportRow
{
    public string Id { get; init; } = string.Empty;
    public string Decision { get; init; } = string.Empty;
    public string Evidence { get; init; } = string.Empty;
    public string ManualSteps { get; init; } = string.Empty;
}

/// <summary>Rows accepted from a filled CSV plus the per-row problems that blocked the rest.</summary>
public sealed class ManualCheckImportFile
{
    public List<ManualCheckImportRow> Rows { get; } = new();
    public List<string> Issues { get; } = new();
}

/// <summary>Outcome of applying a filled CSV to the persisted results of the current run.</summary>
public sealed class ManualCheckApplyResult
{
    public List<string> Applied { get; } = new();
    public List<string> Ignored { get; } = new();
    public List<string> Failed { get; } = new();
}

/// <summary>
/// The single manual-checklist CSV contract shared by the desktop app, the CLI and the IDE (MCP) host.
/// Every surface exports the same columns, parses the same way and maps rows back to checklist items by ID,
/// so a CSV filled from one surface can be imported by any other.
/// </summary>
public static class ManualChecklistCsv
{
    /// <summary>Name used when a run's filled CSV is stored alongside its reports.</summary>
    public const string RunFileName = "manual-checklist.csv";

    public const string IdHeader = "Checklist ID";
    public const string DecisionHeader = "Decision";
    public const string EvidenceHeader = "Evidence";
    public const string ManualStepsHeader = "Manual Steps";

    public static readonly string[] Headers =
    {
        IdHeader, "Area", "Description", "Verification", ManualStepsHeader,
        "Current Status", DecisionHeader, EvidenceHeader,
    };

    private static readonly string[] RequiredImportHeaders = { IdHeader, DecisionHeader, EvidenceHeader };

    /// <summary>Default file name for a fresh export, e.g. <c>manual_checks_20260915_160412.csv</c>.</summary>
    public static string BuildExportFileName(DateTime timestamp) =>
        $"manual_checks_{timestamp:yyyyMMdd_HHmmss}.csv";

    public static string ToCsvField(string? value) =>
        $"\"{(value ?? string.Empty).Replace("\"", "\"\"")}\"";

    public static void Write(string path, IEnumerable<ManualCheckExportRow> rows)
    {
        var csv = new StringBuilder();
        csv.AppendLine(string.Join(",", Headers.Select(ToCsvField)));

        foreach (var row in rows)
        {
            csv.AppendLine(string.Join(",", new[]
            {
                row.Id, row.Area, row.Description, row.Verification, row.ManualSteps,
                row.Status, row.Decision, row.Evidence,
            }.Select(ToCsvField)));
        }

        // The BOM keeps Excel from mangling non-ASCII guidance when the reviewer opens the export.
        File.WriteAllText(path, csv.ToString(), new UTF8Encoding(encoderShouldEmitUTF8Identifier: true));
    }

    public static ManualCheckImportFile Read(string path)
    {
        var result = new ManualCheckImportFile();
        using var parser = new Microsoft.VisualBasic.FileIO.TextFieldParser(path, Encoding.UTF8)
        {
            TextFieldType = Microsoft.VisualBasic.FileIO.FieldType.Delimited,
            HasFieldsEnclosedInQuotes = true,
            TrimWhiteSpace = false,
        };
        parser.SetDelimiters(",");

        var headers = parser.ReadFields();
        if (headers == null || headers.Length == 0)
            throw new InvalidDataException("The CSV is empty or has no header row.");

        var headerIndexes = headers
            .Select((header, index) => new { Header = (header ?? string.Empty).Trim().TrimStart('\uFEFF'), Index = index })
            .GroupBy(entry => entry.Header, StringComparer.OrdinalIgnoreCase)
            .ToDictionary(group => group.Key, group => group.First().Index, StringComparer.OrdinalIgnoreCase);

        var missingHeaders = RequiredImportHeaders.Where(header => !headerIndexes.ContainsKey(header)).ToArray();
        if (missingHeaders.Length > 0)
            throw new InvalidDataException("Missing required CSV column(s): " + string.Join(", ", missingHeaders));

        var seenIds = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        while (!parser.EndOfData)
        {
            var lineNumber = parser.LineNumber;
            string[]? fields;
            try
            {
                fields = parser.ReadFields();
            }
            catch (Microsoft.VisualBasic.FileIO.MalformedLineException ex)
            {
                result.Issues.Add($"Line {lineNumber}: malformed CSV ({ex.Message}).");
                continue;
            }

            if (fields == null || fields.All(string.IsNullOrWhiteSpace)) continue;

            string Field(string header)
            {
                if (!headerIndexes.TryGetValue(header, out var index) || index >= fields.Length) return string.Empty;
                return fields[index]?.Trim() ?? string.Empty;
            }

            var id = Field(IdHeader);
            if (string.IsNullOrWhiteSpace(id))
            {
                result.Issues.Add($"Line {lineNumber}: Checklist ID is empty.");
                continue;
            }

            if (!seenIds.Add(id))
            {
                result.Issues.Add($"Line {lineNumber}: duplicate Checklist ID '{id}'.");
                continue;
            }

            var decision = Field(DecisionHeader).ToLowerInvariant() switch
            {
                "pass" or "passed" or "p" => "Pass",
                "fail" or "failed" or "f" => "Fail",
                "" => string.Empty,
                _ => "Invalid",
            };
            if (decision.Length == 0)
            {
                result.Issues.Add($"{id}: Decision is empty; enter Pass or Fail.");
                continue;
            }
            if (decision == "Invalid")
            {
                result.Issues.Add($"{id}: Decision must be Pass or Fail.");
                continue;
            }

            var evidence = Field(EvidenceHeader);
            if (string.IsNullOrWhiteSpace(evidence))
            {
                result.Issues.Add($"{id}: Evidence is empty.");
                continue;
            }

            result.Rows.Add(new ManualCheckImportRow
            {
                Id = id,
                Decision = decision,
                Evidence = evidence,
                ManualSteps = Field(ManualStepsHeader),
            });
        }

        return result;
    }

    /// <summary>
    /// Builds the export rows for every manual/AI-Manual item in the current run's persisted results.
    /// Area and Verification come from the checklist structure; the guidance the engine wrote for an
    /// undecided item is carried in <see cref="ManualCheckExportRow.ManualSteps"/> so the reviewer has
    /// the steps in front of them, while an already-decided item exports its decision and evidence.
    /// </summary>
    public static async Task<List<ManualCheckExportRow>> BuildExportRowsAsync(Auditor auditor)
    {
        var rows = new List<ManualCheckExportRow>();
        var results = LoadPersistedResults();
        if (results.Count == 0) return rows;

        var areaById = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        var itemById = new Dictionary<string, ChecklistItem>(StringComparer.OrdinalIgnoreCase);
        foreach (var (area, items) in await auditor.GetChecklistStructureAsync())
        {
            foreach (var item in items)
            {
                areaById[item.Id] = area;
                itemById[item.Id] = item;
            }
        }

        foreach (var result in results
                     .Where(r => HistoricalManualResultsStore.IsManualTechnique(r.Technique))
                     .OrderBy(r => r.Id, StringComparer.OrdinalIgnoreCase))
        {
            var decided = HistoricalManualResultsStore.IsCompletedOutcome(result.Outcome);
            itemById.TryGetValue(result.Id, out var item);

            rows.Add(new ManualCheckExportRow
            {
                Id = result.Id,
                Area = areaById.TryGetValue(result.Id, out var area) ? area : string.Empty,
                Description = result.Description ?? item?.Description ?? string.Empty,
                Verification = item?.Verification ?? string.Empty,
                ManualSteps = decided ? string.Empty : result.Evidence ?? string.Empty,
                Status = result.Outcome ?? string.Empty,
                Decision = decided ? result.Outcome ?? string.Empty : string.Empty,
                Evidence = decided ? result.Evidence ?? string.Empty : string.Empty,
            });
        }

        return rows;
    }

    /// <summary>
    /// Applies reviewer decisions to the current run. Each row is routed through
    /// <see cref="Auditor.ResolveReview"/>, so a decision is recorded whether the item was still
    /// awaiting review or already carried a verdict - the CSV always wins. Rows whose ID is not a
    /// manual item in this run are ignored rather than silently changing a script verdict.
    /// </summary>
    public static ManualCheckApplyResult Apply(Auditor auditor, IEnumerable<ManualCheckImportRow> rows)
    {
        var applyResult = new ManualCheckApplyResult();
        var manualIds = LoadPersistedResults()
            .Where(r => HistoricalManualResultsStore.IsManualTechnique(r.Technique))
            .Select(r => r.Id)
            .ToHashSet(StringComparer.OrdinalIgnoreCase);

        foreach (var row in rows)
        {
            if (!manualIds.Contains(row.Id))
            {
                applyResult.Ignored.Add(row.Id);
                continue;
            }

            if (auditor.ResolveReview(row.Id, row.Decision, row.Evidence, out var newOutcome))
                applyResult.Applied.Add($"{row.Id} -> {newOutcome}");
            else
                applyResult.Failed.Add(row.Id);
        }

        return applyResult;
    }

    /// <summary>Stores the filled CSV next to the run's reports so the run records what was imported.</summary>
    public static void StoreInRunDirectory(string sourcePath) =>
        StoreInRunDirectory(sourcePath, AuditOutputPaths.CurrentRunDirectory);

    /// <summary>
    /// Stores the filled CSV in a specific run directory. The desktop app passes its per-instance
    /// run directory here so the copy lands in the right run during a multi-server session, rather
    /// than in whichever run is currently active globally.
    /// </summary>
    public static void StoreInRunDirectory(string sourcePath, string runDirectory)
    {
        Directory.CreateDirectory(runDirectory);
        var target = Path.Combine(runDirectory, RunFileName);
        if (!string.Equals(Path.GetFullPath(sourcePath), Path.GetFullPath(target), StringComparison.OrdinalIgnoreCase))
            File.Copy(sourcePath, target, overwrite: true);
        PreviousEvaluationStore.RecordManualCsv(runDirectory, RunFileName);
    }

    /// <summary>
    /// Marks every manual/AI-Manual item still awaiting a decision (Outcome "NeedsReview") as
    /// Skipped in the persisted results, so it is excluded from scoring. This mirrors the desktop
    /// app's "Export Manual CSV + Generate" step, letting a report be produced before the filled
    /// CSV is imported; a later import overwrites the Skipped placeholder with the real decision.
    /// Returns the number of items skipped. The caller regenerates the reports afterwards.
    /// </summary>
    public static int SkipPendingManual(string exportedCsvFileName, string? runDirectory = null)
    {
        var dir = runDirectory ?? AuditOutputPaths.CurrentRunDirectory;
        var path = Path.Combine(dir, "checklist_results.json");
        if (!File.Exists(path)) return 0;

        var skipped = 0;
        lock (Auditor.ResultsFileLockFor(dir))
        {
            var list = JsonSerializer.Deserialize<List<ChecklistResult>>(File.ReadAllText(path))
                       ?? new List<ChecklistResult>();

            for (var i = 0; i < list.Count; i++)
            {
                var r = list[i];
                if (!HistoricalManualResultsStore.IsManualTechnique(r.Technique)) continue;
                if (!string.Equals(r.Outcome, "NeedsReview", StringComparison.OrdinalIgnoreCase)) continue;

                var evidence = $"Manual evaluation was skipped for this report. Verification steps were exported to {exportedCsvFileName} for offline completion.";
                list[i] = ChecklistResultEnricher.Enrich(new ChecklistResult(
                    r.Id, r.Description, r.Verification, SkippedEvaluation.Outcome, evidence, r.ScriptFile, "AI-Manual"));
                skipped++;
            }

            if (skipped > 0)
            {
                Directory.CreateDirectory(dir);
                File.WriteAllText(path, JsonSerializer.Serialize(list, new JsonSerializerOptions { WriteIndented = true }));
            }
        }

        return skipped;
    }

    private static List<ChecklistResult> LoadPersistedResults()
    {
        var path = AuditOutputPaths.GetCurrentFilePath("checklist_results.json");
        if (!File.Exists(path)) return new List<ChecklistResult>();

        lock (Auditor.ResultsFileLock)
        {
            try
            {
                return JsonSerializer.Deserialize<List<ChecklistResult>>(File.ReadAllText(path))
                       ?? new List<ChecklistResult>();
            }
            catch (JsonException)
            {
                return new List<ChecklistResult>();
            }
        }
    }
}
