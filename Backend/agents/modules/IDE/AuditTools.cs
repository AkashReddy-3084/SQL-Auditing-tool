using System.ComponentModel;
using System.Text;
using System.Text.Json;
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
    /// Agent that owns the full per-item loop in subagent mode, defined in
    /// .github/agents/sql-script-generator.agent.md.
    /// </summary>
    private const string GeneratorAgentName = "sql-script-generator";

    // Subagents save concurrently, and the mapping and execution-results files are
    // read-modify-write, so persistence is serialised across every caller of this server.
    private static readonly SemaphoreSlim SaveGate = new(1, 1);

    /// <summary>
    /// Accepts a single ID (<c>1.1.2</c>), a list (<c>1.1.2,3.1.1</c>) and an inclusive
    /// range in checklist order (<c>1.1.1 - 2.1.4</c>, <c>1.1.1 to 2.1.4</c>).
    /// </summary>
    private static readonly Regex ChecklistIdSpecPattern = new(
        @"(?<start>\d+(?:\.\d+)*)\s*(?:-|–|—|\.\.|to|through)\s*(?<end>\d+(?:\.\d+)*)|(?<single>\d+(?:\.\d+)*)",
        RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);

    [McpServerTool(Name = "evaluate")]
    [Description("Evaluate SQL audit checklist items following the standard workflow, identical to the CLI: (1) how manual items are handled (reuse the last runs or evaluate fresh), (2) SQL Server name, (3) authentication method, (4) checklist items, (5) automated + manual verification, (6) summary. ALWAYS call this tool to begin an evaluation. When a required input is missing it returns the exact next question to ask the user; ask that question and call evaluate again with the answer plus everything gathered so far. Never guess the server, the credentials or the manual-results choice, and never run the evaluation before the server name has been supplied by the user. Writes checklist_results.json in a timestamp-and-server run directory under results — the reports are NOT generated automatically; ask the user afterwards and call 'generate_report' if they say yes.")]
    public static async Task<string> EvaluateAsync(
        [Description("STEP 1: How manual/AI-Manual checklist items are handled — 'last-runs' to copy the results recorded in results/historical_last_run.json, or 'fresh' to evaluate every manual item again. This MUST come from the user; never choose it yourself. Call with it empty to get the exact question to ask.")] string? manualResults = null,
        [Description("STEP 2: SQL Server name/host[,port]. REQUIRED and must come from the user. If you don't have it yet, call with server empty to get the exact prompt to show the user.")] string? server = null,
        [Description("STEP 3: Authentication method — 'windows' for Windows Integrated, or 'sql' for SQL Login.")] string? authMethod = null,
        [Description("STEP 3b: SQL login username (only when authMethod='sql'). The password is NOT passed here; it is read at runtime from the SQLAUDITOR_SQL_PASSWORD session environment variable and must NEVER be typed in chat.")] string? sqlUser = null,
        [Description("STEP 4: The checklist items to evaluate. Accepts a single ID ('1.2.1'), a comma-separated list ('1.2.1,3.1.2'), an inclusive range in checklist order ('1.1.1 - 2.1.4') or 'all'. Pass what the user typed verbatim; this tool resolves it. If the user already named items earlier, reuse them here.")] string? items = null,
        CancellationToken cancellationToken = default)
    {
        // STEP 1 — manual-results source. Asked first, and always answered by the user.
        var manualMode = manualResults?.Trim().ToLowerInvariant();
        bool? useHistoricalManualResults = manualMode switch
        {
            "last-runs" or "lastruns" or "last" or "historical" or "reuse" or "1" => true,
            "fresh" or "new" or "none" or "2" => false,
            _ => null,
        };
        if (useHistoricalManualResults is null)
        {
            var available = HistoricalManualResultsStore.AvailableIds().Count;
            return "STEP 1 of 6 — MANUAL RESULTS SOURCE REQUIRED.\n"
                 + "Before any evaluation starts, ask the user how manual checklist items should be handled. "
                 + "Present BOTH options and wait for their answer — never decide this yourself:\n"
                 + "  Option 1 — Use the Last Runs: \"Do you want me to use the last runs results for the manual steps?\"\n"
                 + "  Option 2 — Fresh Evaluation: \"Do you want to evaluate the checklist items fresh (do not copy manual results from previous runs)?\"\n"
                 + (available > 0
                        ? $"results/{HistoricalManualResultsStore.FileName} currently holds {available} reusable manual result(s).\n"
                        : $"results/{HistoricalManualResultsStore.FileName} does not exist yet, so Option 1 falls back safely to a fresh manual evaluation.\n")
                 + "Then call evaluate again with manualResults='last-runs' (Option 1) or manualResults='fresh' (Option 2), "
                 + "plus everything else already gathered.";
        }

        // STEP 2 — SQL Server name (always required, always from the user first).
        if (string.IsNullOrWhiteSpace(server))
            return "STEP 2 of 6 — SQL SERVER NAME REQUIRED.\n"
                 + "Ask the user: \"Please provide the SQL Server name (host or host,port).\"\n"
                 + "Do not guess or use a default such as localhost. When the user answers, call evaluate again with 'server' set. "
                 + "Retain any checklist IDs the user already mentioned and pass them as 'items' later.";

        // STEP 3 — Authentication method.
        var method = authMethod?.Trim().ToLowerInvariant();
        if (method != "windows" && method != "sql")
            return $"STEP 3 of 6 — AUTHENTICATION METHOD REQUIRED for server '{server}'.\n"
                 + "Ask the user: \"Which authentication method should I use — 'windows' (Windows Integrated) or 'sql' (SQL Login)?\"\n"
                 + "Then call evaluate again with 'server' and 'authMethod' set.";

        // STEP 3b — SQL login username (password stays in the session environment, never in chat).
        if (method == "sql" && string.IsNullOrWhiteSpace(sqlUser))
            return $"STEP 3b — SQL LOGIN USERNAME REQUIRED for server '{server}'.\n"
                 + "Ask the user for the SQL login username. For security, the password must NOT be typed in chat: "
                 + "the user sets it once in their terminal session before launching VS Code "
                 + "(PowerShell: $env:SQLAUDITOR_SQL_PASSWORD='<password>'), and the server reads it at runtime.\n"
                 + "Then call evaluate again with 'server', authMethod='sql', and 'sqlUser' set.";

        // STEP 4 — Checklist items.
        if (string.IsNullOrWhiteSpace(items))
            return $"STEP 4 of 6 — CHECKLIST ITEMS REQUIRED.\n"
                 + $"Server '{server}' and authentication are set. Ask the user which checklist items to evaluate — a single ID ('1.2.1'), "
                 + "a list ('1.2.1,3.1.2'), an inclusive range ('1.1.1 - 2.1.4') or 'all'. "
                 + "If the user already provided items earlier in the conversation, use those instead of asking again.\n"
                 + "Then call evaluate again with 'server', 'authMethod', and 'items' set.";

        // Build the connection string from the chosen method. The SQL Login password
        // is read only from the environment, never passed through tool arguments.
        string connectionString;
        if (method == "sql")
        {
            var pass = Environment.GetEnvironmentVariable("SQLAUDITOR_SQL_PASSWORD");
            if (string.IsNullOrEmpty(pass))
                return $"STEP 3b \u2014 SQL PASSWORD NOT AVAILABLE for user '{sqlUser}' on server '{server}'.\n"
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

        // Resolve the item spec the same way generate_scripts does, so a range or 'all'
        // works here too and the run follows master-checklist order.
        var structure = await auditor.GetChecklistStructureAsync();
        var orderedIds = structure
            .SelectMany(s => s.Items)
            .Select(i => i.Id)
            .Where(id => !string.IsNullOrWhiteSpace(id))
            .ToList();
        var spec = items!.Trim();
        var wantsAll = spec == "*" || string.Equals(spec, "all", StringComparison.OrdinalIgnoreCase);

        var (resolved, unresolved) = wantsAll
            ? (orderedIds.ToList(), new List<string>())
            : ExpandChecklistIdSpec(spec, orderedIds);

        var unknown = unresolved.ToArray();
        var valid = resolved.ToArray();
        if (valid.Length == 0)
            return "Error: none of the requested checklist items could be resolved"
                 + (unknown.Length > 0 ? ". Unknown: " + string.Join(", ", unknown) : $": '{spec}' matched no checklist ID.")
                 + " Call load_checklist to look up valid IDs.";

        // STEP 5 — run automated evaluation (manual-only items resolve to NeedsReview).
        // Manual items with a reusable historical result are copied forward inside the engine
        // when the user chose Option 1, so they never reach the review queue below.
        // Reports are NOT generated here: the user is asked for them after the run.
        var results = await auditor.RunChecklistAsync(
            null, null, valid, cancellationToken,
            useHistoricalManualResults.Value,
            generateReports: false);

        var sb = new StringBuilder();
        if (unknown.Length > 0)
            sb.AppendLine("Skipped unknown IDs: " + string.Join(", ", unknown));

        if (useHistoricalManualResults.Value)
        {
            var historicalIds = HistoricalManualResultsStore.AvailableIds();
            var copied = results.Where(r => historicalIds.Contains(r.Id)
                                         && HistoricalManualResultsStore.IsManualTechnique(r.Technique)).ToList();
            sb.AppendLine(copied.Count > 0
                ? $"Copied from last runs ({copied.Count} item(s)): " + string.Join(", ", copied.Select(r => r.Id).OrderBy(i => i, StringComparer.OrdinalIgnoreCase))
                : "Copied from last runs (0 items): no reusable manual results were found, so every manual item was evaluated normally.");
            sb.AppendLine("Copied items already carry the reviewer's decision \u2014 do NOT generate manual steps, review them or enrich them again.");
        }

        sb.AppendLine($"Evaluated {results.Length} item(s):");
        foreach (var r in results.OrderBy(r => r.Id, StringComparer.OrdinalIgnoreCase))
            sb.AppendLine($"- [{r.Id}] {r.Outcome} ({r.Technique}) - {r.Description}");
        sb.AppendLine();
        sb.AppendLine("Summary (PROVISIONAL \u2014 script verdicts only):");
        foreach (var g in results.GroupBy(r => r.Outcome ?? "Unknown", StringComparer.OrdinalIgnoreCase)
                                  .OrderBy(g => g.Key, StringComparer.OrdinalIgnoreCase))
            sb.AppendLine($"  {g.Key}: {g.Count()}");
        sb.AppendLine("Not Applicable is decided during enrichment below, so these counts are NOT final. Do not present them as the");
        sb.AppendLine("result of the audit. Once every item has been enriched and reviewed, call 'show_reports' and report ITS counts,");
        sb.AppendLine("which include the Not Applicable items.");

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
            sb.AppendLine("  2. Ask the user for their DECISION: Pass or Fail. The verdict is the reviewer's to make — never infer,");
            sb.AppendLine("     assume, announce, question or challenge it, and never propose a different outcome.");
            sb.AppendLine("  3. Ask ONE follow-up question: what they inspected and what they found. Accept their answer as given.");
            sb.AppendLine("     Do NOT assess whether the evidence is sufficient, do NOT ask for extra detail, and do NOT argue that");
            sb.AppendLine("     the item should stay NeedsReview. Re-ask ONLY if they supplied no observation at all.");
            sb.AppendLine("  4. Immediately call 'resolve_review' with the user's decision and their exact words in 'notes'.");
            sb.AppendLine("  5. Then call 'enrich_result' for the same item with audit wording YOU derive from the user's evidence:");
            sb.AppendLine("     finding (the actual state they observed), evidence (why it supports the outcome), riskImpact (the specific");
            sb.AppendLine("     consequence) and recommendation (targeted remediation). Use ONLY facts the user stated — invent nothing.");
            sb.AppendLine("Two questions per item — decision, then evidence. Do NOT write a final summary until every item is resolved.");
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
                sb.AppendLine($"Ask for the Pass/Fail decision first, then the evidence, then call: resolve_review(id=\"{r.Id}\", decision=\"pass\" or \"fail\", notes=\"<the user's own observation/evidence, not just 'pass'>\")");
                sb.AppendLine($"Then call: enrich_result(id=\"{r.Id}\", finding=\"...\", evidence=\"...\", riskImpact=\"...\", recommendation=\"...\") derived from that evidence.");
            }
        }

        sb.AppendLine();
        var resultsDir = AuditOutputPaths.CurrentRunDirectory;
        sb.AppendLine($"Results written to {Path.Combine(resultsDir, "checklist_results.json")}.");
        sb.AppendLine();
        sb.AppendLine("=== REPORT GENERATION DECISION REQUIRED ===");
        sb.AppendLine("NO report has been generated. Once every item above is enriched and reviewed, ask the user:");
        sb.AppendLine("  \"Evaluation completed. Do you want to generate the summary/report?\"");
        sb.AppendLine("If YES: call generate_report() \u2014 it refreshes historical_last_run.json in this run directory with the newly evaluated");
        sb.AppendLine($"manual results, then writes {Path.Combine(resultsDir, "final_report.md")} and {Path.Combine(resultsDir, "audit_report.xlsx")}.");
        sb.AppendLine($"If NO: stop. Keep {Path.Combine(resultsDir, "checklist_results.json")}, do not refresh the historical file, and do not generate");
        sb.AppendLine("the report or the workbook. Never make this decision yourself.");
        sb.AppendLine("=== END REPORT GENERATION DECISION REQUIRED ===");
        return sb.ToString();
    }

    [McpServerTool(Name = "generate_report")]
    [Description("Generate the final audit outputs after the user has explicitly asked for them: refreshes historical_last_run.json with the newly evaluated manual/AI-Manual results from checklist_results.json, then writes final_report.md and audit_report.xlsx in the active timestamp-and-server run directory. Call ONLY after the user answers yes to 'Evaluation completed. Do you want to generate the summary/report?'. Never call it on your own initiative.")]
    public static Task<string> GenerateReportAsync(
        [Description("Set to false to render the reports without recording the new manual results in results/historical_last_run.json. Defaults to true.")] bool refreshHistoricalManualResults = true)
    {
        var jsonPath = AuditOutputPaths.GetCurrentFilePath("checklist_results.json");
        if (!File.Exists(jsonPath))
            return Task.FromResult($"No results found at {jsonPath}. Run 'evaluate' first.");

        var message = Auditor.GenerateReports(refreshHistoricalManualResults);
        var tally = Auditor.BuildOutcomeTally();
        return Task.FromResult(
            message
            + (string.IsNullOrEmpty(tally) ? string.Empty : $"\nFinal outcome counts: {tally}")
            + $"\nCall 'show_reports' to display {AuditOutputPaths.GetCurrentFilePath("final_report.md")} and report ITS counts.");
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
    [Description("GENERATE deterministic audit SCRIPTS for checklist items — this is NOT evaluation and needs no SQL Server or credentials. Use this whenever the user asks to 'generate scripts', 'create scripts', or 'write audit scripts' for one or more checklist IDs (including the /generateScript command). 'items' accepts a single ID ('1.1.2'), a comma-separated list ('1.1.2,3.1.1') or an inclusive range in checklist order ('1.1.1 - 2.1.4'). Items are served ONE BATCH OF 10 AT A TIME, exactly like the WPF app: this call returns only the current batch, and you call it again with the SAME 'items' and batch+1 once every item in the batch is finished. In the default mode='subagent' it returns a dispatch manifest and you launch one 'sql-script-generator' subagent per item, each owning its full generate/validate/save loop in its own session — the closest match to the WPF app's 10 independent LLM sessions. mode='inline' instead returns the generator prompt plus every per-item request for you to author in this conversation. Existing scripts and mapping entries for the same ID are overwritten. Never call 'evaluate' for a script-generation request.")]
    public static async Task<string> GenerateScriptsAsync(
        [Description("Checklist IDs to generate scripts for: a single ID ('1.1.2'), a comma-separated list ('1.1.2,3.1.1'), or an inclusive range in checklist order ('1.1.1 - 2.1.4'). Pass the SAME value unchanged on every batch call. If missing, ask the user which checklist IDs to generate scripts for.")] string? items = null,
        [Description("1-based batch number. One batch of 10 items is processed at a time, mirroring the WPF flow. Omit or pass 1 for the first batch, then call again with batch=2, 3, ... after every item in the previous batch has finished.")] int batch = 1,
        [Description("'subagent' (default) returns a fan-out manifest: launch one 'sql-script-generator' subagent per item, each owning the full loop in its own session. 'inline' returns the generator prompt and every per-item request so the calling conversation writes the scripts itself — use it as a fallback when subagents are unavailable, or for a very small batch you want to watch.")] string? mode = null,
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
        {
            var done = new StringBuilder();
            done.AppendLine($"ALL BATCHES COMPLETE for '{spec}'. {requestedIds.Count} item(s) fit into "
                          + $"{totalBatches} batch(es) of {GenerationBatchSize}; batch {batch} does not exist.");
            done.AppendLine();
            done.Append(DescribeGenerationStatus(requestedIds, "Recorded outcome for every requested item"));
            done.AppendLine();
            done.AppendLine("Report these totals to the user (generated / not feasible / not recorded) and stop — "
                          + "do not call generate_scripts again. Any item shown as NOT RECORDED never reached "
                          + "save_generated_script: re-run just that ID before reporting success.");
            return done.ToString();
        }

        var batchIds = requestedIds
            .Skip((batch - 1) * GenerationBatchSize)
            .Take(GenerationBatchSize)
            .ToList();

        var (checklistItems, unknown) = await ScriptGenerationSkill.LoadItemsAsync(batchIds);
        if (checklistItems.Count == 0)
            return "Error: none of the checklist IDs in this batch exist. Unknown: " + string.Join(", ", unknown);

        var inline = string.Equals(mode?.Trim(), "inline", StringComparison.OrdinalIgnoreCase);

        var sb = new StringBuilder();
        sb.AppendLine($"=== SCRIPT GENERATION — BATCH {batch} OF {totalBatches} ({checklistItems.Count} item(s)) "
                    + $"— {(inline ? "INLINE" : "SUBAGENT")} MODE ===");
        sb.AppendLine($"Requested: {spec}");
        sb.AppendLine($"Resolved {requestedIds.Count} checklist item(s) in checklist order: {string.Join(", ", requestedIds)}");
        if (unresolved.Count > 0)
            sb.AppendLine("Not found in the checklist and skipped: " + string.Join(", ", unresolved));

        // Each batch reports the previous one, so a silently dropped item surfaces immediately.
        if (batch > 1)
        {
            var previousIds = requestedIds
                .Skip((batch - 2) * GenerationBatchSize)
                .Take(GenerationBatchSize)
                .ToList();

            sb.AppendLine();
            sb.Append(DescribeGenerationStatus(previousIds, $"Outcome of batch {batch - 1}"));
            sb.AppendLine("Any item above shown as NOT RECORDED was never saved — re-run that single ID before "
                        + "continuing with this batch.");
        }

        var alreadyGenerated = DescribeExistingScripts(batchIds);
        if (alreadyGenerated.Length > 0)
        {
            sb.AppendLine();
            sb.AppendLine($"Already generated and WILL BE OVERWRITTEN on save: {alreadyGenerated}. "
                        + "Generate them again from scratch — do not skip them and do not reuse the old content.");
        }

        sb.AppendLine();
        if (inline)
        {
            sb.AppendLine($"Generate ONLY the {checklistItems.Count} item(s) in this batch yourself. "
                        + "Do not start the next batch until every item here has been saved.");
            sb.AppendLine();
            sb.Append(ScriptGenerationSkill.BuildGenerationInstructions(
                checklistItems,
                unknown,
                "call save_generated_script(checklistId=\"<id>\", response=\"<full raw generator output>\")"));
        }
        else
        {
            sb.Append(BuildSubagentDispatch(batchIds));
        }

        sb.AppendLine();
        sb.AppendLine($"=== END OF BATCH {batch} OF {totalBatches} ===");
        if (batch < totalBatches)
        {
            var nextCount = Math.Min(GenerationBatchSize, requestedIds.Count - (batch * GenerationBatchSize));
            sb.AppendLine($"After ALL {checklistItems.Count} item(s) above are finished (saved, recorded as NOT "
                        + $"FEASIBLE, or failed), continue with the next {nextCount} item(s) by calling:");
            sb.AppendLine($"    generate_scripts(items=\"{spec}\", batch={batch + 1}{(inline ? ", mode=\"inline\"" : "")})");
            sb.AppendLine("Pass 'items' unchanged so the batches stay aligned. Do not stop or summarise before the last batch.");
        }
        else
        {
            sb.AppendLine("This is the FINAL batch. Once every item here is finished, confirm the recorded outcomes "
                        + $"by calling generate_scripts(items=\"{spec}\", batch={batch + 1}), then report the totals and stop.");
        }

        return sb.ToString();
    }

    /// <summary>
    /// Fan-out instructions for one batch: one <c>sql-script-generator</c> subagent per item,
    /// each owning the full generate/validate/save loop in its own session. This is the IDE
    /// equivalent of the concurrent, independent <c>ProcessItemAsync</c> tasks in the WPF flow.
    /// </summary>
    private static string BuildSubagentDispatch(IReadOnlyList<string> batchIds)
    {
        var sb = new StringBuilder();
        sb.AppendLine("## HOW TO PROCESS THIS BATCH — SUBAGENT FAN-OUT");
        sb.AppendLine($"Do NOT write these {batchIds.Count} scripts yourself and do NOT read the generator prompt.");
        sb.AppendLine($"Launch ONE '{GeneratorAgentName}' subagent per item, ALL IN A SINGLE MESSAGE so they run");
        sb.AppendLine("concurrently in independent sessions — the IDE equivalent of the WPF app generating the 10");
        sb.AppendLine("items of a batch in 10 separate LLM sessions.");
        sb.AppendLine();
        sb.AppendLine("Each subagent owns the FULL loop for its ONE item and reports back a single status line:");
        sb.AppendLine("  get_item_generation_prompt -> author the raw response -> save_generated_script (format gate)");
        sb.AppendLine("  -> C1-C7 review -> save_generated_script with the verdict -> retry up to 3 times.");
        sb.AppendLine();
        sb.AppendLine("Dispatch exactly these calls, together, now:");
        foreach (var id in batchIds)
        {
            sb.AppendLine($"  runSubagent(agentName=\"{GeneratorAgentName}\", description=\"Generate script {id}\", "
                        + $"prompt=\"Generate and save the SQL Auditor audit script for checklist item {id}. "
                        + $"Follow your agent contract exactly: start by calling get_item_generation_prompt(checklistId=\\\"{id}\\\").\")");
        }
        sb.AppendLine();
        sb.AppendLine("While in this mode you must NOT call get_item_generation_prompt, validate_generated_script or");
        sb.AppendLine("save_generated_script yourself — the subagents do. Your only jobs are dispatching the batch,");
        sb.AppendLine("collecting the status lines, and advancing to the next batch.");
        sb.AppendLine("If the subagents cannot be launched at all, fall back to this same batch with mode=\"inline\".");
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

    /// <summary>
    /// Reports what execution-results.json actually recorded for the given IDs. Subagent
    /// transcripts are not visible to the orchestrator, so this is how a batch is verified:
    /// an item that never reached save_generated_script shows as NOT RECORDED.
    /// </summary>
    private static string DescribeGenerationStatus(IReadOnlyList<string> ids, string heading)
    {
        var recorded = ReadGenerationStatus();

        var sb = new StringBuilder();
        sb.AppendLine($"## {heading}");
        foreach (var id in ids)
            sb.AppendLine($"  {id} — {(recorded.TryGetValue(id, out var s) ? s : "NOT RECORDED")}");

        return sb.ToString();
    }

    private static Dictionary<string, string> ReadGenerationStatus()
    {
        var recorded = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);

        try
        {
            var path = Path.Combine(ScriptGenerationSkill.ResolveBasePath(), "results", "execution-results.json");
            if (!File.Exists(path)) return recorded;

            using var doc = JsonDocument.Parse(File.ReadAllText(path));
            if (!doc.RootElement.TryGetProperty("results", out var results)
                || results.ValueKind != JsonValueKind.Array)
                return recorded;

            foreach (var entry in results.EnumerateArray())
            {
                var id = Text(entry, "ChecklistId");
                if (string.IsNullOrWhiteSpace(id)) continue;

                var status = Text(entry, "Status");
                var scriptPath = Text(entry, "ScriptPath");
                var reason = Text(entry, "Reason");

                var detail = scriptPath.Length > 0
                    ? $" ({scriptPath})"
                    : reason.Length > 0
                        ? $" ({(reason.Length > 120 ? reason[..120] + "…" : reason)})"
                        : string.Empty;

                recorded[id] = (status.Length > 0 ? status : "Recorded") + detail;
            }
        }
        catch
        {
            // A missing or malformed results file just means nothing can be confirmed.
        }

        return recorded;

        static string Text(JsonElement element, string property) =>
            element.TryGetProperty(property, out var value) && value.ValueKind == JsonValueKind.String
                ? value.GetString() ?? string.Empty
                : string.Empty;
    }

    [McpServerTool(Name = "get_item_generation_prompt")]
    [Description("Return the generator system prompt plus the filled request for ONE checklist item, built from Backend/agents/prompts/script_generator_system.txt and script_generator_user.txt. This is the entry point for the 'sql-script-generator' subagent: it fetches its own item's prompt here instead of receiving it second-hand, so the canonical templates are never paraphrased. Author the raw response from what this returns, then save it with 'save_generated_script'. Needs no SQL Server and no credentials.")]
    public static async Task<string> GetItemGenerationPromptAsync(
        [Description("The single checklist item ID to generate a script for, e.g. '1.1.2'.")] string checklistId,
        CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(checklistId))
            return "Error: 'checklistId' is required.";

        var (checklistItems, unknown) = await ScriptGenerationSkill.LoadItemsAsync(new[] { checklistId });
        if (checklistItems.Count == 0)
            return $"Error: checklist ID '{checklistId.Trim()}' does not exist. "
                 + "Use 'load_checklist' to discover valid IDs. Do not invent a checklist item.";

        var item = checklistItems[0];

        var sb = new StringBuilder();
        sb.AppendLine($"=== SINGLE-ITEM SCRIPT GENERATION — [{item.ChecklistId}] ===");
        sb.AppendLine("This request contains EXACTLY ONE item. Ignore any batching guidance in the text below —");
        sb.AppendLine("batching is handled by the orchestrator, not by you.");

        var alreadyGenerated = DescribeExistingScripts(new[] { item.ChecklistId });
        if (alreadyGenerated.Length > 0)
            sb.AppendLine($"A script already exists for this item ({alreadyGenerated}) and WILL BE OVERWRITTEN when "
                        + "you save. Generate it again from scratch — do not read or reuse the old content.");

        sb.AppendLine();
        sb.Append(ScriptGenerationSkill.BuildGenerationInstructions(
            checklistItems,
            unknown,
            $"call save_generated_script(checklistId=\"{item.ChecklistId}\", response=\"<full raw generator output>\")"));

        return sb.ToString();
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
    [Description("Save one script YOU generated for a checklist item (used after 'generate_scripts' or 'get_item_generation_prompt'). Provide the checklist ID and the COMPLETE raw generator response (all fields plus the script between ---SCRIPT_START--- and ---SCRIPT_END---). Called without 'validationVerdict' it runs the format gate and returns the standard C1-C7 validation prompt instead of saving. Perform that review, then call again passing the verdict ('VERDICT: VALID', or 'VERDICT: INVALID' with ISSUES and the corrected script between ---CORRECTED_SCRIPT_START--- and ---CORRECTED_SCRIPT_END---). On success it writes the script file and updates Backend/checklist/deterministic-script-mapping.json and Backend/results/execution-results.json. Writes are serialised, so parallel subagents can each call this safely. If it returns a validation error, correct the script and call again (retry up to 3 times).")]
    public static async Task<string> SaveGeneratedScriptAsync(
        [Description("The checklist item ID this script belongs to, e.g. '1.1.2'.")] string checklistId,
        [Description("The COMPLETE raw generator output for this item: the FEASIBLE/SCRIPT_TYPE/SCOPE/SCRIPT_NAME/SCORING_LOGIC fields and the script between ---SCRIPT_START--- and ---SCRIPT_END--- markers.")] string response,
        [Description("The verdict from the C1-C7 review, in the validation template's response format. Omit on the first call to receive the validation prompt.")] string? validationVerdict = null,
        CancellationToken cancellationToken = default)
    {
        // Serialised because the mapping and execution-results files are read-modify-write and
        // subagent mode has up to 10 items saving at once.
        await SaveGate.WaitAsync(cancellationToken);
        try
        {
            return await ScriptGenerationSkill.SaveGeneratedScriptAsync(
                checklistId,
                response,
                validationVerdict,
                SaveWithVerdictHint,
                cancellationToken);
        }
        finally
        {
            SaveGate.Release();
        }
    }

    [McpServerTool(Name = "show_reports")]
    [Description("Return the most recently generated audit output from the latest timestamp-and-server run directory: 'summary' for final_report.md (default) or 'json' for checklist_results.json.")]
    public static Task<string> ShowReportsAsync(
        [Description("'summary' for the Markdown report (default) or 'json' for the raw results.")] string kind = "summary")
    {
        var resultsDir = AuditOutputPaths.CurrentRunDirectory;
        var path = string.Equals(kind, "json", StringComparison.OrdinalIgnoreCase)
            ? Path.Combine(resultsDir, "checklist_results.json")
            : Path.Combine(resultsDir, "final_report.md");

        if (!File.Exists(path))
            return Task.FromResult($"No report found at {path}. Run 'evaluate' first.");

        var tally = Auditor.BuildOutcomeTally();
        return Task.FromResult(
            (string.IsNullOrEmpty(tally) ? string.Empty : $"Final outcome counts (after enrichment and review): {tally}\n\n")
            + File.ReadAllText(path));
    }

    [McpServerTool(Name = "resolve_review")]
    [Description("Mark a checklist item that came back as NeedsReview with a human decision of pass or fail (or needsreview). Requires the reviewer's own observation/evidence text for pass and fail decisions. Updates checklist_results.json and regenerates final_report.md and audit_report.xlsx in the current run directory. Use after 'evaluate' surfaces manual-review items.")]
    public static Task<string> ResolveReviewAsync(
        [Description("The checklist item ID to resolve, e.g. '3.1.1'.")] string id,
        [Description("The decision: 'pass', 'fail', or 'needsreview'.")] string decision,
        [Description("The reviewer's observation/evidence in their own words: what they inspected and what they found (document names, settings, values, counts). Required for 'pass' and 'fail'. A bare 'pass'/'fail' is not acceptable evidence.")] string? notes = null)
    {
        if (string.IsNullOrWhiteSpace(id))
            return Task.FromResult("Error: 'id' is required.");
        if (string.IsNullOrWhiteSpace(decision))
            return Task.FromResult("Error: 'decision' is required (pass, fail, or needsreview).");

        // The reviewer's own words are the evidence of record, so a decision cannot be
        // filed without them.
        var isDecision = decision.Trim().ToLowerInvariant() is "pass" or "p" or "yes" or "y" or "fail" or "f" or "no" or "n";
        if (isDecision && !IsUsableEvidence(notes))
            return Task.FromResult(
                $"Error: 'notes' must contain the reviewer's actual observation for [{id}] — what they checked and what they found. "
                + "Ask the user for the evidence behind their decision and call resolve_review again with it.");

        var auditor = new Auditor(string.Empty);
        if (auditor.ResolveReview(id, decision, notes, out var newOutcome))
            return Task.FromResult(
                $"Updated [{id}] -> {newOutcome}. Outputs regenerated in {AuditOutputPaths.CurrentRunDirectory}. "
                + $"NEXT: call enrich_result(id=\"{id}\", ...) with audit wording you derive from the reviewer's evidence above — finding, evidence, riskImpact and recommendation — using only facts the reviewer stated.");

        return Task.FromResult(
            $"Could not resolve '{id}'. Ensure 'evaluate' has run (results file exists), the ID is present, and decision is pass/fail/needsreview.");
    }

    // A restatement of the verdict carries no information about what was inspected.
    private static bool IsUsableEvidence(string? notes)
    {
        if (string.IsNullOrWhiteSpace(notes)) return false;
        var trimmed = notes.Trim().Trim('.', '!', ' ').ToLowerInvariant();
        return trimmed is not ("pass" or "passed" or "fail" or "failed" or "p" or "f"
            or "yes" or "no" or "y" or "n" or "ok" or "okay" or "good" or "bad" or "n/a");
    }

    [McpServerTool(Name = "enrich_result")]
    [Description("Record the audit wording YOU authored for a script-evaluated checklist item, using only the facts the script returned. Sets Finding, Evidence, RiskImpact and Recommendation in checklist_results.json and regenerates final_report.md and audit_report.xlsx in the current run directory. Outcome, Score, Severity and Databases Verified are script-derived and cannot be changed here, with one exception: when the script result held no supporting artefact at all and your evidence therefore starts with 'Not Applicable.', the item is re-stamped Outcome 'Not Applicable' and excluded from every score. Use after 'evaluate' lists items in its COPILOT ENRICHMENT REQUIRED block.")]
    public static Task<string> EnrichResultAsync(
        [Description("The checklist item ID to enrich, e.g. '1.1.5'.")] string id,
        [Description("1-2 sentences on the actual state the script found (object/database names, counts). Not a restatement of the checklist description.")] string? finding = null,
        [Description("How the finding justifies the outcome, quoting the values the script returned. Under 120 words. When every value the script returned is absent (NULL, empty, zero or 'not found'), the control does not exist to be assessed: start with the exact words 'Not Applicable.' followed by one sentence of your own reasoning. A zero that itself proves compliance is real evidence, not 'Not Applicable'.")] string? evidence = null,
        [Description("The specific business/security/operational consequence of this finding. Under 50 words.")] string? riskImpact = null,
        [Description("Remediation targeted at this gap, consistent with the score. Omit when the score is 3 and the outcome is Pass.")] string? recommendation = null)
    {
        if (string.IsNullOrWhiteSpace(id))
            return Task.FromResult("Error: 'id' is required.");

        var auditor = new Auditor(string.Empty);
        if (auditor.ApplyEnrichment(id, finding, evidence, riskImpact, recommendation, out var markedNotApplicable))
            return Task.FromResult(
                $"Enriched [{id}]"
                + (markedNotApplicable
                    ? $" -> Outcome {NotApplicableEvidence.Outcome}: the evidence declares the control not applicable, so the item is excluded from every score and listed on the 'Not Applicable Items' sheet. Report it as Not Applicable, not as Pass or Fail."
                    : ".")
                + $" Outputs regenerated in {AuditOutputPaths.CurrentRunDirectory}.");

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
      + "items to evaluate. Pass what I type for the items straight through — the tool resolves a single ID "
      + "('1.1.2'), a list ('1.1.2,3.1.1'), an inclusive range ('1.1.1 - 2.1.4') and 'all'. "
      + "Never guess the server or credentials. "
      + "For every item listed in the COPILOT ENRICHMENT REQUIRED block, author the finding, evidence, "
      + "risk impact and recommendation from the script result shown there and record them with 'enrich_result'. "
      + "For any item that comes back as Needs Review, show its verification guidance, help me decide "
      + "Pass or Fail, and record each decision with the 'resolve_review' tool. "
      + "The counts 'evaluate' prints are provisional — Not Applicable is decided during enrichment — so when "
      + "everything is resolved, show the final summary with 'show_reports' and report ITS counts. "
      + "Do not perform the evaluation yourself or duplicate its logic — always use the tools.";

    [McpServerPrompt(Name = "generate_scripts")]
    [Description("Generate deterministic audit scripts for checklist items using the sql-auditor MCP tools (not evaluation).")]
    public static string GenerateScripts() =>
        "Generate audit scripts (do NOT evaluate) using the sql-auditor MCP tools. "
      + "Ask me which checklist item IDs to generate scripts for — a single ID ('1.1.2'), a list "
      + "('1.1.2,3.1.1') or an inclusive range ('1.1.1 - 2.1.4') — then call the 'generate_scripts' tool "
      + "with that value as 'items' and batch=1. "
      + "This is script generation only — do not call 'evaluate', do not connect to a SQL Server, and do not ask "
      + "for a server name or credentials. "
      + "The tool serves ONE BATCH OF 10 ITEMS AT A TIME and defaults to subagent mode: for each batch it returns "
      + "a dispatch manifest, and you launch one 'sql-script-generator' subagent per item, all in a single message "
      + "so they run in independent sessions. Each subagent owns its item's whole loop — fetching the prompt, "
      + "writing the script, running the C1-C7 review, saving, and retrying up to 3 times — and reports one status "
      + "line back. Do not write the scripts yourself in that mode. Only after every subagent in the batch has "
      + "returned, call 'generate_scripts' again with the SAME 'items' and the next batch number, until the tool "
      + "reports the final batch; then call it once more to confirm the recorded outcomes. "
      + "If subagents cannot be launched, re-request the same batch with mode=\"inline\" and generate the scripts "
      + "yourself, following the generator system prompt the tool returns. "
      + "Scripts and mapping entries for IDs that already have one are overwritten, so never skip an item because "
      + "a script already exists.";
}