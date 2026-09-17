using System;
using System.Collections.Generic;
using System.Linq;
using Microsoft.Data.SqlClient;

namespace SQLAuditor.Lib
{
    public enum SqlAuthMethod
    {
        WindowsIntegrated,
        SqlLogin,
        EntraInteractive,
        EntraServicePrincipal,
        EntraManagedIdentity,

        /// <summary>Operator supplied a full connection string; it is used verbatim.</summary>
        ConnectionString,
    }

    // The single description of how the auditor authenticates to SQL Server. Every host
    // (WPF, CLI, MCP) collects credentials into this shape and hands it to
    // SqlConnectionStringFactory, so the connection string is built in exactly one place.
    public sealed record SqlAuthProfile
    {
        // Interactive sign-in has to survive a browser round trip.
        public const int InteractiveConnectTimeoutSeconds = 60;

        public SqlAuthMethod Method { get; init; } = SqlAuthMethod.WindowsIntegrated;

        public string Server { get; init; } = string.Empty;

        public string Database { get; init; } = "master";

        // The identity for the chosen method: SQL login name, Entra UPN, service principal
        // client ID, or user-assigned managed identity client ID.
        public string? UserId { get; init; }

        // SQL login password or service principal client secret. Never logged or persisted.
        public string? Secret { get; init; }

        // Not a connection-string keyword - SQL Server resolves the tenant itself. Kept for
        // the audit trail and for the future access-token path.
        public string? TenantId { get; init; }

        // Set only when Method is ConnectionString. Never logged or persisted.
        public string? RawConnectionString { get; init; }

        public bool? Encrypt { get; init; }

        public bool? TrustServerCertificate { get; init; }

        public int? ConnectTimeout { get; init; }

        public bool IsEntra => IsEntraMethod(Method);

        public bool IsAzureEndpoint => IsAzureSqlEndpoint(Server);

        // Interactive sign-in raises a browser prompt, so it cannot run on a headless host.
        public bool RequiresInteractiveHost => Method == SqlAuthMethod.EntraInteractive;

        public bool RequiresSecret => Method is SqlAuthMethod.SqlLogin
            or SqlAuthMethod.EntraServicePrincipal;

        public bool AcceptsUserId => Method is not (SqlAuthMethod.WindowsIntegrated or SqlAuthMethod.ConnectionString);

        public static bool IsEntraMethod(SqlAuthMethod method) =>
            method is SqlAuthMethod.EntraInteractive
                or SqlAuthMethod.EntraServicePrincipal
                or SqlAuthMethod.EntraManagedIdentity;

        private static readonly string[] AzureSqlSuffixes =
        {
            ".database.windows.net",
            ".database.chinacloudapi.cn",
            ".database.usgovcloudapi.net",
        };

        public static bool IsAzureSqlEndpoint(string? server)
        {
            if (string.IsNullOrWhiteSpace(server)) return false;

            var host = server.Trim();
            var protocolSeparator = host.IndexOf(':');
            if (protocolSeparator >= 0 &&
                (host.StartsWith("tcp:", StringComparison.OrdinalIgnoreCase) ||
                 host.StartsWith("np:", StringComparison.OrdinalIgnoreCase) ||
                 host.StartsWith("admin:", StringComparison.OrdinalIgnoreCase)))
            {
                host = host[(protocolSeparator + 1)..];
            }

            var portSeparator = host.IndexOf(',');
            if (portSeparator >= 0) host = host[..portSeparator];

            host = host.TrimEnd('.');
            return AzureSqlSuffixes.Any(suffix => host.EndsWith(suffix, StringComparison.OrdinalIgnoreCase));
        }

        /// <summary>Environment variable that supplies a full connection string, keeping secrets out of argv.</summary>
        public const string ConnectionStringVariable = "SQLAUDITOR_CONNECTION_STRING";

