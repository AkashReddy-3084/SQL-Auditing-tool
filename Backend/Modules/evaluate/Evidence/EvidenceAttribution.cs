using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;

namespace SQLAuditor.Lib;

/// <summary>
/// Formats the "which artefact did this verdict come from" block that is appended to a result's
/// Evidence, and the instruction block that tells the AI layer how to use attached evidence.
/// </summary>
public static class EvidenceAttribution
{
    public const string EvidencePrefix = "Evidence Source:";

    public static string Describe(string? sourceLabel, string? files)
    {
        var label = string.IsNullOrWhiteSpace(sourceLabel) ? "(attached evidence)" : sourceLabel.Trim();
        var context = EvidenceStore.Load();
        var source = context?.Sources.FirstOrDefault(s =>
            string.Equals(s.Label, label, StringComparison.OrdinalIgnoreCase));

        var sb = new StringBuilder(label);
        if (source != null)
        {
            if (!string.IsNullOrWhiteSpace(source.GitRef)) sb.Append(" @ ").Append(source.GitRef);
            if (!string.IsNullOrWhiteSpace(source.GitCommit))
                sb.Append(" (").Append(source.GitCommit[..Math.Min(8, source.GitCommit.Length)]).Append(')');
        }

        var cited = SplitFiles(files);
        if (cited.Count > 0)
            sb.Append("\nFiles: ").Append(string.Join(", ", cited));

        return sb.ToString();
    }

    public static IReadOnlyList<string> SplitFiles(string? files)
        => (files ?? string.Empty)
            .Split(new[] { ',', ';', '\n' }, StringSplitOptions.RemoveEmptyEntries)
            .Select(f => f.Trim().Trim('"'))
            .Where(f => f.Length > 0)
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToList();

    /// <summary>True when a result's Evidence records that it was derived from attached evidence.</summary>
    public static bool IsEvidenceDerived(string? evidence)
        => !string.IsNullOrWhiteSpace(evidence)
           && evidence.Contains(EvidencePrefix, StringComparison.OrdinalIgnoreCase);

    /// <summary>
    /// The block appended to an evaluate/rerun response telling the AI layer to try the attached
    /// evidence before falling back to questioning the user.
    /// </summary>
    public static string BuildReviewRequest(IEnumerable<string> pendingItemIds, EvidenceContext? context)
    {
        var ids = pendingItemIds.Distinct(StringComparer.OrdinalIgnoreCase).ToList();
        var sb = new StringBuilder();

        if (context == null || !context.HasUsableEvidence)
        {
            sb.AppendLine("=== EVIDENCE REVIEW AVAILABLE (no evidence attached yet) ===");
            sb.AppendLine($"{ids.Count} item(s) need review. Many of them are documentation or process controls that CANNOT be");
            sb.AppendLine("answered from the SQL Server instance - they are evidenced by a Git repository, a CI/CD pipeline");
            sb.AppendLine("definition, a runbook, an architecture document or a policy record.");
            sb.AppendLine("BEFORE asking the user to review each item by hand, ask them ONCE:");
            sb.AppendLine("  \"Do you have a Git repository, deployment pipeline or documentation folder I can read as evidence?");
            sb.AppendLine("   Give me a local folder path, a file path, or an https Git URL - or say 'no' to review these manually.\"");
            sb.AppendLine("If they provide one, call set_evidence_sources(localPaths=\"...\", gitUrl=\"...\", gitRef=\"...\", files=\"...\").");
            sb.AppendLine("If they decline, continue with the manual review below.");
            return sb.ToString();
        }

        sb.AppendLine("=== ACTION REQUIRED: EVIDENCE REVIEW (do this BEFORE the manual review below) ===");
        sb.AppendLine("Evidence is attached to this run. YOU are the analyst - this server makes no LLM calls.");
        sb.AppendLine();
        sb.AppendLine(EvidenceStore.Describe(context));
        sb.AppendLine();
        sb.AppendLine("For EACH item listed for review below:");
        sb.AppendLine("  1. Identify the artefact the control requires - the specific document, pipeline definition,");
        sb.AppendLine("     mapping, register or repository setting that would evidence it - then check whether that");
        sb.AppendLine("     artefact is actually present in the attached evidence.");
        sb.AppendLine("  2. If it is present: READ it with your own file tools under the resolved paths above, then call");
        sb.AppendLine("     resolve_review(id=\"...\", decision=\"pass|fail\", notes=\"<what the files actually show, quoting");
        sb.AppendLine("     the values/sections you relied on>\", evidenceSource=\"<source label>\", evidenceFiles=\"<the");
        sb.AppendLine("     manifest paths you read>\"). Then call enrich_result for the same item.");
        sb.AppendLine("  3. RULES you must not break:");
        sb.AppendLine("     - If the required artefact is NOT in the attached evidence, leave the item as NeedsReview.");
        sb.AppendLine("       The evidence set is a partial view: an artefact you were not given may still exist. Its");
        sb.AppendLine("       absence here is NOT proof the control is missing and is NOT grounds for 'fail'.");
        sb.AppendLine("     - Cite only files you actually opened. Never cite a path you inferred from the manifest listing.");
        sb.AppendLine("     - 'fail' requires you to HOLD the artefact and for it to evidence a gap - an unapproved draft,");
        sb.AppendLine("       an unowned document, or one stating outright that the control does not exist.");
        sb.AppendLine("     - NEVER record 'notapplicable' from evidence. Whether a control has nothing to assess on this");
        sb.AppendLine("       platform is the user's judgement. Leave such an item as NeedsReview and tell the user what");
        sb.AppendLine("       the evidence suggests and why you think it may not apply.");
        sb.AppendLine("     - If the evidence is silent, partial or ambiguous, DO NOT decide. Leave the item for the manual");
        sb.AppendLine("       review below and tell the user which items the evidence could not settle.");
        sb.AppendLine("  4. After the pass, report which items you resolved from evidence and which still need the user.");
        sb.AppendLine();
        sb.AppendLine("Items eligible for evidence review: " + string.Join(", ", ids.OrderBy(i => i, StringComparer.OrdinalIgnoreCase)));

        return sb.ToString();
    }
}
