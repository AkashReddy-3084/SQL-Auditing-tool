using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace SQLAuditor.Lib;

/// <summary>
/// Turns the evidence locations a user supplies - local folders, files and remote Git URLs - into
/// resolved, read-only paths on this machine. Nothing here calls an LLM.
/// </summary>
public static class EvidenceWorkspace
{
    /// <summary>Environment variable holding a PAT for private HTTPS clones. Never persisted.</summary>
    public const string TokenVariable = "SQLAUDITOR_GIT_TOKEN";

    private const int CloneDepth = 50;
    private static readonly TimeSpan GitTimeout = TimeSpan.FromMinutes(2);

    public static async Task<IReadOnlyList<EvidenceSourceRecord>> ResolveAsync(
        IEnumerable<string>? localPaths,
        string? gitUrl,
        string? gitRef,
        IEnumerable<string>? files,
        CancellationToken cancellationToken = default)
    {
        var resolved = new List<EvidenceSourceRecord>();

        foreach (var path in Clean(localPaths))
            resolved.Add(ResolveLocalFolder(path));

        foreach (var file in Clean(files))
            resolved.Add(ResolveFile(file));

        if (!string.IsNullOrWhiteSpace(gitUrl))
            resolved.Add(await ResolveGitRemoteAsync(gitUrl.Trim(), gitRef?.Trim(), cancellationToken));

        return resolved;
    }

    private static EvidenceSourceRecord ResolveLocalFolder(string path)
    {
        var record = new EvidenceSourceRecord
        {
            Kind = EvidenceSourceKind.LocalFolder,
            Location = path,
            Label = SafeLabel(path),
            ResolvedAt = DateTime.Now,
        };

        try
        {
            var full = Path.GetFullPath(path);
            if (!Directory.Exists(full))
                return record with { Error = $"Folder not found: {full}" };
            if (IsSensitiveSystemPath(full))
                return record with { Error = $"Refusing to read evidence from a system location: {full}" };

            return record with { ResolvedPath = full };
        }
        catch (Exception ex)
        {
            return record with { Error = $"{ex.GetType().Name}: {ex.Message}" };
        }
    }

    private static EvidenceSourceRecord ResolveFile(string path)
    {
        var record = new EvidenceSourceRecord
        {
            Kind = EvidenceSourceKind.File,
            Location = path,
            Label = SafeLabel(path),
            ResolvedAt = DateTime.Now,
        };

        try
        {
            var full = Path.GetFullPath(path);
            if (!File.Exists(full))
                return record with { Error = $"File not found: {full}" };
            if (IsSensitiveSystemPath(full))
                return record with { Error = $"Refusing to read evidence from a system location: {full}" };

            return record with { ResolvedPath = full };
        }
        catch (Exception ex)
        {
            return record with { Error = $"{ex.GetType().Name}: {ex.Message}" };
        }
    }

