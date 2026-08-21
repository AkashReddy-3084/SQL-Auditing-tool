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

        // Score (0-3) derived from the outcome when the engine did not provide one.
        var score = result.Score;
        if (score is null && !isNotApplicable)
        {
            score = DeriveScore(result.Outcome);
        }

        // Script-evaluated items carry facts produced by the SQL script and wording
        // authored by the AI enricher. Back-filling them with generic templates would
        // destroy that traceability, so only the score/severity rubric is applied and
        // the AI-authored fields stay null when AI was unavailable.
        if (string.Equals(result.Technique, "Script", StringComparison.OrdinalIgnoreCase))
        {
            return result with
            {
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
            ? DefaultFinding(score, result.Description, isNotApplicable)
            : result.Finding;

        // Recommendation: preserve any engine-supplied (e.g. MCP) value; otherwise
        // derive a context-specific corrective action from the score. Fully implemented
        // and N/A items need no action, so the recommendation stays null.
        var recommendation = string.IsNullOrWhiteSpace(result.Recommendation) ? null : result.Recommendation;
        if (recommendation is null && !isNotApplicable)
        {
            recommendation = DefaultRecommendation(score, result.Description);
        }

        // Effort aligns with the recommendation: when no action is required, no
        // effort is recorded.
        var effort = string.IsNullOrWhiteSpace(result.Effort) ? null : result.Effort;
        if (effort is null && recommendation is not null)
        {
            effort = score switch { 0 => "High", 1 => "Medium", _ => "Low" };
        }

        var riskImpact = string.IsNullOrWhiteSpace(result.RiskImpact)
            ? DefaultRiskImpact(score)
            : result.RiskImpact;

        var evidence = string.IsNullOrWhiteSpace(result.Evidence)
            ? (string.IsNullOrWhiteSpace(result.ScriptFile)
                ? $"Assessed via {result.Technique}."
                : $"Assessed via {result.Technique}; script: {result.ScriptFile}.")
            : result.Evidence;

        return result with
        {
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

    // Rubric section 1: the 0-3 score an outcome maps to when the engine did not supply one.
    public static int DeriveScore(string? outcome) => outcome?.Trim().ToLowerInvariant() switch
    {
        "pass" => 3,
        "fail" => 0,
        "needsreview" or "needs review" => 1,
        _ => 2,
    };

    public static string DefaultRiskImpact(int? score) => score switch
    {
        0 => "High \u2014 control absent",
        1 => "Medium \u2014 partial coverage",
        _ => "Low \u2014 control in place",
    };

    public static string DefaultFinding(int? score, string? description, bool isNotApplicable) => isNotApplicable
        ? $"Not applicable: {description}."
        : score switch
        {
            0 => $"Gap identified: '{description}' is not implemented.",
            1 => $"Partial implementation: '{description}' is in place but has notable gaps.",
            2 => $"Implemented with minor improvement opportunities: {description}.",
            _ => $"Control satisfied: {description}.",
        };

    public static string? DefaultRecommendation(int? score, string? description) => score switch
    {
        0 => $"Implement the control '{description}', which is currently absent, and capture documented evidence of the change.",
        1 => $"Close the remaining gaps in '{description}' to move it from partial to full implementation.",
        2 => $"Optimize '{description}' toward best practice and document the supporting configuration.",
        _ => null,
    };

    // Rubric section 6: severity tracks the score, escalating to Critical for a total
    // gap in the security (area 6) and compliance (area 7) areas, where the exposure
    // is active rather than latent.
    public static string DeriveSeverity(string id, int? score, bool isNotApplicable)
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
