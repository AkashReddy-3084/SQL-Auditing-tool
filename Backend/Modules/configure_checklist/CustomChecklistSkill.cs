using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using SQLAuditor.Agents;

namespace SQLAuditor.Lib;

/// <summary>
/// Host-agnostic engine behind the Configure Checklist feature. It owns every deterministic step
/// of the pipeline
///
///   Custom Checklist -> Guardrails -> Semantic Match Router -> Area/Sub-area Classification
///   -> Script &amp; Logic Generator -> User Verification -> custom-checklist.json
///   -> custom-deterministic-script-mapping.json -> Merge Final Configuration
///
/// and serves the canonical prompts for the three AI stages. WPF drives those prompts through the
/// configured LLM (<see cref="CustomChecklistAiAgent"/>); the CLI and the MCP server hand them to
/// Copilot, which is the AI layer there. Script generation, validation and persistence reuse the
/// existing <see cref="ChecklistItemProcessor"/> / <see cref="ScriptOutputValidator"/> /
/// <see cref="ScriptGenerationSkill"/> pipeline unchanged.
/// </summary>
public static class CustomChecklistSkill
{
    /// <summary>How many nearest existing items the semantic match router is shown.</summary>
    public const int MatchCandidateCount = 12;

    // Read-only engine: anything that mutates state is out of scope for an audit control, and a
    // request phrased that way is refused before a single provider call is made.
    private static readonly string[] UnsafeMarkers =
    {
        "drop table", "drop database", "delete from", "truncate table", "alter login",
        "update statistics", " xp_cmdshell", "sp_configure", "shutdown", "restore database",
        "backup database", "grant ", "revoke ", "sp_addsrvrolemember", "create login",
        "disable ", "reconfigure", "kill ", "format c:", "rm -rf"
    };

    private static readonly string[] InjectionMarkers =
    {
        "ignore previous", "ignore all previous", "disregard the above", "system prompt",
        "you are now", "act as", "jailbreak", "developer mode", "reveal your instructions"
    };

    // ------------------------------------------------------------------
    // Prompts
    // ------------------------------------------------------------------

    public static string PromptsDirectory => Path.Combine(
        ScriptGenerationSkill.ResolveBasePath(), "Modules", "configure_checklist", "prompts");

    public static string ReadPromptTemplate(string fileName)
    {
        var path = Path.Combine(PromptsDirectory, fileName);
        if (!File.Exists(path))
            throw new FileNotFoundException(
                $"Required prompt template '{fileName}' was not found at '{path}'.", path);

        var text = File.ReadAllText(path);
        if (string.IsNullOrWhiteSpace(text))
            throw new InvalidDataException($"Required prompt template '{fileName}' at '{path}' is empty.");

        return text;
    }

    public static (string System, string User) BuildGuardrailsPrompt(string title, string description) =>
    (
        ReadPromptTemplate("custom_checklist_guardrails_system.txt"),
        ReadPromptTemplate("custom_checklist_guardrails_user.txt")
            .Replace("{title}", title ?? "")
            .Replace("{description}", description ?? "")
    );

    public static (string System, string User) BuildMatchPrompt(
        string title, string description, IReadOnlyList<ChecklistCatalogItem> candidates) =>
    (
        ReadPromptTemplate("custom_checklist_match_system.txt"),
        ReadPromptTemplate("custom_checklist_match_user.txt")
            .Replace("{title}", title ?? "")
            .Replace("{description}", description ?? "")
            .Replace("{candidates}", FormatCandidates(candidates))
    );

    public static (string System, string User) BuildClassificationPrompt(
        string title, string description, IReadOnlyList<ChecklistSubAreaInfo> subAreas) =>
    (
        ReadPromptTemplate("custom_checklist_classify_system.txt"),
        ReadPromptTemplate("custom_checklist_classify_user.txt")
            .Replace("{title}", title ?? "")
            .Replace("{description}", description ?? "")
            .Replace("{sub_areas}", FormatSubAreas(subAreas))
    );

    public static string FormatCandidates(IReadOnlyList<ChecklistCatalogItem> candidates)
    {
        if (candidates.Count == 0) return "(no existing item is textually close to this request)";
        var sb = new StringBuilder();
        foreach (var c in candidates)
            sb.AppendLine($"- {c.Id} [{c.SubAreaId} {c.SubAreaTitle}]{(c.IsCustom ? " (custom)" : "")}: {c.Text}");
        return sb.ToString().TrimEnd();
    }

