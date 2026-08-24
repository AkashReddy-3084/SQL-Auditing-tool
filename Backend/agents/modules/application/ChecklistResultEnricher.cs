using System;

namespace SQLAuditor.Lib;

/// <summary>
/// The AI enricher opens the Evidence with "Not Applicable." when the script result held
/// no supporting artefact at all - the control does not exist to be assessed rather than
/// being implemented ineffectively. Such an item is reported with Outcome <c>N/A</c> and
/// is excluded from every score.
/// </summary>
public static class NotApplicableEvidence
{
    public const string Marker = "Not Applicable";

    public const string Outcome = "N/A";

    /// <summary>True when AI-authored evidence declares the item not applicable.</summary>
    public static bool IsMarked(string? evidence) =>
        !string.IsNullOrWhiteSpace(evidence)
        && evidence.TrimStart().StartsWith(Marker, StringComparison.OrdinalIgnoreCase);

    /// <summary>True for the persisted N/A outcome, in any of its spellings.</summary>
    public static bool IsNotApplicableOutcome(string? outcome)
    {
        var v = outcome?.Trim();
        return !string.IsNullOrEmpty(v)
            && (v.Equals(Outcome, StringComparison.OrdinalIgnoreCase)
                || v.Equals("NA", StringComparison.OrdinalIgnoreCase)
                || v.Equals(Marker, StringComparison.OrdinalIgnoreCase));
    }
}

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
            || NotApplicableEvidence.IsNotApplicableOutcome(result.Outcome)
            || NotApplicableEvidence.IsMarked(result.Evidence);

        var outcome = isNotApplicable ? NotApplicableEvidence.Outcome : result.Outcome;

        // Score (0-3) derived from the outcome when the engine did not provide one.
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

        // Script-evaluated items carry facts produced by the SQL script and wording
        // authored by the AI enricher. Back-filling them with generic templates would
        // destroy that traceability, so only the score/severity rubric is applied and
        // the AI-authored fields stay null when AI was unavailable.
        if (string.Equals(result.Technique, "Script", StringComparison.OrdinalIgnoreCase))
        {
            return result with
            {
                Outcome = outcome,
                Score = score,
                Severity = string.IsNullOrWhiteSpace(result.Severity)
                    ? DeriveSeverity(result.Id, score, isNotApplicable)
                    : result.Severity,
                NotApplicable = isNotApplicable ? true : result.NotApplicable,
            };
        }

        var severity = string.IsNullOrWhiteSpace(result.Severity)
            ? DeriveSeverity(result.Id, score, isNotApplicable)
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
        // derive a context-specific corrective action from the score. Fully implemented
        // and N/A items need no action, so the recommendation stays null.
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

        var evidence = string.IsNullOrWhiteSpace(result.Evidence)
            ? (string.IsNullOrWhiteSpace(result.ScriptFile)
                ? $"Assessed via {result.Technique}."
                : $"Assessed via {result.Technique}; script: {result.ScriptFile}.")
            : result.Evidence;

        return result with
        {
            Outcome = outcome,
            Score = score,
            Severity = severity,
            Finding = finding,
            Recommendation = recommendation,
            Effort = effort,
            RiskImpact = riskImpact,
            Evidence = evidence,
            NotApplicable = isNotApplicable ? true : result.NotApplicable,
        };
    }

    // Rubric section 6: severity tracks the score, escalating to Critical for a total
    // gap in the security (area 6) and compliance (area 7) areas, where the exposure
    // is active rather than latent.
    private static string DeriveSeverity(string id, int? score, bool isNotApplicable)
    {
        if (isNotApplicable) return "Informational";

        var dot = id?.IndexOf('.') ?? -1;
        var head = dot >= 0 ? id![..dot] : id;
        var area = int.TryParse(head, out var n) ? n : 0;

        return score switch
        {
            0 => area is 6 or 7 ? "Critical" : "High",
            1 => "Medium",
            2 => "Low",
            _ => "Informational",
        };
    }
}
