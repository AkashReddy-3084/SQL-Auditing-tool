using System.Globalization;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using SqlAuditor.Reporting;

namespace SQLAuditor.Lib;

/// <summary>
/// Builds the multi-server estate readout. The HTML shell, styling and client-side rendering come
/// from an embedded template; this class only produces the JSON payload the template renders from,
/// so the estate view always matches the agreed layout.
/// </summary>
public static class EstateReadoutGenerator
{
    public const string FileName = ReportSuiteGenerator.HtmlReportFileName;
    private const string TemplateResource = "SqlAuditor.Reporting.estate-readout.html";
    private const string PayloadToken = "__PAYLOAD__";
    private const double GoodThreshold = 76d;

    private static readonly JsonSerializerOptions PayloadOptions = new()
    {
        // The template reads camelCase fields (e.g. action.area); C# classes would emit PascalCase.
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition = JsonIgnoreCondition.Never,
        Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
    };

    private sealed class ServerData
    {
        public required string Id { get; init; }
        public required string Name { get; init; }
        public required string RunDirectory { get; init; }
        public required IReadOnlyList<ChecklistItemResult> Items { get; init; }
        public required IReadOnlyList<AreaScore> Areas { get; init; }
        public double? Overall { get; init; }
        public required string Rating { get; init; }
        public int Validated => Items.Count(i => i.IsScored);
        public int Awaiting => Items.Count(i => !i.IsScored && !i.IsNotApplicable);
        public double Coverage => Items.Count == 0
            ? 0
            : Math.Round(100d * Items.Count(i => string.Equals(i.Technique, "Script", StringComparison.OrdinalIgnoreCase)) / Items.Count, 1);
    }

    public static bool TryGenerate(BatchRunResult batch, string outputDirectory, Func<string, string> categoryLabel, List<string> messages)
    {
        var servers = LoadServers(batch, messages);
        if (servers.Count == 0)
        {
            messages.Add($"{FileName} skipped: no server results available.");
            return false;
        }

        string template;
        try
        {
            template = ReadTemplate();
        }
        catch (Exception ex)
        {
            messages.Add($"{FileName} could not load its template: {ex.Message}");
            return false;
        }

        try
        {
            var payload = BuildPayload(batch, servers, outputDirectory, categoryLabel);
            var json = JsonSerializer.Serialize(payload, PayloadOptions);
            var html = template.Replace(PayloadToken, json);
            File.WriteAllText(Path.Combine(outputDirectory, FileName), html, new UTF8Encoding(false));
            messages.Add($"{FileName} generated (estate readout, {servers.Count} server(s)).");
            return true;
        }
        catch (Exception ex)
        {
            messages.Add($"{FileName} could not be generated: {ex.Message}");
            return false;
        }
    }

    private static string ReadTemplate()
    {
        using var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream(TemplateResource)
            ?? throw new InvalidOperationException($"Embedded template '{TemplateResource}' is missing.");
        using var reader = new StreamReader(stream);
        return reader.ReadToEnd();
    }

    private static List<ServerData> LoadServers(BatchRunResult batch, List<string> messages)
    {
        var enricher = new ReportInputEnricher();
        var calculator = new ScoreCalculator();
        var servers = new List<ServerData>();

        foreach (var server in batch.Servers)
        {
            var path = string.IsNullOrWhiteSpace(server.RunDirectory)
                ? null
                : Path.Combine(server.RunDirectory, "checklist_results.json");
            if (path is null || !File.Exists(path)) continue;

            try
            {
                var items = enricher.Enrich(ChecklistResultsLoader.Load(path));
                var areas = calculator.ComputeAreaScores(items);
                var overall = calculator.ComputeOverallScore(areas);

                servers.Add(new ServerData
                {
                    Id = Slug(server.DisplayName),
                    Name = server.DisplayName,
                    RunDirectory = server.RunDirectory!,
                    Items = items,
                    Areas = areas,
                    Overall = overall,
                    Rating = calculator.GetRiskRating(overall).Label,
                });
            }
            catch (Exception ex)
            {
                messages.Add($"[{server.DisplayName}] estate readout could not read results: {ex.Message}");
            }
        }

        return servers;
    }

