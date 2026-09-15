using System.Text.Json.Serialization;

namespace SQLAuditor.Lib;

[JsonConverter(typeof(JsonStringEnumConverter))]
public enum ServerRunStatus
{
    Running,
    Succeeded,
    Failed,
    Canceled
}

/// <summary>Outcome of evaluating one server inside a batch. A failure here never aborts the batch.</summary>
public sealed class ServerRunResult
{
    public required string Server { get; init; }
    public required string DisplayName { get; init; }
    public ServerRunStatus Status { get; set; } = ServerRunStatus.Running;

    /// <summary>Per-server run folder, e.g. results/20260910_101500_123_sql01.</summary>
    public string? RunDirectory { get; set; }

    public string? Error { get; set; }
    public DateTimeOffset StartedUtc { get; set; }
    public DateTimeOffset? CompletedUtc { get; set; }
    public int ItemsEvaluated { get; set; }

    [JsonIgnore]
    public ChecklistResult[] Results { get; set; } = Array.Empty<ChecklistResult>();
}

/// <summary>The manifest persisted as batch_manifest.json; the batch reports are rebuilt from it.</summary>
public sealed class BatchRunResult
{
    public required string BatchId { get; init; }
    public required string BatchDirectory { get; init; }
    public DateTimeOffset StartedUtc { get; init; }
    public DateTimeOffset? CompletedUtc { get; set; }
    public string[] RequestedItems { get; init; } = Array.Empty<string>();
    public int MaxParallel { get; init; }
    public List<ServerRunResult> Servers { get; init; } = new();

    public int SucceededCount => Servers.Count(s => s.Status == ServerRunStatus.Succeeded);
    public int FailedCount => Servers.Count(s => s.Status == ServerRunStatus.Failed);
    public int CanceledCount => Servers.Count(s => s.Status == ServerRunStatus.Canceled);
}