    public static string FormatSubAreas(IReadOnlyList<ChecklistSubAreaInfo> subAreas)
    {
        var sb = new StringBuilder();
        foreach (var group in subAreas.GroupBy(s => s.AreaId))
        {
            sb.AppendLine($"Area {group.Key}: {group.First().AreaTitle}");
            foreach (var s in group)
                sb.AppendLine($"  - {s.SubAreaId}: {s.SubAreaTitle} ({s.ItemCount} existing item(s))");
        }
        return sb.ToString().TrimEnd();
    }

    // ------------------------------------------------------------------
    // Deterministic pre-screen and shortlist
    // ------------------------------------------------------------------

    /// <summary>
    /// Deterministic guardrail applied before any AI call: refuses empty, trivial, unsafe or
    /// instruction-override requests. The AI guardrail still runs on whatever survives this.
    /// </summary>
    public static GuardrailVerdict PreScreen(string title, string description)
    {
        var t = (title ?? "").Trim();
        var d = (description ?? "").Trim();

        if (t.Length == 0)
            return Reject("A custom checklist title is required.");
        if (d.Length == 0)
            return Reject("A description of the checklist item is required.");
        if (t.Length < 5 || d.Length < 15)
            return Reject("The title and description are too short to describe a verifiable control. "
                        + "State what must be true on the SQL Server estate for this check to pass.");
        if (t.Length > 300)
            return Reject("The title is too long. Keep it under 300 characters.");
        if (d.Length > 4000)
            return Reject("The description is too long. Keep it under 4000 characters.");

        var combined = (t + " " + d).ToLowerInvariant();

        foreach (var marker in InjectionMarkers)
        {
            if (combined.Contains(marker, StringComparison.Ordinal))
                return Reject($"The request contains instruction-override content ('{marker}'). "
                            + "Describe the control to audit, not instructions for the tool.");
        }

        foreach (var marker in UnsafeMarkers)
        {
            if (combined.Contains(marker, StringComparison.Ordinal))
                return Reject($"The request implies a state-changing or unsafe operation ('{marker.Trim()}'). "
                            + "The audit engine is strictly read-only, so only observable controls can be added.");
        }

        return new GuardrailVerdict
        {
            IsAccepted = true,
            Reason = "Passed the deterministic pre-screen.",
            NormalizedTitle = t,
            NormalizedDescription = d
        };

        static GuardrailVerdict Reject(string reason) => new() { IsAccepted = false, Reason = reason };
    }

    /// <summary>
    /// Ranks existing checklist items by token overlap with the request so the semantic match
    /// router reasons over a small, relevant shortlist instead of the whole checklist.
    /// </summary>
    public static List<ChecklistCatalogItem> ShortlistCandidates(
        string title, string description, int max = MatchCandidateCount)
    {
        var catalog = ChecklistConfigurationStore.GetCatalog();
        var wanted = Tokenize(title + " " + description);
        if (wanted.Count == 0) return catalog.Take(max).ToList();

        return catalog
            .Select(item => new { item, score = Similarity(wanted, Tokenize(item.Id + " " + item.Text)) })
            .Where(x => x.score > 0)
            .OrderByDescending(x => x.score)
            .ThenBy(x => x.item.Id, Comparer<string>.Create(ChecklistConfigurationStore.CompareIds))
            .Take(max)
            .Select(x => x.item)
            .ToList();
    }

    private static readonly HashSet<string> StopWords = new(StringComparer.OrdinalIgnoreCase)
    {
        "the","and","for","are","is","of","to","in","on","a","an","with","that","this","it","be",
        "should","must","has","have","not","or","by","as","all","any","each","its","per","must"
    };

    private static HashSet<string> Tokenize(string? text)
    {
        var result = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (Match m in Regex.Matches(text ?? "", @"[A-Za-z][A-Za-z0-9_]{2,}"))
        {
            var token = m.Value;
            if (!StopWords.Contains(token)) result.Add(token);
        }
        return result;
    }

    private static double Similarity(HashSet<string> left, HashSet<string> right)
    {
        if (left.Count == 0 || right.Count == 0) return 0;
        var shared = left.Count(right.Contains);
        return shared == 0 ? 0 : (double)shared / Math.Sqrt(left.Count * (double)right.Count);
    }

