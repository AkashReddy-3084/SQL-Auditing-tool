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
/// Shared "generate scripts" skill for the IDE (MCP) and CLI hosts. Unlike the WPF app —
/// which drives <see cref="ScriptGeneratorAgent"/> against a configured LLM endpoint —
/// GitHub Copilot is the AI here, so this helper makes NO LLM/API calls. It reuses the
/// existing pipeline pieces (the generation prompts, <see cref="ScriptOutputValidator"/>,
/// the <see cref="ScriptGenerationResponse"/> parser, and the exact on-disk layout that
/// <see cref="ScriptGeneratorAgent"/> produces): Copilot generates each script from the
/// prompt this class hands it, then calls back to <see cref="SaveGeneratedScriptAsync"/>,
/// which validates, and on success saves the script and updates the mapping/results —
/// mirroring the WPF pipeline (generate → validate → correct/retry → save → update).
/// </summary>
public static class ScriptGenerationSkill
{
    /// <summary>
    /// Locates the Backend base path (the folder <see cref="ScriptGeneratorAgent"/> expects),
    /// by walking up from the current directory to the folder containing the checklist.
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
                    var candidate = Path.Combine(dir.FullName, "Backend", "checklist", name);
                    if (File.Exists(candidate))
                        return Path.Combine(dir.FullName, "Backend");
                }
                dir = dir.Parent;
            }
        }

        throw new DirectoryNotFoundException(
            "Cannot locate the repository root (Backend/checklist/master-checklist.json not found). "
            + "Run from the SQL-Auditing-tool folder.");
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
                // Mirror the WPF mapping (MainWindow.GenerateScriptsBtn_Click) exactly.
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
        var basePath = ResolveBasePath();
        var promptsDir = Path.Combine(basePath, "agents", "prompts");
        var systemPrompt = File.ReadAllText(Path.Combine(promptsDir, "script_generator_system.txt"));
        var userTemplate = File.ReadAllText(Path.Combine(promptsDir, "script_generator_user.txt"));

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

        sb.AppendLine("## How to process (mirror the WPF Generate Scripts flow)");
        sb.AppendLine("- Process the items in BATCHES OF UP TO 10, generating the items within each batch in");
        sb.AppendLine("  parallel, and only start the next batch once the current batch is saved.");
        sb.AppendLine("- For EACH item: write the ANALYSIS, decide FEASIBLE, then emit the full raw response in the");
        sb.AppendLine("  EXACT format the system prompt defines (the FEASIBLE/SCRIPT_TYPE/SCOPE/SCRIPT_NAME/");
        sb.AppendLine("  SCORING_LOGIC fields and the ---SCRIPT_START--- / ---SCRIPT_END--- markers).");
        sb.AppendLine("- Every feasible script MUST output the four required fields: Result, Score, DatabaseQueried,");
        sb.AppendLine("  and Finding (see the system prompt for the required templates).");
        sb.AppendLine($"- After generating an item, save it: {saveInvocationHint}");
        sb.AppendLine("  Pass the COMPLETE raw response (all fields + the script between the markers) as 'response'.");
        sb.AppendLine("- The save step validates the script. If it returns a validation error, CORRECT the script and");
        sb.AppendLine("  save again (retry up to 3 times), exactly like the pipeline's correction/retry loop.");
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
    /// Validates a Copilot-generated raw response and, when valid, persists it exactly like
    /// <see cref="ScriptGeneratorAgent"/> does: writes the script file, updates the deterministic
    /// script mapping and the execution-results file. On a validation failure it returns actionable
    /// feedback so Copilot can correct the script and resubmit (the pipeline's correction/retry step).
    /// </summary>
    public static async Task<string> SaveGeneratedScriptAsync(
        string checklistId,
        string rawResponse,
        CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(checklistId))
            return "Error: 'checklistId' is required.";
        if (string.IsNullOrWhiteSpace(rawResponse))
            return $"Error: no generated response supplied for '{checklistId}'. Generate the script first, then save its full raw output.";

        var basePath = ResolveBasePath();
        var sqlDir = Path.Combine(basePath, "checklist", "scripts", "sql");
        var ps1Dir = Path.Combine(basePath, "checklist", "scripts", "ps1");
        var resultsDir = Path.Combine(basePath, "results");
        Directory.CreateDirectory(sqlDir);
        Directory.CreateDirectory(ps1Dir);
        Directory.CreateDirectory(resultsDir);

        // Reuse the exact parser the WPF/LLM pipeline uses so the accepted format is identical.
        var response = ChecklistItemProcessor.ParseResponse(rawResponse);

        // Resolve item metadata (CheckName/Category) for the results entry.
        var (items, _) = await LoadItemsAsync(new[] { checklistId });
        var item = items.FirstOrDefault();
        var checkName = item?.CheckName ?? checklistId;
        var category = item?.Category ?? "";

        // NOT FEASIBLE — record the classification without saving a script (as the agent does).
        if (!response.IsFeasible)
        {
            await UpsertExecutionResultAsync(resultsDir, new ExecutionResultEntry
            {
                ChecklistId = checklistId,
                CheckName = checkName,
                Category = category,
                Status = "Not Feasible",
                Reason = response.Reason
            });
            UpsertMapping(basePath, checklistId, null, response);
            return $"Recorded [{checklistId}] as NOT FEASIBLE: {response.Reason}. No script saved. "
                 + "Mapping and execution-results updated.";
        }

        // STEP — local format validation (reuse the existing validator).
        var validation = new ScriptOutputValidator().Validate(response);
        if (!validation.IsValid)
        {
            return $"VALIDATION FAILED for [{checklistId}]: {validation.Error}\n"
                 + "Correct the script so it satisfies the required output format (Result, Score, "
                 + "DatabaseQueried, Finding — with @Result/@Score for SQL) and call the save command again. "
                 + "This is the pipeline's correction/retry step; retry up to 3 times before giving up.";
        }

        // STEP — save the script using the same file layout as ScriptGeneratorAgent.
        var safeId = Regex.Replace(checklistId, @"[^a-zA-Z0-9_.-]+", "_").Trim('_');
        if (string.IsNullOrWhiteSpace(safeId)) safeId = "unknown";
        var filename = $"{safeId}.{response.ScriptType}";
        var outputDir = response.ScriptType == "sql" ? sqlDir : ps1Dir;
        var scriptPath = Path.Combine(outputDir, filename);
        await File.WriteAllTextAsync(scriptPath, response.ScriptContent, cancellationToken);

        // STEP — update mapping + execution-results (same shapes the agent writes).
        var relativeScriptFile = $"Backend/checklist/scripts/{response.ScriptType}/{filename}";
        UpsertMapping(basePath, checklistId, relativeScriptFile, response);

        await UpsertExecutionResultAsync(resultsDir, new ExecutionResultEntry
        {
            ChecklistId = checklistId,
            CheckName = checkName,
            Category = category,
            Scope = response.Scope,
            Status = "Script Generated",
            ScriptType = response.ScriptType,
            ScriptPath = $"{response.ScriptType}/{filename}",
            ScoringLogic = response.ScoringLogic
        });

        return $"Saved [{checklistId}] -> {response.ScriptType}/{filename} "
             + $"(Scope: {response.Scope}). Mapping and execution-results updated.";
    }

    private static string FillUserPrompt(string template, ScriptGenChecklistItem item) =>
        template
            .Replace("{checklist_id}", item.ChecklistId)
            .Replace("{category}", item.Category)
            .Replace("{check_name}", item.CheckName)
            .Replace("{description}", item.Description)
            .Replace("{expected_outcome}", item.ExpectedOutcome)
            .Replace("{scope}", item.Scope ?? "");

    private static void UpsertMapping(
        string basePath, string checklistId, string? scriptFile, ScriptGenerationResponse response)
    {
        var mappingPath = Path.Combine(basePath, "checklist", "deterministic-script-mapping.json");

        var mapping = new Dictionary<string, JsonElement>(StringComparer.OrdinalIgnoreCase);
        if (File.Exists(mappingPath))
        {
            try
            {
                var existing = File.ReadAllText(mappingPath);
                if (!string.IsNullOrWhiteSpace(existing))
                    mapping = JsonSerializer.Deserialize<Dictionary<string, JsonElement>>(existing)
                              ?? new(StringComparer.OrdinalIgnoreCase);
            }
            catch
            {
                // Keep going with an empty map if the file cannot be read.
            }
        }

        var merged = new Dictionary<string, object?>();
        foreach (var kv in mapping)
        {
            if (string.Equals(kv.Key, checklistId, StringComparison.OrdinalIgnoreCase))
                continue;
            merged[kv.Key] = kv.Value;
        }

        merged[checklistId] = new
        {
            script_file = scriptFile,
            IsAdminCheck = response.IsAdminCheck,
            IsDocumentationCheck = response.IsDocumentationCheck,
            MCP_Feasibility = response.McpFeasibility
        };

        File.WriteAllText(
            mappingPath,
            JsonSerializer.Serialize(merged, new JsonSerializerOptions { WriteIndented = true }));
    }

    private static async Task UpsertExecutionResultAsync(string resultsDir, ExecutionResultEntry entry)
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