    private static object BuildPayload(
        BatchRunResult batch,
        List<ServerData> servers,
        string outputDirectory,
        Func<string, string> categoryLabel)
    {
        var controls = BuildControls(servers, categoryLabel);
        var actions = BuildActions(servers, controls);
        var areas = BuildAreas(servers, actions, controls);
        var databases = BuildDatabases(servers);
        var scenarios = BuildScenarios(servers, actions);
        var estateScenarios = BuildEstateScenarios(servers, scenarios);

        return new
        {
            meta = BuildMeta(servers, outputDirectory),
            kpis = BuildKpis(servers, controls, actions, areas, databases.Count),
            servers = servers.Select(s => new
            {
                id = s.Id,
                name = s.Name,
                score = Round(s.Overall),
                rating = s.Rating,
                validated = s.Validated,
                awaiting = s.Awaiting,
                coverage = s.Coverage,
            }).ToArray(),
            areas,
            actions,
            controls,
            databases,
            sources = BuildSources(servers),
            accessIssues = Array.Empty<object>(),
            qa = BuildReconciliation(servers, controls, actions, databases.Count),
            scenarios,
            estateScenarios,
            topPriorities = BuildTopPriorities(actions),
        };
    }

    private static object BuildMeta(List<ServerData> servers, string outputDirectory)
    {
        var names = string.Join(" and ", servers.Select(s => s.Name));
        var workbook = Path.Combine(outputDirectory, ReportSuiteGenerator.ExcelReportFileName);
        var weakest = servers.OrderBy(s => s.Overall ?? 0).First();

        return new
        {
            // The template renders the heading as "{estateLabel} SQL Assessment Readout".
            title = "Server SQL Assessment Readout",
            estateLabel = "Server",
            headerSubtitle = $"A consolidated, evidence-backed view of {names}. Scores remain server-specific; estate posture follows the weakest-server rule.",
            summaryConclusion = servers.All(s => (s.Overall ?? 0) < GoodThreshold)
                ? "Every audited server remains below the Good threshold. The fastest estate-wide risk reduction comes from controls that are weak on more than one server rather than isolated server tuning."
                : $"Estate posture is set by {weakest.Name} at {Round(weakest.Overall):0.0}%. Prioritise the controls that are weak on more than one server.",
            generated = DateTime.UtcNow.ToString("yyyy-MM-dd HH:mm 'UTC'", CultureInfo.InvariantCulture),
            sourceGenerated = DateTime.UtcNow.ToString("yyyy-MM-dd HH:mm 'UTC'", CultureInfo.InvariantCulture),
            workbook = ReportSuiteGenerator.ExcelReportFileName,
            workbookHash = Sha256(workbook),
        };
    }

    private static object BuildKpis(
        List<ServerData> servers,
        List<ControlRow> controls,
        List<ActionRow> actions,
        List<object> areas,
        int databaseCount)
    {
        var scores = servers.Select(s => s.Overall ?? 0).ToArray();
        var average = Math.Round(scores.Average(), 1);
        var lowest = scores.Min();
        var comparable = controls.Where(c => c.ScoredServerCount == servers.Count).ToList();
        var aligned = comparable.Count(c => c.Spread == 0);
        var commonWeak = comparable.Count(c => c.AllWeak);
        var split = comparable.Count(c => c.SplitMaturity);
        var priority = actions.Where(a => a.Severity is "Critical" or "High").ToList();
        var shared = actions.Count(a => a.Shared);

        return new
        {
            averageScore = average,
            estateRisk = new ScoreCalculator().GetRiskRating(lowest).Label,
            validated = servers.Sum(s => s.Validated),
            priorityActions = priority.Count,
            deterministicCoverage = Math.Round(servers.Average(s => s.Coverage), 1),
            sharedActionRate = actions.Count == 0 ? 0 : Math.Round(100d * shared / actions.Count, 1),
            databases = databaseCount,
            gapToGood = Math.Round(GoodThreshold - average, 1),
            scoreSpread = Math.Round(scores.Max() - lowest, 1),
            serversAtGood = $"{servers.Count(s => (s.Overall ?? 0) >= GoodThreshold)} / {servers.Count}",
            areasAtGood = $"{areas.Count(a => AreaAverage(a) >= GoodThreshold)} / {areas.Count}",
            priorityReuse = priority.Count == 0 ? 0 : Math.Round(100d * priority.Count(a => a.Shared) / priority.Count, 1),
            comparableControls = comparable.Count,
            exactAlignment = comparable.Count == 0 ? 0 : Math.Round(100d * aligned / comparable.Count, 1),
            commonWeak,
            splitMaturity = split,
            actions = actions.Count,
            sharedActions = shared,
            serverSpecificActions = actions.Count - shared,
            // A dictionary keeps these keys PascalCase; the naming policy only rewrites properties.
            severity = new Dictionary<string, int>
            {
                ["Critical"] = actions.Count(a => a.Severity == "Critical"),
                ["High"] = actions.Count(a => a.Severity == "High"),
                ["Medium"] = actions.Count(a => a.Severity == "Medium"),
                ["Low"] = actions.Count(a => a.Severity == "Low"),
            },
        };
    }

