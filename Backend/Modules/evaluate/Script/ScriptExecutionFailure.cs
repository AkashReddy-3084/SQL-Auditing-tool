using System;
using System.Collections.Generic;
using System.Linq;

namespace SQLAuditor.Lib;

/// <summary>
/// A script that never executed - a command timeout, a SQL error, a database the engine
/// could not evaluate - leaves its control unverified. That is a review task, not an
/// observed control gap, so the item is routed to the existing manual-review pipeline
/// carrying both the execution error and the generated manual steps.
/// </summary>
public static class ScriptExecutionFailure
{
    /// <summary>Opens the Finding the engine writes for a database it could not evaluate.</summary>
    public const string DatabaseFailureMarker = "Database evaluation failed";

    private static readonly string[] FindingAliases = { "Finding", "Findings", "Detail", "Details", "Message" };

    /// <summary>True when execution ended on an error rather than on a verdict.</summary>
    public static bool IsExecutionFailure(string? executionError) =>
        !string.IsNullOrWhiteSpace(executionError);

    /// <summary>
    /// The findings of databases the engine could not evaluate, or null when no row reports
    /// one. An unassessed result without such a row came from a script that ran successfully
    /// and deliberately deferred to a reviewer, which is not an execution failure.
    /// </summary>
    public static string? DatabaseFailureDetail(IReadOnlyList<SqlScriptRow>? rows)
    {
        if (rows is null) return null;

        var failures = rows
            .Select(row => row.Get(FindingAliases))
            .Where(finding => finding != null
                && finding.StartsWith(DatabaseFailureMarker, StringComparison.OrdinalIgnoreCase))
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToList();

        return failures.Count == 0 ? null : string.Join("; ", failures);
    }

    /// <summary>
    /// Evidence for the manual-review result. The error is kept verbatim so the reviewer can
    /// tell a tooling failure from a finding, and the steps are the same guidance a manual
    /// item carries, so the existing CSV export needs no special case.
    /// </summary>
    public static string BuildEvidence(string note, string? executionError, string? manualSteps)
    {
        var error = string.IsNullOrWhiteSpace(executionError)
            ? "(no error text captured)"
            : executionError.Trim();

        return $"{note}\n\nScript Execution Error:\n{error}\n\nManual Steps:\n{manualSteps ?? string.Empty}";
    }
}
