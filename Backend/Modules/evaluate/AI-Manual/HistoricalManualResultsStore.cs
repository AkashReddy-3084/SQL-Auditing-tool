using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace SQLAuditor.Lib;

/// <summary>
/// Keeps the manual / AI-Manual results of previous audit runs in
/// <c>historical_last_run.json</c> within each run directory so a later run can reuse a decision the reviewer
/// already made instead of asking them to verify the same control again.
///
/// The file holds exactly the attributes <c>checklist_results.json</c> carries for those items,
/// keyed by checklist ID. It is refreshed only when a report is generated, never after every
/// evaluation, so it always reflects the last completed audit.
/// </summary>
public static class HistoricalManualResultsStore
{
    public const string FileName = "historical_last_run.json";

    private static string ResultsDirectory => AuditOutputPaths.CurrentRunDirectory;

    public static string FilePath => Path.Combine(ResultsDirectory, FileName);

    private static string ChecklistResultsPath => Path.Combine(ResultsDirectory, "checklist_results.json");

    /// <summary>Reuse applies only to manual/AI-Manual items; Script and AI-MCP keep their pipelines.</summary>
    public static bool IsManualTechnique(string? technique) =>
        !string.IsNullOrWhiteSpace(technique)
        && technique.Contains("Manual", StringComparison.OrdinalIgnoreCase);

    /// <summary>
    /// Only a decided item is worth carrying forward. "Evaluating" placeholders and items still
    /// sitting in the review queue must be evaluated normally next time.
    /// </summary>
    public static bool IsCompletedOutcome(string? outcome)
    {
        if (string.IsNullOrWhiteSpace(outcome)) return false;
        var v = outcome.Trim();
        return v.Equals("Pass", StringComparison.OrdinalIgnoreCase)
            || v.Equals("Fail", StringComparison.OrdinalIgnoreCase)
            || NotApplicableEvidence.IsNotApplicableOutcome(v);
    }

    /// <summary>
    /// Reads the historical file. Accepts both the keyed-object form this class writes and a plain
    /// array of result objects, so a hand-copied <c>checklist_results.json</c> also loads.
    /// Returns an empty map when the file is missing or unreadable.
    /// </summary>
    public static Dictionary<string, JsonObject> Load()
    {
        var map = new Dictionary<string, JsonObject>(StringComparer.OrdinalIgnoreCase);
        var path = AuditOutputPaths.FindLatestFile(FileName);
        if (path is null) return map;

        try
        {
            var root = JsonNode.Parse(File.ReadAllText(path));
            if (root is JsonObject obj)
            {
                foreach (var prop in obj)
                {
                    if (prop.Value is not JsonObject entry) continue;
                    var id = ReadString(entry, "Id") ?? prop.Key;
                    if (!string.IsNullOrWhiteSpace(id)) map[id] = entry;
                }
            }
            else if (root is JsonArray arr)
            {
                foreach (var node in arr)
                {
                    if (node is not JsonObject entry) continue;
                    var id = ReadString(entry, "Id");
                    if (!string.IsNullOrWhiteSpace(id)) map[id!] = entry;
                }
            }
        }
        catch { return new Dictionary<string, JsonObject>(StringComparer.OrdinalIgnoreCase); }

        return map;
    }

