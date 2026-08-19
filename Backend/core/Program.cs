using System;
using System.IO;
using System.Linq;
using System.Threading.Tasks;

namespace SQLAuditor
{
    internal static class Program
    {
        static async Task<int> Main(string[] args)
        {
            // The CLI never calls an LLM: Copilot CLI is the AI layer. Disabling the
            // engine's evaluators guarantees no .env / PROVIDER_* dependency here.
            SQLAuditor.Lib.Auditor.DisableLlmEvaluators();

            // Non-interactive CLI subcommand: evaluate specific checklist items and exit.
            // Example: sqlauditor evaluate --items 1.1.2,3.1.2 --server myhost\\sqlexpress
            if (args.Length > 0 && string.Equals(args[0], "evaluate", StringComparison.OrdinalIgnoreCase))
            {
                return await RunEvaluateCommandAsync(args);
            }

            // Record a review decision for a NeedsReview item (used by the Copilot CLI skill).
            if (args.Length > 0 && string.Equals(args[0], "resolve_review", StringComparison.OrdinalIgnoreCase))
            {
                return RunResolveReviewCommand(args);
            }

            // Record Copilot-authored audit wording for a script-evaluated item.
            if (args.Length > 0 && string.Equals(args[0], "enrich_result", StringComparison.OrdinalIgnoreCase))
            {
                return RunEnrichResultCommand(args);
            }

            // Generate deterministic audit scripts for checklist items (NOT evaluation).
            // Copilot CLI is the AI: this surfaces the generator prompt so Copilot can author
            // each script, then 'save_generated_script' validates and saves it.
            if (args.Length > 0 && string.Equals(args[0], "generate_scripts", StringComparison.OrdinalIgnoreCase))
            {
                return await RunGenerateScriptsCommandAsync(args);
            }

            // Save one Copilot-generated script for a checklist item (used after generate_scripts).
            if (args.Length > 0 && string.Equals(args[0], "save_generated_script", StringComparison.OrdinalIgnoreCase))
            {
                return await RunSaveGeneratedScriptCommandAsync(args);
            }

            // Print a previously-generated report (summary Markdown or raw JSON).
            if (args.Length > 0 && (string.Equals(args[0], "show_reports", StringComparison.OrdinalIgnoreCase) || args.Contains("--show-reports")))
            {
                return RunShowReportsCommand(args);
            }

            Console.WriteLine("SQL Auditor — lightweight console interface");

            // special debug flag: dump parsed checklist structure and exit
            if (args.Contains("--dump-checklist"))
            {
                var dumper = new SQLAuditor.Lib.Auditor(string.Empty);
                var structure = await dumper.GetChecklistStructureAsync();
                foreach (var (area, items) in structure)
                {
                    Console.WriteLine($"Area: {area}");
                    var byCat = items.GroupBy(i => i.Category ?? "").OrderBy(g => g.Key);
                    foreach (var cat in byCat)
                    {
                        Console.WriteLine($"  Category: {cat.Key}");
                        foreach (var it in cat)
                        {
                            Console.WriteLine($"    {it.Id} - {it.Description}");
                        }
                    }
                }
                return 0;
            }

            string fqdn = args.Length > 0 ? args[0] : Prompt("Enter SQL Server FQDN (host[,port]):");
            Console.WriteLine($"Target: {fqdn}");

            string authChoice = Prompt("Auth method? (1=Windows Integrated, 2=SQL Login) [1/2]:");
            string connectionString;
            if (authChoice.Trim() == "2")
            {
                string user = Prompt("SQL username:");
                string pass = PromptSecret("SQL password:");
                connectionString = $"Server={fqdn};User Id={user};Password={pass};TrustServerCertificate=true;";
            }
            else
            {
                connectionString = $"Server={fqdn};Integrated Security=true;TrustServerCertificate=true;";
            }

            var auditor = new SQLAuditor.Lib.Auditor(connectionString);

            while (true)
            {
                Console.WriteLine();
                Console.WriteLine("1) Run deterministic scripts (from Backend/checklist/tools/sql)");
                Console.WriteLine("2) Run single script file");
                Console.WriteLine("3) Show implementation mapping file");
                Console.WriteLine("4) Run checklist evaluation (script/AI/User input)");
                Console.WriteLine("5) Exit");
                var sel = Prompt("Choose:");
                if (sel == "1")
                {
                    var results = await auditor.RunAllScriptsAsync();
                    Console.WriteLine($"Completed {results.Length} script(s). Results written to results/ folder.");
                }
                else if (sel == "2")
                {
                    var path = Prompt("Path to .sql file:");
                    await auditor.RunScriptFileAsync(path);
                }
                else if (sel == "3")
                {
                    auditor.ShowMappingFile();
                }
                else if (sel == "4")
                {
                    // Run checklist evaluation
                    var progress = new Progress<SQLAuditor.Lib.ChecklistResult>(r =>
                    {
                        Console.WriteLine($"[{r.Id}] {r.Description} -> {r.Outcome}");
                    });

                    async Task<string?> RequestUserInput(SQLAuditor.Lib.ChecklistItem item, string manualSteps)
                    {
                        Console.WriteLine($"Manual input required for {item.Id}: {item.Description}");
                        if (!string.IsNullOrWhiteSpace(manualSteps))
                        {
                            Console.WriteLine("Manual steps:");
                            Console.WriteLine(manualSteps);
                        }
                        return Prompt("Enter response (Yes/No/notes):");
                    }

                    var idsInput = Prompt("Enter comma-separated checklist IDs to evaluate (leave blank for all):");
                    System.Collections.Generic.IEnumerable<string>? selected = null;
                    if (!string.IsNullOrWhiteSpace(idsInput)) selected = idsInput.Split(',', StringSplitOptions.RemoveEmptyEntries).Select(s => s.Trim());

                    var results = await auditor.RunChecklistAsync(progress, RequestUserInput, selected, System.Threading.CancellationToken.None);
                    Console.WriteLine($"Completed evaluation of {results.Length} checklist items. Results in results/ folder.");
                }
                else if (sel == "5")
                {
                    break;
                }
            }

            return 0;
        }

