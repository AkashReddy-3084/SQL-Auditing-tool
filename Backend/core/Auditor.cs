using System;
using System.Data;
using System.Diagnostics;
using System.IO;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using System.Linq;
using Microsoft.Data.SqlClient;

namespace SQLAuditor.Lib
{
    public record ScriptResult(string ScriptName, string TextOutput, object? JsonSummary);

    public record ChecklistItem(string Id, string Description, string Category, string Verification, string ScriptFile, string Implemented);

    public record ChecklistResult
    {
        public ChecklistResult(string id, string description, string verification, string outcome, string? evidence, string scriptFile, string technique = "")
        {
            Id = id;
            Description = description;
            Verification = verification;
            Outcome = outcome;
            Evidence = evidence;
            ScriptFile = scriptFile;
            Technique = technique;
        }

        // Serialized fields, declared in the exact order required for
        // checklist_results.json: Id, Description, Outcome, Score, Evidence,
        // Severity, Finding, Recommendation, RiskImpact, Technique, Databases Verified.

        public string Id { get; init; }

        public string Description { get; init; }

        [JsonIgnore]
        public string Verification { get; init; }

        public string Outcome { get; init; }

        [JsonPropertyName("Score")]
        public int? Score { get; init; }

        [JsonPropertyName("Evidence")]
        public string? Evidence { get; init; }

        [JsonPropertyName("Severity")]
        public string Severity { get; init; } = string.Empty;

        [JsonPropertyName("Finding")]
        public string Finding { get; init; } = string.Empty;

        [JsonPropertyName("Recommendation")]
        public string? Recommendation { get; init; }

        [JsonPropertyName("RiskImpact")]
        public string? RiskImpact { get; init; }

        public string Technique { get; init; }

        [JsonPropertyName("Databases Verified")]
        public string? DatabasesVerified { get; init; }

        // ---- Internal-only fields (never serialized) ----

        // Effort and ScriptFile are consumed by the enricher/report generator but are
        // intentionally excluded from the persisted JSON schema.
        [JsonIgnore]
        public string? Effort { get; init; }

        [JsonIgnore]
        public string ScriptFile { get; init; }

        // The structured verdict a Script-technique evaluation produced. Kept in memory
        // so the AI enricher can reason over the real SQL result set; never serialized.
        [JsonIgnore]
        public SqlScriptOutcome? ScriptOutcome { get; init; }

