using System.ComponentModel;
using System.Text;
using System.Text.RegularExpressions;
using ModelContextProtocol.Server;
using SQLAuditor.Lib;

namespace SQLAuditor.Mcp;

/// <summary>
/// MCP tools that expose the SQL Auditor evaluation engine to GitHub Copilot Chat
/// in VS Code. The server performs deterministic (script-based) checks and file I/O
/// only — it makes no direct LLM/API calls. Copilot Chat is the AI that orchestrates
/// the conversation and reviews items that need human judgement. Each tool reuses
/// <see cref="Auditor"/> so behavior matches the CLI and the WPF app.
/// </summary>
[McpServerToolType]
public static class AuditTools
{
    private const string SaveWithVerdictHint =
        "call save_generated_script(checklistId=\"<id>\", response=\"<same full raw generator output>\", "
        + "validationVerdict=\"<your VERDICT block>\")";

    /// <summary>
    /// Items per generation batch. Matches <c>ScriptGeneratorAgent.RunAsync</c> (WPF flow),
    /// which generates 10 items concurrently and only then persists the batch.
    /// </summary>
    private const int GenerationBatchSize = 10;

    /// <summary>
    /// Accepts a single ID (<c>1.1.2</c>), a list (<c>1.1.2,3.1.1</c>) and an inclusive
    /// range in checklist order (<c>1.1.1 - 2.1.4</c>, <c>1.1.1 to 2.1.4</c>).
    /// </summary>
    private static readonly Regex ChecklistIdSpecPattern = new(
        @"(?<start>\d+(?:\.\d+)*)\s*(?:-|–|—|\.\.|to|through)\s*(?<end>\d+(?:\.\d+)*)|(?<single>\d+(?:\.\d+)*)",
        RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);

