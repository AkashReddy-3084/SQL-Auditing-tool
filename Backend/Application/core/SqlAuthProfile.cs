using System;
using System.Collections.Generic;
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

        public bool? Encrypt { get; init; }

        public bool? TrustServerCertificate { get; init; }

        public int? ConnectTimeout { get; init; }

        public bool IsEntra => IsEntraMethod(Method);

        public bool RequiresSecret => Method is SqlAuthMethod.SqlLogin
            or SqlAuthMethod.EntraServicePrincipal;

        public bool AcceptsUserId => Method != SqlAuthMethod.WindowsIntegrated;

        public static bool IsEntraMethod(SqlAuthMethod method) =>
            method is not (SqlAuthMethod.WindowsIntegrated or SqlAuthMethod.SqlLogin);

        public static string DisplayNameFor(SqlAuthMethod method) => method switch
        {
            SqlAuthMethod.WindowsIntegrated => "Windows Authentication",
            SqlAuthMethod.SqlLogin => "SQL Login",
            SqlAuthMethod.EntraInteractive => "Entra Interactive (MFA)",
            SqlAuthMethod.EntraServicePrincipal => "Entra Service Principal",
            SqlAuthMethod.EntraManagedIdentity => "Entra Managed Identity",
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
            _ => method.ToString().ToLowerInvariant(),
        };

        public static IReadOnlyList<SqlAuthMethod> AllMethods { get; } = new[]
        {
            SqlAuthMethod.WindowsIntegrated,
            SqlAuthMethod.SqlLogin,
            SqlAuthMethod.EntraInteractive,
            SqlAuthMethod.EntraServicePrincipal,
            SqlAuthMethod.EntraManagedIdentity,
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

                // Display names, so a method persisted in run metadata parses back to itself.
                ["Windows Authentication"] = SqlAuthMethod.WindowsIntegrated,
                ["SQL Login"] = SqlAuthMethod.SqlLogin,
                ["Entra Interactive (MFA)"] = SqlAuthMethod.EntraInteractive,
                ["Entra Service Principal"] = SqlAuthMethod.EntraServicePrincipal,
                ["Entra Managed Identity"] = SqlAuthMethod.EntraManagedIdentity,
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
            if (string.IsNullOrWhiteSpace(Server))
                return "A SQL Server name (host or host,port) is required.";

            var hasUser = !string.IsNullOrWhiteSpace(UserId);
            var hasSecret = !string.IsNullOrEmpty(Secret);

            switch (Method)
            {
                case SqlAuthMethod.WindowsIntegrated:
                    if (hasUser || hasSecret)
                        return "Windows Authentication uses the signed-in Windows account; remove the username and password.";
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

            var builder = new SqlConnectionStringBuilder
            {
                DataSource = profile.Server.Trim(),
                InitialCatalog = string.IsNullOrWhiteSpace(profile.Database) ? "master" : profile.Database.Trim(),
                Encrypt = profile.Encrypt ?? true,
                // Entra tokens must not be handed to an unverified server; Windows/SQL keep
                // the tool's long-standing default so existing on-prem targets still connect.
                TrustServerCertificate = profile.TrustServerCertificate ?? !profile.IsEntra,
            };

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
                    : (int?)null);
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
