using System;
using System.Collections.Generic;
using System.IO;
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


            foreach (var item in checklist)
            {
                if (cancellationToken.IsCancellationRequested) break;

                progress?.Report($"[Agent] {item.ChecklistId} - {item.CheckName}");

                const int maxGenerationAttempts = 3;
                bool itemSucceeded = false;
                string? retryContext = null;

                for (int genAttempt = 1; genAttempt <= maxGenerationAttempts; genAttempt++)
                {
                    if (cancellationToken.IsCancellationRequested) break;

                    try
                    {
                        // ==========================================
                        // STEP 1 - CALL LLM (FEASIBILITY + SCRIPT)
                        // ==========================================

                        if (genAttempt == 1)
                            progress?.Report($"  Generating script via LLM...");
                        else
                            progress?.Report($"  Retry {genAttempt}/{maxGenerationAttempts}: Regenerating script via LLM...");

                        var response =
                            await _processor
                                .GenerateScriptAsync(
                                    item,
                                    progress,
                                    genAttempt > 1 ? retryContext : null);


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

                            _classificationRegistry[item.ChecklistId] = (
                                null,
                                response.IsAdminCheck,
                                response.IsDocumentationCheck,
                                response.McpFeasibility);

                            await WriteResultsIteratively();
                            itemSucceeded = true; // not a failure, just skipped
                            break;
                        }


                        // ==========================================
                        // STEP 2 - VALIDATE GENERATED SCRIPT FORMAT
                        // ==========================================

                        var validation =
                            _validator.Validate(response);

                        if (!validation.IsValid)
                        {
                            progress?.Report($"  FORMAT VALIDATION FAILED: {validation.Error}");

                            if (genAttempt < maxGenerationAttempts)
                            {
                                retryContext = $"Format validation failed: {validation.Error}";
                                progress?.Report($"  Will retry generation with feedback...");
                                await Task.Delay(2000);
                                continue;
                            }

                            // Final attempt failed
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
                                        $"Failed after {maxGenerationAttempts} attempts. Last error: {validation.Error}"
                                });

                            await WriteResultsIteratively();
                            break;
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

                                    if (genAttempt < maxGenerationAttempts)
                                    {
                                        retryContext = $"Content validation found issues: {contentValidation.Issues}\nValidator provided a corrected script but it also failed format validation: {revalidation.Error}";
                                        progress?.Report($"  Will retry generation with feedback...");
                                        await Task.Delay(2000);
                                        continue;
                                    }

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
                                                $"Failed after {maxGenerationAttempts} attempts. Last error: {revalidation.Error}"
                                        });

                                    await WriteResultsIteratively();
                                    break;
                                }

                                progress?.Report(
                                    $"  ✓ Corrected script passed format validation");
                            }
                            else
                            {
                                progress?.Report(
                                    $"  CONTENT VALIDATION FAILED: {contentValidation.Issues}");

                                if (genAttempt < maxGenerationAttempts)
                                {
                                    retryContext = $"Content validation failed: {contentValidation.Issues}";
                                    progress?.Report($"  Will retry generation with feedback...");
                                    await Task.Delay(2000);
                                    continue;
                                }

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
                                            $"Failed after {maxGenerationAttempts} attempts. Last issues: {contentValidation.Issues}"
                                    });

                                await WriteResultsIteratively();
                                break;
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

                        var safeName = Regex.Replace(
                            item.CheckName ?? "",
                            @"[^a-zA-Z0-9]+",
                            "_").Trim('_');
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
                            response.ScriptContent);

                        progress?.Report($"  ✓ Script saved: {response.ScriptType}/{filename}");
                        progress?.Report($"    Scope: {response.Scope} | Scoring: {response.ScoringLogic}");


                        // ==========================================
                        // STEP 5 - RECORD MAPPING
                        // ==========================================

                        _classificationRegistry[item.ChecklistId] = (
                            $"Backend/checklist/scripts/{response.ScriptType}/{filename}",
                            response.IsAdminCheck,
                            response.IsDocumentationCheck,
                            response.McpFeasibility);


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
                                    genAttempt > 1
                                    ? $"Script Generated (attempt {genAttempt})"
                                    : "Script Generated",

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
                        itemSucceeded = true;
                        break; // success — exit retry loop
                    }
                    catch (Exception ex)
                    {
                        progress?.Report($"  ERROR: {ex.Message}");

                        if (genAttempt < maxGenerationAttempts)
                        {
                            retryContext = $"Exception during generation: {ex.Message}";
                            progress?.Report($"  Will retry generation...");
                            await Task.Delay(2000);
                            continue;
                        }

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
                                    $"Failed after {maxGenerationAttempts} attempts. Last error: {ex.Message}"
                            });

                        await WriteResultsIteratively();
                    }
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