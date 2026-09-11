using System;
using System.Collections.Generic;
using System.IO;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Data.SqlClient;

namespace SQLAuditor.Lib
{
    /// <summary>Identity of the audited instance: platform, plus the gates that depend on it.</summary>
    /// <param name="EditionRank">SQL Server edition rank; <see cref="int.MaxValue"/> on Azure, where the gate does not apply.</param>
    /// <param name="VersionYear">SQL Server release year, 0 when unknown; ignored on Azure.</param>
    /// <param name="TierRank">0 for General Purpose / Standard / Basic, 1 for Business Critical / Premium / Hyperscale; <see cref="int.MaxValue"/> on SQL Server.</param>
    public sealed record PlatformProfile(
        string Platform,
        int EngineEdition,
        string EditionName,
        int EditionRank,
        int VersionYear,
        int TierRank)
    {
        public static readonly PlatformProfile Unknown =
            new(PlatformApplicability.PlatformUnknown, 0, "Unknown", int.MaxValue, 0, int.MaxValue);

        /// <summary>Human-readable identity used in banners and NA justifications.</summary>
        public string Display => Platform switch
        {
            PlatformApplicability.PlatformAzureSqlDb => "Azure SQL Database",
            PlatformApplicability.PlatformAzureSqlMi => "Azure SQL Managed Instance",
            PlatformApplicability.PlatformSqlServer => string.Join(" ", new[]
            {
                "SQL Server",
                VersionYear > 0 ? VersionYear.ToString() : null,
                string.IsNullOrWhiteSpace(EditionName) ? null : EditionName
            }.Where(p => !string.IsNullOrWhiteSpace(p))),
            _ => "an unrecognised SQL platform"
        };
    }

    /// <summary>
    /// Decides, before any evaluation runs, whether a checklist item can apply to the
    /// audited instance. Items excluded here are recorded as Not Applicable without
    /// executing their script or calling a language model.
    /// </summary>
    public sealed class PlatformApplicability
    {
        public const string PlatformSqlServer = "SqlServer";
        public const string PlatformAzureSqlMi = "AzureSqlMi";
        public const string PlatformAzureSqlDb = "AzureSqlDb";
        public const string PlatformUnknown = "Unknown";

        private sealed record Rule(string[]? AppliesTo, string? MinEdition, int MinVersion, string? MinTier, string Reason);

        private readonly Dictionary<string, Rule> _rules;

        private PlatformApplicability(Dictionary<string, Rule> rules) => _rules = rules;

        /// <summary>An engine that excludes nothing. Used when the tag file is absent.</summary>
        public static PlatformApplicability Empty { get; } = new(new Dictionary<string, Rule>(StringComparer.OrdinalIgnoreCase));

        public int RuleCount => _rules.Count;

        public static PlatformApplicability Load(string? repoRoot)
        {
            if (string.IsNullOrWhiteSpace(repoRoot)) return Empty;
            var path = Path.Combine(repoRoot, "Backend", "checklists", "platform-applicability.json");
            if (!File.Exists(path)) return Empty;

            try
            {
                using var doc = JsonDocument.Parse(File.ReadAllText(path));
                if (!doc.RootElement.TryGetProperty("items", out var items) || items.ValueKind != JsonValueKind.Object)
                    return Empty;

                var rules = new Dictionary<string, Rule>(StringComparer.OrdinalIgnoreCase);
                foreach (var entry in items.EnumerateObject())
                {
                    string[]? appliesTo = null;
                    if (entry.Value.TryGetProperty("applies_to", out var at) && at.ValueKind == JsonValueKind.Array)
                    {
                        var list = new List<string>();
                        foreach (var p in at.EnumerateArray())
                        {
                            var v = p.GetString();
                            if (!string.IsNullOrWhiteSpace(v)) list.Add(v!);
                        }
                        if (list.Count > 0) appliesTo = list.ToArray();
                    }

                    var minEdition = entry.Value.TryGetProperty("min_edition", out var me) ? me.GetString() : null;
                    var minTier = entry.Value.TryGetProperty("min_tier", out var mt) ? mt.GetString() : null;
                    var minVersion = entry.Value.TryGetProperty("min_version", out var mv) && mv.TryGetInt32(out var mvi) ? mvi : 0;
                    var reason = entry.Value.TryGetProperty("reason", out var r) ? r.GetString() ?? string.Empty : string.Empty;

                    if (appliesTo != null
                        || !string.IsNullOrWhiteSpace(minEdition)
                        || !string.IsNullOrWhiteSpace(minTier)
                        || minVersion > 0)
                    {
                        rules[entry.Name] = new Rule(appliesTo, minEdition, minVersion, minTier, reason);
                    }
                }

                return new PlatformApplicability(rules);
            }
            catch
            {
                // A malformed tag file must never block an audit; fall back to evaluating everything.
                return Empty;
            }
        }

