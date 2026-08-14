using System;
using System.IO;

namespace SQLAuditor.Lib;

public static class ProviderConfig
{
    private const int DefaultTimeoutSeconds = 240;

    // Runtime overrides supplied via the UI. When set they take precedence over both
    // .env and ambient environment variables, so a .env file is not required.
    private static string? _baseUrlOverride;
    private static string? _apiKeyOverride;
    private static string? _modelOverride;

    static ProviderConfig()
    {
        var path = ResolveEnvFile();
        if (path != null) LoadEnvFile(path);
    }

    // Supplies LLM provider settings at runtime (from the UI). Not persisted to disk.
    public static void SetRuntime(string baseUrl, string apiKey, string model)
    {
        _baseUrlOverride = string.IsNullOrWhiteSpace(baseUrl) ? null : baseUrl.Trim();
        _apiKeyOverride = string.IsNullOrWhiteSpace(apiKey) ? null : apiKey.Trim();
        _modelOverride = string.IsNullOrWhiteSpace(model) ? null : model.Trim();
    }

    public static bool HasRuntimeConfig =>
        !string.IsNullOrWhiteSpace(_baseUrlOverride)
        && !string.IsNullOrWhiteSpace(_apiKeyOverride)
        && !string.IsNullOrWhiteSpace(_modelOverride);

    public static string BaseUrl => (_baseUrlOverride ?? Require("PROVIDER_BASE_URL")).TrimEnd('/');

    public static string ApiKey => _apiKeyOverride ?? Require("PROVIDER_API_KEY");

    public static string Model => _modelOverride ?? Require("MODEL");

    public static TimeSpan Timeout
    {
        get
        {
            var raw = Environment.GetEnvironmentVariable("PROVIDER_TIMEOUT_SECONDS");
            var seconds = int.TryParse(raw, out var parsed) && parsed > 0 ? parsed : DefaultTimeoutSeconds;
            return TimeSpan.FromSeconds(seconds);
        }
    }

    private static string Require(string key)
    {
        var value = Environment.GetEnvironmentVariable(key);
        if (string.IsNullOrWhiteSpace(value))
        {
            throw new InvalidOperationException(
                $"Required setting '{key}' is not configured. Copy .env.example to .env in the repository root and fill it in, or set '{key}' as an environment variable.");
        }

        value = value.Trim();

        // An ambient environment variable beats .env, so an unfilled placeholder there breaks every provider call.
        if (value.StartsWith('<') && value.EndsWith('>'))
        {
            throw new InvalidOperationException(
                $"Setting '{key}' still holds the placeholder value '{value}'. Fill it in, or clear the '{key}' environment variable so the value in .env is used.");
        }

        return value;
    }

    // .env wins over ambient variables: stale values inherited from a parent process are far more
    // likely than a deliberate override. With no .env present, environment variables are still used.
    private static void LoadEnvFile(string path)
    {
        foreach (var rawLine in File.ReadAllLines(path))
        {
            var line = rawLine.Trim();
            if (line.Length == 0 || line.StartsWith('#')) continue;

            var separator = line.IndexOf('=');
            if (separator <= 0) continue;

            var key = line[..separator].Trim();
            var value = line[(separator + 1)..].Trim();

            if (value.Length >= 2 && ((value[0] == '"' && value[^1] == '"') || (value[0] == '\'' && value[^1] == '\'')))
            {
                value = value[1..^1];
            }

            if (value.Length > 0)
            {
                Environment.SetEnvironmentVariable(key, value);
            }
        }
    }

    private static string? ResolveEnvFile()
    {
        foreach (var start in new[] { Directory.GetCurrentDirectory(), AppContext.BaseDirectory })
        {
            var dir = new DirectoryInfo(start);
            while (dir != null)
            {
                var candidate = Path.Combine(dir.FullName, ".env");
                if (File.Exists(candidate)) return candidate;
                dir = dir.Parent;
            }
        }

        return null;
    }
}
