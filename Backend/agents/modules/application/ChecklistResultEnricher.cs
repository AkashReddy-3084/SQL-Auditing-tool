using System;

namespace SQLAuditor.Lib;

/// <summary>
/// Back-fills the report-oriented fields (Score, Severity, Finding, etc.) on a
/// <see cref="ChecklistResult"/> with deterministic defaults so that the
/// persisted <c>checklist_results.json</c> is always schema-compatible with the
/// Summary Report generator.
///
/// Values already supplied by the assessment engine (for example by the MCP
/// evaluator) are preserved; only missing fields are populated. The default
/// formulas intentionally mirror the report generator's own enricher so the
/// numbers are identical regardless of where they are computed.
/// </summary>
public static class ChecklistResultEnricher
{
    public static ChecklistResult Enrich(ChecklistResult result)
    {
        if (result == null) return result!;

        var isNotApplicable = result.NotApplicable == true
            || string.Equals(result.Outcome, "N/A", StringComparison.OrdinalIgnoreCase);

        // Score (0–3) derived from the outcome when the engine did not provide one.
        var score = result.Score;
        if (score is null && !isNotApplicable)
        {
            score = result.Outcome?.Trim().ToLowerInvariant() switch
            {
                "pass" => 3,
                "fail" => 0,
                "needsreview" or "needs review" => 1,
                _ => 2,
            };
        }

        // var implementationStatus = string.IsNullOrWhiteSpace(result.ImplementationStatus)
        //     ? (isNotApplicable
        //         ? "Not Applicable"
        //         : score switch
        //         {
        //             0 => "Not Implemented",
        //             1 => "Partial",
        //             2 => "Implemented",
        //             3 => "Best Practice",
        //             _ => string.Empty,
        //         })
        //     : result.ImplementationStatus;

        var severity = string.IsNullOrWhiteSpace(result.Severity)
            ? score switch
            {
                0 => "High",
                1 => "Medium",
                2 => "Low",
                _ => "Informational",
            }
            : result.Severity;

        var finding = string.IsNullOrWhiteSpace(result.Finding)
            ? (isNotApplicable
                ? $"Not applicable: {result.Description}."
                : score switch
                {
                    0 => $"Gap identified: '{result.Description}' is not implemented.",
                    1 => $"Partial implementation: '{result.Description}' is in place but has notable gaps.",
                    2 => $"Implemented with minor improvement opportunities: {result.Description}.",
                    _ => $"Control satisfied: {result.Description}.",
                })
            : result.Finding;

        // Recommendation: preserve any engine-supplied (e.g. MCP) value; otherwise
        // derive a context-specific corrective action from the implementation status.
        // Fully implemented (Best Practice) and N/A items need no action, so the
        // recommendation stays null.
        var recommendation = string.IsNullOrWhiteSpace(result.Recommendation) ? null : result.Recommendation;
        if (recommendation is null && !isNotApplicable)
        {
            recommendation = score switch
            {
                0 => $"Implement the control '{result.Description}', which is currently absent, and capture documented evidence of the change.",
                1 => $"Close the remaining gaps in '{result.Description}' to move it from partial to full implementation.",
                2 => $"Optimize '{result.Description}' toward best practice and document the supporting configuration.",
                _ => null,
            };
        }

        // Effort aligns with the recommendation: when no action is required, no
        // effort is recorded.
        var effort = string.IsNullOrWhiteSpace(result.Effort) ? null : result.Effort;
        if (effort is null && recommendation is not null)
        {
            effort = score switch { 0 => "High", 1 => "Medium", _ => "Low" };
        }

        var riskImpact = string.IsNullOrWhiteSpace(result.RiskImpact)
            ? score switch
            {
                0 => "High \u2014 control absent",
                1 => "Medium \u2014 partial coverage",
                _ => "Low \u2014 control in place",
            }
            : result.RiskImpact;

        // var scoreImpact = result.ScoreImpact;
        // if (scoreImpact is null && score.HasValue)
        // {
        //     scoreImpact = 3 - score.Value;
        // }

        var evidence = string.IsNullOrWhiteSpace(result.Evidence)
            ? (string.IsNullOrWhiteSpace(result.ScriptFile)
                ? $"Assessed via {result.Technique}."
                : $"Assessed via {result.Technique}; script: {result.ScriptFile}.")
            : result.Evidence;

        return result with
        {
            Score = score,
            // ImplementationStatus = implementationStatus,
            Severity = severity,
            Finding = finding,
            Recommendation = recommendation,
            Effort = effort,
            RiskImpact = riskImpact,
            // ScoreImpact = scoreImpact,
            Evidence = evidence,
            NotApplicable = isNotApplicable ? true : result.NotApplicable,
        };
    }
}