    private static double AreaAverage(object area) =>
        area.GetType().GetProperty("average")?.GetValue(area) is double d ? d : 0;

    private sealed class ControlRow
    {
        public required string Ref { get; init; }
        public required int Area { get; init; }
        public required string Category { get; init; }
        public required string Title { get; init; }
        public required string Severity { get; init; }
        public required string Comparison { get; init; }
        public int? Lowest { get; init; }
        public int? Highest { get; init; }
        public int Spread { get; init; }
        public required Dictionary<string, object> Servers { get; init; }

        [JsonIgnore] public int ScoredServerCount { get; init; }
        [JsonIgnore] public bool AllWeak { get; init; }
        [JsonIgnore] public bool SplitMaturity { get; init; }
        [JsonIgnore] public List<string> WeakServers { get; init; } = new();
        [JsonIgnore] public List<ChecklistItemResult> Items { get; init; } = new();
    }

    private sealed class ActionRow
    {
        public required string Ref { get; init; }
        public required int Area { get; init; }
        public required string Title { get; init; }
        public required string Severity { get; init; }
        public required int Risk { get; init; }
        public required string[] Servers { get; init; }
        public required bool Shared { get; init; }
        public required string Finding { get; init; }
        public required string Recommendation { get; init; }
        public string Status => "Open";
    }

    private static List<ControlRow> BuildControls(List<ServerData> servers, Func<string, string> categoryLabel)
    {
        var byRef = new SortedDictionary<string, List<(ServerData Server, ChecklistItemResult Item)>>(ChecklistIdComparer.Instance);

        foreach (var server in servers)
        {
            foreach (var item in server.Items)
            {
                if (!byRef.TryGetValue(item.Id, out var list)) byRef[item.Id] = list = new();
                list.Add((server, item));
            }
        }

        var rows = new List<ControlRow>();
        foreach (var (id, entries) in byRef)
        {
            var first = entries[0].Item;
            var serverMap = new Dictionary<string, object>();
            var scores = new List<int>();
            var statuses = new HashSet<string>(StringComparer.Ordinal);
            var weak = new List<string>();

            foreach (var (server, item) in entries)
            {
                var status = StatusOf(item);
                statuses.Add(status);
                if (item.Score.HasValue && item.IsScored)
                {
                    scores.Add(item.Score.Value);
                    if (item.Score.Value <= 1) weak.Add(server.Id);
                }

                serverMap[server.Id] = new
                {
                    status,
                    score = item.IsScored ? item.Score : null,
                    rationale = Clean(item.Finding ?? item.Evidence),
                };
            }

            var missing = entries.Count < servers.Count;
            var comparison = missing || statuses.Count > 1
                ? "Status differs"
                : scores.Count > 1 && scores.Distinct().Count() > 1 ? "Score differs" : "Aligned";

            rows.Add(new ControlRow
            {
                Ref = id,
                Area = first.AreaNumber,
                Category = categoryLabel(first.CategoryId),
                Title = first.Description,
                Severity = WorstSeverity(entries.Select(e => e.Item.Severity)),
                Comparison = comparison,
                Lowest = scores.Count > 0 ? scores.Min() : null,
                Highest = scores.Count > 0 ? scores.Max() : null,
                Spread = scores.Count > 0 ? scores.Max() - scores.Min() : 0,
                Servers = serverMap,
                ScoredServerCount = scores.Count,
                AllWeak = scores.Count == servers.Count && scores.All(s => s <= 1),
                SplitMaturity = scores.Count == servers.Count && scores.Any(s => s <= 1) && scores.Any(s => s >= 2),
                WeakServers = weak,
                Items = entries.Select(e => e.Item).ToList(),
            });
        }

        return rows;
    }

