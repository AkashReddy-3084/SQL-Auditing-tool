using System.Globalization;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;
using SqlAuditor.Reporting;

namespace SQLAuditor.Lib;

/// <summary>
/// Metadata describing one completed evaluation run, persisted as <c>run-metadata.json</c>
/// inside its run directory.
/// </summary>
public sealed record EvaluationRunMetadata
{
    public string ServerName { get; init; } = string.Empty;
    public DateTime StartedAt { get; init; }
    public DateTime CompletedAt { get; init; }
    public double? DurationSeconds { get; init; }
    public int ItemCount { get; init; }
    public string Status { get; init; } = string.Empty;
    public double? ScorePercent { get; init; }

    [JsonIgnore]
    public TimeSpan? Duration =>
        DurationSeconds is null ? null : TimeSpan.FromSeconds(DurationSeconds.Value);
}

/// <summary>A previous run offered back to the user, together with the directory that holds it.</summary>
public sealed record PreviousEvaluation
{
    public required string RunDirectory { get; init; }
    public required EvaluationRunMetadata Metadata { get; init; }

    public string ResultsPath => Path.Combine(RunDirectory, "checklist_results.json");

    public string EvaluatedDisplay =>
        Metadata.CompletedAt.ToString("dd-MMM-yyyy hh:mm tt", CultureInfo.InvariantCulture);

    public string ScoreDisplay =>
        Metadata.ScorePercent is null
            ? "N/A"
            : Metadata.ScorePercent.Value.ToString("0.0", CultureInfo.InvariantCulture) + "%";

    public string DurationDisplay
    {
        get
        {
            var duration = Metadata.Duration;
            if (duration is null || duration.Value <= TimeSpan.Zero) return "N/A";
            if (duration.Value.TotalMinutes < 1) return $"{duration.Value.TotalSeconds:0} sec";
            if (duration.Value.TotalHours < 1) return $"{duration.Value.TotalMinutes:0} min";
            return $"{(int)duration.Value.TotalHours} hr {duration.Value.Minutes} min";
        }
    }
}

/// <summary>
/// Tracks the latest evaluation recorded for each audited server so a later session can reuse
/// its stored results instead of executing the whole audit again.
/// </summary>
public static class PreviousEvaluationStore
{
    public const string FileName = "run-metadata.json";
    public const string CompletedStatus = "Completed";
    public const string PartialStatus = "Partially Completed";

    // Run directories collide only within the same millisecond; CreateRunDirectory then appends
    // "_2", "_3", ... which must not be mistaken for part of the server name.
    private static readonly Regex CollisionSuffix = new(@"_\d+$", RegexOptions.CultureInvariant);

    private static readonly JsonSerializerOptions SerializerOptions = new()
    {
        WriteIndented = true,
        PropertyNameCaseInsensitive = true,
    };

    /// <summary>Writes the metadata for a run that has just finished executing.</summary>
    public static void Record(string runDirectory, string? connectionString, DateTime startedAt, DateTime completedAt)
    {
        if (string.IsNullOrWhiteSpace(runDirectory) || !Directory.Exists(runDirectory)) return;

        var (itemCount, status, score) = Summarize(Path.Combine(runDirectory, "checklist_results.json"));
        var metadata = new EvaluationRunMetadata
        {
            ServerName = AuditOutputPaths.ResolveServerName(connectionString),
            StartedAt = startedAt,
            CompletedAt = completedAt,
            DurationSeconds = Math.Max(0, (completedAt - startedAt).TotalSeconds),
            ItemCount = itemCount,
            Status = status,
            ScorePercent = score,
        };

        Write(runDirectory, metadata);
    }

    /// <summary>
    /// Re-derives item count, status and score from the run's current results, keeping the
    /// originally recorded start time and duration. Used after reports are regenerated so the
    /// stored summary reflects manual decisions made after the engine finished.
    /// </summary>
    public static void Refresh(string runDirectory)
    {
        if (string.IsNullOrWhiteSpace(runDirectory) || !Directory.Exists(runDirectory)) return;

        var resultsPath = Path.Combine(runDirectory, "checklist_results.json");
        if (!File.Exists(resultsPath)) return;

        var existing = Read(runDirectory);
        if (existing is null) return;

        var (itemCount, status, score) = Summarize(resultsPath);
        Write(runDirectory, existing with { ItemCount = itemCount, Status = status, ScorePercent = score });
    }

