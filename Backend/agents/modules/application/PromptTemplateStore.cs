using System;
using System.Collections.Generic;
using System.IO;
using System.Text.RegularExpressions;

namespace SQLAuditor.Lib;

internal static class PromptTemplateStore
{
    private static readonly Dictionary<string, string> Cache = new(StringComparer.OrdinalIgnoreCase);

    public static string Render(string fileName, IReadOnlyDictionary<string, string> variables)
    {
        var template = Load(fileName);
        foreach (var pair in variables)
        {
            template = template.Replace("{{" + pair.Key + "}}", pair.Value ?? string.Empty, StringComparison.OrdinalIgnoreCase);
        }

        return template;
    }

    public static string Load(string fileName)
    {
        if (Cache.TryGetValue(fileName, out var cached)) return cached;

        var path = ResolvePromptPath(fileName);
        var text = File.Exists(path) ? File.ReadAllText(path) : string.Empty;
        Cache[fileName] = text;
        return text;
    }

    public static string ResolvePromptPath(string fileName)
    {
        var dir = new DirectoryInfo(Directory.GetCurrentDirectory());
        while (dir != null)
        {
            var candidate = Path.Combine(dir.FullName, "Backend", "agents", "prompts", fileName);
            if (File.Exists(candidate)) return candidate;
            dir = dir.Parent;
        }

        return Path.Combine(Directory.GetCurrentDirectory(), "Backend", "agents", "prompts", fileName);
    }
}
