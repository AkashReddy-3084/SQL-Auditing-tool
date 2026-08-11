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
            // Non-interactive CLI subcommand: evaluate specific checklist items and exit.
            // Example: sqlauditor evaluate --items 1.1.2,3.1.2 --server myhost\\sqlexpress
            if (args.Length > 0 && string.Equals(args[0], "evaluate", StringComparison.OrdinalIgnoreCase))
            {
                return await RunEvaluateCommandAsync(args);
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
                // No username supplied: ask which authentication method to use.
                var authChoice = Prompt("Auth method? (1=Windows Integrated, 2=SQL Login) [1/2]:");
                if (authChoice.Trim() == "2")
                {
                    user = Prompt("SQL username:");
                    pass = PromptSecret("SQL password:");
                }
            }
            else if (string.IsNullOrWhiteSpace(pass))
            {
                // Username provided up front but no password: ask for it securely.
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

            // Optional: let the operator mark manual-review items as pass/fail inline.
            // Enabled explicitly with --interactive, or automatically when running in a
            // real terminal (stdin not redirected) so a hands-on session is always asked.
            // Scripted/CI runs (redirected stdin) stay non-blocking unless --interactive.
            bool interactive = opts.ContainsKey("interactive") || opts.ContainsKey("i") || !Console.IsInputRedirected;
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
                    var updated = new System.Collections.Generic.Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
                    foreach (var r in manualPending)
                    {
                        Console.WriteLine();
                        Console.WriteLine($"--- {r.Id}: {r.Description} ---");
                        if (!string.IsNullOrWhiteSpace(r.Evidence))
                        {
                            Console.WriteLine("Guidance:");
                            Console.WriteLine(r.Evidence.Trim());
                        }
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
            Console.WriteLine("  --help              Show this help.");
            Console.WriteLine();
            Console.WriteLine("Provider config (LLM) is read from PROVIDER_BASE_URL, PROVIDER_API_KEY, MODEL.");
            Console.WriteLine();
            Console.WriteLine("Examples:");
            Console.WriteLine("  sqlauditor evaluate                                  (fully interactive)");
            Console.WriteLine("  sqlauditor evaluate --items 1.1.2,3.1.2 --server localhost");
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

