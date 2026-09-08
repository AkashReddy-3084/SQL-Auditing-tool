using System;
using System.Collections.Generic;

namespace SQLAuditor.Lib;

/// <summary>An existing Area/Sub-area pair a custom checklist item can be filed under.</summary>
public sealed class ChecklistSubAreaInfo
{
    public string AreaId { get; set; } = "";
    public string AreaTitle { get; set; } = "";
    public string SubAreaId { get; set; } = "";
    public string SubAreaTitle { get; set; } = "";
    public int ItemCount { get; set; }
}

/// <summary>A checklist item as seen by the configuration flow (default or custom).</summary>
public sealed class ChecklistCatalogItem
{
    public string Id { get; set; } = "";
    public string Text { get; set; } = "";

    /// <summary>The custom item's own title; falls back to <see cref="Text"/> for default items.</summary>
    public string Title { get; set; } = "";
    public string AreaId { get; set; } = "";
    public string AreaTitle { get; set; } = "";
    public string SubAreaId { get; set; } = "";
    public string SubAreaTitle { get; set; } = "";
    public bool IsCustom { get; set; }
}

/// <summary>
/// A custom checklist item that has been accepted by the guardrails and classified, and whose
/// ID is reserved, but which is NOT yet part of the custom checklist. Nothing reaches
/// custom-checklist.json until the user approves the generated script.
/// </summary>
public sealed class PendingCustomChecklistItem
{
    public string Id { get; set; } = "";
    public string AreaId { get; set; } = "";
    public string AreaTitle { get; set; } = "";
    public string SubAreaId { get; set; } = "";
    public string SubAreaTitle { get; set; } = "";
    public string Title { get; set; } = "";
    public string Description { get; set; } = "";
    public string ClassificationRationale { get; set; } = "";
    public string CreatedUtc { get; set; } = "";

    // Populated once a script has been generated and validated, before approval.
    public bool HasScript { get; set; }
    public bool IsFeasible { get; set; }
    public string ScriptType { get; set; } = "";
    public string Scope { get; set; } = "";
    public string ScriptContent { get; set; } = "";
    public string ScoringLogic { get; set; } = "";
    public string Reason { get; set; } = "";
    public bool IsAdminCheck { get; set; }
    public bool IsDocumentationCheck { get; set; }
    public bool McpFeasibility { get; set; }
}

/// <summary>Outcome of the guardrails stage.</summary>
public sealed class GuardrailVerdict
{
    public bool IsAccepted { get; set; }
    public string Reason { get; set; } = "";
    public string NormalizedTitle { get; set; } = "";
    public string NormalizedDescription { get; set; } = "";
}

/// <summary>Outcome of the semantic match router stage.</summary>
public sealed class SemanticMatchVerdict
{
    public bool IsDuplicate { get; set; }
    public string MatchedId { get; set; } = "";
    public string MatchedText { get; set; } = "";
    public string Reason { get; set; } = "";
}

/// <summary>Outcome of the Area/Sub-area classification stage.</summary>
public sealed class AreaClassificationVerdict
{
    public bool IsClassified { get; set; }
    public string AreaId { get; set; } = "";
    public string SubAreaId { get; set; } = "";
    public string Rationale { get; set; } = "";
}

/// <summary>Per-item outcome of the whole custom checklist configuration pipeline.</summary>
public sealed class CustomChecklistOutcome
{
    public string Title { get; set; } = "";
    public string Description { get; set; } = "";

    /// <summary>Rejected | Duplicate | Unclassified | Failed | Declined | Added</summary>
    public string Status { get; set; } = "";
    public string Detail { get; set; } = "";
    public string AssignedId { get; set; } = "";
    public string SubAreaId { get; set; } = "";
    public string SubAreaTitle { get; set; } = "";

    public bool IsAdded => string.Equals(Status, "Added", StringComparison.OrdinalIgnoreCase);
}

/// <summary>A custom checklist request as typed by the user.</summary>
public sealed class CustomChecklistRequest
{
    public string Title { get; set; } = "";
    public string Description { get; set; } = "";
}

/// <summary>Aggregated result of a configuration run over several requests.</summary>
public sealed class CustomChecklistRunResult
{
    public List<CustomChecklistOutcome> Outcomes { get; } = new();
}
