using System;
using System.Collections.Generic;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace SQLAuditor.Lib;

/// <summary>
/// Rewrites a reviewer-decided manual checklist result into audit-report wording
/// (Finding, Evidence, RiskImpact, Recommendation, Severity) using the reviewer's own
/// Input/Evidence text as the only factual source.
///
/// The evaluation itself (Outcome and Score) is decided by the reviewer and is never
/// changed here. When the provider is unreachable the caller falls back to the
/// deterministic wording produced by <see cref="ChecklistResultEnricher"/>.
/// </summary>
internal sealed class ManualResultAiEnricher
{
    // Keeps the prompt bounded when the generated steps or the reviewer's notes are long.
    private const int MaxManualStepsChars = 6000;
    private const int MaxReviewerInputChars = 4000;

    private readonly ProviderChatClient _client;

    // A single provider outage should not make every remaining item pay the timeout.
    private bool _providerUnavailable;

    private ManualResultAiEnricher(ProviderChatClient client) => _client = client;

    public static ManualResultAiEnricher CreateFromEnvironment() =>
        new(ProviderChatClient.CreateFromEnvironment());

    public sealed record ManualEnrichment(
        string? Finding,
        string? Evidence,
        string? RiskImpact,
        string? Recommendation,
        string? Severity);

    public async Task<ManualEnrichment?> EnrichAsync(
        ChecklistItem item,
        string outcome,
        int? score,
        string manualSteps,
        string reviewerInput,
        CancellationToken cancellationToken = default)
    {
        if (_providerUnavailable) return null;

        // With no reviewer text there is nothing to reason over, and asking anyway would
        // only produce invented or generic wording.
        if (string.IsNullOrWhiteSpace(reviewerInput)) return null;

        var prompt = PromptTemplateStore.Render(
            "manual_enrichment_user.txt",
            new Dictionary<string, string>
            {
                ["CHECKLIST_ITEM_ID"] = item.Id,
                ["CHECKLIST_ITEM_DESCRIPTION"] = item.Description,
                ["CHECKLIST_ITEM_VERIFICATION"] = item.Verification ?? string.Empty,
                ["OUTCOME"] = outcome,
                ["SCORE"] = score?.ToString() ?? "unknown",
                ["MANUAL_STEPS"] = Clip(manualSteps, MaxManualStepsChars, "no manual steps were recorded"),
                ["REVIEWER_INPUT"] = Clip(reviewerInput, MaxReviewerInputChars, string.Empty),
            });

        string content;
        try
        {
            content = await _client.CompleteAsync(
                PromptTemplateStore.Load("manual_enrichment_system.txt"),
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
                ? "manual enrichment failed (permanent — disabled for run): "
                : "manual enrichment failed (transient — this item skipped): ") + ex.Message);

            if (permanent) _providerUnavailable = true;
            return null;
        }

        var parsed = Parse(content);
        if (parsed == null)
        {
            ProviderChatClient.WriteDiagnostic(item.Id,
                "manual enrichment response did not parse into enrichment JSON. Raw content: "
                + ProviderChatClient.Truncate(content, 1000));
        }

        return parsed;
    }

    private static string Clip(string? value, int max, string fallback)
    {
        if (string.IsNullOrWhiteSpace(value)) return fallback;
        var trimmed = value.Trim();
        return trimmed.Length <= max ? trimmed : trimmed[..max] + "…(truncated)";
    }

    private static ManualEnrichment? Parse(string raw)
    {
        var cleaned = ProviderChatClient.ExtractJsonObject(raw);
        if (cleaned == null) return null;

        try
        {
            using var doc = JsonDocument.Parse(cleaned);
            var root = doc.RootElement;
            var enrichment = new ManualEnrichment(
                ProviderChatClient.ReadString(root, "finding"),
                ProviderChatClient.ReadString(root, "evidence"),
                ProviderChatClient.ReadString(root, "riskImpact"),
                ProviderChatClient.ReadString(root, "recommendation"),
                ProviderChatClient.ReadString(root, "severity"));

            var hasContent = enrichment.Finding != null || enrichment.Evidence != null
                || enrichment.RiskImpact != null || enrichment.Recommendation != null;
            return hasContent ? enrichment : null;
        }
        catch (JsonException)
        {
            return null;
        }
    }
}