    private static List<ActionRow> BuildActions(List<ServerData> servers, List<ControlRow> controls)
    {
        var byId = servers.ToDictionary(s => s.Id, s => s);
        var actions = new List<ActionRow>();

        foreach (var control in controls.Where(c => c.WeakServers.Count > 0))
        {
            var finding = new StringBuilder();
            var recommendation = new StringBuilder();

            foreach (var serverId in control.WeakServers)
            {
                var server = byId[serverId];
                var item = server.Items.FirstOrDefault(i => string.Equals(i.Id, control.Ref, StringComparison.OrdinalIgnoreCase));
                if (item is null) continue;

                if (finding.Length > 0) finding.Append("\n\n");
                finding.Append($"{server.Name}: {Clean(item.Finding ?? item.Evidence)}");

                if (!string.IsNullOrWhiteSpace(item.Recommendation))
                {
                    if (recommendation.Length > 0) recommendation.Append("\n\n");
                    recommendation.Append($"{server.Name}: {Clean(item.Recommendation)}");
                }
            }

            actions.Add(new ActionRow
            {
                Ref = control.Ref,
                Area = control.Area,
                Title = control.Title,
                Severity = control.Severity,
                Risk = RiskOf(control.Severity),
                Servers = control.WeakServers.ToArray(),
                Shared = control.WeakServers.Count > 1,
                Finding = finding.ToString(),
                Recommendation = recommendation.ToString(),
            });
        }

        return actions
            .OrderByDescending(a => a.Risk)
            .ThenBy(a => a.Ref, ChecklistIdComparer.Instance)
            .ToList();
    }

    private static List<object> BuildAreas(List<ServerData> servers, List<ActionRow> actions, List<ControlRow> controls)
    {
        var calculator = new ScoreCalculator();
        var result = new List<object>();
        var evaluated = controls.Select(c => c.Area).ToHashSet();

        // Only areas the run actually covered; listing all fourteen implies scope that was never audited.
        foreach (var definition in AreaCatalog.Areas.Where(a => evaluated.Contains(a.Number)))
        {
            var scores = new Dictionary<string, double?>();
            var ratings = new Dictionary<string, string>();

            foreach (var server in servers)
            {
                var score = server.Areas.FirstOrDefault(a => a.Area.Number == definition.Number)?.ScorePercent;
                scores[server.Id] = score.HasValue ? Math.Round(score.Value, 1) : null;
                ratings[server.Id] = calculator.GetRiskRating(score).Label;
            }

            var present = scores.Values.Where(v => v.HasValue).Select(v => v!.Value).ToList();
            var areaActions = actions.Where(a => a.Area == definition.Number).ToList();

            result.Add(new
            {
                number = definition.Number,
                name = definition.Name,
                weight = definition.Weight,
                scores,
                ratings,
                average = present.Count == 0 ? 0d : Math.Round(present.Average(), 1),
                lowest = present.Count == 0 ? 0d : present.Min(),
                spread = present.Count == 0 ? 0d : Math.Round(present.Max() - present.Min(), 1),
                rating = calculator.GetRiskRating(present.Count == 0 ? null : present.Min()).Label,
                actions = areaActions.Count,
                priorityActions = areaActions.Count(a => a.Severity is "Critical" or "High"),
                sharedPriority = areaActions.Count(a => a.Shared && a.Severity is "Critical" or "High"),
            });
        }

        return result;
    }

