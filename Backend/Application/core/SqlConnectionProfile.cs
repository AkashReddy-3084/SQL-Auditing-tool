using System;
using System.Linq;
using Microsoft.Data.SqlClient;

namespace SQLAuditor.Lib
{
    public enum SqlAuthMode
    {
        WindowsIntegrated,
        SqlLogin,
        EntraMfa,
        EntraManagedIdentity,
        EntraServicePrincipal,

        /// <summary>Operator supplied a full connection string; it is used verbatim. Must stay last — the WPF combo maps by index.</summary>
        ConnectionString,
    }

    /// <summary>
    /// The single place a SQL connection string is built, shared by the WPF app, the CLI,
    /// the MCP server and the multi-server runner.
    /// </summary>
    public sealed record SqlConnectionProfile
    {
        private static readonly string[] AzureSqlSuffixes =
        {
            ".database.windows.net",
            ".database.chinacloudapi.cn",
            ".database.usgovcloudapi.net",
        };

        public required string Server { get; init; }

        /// <summary>Initial catalog. Left unset so <see cref="Auditor"/> can decide whether master is reachable.</summary>
        public string? Database { get; init; }

        public SqlAuthMode AuthMode { get; init; } = SqlAuthMode.WindowsIntegrated;

        public string? UserId { get; init; }

        public string? Password { get; init; }

        /// <summary>User-assigned managed identity or service principal client id.</summary>
        public string? ClientId { get; init; }

        /// <summary>Set only when <see cref="AuthMode"/> is ConnectionString. Never logged or persisted.</summary>
        public string? RawConnectionString { get; init; }

        public bool IsAzureEndpoint => IsAzureSqlEndpoint(Server);

        /// <summary>MFA raises an interactive browser sign-in prompt, so it cannot run on a headless host.</summary>
        public bool RequiresInteractiveHost => AuthMode == SqlAuthMode.EntraMfa;

        public string BuildConnectionString()
        {
            // A supplied connection string is authoritative: the tool overrides nothing in it.
            if (AuthMode == SqlAuthMode.ConnectionString)
                return RawConnectionString ?? string.Empty;

            var builder = new SqlConnectionStringBuilder
            {
                DataSource = Server,
                ApplicationName = "SQLAuditor",
            };

            if (!string.IsNullOrWhiteSpace(Database))
                builder.InitialCatalog = Database;

            switch (AuthMode)
            {
                case SqlAuthMode.SqlLogin:
                    builder.UserID = UserId ?? string.Empty;
                    builder.Password = Password ?? string.Empty;
                    break;

                case SqlAuthMode.EntraMfa:
                    builder.Authentication = SqlAuthenticationMethod.ActiveDirectoryInteractive;
                    // Optional sign-in hint that pre-fills the browser prompt.
                    if (!string.IsNullOrWhiteSpace(UserId)) builder.UserID = UserId;
                    break;

                case SqlAuthMode.EntraManagedIdentity:
                    builder.Authentication = SqlAuthenticationMethod.ActiveDirectoryManagedIdentity;
                    // Omitting the client id selects the system-assigned identity.
                    if (!string.IsNullOrWhiteSpace(ClientId)) builder.UserID = ClientId;
                    break;

                case SqlAuthMode.EntraServicePrincipal:
                    builder.Authentication = SqlAuthenticationMethod.ActiveDirectoryServicePrincipal;
                    builder.UserID = ClientId ?? UserId ?? string.Empty;
                    builder.Password = Password ?? string.Empty;
                    break;

                default:
                    builder.IntegratedSecurity = true;
                    break;
            }

            var azure = IsAzureEndpoint;
            builder.Encrypt = true;
            // On-premises instances commonly present a self-signed certificate; Azure never does.
            builder.TrustServerCertificate = !azure;

            if (azure)
            {
                builder.ConnectTimeout = 30;
                builder.ConnectRetryCount = 3;
                builder.ConnectRetryInterval = 10;
            }

            return builder.ConnectionString;
        }

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

        /// <summary>
        /// Builds a profile from an operator-supplied connection string. The string is kept verbatim;
        /// only the server name is read out of it so run folders and reports stay labelled correctly.
        /// </summary>
        public static bool TryParseConnectionString(string? raw, out SqlConnectionProfile profile, out string error)
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

