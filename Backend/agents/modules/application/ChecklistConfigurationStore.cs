using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Threading;

namespace SQLAuditor.Lib;

/// <summary>
/// Owns the split between the DEFAULT checklist/mapping (shipped with the tool) and the CUSTOM
/// checklist/mapping (added through the Configure Checklist flow), and keeps the merged runtime
/// files the rest of the application already reads in sync:
///
///   master-checklist.json              = default-checklist.json + custom-checklist.json
///   deterministic-script-mapping.json  = default-deterministic-script-mapping.json
///                                        + custom-deterministic-script-mapping.json
///
/// The default files are created once from the existing runtime files, so nothing has to be
/// migrated by hand and the default data is never edited when custom checks are added.
/// All read-modify-write sequences are guarded by a named mutex so WPF, CLI and the MCP server
/// cannot allocate the same custom checklist ID or clobber each other's writes.
/// </summary>
public static class ChecklistConfigurationStore
{
    public const string DefaultChecklistFileName = "default-checklist.json";
    public const string CustomChecklistFileName = "custom-checklist.json";
    public const string MergedChecklistFileName = "master-checklist.json";
    public const string DefaultMappingFileName = "default-deterministic-script-mapping.json";
    public const string CustomMappingFileName = "custom-deterministic-script-mapping.json";
    public const string MergedMappingFileName = "deterministic-script-mapping.json";
    public const string PendingFileName = "custom-checklist-pending.json";

    private const string MutexName = "SQLAuditor.ChecklistConfigurationStore";

    private static readonly JsonSerializerOptions WriteOptions = new()
    {
        WriteIndented = true,
        // Keeps the merged files byte-comparable with the hand-maintained defaults, which use
        // literal '&' and typographic dashes rather than \u escapes.
        Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping
    };

    private static string? _checklistDirectory;

    /// <summary>The <c>Backend/checklist</c> folder that holds every checklist artefact.</summary>
    public static string ChecklistDirectory
    {
        get
        {
            if (_checklistDirectory != null) return _checklistDirectory;

            foreach (var start in new[] { Directory.GetCurrentDirectory(), AppContext.BaseDirectory })
            {
                var dir = new DirectoryInfo(start);
                while (dir != null)
                {
                    var candidate = Path.Combine(dir.FullName, "Backend", "checklist");
                    if (Directory.Exists(candidate)
                        && (File.Exists(Path.Combine(candidate, MergedChecklistFileName))
                            || File.Exists(Path.Combine(candidate, "master_checklist.json"))
                            || File.Exists(Path.Combine(candidate, DefaultChecklistFileName))))
                    {
                        _checklistDirectory = candidate;
                        return _checklistDirectory;
                    }
                    dir = dir.Parent;
                }
            }

            throw new DirectoryNotFoundException(
                "Cannot locate Backend/checklist. Run from the SQL-Auditing-tool folder.");
        }
    }

    public static string DefaultChecklistPath => Path.Combine(ChecklistDirectory, DefaultChecklistFileName);
    public static string CustomChecklistPath => Path.Combine(ChecklistDirectory, CustomChecklistFileName);
    public static string MergedChecklistPath => Path.Combine(ChecklistDirectory, MergedChecklistFileName);
    public static string DefaultMappingPath => Path.Combine(ChecklistDirectory, DefaultMappingFileName);
    public static string CustomMappingPath => Path.Combine(ChecklistDirectory, CustomMappingFileName);
    public static string MergedMappingPath => Path.Combine(ChecklistDirectory, MergedMappingFileName);
    public static string PendingPath => Path.Combine(ChecklistDirectory, PendingFileName);

    // ------------------------------------------------------------------
    // Initialisation / merging
    // ------------------------------------------------------------------

    /// <summary>
    /// Splits the existing runtime files into their default counterparts the first time this
    /// runs, creates the (empty) custom files, and regenerates the merged runtime files.
    /// Safe to call repeatedly and from any host.
    /// </summary>
    public static void EnsureInitialized() => WithLock(() =>
    {
        EnsureInitializedCore();
        RebuildMergedCore();
        return true;
    });

