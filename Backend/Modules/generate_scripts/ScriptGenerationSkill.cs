using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using SQLAuditor.Agents;

namespace SQLAuditor.Lib;

/// <summary>
/// Shared script-generation helpers for every host. This class makes NO LLM/API calls: it only
/// reads the four canonical prompt templates in Backend/Modules/generate_scripts/prompts
/// (script_generator_system.txt, script_generator_user.txt, script_validation_system.txt,
/// script_validation_user.txt), fills them for a checklist item and resolves the on-disk layout.
/// The Configure Checklist flow drives these helpers for each NEW custom checklist item —
/// <see cref="CustomChecklistPipeline"/> in the WPF app and <see cref="CustomChecklistHostFlow"/>
/// in the IDE/CLI hosts. Existing/default checklist items are never regenerated.
/// </summary>
public static class ScriptGenerationSkill
{
    /// <summary>
    /// Locates the Backend base path by walking up from the current directory to the folder
    /// containing the checklist.
    /// </summary>
    public static string ResolveBasePath()
    {
        foreach (var start in new[] { Directory.GetCurrentDirectory(), AppContext.BaseDirectory })
        {
            var dir = new DirectoryInfo(start);
            while (dir != null)
            {
                foreach (var name in new[] { "master-checklist.json", "master_checklist.json" })
                {
                    var candidate = Path.Combine(dir.FullName, "Backend", "checklists", name);
                    if (File.Exists(candidate))
                        return Path.Combine(dir.FullName, "Backend");
                }
                dir = dir.Parent;
            }
        }

        throw new DirectoryNotFoundException(
            "Cannot locate the repository root (Backend/checklists/master-checklist.json not found). "
            + "Run from the SQL-Auditing-tool folder.");
    }

    /// <summary>
    /// Folder holding the four canonical prompt templates this flow must run on:
    /// script_generator_system.txt, script_generator_user.txt, script_validation_system.txt
    /// and script_validation_user.txt.
    /// </summary>
    public static string ResolvePromptsDir() =>
        Path.Combine(ResolveBasePath(), "Modules", "generate_scripts", "prompts");

    // Missing template is a hard failure: silently falling back would let the host answer from
    // its own reasoning instead of the standard schema and validation rules.
    private static string ReadPromptTemplate(string fileName)
    {
        var path = Path.Combine(ResolvePromptsDir(), fileName);
        if (!File.Exists(path))
            throw new FileNotFoundException(
                $"Required prompt template '{fileName}' was not found at '{path}'. "
                + "Script generation and validation must run on the standard templates.",
                path);

        var text = File.ReadAllText(path);
        if (string.IsNullOrWhiteSpace(text))
            throw new InvalidDataException(
                $"Required prompt template '{fileName}' at '{path}' is empty.");

        return text;
    }

    /// <summary>
    /// Resolves the requested checklist IDs into <see cref="ScriptGenChecklistItem"/>s using the
    /// same checklist structure the rest of the tool uses. Returns the matched items plus any IDs
    /// that could not be found.
    /// </summary>
    public static async Task<(List<ScriptGenChecklistItem> Items, List<string> Unknown)> LoadItemsAsync(
        IEnumerable<string> ids)
    {
        var wanted = ids
            .Select(s => s?.Trim() ?? string.Empty)
            .Where(s => s.Length > 0)
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToList();

        var auditor = new Auditor(string.Empty);
        var structure = await auditor.GetChecklistStructureAsync();
        var lookup = structure
            .SelectMany(s => s.Items)
            .GroupBy(i => i.Id, StringComparer.OrdinalIgnoreCase)
            .ToDictionary(g => g.Key, g => g.First(), StringComparer.OrdinalIgnoreCase);

        var items = new List<ScriptGenChecklistItem>();
        var unknown = new List<string>();

        foreach (var id in wanted)
        {
            if (lookup.TryGetValue(id, out var it))
            {
                items.Add(new ScriptGenChecklistItem
                {
                    ChecklistId = it.Id,
                    Category = it.Category ?? "",
                    CheckName = it.Description,
                    Scope = "",
                    Description = it.Description,
                    ExpectedOutcome = it.Description
                });
            }
            else
            {
                unknown.Add(id);
            }
        }

        return (items, unknown);
    }

