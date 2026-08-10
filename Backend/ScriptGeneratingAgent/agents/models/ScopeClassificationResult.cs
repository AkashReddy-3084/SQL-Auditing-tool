namespace SQLAuditor.Agents
{
    public class ScopeClassificationResult
    {
        public bool IsFeasible { get; set; }

        public string Scope { get; set; } = "";

        public string Reason { get; set; } = "";

        public string Evidence { get; set; } = "";
    }
}