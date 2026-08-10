using System;
using System.Collections.Generic;
using System.IO;
using System.Text.Json;
using System.Threading.Tasks;

namespace SQLAuditor.Agents
{
    public class ScriptGeneratorAgent
    {
        private readonly ChecklistItemProcessor _processor;

        private readonly ScriptOutputValidator _validator;

        private readonly string _basePath;

        private readonly string _resultsPath;

        private readonly string _mappingPath;

        private readonly List<ScriptMapping> _mappings = new();

        private readonly List<ExecutionResultEntry> _executionResults = new();


        public ScriptGeneratorAgent(
            ChecklistItemProcessor processor,
            ScriptOutputValidator validator,
            string basePath)
        {
            _processor = processor;

            _validator = validator;

            _basePath = basePath;

            _resultsPath =
                Path.Combine(
                    basePath,
                    "results",
                    "execution-results.json");

            _mappingPath =
                Path.Combine(
                    basePath,
                    "checklist",
                    "deterministic-script-mapping.json");
        }


        public async Task<AgentRunResult> RunAsync()
        {
            var sqlDir =
                Path.Combine(
                    _basePath,
                    "checklist",
                    "scripts",
                    "sql");

            var ps1Dir =
                Path.Combine(
                    _basePath,
                    "checklist",
                    "scripts",
                    "ps1");

            var resultsDir =
                Path.Combine(
                    _basePath,
                    "results");

            Directory.CreateDirectory(sqlDir);
            Directory.CreateDirectory(ps1Dir);
            Directory.CreateDirectory(resultsDir);


            var checklist =
                LoadChecklist(
                    Path.Combine(
                        _basePath,
                        "checklist",
                        "master-checklist.json"));

            Console.WriteLine(
                $"[Agent] Loaded {checklist.Count} checklist items\n");


            var runResult =
                new AgentRunResult();


            foreach (var item in checklist)
            {
                Console.WriteLine(
                    $"[Agent] {item.ChecklistId} - {item.CheckName}");

                try
                {
                    // ==========================================
                    // STEP 1 - CALL LLM (FEASIBILITY + SCRIPT)
                    // ==========================================

                    Console.WriteLine(
                        " Generating script via LLM...");

                    var response =
                        await _processor
                            .GenerateScriptAsync(item);


                    if (!response.IsFeasible)
                    {
                        Console.WriteLine(
                            $" NOT FEASIBLE: {response.Reason}");

                        runResult.Skipped.Add(
                            new SkippedItem
                            {
                                ChecklistId =
                                    item.ChecklistId,

                                CheckName =
                                    item.CheckName,

                                Reason =
                                    response.Reason
                            });

                        _executionResults.Add(
                            new ExecutionResultEntry
                            {
                                ChecklistId =
                                    item.ChecklistId,

                                CheckName =
                                    item.CheckName,

                                Category =
                                    item.Category,

                                Status =
                                    "Not Feasible",

                                Reason =
                                    response.Reason
                            });

                        await WriteResultsIteratively();
                        continue;
                    }


                    // ==========================================
                    // STEP 2 - VALIDATE GENERATED SCRIPT
                    // ==========================================

                    var validation =
                        _validator.Validate(response);

                    if (!validation.IsValid)
                    {
                        Console.WriteLine(
                            $" VALIDATION FAILED: {validation.Error}");

                        runResult.Failed.Add(
                            item.ChecklistId);

                        _executionResults.Add(
                            new ExecutionResultEntry
                            {
                                ChecklistId =
                                    item.ChecklistId,

                                CheckName =
                                    item.CheckName,

                                Category =
                                    item.Category,

                                Status =
                                    "Validation Failed",

                                Reason =
                                    validation.Error
                            });

                        await WriteResultsIteratively();
                        continue;
                    }


                    // ==========================================
                    // STEP 3 - SAVE SCRIPT TO DISK
                    // ==========================================

                    var filename =
                        $"{response.ScriptName}.{response.ScriptType}";

                    var outputDir =
                        response.ScriptType == "sql"
                        ? sqlDir
                        : ps1Dir;

                    var scriptPath =
                        Path.Combine(
                            outputDir,
                            filename);

                    await File.WriteAllTextAsync(
                        scriptPath,
                        response.ScriptContent);

                    Console.WriteLine(
                        $" ✓ Script saved: {response.ScriptType}/{filename}");

                    Console.WriteLine(
                        $"   Scope: {response.Scope}");

                    Console.WriteLine(
                        $"   Scoring: {response.ScoringLogic}");


                    // ==========================================
                    // STEP 4 - RECORD MAPPING
                    // ==========================================

                    _mappings.Add(
                        new ScriptMapping
                        {
                            ChecklistId =
                                item.ChecklistId,

                            Name =
                                item.CheckName,

                            Scope =
                                response.Scope,

                            ScriptType =
                                response.ScriptType,

                            ScriptPath =
                                $"{response.ScriptType}/{filename}",

                            MaxScore =
                                3,

                            ScoringLogic =
                                response.ScoringLogic
                        });


                    // ==========================================
                    // STEP 5 - RECORD RESULT
                    // ==========================================

                    _executionResults.Add(
                        new ExecutionResultEntry
                        {
                            ChecklistId =
                                item.ChecklistId,

                            CheckName =
                                item.CheckName,

                            Category =
                                item.Category,

                            Scope =
                                response.Scope,

                            Status =
                                "Script Generated",

                            ScriptType =
                                response.ScriptType,

                            ScriptPath =
                                $"{response.ScriptType}/{filename}",

                            ScoringLogic =
                                response.ScoringLogic
                        });


                    runResult.Generated.Add(
                        item.ChecklistId);

                    await WriteResultsIteratively();
                }
                catch (Exception ex)
                {
                    Console.WriteLine(
                        $" ERROR: {ex.Message}");

                    runResult.Failed.Add(
                        item.ChecklistId);

                    _executionResults.Add(
                        new ExecutionResultEntry
                        {
                            ChecklistId =
                                item.ChecklistId,

                            CheckName =
                                item.CheckName,

                            Category =
                                item.Category,

                            Status =
                                "Failed",

                            Reason =
                                ex.Message
                        });

                    await WriteResultsIteratively();
                }
            }


            return runResult;
        }


