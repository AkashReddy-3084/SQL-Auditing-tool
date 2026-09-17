using SQLAuditor.Lib;
using Xunit;

namespace SQLAuditor.Tests;

/// <summary>
/// The four behaviours that separate a script verdict from a script that never ran:
/// a Pass and a Fail keep their verdict, an execution failure becomes a manual review,
/// and a repeated failure reuses the stored steps instead of generating them again.
/// </summary>
public class ScriptExecutionFailureFallbackTests
{
    private const string TimeoutError =
        "Execution Timeout Expired. The timeout period elapsed prior to completion of the operation.";

    private static SqlScriptRow VerdictRow(string result, string score, string database, string finding) =>
        new(new[] { "Result", "Score", "DatabaseQueried", "Finding" },
            new[] { result, score, database, finding });

    [Fact]
    public void SuccessfulScriptKeepsItsPassVerdict()
    {
        var outcome = SqlScriptResultParser.Parse(
            new[] { VerdictRow("Pass", "3", "AdventureWorks", "Control in place.") },
            error: null);

        Assert.Equal("Pass", outcome.Result);
        Assert.Equal(3, outcome.Score);
        Assert.False(ScriptExecutionFailure.IsExecutionFailure(null));
        Assert.False(ScriptOutcomeInvariants.IsTimeout(null));
    }

    [Fact]
    public void GenuineFailKeepsItsFailVerdict()
    {
        var outcome = SqlScriptResultParser.Parse(
            new[] { VerdictRow("Fail", "0", "AdventureWorks", "Control absent.") },
            error: null);

        Assert.Equal("Fail", outcome.Result);
        Assert.Equal(0, outcome.Score);
        // No execution error, so the fallback never applies and the Fail is reported as-is.
        Assert.False(ScriptExecutionFailure.IsExecutionFailure(null));
    }

    [Fact]
    public void TimeoutIsClassifiedAsAnExecutionFailure()
    {
        Assert.True(ScriptOutcomeInvariants.IsTimeout(TimeoutError));
        Assert.True(ScriptExecutionFailure.IsExecutionFailure(TimeoutError));

        var outcome = SqlScriptResultParser.Parse(Array.Empty<SqlScriptRow>(), TimeoutError);
        Assert.Null(outcome.Result);
        Assert.Equal(TimeoutError, outcome.Error);
    }

    [Fact]
    public void SqlExecutionErrorIsClassifiedAsAnExecutionFailure()
    {
        const string error = "Invalid object name 'sys.dm_os_missing_table'.";

        Assert.False(ScriptOutcomeInvariants.IsTimeout(error));
        Assert.True(ScriptExecutionFailure.IsExecutionFailure(error));
    }

    [Fact]
    public void CapturedSqlErrorTextIsClassifiedAsAnExecutionFailure()
    {
        // ExecuteSqlCaptureAsync never throws; it returns the error as its log text.
        Assert.True(ScriptExecutionFailure.IsExecutionFailure("SQL ERROR: Invalid object name 'sys.nope'."));
        Assert.True(ScriptOutcomeInvariants.IsTimeout("SQL ERROR: " + TimeoutError));
    }

    [Fact]
    public void ErrorAlongsideAVerdictKeepsTheVerdict()
    {
        // One failed batch must not discard the verdict a later batch produced.
        var outcome = SqlScriptResultParser.Parse(
            new[] { VerdictRow("Fail", "0", "AdventureWorks", "Control absent.") },
            error: "SQL ERROR: Invalid object name 'sys.nope'.");

        Assert.Equal("Fail", outcome.Result);
    }

    [Fact]
    public void PerDatabaseExecutionErrorParsesAsUnassessedRatherThanFail()
    {
        // The engine's own failure row, written when a database could not be evaluated.
        var row = new SqlScriptRow(
            new[] { "Result", "DatabaseQueried", "Finding" },
            new[] { SqlScriptResultParser.Unassessed, "AdventureWorks", $"{ScriptExecutionFailure.DatabaseFailureMarker}: login failed." });

        var outcome = SqlScriptResultParser.Parse(new[] { row }, error: null);

        Assert.Equal(SqlScriptResultParser.Unassessed, outcome.Result);
        Assert.Null(outcome.Score);
        Assert.Contains("login failed.", ScriptExecutionFailure.DatabaseFailureDetail(outcome.Rows));
    }