    private static void EnsureInitializedCore()
    {
        // The shipped runtime files become the default sources exactly once.
        if (!File.Exists(DefaultChecklistPath))
        {
            var seed = File.Exists(MergedChecklistPath)
                ? MergedChecklistPath
                : Path.Combine(ChecklistDirectory, "master_checklist.json");
            if (File.Exists(seed)) File.Copy(seed, DefaultChecklistPath);
        }

        if (!File.Exists(DefaultMappingPath) && File.Exists(MergedMappingPath))
            File.Copy(MergedMappingPath, DefaultMappingPath);

        if (!File.Exists(CustomChecklistPath))
        {
            var empty = new JsonObject
            {
                ["generated"] = DateTime.UtcNow.ToString("o", CultureInfo.InvariantCulture),
                ["source"] = "Configure Checklist (custom items only)",
                ["areas"] = new JsonArray()
            };
            WriteJson(CustomChecklistPath, empty);
        }

        if (!File.Exists(CustomMappingPath))
            File.WriteAllText(CustomMappingPath, "{}");
    }

    /// <summary>Regenerates master-checklist.json and deterministic-script-mapping.json.</summary>
    public static void RebuildMerged() => WithLock(() =>
    {
        EnsureInitializedCore();
        RebuildMergedCore();
        return true;
    });

    private static void RebuildMergedCore()
    {
        RebuildMergedChecklistCore();
        RebuildMergedMappingCore();
    }

    private static void RebuildMergedChecklistCore()
    {
        var defaults = ReadJsonObject(DefaultChecklistPath);
        if (defaults == null) return;

        var custom = ReadJsonObject(CustomChecklistPath);
        var merged = defaults.DeepClone().AsObject();

        if (custom?["areas"] is JsonArray customAreas && merged["areas"] is JsonArray mergedAreas)
        {
            foreach (var areaNode in customAreas.OfType<JsonObject>())
            {
                var areaId = areaNode["id"]?.GetValue<string>();
                if (string.IsNullOrWhiteSpace(areaId)) continue;

                var targetArea = mergedAreas.OfType<JsonObject>()
                    .FirstOrDefault(a => string.Equals(a["id"]?.GetValue<string>(), areaId, StringComparison.OrdinalIgnoreCase));

                // New areas are not supported: a custom item can only extend an existing area.
                if (targetArea?["sub_areas"] is not JsonArray targetSubAreas) continue;
                if (areaNode["sub_areas"] is not JsonArray customSubAreas) continue;

                foreach (var subNode in customSubAreas.OfType<JsonObject>())
                {
                    var subId = subNode["id"]?.GetValue<string>();
                    if (string.IsNullOrWhiteSpace(subId)) continue;

                    var targetSub = targetSubAreas.OfType<JsonObject>()
                        .FirstOrDefault(s => string.Equals(s["id"]?.GetValue<string>(), subId, StringComparison.OrdinalIgnoreCase));
                    if (targetSub == null) continue;

                    if (targetSub["items"] is not JsonArray targetItems)
                    {
                        targetItems = new JsonArray();
                        targetSub["items"] = targetItems;
                    }

                    if (subNode["items"] is not JsonArray customItems) continue;

                    foreach (var item in customItems.OfType<JsonObject>())
                    {
                        var id = item["id"]?.GetValue<string>();
                        if (string.IsNullOrWhiteSpace(id)) continue;
                        if (targetItems.OfType<JsonObject>().Any(x =>
                                string.Equals(x["id"]?.GetValue<string>(), id, StringComparison.OrdinalIgnoreCase)))
                            continue;

                        targetItems.Add(item.DeepClone());
                    }

                    SortItemsById(targetSub);
                }
            }
        }

        merged["generated"] = DateTime.UtcNow.ToString("o", CultureInfo.InvariantCulture);
        merged["merged_from"] = new JsonArray(DefaultChecklistFileName, CustomChecklistFileName);
        WriteJson(MergedChecklistPath, merged);
    }

    private static void SortItemsById(JsonObject subArea)
    {
        if (subArea["items"] is not JsonArray items) return;

        var ordered = items.OfType<JsonObject>()
            .Select(o => o.DeepClone().AsObject())
            .OrderBy(o => o["id"]?.GetValue<string>() ?? "", Comparer<string>.Create(CompareIds))
            .ToList();

        var replacement = new JsonArray();
        foreach (var o in ordered) replacement.Add(o);
        subArea["items"] = replacement;
    }

