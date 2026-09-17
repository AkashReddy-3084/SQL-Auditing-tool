using System;
using System.Collections.Generic;
using System.Linq;

namespace SQLAuditor.Lib;

/// <summary>
/// A single row returned by an audit SQL script, keyed by column name.
/// </summary>
public sealed class SqlScriptRow
{
    public SqlScriptRow(IReadOnlyList<string> columns, IReadOnlyList<string> values)
    {
        Columns = columns;
        Values = values;
    }

    public IReadOnlyList<string> Columns { get; }

    public IReadOnlyList<string> Values { get; }

    public string? this[string column]
    {
        get
        {
            for (var i = 0; i < Columns.Count && i < Values.Count; i++)
            {
                if (string.Equals(Columns[i], column, StringComparison.OrdinalIgnoreCase))
                    return Values[i];
            }
            return null;
        }
    }

    public string? Get(params string[] columnAliases)
    {
        foreach (var alias in columnAliases)
        {
            var v = this[alias];
            if (!string.IsNullOrWhiteSpace(v) && !string.Equals(v, "NULL", StringComparison.OrdinalIgnoreCase))
                return v.Trim();
        }
        return null;
    }

    public override string ToString() =>
        string.Join(" | ", Columns.Zip(Values, (c, v) => $"{c}={v}"));
}

/// <summary>
/// The structured verdict an audit SQL script produced: the Result/Score/Finding/
/// DatabaseQueried columns of its final SELECT, plus every row it returned so the
/// AI enricher has the raw facts to reason over. This is the factual source for the
/// enriched checklist result - never the script path or console formatting.
/// </summary>
public sealed class SqlScriptOutcome
{
    public string? Result { get; init; }

    public int? Score { get; init; }

    public string? DatabasesVerified { get; init; }

    public string? Finding { get; init; }

    public IReadOnlyList<SqlScriptRow> Rows { get; init; } = Array.Empty<SqlScriptRow>();

    public string? Error { get; init; }

    /// <summary>True when the script produced at least one usable structured value.</summary>
    public bool HasStructuredResult =>
        Result != null || Score != null || !string.IsNullOrWhiteSpace(Finding);

    /// <summary>
    /// A compact, column-labelled rendering of the script result set for use as LLM
    /// input. Contains no file paths, SQL text or batch headers.
    /// </summary>
    public string ToFactSheet(int maxRows = 40)
    {
        if (Rows.Count == 0)
            return string.IsNullOrWhiteSpace(Error) ? "(the script returned no rows)" : $"(script error: {Error})";

        return string.Join(Environment.NewLine, Rows.Take(maxRows).Select(r => r.ToString()))
            + (Rows.Count > maxRows ? $"{Environment.NewLine}... ({Rows.Count - maxRows} further rows omitted)" : string.Empty);
    }
}