    [McpServerTool(Name = "evaluate")]
    [Description("Evaluate SQL audit checklist items following the standard workflow, identical to the CLI: (1) SQL Server name, (2) authentication method, (3) checklist items, (4) automated + manual verification, (5) summary. ALWAYS call this tool to begin an evaluation. When a required input is missing it returns the exact next question to ask the user; ask that question and call evaluate again with the answer plus everything gathered so far. Never guess the server or credentials, and never run the evaluation before the server name has been supplied by the user. Writes results/checklist_results.json, results/final_report.md and results/audit_report.xlsx (a 4-tab Excel workbook: Summary, Area Detail, Checklists, Risk Register).")]
    public static async Task<string> EvaluateAsync(
        [Description("STEP 1: SQL Server name/host[,port]. REQUIRED and must come from the user. If you don't have it yet, call with server empty to get the exact prompt to show the user.")] string? server = null,
        [Description("STEP 2: Authentication method — 'windows' for Windows Integrated, or 'sql' for SQL Login.")] string? authMethod = null,
        [Description("STEP 2b: SQL login username (only when authMethod='sql'). The password is NOT passed here; it is read at runtime from the SQLAUDITOR_SQL_PASSWORD session environment variable and must NEVER be typed in chat.")] string? sqlUser = null,
        [Description("STEP 3: Comma-separated checklist item IDs to evaluate, e.g. '1.2.1,3.1.2'. If the user already named IDs earlier, reuse them here.")] string? items = null,
        CancellationToken cancellationToken = default)
    {
        // STEP 1 — SQL Server name (always required, always from the user first).
        if (string.IsNullOrWhiteSpace(server))
            return "STEP 1 of 5 — SQL SERVER NAME REQUIRED.\n"
                 + "Ask the user: \"Please provide the SQL Server name (host or host,port).\"\n"
                 + "Do not guess or use a default such as localhost. When the user answers, call evaluate again with 'server' set. "
                 + "Retain any checklist IDs the user already mentioned and pass them as 'items' later.";

        // STEP 2 — Authentication method.
        var method = authMethod?.Trim().ToLowerInvariant();
        if (method != "windows" && method != "sql")
            return $"STEP 2 of 5 — AUTHENTICATION METHOD REQUIRED for server '{server}'.\n"
                 + "Ask the user: \"Which authentication method should I use — 'windows' (Windows Integrated) or 'sql' (SQL Login)?\"\n"
                 + "Then call evaluate again with 'server' and 'authMethod' set.";

        // STEP 2b — SQL login username (password stays in the session environment, never in chat).
        if (method == "sql" && string.IsNullOrWhiteSpace(sqlUser))
            return $"STEP 2b — SQL LOGIN USERNAME REQUIRED for server '{server}'.\n"
                 + "Ask the user for the SQL login username. For security, the password must NOT be typed in chat: "
                 + "the user sets it once in their terminal session before launching VS Code "
                 + "(PowerShell: $env:SQLAUDITOR_SQL_PASSWORD='<password>'), and the server reads it at runtime.\n"
                 + "Then call evaluate again with 'server', authMethod='sql', and 'sqlUser' set.";

        // STEP 3 — Checklist items.
        var ids = (items ?? string.Empty)
            .Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToArray();
        if (ids.Length == 0)
            return $"STEP 3 of 5 — CHECKLIST ITEMS REQUIRED.\n"
                 + $"Server '{server}' and authentication are set. Ask the user which checklist item IDs to evaluate (e.g. '1.2.1,3.1.2'). "
                 + "If the user already provided IDs earlier in the conversation, use those instead of asking again.\n"
                 + "Then call evaluate again with 'server', 'authMethod', and 'items' set.";

        // Build the connection string from the chosen method. The SQL Login password
        // is read only from the environment, never passed through tool arguments.
        string connectionString;
        if (method == "sql")
        {
            var pass = Environment.GetEnvironmentVariable("SQLAUDITOR_SQL_PASSWORD");
            if (string.IsNullOrEmpty(pass))
                return $"STEP 2b — SQL PASSWORD NOT AVAILABLE for user '{sqlUser}' on server '{server}'.\n"
                     + "The SQLAUDITOR_SQL_PASSWORD session environment variable is not set, so no SQL login can be made. "
                     + "Do NOT ask for the password in chat. Ask the user to set it in the terminal session that launched VS Code "
                     + "(PowerShell: $env:SQLAUDITOR_SQL_PASSWORD='<password>'), restart the MCP server, then run evaluate again. "
                     + "Alternatively, they can choose Windows authentication instead.";
            connectionString = $"Server={server};User Id={sqlUser};Password={pass};TrustServerCertificate=true;";
        }
        else
        {
            connectionString = $"Server={server};Integrated Security=true;TrustServerCertificate=true;";
        }

        var auditor = new Auditor(connectionString);

        // Validate requested IDs against the known checklist structure.
        var structure = await auditor.GetChecklistStructureAsync();
        var known = new HashSet<string>(
            structure.SelectMany(s => s.Items).Select(i => i.Id), StringComparer.OrdinalIgnoreCase);
        var unknown = ids.Where(id => !known.Contains(id)).ToArray();
        var valid = ids.Where(id => known.Contains(id)).ToArray();
        if (valid.Length == 0)
            return "Error: none of the requested checklist IDs exist. Unknown: " + string.Join(", ", unknown);

        // STEP 4 — run automated evaluation (manual-only items resolve to NeedsReview).
        var results = await auditor.RunChecklistAsync(null, null, valid, cancellationToken);

        var sb = new StringBuilder();
        if (unknown.Length > 0)
            sb.AppendLine("Skipped unknown IDs: " + string.Join(", ", unknown));
        sb.AppendLine($"Evaluated {results.Length} item(s):");
        foreach (var r in results.OrderBy(r => r.Id, StringComparer.OrdinalIgnoreCase))
            sb.AppendLine($"- [{r.Id}] {r.Outcome} ({r.Technique}) - {r.Description}");
        sb.AppendLine();
        sb.AppendLine("Summary:");
        foreach (var g in results.GroupBy(r => r.Outcome ?? "Unknown", StringComparer.OrdinalIgnoreCase)
                                  .OrderBy(g => g.Key, StringComparer.OrdinalIgnoreCase))
            sb.AppendLine($"  {g.Key}: {g.Count()}");

        // Script items get their verdict deterministically but their wording from Copilot,
        // since this server makes no LLM calls.
        sb.AppendLine();
        sb.Append(Auditor.BuildScriptEnrichmentRequest(
            results,
            id => $"enrich_result(id=\"{id}\", finding=\"...\", evidence=\"...\", riskImpact=\"...\", recommendation=\"...\")"));

        // Items not decided by deterministic scripts need review. This server makes no
        // LLM calls, so Copilot Chat is the reviewer: it analyzes each item, guides the
        // user, and records the decision via the resolve_review tool.
        var manualPending = results
            .Where(r => string.Equals(r.Outcome, "NeedsReview", StringComparison.OrdinalIgnoreCase)
                     && (r.Technique?.Contains("Manual", StringComparison.OrdinalIgnoreCase) ?? false))
            .OrderBy(r => r.Id, StringComparer.OrdinalIgnoreCase)
            .ToList();

        if (manualPending.Count > 0)
        {
            var itemLookup = structure.SelectMany(s => s.Items)
                .GroupBy(i => i.Id, StringComparer.OrdinalIgnoreCase)
                .ToDictionary(g => g.Key, g => g.First(), StringComparer.OrdinalIgnoreCase);

            sb.AppendLine();
            sb.AppendLine("=== ACTION REQUIRED: REVIEW (do not stop here) ===");
            sb.AppendLine($"{manualPending.Count} item(s) were not decided by the deterministic scripts and need review.");
            sb.AppendLine("This MCP server performs NO AI/LLM calls — YOU (GitHub Copilot) are the reviewer. For EACH item below you MUST:");
            sb.AppendLine("  1. Present the guidance to the user using EXACTLY this output format (fill each section with specific, item-tailored content — exact T-SQL to run, settings/objects to inspect in SSMS):");
            sb.AppendLine("       Checklist: <checklist title>");
            sb.AppendLine("       Objective: <one sentence explaining what is being verified>");
            sb.AppendLine("       ");
            sb.AppendLine("       ## Manual Verification Steps:");
            sb.AppendLine("       1. ...");
            sb.AppendLine("       2. ... (include SQL queries in ```sql code blocks whenever required)");
            sb.AppendLine("       ");
            sb.AppendLine("       ## What indicates a PASS and a FAIL");
            sb.AppendLine("       Pass:");
            sb.AppendLine("       - ...");
            sb.AppendLine("       Fail:");
            sb.AppendLine("       - ...");
            sb.AppendLine("       ");
            sb.AppendLine("       ## Recommended Actions (if failed)");
            sb.AppendLine("       - ...");
            sb.AppendLine("     Do NOT add extra sections or headings outside this format.");
            sb.AppendLine("  2. Ask the user for their finding / evidence.");
            sb.AppendLine("  3. Decide Pass or Fail together with the user, then call the 'resolve_review' tool.");
            sb.AppendLine("Do NOT write a final summary until every item has been resolved.");
            foreach (var r in manualPending)
            {
                sb.AppendLine();
                sb.AppendLine($"--- {r.Id}: {r.Description} ---");
                if (itemLookup.TryGetValue(r.Id, out var it))
                {
                    if (!string.IsNullOrWhiteSpace(it.Category)) sb.AppendLine($"Area/Category: {it.Category}");
                    if (!string.IsNullOrWhiteSpace(it.Verification)) sb.AppendLine($"Verification objective: {it.Verification}");
                }
                if (!string.IsNullOrWhiteSpace(r.Evidence))
                {
                    sb.AppendLine("Baseline verification steps (use as your source, then render it in the required output format above — do NOT invent a different structure):");
                    sb.AppendLine(r.Evidence.Trim());
                }
                sb.AppendLine($"After the user decides, call: resolve_review(id=\"{r.Id}\", decision=\"pass\" or \"fail\", notes=\"<user's rationale>\")");
            }
        }

        sb.AppendLine();
        sb.AppendLine("Reports written to results/checklist_results.json, results/final_report.md and results/audit_report.xlsx (4-tab Excel workbook).");
        return sb.ToString();
    }