        // ---------------------------------------------------------------------
        // Non-interactive CLI: `evaluate` subcommand
        // ---------------------------------------------------------------------
        static async Task<int> RunEvaluateCommandAsync(string[] args)
        {
            try
            {
                return await RunEvaluateCoreAsync(args);
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine($"Error: {ex.Message}");
                Console.Error.WriteLine("Hint: run this command from the 'SQL-Auditing-tool' folder so the checklist can be located.");
                return 3;
            }
        }

        static async Task<int> RunEvaluateCoreAsync(string[] args)
        {
            var opts = ParseOptions(args);

            if (opts.ContainsKey("help") || opts.ContainsKey("h"))
            {
                PrintEvaluateUsage();
                return 0;
            }

            // Copilot mode: the CLI stays non-interactive and surfaces NeedsReview items
            // so the Copilot CLI skill can generate guidance and record decisions.
            bool copilotMode = opts.ContainsKey("copilot");

            // Values come from flags/env first; anything missing is prompted for,
            // one detail at a time. Secrets are never hardcoded.

            // --- Step 1: SQL Server ---
            string? server = GetOption(opts, "server") ?? Environment.GetEnvironmentVariable("SQLAUDITOR_SERVER");
            if (string.IsNullOrWhiteSpace(server))
                server = PromptRequired("Enter SQL Server FQDN (host[,port]):", "A SQL Server is required.");
            if (string.IsNullOrWhiteSpace(server))
            {
                Console.Error.WriteLine("Error: SQL Server is required.");
                return 2;
            }

            // --- Step 2: Authentication / login details ---
            string? user = GetOption(opts, "user") ?? Environment.GetEnvironmentVariable("SQLAUDITOR_SQL_USER");
            string? pass = GetOption(opts, "password") ?? Environment.GetEnvironmentVariable("SQLAUDITOR_SQL_PASSWORD");

            if (string.IsNullOrWhiteSpace(user))
            {
                // No username supplied. In Copilot mode we never prompt: default to
                // Windows Integrated auth (pass --user for SQL Login instead).
                if (!copilotMode)
                {
                    var authChoice = Prompt("Auth method? (1=Windows Integrated, 2=SQL Login) [1/2]:");
                    if (authChoice.Trim() == "2")
                    {
                        user = Prompt("SQL username:");
                        pass = PromptSecret("SQL password:");
                    }
                }
            }
            else if (string.IsNullOrWhiteSpace(pass))
            {
                // Username provided up front but no password. In Copilot mode the password
                // must come from the SQLAUDITOR_SQL_PASSWORD session env var (never chat).
                if (copilotMode)
                {
                    Console.Error.WriteLine($"Error: SQL Login user '{user}' supplied but no password. Set SQLAUDITOR_SQL_PASSWORD in your session, or omit --user for Windows auth.");
                    return 2;
                }
                pass = PromptSecret($"SQL password for '{user}':");
            }

            string connectionString = !string.IsNullOrWhiteSpace(user)
                ? $"Server={server};User Id={user};Password={pass};TrustServerCertificate=true;"
                : $"Server={server};Integrated Security=true;TrustServerCertificate=true;";

            // --- Step 3: Checklist IDs to evaluate ---
            if (!opts.TryGetValue("items", out var itemsCsv) || string.IsNullOrWhiteSpace(itemsCsv))
                itemsCsv = PromptRequired("Enter comma-separated checklist IDs to evaluate (e.g. 1.1.2,3.1.2):", "At least one checklist ID is required.");

            var ids = (itemsCsv ?? string.Empty)
                .Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
                .Distinct(StringComparer.OrdinalIgnoreCase)
                .ToArray();
            if (ids.Length == 0)
            {
                Console.Error.WriteLine("Error: no checklist IDs provided.");
                return 2;
            }

            var auditor = new SQLAuditor.Lib.Auditor(connectionString);

            // Validate requested IDs against the known checklist structure.
            var structure = await auditor.GetChecklistStructureAsync();
            var knownIds = new System.Collections.Generic.HashSet<string>(
                structure.SelectMany(s => s.Items).Select(i => i.Id), StringComparer.OrdinalIgnoreCase);

            var unknown = ids.Where(id => !knownIds.Contains(id)).ToArray();
            foreach (var u in unknown)
                Console.Error.WriteLine($"Warning: unknown checklist ID '{u}' (skipped).");

            var validIds = ids.Where(id => knownIds.Contains(id)).ToArray();
            if (validIds.Length == 0)
            {
                Console.Error.WriteLine("Error: none of the requested checklist IDs exist.");
                return 2;
            }

            // Item metadata (Category/Verification) for the Copilot review block, keyed by Id.
            var itemLookup = structure.SelectMany(s => s.Items)
                .GroupBy(i => i.Id, StringComparer.OrdinalIgnoreCase)
                .ToDictionary(g => g.Key, g => g.First(), StringComparer.OrdinalIgnoreCase);

            Console.WriteLine($"Evaluating {validIds.Length} checklist item(s): {string.Join(", ", validIds)}");
            Console.WriteLine($"Target server: {server}");
            Console.WriteLine("(Press Ctrl+C to stop; partial results are still saved.)");
            Console.WriteLine();

            // Ctrl+C cancels the evaluation gracefully instead of killing the process.
            using var cts = new System.Threading.CancellationTokenSource();
            ConsoleCancelEventHandler onCancel = (_, e) =>
            {
                e.Cancel = true; // keep the process alive so we can stop cleanly
                if (!cts.IsCancellationRequested)
                {
                    Console.WriteLine();
                    Console.WriteLine("Cancellation requested — stopping after the current item...");
                    cts.Cancel();
                }
            };
            Console.CancelKeyPress += onCancel;

            // Announce each item as it starts so slow items (manual guidance is
            // LLM-generated) don't look like the tool has hung or exited.
            var announced = new System.Collections.Generic.HashSet<string>(StringComparer.OrdinalIgnoreCase);
            var progress = new Progress<SQLAuditor.Lib.ChecklistResult>(r =>
            {
                if (string.Equals(r.Outcome, "Evaluating", StringComparison.OrdinalIgnoreCase))
                {
                    if (announced.Add(r.Id))
                        Console.WriteLine($"  [{r.Id}] evaluating... ({r.Technique}; manual items may take a moment)");
                }
                else
                {
                    Console.WriteLine($"  [{r.Id}] {r.Outcome,-11} ({r.Technique}) - {r.Description}");
                }
            });

            SQLAuditor.Lib.ChecklistResult[] results;
            try
            {
                // Non-interactive: no user prompts. Manual-only items resolve to NeedsReview.
                results = await auditor.RunChecklistAsync(progress, null, validIds, cts.Token);
            }
            finally
            {
                Console.CancelKeyPress -= onCancel;
            }

            // Always surface the manual verification guidance in the terminal for any
            // item that needs manual review, regardless of interactive/non-interactive
            // mode. The same guidance is persisted to the results files, but printing it
            // here means operators (and CI logs) can see the steps without opening them.
            var manualReviewItems = results
                .Where(r => string.Equals(r.Outcome, "NeedsReview", StringComparison.OrdinalIgnoreCase)
                         && (r.Technique?.Contains("Manual", StringComparison.OrdinalIgnoreCase) ?? false))
                .OrderBy(r => r.Id, StringComparer.OrdinalIgnoreCase)
                .ToList();

            // Non-Copilot runs print the plain listing here. In Copilot mode the enriched
            // review block below is the single on-screen guidance, so this is skipped to
            // avoid printing the same steps twice.
            if (!copilotMode && manualReviewItems.Count > 0 && !cts.IsCancellationRequested)
            {
                Console.WriteLine();
                Console.WriteLine($"Manual verification steps for {manualReviewItems.Count} item(s) needing review:");
                foreach (var r in manualReviewItems)
                {
                    Console.WriteLine();
                    Console.WriteLine($"--- {r.Id}: {r.Description} ---");
                    if (!string.IsNullOrWhiteSpace(r.Evidence))
                        Console.WriteLine(r.Evidence.Trim());
                    else
                        Console.WriteLine("(No guidance was generated for this item.)");
                }
            }

            // In Copilot mode, surface the NeedsReview items in a clearly delimited block
            // so the Copilot CLI skill can act as the reviewer (tailor guidance + decide),
            // and the script-evaluated items so it can author their audit wording.
            if (copilotMode)
            {
                Console.WriteLine();
                Console.Write(SQLAuditor.Lib.Auditor.BuildScriptEnrichmentRequest(
                    results,
                    id => $"sql-auditor enrich_result --id {id} --finding \"<finding>\" --evidence \"<evidence>\" --risk \"<riskImpact>\" --recommendation \"<recommendation>\""));

                PrintNeedsReviewForCopilot(results, validIds, itemLookup);
            }

            // Optional: let the operator mark manual-review items as pass/fail inline.
            // Enabled explicitly with --interactive, or automatically when running in a
            // real terminal (stdin not redirected) so a hands-on session is always asked.
            // Scripted/CI runs (redirected stdin) stay non-blocking unless --interactive.
            bool interactive = !copilotMode
                && (opts.ContainsKey("interactive") || opts.ContainsKey("i") || !Console.IsInputRedirected);
            if (interactive && !cts.IsCancellationRequested)
            {
                var manualPending = results
                    .Where(r => string.Equals(r.Outcome, "NeedsReview", StringComparison.OrdinalIgnoreCase)
                             && (r.Technique?.Contains("Manual", StringComparison.OrdinalIgnoreCase) ?? false))
                    .OrderBy(r => r.Id, StringComparer.OrdinalIgnoreCase)
                    .ToList();

                if (manualPending.Count > 0)
                {
                    Console.WriteLine();
                    Console.WriteLine($"{manualPending.Count} item(s) need manual review. Mark each as pass/fail, or skip to keep NeedsReview.");
                    Console.WriteLine("(Manual verification steps are listed above.)");
                    var updated = new System.Collections.Generic.Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
                    foreach (var r in manualPending)
                    {
                        Console.WriteLine();
                        Console.WriteLine($"--- {r.Id}: {r.Description} ---");
                        var ans = Prompt("Mark item (p=Pass, f=Fail, s=Skip) [s]:").Trim().ToLowerInvariant();
                        string decision = ans switch { "p" or "pass" => "Pass", "f" or "fail" => "Fail", _ => string.Empty };
                        if (decision.Length == 0)
                        {
                            Console.WriteLine("Skipped (kept NeedsReview).");
                            continue;
                        }
                        var notes = Prompt("Optional notes (Enter to skip):");
                        if (auditor.ResolveReview(r.Id, decision, notes, out var newOutcome))
                        {
                            updated[r.Id] = newOutcome;
                            Console.WriteLine($"  [{r.Id}] -> {newOutcome}");
                        }
                        else
                        {
                            Console.WriteLine($"  Could not update {r.Id}.");
                        }
                    }

                    // Reflect the operator's decisions in the in-memory results so the
                    // summary and exit code below match the persisted report.
                    if (updated.Count > 0)
                        results = results.Select(r => updated.TryGetValue(r.Id, out var o) ? r with { Outcome = o } : r).ToArray();
                }
            }

            Console.WriteLine();
            Console.WriteLine("Summary:");
            foreach (var g in results.GroupBy(r => r.Outcome ?? "Unknown", StringComparer.OrdinalIgnoreCase).OrderBy(g => g.Key))
                Console.WriteLine($"  {g.Key,-12}: {g.Count()}");

            var resultsDir = Path.Combine(Directory.GetCurrentDirectory(), "results");
            var jsonDefault = Path.Combine(resultsDir, "checklist_results.json");
            Console.WriteLine();
            Console.WriteLine($"Results JSON : {jsonDefault}");
            Console.WriteLine($"Report       : {Path.Combine(resultsDir, "final_report.md")}");

            var jsonOut = GetOption(opts, "json");
            if (!string.IsNullOrWhiteSpace(jsonOut))
            {
                try
                {
                    var dir = Path.GetDirectoryName(Path.GetFullPath(jsonOut));
                    if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);
                    File.Copy(jsonDefault, jsonOut, overwrite: true);
                    Console.WriteLine($"Copied JSON to: {jsonOut}");
                }
                catch (Exception ex)
                {
                    Console.Error.WriteLine($"Warning: could not write --json '{jsonOut}': {ex.Message}");
                }
            }