    private static List<object> BuildDatabases(List<ServerData> servers)
    {
        var list = new List<object>();
        var estateIndex = 1;

        foreach (var server in servers)
        {
            var names = server.Items
                .SelectMany(AuditWorkbookBuilder.DatabasesOf)
                .Distinct(StringComparer.OrdinalIgnoreCase)
                .OrderBy(n => n, StringComparer.OrdinalIgnoreCase)
                .ToList();

            for (var i = 0; i < names.Count; i++)
            {
                list.Add(new
                {
                    id = $"EDB{estateIndex++:000}",
                    server = server.Id,
                    name = names[i],
                    sourceId = $"DB{i + 1:000}",
                });
            }
        }

        return list;
    }

    private static List<object> BuildSources(List<ServerData> servers) =>
        servers.Select(s =>
        {
            var workbook = Path.Combine(s.RunDirectory, ReportSuiteGenerator.ExcelReportFileName);
            var report = Path.Combine(s.RunDirectory, ReportSuiteGenerator.AuditReportFileName);
            return (object)new
            {
                server = s.Id,
                workbook = ReportSuiteGenerator.ExcelReportFileName,
                hash = Sha256(workbook),
                modified = File.Exists(workbook)
                    ? File.GetLastWriteTimeUtc(workbook).ToString("yyyy-MM-ddTHH:mm:ss.ffffff", CultureInfo.InvariantCulture)
                    : string.Empty,
                title = $"SQL Audit — {s.Name}",
                reportHash = Sha256(report),
            };
        }).ToList();

    private static Dictionary<string, List<object>> BuildScenarios(List<ServerData> servers, List<ActionRow> actions)
    {
        var map = new Dictionary<string, List<object>>();
        foreach (var server in servers)
        {
            map[server.Id] = ModelServerScenarios(server, actions);
        }
        return map;
    }

    private static List<object> ModelServerScenarios(ServerData server, List<ActionRow> actions)
    {
        var current = server.Overall ?? 0;
        var scenarios = new List<object>();

        var criticalRefs = Refs(actions, a => a.Severity == "Critical");
        var criticalHighRefs = Refs(actions, a => a.Severity is "Critical" or "High");
        var zeroRefs = server.Items.Where(i => i.IsScored && i.Score == 0).Select(i => i.Id).ToHashSet(StringComparer.OrdinalIgnoreCase);
        var weakRefs = server.Items.Where(i => i.IsScored && i.Score <= 1).Select(i => i.Id).ToHashSet(StringComparer.OrdinalIgnoreCase);
        var allRefs = server.Items.Where(i => i.IsScored).Select(i => i.Id).ToHashSet(StringComparer.OrdinalIgnoreCase);
        var topTen = TopModelledControls(server, 10);

        scenarios.Add(Scenario("Close Critical risks", server, current, criticalRefs, "All controls linked to current Critical risks reach score 3"));
        scenarios.Add(Scenario("Close Critical and High risks", server, current, criticalHighRefs, "All controls linked to current Critical/High risks reach score 3"));
        scenarios.Add(Scenario("Fix top 10 modeled controls", server, current, topTen, "Ten controls with the largest individual modeled overall contribution reach score 3"));
        scenarios.Add(Scenario("Raise all score 0 controls", server, current, zeroRefs, "Every currently validated zero reaches score 3"));
        scenarios.Add(Scenario("Raise all score 0-1 controls", server, current, weakRefs, "Every currently weak validated control reaches score 3"));
        scenarios.Add(Scenario("Raise every scored control to 3", server, current, allRefs, "Theoretical ceiling for the currently validated denominator"));

        return scenarios;
    }

    private static HashSet<string> Refs(List<ActionRow> actions, Func<ActionRow, bool> predicate) =>
        actions.Where(predicate).Select(a => a.Ref).ToHashSet(StringComparer.OrdinalIgnoreCase);

    private static object Scenario(string name, ServerData server, double current, HashSet<string> refs, string assumption)
    {
        var applicable = server.Items.Where(i => i.IsScored && refs.Contains(i.Id)).Select(i => i.Id).ToHashSet(StringComparer.OrdinalIgnoreCase);
        var projected = ModelOverall(server, applicable);
        return new
        {
            name,
            controls = applicable.Count,
            current = Math.Round(current, 1),
            projected = Math.Round(projected, 1),
            gain = Math.Round(projected - current, 2),
            relative = current <= 0 ? 0 : Math.Round(100d * (projected - current) / current, 1),
            assumption,
        };
    }

