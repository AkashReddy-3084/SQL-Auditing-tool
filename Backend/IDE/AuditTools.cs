using System.ComponentModel;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using ModelContextProtocol.Server;
using SQLAuditor.Lib;
using SqlAuditor.Reporting;

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
    // Custom-checklist writes are read-modify-write across several files, so persistence is
    // serialised across every caller of this server.
    private static readonly SemaphoreSlim SaveGate = new(1, 1);

    /// <summary>
    /// Accepts a single ID (<c>1.1.2</c>), a list (<c>1.1.2,3.1.1</c>) and an inclusive
    /// range in checklist order (<c>1.1.1 - 2.1.4</c>, <c>1.1.1 to 2.1.4</c>).
    /// </summary>
    private static readonly Regex ChecklistIdSpecPattern = new(
        @"(?<start>\d+(?:\.\d+)*)\s*(?:-|–|—|\.\.|to|through)\s*(?<end>\d+(?:\.\d+)*)|(?<single>\d+(?:\.\d+)*)",
        RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);

    [McpServerTool(Name = "evaluate")]
    [Description("Evaluate SQL audit checklist items following the standard workflow, identical to the CLI and the desktop app: (1) how manual items are handled (reuse the last runs or evaluate fresh), (2) SQL Server name, (3) authentication method, (4) checklist items, (4b) which user databases to audit, (5) automated + manual verification, (6) summary. ALWAYS call this tool to begin an evaluation. When a required input is missing it returns the exact next question to ask the user; ask that question and call evaluate again with the answer plus everything gathered so far. Never guess the server, the credentials, the database scope or the manual-results choice, and never run the evaluation before the server name has been supplied by the user. Writes checklist_results.json and the complete report suite in a timestamp-and-server run directory under results.")]
    public static Task<string> EvaluateAsync(
        [Description("STEP 1: How manual/AI-Manual checklist items are handled — 'last-runs' to copy the results recorded in results/historical_last_run.json, or 'fresh' to evaluate every manual item again. This MUST come from the user; never choose it yourself. Call with it empty to get the exact question to ask.")] string? manualResults = null,
        [Description("STEP 2: SQL Server name/host[,port]. REQUIRED and must come from the user. If you don't have it yet, call with server empty to get the exact prompt to show the user.")] string? server = null,
        [Description("STEP 3: Authentication method — 'windows' for Windows Integrated, or 'sql' for SQL Login.")] string? authMethod = null,
        [Description("STEP 3b: SQL login username (only when authMethod='sql'). The password is NOT passed here; it is read at runtime from the SQLAUDITOR_SQL_PASSWORD session environment variable and must NEVER be typed in chat.")] string? sqlUser = null,
        [Description("STEP 4: The checklist items to evaluate. Accepts a single ID ('1.2.1'), a comma-separated list ('1.2.1,3.1.2'), an inclusive range in checklist order ('1.1.1 - 2.1.4') or 'all'. Pass what the user typed verbatim; this tool resolves it. If the user already named items earlier, reuse them here.")] string? items = null,
        [Description("STEP 4b: Which user databases the database-scoped checks run against — a comma-separated list of database names ('Sales,Warehouse') or 'all' for every accessible user database. This MUST come from the user, exactly as the desktop app asks. Call with it empty to get the list of databases on the instance to present to the user.")] string? databases = null,
        CancellationToken cancellationToken = default)
        => EvaluateCoreAsync(manualResults, server, authMethod, sqlUser, items, databases,
                             reuseActiveRunDirectory: false, targetDatabases: null, cancellationToken);

    // Shared core used by both `evaluate` (fresh run) and `rerun_evaluation` (same folder).
    // `databaseSpec` is what the user typed; `targetDatabases` is an already-resolved scope
    // (used by rerun, which replays the databases stored in the run metadata).
    private static async Task<string> EvaluateCoreAsync(
        string? manualResults,
        string? server,
        string? authMethod,
        string? sqlUser,
        string? items,
        string? databaseSpec,
        bool reuseActiveRunDirectory,
        string[]? targetDatabases,
        CancellationToken cancellationToken)
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

        // STEP 4b — database scope. The desktop app makes the user pick the databases, so the
        // IDE must ask too: auditing every database (including system databases) silently
        // changes the Pass/Fail/Not Applicable counts for database-scoped checks.
        if (targetDatabases == null)
        {
            string[] availableDatabases;
            try
            {
                availableDatabases = await auditor.GetAvailableDatabasesAsync(cancellationToken);
            }
            catch (Exception ex)
            {
                return $"Error: could not connect to '{server}' to list its databases: {ex.Message}\n"
                     + "Check the server name, the authentication method and that the login has access, then call evaluate again.";
            }

            if (availableDatabases.Length == 0)
                return $"Error: no accessible user database was found on '{server}'.\n"
                     + "Database-scoped checks cannot run. Confirm with the user that the login can see the databases to audit.";

            if (string.IsNullOrWhiteSpace(databaseSpec))
                return "STEP 4b of 6 — DATABASE SELECTION REQUIRED.\n"
                     + $"Ask the user which of these user databases on '{server}' should be audited — never choose for them:\n"
                     + string.Join("\n", availableDatabases.Select(name => "  - " + name)) + "\n"
                     + "They may pick one, several (comma-separated) or all of them.\n"
                     + "Then call evaluate again with everything already gathered plus databases='<names>' or databases='all'.\n"
                     + "System databases (master, model, msdb, tempdb) are never audit targets and are not offered.";

            var databaseInput = databaseSpec.Trim();
            if (string.Equals(databaseInput, "all", StringComparison.OrdinalIgnoreCase) || databaseInput == "*")
            {
                targetDatabases = availableDatabases;
            }
            else
            {
                var requested = databaseInput
                    .Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
                    .Distinct(StringComparer.OrdinalIgnoreCase)
                    .ToArray();
                var unknownDatabases = requested
                    .Where(name => !availableDatabases.Contains(name, StringComparer.OrdinalIgnoreCase))
                    .ToArray();
                if (requested.Length == 0 || unknownDatabases.Length > 0)
                    return "STEP 4b of 6 — DATABASE SELECTION INVALID.\n"
                         + (unknownDatabases.Length > 0
                                ? "Not on this instance (or not accessible to this login): " + string.Join(", ", unknownDatabases) + "\n"
                                : "No database name was recognised in the answer.\n")
                         + $"Available user databases on '{server}':\n"
                         + string.Join("\n", availableDatabases.Select(name => "  - " + name)) + "\n"
                         + "Ask the user to choose from this list, then call evaluate again with databases='<names>' or databases='all'.";

                // Keep the instance's own casing so the run metadata matches the desktop app.
                targetDatabases = availableDatabases
                    .Where(name => requested.Contains(name, StringComparer.OrdinalIgnoreCase))
                    .ToArray();
            }
        }

        // Resolve the item spec so a range or 'all' works here too and the run follows
        // master-checklist order.
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
        // Generate the complete report suite from this run's persisted results.
        // Record the server/auth so this run can be rerun or edited later.
        auditor.LastRunInputs = new RunInputs
        {
            Fqdn = server,
            AuthMethod = method == "sql" ? "SQL Login" : "Windows Authentication",
            SqlUser = method == "sql" ? sqlUser : null,
        };

        var results = await auditor.RunChecklistAsync(
            null, null, valid, cancellationToken,
            useHistoricalManualResults.Value,
            generateReports: true, targetDatabases: targetDatabases,
            reuseActiveRunDirectory: reuseActiveRunDirectory);

        var sb = new StringBuilder();
        if (unknown.Length > 0)
            sb.AppendLine("Skipped unknown IDs: " + string.Join(", ", unknown));

        if (targetDatabases is { Length: > 0 })
            sb.AppendLine($"Database-scoped checks ran against {targetDatabases.Length} user database(s): " + string.Join(", ", targetDatabases));

        if (auditor.LastDetectedPlatform is { } detectedPlatform
            && detectedPlatform.Platform != PlatformApplicability.PlatformUnknown)
        {
            sb.AppendLine($"Detected platform: {detectedPlatform.Display} (EngineEdition {detectedPlatform.EngineEdition}).");
            if (auditor.LastPlatformExclusionCount > 0)
                sb.AppendLine($"{auditor.LastPlatformExclusionCount} item(s) recorded as Not Applicable to this platform \u2014 no script ran and no model was called for them.");
        }

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
            sb.AppendLine("This MCP server performs NO AI/LLM calls — YOU (GitHub Copilot) are the reviewer. The manual review is CSV-based:");
            sb.AppendLine("  1. FIRST ask the user which they want — do NOT export or import anything until they answer:");
            sb.AppendLine("       (a) IMPORT an already-filled CSV they have (for example one they filled during a previous run), or");
            sb.AppendLine("       (b) EXPORT a fresh CSV to fill in now.");
            sb.AppendLine("     If they choose (a): ask for the file path and call 'import_manual_csv' with it. A CSV from an earlier run");
            sb.AppendLine("     works because rows are matched by 'Checklist ID'; rows for items not in this run are simply ignored. Do");
            sb.AppendLine("     NOT export a new CSV in this case.");
            sb.AppendLine("     If they choose (b): call 'export_manual_csv'. It writes EVERY manual item, with its verification steps");
            sb.AppendLine("     already in the 'Manual Steps' column, to one CSV. Give the user ONLY the file path and a one-line");
            sb.AppendLine("     instruction — do NOT paste the steps, a Pass/Fail rubric or any per-item guidance into the chat; the steps");
            sb.AppendLine("     live in the CSV. Tell the user to open it and, for each row, enter Pass or Fail in the 'Decision' column");
            sb.AppendLine("     and what they inspected and found in the 'Evidence' column, leaving 'Checklist ID' unchanged. The verdict is");
            sb.AppendLine("     the reviewer's to make — never infer, assume, announce, question or challenge it, or propose a different outcome.");
            sb.AppendLine("  2. When they give you a filled CSV (whether an existing one or the one just exported), call 'import_manual_csv'");
            sb.AppendLine("     with its path to apply every decision at once. Accept their entries as given: do NOT assess whether the");
            sb.AppendLine("     evidence is sufficient, do NOT ask for extra detail, and do NOT argue that an item should stay NeedsReview.");
            sb.AppendLine("     Report back only the rows the import flagged. Do NOT ask for these decisions one item at a time, and do NOT");
            sb.AppendLine("     call resolve_review for them — the CSV is the manual workflow. Use resolve_review only to correct a single");
            sb.AppendLine("     item afterwards, or to record 'notapplicable' when the user reports a control does not exist on this server");
            sb.AppendLine("     at all (excluded from every score, and it needs no enrich_result call). A zero that itself proves compliance is a Pass, not this.");
            sb.AppendLine("  3. Then call 'enrich_result' for each applied item with audit wording YOU derive from the user's evidence:");
            sb.AppendLine("     finding (the actual state they observed), evidence (why it supports the outcome), riskImpact (the specific");
            sb.AppendLine("     consequence) and recommendation (targeted remediation). Use ONLY facts the user stated — invent nothing.");
            sb.AppendLine("Only if the user explicitly asks to see a specific item's steps, show that one item using this format");
            sb.AppendLine("(Checklist / Objective / Manual Verification Steps / What indicates a PASS and a FAIL / Recommended Actions).");
            sb.AppendLine("Do NOT write a final summary until the CSV has been imported and every applied item is enriched.");
            foreach (var r in manualPending)
            {
                sb.AppendLine();
                sb.AppendLine($"--- {r.Id}: {r.Description} ---");
                if (itemLookup.TryGetValue(r.Id, out var it))
                {
                    if (!string.IsNullOrWhiteSpace(it.Category)) sb.AppendLine($"Area/Category: {it.Category}");
                    if (!string.IsNullOrWhiteSpace(it.Verification)) sb.AppendLine($"Verification objective: {it.Verification}");
                }
                sb.AppendLine("This item is a row in the manual CSV; its verification steps are in the CSV's 'Manual Steps' column.");
                sb.AppendLine("Do NOT paste those steps into the chat and do NOT collect its decision through a per-item resolve_review call.");
            }
        }

        sb.AppendLine();
        var resultsDir = AuditOutputPaths.CurrentRunDirectory;
        sb.AppendLine($"Results written to {Path.Combine(resultsDir, "checklist_results.json")}.");
        sb.AppendLine();
        sb.AppendLine("Report suite generated in the same run directory:");
        foreach (var fileName in ReportSuiteGenerator.FileNames)
            sb.AppendLine($"- {fileName}");
        sb.AppendLine();
        sb.AppendLine("FINAL STEP \u2014 once every item above is resolved and enriched, ASK the user whether to generate the final report. "
            + "Only when they confirm, call generate_report \u2014 that step refreshes historical_last_run.json. Never generate it silently.");
        return sb.ToString();
    }

    [McpServerTool(Name = "list_evaluations")]
    [Description("List the most recent evaluation runs across all servers (newest first), each with an index, server, date, score, item count, status and run directory. Use an index with rerun_evaluation to redo one in place.")]
    public static Task<string> ListEvaluationsAsync(
        [Description("How many recent runs to list. Defaults to 5.")] int count = 5)
    {
        if (count <= 0) count = 5;
        var runs = PreviousEvaluationStore.FindRecentAcrossServers(count);
        if (runs.Count == 0)
            return Task.FromResult("No previous evaluation runs were found under the results/ folder.");

        var sb = new StringBuilder();
        sb.AppendLine($"{runs.Count} most recent evaluation run(s) across all servers:");
        for (int i = 0; i < runs.Count; i++)
        {
            var r = runs[i];
            var m = r.Metadata;
            sb.AppendLine();
            sb.AppendLine($"[{i + 1}] {m.ServerName} \u2014 {r.EvaluatedDisplay} \u2014 {r.ScoreDisplay}");
            sb.AppendLine($"    Items: {m.ItemCount}   Status: {m.Status}   Duration: {r.DurationDisplay}");
            sb.AppendLine($"    Run: {r.RunDirectory}");
        }
        sb.AppendLine();
        sb.AppendLine("Rerun one with: rerun_evaluation(run=\"<index-or-path>\", manualResults=\"last-runs|fresh\").");
        return Task.FromResult(sb.ToString());
    }

    [McpServerTool(Name = "rerun_evaluation")]
    [Description("Re-run (or edit) a previous evaluation, overwriting its reports in the SAME run directory. Provide 'run' as an index from list_evaluations or a run directory path. The server and authentication are always reused from the original run and cannot be changed; only the checklist items may be edited via 'items'. Manual-results handling still comes from the user (manualResults='last-runs' or 'fresh'), and for SQL Login the password is read from SQLAUDITOR_SQL_PASSWORD, never chat.")]
    public static async Task<string> RerunEvaluationAsync(
        [Description("Which run to redo: an index from list_evaluations (e.g. '1') or a run directory path.")] string? run = null,
        [Description("How manual/AI-Manual items are handled: 'last-runs' to copy prior decisions, or 'fresh'. MUST come from the user.")] string? manualResults = null,
        [Description("Optional: override the checklist items (edit). Defaults to the run's stored selection.")] string? items = null,
        CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(run))
            return "Provide 'run' \u2014 an index from list_evaluations or a run directory path. Call list_evaluations to see the choices.";

        var selected = ResolveRunSelection(run);
        if (selected is null)
            return $"No completed run found for '{run}'. Call list_evaluations to see valid indexes and paths.";
        var meta = selected.Metadata;

        // Server and authentication are always reused from the original run and cannot be changed
        // on rerun/edit; only the checklist items may be overridden.
        var server = meta.Fqdn;
        var authMethod = string.Equals(meta.AuthMethod, "SQL Login", StringComparison.OrdinalIgnoreCase) ? "sql" : "windows";
        var sqlUser = meta.SqlUser;
        if (string.IsNullOrWhiteSpace(items) && meta.SelectedItemIds is { Count: > 0 })
            items = string.Join(",", meta.SelectedItemIds);

        // Manual-results source is the only thing that must come from the user. Gate it HERE with a
        // rerun-specific prompt so the follow-up turn calls rerun_evaluation again — NEVER evaluate,
        // which would start a fresh run in a NEW folder instead of updating the original.
        var manualMode = manualResults?.Trim().ToLowerInvariant();
        var manualResolved = manualMode is "last-runs" or "lastruns" or "last" or "historical" or "reuse" or "1"
                                        or "fresh" or "new" or "none" or "2";
        if (!manualResolved)
            return $"To rerun run '{run}' ({meta.ServerName}), ask the user how manual/AI-Manual items should be handled, then "
                 + "call rerun_evaluation AGAIN (NOT evaluate) with the same 'run' plus manualResults set:\n"
                 + "  Option 1 \u2014 Use the Last Runs: manualResults='last-runs'\n"
                 + "  Option 2 \u2014 Fresh Evaluation: manualResults='fresh'\n"
                 + "Do NOT call 'evaluate' for a rerun \u2014 that creates a new run folder instead of updating the original.";

        if (string.IsNullOrWhiteSpace(server))
            return $"Run '{run}' predates input capture and has no stored server, so it cannot be rerun here. Run a fresh 'evaluate' instead.";
        if (string.IsNullOrWhiteSpace(items))
            return $"Run '{run}' has no stored checklist items. Call rerun_evaluation again with 'items' set (e.g. '1.1.1,2.1.4').";
        if (string.Equals(authMethod, "sql", StringComparison.OrdinalIgnoreCase)
            && string.IsNullOrEmpty(Environment.GetEnvironmentVariable("SQLAUDITOR_SQL_PASSWORD")))
            return $"Run '{run}' uses SQL Login ('{sqlUser}'), but SQLAUDITOR_SQL_PASSWORD is not set. Ask the user to set it in the "
                 + "session that launched VS Code, restart the server, then call rerun_evaluation again \u2014 or use Windows auth.";

        // Replay the stored scope, minus any system database recorded by an older build.
        var storedDatabases = (meta.Databases ?? Array.Empty<string>())
            .Where(name => !IsSystemDatabase(name))
            .ToArray();
        var targetDatabases = storedDatabases.Length > 0 ? storedDatabases : null;

        // Reuse the SAME folder so the reports are overwritten in place.
        AuditOutputPaths.ResumeRun(selected.RunDirectory);

        return await EvaluateCoreAsync(manualResults, server, authMethod, sqlUser, items, databaseSpec: null,
            reuseActiveRunDirectory: true, targetDatabases: targetDatabases, cancellationToken);
    }

    private static bool IsSystemDatabase(string? name) =>
        string.Equals(name, "master", StringComparison.OrdinalIgnoreCase)
        || string.Equals(name, "model", StringComparison.OrdinalIgnoreCase)
        || string.Equals(name, "msdb", StringComparison.OrdinalIgnoreCase)
        || string.Equals(name, "tempdb", StringComparison.OrdinalIgnoreCase);

    // Resolves a run argument to a stored run: a 1-based index into the recent-runs list,
    // a run directory path, or just the folder name under results/.
    private static PreviousEvaluation? ResolveRunSelection(string runArg)
    {
        runArg = runArg.Trim();
        if (int.TryParse(runArg, out var idx) && idx > 0)
        {
            var recent = PreviousEvaluationStore.FindRecentAcrossServers(Math.Max(idx, 5));
            return idx <= recent.Count ? recent[idx - 1] : null;
        }

        var direct = PreviousEvaluationStore.GetRun(runArg);
        if (direct != null) return direct;

        var underResults = Path.Combine(AuditOutputPaths.RootDirectory, runArg);
        return PreviousEvaluationStore.GetRun(underResults);
    }

    [McpServerTool(Name = "generate_report")]
    [Description("Regenerate all audit outputs from checklist_results.json in the active timestamp-and-server run directory, including the five-file report suite. Optionally refreshes historical_last_run.json with newly evaluated manual/AI-Manual results. Evaluations already generate reports automatically; use this tool only when explicit regeneration or historical refresh is required.")]
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
            + $"\nCall 'show_reports' to display {AuditOutputPaths.GetCurrentFilePath(ReportSuiteGenerator.AuditReportFileName)} and report ITS counts.");
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

    [McpServerTool(Name = "configure_checklist")]
    [Description("CONFIGURE the checklist by adding a CUSTOM checklist item under an EXISTING Area/Sub-area. This is NOT evaluation and NOT script generation for an existing item: never call 'evaluate', never connect to a SQL Server and never ask for credentials. The tool is a state machine driven by the arguments you supply, and YOU are the AI layer for its three reviews. STEP 1 — call with 'title' and 'description' (ask the user for both; never ask for an Area, Sub-area or ID): it pre-screens the request and returns the canonical guardrails, semantic-match-router and Area/Sub-area classification prompts. Perform those three reviews in order using ONLY those prompts. STEP 2 — call again with the same title/description plus guardrail='accept', match='<matched id>' or 'none', subArea='<existing sub-area id>' and rationale: it assigns the next free checklist ID inside that Sub-area (reserved only) and returns the script generation prompt. STEP 3 — author the script, then call with id and response (and validationVerdict on the second pass) to run the format gate and the C1-C7 review; the script is held, not saved. STEP 4 — show the script to the user and call with id and approve=true only after they approve, or reject=true if they do not. Nothing is written to custom-checklist.json or custom-deterministic-script-mapping.json until approval, and the default checklist and default mapping are never modified.")]
    public static async Task<string> ConfigureChecklistAsync(
        [Description("STEP 1: the Custom Checklist Title supplied by the user. Required for steps 1 and 2.")] string? title = null,
        [Description("STEP 1: the user's description of the checklist item — what must be true for it to pass. Required for steps 1 and 2.")] string? description = null,
        [Description("STEP 2: your guardrails verdict — 'accept' or 'reject'. Take it from the guardrails review returned by step 1.")] string? guardrail = null,
        [Description("STEP 2: the reason from your guardrails review; shown to the user when the verdict is 'reject'.")] string? guardrailReason = null,
        [Description("STEP 2: your semantic-match verdict — the EXISTING checklist ID this request duplicates, or 'none' when it is genuinely new. Must be one of the candidate IDs shown in step 1.")] string? match = null,
        [Description("STEP 2: the reason from your semantic-match review.")] string? matchReason = null,
        [Description("STEP 2: the EXISTING Sub-area ID chosen by your classification review, e.g. '1.1'. New Areas/Sub-areas are not supported.")] string? subArea = null,
        [Description("STEP 2: one sentence on why that Sub-area is the right home.")] string? rationale = null,
        [Description("STEP 3/4: the reserved custom checklist ID returned by step 2, e.g. '1.1.8'.")] string? id = null,
        [Description("STEP 3: the COMPLETE raw generator output for the reserved item: the FEASIBLE/SCRIPT_TYPE/SCOPE/SCRIPT_NAME/SCORING_LOGIC fields and the script between ---SCRIPT_START--- and ---SCRIPT_END--- markers.")] string? response = null,
        [Description("STEP 3: the verdict from the C1-C7 review, in the validation template's response format. Omit on the first call to receive the validation prompt.")] string? validationVerdict = null,
        [Description("STEP 4: set to true ONLY after the user has seen the generated script and approved it. Saves the item, its mapping and the merged configuration.")] bool approve = false,
        [Description("STEP 4: set to true when the user rejects the item. Releases the reserved ID and writes nothing.")] bool reject = false,
        [Description("Set to true to list the Areas/Sub-areas a custom item may be filed under, without changing anything.")] bool listSubAreas = false,
        [Description("Set to true to list the drafts that are reserved but not yet approved.")] bool listPending = false,
        CancellationToken cancellationToken = default)
    {
        var hints = new CustomChecklistInvocationHints
        {
            Classify = "call configure_checklist(title=\"<same title>\", description=\"<same description>\", "
                     + "guardrail=\"accept\", match=\"none\", subArea=\"<existing sub-area id>\", rationale=\"<why>\")",
            Generate = "call configure_checklist(id=\"<reserved id>\", response=\"<full raw generator output>\")",
            Review = "call configure_checklist(id=\"<reserved id>\", response=\"<same full raw output>\", validationVerdict=\"<your VERDICT block>\")",
            Approve = "Show the script to the user and ask whether to add this checklist item. "
                    + "If yes: call configure_checklist(id=\"<reserved id>\", approve=true). "
                    + "If no: call configure_checklist(id=\"<reserved id>\", reject=true).",
            Reject = "call configure_checklist(id=\"<reserved id>\", reject=true)"
        };

        // Custom-checklist writes touch the same read-modify-write files as script saves.
        await SaveGate.WaitAsync(cancellationToken);
        try
        {
            if (listSubAreas) return CustomChecklistHostFlow.ListSubAreas();
            if (listPending) return CustomChecklistHostFlow.ListPending();

            if (!string.IsNullOrWhiteSpace(id))
            {
                if (reject) return CustomChecklistHostFlow.Reject(id);
                if (approve) return await CustomChecklistHostFlow.ApproveAsync(id, cancellationToken);
                return CustomChecklistHostFlow.Generate(id, response, validationVerdict, hints);
            }

            if (!string.IsNullOrWhiteSpace(guardrail) || !string.IsNullOrWhiteSpace(subArea))
                return CustomChecklistHostFlow.Classify(
                    title, description, guardrail, guardrailReason, match, matchReason, subArea, rationale, hints);

            return CustomChecklistHostFlow.Begin(title, description, hints);
        }
        finally
        {
            SaveGate.Release();
        }
    }

    [McpServerTool(Name = "show_reports")]
    [Description("Return the most recently generated audit output from the latest timestamp-and-server run directory: 'summary' for Audit Report.md (default) or 'json' for checklist_results.json.")]
    public static Task<string> ShowReportsAsync(
        [Description("'summary' for the Markdown report (default) or 'json' for the raw results.")] string kind = "summary")
    {
        var resultsDir = AuditOutputPaths.CurrentRunDirectory;
        var path = string.Equals(kind, "json", StringComparison.OrdinalIgnoreCase)
            ? Path.Combine(resultsDir, "checklist_results.json")
            : Path.Combine(resultsDir, ReportSuiteGenerator.AuditReportFileName);

        if (!File.Exists(path))
            return Task.FromResult($"No report found at {path}. Run 'evaluate' first.");

        var tally = Auditor.BuildOutcomeTally();
        return Task.FromResult(
            (string.IsNullOrEmpty(tally) ? string.Empty : $"Final outcome counts (after enrichment and review): {tally}\n\n")
            + File.ReadAllText(path));
    }

    [McpServerTool(Name = "resolve_review")]
    [Description("Mark a checklist item that came back as NeedsReview with a human decision of pass, fail, notapplicable (or needsreview). Requires the reviewer's own observation/evidence text for pass, fail and notapplicable decisions. 'notapplicable' records that the control does not exist on this server to be assessed, so the item is excluded from every score and reported as Not Applicable. Updates checklist_results.json and regenerates the five-file report suite in the current run directory. Use after 'evaluate' surfaces manual-review items.")]
    public static Task<string> ResolveReviewAsync(
        [Description("The checklist item ID to resolve, e.g. '3.1.1'.")] string id,
        [Description("The decision: 'pass', 'fail', 'notapplicable', or 'needsreview'. Use 'notapplicable' only when every value the reviewer reports is absent, empty, zero or irrelevant, so there is nothing to assess; a zero that itself proves compliance is a Pass.")] string decision,
        [Description("The reviewer's observation/evidence in their own words: what they inspected and what they found (document names, settings, values, counts). Required for 'pass', 'fail' and 'notapplicable'. A bare 'pass'/'fail' is not acceptable evidence.")] string? notes = null)
    {
        if (string.IsNullOrWhiteSpace(id))
            return Task.FromResult("Error: 'id' is required.");
        if (string.IsNullOrWhiteSpace(decision))
            return Task.FromResult("Error: 'decision' is required (pass, fail, notapplicable, or needsreview).");

        // The reviewer's own words are the evidence of record, so a decision cannot be
        // filed without them.
        var isDecision = decision.Trim().ToLowerInvariant() is "pass" or "p" or "yes" or "y" or "fail" or "f" or "no" or "n"
            or "notapplicable" or "not applicable" or "not-applicable" or "na" or "n/a";
        if (isDecision && !IsUsableEvidence(notes))
            return Task.FromResult(
                $"Error: 'notes' must contain the reviewer's actual observation for [{id}] — what they checked and what they found. "
                + "Ask the user for the evidence behind their decision and call resolve_review again with it.");

        var auditor = new Auditor(string.Empty);
        if (auditor.ResolveReview(id, decision, notes, out var newOutcome))
        {
            if (NotApplicableEvidence.IsNotApplicableOutcome(newOutcome))
                return Task.FromResult(
                    $"Updated [{id}] -> {newOutcome}. results/checklist_results.json and the five-file report suite regenerated. "
                    + "The item is excluded from every score and is listed on the 'Not Applicable Items' sheet — report it as Not Applicable, never as Pass or Fail. "
                    + "No enrich_result call is needed for it.");

            return Task.FromResult(
                $"Updated [{id}] -> {newOutcome}. Outputs regenerated in {AuditOutputPaths.CurrentRunDirectory}. "
                + $"NEXT: call enrich_result(id=\"{id}\", ...) with audit wording you derive from the reviewer's evidence above — finding, evidence, riskImpact and recommendation — using only facts the reviewer stated.");
        }

        return Task.FromResult(
            $"Could not resolve '{id}'. Ensure 'evaluate' has run (results file exists), the ID is present, and decision is pass/fail/notapplicable/needsreview.");
    }

    // A restatement of the verdict carries no information about what was inspected.
    private static bool IsUsableEvidence(string? notes)
    {
        if (string.IsNullOrWhiteSpace(notes)) return false;
        var trimmed = notes.Trim().Trim('.', '!', ' ').ToLowerInvariant();
        return trimmed is not ("pass" or "passed" or "fail" or "failed" or "p" or "f"
            or "yes" or "no" or "y" or "n" or "ok" or "okay" or "good" or "bad" or "n/a");
    }

    [McpServerTool(Name = "export_manual_csv")]
    [Description("Export every manual/AI-Manual checklist item of the current run — with its area, description, verification and generated manual steps — to a CSV the user fills in offline. This is the manual review workflow: the user enters Pass/Fail in the 'Decision' column and their observation in the 'Evidence' column, then 'import_manual_csv' applies the whole file. Identical CSV contract to the desktop app and the CLI. Set generateReport=true to also mark every still-undecided manual item as Skipped and regenerate the report suite now (the same as the desktop 'Export Manual CSV + Generate' button), so a report is available before the filled CSV is imported. Use after 'evaluate' reports manual items.")]
    public static async Task<string> ExportManualCsvAsync(
        [Description("Optional full path for the CSV. Defaults to a timestamped manual_checks_*.csv inside the current run directory.")] string? path = null,
        [Description("When true, mark every still-undecided manual item as Skipped (excluded from scoring) and regenerate the five-file report suite immediately. A later import_manual_csv overwrites the Skipped items with the user's real decisions. Defaults to false.")] bool generateReport = false)
    {
        var resultsDir = AuditOutputPaths.CurrentRunDirectory;
        if (!File.Exists(Path.Combine(resultsDir, "checklist_results.json")))
            return "No evaluation results were found. Run 'evaluate' first.";

        var auditor = new Auditor(string.Empty);
        var rows = await ManualChecklistCsv.BuildExportRowsAsync(auditor);
        if (rows.Count == 0)
            return "The current evaluation contains no manual checklist items to export.";

        var target = string.IsNullOrWhiteSpace(path)
            ? Path.Combine(resultsDir, ManualChecklistCsv.BuildExportFileName(DateTime.Now))
            : Path.GetFullPath(path);

        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(target)!);
            ManualChecklistCsv.Write(target, rows);
        }
        catch (Exception ex)
        {
            return $"The manual checklist CSV could not be written to {target}: {ex.Message}";
        }

        var undecided = rows.Count(r => string.IsNullOrWhiteSpace(r.Decision));
        var sb = new StringBuilder();
        sb.AppendLine($"Exported {rows.Count} manual checklist item(s) ({undecided} undecided) to:");
        sb.AppendLine($"  {target}");
        sb.AppendLine();

        if (generateReport)
        {
            var skipped = ManualChecklistCsv.SkipPendingManual(Path.GetFileName(target), resultsDir);
            Auditor.GenerateReports(runDirectory: resultsDir);
            sb.AppendLine($"{skipped} undecided manual item(s) were marked Skipped (excluded from scoring) and the five-file report");
            sb.AppendLine($"suite was regenerated in {resultsDir}.");
            sb.AppendLine("Give the user the CSV path and ask them to fill the 'Decision' and 'Evidence' columns (leaving 'Checklist ID'");
            sb.AppendLine("unchanged), then call import_manual_csv with the path to replace the Skipped items with their real decisions.");
            sb.AppendLine("Do NOT paste the steps into chat; they are in the CSV's 'Manual Steps' column. Do NOT ask for decisions one item at a time.");
            return sb.ToString();
        }

        sb.AppendLine("Tell the user to open that CSV and, for each row, enter 'Pass' or 'Fail' in the 'Decision' column and");
        sb.AppendLine("what they inspected and found in the 'Evidence' column, leaving 'Checklist ID' unchanged. The 'Manual Steps'");
        sb.AppendLine("column already holds the verification guidance for each item. Then call");
        sb.AppendLine($"  import_manual_csv(path=\"{target}\")");
        sb.AppendLine("to apply every decision at once. Rows left blank stay NeedsReview; re-importing an edited CSV overwrites");
        sb.AppendLine("decisions that were already recorded. Do NOT ask the user for these decisions one item at a time.");
        sb.AppendLine("To produce a report now without waiting for the filled CSV, call export_manual_csv(generateReport=true), which");
        sb.AppendLine("marks the undecided items Skipped and regenerates the report suite.");
        sb.AppendLine();
        sb.AppendLine("Items exported:");
        foreach (var row in rows)
            sb.AppendLine($"- [{row.Id}] {row.Status} - {row.Description}");
        return sb.ToString();
    }

    [McpServerTool(Name = "import_manual_csv")]
    [Description("Apply the Pass/Fail decisions from a filled manual checklist CSV to the current run. Rows are matched to checklist items by 'Checklist ID', so a row records a new decision or overwrites an existing one; the CSV is the source of truth. Rows whose ID is not a manual item in this run are ignored. Updates checklist_results.json and regenerates the five-file report suite. Use after 'export_manual_csv' once the user has filled the file.")]
    public static Task<string> ImportManualCsvAsync(
        [Description("Full path to the filled CSV produced by 'export_manual_csv' (or by the desktop app / CLI).")] string path)
    {
        if (string.IsNullOrWhiteSpace(path))
            return Task.FromResult("Error: 'path' is required (the filled manual checklist CSV).");
        if (!File.Exists(path))
            return Task.FromResult($"File not found: {path}. Ask the user for the saved location of the filled CSV.");

        var resultsDir = AuditOutputPaths.CurrentRunDirectory;
        if (!File.Exists(Path.Combine(resultsDir, "checklist_results.json")))
            return Task.FromResult("No evaluation results were found. Run 'evaluate' first.");

        ManualCheckImportFile importFile;
        try
        {
            importFile = ManualChecklistCsv.Read(path);
        }
        catch (Exception ex)
        {
            return Task.FromResult($"The manual CSV could not be read: {ex.Message}");
        }

        var auditor = new Auditor(string.Empty);
        var applied = ManualChecklistCsv.Apply(auditor, importFile.Rows);

        try { ManualChecklistCsv.StoreInRunDirectory(path); }
        catch { }

        var sb = new StringBuilder();
        sb.AppendLine($"Applied {applied.Applied.Count} manual decision(s); outputs regenerated in {resultsDir}.");
        foreach (var entry in applied.Applied) sb.AppendLine($"  [{entry}]");
        if (applied.Ignored.Count > 0)
            sb.AppendLine($"Ignored {applied.Ignored.Count} row(s) that are not manual items in this run: {string.Join(", ", applied.Ignored)}");
        if (applied.Failed.Count > 0)
            sb.AppendLine($"Could not update {applied.Failed.Count} row(s): {string.Join(", ", applied.Failed)}");
        if (importFile.Issues.Count > 0)
        {
            sb.AppendLine($"{importFile.Issues.Count} row(s) need correction before they can be applied:");
            foreach (var issue in importFile.Issues.Take(20)) sb.AppendLine($"  {issue}");
            if (importFile.Issues.Count > 20) sb.AppendLine($"  ...and {importFile.Issues.Count - 20} more.");
            sb.AppendLine("Report these to the user so they can correct the CSV and call import_manual_csv again.");
        }

        if (applied.Applied.Count > 0)
        {
            sb.AppendLine();
            sb.AppendLine("NEXT: for each applied item call enrich_result(id=\"<id>\", ...) with audit wording you derive from the");
            sb.AppendLine("reviewer's Evidence text — finding, evidence, riskImpact and recommendation — using only facts they stated.");
        }

        return Task.FromResult(sb.ToString());
    }

    [McpServerTool(Name = "enrich_result")]
    [Description("Record the audit wording YOU authored for a script-evaluated checklist item, using only the facts the script returned. Sets Finding, Evidence, RiskImpact and Recommendation in checklist_results.json and regenerates the five-file report suite in the current run directory. Outcome, Score, Severity and Databases Verified are script-derived and cannot be changed here, with one exception: when the script result held no supporting artefact at all and your evidence therefore starts with 'Not Applicable.', the item is re-stamped Outcome 'Not Applicable' and excluded from every score. Use after 'evaluate' lists items in its COPILOT ENRICHMENT REQUIRED block.")]
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
        if (auditor.ApplyEnrichment(id, finding, evidence, riskImpact, recommendation))
            return Task.FromResult(
                $"Enriched [{id}]. Outputs regenerated in {AuditOutputPaths.CurrentRunDirectory}.");

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

    [McpServerPrompt(Name = "configure_checklist")]
    [Description("Add a custom checklist item under an existing Area/Sub-area using the sql-auditor MCP tools (not evaluation).")]
    public static string ConfigureChecklist() =>
        "Configure the SQL Auditor checklist by adding a CUSTOM checklist item, using the 'configure_checklist' "
      + "MCP tool. This is configuration only — do not call 'evaluate', do not connect to a SQL Server and do not "
      + "ask for a server name or credentials. "
      + "Ask me for exactly two things: the Custom Checklist Title and a description of the checklist item. "
      + "Never ask me for an Area, a Sub-area or a checklist ID — the tool and your classification review decide "
      + "those. Then call configure_checklist(title=..., description=...) and follow its state machine: perform the "
      + "guardrails, semantic-match-router and Area/Sub-area classification reviews using ONLY the prompts it "
      + "returns, then call it again with your three verdicts to get the assigned ID and the script generation "
      + "prompt. Write the script, submit it for the format gate and the C1-C7 review, then SHOW ME the generated "
      + "script and ask whether to add the item. Call the tool with approve=true only after I say yes, or "
      + "reject=true if I say no. "
      + "Report each stage clearly: guardrail rejection, duplicate/matched checklist item, the assigned "
      + "Area/Sub-area, the generated checklist ID, the script generation and validation status, my approval or "
      + "rejection, and the final merged configuration update.";
}