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
    private const string DefaultBaseUrl = "https://llm.maqsoftware.net/v1";
    private const string DefaultApiKey = "sk-jlQlxi3zFjCNOYyeSqLDwQ";
    private const string DefaultModel = "qwen-3.6-27b";

    private readonly string _baseUrl;
    private readonly string _model;
    private readonly HttpClient _http;

    private ManualStepsGenerator(string baseUrl, string apiKey, string model)
    {
        _baseUrl = baseUrl;
        _model = model;
        _http = new HttpClient();
        _http.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", apiKey);
    }

    public static ManualStepsGenerator CreateFromEnvironment()
    {
        var baseUrl = Environment.GetEnvironmentVariable("PROVIDER_BASE_URL");
        var apiKey = Environment.GetEnvironmentVariable("PROVIDER_API_KEY");
        var model = Environment.GetEnvironmentVariable("MODEL");

        return new ManualStepsGenerator(
            string.IsNullOrWhiteSpace(baseUrl) ? DefaultBaseUrl : baseUrl.TrimEnd('/'),
            string.IsNullOrWhiteSpace(apiKey) ? DefaultApiKey : apiKey,
            string.IsNullOrWhiteSpace(model) ? DefaultModel : model);
    }

    public async Task<string> GenerateAsync(ChecklistItem item, CancellationToken cancellationToken = default)
    {
        var result = await GenerateWithMetadataAsync(item, cancellationToken);
        return result.Instructions;
    }

    public async Task<ManualStepsGenerationResult> GenerateWithMetadataAsync(ChecklistItem item, CancellationToken cancellationToken = default)
    {
        var checklistItem = $"ID: {item.Id}\nDescription: {item.Description}\nVerification: {item.Verification}";
        var systemPrompt = PromptTemplateStore.Render(
            "manual_steps_prompt.txt",
            new Dictionary<string, string>
            {
                ["CHECKLIST_ITEM"] = "The checklist item will be provided in the user message."
            });
        var userPrompt = checklistItem;

        var body = new
        {
            model = _model,
            messages = new[]
            {
                new { role = "system", content = systemPrompt },
                new { role = "user", content = userPrompt }
            }
        };

        using var content = new StringContent(JsonSerializer.Serialize(body), Encoding.UTF8, "application/json");
        using var response = await _http.PostAsync(_baseUrl + "/chat/completions", content, cancellationToken);
        response.EnsureSuccessStatusCode();

        var txt = await response.Content.ReadAsStringAsync(cancellationToken);
        using var doc = JsonDocument.Parse(txt);
        var totalTokens = TryExtractTotalTokens(doc.RootElement);
        if (!doc.RootElement.TryGetProperty("choices", out var choices) || choices.GetArrayLength() == 0)
        {
            return new ManualStepsGenerationResult(string.Empty, txt, totalTokens);
        }

        var output = choices[0].GetProperty("message").GetProperty("content").GetString();
        var instructions = string.IsNullOrWhiteSpace(output) ? string.Empty : output.Trim();
        return new ManualStepsGenerationResult(instructions, txt, totalTokens);
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