        /// <summary>Reads the connection string from the environment, or null when it is not set.</summary>
        public static string? ReadConnectionStringFromEnvironment()
        {
            var value = Environment.GetEnvironmentVariable(ConnectionStringVariable);
            return string.IsNullOrWhiteSpace(value) ? null : value;
        }

        /// <summary>
        /// Builds a profile from an operator-supplied connection string. The string is kept verbatim;
        /// only the server name is read out of it so run folders and reports stay labelled correctly.
        /// </summary>
        public static bool TryParseConnectionString(string? raw, out SqlAuthProfile profile, out string error)
        {
            profile = null!;
            error = string.Empty;

            if (string.IsNullOrWhiteSpace(raw))
            {
                error = "The connection string is empty.";
                return false;
            }

            SqlConnectionStringBuilder builder;
            try
            {
                builder = new SqlConnectionStringBuilder(raw);
            }
            catch (Exception ex)
            {
                error = $"The connection string could not be parsed: {ex.Message}";
                return false;
            }

            if (string.IsNullOrWhiteSpace(builder.DataSource))
            {
                error = "The connection string has no Server / Data Source value.";
                return false;
            }

            profile = new SqlAuthProfile
            {
                Method = SqlAuthMethod.ConnectionString,
                Server = builder.DataSource,
                Database = string.IsNullOrWhiteSpace(builder.InitialCatalog) ? "master" : builder.InitialCatalog,
                RawConnectionString = raw,
            };
            return true;
        }

        public static string DisplayNameFor(SqlAuthMethod method) => method switch
        {
            SqlAuthMethod.WindowsIntegrated => "Windows Authentication",
            SqlAuthMethod.SqlLogin => "SQL Login",
            SqlAuthMethod.EntraInteractive => "Entra Interactive (MFA)",
            SqlAuthMethod.EntraServicePrincipal => "Entra Service Principal",
            SqlAuthMethod.EntraManagedIdentity => "Entra Managed Identity",
            SqlAuthMethod.ConnectionString => "Connection String",
            _ => method.ToString(),
        };

        // Canonical token accepted by the CLI --auth flag and the MCP authMethod argument.
        public static string TokenFor(SqlAuthMethod method) => method switch
        {
            SqlAuthMethod.WindowsIntegrated => "windows",
            SqlAuthMethod.SqlLogin => "sql",
            SqlAuthMethod.EntraInteractive => "entra-interactive",
            SqlAuthMethod.EntraServicePrincipal => "entra-service-principal",
            SqlAuthMethod.EntraManagedIdentity => "entra-managed-identity",
            SqlAuthMethod.ConnectionString => "connection-string",
            _ => method.ToString().ToLowerInvariant(),
        };

        public static IReadOnlyList<SqlAuthMethod> AllMethods { get; } = new[]
        {
            SqlAuthMethod.WindowsIntegrated,
            SqlAuthMethod.SqlLogin,
            SqlAuthMethod.EntraInteractive,
            SqlAuthMethod.EntraServicePrincipal,
            SqlAuthMethod.EntraManagedIdentity,
            SqlAuthMethod.ConnectionString,
        };

        public static string SupportedTokens => string.Join(", ", System.Linq.Enumerable.Select(AllMethods, TokenFor));

        // Label the host should put on the identity field for this method.
        public static string UserIdLabelFor(SqlAuthMethod method) => method switch
        {
            SqlAuthMethod.SqlLogin => "Username",
            SqlAuthMethod.EntraInteractive => "Entra user (optional)",
            SqlAuthMethod.EntraServicePrincipal => "Client ID",
            SqlAuthMethod.EntraManagedIdentity => "User-assigned client ID (optional)",
            _ => "Username",
        };

        public static string SecretLabelFor(SqlAuthMethod method) => method switch
        {
            SqlAuthMethod.EntraServicePrincipal => "Client secret",
            _ => "Password",
        };

        /// <summary>True when the mode needs a user name typed by the operator.</summary>
        public static bool RequiresUserNameFor(SqlAuthMethod method) => method == SqlAuthMethod.SqlLogin;

