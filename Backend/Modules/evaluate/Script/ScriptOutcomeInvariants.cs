using System;

namespace SQLAuditor.Lib;

/// <summary>
/// Conditions under which an audit script's verdict cannot be trusted. Each one exists
/// because the engine previously turned a tooling failure into a confident Fail: a query
/// timeout and a self-contradicting Pass both scored 0 and were reported as genuine
/// control gaps.
/// </summary>
public static class ScriptOutcomeInvariants
{
    // The generator contract derives Result as CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail',
    // so a Pass can never legitimately carry a score below 2.
    private const int MinimumPassScore = 2;

    /// <summary>True when execution ended on a command timeout rather than a verdict.</summary>
    public static bool IsTimeout(string? error) =>
        !string.IsNullOrWhiteSpace(error)
        && (error.Contains("Execution Timeout Expired", StringComparison.OrdinalIgnoreCase)
            || error.Contains("timeout period elapsed", StringComparison.OrdinalIgnoreCase));

    /// <summary>True when the script returned Pass alongside a score that denies it.</summary>
    public static bool IsContradictoryPass(string? outcome, int? score) =>
        string.Equals(outcome?.Trim(), "Pass", StringComparison.OrdinalIgnoreCase)
        && score.HasValue
        && score.Value < MinimumPassScore;
}
