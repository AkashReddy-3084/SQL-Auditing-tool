using System;
using System.Collections.Generic;
using System.IO;
using System.Text.Json;
using System.Threading;
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
            return await RunAsync(null, null, CancellationToken.None);
        }

        public async Task<AgentRunResult> RunAsync(
            IProgress<string>? progress,
            IEnumerable<ScriptGenChecklistItem>? items = null,
            CancellationToken cancellationToken = default)
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


            List<ScriptGenChecklistItem> checklist;
            if (items != null)
            {
                checklist = new List<ScriptGenChecklistItem>(items);
            }
            else
            {
                checklist = LoadChecklist(
                    Path.Combine(
                        _basePath,
                        "checklist",
                        "master-checklist.json"));
            }

            progress?.Report($"[Agent] Loaded {checklist.Count} checklist items");


            var runResult =
                new AgentRunResult();


            foreach (var item in checklist)
            {
                if (cancellationToken.IsCancellationRequested) break;

                progress?.Report($"[Agent] {item.ChecklistId} - {item.CheckName}");

                try
                {
                    // ==========================================
                    // STEP 1 - CALL LLM (FEASIBILITY + SCRIPT)
                    // ==========================================

                    progress?.Report($"  Generating script via LLM...");

                    var response =
                        await _processor
                            .GenerateScriptAsync(item, progress);


                    if (!response.IsFeasible)
                    {
                        progress?.Report($"  NOT FEASIBLE: {response.Reason}");

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
                        progress?.Report($"  VALIDATION FAILED: {validation.Error}");

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
                    // STEP 3 - VALIDATE SCRIPT CONTENT VIA LLM
                    // ==========================================

                    progress?.Report($"  Validating script content via LLM...");

                    var contentValidation =
                        await _processor
                            .ValidateScriptAsync(
                                item, response, progress);

                    if (!contentValidation.IsValid)
                    {
                        if (!string.IsNullOrWhiteSpace(
                            contentValidation.CorrectedScript))
                        {
                            progress?.Report(
                                $"  Script had issues, using corrected version from validator.");

                            response.ScriptContent =
                                contentValidation.CorrectedScript;

                            // Re-validate corrected script format
                            var revalidation =
                                _validator.Validate(response);

                            if (!revalidation.IsValid)
                            {
                                progress?.Report(
                                    $"  CORRECTED SCRIPT FORMAT INVALID: {revalidation.Error}");

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
                                            "Corrected Script Validation Failed",

                                        Reason =
                                            revalidation.Error
                                    });

                                await WriteResultsIteratively();
                                continue;
                            }

                            progress?.Report(
                                $"  ✓ Corrected script passed format validation");
                        }
                        else
                        {
                            progress?.Report(
                                $"  CONTENT VALIDATION FAILED: {contentValidation.Issues}");

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
                                        "Content Validation Failed",

                                    Reason =
                                        contentValidation.Issues
                                });

                            await WriteResultsIteratively();
                            continue;
                        }
                    }
                    else
                    {
                        progress?.Report(
                            $"  ✓ Script content validated successfully");
                    }


                    // ==========================================
                    // STEP 4 - SAVE SCRIPT TO DISK
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

                    progress?.Report($"  ✓ Script saved: {response.ScriptType}/{filename}");
                    progress?.Report($"    Scope: {response.Scope} | Scoring: {response.ScoringLogic}");


                    // ==========================================
                    // STEP 5 - RECORD MAPPING
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
                    // STEP 6 - RECORD RESULT
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
                    progress?.Report($"  ERROR: {ex.Message}");

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

            // Merge generated mappings into the existing deterministic-script-mapping.json
            // which uses format: { "id": ["path1", ..."] }
            var existingMapping = new Dictionary<string, string[]>();
            if (File.Exists(_mappingPath))
            {
                try
                {
                    var existing = JsonSerializer.Deserialize<Dictionary<string, string[]>>(
                        File.ReadAllText(_mappingPath));
                    if (existing != null) existingMapping = existing;
                }
                catch { /* If parse fails (e.g. different format), start fresh */ }
            }

            foreach (var m in _mappings)
            {
                var relativePath = $"Backend/checklist/scripts/{m.ScriptPath}";
                existingMapping[m.ChecklistId] = new[] { relativePath };
            }

            await File.WriteAllTextAsync(
                _mappingPath,
                JsonSerializer.Serialize(
                    existingMapping,
                    new JsonSerializerOptions
                    {
                        WriteIndented = true
                    }));
        }


        private List<ScriptGenChecklistItem>
            LoadChecklist(string path)
        {
            var json = File.ReadAllText(path);

            using var doc = JsonDocument.Parse(json);
            var root = doc.RootElement;

            // Format 1: flat { "items": [...] } with ChecklistId, CheckName, etc.
            if (root.TryGetProperty("items", out var itemsArr) && itemsArr.ValueKind == JsonValueKind.Array)
            {
                return JsonSerializer
                    .Deserialize<ScriptGenChecklistDocument>(
                        json,
                        new JsonSerializerOptions
                        {
                            PropertyNameCaseInsensitive = true
                        })
                    ?.Items
                    ?? new();
            }

            // Format 2: nested { "areas": [ { "sub_areas": [ { "items": [ { "id", "text" } ] } ] } ] }
            if (root.TryGetProperty("areas", out var areas) && areas.ValueKind == JsonValueKind.Array)
            {
                var result = new List<ScriptGenChecklistItem>();
                foreach (var area in areas.EnumerateArray())
                {
                    var areaTitle = area.TryGetProperty("title", out var at) ? at.GetString() ?? "" : "";
                    var areaId = area.TryGetProperty("id", out var aid) ? aid.GetString() ?? "" : "";

                    if (!area.TryGetProperty("sub_areas", out var subAreas) || subAreas.ValueKind != JsonValueKind.Array)
                        continue;

                    foreach (var sub in subAreas.EnumerateArray())
                    {
                        var subTitle = sub.TryGetProperty("title", out var st) ? st.GetString() ?? "" : "";

                        if (!sub.TryGetProperty("items", out var items) || items.ValueKind != JsonValueKind.Array)
                            continue;

                        foreach (var item in items.EnumerateArray())
                        {
                            var id = item.TryGetProperty("id", out var iid) ? iid.GetString() ?? "" : "";
                            var text = item.TryGetProperty("text", out var txt)
                                ? txt.GetString() ?? ""
                                : item.TryGetProperty("description", out var dsc)
                                    ? dsc.GetString() ?? ""
                                    : "";

                            if (string.IsNullOrWhiteSpace(id) || string.IsNullOrWhiteSpace(text))
                                continue;

                            result.Add(new ScriptGenChecklistItem
                            {
                                ChecklistId = id,
                                Category = subTitle,
                                CheckName = text,
                                Scope = "",
                                Description = text,
                                ExpectedOutcome = text
                            });
                        }
                    }
                }
                return result;
            }

            // Format 3: plain array [{ "Id", "Description", ... }]
            if (root.ValueKind == JsonValueKind.Array)
            {
                var result = new List<ScriptGenChecklistItem>();
                foreach (var el in root.EnumerateArray())
                {
                    var id = el.TryGetProperty("Id", out var pid) ? pid.GetString() ?? "" : "";
                    var desc = el.TryGetProperty("Description", out var pdesc) ? pdesc.GetString() ?? "" : "";
                    if (string.IsNullOrWhiteSpace(id)) continue;

                    result.Add(new ScriptGenChecklistItem
                    {
                        ChecklistId = id,
                        Category = el.TryGetProperty("Category", out var pcat) ? pcat.GetString() ?? "" : "",
                        CheckName = desc,
                        Scope = "",
                        Description = desc,
                        ExpectedOutcome = desc
                    });
                }
                return result;
            }

            return new();
        }
    }


    public class ScriptGenChecklistDocument
    {
        public List<ScriptGenChecklistItem> Items { get; set; } = new();
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