    /// <summary>
    /// Builds the instructions Copilot follows to generate the scripts itself. This reuses the
    /// existing generation system/user prompts verbatim and tells Copilot to save each result via
    /// the save-script tool/command. It contains NO evaluation logic — this is script GENERATION.
    /// </summary>
    public static string BuildGenerationInstructions(
        IReadOnlyList<ScriptGenChecklistItem> items,
        IReadOnlyList<string> unknown,
        string saveInvocationHint)
    {
        var systemPrompt = ReadPromptTemplate("script_generator_system.txt");
        var userTemplate = ReadPromptTemplate("script_generator_user.txt");

        var sb = new StringBuilder();
        sb.AppendLine("=== SCRIPT GENERATION (not evaluation) ===");
        sb.AppendLine("This is a SCRIPT GENERATION request. Do NOT run the 'evaluate' workflow, do NOT connect to");
        sb.AppendLine("a SQL Server, and do NOT ask for a server name or credentials. YOU (GitHub Copilot) are the");
        sb.AppendLine("script generator AI: for each checklist item below, produce a deterministic, read-only audit");
        sb.AppendLine("script by following the GENERATOR SYSTEM PROMPT exactly, then save it with the save command.");
        sb.AppendLine();

        if (unknown.Count > 0)
            sb.AppendLine("Skipped unknown IDs: " + string.Join(", ", unknown));

        sb.AppendLine($"Items to generate ({items.Count}):");
        foreach (var it in items)
            sb.AppendLine($"  - {it.ChecklistId}: {it.CheckName}");
        sb.AppendLine();

        sb.AppendLine("## How to process");
        sb.AppendLine("- Process the items in BATCHES OF UP TO 10, generating the items within each batch in");
        sb.AppendLine("  parallel, and only start the next batch once the current batch is saved.");
        sb.AppendLine("- For EACH item: write the ANALYSIS, decide FEASIBLE, then emit the full raw response in the");
        sb.AppendLine("  EXACT format the system prompt defines (the FEASIBLE/SCRIPT_TYPE/SCOPE/SCRIPT_NAME/");
        sb.AppendLine("  SCORING_LOGIC fields and the ---SCRIPT_START--- / ---SCRIPT_END--- markers).");
        sb.AppendLine("- Every feasible script MUST output the four required fields: Result, Score, DatabaseQueried,");
        sb.AppendLine("  and Finding (see the system prompt for the required templates).");
        sb.AppendLine($"- After generating an item, save it: {saveInvocationHint}");
        sb.AppendLine("  Pass the COMPLETE raw response (all fields + the script between the markers) as 'response'.");
        sb.AppendLine("- The save step runs the deterministic format gate and then returns the VALIDATION SYSTEM");
        sb.AppendLine("  PROMPT for that script. Review the script with ONLY the C1-C7 checks that prompt defines —");
        sb.AppendLine("  not your own criteria — and save again with the resulting verdict. Nothing is written to");
        sb.AppendLine("  disk until that verdict is supplied.");
        sb.AppendLine("- If a save returns a validation error, CORRECT the script and save again (retry up to 3");
        sb.AppendLine("  times), exactly like the pipeline's correction/retry loop.");
        sb.AppendLine();

        sb.AppendLine("===== GENERATOR SYSTEM PROMPT (follow this precisely for every item) =====");
        sb.AppendLine(systemPrompt);
        sb.AppendLine("===== END GENERATOR SYSTEM PROMPT =====");
        sb.AppendLine();

        sb.AppendLine("===== PER-ITEM GENERATION REQUESTS =====");
        foreach (var it in items)
        {
            sb.AppendLine();
            sb.AppendLine($"--- Item {it.ChecklistId} ---");
            sb.AppendLine(FillUserPrompt(userTemplate, it));
        }

        return sb.ToString();
    }

