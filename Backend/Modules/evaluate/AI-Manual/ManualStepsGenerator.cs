using System;
using System.Collections.Generic;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace SQLAuditor.Lib;

internal sealed record ManualStepsGenerationResult(string Instructions, string RawOutput, int TotalTokens);

internal sealed class ManualStepsGenerator
{
    private readonly string _baseUrl;
    private readonly string _model;
    private readonly HttpClient _http;

    private ManualStepsGenerator(string baseUrl, string apiKey, string model, TimeSpan timeout)
    {
        _baseUrl = baseUrl;
        _model = model;
        _http = new HttpClient { Timeout = timeout };
        _http.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", apiKey);
    }

    public static ManualStepsGenerator CreateFromEnvironment()
    {
        return new ManualStepsGenerator(
            ProviderConfig.BaseUrl,
            ProviderConfig.ApiKey,
            ProviderConfig.Model,
            ProviderConfig.Timeout);
    }

    public async Task<string> GenerateAsync(ChecklistItem item, CancellationToken cancellationToken = default)
    {
        var result = await GenerateWithMetadataAsync(item, null, cancellationToken);
        return result.Instructions;
    }

    public async Task<ManualStepsGenerationResult> GenerateWithMetadataAsync(ChecklistItem item, string? auditScript = null, CancellationToken cancellationToken = default)
    {
        var systemPrompt = PromptTemplateStore.Render(
            "manual_steps_prompt.txt",
            new Dictionary<string, string>
            {
                ["CHECKLIST_ITEM"] = "(supplied in the user message)"
            });

        var body = new
        {
            model = _model,
            temperature = 0.2,
            messages = new[]
            {
                new { role = "system", content = systemPrompt },
                new { role = "user", content = BuildChecklistItemPrompt(item, auditScript) }
            }
        };

        using var content = new StringContent(JsonSerializer.Serialize(body), Encoding.UTF8, "application/json");
        using var response = await _http.PostAsync(_baseUrl + "/chat/completions", content, cancellationToken);
        var txt = await response.Content.ReadAsStringAsync(cancellationToken);

        if (!response.IsSuccessStatusCode)
        {
            throw new HttpRequestException(
                $"HTTP {(int)response.StatusCode} {response.ReasonPhrase} from {_baseUrl}/chat/completions (model '{_model}'): {Truncate(txt, 500)}");
        }

        using var doc = JsonDocument.Parse(txt);
        var totalTokens = TryExtractTotalTokens(doc.RootElement);
        if (!doc.RootElement.TryGetProperty("choices", out var choices)
            || choices.GetArrayLength() == 0
            || !choices[0].TryGetProperty("message", out var message))
        {
            return new ManualStepsGenerationResult(string.Empty, txt, totalTokens);
        }

        // Reasoning models leave "content" empty and put the answer in "reasoning_content".
        var output = ReadStringProperty(message, "content");
        if (string.IsNullOrWhiteSpace(output))
        {
            output = ReadStringProperty(message, "reasoning_content");
        }

        var instructions = string.IsNullOrWhiteSpace(output) ? string.Empty : output.Trim();
        return new ManualStepsGenerationResult(instructions, txt, totalTokens);
    }

    private static string BuildChecklistItemPrompt(ChecklistItem item, string? auditScript)
    {
        var sb = new StringBuilder();
        sb.Append("ID: ").AppendLine(item.Id);
        sb.Append("Description: ").AppendLine(item.Description);
        if (!string.IsNullOrWhiteSpace(item.Category))
        {
            sb.Append("Audit area: ").AppendLine(item.Category);
        }
        if (!string.IsNullOrWhiteSpace(item.Verification))
        {
            sb.Append("Verification: ").AppendLine(item.Verification);
        }

        if (!string.IsNullOrWhiteSpace(auditScript))
        {
            sb.AppendLine();
            sb.AppendLine("AUDIT SCRIPT (already reviewed and read-only; this check needs administrator rights, so the operator runs it manually):");
            sb.AppendLine(auditScript.Trim());
        }

        return sb.ToString().TrimEnd();
    }

    private static string? ReadStringProperty(JsonElement element, string propertyName)
    {
        return element.TryGetProperty(propertyName, out var value) && value.ValueKind == JsonValueKind.String
            ? value.GetString()
            : null;
    }

    private static string Truncate(string value, int maxLength)
    {
        if (string.IsNullOrEmpty(value) || value.Length <= maxLength) return value;
        return value.Substring(0, maxLength) + "...";
    }

    private static int TryExtractTotalTokens(JsonElement root)
    {
        if (!root.TryGetProperty("usage", out var usage))
        {
            return 0;
        }

        if (TryReadInt(usage, "total_tokens", out var total) || TryReadInt(usage, "totalTokens", out total))
        {
            return Math.Max(total, 0);
        }

        var hasInput = TryReadInt(usage, "prompt_tokens", out var prompt)
            || TryReadInt(usage, "input_tokens", out prompt)
            || TryReadInt(usage, "promptTokens", out prompt)
            || TryReadInt(usage, "inputTokens", out prompt);

        var hasOutput = TryReadInt(usage, "completion_tokens", out var completion)
            || TryReadInt(usage, "output_tokens", out completion)
            || TryReadInt(usage, "completionTokens", out completion)
            || TryReadInt(usage, "outputTokens", out completion);

        if (hasInput || hasOutput)
        {
            return Math.Max(prompt, 0) + Math.Max(completion, 0);
        }

        return 0;
    }

    private static bool TryReadInt(JsonElement parent, string propertyName, out int value)
    {
        value = 0;
        if (!parent.TryGetProperty(propertyName, out var prop))
        {
            return false;
        }

        if (prop.ValueKind == JsonValueKind.Number && prop.TryGetInt32(out var i))
        {
            value = i;
            return true;
        }

        if (prop.ValueKind == JsonValueKind.String && int.TryParse(prop.GetString(), out i))
        {
            value = i;
            return true;
        }

        return false;
    }
}
