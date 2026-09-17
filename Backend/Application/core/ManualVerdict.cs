using System;
using System.Text.RegularExpressions;

namespace SQLAuditor.Lib;

/// <summary>
/// The single place a reviewer's decision text is turned into a persisted Outcome, shared by the
/// engine, the MCP/CLI hosts and the WPF app so all three agree on what a verdict means.
/// </summary>
public static class ManualVerdict
{
    public const string Pass = "Pass";
    public const string Fail = "Fail";
    public const string NotApplicable = NotApplicableEvidence.Outcome;
    public const string NeedsReview = "NeedsReview";

    // Only a verdict the reviewer leads with counts. Scanning the whole sentence is what let
    // "no failover test evidence" resolve to Fail and "password policy enforced" to Pass.
    private static readonly Regex LeadingVerdict = new(
        @"^[\s\-*#>""'\[\(]*(?<verdict>not[\s\-]?applicable|n\s*/\s*a|not\s+in\s+scope|needs[\s\-]?review|pass(?:ed)?|fail(?:ed)?)\b",
        RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);

    /// <summary>
    /// Reads the verdict the reviewer led their evidence with, or null when they did not state one.
    /// </summary>
    public static string? TryParse(string? text)
    {
        if (string.IsNullOrWhiteSpace(text)) return null;

        var match = LeadingVerdict.Match(text);
        if (!match.Success) return null;

        return Canonicalize(match.Groups["verdict"].Value);
    }

    /// <summary>Same as <see cref="TryParse"/>, but an unstated verdict stays NeedsReview.</summary>
    public static string Parse(string? text) => TryParse(text) ?? NeedsReview;

    /// <summary>
    /// Normalizes an explicit decision token supplied by a caller (MCP <c>resolve_review</c>, CLI,
    /// or a WPF outcome button). Returns null when the token is not a recognised verdict.
    /// </summary>
    public static string? Normalize(string? decision)
    {
        var v = decision?.Trim().Trim('.', '!', '"', '\'');
        if (string.IsNullOrEmpty(v)) return null;

        return Canonicalize(v);
    }

    public static bool IsDecided(string? outcome)
    {
        var v = Normalize(outcome);
        return v == Pass || v == Fail || v == NotApplicable;
    }

    private static string? Canonicalize(string verdict)
    {
        var v = Regex.Replace(verdict.Trim(), @"[\s\-/]+", string.Empty).ToLowerInvariant();

        return v switch
        {
            "pass" or "passed" or "p" or "yes" or "y" or "ok" or "compliant" => Pass,
            "fail" or "failed" or "failure" or "f" or "no" or "n" or "noncompliant" => Fail,
            "notapplicable" or "na" or "notinscope" or "outofscope" => NotApplicable,
            "needsreview" or "review" or "r" or "needreview" or "unknown" or "inconclusive" => NeedsReview,
            _ => null,
        };
    }
}
