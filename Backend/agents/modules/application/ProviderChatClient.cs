using System;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace SQLAuditor.Lib;

/// <summary>
/// Shared chat-completions transport for the report-wording enrichers. It owns the
/// provider quirks (reasoning models, strict-JSON support, truncated replies) so both
/// the script and manual enrichers behave identically against the same endpoint.
/// </summary>
internal sealed class ProviderChatClient
{
    private readonly string _model;
    private readonly HttpClient _http;
    private readonly string _endpoint;

    private ProviderChatClient(string baseUrl, string apiKey, string model)
    {
        _model = model;
        _endpoint = baseUrl.TrimEnd('/') + "/chat/completions";
        _http = new HttpClient { Timeout = ProviderConfig.Timeout };
        _http.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", apiKey);
    }

    public static ProviderChatClient CreateFromEnvironment() =>
        new(ProviderConfig.BaseUrl, ProviderConfig.ApiKey, ProviderConfig.Model);

    /// <summary>
    /// A permanent fault (bad key, missing model) should disable enrichment for the whole
    /// run; a transient timeout should only skip the current item.
    /// </summary>
    public static bool IsPermanentFault(Exception ex) =>
        ex is HttpRequestException hre && hre.StatusCode is
            System.Net.HttpStatusCode.Unauthorized or
            System.Net.HttpStatusCode.Forbidden or
            System.Net.HttpStatusCode.NotFound;

    public async Task<string> CompleteAsync(string systemPrompt, string prompt, CancellationToken cancellationToken)
    {
        // qwen-3.6-27b and other Qwen3 reasoning models emit a long chain-of-thought before
        // the answer. Left on, the thinking pass consumes the whole max_tokens budget
        // (finish_reason=length) and message.content comes back empty — the reply lands in a
        // separate reasoning_content field that never finishes. Diagnostics confirmed the
        // endpoint is vLLM, which ignores the soft "/no_think" text directive but DOES honour
        // chat_template_kwargs.enable_thinking=false. Turning thinking off makes the model
        // answer directly, so content is populated and the call returns well inside the window.
        // The /no_think text is kept as a harmless fallback for servers that read it instead.
        var system = string.IsNullOrWhiteSpace(systemPrompt) ? "/no_think" : systemPrompt.TrimEnd() + "\n\n/no_think";

        object BuildBody(bool jsonMode, int maxTokens)
        {
            var messages = new[]
            {
                new { role = "system", content = system },
                new { role = "user", content = prompt }
            };
            return jsonMode
                ? new
                {
                    model = _model,
                    temperature = 0,
                    top_p = 1,
                    max_tokens = maxTokens,
                    chat_template_kwargs = new { enable_thinking = false },
                    response_format = new { type = "json_object" },
                    messages
                }
                : (object)new
                {
                    model = _model,
                    temperature = 0,
                    top_p = 1,
                    max_tokens = maxTokens,
                    chat_template_kwargs = new { enable_thinking = false },
                    messages
                };
        }

        async Task<HttpResponseMessage> PostAsync(bool jsonMode, int maxTokens)
        {
            var content = new StringContent(JsonSerializer.Serialize(BuildBody(jsonMode, maxTokens)), Encoding.UTF8, "application/json");
            return await _http.PostAsync(_endpoint, content, cancellationToken);
        }

        // Reads message.content from a successful response, logging the raw shape (and whether
        // the answer got stranded in reasoning_content) whenever content is empty. Returns the
        // text plus the finish_reason so the caller can decide whether a retry is worthwhile.
        async Task<(string Text, string? Finish)> ReadContentAsync(HttpResponseMessage response)
        {
            using (response)
            {
                var body = await response.Content.ReadAsStringAsync(cancellationToken);
                if (!response.IsSuccessStatusCode)
                {
                    // Carry the status code so the caller can tell a permanent fault from a
                    // transient timeout, and include the provider's own error text.
                    throw new HttpRequestException(
                        $"HTTP {(int)response.StatusCode} {response.StatusCode}: {Truncate(body, 300)}",
                        null,
                        response.StatusCode);
                }

                using var doc = JsonDocument.Parse(body);
                if (!doc.RootElement.TryGetProperty("choices", out var choices) || choices.GetArrayLength() == 0)
                {
                    WriteDiagnostic("provider", "success response had no choices. Raw: " + Truncate(body, 1500));
                    return (string.Empty, null);
                }

                var choice = choices[0];
                var message = choice.GetProperty("message");
                var text = message.TryGetProperty("content", out var contentEl) ? contentEl.GetString() ?? string.Empty : string.Empty;
                var finish = choice.TryGetProperty("finish_reason", out var fr) ? fr.GetString() : null;

                if (string.IsNullOrWhiteSpace(text))
                {
                    var hasReasoning = message.TryGetProperty("reasoning_content", out var rc)
                        && rc.ValueKind == JsonValueKind.String
                        && !string.IsNullOrWhiteSpace(rc.GetString());
                    WriteDiagnostic("provider",
                        $"empty message.content (finish_reason={finish ?? "(none)"}, reasoning_content present={hasReasoning}). Raw: " + Truncate(body, 1500));
                }

                return (text, finish);
            }
        }

        var resp = await PostAsync(true, MaxOutputTokens());

        // Some servers reject response_format=json_object; retry once without strict JSON mode.
        if (!resp.IsSuccessStatusCode && (int)resp.StatusCode is 400 or 422)
        {
            resp.Dispose();
            resp = await PostAsync(false, MaxOutputTokens());
        }

        var (text, finish) = await ReadContentAsync(resp);

        // Safety net: if the endpoint ignored enable_thinking and the reasoning pass still ate
        // the whole budget (empty content, finish_reason=length), retry once with a much larger
        // ceiling so the model has room to finish thinking AND emit the answer. A genuinely slow
        // item that now times out is handled by the caller (transient skip), not a cascade.
        if (string.IsNullOrWhiteSpace(text) && string.Equals(finish, "length", StringComparison.OrdinalIgnoreCase))
        {
            WriteDiagnostic("provider", $"retrying with larger max_tokens ({RetryMaxOutputTokens()}) after truncated empty reply.");
            var retry = await PostAsync(true, RetryMaxOutputTokens());
            if (!retry.IsSuccessStatusCode && (int)retry.StatusCode is 400 or 422)
            {
                retry.Dispose();
                retry = await PostAsync(false, RetryMaxOutputTokens());
            }
            (text, _) = await ReadContentAsync(retry);
        }

        return text;
    }