            // Script/CI friendly: non-zero exit if any item hard-failed.
            bool anyFail = results.Any(r => string.Equals(r.Outcome, "Fail", StringComparison.OrdinalIgnoreCase));
            return anyFail ? 1 : 0;
        }

        static void PrintEvaluateUsage()
        {
            Console.WriteLine();
            Console.WriteLine("Usage: sqlauditor evaluate [options]");
            Console.WriteLine();
            Console.WriteLine("Any option not supplied is prompted for interactively (server, then");
            Console.WriteLine("login details, then checklist IDs).");
            Console.WriteLine();
            Console.WriteLine("Options:");
            Console.WriteLine("  --items <ids>       Comma-separated checklist IDs to evaluate.");
            Console.WriteLine("  --server <host>     SQL Server FQDN/host[,port]. Or set SQLAUDITOR_SERVER.");
            Console.WriteLine("  --user <name>       SQL login username. Or set SQLAUDITOR_SQL_USER.");
            Console.WriteLine("                      Omit for Windows Integrated authentication.");
            Console.WriteLine("  --password <pw>     SQL login password. Or set SQLAUDITOR_SQL_PASSWORD.");
            Console.WriteLine("  --json <path>       Also copy results JSON to this path.");
            Console.WriteLine("  --interactive       Force prompting to mark manual-review items pass/fail.");
            Console.WriteLine("                      (Auto-enabled in an interactive terminal.)");
            Console.WriteLine("  --copilot           Non-interactive; emit NeedsReview items for the");
            Console.WriteLine("                      Copilot CLI skill to review via 'resolve_review', and");
            Console.WriteLine("                      script items for it to word via 'enrich_result'.");
            Console.WriteLine("  --help              Show this help.");
            Console.WriteLine();
            Console.WriteLine("The CLI performs no LLM calls: Copilot CLI is the AI layer. No .env or");
            Console.WriteLine("PROVIDER_BASE_URL / PROVIDER_API_KEY / MODEL configuration is required.");
            Console.WriteLine();
            Console.WriteLine("Examples:");
            Console.WriteLine("  sqlauditor evaluate                                  (fully interactive)");
            Console.WriteLine("  sqlauditor evaluate --items 1.1.2,3.1.2 --server localhost");
        }