    // ------------------------------------------------------------------
    // Reservation, script preparation and finalisation
    // ------------------------------------------------------------------

    /// <summary>
    /// Reserves the next free ID under an existing sub-area. The item is only a draft: it does not
    /// appear in any checklist file until <see cref="ApproveAsync"/> runs.
    /// </summary>
    public static PendingCustomChecklistItem Reserve(
        string subAreaId, string title, string description, string rationale) =>
        ChecklistConfigurationStore.ReserveItem(subAreaId, title, description, rationale);

    public static void Discard(string checklistId) => ChecklistConfigurationStore.DiscardPending(checklistId);

    /// <summary>Maps a reserved draft onto the item shape the existing script generator consumes.</summary>
    public static ScriptGenChecklistItem ToScriptGenItem(PendingCustomChecklistItem pending) => new()
    {
        ChecklistId = pending.Id,
        Category = pending.SubAreaTitle,
        CheckName = pending.Title,
        Scope = "",
        Description = string.IsNullOrWhiteSpace(pending.Description) ? pending.Title : pending.Description,
        ExpectedOutcome = string.IsNullOrWhiteSpace(pending.Description) ? pending.Title : pending.Description
    };

    /// <summary>
    /// Attaches a generated + validated script to the reserved draft so it can be shown to the user
    /// for approval. Nothing is written to the checklist or the mapping at this point.
    /// </summary>
    public static void AttachScriptForApproval(string checklistId, ScriptGenerationResponse response)
    {
        ChecklistConfigurationStore.AttachScript(checklistId, p =>
        {
            p.IsFeasible = response.IsFeasible;
            p.ScriptType = response.ScriptType ?? "";
            p.Scope = response.Scope ?? "";
            p.ScriptContent = response.ScriptContent ?? "";
            p.ScoringLogic = response.ScoringLogic ?? "";
            p.Reason = response.Reason ?? "";
            p.IsAdminCheck = response.IsAdminCheck;
            p.IsDocumentationCheck = response.IsDocumentationCheck;
            p.McpFeasibility = response.McpFeasibility;
        });
    }

