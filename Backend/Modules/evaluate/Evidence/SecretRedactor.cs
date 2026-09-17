using System.Text.RegularExpressions;

namespace SQLAuditor.Lib;

/// <summary>
/// Masks credentials before evidence text leaves the workspace, so a secret that is committed in
/// the repository under audit is never echoed into a prompt, a manifest, a log or a report.
/// </summary>
public static class SecretRedactor
{
    public const string Mask = "[REDACTED]";

    private static readonly RegexOptions Options = RegexOptions.IgnoreCase | RegexOptions.CultureInvariant;

    private static readonly Regex[] Patterns =
    {
        // key=value forms in connection strings, config files and pipeline variables
        new(@"\b(password|pwd|pass|secret|api[_-]?key|apikey|access[_-]?key|client[_-]?secret|sas[_-]?token|connectionstring|conn[_-]?str)\b\s*[:=]\s*(""[^""\r\n]*""|'[^'\r\n]*'|[^\s;,""'&\r\n]+)", Options),
        // JSON / YAML members
        new(@"(""(?:password|pwd|secret|apiKey|api_key|accessKey|clientSecret|sasToken|token)""\s*:\s*)(""[^""\r\n]*"")", Options),
        // PEM private key blocks
        new(@"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----", Options),
        // Common provider token shapes
        new(@"\bgh[pousr]_[A-Za-z0-9]{20,}\b", Options),
        new(@"\bgithub_pat_[A-Za-z0-9_]{20,}\b", Options),
        new(@"\bxox[abprs]-[A-Za-z0-9-]{10,}\b", Options),
        new(@"\bAKIA[0-9A-Z]{16}\b", RegexOptions.CultureInvariant),
        // JWTs
        new(@"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b", RegexOptions.CultureInvariant),
        // credentials embedded in a URL
        new(@"(?<=://)[^\s/:@]+:[^\s/@]+(?=@)", Options),
    };

    public static string Redact(string? text)
    {
        if (string.IsNullOrEmpty(text)) return text ?? string.Empty;

        var result = text;
        foreach (var pattern in Patterns)
        {
            result = pattern.Replace(result, match => ReplaceValue(match));
        }
        return result;
    }

    /// <summary>True when the text still looks like it carries a credential after redaction.</summary>
    public static bool ContainsSecret(string? text)
        => !string.IsNullOrEmpty(text) && !string.Equals(Redact(text), text, System.StringComparison.Ordinal);

    // Keeps the key visible so the reviewer can still see WHICH setting held a secret.
    private static string ReplaceValue(Match match)
    {
        if (match.Groups.Count > 2 && match.Groups[1].Success && match.Groups[2].Success)
        {
            var keyEnd = match.Groups[2].Index - match.Index;
            return match.Value.Substring(0, keyEnd) + Mask;
        }

        return Mask;
    }
}
