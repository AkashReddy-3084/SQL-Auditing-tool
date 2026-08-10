namespace SQLAuditor.Agents
{
    public class ScriptExecutionResult
    {
        public bool Success { get; set; }

        public string Result { get; set; } = "Fail";

        public int Score { get; set; }

        public string Error { get; set; } = "";
    }
}
