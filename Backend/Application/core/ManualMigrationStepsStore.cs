using System.Text.Json;

namespace SQLAuditor.Lib;

internal static class ManualMigrationStepsStore
{
    internal const string FileName = "manual-migration-steps.json";

    private static readonly object SyncRoot = new();
    private static readonly JsonSerializerOptions SerializerOptions = new() { WriteIndented = true };

    public static bool TryGet(string? checklistItemId, out string steps)
    {
        steps = string.Empty;
        var id = NormalizeId(checklistItemId);
        if (id is null) return false;

        lock (SyncRoot)
        {
            var entries = Load();
            return entries.TryGetValue(id, out steps!) && !string.IsNullOrWhiteSpace(steps);
        }
    }

    public static void Store(string? checklistItemId, string? steps)
    {
        var id = NormalizeId(checklistItemId);
        if (id is null || string.IsNullOrWhiteSpace(steps)) return;

        lock (SyncRoot)
        {
            var path = Path.Combine(AuditOutputPaths.RootDirectory, FileName);
            var temporaryPath = path + ".tmp";
            try
            {
                var entries = Load();
                entries[id] = steps.Trim();

                Directory.CreateDirectory(AuditOutputPaths.RootDirectory);
                File.WriteAllText(temporaryPath, JsonSerializer.Serialize(entries, SerializerOptions));
                File.Move(temporaryPath, path, overwrite: true);
            }
            catch (IOException)
            {
            }
            catch (UnauthorizedAccessException)
            {
            }
            finally
            {
                try { File.Delete(temporaryPath); } catch { }
            }
        }
    }

    private static Dictionary<string, string> Load()
    {
        var entries = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        var path = Path.Combine(AuditOutputPaths.RootDirectory, FileName);
        if (!File.Exists(path)) return entries;

        try
        {
            var stored = JsonSerializer.Deserialize<Dictionary<string, string>>(File.ReadAllText(path));
            if (stored is null) return entries;

            foreach (var (id, steps) in stored)
            {
                var normalizedId = NormalizeId(id);
                if (normalizedId is not null && !string.IsNullOrWhiteSpace(steps))
                    entries[normalizedId] = steps;
            }
        }
        catch (JsonException)
        {
        }
        catch (IOException)
        {
        }
        catch (UnauthorizedAccessException)
        {
        }

        return entries;
    }

    private static string? NormalizeId(string? checklistItemId) =>
        string.IsNullOrWhiteSpace(checklistItemId) ? null : checklistItemId.Trim();
}