            profile = new SqlConnectionProfile
            {
                Server = builder.DataSource,
                Database = string.IsNullOrWhiteSpace(builder.InitialCatalog) ? null : builder.InitialCatalog,
                AuthMode = SqlAuthMode.ConnectionString,
                RawConnectionString = raw,
            };
            return true;
        }

        /// <summary>Reads the connection string from the environment, or null when it is not set.</summary>
        public static string? ReadConnectionStringFromEnvironment()
        {
            var value = Environment.GetEnvironmentVariable(ConnectionStringVariable);
            return string.IsNullOrWhiteSpace(value) ? null : value;
        }

        /// <summary>Parses a CLI/MCP auth token. Returns false with an actionable message when unrecognised.</summary>
        public static bool TryParseAuthMode(string? token, out SqlAuthMode mode, out string error)
        {
            mode = SqlAuthMode.WindowsIntegrated;
            error = string.Empty;

            switch (token?.Trim().ToLowerInvariant())
            {
                case "windows":
                case "win":
                case "integrated":
                    mode = SqlAuthMode.WindowsIntegrated;
                    return true;
                case "sql":
                case "sqllogin":
                    mode = SqlAuthMode.SqlLogin;
                    return true;
                case "entra-mfa":
                case "mfa":
                case "entra-interactive":
                case "entra":
                    mode = SqlAuthMode.EntraMfa;
                    return true;
                case "entra-msi":
                case "entra-managed-identity":
                case "msi":
                    mode = SqlAuthMode.EntraManagedIdentity;
                    return true;
                case "entra-sp":
                case "entra-service-principal":
                    mode = SqlAuthMode.EntraServicePrincipal;
                    return true;
                case "connection-string":
                case "connectionstring":
                case "cs":
                    mode = SqlAuthMode.ConnectionString;
                    return true;
                default:
                    error = $"Unknown authentication method '{token}'. Use one of: "
                          + "windows, sql, entra-mfa, entra-msi, entra-sp, connection-string.";
                    return false;
            }
        }

        public static string ToDisplayName(SqlAuthMode mode) => mode switch
        {
            SqlAuthMode.SqlLogin => "SQL Login",
            SqlAuthMode.EntraMfa => "Microsoft Entra Multi-Factor Authentication (MFA)",
            SqlAuthMode.EntraManagedIdentity => "Microsoft Entra Managed Identity",
            SqlAuthMode.EntraServicePrincipal => "Microsoft Entra Service Principal",
            SqlAuthMode.ConnectionString => "Connection String",
            _ => "Windows Authentication",
        };

        /// <summary>Inverse of <see cref="ToDisplayName"/>, used by the UI combo and stored run metadata.</summary>
        public static SqlAuthMode FromDisplayName(string? displayName) => displayName?.Trim() switch
        {
            "SQL Login" => SqlAuthMode.SqlLogin,
            "Microsoft Entra Multi-Factor Authentication (MFA)" => SqlAuthMode.EntraMfa,
            // Accepted so runs recorded before the rename still replay correctly.
            "Microsoft Entra Interactive" => SqlAuthMode.EntraMfa,
            "Microsoft Entra Managed Identity" => SqlAuthMode.EntraManagedIdentity,
            "Microsoft Entra Service Principal" => SqlAuthMode.EntraServicePrincipal,
            "Connection String" => SqlAuthMode.ConnectionString,
            _ => SqlAuthMode.WindowsIntegrated,
        };

        /// <summary>True when the mode needs a user name typed by the operator.</summary>
        public static bool RequiresUserName(SqlAuthMode mode) => mode == SqlAuthMode.SqlLogin;

        /// <summary>True when the mode needs a secret supplied out of band (password or client secret).</summary>
        public static bool RequiresSecret(SqlAuthMode mode)
            => mode is SqlAuthMode.SqlLogin or SqlAuthMode.EntraServicePrincipal;

        /// <summary>True when the mode needs a client id (service principal application id).</summary>
        public static bool RequiresClientId(SqlAuthMode mode) => mode == SqlAuthMode.EntraServicePrincipal;
    }
}