    /// <summary>
    /// The most recent evaluation recorded for the server behind <paramref name="connectionString"/>,
    /// or null when that server has never been audited on this machine.
    /// </summary>
    public static PreviousEvaluation? FindLatestForServer(string? connectionString)
    {
        var serverName = AuditOutputPaths.ResolveServerName(connectionString);
        if (string.IsNullOrWhiteSpace(serverName)) return null;

        foreach (var directory in AuditOutputPaths.GetRunDirectories())
        {
            if (!AuditOutputPaths.TryParseRunDirectoryName(directory, out var startedAt, out var directoryServer))
                continue;
            if (!MatchesServer(directoryServer, serverName)) continue;
            if (!File.Exists(Path.Combine(directory, "checklist_results.json"))) continue;

            var metadata = Read(directory) ?? Reconstruct(directory, serverName, startedAt);
            if (metadata.ItemCount == 0) continue;

            return new PreviousEvaluation { RunDirectory = directory, Metadata = metadata };
        }

        return null;
    }

    private static bool MatchesServer(string directoryServer, string serverName) =>
        string.Equals(directoryServer, serverName, StringComparison.OrdinalIgnoreCase)
        || string.Equals(CollisionSuffix.Replace(directoryServer, string.Empty), serverName, StringComparison.OrdinalIgnoreCase);

    /// <summary>Metadata for runs recorded before this file existed, derived from what is on disk.</summary>
    private static EvaluationRunMetadata Reconstruct(string runDirectory, string serverName, DateTime startedAt)
    {
        var resultsPath = Path.Combine(runDirectory, "checklist_results.json");
        var (itemCount, status, score) = Summarize(resultsPath);
        var completedAt = File.Exists(resultsPath) ? File.GetLastWriteTime(resultsPath) : startedAt;

        return new EvaluationRunMetadata
        {
            ServerName = serverName,
            StartedAt = startedAt,
            CompletedAt = completedAt,
            DurationSeconds = completedAt > startedAt ? (completedAt - startedAt).TotalSeconds : null,
            ItemCount = itemCount,
            Status = status,
            ScorePercent = score,
        };
    }

    private static (int ItemCount, string Status, double? Score) Summarize(string resultsPath)
    {
        if (!File.Exists(resultsPath)) return (0, PartialStatus, null);

        List<ChecklistItemResult> items;
        try
        {
            lock (Auditor.ResultsFileLock)
            {
                items = ChecklistResultsLoader.Load(resultsPath);
            }
        }
        catch
        {
            return (0, PartialStatus, null);
        }

        var pending = items.Count(item =>
            string.IsNullOrWhiteSpace(item.Outcome)
            || string.Equals(item.Outcome, "Evaluating", StringComparison.OrdinalIgnoreCase)
            || string.Equals(item.Outcome, "Not Started", StringComparison.OrdinalIgnoreCase)
            || string.Equals(item.Outcome, "NeedsReview", StringComparison.OrdinalIgnoreCase)
            || string.Equals(item.Outcome, "Needs Review", StringComparison.OrdinalIgnoreCase));

        double? score = null;
        try
        {
            var calculator = new ScoreCalculator();
            var enriched = new ReportInputEnricher().Enrich(items);
            score = calculator.ComputeOverallScore(calculator.ComputeAreaScores(enriched));
        }
        catch
        {
        }

        return (items.Count, pending == 0 ? CompletedStatus : PartialStatus, score);
    }

    private static EvaluationRunMetadata? Read(string runDirectory)
    {
        var path = Path.Combine(runDirectory, FileName);
        if (!File.Exists(path)) return null;

        try
        {
            return JsonSerializer.Deserialize<EvaluationRunMetadata>(File.ReadAllText(path), SerializerOptions);
        }
        catch
        {
            return null;
        }
    }

    private static void Write(string runDirectory, EvaluationRunMetadata metadata)
    {
        try
        {
            File.WriteAllText(
                Path.Combine(runDirectory, FileName),
                JsonSerializer.Serialize(metadata, SerializerOptions));
        }
        catch
        {
        }
    }
}