    [McpServerTool(Name = "load_checklist")]
    [Description("List the SQL audit checklist structure (areas and item IDs with descriptions) so valid IDs can be discovered before evaluating. Read-only; needs no SQL Server.")]
    public static async Task<string> LoadChecklistAsync(
        [Description("Optional text to filter by; matches against item IDs or descriptions.")] string? search = null)
    {
        var auditor = new Auditor(string.Empty);
        var structure = await auditor.GetChecklistStructureAsync();

        var sb = new StringBuilder();
        foreach (var (area, items) in structure)
        {
            var filtered = string.IsNullOrWhiteSpace(search)
                ? items
                : items.Where(i =>
                        (i.Id?.Contains(search, StringComparison.OrdinalIgnoreCase) ?? false) ||
                        (i.Description?.Contains(search, StringComparison.OrdinalIgnoreCase) ?? false))
                    .ToArray();
            if (filtered.Length == 0) continue;

            sb.AppendLine($"Area: {area}");
            foreach (var it in filtered)
                sb.AppendLine($"  {it.Id} - {it.Description}");
        }

        var text = sb.ToString();
        return string.IsNullOrWhiteSpace(text) ? "No checklist items matched." : text;
    }

    [McpServerTool(Name = "generate_scripts")]
    [Description("GENERATE deterministic audit SCRIPTS for checklist items — this is NOT evaluation and needs no SQL Server or credentials. Use this whenever the user asks to 'generate scripts', 'create scripts', or 'write audit scripts' for one or more checklist IDs (including the /generateScript command). 'items' accepts a single ID ('1.1.2'), a comma-separated list ('1.1.2,3.1.1') or an inclusive range in checklist order ('1.1.1 - 2.1.4'). Items are served in BATCHES OF 10, exactly like the WPF app: this call returns only the current batch, and you call it again with the SAME 'items' and batch+1 once every item in the batch is saved. It reuses the same generation pipeline as the WPF app: it returns the generator system prompt plus a per-item request and instructs YOU (GitHub Copilot) to author each read-only script (with the required Result/Score/DatabaseQueried/Finding output) and then save it with 'save_generated_script'. Existing scripts and mapping entries for the same ID are overwritten. Never call 'evaluate' for a script-generation request.")]
    public static async Task<string> GenerateScriptsAsync(
        [Description("Checklist IDs to generate scripts for: a single ID ('1.1.2'), a comma-separated list ('1.1.2,3.1.1'), or an inclusive range in checklist order ('1.1.1 - 2.1.4'). Pass the SAME value unchanged on every batch call. If missing, ask the user which checklist IDs to generate scripts for.")] string? items = null,
        [Description("1-based batch number. Items are processed 10 at a time, mirroring the WPF flow. Omit or pass 1 for the first batch, then call again with batch=2, 3, ... after every item in the previous batch has been saved.")] int batch = 1,
        CancellationToken cancellationToken = default)
    {
        var spec = (items ?? string.Empty).Trim();

        if (spec.Length == 0)
            return "SCRIPT GENERATION — CHECKLIST IDS REQUIRED.\n"
                 + "Ask the user which checklist item IDs to generate scripts for. Accepted forms: a single ID "
                 + "('1.1.2'), a list ('1.1.2,3.1.1') or an inclusive range ('1.1.1 - 2.1.4'). "
                 + "This is script generation, not evaluation — do not ask for a SQL Server or credentials.";

        // Ranges resolve against the checklist's own ordering, so '1.1.1 - 2.1.4' means
        // "every item between these two in master-checklist.json", not a numeric interval.
        var auditor = new Auditor(string.Empty);
        var structure = await auditor.GetChecklistStructureAsync();
        var orderedIds = structure
            .SelectMany(s => s.Items)
            .Select(i => i.Id)
            .Where(id => !string.IsNullOrWhiteSpace(id))
            .ToList();

        var (requestedIds, unresolved) = ExpandChecklistIdSpec(spec, orderedIds);

        if (requestedIds.Count == 0)
            return $"Error: no checklist IDs could be resolved from '{spec}'."
                 + (unresolved.Count > 0 ? " Unresolved: " + string.Join(", ", unresolved) + "." : string.Empty)
                 + " Use 'load_checklist' to discover valid IDs, then call generate_scripts again.";

        var totalBatches = (requestedIds.Count + GenerationBatchSize - 1) / GenerationBatchSize;
        if (batch < 1) batch = 1;

        if (batch > totalBatches)
            return $"ALL BATCHES COMPLETE for '{spec}'. {requestedIds.Count} item(s) fit into {totalBatches} "
                 + $"batch(es) of {GenerationBatchSize}; batch {batch} does not exist. "
                 + "Summarise what was generated, skipped (not feasible) and failed — do not call generate_scripts again.";

        var batchIds = requestedIds
            .Skip((batch - 1) * GenerationBatchSize)
            .Take(GenerationBatchSize)
            .ToList();

        var (checklistItems, unknown) = await ScriptGenerationSkill.LoadItemsAsync(batchIds);
        if (checklistItems.Count == 0)
            return "Error: none of the checklist IDs in this batch exist. Unknown: " + string.Join(", ", unknown);

        var sb = new StringBuilder();
        sb.AppendLine($"=== SCRIPT GENERATION — BATCH {batch} OF {totalBatches} ({checklistItems.Count} item(s)) ===");
        sb.AppendLine($"Requested: {spec}");
        sb.AppendLine($"Resolved {requestedIds.Count} checklist item(s) in checklist order: {string.Join(", ", requestedIds)}");
        if (unresolved.Count > 0)
            sb.AppendLine("Not found in the checklist and skipped: " + string.Join(", ", unresolved));

        var alreadyGenerated = DescribeExistingScripts(batchIds);
        if (alreadyGenerated.Length > 0)
            sb.AppendLine($"Already generated and WILL BE OVERWRITTEN on save: {alreadyGenerated}. "
                        + "Generate them again from scratch — do not skip them and do not reuse the old content.");

        sb.AppendLine($"Generate ONLY the {checklistItems.Count} item(s) in this batch, in parallel. "
                    + "Do not start the next batch until every item here has been saved.");
        sb.AppendLine();

        sb.Append(ScriptGenerationSkill.BuildGenerationInstructions(
            checklistItems,
            unknown,
            "call save_generated_script(checklistId=\"<id>\", response=\"<full raw generator output>\")"));

        sb.AppendLine();
        sb.AppendLine($"=== END OF BATCH {batch} OF {totalBatches} ===");
        if (batch < totalBatches)
        {
            var nextCount = Math.Min(GenerationBatchSize, requestedIds.Count - (batch * GenerationBatchSize));
            sb.AppendLine($"After ALL {checklistItems.Count} item(s) above are saved (or recorded as NOT FEASIBLE), "
                        + $"continue with the next {nextCount} item(s) by calling:");
            sb.AppendLine($"    generate_scripts(items=\"{spec}\", batch={batch + 1})");
            sb.AppendLine("Pass 'items' unchanged so the batches stay aligned. Do not stop or summarise before the last batch.");
        }
        else
        {
            sb.AppendLine("This is the FINAL batch. Once every item here is saved, report the totals "
                        + "(generated / not feasible / failed) and stop — do not call generate_scripts again.");
        }

        return sb.ToString();
    }