    private static void RebuildMergedMappingCore()
    {
        var merged = new JsonObject();

        foreach (var source in new[] { DefaultMappingPath, CustomMappingPath })
        {
            var doc = ReadJsonObject(source);
            if (doc == null) continue;
            foreach (var kv in doc)
            {
                if (kv.Value == null) continue;
                merged[kv.Key] = kv.Value.DeepClone();
            }
        }

        WriteJson(MergedMappingPath, merged);
    }

    // ------------------------------------------------------------------
    // Catalog / lookups
    // ------------------------------------------------------------------

    /// <summary>Every Area/Sub-area the classifier may choose from (defaults only — new areas are not supported).</summary>
    public static List<ChecklistSubAreaInfo> GetSubAreas() => WithLock(() =>
    {
        EnsureInitializedCore();
        var counts = ReadCatalogCore()
            .GroupBy(i => i.SubAreaId, StringComparer.OrdinalIgnoreCase)
            .ToDictionary(g => g.Key, g => g.Count(), StringComparer.OrdinalIgnoreCase);

        var result = GetSubAreasCore();
        foreach (var sub in result)
            sub.ItemCount = counts.TryGetValue(sub.SubAreaId, out var c) ? c : 0;

        return result;
    });

    /// <summary>Every default and custom checklist item, used for duplicate detection.</summary>
    public static List<ChecklistCatalogItem> GetCatalog() => WithLock(() =>
    {
        EnsureInitializedCore();
        return ReadCatalogCore();
    });

    private static List<ChecklistCatalogItem> ReadCatalogCore()
    {
        var result = new List<ChecklistCatalogItem>();
        AppendCatalog(result, ReadJsonObject(DefaultChecklistPath), isCustom: false);
        AppendCatalog(result, ReadJsonObject(CustomChecklistPath), isCustom: true);
        return result;
    }

    private static void AppendCatalog(List<ChecklistCatalogItem> sink, JsonObject? doc, bool isCustom)
    {
        if (doc?["areas"] is not JsonArray areas) return;

        foreach (var area in areas.OfType<JsonObject>())
        {
            var areaId = area["id"]?.GetValue<string>() ?? "";
            var areaTitle = area["title"]?.GetValue<string>() ?? "";
            if (area["sub_areas"] is not JsonArray subs) continue;

            foreach (var sub in subs.OfType<JsonObject>())
            {
                var subId = sub["id"]?.GetValue<string>() ?? "";
                var subTitle = sub["title"]?.GetValue<string>() ?? "";
                if (sub["items"] is not JsonArray items) continue;

                foreach (var item in items.OfType<JsonObject>())
                {
                    var id = item["id"]?.GetValue<string>();
                    if (string.IsNullOrWhiteSpace(id)) continue;

                    var text = item["text"]?.GetValue<string>() ?? item["description"]?.GetValue<string>() ?? "";
                    sink.Add(new ChecklistCatalogItem
                    {
                        Id = id,
                        Text = text,
                        Title = item["custom_title"]?.GetValue<string>() ?? text,
                        AreaId = areaId,
                        AreaTitle = areaTitle,
                        SubAreaId = subId,
                        SubAreaTitle = subTitle,
                        IsCustom = isCustom
                    });
                }
            }
        }
    }

    public static bool IsCustomId(string checklistId) => WithLock(() =>
    {
        EnsureInitializedCore();
        return ReadCustomIdsCore().Contains(checklistId);
    });

    private static HashSet<string> ReadCustomIdsCore()
    {
        var ids = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var custom = new List<ChecklistCatalogItem>();
        AppendCatalog(custom, ReadJsonObject(CustomChecklistPath), isCustom: true);
        foreach (var item in custom) ids.Add(item.Id);
        return ids;
    }

    // ------------------------------------------------------------------
    // Pending (reserved but not yet approved) custom items
    // ------------------------------------------------------------------