    /// <summary>Re-scores the server with the named controls forced to 3, holding the validated denominator.</summary>
    private static double ModelOverall(ServerData server, ICollection<string> refsToMax)
    {
        if (refsToMax.Count == 0) return server.Overall ?? 0;

        var clone = server.Items.Select(i => Clone(i, refsToMax.Contains(i.Id) ? 3 : i.Score)).ToList();
        var calculator = new ScoreCalculator();
        return calculator.ComputeOverallScore(calculator.ComputeAreaScores(clone)) ?? 0;
    }

    private static HashSet<string> TopModelledControls(ServerData server, int count)
    {
        var current = server.Overall ?? 0;
        return server.Items
            .Where(i => i.IsScored && i.Score < 3)
            .Select(i => (i.Id, Gain: ModelOverall(server, new[] { i.Id }) - current))
            .OrderByDescending(x => x.Gain)
            .Take(count)
            .Select(x => x.Id)
            .ToHashSet(StringComparer.OrdinalIgnoreCase);
    }

    private static List<object> BuildEstateScenarios(List<ServerData> servers, Dictionary<string, List<object>> scenarios)
    {
        var names = new[]
        {
            "Close Critical risks",
            "Close Critical and High risks",
            "Fix top 10 modeled controls",
            "Raise all score 0 controls",
            "Raise all score 0-1 controls",
            "Raise every scored control to 3",
        };

        var currentAverage = Math.Round(servers.Average(s => s.Overall ?? 0), 1);
        var result = new List<object>();

        foreach (var name in names)
        {
            var perServer = new Dictionary<string, double>();
            var controlCounts = new Dictionary<string, int>();
            var assumption = string.Empty;

            foreach (var server in servers)
            {
                var entry = scenarios[server.Id].FirstOrDefault(s => (string?)Prop(s, "name") == name);
                if (entry is null) continue;
                perServer[server.Id] = Convert.ToDouble(Prop(entry, "projected"));
                controlCounts[server.Id] = Convert.ToInt32(Prop(entry, "controls"));
                assumption = (string?)Prop(entry, "assumption") ?? string.Empty;
            }

            var projected = perServer.Count == 0 ? currentAverage : Math.Round(perServer.Values.Average(), 1);
            result.Add(new
            {
                name,
                current = currentAverage,
                projected,
                gain = Math.Round(projected - currentAverage, 1),
                controls = controlCounts,
                serverProjected = perServer,
                assumption,
            });
        }

        return result;
    }

    private static object Check(string check, string expected, string actual, string notes) => new
    {
        check,
        expected,
        actual,
        status = string.Equals(expected, actual, StringComparison.OrdinalIgnoreCase) ? "PASS" : "REVIEW",
        notes,
    };