    /// <summary>
    /// Expands an ID specification into concrete checklist IDs, sorted in checklist order.
    /// Ranges are resolved by position in <paramref name="orderedIds"/>, so they follow the
    /// master checklist rather than numeric comparison.
    /// </summary>
    private static (List<string> Ids, List<string> Unresolved) ExpandChecklistIdSpec(
        string spec, IReadOnlyList<string> orderedIds)
    {
        var position = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
        for (var i = 0; i < orderedIds.Count; i++)
            if (!position.ContainsKey(orderedIds[i]))
                position[orderedIds[i]] = i;

        var resolved = new List<string>();
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var unresolved = new List<string>();

        void Add(int index)
        {
            var id = orderedIds[index];
            if (seen.Add(id)) resolved.Add(id);
        }

        foreach (Match m in ChecklistIdSpecPattern.Matches(spec))
        {
            if (m.Groups["single"].Success)
            {
                var id = m.Groups["single"].Value;
                if (position.TryGetValue(id, out var idx)) Add(idx);
                else if (!unresolved.Contains(id, StringComparer.OrdinalIgnoreCase)) unresolved.Add(id);
                continue;
            }

            var startId = m.Groups["start"].Value;
            var endId = m.Groups["end"].Value;
            var hasStart = position.TryGetValue(startId, out var startIdx);
            var hasEnd = position.TryGetValue(endId, out var endIdx);

            if (!hasStart && !unresolved.Contains(startId, StringComparer.OrdinalIgnoreCase)) unresolved.Add(startId);
            if (!hasEnd && !unresolved.Contains(endId, StringComparer.OrdinalIgnoreCase)) unresolved.Add(endId);
            if (!hasStart || !hasEnd) continue;

            if (startIdx > endIdx) (startIdx, endIdx) = (endIdx, startIdx);
            for (var i = startIdx; i <= endIdx; i++) Add(i);
        }

        resolved.Sort((a, b) => position[a].CompareTo(position[b]));
        return (resolved, unresolved);
    }

