using System;
using System.Collections.Generic;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
using SQLAuditor.Agents;

namespace SQLAuditor.Lib;

/// <summary>
/// Runs the complete Configure Checklist pipeline for hosts that own a model endpoint (the WPF
/// app):
///
///   Guardrails -> Semantic Match Router -> Area/Sub-area Classification
///   -> Script &amp; Logic Generator -> User Verification -> custom-checklist.json
///   -> custom-deterministic-script-mapping.json -> Merge Final Configuration
///
/// The AI stages run through <see cref="CustomChecklistAiAgent"/>; script generation and
/// validation reuse the existing <see cref="ChecklistItemProcessor"/> and
/// <see cref="ScriptOutputValidator"/>. Nothing is persisted until the approval callback says yes.
/// </summary>
public sealed class CustomChecklistPipeline
{
    private const int MaxGenerationAttempts = 3;

    private readonly CustomChecklistAiAgent _ai;
    private readonly ChecklistItemProcessor _processor;
    private readonly ScriptOutputValidator _validator = new();

    public CustomChecklistPipeline()
    {
        ChecklistConfigurationStore.EnsureInitialized();

        _ai = new CustomChecklistAiAgent();
        _processor = new ChecklistItemProcessor(
            ProviderConfig.BaseUrl,
            ProviderConfig.ApiKey,
            ProviderConfig.Model,
            CustomChecklistSkill.PromptsDirectory,
            (int)ProviderConfig.Timeout.TotalSeconds,
            maxRetries: 3);
    }

    /// <summary>
    /// Processes every request in order. <paramref name="requestApproval"/> is invoked with the
    /// generated (but unsaved) draft and must return true to publish it.
    /// </summary>
    public async Task<CustomChecklistRunResult> RunAsync(
        IReadOnlyList<CustomChecklistRequest> requests,
        IProgress<string>? progress,
        Func<PendingCustomChecklistItem, CancellationToken, Task<bool>> requestApproval,
        CancellationToken cancellationToken = default,
        IProgress<CustomChecklistOutcome>? outcomeProgress = null)
    {
        var run = new CustomChecklistRunResult();

        void Complete(CustomChecklistOutcome result)
        {
            run.Outcomes.Add(result);
            outcomeProgress?.Report(result);
        }

        foreach (var request in requests)
        {
            cancellationToken.ThrowIfCancellationRequested();

            var label = string.IsNullOrWhiteSpace(request.Title) ? "(untitled)" : request.Title;
            var outcome = new CustomChecklistOutcome
            {
                Title = request.Title,
                Description = request.Description
            };

            string? reservedId = null;
            try
            {
                // ---- Guardrails ------------------------------------------------
                progress?.Report($"[{label}] Guardrails: validating safety, validity and applicability...");
                var guard = await _ai.RunGuardrailsAsync(request.Title, request.Description, cancellationToken);
                if (!guard.IsAccepted)
                {
                    outcome.Status = "Rejected";
                    outcome.Detail = guard.Reason;
                    progress?.Report($"[{label}] REJECTED by guardrails: {guard.Reason}");
                    Complete(outcome);
                    continue;
                }

                var title = guard.NormalizedTitle;
                var description = guard.NormalizedDescription;
                progress?.Report($"[{label}] Guardrails passed.");

                // ---- Semantic match router -------------------------------------
                progress?.Report($"[{label}] Semantic match router: checking existing coverage...");
                var match = await _ai.RunSemanticMatchAsync(title, description, cancellationToken);
                if (match.IsDuplicate)
                {
                    outcome.Status = "Duplicate";
                    outcome.AssignedId = match.MatchedId;
                    outcome.Detail = $"Already covered by {match.MatchedId}: {match.MatchedText}. {match.Reason}";
                    progress?.Report($"[{label}] DUPLICATE of {match.MatchedId} — {match.MatchedText}");
                    Complete(outcome);
                    continue;
                }
                progress?.Report($"[{label}] No existing checklist item covers this. {match.Reason}");

                // ---- Area / Sub-area classification ----------------------------
                progress?.Report($"[{label}] Classifying into an existing Area/Sub-area...");
                var classification = await _ai.ClassifyAsync(title, description, cancellationToken);
                if (!classification.IsClassified)
                {
                    outcome.Status = "Unclassified";
                    outcome.Detail = classification.Rationale;
                    progress?.Report($"[{label}] NOT CLASSIFIED: {classification.Rationale}");
                    Complete(outcome);
                    continue;
                }

                var pending = CustomChecklistSkill.Reserve(
                    classification.SubAreaId, title, description, classification.Rationale);
                reservedId = pending.Id;

                outcome.AssignedId = pending.Id;
                outcome.SubAreaId = pending.SubAreaId;
                outcome.SubAreaTitle = pending.SubAreaTitle;
                progress?.Report(
                    $"[{label}] Area {pending.AreaId} / Sub-area {pending.SubAreaId} ({pending.SubAreaTitle}). "
                    + $"Assigned checklist ID {pending.Id}. {classification.Rationale}");

                // ---- Script & logic generator ----------------------------------
                var response = await GenerateAsync(pending, progress, cancellationToken);
                if (response == null)
                {
                    CustomChecklistSkill.Discard(pending.Id);
                    reservedId = null;
                    outcome.Status = "Failed";
                    outcome.Detail = $"Script generation failed after {MaxGenerationAttempts} attempts.";
                    progress?.Report($"[{pending.Id}] Script generation FAILED — nothing was added.");
                    Complete(outcome);
                    continue;
                }

                CustomChecklistSkill.AttachScriptForApproval(pending.Id, response);
                var draft = ChecklistConfigurationStore.GetPending(pending.Id)!;
                var (technique, why) = CustomChecklistSkill.DescribeEvaluationPath(draft);
                progress?.Report($"[{pending.Id}] Evaluation path: {technique} - {why}.");

                // ---- User verification / approval ------------------------------
                progress?.Report($"[{pending.Id}] Waiting for your review of the generated script...");
                var approved = await requestApproval(draft, cancellationToken);
                if (!approved)
                {
                    CustomChecklistSkill.Discard(pending.Id);
                    reservedId = null;
                    outcome.Status = "Declined";
                    outcome.Detail = "The generated script was rejected, so the checklist item was not added.";
                    progress?.Report($"[{pending.Id}] Rejected by the user — nothing was added.");
                    Complete(outcome);
                    continue;
                }

                // ---- Persist + merge -------------------------------------------
                var added = await CustomChecklistSkill.ApproveAsync(pending.Id, cancellationToken);
                reservedId = null;
                Complete(added);
                progress?.Report($"[{added.AssignedId}] Added to {ChecklistConfigurationStore.CustomChecklistFileName}. {added.Detail}");
            }
            catch (OperationCanceledException)
            {
                if (reservedId != null) CustomChecklistSkill.Discard(reservedId);
                throw;
            }
            catch (Exception ex)
            {
                if (reservedId != null) CustomChecklistSkill.Discard(reservedId);
                outcome.Status = "Failed";
                outcome.Detail = ex.Message;
                progress?.Report($"[{label}] ERROR: {ex.Message}");
                Complete(outcome);
            }
        }

        progress?.Report(CustomChecklistSkill.DescribeMergedConfiguration());
        return run;
    }

