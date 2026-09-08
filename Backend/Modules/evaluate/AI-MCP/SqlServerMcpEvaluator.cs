using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Data.SqlClient;

namespace SQLAuditor.Lib;

internal sealed class SqlServerMcpEvaluator
{
    private sealed record ProviderCallResult(string Content);

    private sealed record SnapshotCacheEntry(string Key, string Snapshot);

    // Matches the score-to-verdict rule the audit scripts use.
    private const int PassScore = 2;

    private const int MaxProviderAttempts = 3;

    private static readonly TimeSpan MaxProviderBackoff = TimeSpan.FromSeconds(10);

    private readonly string _baseUrl;
    private readonly string _apiKey;
    private readonly string _model;
    private readonly HttpClient _http;

    // The snapshot describes the server, not the checklist item, so every item on one target
    // produces identical SQL. It is collected once per run and shared by all of them. Key and
    // snapshot live in one reference so a concurrent reader can never pair them up wrongly.
    private readonly SemaphoreSlim _snapshotGate = new(1, 1);
    private SnapshotCacheEntry? _snapshotCache;

    public string ProviderName => "MAQProvider";
    public string ModelName => _model;
    public string Endpoint => _baseUrl.TrimEnd('/') + "/chat/completions";

    private SqlServerMcpEvaluator(string baseUrl, string apiKey, string model)
    {
        _baseUrl = baseUrl;
        _apiKey = apiKey;
        _model = model;
        _http = new HttpClient();
        _http.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", _apiKey);
    }

    public static SqlServerMcpEvaluator CreateFromEnvironment()
    {
        return new SqlServerMcpEvaluator(
            ProviderConfig.BaseUrl,
            ProviderConfig.ApiKey,
            ProviderConfig.Model);
    }

    /// <summary>
    /// Drops the cached snapshot so the next run reads live server state again. Called by the
    /// engine when an evaluation starts; within a run the snapshot is deliberately stable so
    /// every item is judged against the same server state.
    /// </summary>
    public void ResetSnapshotCache()
    {
        _snapshotCache = null;
    }

    private async Task<string> GetSqlSnapshotAsync(
        string snapshotKey,
        Func<CancellationToken, Task<string>> collect,
        CancellationToken cancellationToken)
    {
        if (_snapshotCache is { } cached && cached.Key == snapshotKey) return cached.Snapshot;

        await _snapshotGate.WaitAsync(cancellationToken);
        try
        {
            if (_snapshotCache is { } warmed && warmed.Key == snapshotKey) return warmed.Snapshot;

            var collected = await collect(cancellationToken);

            // A failed collection is never cached: the next item retries instead of inheriting it.
            if (!string.IsNullOrWhiteSpace(collected))
            {
                _snapshotCache = new SnapshotCacheEntry(snapshotKey, collected);
            }

            return collected;
        }
        finally
        {
            _snapshotGate.Release();
        }
    }

    private static string SnapshotKeyFromConnectionString(string connectionString)
    {
        return BuildSnapshotKey(
            ReadConnectionValue(connectionString, "data source", "server", "addr", "address", "network address"),
            ReadConnectionValue(connectionString, "initial catalog", "database"));
    }

    private static string? ReadConnectionValue(string connectionString, params string[] keys)
    {
        foreach (var part in (connectionString ?? string.Empty).Split(';', StringSplitOptions.RemoveEmptyEntries))
        {
            var separator = part.IndexOf('=');
            if (separator <= 0) continue;

            var key = part.Substring(0, separator).Trim();
            foreach (var candidate in keys)
            {
                if (string.Equals(key, candidate, StringComparison.OrdinalIgnoreCase))
                    return part.Substring(separator + 1).Trim();
            }
        }

        return null;
    }