    /// <summary>
    /// Lists the IDs in the batch that already have a script on disk. Saving overwrites them,
    /// so this is reported rather than treated as a reason to skip.
    /// </summary>
    private static string DescribeExistingScripts(IEnumerable<string> ids)
    {
        try
        {
            var basePath = ScriptGenerationSkill.ResolveBasePath();
            var existing = new List<string>();

            foreach (var id in ids)
            {
                var safeId = Regex.Replace(id, @"[^a-zA-Z0-9_.-]+", "_").Trim('_');
                if (string.IsNullOrWhiteSpace(safeId)) continue;

                foreach (var type in new[] { "sql", "ps1" })
                {
                    var path = Path.Combine(basePath, "checklist", "scripts", type, $"{safeId}.{type}");
                    if (File.Exists(path)) existing.Add($"{id} ({type})");
                }
            }

            return string.Join(", ", existing);
        }
        catch
        {
            return string.Empty;
        }
    }

    [McpServerTool(Name = "validate_generated_script")]
    [Description("Return the standard C1-C7 review request for one script YOU generated, built from Backend/agents/prompts/script_validation_system.txt and script_validation_user.txt. Provide the checklist ID and the COMPLETE raw generator response. Review the script using ONLY the checks in the returned prompt, then call 'save_generated_script' with the resulting verdict. 'save_generated_script' returns this same prompt if called without a verdict, so nothing is saved until the review is done.")]
    public static async Task<string> ValidateGeneratedScriptAsync(
        [Description("The checklist item ID this script belongs to, e.g. '1.1.2'.")] string checklistId,
        [Description("The COMPLETE raw generator output for this item, exactly as produced from the generator prompt.")] string response,
        CancellationToken cancellationToken = default)
    {
        return await ScriptGenerationSkill.SaveGeneratedScriptAsync(
            checklistId,
            response,
            validationVerdict: null,
            saveInvocationHint: SaveWithVerdictHint,
            cancellationToken);
    }

