using System.Globalization;
using System.Text.RegularExpressions;
using Microsoft.Data.SqlClient;

namespace SQLAuditor.Lib;

public static class AuditOutputPaths
{
    private static readonly object SyncRoot = new();
    private static readonly Regex RunDirectoryPattern = new(
        @"^\d{8}_\d{6}_\d{3}_.+$",
        RegexOptions.CultureInvariant);

    private static string? _activeRunDirectory;

    // Flows down one server's async call tree so parallel runs never share a run directory.
    private static readonly AsyncLocal<string?> ScopedRunDirectory = new();

    public static string RootDirectory =>
        Path.Combine(Directory.GetCurrentDirectory(), "results");

    public static string? ActiveRunDirectory
    {
        get
        {
            var scoped = ScopedRunDirectory.Value;
            if (scoped is not null) return scoped;

            lock (SyncRoot)
            {
                return _activeRunDirectory;
            }
        }
    }

    public static string CurrentRunDirectory
    {
        get
        {
            var scoped = ScopedRunDirectory.Value;
            if (scoped is not null) return scoped;

            lock (SyncRoot)
            {
                return _activeRunDirectory
                    ?? FindLatestRunDirectory()
                    ?? CreateRunDirectory("unknown-server", setAsActive: true);
            }
        }
    }

    public static IDisposable EnterRunScope(string runDirectory)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(runDirectory);
        return new RunScope(runDirectory);
    }

    /// <summary>Run directory of the enclosing <see cref="EnterRunScope"/>, or null when unscoped.</summary>
    public static string? AmbientRunDirectory => ScopedRunDirectory.Value;

    public static string BeginRun(string? connectionString) =>
        BeginRun(connectionString, setAsActive: true);

    public static string BeginRun(string? connectionString, bool setAsActive)
    {
        lock (SyncRoot)
        {
            Directory.CreateDirectory(RootDirectory);
            var serverName = SanitizeServerName(ReadServerName(connectionString));
            return CreateRunDirectory(serverName, setAsActive);
        }
    }

    /// <summary>
    /// Makes an existing run directory the active one, so every later read and report
    /// generation targets that run instead of creating a new one.
    /// </summary>
    public static void ResumeRun(string runDirectory)
    {
        if (string.IsNullOrWhiteSpace(runDirectory))
            throw new ArgumentException("A run directory is required.", nameof(runDirectory));

        var fullPath = Path.GetFullPath(runDirectory);
        if (!Directory.Exists(fullPath))
            throw new DirectoryNotFoundException($"Run directory not found: {fullPath}");

        lock (SyncRoot)
        {
            _activeRunDirectory = fullPath;
        }
    }

    /// <summary>The sanitized server token used in run directory names for this connection.</summary>
    public static string ResolveServerName(string? connectionString) =>
        SanitizeServerName(ReadServerName(connectionString));

    /// <summary>Existing run directories, newest first.</summary>
    public static IReadOnlyList<string> GetRunDirectories()
    {
        lock (SyncRoot)
        {
            return EnumerateRunDirectories().ToArray();
        }
    }

    /// <summary>Splits a <c>yyyyMMdd_HHmmss_fff_server</c> directory name into its parts.</summary>
    public static bool TryParseRunDirectoryName(string directoryName, out DateTime startedAt, out string serverName)
    {
        startedAt = default;
        serverName = string.Empty;
        if (string.IsNullOrWhiteSpace(directoryName)) return false;

        var name = Path.GetFileName(directoryName.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar));
        if (!RunDirectoryPattern.IsMatch(name)) return false;

        var parts = name.Split('_');
        if (parts.Length < 4) return false;

        if (!DateTime.TryParseExact(
                $"{parts[0]}_{parts[1]}_{parts[2]}",
                "yyyyMMdd_HHmmss_fff",
                CultureInfo.InvariantCulture,
                DateTimeStyles.None,
                out startedAt))
            return false;

        serverName = string.Join('_', parts.Skip(3));
        return true;
    }

    public static string GetCurrentFilePath(string fileName) =>
        Path.Combine(CurrentRunDirectory, fileName);

    public static string? FindLatestFile(string fileName)
    {
        var active = ActiveRunDirectory;

        lock (SyncRoot)
        {
            if (active is not null)
            {
                var activePath = Path.Combine(active, fileName);
                if (File.Exists(activePath)) return activePath;
            }

            foreach (var directory in EnumerateRunDirectories())
            {
                var path = Path.Combine(directory, fileName);
                if (File.Exists(path)) return path;
            }

            return null;
        }
    }

    private static string? FindLatestRunDirectory()
    {
        var directories = EnumerateRunDirectories().ToArray();
        return directories.FirstOrDefault(directory =>
                   File.Exists(Path.Combine(directory, "checklist_results.json")))
            ?? directories.FirstOrDefault();
    }

    private static string CreateRunDirectory(string serverName, bool setAsActive)
    {
        Directory.CreateDirectory(RootDirectory);

        var timestamp = DateTime.Now.ToString("yyyyMMdd_HHmmss_fff", CultureInfo.InvariantCulture);
        var baseName = $"{timestamp}_{serverName}";
        var runDirectory = Path.Combine(RootDirectory, baseName);
        var suffix = 2;

        while (Directory.Exists(runDirectory))
        {
            runDirectory = Path.Combine(RootDirectory, $"{baseName}_{suffix++}");
        }

        Directory.CreateDirectory(runDirectory);
        if (setAsActive) _activeRunDirectory = runDirectory;
        return runDirectory;
    }

    private static IEnumerable<string> EnumerateRunDirectories()
    {
        if (!Directory.Exists(RootDirectory)) return Array.Empty<string>();

        try
        {
            return Directory.EnumerateDirectories(RootDirectory)
                .Where(path => RunDirectoryPattern.IsMatch(Path.GetFileName(path)))
                .OrderByDescending(Path.GetFileName, StringComparer.Ordinal)
                .ToArray();
        }
        catch
        {
            return Array.Empty<string>();
        }
    }

    private static string ReadServerName(string? connectionString)
    {
        if (string.IsNullOrWhiteSpace(connectionString)) return "unknown-server";

        try
        {
            var builder = new SqlConnectionStringBuilder(connectionString);
            if (!string.IsNullOrWhiteSpace(builder.DataSource)) return builder.DataSource;
        }
        catch
        {
        }

        var match = Regex.Match(
            connectionString,
            @"(?:Server|Data Source|Address|Addr|Network Address)\s*=\s*([^;]+)",
            RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
        return match.Success ? match.Groups[1].Value.Trim() : "unknown-server";
    }

    private static string SanitizeServerName(string serverName)
    {
        var sanitized = Regex.Replace(serverName.Trim(), @"[^A-Za-z0-9._-]+", "_")
            .Trim('.', '-', '_');
        if (string.IsNullOrWhiteSpace(sanitized)) sanitized = "unknown-server";
        return sanitized.Length <= 80 ? sanitized : sanitized[..80];
    }

    private sealed class RunScope : IDisposable
    {
        private readonly string? _previous;
        private bool _disposed;

        public RunScope(string runDirectory)
        {
            _previous = ScopedRunDirectory.Value;
            ScopedRunDirectory.Value = runDirectory;
        }

        public void Dispose()
        {
            if (_disposed) return;
            _disposed = true;
            ScopedRunDirectory.Value = _previous;
        }
    }
}