    /// <summary>
    /// Both overloads must derive the same key for one target. The cache holds a single entry, so
    /// a key that differed by transport prefix or casing would evict and re-collect on every call.
    /// </summary>
    private static string BuildSnapshotKey(string? dataSource, string? database)
    {
        var server = (dataSource ?? string.Empty).Trim();
        foreach (var prefix in new[] { "tcp:", "np:", "lpc:", "admin:" })
        {
            if (server.StartsWith(prefix, StringComparison.OrdinalIgnoreCase))
            {
                server = server.Substring(prefix.Length);
                break;
            }
        }

        var catalog = (database ?? string.Empty).Trim();
        if (catalog.Length == 0) catalog = "master";

        return server.ToLowerInvariant() + "|" + catalog.ToLowerInvariant();
    }

    public async Task<bool> IsAvailableAsync(int timeoutMs = 5000)
    {
        using var cts = new CancellationTokenSource(timeoutMs);
        try
        {
            var body = new
            {
                model = _model,
                messages = new[]
                {
                    new { role = "system", content = "Reply with OK." },
                    new { role = "user", content = "Health check" }
                }
            };

            using var content = new StringContent(JsonSerializer.Serialize(body), Encoding.UTF8, "application/json");
            using var resp = await _http.PostAsync(Endpoint, content, cts.Token);
            resp.EnsureSuccessStatusCode();
            return true;
        }
        catch
        {
            return false;
        }
    }

    public async Task<ChecklistResult?> EvaluateAsync(ChecklistItem item, string connectionString, CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(connectionString)) return null;

        var stopwatch = Stopwatch.StartNew();

        var sqlSnapshot = await GetSqlSnapshotAsync(
            SnapshotKeyFromConnectionString(connectionString),
            token => CollectSqlSnapshotAsync(connectionString, token),
            cancellationToken);
        if (string.IsNullOrWhiteSpace(sqlSnapshot))
        {
            return null;
        }

        var prompt = BuildPrompt(item, sqlSnapshot, ExtractServerName(connectionString));
        var provider = await CallProviderAsync(prompt, cancellationToken);
        if (provider == null || string.IsNullOrWhiteSpace(provider.Content))
        {
            return null;
        }

        var parsed = ParseProviderResponse(provider.Content);

        if (!parsed.Feasible)
        {
            return null;
        }

