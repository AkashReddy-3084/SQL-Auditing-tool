using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using SQLAuditor.Agents;

namespace SQLAuditor.Lib;

/// <summary>How a host tells the AI to call the next step of the flow.</summary>
public sealed class CustomChecklistInvocationHints
{
    public string Classify { get; set; } = "";
    public string Generate { get; set; } = "";
    public string Review { get; set; } = "";
    public string Approve { get; set; } = "";
    public string Reject { get; set; } = "";
}

/// <summary>
/// The Configure Checklist flow for hosts where the AI is the calling agent (Copilot CLI and the
/// VS Code MCP server) rather than a configured model endpoint. Each step returns the canonical
/// prompt or a decision receipt; the host never calls an LLM itself. The stages, prompts,
/// validators, ID allocation and persistence are exactly the ones the WPF pipeline uses.
/// </summary>
public static class CustomChecklistHostFlow
{
    /// <summary>Step 1 — guardrails, semantic match shortlist and the Area/Sub-area catalog.</summary>
    public static string Begin(string? title, string? description, CustomChecklistInvocationHints hints)
    {
        if (string.IsNullOrWhiteSpace(title) || string.IsNullOrWhiteSpace(description))
            return "STEP 1 of 6 — CUSTOM CHECKLIST TITLE AND DESCRIPTION REQUIRED.\n"
                 + "Ask the user for:\n"
                 + "  1) Custom Checklist Title — a short name for the check.\n"
                 + "  2) Describe the Checklist Item — what must be true for this check to pass.\n"
                 + "Do NOT ask for an Area, a Sub-area or a checklist ID: both are derived automatically.\n"
                 + "Then call this flow again with title and description set.";

        ChecklistConfigurationStore.EnsureInitialized();

        var preScreen = CustomChecklistSkill.PreScreen(title, description);
        if (!preScreen.IsAccepted)
            return $"GUARDRAIL REJECTION — the request was refused before any review.\n"
                 + $"Title: {title}\nReason: {preScreen.Reason}\n"
                 + "Nothing was added to the custom configuration. Tell the user why, and offer to rephrase the item.";

        var candidates = CustomChecklistSkill.ShortlistCandidates(preScreen.NormalizedTitle, preScreen.NormalizedDescription);
        var subAreas = ChecklistConfigurationStore.GetSubAreas();

        var (guardSystem, guardUser) = CustomChecklistSkill.BuildGuardrailsPrompt(
            preScreen.NormalizedTitle, preScreen.NormalizedDescription);
        var (matchSystem, matchUser) = CustomChecklistSkill.BuildMatchPrompt(
            preScreen.NormalizedTitle, preScreen.NormalizedDescription, candidates);
        var (classSystem, classUser) = CustomChecklistSkill.BuildClassificationPrompt(
            preScreen.NormalizedTitle, preScreen.NormalizedDescription, subAreas);

        var sb = new StringBuilder();
        sb.AppendLine("=== CONFIGURE CHECKLIST — STEPS 2-4 (GUARDRAILS, SEMANTIC MATCH, CLASSIFICATION) ===");
        sb.AppendLine("This is checklist CONFIGURATION, not evaluation. Do NOT connect to a SQL Server and do NOT");
        sb.AppendLine("ask for credentials. YOU are the AI layer for the three reviews below. Perform them IN ORDER,");
        sb.AppendLine("using ONLY the prompts supplied here, then report the outcome of each one to the user.");
        sb.AppendLine();
        sb.AppendLine($"Title: {preScreen.NormalizedTitle}");
        sb.AppendLine($"Description: {preScreen.NormalizedDescription}");
        sb.AppendLine("The deterministic pre-screen already passed (safe, non-empty, no instruction override).");
        sb.AppendLine();

        sb.AppendLine("===== A. GUARDRAILS SYSTEM PROMPT =====");
        sb.AppendLine(guardSystem);
        sb.AppendLine("===== GUARDRAILS REQUEST =====");
        sb.AppendLine(guardUser);
        sb.AppendLine();

        sb.AppendLine("===== B. SEMANTIC MATCH ROUTER SYSTEM PROMPT =====");
        sb.AppendLine(matchSystem);
        sb.AppendLine("===== SEMANTIC MATCH REQUEST =====");
        sb.AppendLine(matchUser);
        sb.AppendLine();

        sb.AppendLine("===== C. AREA/SUB-AREA CLASSIFICATION SYSTEM PROMPT =====");
        sb.AppendLine(classSystem);
        sb.AppendLine("===== CLASSIFICATION REQUEST =====");
        sb.AppendLine(classUser);
        sb.AppendLine();

        sb.AppendLine("## What to do with the three verdicts");
        sb.AppendLine("- Guardrails REJECT  -> stop. Tell the user the reason. Nothing is added.");
        sb.AppendLine("- Semantic match DUPLICATE -> stop. Show the user the matched checklist ID and its text.");
        sb.AppendLine("  Do not create a duplicate custom item.");
        sb.AppendLine("- Otherwise -> report the chosen Sub-area to the user and continue:");
        sb.AppendLine($"  {hints.Classify}");
        sb.AppendLine("  That call assigns the next free checklist ID inside the chosen Sub-area and returns the");
        sb.AppendLine("  script generation prompt. New Areas/Sub-areas cannot be created.");

        return sb.ToString();
    }