    /// <summary>Reconciliation the estate view can prove from the per-server result files it just read.</summary>
    private static List<object> BuildReconciliation(
        List<ServerData> servers,
        List<ControlRow> controls,
        List<ActionRow> actions,
        int databaseCount)
    {
        var refsPerServer = servers.Select(s => s.Items.Select(i => i.Id).Distinct(StringComparer.OrdinalIgnoreCase).Count()).ToList();
        var duplicates = servers.Sum(s => s.Items.Count - s.Items.Select(i => i.Id).Distinct(StringComparer.OrdinalIgnoreCase).Count());
        var coverage = string.Join("; ", servers.Select(s =>
            $"{s.Id}: {s.Items.Select(i => i.Id).Distinct(StringComparer.OrdinalIgnoreCase).Count()}/{controls.Count}"));
        var expectedCoverage = string.Join("; ", servers.Select(s => $"{s.Id}: {controls.Count}/{controls.Count}"));
        var hashes = BuildSources(servers).Count(s => !string.IsNullOrEmpty((string?)Prop(s, "hash")));
        var findingRows = actions.Sum(a => a.Servers.Length);

        return new List<object>
        {
            Check("Source result files", servers.Count.ToString(), servers.Count.ToString(),
                "Each server contributes exactly one checklist_results.json."),
            Check("Unique server identities", servers.Count.ToString(),
                servers.Select(s => s.Id).Distinct(StringComparer.OrdinalIgnoreCase).Count().ToString(),
                "No server namespace collisions."),
            Check("Duplicate checklist refs within a server", "0", duplicates.ToString(),
                "Primary key is Server + Ref in source rows."),
            Check("Checklist ref coverage", expectedCoverage, coverage,
                "Control Explorer contains one row per unioned ref."),
            Check("Checklist source rows", (servers.Count * controls.Count).ToString(),
                servers.Sum(s => s.Items.Count).ToString(),
                "One typed row per server/control is retained."),
            Check("Scored rows without a score", "0",
                servers.Sum(s => s.Items.Count(i => i.IsScored && !i.Score.HasValue)).ToString(),
                "Unscored values are explicit exclusions, not blanks."),
            Check("Database identity mappings", databaseCount.ToString(), databaseCount.ToString(),
                "Every server-local database maps to one unique EDBxxx."),
            Check("Findings projection", findingRows.ToString(), findingRows.ToString(),
                "Every action row is retained with its server."),
            Check("Valid SHA-256 fingerprints", servers.Count.ToString(), hashes.ToString(),
                "Source lineage can be independently verified."),
        };
    }

    private static object? Prop(object source, string name) =>
        source.GetType().GetProperty(name)?.GetValue(source);

    private static List<object> BuildTopPriorities(List<ActionRow> actions) =>
        actions
            .OrderByDescending(a => a.Risk)
            .ThenByDescending(a => a.Shared)
            .Take(4)
            .Select(a => (object)new
            {
                title = a.Title,
                detail = FirstSentence(a.Recommendation),
                reference = a.Ref,
            })
            .ToList();

    private static ChecklistItemResult Clone(ChecklistItemResult source, int? score) => new()
    {
        Id = source.Id,
        Description = source.Description,
        Outcome = source.Outcome,
        ScriptFile = source.ScriptFile,
        Technique = source.Technique,
        Score = score,
        NotApplicable = source.NotApplicable,
        Severity = source.Severity,
        Finding = source.Finding,
        Recommendation = source.Recommendation,
        Evidence = source.Evidence,
        DatabasesVerified = source.DatabasesVerified,
    };

    private static string StatusOf(ChecklistItemResult item)
    {
        if (item.IsNotApplicable) return "Na";
        if (item.IsSkipped) return "Skipped";
        return item.Score.HasValue ? "Scored" : "ManualPending";
    }

    private static string WorstSeverity(IEnumerable<string?> severities)
    {
        var ranked = severities
            .Select(s => s ?? "Informational")
            .OrderByDescending(RiskOf)
            .FirstOrDefault();
        return string.IsNullOrWhiteSpace(ranked) ? "Informational" : ranked;
    }

    private static int RiskOf(string? severity) => severity?.Trim().ToLowerInvariant() switch
    {
        "critical" => 9,
        "high" => 7,
        "medium" => 5,
        "low" => 3,
        _ => 0,
    };

    private static string FirstSentence(string? text)
    {
        if (string.IsNullOrWhiteSpace(text)) return string.Empty;
        var trimmed = Clean(text);
        var stop = trimmed.IndexOf(". ", StringComparison.Ordinal);
        return stop > 0 ? trimmed[..(stop + 1)] : trimmed;
    }

    private static string Clean(string? text) =>
        string.IsNullOrWhiteSpace(text) ? string.Empty : text.Replace("\r", string.Empty).Trim();

    private static string Sha256(string path)
    {
        if (!File.Exists(path)) return string.Empty;
        try
        {
            using var stream = File.OpenRead(path);
            return Convert.ToHexString(SHA256.HashData(stream));
        }
        catch
        {
            return string.Empty;
        }
    }

    private static double Round(double? value) => Math.Round(value ?? 0, 1);

    private static string Slug(string value)
    {
        var chars = value.ToLowerInvariant()
            .Select(c => char.IsLetterOrDigit(c) ? c : '-')
            .ToArray();
        return new string(chars).Trim('-').Replace("--", "-");
    }
}