    [McpServerTool(Name = "save_generated_script")]
    [Description("Save one script YOU generated for a checklist item (used after 'generate_scripts'). Provide the checklist ID and the COMPLETE raw generator response (all fields plus the script between ---SCRIPT_START--- and ---SCRIPT_END---). Called without 'validationVerdict' it runs the format gate and returns the standard C1-C7 validation prompt instead of saving. Perform that review, then call again passing the verdict ('VERDICT: VALID', or 'VERDICT: INVALID' with ISSUES and the corrected script between ---CORRECTED_SCRIPT_START--- and ---CORRECTED_SCRIPT_END---). On success it writes the script file and updates Backend/checklist/deterministic-script-mapping.json and Backend/results/execution-results.json. If it returns a validation error, correct the script and call again (retry up to 3 times).")]
    public static async Task<string> SaveGeneratedScriptAsync(
        [Description("The checklist item ID this script belongs to, e.g. '1.1.2'.")] string checklistId,
        [Description("The COMPLETE raw generator output for this item: the FEASIBLE/SCRIPT_TYPE/SCOPE/SCRIPT_NAME/SCORING_LOGIC fields and the script between ---SCRIPT_START--- and ---SCRIPT_END--- markers.")] string response,
        [Description("The verdict from the C1-C7 review, in the validation template's response format. Omit on the first call to receive the validation prompt.")] string? validationVerdict = null,
        CancellationToken cancellationToken = default)
    {
        return await ScriptGenerationSkill.SaveGeneratedScriptAsync(
            checklistId,
            response,
            validationVerdict,
            SaveWithVerdictHint,
            cancellationToken);
    }