        public static async Task<PlatformProfile> DetectAsync(string connectionString, CancellationToken cancellationToken = default)
        {
            if (string.IsNullOrWhiteSpace(connectionString)) return PlatformProfile.Unknown;

            try
            {
                using var conn = new SqlConnection(connectionString);
                await conn.OpenAsync(cancellationToken);

                int engineEdition;
                string editionName;
                string productMajorVersion;
                using (var cmd = new SqlCommand(
                    "SELECT CONVERT(int, SERVERPROPERTY('EngineEdition')), " +
                    "CONVERT(nvarchar(128), SERVERPROPERTY('Edition')), " +
                    "CONVERT(nvarchar(128), SERVERPROPERTY('ProductMajorVersion'));",
                    conn)
                { CommandTimeout = 30 })
                using (var reader = await cmd.ExecuteReaderAsync(cancellationToken))
                {
                    if (!await reader.ReadAsync(cancellationToken)) return PlatformProfile.Unknown;
                    engineEdition = reader.IsDBNull(0) ? 0 : reader.GetInt32(0);
                    editionName = reader.IsDBNull(1) ? string.Empty : reader.GetString(1);
                    productMajorVersion = reader.IsDBNull(2) ? string.Empty : reader.GetString(2);
                }

                var serviceObjective = engineEdition is 5 or 8
                    ? await ReadServiceObjectiveAsync(conn, engineEdition, cancellationToken)
                    : null;

                return BuildProfile(engineEdition, editionName, productMajorVersion, serviceObjective);
            }
            catch
            {
                // If the platform cannot be identified we exclude nothing rather than risk
                // marking a genuinely applicable control as Not Applicable.
                return PlatformProfile.Unknown;
            }
        }

        private static async Task<string?> ReadServiceObjectiveAsync(SqlConnection conn, int engineEdition, CancellationToken cancellationToken)
        {
            var sql = engineEdition == 5
                ? "SELECT CONVERT(nvarchar(128), DATABASEPROPERTYEX(DB_NAME(), 'ServiceObjective'));"
                : "SELECT TOP (1) CONVERT(nvarchar(128), sku) FROM sys.server_resource_stats ORDER BY start_time DESC;";
            try
            {
                using var cmd = new SqlCommand(sql, conn) { CommandTimeout = 30 };
                var value = await cmd.ExecuteScalarAsync(cancellationToken);
                return value == null || value == DBNull.Value ? null : Convert.ToString(value);
            }
            catch
            {
                // An unreadable tier must not cause a tier-gated item to be wrongly excluded.
                return null;
            }
        }

        public static PlatformProfile BuildProfile(int engineEdition, string? editionName, string? productMajorVersion = null, string? serviceObjective = null)
        {
            // 6 (Synapse dedicated pool), 9, 11 and 12 (Fabric) deliberately fall through to
            // Unknown: silently treating them as SQL Server would apply the wrong exclusions.
            var platform = engineEdition switch
            {
                1 or 2 or 3 or 4 => PlatformSqlServer,
                5 => PlatformAzureSqlDb,
                8 => PlatformAzureSqlMi,
                _ => PlatformUnknown
            };

            var isSqlServer = platform == PlatformSqlServer;
            return new PlatformProfile(
                platform,
                engineEdition,
                NormalizeEditionName(editionName),
                isSqlServer ? RankEdition(editionName) : int.MaxValue,
                isSqlServer ? ReleaseYear(productMajorVersion) : 0,
                isSqlServer ? int.MaxValue : RankTier(serviceObjective));
        }