        // Emits NeedsReview items in a clearly delimited block so the Copilot CLI skill
        // can generate tailored verification guidance, help the user decide, and record
        // each decision with 'resolve_review'. Mirrors the MCP server's review format and
        // reuses the same baseline guidance (from the shared engine). The CLI makes no AI calls.
        static void PrintNeedsReviewForCopilot(
            SQLAuditor.Lib.ChecklistResult[] results,
            string[] requestedOrder,
            System.Collections.Generic.IReadOnlyDictionary<string, SQLAuditor.Lib.ChecklistItem> itemLookup)
        {
            // Preserve the order the user requested via --items.
            var order = new System.Collections.Generic.Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
            for (int i = 0; i < requestedOrder.Length; i++) order[requestedOrder[i]] = i;

            var pending = results
                .Where(r => string.Equals(r.Outcome, "NeedsReview", StringComparison.OrdinalIgnoreCase)
                         && (r.Technique?.Contains("Manual", StringComparison.OrdinalIgnoreCase) ?? false))
                .OrderBy(r => order.TryGetValue(r.Id, out var idx) ? idx : int.MaxValue)
                .ThenBy(r => r.Id, StringComparer.OrdinalIgnoreCase)
                .ToList();

            Console.WriteLine();
            Console.WriteLine("=== COPILOT REVIEW REQUIRED ===");
            if (pending.Count == 0)
            {
                Console.WriteLine("No items need manual review.");
                Console.WriteLine("=== END COPILOT REVIEW REQUIRED ===");
                return;
            }

            Console.WriteLine($"{pending.Count} item(s) were not decided by the deterministic scripts and need review.");
            Console.WriteLine("This CLI performs NO AI/LLM calls — YOU (GitHub Copilot CLI) are the reviewer. For EACH item below you MUST:");
            Console.WriteLine("  1. Present the guidance to the user using EXACTLY this output format (fill each section with specific, item-tailored content — exact T-SQL to run, settings/objects to inspect in SSMS):");
            Console.WriteLine("       Checklist: <checklist title>");
            Console.WriteLine("       Objective: <one sentence explaining what is being verified>");
            Console.WriteLine("       ");
            Console.WriteLine("       ## Manual Verification Steps:");
            Console.WriteLine("       1. ...");
            Console.WriteLine("       2. ... (include SQL queries in ```sql code blocks whenever required)");
            Console.WriteLine("       ");
            Console.WriteLine("       ## What indicates a PASS and a FAIL");
            Console.WriteLine("       Pass:");
            Console.WriteLine("       - ...");
            Console.WriteLine("       Fail:");
            Console.WriteLine("       - ...");
            Console.WriteLine("       ");
            Console.WriteLine("       ## Recommended Actions (if failed)");
            Console.WriteLine("       - ...");
            Console.WriteLine("     Do NOT add extra sections or headings outside this format.");
            Console.WriteLine("  2. Ask the user for their finding / evidence.");
            Console.WriteLine("  3. Decide Pass or Fail together with the user, then record it with the resolve_review command.");
            Console.WriteLine("Do NOT write a final summary until every item has been resolved.");

            foreach (var r in pending)
            {
                Console.WriteLine();
                Console.WriteLine($"--- {r.Id}: {r.Description} ---");
                if (itemLookup.TryGetValue(r.Id, out var it))
                {
                    if (!string.IsNullOrWhiteSpace(it.Category)) Console.WriteLine($"Area/Category: {it.Category}");
                    if (!string.IsNullOrWhiteSpace(it.Verification)) Console.WriteLine($"Verification objective: {it.Verification}");
                }
                if (!string.IsNullOrWhiteSpace(r.Evidence))
                {
                    Console.WriteLine("Baseline verification steps (use as your source, then render it in the required output format above — do NOT invent a different structure):");
                    Console.WriteLine(r.Evidence.Trim());
                }
                else
                {
                    Console.WriteLine("(No baseline guidance was generated for this item.)");
                }
                Console.WriteLine($"After the user decides, run: sql-auditor resolve_review --id {r.Id} --decision <pass|fail> --notes \"<user's rationale>\"");
            }
            Console.WriteLine("=== END COPILOT REVIEW REQUIRED ===");
        }