    /// <summary>
    /// CLI/MCP entry point for the generation stage: runs the deterministic format gate, then the
    /// template-driven C1-C7 review, exactly as <see cref="ScriptGenerationSkill"/> does, and
    /// stores the accepted script on the draft for the user to approve.
    /// </summary>
    public static string PrepareScript(
        string checklistId,
        string rawResponse,
        string? validationVerdict,
        string reviewInvocationHint,
        string approveInvocationHint)
    {
        var pending = ChecklistConfigurationStore.GetPending(checklistId);
        if (pending == null)
            return $"Error: '{checklistId}' is not a reserved custom checklist draft. "
                 + "Run the classification step first so an ID is assigned.";

        if (string.IsNullOrWhiteSpace(rawResponse))
            return $"Error: no generated response supplied for '{checklistId}'.";

        var response = ChecklistItemProcessor.ParseResponse(rawResponse);
        var item = ToScriptGenItem(pending);

        if (!response.IsFeasible)
        {
            AttachScriptForApproval(checklistId, response);
            var draft = ChecklistConfigurationStore.GetPending(checklistId)!;
            var (technique, why) = DescribeEvaluationPath(draft);
            return $"[{checklistId}] classified NOT FEASIBLE as a script: {response.Reason}\n"
                 + $"Evaluation path: {technique} - {why}.\n"
                 + "No script will be stored. Ask the user to approve or reject the checklist item, then "
                 + approveInvocationHint;
        }

        var validation = new ScriptOutputValidator().Validate(response);
        if (!validation.IsValid)
            return $"VALIDATION FAILED for [{checklistId}]: {validation.Error}\n"
                 + "Correct the script so it satisfies the required output format (Result, Score, "
                 + "DatabaseQueried, Finding) and submit it again (retry up to 3 times).";

        if (string.IsNullOrWhiteSpace(validationVerdict))
            return ScriptGenerationSkill.BuildValidationInstructions(item, response, reviewInvocationHint);

        if (!Regex.IsMatch(validationVerdict, @"VERDICT:\s*(VALID|INVALID)", RegexOptions.IgnoreCase))
            return $"VALIDATION VERDICT NOT RECOGNISED for [{checklistId}]. Nothing was stored.\n"
                 + "Resubmit a verdict that starts with 'VERDICT: VALID' or 'VERDICT: INVALID'.";

        var review = ChecklistItemProcessor.ParseValidationResponse(validationVerdict);
        var correctionNote = string.Empty;

        if (!review.IsValid)
        {
            if (string.IsNullOrWhiteSpace(review.CorrectedScript))
                return $"VALIDATION REJECTED [{checklistId}] (C1-C7): "
                     + $"{(string.IsNullOrWhiteSpace(review.Issues) ? "no issues listed" : review.Issues)}\n"
                     + "Nothing was stored. Supply the complete corrected script between "
                     + "---CORRECTED_SCRIPT_START--- and ---CORRECTED_SCRIPT_END---, or regenerate the item.";

            response.ScriptContent = review.CorrectedScript;

            var revalidation = new ScriptOutputValidator().Validate(response);
            if (!revalidation.IsValid)
                return $"CORRECTED SCRIPT STILL INVALID for [{checklistId}]: {revalidation.Error}\n"
                     + $"Review issues were: {review.Issues}\nNothing was stored.";

            correctionNote = " The corrected script from the C1-C7 review was applied.";
        }

        AttachScriptForApproval(checklistId, response);
        var reviewed = ChecklistConfigurationStore.GetPending(checklistId)!;
        var (readyTechnique, readyWhy) = DescribeEvaluationPath(reviewed);

        return $"=== SCRIPT READY FOR USER APPROVAL - [{checklistId}] (NOT SAVED YET) ==="
             + $"\nSub-area: {pending.SubAreaId} {pending.SubAreaTitle}"
             + $"\nTitle: {pending.Title}"
             + $"\nScript type: {response.ScriptType} | Scope: {response.Scope}"
             + $"\nEvaluation path: {readyTechnique} - {readyWhy}"
             + $"\nScoring logic: {response.ScoringLogic}{correctionNote}"
             + "\n\n----- GENERATED SCRIPT -----\n"
             + response.ScriptContent
             + "\n----- END GENERATED SCRIPT -----\n\n"
             + "Show this script to the user and ask whether to add the checklist item. "
             + "Nothing is written to custom-checklist.json until they approve.\n"
             + approveInvocationHint;
    }

    /// <summary>
    /// Finalises an approved draft: writes the script file, adds the item to custom-checklist.json,
    /// adds its metadata to custom-deterministic-script-mapping.json and regenerates the merged
    /// master-checklist.json and deterministic-script-mapping.json.
    /// </summary>
    public static async Task<CustomChecklistOutcome> ApproveAsync(
        string checklistId, CancellationToken cancellationToken = default)
    {
        var pending = ChecklistConfigurationStore.GetPending(checklistId)
            ?? throw new InvalidOperationException($"No pending custom checklist item with ID '{checklistId}'.");

        if (!pending.HasScript)
            throw new InvalidOperationException(
                $"Custom checklist item '{checklistId}' has no generated script yet. Run the generation step first.");

        var basePath = ScriptGenerationSkill.ResolveBasePath();
        var resultsDir = Path.Combine(basePath, "results");
        Directory.CreateDirectory(resultsDir);

        string? relativeScriptFile = null;
        if (pending.IsFeasible && !string.IsNullOrWhiteSpace(pending.ScriptContent))
        {
            var scriptType = string.IsNullOrWhiteSpace(pending.ScriptType) ? "sql" : pending.ScriptType;
            var outputDir = Path.Combine(basePath, "checklists", "Scripts", scriptType == "sql" ? "sql" : "ps1");
            Directory.CreateDirectory(outputDir);

            var safeId = Regex.Replace(pending.Id, @"[^a-zA-Z0-9_.-]+", "_").Trim('_');
            if (safeId.Length == 0) safeId = "custom";
            var fileName = $"{safeId}.{scriptType}";

            await File.WriteAllTextAsync(
                Path.Combine(outputDir, fileName), pending.ScriptContent, cancellationToken);

            relativeScriptFile = $"Backend/checklists/Scripts/{(scriptType == "sql" ? "sql" : "ps1")}/{fileName}";
        }

        var published = ChecklistConfigurationStore.ApprovePending(checklistId, relativeScriptFile);
        var (technique, why) = DescribeEvaluationPath(pending);

        await ScriptGenerationSkill.UpsertExecutionResultAsync(resultsDir, new ExecutionResultEntry
        {
            ChecklistId = published.Id,
            CheckName = published.Title,
            Category = published.SubAreaTitle,
            Scope = published.Scope,
            Status = relativeScriptFile == null ? "Not Feasible" : "Script Generated",
            ScriptType = relativeScriptFile == null ? "" : published.ScriptType,
            ScriptPath = relativeScriptFile == null
                ? ""
                : $"{published.ScriptType}/{Path.GetFileName(relativeScriptFile)}",
            ScoringLogic = published.ScoringLogic,
            Reason = relativeScriptFile == null ? published.Reason : ""
        });

        return new CustomChecklistOutcome
        {
            Title = published.Title,
            Description = published.Description,
            Status = "Added",
            AssignedId = published.Id,
            SubAreaId = published.SubAreaId,
            SubAreaTitle = published.SubAreaTitle,
            Detail = relativeScriptFile == null
                ? $"Added without a script. Evaluation path: {technique} - {why}."
                : $"Added with script {relativeScriptFile} (scope {published.Scope}). Evaluation path: {technique} - {why}."
        };
    }

