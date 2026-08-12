using System.ComponentModel;
using System.Text;
using ModelContextProtocol.Server;
using SQLAuditor.Lib;

namespace SQLAuditor.Mcp;

/// <summary>
/// MCP tools that expose the SQL Auditor evaluation engine to the IDE
/// (VS Code Copilot Chat). Each tool reuses <see cref="Auditor"/> directly so
/// behavior matches the CLI and the WPF app.
/// </summary>
[McpServerToolType]
public static class AuditTools
{
    [McpServerTool(Name = "evaluate")]
    [Description("Evaluate SQL audit checklist items following the standard workflow, identical to the CLI: (1) SQL Server name, (2) authentication method, (3) checklist items, (4) automated + manual verification, (5) summary. ALWAYS call this tool to begin an evaluation. When a required input is missing it returns the exact next question to ask the user; ask that question and call evaluate again with the answer plus everything gathered so far. Never guess the server or credentials, and never run the evaluation before the server name has been supplied by the user. Writes results/checklist_results.json and results/final_report.md.")]
    public static async Task<string> EvaluateAsync(
        [Description("STEP 1: SQL Server name/host[,port]. REQUIRED and must come from the user. If you don't have it yet, call with server empty to get the exact prompt to show the user.")] string? server = null,
        [Description("STEP 2: Authentication method — 'windows' for Windows Integrated, or 'sql' for SQL Login.")] string? authMethod = null,
        [Description("STEP 2b: SQL login username (only when authMethod='sql'). The password is read from the SQLAUDITOR_SQL_PASSWORD environment variable and must NEVER be typed in chat.")] string? sqlUser = null,
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

        // STEP 2b — SQL login username (password stays in the environment, never in chat).
        if (method == "sql" && string.IsNullOrWhiteSpace(sqlUser))
            return $"STEP 2b — SQL LOGIN USERNAME REQUIRED for server '{server}'.\n"
                 + "Ask the user for the SQL login username. For security, the password must be set in the "
                 + "SQLAUDITOR_SQL_PASSWORD environment variable and must never be typed in chat.\n"
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

        // Manual-review items cannot be decided automatically. An MCP tool cannot
        // prompt mid-run, so instruct the agent to elicit a pass/fail decision from
        // the user for each item and record it via the resolve_review tool.
        var manualPending = results
            .Where(r => string.Equals(r.Outcome, "NeedsReview", StringComparison.OrdinalIgnoreCase)
                     && (r.Technique?.Contains("Manual", StringComparison.OrdinalIgnoreCase) ?? false))
            .OrderBy(r => r.Id, StringComparer.OrdinalIgnoreCase)
            .ToList();

        if (manualPending.Count > 0)
        {
            sb.AppendLine();
            sb.AppendLine("=== ACTION REQUIRED: MANUAL REVIEW (do not stop here) ===");
            sb.AppendLine($"{manualPending.Count} item(s) could not be decided automatically and REQUIRE a human Pass/Fail decision.");
            sb.AppendLine("For EACH item below you MUST: (1) display the FULL 'Manual verification steps' shown for that item verbatim to the user (do not summarize, shorten, or omit them), (2) ask them to decide Pass or Fail (with optional notes), then (3) call the 'resolve_review' tool with their decision. Do NOT write a final summary or consider the task complete until every item has been resolved by the user.");
            foreach (var r in manualPending)
            {
                sb.AppendLine();
                sb.AppendLine($"--- {r.Id}: {r.Description} ---");
                if (!string.IsNullOrWhiteSpace(r.Evidence))
                {
                    sb.AppendLine("Manual verification steps / guidance:");
                    sb.AppendLine(r.Evidence.Trim());
                }
                sb.AppendLine($"After the user decides, call: resolve_review(id=\"{r.Id}\", decision=\"pass\" or \"fail\", notes=\"<user's rationale>\")");
            }
        }

        sb.AppendLine();
        sb.AppendLine("Reports written to results/checklist_results.json and results/final_report.md.");
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
    [Description("Mark a checklist item that came back as NeedsReview with a human decision of pass or fail (or needsreview). Updates results/checklist_results.json and regenerates results/final_report.md. Use after 'evaluate' surfaces manual-review items.")]
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
            return Task.FromResult($"Updated [{id}] -> {newOutcome}. results/checklist_results.json and results/final_report.md regenerated.");

        return Task.FromResult(
            $"Could not resolve '{id}'. Ensure 'evaluate' has run (results file exists), the ID is present, and decision is pass/fail/needsreview.");
    }
}
