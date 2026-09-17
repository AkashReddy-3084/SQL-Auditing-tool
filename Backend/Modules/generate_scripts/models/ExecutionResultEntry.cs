namespace SQLAuditor.Agents
{
    public class ExecutionResultEntry
    {
        public string ChecklistId { get; set; } = "";

        public string CheckName { get; set; } = "";

        public string Category { get; set; } = "";

        public string Scope { get; set; } = "";

        public string ScopeReason { get; set; } = "";

        public string Status { get; set; } = "";

        public string Result { get; set; } = "";

        public int Score { get; set; }

        public string ScriptType { get; set; } = "";

        public string ScriptPath { get; set; } = "";

        public string ScoringLogic { get; set; } = "";

        public string Reason { get; set; } = "";
    }
}