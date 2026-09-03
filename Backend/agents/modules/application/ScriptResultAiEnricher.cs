using System;
using System.Collections.Generic;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace SQLAuditor.Lib;

/// <summary>
/// Rewrites a Script-evaluated checklist result into audit-report wording (Finding,
/// Evidence, RiskImpact, Recommendation, Severity) using the structured values the
/// SQL script returned as the only factual source.
///
/// The evaluation itself (Outcome, Score, Databases Verified) is never changed here.
/// When the provider is unreachable the caller keeps the script-supplied finding and
/// leaves the AI-authored fields null rather than emitting generic filler.
/// </summary>
internal sealed class ScriptResultAiEnricher
{
    private readonly ProviderChatClient _client;

    // A single provider outage should not make every remaining item pay the timeout.
    private bool _providerUnavailable;

    private ScriptResultAiEnricher(ProviderChatClient client) => _client = client;

    public static ScriptResultAiEnricher CreateFromEnvironment() =>
        new(ProviderChatClient.CreateFromEnvironment());

    public sealed record ScriptEnrichment(
        string? Finding,
        string? Evidence,
        string? RiskImpact,
        string? Recommendation,
        string? Severity);

    public async Task<ScriptEnrichment?> EnrichAsync(
        ChecklistItem item,
        string outcome,
        int? score,
        SqlScriptOutcome scriptOutcome,
        CancellationToken cancellationToken = default)
    {
        if (_providerUnavailable) return null;

        var prompt = PromptTemplateStore.Render(
            "script_enrichment_user.txt",
            new Dictionary<string, string>
            {
                ["CHECKLIST_ITEM_ID"] = item.Id,
                ["CHECKLIST_ITEM_DESCRIPTION"] = item.Description,
                ["CHECKLIST_ITEM_VERIFICATION"] = item.Verification ?? string.Empty,
                ["OUTCOME"] = outcome,
                ["SCORE"] = score?.ToString() ?? "unknown",
                ["DATABASES_VERIFIED"] = scriptOutcome.DatabasesVerified ?? "not reported by the script",
                ["SCRIPT_FINDING"] = scriptOutcome.Finding ?? "not reported by the script",
                ["SCRIPT_RESULT"] = scriptOutcome.ToFactSheet(),
            });

        string content;
        try
        {
            content = await _client.CompleteAsync(
                PromptTemplateStore.Load("script_enrichment_system.txt"),
                prompt,
                cancellationToken);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch (Exception ex)
        {
            // Only a permanent fault (bad key, missing model) should disable enrichment for
            // the whole run. A transient timeout — e.g. Cloudflare 524 when one item's
            // generation runs long — must skip just this item so the next one still tries,
            // instead of nulling every remaining result.
            var permanent = ProviderChatClient.IsPermanentFault(ex);

            ProviderChatClient.WriteDiagnostic(item.Id, (permanent
                ? "provider call failed (permanent — enrichment disabled for run): "
                : "provider call failed (transient — this item skipped, next item still attempted): ") + ex.Message);

            if (permanent) _providerUnavailable = true;
            return null;
        }

        var parsed = Parse(content);
        if (parsed == null)
        {
            // The call succeeded but the model's reply was not the expected JSON object.
            ProviderChatClient.WriteDiagnostic(item.Id, "response did not parse into enrichment JSON. Raw content: " + ProviderChatClient.Truncate(content, 1000));
        }

        return parsed;
    }

    private static ScriptEnrichment? Parse(string raw)
    {
        var cleaned = ProviderChatClient.ExtractJsonObject(raw);
        if (cleaned == null) return null;

        try
        {
            using var doc = JsonDocument.Parse(cleaned);
            var root = doc.RootElement;
            var enrichment = new ScriptEnrichment(
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