        /// <summary>True when the mode needs a secret supplied out of band (password or client secret).</summary>
        public static bool RequiresSecretFor(SqlAuthMethod method)
            => method is SqlAuthMethod.SqlLogin or SqlAuthMethod.EntraServicePrincipal;

        /// <summary>True when the mode needs a client id (service principal application id).</summary>
        public static bool RequiresClientIdFor(SqlAuthMethod method)
            => method == SqlAuthMethod.EntraServicePrincipal;

        /// <summary>Inverse of <see cref="DisplayNameFor"/>, used by the UI combo and stored run metadata.</summary>
        public static SqlAuthMethod FromDisplayName(string? displayName)
            => TryParseMethod(displayName, out var method) ? method : SqlAuthMethod.WindowsIntegrated;

        private static readonly Dictionary<string, SqlAuthMethod> Aliases =
            new(StringComparer.OrdinalIgnoreCase)
            {
                ["windows"] = SqlAuthMethod.WindowsIntegrated,
                ["win"] = SqlAuthMethod.WindowsIntegrated,
                ["integrated"] = SqlAuthMethod.WindowsIntegrated,
                ["windowsintegrated"] = SqlAuthMethod.WindowsIntegrated,
                ["1"] = SqlAuthMethod.WindowsIntegrated,

                ["sql"] = SqlAuthMethod.SqlLogin,
                ["sqllogin"] = SqlAuthMethod.SqlLogin,
                ["sql-login"] = SqlAuthMethod.SqlLogin,
                ["2"] = SqlAuthMethod.SqlLogin,

                ["entra-interactive"] = SqlAuthMethod.EntraInteractive,
                ["entrainteractive"] = SqlAuthMethod.EntraInteractive,
                ["interactive"] = SqlAuthMethod.EntraInteractive,
                ["mfa"] = SqlAuthMethod.EntraInteractive,
                ["aad-interactive"] = SqlAuthMethod.EntraInteractive,
                ["activedirectoryinteractive"] = SqlAuthMethod.EntraInteractive,
                ["3"] = SqlAuthMethod.EntraInteractive,

                ["entra-service-principal"] = SqlAuthMethod.EntraServicePrincipal,
                ["entra-sp"] = SqlAuthMethod.EntraServicePrincipal,
                ["serviceprincipal"] = SqlAuthMethod.EntraServicePrincipal,
                ["service-principal"] = SqlAuthMethod.EntraServicePrincipal,
                ["spn"] = SqlAuthMethod.EntraServicePrincipal,
                ["activedirectoryserviceprincipal"] = SqlAuthMethod.EntraServicePrincipal,
                ["4"] = SqlAuthMethod.EntraServicePrincipal,

                ["entra-managed-identity"] = SqlAuthMethod.EntraManagedIdentity,
                ["entra-mi"] = SqlAuthMethod.EntraManagedIdentity,
                ["managed-identity"] = SqlAuthMethod.EntraManagedIdentity,
                ["managedidentity"] = SqlAuthMethod.EntraManagedIdentity,
                ["msi"] = SqlAuthMethod.EntraManagedIdentity,
                ["activedirectorymanagedidentity"] = SqlAuthMethod.EntraManagedIdentity,
                ["5"] = SqlAuthMethod.EntraManagedIdentity,

                ["connection-string"] = SqlAuthMethod.ConnectionString,
                ["connectionstring"] = SqlAuthMethod.ConnectionString,
                ["cs"] = SqlAuthMethod.ConnectionString,
                ["6"] = SqlAuthMethod.ConnectionString,

                // Short forms used by the multiple-environments branch, kept so existing
                // scripts and saved runs using them keep working.
                ["entra-sp"] = SqlAuthMethod.EntraServicePrincipal,
                ["entra-msi"] = SqlAuthMethod.EntraManagedIdentity,
                ["entra-mfa"] = SqlAuthMethod.EntraInteractive,
                ["entra"] = SqlAuthMethod.EntraInteractive,

                // Display names, so a method persisted in run metadata parses back to itself.
                ["Windows Authentication"] = SqlAuthMethod.WindowsIntegrated,
                ["SQL Login"] = SqlAuthMethod.SqlLogin,
                ["Entra Interactive (MFA)"] = SqlAuthMethod.EntraInteractive,
                ["Entra Service Principal"] = SqlAuthMethod.EntraServicePrincipal,
                ["Entra Managed Identity"] = SqlAuthMethod.EntraManagedIdentity,
                ["Connection String"] = SqlAuthMethod.ConnectionString,

                // Display names written by the multiple-environments branch.
                ["Microsoft Entra Multi-Factor Authentication (MFA)"] = SqlAuthMethod.EntraInteractive,
                ["Microsoft Entra Interactive"] = SqlAuthMethod.EntraInteractive,
                ["Microsoft Entra Managed Identity"] = SqlAuthMethod.EntraManagedIdentity,
                ["Microsoft Entra Service Principal"] = SqlAuthMethod.EntraServicePrincipal,
            };