    /// <summary>
    /// Generation stage, using the same generate -> format gate -> C1-C7 review -> correct/retry
    /// loop the script pipeline uses. Returns null when every attempt fails.
    /// </summary>
    private async Task<ScriptGenerationResponse?> GenerateAsync(
        PendingCustomChecklistItem pending,
        IProgress<string>? progress,
        CancellationToken cancellationToken)
    {
        var item = CustomChecklistSkill.ToScriptGenItem(pending);
        string? retryContext = null;

        for (var attempt = 1; attempt <= MaxGenerationAttempts; attempt++)
        {
            cancellationToken.ThrowIfCancellationRequested();

            progress?.Report(attempt == 1
                ? $"[{pending.Id}] Generating the audit script..."
                : $"[{pending.Id}] Retry {attempt}/{MaxGenerationAttempts}: regenerating the audit script...");

            var response = await _processor.GenerateScriptAsync(item, progress, retryContext);

            if (!response.IsFeasible)
            {
                progress?.Report($"[{pending.Id}] NOT FEASIBLE as a script: {response.Reason}");
                return response;
            }

            var format = _validator.Validate(response);
            if (!format.IsValid)
            {
                progress?.Report($"[{pending.Id}] Format validation failed: {format.Error}");
                retryContext = $"Format validation failed: {format.Error}";
                continue;
            }

            progress?.Report($"[{pending.Id}] Reviewing the script (C1-C7)...");
            var review = await _processor.ValidateScriptAsync(item, response, progress);
            if (!review.IsValid)
            {
                if (string.IsNullOrWhiteSpace(review.CorrectedScript))
                {
                    retryContext = $"Content validation found issues: {review.Issues}";
                    continue;
                }

                response.ScriptContent = review.CorrectedScript;
                var recheck = _validator.Validate(response);
                if (!recheck.IsValid)
                {
                    retryContext = $"Content validation issues: {review.Issues}. "
                                 + $"The corrected script also failed the format gate: {recheck.Error}";
                    continue;
                }

                progress?.Report($"[{pending.Id}] Applied the corrected script from the review.");
            }

            return response;
        }

        return null;
    }
}
