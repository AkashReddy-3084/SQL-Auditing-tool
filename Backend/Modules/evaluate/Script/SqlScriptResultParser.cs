using System;
using System.Collections.Generic;
using System.Linq;

namespace SQLAuditor.Lib;

/// <summary>
/// Turns the rows returned by an audit SQL script into a <see cref="SqlScriptOutcome"/>.
/// Audit scripts end with a SELECT exposing Result / Score / DatabaseQueried / Finding,
/// so those columns are read by name (with tolerant aliases) rather than scraped from
/// the console text.
/// </summary>
internal static class SqlScriptResultParser
{
    // The generator contract derives Result as CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail'.
    private const int PassScore = 2;

    private static readonly string[] ResultAliases = { "Result", "Outcome", "Status", "PassFail" };
    private static readonly string[] ScoreAliases = { "Score", "DbScore", "ItemScore" };
    private static readonly string[] DatabaseAliases = { "DatabaseQueried", "DatabasesQueried", "DatabasesVerified", "DbName", "DatabaseName", "Database" };
    private static readonly string[] FindingAliases = { "Finding", "Findings", "Detail", "Details", "Message" };

    public static SqlScriptOutcome Parse(IReadOnlyList<SqlScriptRow> rows, string? error = null)
    {
        if (rows == null || rows.Count == 0)
            return new SqlScriptOutcome { Error = error };

        // Only rows carrying at least one recognised verdict column contribute to the
        // aggregate; diagnostic rows are still preserved for the AI fact sheet.
        var verdictRows = rows
            .Where(r => r.Get(ResultAliases) != null || r.Get(ScoreAliases) != null || r.Get(FindingAliases) != null)
            .ToList();

        var scores = verdictRows
            .Select(TryGetScore)
            .Where(n => n.HasValue)
            .Select(n => n!.Value)
            .ToList();

        // The strictest per-database verdict governs the item as a whole.
        int? score = scores.Count == 0 ? null : scores.Min();

        var results = verdictRows
            .Select(ResolveRowOutcome)
            .Where(v => v != null)
            .ToList();

        string? result = null;
        if (results.Count > 0)
            result = results.Contains("Fail") ? "Fail" : "Pass";

        var databases = rows
            .Select(r => r.Get(DatabaseAliases))
            .Where(v => !string.IsNullOrWhiteSpace(v))
            .SelectMany(v => v!.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToList();

        var findings = verdictRows
            .Select(r => r.Get(FindingAliases))
            .Where(v => !string.IsNullOrWhiteSpace(v))
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToList();

        return new SqlScriptOutcome
        {
            Result = result,
            Score = score,
            DatabasesVerified = databases.Count == 0 ? null : string.Join(", ", databases),
            Finding = findings.Count == 0 ? null : string.Join("; ", findings),
            Rows = rows,
            Error = error,
        };
    }

    private static int? TryGetScore(SqlScriptRow row)
        => int.TryParse(row.Get(ScoreAliases), out var n) ? n : null;

    // A script-evaluated row must settle on Pass or Fail. Only 'Pass' and 'Fail' are
    // honoured from the Result column; any other wording a script emits ('Review',
    // 'Warning', 'Unknown') is resolved from that row's Score instead, so a
    // non-conforming script can never leave the item without a verdict. A row that
    // carries neither returns null and does not contribute to the aggregate.
    private static string? ResolveRowOutcome(SqlScriptRow row)
    {
        var raw = row.Get(ResultAliases)?.Trim();
        if (raw != null)
        {
            if (raw.StartsWith("pass", StringComparison.OrdinalIgnoreCase)) return "Pass";
            if (raw.StartsWith("fail", StringComparison.OrdinalIgnoreCase)) return "Fail";
        }

        var score = TryGetScore(row);
        if (score.HasValue) return score.Value >= PassScore ? "Pass" : "Fail";

        return raw == null ? null : "Fail";
    }
}