    private static async Task<EvidenceSourceRecord> ResolveGitRemoteAsync(string url, string? gitRef, CancellationToken cancellationToken)
    {
        var sanitized = SanitizeRemoteUrl(url);
        var record = new EvidenceSourceRecord
        {
            Kind = EvidenceSourceKind.GitRemote,
            Location = sanitized,
            Label = SafeLabel(sanitized),
            GitRef = gitRef,
            ResolvedAt = DateTime.Now,
        };

        // A browser URL would otherwise fail deep inside git with a message the user cannot act on.
        if (EvidenceRepositoryUrl.TryParseBrowseUrl(url) is { } browse)
            return record with { Error = EvidenceRepositoryUrl.DescribeBrowseUrlRejection(browse) };

        if (!IsSupportedRemoteUrl(url))
        {
            return record with
            {
                Error = "Only https:// Git clone URLs are supported. SSH remotes, file:// paths and git transport helpers (for example 'ext::') are rejected.",
            };
        }

        try
        {
            var root = Path.Combine(Path.GetTempPath(), "sqlauditor-evidence");
            Directory.CreateDirectory(root);
            var target = Path.Combine(root, Fingerprint(sanitized + "\u0001" + (gitRef ?? string.Empty)));
            if (Directory.Exists(target))
                TryDelete(target);
            Directory.CreateDirectory(target);

            var args = new List<string> { "clone", "--depth", CloneDepth.ToString(), "--no-single-branch" };
            if (!string.IsNullOrWhiteSpace(gitRef))
            {
                args.Add("--branch");
                args.Add(gitRef);
            }
            // "--" keeps a hostile URL from being parsed as further options.
            args.Add("--");
            args.Add(BuildCloneUrl(url));
            args.Add(target);

            var clone = await RunGitAsync(args, workingDirectory: root, cancellationToken);
            if (clone.ExitCode != 0)
            {
                var detail = Redact(clone.Error.Trim());
                if (!string.IsNullOrWhiteSpace(gitRef) && detail.Contains("not found in upstream", StringComparison.OrdinalIgnoreCase))
                    detail += $" — branch or tag '{gitRef}' does not exist in this repository.";
                return record with { Error = "git clone failed: " + detail };
            }

            var head = await RunGitAsync(new[] { "rev-parse", "HEAD" }, target, cancellationToken);
            var commit = head.ExitCode == 0 ? head.Output.Trim() : null;

            // Records the branch actually checked out, so a default-branch clone is not reported
            // as if it were the one the user asked for.
            var branch = await RunGitAsync(new[] { "rev-parse", "--abbrev-ref", "HEAD" }, target, cancellationToken);
            var checkedOut = branch.ExitCode == 0 ? branch.Output.Trim() : null;

            return record with
            {
                ResolvedPath = target,
                GitCommit = commit,
                GitRef = string.IsNullOrWhiteSpace(checkedOut) ? gitRef : checkedOut,
            };
        }
        catch (Exception ex)
        {
            return record with { Error = $"{ex.GetType().Name}: {Redact(ex.Message)}" };
        }
    }

    /// <summary>
    /// Injects the PAT into the clone URL only for the duration of the call. The token is never
    /// written to the record, the manifest or run metadata.
    /// </summary>
    private static string BuildCloneUrl(string url)
    {
        var token = Environment.GetEnvironmentVariable(TokenVariable);
        if (string.IsNullOrWhiteSpace(token)) return url;

        if (!Uri.TryCreate(url, UriKind.Absolute, out var uri)) return url;
        var builder = new UriBuilder(uri)
        {
            UserName = Uri.EscapeDataString("x-access-token"),
            Password = Uri.EscapeDataString(token.Trim()),
        };
        return builder.Uri.ToString();
    }

    public static bool IsSupportedRemoteUrl(string? url)
    {
        if (string.IsNullOrWhiteSpace(url)) return false;
        var trimmed = url.Trim();
        if (trimmed.StartsWith("-", StringComparison.Ordinal)) return false;
        if (trimmed.IndexOf("::", StringComparison.Ordinal) >= 0) return false;
        // Only a clone URL can be cloned; a browser URL is reported separately so the user is told why.
        if (EvidenceRepositoryUrl.IsBrowseUrl(trimmed)) return false;

        return Uri.TryCreate(trimmed, UriKind.Absolute, out var uri)
            && string.Equals(uri.Scheme, Uri.UriSchemeHttps, StringComparison.OrdinalIgnoreCase);
    }

    /// <summary>Strips any credential a user pasted inside the URL so it is safe to persist.</summary>
    public static string SanitizeRemoteUrl(string url)
    {
        if (!Uri.TryCreate(url?.Trim(), UriKind.Absolute, out var uri)) return url?.Trim() ?? string.Empty;
        if (string.IsNullOrEmpty(uri.UserInfo)) return uri.ToString();

        return new UriBuilder(uri) { UserName = string.Empty, Password = string.Empty }.Uri.ToString();
    }

    private static string Redact(string message)
    {
        var token = Environment.GetEnvironmentVariable(TokenVariable);
        if (!string.IsNullOrWhiteSpace(token))
            message = message.Replace(token.Trim(), "***", StringComparison.Ordinal);

        return SecretRedactor.Redact(message);
    }