    /// <summary>Step 4/5 — records the three verdicts, reserves the ID and serves the generation prompt.</summary>
    public static string Classify(
        string? title,
        string? description,
        string? guardrail,
        string? guardrailReason,
        string? matchedId,
        string? matchReason,
        string? subAreaId,
        string? rationale,
        CustomChecklistInvocationHints hints)
    {
        if (string.IsNullOrWhiteSpace(title) || string.IsNullOrWhiteSpace(description))
            return "Error: 'title' and 'description' are required and must be the same values the reviews ran on.";

        ChecklistConfigurationStore.EnsureInitialized();

        var guard = (guardrail ?? "").Trim().ToLowerInvariant();
        if (guard is "reject" or "rejected" or "false" or "no")
            return "GUARDRAIL REJECTION recorded.\n"
                 + $"Title: {title}\nReason: {(string.IsNullOrWhiteSpace(guardrailReason) ? "(no reason supplied)" : guardrailReason)}\n"
                 + "Nothing was added to custom-checklist.json or custom-deterministic-script-mapping.json.";

        if (guard is not ("accept" or "accepted" or "true" or "yes" or "pass"))
            return "Error: 'guardrail' must be 'accept' or 'reject', taken from the guardrails review in step A.";

        var preScreen = CustomChecklistSkill.PreScreen(title, description);
        if (!preScreen.IsAccepted)
            return $"GUARDRAIL REJECTION — {preScreen.Reason}\nNothing was added.";

        if (!string.IsNullOrWhiteSpace(matchedId) &&
            !string.Equals(matchedId.Trim(), "none", StringComparison.OrdinalIgnoreCase))
        {
            var id = matchedId.Trim();
            var existing = ChecklistConfigurationStore.GetCatalog()
                .FirstOrDefault(i => string.Equals(i.Id, id, StringComparison.OrdinalIgnoreCase));
            if (existing == null)
                return $"Error: the semantic match router named '{id}', which is not an existing checklist ID. "
                     + "Re-run the match review and pass either a real ID or 'none'.";

            return "DUPLICATE — this custom checklist item is already covered.\n"
                 + $"Matched checklist item: {existing.Id} [{existing.SubAreaId} {existing.SubAreaTitle}]\n"
                 + $"  {existing.Text}\n"
                 + $"Reason: {(string.IsNullOrWhiteSpace(matchReason) ? "(no reason supplied)" : matchReason)}\n"
                 + "No custom checklist item was created. Show the matched item to the user.";
        }

        if (string.IsNullOrWhiteSpace(subAreaId))
            return "Error: 'subArea' is required. It must be an existing Sub-area ID chosen by the classification "
                 + "review in step C (for example '1.1'). New Areas/Sub-areas are not supported.";

        var subAreas = ChecklistConfigurationStore.GetSubAreas();
        var target = subAreas.FirstOrDefault(s =>
            string.Equals(s.SubAreaId, subAreaId.Trim(), StringComparison.OrdinalIgnoreCase));
        if (target == null)
            return $"Error: '{subAreaId}' is not an existing Sub-area. Valid Sub-areas:\n"
                 + CustomChecklistSkill.FormatSubAreas(subAreas);

        var pending = CustomChecklistSkill.Reserve(
            target.SubAreaId, preScreen.NormalizedTitle, preScreen.NormalizedDescription, rationale ?? "");

        var item = CustomChecklistSkill.ToScriptGenItem(pending);
        var generation = ScriptGenerationSkill.BuildGenerationInstructions(
            new[] { item }, Array.Empty<string>(), hints.Generate);

        var sb = new StringBuilder();
        sb.AppendLine("=== STEP 5 of 6 — SCRIPT GENERATION ===");
        sb.AppendLine($"Guardrails: ACCEPTED. Semantic match: UNIQUE (no existing item covers it).");
        sb.AppendLine($"Area: {pending.AreaId} — {pending.AreaTitle}");
        sb.AppendLine($"Sub-area: {pending.SubAreaId} — {pending.SubAreaTitle}");
        sb.AppendLine($"Assigned checklist ID: {pending.Id}");
        if (!string.IsNullOrWhiteSpace(rationale)) sb.AppendLine($"Classification rationale: {rationale}");
        sb.AppendLine();
        sb.AppendLine("The ID is RESERVED only. The item is NOT in custom-checklist.json yet and will not be");
        sb.AppendLine("added until the user approves the generated script.");
        sb.AppendLine($"If the user abandons this item, release the ID: {hints.Reject}");
        sb.AppendLine();
        sb.Append(generation);

        return sb.ToString();
    }

