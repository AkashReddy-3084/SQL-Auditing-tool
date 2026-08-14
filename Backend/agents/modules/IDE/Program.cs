using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using SQLAuditor.Lib;

// The evaluation engine locates the checklist and writes results/ relative to the
// current working directory. When VS Code launches this server, set the working
// directory to the SQL-Auditing-tool folder (via the MCP config "cwd") or set
// SQLAUDITOR_REPO_ROOT so the engine can find everything.
var repoRoot = Environment.GetEnvironmentVariable("SQLAUDITOR_REPO_ROOT");
if (!string.IsNullOrWhiteSpace(repoRoot) && Directory.Exists(repoRoot))
{
    Directory.SetCurrentDirectory(repoRoot);
}

// GitHub Copilot Chat is the AI for the IDE flow. Disable the engine's LLM evaluators
// so this server makes NO direct LLM/API calls, regardless of any .env or env vars.
Auditor.DisableLlmEvaluators();

var builder = Host.CreateApplicationBuilder(args);

// stdio transport uses stdout for the MCP protocol; all logs must go to stderr
// so they don't corrupt the JSON-RPC message stream.
builder.Logging.AddConsole(options =>
{
    options.LogToStandardErrorThreshold = LogLevel.Trace;
});

builder.Services
    .AddMcpServer()
    .WithStdioServerTransport()
    .WithToolsFromAssembly()
    .WithPromptsFromAssembly();

await builder.Build().RunAsync();
