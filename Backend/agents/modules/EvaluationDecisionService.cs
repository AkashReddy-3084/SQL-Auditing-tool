using System.Text.RegularExpressions;
using System.Threading.Tasks;

namespace SQLAuditor.Lib;

internal static class EvaluationDecisionService
{
    private const string ManualFallbackBody = """
        Objective: Confirm that this control is correctly implemented on the audited SQL Server instance.

        Note: Detailed guidance could not be generated automatically (the language model was unreachable).
        See results/ui_log.txt for the underlying error, then follow the generic steps below.

        ## Manual Verification Steps:
        1. Connect to the audited SQL Server instance in SQL Server Management Studio (SSMS) with an account that has at least the VIEW SERVER STATE permission.
        2. Identify the object, setting, job, or process named in the checklist description above.
        3. Inspect its current configuration in SSMS (Object Explorer, the relevant Properties dialog, or SQL Server Agent) and note what you find.
        4. Compare the observed configuration against your organisation's documented standard for this control.
        5. Record the evidence you relied on in the Remarks box so the finding can be reviewed later.

        ## What indicates a PASS and a FAIL
        Pass:
        - The control is present, enabled, and configured as the standard requires.
        - You can point to concrete evidence (a setting value, a job definition, a query result).
        Fail:
        - The control is missing, disabled, or configured differently from the standard.
        - No evidence of the control can be found on the instance.

        ## Recommended Actions (if failed)
        - Raise the gap with the team that owns this instance.
        - Apply the organisation's standard configuration for this control.
        - Re-run this checklist item once the change has been deployed.
        """;

    public static string EvaluateEvidenceOutcome(string evidence)
    {
        if (string.IsNullOrWhiteSpace(evidence)) return "NeedsReview";
        if (Regex.IsMatch(evidence, "\\b(Passed|Pass)\\b", RegexOptions.IgnoreCase)) return "Pass";
        if (Regex.IsMatch(evidence, "\\b(Failed|Fail)\\b", RegexOptions.IgnoreCase)) return "Fail";
        if (evidence.IndexOf("SQL ERROR", System.StringComparison.OrdinalIgnoreCase) >= 0) return "Fail";
        return "NeedsReview";
    }

    public static Task<string> BuildManualInstructionsAsync(ChecklistItem item)
    {
        var area = string.IsNullOrWhiteSpace(item.Category) ? string.Empty : $"Audit area: {item.Category}\n";
        return Task.FromResult($"Checklist: {item.Id} - {item.Description}\n{area}{ManualFallbackBody}");
    }
}
