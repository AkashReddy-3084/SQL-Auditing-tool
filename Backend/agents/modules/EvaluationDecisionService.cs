using System.Text;
using System.Text.RegularExpressions;
using System.Threading.Tasks;

namespace SQLAuditor.Lib;

internal static class EvaluationDecisionService
{
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
        var sb = new StringBuilder();
        sb.AppendLine($"Checklist: {item.Id} - {item.Description}");
        if (!string.IsNullOrWhiteSpace(item.Category))
        {
            sb.AppendLine($"Audit area: {item.Category}");
        }
        sb.AppendLine("Objective: Confirm that this control is correctly implemented on the audited SQL Server instance.");
        sb.AppendLine();
        sb.AppendLine("Note: Detailed guidance could not be generated automatically (the language model was unreachable).");
        sb.AppendLine("See results/ui_log.txt for the underlying error, then follow the generic steps below.");
        sb.AppendLine();
        sb.AppendLine("## Manual Verification Steps:");
        sb.AppendLine("1. Connect to the audited SQL Server instance in SQL Server Management Studio (SSMS) with an account that has at least the VIEW SERVER STATE permission.");
        sb.AppendLine("2. Identify the object, setting, job, or process named in the checklist description above.");
        sb.AppendLine("3. Inspect its current configuration in SSMS (Object Explorer, the relevant Properties dialog, or SQL Server Agent) and note what you find.");
        sb.AppendLine("4. Compare the observed configuration against your organisation's documented standard for this control.");
        sb.AppendLine("5. Record the evidence you relied on in the Remarks box so the finding can be reviewed later.");
        sb.AppendLine();
        sb.AppendLine("## What indicates a PASS and a FAIL");
        sb.AppendLine("Pass:");
        sb.AppendLine("- The control is present, enabled, and configured as the standard requires.");
        sb.AppendLine("- You can point to concrete evidence (a setting value, a job definition, a query result).");
        sb.AppendLine("Fail:");
        sb.AppendLine("- The control is missing, disabled, or configured differently from the standard.");
        sb.AppendLine("- No evidence of the control can be found on the instance.");
        sb.AppendLine();
        sb.AppendLine("## Recommended Actions (if failed)");
        sb.AppendLine("- Raise the gap with the team that owns this instance.");
        sb.AppendLine("- Apply the organisation's standard configuration for this control.");
        sb.AppendLine("- Re-run this checklist item once the change has been deployed.");

        return Task.FromResult(sb.ToString().TrimEnd());
    }
}
