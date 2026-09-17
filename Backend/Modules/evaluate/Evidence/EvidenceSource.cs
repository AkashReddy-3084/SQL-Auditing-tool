using System;
using System.Collections.Generic;

namespace SQLAuditor.Lib;

public enum EvidenceSourceKind
{
    LocalFolder,
    GitRemote,
    File,
}

/// <summary>
/// One resolved evidence input. Deliberately carries no credential: a token supplied through
/// <c>SQLAUDITOR_GIT_TOKEN</c> is used for the clone and then dropped.
/// </summary>
public sealed record EvidenceSourceRecord
{
    public string Label { get; init; } = string.Empty;

    public EvidenceSourceKind Kind { get; init; }

    /// <summary>The location as the user supplied it, with any embedded credential stripped.</summary>
    public string Location { get; init; } = string.Empty;

    /// <summary>Absolute path the content was resolved to on this machine.</summary>
    public string ResolvedPath { get; init; } = string.Empty;

    public string? GitRef { get; init; }

    public string? GitCommit { get; init; }

    public DateTime ResolvedAt { get; init; }

    /// <summary>Populated instead of <see cref="ResolvedPath"/> when resolution failed.</summary>
    public string? Error { get; init; }

    public bool IsResolved => string.IsNullOrEmpty(Error) && !string.IsNullOrWhiteSpace(ResolvedPath);
}

/// <summary>The evidence attached to a run: the resolved sources and the index built over them.</summary>
public sealed record EvidenceContext
{
    public IReadOnlyList<EvidenceSourceRecord> Sources { get; init; } = Array.Empty<EvidenceSourceRecord>();

    public EvidenceManifest Manifest { get; init; } = EvidenceManifest.Empty;

    public bool HasUsableEvidence => Manifest.Files.Count > 0;
}