    /// <summary>Step 5 — format gate, C1-C7 review, then hold the script for user approval.</summary>
    public static string Generate(
        string? checklistId, string? response, string? validationVerdict, CustomChecklistInvocationHints hints)
    {
        if (string.IsNullOrWhiteSpace(checklistId))
            return "Error: 'id' is required (the reserved custom checklist ID from the classification step).";

        return CustomChecklistSkill.PrepareScript(
            checklistId, response ?? "", validationVerdict, hints.Review, hints.Approve);
    }

    /// <summary>Step 6 — the user approved: persist the item, its mapping, and merge.</summary>
    public static async Task<string> ApproveAsync(string? checklistId, CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(checklistId))
            return "Error: 'id' is required.";

        var pending = ChecklistConfigurationStore.GetPending(checklistId);
        if (pending == null)
            return $"Error: '{checklistId}' is not a reserved custom checklist draft. "
                 + "It may already have been approved or rejected.";
        if (!pending.HasScript)
            return $"Error: '{checklistId}' has no generated script yet. Run the generation step first.";

        var outcome = await CustomChecklistSkill.ApproveAsync(checklistId, cancellationToken);

        return $"=== STEP 6 of 6 — CONFIGURATION UPDATED ===\n"
             + $"Added {outcome.AssignedId} under Sub-area {outcome.SubAreaId} ({outcome.SubAreaTitle}).\n"
             + $"  {ChecklistConfigurationStore.CustomChecklistFileName}: item added.\n"
             + $"  {ChecklistConfigurationStore.CustomMappingFileName}: script metadata added.\n"
             + $"  {outcome.Detail}\n"
             + CustomChecklistSkill.DescribeMergedConfiguration() + "\n"
             + "The item is now selectable in the normal evaluation flow alongside the default checklist.";
    }

    /// <summary>The user rejected the item: release the reserved ID and write nothing.</summary>
    public static string Reject(string? checklistId)
    {
        if (string.IsNullOrWhiteSpace(checklistId))
            return "Error: 'id' is required.";

        var pending = ChecklistConfigurationStore.GetPending(checklistId);
        if (pending == null)
            return $"Nothing to reject: '{checklistId}' is not a reserved custom checklist draft.";

        CustomChecklistSkill.Discard(checklistId);
        return $"Rejected {checklistId} ('{pending.Title}'). The reserved ID was released and nothing was written to "
             + $"{ChecklistConfigurationStore.CustomChecklistFileName} or {ChecklistConfigurationStore.CustomMappingFileName}.";
    }

    /// <summary>Shows the drafts that are reserved but not yet approved.</summary>
    public static string ListPending()
    {
        ChecklistConfigurationStore.EnsureInitialized();
        var pending = ChecklistConfigurationStore.GetAllPending();
        if (pending.Count == 0) return "No custom checklist drafts are awaiting approval.";

        var sb = new StringBuilder();
        sb.AppendLine($"{pending.Count} custom checklist draft(s) awaiting approval:");
        foreach (var p in pending)
            sb.AppendLine($"  {p.Id} [{p.SubAreaId} {p.SubAreaTitle}] {p.Title} "
                        + $"({(p.HasScript ? "script ready for review" : "no script generated yet")})");
        return sb.ToString();
    }

    /// <summary>Lists every Area/Sub-area a custom item may be filed under.</summary>
    public static string ListSubAreas()
    {
        ChecklistConfigurationStore.EnsureInitialized();
        return "Existing Areas and Sub-areas (the only valid homes for a custom checklist item):\n"
             + CustomChecklistSkill.FormatSubAreas(ChecklistConfigurationStore.GetSubAreas());
    }
}