        // ---------------------------------------------------------------------
        // Non-interactive CLI: `resolve_review` subcommand
        // Reuses Auditor.ResolveReview to patch results/checklist_results.json and
        // regenerate results/final_report.md. Used by the Copilot CLI skill to record
        // Pass/Fail decisions without re-running the evaluation.
        // ---------------------------------------------------------------------
        static int RunResolveReviewCommand(string[] args)
        {
            var opts = ParseOptions(args);
            if (opts.ContainsKey("help") || opts.ContainsKey("h"))
            {
                Console.WriteLine("Usage: sqlauditor resolve_review --id <id> --decision <pass|fail|needsreview> [--notes <text>]");
                return 0;
            }

            var id = GetOption(opts, "id");
            var decision = GetOption(opts, "decision");
            var notes = GetOption(opts, "notes");

            if (string.IsNullOrWhiteSpace(id))
            {
                Console.Error.WriteLine("Error: --id is required.");
                return 2;
            }
            if (string.IsNullOrWhiteSpace(decision))
            {
                Console.Error.WriteLine("Error: --decision is required (pass, fail, or needsreview).");
                return 2;
            }

            var auditor = new SQLAuditor.Lib.Auditor(string.Empty);
            if (auditor.ResolveReview(id, decision, notes, out var newOutcome))
            {
                Console.WriteLine($"Updated [{id}] -> {newOutcome}. results/checklist_results.json and results/final_report.md regenerated.");
                return 0;
            }

            Console.Error.WriteLine($"Could not resolve '{id}'. Ensure 'evaluate' has run (results file exists), the ID is present, and decision is pass/fail/needsreview.");
            return 2;
        }

