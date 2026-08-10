namespace SQLAuditor.Agents
{
    public class ChecklistItem
    {
        public string ChecklistId { get; set; } = "";

        public string Category { get; set; } = "";

        public string CheckName { get; set; } = "";

        public string Scope { get; set; } = "";

        public string Description { get; set; } = "";

        public string ExpectedOutcome { get; set; } = "";
    }
}
