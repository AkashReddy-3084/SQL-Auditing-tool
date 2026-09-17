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

    /// <summary>Verdict for a control nobody could settle: written by the engine when a database
    /// could not be evaluated, and by scripts that deliberately defer to a reviewer.</summary>
    public const string Unassessed = "NeedsReview";

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
        {
            // Every row declaring itself not applicable means the control does not exist to be
            // assessed. A mix is judged on the rows that do apply. A row the engine could not
            // evaluate yields no verdict, so it can only be settled by a reviewer - but a real
            // Fail from a database that did evaluate is still a genuine finding and wins.
            result = results.All(v => string.Equals(v, NotApplicableEvidence.Outcome, StringComparison.OrdinalIgnoreCase))
                ? NotApplicableEvidence.Outcome
                : results.Contains("Fail") ? "Fail"
                : results.Contains(Unassessed) ? Unassessed
                : "Pass";
        }

        if (string.Equals(result, NotApplicableEvidence.Outcome, StringComparison.OrdinalIgnoreCase)
            || string.Equals(result, Unassessed, StringComparison.Ordinal))
            score = null;

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

    // A script-evaluated row settles on Pass, Fail or Not Applicable. Only those three are
    // honoured from the Result column; any other wording a script emits ('Warning',
    // 'Unknown') is resolved from that row's Score instead, so a
    // non-conforming script can never leave the item without a verdict. A row that
    // carries neither returns null and does not contribute to the aggregate.
    private static string? ResolveRowOutcome(SqlScriptRow row)
    {
        var raw = row.Get(ResultAliases)?.Trim();
        if (raw != null)
        {
            // Written by the engine when a database could not be evaluated, and by scripts that
            // defer to a reviewer. Checked before Score so it is never reinterpreted as a verdict.
            if (IsDeferredToReviewer(raw)) return Unassessed;
            if (raw.StartsWith("pass", StringComparison.OrdinalIgnoreCase)) return "Pass";
            if (raw.StartsWith("fail", StringComparison.OrdinalIgnoreCase)) return "Fail";
            if (NotApplicableEvidence.IsNotApplicableOutcome(raw)) return NotApplicableEvidence.Outcome;
        }

        var score = TryGetScore(row);
        if (score.HasValue) return score.Value >= PassScore ? "Pass" : "Fail";

        return raw == null ? null : "Fail";
    }

    // A script asking for a human is not a verdict, so the wording variants scripts actually
    // use are matched here rather than falling through to Score and becoming a Pass or Fail.
    private static bool IsDeferredToReviewer(string raw)
    {
        var collapsed = raw.Replace(" ", string.Empty).Replace("-", string.Empty).Replace("_", string.Empty);
        return collapsed.Equals("NeedsReview", StringComparison.OrdinalIgnoreCase)
            || collapsed.Equals("ManualReview", StringComparison.OrdinalIgnoreCase)
            || collapsed.Equals("Review", StringComparison.OrdinalIgnoreCase)
            || collapsed.Equals("Unassessed", StringComparison.OrdinalIgnoreCase);
    }
}