        // ---------------------------------------------------------------------
        // Non-interactive CLI: `enrich_result` subcommand
        // Writes the audit wording Copilot authored for a script-evaluated item into
        // results/checklist_results.json and regenerates the report. Outcome, Score,
        // Severity and Databases Verified are script-derived and cannot be set here.
        // ---------------------------------------------------------------------
        static int RunEnrichResultCommand(string[] args)
        {
            var opts = ParseOptions(args);
            if (opts.ContainsKey("help") || opts.ContainsKey("h"))
            {
                Console.WriteLine("Usage: sqlauditor enrich_result --id <id> [--finding <text>] [--evidence <text>] [--risk <text>] [--recommendation <text>]");
                return 0;
            }

            var id = GetOption(opts, "id");
            if (string.IsNullOrWhiteSpace(id))
            {
                Console.Error.WriteLine("Error: --id is required.");
                return 2;
            }

            var finding = GetOption(opts, "finding");
            var evidence = GetOption(opts, "evidence");
            var risk = GetOption(opts, "risk") ?? GetOption(opts, "riskimpact");
            var recommendation = GetOption(opts, "recommendation");

            var auditor = new SQLAuditor.Lib.Auditor(string.Empty);
            if (auditor.ApplyEnrichment(id, finding, evidence, risk, recommendation))
            {
                Console.WriteLine($"Enriched [{id}]. results/checklist_results.json and results/final_report.md regenerated.");
                return 0;
            }

            Console.Error.WriteLine($"Could not enrich '{id}'. Ensure 'evaluate' has run (results file exists), the ID is present, and at least one field was supplied.");
            return 2;
        }

