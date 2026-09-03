namespace SQLAuditor.Agents
{
    public class ScriptValidationResult
    {
        public bool IsValid { get; set; }

        public string Issues { get; set; } = "";

        public string? CorrectedScript { get; set; }
    }
}