        [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
        [JsonPropertyName("NotApplicable")]
        public bool? NotApplicable { get; init; }

        [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
        [JsonPropertyName("NotApplicableJustification")]
        public string? NotApplicableJustification { get; init; }

        [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
        [JsonPropertyName("rawAttribute")]
        public JsonElement? RawAttribute { get; init; }

        [JsonIgnore]
        public string? McpUsage { get; init; }

        [JsonIgnore]
        public long? McpExecutionTimeMs { get; init; }

        [JsonIgnore]
        public string? McpEvidence { get; init; }
    }

    public class Auditor
    {
        // checklist_results.json is written by this engine at the end of a run and, in the WPF
        // flow, by the manual Pass/Fail handler while the run is still in progress. Both writers
        // take this lock so neither can observe or produce a half-written file.
        public static readonly object ResultsFileLock = new object();

        private string _connectionString;
        private SqlServerMcpEvaluator? _mcpEvaluator;
        private ManualStepsGenerator? _manualStepsGenerator;
        private ScriptResultAiEnricher? _scriptEnricher;
        private ManualResultAiEnricher? _manualResultEnricher;

        public Auditor(string connectionString)
        {
            _connectionString = connectionString;
            // Evaluators are created tolerantly so the auditor can be built for SQL-only
            // operations (connection verification, checklist loading) before the user has
            // supplied LLM settings at runtime.
            EnsureLlmEvaluators();
        }

        // Creates the LLM evaluators if they don't exist yet. Safe to call repeatedly;
        // it is a no-op once the evaluators exist and silently skips when LLM settings
        // are not yet configured.
        public void EnsureLlmEvaluators()
        {
            if (_llmDisabled) return;
            try { _mcpEvaluator ??= SqlServerMcpEvaluator.CreateFromEnvironment(); } catch { }
            try { _manualStepsGenerator ??= ManualStepsGenerator.CreateFromEnvironment(); } catch { }
            try { _scriptEnricher ??= ScriptResultAiEnricher.CreateFromEnvironment(); } catch { }
            try { _manualResultEnricher ??= ManualResultAiEnricher.CreateFromEnvironment(); } catch { }
        }

        // When set, the auditor never creates LLM evaluators (even if .env or env vars
        // are present). The IDE/MCP server calls this so GitHub Copilot Chat is the AI
        // and the server makes no direct LLM/API calls. CLI and WPF do not set it.
        private static bool _llmDisabled;
        public static void DisableLlmEvaluators() => _llmDisabled = true;

        // Supplies LLM provider settings at runtime (from the UI). Not persisted to disk;
        // these values take precedence over any .env or environment variables.
        public static void SetLlmConfig(string baseUrl, string apiKey, string model)
            => ProviderConfig.SetRuntime(baseUrl, apiKey, model);

        // Verifies the currently-configured LLM provider by issuing a minimal request.
        public static async Task<(bool Ok, string Message)> VerifyLlmAsync(System.Threading.CancellationToken cancellationToken = default)
        {
            string baseUrl, apiKey, model;
            try { baseUrl = ProviderConfig.BaseUrl; apiKey = ProviderConfig.ApiKey; model = ProviderConfig.Model; }
            catch (Exception ex) { return (false, ex.Message); }

            try
            {
                using var http = new System.Net.Http.HttpClient { Timeout = TimeSpan.FromSeconds(120) };
                http.DefaultRequestHeaders.Authorization = new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", apiKey);
                var body = new { model, max_tokens = 1, messages = new[] { new { role = "user", content = "ping" } } };
                using var content = new System.Net.Http.StringContent(JsonSerializer.Serialize(body), System.Text.Encoding.UTF8, "application/json");
                using var resp = await http.PostAsync(baseUrl + "/chat/completions", content, cancellationToken);
                if (resp.IsSuccessStatusCode) return (true, $"Connected to model '{model}'.");
                var txt = await resp.Content.ReadAsStringAsync(cancellationToken);
                if (txt.Length > 300) txt = txt.Substring(0, 300);
                return (false, $"HTTP {(int)resp.StatusCode} {resp.ReasonPhrase}: {txt}");
            }
            catch (Exception ex) { return (false, ex.Message); }
        }

        // --- Remaining methods omitted for brevity; this Auditor is a lightweight stub for UI testing ---

        public async Task<System.Collections.Generic.List<(string Area, ChecklistItem[] Items)>> GetChecklistStructureAsync()
        {
            var repoRoot = FindRepoRoot();
            if (repoRoot == null) throw new FileNotFoundException("Checklist not found in repository root.");
            // Prefer JSON master checklist under Backend/checklist/master_checklist.json when present
            string[] lines;
            var jsonPath = Path.Combine(repoRoot, "Backend", "checklist", "master_checklist.json");
            var jsonPathAlt = Path.Combine(repoRoot, "Backend", "checklist", "master-checklist.json");
            var checklistCandidate = Path.Combine(repoRoot, "SQL", "02-audit-checklist.md");
            var mappingPath = Path.Combine(repoRoot, "Backend", "checklist", "master_checklist.md");
            // accept either master_checklist.json or master-checklist.json
            var effectiveJson = File.Exists(jsonPath) ? jsonPath : (File.Exists(jsonPathAlt) ? jsonPathAlt : null);
            if (effectiveJson != null)
            {
                try
                {
                    var json = await File.ReadAllTextAsync(effectiveJson);
                    var builder = new System.Collections.Generic.List<string>();
                    using var jd = JsonDocument.Parse(json);
                    var root = jd.RootElement;
                    // Support two schemas:
                    // 1) simple array of { Id, Description, Category, Verification, ScriptFile }
                    // 2) nested { areas: [ { id, title, sub_areas: [ { id, title, items: [ { id, text } ] } ] } ] }
                    if (root.ValueKind == JsonValueKind.Array)
                    {
                        foreach (var el in root.EnumerateArray())
                        {
                            var id = el.TryGetProperty("Id", out var pid) ? pid.GetString() : null;
                            var desc = el.TryGetProperty("Description", out var pdesc) ? pdesc.GetString() : null;
                            if (!string.IsNullOrWhiteSpace(id) && !string.IsNullOrWhiteSpace(desc))
                            {
                                var line = id + " | " + desc;
                                if (el.TryGetProperty("Category", out var pcat) && pcat.ValueKind != JsonValueKind.Null) line += " | Cat:" + pcat.GetString();
                                if (el.TryGetProperty("Verification", out var pver) && pver.ValueKind != JsonValueKind.Null) line += " | Verification:" + pver.GetString();
                                if (el.TryGetProperty("ScriptFile", out var psf) && psf.ValueKind != JsonValueKind.Null) line += " | ScriptFile:" + psf.GetString();
                                builder.Add(line);
                            }
                        }
                    }
                    else if (root.ValueKind == JsonValueKind.Object && root.TryGetProperty("areas", out var areas) && areas.ValueKind == JsonValueKind.Array)
                    {
                        var structuredResult = new System.Collections.Generic.List<(string Area, ChecklistItem[] Items)>();
                        foreach (var area in areas.EnumerateArray())
                        {
                            var areaTitle = area.TryGetProperty("title", out var at) ? at.GetString() : area.TryGetProperty("id", out var aid) ? aid.GetString() : "Area";
                            var currentAreaItems = new System.Collections.Generic.List<ChecklistItem>();
                            if (area.TryGetProperty("sub_areas", out var subs) && subs.ValueKind == JsonValueKind.Array)
                            {
                                foreach (var sub in subs.EnumerateArray())
                                {
                                    var subTitle = sub.TryGetProperty("title", out var st) ? st.GetString() : sub.TryGetProperty("id", out var sid) ? sid.GetString() : string.Empty;
                                    if (sub.TryGetProperty("items", out var items) && items.ValueKind == JsonValueKind.Array)
                                    {
                                        foreach (var it in items.EnumerateArray())
                                        {
                                            var id = it.TryGetProperty("id", out var iid) ? iid.GetString() : null;
                                            var text = it.TryGetProperty("text", out var txt) ? txt.GetString() : it.TryGetProperty("description", out var dsc) ? dsc.GetString() : null;
                                            if (!string.IsNullOrWhiteSpace(id) && !string.IsNullOrWhiteSpace(text))
                                            {
                                                currentAreaItems.Add(new ChecklistItem(id, text, subTitle, string.Empty, string.Empty, string.Empty));
                                            }
                                        }
                                    }
                                }
                            }
                            if (currentAreaItems.Count > 0)
                            {
                                structuredResult.Add((areaTitle ?? "Area", currentAreaItems.ToArray()));
                            }
                        }
                        return structuredResult;
                    }
                    lines = builder.ToArray();
                }
                catch
                {
                    // fallback to markdown parsing if JSON invalid
                    lines = Array.Empty<string>();
                }
            }
            else if (File.Exists(checklistCandidate))
            {
                lines = await File.ReadAllLinesAsync(checklistCandidate);
            }
            else
            {
                if (!File.Exists(mappingPath)) mappingPath = Path.Combine(repoRoot, "implementation-tracking.md");
                if (!File.Exists(mappingPath)) throw new FileNotFoundException("Checklist file not found at SQL/02-audit-checklist.md or Backend/checklist/master_checklist.md/implementation-tracking.md or Backend/checklist/master_checklist.json");
                lines = await File.ReadAllLinesAsync(mappingPath);
            }
            var result = new System.Collections.Generic.List<(string, ChecklistItem[])>();
            string currentArea = "General";
            string currentCategoryHeader = string.Empty;
            var areaItems = new System.Collections.Generic.List<ChecklistItem>();

            foreach (var rawLine in lines)
            {
                if (string.IsNullOrWhiteSpace(rawLine)) continue;
                var raw = rawLine.Trim();

                // Area header: 'Area 1: Title' or '## Area 1: Title' or 'Area 1 - Title'
                var areaMatch = System.Text.RegularExpressions.Regex.Match(raw, @"^#{0,6}\s*(Area\s+\d+[:\-]?)\s*(.*)$", System.Text.RegularExpressions.RegexOptions.IgnoreCase);
                if (areaMatch.Success)
                {
                    if (areaItems.Count > 0) { result.Add((currentArea, areaItems.ToArray())); areaItems.Clear(); }
                    var title = (areaMatch.Groups[1].Value + " " + areaMatch.Groups[2].Value).Trim();
                    currentArea = System.Text.RegularExpressions.Regex.Replace(title, @"^#+\s*", "").Trim();
                    currentCategoryHeader = string.Empty;
                    continue;
                }

                // Category header: '### 1.1 Title' or '1.1 Title' as header
                var catMatch = System.Text.RegularExpressions.Regex.Match(raw, @"^#{1,6}\s*(\d+(?:\.\d+)*)\s*(.*)$");
                if (catMatch.Success)
                {
                    currentCategoryHeader = string.IsNullOrWhiteSpace(catMatch.Groups[2].Value) ? catMatch.Groups[1].Value.Trim() : ($"{catMatch.Groups[1].Value.Trim()} {catMatch.Groups[2].Value.Trim()}");
                    continue;
                }

                // If line contains pipe-separated fields, prefer that parsing
                if (raw.Contains("|") )
                {
                    var parts = raw.Split('|').Select(p => p.Trim()).Where(p => p.Length > 0).ToArray();
                    // Expect at least id and description
                    if (parts.Length >= 2 && System.Text.RegularExpressions.Regex.IsMatch(parts[0], "^\\d+(?:\\.\\d+)*$"))
                    {
                        var id = parts[0];
                        var desc = parts[1];
                        string cat = string.Empty, ver = string.Empty, script = string.Empty, impl = string.Empty;
                        // Attempt to find labeled fields in remaining parts
                        for (int i = 2; i < parts.Length; i++)
                        {
                            var p = parts[i];
                            if (p.StartsWith("Cat:", StringComparison.OrdinalIgnoreCase)) cat = MapCategoryLabel(p.Substring(4).Trim());
                            else if (p.StartsWith("Verification:", StringComparison.OrdinalIgnoreCase)) ver = p.Substring(13).Trim();
                            else if (p.StartsWith("ScriptFile:", StringComparison.OrdinalIgnoreCase)) script = p.Substring(11).Trim();
                            else if (p.StartsWith("Implemented:", StringComparison.OrdinalIgnoreCase)) impl = p.Substring(12).Trim();
                        }
                        if (string.IsNullOrWhiteSpace(cat)) cat = string.IsNullOrWhiteSpace(currentCategoryHeader) ? MapCategoryLabel(string.Empty) : currentCategoryHeader;
                        if (string.IsNullOrWhiteSpace(ver)) ver = string.Empty;
                        if (string.IsNullOrWhiteSpace(script)) script = string.Empty;
                        if (string.IsNullOrWhiteSpace(impl)) impl = string.Empty;
                        // If no explicit category header, derive from id prefix (e.g., 1.1)
                        if (string.IsNullOrWhiteSpace(currentCategoryHeader) && string.IsNullOrWhiteSpace(cat))
                        {
                            var idParts = id.Split('.');
                            if (idParts.Length >= 2) cat = string.Join('.', idParts.Take(2));
                        }
                        areaItems.Add(new ChecklistItem(id, desc, cat, ver, script, impl));
                        continue;
                    }
                }

                // Fallback: lines like '1.1.1 Description...' or '1.1.1 | ...' without full labeling
                var itemMatch = System.Text.RegularExpressions.Regex.Match(raw, @"^(\d+(?:\.\d+)*)(?:[\t\s\-|:]+)(.+)$");
                if (itemMatch.Success)
                {
                    var id = itemMatch.Groups[1].Value.Trim();
                    var desc = itemMatch.Groups[2].Value.Trim();
                    // derive category from id when no header provided
                    string cat = currentCategoryHeader;
                    if (string.IsNullOrWhiteSpace(cat))
                    {
                        var idParts = id.Split('.');
                        if (idParts.Length >= 2) cat = string.Join('.', idParts.Take(2));
                        else cat = string.Empty;
                    }
                    areaItems.Add(new ChecklistItem(id, desc, cat, string.Empty, string.Empty, string.Empty));
                    continue;
                }
            }

            if (areaItems.Count > 0) result.Add((currentArea, areaItems.ToArray()));
            return result;
        }

        private string? FindRepoRoot()
        {
            var dir = new DirectoryInfo(Directory.GetCurrentDirectory());
            while (dir != null)
            {
                var checklistMd = Path.Combine(dir.FullName, "Backend", "checklist", "master_checklist.md");
                var checklistMdAlt = Path.Combine(dir.FullName, "Backend", "checklist", "master-checklist.md");
                var checklistJson = Path.Combine(dir.FullName, "Backend", "checklist", "master_checklist.json");
                var checklistJsonAlt = Path.Combine(dir.FullName, "Backend", "checklist", "master-checklist.json");
                if (File.Exists(checklistMd) || File.Exists(checklistMdAlt) || File.Exists(checklistJson) || File.Exists(checklistJsonAlt)) return dir.FullName;
                var candidate = Path.Combine(dir.FullName, "implementation-tracking.md");
                if (File.Exists(candidate)) return dir.FullName;
                dir = dir.Parent;
            }
            return null;
        }

        private string? FindSqlScriptsFolder()
        {
            var dir = new DirectoryInfo(Directory.GetCurrentDirectory());
            while (dir != null)
            {
                // Prefer curated backend scripts folder when present
                var checklistCandidate = Path.Combine(dir.FullName, "Backend", "checklist", "scripts", "sql");
                if (Directory.Exists(checklistCandidate)) return checklistCandidate;
                var backendCandidate = Path.Combine(dir.FullName, "Backend", "scripts", "sql");
                if (Directory.Exists(backendCandidate)) return backendCandidate;
                var candidate = Path.Combine(dir.FullName, "SQL", "scripts");
                if (Directory.Exists(candidate)) return candidate;
                dir = dir.Parent;
            }
            return null;
        }

        private static string MapCategoryLabel(string raw)
        {
            if (string.IsNullOrWhiteSpace(raw)) return string.Empty;
            var s = raw.Trim();
            // strip Markdown emphasis and non-alphanumeric wrappers
            s = System.Text.RegularExpressions.Regex.Replace(s, @"[*_\[\]\(\)]", "").Trim();
            // If the value looks like a numeric category code (e.g. 1, 2, 4.2), return it as-is
            if (System.Text.RegularExpressions.Regex.IsMatch(s, @"^\d+(?:\.\d+)*$") ) return s;
            // Preserve human-readable labels when they appear
            if (s.IndexOf("Automated", StringComparison.OrdinalIgnoreCase) >= 0) return "Automated";
            if (s.IndexOf("Admin", StringComparison.OrdinalIgnoreCase) >= 0) return "Admin Review";
            if (s.IndexOf("Client", StringComparison.OrdinalIgnoreCase) >= 0 || s.IndexOf("Documentation", StringComparison.OrdinalIgnoreCase) >= 0) return "Client Documentation";
            return s;
        }

        private object SummarizeTextResultToJson(string name, string text)
        {
            var lines = text?.Split(new[] { '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries) ?? Array.Empty<string>();
            int errorCount = 0;
            foreach (var l in lines) if (l.IndexOf("ERROR", StringComparison.OrdinalIgnoreCase) >= 0) errorCount++;
            return new { Script = name, LineCount = lines.Length, ErrorCount = errorCount, Sample = lines.Take(Math.Min(5, lines.Length)).ToArray() };
        }

        private static string? FindExecutable(string name)
        {
            var paths = Environment.GetEnvironmentVariable("PATH")?.Split(Path.PathSeparator) ?? Array.Empty<string>();
            foreach (var p in paths)
            {
                try
                {
                    var candidate = Path.Combine(p, name + (OperatingSystem.IsWindows() ? ".exe" : string.Empty));
                    if (File.Exists(candidate)) return candidate;
                }
                catch { }
            }
            return null;
        }

        private async Task<string> RunPowerShellScriptAsync(string scriptPath)
        {
            var psi = new ProcessStartInfo();
            var pwsh = FindExecutable("pwsh") ?? FindExecutable("powershell");
            if (pwsh == null) throw new InvalidOperationException("No PowerShell executable found (pwsh or powershell)");
            psi.FileName = pwsh;
            psi.Arguments = $"-NoProfile -ExecutionPolicy Bypass -File \"{scriptPath}\"";
            psi.RedirectStandardOutput = true;
            psi.RedirectStandardError = true;
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;
            using var proc = Process.Start(psi)!;
            var outText = await proc.StandardOutput.ReadToEndAsync();
            var errText = await proc.StandardError.ReadToEndAsync();
            await proc.WaitForExitAsync();
            return outText + (string.IsNullOrWhiteSpace(errText) ? string.Empty : "\nERRORS:\n" + errText);
        }

        public async Task<ScriptResult[]> RunAllScriptsAsync()
        {
            var scriptsDir = FindSqlScriptsFolder();
            if (scriptsDir == null) return Array.Empty<ScriptResult>();
            var resultsDir = AuditOutputPaths.BeginRun(_connectionString);
            var list = new System.Collections.Generic.List<ScriptResult>();
            foreach (var f in Directory.GetFiles(scriptsDir, "*.sql"))
            {
                var txt = await RunScriptFileAsync(f);
                var json = SummarizeTextResultToJson(Path.GetFileName(f), txt);
                var outPath = Path.Combine(resultsDir, Path.GetFileNameWithoutExtension(f) + "_result.txt");
                await File.WriteAllTextAsync(outPath, txt);
                var jsonPath = Path.Combine(resultsDir, Path.GetFileNameWithoutExtension(f) + ".json");
                await File.WriteAllTextAsync(jsonPath, JsonSerializer.Serialize(json, new JsonSerializerOptions { WriteIndented = true }));
                list.Add(new ScriptResult(Path.GetFileName(f), txt, json));
            }
            return list.ToArray();
        }

        public async Task<string> RunScriptFileAsync(string path)
        {
            if (!File.Exists(path)) throw new FileNotFoundException("Script not found", path);
            var ext = Path.GetExtension(path);
            if (ext.Equals(".ps1", StringComparison.OrdinalIgnoreCase))
            {
                try { return await RunPowerShellScriptAsync(path); } catch (Exception ex) { return "PS ERROR: " + ex.Message; }
            }
            else
            {
                var txt = await File.ReadAllTextAsync(path);
                // If we have a DB connection configured, attempt to execute SQL batches and capture output
                if (!string.IsNullOrWhiteSpace(_connectionString))
                {
                    try
                    {
                        var sb = new System.Text.StringBuilder();
                        // Split batches by standalone GO on its own line
                        var batches = System.Text.RegularExpressions.Regex.Split(txt, @"^GO\s*$", System.Text.RegularExpressions.RegexOptions.IgnoreCase | System.Text.RegularExpressions.RegexOptions.Multiline);
                        using var conn = new SqlConnection(_connectionString);
                        await conn.OpenAsync();
                        int batchNo = 1;
                        foreach (var batch in batches)
                        {
                            var script = batch.Trim();
                            if (string.IsNullOrWhiteSpace(script)) { batchNo++; continue; }
                            sb.AppendLine($"--- Batch {batchNo} ---");
                            try
                            {
                                using var cmd = new SqlCommand(script, conn) { CommandTimeout = 120 };
                                using var rdr = await cmd.ExecuteReaderAsync();
                                int rowCount = 0;
                                while (await rdr.ReadAsync())
                                {
                                    rowCount++;
                                    var cols = new System.Collections.Generic.List<string>();
                                    for (int i = 0; i < rdr.FieldCount; i++)
                                    {
                                        try { cols.Add(rdr.IsDBNull(i) ? "NULL" : rdr.GetValue(i)?.ToString() ?? string.Empty); }
                                        catch { cols.Add("<err>"); }
                                    }
                                    sb.AppendLine(string.Join('\t', cols));
                                }
                                sb.AppendLine($"(rows: {rowCount})");
                                // move to next result set if any
                                while (await rdr.NextResultAsync()) { /* iterate to exhaust results */ }
                            }
                            catch (Exception ex)
                            {
                                sb.AppendLine("SQL ERROR: " + ex.Message);
                            }
                            batchNo++;
                        }
                        await conn.CloseAsync();
                        return sb.ToString();
                    }
                    catch (Exception ex)
                    {
                        return "SQL EXEC ERROR: " + ex.Message + "\n\nScript contents:\n" + txt;
                    }
                }

                // No DB connection — return file contents as dry-run output
                return txt;
            }
        }

        public void ShowMappingFile()
        {
            var repoRoot = FindRepoRoot();
            if (repoRoot == null) { Console.WriteLine("Repository root not found"); return; }
            var mapping = Path.Combine(repoRoot, "Backend", "checklist", "deterministic-script-mapping.json");
            if (File.Exists(mapping)) { Console.WriteLine(File.ReadAllText(mapping)); return; }
            var legacy = Path.Combine(repoRoot, "Backend", "checklist", "master_checklist.md");
            if (File.Exists(legacy)) { Console.WriteLine(File.ReadAllText(legacy)); return; }
            var fallback = Path.Combine(repoRoot, "implementation-tracking.md");
            if (File.Exists(fallback)) Console.WriteLine(File.ReadAllText(fallback));
            else Console.WriteLine("Mapping file not found.");
        }

        // Save a generated script and update deterministic-script-mapping.json to track it.
        // IMPORTANT: This API is reserved for the UI "Generate Scripts" operator action only.
        // The Generate Scripts button in the checklist UI is currently disabled; do NOT call
        // this method from any automated runtime paths. Keep this method as the single
        // intentional writer for scripts under Backend/checklist/scripts/sql and for the
        // deterministic mapping. Any other code that modifies files under scripts/sql
        // must be removed or refactored to call this method only via the operator-driven UI.
        // This method intentionally performs file writes (script + mapping) and is best
        // executed only with operator consent.
        // This method is currently retained but the UI button that invokes it is disabled/commented.
        public async Task<string> SaveGeneratedScriptAsync(string checklistId, string scriptText, string? suggestedFileName = null)
        {
            var repoRoot = FindRepoRoot() ?? Directory.GetCurrentDirectory();
            var scriptsDir = Path.Combine(repoRoot, "Backend", "checklist", "scripts", "sql");
            Directory.CreateDirectory(scriptsDir);
            var safeId = System.Text.RegularExpressions.Regex.Replace(checklistId ?? "unknown", "[^a-zA-Z0-9_.-]", "_");
            var fileName = string.IsNullOrWhiteSpace(suggestedFileName)? $"{safeId}.sql" : suggestedFileName;
            var fullPath = Path.Combine(scriptsDir, fileName);
            await File.WriteAllTextAsync(fullPath, scriptText ?? string.Empty);

            // Update deterministic mapping
            try
            {
                var mapPath = Path.Combine(repoRoot, "Backend", "checklist", "deterministic-script-mapping.json");
                var mappingDict = new System.Collections.Generic.Dictionary<string, JsonElement>();
                if (File.Exists(mapPath))
                {
                    try
                    {
                        using var doc = JsonDocument.Parse(File.ReadAllText(mapPath));
                        foreach (var prop in doc.RootElement.EnumerateObject())
                            mappingDict[prop.Name] = prop.Value.Clone();
                    }
                    catch { mappingDict = new(); }
                }

                var rel = Path.Combine("Backend", "checklist", "scripts", "sql", fileName).Replace(Path.DirectorySeparatorChar, '/');
                var newEntry = JsonSerializer.SerializeToElement(new { script_file = rel, IsAdminCheck = false, IsDocumentationCheck = false, MCP_Feasibility = true });
                mappingDict[checklistId] = newEntry;
                await File.WriteAllTextAsync(mapPath, JsonSerializer.Serialize(mappingDict, new JsonSerializerOptions { WriteIndented = true }));
            }
            catch { /* best-effort only */ }

            return fullPath;
        }

        /// <param name="useHistoricalManualResults">
        /// When true, manual/AI-Manual items that already have a completed result in
        /// results/historical_last_run.json are copied forward and skip manual-step generation and
        /// manual review entirely. The caller must decide this explicitly; the engine never infers it.
        /// </param>
        /// <param name="generateReports">
        /// When true (WPF), final_report.md and audit_report.xlsx are produced as soon as the run
        /// finishes. The CLI and IDE hosts pass false and generate the reports only after the user
        /// explicitly asks for them.
        /// </param>
        public async Task<ChecklistResult[]> RunChecklistAsync(IProgress<ChecklistResult>? progress = null, Func<ChecklistItem, string, Task<string?>>? requestUserInput = null, System.Collections.Generic.IEnumerable<string>? selectedIds = null, System.Threading.CancellationToken cancellationToken = default, bool useHistoricalManualResults = false, bool generateReports = true)
        {
            // Ensure LLM evaluators reflect any runtime configuration provided after construction.
            EnsureLlmEvaluators();
            var resultsDir = AuditOutputPaths.BeginRun(_connectionString);
            var structure = await GetChecklistStructureAsync();
            var repoRoot = FindRepoRoot() ?? Directory.GetCurrentDirectory();

            // normalize connection (try alternate server variants) so script execution reuses a working connection string when possible
            try { await TestAndNormalizeConnectionAsync(); } catch { }

            // load deterministic mapping if present
            var mapping = new System.Collections.Generic.Dictionary<string, string[]>();
            // Items whose compliance can only be judged from external documentation.
            var documentationItems = new System.Collections.Generic.HashSet<string>(StringComparer.OrdinalIgnoreCase);
            // Items needing elevated rights: the script is still generated, but the operator runs it.
            var adminItems = new System.Collections.Generic.HashSet<string>(StringComparer.OrdinalIgnoreCase);
            try
            {
                var mapPath = Path.Combine(repoRoot, "Backend", "checklist", "deterministic-script-mapping.json");
                if (File.Exists(mapPath))
                {
                    var mapJson = File.ReadAllText(mapPath);
                    using var mapDoc = JsonDocument.Parse(mapJson);
                    foreach (var prop in mapDoc.RootElement.EnumerateObject())
                    {
                        if (prop.Value.ValueKind == JsonValueKind.Array)
                        {
                            // Legacy format: { "id": ["path1", ...] }
                            var arr = prop.Value.EnumerateArray()
                                .Select(e => e.GetString() ?? string.Empty)
                                .Where(s => !string.IsNullOrWhiteSpace(s))
                                .ToArray();
                            mapping[prop.Name] = arr;
                        }
                        else if (prop.Value.ValueKind == JsonValueKind.Object)
                        {
                            // New format: { "id": { "script_file": "path", ... } }
                            var scriptFile = prop.Value.TryGetProperty("script_file", out var sf) ? sf.GetString() : null;
                            if (!string.IsNullOrWhiteSpace(scriptFile))
                                mapping[prop.Name] = new[] { scriptFile! };

                            if (prop.Value.TryGetProperty("IsDocumentationCheck", out var docCheck) && docCheck.ValueKind == JsonValueKind.True)
                                documentationItems.Add(prop.Name);

                            if (prop.Value.TryGetProperty("IsAdminCheck", out var adminCheck) && adminCheck.ValueKind == JsonValueKind.True)
                                adminItems.Add(prop.Name);
                        }
                    }
                }
                // Normalize any legacy SQL/scripts/checks references to Backend/checklist/scripts/sql
                var keys = mapping.Keys.ToArray();
                foreach (var k in keys)
                {
                    var arr = mapping[k];
                    if (arr == null) continue;
                    var normalized = arr.Select(s => s?.Replace("Backend/checklist/tools/sql/", "Backend/checklist/scripts/sql/") ?? s).Distinct().ToArray();
                    mapping[k] = normalized;
                }
            }
            catch { }

            var results = new System.Collections.Concurrent.ConcurrentBag<ChecklistResult>();

            var selectedSet = selectedIds != null && selectedIds.Any()
                ? new System.Collections.Generic.HashSet<string>(selectedIds)
                : null;
            var nonBlockingManualFallback = selectedSet != null;

            var selectedItems = new System.Collections.Generic.List<ChecklistItem>();
            foreach (var (_, items) in structure)
            {
                foreach (var it in items)
                {
                    if (selectedSet != null && !selectedSet.Contains(it.Id)) continue;
                    selectedItems.Add(it);
                }
            }

            bool IsDocumentationCheck(ChecklistItem item)
            {
                return documentationItems.Contains(item.Id);
            }

            bool IsAdminCheck(ChecklistItem item)
            {
                return adminItems.Contains(item.Id);
            }

            // Both documentation and admin checks go to AI-Manual. A documentation check has no script
            // at all; an admin check keeps its script but the operator executes it, not the tool.
            bool IsScriptMapped(ChecklistItem item)
            {
                if (IsDocumentationCheck(item) || IsAdminCheck(item)) return false;
                return mapping.TryGetValue(item.Id, out var files) && files != null && files.Length > 0;
            }

            string? ReadMappedScript(ChecklistItem item)
            {
                if (!mapping.TryGetValue(item.Id, out var files) || files == null) return null;
                foreach (var f in files)
                {
                    try
                    {
                        var full = Path.IsPathRooted(f) ? f : Path.Combine(repoRoot, f.Replace('/', Path.DirectorySeparatorChar));
                        if (File.Exists(full)) return File.ReadAllText(full);
                    }
                    catch { }
                }
                return null;
            }

            var scriptItems = selectedItems.Where(IsScriptMapped).ToList();
            var aiItems = selectedItems.Where(it => !IsScriptMapped(it)).ToList();

            // Historical reuse: manual/AI-Manual items decided in an earlier run are copied
            // forward verbatim and never reach the manual pipeline, so no manual steps are
            // generated, no review is queued and no LLM call is made for them. Script and
            // AI-MCP items are untouched — an entry only qualifies when the recorded technique
            // is manual.
            var copiedFromHistory = new System.Collections.Generic.List<ChecklistResult>();
            if (useHistoricalManualResults)
            {
                try
                {
                    var historical = HistoricalManualResultsStore.Load();
                    if (historical.Count > 0)
                    {
                        var remaining = new System.Collections.Generic.List<ChecklistItem>(aiItems.Count);
                        foreach (var it in aiItems)
                        {
                            if (historical.TryGetValue(it.Id, out var entry)
                                && HistoricalManualResultsStore.TryBuildResult(entry, it, out var copied))
                            {
                                results.Add(copied);
                                copiedFromHistory.Add(copied);
                                progress?.Report(copied);
                                continue;
                            }
                            remaining.Add(it);
                        }
                        aiItems = remaining;
                    }

                    if (copiedFromHistory.Count > 0)
                        LogDiagnostic($"Copied {copiedFromHistory.Count} manual result(s) from {HistoricalManualResultsStore.FileName}.");
                }
                catch (Exception ex)
                {
                    // A missing or malformed historical file must never fail a run: fall back to
                    // the normal manual flow for every item.
                    LogDiagnostic($"Historical manual result reuse skipped: {ex.GetType().Name}: {ex.Message}");
                }
            }

            async Task<ChecklistResult?> EvaluateScriptAsync(ChecklistItem it, Microsoft.Data.SqlClient.SqlConnection? pipelineConn)
            {
                var allRows = new System.Collections.Generic.List<SqlScriptRow>();
                var textLog = new System.Text.StringBuilder();
                string? execError = null;
                var files = mapping[it.Id];
                foreach (var f in files)
                {
                    try
                    {
                        var full = f;
                        if (!Path.IsPathRooted(f)) full = Path.Combine(repoRoot, f.Replace('/', Path.DirectorySeparatorChar));
                        if (File.Exists(full))
                        {
                            var txt = await File.ReadAllTextAsync(full);
                            if (pipelineConn != null)
                            {
                                var (log, rows) = await ExecuteSqlCaptureAsync(pipelineConn, txt);
                                allRows.AddRange(rows);
                                if (!string.IsNullOrWhiteSpace(log)) textLog.AppendLine(log);
                            }
                            else
                            {
                                textLog.AppendLine(await RunScriptFileAsync(full));
                            }
                        }
                        else
                        {
                            var checks = Path.Combine(repoRoot, "SQL", "scripts", "checks");
                            var match = Directory.Exists(checks) ? Directory.GetFiles(checks, it.Id + "_*", SearchOption.TopDirectoryOnly).FirstOrDefault() : null;
                            if (match != null)
                            {
                                textLog.AppendLine(await RunScriptFileAsync(match));
                            }
                        }
                    }
                    catch (Exception ex)
                    {
                        execError = ex.Message;
                        textLog.AppendLine("Script error: " + ex.Message);
                    }
                }

                // The script's final SELECT (Result/Score/DatabaseQueried/Finding) is the
                // factual source. Preserve the verdict and score it returned; only fall back
                // to scraping the console text when the script exposed no structured result.
                // Either way the verdict is Pass or Fail - a script item is never deferred to
                // a reviewer; only the Not Applicable check below can move it off that verdict.
                var scriptOutcome = SqlScriptResultParser.Parse(allRows, execError);
                var outcome = scriptOutcome.Result
                    ?? EvaluationDecisionService.EvaluateScriptEvidenceOutcome(textLog.ToString());
                var score = scriptOutcome.Score;

                // Turn the structured SQL result into audit-report wording (Finding, Evidence,
                // RiskImpact, Recommendation, Severity) using only the values the script
                // returned. When the provider is unavailable the enricher returns null: we then
                // keep the script's own finding and leave the AI-authored fields null rather
                // than emitting generic filler (Severity is still derived from the rubric by
                // ChecklistResultEnricher during the post-pipeline back-fill).
                ScriptResultAiEnricher.ScriptEnrichment? ai = null;
                if (_scriptEnricher != null && scriptOutcome.HasStructuredResult)
                {
                    try
                    {
                        ai = await _scriptEnricher.EnrichAsync(it, outcome, score, scriptOutcome, cancellationToken);
                    }
                    catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
                    {
                        throw;
                    }
                    catch
                    {
                        ai = null;
                    }
                }

                var finding = !string.IsNullOrWhiteSpace(ai?.Finding)
                    ? ai!.Finding!
                    : (scriptOutcome.Finding ?? string.Empty);

                // Evidence opening with "Not Applicable." means the enricher found no
                // supporting artefact at all: the control does not exist to be assessed, so
                // the item is reported as Not Applicable and carries no weight in the score.
                var notApplicable = NotApplicableEvidence.IsMarked(ai?.Evidence);
                if (notApplicable) outcome = NotApplicableEvidence.Outcome;

                return new ChecklistResult(it.Id, it.Description, it.Verification, outcome, ai?.Evidence, string.Join(';', files), "Script")
                {
                    Score = score,
                    Finding = finding,
                    Severity = string.IsNullOrWhiteSpace(ai?.Severity) ? string.Empty : ai!.Severity!,
                    RiskImpact = ai?.RiskImpact,
                    Recommendation = ai?.Recommendation,
                    DatabasesVerified = scriptOutcome.DatabasesVerified,
                    ScriptOutcome = scriptOutcome,
                    NotApplicable = notApplicable ? true : null,
                };
            }

            async Task<ChecklistResult?> EvaluateAiAsync(ChecklistItem it, Microsoft.Data.SqlClient.SqlConnection? pipelineConn)
            {
                if (_mcpEvaluator != null && !string.IsNullOrWhiteSpace(_connectionString) && !IsDocumentationCheck(it) && !IsAdminCheck(it))
                {
                    try
                    {
                        ChecklistResult? mcp = null;
                        if (pipelineConn != null)
                        {
                            mcp = await _mcpEvaluator.EvaluateAsync(it, pipelineConn, cancellationToken);
                        }
                        else
                        {
                            mcp = await _mcpEvaluator.EvaluateAsync(it, _connectionString, cancellationToken);
                        }

                        if (mcp != null)
                        {
                            return mcp;
                        }
                    }
                    catch (Exception ex)
                    {
                        LogDiagnostic($"SQL MCP evaluation error for {it.Id}: {ex.GetType().Name}: {ex.Message}");
                    }
                }

                var manualStartingProgress = new ChecklistResult(it.Id, it.Description, it.Verification, "Evaluating", string.Empty, it.ScriptFile, "AI-Manual");
                progress?.Report(manualStartingProgress);

                // An admin check keeps its generated script so the operator can run it themselves.
                var auditScript = IsAdminCheck(it) && !IsDocumentationCheck(it) ? ReadMappedScript(it) : null;

                // Only reached once MCP has declined or failed, so the guidance is never wasted work.
                var manualPlan = await GenerateManualInstructionsWithMetadataAsync(it, auditScript, cancellationToken);

                if (requestUserInput != null && nonBlockingManualFallback)
                {
                    _ = Task.Run(async () =>
                    {
                        try
                        {
                            await requestUserInput(it, manualPlan.Instructions);
                        }
                        catch
                        {
                            try { await requestUserInput(it, "Manual verification guidance could not be generated. Please validate this checklist item manually."); } catch { }
                        }
                    }, cancellationToken);

                    return new ChecklistResult(it.Id, it.Description, it.Verification, "Evaluating", "Manual review queued", it.ScriptFile, "AI-Manual");
                }

                var instructions = manualPlan.Instructions;
                string BuildManualEvidence(string manualSteps, string operatorResponse)
                {
                    return $"Manual Steps:\n{manualSteps}\n\nOperator Response:\n{operatorResponse}";
                }

                if (requestUserInput != null)
                {
                    try
                    {
                        var userEvidence = await requestUserInput(it, instructions);
                        if (!string.IsNullOrWhiteSpace(userEvidence))
                        {
                            if (string.Equals(userEvidence, "PASS", StringComparison.OrdinalIgnoreCase))
                                return new ChecklistResult(it.Id, it.Description, it.Verification, "Pass", BuildManualEvidence(instructions, "PASS"), it.ScriptFile, "AI-Manual");
                                // {
                                //     RawOutput = manualPlan.RawOutput,
                                //     SlmTokensUsed = manualPlan.TotalTokens
                                // };
                            if (string.Equals(userEvidence, "FAIL", StringComparison.OrdinalIgnoreCase))
                                return new ChecklistResult(it.Id, it.Description, it.Verification, "Fail", BuildManualEvidence(instructions, "FAIL"), it.ScriptFile, "AI-Manual");
                                // {
                                //     RawOutput = manualPlan.RawOutput,
                                //     SlmTokensUsed = manualPlan.TotalTokens
                                // };

                            var outcome = EvaluationDecisionService.EvaluateEvidenceOutcome(userEvidence);
                            if (string.Equals(outcome, "Fail", StringComparison.OrdinalIgnoreCase) || string.Equals(outcome, "Pass", StringComparison.OrdinalIgnoreCase))
                                return new ChecklistResult(it.Id, it.Description, it.Verification, outcome, BuildManualEvidence(instructions, userEvidence), it.ScriptFile, "AI-Manual");
                                // {
                                //     RawOutput = manualPlan.RawOutput,
                                //     SlmTokensUsed = manualPlan.TotalTokens
                                // };

                            return new ChecklistResult(it.Id, it.Description, it.Verification, "NeedsReview", BuildManualEvidence(instructions, userEvidence), it.ScriptFile, "AI-Manual");
                            // {
                            //     RawOutput = manualPlan.RawOutput,
                            //     SlmTokensUsed = manualPlan.TotalTokens
                            // };
                        }
                    }
                    catch { }
                }

                return new ChecklistResult(it.Id, it.Description, it.Verification, "NeedsReview", instructions, it.ScriptFile, "AI-Manual");
                // {
                //     RawOutput = manualPlan.RawOutput,
                //     SlmTokensUsed = manualPlan.TotalTokens
                // };
            }

            // One aborted command (a timeout, or a continuation starved while the host was busy)
            // leaves the shared pipeline connection unusable. Every later script would then come
            // back as "SQL ERROR" and be scored Fail without ever being evaluated, so the
            // connection is probed before each item and transparently re-opened when broken.
            async Task<Microsoft.Data.SqlClient.SqlConnection?> EnsureUsableConnectionAsync(Microsoft.Data.SqlClient.SqlConnection? conn)
            {
                if (string.IsNullOrWhiteSpace(_connectionString)) return null;

                if (conn != null && conn.State == ConnectionState.Open)
                {
                    try
                    {
                        using var probe = new SqlCommand("SELECT 1", conn) { CommandTimeout = 15 };
                        await probe.ExecuteScalarAsync(cancellationToken);
                        return conn;
                    }
                    catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { throw; }
                    catch { }
                }

                if (conn != null)
                {
                    try { await conn.DisposeAsync(); } catch { }
                }

                try
                {
                    var fresh = new Microsoft.Data.SqlClient.SqlConnection(_connectionString);
                    await fresh.OpenAsync(cancellationToken);
                    return fresh;
                }
                catch
                {
                    // Falling back to null makes the evaluators open their own short-lived
                    // connection instead of reporting a fabricated failure.
                    return null;
                }
            }

            async Task RunPipelineAsync(System.Collections.Generic.List<ChecklistItem> items, bool isScriptPipeline)
            {
                Microsoft.Data.SqlClient.SqlConnection? pipelineConn = await EnsureUsableConnectionAsync(null);

                try
                {
                    foreach (var it in items)
                    {
                        if (cancellationToken.IsCancellationRequested)
                        {
                            var stopped = new ChecklistResult(it.Id, it.Description, it.Verification, "Stopped", "Cancelled by user", it.ScriptFile, "Stopped");
                            results.Add(stopped);
                            progress?.Report(stopped);
                            break;
                        }

                        pipelineConn = await EnsureUsableConnectionAsync(pipelineConn);

                        var startingScriptFile = string.Empty;
                        if (!IsDocumentationCheck(it) && mapping.TryGetValue(it.Id, out var mappedFiles) && mappedFiles != null && mappedFiles.Length > 0)
                        {
                            startingScriptFile = string.Join(';', mappedFiles);
                        }
                        var canTryMcp = !string.IsNullOrWhiteSpace(_connectionString) && !IsDocumentationCheck(it) && !IsAdminCheck(it);
                        var startingTechnique = isScriptPipeline
                            ? "Script"
                            : (canTryMcp ? "AI-MCP" : "AI-Manual");
                        var startingProgress = new ChecklistResult(it.Id, it.Description, it.Verification, "Evaluating", string.Empty, startingScriptFile, startingTechnique);
                        progress?.Report(startingProgress);

                        try
                        {
                            ChecklistResult? result = isScriptPipeline
                                ? await EvaluateScriptAsync(it, pipelineConn)
                                : await EvaluateAiAsync(it, pipelineConn);

                            if (result != null)
                            {
                                results.Add(result);
                                progress?.Report(result);
                            }
                        }
                        catch (Exception ex)
                        {
                            var err = new ChecklistResult(it.Id, it.Description, it.Verification, isScriptPipeline ? "Fail" : "NeedsReview", "Error: " + ex.Message, it.ScriptFile, isScriptPipeline ? "Script" : "AI-Manual");
                            results.Add(err);
                            progress?.Report(err);
                        }
                    }
                }
                finally
                {
                    if (pipelineConn != null)
                    {
                        try { await pipelineConn.DisposeAsync(); } catch { }
                    }
                }
            }

            await Task.WhenAll(
                RunPipelineAsync(scriptItems, true),
                RunPipelineAsync(aiItems, false));

            // Back-fill report-oriented fields so the persisted JSON is always
            // schema-compatible with the Summary Report generator. Script items were
            // already given their audit wording by the AI enricher inside the pipeline
            // (WPF flow). In the CLI/IDE flows no provider is configured, so they keep the
            // script-supplied Finding and leave Evidence/RiskImpact/Recommendation null for
            // GitHub Copilot to author and write back via ApplyEnrichment.
            var enrichedResults = results.Select(ChecklistResultEnricher.Enrich).ToArray();

            var jsonPath = Path.Combine(resultsDir, "checklist_results.json");
            try
            {
                Directory.CreateDirectory(resultsDir);
                var payload = JsonSerializer.Serialize(enrichedResults, new JsonSerializerOptions { WriteIndented = true });
                lock (ResultsFileLock)
                {
                    File.WriteAllText(jsonPath, payload);
                }
            }
            catch { }

            // Automatically produce the final Markdown summary report and the Excel workbook from
            // the freshly written checklist_results.json, refreshing the historical manual results
            // as part of that step. CLI/IDE pass generateReports: false and ask the user first.
            if (generateReports)
            {
                GenerateReports();
            }

            return enrichedResults;
        }

        /// <summary>
        /// Produces final_report.md and audit_report.xlsx in the active run directory from its
        /// persisted checklist_results.json. Report generation is also the moment
        /// historical_last_run.json is refreshed, so the historical file always mirrors the
        /// manual results of the latest reported audit.
        /// </summary>
        public static string GenerateReports(bool refreshHistoricalManualResults = true)
        {
            var resultsDir = AuditOutputPaths.CurrentRunDirectory;
            var jsonPath = Path.Combine(resultsDir, "checklist_results.json");
            if (!File.Exists(jsonPath))
                return $"No results found at {jsonPath}. Run an evaluation first.";

            var messages = new System.Collections.Generic.List<string>();

            if (refreshHistoricalManualResults)
            {
                try
                {
                    var added = HistoricalManualResultsStore.RefreshFromResults();
                    messages.Add($"{HistoricalManualResultsStore.FileName} refreshed ({added} new manual result(s) recorded).");
                }
                catch (Exception ex)
                {
                    messages.Add($"Historical manual results could not be refreshed: {ex.Message}");
                }
            }

            var total = 0;
            try
            {
                total = (System.Text.Json.Nodes.JsonNode.Parse(File.ReadAllText(jsonPath)) as System.Text.Json.Nodes.JsonArray)?.Count ?? 0;
            }
            catch { }

            var metadata = new SqlAuditor.Reporting.ReportMetadata
            {
                ReportDate = DateTime.UtcNow.ToString("yyyy-MM-dd"),
                Auditors = "SQL Auditor Tool (automated)",
                TotalChecklistItems = total,
            };

            try
            {
                new SqlAuditor.Reporting.SummaryReportGenerator().GenerateFromFile(
                    jsonPath, Path.Combine(resultsDir, "final_report.md"), metadata);
                messages.Add($"{Path.Combine(resultsDir, "final_report.md")} generated.");
            }
            catch (Exception ex)
            {
                messages.Add($"Report generation error: {ex.Message}");
                try { File.AppendAllText(Path.Combine(resultsDir, "ui_log.txt"), $"{DateTime.UtcNow:O} Report generation error: {ex.Message}\r\n"); } catch { }
            }

            // The workbook is scored from the same JSON. Isolated so a workbook failure never
            // breaks the Markdown report or the audit run.
            try
            {
                new SqlAuditor.Reporting.ExcelReportGenerator().GenerateFromFile(
                    jsonPath, Path.Combine(resultsDir, "audit_report.xlsx"), metadata);
                messages.Add($"{Path.Combine(resultsDir, "audit_report.xlsx")} generated.");
            }
            catch (Exception ex)
            {
                messages.Add($"Excel report generation error: {ex.Message}");
                try { File.AppendAllText(Path.Combine(resultsDir, "ui_log.txt"), $"{DateTime.UtcNow:O} Excel report generation error: {ex.Message}\r\n"); } catch { }
            }

            return string.Join(Environment.NewLine, messages);
        }

        // Marks a previously-evaluated checklist item as Pass/Fail/NeedsReview in the
        // persisted results and regenerates the report. Used by the CLI --interactive
        // flow and the IDE 'resolve_review' tool so manual items can be decided by a
        // human without re-running the evaluation. Patches the JSON in place so no
        // enrichment fields are lost.
        public bool ResolveReview(string id, string decision, string? notes, out string newOutcome)
        {
            newOutcome = string.Empty;
            var norm = decision?.Trim().ToLowerInvariant();
            var outcome = norm switch
            {
                "pass" or "p" or "yes" or "y" => "Pass",
                "fail" or "f" or "no" or "n" => "Fail",
                "needsreview" or "review" or "r" => "NeedsReview",
                _ => string.Empty
            };
            if (string.IsNullOrEmpty(outcome) || string.IsNullOrWhiteSpace(id)) return false;

            var resultsDir = AuditOutputPaths.CurrentRunDirectory;
            var jsonPath = Path.Combine(resultsDir, "checklist_results.json");
            if (!File.Exists(jsonPath)) return false;

            if (System.Text.Json.Nodes.JsonNode.Parse(File.ReadAllText(jsonPath)) is not System.Text.Json.Nodes.JsonArray arr)
                return false;

            System.Text.Json.Nodes.JsonObject? target = null;
            foreach (var el in arr)
            {
                if (el is System.Text.Json.Nodes.JsonObject obj &&
                    string.Equals(obj["Id"]?.GetValue<string>(), id, StringComparison.OrdinalIgnoreCase))
                {
                    target = obj;
                    break;
                }
            }
            if (target == null) return false;

            target["Outcome"] = outcome;

            // A human verdict makes the item assessable again, so any earlier Not Applicable
            // marking goes.
            target.Remove("NotApplicable");

            // Score and severity follow the outcome, exactly as the desktop flow derives them
            // through ChecklistResultEnricher; leaving them frozen would score a resolved Pass
            // as the 1 it carried while it was NeedsReview.
            int? previousScore = target["Score"] is System.Text.Json.Nodes.JsonValue scoreValue
                && scoreValue.TryGetValue<int>(out var parsedScore)
                    ? parsedScore
                    : null;

            var newScore = ChecklistResultEnricher.DeriveScore(outcome);
            target["Score"] = newScore;
            target["Severity"] = ChecklistResultEnricher.DeriveSeverity(id, newScore, false);

            // Only wording the enricher itself generated is refreshed, so anything
            // Copilot authored through ApplyEnrichment survives untouched.
            var description = target["Description"]?.GetValue<string>() ?? string.Empty;
            if (Matches(target["Finding"], ChecklistResultEnricher.DefaultFinding(previousScore, description, false)))
                target["Finding"] = ChecklistResultEnricher.DefaultFinding(newScore, description, false);
            if (Matches(target["RiskImpact"], ChecklistResultEnricher.DefaultRiskImpact(previousScore)))
                target["RiskImpact"] = ChecklistResultEnricher.DefaultRiskImpact(newScore);
            if (Matches(target["Recommendation"], ChecklistResultEnricher.DefaultRecommendation(previousScore, description)))
                target["Recommendation"] = ChecklistResultEnricher.DefaultRecommendation(newScore, description);

            if (!string.IsNullOrWhiteSpace(notes))
            {
                var existing = target["Evidence"]?.GetValue<string>() ?? string.Empty;
                target["Evidence"] = string.IsNullOrWhiteSpace(existing)
                    ? $"Manual decision: {outcome}. {notes}"
                    : existing + $"\n\nManual decision: {outcome}. {notes}";
                target["Finding"] = notes;
            }

            try
            {
                File.WriteAllText(jsonPath, arr.ToJsonString(new JsonSerializerOptions { WriteIndented = true }));
            }
            catch { return false; }

            // Regenerate the Markdown report from the updated results.
            try
            {
                var reportPath = Path.Combine(resultsDir, "final_report.md");
                new SqlAuditor.Reporting.SummaryReportGenerator().GenerateFromFile(
                    jsonPath,
                    reportPath,
                    new SqlAuditor.Reporting.ReportMetadata
                    {
                        ReportDate = DateTime.UtcNow.ToString("yyyy-MM-dd"),
                        Auditors = "SQL Auditor Tool (automated)",
                        TotalChecklistItems = arr.Count,
                    });
            }
            catch { }

            // Regenerate the Excel workbook from the updated results using the same
            // scoring pipeline. Isolated so a workbook failure never fails the resolve.
            try
            {
                var excelPath = Path.Combine(resultsDir, "audit_report.xlsx");
                new SqlAuditor.Reporting.ExcelReportGenerator().GenerateFromFile(
                    jsonPath,
                    excelPath,
                    new SqlAuditor.Reporting.ReportMetadata
                    {
                        ReportDate = DateTime.UtcNow.ToString("yyyy-MM-dd"),
                        Auditors = "SQL Auditor Tool (automated)",
                        TotalChecklistItems = arr.Count,
                    });
            }
            catch { }

            newOutcome = outcome;
            return true;
        }

        private static bool Matches(System.Text.Json.Nodes.JsonNode? node, string? expected)
        {
            if (expected is null) return node is null;
            return node is System.Text.Json.Nodes.JsonValue value
                && value.TryGetValue<string>(out var text)
                && string.Equals(text, expected, StringComparison.Ordinal);
        }

        // The CLI/IDE hosts stamp Not Applicable during Copilot's enrichment, after 'evaluate'
        // has already printed its counts, so the final tally has to be read back from the
        // persisted results.
        public static string BuildOutcomeTally()
        {
            var jsonPath = AuditOutputPaths.GetCurrentFilePath("checklist_results.json");
            if (!File.Exists(jsonPath)) return string.Empty;

            try
            {
                if (System.Text.Json.Nodes.JsonNode.Parse(File.ReadAllText(jsonPath)) is not System.Text.Json.Nodes.JsonArray arr)
                    return string.Empty;

                var counts = new System.Collections.Generic.SortedDictionary<string, int>(StringComparer.OrdinalIgnoreCase);
                foreach (var el in arr)
                {
                    var outcome = (el as System.Text.Json.Nodes.JsonObject)?["Outcome"]?.GetValue<string>() ?? "Unknown";
                    if (NotApplicableEvidence.IsNotApplicableOutcome(outcome)) outcome = NotApplicableEvidence.Outcome;
                    counts[outcome] = counts.TryGetValue(outcome, out var c) ? c + 1 : 1;
                }

                return string.Join(", ", counts.Select(kv => $"{kv.Key}: {kv.Value}"));
            }
            catch { return string.Empty; }
        }

        // Records AI-authored wording for an already-evaluated item. Used by the CLI
        // 'enrich_result' command and the IDE 'enrich_result' tool so GitHub Copilot can
        // supply Finding/Evidence/RiskImpact/Recommendation in the flows where this engine
        // makes no LLM calls. Outcome, Score, Severity and Databases Verified come from the
        // SQL script and are never touched here. Patches the JSON in place so nothing is lost.
        public bool ApplyEnrichment(string id, string? finding, string? evidence, string? riskImpact, string? recommendation)
            => ApplyEnrichment(id, finding, evidence, riskImpact, recommendation, out _);

        // <paramref name="markedNotApplicable"/> reports whether this enrichment moved the
        // item to Outcome Not Applicable, so the CLI/IDE host can tell Copilot the verdict changed.
        public bool ApplyEnrichment(string id, string? finding, string? evidence, string? riskImpact, string? recommendation, out bool markedNotApplicable)
        {
            markedNotApplicable = false;
            if (string.IsNullOrWhiteSpace(id)) return false;
            if (string.IsNullOrWhiteSpace(finding) && string.IsNullOrWhiteSpace(evidence)
                && string.IsNullOrWhiteSpace(riskImpact) && string.IsNullOrWhiteSpace(recommendation)) return false;

            var resultsDir = AuditOutputPaths.CurrentRunDirectory;
            var jsonPath = Path.Combine(resultsDir, "checklist_results.json");
            if (!File.Exists(jsonPath)) return false;

            if (System.Text.Json.Nodes.JsonNode.Parse(File.ReadAllText(jsonPath)) is not System.Text.Json.Nodes.JsonArray arr)
                return false;

            System.Text.Json.Nodes.JsonObject? target = null;
            foreach (var el in arr)
            {
                if (el is System.Text.Json.Nodes.JsonObject obj &&
                    string.Equals(obj["Id"]?.GetValue<string>(), id, StringComparison.OrdinalIgnoreCase))
                {
                    target = obj;
                    break;
                }
            }
            if (target == null) return false;

            if (!string.IsNullOrWhiteSpace(finding)) target["Finding"] = finding;
            if (!string.IsNullOrWhiteSpace(evidence)) target["Evidence"] = evidence;
            if (!string.IsNullOrWhiteSpace(riskImpact)) target["RiskImpact"] = riskImpact;
            if (!string.IsNullOrWhiteSpace(recommendation)) target["Recommendation"] = recommendation;

            // Evidence opening with "Not Applicable." means the control does not exist to be
            // assessed, so the item is re-stamped Not Applicable and dropped from the scoring.
            // Only script-evaluated items qualify, exactly as in the desktop flow: a manual item
            // already carries a human verdict that must never be overwritten by wording.
            var isScriptItem = string.Equals(
                target["Technique"]?.GetValue<string>(), "Script", StringComparison.OrdinalIgnoreCase);
            if (isScriptItem && NotApplicableEvidence.IsMarked(evidence))
            {
                target["Outcome"] = NotApplicableEvidence.Outcome;
                target["NotApplicable"] = true;
                // An unassessable control carries no severity weight, as in the desktop flow.
                target["Severity"] = ChecklistResultEnricher.DeriveSeverity(id, null, isNotApplicable: true);
                markedNotApplicable = true;
            }

            try
            {
                File.WriteAllText(jsonPath, arr.ToJsonString(new JsonSerializerOptions { WriteIndented = true }));
            }
            catch { return false; }

            try
            {
                var reportPath = Path.Combine(resultsDir, "final_report.md");
                new SqlAuditor.Reporting.SummaryReportGenerator().GenerateFromFile(
                    jsonPath,
                    reportPath,
                    new SqlAuditor.Reporting.ReportMetadata
                    {
                        ReportDate = DateTime.UtcNow.ToString("yyyy-MM-dd"),
                        Auditors = "SQL Auditor Tool (automated)",
                        TotalChecklistItems = arr.Count,
                    });
            }
            catch { }

            // The workbook is scored from the same JSON, so it has to be refreshed here too;
            // otherwise the enriched wording and any N/A re-stamp never reach audit_report.xlsx
            // in the CLI/IDE flows. Isolated so a workbook failure never fails the enrichment.
            try
            {
                var excelPath = Path.Combine(resultsDir, "audit_report.xlsx");
                new SqlAuditor.Reporting.ExcelReportGenerator().GenerateFromFile(
                    jsonPath,
                    excelPath,
                    new SqlAuditor.Reporting.ReportMetadata
                    {
                        ReportDate = DateTime.UtcNow.ToString("yyyy-MM-dd"),
                        Auditors = "SQL Auditor Tool (automated)",
                        TotalChecklistItems = arr.Count,
                    });
            }
            catch { }

            return true;
        }

        // Builds the block that asks GitHub Copilot to author the audit wording for
        // script-evaluated items, for the CLI (--copilot) and IDE flows where this engine
        // makes no LLM calls. Mirrors the field policy of the WPF flow's script enrichment
        // prompt so the JSON reads the same whichever host produced it. <paramref
        // name="commandFor"/> renders the host-specific write-back call for an item id.
        public static string BuildScriptEnrichmentRequest(
            System.Collections.Generic.IEnumerable<ChecklistResult> results,
            Func<string, string> commandFor)
        {
            var pending = results
                .Where(r => string.Equals(r.Technique, "Script", StringComparison.OrdinalIgnoreCase)
                         && (string.IsNullOrWhiteSpace(r.Evidence)
                             || string.IsNullOrWhiteSpace(r.RiskImpact)
                             || string.IsNullOrWhiteSpace(r.Recommendation)))
                .OrderBy(r => r.Id, StringComparer.OrdinalIgnoreCase)
                .ToList();

            var sb = new System.Text.StringBuilder();
            sb.AppendLine("=== COPILOT ENRICHMENT REQUIRED ===");
            if (pending.Count == 0)
            {
                sb.AppendLine("No script-evaluated items need audit wording.");
                sb.AppendLine("=== END COPILOT ENRICHMENT REQUIRED ===");
                return sb.ToString();
            }

            sb.AppendLine($"{pending.Count} script-evaluated item(s) have a verdict but no audit wording yet.");
            sb.AppendLine("This tool performs NO AI/LLM calls — YOU (GitHub Copilot) write the wording. For EACH item below:");
            sb.AppendLine("  1. Use ONLY the facts under 'Finding' and 'Script result'. Never invent objects, counts, databases or settings.");
            sb.AppendLine("  2. Never change Outcome, Score, Severity or Databases Verified — the script already decided them.");
            sb.AppendLine("  3. Produce these four values:");
            sb.AppendLine("       finding        - 1-2 sentences on the ACTUAL state the script found (object/database names, counts). Do not restate the checklist description.");
            sb.AppendLine("       evidence       - how that finding justifies the outcome, quoting the values returned. Under 120 words. When the script result holds no supporting artefact at all (every value NULL, empty, zero or 'not found'), the control does not exist to be assessed: start evidence with the exact words 'Not Applicable.' followed by one sentence of your own reasoning. A zero that itself proves compliance is real evidence, not 'Not Applicable'.");
            sb.AppendLine("       riskImpact     - the specific business/security/operational consequence of THIS finding. Under 50 words, no generic phrases.");
            sb.AppendLine("       recommendation - remediation targeted at this gap, consistent with the score. Leave empty when Score is 3 and the outcome is Pass.");
            sb.AppendLine("  4. Record them with the command shown under the item, then move to the next. Do not write a final summary until every item is enriched.");

            foreach (var r in pending)
            {
                sb.AppendLine();
                sb.AppendLine($"--- {r.Id}: {r.Description} ---");
                sb.AppendLine($"Outcome: {r.Outcome} | Score: {r.Score?.ToString() ?? "unknown"} | Severity: {(string.IsNullOrWhiteSpace(r.Severity) ? "unset" : r.Severity)} | Databases Verified: {r.DatabasesVerified ?? "not reported"}");
                sb.AppendLine($"Finding returned by the script: {r.ScriptOutcome?.Finding ?? r.Finding}");
                sb.AppendLine("Script result (column=value per row):");
                sb.AppendLine(r.ScriptOutcome?.ToFactSheet() ?? "(no structured result was captured)");
                sb.AppendLine($"Record with: {commandFor(r.Id)}");
            }
            sb.AppendLine("=== END COPILOT ENRICHMENT REQUIRED ===");
            return sb.ToString();
        }

        public async Task<bool> TestConnectionAsync()
        {
            if (string.IsNullOrWhiteSpace(_connectionString)) return false;
            try
            {
                using var conn = new SqlConnection(_connectionString);
                await conn.OpenAsync();
                await conn.CloseAsync();
                return true;
            }
            catch { return false; }
        }

        // Try connection and, if initial attempt fails, try common localhost/transport variants.
        // If a variant succeeds, update _connectionString so subsequent script runs reuse it.
        public async Task<bool> TestAndNormalizeConnectionAsync()
        {
            if (await TestConnectionAsync()) return true;
            try
            {
                // extract server token from connection string
                var m = System.Text.RegularExpressions.Regex.Match(_connectionString, "Server\\s*=\\s*([^;]+)", System.Text.RegularExpressions.RegexOptions.IgnoreCase);
                if (!m.Success) return false;
                var server = m.Groups[1].Value;
                // candidate variants to try
                var variants = new[] { server, ".", "(local)", "localhost", "127.0.0.1", "np:" + server, "tcp:" + server, server + ",1433",
                    // common named instance patterns
                    server + "\\SQLEXPRESS", ".\\SQLEXPRESS", "localhost\\SQLEXPRESS", "127.0.0.1\\SQLEXPRESS" };
                foreach (var v in variants.Distinct())
                {
                    var cs2 = System.Text.RegularExpressions.Regex.Replace(_connectionString, "Server\\s*=\\s*[^;]+", $"Server={v}", System.Text.RegularExpressions.RegexOptions.IgnoreCase);
                    try
                    {
                        using var conn = new SqlConnection(cs2);
                        await conn.OpenAsync();
                        await conn.CloseAsync();
                        // adopt working connection string
                        _connectionString = cs2;
                        try
                        {
                            Directory.CreateDirectory(AuditOutputPaths.CurrentRunDirectory);
                            var log = AuditOutputPaths.GetCurrentFilePath("ui_log.txt");
                            File.AppendAllText(log, $"{DateTime.UtcNow:O} Adopted working connection variant: {v} -> SUCCESS\n");
                        }
                        catch { }
                        return true;
                    }
                    catch (Exception ex)
                    {
                        try
                        {
                            Directory.CreateDirectory(AuditOutputPaths.CurrentRunDirectory);
                            var log = AuditOutputPaths.GetCurrentFilePath("ui_log.txt");
                            File.AppendAllText(log, $"{DateTime.UtcNow:O} Variant: {v} -> FAIL: {ex.Message}\n");
                        }
                        catch { }
                        // try next
                    }
                }
            }
            catch { }
            return false;
        }

        public async Task<ChecklistResult?> TryEvaluateViaMcpAsync(ChecklistItem item)
        {
            if (_mcpEvaluator == null) return null;
            return await _mcpEvaluator.EvaluateAsync(item, _connectionString);
        }

        // Script generation and placeholder-writing functionality removed to prevent runtime modifications

        public async Task<bool> IsAgentAvailableAsync(int timeoutMs = 5000)
        {
            if (_mcpEvaluator == null) return false;
            return await _mcpEvaluator.IsAvailableAsync(timeoutMs);
        }

        public (string Provider, string Model, string Endpoint) GetAgentDetails()
        {
            if (_mcpEvaluator == null) return (string.Empty, string.Empty, string.Empty);
            return (_mcpEvaluator.ProviderName, _mcpEvaluator.ModelName, _mcpEvaluator.Endpoint);
        }

        public async Task<string> GenerateManualInstructionsAsync(ChecklistItem item, System.Threading.CancellationToken cancellationToken = default)
        {
            var result = await GenerateManualInstructionsWithMetadataAsync(item, null, cancellationToken);
            return result.Instructions;
        }

        // Builds the persisted result for a manual item the reviewer has decided, turning
        // their Input/Evidence text into audit wording. The reviewer's outcome is
        // authoritative: the AI only authors Finding/Evidence/RiskImpact/Recommendation/
        // Severity, and ChecklistResultEnricher back-fills whatever it did not supply.
        public async Task<ChecklistResult> BuildManualResultAsync(
            ChecklistItem item,
            string outcome,
            string manualSteps,
            string reviewerInput,
            System.Threading.CancellationToken cancellationToken = default)
        {
            var normalizedOutcome = outcome?.Trim().ToLowerInvariant() switch
            {
                "pass" => "Pass",
                "fail" => "Fail",
                _ => "NeedsReview",
            };
            var score = ChecklistResultEnricher.DeriveScore(normalizedOutcome);

            ManualResultAiEnricher.ManualEnrichment? ai = null;
            if (_manualResultEnricher != null)
            {
                try
                {
                    ai = await _manualResultEnricher.EnrichAsync(
                        item, normalizedOutcome, score, manualSteps ?? string.Empty, reviewerInput ?? string.Empty, cancellationToken);
                }
                catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
                {
                    throw;
                }
                catch
                {
                    ai = null;
                }
            }

            var result = new ChecklistResult(
                item.Id,
                item.Description,
                item.Verification,
                normalizedOutcome,
                BuildManualEvidence(ai?.Evidence, manualSteps, reviewerInput, normalizedOutcome),
                item.ScriptFile,
                "AI-Manual")
            {
                Finding = ai?.Finding ?? string.Empty,
                Severity = ai?.Severity ?? string.Empty,
                RiskImpact = ai?.RiskImpact,
                Recommendation = ai?.Recommendation,
            };

            return ChecklistResultEnricher.Enrich(result);
        }

        // The reviewer's own words are always kept verbatim so the finding stays auditable,
        // whether or not the AI summary was produced.
        private static string BuildManualEvidence(string? aiEvidence, string? manualSteps, string? reviewerInput, string outcome)
        {
            var remarks = string.IsNullOrWhiteSpace(reviewerInput) ? "(none provided)" : reviewerInput.Trim();

            if (!string.IsNullOrWhiteSpace(aiEvidence))
            {
                return $"{aiEvidence.Trim()}\n\nReviewer Input / Evidence (verbatim):\n{remarks}\n\nSelected Outcome:\n{outcome}";
            }

            return $"Manual Steps:\n{manualSteps ?? string.Empty}\n\nOperator Remarks:\n{remarks}\n\nSelected Outcome:\n{outcome}";
        }

        private async Task<ManualStepsGenerationResult> GenerateManualInstructionsWithMetadataAsync(ChecklistItem item, string? auditScript = null, System.Threading.CancellationToken cancellationToken = default)
        {
            try
            {
                if (_manualStepsGenerator != null)
                {
                    var slm = await _manualStepsGenerator.GenerateWithMetadataAsync(item, auditScript, cancellationToken);
                    if (!string.IsNullOrWhiteSpace(slm.Instructions))
                    {
                        return slm;
                    }

                    LogDiagnostic($"Manual steps LLM returned an empty completion for {item.Id}; falling back to the offline template.");
                }
            }
            catch (Exception ex)
            {
                LogDiagnostic($"Manual steps LLM call failed for {item.Id}: {ex.GetType().Name}: {ex.Message}");
            }

            var fallback = await EvaluationDecisionService.BuildManualInstructionsAsync(item);
            if (!string.IsNullOrWhiteSpace(auditScript))
            {
                fallback += "\n\n## Audit script to run in SSMS\n\n```sql\n" + auditScript.Trim() + "\n```";
            }
            return new ManualStepsGenerationResult(fallback, fallback, 0);
        }

        private static void LogDiagnostic(string message)
        {
            try
            {
                var dir = AuditOutputPaths.CurrentRunDirectory;
                Directory.CreateDirectory(dir);
                File.AppendAllText(Path.Combine(dir, "ui_log.txt"), $"{DateTime.UtcNow:O} {message}\r\n");
            }
            catch { }
        }

        // Executes a (possibly multi-batch) SQL script and captures every returned row
        // keyed by its column name, so the audit verdict can be read from the script's
        // final SELECT (Result/Score/DatabaseQueried/Finding) rather than scraped from
        // console text. Only error text is returned as the log; row data is structured.
        private async Task<(string Text, System.Collections.Generic.List<SqlScriptRow> Rows)> ExecuteSqlCaptureAsync(SqlConnection conn, string txt)
        {
            var rows = new System.Collections.Generic.List<SqlScriptRow>();
            var sb = new System.Text.StringBuilder();
            try
            {
                var batches = Regex.Split(txt, @"^GO\s*$", RegexOptions.IgnoreCase | RegexOptions.Multiline);
                foreach (var batch in batches)
                {
                    var script = batch.Trim();
                    if (string.IsNullOrWhiteSpace(script)) continue;
                    try
                    {
                        using var cmd = new SqlCommand(script, conn) { CommandTimeout = 120 };
                        using var rdr = await cmd.ExecuteReaderAsync();
                        do
                        {
                            if (rdr.FieldCount == 0) continue;
                            var names = new System.Collections.Generic.List<string>(rdr.FieldCount);
                            for (int i = 0; i < rdr.FieldCount; i++) names.Add(rdr.GetName(i));
                            while (await rdr.ReadAsync())
                            {
                                var vals = new System.Collections.Generic.List<string>(rdr.FieldCount);
                                for (int i = 0; i < rdr.FieldCount; i++)
                                {
                                    try { vals.Add(rdr.IsDBNull(i) ? "NULL" : rdr.GetValue(i)?.ToString() ?? string.Empty); }
                                    catch { vals.Add("<err>"); }
                                }
                                rows.Add(new SqlScriptRow(names, vals));
                            }
                        } while (await rdr.NextResultAsync());
                    }
                    catch (Exception ex)
                    {
                        sb.AppendLine("SQL ERROR: " + ex.Message);
                    }
                }
            }
            catch (Exception ex)
            {
                sb.AppendLine("SQL EXEC ERROR: " + ex.Message);
            }
            return (sb.ToString(), rows);
        }

        private async Task<string> ExecuteSqlTextAsync(SqlConnection conn, string txt)
        {            try
            {
                var sb = new System.Text.StringBuilder();
                var batches = Regex.Split(txt, @"^GO\s*$", RegexOptions.IgnoreCase | RegexOptions.Multiline);
                int batchNo = 1;
                foreach (var batch in batches)
                {
                    var script = batch.Trim();
                    if (string.IsNullOrWhiteSpace(script)) { batchNo++; continue; }
                    sb.AppendLine($"--- Batch {batchNo} ---");
                    try
                    {
                        using var cmd = new SqlCommand(script, conn) { CommandTimeout = 120 };
                        using var rdr = await cmd.ExecuteReaderAsync();
                        int rowCount = 0;
                        while (await rdr.ReadAsync())
                        {
                            rowCount++;
                            var cols = new System.Collections.Generic.List<string>();
                            for (int i = 0; i < rdr.FieldCount; i++)
                            {
                                try { cols.Add(rdr.IsDBNull(i) ? "NULL" : rdr.GetValue(i)?.ToString() ?? string.Empty); }
                                catch { cols.Add("<err>"); }
                            }
                            sb.AppendLine(string.Join('\t', cols));
                        }
                        sb.AppendLine($"(rows: {rowCount})");
                        while (await rdr.NextResultAsync()) { }
                    }
                    catch (Exception ex)
                    {
                        sb.AppendLine("SQL ERROR: " + ex.Message);
                    }
                    batchNo++;
                }
                return sb.ToString();
            }
            catch (Exception ex)
            {
                return "SQL EXEC ERROR: " + ex.Message + "\n\nScript contents:\n" + txt;
            }
        }
    }
}