    [Fact]
    public void ScriptThatDeliberatelyDefersIsNotAnExecutionFailure()
    {
        // A script returning 'Review' ran successfully; its finding must never be reported
        // as an execution error.
        var outcome = SqlScriptResultParser.Parse(
            new[] { VerdictRow("Review", "3", "master", "Found 1 non-default principal in sysadmin role.") },
            error: null);

        Assert.Equal(SqlScriptResultParser.Unassessed, outcome.Result);
        Assert.Null(ScriptExecutionFailure.DatabaseFailureDetail(outcome.Rows));
    }

    [Fact]
    public void ManualReviewEvidencePreservesTheErrorAndTheSteps()
    {
        const string note = "The audit script for 1.1.2 exceeded its command timeout.";
        const string steps = "1. Open SSMS.\n2. Run the query manually.";

        var evidence = ScriptExecutionFailure.BuildEvidence(note, TimeoutError, steps);

        Assert.Contains(note, evidence);
        Assert.Contains(TimeoutError, evidence);
        Assert.Contains(steps, evidence);
    }

    [Fact]
    public void ExecutionFailureResultStaysOnTheManualTechniqueAndOutcome()
    {
        var result = new ChecklistResult(
            "1.1.2", "Database design is documented", "Review the design docs",
            "NeedsReview",
            ScriptExecutionFailure.BuildEvidence("note", TimeoutError, "steps"),
            "Scripts/sql/1.1.2.sql",
            "AI-Manual");

        var enriched = ChecklistResultEnricher.Enrich(result);

        // Picked up by every manual surface: WPF queue, CLI/IDE review block and the CSV.
        Assert.True(HistoricalManualResultsStore.IsManualTechnique(enriched.Technique));
        Assert.Equal("NeedsReview", enriched.Outcome);
        Assert.Equal(1, enriched.Score);
        Assert.False(HistoricalManualResultsStore.IsCompletedOutcome(enriched.Outcome));
    }

    [Fact]
    public void RepeatedExecutionFailureReusesStoredStepsWithoutGeneratingAgain()
    {
        using var workspace = new TemporaryWorkingDirectory();
        const string id = "1.1.2";

        var generatorCalls = 0;

        // Mirrors Auditor.GenerateManualInstructionsWithMetadataAsync: the store is consulted
        // first and the provider is only called when nothing is stored for the item.
        string ResolveSteps()
        {
            if (ManualMigrationStepsStore.TryGet(id, out var stored)) return stored;
            generatorCalls++;
            var generated = "1. Open SSMS.\n2. Run the query manually.";
            ManualMigrationStepsStore.Store(id, generated);
            return generated;
        }

        var first = ResolveSteps();
        var second = ResolveSteps();

        Assert.Equal(1, generatorCalls);
        Assert.Equal(first, second);
        Assert.True(ManualMigrationStepsStore.TryGet(id, out var persisted));
        Assert.Equal(first, persisted);
    }

    /// <summary>The store writes under the current directory, so each test gets its own.</summary>
    private sealed class TemporaryWorkingDirectory : IDisposable
    {
        private readonly string _previous = Directory.GetCurrentDirectory();
        private readonly string _path = Path.Combine(Path.GetTempPath(), "sqlauditor-tests-" + Guid.NewGuid().ToString("N"));

        public TemporaryWorkingDirectory()
        {
            Directory.CreateDirectory(_path);
            Directory.SetCurrentDirectory(_path);
        }

        public void Dispose()
        {
            Directory.SetCurrentDirectory(_previous);
            try { Directory.Delete(_path, recursive: true); } catch { }
        }
    }
}