    /// <summary>
    /// Allocates the next free ID inside an EXISTING sub-area and reserves it as a pending draft,
    /// so two concurrent additions can never receive the same ID. Nothing is added to the custom
    /// checklist until <see cref="ApprovePending"/> runs.
    /// </summary>
    public static PendingCustomChecklistItem ReserveItem(string subAreaId, string title, string description, string rationale) => WithLock(() =>
    {
        EnsureInitializedCore();

        var subArea = GetSubAreasCore().FirstOrDefault(s =>
            string.Equals(s.SubAreaId, subAreaId, StringComparison.OrdinalIgnoreCase))
            ?? throw new InvalidOperationException(
                $"Sub-area '{subAreaId}' does not exist. Custom checklist items can only be added under an existing Area/Sub-area.");

        var taken = new HashSet<string>(
            ReadCatalogCore().Select(i => i.Id),
            StringComparer.OrdinalIgnoreCase);
        foreach (var p in ReadPendingCore()) taken.Add(p.Id);

        var next = 1;
        var prefix = subArea.SubAreaId + ".";
        foreach (var id in taken)
        {
            if (!id.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)) continue;
            var tail = id[prefix.Length..];
            if (int.TryParse(tail, NumberStyles.Integer, CultureInfo.InvariantCulture, out var n) && n >= next)
                next = n + 1;
        }

        var pending = new PendingCustomChecklistItem
        {
            Id = prefix + next.ToString(CultureInfo.InvariantCulture),
            AreaId = subArea.AreaId,
            AreaTitle = subArea.AreaTitle,
            SubAreaId = subArea.SubAreaId,
            SubAreaTitle = subArea.SubAreaTitle,
            Title = title?.Trim() ?? "",
            Description = description?.Trim() ?? "",
            ClassificationRationale = rationale?.Trim() ?? "",
            CreatedUtc = DateTime.UtcNow.ToString("o", CultureInfo.InvariantCulture)
        };

        var all = ReadPendingCore();
        all.Add(pending);
        WritePendingCore(all);
        return pending;
    });

    public static PendingCustomChecklistItem? GetPending(string checklistId) => WithLock(() =>
    {
        EnsureInitializedCore();
        return ReadPendingCore().FirstOrDefault(p =>
            string.Equals(p.Id, checklistId, StringComparison.OrdinalIgnoreCase));
    });

    public static List<PendingCustomChecklistItem> GetAllPending() => WithLock(() =>
    {
        EnsureInitializedCore();
        return ReadPendingCore();
    });

    /// <summary>Attaches a generated + validated script to a reserved item, still without publishing it.</summary>
    public static void AttachScript(string checklistId, Action<PendingCustomChecklistItem> apply) => WithLock(() =>
    {
        var all = ReadPendingCore();
        var pending = all.FirstOrDefault(p => string.Equals(p.Id, checklistId, StringComparison.OrdinalIgnoreCase))
            ?? throw new InvalidOperationException($"No pending custom checklist item with ID '{checklistId}'.");
        apply(pending);
        pending.HasScript = true;
        WritePendingCore(all);
        return true;
    });

    /// <summary>Drops a reserved item (guardrail rejection, duplicate, or user rejection). Frees the ID.</summary>
    public static void DiscardPending(string checklistId) => WithLock(() =>
    {
        var all = ReadPendingCore();
        all.RemoveAll(p => string.Equals(p.Id, checklistId, StringComparison.OrdinalIgnoreCase));
        WritePendingCore(all);
        return true;
    });

    /// <summary>
    /// Publishes an approved item: writes it into custom-checklist.json, writes its script
    /// metadata into custom-deterministic-script-mapping.json, then regenerates the merged files.
    /// </summary>
    public static PendingCustomChecklistItem ApprovePending(string checklistId, string? scriptFile) => WithLock(() =>
    {
        EnsureInitializedCore();

        var all = ReadPendingCore();
        var pending = all.FirstOrDefault(p => string.Equals(p.Id, checklistId, StringComparison.OrdinalIgnoreCase))
            ?? throw new InvalidOperationException($"No pending custom checklist item with ID '{checklistId}'.");

        AddCustomItemCore(pending);
        UpsertMappingCore(CustomMappingPath, pending.Id, new JsonObject
        {
            ["script_file"] = string.IsNullOrWhiteSpace(scriptFile) ? null : scriptFile,
            ["scope"] = string.IsNullOrWhiteSpace(pending.Scope) ? null : pending.Scope,
            ["IsAdminCheck"] = pending.IsAdminCheck,
            ["IsDocumentationCheck"] = pending.IsDocumentationCheck,
            ["MCP_Feasibility"] = pending.McpFeasibility
        });

        all.RemoveAll(p => string.Equals(p.Id, checklistId, StringComparison.OrdinalIgnoreCase));
        WritePendingCore(all);

        RebuildMergedCore();
        return pending;
    });

    private static void AddCustomItemCore(PendingCustomChecklistItem pending)
    {
        var doc = ReadJsonObject(CustomChecklistPath) ?? new JsonObject { ["areas"] = new JsonArray() };
        if (doc["areas"] is not JsonArray areas)
        {
            areas = new JsonArray();
            doc["areas"] = areas;
        }

        var area = areas.OfType<JsonObject>()
            .FirstOrDefault(a => string.Equals(a["id"]?.GetValue<string>(), pending.AreaId, StringComparison.OrdinalIgnoreCase));
        if (area == null)
        {
            area = new JsonObject
            {
                ["id"] = pending.AreaId,
                ["title"] = pending.AreaTitle,
                ["sub_areas"] = new JsonArray()
            };
            areas.Add(area);
        }

        if (area["sub_areas"] is not JsonArray subs)
        {
            subs = new JsonArray();
            area["sub_areas"] = subs;
        }

        var sub = subs.OfType<JsonObject>()
            .FirstOrDefault(s => string.Equals(s["id"]?.GetValue<string>(), pending.SubAreaId, StringComparison.OrdinalIgnoreCase));
        if (sub == null)
        {
            sub = new JsonObject
            {
                ["id"] = pending.SubAreaId,
                ["title"] = pending.SubAreaTitle,
                ["items"] = new JsonArray()
            };
            subs.Add(sub);
        }

        if (sub["items"] is not JsonArray items)
        {
            items = new JsonArray();
            sub["items"] = items;
        }

        if (items.OfType<JsonObject>().Any(i =>
                string.Equals(i["id"]?.GetValue<string>(), pending.Id, StringComparison.OrdinalIgnoreCase)))
            throw new InvalidOperationException($"Custom checklist item '{pending.Id}' already exists.");

        items.Add(new JsonObject
        {
            ["id"] = pending.Id,
            // 'text' keeps the merged file compatible with every existing reader.
            ["text"] = string.IsNullOrWhiteSpace(pending.Description) ? pending.Title : pending.Title + " — " + pending.Description,
            ["custom"] = true,
            ["custom_title"] = pending.Title,
            ["custom_description"] = pending.Description,
            ["created"] = DateTime.UtcNow.ToString("o", CultureInfo.InvariantCulture)
        });

        doc["generated"] = DateTime.UtcNow.ToString("o", CultureInfo.InvariantCulture);
        doc["source"] = "Configure Checklist (custom items only)";
        WriteJson(CustomChecklistPath, doc);
    }

    // ------------------------------------------------------------------
    // Mapping writes used by the existing script-generation pipeline
    // ------------------------------------------------------------------

    /// <summary>
    /// Writes one mapping entry to the file that owns the ID (custom items to the custom mapping,
    /// everything else to the default mapping) and regenerates the merged mapping.
    /// </summary>
    public static void UpsertMappingEntry(
        string checklistId,
        string? scriptFile,
        string? scope,
        bool isAdminCheck,
        bool isDocumentationCheck,
        bool mcpFeasibility) => WithLock(() =>
    {
        EnsureInitializedCore();

        var target = ReadCustomIdsCore().Contains(checklistId) ? CustomMappingPath : DefaultMappingPath;
        UpsertMappingCore(target, checklistId, new JsonObject
        {
            ["script_file"] = string.IsNullOrWhiteSpace(scriptFile) ? null : scriptFile,
            ["scope"] = string.IsNullOrWhiteSpace(scope) ? null : scope,
            ["IsAdminCheck"] = isAdminCheck,
            ["IsDocumentationCheck"] = isDocumentationCheck,
            ["MCP_Feasibility"] = mcpFeasibility
        });

        RebuildMergedCore();
        return true;
    });

    /// <summary>
    /// Applies a complete mapping snapshot (as produced by <c>ScriptGeneratorAgent</c>) by routing
    /// each entry to the default or custom mapping, then regenerating the merged mapping. Entries
    /// absent from the snapshot are left untouched.
    /// </summary>
    public static void ApplyMappingSnapshot(IEnumerable<KeyValuePair<string, JsonObject>> entries) => WithLock(() =>
    {
        EnsureInitializedCore();

        var customIds = ReadCustomIdsCore();
        var defaults = ReadJsonObject(DefaultMappingPath) ?? new JsonObject();
        var custom = ReadJsonObject(CustomMappingPath) ?? new JsonObject();

        foreach (var kv in entries)
        {
            if (string.IsNullOrWhiteSpace(kv.Key)) continue;
            var target = customIds.Contains(kv.Key) ? custom : defaults;
            target[kv.Key] = kv.Value.DeepClone();
        }

        WriteJson(DefaultMappingPath, defaults);
        WriteJson(CustomMappingPath, custom);
        RebuildMergedCore();
        return true;
    });

    private static void UpsertMappingCore(string path, string checklistId, JsonObject entry)
    {
        var doc = ReadJsonObject(path) ?? new JsonObject();
        doc[checklistId] = entry;
        WriteJson(path, doc);
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    private static List<ChecklistSubAreaInfo> GetSubAreasCore()
    {
        var result = new List<ChecklistSubAreaInfo>();
        var defaults = ReadJsonObject(DefaultChecklistPath);
        if (defaults?["areas"] is not JsonArray areas) return result;

        foreach (var area in areas.OfType<JsonObject>())
        {
            var areaId = area["id"]?.GetValue<string>() ?? "";
            var areaTitle = area["title"]?.GetValue<string>() ?? "";
            if (area["sub_areas"] is not JsonArray subs) continue;

            foreach (var sub in subs.OfType<JsonObject>())
            {
                var subId = sub["id"]?.GetValue<string>() ?? "";
                if (subId.Length == 0) continue;
                result.Add(new ChecklistSubAreaInfo
                {
                    AreaId = areaId,
                    AreaTitle = areaTitle,
                    SubAreaId = subId,
                    SubAreaTitle = sub["title"]?.GetValue<string>() ?? ""
                });
            }
        }

        return result;
    }

    private static List<PendingCustomChecklistItem> ReadPendingCore()
    {
        if (!File.Exists(PendingPath)) return new List<PendingCustomChecklistItem>();
        try
        {
            var json = File.ReadAllText(PendingPath);
            if (string.IsNullOrWhiteSpace(json)) return new List<PendingCustomChecklistItem>();
            return JsonSerializer.Deserialize<List<PendingCustomChecklistItem>>(json)
                   ?? new List<PendingCustomChecklistItem>();
        }
        catch
        {
            return new List<PendingCustomChecklistItem>();
        }
    }

    private static void WritePendingCore(List<PendingCustomChecklistItem> items) =>
        File.WriteAllText(PendingPath, JsonSerializer.Serialize(items, WriteOptions));

    private static JsonObject? ReadJsonObject(string path)
    {
        if (!File.Exists(path)) return null;
        try
        {
            var json = File.ReadAllText(path);
            if (string.IsNullOrWhiteSpace(json)) return null;
            return JsonNode.Parse(json) as JsonObject;
        }
        catch
        {
            return null;
        }
    }

    private static void WriteJson(string path, JsonNode node) =>
        File.WriteAllText(path, node.ToJsonString(WriteOptions));

    /// <summary>Numeric, segment-wise comparison so 1.1.10 sorts after 1.1.9.</summary>
    public static int CompareIds(string? a, string? b)
    {
        var left = (a ?? "").Split('.');
        var right = (b ?? "").Split('.');
        for (var i = 0; i < Math.Max(left.Length, right.Length); i++)
        {
            var lv = i < left.Length && int.TryParse(left[i], out var l) ? l : -1;
            var rv = i < right.Length && int.TryParse(right[i], out var r) ? r : -1;
            if (lv != rv) return lv.CompareTo(rv);
        }
        return string.Compare(a, b, StringComparison.OrdinalIgnoreCase);
    }

    private static T WithLock<T>(Func<T> action)
    {
        using var mutex = new Mutex(false, MutexName);
        var acquired = false;
        try
        {
            try { acquired = mutex.WaitOne(TimeSpan.FromSeconds(60)); }
            catch (AbandonedMutexException) { acquired = true; }
            return action();
        }
        finally
        {
            if (acquired)
            {
                try { mutex.ReleaseMutex(); } catch (ApplicationException) { }
            }
        }
    }
}
