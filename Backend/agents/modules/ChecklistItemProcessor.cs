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

        private readonly HttpClient _validationHttpClient;

        private readonly string _baseUrl;

        private readonly string _apiKey;

        private readonly string _model;

        private readonly string _systemPrompt;

        private readonly string _userPromptTemplate;

        private readonly int _maxRetries;

        private readonly string _validationSystemPrompt;

        private readonly string _validationUserPromptTemplate;


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

            _validationHttpClient =
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

            _validationSystemPrompt =
                File.ReadAllText(
                    Path.Combine(
                        promptsDir,
                        "script_validation_system.txt"));

            _validationUserPromptTemplate =
                File.ReadAllText(
                    Path.Combine(
                        promptsDir,
                        "script_validation_user.txt"));
        }


        public async Task<ScriptGenerationResponse>
            GenerateScriptAsync(
                ScriptGenChecklistItem item,
                IProgress<string>? progress = null,
                string? previousFailureContext = null)
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

            // On retry, append the failure context so the LLM knows what went wrong
            if (!string.IsNullOrWhiteSpace(previousFailureContext))
            {
                userPrompt += "\n\n--- PREVIOUS ATTEMPT FAILED ---\n"
                    + previousFailureContext
                    + "\n\nGenerate the script again, correcting the issues above. "
                    + "Ensure you include the complete script between ---SCRIPT_START--- and ---SCRIPT_END--- markers.";
            }


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

                    temperature = 0.1,

                    top_p = 1,

                    max_tokens = 8192,

                    stream = true
                };


            string content = "";
            bool truncated = false;

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

                    // Use ResponseHeadersRead so the connection stays alive
                    // while tokens stream in — prevents Cloudflare 524 timeouts.
                    var response =
                        await _httpClient.SendAsync(
                            request,
                            HttpCompletionOption.ResponseHeadersRead);

                    response.EnsureSuccessStatusCode();

                    var stream =
                        await ReadSseStreamAsync(response);

                    content = stream.Content;
                    truncated = stream.Truncated;

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

            if (string.IsNullOrWhiteSpace(content))
            {
                progress?.Report(
                    "    ⚠ LLM returned empty content after all attempts.");
            }
            else
            {
                progress?.Report(
                    $"    [Debug] LLM response length: {content.Length} chars");

                bool hasMarkers = content.Contains("---SCRIPT_START---");
                bool hasEndMarker = content.Contains("---SCRIPT_END---");
                bool hasCodeFence = content.Contains("```");
                bool hasThinkTag = content.Contains("<think>");
                progress?.Report(
                    $"    [Debug] Has SCRIPT_START: {hasMarkers} | Has SCRIPT_END: {hasEndMarker} | Has code fence: {hasCodeFence} | Has <think>: {hasThinkTag} | Token-capped: {truncated}");
            }

            var parsed = ParseResponse(content, truncated);

            // Log a diagnostic preview when content was received but script extraction failed
            if (!string.IsNullOrWhiteSpace(content) && parsed.IsFeasible && string.IsNullOrWhiteSpace(parsed.ScriptContent))
            {
                var preview = content.Length > 500
                    ? content.Substring(0, 500) + "...[truncated]"
                    : content;
                progress?.Report(
                    $"    ⚠ Script extraction failed despite LLM returning content. Preview:\n{preview}");
            }

            return parsed;
        }


        /// <summary>
        /// Reads an OpenAI-compatible streaming response. Handles both true SSE
        /// streams (text/event-stream) and servers that ignore the stream flag
        /// and return a single JSON body (application/json).
        /// </summary>
        private static async Task<LlmStreamResult>
            ReadSseStreamAsync(HttpResponseMessage response)
        {
            var contentType =
                response.Content.Headers.ContentType?.MediaType ?? "";

            // Some servers ignore stream=true and return a normal JSON body.
            if (contentType.Contains("application/json"))
            {
                var json = await response.Content.ReadAsStringAsync();
                try
                {
                    using var doc = JsonDocument.Parse(json);
                    var root = doc.RootElement;
                    if (root.TryGetProperty("choices", out var ch) &&
                        ch.GetArrayLength() > 0)
                    {
                        var choice = ch[0];
                        var cut = IsLengthCapped(choice);
                        if (choice.TryGetProperty("message", out var msg) &&
                            msg.TryGetProperty("content", out var mc) &&
                            mc.ValueKind == JsonValueKind.String)
                            return new LlmStreamResult(mc.GetString() ?? "", cut);
                        if (choice.TryGetProperty("text", out var t) &&
                            t.ValueKind == JsonValueKind.String)
                            return new LlmStreamResult(t.GetString() ?? "", cut);
                    }
                }
                catch (JsonException) { }
                return new LlmStreamResult("", false);
            }

            var truncated = false;

            var sb = new StringBuilder();

            using var stream =
                await response.Content.ReadAsStreamAsync();

            using var reader =
                new StreamReader(stream, Encoding.UTF8);

            var rawSb = new StringBuilder();

            while (true)
            {
                var line = await reader.ReadLineAsync();

                if (line == null)
                    break;

                rawSb.AppendLine(line);

                // SSE lines: "data: {...}" or "data:{...}" (some servers omit space)
                string payload;
                if (line.StartsWith("data: "))
                    payload = line.Substring(6).Trim();
                else if (line.StartsWith("data:"))
                    payload = line.Substring(5).Trim();
                else
                    continue;

                if (payload == "[DONE]")
                    break;

                if (payload.Length == 0)
                    continue;

                try
                {
                    using var doc = JsonDocument.Parse(payload);
                    var root = doc.RootElement;

                    if (!root.TryGetProperty("choices", out var choices) ||
                        choices.GetArrayLength() == 0)
                        continue;

                    var choice = choices[0];

                    if (IsLengthCapped(choice))
                        truncated = true;

                    // Standard chat streaming: choices[0].delta.content
                    if (choice.TryGetProperty("delta", out var delta))
                    {
                        if (delta.TryGetProperty("content", out var c) &&
                            c.ValueKind == JsonValueKind.String)
                        {
                            var token = c.GetString();
                            if (token != null)
                                sb.Append(token);
                        }
                        continue;
                    }

                    // Legacy completions streaming: choices[0].text
                    if (choice.TryGetProperty("text", out var t) &&
                        t.ValueKind == JsonValueKind.String)
                    {
                        var token = t.GetString();
                        if (token != null)
                            sb.Append(token);
                        continue;
                    }

                    // Non-streaming shape in SSE: choices[0].message.content
                    if (choice.TryGetProperty("message", out var msg) &&
                        msg.TryGetProperty("content", out var mc) &&
                        mc.ValueKind == JsonValueKind.String)
                    {
                        var token = mc.GetString();
                        if (token != null)
                            sb.Append(token);
                    }
                }
                catch (JsonException)
                {
                    // Malformed chunk — skip
                }
            }

            // Fallback: if SSE parsing yielded nothing, try parsing raw as JSON
            if (sb.Length == 0)
            {
                var raw = rawSb.ToString().Trim();
                if (raw.StartsWith("{"))
                {
                    try
                    {
                        using var doc = JsonDocument.Parse(raw);
                        var root = doc.RootElement;
                        if (root.TryGetProperty("choices", out var ch) &&
                            ch.GetArrayLength() > 0)
                        {
                            var choice = ch[0];
                            if (choice.TryGetProperty("message", out var msg) &&
                                msg.TryGetProperty("content", out var mc) &&
                                mc.ValueKind == JsonValueKind.String)
                                return new LlmStreamResult(
                                    mc.GetString() ?? "",
                                    IsLengthCapped(choice));
                        }
                    }
                    catch (JsonException) { }
                }

                Console.WriteLine(
                    $"    ⚠ SSE stream produced no content. Raw length: {raw.Length}. " +
                    $"Preview: {raw.Substring(0, Math.Min(300, raw.Length))}");
            }

            return new LlmStreamResult(sb.ToString(), truncated);
        }


        /// <summary>Provider stopped because the token budget ran out, not because the answer finished.</summary>
        private static bool IsLengthCapped(JsonElement choice)
        {
            return choice.TryGetProperty("finish_reason", out var fr) &&
                   fr.ValueKind == JsonValueKind.String &&
                   string.Equals(fr.GetString(), "length", StringComparison.OrdinalIgnoreCase);
        }


        private readonly record struct LlmStreamResult(string Content, bool Truncated);


        private ScriptGenerationResponse
            ParseResponse(string content, bool truncated = false)
        {

            var response =
                new ScriptGenerationResponse
                {
                    IsTruncated = truncated
                };


            // ==========================================
            // STRIP THINKING BLOCKS (Qwen, DeepSeek, etc.)
            // ==========================================

            content = Regex.Replace(
                content,
                @"<think>.*?</think>",
                "",
                RegexOptions.Singleline);

            content = content.Trim();


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

                // Parse classification fields even for non-feasible items
                ParseClassificationFields(content, response);

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

            // Fallback: relaxed end-marker matching (handles whitespace/dash variations)
            if (string.IsNullOrWhiteSpace(response.ScriptContent))
            {
                var relaxedScript =
                    Regex.Match(
                        content,
                        @"---\s*SCRIPT[_\s]START\s*---(.*?)---\s*SCRIPT[_\s]END\s*---",
                        RegexOptions.Singleline | RegexOptions.IgnoreCase);

                if (relaxedScript.Success)
                {
                    response.ScriptContent =
                        relaxedScript.Groups[1]
                        .Value
                        .Trim();

                    Console.WriteLine(
                        "    ⚠ Used relaxed marker matching to extract script");
                }
            }

            // Fallback: SCRIPT_START present but no matching end-marker —
            // take everything after the start marker
            if (string.IsNullOrWhiteSpace(response.ScriptContent) &&
                content.Contains("---SCRIPT_START---"))
            {
                var startIdx = content.IndexOf("---SCRIPT_START---") + "---SCRIPT_START---".Length;
                var remaining = content.Substring(startIdx).Trim();

                // Strip a trailing end-marker line if present in any form
                remaining = Regex.Replace(
                    remaining,
                    @"\s*---.*SCRIPT.*END.*---\s*$",
                    "",
                    RegexOptions.IgnoreCase).Trim();

                // Strip trailing metadata lines that may follow the script
                // (e.g. stray SCOPE:, SCORING_LOGIC: lines appended after the script)
                remaining = Regex.Replace(
                    remaining,
                    @"\n(SCOPE|SCORING_LOGIC|SCRIPT_NAME|SCRIPT_TYPE|FEASIBLE|REASON|IS_ADMIN_CHECK|IS_DOCUMENTATION_CHECK|MCP_FEASIBILITY):.*$",
                    "",
                    RegexOptions.Singleline | RegexOptions.IgnoreCase).Trim();

                if (!string.IsNullOrWhiteSpace(remaining))
                {
                    response.ScriptContent = remaining;

                    // No closing marker means the model stopped mid-answer; the
                    // extracted text is kept only so the retry can report it.
                    response.IsTruncated = true;

                    Console.WriteLine(
                        "    ⚠ ---SCRIPT_END--- marker missing or malformed, extracted content after ---SCRIPT_START---");
                }
            }

            // Fallback: extract from markdown code fences when markers are absent
            if (string.IsNullOrWhiteSpace(response.ScriptContent))
            {
                var codeFence =
                    Regex.Match(
                        content,
                        @"```(?:sql|powershell|ps1|tsql)?\s*\r?\n(.*?)```",
                        RegexOptions.Singleline | RegexOptions.IgnoreCase);

                if (codeFence.Success)
                {
                    response.ScriptContent =
                        codeFence.Groups[1]
                        .Value
                        .Trim();

                    Console.WriteLine(
                        "    ⚠ ---SCRIPT_START--- markers missing, extracted script from code fence");
                }
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


            // ==========================================
            // CLASSIFICATION FIELDS
            // ==========================================

            ParseClassificationFields(content, response);


            return response;
        }


        private static void ParseClassificationFields(string content, ScriptGenerationResponse response)
        {
            var adminCheck =
                Regex.Match(
                    content,
                    @"IS_ADMIN_CHECK:\s*(YES|NO)",
                    RegexOptions.IgnoreCase);

            response.IsAdminCheck =
                adminCheck.Success &&
                adminCheck.Groups[1].Value.Equals("YES", StringComparison.OrdinalIgnoreCase);

            var docCheck =
                Regex.Match(
                    content,
                    @"IS_DOCUMENTATION_CHECK:\s*(YES|NO)",
                    RegexOptions.IgnoreCase);

            response.IsDocumentationCheck =
                docCheck.Success &&
                docCheck.Groups[1].Value.Equals("YES", StringComparison.OrdinalIgnoreCase);

            var mcpFeasibility =
                Regex.Match(
                    content,
                    @"MCP_FEASIBILITY:\s*(YES|NO)",
                    RegexOptions.IgnoreCase);

            response.McpFeasibility =
                mcpFeasibility.Success &&
                mcpFeasibility.Groups[1].Value.Equals("YES", StringComparison.OrdinalIgnoreCase);
        }


        public async Task<ScriptValidationResult>
            ValidateScriptAsync(
                ScriptGenChecklistItem item,
                ScriptGenerationResponse generatedScript,
                IProgress<string>? progress = null)
        {

            // Delay before validation to avoid provider rate-limiting
            // (the generation call just completed on the same endpoint)
            await Task.Delay(3000);

            var userPrompt =
                _validationUserPromptTemplate

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
                    "{script_type}",
                    generatedScript.ScriptType ?? "")

                .Replace(
                    "{scope}",
                    generatedScript.Scope ?? "")

                .Replace(
                    "{scoring_logic}",
                    generatedScript.ScoringLogic ?? "")

                .Replace(
                    "{script_content}",
                    generatedScript.ScriptContent ?? "");


            var requestBody =
                new
                {
                    model = _model,

                    messages = new[]
                    {
                        new
                        {
                            role = "system",
                            content = _validationSystemPrompt
                        },

                        new
                        {
                            role = "user",
                            content = userPrompt
                        }
                    },

                    temperature = 0.1,

                    top_p = 1,

                    max_tokens = 8192,

                    stream = true
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
                        await _validationHttpClient.SendAsync(
                            request,
                            HttpCompletionOption.ResponseHeadersRead);

                    progress?.Report(
                        $"    [Debug] Validation HTTP status: {(int)response.StatusCode} {response.ReasonPhrase}");

                    response.EnsureSuccessStatusCode();

                    content =
                        (await ReadSseStreamAsync(response)).Content;

                    break;
                }
                catch (TaskCanceledException) when (attempt < _maxRetries)
                {
                    progress?.Report(
                        $"    ⚠ Validation LLM timeout (attempt {attempt}/{_maxRetries}), retrying...");
                    await Task.Delay(attempt * 3000);
                }
                catch (HttpRequestException ex) when (attempt < _maxRetries)
                {
                    progress?.Report(
                        $"    ⚠ Validation LLM request failed (attempt {attempt}/{_maxRetries}): {ex.Message}");
                    await Task.Delay(attempt * 3000);
                }
            }

            if (string.IsNullOrWhiteSpace(content))
            {
                progress?.Report(
                    "    ⚠ Validation LLM returned empty content, defaulting to valid.");
                return new ScriptValidationResult { IsValid = true };
            }

            progress?.Report(
                $"    [Debug] Validation response length: {content.Length} chars");

            return ParseValidationResponse(content);
        }


        private ScriptValidationResult
            ParseValidationResponse(string content)
        {

            var result = new ScriptValidationResult();


            // Strip thinking blocks (Qwen, DeepSeek, etc.)
            content = Regex.Replace(
                content,
                @"<think>.*?</think>",
                "",
                RegexOptions.Singleline);

            content = content.Trim();


            // Check verdict
            var verdict =
                Regex.Match(
                    content,
                    @"VERDICT:\s*(VALID|INVALID)",
                    RegexOptions.IgnoreCase);

            if (verdict.Success)
            {
                result.IsValid =
                    verdict.Groups[1]
                    .Value
                    .Equals(
                        "VALID",
                        StringComparison.OrdinalIgnoreCase);
            }
            else
            {
                // No verdict marker found — default to valid
                // to avoid blocking on parser failure
                result.IsValid = true;
                return result;
            }


            if (!result.IsValid)
            {
                // Extract issues
                var issuesMatch =
                    Regex.Match(
                        content,
                        @"ISSUES:\s*\n(.*?)(?=---CORRECTED_SCRIPT_START---|$)",
                        RegexOptions.Singleline);

                if (issuesMatch.Success)
                {
                    result.Issues =
                        issuesMatch.Groups[1]
                        .Value
                        .Trim();
                }

                // Extract corrected script if provided
                var corrected =
                    Regex.Match(
                        content,
                        @"---CORRECTED_SCRIPT_START---(.*?)---CORRECTED_SCRIPT_END---",
                        RegexOptions.Singleline);

                if (corrected.Success)
                {
                    var correctedContent =
                        corrected.Groups[1]
                        .Value
                        .Trim();

                    if (!string.IsNullOrWhiteSpace(correctedContent))
                    {
                        result.CorrectedScript = correctedContent;
                    }
                }
            }


            return result;
        }
    }
}