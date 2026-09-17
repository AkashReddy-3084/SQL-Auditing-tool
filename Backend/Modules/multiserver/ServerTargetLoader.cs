using System.Text.Json;

namespace SQLAuditor.Lib;

public sealed record ServerTargetLoadResult(
    IReadOnlyList<ServerTarget> Targets,
    IReadOnlyList<string> Errors)
{
    public bool HasErrors => Errors.Count > 0;
}

/// <summary>
/// Builds the batch target list from an inline server list or a JSON/CSV file. Passwords are never
/// read from the file: for SQL Login targets they come from the environment.
/// </summary>
public static class ServerTargetLoader
{
    /// <summary>Per-server override, e.g. SQLAUDITOR_SQL_PASSWORD_SQL01_PROD.</summary>
    public const string PasswordEnvPrefix = "SQLAUDITOR_SQL_PASSWORD_";

    /// <summary>Fallback used when no per-server variable is set.</summary>
    public const string PasswordEnvFallback = "SQLAUDITOR_SQL_PASSWORD";

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNameCaseInsensitive = true,
        ReadCommentHandling = JsonCommentHandling.Skip,
        AllowTrailingCommas = true,
    };

    /// <summary>Comma-separated server names, all using Windows authentication.</summary>
    public static ServerTargetLoadResult FromInlineList(string? servers)
    {
        var names = (servers ?? string.Empty)
            .Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);

        var targets = names.Select(name => new ServerTarget { Server = name }).ToList();
        return Validate(targets);
    }

    public static ServerTargetLoadResult FromFile(string path)
    {
        if (!File.Exists(path))
            return new ServerTargetLoadResult(Array.Empty<ServerTarget>(), new[] { $"Server list file not found: {path}" });

        try
        {
            var isCsv = Path.GetExtension(path).Equals(".csv", StringComparison.OrdinalIgnoreCase);
            var targets = isCsv
                ? ParseCsv(File.ReadAllLines(path))
                : ParseJson(File.ReadAllText(path));
            return Validate(targets);
        }
        catch (Exception ex)
        {
            return new ServerTargetLoadResult(Array.Empty<ServerTarget>(), new[] { $"Could not read {path}: {ex.Message}" });
        }
    }

    private static List<ServerTarget> ParseJson(string json)
    {
        var parsed = JsonSerializer.Deserialize<List<ServerTargetFile>>(json, JsonOptions)
            ?? new List<ServerTargetFile>();

        return parsed.Select(entry => new ServerTarget
        {
            Server = entry.Server?.Trim() ?? string.Empty,
            Name = entry.Name?.Trim(),
            AuthMode = ParseAuthMode(entry.AuthMode, entry.User),
            User = entry.User?.Trim(),
            Databases = NormalizeDatabases(entry.Databases),
        }).ToList();
    }

    private static List<ServerTarget> ParseCsv(IReadOnlyList<string> lines)
    {
        var targets = new List<ServerTarget>();
        var headerSeen = false;

        foreach (var raw in lines)
        {
            var line = raw.Trim();
            if (line.Length == 0 || line.StartsWith('#')) continue;

            var cells = line.Split(',').Select(c => c.Trim()).ToArray();

            if (!headerSeen)
            {
                headerSeen = true;
                if (cells[0].Equals("server", StringComparison.OrdinalIgnoreCase)) continue;
            }

            var user = Cell(cells, 3);
            targets.Add(new ServerTarget
            {
                Server = cells[0],
                Name = Cell(cells, 1),
                AuthMode = ParseAuthMode(Cell(cells, 2), user),
                User = user,
                Databases = NormalizeDatabases(Cell(cells, 4)?.Split(';', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)),
            });
        }

        return targets;
    }

    private static string? Cell(string[] cells, int index) =>
        index < cells.Length && cells[index].Length > 0 ? cells[index] : null;

    private static ServerAuthMode ParseAuthMode(string? value, string? user)
    {
        if (string.IsNullOrWhiteSpace(value))
            return string.IsNullOrWhiteSpace(user) ? ServerAuthMode.Windows : ServerAuthMode.Sql;

        return value.Trim().ToLowerInvariant() switch
        {
            "sql" or "sqllogin" or "sql login" or "sql_login" => ServerAuthMode.Sql,
            _ => ServerAuthMode.Windows,
        };
    }

    private static string[]? NormalizeDatabases(IEnumerable<string>? databases)
    {
        var list = databases?
            .Where(d => !string.IsNullOrWhiteSpace(d))
            .Select(d => d.Trim())
            .ToArray();
        return list is { Length: > 0 } ? list : null;
    }

    private static ServerTargetLoadResult Validate(List<ServerTarget> targets)
    {
        var errors = new List<string>();
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var valid = new List<ServerTarget>();

        foreach (var target in targets)
        {
            if (string.IsNullOrWhiteSpace(target.Server))
            {
                errors.Add("A server entry has no 'server' value.");
                continue;
            }

            if (!seen.Add(target.DisplayName))
            {
                errors.Add($"Duplicate entry '{target.DisplayName}' in the target list. Give one of them a distinct 'name'.");
                continue;
            }

            if (target.AuthMode == ServerAuthMode.Sql)
            {
                if (string.IsNullOrWhiteSpace(target.User))
                {
                    errors.Add($"Server '{target.Server}' uses SQL authentication but has no user.");
                    continue;
                }

                target.Password = ResolvePassword(target.Server);
                if (string.IsNullOrWhiteSpace(target.Password))
                {
                    errors.Add(
                        $"Server '{target.Server}' uses SQL authentication but no password was found. "
                        + $"Set {PasswordEnvPrefix}{SanitizeForEnv(target.Server)} or {PasswordEnvFallback}.");
                    continue;
                }
            }

            valid.Add(target);
        }

        if (valid.Count == 0 && errors.Count == 0)
            errors.Add("No servers were supplied.");

        return new ServerTargetLoadResult(valid, errors);
    }

    private static string? ResolvePassword(string server) =>
        Environment.GetEnvironmentVariable(PasswordEnvPrefix + SanitizeForEnv(server))
        ?? Environment.GetEnvironmentVariable(PasswordEnvFallback);

    private static string SanitizeForEnv(string server)
    {
        var chars = server.Select(c => char.IsLetterOrDigit(c) ? char.ToUpperInvariant(c) : '_');
        return new string(chars.ToArray());
    }

    private sealed class ServerTargetFile
    {
        public string? Server { get; set; }
        public string? Name { get; set; }
        public string? AuthMode { get; set; }
        public string? User { get; set; }
        public string[]? Databases { get; set; }
    }
}