    public static void WriteDiagnostic(string id, string message)
    {
        try
        {
            var dir = System.IO.Path.Combine(System.IO.Directory.GetCurrentDirectory(), "results");
            System.IO.Directory.CreateDirectory(dir);
            var line = $"{DateTime.Now:yyyy-MM-dd HH:mm:ss} [{id}] {message}{Environment.NewLine}";
            System.IO.File.AppendAllText(System.IO.Path.Combine(dir, "enrichment_diagnostics.log"), line);
        }
        catch
        {
            // Diagnostics must never affect the audit run.
        }
    }

    public static string Truncate(string? value, int max)
    {
        if (string.IsNullOrEmpty(value)) return "(empty)";
        return value.Length <= max ? value : value[..max] + "…(truncated)";
    }

    /// <summary>Strips markdown fences and any preamble so the JSON object can be parsed.</summary>
    public static string? ExtractJsonObject(string raw)
    {
        if (string.IsNullOrWhiteSpace(raw)) return null;

        var cleaned = raw.Trim();
        if (cleaned.StartsWith("```"))
        {
            var first = cleaned.IndexOf('\n');
            var last = cleaned.LastIndexOf("```", StringComparison.Ordinal);
            if (first >= 0 && last > first) cleaned = cleaned[(first + 1)..last].Trim();
        }

        var start = cleaned.IndexOf('{');
        var end = cleaned.LastIndexOf('}');
        if (start < 0 || end <= start) return null;
        return cleaned[start..(end + 1)];
    }

    public static string? ReadString(JsonElement root, string name)
    {
        if (!root.TryGetProperty(name, out var el) || el.ValueKind != JsonValueKind.String) return null;
        var value = el.GetString();
        return string.IsNullOrWhiteSpace(value) ? null : value.Trim();
    }

    // Bounds the model's reply so a slow reasoning pass can't run past the provider timeout.
    // Overridable via PROVIDER_MAX_TOKENS for endpoints that need more or less headroom.
    private static int MaxOutputTokens()
    {
        var raw = Environment.GetEnvironmentVariable("PROVIDER_MAX_TOKENS");
        return int.TryParse(raw, out var v) && v > 0 ? v : 800;
    }

    // Larger ceiling used only for the one-shot retry when a reasoning model ignored the
    // enable_thinking switch and truncated its answer. Overridable via PROVIDER_MAX_TOKENS_RETRY.
    private static int RetryMaxOutputTokens()
    {
        var raw = Environment.GetEnvironmentVariable("PROVIDER_MAX_TOKENS_RETRY");
        if (int.TryParse(raw, out var v) && v > 0) return v;
        return Math.Max(4000, MaxOutputTokens() * 4);
    }
}
