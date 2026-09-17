using System;
using System.Linq;
using System.Text.RegularExpressions;

namespace SQLAuditor.Lib;

/// <summary>
/// Recognises the URLs a user copies out of their browser address bar. Those cannot be cloned, so
/// they are rejected up front with the clone URL and branch the user should supply instead - a raw
/// "repository not found" from git gives them nothing to act on.
/// </summary>
public static class EvidenceRepositoryUrl
{
    public sealed record BrowseUrl(string CloneUrl, string? Branch);

    // https://host/owner/repo/tree|blob/<branch>[/path...]  (GitHub, GitLab, Gitea)
    private static readonly Regex WebTreeUrl = new(
        @"^(?<repo>https://[^/\s]+/[^/\s]+/[^/\s]+?)(?:\.git)?/(?:tree|blob|-/tree|-/blob)/(?<branch>[^/?#]+)(?:/[^?#]*)?(?:[?#].*)?$",
        RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);

    // https://dev.azure.com/org/project/_git/repo?version=GB<branch>
    private static readonly Regex AzureDevOpsBrowseUrl = new(
        @"^(?<repo>https://[^/\s]+/[^\s?#]*/_git/[^/?#]+)\?(?<query>[^#]*)",
        RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);

    /// <summary>
    /// Returns the clone URL and branch a browser URL was pointing at, or null when the URL is
    /// already a clone URL.
    /// </summary>
    public static BrowseUrl? TryParseBrowseUrl(string? url)
    {
        var trimmed = (url ?? string.Empty).Trim();
        if (trimmed.Length == 0) return null;

        var web = WebTreeUrl.Match(trimmed);
        if (web.Success)
        {
            // A branch containing '/' is indistinguishable from the path here, so only the first
            // segment is suggested; the user confirms it in the Branch field.
            return new BrowseUrl(web.Groups["repo"].Value + ".git", Uri.UnescapeDataString(web.Groups["branch"].Value));
        }

        var ado = AzureDevOpsBrowseUrl.Match(trimmed);
        if (ado.Success)
        {
            var branch = ReadAzureVersion(ado.Groups["query"].Value);
            if (branch != null) return new BrowseUrl(ado.Groups["repo"].Value, branch);
        }

        return null;
    }

    public static bool IsBrowseUrl(string? url) => TryParseBrowseUrl(url) != null;

    /// <summary>Message shown when a browser URL is supplied, naming what to use instead.</summary>
    public static string DescribeBrowseUrlRejection(BrowseUrl parsed)
    {
        var branch = string.IsNullOrWhiteSpace(parsed.Branch) ? "<branch>" : parsed.Branch;
        return "That is a browser URL, not a clone URL, so it cannot be cloned.\n\n"
             + $"Use the clone URL instead:  {parsed.CloneUrl}\n"
             + $"and enter the branch separately:  {branch}";
    }

    private static string? ReadAzureVersion(string? query)
    {
        if (string.IsNullOrWhiteSpace(query)) return null;

        var version = query.Split('&', StringSplitOptions.RemoveEmptyEntries)
            .Select(p => p.Split('=', 2))
            .FirstOrDefault(p => p.Length == 2 && p[0].Equals("version", StringComparison.OrdinalIgnoreCase))?[1];
        if (string.IsNullOrWhiteSpace(version)) return null;

        // Azure DevOps prefixes GB for branch, GT for tag, GC for commit.
        var value = Uri.UnescapeDataString(version);
        if (!value.StartsWith("GB", StringComparison.OrdinalIgnoreCase) && !value.StartsWith("GT", StringComparison.OrdinalIgnoreCase))
            return null;

        var branch = value[2..].Trim();
        return branch.Length == 0 ? null : branch;
    }
}
