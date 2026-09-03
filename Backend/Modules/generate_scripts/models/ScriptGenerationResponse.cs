namespace SQLAuditor.Agents
{
    public class ScriptGenerationResponse
    {
        public bool IsFeasible { get; set; }

        public string ScriptType { get; set; } = "";

        public string Scope { get; set; } = "";

        public string ScriptName { get; set; } = "";

        public string ScoringLogic { get; set; } = "";

        public string ScriptContent { get; set; } = "";

        public string Reason { get; set; } = "";

        /// <summary>Provider cut the response short, or the script had no closing marker.</summary>
        public bool IsTruncated { get; set; }

        public bool IsAdminCheck { get; set; }

        public bool IsDocumentationCheck { get; set; }

        public bool McpFeasibility { get; set; }
    }
}