    /// <summary>Human-readable snapshot of the merged configuration, used to close every host flow.</summary>
    public static string DescribeMergedConfiguration()
    {
        ChecklistConfigurationStore.RebuildMerged();
        var catalog = ChecklistConfigurationStore.GetCatalog();
        var custom = catalog.Count(i => i.IsCustom);
        return $"Final configuration merged: {ChecklistConfigurationStore.MergedChecklistFileName} now holds "
             + $"{catalog.Count} checklist item(s) ({catalog.Count - custom} default + {custom} custom), and "
             + $"{ChecklistConfigurationStore.MergedMappingFileName} was regenerated from "
             + $"{ChecklistConfigurationStore.DefaultMappingFileName} + {ChecklistConfigurationStore.CustomMappingFileName}.";
    }

    /// <summary>Mapping entry shape shared with the default mapping, used only for reporting/tests.</summary>
    public static JsonObject BuildMappingEntry(PendingCustomChecklistItem pending, string? scriptFile) => new()
    {
        ["script_file"] = string.IsNullOrWhiteSpace(scriptFile) ? null : scriptFile,
        ["scope"] = string.IsNullOrWhiteSpace(pending.Scope) ? null : pending.Scope,
        ["IsAdminCheck"] = pending.IsAdminCheck,
        ["IsDocumentationCheck"] = pending.IsDocumentationCheck,
        ["MCP_Feasibility"] = pending.McpFeasibility
    };

    /// <summary>
    /// Resolves the single evaluation technique this item will actually run under, applying the
    /// same rules the engine uses in <c>Auditor</c>: documentation and admin checks always go to
    /// AI-Manual, a script that survives those gates is executed by the Script pipeline, and an
    /// unscripted item goes to AI-MCP only when it was classified as MCP-feasible.
    /// </summary>
    public static (string Technique, string Reason) DescribeEvaluationPath(PendingCustomChecklistItem pending)
    {
        var hasScript = pending.IsFeasible && !string.IsNullOrWhiteSpace(pending.ScriptContent);

        if (pending.IsDocumentationCheck)
            return ("AI-Manual", hasScript
                ? "documentation check - the evidence lives outside SQL Server, so a reviewer confirms it and the generated script is offered as guidance"
                : "documentation check - the evidence lives outside SQL Server, so a reviewer must confirm it");

        if (pending.IsAdminCheck)
            return ("AI-Manual", hasScript
                ? "admin check - the reviewer runs the generated script themselves and records the outcome"
                : "admin check - a reviewer must inspect the instance and record the outcome");

        if (hasScript)
        {
            var scope = string.IsNullOrWhiteSpace(pending.Scope) ? "SERVER" : pending.Scope.ToUpperInvariant();
            return ("Script", scope == "DATABASE"
                ? "the generated script is executed by the engine once per selected database"
                : "the generated script is executed by the engine on the server connection");
        }

        if (pending.McpFeasibility)
            return ("AI-MCP", "decided by the model from the per-run SQL snapshot; it falls back to AI-Manual only if the model cannot decide");

        return ("AI-Manual", "no script is feasible and the item cannot be decided from the SQL snapshot, so a reviewer records the outcome");
    }
}