        stopwatch.Stop();
        return BuildResult(item, parsed, provider.Content, stopwatch.ElapsedMilliseconds);
    }

    public async Task<ChecklistResult?> EvaluateAsync(ChecklistItem item, SqlConnection connection, CancellationToken cancellationToken = default)
    {
        if (connection == null) return null;
        if (connection.State != System.Data.ConnectionState.Open) return null;

        var stopwatch = Stopwatch.StartNew();

        var sqlSnapshot = await GetSqlSnapshotAsync(
            BuildSnapshotKey(connection.DataSource, connection.Database),
            token => CollectSqlSnapshotAsync(connection, token),
            cancellationToken);
        if (string.IsNullOrWhiteSpace(sqlSnapshot))
        {
            return null;
        }

        var prompt = BuildPrompt(item, sqlSnapshot, connection.DataSource ?? string.Empty);
        var provider = await CallProviderAsync(prompt, cancellationToken);
        if (provider == null || string.IsNullOrWhiteSpace(provider.Content))
        {
            return null;
        }

        var parsed = ParseProviderResponse(provider.Content);

        if (!parsed.Feasible)
        {
            return null;
        }

        stopwatch.Stop();
        return BuildResult(item, parsed, provider.Content, stopwatch.ElapsedMilliseconds);
    }

    /// <summary>
    /// Turns a feasible MCP response into the persisted result. Returns null when the response
    /// carries no resolvable verdict, which hands the item to the manual pipeline.
    /// </summary>
    private static ChecklistResult? BuildResult(ChecklistItem item, ParsedMcpResponse parsed, string rawContent, long elapsedMs)
    {
        var evidence = string.IsNullOrWhiteSpace(parsed.Evidence)
            ? rawContent
            : parsed.Evidence;

        var outcome = ResolveOutcome(parsed, evidence);
        if (outcome == null)
        {
            return null;
        }

        // The snapshot held no supporting artefact for this item, so the control does not exist
        // to be assessed rather than being implemented ineffectively. The item is reported as
        // Not Applicable and carries no weight in any score, exactly as a script-evaluated item
        // whose enrichment declares it not applicable.
        var notApplicable = NotApplicableEvidence.IsNotApplicableOutcome(outcome);

        return new ChecklistResult(item.Id, item.Description, item.Verification, outcome, evidence, item.ScriptFile, "AI-MCP")
        {
            RawAttribute = parsed.RawAttribute,
            // RawOutput = provider.RawOutput,
            // McpTokensUsed = provider.TotalTokens,
            McpUsage = "Yes",
            McpExecutionTimeMs = elapsedMs,
            McpEvidence = evidence,
            Score = notApplicable ? null : parsed.Score,
            // ImplementationStatus = parsed.ImplementationStatus ?? string.Empty,
            Severity = notApplicable
                ? ChecklistResultEnricher.DeriveSeverity(item.Id, null, isNotApplicable: true)
                : (parsed.Severity ?? string.Empty),
            Finding = parsed.Finding ?? string.Empty,
            Recommendation = notApplicable ? null : parsed.Recommendation,
            Effort = notApplicable ? null : (parsed.Effort ?? string.Empty),
            RiskImpact = parsed.RiskImpact ?? string.Empty,
            NotApplicable = notApplicable ? true : null,
            // ScoreImpact = parsed.ScoreImpact
        };
    }

    /// <summary>
    /// The verdict for a feasible MCP evaluation. 'Not Applicable' wins over everything else:
    /// the snapshot held nothing to assess, so there is no Pass or Fail to give. 'Pass' and
    /// 'Fail' are otherwise honoured as given; a hedged 'NeedsReview' is resolved from the score
    /// the same response already carries, because no workflow can resolve a NeedsReview on an
    /// AI-MCP item. Returns null when there is no score to fall back on, which hands the item to
    /// the manual pipeline where a human can actually decide it.
    /// </summary>
    private static string? ResolveOutcome(ParsedMcpResponse parsed, string evidence)
    {
        if (NotApplicableEvidence.IsNotApplicableOutcome(parsed.Outcome)
            || NotApplicableEvidence.IsMarked(evidence))
        {
            return NotApplicableEvidence.Outcome;
        }
        if (parsed.Outcome is "Pass" or "Fail") return parsed.Outcome;
        if (parsed.Score.HasValue) return parsed.Score.Value >= PassScore ? "Pass" : "Fail";
        return null;
    }

    private async Task<ProviderCallResult?> CallProviderAsync(string prompt, CancellationToken cancellationToken)
    {
        var systemPrompt = PromptTemplateStore.Load("mcp_system_prompt.txt");
        return await CallProviderAsync(systemPrompt, prompt, cancellationToken);
    }

    private async Task<ProviderCallResult?> CallProviderAsync(string systemPrompt, string prompt, CancellationToken cancellationToken)
    {
        var strictBody = new
        {
            model = _model,
            temperature = 0,
            top_p = 1,
            response_format = new { type = "json_object" },
            messages = new[]
            {
                new { role = "system", content = systemPrompt },
                new { role = "user", content = prompt }
            }
        };

        using var strictResp = await PostWithRetryAsync(strictBody, cancellationToken);

        HttpResponseMessage? fallbackResp = null;
        try
        {
            var resp = strictResp;
            if (!strictResp.IsSuccessStatusCode && (int)strictResp.StatusCode is 400 or 422)
            {
                var fallbackBody = new
                {
                    model = _model,
                    temperature = 0,
                    top_p = 1,
                    messages = new[]
                    {
                        new { role = "system", content = systemPrompt },
                        new { role = "user", content = prompt }
                    }
                };

                fallbackResp = await PostWithRetryAsync(fallbackBody, cancellationToken);
                resp = fallbackResp;
            }

            resp.EnsureSuccessStatusCode();

            var txt = await resp.Content.ReadAsStringAsync(cancellationToken);
            using var doc = JsonDocument.Parse(txt);
            if (!doc.RootElement.TryGetProperty("choices", out var choices) || choices.GetArrayLength() == 0)
            {
                return null;
            }

            var content = choices[0].GetProperty("message").GetProperty("content").GetString() ?? string.Empty;
            // var totalTokens = TryExtractTotalTokens(doc.RootElement);
            return new ProviderCallResult(content);
        }
        finally
        {
            fallbackResp?.Dispose();
        }
    }

    /// <summary>
    /// Both evaluation stages call the provider at once, so a throttled or briefly unavailable
    /// endpoint is retried. Without this a transient 429 would surface as "MCP declined" and
    /// silently demote a decidable item to manual review.
    /// </summary>
    private async Task<HttpResponseMessage> PostWithRetryAsync(object body, CancellationToken cancellationToken)
    {
        for (var attempt = 1; ; attempt++)
        {
            using var content = new StringContent(JsonSerializer.Serialize(body), Encoding.UTF8, "application/json");
            var response = await _http.PostAsync(Endpoint, content, cancellationToken);

            if (response.IsSuccessStatusCode
                || !IsTransientFailure((int)response.StatusCode)
                || attempt >= MaxProviderAttempts)
            {
                return response;
            }

            var backoff = response.Headers.RetryAfter?.Delta
                ?? TimeSpan.FromMilliseconds(500 * Math.Pow(2, attempt - 1));

            // A hostile or very large Retry-After would otherwise park a worker indefinitely, and
            // the jitter stops parallel workers from retrying a shared 429 in lockstep.
            if (backoff < TimeSpan.Zero) backoff = TimeSpan.Zero;
            if (backoff > MaxProviderBackoff) backoff = MaxProviderBackoff;
            backoff += TimeSpan.FromMilliseconds(Random.Shared.Next(50, 250));

            response.Dispose();
            await Task.Delay(backoff, cancellationToken);
        }
    }

    private static bool IsTransientFailure(int statusCode) =>
        statusCode is 429 or 502 or 503 or 504;

    // private static int TryExtractTotalTokens(JsonElement root)
    // {
    //     if (!root.TryGetProperty("usage", out var usage))
    //     {
    //         return 0;
    //     }

    //     if (TryReadInt(usage, "total_tokens", out var total) || TryReadInt(usage, "totalTokens", out total))
    //     {
    //         return Math.Max(total, 0);
    //     }

    //     var hasInput = TryReadInt(usage, "prompt_tokens", out var prompt)
    //         || TryReadInt(usage, "input_tokens", out prompt)
    //         || TryReadInt(usage, "promptTokens", out prompt)
    //         || TryReadInt(usage, "inputTokens", out prompt);

    //     var hasOutput = TryReadInt(usage, "completion_tokens", out var completion)
    //         || TryReadInt(usage, "output_tokens", out completion)
    //         || TryReadInt(usage, "completionTokens", out completion)
    //         || TryReadInt(usage, "outputTokens", out completion);

    //     if (hasInput || hasOutput)
    //     {
    //         return Math.Max(prompt, 0) + Math.Max(completion, 0);
    //     }

    //     return 0;
    // }

    // private static bool TryReadInt(JsonElement parent, string propertyName, out int value)
    // {
    //     value = 0;
    //     if (!parent.TryGetProperty(propertyName, out var prop))
    //     {
    //         return false;
    //     }

    //     if (prop.ValueKind == JsonValueKind.Number && prop.TryGetInt32(out var i))
    //     {
    //         value = i;
    //         return true;
    //     }

    //     if (prop.ValueKind == JsonValueKind.String && int.TryParse(prop.GetString(), out i))
    //     {
    //         value = i;
    //         return true;
    //     }

    //     return false;
    // }

    private sealed record ParsedMcpResponse(
        string Outcome,
        string Evidence,
        bool Feasible,
        JsonElement? RawAttribute,
        string Notes,
        int? Score,
        // string? ImplementationStatus,
        string? Severity,
        string? Finding,
        string? Recommendation,
        string? Effort,
        string? RiskImpact
        // double? ScoreImpact
        );

    private static ParsedMcpResponse ParseProviderResponse(string raw)
    {
        var cleaned = raw.Trim();

        try
        {
            using var doc = JsonDocument.Parse(cleaned);
            var root = doc.RootElement;
            var outcomeRaw = root.TryGetProperty("outcome", out var o) ? o.GetString() ?? string.Empty : string.Empty;
            var evidence = root.TryGetProperty("evidence", out var e) ? e.GetString() ?? string.Empty : string.Empty;
            var feasible = root.TryGetProperty("feasible", out var f)
                ? f.ValueKind == JsonValueKind.True || (f.ValueKind == JsonValueKind.String && bool.TryParse(f.GetString(), out var b) && b)
                : true;
            var reasoning = root.TryGetProperty("reasoning", out var r) ? r.GetString() ?? string.Empty : string.Empty;

            return new ParsedMcpResponse(
                NormalizeOutcome(outcomeRaw),
                evidence,
                feasible,
                root.Clone(),
                reasoning,
                ReadOptionalInt(root, "score"),
                // ReadOptionalString(root, "implementationStatus"),
                ReadOptionalString(root, "severity"),
                ReadOptionalString(root, "finding"),
                ReadOptionalString(root, "recommendation"),
                ReadOptionalString(root, "effort"),
                ReadOptionalString(root, "riskImpact")
                // ReadOptionalDouble(root, "scoreImpact")
                );
        }
        catch
        {
            var outcome = NormalizeOutcome(cleaned);
            var feasibleText = !Regex.IsMatch(cleaned, "not feasible|cannot determine|insufficient evidence|manual review required", RegexOptions.IgnoreCase);
            return new ParsedMcpResponse(
                outcome,
                cleaned,
                feasibleText,
                null,
                feasibleText ? string.Empty : "Not feasible for MCP",
                null, null, null, null, null, null);
        }
    }

    private static string? ReadOptionalString(JsonElement root, string name)
    {
        if (root.TryGetProperty(name, out var el) && el.ValueKind == JsonValueKind.String)
        {
            var value = el.GetString();
            return string.IsNullOrWhiteSpace(value) ? null : value;
        }
        return null;
    }

    private static int? ReadOptionalInt(JsonElement root, string name)
    {
        if (!root.TryGetProperty(name, out var el)) return null;
        if (el.ValueKind == JsonValueKind.Number && el.TryGetInt32(out var i)) return i;
        if (el.ValueKind == JsonValueKind.String && int.TryParse(el.GetString(), out i)) return i;
        return null;
    }

    // private static double? ReadOptionalDouble(JsonElement root, string name)
    // {
    //     if (!root.TryGetProperty(name, out var el)) return null;
    //     if (el.ValueKind == JsonValueKind.Number && el.TryGetDouble(out var d)) return d;
    //     if (el.ValueKind == JsonValueKind.String && double.TryParse(el.GetString(), System.Globalization.NumberStyles.Any, System.Globalization.CultureInfo.InvariantCulture, out d)) return d;
    //     return null;
    // }

    private static string NormalizeOutcome(string raw)
    {
        // Checked first so a "not applicable" verdict is never mistaken for a hedge.
        if (Regex.IsMatch(raw, "not[\\s_-]*applicable", RegexOptions.IgnoreCase)) return NotApplicableEvidence.Outcome;
        if (Regex.IsMatch(raw, "\\bpass(?:ed)?\\b", RegexOptions.IgnoreCase)) return "Pass";
        if (Regex.IsMatch(raw, "\\bfail(?:ed)?\\b", RegexOptions.IgnoreCase)) return "Fail";
        return "NeedsReview";
    }

    // The template puts the run-constant server name and snapshot ahead of the per-item text so
    // every item after the first shares the same prompt prefix and can hit the provider's prefix
    // cache. Keep that ordering when editing mcp_user_prompt.txt.
    private static string BuildPrompt(ChecklistItem item, string sqlSnapshot, string sqlServerName)
    {
        return PromptTemplateStore.Render(
            "mcp_user_prompt.txt",
            new Dictionary<string, string>
            {
                ["CHECKLIST_ITEM_ID"] = item.Id,
                ["CHECKLIST_ITEM_DESCRIPTION"] = item.Description,
                ["CHECKLIST_ITEM_VERIFICATION"] = item.Verification,
                ["SQL_SERVER_NAME"] = sqlServerName,
                ["SQL_SNAPSHOT"] = sqlSnapshot
            });
    }

    private static string ExtractServerName(string connectionString)
    {
        try
        {
            using var conn = new SqlConnection(connectionString);
            return conn.DataSource ?? string.Empty;
        }
        catch
        {
            return string.Empty;
        }
    }

    private static async Task<string> CollectSqlSnapshotAsync(string connectionString, CancellationToken cancellationToken)
    {
        try
        {
            var sb = new StringBuilder();
            using var conn = new SqlConnection(connectionString);
            await conn.OpenAsync(cancellationToken);

            await AppendCommonSnapshotAsync(conn, sb, cancellationToken);

            return sb.ToString();
        }
        catch
        {
            return string.Empty;
        }
    }

    private static async Task<string> CollectSqlSnapshotAsync(SqlConnection conn, CancellationToken cancellationToken)
    {
        try
        {
            var sb = new StringBuilder();

            await AppendCommonSnapshotAsync(conn, sb, cancellationToken);

            return sb.ToString();
        }
        catch
        {
            return string.Empty;
        }
    }

    private static async Task AppendCommonSnapshotAsync(SqlConnection conn, StringBuilder sb, CancellationToken cancellationToken)
    {
        await AppendSingleRowAsync(conn,
            "SELECT @@SERVERNAME AS ServerName, @@VERSION AS SqlVersion, DB_NAME() AS CurrentDb, SUSER_SNAME() AS CurrentLogin",
            sb,
            cancellationToken);

        await AppendSingleRowAsync(conn,
            "SELECT COUNT(*) AS DatabaseCount FROM sys.databases",
            sb,
            cancellationToken);

        await AppendSingleRowAsync(conn,
            "SELECT CAST(value_in_use AS nvarchar(50)) AS IsAuditLevelEnabled FROM sys.configurations WHERE name = 'default trace enabled'",
            sb,
            cancellationToken);

        sb.AppendLine("UserDbMetadataSummary:");
        await AppendResultSetAsync(conn,
            @"IF OBJECT_ID('tempdb..#AuditMeta') IS NOT NULL DROP TABLE #AuditMeta;
CREATE TABLE #AuditMeta
(
    DbName sysname NOT NULL,
    ProcCount int NULL,
    FuncCount int NULL,
    ViewCount int NULL,
    TryCatchModules int NULL,
    ThrowOrRaiseErrorModules int NULL,
    NoCountModules int NULL,
    CursorOrWhileModules int NULL,
    DeprecatedTypeColumns int NULL
);

DECLARE @db sysname, @sql nvarchar(max);
DECLARE dbcur CURSOR LOCAL FAST_FORWARD FOR
SELECT name
FROM sys.databases
WHERE database_id > 4 AND state = 0;

OPEN dbcur;
FETCH NEXT FROM dbcur INTO @db;
WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        SET @sql = N'USE ' + QUOTENAME(@db) + N';
INSERT INTO #AuditMeta
SELECT
    DB_NAME(),
    (SELECT COUNT(*) FROM sys.procedures WHERE is_ms_shipped = 0),
    (SELECT COUNT(*) FROM sys.objects WHERE is_ms_shipped = 0 AND type IN (''FN'',''IF'',''TF'')),
    (SELECT COUNT(*) FROM sys.views WHERE is_ms_shipped = 0),
    (SELECT COUNT(*) FROM sys.sql_modules m JOIN sys.objects o ON m.object_id = o.object_id WHERE o.is_ms_shipped = 0 AND m.definition LIKE ''%TRY%'' AND m.definition LIKE ''%CATCH%''),
    (SELECT COUNT(*) FROM sys.sql_modules m JOIN sys.objects o ON m.object_id = o.object_id WHERE o.is_ms_shipped = 0 AND (m.definition LIKE ''%THROW%'' OR m.definition LIKE ''%RAISERROR%'')),
    (SELECT COUNT(*) FROM sys.sql_modules m JOIN sys.objects o ON m.object_id = o.object_id WHERE o.is_ms_shipped = 0 AND m.definition LIKE ''%SET NOCOUNT ON%''),
    (SELECT COUNT(*) FROM sys.sql_modules m JOIN sys.objects o ON m.object_id = o.object_id WHERE o.is_ms_shipped = 0 AND (m.definition LIKE ''%CURSOR%'' OR m.definition LIKE ''%WHILE%'')),
    (SELECT COUNT(*) FROM sys.columns c JOIN sys.types t ON c.user_type_id = t.user_type_id WHERE t.name IN (''text'',''ntext'',''image''));';
        EXEC sys.sp_executesql @sql;
    END TRY
    BEGIN CATCH
        INSERT INTO #AuditMeta(DbName) VALUES (@db);
    END CATCH;

    FETCH NEXT FROM dbcur INTO @db;
END

CLOSE dbcur;
DEALLOCATE dbcur;

SELECT TOP (25)
    DbName,
    ProcCount,
    FuncCount,
    ViewCount,
    TryCatchModules,
    ThrowOrRaiseErrorModules,
    NoCountModules,
    CursorOrWhileModules,
    DeprecatedTypeColumns
FROM #AuditMeta
ORDER BY DbName;",
            sb,
            cancellationToken,
            maxRows: 25);
        sb.AppendLine();
    }

    private static async Task AppendResultSetAsync(SqlConnection conn, string sql, StringBuilder sb, CancellationToken cancellationToken, int maxRows = 25)
    {
        using var cmd = new SqlCommand(sql, conn) { CommandTimeout = 60 };
        using var rdr = await cmd.ExecuteReaderAsync(cancellationToken);

        var row = 0;
        while (await rdr.ReadAsync(cancellationToken) && row < maxRows)
        {
            // The snapshot is re-sent with every checklist item, so the column names are written
            // once as a header rather than repeated on each row.
            if (row == 0)
            {
                var names = new List<string>(rdr.FieldCount);
                for (int i = 0; i < rdr.FieldCount; i++) names.Add(rdr.GetName(i));
                sb.AppendLine("columns: " + string.Join(" | ", names));
            }

            var cols = new List<string>(rdr.FieldCount);
            for (int i = 0; i < rdr.FieldCount; i++)
            {
                cols.Add(rdr.IsDBNull(i) ? "NULL" : CompactValue(rdr.GetValue(i)));
            }

            sb.AppendLine(string.Join(" | ", cols));
            row++;
        }

        while (await rdr.NextResultAsync(cancellationToken))
        {
            // consume all results
        }
        await rdr.CloseAsync();
    }

    private static async Task AppendSingleRowAsync(SqlConnection conn, string sql, StringBuilder sb, CancellationToken cancellationToken)
    {
        using var cmd = new SqlCommand(sql, conn) { CommandTimeout = 30 };
        using var rdr = await cmd.ExecuteReaderAsync(cancellationToken);
        if (!await rdr.ReadAsync(cancellationToken))
        {
            await rdr.CloseAsync();
            return;
        }

        for (int i = 0; i < rdr.FieldCount; i++)
        {
            var key = rdr.GetName(i);
            var value = rdr.IsDBNull(i) ? "NULL" : CompactValue(rdr.GetValue(i));
            sb.AppendLine($"{key}: {value}");
        }

        sb.AppendLine();
        await rdr.CloseAsync();
    }

    /// <summary>
    /// Flattens a snapshot value onto one line. Multi-line banners such as @@VERSION otherwise
    /// carry newlines and tab runs into every per-item prompt without adding information.
    /// </summary>
    private static string CompactValue(object? value)
    {
        var text = Convert.ToString(value) ?? string.Empty;
        return Regex.Replace(text, "\\s+", " ").Trim();
    }
}
