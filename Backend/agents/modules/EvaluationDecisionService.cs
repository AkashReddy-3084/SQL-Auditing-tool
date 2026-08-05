using System.Collections.Generic;
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
        var checklistItem = $"ID: {item.Id}\nDescription: {item.Description}\nVerification: {item.Verification}";
        var prompt = PromptTemplateStore.Render(
            "manual_steps_prompt.txt",
            new Dictionary<string, string>
            {
                ["CHECKLIST_ITEM"] = checklistItem
            });

        return Task.FromResult(prompt);
    }
}