        public static bool TryParseMethod(string? token, out SqlAuthMethod method)
        {
            method = SqlAuthMethod.WindowsIntegrated;
            if (string.IsNullOrWhiteSpace(token)) return false;
            return Aliases.TryGetValue(token.Trim(), out method);
        }

        // Best-effort recovery of the method from a pre-built connection string, so the
        // legacy Auditor(string) path can still make auth-aware decisions.
        public static SqlAuthMethod InferMethod(string? connectionString)
        {
            if (string.IsNullOrWhiteSpace(connectionString)) return SqlAuthMethod.WindowsIntegrated;
            try
            {
                var builder = new SqlConnectionStringBuilder(connectionString);
                return builder.Authentication switch
                {
                    SqlAuthenticationMethod.ActiveDirectoryInteractive => SqlAuthMethod.EntraInteractive,
                    SqlAuthenticationMethod.ActiveDirectoryServicePrincipal => SqlAuthMethod.EntraServicePrincipal,
                    SqlAuthenticationMethod.ActiveDirectoryManagedIdentity => SqlAuthMethod.EntraManagedIdentity,
                    SqlAuthenticationMethod.NotSpecified or SqlAuthenticationMethod.SqlPassword =>
                        builder.IntegratedSecurity ? SqlAuthMethod.WindowsIntegrated : SqlAuthMethod.SqlLogin,
                    // Any other Entra variant only has to be recognised as Entra, for transport and retry gating.
                    _ => SqlAuthMethod.EntraInteractive,
                };
            }
            catch
            {
                return SqlAuthMethod.WindowsIntegrated;
            }
        }

        // Returns null when the profile is usable, otherwise a message fit to show the user.
        public string? Validate()
        {
            if (Method == SqlAuthMethod.ConnectionString)
            {
                return string.IsNullOrWhiteSpace(RawConnectionString)
                    ? "A connection string is required."
                    : null;
            }

            if (string.IsNullOrWhiteSpace(Server))
                return "A SQL Server name (host or host,port) is required.";

            var hasUser = !string.IsNullOrWhiteSpace(UserId);
            var hasSecret = !string.IsNullOrEmpty(Secret);

            switch (Method)
            {
                case SqlAuthMethod.WindowsIntegrated:
                    if (hasUser || hasSecret)
                        return "Windows Authentication uses the signed-in Windows account; remove the username and password.";
                    if (IsAzureSqlEndpoint(Server))
                        return "Azure SQL does not accept Windows Authentication; choose SQL Login or an Entra method.";
                    break;

                case SqlAuthMethod.SqlLogin:
                    if (!hasUser) return "SQL Login requires a username.";
                    if (!hasSecret) return "SQL Login requires a password.";
                    break;

                case SqlAuthMethod.EntraServicePrincipal:
                    if (!hasUser) return "Entra Service Principal requires the application (client) ID.";
                    if (!hasSecret) return "Entra Service Principal requires the client secret.";
                    break;

                case SqlAuthMethod.EntraInteractive:
                case SqlAuthMethod.EntraManagedIdentity:
                    if (hasSecret)
                        return $"{DisplayNameFor(Method)} acquires its own token; remove the password/secret.";
                    break;
            }

            return null;
        }

