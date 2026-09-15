using System.ComponentModel;
using System.Runtime.CompilerServices;
using SQLAuditor.Lib;

namespace SQLAuditor.Wpf;

/// <summary>One row of the Connect tab server list. Password is held in memory only.</summary>
public sealed class ServerEntry : INotifyPropertyChanged
{
    private string _status = "Not verified";
    private string? _runDirectory;

    public required string Server { get; init; }

    /// <summary>Unique label; lets the same instance appear more than once in a batch.</summary>
    public string? Name { get; init; }

    public ServerAuthMode AuthMode { get; init; } = ServerAuthMode.Windows;
    public string? User { get; init; }
    public string? Password { get; init; }
    public string[]? Databases { get; init; }

    public string DisplayName => string.IsNullOrWhiteSpace(Name) ? Server : Name!;

    public string AuthLabel => AuthMode == ServerAuthMode.Sql ? $"SQL ({User})" : "Windows";

    public string DatabasesLabel =>
        Databases is { Length: > 0 } ? string.Join(", ", Databases) : "All databases";

    public string Status
    {
        get => _status;
        set { _status = value; Raise(); }
    }

    public string? RunDirectory
    {
        get => _runDirectory;
        set { _runDirectory = value; Raise(); }
    }

    public ServerTarget ToTarget() => new()
    {
        Server = Server,
        Name = DisplayName,
        AuthMode = AuthMode,
        User = User,
        Password = Password,
        Databases = Databases,
    };

    public event PropertyChangedEventHandler? PropertyChanged;

    private void Raise([CallerMemberName] string? name = null) =>
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
}
