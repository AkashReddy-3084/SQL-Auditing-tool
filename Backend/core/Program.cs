using System;
using System.IO;
using System.Linq;
using System.Threading.Tasks;

namespace SQLAuditor
{
    internal static class Program
    {
        static async Task Main(string[] args)
        {
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
                return;
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
        }

        static string Prompt(string msg)
        {
            Console.Write(msg + " ");
            return Console.ReadLine() ?? string.Empty;
        }

        static string PromptSecret(string msg)
        {
            Console.Write(msg + " ");
            // simple no-echo password
            var pass = string.Empty;
            ConsoleKeyInfo key;
            while ((key = Console.ReadKey(true)).Key != ConsoleKey.Enter)
            {
                if (key.Key == ConsoleKey.Backspace && pass.Length > 0)
                {
                    pass = pass[..^1];
                }
                else if (!char.IsControl(key.KeyChar))
                {
                    pass += key.KeyChar;
                }
            }
            Console.WriteLine();
            return pass;
        }
    }
}