    // Reading an evidence tree is a broad file read, so the obvious credential stores are refused
    // outright rather than relying on the caller to pick a sensible folder.
    private static bool IsSensitiveSystemPath(string fullPath)
    {
        string[] roots =
        {
            Environment.GetFolderPath(Environment.SpecialFolder.Windows),
            Environment.GetFolderPath(Environment.SpecialFolder.System),
            Environment.GetFolderPath(Environment.SpecialFolder.SystemX86),
        };

        foreach (var root in roots)
        {
            if (string.IsNullOrWhiteSpace(root)) continue;
            if (fullPath.StartsWith(root, StringComparison.OrdinalIgnoreCase)) return true;
        }

        var profile = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        if (!string.IsNullOrWhiteSpace(profile))
        {
            string[] secretFolders = { ".ssh", ".aws", ".azure", ".gnupg" };
            if (secretFolders.Any(f => fullPath.StartsWith(Path.Combine(profile, f), StringComparison.OrdinalIgnoreCase)))
                return true;
        }

        return false;
    }

    private static IEnumerable<string> Clean(IEnumerable<string>? values)
        => (values ?? Enumerable.Empty<string>())
            .Where(v => !string.IsNullOrWhiteSpace(v))
            .Select(v => v.Trim().Trim('"'))
            .Distinct(StringComparer.OrdinalIgnoreCase);

    private static string SafeLabel(string location)
    {
        try
        {
            var trimmed = location.TrimEnd('/', '\\');
            var name = Path.GetFileName(trimmed);
            return string.IsNullOrWhiteSpace(name) ? trimmed : name;
        }
        catch { return location; }
    }

    private static string Fingerprint(string value)
    {
        var hash = SHA256.HashData(Encoding.UTF8.GetBytes(value));
        return Convert.ToHexString(hash, 0, 8).ToLowerInvariant();
    }

    private static void TryDelete(string directory)
    {
        try
        {
            // A shallow clone leaves read-only objects under .git that block a plain delete.
            foreach (var file in Directory.EnumerateFiles(directory, "*", SearchOption.AllDirectories))
            {
                try { File.SetAttributes(file, FileAttributes.Normal); } catch { }
            }
            Directory.Delete(directory, recursive: true);
        }
        catch { }
    }

    internal static async Task<(int ExitCode, string Output, string Error)> RunGitAsync(
        IEnumerable<string> arguments,
        string? workingDirectory,
        CancellationToken cancellationToken)
    {
        var psi = new ProcessStartInfo("git")
        {
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true,
            WorkingDirectory = string.IsNullOrWhiteSpace(workingDirectory) ? Environment.CurrentDirectory : workingDirectory,
        };

        foreach (var arg in arguments) psi.ArgumentList.Add(arg);

        // Any credential prompt would hang a non-interactive host, so git must fail instead.
        // GIT_ASKPASS matters most: VS Code injects its own askpass helper into every child
        // process, and git prefers it over the terminal, so GIT_TERMINAL_PROMPT alone is not enough.
        psi.Environment["GIT_TERMINAL_PROMPT"] = "0";
        psi.Environment["GCM_INTERACTIVE"] = "never";
        psi.Environment["GIT_ASKPASS"] = "echo";

        using var process = new Process { StartInfo = psi };
        try
        {
            process.Start();
        }
        catch (Exception ex)
        {
            return (-1, string.Empty, $"git could not be started ({ex.Message}). Install Git and ensure it is on PATH.");
        }

        // Closed at once so anything that tries to prompt sees EOF and fails instead of waiting,
        // and so git can never consume the host's own stdin stream.
        try { process.StandardInput.Close(); } catch { }

        var stdout = process.StandardOutput.ReadToEndAsync(CancellationToken.None);
        var stderr = process.StandardError.ReadToEndAsync(CancellationToken.None);

        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(GitTimeout);
        try
        {
            await process.WaitForExitAsync(timeout.Token);
        }
        catch (OperationCanceledException)
        {
            try { process.Kill(entireProcessTree: true); } catch { }

            // The caller going away and git exceeding its own budget are different faults, and
            // reporting the first as a timeout sends anyone debugging it down the wrong path.
            return cancellationToken.IsCancellationRequested
                ? (-1, string.Empty, "the request was cancelled before git finished.")
                : (-1, string.Empty, $"git did not finish within {GitTimeout.TotalMinutes:n0} minute(s).");
        }

        return (process.ExitCode, await stdout, await stderr);
    }
}
