using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace SQLAuditor.Lib;

/// <summary>
/// The AI layer of the Configure Checklist flow for hosts that own a model endpoint (the WPF app).
/// It runs the guardrails, semantic match router and Area/Sub-area classification stages against
/// the configured provider using the canonical templates served by <see cref="CustomChecklistSkill"/>.
/// The CLI and the MCP server do not use this class: Copilot is the AI there, and it follows the
/// very same templates.
/// </summary>
public sealed class CustomChecklistAiAgent
{
    private readonly ProviderChatClient _client;

    public CustomChecklistAiAgent()
    {
        _client = ProviderChatClient.CreateFromEnvironment();
    }

    /// <summary>Guardrails: deterministic pre-screen first, then the model review.</summary>
    public async Task<GuardrailVerdict> RunGuardrailsAsync(
        string title, string description, CancellationToken cancellationToken = default)
    {
        var preScreen = CustomChecklistSkill.PreScreen(title, description);
        if (!preScreen.IsAccepted) return preScreen;

        var (system, user) = CustomChecklistSkill.BuildGuardrailsPrompt(
            preScreen.NormalizedTitle, preScreen.NormalizedDescription);

        var raw = await _client.CompleteAsync(system, user, cancellationToken);
        var json = ProviderChatClient.ExtractJsonObject(raw);
        if (json == null)
        {
            // An unreadable reply must not silently approve an item.
            return new GuardrailVerdict
            {
                IsAccepted = false,
                Reason = "The guardrails review could not be read from the model response. "
                       + "Retry, or rephrase the checklist item."
            };
        }

        using var doc = JsonDocument.Parse(json);
        var root = doc.RootElement;

        var accepted = ReadBool(root, "accepted");
        return new GuardrailVerdict
        {
            IsAccepted = accepted,
            Reason = ReadString(root, "reason", accepted ? "Accepted." : "Rejected by the guardrails review."),
            NormalizedTitle = Fallback(ReadString(root, "normalized_title", ""), preScreen.NormalizedTitle),
            NormalizedDescription = Fallback(ReadString(root, "normalized_description", ""), preScreen.NormalizedDescription)
        };
    }

    /// <summary>Semantic match router over the deterministic shortlist of nearest existing items.</summary>
    public async Task<SemanticMatchVerdict> RunSemanticMatchAsync(
        string title, string description, CancellationToken cancellationToken = default)
    {
        var candidates = CustomChecklistSkill.ShortlistCandidates(title, description);
        if (candidates.Count == 0)
            return new SemanticMatchVerdict { IsDuplicate = false, Reason = "No existing item is close to this request." };

        var (system, user) = CustomChecklistSkill.BuildMatchPrompt(title, description, candidates);
        var raw = await _client.CompleteAsync(system, user, cancellationToken);
        var json = ProviderChatClient.ExtractJsonObject(raw);
        if (json == null)
            return new SemanticMatchVerdict { IsDuplicate = false, Reason = "The duplicate review returned no readable verdict; treated as unique." };

        using var doc = JsonDocument.Parse(json);
        var root = doc.RootElement;

        var duplicate = ReadBool(root, "duplicate");
        var matchedId = ReadString(root, "matched_id", "").Trim();

        // A duplicate verdict is only honoured when it names a real candidate.
        var matched = candidates.FirstOrDefault(c =>
            string.Equals(c.Id, matchedId, StringComparison.OrdinalIgnoreCase));
        if (duplicate && matched == null)
        {
            return new SemanticMatchVerdict
            {
                IsDuplicate = false,
                Reason = "The duplicate review named an unknown checklist ID, so the item is treated as unique."
            };
        }

        return new SemanticMatchVerdict
        {
            IsDuplicate = duplicate,
            MatchedId = matched?.Id ?? "",
            MatchedText = matched?.Text ?? "",
            Reason = ReadString(root, "reason", duplicate ? "Already covered." : "Not covered by an existing item.")
        };
    }

    /// <summary>Chooses one EXISTING sub-area for the item. New areas/sub-areas are never created.</summary>
    public async Task<AreaClassificationVerdict> ClassifyAsync(
        string title, string description, CancellationToken cancellationToken = default)
    {
        var subAreas = ChecklistConfigurationStore.GetSubAreas();
        var (system, user) = CustomChecklistSkill.BuildClassificationPrompt(title, description, subAreas);

        var raw = await _client.CompleteAsync(system, user, cancellationToken);
        var json = ProviderChatClient.ExtractJsonObject(raw);
        if (json == null)
            return new AreaClassificationVerdict { IsClassified = false, Rationale = "The classifier returned no readable verdict." };

        using var doc = JsonDocument.Parse(json);
        var root = doc.RootElement;

        var subAreaId = ReadString(root, "sub_area_id", "").Trim();
        var match = subAreas.FirstOrDefault(s =>
            string.Equals(s.SubAreaId, subAreaId, StringComparison.OrdinalIgnoreCase));

        if (!ReadBool(root, "classified") || match == null)
        {
            return new AreaClassificationVerdict
            {
                IsClassified = false,
                Rationale = match == null && subAreaId.Length > 0
                    ? $"The classifier chose '{subAreaId}', which is not an existing Sub-area."
                    : ReadString(root, "rationale", "No existing Sub-area fits this item.")
            };
        }

        return new AreaClassificationVerdict
        {
            IsClassified = true,
            AreaId = match.AreaId,
            SubAreaId = match.SubAreaId,
            Rationale = ReadString(root, "rationale", $"Filed under {match.SubAreaId} {match.SubAreaTitle}.")
        };
    }

    private static bool ReadBool(JsonElement root, string name) =>
        root.TryGetProperty(name, out var el) &&
        (el.ValueKind == JsonValueKind.True ||
         (el.ValueKind == JsonValueKind.String && bool.TryParse(el.GetString(), out var b) && b));

    private static string ReadString(JsonElement root, string name, string fallback) =>
        root.TryGetProperty(name, out var el) && el.ValueKind == JsonValueKind.String
            ? el.GetString() ?? fallback
            : fallback;

    private static string Fallback(string value, string fallback) =>
        string.IsNullOrWhiteSpace(value) ? fallback : value;
}
