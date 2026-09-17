using System.Text.Json.Serialization;

namespace SQLAuditor.Lib;

public enum ServerAuthMode
{
    Windows,
    Sql
}

/// <summary>
/// One SQL Server instance in a multi-server batch. <see cref="Password"/> is held in memory only
/// and is never serialized into a server-list file or a manifest.
/// </summary>
public sealed class ServerTarget
{
    public required string Server { get; init; }

    /// <summary>Label used in reports; defaults to <see cref="Server"/>.</summary>
    public string? Name { get; init; }

    public ServerAuthMode AuthMode { get; init; } = ServerAuthMode.Windows;

    public string? User { get; init; }

    [JsonIgnore]
    public string? Password { get; set; }

    /// <summary>Databases to audit on this instance; null means every accessible database.</summary>
    public string[]? Databases { get; init; }

    public string DisplayName => string.IsNullOrWhiteSpace(Name) ? Server : Name!;

    public string BuildConnectionString() => SqlConnectionStringFactory.Build(new SqlAuthProfile
    {
        Server = Server,
        Method = AuthMode == ServerAuthMode.Sql ? SqlAuthMethod.SqlLogin : SqlAuthMethod.WindowsIntegrated,
        UserId = User,
        Secret = Password,
    });
}