    /// <summary>
    /// Builds the review request for ONE generated script from the canonical validation templates
    /// (script_validation_system.txt + script_validation_user.txt). This is the host-driven
    /// equivalent of <see cref="ChecklistItemProcessor.ValidateScriptAsync"/>: the AI layer performs
    /// the C1-C7 review the template defines and hands the verdict back to the caller.
    /// </summary>
    public static string BuildValidationInstructions(
        ScriptGenChecklistItem item,
        ScriptGenerationResponse response,
        string saveInvocationHint)
    {
        var systemPrompt = ReadPromptTemplate("script_validation_system.txt");
        var userTemplate = ReadPromptTemplate("script_validation_user.txt");

        var sb = new StringBuilder();
        sb.AppendLine($"=== VALIDATION REQUIRED — [{item.ChecklistId}] (NOT SAVED YET) ===");
        sb.AppendLine("The script passed the deterministic format gate. It is NOT written to disk until you");
        sb.AppendLine("return a verdict. Act as the script validator: apply the VALIDATION SYSTEM PROMPT below");
        sb.AppendLine("to the script in the request that follows, using ONLY its C1-C7 checks and verdict rules.");
        sb.AppendLine("Do not substitute your own review criteria and do not re-run the generator prompt.");
        sb.AppendLine();
        sb.AppendLine($"Then save again WITH the verdict: {saveInvocationHint}");
        sb.AppendLine("The verdict must use the template's response format exactly:");
        sb.AppendLine("  - 'VERDICT: VALID' on its own when no C1-C7 violation exists.");
        sb.AppendLine("  - 'VERDICT: INVALID' plus ISSUES, and the complete corrected script between");
        sb.AppendLine("    ---CORRECTED_SCRIPT_START--- and ---CORRECTED_SCRIPT_END--- when it is repairable.");
        sb.AppendLine("A verdict without a 'VERDICT:' line is rejected and nothing is saved.");
        sb.AppendLine();
        sb.AppendLine("===== VALIDATION SYSTEM PROMPT (follow this precisely) =====");
        sb.AppendLine(systemPrompt);
        sb.AppendLine("===== END VALIDATION SYSTEM PROMPT =====");
        sb.AppendLine();
        sb.AppendLine("===== VALIDATION REQUEST =====");
        sb.AppendLine(FillValidationPrompt(userTemplate, item, response));

        return sb.ToString();
    }

    private static string FillUserPrompt(string template, ScriptGenChecklistItem item) =>
        template
            .Replace("{checklist_id}", item.ChecklistId)
            .Replace("{category}", item.Category)
            .Replace("{check_name}", item.CheckName)
            .Replace("{description}", item.Description)
            .Replace("{expected_outcome}", item.ExpectedOutcome)
            .Replace("{scope}", item.Scope ?? "");

    // Placeholder set mirrors ChecklistItemProcessor.ValidateScriptAsync exactly.
    private static string FillValidationPrompt(
        string template, ScriptGenChecklistItem item, ScriptGenerationResponse response) =>
        template
            .Replace("{checklist_id}", item.ChecklistId)
            .Replace("{category}", item.Category)
            .Replace("{check_name}", item.CheckName)
            .Replace("{description}", item.Description)
            .Replace("{expected_outcome}", item.ExpectedOutcome)
            .Replace("{script_type}", response.ScriptType ?? "")
            .Replace("{scope}", response.Scope ?? "")
            .Replace("{scoring_logic}", response.ScoringLogic ?? "")
            .Replace("{script_content}", response.ScriptContent ?? "");

    internal static async Task UpsertExecutionResultAsync(string resultsDir, ExecutionResultEntry entry)
    {
        var resultsPath = Path.Combine(resultsDir, "execution-results.json");

        var results = new List<ExecutionResultEntry>();
        if (File.Exists(resultsPath))
        {
            try
            {
                var existing = await File.ReadAllTextAsync(resultsPath);
                if (!string.IsNullOrWhiteSpace(existing))
                {
                    using var doc = JsonDocument.Parse(existing);
                    if (doc.RootElement.TryGetProperty("results", out var arr)
                        && arr.ValueKind == JsonValueKind.Array)
                    {
                        results = JsonSerializer.Deserialize<List<ExecutionResultEntry>>(arr.GetRawText())
                                  ?? new();
                    }
                }
            }
            catch
            {
                results = new();
            }
        }

        results.RemoveAll(r => string.Equals(r.ChecklistId, entry.ChecklistId, StringComparison.OrdinalIgnoreCase));
        results.Add(entry);

        await File.WriteAllTextAsync(
            resultsPath,
            JsonSerializer.Serialize(
                new
                {
                    generatedAt = DateTime.UtcNow,
                    totalProcessed = results.Count,
                    results
                },
                new JsonSerializerOptions { WriteIndented = true }));
    }
}
