using System;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using SQLAuditor.Lib;

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

            // List the most recent evaluation runs across all servers.
            if (args.Length > 0 && string.Equals(args[0], "history", StringComparison.OrdinalIgnoreCase))
            {
                return RunHistoryCommand(args);
            }

            // Rerun (or edit) a previous run, overwriting its reports in the same folder.
            if (args.Length > 0 && string.Equals(args[0], "rerun", StringComparison.OrdinalIgnoreCase))
            {
                return await RunRerunCommandAsync(args);
            }

            // Record a review decision for a NeedsReview item (used by the Copilot CLI skill).
            if (args.Length > 0 && string.Equals(args[0], "resolve_review", StringComparison.OrdinalIgnoreCase))
            {
                return RunResolveReviewCommand(args);
            }

            // Attach or show the Git repository / pipeline / documentation evidence for the run.
            if (args.Length > 0 && string.Equals(args[0], "evidence", StringComparison.OrdinalIgnoreCase))
            {
                return await RunEvidenceCommandAsync(args);
            }

            // Export every manual checklist item, with its verification steps, to the shared CSV
            // so the reviewer can decide them offline - the same workflow as the desktop app.
            if (args.Length > 0 && string.Equals(args[0], "export_manual_csv", StringComparison.OrdinalIgnoreCase))
            {
                return await RunExportManualCsvCommandAsync(args);
            }

            // Apply the Pass/Fail decisions from a filled manual CSV back onto the current run.
            if (args.Length > 0 && string.Equals(args[0], "import_manual_csv", StringComparison.OrdinalIgnoreCase))
            {
                return RunImportManualCsvCommand(args);
            }

            // Record Copilot-authored audit wording for a script-evaluated item.
            if (args.Length > 0 && string.Equals(args[0], "enrich_result", StringComparison.OrdinalIgnoreCase))
            {
                return RunEnrichResultCommand(args);
            }

            // Add a CUSTOM checklist item under an existing Area/Sub-area (NOT evaluation).
            // Copilot CLI is the AI: this surfaces the guardrail, semantic-match and classification
            // prompts, reserves the ID, serves the script generation prompt, and only writes to the
            // custom configuration once the user approves.
            if (args.Length > 0 &&
                (string.Equals(args[0], "configure_checklist", StringComparison.OrdinalIgnoreCase)
                 || string.Equals(args[0], "configure-checklist", StringComparison.OrdinalIgnoreCase)))
            {
                return await RunConfigureChecklistCommandAsync(args);
            }

            // Print a previously-generated report (summary Markdown or raw JSON).
            if (args.Length > 0 && (string.Equals(args[0], "show_reports", StringComparison.OrdinalIgnoreCase) || args.Contains("--show-reports")))
            {
                return RunShowReportsCommand(args);
            }

            // Explicitly refresh historical results and regenerate the five-file report suite.
            if (args.Length > 0 && string.Equals(args[0], "generate_report", StringComparison.OrdinalIgnoreCase))
            {
                return RunGenerateReportCommand(args);
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

            var (interactiveProfile, interactiveAuthError) = ResolveAuthProfile(
                new System.Collections.Generic.Dictionary<string, string>(StringComparer.OrdinalIgnoreCase),
                fqdn,
                nonInteractive: false);
            if (interactiveProfile is null)
            {
                Console.Error.WriteLine(interactiveAuthError);
                return 2;
            }
            Console.WriteLine($"Authentication: {interactiveProfile.Describe()}");

            var auditor = new SQLAuditor.Lib.Auditor(interactiveProfile);

            while (true)
            {
                Console.WriteLine();
                Console.WriteLine("1) Run deterministic scripts (from Backend/checklists/Scripts/sql)");
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

        // ---------------------------------------------------------------------
        // `history` subcommand: list the most recent runs across all servers
        // ---------------------------------------------------------------------
        static int RunHistoryCommand(string[] args)
        {
            var opts = ParseOptions(args);
            int count = 5;
            var countOpt = GetOption(opts, "count");
            if (!string.IsNullOrWhiteSpace(countOpt) && int.TryParse(countOpt, out var c) && c > 0) count = c;

            var runs = SQLAuditor.Lib.PreviousEvaluationStore.FindRecentAcrossServers(count);
            if (runs.Count == 0)
            {
                Console.WriteLine("No previous evaluation runs were found under the results/ folder.");
                return 0;
            }

            Console.WriteLine($"{runs.Count} most recent evaluation run(s) across all servers:");
            Console.WriteLine();
            for (int i = 0; i < runs.Count; i++)
            {
                var r = runs[i];
                var m = r.Metadata;
                Console.WriteLine($"[{i + 1}] {m.ServerName}   {r.EvaluatedDisplay}   {r.ScoreDisplay}");
                Console.WriteLine($"     Items: {m.ItemCount}   Status: {m.Status}   Duration: {r.DurationDisplay}");
                Console.WriteLine($"     Run:   {r.RunDirectory}");
                Console.WriteLine();
            }
            Console.WriteLine("Rerun one with:  sqlauditor rerun --run <index-or-path> --manual-results <last-runs|fresh> [--server <host>] [--user <name>] [--items <ids>]");
            return 0;
        }

        // ---------------------------------------------------------------------
        // `rerun` subcommand: re-run a previous run into the SAME folder.
        // With no overrides it reruns exactly; --items / --server act as an edit.
        // ---------------------------------------------------------------------
        static async Task<int> RunRerunCommandAsync(string[] args)
        {
            try
            {
                return await RunRerunCoreAsync(args);
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine($"Error: {ex.Message}");
                return 3;
            }
        }

        static async Task<int> RunRerunCoreAsync(string[] args)
        {
            var opts = ParseOptions(args);
            if (opts.ContainsKey("help") || opts.ContainsKey("h")) { PrintRerunUsage(); return 0; }
            bool copilotMode = opts.ContainsKey("copilot");

            var runArg = GetOption(opts, "run");
            if (string.IsNullOrWhiteSpace(runArg))
            {
                Console.Error.WriteLine("Error: --run <index-or-path> is required. Run 'sqlauditor history' to list runs.");
                return 2;
            }
            var run = ResolveRunSelection(runArg);
            if (run is null)
            {
                Console.Error.WriteLine($"Error: could not find a completed run for '{runArg}'. Run 'sqlauditor history' to list runs.");
                return 2;
            }
            var meta = run.Metadata;

            bool? useHistorical = ResolveManualResultsMode(opts);
            if (useHistorical is null)
            {
                if (copilotMode)
                {
                    Console.WriteLine();
                    Console.WriteLine("=== MANUAL RESULTS SOURCE REQUIRED (rerun) ===");
                    Console.WriteLine("Ask the user how manual items should be handled, then run 'rerun' AGAIN (NOT 'evaluate')");
                    Console.WriteLine($"with the same --run {runArg} plus EXACTLY ONE of:");
                    Console.WriteLine("  --manual-results last-runs     (Option 1 \u2014 reuse the last runs)");
                    Console.WriteLine("  --manual-results fresh         (Option 2 \u2014 evaluate fresh)");
                    Console.WriteLine("Do NOT run 'evaluate' for a rerun \u2014 that creates a new run folder instead of updating the original.");
                    Console.WriteLine("=== END ===");
                    return 2;
                }
                useHistorical = PromptManualResultsMode();
            }

            // Server and authentication are reused from the original run and cannot be changed on
            // rerun/edit; only the checklist items may be overridden.
            string? server = meta.Fqdn;
            if (string.IsNullOrWhiteSpace(server))
            {
                Console.Error.WriteLine("Error: this run predates input capture and has no stored server, so it cannot be rerun. Run 'evaluate' instead.");
                return 2;
            }

            // Replay the authentication method recorded with the original run.
            if (!SqlAuthProfile.TryParseMethod(meta.AuthMethod, out var rerunMethod))
                rerunMethod = SqlAuthMethod.WindowsIntegrated;
            string? user = meta.SqlUser;
            var rerunShell = new SqlAuthProfile { Method = rerunMethod };
            string? pass = null;
            if (rerunShell.RequiresSecret)
            {
                var secretEnv = rerunMethod == SqlAuthMethod.EntraServicePrincipal
                    ? "SQLAUDITOR_ENTRA_CLIENT_SECRET"
                    : "SQLAUDITOR_SQL_PASSWORD";
                pass = GetOption(opts, "password") ?? Environment.GetEnvironmentVariable(secretEnv);
                if (string.IsNullOrWhiteSpace(pass))
                {
                    var secretLabel = SqlAuthProfile.SecretLabelFor(rerunMethod);
                    if (copilotMode)
                    {
                        Console.Error.WriteLine($"Error: {SqlAuthProfile.DisplayNameFor(rerunMethod)} identity '{user}' requires a {secretLabel.ToLowerInvariant()}. Set {secretEnv} in your session.");
                        return 2;
                    }
                    pass = PromptSecret($"{secretLabel} for '{user}':");
                }
            }

            var rerunProfile = new SqlAuthProfile
            {
                Method = rerunMethod,
                Server = server!,
                Database = "master",
                UserId = string.IsNullOrWhiteSpace(user) ? null : user.Trim(),
                Secret = pass,
            };

            var rerunAuthError = rerunProfile.Validate();
            if (rerunAuthError is not null)
            {
                Console.Error.WriteLine($"Error: stored authentication for this run is unusable: {rerunAuthError}");
                return 2;
            }

            // Items: override with --items, else reuse the stored selection.
            var itemsCsv = GetOption(opts, "items");
            string[] ids = !string.IsNullOrWhiteSpace(itemsCsv)
                ? itemsCsv.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries).Distinct(StringComparer.OrdinalIgnoreCase).ToArray()
                : (meta.SelectedItemIds ?? Array.Empty<string>()).ToArray();
            if (ids.Length == 0) { Console.Error.WriteLine("Error: this run has no stored checklist items; pass --items."); return 2; }

            var auditor = new SQLAuditor.Lib.Auditor(rerunProfile);
            var structure = await auditor.GetChecklistStructureAsync();
            var knownIds = new System.Collections.Generic.HashSet<string>(
                structure.SelectMany(s => s.Items).Select(i => i.Id), StringComparer.OrdinalIgnoreCase);
            var validIds = ids.Where(id => knownIds.Contains(id)).ToArray();
            if (validIds.Length == 0) { Console.Error.WriteLine("Error: none of the checklist IDs exist."); return 2; }

            // Databases: reuse the stored scope (null = all user databases), dropping any
            // system database recorded by an older build.
            var storedDatabases = (meta.Databases ?? (System.Collections.Generic.IReadOnlyList<string>)Array.Empty<string>())
                .Where(name => !(string.Equals(name, "master", StringComparison.OrdinalIgnoreCase)
                              || string.Equals(name, "model", StringComparison.OrdinalIgnoreCase)
                              || string.Equals(name, "msdb", StringComparison.OrdinalIgnoreCase)
                              || string.Equals(name, "tempdb", StringComparison.OrdinalIgnoreCase)))
                .ToArray();
            var targetDatabases = storedDatabases.Length > 0 ? storedDatabases : null;

            Console.WriteLine($"Rerunning {validIds.Length} item(s) into the original folder: {run.RunDirectory}");
            Console.WriteLine($"Target server: {server}");
            Console.WriteLine(useHistorical.Value
                ? "Manual items: reusing last-runs results where available."
                : "Manual items: fresh evaluation.");
            Console.WriteLine();

            // Reuse the SAME run folder so the reports are overwritten in place.
            SQLAuditor.Lib.AuditOutputPaths.ResumeRun(run.RunDirectory);
            auditor.LastRunInputs = new SQLAuditor.Lib.RunInputs
            {
                Fqdn = server,
                AuthMethod = SqlAuthProfile.DisplayNameFor(rerunMethod),
                SqlUser = rerunProfile.UserId,
            };

            using var cts = new System.Threading.CancellationTokenSource();
            ConsoleCancelEventHandler onCancel = (_, e) =>
            {
                e.Cancel = true;
                if (!cts.IsCancellationRequested) { Console.WriteLine(); Console.WriteLine("Cancellation requested \u2014 stopping after the current item..."); cts.Cancel(); }
            };
            Console.CancelKeyPress += onCancel;

            SQLAuditor.Lib.ChecklistResult[] results;
            try
            {
                var progress = new Progress<SQLAuditor.Lib.ChecklistResult>(r =>
                {
                    if (string.Equals(r.Outcome, "Evaluating", StringComparison.OrdinalIgnoreCase)) return;
                    Console.WriteLine($"  [{r.Id}] {r.Outcome,-11} ({r.Technique}) - {r.Description}");
                });
                results = await auditor.RunChecklistAsync(
                    progress, null, validIds, cts.Token,
                    useHistorical.Value, generateReports: true,
                    targetDatabases: targetDatabases, reuseActiveRunDirectory: true);
            }
            finally
            {
                Console.CancelKeyPress -= onCancel;
            }

            if (auditor.LastDetectedPlatform is { } rerunPlatform
                && rerunPlatform.Platform != SQLAuditor.Lib.PlatformApplicability.PlatformUnknown)
            {
                Console.WriteLine($"Detected platform: {rerunPlatform.Display} (EngineEdition {rerunPlatform.EngineEdition}).");
                if (auditor.LastPlatformExclusionCount > 0)
                    Console.WriteLine($"{auditor.LastPlatformExclusionCount} item(s) recorded as Not Applicable to this platform - no script ran and no model was called for them.");
            }

            // The CLI engine never calls an LLM, so a rerun must hand the same enrichment and
            // review work back to Copilot as 'evaluate' does. Without this the script items keep
            // null Evidence/RiskImpact/Recommendation.
            if (copilotMode)
            {
                var itemLookup = structure.SelectMany(s => s.Items)
                    .GroupBy(i => i.Id, StringComparer.OrdinalIgnoreCase)
                    .ToDictionary(g => g.Key, g => g.First(), StringComparer.OrdinalIgnoreCase);

                Console.WriteLine();
                Console.WriteLine("NOTE: every enrich_result field also accepts a file form (--finding-file / --evidence-file / --risk-file /");
                Console.WriteLine("      --recommendation-file <path>). Use it whenever the text contains a quote character, otherwise the");
                Console.WriteLine("      shell truncates the value at that quote.");
                Console.Write(SQLAuditor.Lib.Auditor.BuildScriptEnrichmentRequest(
                    results,
                    id => $"sql-auditor enrich_result --id {id} --finding \"<finding>\" --evidence-file \"<file holding the evidence>\" --risk \"<riskImpact>\" --recommendation \"<recommendation>\""));

                PrintNeedsReviewForCopilot(results, validIds, itemLookup);
            }

            Console.WriteLine();
            Console.WriteLine(copilotMode ? "Summary (PROVISIONAL - script verdicts only):" : "Summary:");
            foreach (var g in results.GroupBy(r => r.Outcome ?? "Unknown", StringComparer.OrdinalIgnoreCase).OrderBy(g => g.Key))
                Console.WriteLine($"  {g.Key,-12}: {g.Count()}");
            if (copilotMode)
            {
                Console.WriteLine("Not Applicable is decided during enrichment, so these counts are not final. Once every item has been");
                Console.WriteLine("enriched and reviewed, run 'sql-auditor show_reports' and report ITS counts, which include Not Applicable.");
            }

            var resultsDir = SQLAuditor.Lib.AuditOutputPaths.CurrentRunDirectory;
            Console.WriteLine();
            Console.WriteLine($"Reports updated in the original folder: {resultsDir}");

            bool anyFail = results.Any(r => string.Equals(r.Outcome, "Fail", StringComparison.OrdinalIgnoreCase));
            return anyFail ? 1 : 0;
        }

        // Resolves a --run argument to a stored run: a 1-based index into the recent-runs
        // list, a run directory path, or just the folder name under results/.
        static SQLAuditor.Lib.PreviousEvaluation? ResolveRunSelection(string runArg)
        {
            runArg = runArg.Trim();
            if (int.TryParse(runArg, out var idx) && idx > 0)
            {
                var recent = SQLAuditor.Lib.PreviousEvaluationStore.FindRecentAcrossServers(Math.Max(idx, 5));
                return idx <= recent.Count ? recent[idx - 1] : null;
            }

            var direct = SQLAuditor.Lib.PreviousEvaluationStore.GetRun(runArg);
            if (direct != null) return direct;

            var underResults = Path.Combine(SQLAuditor.Lib.AuditOutputPaths.RootDirectory, runArg);
            return SQLAuditor.Lib.PreviousEvaluationStore.GetRun(underResults);
        }

        static void PrintRerunUsage()
        {
            Console.WriteLine();
            Console.WriteLine("Usage: sqlauditor rerun --run <index-or-path> [options]");
            Console.WriteLine();
            Console.WriteLine("Re-runs a previous evaluation and overwrites its reports in the SAME run");
            Console.WriteLine("folder. The server and authentication are reused from the original run and");
            Console.WriteLine("cannot be changed; only the checklist items may be edited via --items.");
            Console.WriteLine();
            Console.WriteLine("Options:");
            Console.WriteLine("  --run <index|path>  Which run to redo: a number from 'sqlauditor history',");
            Console.WriteLine("                      a run directory path, or a folder name under results/.");
            Console.WriteLine("  --manual-results <last-runs|fresh>  How manual items are handled.");
            Console.WriteLine("  --items <ids>       Override the checklist IDs (edit). Defaults to the stored set.");
            Console.WriteLine("  --password <pw>     SQL login password (only if the run used SQL Login).");
            Console.WriteLine("                      Or set SQLAUDITOR_SQL_PASSWORD.");
            Console.WriteLine("  --copilot           Non-interactive mode for the Copilot CLI skill.");
            Console.WriteLine("  --help              Show this help.");
            Console.WriteLine();
            Console.WriteLine("Examples:");
            Console.WriteLine("  sqlauditor rerun --run 1 --manual-results last-runs");
            Console.WriteLine("  sqlauditor rerun --run 1 --items 1.1.1,2.1.4 --fresh   (edit the selection)");
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

            // --- Step 1: how manual checklist items are handled ---
            // The choice is always the user's; it is never inferred by the CLI or by Copilot.
            bool? useHistoricalManualResults = ResolveManualResultsMode(opts);
            if (useHistoricalManualResults is null)
            {
                if (copilotMode)
                {
                    PrintManualResultsModeQuestion();
                    return 2;
                }
                useHistoricalManualResults = PromptManualResultsMode();
            }

            Console.WriteLine(useHistoricalManualResults.Value
                ? "Manual items: reusing historical_last_run.json from the latest completed run where available."
                : "Manual items: fresh evaluation (previous manual results are not copied).");

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
            var (authProfile, authError) = ResolveAuthProfile(opts, server!, copilotMode);
            if (authProfile is null)
            {
                Console.Error.WriteLine(authError);
                return 2;
            }
            Console.WriteLine($"Authentication: {authProfile.Describe()}");

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

            var auditor = new SQLAuditor.Lib.Auditor(authProfile);

            // --- Step 4: Databases to audit ---
            // The desktop app makes the user pick the databases, so the CLI must ask too:
            // auditing every database silently changes the counts for database-scoped checks.
            string[] availableDatabases;
            try
            {
                availableDatabases = await auditor.GetAvailableDatabasesAsync();
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine($"Error: could not connect to '{server}' to list its databases: {ex.Message}");
                return 2;
            }

            if (availableDatabases.Length == 0)
            {
                Console.Error.WriteLine($"Error: no accessible user database was found on '{server}'; database-scoped checks cannot run.");
                return 2;
            }

            var databaseSpec = GetOption(opts, "databases") ?? GetOption(opts, "db");
            if (string.IsNullOrWhiteSpace(databaseSpec))
            {
                if (copilotMode)
                {
                    PrintDatabaseSelectionQuestion(server!, availableDatabases);
                    return 2;
                }
                databaseSpec = PromptDatabaseSelection(availableDatabases);
            }

            if (!TryResolveDatabaseSelection(databaseSpec, availableDatabases, out var targetDatabases, out var databaseError))
            {
                Console.Error.WriteLine("Error: " + databaseError);
                Console.Error.WriteLine("Available user databases: " + string.Join(", ", availableDatabases));
                return 2;
            }

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

            // Evidence. The desktop app offers this before the run, so the CLI asks too: without
            // it every documentation and process item comes back as manual review.
            var evidenceSpec = ResolveEvidenceSpec(opts);
            if (evidenceSpec == null)
            {
                if (copilotMode)
                {
                    PrintEvidenceQuestion();
                    return 2;
                }
                evidenceSpec = PromptEvidenceSpec();
            }

            Console.WriteLine($"Evaluating {validIds.Length} checklist item(s): {string.Join(", ", validIds)}");
            Console.WriteLine($"Target server: {server}");
            Console.WriteLine($"Target databases ({targetDatabases.Length}): {string.Join(", ", targetDatabases)}");
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
                // Console has no synchronization context, so these callbacks arrive on pool threads
                // from every evaluation stage at once.
                lock (announced)
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
                }
            });

            // Record the server/auth for this run so it can be rerun or edited later.
            auditor.LastRunInputs = new SQLAuditor.Lib.RunInputs
            {
                Fqdn = server,
                AuthMethod = SqlAuthProfile.DisplayNameFor(authProfile.Method),
                SqlUser = authProfile.UserId,
            };

            SQLAuditor.Lib.ChecklistResult[] results;
            try
            {
                // Non-interactive: no user prompts. Manual-only items resolve to NeedsReview.
                // The complete report suite is generated from the persisted result set.
                results = await auditor.RunChecklistAsync(
                    progress, null, validIds, cts.Token,
                    useHistoricalManualResults.Value,
                    generateReports: true,
                    targetDatabases: targetDatabases);
            }
            finally
            {
                Console.CancelKeyPress -= onCancel;
            }

            if (auditor.LastDetectedPlatform is { } detectedPlatform
                && detectedPlatform.Platform != SQLAuditor.Lib.PlatformApplicability.PlatformUnknown)
            {
                Console.WriteLine($"Detected platform: {detectedPlatform.Display} (EngineEdition {detectedPlatform.EngineEdition}).");
                if (auditor.LastPlatformExclusionCount > 0)
                    Console.WriteLine($"{auditor.LastPlatformExclusionCount} item(s) recorded as Not Applicable to this platform - no script ran and no model was called for them.");
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

            // Attached after the run so the manifest lands in this run's directory.
            var evidenceContext = await AttachEvaluateEvidenceAsync(opts, evidenceSpec);
            if (evidenceContext is { } attached && attached.Sources.Count > 0)
            {
                Console.WriteLine();
                Console.WriteLine(SQLAuditor.Lib.EvidenceStore.Describe(attached));
            }

            // In Copilot mode, surface the NeedsReview items in a clearly delimited block
            // so the Copilot CLI skill can act as the reviewer (tailor guidance + decide),
            // and the script-evaluated items so it can author their audit wording.
            if (copilotMode)
            {
                Console.WriteLine();
                Console.WriteLine("NOTE: every enrich_result field also accepts a file form (--finding-file / --evidence-file / --risk-file /");
                Console.WriteLine("      --recommendation-file <path>). Use it whenever the text contains a quote character, otherwise the");
                Console.WriteLine("      shell truncates the value at that quote.");
                Console.Write(SQLAuditor.Lib.Auditor.BuildScriptEnrichmentRequest(
                    results,
                    id => $"sql-auditor enrich_result --id {id} --finding \"<finding>\" --evidence-file \"<file holding the evidence>\" --risk \"<riskImpact>\" --recommendation \"<recommendation>\""));

                if (manualReviewItems.Count > 0)
                {
                    Console.WriteLine();
                    Console.Write(SQLAuditor.Lib.EvidenceAttribution.BuildReviewRequest(
                        manualReviewItems.Select(r => r.Id), evidenceContext));
                    Console.WriteLine();
                    Console.WriteLine("Attach more evidence with: sql-auditor evidence add --path <folder> | --git <https clone url> | --file <path>");
                }

                PrintNeedsReviewForCopilot(results, validIds, itemLookup);
            }

            // Manual items are decided through the shared CSV workflow, exactly as the desktop app
            // does: every manual item and its verification steps are exported in one file, the
            // reviewer fills Decision/Evidence offline, and 'import_manual_csv' applies the lot.
            bool interactive = !copilotMode
                && (opts.ContainsKey("interactive") || opts.ContainsKey("i") || !Console.IsInputRedirected);
            if (interactive && !cts.IsCancellationRequested)
            {
                var manualAuditor = new SQLAuditor.Lib.Auditor(string.Empty);
                var manualRows = await SQLAuditor.Lib.ManualChecklistCsv.BuildExportRowsAsync(manualAuditor);
                if (manualRows.Count > 0)
                {
                    var csvPath = Path.Combine(
                        SQLAuditor.Lib.AuditOutputPaths.CurrentRunDirectory,
                        SQLAuditor.Lib.ManualChecklistCsv.BuildExportFileName(DateTime.Now));
                    try
                    {
                        SQLAuditor.Lib.ManualChecklistCsv.Write(csvPath, manualRows);
                        var undecided = manualRows.Count(r => string.IsNullOrWhiteSpace(r.Decision));
                        Console.WriteLine();
                        Console.WriteLine($"{manualRows.Count} manual checklist item(s) ({undecided} undecided) were exported for offline review:");
                        Console.WriteLine($"  {csvPath}");
                        Console.WriteLine("Fill the 'Decision' column with Pass or Fail and the 'Evidence' column with what you");
                        Console.WriteLine("inspected and found, leaving 'Checklist ID' unchanged, then apply the decisions with:");
                        Console.WriteLine($"  sqlauditor import_manual_csv --file \"{csvPath}\"");
                        Console.WriteLine("Items left undecided stay NeedsReview. Re-importing an edited CSV overwrites earlier decisions.");
                        Console.WriteLine("To produce a report now without waiting for the filled CSV, run 'sqlauditor export_manual_csv --generate',");
                        Console.WriteLine("which marks the undecided manual items Skipped and regenerates the report suite.");
                    }
                    catch (Exception ex)
                    {
                        Console.WriteLine();
                        Console.WriteLine("The manual checklist CSV could not be exported: " + ex.Message);
                        Console.WriteLine("Run 'sqlauditor export_manual_csv' to try again.");
                    }
                }
            }

            Console.WriteLine();
            Console.WriteLine(copilotMode ? "Summary (PROVISIONAL - script verdicts only):" : "Summary:");
            foreach (var g in results.GroupBy(r => r.Outcome ?? "Unknown", StringComparer.OrdinalIgnoreCase).OrderBy(g => g.Key))
                Console.WriteLine($"  {g.Key,-12}: {g.Count()}");
            if (copilotMode)
            {
                Console.WriteLine("Not Applicable is decided during enrichment, so these counts are not final. Once every item has been");
                Console.WriteLine("enriched and reviewed, run 'sql-auditor show_reports' and report ITS counts, which include Not Applicable.");
            }

            var resultsDir = SQLAuditor.Lib.AuditOutputPaths.CurrentRunDirectory;
            var jsonDefault = Path.Combine(resultsDir, "checklist_results.json");
            Console.WriteLine();
            Console.WriteLine($"Results JSON : {jsonDefault}");
            Console.WriteLine($"Report suite : {resultsDir}");
            foreach (var fileName in SqlAuditor.Reporting.ReportSuiteGenerator.FileNames)
                Console.WriteLine($"  {Path.Combine(resultsDir, fileName)}");

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

        // ---------------------------------------------------------------------
        // Authentication. Flags and environment variables win; anything still
        // missing is prompted for. Secrets come only from the environment or a
        // masked prompt, never from an echoed argument in non-interactive mode.
        // ---------------------------------------------------------------------
        static (SqlAuthProfile? Profile, string? Error) ResolveAuthProfile(
            System.Collections.Generic.Dictionary<string, string> opts,
            string server,
            bool nonInteractive)
        {
            var token = GetOption(opts, "auth")
                ?? GetOption(opts, "auth-method")
                ?? Environment.GetEnvironmentVariable("SQLAUDITOR_AUTH_METHOD");

            var user = GetOption(opts, "user")
                ?? GetOption(opts, "client-id")
                ?? Environment.GetEnvironmentVariable("SQLAUDITOR_SQL_USER");

            SqlAuthMethod method;
            if (!string.IsNullOrWhiteSpace(token))
            {
                if (!SqlAuthProfile.TryParseMethod(token, out method))
                    return (null, $"Error: unknown --auth value '{token}'. Supported: {SqlAuthProfile.SupportedTokens}.");
            }
            else if (!string.IsNullOrWhiteSpace(user))
            {
                // Back-compat: a username with no --auth has always meant SQL Login.
                method = SqlAuthMethod.SqlLogin;
            }
            else if (nonInteractive)
            {
                method = SqlAuthMethod.WindowsIntegrated;
            }
            else
            {
                method = PromptAuthMethod();
            }

            var shell = new SqlAuthProfile { Method = method };
            var display = SqlAuthProfile.DisplayNameFor(method);
            var userLabel = SqlAuthProfile.UserIdLabelFor(method);

            if (method == SqlAuthMethod.WindowsIntegrated)
            {
                user = null;
            }
            else if (string.IsNullOrWhiteSpace(user) && shell.RequiresSecret)
            {
                if (nonInteractive)
                    return (null, $"Error: {display} requires {userLabel}. Pass --user (or --client-id), or set SQLAUDITOR_SQL_USER.");
                user = PromptRequired($"{userLabel}:", $"{userLabel} is required.");
            }
            else if (string.IsNullOrWhiteSpace(user) && !nonInteractive && method != SqlAuthMethod.EntraInteractive)
            {
                user = Prompt($"{userLabel} (press Enter to skip):");
            }

            string? secret = null;
            if (shell.RequiresSecret)
            {
                if (method == SqlAuthMethod.EntraServicePrincipal)
                    secret = Environment.GetEnvironmentVariable("SQLAUDITOR_ENTRA_CLIENT_SECRET");
                secret ??= GetOption(opts, "password")
                    ?? Environment.GetEnvironmentVariable("SQLAUDITOR_SQL_PASSWORD");

                if (string.IsNullOrEmpty(secret))
                {
                    var secretLabel = SqlAuthProfile.SecretLabelFor(method);
                    if (nonInteractive)
                    {
                        var envName = method == SqlAuthMethod.EntraServicePrincipal
                            ? "SQLAUDITOR_ENTRA_CLIENT_SECRET"
                            : "SQLAUDITOR_SQL_PASSWORD";
                        return (null, $"Error: {display} for '{user}' has no {secretLabel.ToLowerInvariant()}. Set {envName} in your session.");
                    }
                    secret = PromptSecret($"{secretLabel} for '{user}':");
                }
            }

            var tenantId = GetOption(opts, "tenant-id")
                ?? GetOption(opts, "tenant")
                ?? Environment.GetEnvironmentVariable("SQLAUDITOR_TENANT_ID");

            var profile = new SqlAuthProfile
            {
                Method = method,
                Server = server,
                Database = "master",
                UserId = string.IsNullOrWhiteSpace(user) ? null : user.Trim(),
                Secret = string.IsNullOrEmpty(secret) ? null : secret,
                TenantId = SqlAuthProfile.IsEntraMethod(method) && !string.IsNullOrWhiteSpace(tenantId) ? tenantId.Trim() : null,
                Encrypt = ParseBoolOption(opts, "encrypt"),
                TrustServerCertificate = ParseBoolOption(opts, "trust-server-certificate")
                    ?? ParseBoolOption(opts, "trust"),
            };

            var error = profile.Validate();
            return error is null ? (profile, null) : (null, "Error: " + error);
        }

        static SqlAuthMethod PromptAuthMethod()
        {
            Console.WriteLine("Authentication method:");
            for (var i = 0; i < SqlAuthProfile.AllMethods.Count; i++)
                Console.WriteLine($"  {i + 1}) {SqlAuthProfile.DisplayNameFor(SqlAuthProfile.AllMethods[i])}");

            while (true)
            {
                var answer = Prompt($"Choose [1-{SqlAuthProfile.AllMethods.Count}]:");
                if (string.IsNullOrWhiteSpace(answer)) return SqlAuthMethod.WindowsIntegrated;
                if (SqlAuthProfile.TryParseMethod(answer, out var parsed)) return parsed;
                Console.WriteLine("  Unrecognised choice. Please try again.");
            }
        }

        static bool? ParseBoolOption(System.Collections.Generic.Dictionary<string, string> opts, string key)
        {
            var raw = GetOption(opts, key);
            if (raw is null) return null;
            if (string.IsNullOrWhiteSpace(raw)) return true;
            return raw.Trim().ToLowerInvariant() is "1" or "true" or "yes" or "y" or "on";
        }

        static void PrintEvaluateUsage()
        {
            Console.WriteLine();
            Console.WriteLine("Usage: sqlauditor evaluate [options]");
            Console.WriteLine();
            Console.WriteLine("Any option not supplied is prompted for interactively (manual-results");
            Console.WriteLine("source, then server, then login details, then checklist IDs, then databases).");
            Console.WriteLine();
            Console.WriteLine("Options:");
            Console.WriteLine("  --manual-results <last-runs|fresh>");
            Console.WriteLine("                      How manual/AI-Manual items are handled: reuse the results");
            Console.WriteLine("                      recorded in the latest run's historical_last_run.json, or evaluate");
            Console.WriteLine("                      them fresh. Aliases: --use-last-runs / --fresh.");
            Console.WriteLine("  --items <ids>       Comma-separated checklist IDs to evaluate.");
            Console.WriteLine("  --server <host>     SQL Server FQDN/host[,port]. Or set SQLAUDITOR_SERVER.");
            Console.WriteLine("  --databases <names> Comma-separated user databases the database-scoped checks");
            Console.WriteLine("                      run against, or 'all'. System databases are never audited.");
            Console.WriteLine("  --auth <method>     Authentication method. Or set SQLAUDITOR_AUTH_METHOD. One of:");
            Console.WriteLine("                        windows                  Windows Integrated (default)");
            Console.WriteLine("                        sql                      SQL Login");
            Console.WriteLine("                        entra-interactive        Entra browser sign-in (MFA)");
            Console.WriteLine("                        entra-service-principal  Client ID + client secret");
            Console.WriteLine("                        entra-managed-identity   Managed identity of this host");
            Console.WriteLine("  --user <name>       SQL login name, Entra UPN, or client ID (alias: --client-id).");
            Console.WriteLine("                      Or set SQLAUDITOR_SQL_USER. Omitting it with no --auth means");
            Console.WriteLine("                      Windows Integrated authentication.");
            Console.WriteLine("  --password <pw>     SQL login password. Or set SQLAUDITOR_SQL_PASSWORD.");
            Console.WriteLine("                      Service principal secrets: set SQLAUDITOR_ENTRA_CLIENT_SECRET.");
            Console.WriteLine("  --tenant-id <guid>  Entra tenant, recorded in the run metadata. Or set SQLAUDITOR_TENANT_ID.");
            Console.WriteLine("  --encrypt <bool>    Encrypt the connection. Defaults to true.");
            Console.WriteLine("  --trust-server-certificate <bool>");
            Console.WriteLine("                      Defaults to true for Windows/SQL auth and false for Entra.");
            Console.WriteLine("  --json <path>       Also copy results JSON to this path.");
            Console.WriteLine("  --evidence-path <folders>");
            Console.WriteLine("                      Comma-separated local folders (a cloned repo, a docs folder) to");
            Console.WriteLine("                      attach as evidence so documentation and process items can be");
            Console.WriteLine("                      decided from artefacts instead of by interview.");
            Console.WriteLine("  --evidence-git <url>");
            Console.WriteLine("                      An https:// Git URL to shallow-clone and index as evidence.");
            Console.WriteLine("                      Private repos authenticate from SQLAUDITOR_GIT_TOKEN.");
            Console.WriteLine("  --evidence-ref <branch|tag>");
            Console.WriteLine("                      Branch or tag to clone when --evidence-git is used.");
            Console.WriteLine("  --evidence-file <paths>");
            Console.WriteLine("                      Comma-separated individual files to attach as evidence.");
            Console.WriteLine("  --no-evidence       The user has no evidence to attach. Without any of the");
            Console.WriteLine("                      --evidence-* flags or this one, evaluate stops and asks.");
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
            Console.WriteLine("  sqlauditor evaluate --items 1.1.2,3.1.2 --server localhost --databases Sales --fresh");
            Console.WriteLine("  sqlauditor evaluate --items 11.1.1-11.4.5 --server localhost --databases all --copilot \\");
            Console.WriteLine("      --fresh --evidence-path C:\\src\\datawarehouse");
        }

        // ---------------------------------------------------------------------
        // Manual-results source: reuse the last runs, or evaluate fresh.
        // The user always decides; neither the CLI nor Copilot may pick for them.
        // ---------------------------------------------------------------------
        static bool? ResolveManualResultsMode(System.Collections.Generic.Dictionary<string, string> opts)
        {
            var mode = GetOption(opts, "manual-results") ?? GetOption(opts, "manualresults");
            if (!string.IsNullOrWhiteSpace(mode))
            {
                switch (mode.Trim().ToLowerInvariant())
                {
                    case "1":
                    case "last":
                    case "last-runs":
                    case "lastruns":
                    case "historical":
                    case "reuse":
                        return true;
                    case "2":
                    case "fresh":
                    case "new":
                    case "none":
                        return false;
                }
            }

            if (opts.ContainsKey("use-last-runs") || opts.ContainsKey("use-historical")) return true;
            if (opts.ContainsKey("fresh")) return false;
            return null;
        }

        static bool PromptManualResultsMode()
        {
            var available = SQLAuditor.Lib.HistoricalManualResultsStore.AvailableIds().Count;

            Console.WriteLine();
            Console.WriteLine("How should manual checklist items be handled?");
            Console.WriteLine("  1) Use the Last Runs  — Do you want me to use the last runs results for the manual steps?");
            Console.WriteLine("  2) Fresh Evaluation   — Do you want to evaluate the checklist items fresh (do not copy manual results from previous runs)?");
            Console.WriteLine(available > 0
                ? $"     ({available} manual result(s) available in results/{SQLAuditor.Lib.HistoricalManualResultsStore.FileName})"
                : $"     (no results/{SQLAuditor.Lib.HistoricalManualResultsStore.FileName} yet — option 1 falls back to a fresh manual evaluation)");

            if (Console.IsInputRedirected)
            {
                Console.WriteLine("Non-interactive session: defaulting to a fresh evaluation. Pass --manual-results last-runs to reuse.");
                return false;
            }

            while (true)
            {
                var ans = Prompt("Choose [1/2]:").Trim().ToLowerInvariant();
                if (ans is "1" or "last" or "last-runs") return true;
                if (ans is "2" or "fresh") return false;
                Console.WriteLine("Enter 1 (use the last runs) or 2 (fresh evaluation).");
            }
        }

        static void PrintManualResultsModeQuestion()
        {
            var available = SQLAuditor.Lib.HistoricalManualResultsStore.AvailableIds().Count;

            Console.WriteLine();
            Console.WriteLine("=== MANUAL RESULTS SOURCE REQUIRED ===");
            Console.WriteLine("Before any evaluation starts, the user must choose how manual checklist items are handled.");
            Console.WriteLine("Ask the user these two options and wait for their answer — never decide this yourself:");
            Console.WriteLine("  Option 1 — Use the Last Runs:");
            Console.WriteLine("      \"Do you want me to use the last runs results for the manual steps?\"");
            Console.WriteLine("  Option 2 — Fresh Evaluation:");
            Console.WriteLine("      \"Do you want to evaluate the checklist items fresh (do not copy manual results from previous runs)?\"");
            Console.WriteLine(available > 0
                ? $"results/{SQLAuditor.Lib.HistoricalManualResultsStore.FileName} currently holds {available} reusable manual result(s)."
                : $"results/{SQLAuditor.Lib.HistoricalManualResultsStore.FileName} does not exist yet, so Option 1 falls back safely to a fresh manual evaluation.");
            Console.WriteLine("Then run evaluate again, adding EXACTLY ONE of:");
            Console.WriteLine("  --manual-results last-runs     (Option 1)");
            Console.WriteLine("  --manual-results fresh         (Option 2)");
            Console.WriteLine("=== END MANUAL RESULTS SOURCE REQUIRED ===");
        }

        // ---------------------------------------------------------------------
        // Database scope: which user databases the database-scoped checks run against.
        // Mirrors the desktop app's database picker so all three entry points audit
        // the same set and report the same Pass/Fail/Not Applicable counts.
        // ---------------------------------------------------------------------
        static string PromptDatabaseSelection(string[] available)
        {
            Console.WriteLine();
            Console.WriteLine("Which databases should be audited? (system databases are never audit targets)");
            for (int i = 0; i < available.Length; i++)
                Console.WriteLine($"  {i + 1}) {available[i]}");
            Console.WriteLine("  a) All databases");

            if (Console.IsInputRedirected)
            {
                Console.WriteLine("Non-interactive session: defaulting to all user databases. Pass --databases to narrow the scope.");
                return "all";
            }

            while (true)
            {
                var ans = Prompt("Enter names or numbers (comma-separated), or 'a' for all:").Trim();
                if (ans.Length == 0) { Console.WriteLine("Select at least one database."); continue; }
                if (TryResolveDatabaseSelection(ans, available, out _, out var error)) return ans;
                Console.WriteLine(error);
            }
        }

        static void PrintDatabaseSelectionQuestion(string server, string[] available)
        {
            Console.WriteLine();
            Console.WriteLine("=== DATABASE SELECTION REQUIRED ===");
            Console.WriteLine($"Ask the user which of these user databases on '{server}' should be audited — never decide this yourself:");
            foreach (var name in available)
                Console.WriteLine("  - " + name);
            Console.WriteLine("They may pick one, several, or all of them.");
            Console.WriteLine("Then run evaluate again, adding:");
            Console.WriteLine("  --databases <name1,name2>      (the chosen databases)");
            Console.WriteLine("  --databases all                (every database listed above)");
            Console.WriteLine("System databases (master, model, msdb, tempdb) are never audit targets and are not offered.");
            Console.WriteLine("=== END DATABASE SELECTION REQUIRED ===");
        }

        // Accepts 'all'/'*', database names, 1-based list positions, or a mix.
        static bool TryResolveDatabaseSelection(
            string? spec,
            string[] available,
            out string[] selected,
            out string error)
        {
            selected = Array.Empty<string>();
            error = string.Empty;

            var input = (spec ?? string.Empty).Trim();
            if (input.Length == 0) { error = "no database selected."; return false; }

            if (string.Equals(input, "all", StringComparison.OrdinalIgnoreCase) || input is "a" or "*")
            {
                selected = available;
                return true;
            }

            var chosen = new System.Collections.Generic.List<string>();
            var unknown = new System.Collections.Generic.List<string>();
            foreach (var token in input.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
            {
                var match = int.TryParse(token, out var index) && index >= 1 && index <= available.Length
                    ? available[index - 1]
                    : available.FirstOrDefault(name => string.Equals(name, token, StringComparison.OrdinalIgnoreCase));
                if (match == null) unknown.Add(token);
                else chosen.Add(match);
            }

            if (unknown.Count > 0)
            {
                error = "not on this instance (or not accessible to this login): " + string.Join(", ", unknown);
                return false;
            }
            if (chosen.Count == 0) { error = "no database selected."; return false; }

            selected = chosen.Distinct(StringComparer.OrdinalIgnoreCase).ToArray();
            return true;
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
            Console.WriteLine("     If the verification shows the control does not exist on this server at all - every value the user");
            Console.WriteLine("     reports is absent, empty, zero or irrelevant to it - the item is not assessable: record it with");
            Console.WriteLine("     --decision notapplicable and the reason in --notes. It is then excluded from every score and");
            Console.WriteLine("     reported as Not Applicable, never as Pass or Fail. A zero that itself proves compliance is a Pass.");
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
                Console.WriteLine($"After the user decides, run: sql-auditor resolve_review --id {r.Id} --decision <pass|fail|notapplicable> --notes \"<user's rationale>\"");
            }
            Console.WriteLine("=== END COPILOT REVIEW REQUIRED ===");
        }

        // ---------------------------------------------------------------------
        // Non-interactive CLI: `evidence` subcommand. Attaches a Git repository,
        // pipeline definitions, docs folders or policy files to the active run so
        // documentation items can be decided from artefacts instead of by interview.
        // ---------------------------------------------------------------------
        static async Task<int> RunEvidenceCommandAsync(string[] args)
        {
            var opts = ParseOptions(args);
            var action = args.Length > 1 && !args[1].StartsWith("--", StringComparison.Ordinal)
                ? args[1].Trim().ToLowerInvariant()
                : "show";

            if (opts.ContainsKey("help") || opts.ContainsKey("h"))
            {
                PrintEvidenceUsage();
                return 0;
            }

            if (string.Equals(action, "show", StringComparison.Ordinal))
            {
                var existing = SQLAuditor.Lib.EvidenceStore.Load();
                if (existing == null)
                {
                    Console.WriteLine($"No evidence is attached to the run in {SQLAuditor.Lib.AuditOutputPaths.CurrentRunDirectory}.");
                    Console.WriteLine("Attach some with: sql-auditor evidence add --path <folder> | --git <https url> | --file <path>");
                    return 0;
                }
                Console.WriteLine(SQLAuditor.Lib.EvidenceStore.Describe(existing));
                return 0;
            }

            if (!string.Equals(action, "add", StringComparison.Ordinal))
            {
                Console.Error.WriteLine($"Error: unknown evidence action '{action}'. Use 'add' or 'show'.");
                PrintEvidenceUsage();
                return 2;
            }

            var paths = SplitEvidenceList(GetOption(opts, "path") ?? GetOption(opts, "paths"));
            var fileList = SplitEvidenceList(GetOption(opts, "file") ?? GetOption(opts, "files"));
            var gitUrl = GetOption(opts, "git") ?? GetOption(opts, "git-url");
            var gitRef = GetOption(opts, "ref") ?? GetOption(opts, "git-ref");

            if (paths.Count == 0 && fileList.Count == 0 && string.IsNullOrWhiteSpace(gitUrl))
            {
                Console.Error.WriteLine("Error: provide at least one of --path, --file or --git.");
                PrintEvidenceUsage();
                return 2;
            }

            if (!string.IsNullOrWhiteSpace(gitUrl) && !SQLAuditor.Lib.EvidenceWorkspace.IsSupportedRemoteUrl(gitUrl))
            {
                if (SQLAuditor.Lib.EvidenceRepositoryUrl.TryParseBrowseUrl(gitUrl) is { } browse)
                    Console.Error.WriteLine(SQLAuditor.Lib.EvidenceRepositoryUrl.DescribeBrowseUrlRejection(browse)
                        + $"\n  sql-auditor evidence add --git \"{browse.CloneUrl}\" --ref \"{browse.Branch}\"");
                else
                    Console.Error.WriteLine($"Error: '{gitUrl}' is not a supported evidence repository URL. Only https:// Git clone URLs are accepted.");
                return 2;
            }

            try
            {
                var context = await SQLAuditor.Lib.EvidenceStore.AttachAsync(
                    paths, gitUrl, gitRef, fileList, System.Threading.CancellationToken.None);

                Console.WriteLine(SQLAuditor.Lib.EvidenceStore.Describe(context));

                if (!context.HasUsableEvidence)
                {
                    Console.WriteLine();
                    Console.WriteLine("Nothing was indexed, so no item can be decided from evidence.");
                    return 2;
                }

                Console.WriteLine();
                Console.WriteLine("NEXT: read the relevant files yourself under the resolved paths above. For every item you can settle, run:");
                Console.WriteLine("  sql-auditor resolve_review --id <id> --decision <pass|fail|notapplicable> --notes \"<what the files show>\" \\");
                Console.WriteLine("      --evidence-source \"<label>\" --evidence-files \"<paths you read>\"");
                Console.WriteLine("then 'enrich_result' for the same item. Cite only files you actually opened.");
                Console.WriteLine("If the evidence is silent, partial or ambiguous for an item, leave it as NeedsReview and say so - never guess.");
                return 0;
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine($"Failed to attach evidence: {ex.GetType().Name}: {ex.Message}");
                return 3;
            }
        }

        static void PrintEvidenceUsage()
        {
            Console.WriteLine("Usage: sqlauditor evidence add [options]");
            Console.WriteLine("       sqlauditor evidence show");
            Console.WriteLine();
            Console.WriteLine("Attaches Git repositories, CI/CD pipeline definitions, documentation folders and policy");
            Console.WriteLine("files to the active run so documentation and process checklist items can be decided from");
            Console.WriteLine("real artefacts. The CLI makes NO AI calls: it resolves and indexes the sources, and Copilot");
            Console.WriteLine("CLI reads the files and records each verdict with resolve_review.");
            Console.WriteLine();
            Console.WriteLine("Options:");
            Console.WriteLine("  --path <folders>    Comma-separated local folder paths (a cloned repo, a docs folder).");
            Console.WriteLine("  --file <paths>      Comma-separated individual file paths (a policy doc, a pipeline export).");
            Console.WriteLine("  --git <url>         An https:// Git URL to shallow-clone and index.");
            Console.WriteLine("                      Private repos authenticate from SQLAUDITOR_GIT_TOKEN; never pass a token here.");
            Console.WriteLine("  --ref <branch|tag>  Branch or tag to clone when --git is used.");
            Console.WriteLine("  --help              Show this help.");
            Console.WriteLine();
            Console.WriteLine("Examples:");
            Console.WriteLine("  sqlauditor evidence add --path C:\\src\\datawarehouse");
            Console.WriteLine("  sqlauditor evidence add --git https://github.com/contoso/dw --ref main");
            Console.WriteLine("  sqlauditor evidence show");
        }

        static System.Collections.Generic.List<string> SplitEvidenceList(string? value)
            => (value ?? string.Empty)
                .Split(new[] { ',', ';' }, StringSplitOptions.RemoveEmptyEntries)
                .Select(v => v.Trim().Trim('"'))
                .Where(v => v.Length > 0)
                .Distinct(StringComparer.OrdinalIgnoreCase)
                .ToList();

        // Honours the --evidence-* flags on `evaluate`; falls back to whatever is already
        // attached to the run so a second call does not re-clone.
        static async Task<SQLAuditor.Lib.EvidenceContext?> AttachEvaluateEvidenceAsync(
            System.Collections.Generic.Dictionary<string, string> opts,
            string? interactiveSpec = null)
        {
            var paths = SplitEvidenceList(GetOption(opts, "evidence-path"));
            var fileList = SplitEvidenceList(GetOption(opts, "evidence-file"));
            var gitUrl = GetOption(opts, "evidence-git");
            var gitRef = GetOption(opts, "evidence-ref");

            // A free-text answer to the interactive question is classified here.
            foreach (var entry in SplitEvidenceList(interactiveSpec))
            {
                if (entry.StartsWith("http://", StringComparison.OrdinalIgnoreCase)
                    || entry.StartsWith("https://", StringComparison.OrdinalIgnoreCase))
                    gitUrl ??= entry;
                else if (File.Exists(entry)) fileList.Add(entry);
                else paths.Add(entry);
            }

            if (paths.Count == 0 && fileList.Count == 0 && string.IsNullOrWhiteSpace(gitUrl))
                return SQLAuditor.Lib.EvidenceStore.Load();

            if (!string.IsNullOrWhiteSpace(gitUrl) && !SQLAuditor.Lib.EvidenceWorkspace.IsSupportedRemoteUrl(gitUrl))
            {
                if (SQLAuditor.Lib.EvidenceRepositoryUrl.TryParseBrowseUrl(gitUrl) is { } browse)
                    Console.Error.WriteLine("Warning: " + SQLAuditor.Lib.EvidenceRepositoryUrl.DescribeBrowseUrlRejection(browse));
                else
                    Console.Error.WriteLine($"Warning: '{gitUrl}' is not a supported evidence repository URL and was ignored. Only https:// Git clone URLs are accepted.");
                gitUrl = null;
            }

            try
            {
                return await SQLAuditor.Lib.EvidenceStore.AttachAsync(
                    paths, gitUrl, gitRef, fileList, System.Threading.CancellationToken.None);
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine($"Warning: could not attach evidence ({ex.GetType().Name}: {ex.Message}). Continuing with manual review.");
                return null;
            }
        }

        // Returns the evidence answer, "" when the user declined, or null when it has not been
        // supplied yet and must be asked for.
        static string? ResolveEvidenceSpec(System.Collections.Generic.Dictionary<string, string> opts)
        {
            if (opts.ContainsKey("no-evidence")) return string.Empty;

            // The granular flags are themselves an answer to the question.
            var hasGranular = !string.IsNullOrWhiteSpace(GetOption(opts, "evidence-path"))
                || !string.IsNullOrWhiteSpace(GetOption(opts, "evidence-file"))
                || !string.IsNullOrWhiteSpace(GetOption(opts, "evidence-git"));
            return hasGranular ? string.Empty : null;
        }

        static void PrintEvidenceQuestion()
        {
            Console.WriteLine();
            Console.WriteLine("=== EVIDENCE FOR DOCUMENTATION ITEMS ===");
            Console.WriteLine("Many checklist items are documentation or process controls (source control, pipelines, runbooks,");
            Console.WriteLine("architecture documents, environment separation, secrets handling). They cannot be answered from the");
            Console.WriteLine("SQL Server instance, so without evidence they all come back for manual review.");
            Console.WriteLine("Ask the user, and never decide for them:");
            Console.WriteLine("  \"Do you have a Git repository, deployment pipeline or documentation folder I can read as evidence?");
            Console.WriteLine("   Give me a local folder path, a file path, or an https Git clone URL - or say 'none' to review these manually.\"");
            Console.WriteLine("Then run evaluate again, adding EXACTLY ONE of:");
            Console.WriteLine("  --evidence-path <folder>  and/or  --evidence-file <path>  and/or  --evidence-git <https clone url> [--evidence-ref <branch>]");
            Console.WriteLine("  --no-evidence             (they declined)");
            Console.WriteLine("A browser page URL (.../tree/...) is NOT a clone URL and will be rejected - ask for the clone URL and branch separately.");
            Console.WriteLine("=== END EVIDENCE FOR DOCUMENTATION ITEMS ===");
        }

        static string PromptEvidenceSpec()
        {
            Console.WriteLine();
            Console.WriteLine("Evidence for documentation items (optional).");
            Console.WriteLine("Documentation and process controls are decided from artefacts - a repository, pipeline definitions,");
            Console.WriteLine("runbooks or policy documents. Without them those items are queued for manual review.");

            if (Console.IsInputRedirected)
            {
                Console.WriteLine("Non-interactive session: skipping evidence. Pass --evidence-path / --evidence-git to attach some.");
                return string.Empty;
            }

            return Prompt("Evidence folder path, file path or https Git clone URL (blank to skip):").Trim();
        }

        // ---------------------------------------------------------------------
        // Non-interactive CLI: `resolve_review` subcommand
        // Reuses Auditor.ResolveReview to patch results/checklist_results.json and
        // regenerate the report suite. Used by the Copilot CLI skill to record
        // Pass/Fail decisions without re-running the evaluation.
        // ---------------------------------------------------------------------
        static int RunResolveReviewCommand(string[] args)
        {
            var opts = ParseOptions(args);
            if (opts.ContainsKey("help") || opts.ContainsKey("h"))
            {
                Console.WriteLine("Usage: sqlauditor resolve_review --id <id> --decision <pass|fail|needsreview|notapplicable> [--notes <text> | --notes-file <path>]");
                Console.WriteLine("                                [--evidence-source <label>] [--evidence-files <paths>]");
                Console.WriteLine();
                Console.WriteLine("  --evidence-source   Set ONLY when the verdict came from attached evidence: the source label");
                Console.WriteLine("                      shown by 'sql-auditor evidence show'.");
                Console.WriteLine("  --evidence-files    Comma-separated manifest paths of the files you actually read.");
                Console.WriteLine("                      Required whenever --evidence-source is set.");
                return 0;
            }

            var id = GetOption(opts, "id");
            var decision = GetOption(opts, "decision");
            var notes = ReadValueOption(opts, "notes");
            var evidenceSource = GetOption(opts, "evidence-source");
            var evidenceFiles = ReadValueOption(opts, "evidence-files");

            if (string.IsNullOrWhiteSpace(id))
            {
                Console.Error.WriteLine("Error: --id is required.");
                return 2;
            }
            if (string.IsNullOrWhiteSpace(decision))
            {
                Console.Error.WriteLine("Error: --decision is required (pass, fail, needsreview, or notapplicable).");
                return 2;
            }

            var isEvidenceDerived = !string.IsNullOrWhiteSpace(evidenceSource) || !string.IsNullOrWhiteSpace(evidenceFiles);
            if (isEvidenceDerived && string.IsNullOrWhiteSpace(evidenceFiles))
            {
                Console.Error.WriteLine($"Error: --evidence-files is required for [{id}] when the verdict comes from attached evidence. "
                    + "List the manifest paths of the files you actually read.");
                return 2;
            }

            // Deciding that a control has nothing to assess is a human judgement, so it cannot be
            // filed from artefacts alone.
            if (isEvidenceDerived
                && SQLAuditor.Lib.NotApplicableEvidence.IsNotApplicableOutcome(SQLAuditor.Lib.ManualVerdict.Normalize(decision)))
            {
                Console.Error.WriteLine($"Error: 'notapplicable' cannot be recorded from attached evidence for [{id}]. "
                    + "Whether a control has nothing to assess on this platform is the user's call. Leave the item as "
                    + "NeedsReview and tell the user what the evidence suggests and why you think it may not apply.");
                return 2;
            }

            if (isEvidenceDerived)
            {
                notes = $"{notes?.Trim()}\n\n{SQLAuditor.Lib.EvidenceAttribution.EvidencePrefix} "
                      + SQLAuditor.Lib.EvidenceAttribution.Describe(evidenceSource, evidenceFiles);
            }

            var auditor = new SQLAuditor.Lib.Auditor(string.Empty);
            if (auditor.ResolveReview(id, decision, notes, out var newOutcome))
            {
                Console.WriteLine($"Updated [{id}] -> {newOutcome}. Outputs regenerated in {SQLAuditor.Lib.AuditOutputPaths.CurrentRunDirectory}.");
                if (SQLAuditor.Lib.NotApplicableEvidence.IsNotApplicableOutcome(newOutcome))
                {
                    Console.WriteLine($"[{id}] is excluded from every score and is listed on the 'Not Applicable Items' sheet. "
                        + "Report it as Not Applicable, never as Pass or Fail.");
                    return 0;
                }
                Console.WriteLine($"NEXT: run 'sql-auditor enrich_result --id {id} ...' with audit wording you derive from the reviewer's evidence "
                    + "- finding, evidence, riskImpact and recommendation - using only facts the reviewer stated. "
                    + "Their raw words must not stay as the report Finding.");
                return 0;
            }

            Console.Error.WriteLine($"Could not resolve '{id}'. Ensure 'evaluate' has run (results file exists), the ID is present, and decision is pass/fail/needsreview/notapplicable.");
            return 2;
        }

        // ---------------------------------------------------------------------
        // Non-interactive CLI: `export_manual_csv` / `import_manual_csv` subcommands
        // The manual review workflow is CSV-based on every surface. Both commands go
        // through SQLAuditor.Lib.ManualChecklistCsv, the same component the desktop app
        // and the IDE (MCP) host use, so the three produce and consume one CSV contract.
        // ---------------------------------------------------------------------
        static async Task<int> RunExportManualCsvCommandAsync(string[] args)
        {
            var opts = ParseOptions(args);
            if (opts.ContainsKey("help") || opts.ContainsKey("h"))
            {
                Console.WriteLine("Usage: sqlauditor export_manual_csv [--out <path>] [--generate]");
                Console.WriteLine("       Exports every manual checklist item of the current run, with its verification steps,");
                Console.WriteLine("       to a CSV. Fill the Decision (Pass/Fail) and Evidence columns, then apply it with");
                Console.WriteLine("       'sqlauditor import_manual_csv --file <path>'.");
                Console.WriteLine("       --generate: also mark every still-undecided manual item as Skipped (excluded from");
                Console.WriteLine("       scoring) and regenerate the report suite now, so a report is available before the");
                Console.WriteLine("       filled CSV is imported. Importing the CSV later overwrites those Skipped items.");
                return 0;
            }

            var resultsDir = SQLAuditor.Lib.AuditOutputPaths.CurrentRunDirectory;
            if (!File.Exists(Path.Combine(resultsDir, "checklist_results.json")))
            {
                Console.Error.WriteLine("Error: no evaluation results were found. Run 'sqlauditor evaluate' first.");
                return 2;
            }

            var auditor = new SQLAuditor.Lib.Auditor(string.Empty);
            var rows = await SQLAuditor.Lib.ManualChecklistCsv.BuildExportRowsAsync(auditor);
            if (rows.Count == 0)
            {
                Console.WriteLine("The current evaluation contains no manual checklist items to export.");
                return 0;
            }

            var outPath = GetOption(opts, "out");
            if (string.IsNullOrWhiteSpace(outPath))
                outPath = Path.Combine(resultsDir, SQLAuditor.Lib.ManualChecklistCsv.BuildExportFileName(DateTime.Now));
            outPath = Path.GetFullPath(outPath);
            Directory.CreateDirectory(Path.GetDirectoryName(outPath)!);

            SQLAuditor.Lib.ManualChecklistCsv.Write(outPath, rows);

            var pending = rows.Count(r => string.IsNullOrWhiteSpace(r.Decision));
            Console.WriteLine($"Exported {rows.Count} manual checklist item(s) ({pending} still undecided) to:");
            Console.WriteLine($"  {outPath}");

            if (opts.ContainsKey("generate") || opts.ContainsKey("g"))
            {
                var skipped = SQLAuditor.Lib.ManualChecklistCsv.SkipPendingManual(Path.GetFileName(outPath), resultsDir);
                SQLAuditor.Lib.Auditor.GenerateReports(runDirectory: resultsDir);
                Console.WriteLine();
                Console.WriteLine($"{skipped} undecided manual item(s) were marked Skipped and excluded from scoring; the report suite was regenerated in:");
                Console.WriteLine($"  {resultsDir}");
                Console.WriteLine("Fill the CSV and run 'sqlauditor import_manual_csv --file ...' to replace the Skipped items with real decisions.");
                return 0;
            }

            Console.WriteLine();
            Console.WriteLine("Fill the 'Decision' column with Pass or Fail and the 'Evidence' column with what you inspected");
            Console.WriteLine("and found. Rows are matched back by 'Checklist ID', so keep that column unchanged. Then run:");
            Console.WriteLine($"  sqlauditor import_manual_csv --file \"{outPath}\"");
            Console.WriteLine("Or run 'sqlauditor export_manual_csv --generate' to skip undecided items and generate a report now.");
            return 0;
        }

        static int RunImportManualCsvCommand(string[] args)
        {
            var opts = ParseOptions(args);
            if (opts.ContainsKey("help") || opts.ContainsKey("h"))
            {
                Console.WriteLine("Usage: sqlauditor import_manual_csv --file <path>");
                Console.WriteLine("       Applies the Pass/Fail decisions from a filled manual CSV to the current run,");
                Console.WriteLine("       matching rows to checklist items by 'Checklist ID'. Items that already carry a");
                Console.WriteLine("       decision are overwritten, so the CSV is always the source of truth.");
                return 0;
            }

            var file = GetOption(opts, "file") ?? GetOption(opts, "csv") ?? GetOption(opts, "in");
            if (string.IsNullOrWhiteSpace(file))
            {
                Console.Error.WriteLine("Error: --file is required (the filled manual CSV).");
                return 2;
            }
            if (!File.Exists(file))
            {
                Console.Error.WriteLine($"Error: file not found: {file}");
                return 2;
            }

            var resultsDir = SQLAuditor.Lib.AuditOutputPaths.CurrentRunDirectory;
            if (!File.Exists(Path.Combine(resultsDir, "checklist_results.json")))
            {
                Console.Error.WriteLine("Error: no evaluation results were found. Run 'sqlauditor evaluate' first.");
                return 2;
            }

            SQLAuditor.Lib.ManualCheckImportFile importFile;
            try
            {
                importFile = SQLAuditor.Lib.ManualChecklistCsv.Read(file);
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine("Error: the manual CSV could not be read. " + ex.Message);
                return 2;
            }

            var auditor = new SQLAuditor.Lib.Auditor(string.Empty);
            var applied = SQLAuditor.Lib.ManualChecklistCsv.Apply(auditor, importFile.Rows);

            try { SQLAuditor.Lib.ManualChecklistCsv.StoreInRunDirectory(file); }
            catch (Exception ex) { Console.WriteLine("Note: the CSV could not be stored in the run folder. " + ex.Message); }

            Console.WriteLine($"Applied {applied.Applied.Count} manual decision(s) to {resultsDir}.");
            foreach (var entry in applied.Applied) Console.WriteLine($"  [{entry}]");
            if (applied.Ignored.Count > 0)
                Console.WriteLine($"Ignored {applied.Ignored.Count} row(s) that are not manual items in this run: {string.Join(", ", applied.Ignored)}");
            if (applied.Failed.Count > 0)
                Console.WriteLine($"Could not update {applied.Failed.Count} row(s): {string.Join(", ", applied.Failed)}");
            if (importFile.Issues.Count > 0)
            {
                Console.WriteLine($"{importFile.Issues.Count} row(s) need correction in the CSV:");
                foreach (var issue in importFile.Issues.Take(20)) Console.WriteLine($"  {issue}");
                if (importFile.Issues.Count > 20) Console.WriteLine($"  ...and {importFile.Issues.Count - 20} more.");
            }

            Console.WriteLine("Reports were regenerated for every applied decision.");
            return applied.Applied.Count > 0 || importFile.Rows.Count == 0 ? 0 : 2;
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
                Console.WriteLine("       Every field also accepts a file form: --finding-file / --evidence-file / --risk-file / --recommendation-file <path>.");
                Console.WriteLine("       Use the file form whenever the text contains a quote character.");
                return 0;
            }

            var id = GetOption(opts, "id");
            if (string.IsNullOrWhiteSpace(id))
            {
                Console.Error.WriteLine("Error: --id is required.");
                return 2;
            }

            var finding = ReadValueOption(opts, "finding");
            var evidence = ReadValueOption(opts, "evidence");
            var risk = ReadValueOption(opts, "risk") ?? ReadValueOption(opts, "riskimpact");
            var recommendation = ReadValueOption(opts, "recommendation");

            var auditor = new SQLAuditor.Lib.Auditor(string.Empty);
            if (auditor.ApplyEnrichment(id, finding, evidence, risk, recommendation))
            {
                Console.WriteLine($"Enriched [{id}].");
                Console.WriteLine($"Outputs regenerated in {SQLAuditor.Lib.AuditOutputPaths.CurrentRunDirectory}.");
                return 0;
            }

            Console.Error.WriteLine($"Could not enrich '{id}'. Ensure 'evaluate' has run (results file exists), the ID is present, and at least one field was supplied.");
            return 2;
        }

        // ---------------------------------------------------------------------
        // Non-interactive CLI: `configure_checklist` subcommand
        // Configure Checklist -> Guardrails -> Semantic Match Router -> Area/Sub-area
        // Classification -> Script Generation -> User Review/Approval -> Save Custom Checklist +
        // Mapping -> Update Final Merged Configuration.
        // Copilot CLI performs the three reviews from the prompts this command serves; the command
        // itself makes no LLM calls and never connects to a SQL Server.
        // ---------------------------------------------------------------------
        static async Task<int> RunConfigureChecklistCommandAsync(string[] args)
        {
            var opts = ParseOptions(args);
            if (opts.ContainsKey("help") || opts.ContainsKey("h"))
            {
                PrintConfigureChecklistUsage();
                return 0;
            }

            var hints = new SQLAuditor.Lib.CustomChecklistInvocationHints
            {
                Classify = "run: sqlauditor configure_checklist --title \"<title>\" --description \"<description>\" "
                         + "--guardrail accept --match none --sub-area <existing sub-area id> --rationale \"<why>\"",
                Generate = "run: sqlauditor configure_checklist --id <id> --response-file <path-to-raw-response-file>",
                Review = "run: sqlauditor configure_checklist --id <id> --response-file <path> --validation-file <path-to-verdict-file>",
                Approve = "After the user approves, run: sqlauditor configure_checklist --id <id> --approve",
                Reject = "run: sqlauditor configure_checklist --id <id> --reject"
            };

            try
            {
                if (opts.ContainsKey("list-sub-areas") || opts.ContainsKey("sub-areas"))
                {
                    Console.WriteLine(SQLAuditor.Lib.CustomChecklistHostFlow.ListSubAreas());
                    return 0;
                }

                if (opts.ContainsKey("list") || opts.ContainsKey("pending"))
                {
                    Console.WriteLine(SQLAuditor.Lib.CustomChecklistHostFlow.ListPending());
                    return 0;
                }

                var id = GetOption(opts, "id");

                if (!string.IsNullOrWhiteSpace(id) && opts.ContainsKey("reject"))
                {
                    Console.WriteLine(SQLAuditor.Lib.CustomChecklistHostFlow.Reject(id));
                    return 0;
                }

                if (!string.IsNullOrWhiteSpace(id) && opts.ContainsKey("approve"))
                {
                    var approved = await SQLAuditor.Lib.CustomChecklistHostFlow.ApproveAsync(id);
                    Console.WriteLine(approved);
                    return approved.StartsWith("Error", StringComparison.OrdinalIgnoreCase) ? 2 : 0;
                }

                if (!string.IsNullOrWhiteSpace(id))
                {
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
                        Console.Error.WriteLine(
                            "Error: supply the generated script via --response-file <path> or --response \"<text>\", "
                            + "or use --approve / --reject to finish the item.");
                        return 2;
                    }

                    var verdict = GetOption(opts, "validation");
                    var verdictFile = GetOption(opts, "validation-file") ?? GetOption(opts, "validationfile");
                    if (string.IsNullOrWhiteSpace(verdict) && !string.IsNullOrWhiteSpace(verdictFile))
                    {
                        if (!File.Exists(verdictFile))
                        {
                            Console.Error.WriteLine($"Error: --validation-file not found: {verdictFile}");
                            return 2;
                        }
                        verdict = await File.ReadAllTextAsync(verdictFile);
                    }

                    var generated = SQLAuditor.Lib.CustomChecklistHostFlow.Generate(id, response, verdict, hints);
                    Console.WriteLine(generated);
                    return generated.StartsWith("Error", StringComparison.OrdinalIgnoreCase)
                        || generated.StartsWith("VALIDATION FAILED", StringComparison.OrdinalIgnoreCase)
                        || generated.StartsWith("VALIDATION REJECTED", StringComparison.OrdinalIgnoreCase)
                        || generated.StartsWith("VALIDATION VERDICT NOT RECOGNISED", StringComparison.OrdinalIgnoreCase)
                        || generated.StartsWith("CORRECTED SCRIPT STILL INVALID", StringComparison.OrdinalIgnoreCase) ? 2 : 0;
                }

                var title = GetOption(opts, "title");
                var description = GetOption(opts, "description") ?? GetOption(opts, "desc");

                if (opts.ContainsKey("guardrail") || opts.ContainsKey("sub-area") || opts.ContainsKey("subarea"))
                {
                    var classified = SQLAuditor.Lib.CustomChecklistHostFlow.Classify(
                        title,
                        description,
                        GetOption(opts, "guardrail"),
                        GetOption(opts, "guardrail-reason"),
                        GetOption(opts, "match") ?? GetOption(opts, "matched-id"),
                        GetOption(opts, "match-reason"),
                        GetOption(opts, "sub-area") ?? GetOption(opts, "subarea"),
                        GetOption(opts, "rationale"),
                        hints);
                    Console.WriteLine(classified);
                    return classified.StartsWith("Error", StringComparison.OrdinalIgnoreCase) ? 2 : 0;
                }

                Console.WriteLine(SQLAuditor.Lib.CustomChecklistHostFlow.Begin(title, description, hints));
                return 0;
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine($"Error: {ex.Message}");
                Console.Error.WriteLine("Hint: run this command from the 'SQL-Auditing-tool' folder so the checklist can be located.");
                return 3;
            }
        }

        static void PrintConfigureChecklistUsage()
        {
            Console.WriteLine();
            Console.WriteLine("Usage: sqlauditor configure_checklist [options]");
            Console.WriteLine();
            Console.WriteLine("Adds a CUSTOM checklist item under an EXISTING Area/Sub-area. The default checklist");
            Console.WriteLine("and the default mapping are never modified. New Areas/Sub-areas are not supported.");
            Console.WriteLine();
            Console.WriteLine("Flow (one command per step):");
            Console.WriteLine("  1) --title \"<t>\" --description \"<d>\"");
            Console.WriteLine("       Pre-screens the request and returns the guardrails, semantic-match and");
            Console.WriteLine("       classification prompts for you (the AI) to review.");
            Console.WriteLine("  2) --title \"<t>\" --description \"<d>\" --guardrail <accept|reject>");
            Console.WriteLine("       [--guardrail-reason \"<why>\"] --match <existing id|none> [--match-reason \"<why>\"]");
            Console.WriteLine("       --sub-area <id> [--rationale \"<why>\"]");
            Console.WriteLine("       Records the verdicts, assigns the next free checklist ID inside the Sub-area,");
            Console.WriteLine("       and returns the script generation prompt.");
            Console.WriteLine("  3) --id <id> --response-file <path> [--validation-file <path>]");
            Console.WriteLine("       Runs the format gate, then the C1-C7 review, and holds the script for approval.");
            Console.WriteLine("  4) --id <id> --approve      Saves the item + mapping and merges the final config.");
            Console.WriteLine("     --id <id> --reject       Releases the reserved ID; nothing is written.");
            Console.WriteLine();
            Console.WriteLine("Other options:");
            Console.WriteLine("  --list-sub-areas    Print every Area/Sub-area a custom item may be filed under.");
            Console.WriteLine("  --list              Print the drafts reserved but not yet approved.");
            Console.WriteLine("  --help              Show this help.");
            Console.WriteLine();
            Console.WriteLine("The CLI performs no LLM calls: Copilot CLI is the AI layer. This command never");
            Console.WriteLine("connects to a SQL Server and never asks for credentials.");
        }

        // ---------------------------------------------------------------------
        // Non-interactive CLI: `generate_report` subcommand
        // Refreshes results/historical_last_run.json from the newly evaluated manual results,
        // then regenerates the five-file report suite in the active run directory.
        // ---------------------------------------------------------------------
        static int RunGenerateReportCommand(string[] args)
        {
            var opts = ParseOptions(args);
            if (opts.ContainsKey("help") || opts.ContainsKey("h"))
            {
                Console.WriteLine("Usage: sqlauditor generate_report [--no-historical-refresh]");
                Console.WriteLine("  Refreshes historical_last_run.json with the manual results in");
                Console.WriteLine("  checklist_results.json, then regenerates the existing reports and five-file report suite");
                Console.WriteLine("  in the latest timestamp-and-server run directory under results.");
                return 0;
            }

            var resultsDir = SQLAuditor.Lib.AuditOutputPaths.CurrentRunDirectory;
            var jsonPath = Path.Combine(resultsDir, "checklist_results.json");
            if (!File.Exists(jsonPath))
            {
                Console.Error.WriteLine($"No results found at {jsonPath}. Run 'evaluate' first.");
                return 2;
            }

            Console.WriteLine(SQLAuditor.Lib.Auditor.GenerateReports(!opts.ContainsKey("no-historical-refresh")));
            Console.WriteLine($"Report suite : {resultsDir}");
            foreach (var fileName in SqlAuditor.Reporting.ReportSuiteGenerator.FileNames)
                Console.WriteLine($"  {Path.Combine(resultsDir, fileName)}");

            var tally = SQLAuditor.Lib.Auditor.BuildOutcomeTally();
            if (!string.IsNullOrEmpty(tally))
                Console.WriteLine($"Final outcome counts: {tally}");

            return 0;
        }

        // ---------------------------------------------------------------------
        // Non-interactive CLI: `show_reports` subcommand (also via --show-reports)
        // ---------------------------------------------------------------------
        static int RunShowReportsCommand(string[] args)
        {
            var opts = ParseOptions(args);
            var kind = GetOption(opts, "kind") ?? "summary";
            var resultsDir = SQLAuditor.Lib.AuditOutputPaths.CurrentRunDirectory;
            var path = string.Equals(kind, "json", StringComparison.OrdinalIgnoreCase)
                ? Path.Combine(resultsDir, "checklist_results.json")
                : Path.Combine(resultsDir, SqlAuditor.Reporting.ReportSuiteGenerator.AuditReportFileName);

            if (!File.Exists(path))
            {
                Console.Error.WriteLine($"No report found at {path}. Run 'evaluate' first.");
                return 2;
            }

            var tally = SQLAuditor.Lib.Auditor.BuildOutcomeTally();
            if (!string.IsNullOrEmpty(tally))
            {
                Console.WriteLine($"Final outcome counts (after enrichment and review): {tally}");
                Console.WriteLine();
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
                    // A quote inside the text makes the shell split one argument into several,
                    // so every following token is re-joined instead of silently dropped.
                    var sb = new System.Text.StringBuilder(args[++i]);
                    while (i + 1 < args.Length && !args[i + 1].StartsWith("--", StringComparison.Ordinal))
                        sb.Append(' ').Append(args[++i]);
                    val = sb.ToString();
                }
                opts[key] = val;
            }
            return opts;
        }

        static string? GetOption(System.Collections.Generic.Dictionary<string, string> opts, string key)
            => opts.TryGetValue(key, out var v) ? v : null;

        // Wording that quotes script values is passed by file so no shell can mangle it.
        static string? ReadValueOption(System.Collections.Generic.Dictionary<string, string> opts, string key)
        {
            var file = GetOption(opts, key + "-file") ?? GetOption(opts, key + "file");
            if (!string.IsNullOrWhiteSpace(file) && File.Exists(file)) return File.ReadAllText(file);
            return GetOption(opts, key);
        }

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

