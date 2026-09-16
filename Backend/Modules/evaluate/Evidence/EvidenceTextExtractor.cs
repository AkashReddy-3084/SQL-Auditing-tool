using System;
using System.Collections.Generic;
using System.IO;
using System.Text;

namespace SQLAuditor.Lib;

/// <summary>
/// Reads evidence file content as redacted, size-capped text. Every path that hands file content
/// to an AI layer or to a report goes through here, so no unredacted secret can escape.
/// </summary>
public static class EvidenceTextExtractor
{
    public const int DefaultMaxCharacters = 20_000;

    private static readonly HashSet<string> TextExtensions = new(StringComparer.OrdinalIgnoreCase)
    {
        ".md", ".markdown", ".rst", ".adoc", ".txt", ".yml", ".yaml", ".json", ".xml", ".sql",
        ".cs", ".ps1", ".psm1", ".sh", ".bat", ".cmd", ".py", ".js", ".ts", ".csproj", ".sqlproj",
        ".props", ".targets", ".config", ".ini", ".toml", ".tf", ".tfvars", ".bicep", ".env",
        ".gitignore", ".gitattributes", ".editorconfig", ".dockerfile", ".csv",
    };

    public static bool IsExtractable(string path)
    {
        var ext = Path.GetExtension(path);
        if (string.IsNullOrEmpty(ext))
        {
            // Extensionless repository files that still matter (CODEOWNERS, Jenkinsfile, Dockerfile).
            var name = Path.GetFileName(path);
            return name.Equals("CODEOWNERS", StringComparison.OrdinalIgnoreCase)
                || name.Equals("Jenkinsfile", StringComparison.OrdinalIgnoreCase)
                || name.Equals("Dockerfile", StringComparison.OrdinalIgnoreCase)
                || name.Equals("LICENSE", StringComparison.OrdinalIgnoreCase);
        }

        return TextExtensions.Contains(ext);
    }

    /// <summary>
    /// Returns redacted text, or null when the file cannot be read as text. Binary document formats
    /// (PDF, DOCX, XLSX) are reported as unsupported rather than read as bytes.
    /// </summary>
    public static string? TryRead(string absolutePath, out string? reason, int maxCharacters = DefaultMaxCharacters)
    {
        reason = null;

        try
        {
            if (!File.Exists(absolutePath))
            {
                reason = "File not found.";
                return null;
            }

            if (!IsExtractable(absolutePath))
            {
                reason = $"'{Path.GetExtension(absolutePath)}' is not a supported text format; open it manually and record what it says.";
                return null;
            }

            var raw = ReadCapped(absolutePath, maxCharacters, out var truncated);
            var redacted = SecretRedactor.Redact(raw);
            return truncated ? redacted + $"\n\n[... truncated at {maxCharacters} characters ...]" : redacted;
        }
        catch (Exception ex)
        {
            reason = $"{ex.GetType().Name}: {ex.Message}";
            return null;
        }
    }

    /// <summary>Reads several files into one redacted, budgeted block for an AI prompt.</summary>
    public static string ReadBundle(IEnumerable<EvidenceFileEntry> entries, int totalCharacterBudget, int perFileCharacters = 6_000)
    {
        var sb = new StringBuilder();
        var used = 0;

        foreach (var entry in entries)
        {
            if (used >= totalCharacterBudget) break;

            var allowance = Math.Min(perFileCharacters, totalCharacterBudget - used);
            var text = TryRead(entry.AbsolutePath, out var reason, allowance);

            sb.Append("=== FILE: ").Append(entry.Path).AppendLine(" ===");
            if (text == null)
            {
                sb.AppendLine($"[unreadable: {reason}]");
            }
            else
            {
                sb.AppendLine(text);
            }
            sb.AppendLine();

            used += text?.Length ?? 0;
        }

        return sb.ToString().TrimEnd();
    }

    private static string ReadCapped(string path, int maxCharacters, out bool truncated)
    {
        using var reader = new StreamReader(path, Encoding.UTF8, detectEncodingFromByteOrderMarks: true);
        var buffer = new char[Math.Min(maxCharacters, 8192)];
        var sb = new StringBuilder();

        int read;
        while (sb.Length < maxCharacters && (read = reader.Read(buffer, 0, Math.Min(buffer.Length, maxCharacters - sb.Length))) > 0)
        {
            sb.Append(buffer, 0, read);
        }

        truncated = !reader.EndOfStream;
        return sb.ToString();
    }
}
