using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Text.RegularExpressions;
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

        private readonly List<ExecutionResultEntry> _executionResults = new();

        // Tracks classification for ALL processed items (feasible and non-feasible)
        private readonly Dictionary<string, (string? ScriptFile, bool IsAdminCheck, bool IsDocumentationCheck, bool McpFeasibility)> _classificationRegistry = new();


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

            // Reset script directories and mapping file for a fresh generation run.
            // This avoids stale scripts accumulating when new checklists are introduced.
            foreach (var f in Directory.GetFiles(sqlDir))
            {
                try { File.Delete(f); } catch { }
            }
            foreach (var f in Directory.GetFiles(ps1Dir))
            {
                try { File.Delete(f); } catch { }
            }

            // Reset the mapping file so it only contains entries from this generation run.
            try
            {
                File.WriteAllText(_mappingPath, "{}");
            }
            catch { }


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


            const int batchSize = 10;

            for (int batchStart = 0;
                batchStart < checklist.Count;
                batchStart += batchSize)
            {
                if (cancellationToken.IsCancellationRequested)
                    break;

                var batch =
                    checklist
                        .Skip(batchStart)
                        .Take(batchSize)
                        .ToList();

                progress?.Report(
                    $"[Agent] Starting batch {(batchStart / batchSize) + 1} " +
                    $"with {batch.Count} checklist items");

                // ==========================================================
                // PROCESS ALL ITEMS IN THIS BATCH CONCURRENTLY
                // Each item gets its own independent LLM request/session.
                // ==========================================================

                var tasks =
                    batch.Select(item =>
                        ProcessItemAsync(
                            item,
                            sqlDir,
                            ps1Dir,
                            progress,
                            cancellationToken))
                    .ToArray();

                // Wait until ALL items in this batch have completed.
                var batchResults =
                    await Task.WhenAll(tasks);

                // ==========================================================
                // MERGE RESULTS AFTER ALL 10 ITEMS ARE COMPLETE
                // ==========================================================

                foreach (var result in batchResults)
                {
                    if (result == null)
                        continue;

                    // Generated item
                    if (result.Generated)
                    {
                        runResult.Generated.Add(
                            result.ChecklistId);
                    }

                    // Failed item
                    if (result.Failed)
                    {
                        runResult.Failed.Add(
                            result.ChecklistId);
                    }

                    // Skipped item
                    if (result.Skipped != null)
                    {
                        runResult.Skipped.Add(
                            result.Skipped);
                    }

                    // Execution result
                    if (result.ExecutionResult != null)
                    {
                        _executionResults.Add(
                            result.ExecutionResult);
                    }

                    // Classification / deterministic mapping
                    _classificationRegistry[result.ChecklistId] =
                        (
                            result.ScriptFile,
                            result.IsAdminCheck,
                            result.IsDocumentationCheck,
                            result.McpFeasibility
                        );
                }

                // ==========================================================
                // WRITE ONCE AFTER THE ENTIRE BATCH IS COMPLETE
                // ==========================================================

                await WriteResultsIteratively();

                progress?.Report(
                    $"[Agent] Completed batch {(batchStart / batchSize) + 1} " +
                    $"({batchResults.Length} items)");

                if (cancellationToken.IsCancellationRequested)
                    break;
            }
            return runResult;
        }
        



        private async Task<ItemProcessingResult> ProcessItemAsync(
            ScriptGenChecklistItem item,
            string sqlDir,
            string ps1Dir,
            IProgress<string>? progress,
            CancellationToken cancellationToken)
        {
            const int maxGenerationAttempts = 3;

            string? retryContext = null;

            var result =
                new ItemProcessingResult
                {
                    ChecklistId = item.ChecklistId
                };

            for (int genAttempt = 1;
                 genAttempt <= maxGenerationAttempts;
                 genAttempt++)
            {
                if (cancellationToken.IsCancellationRequested)
                    return result;

                try
                {
                    // ==========================================================
                    // STEP 1 - CALL LLM
                    // This is an independent chat/request for THIS item only.
                    // ==========================================================

                    progress?.Report(
                        $"[{item.ChecklistId}] " +
                        $"{(genAttempt == 1 ? "Generating" : $"Retry {genAttempt}/{maxGenerationAttempts}: Regenerating")} script via LLM...");

                    var response =
                        await _processor.GenerateScriptAsync(
                            item,
                            progress,
                            genAttempt > 1
                                ? retryContext
                                : null);

                    // ==========================================================
                    // NOT FEASIBLE
                    // ==========================================================

                    if (!response.IsFeasible)
                    {
                        progress?.Report(
                            $"[{item.ChecklistId}] NOT FEASIBLE: {response.Reason}");

                        result.Skipped =
                            new SkippedItem
                            {
                                ChecklistId =
                                    item.ChecklistId,

                                CheckName =
                                    item.CheckName,

                                Reason =
                                    response.Reason
                            };

                        result.ExecutionResult =
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
                            };

                        result.ScriptFile = null;
                        result.IsAdminCheck = response.IsAdminCheck;
                        result.IsDocumentationCheck = response.IsDocumentationCheck;
                        result.McpFeasibility = response.McpFeasibility;

                        return result;
                    }

                    // ==========================================================
                    // STEP 2 - LOCAL FORMAT VALIDATION
                    // ==========================================================

                    var validation =
                        _validator.Validate(response);

                    if (!validation.IsValid)
                    {
                        progress?.Report(
                            $"[{item.ChecklistId}] FORMAT VALIDATION FAILED: {validation.Error}");

                        if (genAttempt < maxGenerationAttempts)
                        {
                            retryContext =
                                $"Format validation failed: {validation.Error}";

                            await Task.Delay(
                                2000,
                                cancellationToken);

                            continue;
                        }

                        result.Failed = true;

                        result.ExecutionResult =
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
                                    $"Failed after {maxGenerationAttempts} attempts. " +
                                    $"Last error: {validation.Error}"
                            };

                        return result;
                    }

                    // ==========================================================
                    // STEP 3 - CONTENT VALIDATION VIA LLM
                    // This is another independent request for THIS item.
                    // ==========================================================

                    progress?.Report(
                        $"[{item.ChecklistId}] Validating script content via LLM...");

                    var contentValidation =
                        await _processor.ValidateScriptAsync(
                            item,
                            response,
                            progress);

                    if (!contentValidation.IsValid)
                    {
                        if (!string.IsNullOrWhiteSpace(
                            contentValidation.CorrectedScript))
                        {
                            progress?.Report(
                                $"[{item.ChecklistId}] Script had issues, " +
                                $"using corrected version from validator.");

                            response.ScriptContent =
                                contentValidation.CorrectedScript;

                            var revalidation =
                                _validator.Validate(response);

                            if (!revalidation.IsValid)
                            {
                                progress?.Report(
                                    $"[{item.ChecklistId}] " +
                                    $"CORRECTED SCRIPT FORMAT INVALID: {revalidation.Error}");

                                if (genAttempt < maxGenerationAttempts)
                                {
                                    retryContext =
                                        $"Content validation found issues: " +
                                        $"{contentValidation.Issues}\n" +
                                        $"Validator provided a corrected script " +
                                        $"but it also failed format validation: " +
                                        $"{revalidation.Error}";

                                    await Task.Delay(
                                        2000,
                                        cancellationToken);

                                    continue;
                                }

                                result.Failed = true;

                                result.ExecutionResult =
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
                                            $"Failed after {maxGenerationAttempts} attempts. " +
                                            $"Last error: {revalidation.Error}"
                                    };

                                return result;
                            }

                            progress?.Report(
                                $"[{item.ChecklistId}] " +
                                $"✓ Corrected script passed format validation");
                        }
                        else
                        {
                            progress?.Report(
                                $"[{item.ChecklistId}] " +
                                $"CONTENT VALIDATION FAILED: {contentValidation.Issues}");

                            if (genAttempt < maxGenerationAttempts)
                            {
                                retryContext =
                                    $"Content validation failed: " +
                                    $"{contentValidation.Issues}";

                                await Task.Delay(
                                    2000,
                                    cancellationToken);

                                continue;
                            }

                            result.Failed = true;

                            result.ExecutionResult =
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
                                        $"Failed after {maxGenerationAttempts} attempts. " +
                                        $"Last issues: {contentValidation.Issues}"
                                };

                            return result;
                        }
                    }
                    else
                    {
                        progress?.Report(
                            $"[{item.ChecklistId}] " +
                            $"✓ Script content validated successfully");
                    }

                    // ==========================================================
                    // STEP 4 - SAVE SCRIPT
                    // ==========================================================

                    var safeName =
                        Regex.Replace(
                            item.CheckName ?? "",
                            @"[^a-zA-Z0-9]+",
                            "_")
                        .Trim('_');

                    var filename =
                        $"{item.ChecklistId}_{safeName}.{response.ScriptType}";

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
                        response.ScriptContent,
                        cancellationToken);

                    progress?.Report(
                        $"[{item.ChecklistId}] ✓ Script saved: " +
                        $"{response.ScriptType}/{filename}");

                    progress?.Report(
                        $"[{item.ChecklistId}] " +
                        $"Scope: {response.Scope} | " +
                        $"Scoring: {response.ScoringLogic}");

                    // ==========================================================
                    // STEP 5 + STEP 6
                    // DO NOT MODIFY SHARED COLLECTIONS HERE.
                    // Return the result to RunAsync instead.
                    // ==========================================================

                    result.Generated = true;

                    result.ScriptFile =
                        $"Backend/checklist/scripts/" +
                        $"{response.ScriptType}/{filename}";

                    result.IsAdminCheck =
                        response.IsAdminCheck;

                    result.IsDocumentationCheck =
                        response.IsDocumentationCheck;

                    result.McpFeasibility =
                        response.McpFeasibility;

                    result.ExecutionResult =
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
                                genAttempt > 1
                                    ? $"Script Generated (attempt {genAttempt})"
                                    : "Script Generated",

                            ScriptType =
                                response.ScriptType,

                            ScriptPath =
                                $"{response.ScriptType}/{filename}",

                            ScoringLogic =
                                response.ScoringLogic
                        };

                    return result;
                }
                catch (OperationCanceledException)
                    when (cancellationToken.IsCancellationRequested)
                {
                    return result;
                }
                catch (Exception ex)
                {
                    progress?.Report(
                        $"[{item.ChecklistId}] ERROR: {ex.Message}");

                    if (genAttempt < maxGenerationAttempts)
                    {
                        retryContext =
                            $"Exception during generation: {ex.Message}";

                        await Task.Delay(
                            2000,
                            cancellationToken);

                        continue;
                    }

                    result.Failed = true;

                    result.ExecutionResult =
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
                                $"Failed after {maxGenerationAttempts} attempts. " +
                                $"Last error: {ex.Message}"
                        };

                    return result;
                }
            }

            return result;
        }

        private sealed class ItemProcessingResult
        {
            public string ChecklistId { get; set; } = "";

            public bool Generated { get; set; }

            public bool Failed { get; set; }

            public SkippedItem? Skipped { get; set; }

            public ExecutionResultEntry? ExecutionResult { get; set; }

            public string? ScriptFile { get; set; }

            public bool IsAdminCheck { get; set; }

            public bool IsDocumentationCheck { get; set; }

            public bool McpFeasibility { get; set; }
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

            // Write complete classification registry into the deterministic-script-mapping.json
            // All processed items are included; non-feasible items have script_file = null.
            var mappingDict = new Dictionary<string, object>();

            foreach (var entry in _classificationRegistry)
            {
                mappingDict[entry.Key] = new
                {
                    script_file = entry.Value.ScriptFile,
                    IsAdminCheck = entry.Value.IsAdminCheck,
                    IsDocumentationCheck = entry.Value.IsDocumentationCheck,
                    MCP_Feasibility = entry.Value.McpFeasibility
                };
            }

            await File.WriteAllTextAsync(
                _mappingPath,
                JsonSerializer.Serialize(
                    mappingDict,
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