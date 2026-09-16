using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace SQLAuditor.Lib;

/// <summary>
/// Decides a documentation or process checklist item from attached evidence using the configured
/// provider. Used by the desktop app, where there is no Copilot to act as the analyst.
///
/// The MCP server and the CLI never reach this class: both call
/// <see cref="Auditor.DisableLlmEvaluators"/>, so evidence review there is Copilot's job.
/// </summary>
internal sealed class EvidenceAiAnalyzer
{
    private const int TotalEvidenceBudgetChars = 24_000;
    private const int PerFileChars = 6_000;
    private const int MaxCandidateFiles = 10;
    private const int MaxManualStepsChars = 5_000;

    private readonly ProviderChatClient _client;

    // One permanent provider fault disables evidence review for the whole run rather than
    // making every remaining item pay the same timeout.
    private bool _providerUnavailable;

    private EvidenceAiAnalyzer(ProviderChatClient client) => _client = client;

    public static EvidenceAiAnalyzer CreateFromEnvironment() =>
        new(ProviderChatClient.CreateFromEnvironment());

    public sealed record EvidenceVerdict(
        string Decision,
        string? Confidence,
        string? RequiredArtefact,
        IReadOnlyList<string> CitedFiles,
        string? Finding,
        string? Evidence,
        string? RiskImpact,
        string? Recommendation,
        string? Severity)
    {
        /// <summary>
        /// Only Pass and Fail are applied automatically. Not Applicable is deliberately excluded:
        /// deciding that a control has nothing to assess is a human judgement, so such an item is
        /// left for manual review instead.
        /// </summary>
        public bool IsDecisive =>
            Outcome is ManualVerdict.Pass or ManualVerdict.Fail
            && CitedFiles.Count > 0;

        public string Outcome => ManualVerdict.Normalize(Decision) ?? ManualVerdict.NeedsReview;
    }