        // Redacted one-liner for logs, run metadata and reports.
        public string Describe()
        {
            var name = DisplayNameFor(Method);
            if (Method == SqlAuthMethod.ConnectionString)
                return string.IsNullOrWhiteSpace(Server) ? name : $"{name} for {Server}";

            var identity = string.IsNullOrWhiteSpace(UserId) ? null : UserId.Trim();
            var tenant = string.IsNullOrWhiteSpace(TenantId) ? null : TenantId.Trim();

            var text = identity is null ? name : $"{name} as {identity}";
            if (tenant is not null) text += $" (tenant {tenant})";
            return text;
        }
    }

    public static class SqlConnectionStringFactory
    {
        public static string Build(SqlAuthProfile profile)
        {
            if (profile is null) throw new ArgumentNullException(nameof(profile));

            var error = profile.Validate();
            if (error is not null) throw new ArgumentException(error, nameof(profile));

            // A supplied connection string is authoritative: the tool overrides nothing in it.
            if (profile.Method == SqlAuthMethod.ConnectionString)
                return profile.RawConnectionString!;

            var azure = profile.IsAzureEndpoint;
            var builder = new SqlConnectionStringBuilder
            {
                DataSource = profile.Server.Trim(),
                InitialCatalog = string.IsNullOrWhiteSpace(profile.Database) ? "master" : profile.Database.Trim(),
                ApplicationName = "SQLAuditor",
                Encrypt = profile.Encrypt ?? true,
                // Entra tokens must not be handed to an unverified server, and Azure always
                // presents a valid certificate; on-prem Windows/SQL keep the tool's
                // long-standing default so existing targets still connect.
                TrustServerCertificate = profile.TrustServerCertificate ?? !(profile.IsEntra || azure),
            };

            if (azure)
            {
                builder.ConnectRetryCount = 3;
                builder.ConnectRetryInterval = 10;
            }

            switch (profile.Method)
            {
                case SqlAuthMethod.WindowsIntegrated:
                    builder.IntegratedSecurity = true;
                    break;

                case SqlAuthMethod.SqlLogin:
                    builder.UserID = profile.UserId!.Trim();
                    builder.Password = profile.Secret!;
                    break;

                default:
                    builder.Authentication = AuthenticationFor(profile.Method);
                    if (!string.IsNullOrWhiteSpace(profile.UserId)) builder.UserID = profile.UserId.Trim();
                    if (!string.IsNullOrEmpty(profile.Secret)) builder.Password = profile.Secret;
                    break;
            }

            var timeout = profile.ConnectTimeout
                ?? (profile.Method == SqlAuthMethod.EntraInteractive
                    ? SqlAuthProfile.InteractiveConnectTimeoutSeconds
                    : azure ? 30 : (int?)null);
            if (timeout.HasValue) builder.ConnectTimeout = timeout.Value;

            return builder.ConnectionString;
        }

        private static SqlAuthenticationMethod AuthenticationFor(SqlAuthMethod method) => method switch
        {
            SqlAuthMethod.EntraInteractive => SqlAuthenticationMethod.ActiveDirectoryInteractive,
            SqlAuthMethod.EntraServicePrincipal => SqlAuthenticationMethod.ActiveDirectoryServicePrincipal,
            SqlAuthMethod.EntraManagedIdentity => SqlAuthenticationMethod.ActiveDirectoryManagedIdentity,
            _ => throw new ArgumentOutOfRangeException(nameof(method), method, "Not an Entra authentication method."),
        };
    }
}