        private async Task WriteResultsIteratively()
        {
            await File.WriteAllTextAsync(
                _resultsPath,
                JsonSerializer.Serialize(
                    new
                    {
                        generatedAt =
                            DateTime.UtcNow,

                        totalProcessed =
                            _executionResults.Count,

                        results =
                            _executionResults
                    },
                    new JsonSerializerOptions
                    {
                        WriteIndented = true
                    }));

            await File.WriteAllTextAsync(
                _mappingPath,
                JsonSerializer.Serialize(
                    new
                    {
                        mappings = _mappings
                    },
                    new JsonSerializerOptions
                    {
                        WriteIndented = true
                    }));
        }


        private List<ChecklistItem>
            LoadChecklist(string path)
        {
            var json =
                File.ReadAllText(path);

            return JsonSerializer
                .Deserialize<ChecklistDocument>(
                    json,
                    new JsonSerializerOptions
                    {
                        PropertyNameCaseInsensitive = true
                    })
                ?.Items
                ?? new();
        }
    }


    public class ChecklistDocument
    {
        public List<ChecklistItem> Items { get; set; } = new();
    }


    public class AgentRunResult
    {
        public List<string> Generated { get; set; } = new();

        public List<string> Failed { get; set; } = new();

        public List<SkippedItem> Skipped { get; set; } = new();
    }


    public class SkippedItem
    {
        public string ChecklistId { get; set; } = "";

        public string CheckName { get; set; } = "";

        public string Reason { get; set; } = "";
    }
}