        /// <summary>
        /// True when the item should be evaluated. When false, <paramref name="justification"/>
        /// carries the text written to NotApplicableJustification.
        /// </summary>
        public bool IsApplicable(string itemId, PlatformProfile profile, out string? justification)
        {
            justification = null;
            if (string.IsNullOrWhiteSpace(itemId)) return true;
            if (profile.Platform == PlatformUnknown) return true;
            if (!_rules.TryGetValue(itemId, out var rule)) return true;

            if (rule.AppliesTo != null && Array.IndexOf(rule.AppliesTo, profile.Platform) < 0)
            {
                justification = $"Not applicable to {profile.Display} (EngineEdition {profile.EngineEdition}): {rule.Reason}";
                return false;
            }

            if (!string.IsNullOrWhiteSpace(rule.MinEdition) && profile.EditionRank < RankEditionToken(rule.MinEdition!))
            {
                justification = $"Not applicable to {profile.Display}: requires {rule.MinEdition} edition or higher. {rule.Reason}";
                return false;
            }

            // A version of 0 means the release could not be read; gating on it would produce
            // exactly the false exclusions this design exists to prevent.
            if (rule.MinVersion > 0 && profile.VersionYear > 0 && profile.VersionYear < rule.MinVersion)
            {
                justification = $"Not applicable to {profile.Display}: requires SQL Server {rule.MinVersion} or later. {rule.Reason}";
                return false;
            }

            if (!string.IsNullOrWhiteSpace(rule.MinTier) && profile.TierRank < RankTierToken(rule.MinTier!))
            {
                justification = $"Not applicable to {profile.Display}: requires the {rule.MinTier} service tier. {rule.Reason}";
                return false;
            }

            return true;
        }

        private static string NormalizeEditionName(string? editionName)
        {
            if (string.IsNullOrWhiteSpace(editionName)) return string.Empty;
            // SERVERPROPERTY('Edition') returns e.g. "Express Edition (64-bit)".
            var cut = editionName.IndexOf(" Edition", StringComparison.OrdinalIgnoreCase);
            return (cut > 0 ? editionName.Substring(0, cut) : editionName).Trim();
        }

        private static int RankEdition(string? editionName)
        {
            if (string.IsNullOrWhiteSpace(editionName)) return int.MaxValue;
            var e = editionName!;
            // LocalDB reports "Express Edition (64-bit)" and is ranked with Express.
            if (e.Contains("Express", StringComparison.OrdinalIgnoreCase)) return 0;
            if (e.Contains("Web", StringComparison.OrdinalIgnoreCase)) return 1;
            if (e.Contains("Standard", StringComparison.OrdinalIgnoreCase)) return 2;
            if (e.Contains("Business Intelligence", StringComparison.OrdinalIgnoreCase)) return 3;
            // Developer and Evaluation carry the full Enterprise feature set.
            if (e.Contains("Enterprise", StringComparison.OrdinalIgnoreCase)) return 4;
            if (e.Contains("Developer", StringComparison.OrdinalIgnoreCase)) return 4;
            if (e.Contains("Evaluation", StringComparison.OrdinalIgnoreCase)) return 4;
            // Unrecognised editions are assumed fully featured so nothing is wrongly excluded.
            return int.MaxValue;
        }

        private static int RankEditionToken(string token) => token.Trim().ToLowerInvariant() switch
        {
            "express" => 0,
            "web" => 1,
            "standard" => 2,
            "businessintelligence" => 3,
            "enterprise" => 4,
            _ => 0
        };

        private static int ReleaseYear(string? productMajorVersion) =>
            int.TryParse(productMajorVersion?.Trim(), out var major)
                ? major switch
                {
                    11 => 2012,
                    12 => 2014,
                    13 => 2016,
                    14 => 2017,
                    15 => 2019,
                    16 => 2022,
                    17 => 2025,
                    _ => major > 17 ? 2025 : 0
                }
                : 0;

        private static int RankTier(string? serviceObjective)
        {
            // Unreadable tier is treated as the highest so a tier gate never wrongly excludes.
            if (string.IsNullOrWhiteSpace(serviceObjective)) return int.MaxValue;
            var o = serviceObjective!.Trim();
            if (o.StartsWith("BC", StringComparison.OrdinalIgnoreCase)) return 1;
            if (o.StartsWith("HS", StringComparison.OrdinalIgnoreCase)) return 1;
            // Premium DTU objectives are P1..P15; the GP_S_ serverless prefix must not match here.
            if (o.Length > 1 && (o[0] == 'P' || o[0] == 'p') && char.IsDigit(o[1])) return 1;
            return 0;
        }

        private static int RankTierToken(string token) => token.Trim().ToLowerInvariant() switch
        {
            "businesscritical" => 1,
            _ => 0
        };
    }
}
