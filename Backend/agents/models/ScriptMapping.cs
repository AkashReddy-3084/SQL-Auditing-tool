namespace SQLAuditor.Agents
{
    public class ScriptMapping
    {
        public string ChecklistId { get; set; } = "";

        public string Name { get; set; } = "";

        public string Scope { get; set; } = "";

        public string ScopeReason { get; set; } = "";

        public string ScriptType { get; set; } = "";

        public string ScriptPath { get; set; } = "";

        public int MaxScore { get; set; }

        public string ScoringLogic { get; set; } = "";
    }
}