    public async Task<EvidenceVerdict?> AnalyzeAsync(
        ChecklistItem item,
        string manualSteps,
        EvidenceContext evidence,
        CancellationToken cancellationToken = default)
    {
        if (_providerUnavailable || !evidence.HasUsableEvidence) return null;

        var candidates = EvidenceRelevanceSelector.SelectFor(
            evidence.Manifest, item.Description, item.Category, MaxCandidateFiles);
        if (candidates.Count == 0) return null;

        var prompt = PromptTemplateStore.Render(
            "evidence_decision_user.txt",
            new Dictionary<string, string>
            {
                ["CHECKLIST_ITEM_ID"] = item.Id,
                ["CHECKLIST_ITEM_DESCRIPTION"] = item.Description ?? string.Empty,
                ["CHECKLIST_ITEM_CATEGORY"] = item.Category ?? string.Empty,
                ["CHECKLIST_ITEM_VERIFICATION"] = item.Verification ?? string.Empty,
                ["MANUAL_STEPS"] = Clip(manualSteps, MaxManualStepsChars),
                ["GIT_SIGNALS"] = DescribeGitSignals(evidence),
                ["EVIDENCE_FILES"] = EvidenceTextExtractor.ReadBundle(candidates, TotalEvidenceBudgetChars, PerFileChars),
            });

        string content;
        try
        {
            content = await _client.CompleteAsync(
                PromptTemplateStore.Load("evidence_decision_system.txt"),
                prompt,
                cancellationToken);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch (Exception ex)
        {
            var permanent = ProviderChatClient.IsPermanentFault(ex);
            ProviderChatClient.WriteDiagnostic(item.Id, (permanent
                ? "evidence review failed (permanent — disabled for run): "
                : "evidence review failed (transient — this item skipped): ") + ex.Message);

            if (permanent) { _providerUnavailable = true; ProviderChatClient.RecordPermanentFault(ex.Message); }
            return null;
        }

        var verdict = Parse(content);
        if (verdict == null)
        {
            ProviderChatClient.WriteDiagnostic(item.Id,
                "evidence review response did not parse into verdict JSON. Raw content: "
                + ProviderChatClient.Truncate(content, 1000));
            return null;
        }

        // A cited path the model invented would make the attribution in the report a lie.
        var allowed = candidates.Select(c => c.Path).ToHashSet(StringComparer.OrdinalIgnoreCase);
        var cited = verdict.CitedFiles.Where(allowed.Contains).ToList();
        if (cited.Count != verdict.CitedFiles.Count)
        {
            ProviderChatClient.WriteDiagnostic(item.Id,
                "evidence review cited file(s) that were not supplied; dropped: "
                + string.Join(", ", verdict.CitedFiles.Except(cited, StringComparer.OrdinalIgnoreCase)));
        }

        if (NotApplicableEvidence.IsNotApplicableOutcome(verdict.Outcome))
        {
            ProviderChatClient.WriteDiagnostic(item.Id,
                "evidence review returned Not Applicable, which only a human may decide; item left for manual review.");
            return null;
        }

        return verdict with { CitedFiles = cited };
    }

    private static string DescribeGitSignals(EvidenceContext evidence)
    {
        if (evidence.Manifest.GitSignals.Count == 0)
            return "(no git repository was attached, so no repository-level signals are available)";

        var sb = new StringBuilder();
        foreach (var git in evidence.Manifest.GitSignals)
        {
            sb.Append("Repository: ").AppendLine(git.SourceLabel);
            sb.Append("- current branch: ").AppendLine(git.CurrentBranch ?? "(unknown)");
            if (git.Branches.Count > 0)
                sb.Append("- branches: ").AppendLine(string.Join(", ", git.Branches.Take(20)));
            sb.Append("- of ").Append(git.CommitsInspected).Append(" recent commits, ")
              .Append(git.MergeCommits).Append(" are merge commits and ")
              .Append(git.CommitsReferencingWorkItems).AppendLine(" reference a work item");
            sb.Append("- CODEOWNERS present: ").Append(git.HasCodeOwners)
              .Append(" | pull-request template present: ").Append(git.HasPullRequestTemplate)
              .Append(" | secret-scanning config present: ").AppendLine(git.HasSecretScanningConfig.ToString());
            if (git.RecentCommitSubjects.Count > 0)
            {
                sb.AppendLine("- recent commit subjects:");
                foreach (var subject in git.RecentCommitSubjects.Take(15))
                    sb.Append("    ").AppendLine(subject);
            }
            sb.AppendLine();
        }
        return sb.ToString().TrimEnd();
    }

    private static string Clip(string? value, int max)
    {
        if (string.IsNullOrWhiteSpace(value)) return "(no guidance was generated for this item)";
        var trimmed = value.Trim();
        return trimmed.Length <= max ? trimmed : trimmed[..max] + "…(truncated)";
    }

    private static EvidenceVerdict? Parse(string raw)
    {
        var cleaned = ProviderChatClient.ExtractJsonObject(raw);
        if (cleaned == null) return null;

        try
        {
            using var doc = JsonDocument.Parse(cleaned);
            var root = doc.RootElement;

            var decision = ProviderChatClient.ReadString(root, "decision");
            if (string.IsNullOrWhiteSpace(decision)) return null;

            var cited = new List<string>();
            if (root.TryGetProperty("citedFiles", out var files) && files.ValueKind == JsonValueKind.Array)
            {
                foreach (var file in files.EnumerateArray())
                {
                    var path = file.GetString();
                    if (!string.IsNullOrWhiteSpace(path)) cited.Add(path.Trim());
                }
            }

            return new EvidenceVerdict(
                decision.Trim(),
                ProviderChatClient.ReadString(root, "confidence"),
                ProviderChatClient.ReadString(root, "requiredArtefact"),
                cited,
                ProviderChatClient.ReadString(root, "finding"),
                ProviderChatClient.ReadString(root, "evidence"),
                ProviderChatClient.ReadString(root, "riskImpact"),
                ProviderChatClient.ReadString(root, "recommendation"),
                ProviderChatClient.ReadString(root, "severity"));
        }
        catch (JsonException)
        {
            return null;
        }
    }
}