        // ---------------------------------------------------------------------
        // Non-interactive CLI: `generate_scripts` subcommand
        // Copilot CLI is the AI: this prints the generator system prompt plus a per-item
        // request so Copilot can author each read-only script, then save it with
        // `save_generated_script`. It never calls an LLM and needs no SQL Server.
        // ---------------------------------------------------------------------
        static async Task<int> RunGenerateScriptsCommandAsync(string[] args)
        {
            var opts = ParseOptions(args);
            if (opts.ContainsKey("help") || opts.ContainsKey("h"))
            {
                Console.WriteLine("Usage: sqlauditor generate_scripts --items <ids>");
                Console.WriteLine("  Example: sqlauditor generate_scripts --items 1.1.2,3.1.1");
                return 0;
            }

            var itemsCsv = GetOption(opts, "items");
            if (string.IsNullOrWhiteSpace(itemsCsv))
            {
                Console.Error.WriteLine("Error: --items is required (comma-separated checklist IDs, e.g. 1.1.2,3.1.1).");
                return 2;
            }

            var ids = itemsCsv
                .Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
                .Distinct(StringComparer.OrdinalIgnoreCase)
                .ToArray();

            try
            {
                var (checklistItems, unknown) = await SQLAuditor.Lib.ScriptGenerationSkill.LoadItemsAsync(ids);
                if (checklistItems.Count == 0)
                {
                    Console.Error.WriteLine("Error: none of the requested checklist IDs exist. Unknown: " + string.Join(", ", unknown));
                    return 2;
                }

                var text = SQLAuditor.Lib.ScriptGenerationSkill.BuildGenerationInstructions(
                    checklistItems,
                    unknown,
                    "run: sqlauditor save_generated_script --id <id> --response-file <path-to-raw-response-file>");
                Console.WriteLine(text);
                return 0;
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine($"Error: {ex.Message}");
                Console.Error.WriteLine("Hint: run this command from the 'SQL-Auditing-tool' folder so the checklist can be located.");
                return 3;
            }
        }

