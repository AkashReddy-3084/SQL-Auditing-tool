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
        public ChecklistResult(string id, string description, string verification, string outcome, string evidence, string scriptFile, string technique = "")
        {
            Id = id;
            Description = description;
            Verification = verification;
            Outcome = outcome;
            Evidence = evidence;
            ScriptFile = scriptFile;
            Technique = technique;
        }

        public string Id { get; init; }

        public string Description { get; init; }

        [JsonIgnore]
        public string Verification { get; init; }

        public string Outcome { get; init; }

        [JsonIgnore]
        public string Evidence { get; init; }

        [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
        [JsonPropertyName("rawAttribute")]
        public JsonElement? RawAttribute { get; init; }

        [JsonPropertyName("RawOutput")]
        public string RawOutput { get; init; } = string.Empty;

        [JsonPropertyName("mcp_tokens_used")]
        public int McpTokensUsed { get; init; }

        [JsonPropertyName("slm_tokens_used")]
        public int SlmTokensUsed { get; init; }

        public string ScriptFile { get; init; }

        public string Technique { get; init; }

        [JsonIgnore]
        public string? McpUsage { get; init; }

        [JsonIgnore]
        public long? McpExecutionTimeMs { get; init; }

        [JsonIgnore]
        public string? McpEvidence { get; init; }
    }

    public class Auditor
    {
        private string _connectionString;
        private readonly SqlServerMcpEvaluator _mcpEvaluator;
        private readonly ManualStepsGenerator _manualStepsGenerator;

        public Auditor(string connectionString)
        {
            _connectionString = connectionString;
            _mcpEvaluator = SqlServerMcpEvaluator.CreateFromEnvironment();
            _manualStepsGenerator = ManualStepsGenerator.CreateFromEnvironment();
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
            Directory.CreateDirectory(Path.Combine(Directory.GetCurrentDirectory(), "results"));
            var list = new System.Collections.Generic.List<ScriptResult>();
            foreach (var f in Directory.GetFiles(scriptsDir, "*.sql"))
            {
                var txt = await RunScriptFileAsync(f);
                var json = SummarizeTextResultToJson(Path.GetFileName(f), txt);
                var outPath = Path.Combine("results", Path.GetFileNameWithoutExtension(f) + "_result.txt");
                await File.WriteAllTextAsync(outPath, txt);
                var jsonPath = Path.Combine("results", Path.GetFileNameWithoutExtension(f) + ".json");
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
            var fileName = string.IsNullOrWhiteSpace(suggestedFileName) ? ($"{safeId}_generated_{DateTime.UtcNow:yyyyMMddHHmmss}.sql") : suggestedFileName;
            var fullPath = Path.Combine(scriptsDir, fileName);
            await File.WriteAllTextAsync(fullPath, scriptText ?? string.Empty);

            // Update deterministic mapping
            try
            {
                var mapPath = Path.Combine(repoRoot, "Backend", "checklist", "deterministic-script-mapping.json");
                System.Collections.Generic.Dictionary<string, string[]> mapping = new();
                if (File.Exists(mapPath))
                {
                    try { mapping = JsonSerializer.Deserialize<System.Collections.Generic.Dictionary<string, string[]>>(File.ReadAllText(mapPath)) ?? new(); } catch { mapping = new(); }
                }

                var rel = Path.Combine("Backend", "checklist", "scripts", "sql", fileName).Replace(Path.DirectorySeparatorChar, '/');
                // Replace existing entry or append if missing
                mapping[checklistId] = new[] { rel };
                await File.WriteAllTextAsync(mapPath, JsonSerializer.Serialize(mapping, new JsonSerializerOptions { WriteIndented = true }));
            }
            catch { /* best-effort only */ }

            return fullPath;
        }

        public async Task<ChecklistResult[]> RunChecklistAsync(IProgress<ChecklistResult>? progress = null, Func<ChecklistItem, string, Task<string?>>? requestUserInput = null, System.Collections.Generic.IEnumerable<string>? selectedIds = null, System.Threading.CancellationToken cancellationToken = default)
        {
            var structure = await GetChecklistStructureAsync();
            var repoRoot = FindRepoRoot() ?? Directory.GetCurrentDirectory();

            // normalize connection (try alternate server variants) so script execution reuses a working connection string when possible
            try { await TestAndNormalizeConnectionAsync(); } catch { }

            // load deterministic mapping if present
            var mapping = new System.Collections.Generic.Dictionary<string, string[]>();
            try
            {
                var mapPath = Path.Combine(repoRoot, "Backend", "checklist", "deterministic-script-mapping.json");
                if (File.Exists(mapPath)) mapping = JsonSerializer.Deserialize<System.Collections.Generic.Dictionary<string, string[]>>(File.ReadAllText(mapPath)) ?? new();
                // Normalize any legacy SQL/scripts/checks references to Backend/checklist/tools/sql
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

            bool IsScriptMapped(ChecklistItem item)
            {
                return mapping.TryGetValue(item.Id, out var files) && files != null && files.Length > 0;
            }

            var scriptItems = selectedItems.Where(IsScriptMapped).ToList();
            var aiItems = selectedItems.Where(it => !IsScriptMapped(it)).ToList();

            async Task<ChecklistResult?> EvaluateScriptAsync(ChecklistItem it, Microsoft.Data.SqlClient.SqlConnection? pipelineConn)
            {
                var evidenceSb = new System.Text.StringBuilder();
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
                            string outt;
                            if (pipelineConn != null)
                            {
                                outt = await ExecuteSqlTextAsync(pipelineConn, txt);
                            }
                            else
                            {
                                outt = await RunScriptFileAsync(full);
                            }
                            evidenceSb.AppendLine($"--- Script: {f} ---");
                            evidenceSb.AppendLine(outt);
                        }
                        else
                        {
                            var checks = Path.Combine(repoRoot, "SQL", "scripts", "checks");
                            var match = Directory.Exists(checks) ? Directory.GetFiles(checks, it.Id + "_*", SearchOption.TopDirectoryOnly).FirstOrDefault() : null;
                            if (match != null)
                            {
                                var outt = await RunScriptFileAsync(match);
                                evidenceSb.AppendLine($"--- Script: {Path.GetRelativePath(repoRoot, match)} ---");
                                evidenceSb.AppendLine(outt);
                            }
                        }
                    }
                    catch (Exception ex)
                    {
                        evidenceSb.AppendLine("Script error: " + ex.Message);
                    }
                }

                var evidence = evidenceSb.ToString();
                var outcome = EvaluationDecisionService.EvaluateEvidenceOutcome(evidence);
                return new ChecklistResult(it.Id, it.Description, it.Verification, outcome, evidence, string.Join(';', files), "Script");
            }

            async Task<ChecklistResult?> EvaluateAiAsync(ChecklistItem it, Microsoft.Data.SqlClient.SqlConnection? pipelineConn)
            {
                if (!string.IsNullOrWhiteSpace(_connectionString))
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

                // Only reached once MCP has declined or failed, so the guidance is never wasted work.
                var manualPlan = await GenerateManualInstructionsWithMetadataAsync(it, cancellationToken);

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
                                return new ChecklistResult(it.Id, it.Description, it.Verification, "Pass", BuildManualEvidence(instructions, "PASS"), it.ScriptFile, "AI-Manual")
                                {
                                    RawOutput = manualPlan.RawOutput,
                                    SlmTokensUsed = manualPlan.TotalTokens
                                };
                            if (string.Equals(userEvidence, "FAIL", StringComparison.OrdinalIgnoreCase))
                                return new ChecklistResult(it.Id, it.Description, it.Verification, "Fail", BuildManualEvidence(instructions, "FAIL"), it.ScriptFile, "AI-Manual")
                                {
                                    RawOutput = manualPlan.RawOutput,
                                    SlmTokensUsed = manualPlan.TotalTokens
                                };

                            var outcome = EvaluationDecisionService.EvaluateEvidenceOutcome(userEvidence);
                            if (string.Equals(outcome, "Fail", StringComparison.OrdinalIgnoreCase) || string.Equals(outcome, "Pass", StringComparison.OrdinalIgnoreCase))
                                return new ChecklistResult(it.Id, it.Description, it.Verification, outcome, BuildManualEvidence(instructions, userEvidence), it.ScriptFile, "AI-Manual")
                                {
                                    RawOutput = manualPlan.RawOutput,
                                    SlmTokensUsed = manualPlan.TotalTokens
                                };

                            return new ChecklistResult(it.Id, it.Description, it.Verification, "NeedsReview", BuildManualEvidence(instructions, userEvidence), it.ScriptFile, "AI-Manual")
                            {
                                RawOutput = manualPlan.RawOutput,
                                SlmTokensUsed = manualPlan.TotalTokens
                            };
                        }
                    }
                    catch { }
                }

                return new ChecklistResult(it.Id, it.Description, it.Verification, "NeedsReview", instructions, it.ScriptFile, "AI-Manual")
                {
                    RawOutput = manualPlan.RawOutput,
                    SlmTokensUsed = manualPlan.TotalTokens
                };
            }

            async Task RunPipelineAsync(System.Collections.Generic.List<ChecklistItem> items, bool isScriptPipeline)
            {
                Microsoft.Data.SqlClient.SqlConnection? pipelineConn = null;
                if (!string.IsNullOrWhiteSpace(_connectionString))
                {
                    try
                    {
                        pipelineConn = new Microsoft.Data.SqlClient.SqlConnection(_connectionString);
                        await pipelineConn.OpenAsync(cancellationToken);
                    }
                    catch
                    {
                        pipelineConn = null;
                    }
                }

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

                        var startingScriptFile = string.Empty;
                        if (mapping.TryGetValue(it.Id, out var mappedFiles) && mappedFiles != null && mappedFiles.Length > 0)
                        {
                            startingScriptFile = string.Join(';', mappedFiles);
                        }
                        var canTryMcp = !string.IsNullOrWhiteSpace(_connectionString);
                        var startingTechnique = string.IsNullOrWhiteSpace(startingScriptFile)
                            ? (canTryMcp ? "AI-MCP" : "AI-Manual")
                            : "Script";
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
                            var err = new ChecklistResult(it.Id, it.Description, it.Verification, "NeedsReview", "Error: " + ex.Message, it.ScriptFile, isScriptPipeline ? "Script" : "AI-Manual");
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

            try
            {
                Directory.CreateDirectory(Path.Combine(Directory.GetCurrentDirectory(), "results"));
                await File.WriteAllTextAsync(Path.Combine("results", "checklist_results.json"), JsonSerializer.Serialize(results, new JsonSerializerOptions { WriteIndented = true }));
            }
            catch { }

            return results.ToArray();
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
                            Directory.CreateDirectory(Path.Combine(Directory.GetCurrentDirectory(), "results"));
                            var log = Path.Combine(Directory.GetCurrentDirectory(), "results", "ui_log.txt");
                            File.AppendAllText(log, $"{DateTime.UtcNow:O} Adopted working connection variant: {v} -> SUCCESS\n");
                        }
                        catch { }
                        return true;
                    }
                    catch (Exception ex)
                    {
                        try
                        {
                            Directory.CreateDirectory(Path.Combine(Directory.GetCurrentDirectory(), "results"));
                            var log = Path.Combine(Directory.GetCurrentDirectory(), "results", "ui_log.txt");
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
            return await _mcpEvaluator.EvaluateAsync(item, _connectionString);
        }

        // Script generation and placeholder-writing functionality removed to prevent runtime modifications

        public async Task<bool> IsAgentAvailableAsync(int timeoutMs = 5000)
        {
            return await _mcpEvaluator.IsAvailableAsync(timeoutMs);
        }

        public (string Provider, string Model, string Endpoint) GetAgentDetails()
        {
            return (_mcpEvaluator.ProviderName, _mcpEvaluator.ModelName, _mcpEvaluator.Endpoint);
        }

        public async Task<string> GenerateManualInstructionsAsync(ChecklistItem item, System.Threading.CancellationToken cancellationToken = default)
        {
            var result = await GenerateManualInstructionsWithMetadataAsync(item, cancellationToken);
            return result.Instructions;
        }

        private async Task<ManualStepsGenerationResult> GenerateManualInstructionsWithMetadataAsync(ChecklistItem item, System.Threading.CancellationToken cancellationToken = default)
        {
            try
            {
                var slm = await _manualStepsGenerator.GenerateWithMetadataAsync(item, cancellationToken);
                if (!string.IsNullOrWhiteSpace(slm.Instructions))
                {
                    return slm;
                }

                LogDiagnostic($"Manual steps LLM returned an empty completion for {item.Id}; falling back to the offline template.");
            }
            catch (Exception ex)
            {
                LogDiagnostic($"Manual steps LLM call failed for {item.Id}: {ex.GetType().Name}: {ex.Message}");
            }

            var fallback = await EvaluationDecisionService.BuildManualInstructionsAsync(item);
            return new ManualStepsGenerationResult(fallback, fallback, 0);
        }

        private static void LogDiagnostic(string message)
        {
            try
            {
                var dir = Path.Combine(Directory.GetCurrentDirectory(), "results");
                Directory.CreateDirectory(dir);
                File.AppendAllText(Path.Combine(dir, "ui_log.txt"), $"{DateTime.UtcNow:O} {message}\r\n");
            }
            catch { }
        }

        private async Task<string> ExecuteSqlTextAsync(SqlConnection conn, string txt)
        {
            try
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

