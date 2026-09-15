using System.Globalization;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace SQLAuditor.Lib;

public sealed class MultiServerRunOptions
{
    public required IReadOnlyList<ServerTarget> Targets { get; init; }
    public IEnumerable<string>? SelectedIds { get; init; }
    public bool UseHistoricalManualResults { get; init; }
    public int MaxParallel { get; init; } = DefaultMaxParallel;

    /// <summary>Per-item progress for one target; the host keys its own UI state off the target.</summary>
    public Func<ServerTarget, IProgress<ChecklistResult>?>? ProgressFactory { get; init; }

    /// <summary>
    /// Manual-item callback for one target. It must not block: several servers run at once, so a
    /// host that prompts has to queue the item and return immediately.
    /// </summary>
    public Func<ServerTarget, Func<ChecklistItem, string, Task<string?>>?>? UserInputFactory { get; init; }

    /// <summary>Pre-created batch folder; when null the runner creates one.</summary>
    public string? BatchDirectory { get; init; }

    /// <summary>Bounded by the LLM provider rate limit for the enrichment stages, not by SQL.</summary>
    public const int DefaultMaxParallel = 4;
}

/// <summary>
/// Runs the existing single-server evaluation engine against several instances concurrently. Each
/// server gets its own <see cref="Auditor"/> and its own run directory, entered as an ambient run
/// scope so every downstream write lands in the right folder.
/// </summary>
public static class MultiServerRunner
{
    public const string ManifestFileName = "batch_manifest.json";

    public static string CreateBatchDirectory()
    {
        var id = "batch_" + DateTime.Now.ToString("yyyyMMdd_HHmmss_fff", CultureInfo.InvariantCulture);
        var path = Path.Combine(AuditOutputPaths.RootDirectory, id);
        Directory.CreateDirectory(path);
        return path;
    }

    private static readonly JsonSerializerOptions ManifestOptions = new()
    {
        WriteIndented = true,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
    };

    public static async Task<BatchRunResult> RunAsync(
        MultiServerRunOptions options,
        IProgress<ServerRunResult>? serverProgress = null,
        CancellationToken cancellationToken = default)
    {
        var requestedItems = options.SelectedIds?.ToArray() ?? Array.Empty<string>();
        var batchDirectory = options.BatchDirectory ?? CreateBatchDirectory();
        Directory.CreateDirectory(batchDirectory);
        var batchId = Path.GetFileName(batchDirectory);

        var batch = new BatchRunResult
        {
            BatchId = batchId,
            BatchDirectory = batchDirectory,
            StartedUtc = DateTimeOffset.UtcNow,
            RequestedItems = requestedItems,
            MaxParallel = Math.Max(1, options.MaxParallel),
        };

        using var gate = new SemaphoreSlim(Math.Max(1, options.MaxParallel));

        var runs = options.Targets.Select(target =>
            RunOneAsync(target, options, gate, serverProgress, cancellationToken)).ToArray();

        batch.Servers.AddRange(await Task.WhenAll(runs));
        batch.CompletedUtc = DateTimeOffset.UtcNow;

        WriteManifest(batch);
        return batch;
    }

    private static async Task<ServerRunResult> RunOneAsync(
        ServerTarget target,
        MultiServerRunOptions options,
        SemaphoreSlim gate,
        IProgress<ServerRunResult>? serverProgress,
        CancellationToken cancellationToken)
    {
        var result = new ServerRunResult
        {
            Server = target.Server,
            DisplayName = target.DisplayName,
            StartedUtc = DateTimeOffset.UtcNow,
        };

        await gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            // A snapshot: Progress<T> posts asynchronously, so reporting the live object here
            // would let the consumer observe a status this method has since moved on from.
            serverProgress?.Report(new ServerRunResult
            {
                Server = result.Server,
                DisplayName = result.DisplayName,
                Status = ServerRunStatus.Running,
                StartedUtc = result.StartedUtc,
            });

            var connectionString = target.BuildConnectionString();
            var runDirectory = AuditOutputPaths.BeginRun(connectionString, setAsActive: false);
            result.RunDirectory = runDirectory;

            using var scope = AuditOutputPaths.EnterRunScope(runDirectory);
            var auditor = new Auditor(connectionString);

            var results = await auditor.RunChecklistAsync(
                progress: options.ProgressFactory?.Invoke(target),
                requestUserInput: options.UserInputFactory?.Invoke(target),
                selectedIds: options.SelectedIds,
                cancellationToken: cancellationToken,
                useHistoricalManualResults: options.UseHistoricalManualResults,
                generateReports: true,
                targetDatabases: target.Databases).ConfigureAwait(false);

            result.Results = results;
            result.ItemsEvaluated = results.Length;
            result.Status = ServerRunStatus.Succeeded;
        }
        catch (OperationCanceledException)
        {
            result.Status = ServerRunStatus.Canceled;
            result.Error = "Run canceled before completion.";
        }
        catch (Exception ex)
        {
            result.Status = ServerRunStatus.Failed;
            result.Error = ex.Message;
        }
        finally
        {
            result.CompletedUtc = DateTimeOffset.UtcNow;
            gate.Release();
        }

        serverProgress?.Report(result);
        return result;
    }

    private static void WriteManifest(BatchRunResult batch)
    {
        try
        {
            var path = Path.Combine(batch.BatchDirectory, ManifestFileName);
            File.WriteAllText(path, JsonSerializer.Serialize(batch, ManifestOptions));
        }
        catch
        {
        }
    }

    public static BatchRunResult? ReadManifest(string batchDirectory)
    {
        var path = Directory.Exists(batchDirectory)
            ? Path.Combine(batchDirectory, ManifestFileName)
            : batchDirectory;

        if (!File.Exists(path)) return null;

        try
        {
            return JsonSerializer.Deserialize<BatchRunResult>(File.ReadAllText(path), ManifestOptions);
        }
        catch
        {
            return null;
        }
    }
}
