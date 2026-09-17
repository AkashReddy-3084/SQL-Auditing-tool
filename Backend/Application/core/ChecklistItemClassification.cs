using System;
using System.Collections.Generic;
using System.IO;
using System.Text.Json;

namespace SQLAuditor.Lib;

/// <summary>
/// Reads the <c>IsDocumentationCheck</c> flags from the deterministic script mapping for callers
/// outside a checklist run, which parses the mapping itself as part of a wider pass.
/// </summary>
internal static class ChecklistItemClassification
{
    private static readonly object Gate = new();
    private static HashSet<string>? _documentationItems;
    private static string? _loadedFrom;

    public static bool IsDocumentationCheck(string? id, string? repoRoot)
    {
        if (string.IsNullOrWhiteSpace(id)) return false;
        return Load(repoRoot).Contains(id);
    }

    private static HashSet<string> Load(string? repoRoot)
    {
        var path = string.IsNullOrWhiteSpace(repoRoot)
            ? null
            : Path.Combine(repoRoot, "Backend", "checklists", "deterministic-script-mapping.json");

        lock (Gate)
        {
            if (_documentationItems != null && string.Equals(_loadedFrom, path, StringComparison.OrdinalIgnoreCase))
                return _documentationItems;

            var items = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            try
            {
                if (path != null && File.Exists(path))
                {
                    using var doc = JsonDocument.Parse(File.ReadAllText(path));
                    foreach (var entry in doc.RootElement.EnumerateObject())
                    {
                        if (entry.Value.ValueKind != JsonValueKind.Object) continue;
                        if (entry.Value.TryGetProperty("IsDocumentationCheck", out var flag) && flag.ValueKind == JsonValueKind.True)
                            items.Add(entry.Name);
                    }
                }
            }
            catch { }

            _documentationItems = items;
            _loadedFrom = path;
            return items;
        }
    }
}