        // ---------------------------------------------------------------------
        // Non-interactive CLI: `save_generated_script` subcommand
        // Validates and saves one Copilot-generated script (used after generate_scripts).
        // The raw response can be supplied via --response-file <path> (preferred for large
        // scripts) or inline via --response "<text>".
        // ---------------------------------------------------------------------
        static async Task<int> RunSaveGeneratedScriptCommandAsync(string[] args)
        {
            var opts = ParseOptions(args);
            if (opts.ContainsKey("help") || opts.ContainsKey("h"))
            {
                Console.WriteLine("Usage: sqlauditor save_generated_script --id <id> (--response-file <path> | --response \"<raw response>\")");
                return 0;
            }

            var id = GetOption(opts, "id");
            if (string.IsNullOrWhiteSpace(id))
            {
                Console.Error.WriteLine("Error: --id is required.");
                return 2;
            }

            var response = GetOption(opts, "response");
            var responseFile = GetOption(opts, "response-file") ?? GetOption(opts, "responsefile");
            if (string.IsNullOrWhiteSpace(response) && !string.IsNullOrWhiteSpace(responseFile))
            {
                if (!File.Exists(responseFile))
                {
                    Console.Error.WriteLine($"Error: --response-file not found: {responseFile}");
                    return 2;
                }
                response = await File.ReadAllTextAsync(responseFile);
            }

            if (string.IsNullOrWhiteSpace(response))
            {
                Console.Error.WriteLine("Error: supply the generated script via --response-file <path> or --response \"<text>\".");
                return 2;
            }

            try
            {
                var result = await SQLAuditor.Lib.ScriptGenerationSkill.SaveGeneratedScriptAsync(id, response);
                Console.WriteLine(result);
                // A validation failure is surfaced to Copilot as a non-zero exit so it retries.
                return result.StartsWith("VALIDATION FAILED", StringComparison.OrdinalIgnoreCase)
                    || result.StartsWith("Error", StringComparison.OrdinalIgnoreCase) ? 2 : 0;
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine($"Error: {ex.Message}");
                Console.Error.WriteLine("Hint: run this command from the 'SQL-Auditing-tool' folder so the checklist can be located.");
                return 3;
            }
        }

        // ---------------------------------------------------------------------
        // Non-interactive CLI: `show_reports` subcommand (also via --show-reports)
        // ---------------------------------------------------------------------
        static int RunShowReportsCommand(string[] args)
        {
            var opts = ParseOptions(args);
            var kind = GetOption(opts, "kind") ?? "summary";
            var resultsDir = Path.Combine(Directory.GetCurrentDirectory(), "results");
            var path = string.Equals(kind, "json", StringComparison.OrdinalIgnoreCase)
                ? Path.Combine(resultsDir, "checklist_results.json")
                : Path.Combine(resultsDir, "final_report.md");

            if (!File.Exists(path))
            {
                Console.Error.WriteLine($"No report found at {path}. Run 'evaluate' first.");
                return 2;
            }

            Console.WriteLine(File.ReadAllText(path));
            return 0;
        }

        static System.Collections.Generic.Dictionary<string, string> ParseOptions(string[] args)
        {
            var opts = new System.Collections.Generic.Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            // args[0] is the subcommand ("evaluate"); parse the remainder.
            for (int i = 1; i < args.Length; i++)
            {
                var a = args[i];
                if (!a.StartsWith("--", StringComparison.Ordinal)) continue;
                var key = a.Substring(2);
                string val = "true";
                var eq = key.IndexOf('=');
                if (eq >= 0)
                {
                    val = key.Substring(eq + 1);
                    key = key.Substring(0, eq);
                }
                else if (i + 1 < args.Length && !args[i + 1].StartsWith("--", StringComparison.Ordinal))
                {
                    val = args[++i];
                }
                opts[key] = val;
            }
            return opts;
        }

        static string? GetOption(System.Collections.Generic.Dictionary<string, string> opts, string key)
            => opts.TryGetValue(key, out var v) ? v : null;

        static string Prompt(string msg)
        {
            Console.Write(msg + " ");
            return Console.ReadLine() ?? string.Empty;
        }

        // Prompts repeatedly until a non-empty value is entered. Returns empty
        // only if input is exhausted (e.g. redirected stdin) to avoid an
        // infinite loop in non-interactive contexts.
        static string PromptRequired(string msg, string requiredHint)
        {
            while (true)
            {
                Console.Write(msg + " ");
                var line = Console.ReadLine();
                if (line == null) return string.Empty; // EOF / no interactive input
                if (!string.IsNullOrWhiteSpace(line)) return line;
                Console.WriteLine($"  {requiredHint} Please try again.");
            }
        }

        static string PromptSecret(string msg)
        {
            Console.Write(msg + " ");

            // When input is redirected (piped/non-interactive), ReadKey is unavailable;
            // fall back to a normal read so the value is still captured.
            if (Console.IsInputRedirected)
            {
                return Console.ReadLine() ?? string.Empty;
            }

            // Interactive: mask each character with '*' so the user gets feedback.
            var pass = string.Empty;
            ConsoleKeyInfo key;
            while ((key = Console.ReadKey(true)).Key != ConsoleKey.Enter)
            {
                if (key.Key == ConsoleKey.Backspace && pass.Length > 0)
                {
                    pass = pass[..^1];
                    Console.Write("\b \b");
                }
                else if (!char.IsControl(key.KeyChar))
                {
                    pass += key.KeyChar;
                    Console.Write("*");
                }
            }
            Console.WriteLine();
            return pass;
        }
    }
}