    [McpServerTool(Name = "show_reports")]
    [Description("Return the most recently generated audit output: 'summary' for results/final_report.md (default) or 'json' for results/checklist_results.json.")]
    public static Task<string> ShowReportsAsync(
        [Description("'summary' for the Markdown report (default) or 'json' for the raw results.")] string kind = "summary")
    {
        var resultsDir = Path.Combine(Directory.GetCurrentDirectory(), "results");
        var path = string.Equals(kind, "json", StringComparison.OrdinalIgnoreCase)
            ? Path.Combine(resultsDir, "checklist_results.json")
            : Path.Combine(resultsDir, "final_report.md");

        if (!File.Exists(path))
            return Task.FromResult($"No report found at {path}. Run 'evaluate' first.");

        return Task.FromResult(File.ReadAllText(path));
    }

    [McpServerTool(Name = "resolve_review")]
    [Description("Mark a checklist item that came back as NeedsReview with a human decision of pass or fail (or needsreview). Updates results/checklist_results.json and regenerates results/final_report.md and results/audit_report.xlsx. Use after 'evaluate' surfaces manual-review items.")]
    public static Task<string> ResolveReviewAsync(
        [Description("The checklist item ID to resolve, e.g. '3.1.1'.")] string id,
        [Description("The decision: 'pass', 'fail', or 'needsreview'.")] string decision,
        [Description("Optional reviewer notes, recorded as the finding/evidence.")] string? notes = null)
    {
        if (string.IsNullOrWhiteSpace(id))
            return Task.FromResult("Error: 'id' is required.");
        if (string.IsNullOrWhiteSpace(decision))
            return Task.FromResult("Error: 'decision' is required (pass, fail, or needsreview).");

        var auditor = new Auditor(string.Empty);
        if (auditor.ResolveReview(id, decision, notes, out var newOutcome))
            return Task.FromResult($"Updated [{id}] -> {newOutcome}. results/checklist_results.json, results/final_report.md and results/audit_report.xlsx regenerated.");

        return Task.FromResult(
            $"Could not resolve '{id}'. Ensure 'evaluate' has run (results file exists), the ID is present, and decision is pass/fail/needsreview.");
    }

