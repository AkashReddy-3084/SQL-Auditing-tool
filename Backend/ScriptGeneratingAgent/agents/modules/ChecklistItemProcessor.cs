using System;
using System.IO;
using System.Net.Http;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Threading.Tasks;

namespace SQLAuditor.Agents
{
    public class ChecklistItemProcessor
    {

        private readonly HttpClient _httpClient;

        private readonly string _baseUrl;

        private readonly string _apiKey;

        private readonly string _model;

        private readonly string _systemPrompt;

        private readonly string _userPromptTemplate;

        private readonly int _maxRetries;


        public ChecklistItemProcessor(
            string baseUrl,
            string apiKey,
            string model,
            string promptsDir,
            int timeoutSeconds = 300,
            int maxRetries = 3)
        {

            _maxRetries = maxRetries;

            _baseUrl =
                baseUrl.TrimEnd('/');

            _apiKey = apiKey;

            _model = model;

            _httpClient =
                new HttpClient
                {
                    Timeout = TimeSpan.FromSeconds(timeoutSeconds)
                };

            _systemPrompt =
                File.ReadAllText(
                    Path.Combine(
                        promptsDir,
                        "script_generator_system.txt"));

            _userPromptTemplate =
                File.ReadAllText(
                    Path.Combine(
                        promptsDir,
                        "script_generator_user.txt"));
        }


        public async Task<ScriptGenerationResponse>
            GenerateScriptAsync(
                ChecklistItem item)
        {

            var userPrompt =
                _userPromptTemplate

                .Replace(
                    "{checklist_id}",
                    item.ChecklistId)

                .Replace(
                    "{category}",
                    item.Category)

                .Replace(
                    "{check_name}",
                    item.CheckName)

                .Replace(
                    "{description}",
                    item.Description)

                .Replace(
                    "{expected_outcome}",
                    item.ExpectedOutcome)

                .Replace(
                    "{scope}",
                    item.Scope ?? "");


            var requestBody =
                new
                {
                    model = _model,

                    messages = new[]
                    {
                        new
                        {
                            role = "system",
                            content = _systemPrompt
                        },

                        new
                        {
                            role = "user",
                            content = userPrompt
                        }
                    },

                    temperature = 0.2,

                    max_tokens = 4096
                };


            string content = "";

            for (int attempt = 1; attempt <= _maxRetries; attempt++)
            {
                try
                {
                    var request =
                        new HttpRequestMessage(
                            HttpMethod.Post,
                            $"{_baseUrl}/chat/completions");

                    request.Headers.Add(
                        "Authorization",
                        $"Bearer {_apiKey}");

                    request.Content =
                        new StringContent(
                            JsonSerializer.Serialize(requestBody),
                            Encoding.UTF8,
                            "application/json");

                    var response =
                        await _httpClient.SendAsync(request);

                    response.EnsureSuccessStatusCode();

                    var json =
                        await response.Content
                        .ReadAsStringAsync();

                    using var doc =
                        JsonDocument.Parse(json);

                    content =
                        doc.RootElement
                        .GetProperty("choices")[0]
                        .GetProperty("message")
                        .GetProperty("content")
                        .GetString()
                        ?? "";

                    break;
                }
                catch (TaskCanceledException) when (attempt < _maxRetries)
                {
                    Console.WriteLine(
                        $"    ⚠ LLM timeout (attempt {attempt}/{_maxRetries}), retrying in {attempt * 3}s...");
                    await Task.Delay(attempt * 3000);
                }
                catch (HttpRequestException ex) when (attempt < _maxRetries)
                {
                    Console.WriteLine(
                        $"    ⚠ LLM request failed (attempt {attempt}/{_maxRetries}): {ex.Message}");
                    await Task.Delay(attempt * 3000);
                }
            }

            return ParseResponse(content);
        }