    /// <summary>Checklist IDs that currently have a reusable manual result.</summary>
    public static HashSet<string> AvailableIds()
    {
        var ids = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var kv in Load())
        {
            if (IsManualTechnique(ReadString(kv.Value, "Technique"))
                && IsCompletedOutcome(ReadString(kv.Value, "Outcome")))
            {
                ids.Add(kv.Key);
            }
        }
        return ids;
    }

    /// <summary>True when at least one previous manual result can be reused.</summary>
    public static bool HasAny() => AvailableIds().Count > 0;

    /// <summary>
    /// Rebuilds a <see cref="ChecklistResult"/> from a historical entry, preserving every
    /// persisted attribute. Returns <c>false</c> when the entry is not a reusable manual result.
    /// </summary>
    public static bool TryBuildResult(JsonObject entry, ChecklistItem item, out ChecklistResult result)
    {
        result = null!;
        var outcome = ReadString(entry, "Outcome");
        var technique = ReadString(entry, "Technique");
        if (!IsManualTechnique(technique) || !IsCompletedOutcome(outcome)) return false;

        result = new ChecklistResult(
            item.Id,
            ReadString(entry, "Description") ?? item.Description,
            item.Verification,
            outcome!,
            ReadString(entry, "Evidence"),
            item.ScriptFile,
            technique!)
        {
            Score = ReadInt(entry, "Score"),
            Severity = ReadString(entry, "Severity") ?? string.Empty,
            Finding = ReadString(entry, "Finding") ?? string.Empty,
            Recommendation = ReadString(entry, "Recommendation"),
            RiskImpact = ReadString(entry, "RiskImpact"),
            DatabasesVerified = ReadString(entry, "Databases Verified"),
            NotApplicable = ReadBool(entry, "NotApplicable"),
            NotApplicableJustification = ReadString(entry, "NotApplicableJustification"),
            RawAttribute = ReadElement(entry, "rawAttribute"),
        };
        return true;
    }

    /// <summary>
    /// Merges the manual/AI-Manual results of the current <c>checklist_results.json</c> into the
    /// historical file. Existing entries are preserved; only IDs that are not yet recorded are
    /// added. Returns the number of newly recorded items.
    /// </summary>
    public static int RefreshFromResults()
    {
        var resultsPath = ChecklistResultsPath;
        if (!File.Exists(resultsPath)) return 0;

        JsonArray? results;
        try
        {
            string text;
            lock (Auditor.ResultsFileLock)
            {
                text = File.ReadAllText(resultsPath);
            }
            results = JsonNode.Parse(text) as JsonArray;
        }
        catch { return 0; }
        if (results == null) return 0;

        var historical = Load();
        var added = 0;
        foreach (var node in results)
        {
            if (node is not JsonObject entry) continue;
            var id = ReadString(entry, "Id");
            if (string.IsNullOrWhiteSpace(id)) continue;
            if (!IsManualTechnique(ReadString(entry, "Technique"))) continue;
            if (!IsCompletedOutcome(ReadString(entry, "Outcome"))) continue;
            if (historical.ContainsKey(id!)) continue;

            historical[id!] = (JsonObject)entry.DeepClone();
            added++;
        }

        if (added == 0 && File.Exists(FilePath)) return 0;

        Save(historical);
        return added;
    }

    private static void Save(Dictionary<string, JsonObject> historical)
    {
        try
        {
            Directory.CreateDirectory(ResultsDirectory);
            var output = new JsonObject();
            foreach (var kv in historical.OrderBy(k => k.Key, StringComparer.OrdinalIgnoreCase))
                output[kv.Key] = kv.Value.DeepClone();

            File.WriteAllText(FilePath, output.ToJsonString(new JsonSerializerOptions { WriteIndented = true }));
        }
        catch { }
    }

    private static string? ReadString(JsonObject entry, string name) =>
        entry[name] is JsonValue v && v.TryGetValue<string>(out var s) ? s : null;

    private static int? ReadInt(JsonObject entry, string name) =>
        entry[name] is JsonValue v && v.TryGetValue<int>(out var n) ? n : null;

    private static bool? ReadBool(JsonObject entry, string name) =>
        entry[name] is JsonValue v && v.TryGetValue<bool>(out var b) ? b : null;

    private static JsonElement? ReadElement(JsonObject entry, string name)
    {
        if (entry[name] is not JsonNode node) return null;
        try { return JsonSerializer.Deserialize<JsonElement>(node.ToJsonString()); }
        catch { return null; }
    }
}