    [McpServerTool(Name = "enrich_result")]
    [Description("Record the audit wording YOU authored for a script-evaluated checklist item, using only the facts the script returned. Sets Finding, Evidence, RiskImpact and Recommendation in results/checklist_results.json and regenerates results/final_report.md. Outcome, Score, Severity and Databases Verified are script-derived and cannot be changed. Use after 'evaluate' lists items in its COPILOT ENRICHMENT REQUIRED block.")]
    public static Task<string> EnrichResultAsync(
        [Description("The checklist item ID to enrich, e.g. '1.1.5'.")] string id,
        [Description("1-2 sentences on the actual state the script found (object/database names, counts). Not a restatement of the checklist description.")] string? finding = null,
        [Description("How the finding justifies the outcome, quoting the values the script returned. Under 120 words.")] string? evidence = null,
        [Description("The specific business/security/operational consequence of this finding. Under 50 words.")] string? riskImpact = null,
        [Description("Remediation targeted at this gap, consistent with the score. Omit when the score is 3 and the outcome is Pass.")] string? recommendation = null)
    {
        if (string.IsNullOrWhiteSpace(id))
            return Task.FromResult("Error: 'id' is required.");

        var auditor = new Auditor(string.Empty);
        if (auditor.ApplyEnrichment(id, finding, evidence, riskImpact, recommendation))
            return Task.FromResult($"Enriched [{id}]. results/checklist_results.json and results/final_report.md regenerated.");

        return Task.FromResult(
            $"Could not enrich '{id}'. Ensure 'evaluate' has run (results file exists), the ID is present, and at least one field was supplied.");
    }
}

/// <summary>
/// MCP prompts surfaced as slash commands in GitHub Copilot Chat. A prompt only
/// instructs Copilot to drive the existing SQL Auditor tools; it contains no
/// evaluation logic of its own.
/// </summary>
[McpServerPromptType]
public static class AuditPrompts
{
    [McpServerPrompt(Name = "evaluate")]
    [Description("Run a SQL Auditor checklist evaluation using the sql-auditor MCP tools.")]
    public static string Evaluate() =>
        "Start a SQL Auditor checklist evaluation using the sql-auditor MCP tools. "
      + "Call the 'evaluate' tool and follow its step-by-step workflow exactly — it returns the next "
      + "question to ask me: (1) the SQL Server name, (2) the authentication method ('windows' or 'sql'; "
      + "for SQL Login ask the username, the password comes from the environment), then (3) the checklist "
      + "item IDs to evaluate. Never guess the server or credentials. "
      + "For every item listed in the COPILOT ENRICHMENT REQUIRED block, author the finding, evidence, "
      + "risk impact and recommendation from the script result shown there and record them with 'enrich_result'. "
      + "For any item that comes back as Needs Review, show its verification guidance, help me decide "
      + "Pass or Fail, and record each decision with the 'resolve_review' tool. "
      + "When everything is resolved, show the summary with 'show_reports'. "
      + "Do not perform the evaluation yourself or duplicate its logic — always use the tools.";

    [McpServerPrompt(Name = "generate_scripts")]
    [Description("Generate deterministic audit scripts for checklist items using the sql-auditor MCP tools (not evaluation).")]
    public static string GenerateScripts() =>
        "Generate audit scripts (do NOT evaluate) using the sql-auditor MCP tools. "
      + "Ask me which checklist item IDs to generate scripts for — a single ID ('1.1.2'), a list "
      + "('1.1.2,3.1.1') or an inclusive range ('1.1.1 - 2.1.4') — then call the 'generate_scripts' tool "
      + "with that value as 'items' and batch=1. "
      + "This is script generation only — do not call 'evaluate', do not connect to a SQL Server, and do not ask "
      + "for a server name or credentials. Follow the generator system prompt the tool returns: for each item, "
      + "write the analysis, decide feasibility, and author a read-only script that outputs Result, Score, "
      + "DatabaseQueried and Finding. The tool serves the items in batches of 10, mirroring the WPF app: generate "
      + "the items of the current batch in parallel, and only after every one of them is saved call "
      + "'generate_scripts' again with the SAME 'items' and the next batch number, until the tool reports the "
      + "final batch. After generating each item, save it with the 'save_generated_script' tool, passing the full "
      + "raw generator output. That returns the standard C1-C7 validation prompt: review the script using only "
      + "those checks, then call 'save_generated_script' again with the verdict. Nothing is written to disk until "
      + "you do. If saving returns a validation error, correct the script and save again (retry up to 3 times). "
      + "Scripts and mapping entries for IDs that already have one are overwritten, so never skip an item because "
      + "a script already exists.";
}