        private ScriptGenerationResponse
            ParseResponse(string content)
        {

            var response =
                new ScriptGenerationResponse();


            // ==========================================
            // FEASIBILITY CHECK
            // ==========================================

            var feasible =
                Regex.Match(
                    content,
                    @"FEASIBLE:\s*(YES|NO)",
                    RegexOptions.IgnoreCase);

            if (feasible.Success &&
               feasible.Groups[1]
               .Value
               .Equals(
                   "NO",
                   StringComparison.OrdinalIgnoreCase))
            {
                response.IsFeasible = false;

                var reason =
                    Regex.Match(
                        content,
                        @"REASON:\s*(.+)");

                response.Reason =
                    reason.Success
                    ? reason.Groups[1]
                        .Value
                        .Trim()
                    : "Not feasible";

                return response;
            }


            response.IsFeasible = true;


            // ==========================================
            // PARSE SCRIPT CONTENT FIRST (needed for fallbacks)
            // ==========================================

            var script =
                Regex.Match(
                    content,
                    @"---SCRIPT_START---(.*?)---SCRIPT_END---",
                    RegexOptions.Singleline);

            if (script.Success)
            {
                response.ScriptContent =
                    script.Groups[1]
                    .Value
                    .Trim();
            }


            // ==========================================
            // SCRIPT_TYPE with fallback inference
            // ==========================================

            var type =
                Regex.Match(
                    content,
                    @"SCRIPT_TYPE:\s*(sql|ps1)",
                    RegexOptions.IgnoreCase);

            if (type.Success)
            {
                response.ScriptType =
                    type.Groups[1]
                    .Value
                    .ToLower();
            }
            else if (!string.IsNullOrEmpty(response.ScriptContent))
            {
                if (response.ScriptContent.Contains("DECLARE", StringComparison.OrdinalIgnoreCase) ||
                    response.ScriptContent.Contains("SELECT", StringComparison.OrdinalIgnoreCase) ||
                    response.ScriptContent.Contains("sys.", StringComparison.OrdinalIgnoreCase) ||
                    response.ScriptContent.Contains("@Result", StringComparison.OrdinalIgnoreCase))
                {
                    response.ScriptType = "sql";
                    Console.WriteLine(
                        "    ⚠ SCRIPT_TYPE missing, inferred as 'sql' from content");
                }
                else if (response.ScriptContent.Contains("$Score", StringComparison.OrdinalIgnoreCase) ||
                         response.ScriptContent.Contains("PSCustomObject", StringComparison.OrdinalIgnoreCase) ||
                         response.ScriptContent.Contains("$Result", StringComparison.OrdinalIgnoreCase))
                {
                    response.ScriptType = "ps1";
                    Console.WriteLine(
                        "    ⚠ SCRIPT_TYPE missing, inferred as 'ps1' from content");
                }
            }


            // ==========================================
            // SCOPE with fallback to SERVER
            // ==========================================

            var scope =
                Regex.Match(
                    content,
                    @"SCOPE:\s*(SERVER|DATABASE)",
                    RegexOptions.IgnoreCase);

            if (scope.Success)
            {
                response.Scope =
                    scope.Groups[1]
                    .Value
                    .ToUpperInvariant();
            }
            else
            {
                response.Scope = "SERVER";
                Console.WriteLine(
                    "    ⚠ SCOPE missing, defaulted to 'SERVER'");
            }


            // ==========================================
            // SCRIPT_NAME with fallback
            // ==========================================

            var name =
                Regex.Match(
                    content,
                    @"SCRIPT_NAME:\s*(.+)");

            if (name.Success)
            {
                response.ScriptName =
                    name.Groups[1]
                    .Value
                    .Trim();
            }
            else
            {
                response.ScriptName =
                    "check_" +
                    Guid.NewGuid()
                    .ToString("N")
                    .Substring(0, 8);

                Console.WriteLine(
                    $"    ⚠ SCRIPT_NAME missing, generated as '{response.ScriptName}'");
            }


            // ==========================================
            // SCORING_LOGIC (optional, no fallback needed)
            // ==========================================

            var scoring =
                Regex.Match(
                    content,
                    @"SCORING_LOGIC:\s*(.+)");

            if (scoring.Success)
            {
                response.ScoringLogic =
                    scoring.Groups[1]
                    .Value
                    .Trim();
            }


            return response;
        }
    }
}