using System.Linq;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading.Tasks;

namespace SQLAuditor.Lib;

internal static class EvaluationDecisionService
{
    public static string EvaluateEvidenceOutcome(string evidence)
    {
        if (string.IsNullOrWhiteSpace(evidence)) return "NeedsReview";
        if (Regex.IsMatch(evidence, "\\b(Passed|Pass)\\b", RegexOptions.IgnoreCase)) return "Pass";
        if (Regex.IsMatch(evidence, "\\b(Failed|Fail)\\b", RegexOptions.IgnoreCase)) return "Fail";
        if (evidence.IndexOf("SQL ERROR", System.StringComparison.OrdinalIgnoreCase) >= 0) return "Fail";
        return "NeedsReview";
    }

    public static Task<string> BuildManualInstructionsAsync(ChecklistItem item)
        => Task.FromResult(BuildManualInstructions(item));

    // Builds manual verification steps tailored to a single checklist item from its
    // Id, Description and Category. No LLM/network call is made, so each item
    // deterministically gets its own item-specific guidance, not a shared template.
    public static string BuildManualInstructions(ChecklistItem item)
    {
        var description = (item.Description ?? string.Empty).Trim();
        var category = (item.Category ?? string.Empty).Trim();
        var topic = ClassifyTopic(description, category);
        var control = string.IsNullOrWhiteSpace(description) ? "this control" : $"\"{description}\"";

        var sb = new StringBuilder();
        sb.Append("Checklist: ").Append(item.Id).Append(" - ").AppendLine(description);
        if (!string.IsNullOrWhiteSpace(category))
            sb.Append("Audit area: ").AppendLine(category);
        sb.Append("Objective: Confirm that ").Append(control).AppendLine(" is correctly implemented and consistently enforced on the audited SQL Server instance, with objective evidence to support the finding.");
        sb.AppendLine();

        // Prerequisites — what the reviewer needs before starting, so the steps below
        // can be followed without guesswork.
        sb.AppendLine("## Prerequisites");
        sb.AppendLine("- Connect with SSMS or Azure Data Studio using an account that has at least VIEW SERVER STATE and VIEW DEFINITION (plus any control-specific permissions) on the databases in scope.");
        sb.Append("- Have your organisation's documented standard or policy for ").Append(control).AppendLine(" to hand, so you have a baseline to compare against.");
        sb.AppendLine("- Confirm which databases and objects are in scope for this audit before you begin.");
        sb.AppendLine();

        sb.AppendLine("## Manual Verification Steps:");
        var step = 1;
        sb.Append(step++).Append(". ").AppendLine(topic.Focus);
        foreach (var s in topic.Steps)
            sb.Append(step++).Append(". ").AppendLine(s);
        if (!string.IsNullOrWhiteSpace(topic.ExampleSql))
        {
            sb.Append(step++).AppendLine(". Run the query below in each in-scope database to gather objective evidence:");
            sb.AppendLine("```sql");
            sb.AppendLine(topic.ExampleSql.Trim());
            sb.AppendLine("```");
            sb.Append(step++).AppendLine(". Review the result set and flag every row that deviates from the documented standard.");
        }
        sb.Append(step++).Append(". Compare what you observe against your organisation's documented standard for ").Append(control).AppendLine(", noting each deviation and its scope (which objects/databases are affected).");
        sb.Append(step++).AppendLine(". Repeat across all in-scope databases — confirm the control holds everywhere, not just in a sample.");
        sb.Append(step++).AppendLine(". Record the concrete evidence you relied on (query results, setting values, object names, screenshots) so the finding can be reviewed later.");
        sb.AppendLine();

        // Evidence to capture — makes the finding auditable and repeatable.
        sb.AppendLine("## Evidence to Capture");
        sb.AppendLine("- The query output or configuration values you inspected.");
        sb.AppendLine("- The specific objects/settings that conform, and those that deviate from the standard.");
        sb.AppendLine("- A reference to the organisational standard used as the baseline for comparison.");
        sb.AppendLine();

        sb.AppendLine("## What indicates a PASS and a FAIL");
        sb.AppendLine("Pass:");
        sb.Append("- ").AppendLine(topic.PassHint);
        sb.AppendLine("- The control is applied consistently across all in-scope objects and databases, not just a sample.");
        sb.AppendLine("- You can point to concrete evidence (a query result, a setting value, or an object definition).");
        sb.AppendLine("Fail:");
        sb.Append("- ").AppendLine(topic.FailHint);
        sb.AppendLine("- The control is applied inconsistently or only partially across the in-scope scope.");
        sb.AppendLine("- No evidence of the control can be found on the instance.");
        sb.AppendLine();
        sb.AppendLine("If the evidence is mixed or incomplete, keep the item as Needs Review and gather more detail before deciding.");
        sb.AppendLine();

        sb.AppendLine("## Recommended Actions (if failed)");
        sb.Append("- ").AppendLine(topic.Remediation);
        sb.AppendLine("- Prioritise remediation by risk, and record the owner and a target completion date.");
        sb.AppendLine("- Raise the gap with the team that owns this instance and re-run this checklist item once the change has been deployed.");

        return sb.ToString().TrimEnd();
    }

    private sealed record TopicGuidance(
        string Focus,
        string[] Steps,
        string ExampleSql,
        string PassHint,
        string FailHint,
        string Remediation);

    private static TopicGuidance ClassifyTopic(string description, string category)
    {
        var text = (description + " " + category).ToLowerInvariant();
        bool Has(params string[] keys) => keys.Any(k => text.Contains(k));
        var control = string.IsNullOrWhiteSpace(description) ? "this control" : $"\"{description}\"";

        if (Has("select *", "select star", "explicit column"))
            return new TopicGuidance(
                "Look for `SELECT *` in production stored procedures, views and functions; production code should list explicit columns (EXISTS(SELECT *) is acceptable).",
                new[]
                {
                    "Search module definitions for `SELECT *` across the in-scope databases (Programmability nodes, or the query below).",
                    "For each hit, confirm whether it returns a result set (a real violation) or is an acceptable EXISTS(SELECT *) predicate.",
                },
                @"SELECT OBJECT_SCHEMA_NAME(o.object_id) AS [schema], OBJECT_NAME(o.object_id) AS [object], o.type_desc
FROM sys.sql_modules m
JOIN sys.objects o ON o.object_id = m.object_id
WHERE o.is_ms_shipped = 0 AND m.definition LIKE '%SELECT%*%'
ORDER BY [schema], [object];",
                "Production modules use explicit column lists; any `SELECT *` is limited to acceptable cases.",
                "One or more production modules use `SELECT *` to return data.",
                "Replace `SELECT *` with explicit column lists in the flagged modules.");

        if (Has("schema-qualif", "schema qualif", "dbo.", "two-part", "two part"))
            return new TopicGuidance(
                "Check that object references in code use two-part, schema-qualified names (e.g. dbo.Orders) rather than unqualified names (Orders).",
                new[]
                {
                    "Query sys.sql_expression_dependencies for references whose referenced_schema_name is NULL (unqualified).",
                    "Manually review modules that build dynamic SQL (EXEC / sp_executesql); those references are not in dependency metadata.",
                },
                @"SELECT QUOTENAME(OBJECT_SCHEMA_NAME(d.referencing_id)) + '.' + QUOTENAME(OBJECT_NAME(d.referencing_id)) AS referencing_object,
       d.referenced_entity_name
FROM sys.sql_expression_dependencies d
WHERE d.referenced_id IS NOT NULL AND d.referenced_schema_name IS NULL
ORDER BY referencing_object;",
                "Production modules reference objects with schema-qualified names; no unqualified references remain.",
                "One or more references omit the schema (e.g. FROM Orders instead of FROM dbo.Orders).",
                "Update the flagged modules to use schema-qualified (two-part) object names.");

        if (Has("set nocount", "nocount", "set option"))
            return new TopicGuidance(
                "Verify that stored procedures start with SET NOCOUNT ON and use appropriate SET options (ANSI_NULLS, QUOTED_IDENTIFIER ON).",
                new[]
                {
                    "Query sys.sql_modules for procedures whose definition lacks SET NOCOUNT ON and check uses_ansi_nulls / uses_quoted_identifier.",
                    "Spot-check a few flagged procedures in Object Explorer to confirm the SET options are genuinely missing.",
                },
                @"SELECT QUOTENAME(SCHEMA_NAME(p.schema_id)) + '.' + QUOTENAME(p.name) AS procedure_name,
       m.uses_ansi_nulls, m.uses_quoted_identifier,
       CASE WHEN UPPER(m.definition) LIKE '%SET NOCOUNT ON%' THEN 1 ELSE 0 END AS has_set_nocount_on
FROM sys.procedures p
JOIN sys.sql_modules m ON m.object_id = p.object_id
WHERE p.is_ms_shipped = 0
ORDER BY procedure_name;",
                "In-scope procedures use SET NOCOUNT ON together with ANSI_NULLS and QUOTED_IDENTIFIER ON.",
                "One or more procedures omit SET NOCOUNT ON or a required SET option.",
                "Add SET NOCOUNT ON and the required SET options to the flagged procedures.");

        if (Has("deprecated", "ntext", "old-style join", "old style join", "image type"))
            return new TopicGuidance(
                "Look for deprecated features and syntax: TEXT/NTEXT/IMAGE data types, old-style outer joins (*= and =*), and other deprecated constructs.",
                new[]
                {
                    "Scan module definitions for old-style joins and deprecated type usage.",
                    "Check column data types via sys.columns / sys.types for TEXT, NTEXT and IMAGE.",
                },
                @"SELECT OBJECT_SCHEMA_NAME(object_id) AS [schema], OBJECT_NAME(object_id) AS [object]
FROM sys.sql_modules
WHERE definition LIKE '%*=%' OR definition LIKE '%=*%'
   OR definition LIKE '% TEXT%' OR definition LIKE '%NTEXT%' OR definition LIKE '% IMAGE%'
ORDER BY [schema], [object];",
                "No deprecated types or syntax remain in production code or column definitions.",
                "Deprecated types (TEXT/NTEXT/IMAGE) or old-style joins are present.",
                "Migrate deprecated types to VARCHAR(MAX)/NVARCHAR(MAX)/VARBINARY(MAX) and modernise the join syntax.");

        if (Has("naming", "formatting"))
            return new TopicGuidance(
                "Review object and column names for consistency with the documented naming/formatting convention across schemas, tables, procedures and columns.",
                new[]
                {
                    "List objects and columns and compare their names against the agreed convention.",
                    "Note any objects that deviate (casing, prefixes, abbreviations) as evidence.",
                },
                @"SELECT o.type_desc, QUOTENAME(SCHEMA_NAME(o.schema_id)) + '.' + QUOTENAME(o.name) AS object_name
FROM sys.objects o
WHERE o.is_ms_shipped = 0
ORDER BY o.type_desc, object_name;",
                "Object and column names follow the documented convention consistently.",
                "Multiple objects deviate from the naming/formatting standard.",
                "Rename or refactor the non-conforming objects to match the documented convention.");

        if (Has("comment", "commented", "business rule"))
            return new TopicGuidance(
                "Confirm that complex modules contain explanatory comments and that business rules are documented in or alongside the code.",
                new[]
                {
                    "Open the longest / most complex modules and confirm meaningful comments explain the logic.",
                    "Check that business rules are captured in comments or linked documentation.",
                },
                @"SELECT QUOTENAME(OBJECT_SCHEMA_NAME(object_id)) + '.' + QUOTENAME(OBJECT_NAME(object_id)) AS module,
       LEN(definition) AS definition_length
FROM sys.sql_modules
ORDER BY definition_length DESC;",
                "Complex modules are commented and business rules are documented.",
                "Complex logic lacks comments or documented business rules.",
                "Add explanatory comments to the flagged modules and document the relevant business rules.");

        if (Has("index", "fragmentation"))
            return new TopicGuidance(
                "Inspect indexing: appropriate indexes exist, fragmentation is controlled, and there are no obviously unused or duplicate indexes.",
                new[]
                {
                    "Review indexes on the key tables and check fragmentation for the larger indexes.",
                    "Look for missing-index suggestions and unused indexes via the relevant DMVs.",
                },
                @"SELECT QUOTENAME(OBJECT_SCHEMA_NAME(i.object_id)) + '.' + QUOTENAME(OBJECT_NAME(i.object_id)) AS [table],
       i.name AS index_name, i.type_desc
FROM sys.indexes i
WHERE i.object_id > 100 AND i.type_desc <> 'HEAP'
ORDER BY [table], index_name;",
                "Indexing is appropriate, maintained, and free of significant fragmentation or redundant indexes.",
                "Key tables lack appropriate indexes, or fragmentation/duplicate indexes are unmanaged.",
                "Add, rebuild, or remove indexes as indicated and schedule regular index maintenance.");

        if (Has("deadlock"))
            return new TopicGuidance(
                "Confirm deadlocks are being captured (system_health Extended Events session or a dedicated XE session) and are reviewed/resolved.",
                new[]
                {
                    "Verify the system_health Extended Events session is running.",
                    "Query recent deadlock reports and confirm they are triaged.",
                },
                @"SELECT XEvent.value('(@timestamp)[1]', 'datetime2') AS deadlock_time
FROM (
    SELECT CAST(target_data AS XML) AS TargetData
    FROM sys.dm_xe_session_targets st
    JOIN sys.dm_xe_sessions s ON s.address = st.event_session_address
    WHERE s.name = 'system_health' AND st.target_name = 'ring_buffer'
) AS Data
CROSS APPLY TargetData.nodes('//RingBufferTarget/event[@name=""xml_deadlock_report""]') AS X(XEvent);",
                "Deadlocks are captured and there is evidence they are reviewed and resolved.",
                "Deadlock capture is not configured, or captured deadlocks are not acted upon.",
                "Enable deadlock capture (Extended Events) and establish a triage process for reported deadlocks.");

        if (Has("query store"))
            return new TopicGuidance(
                "Check that Query Store is enabled and appropriately configured on the in-scope databases.",
                new[]
                {
                    "Review Query Store options (state, capture mode, retention) for each database.",
                    "Confirm the actual state is READ_WRITE where the standard expects it.",
                },
                @"SELECT actual_state_desc, query_capture_mode_desc, max_storage_size_mb, stale_query_threshold_days
FROM sys.database_query_store_options;",
                "Query Store is ON (READ_WRITE) and configured per the standard.",
                "Query Store is OFF, unexpectedly READ_ONLY, or misconfigured.",
                "Enable and configure Query Store (capture mode, retention, storage) per the standard.");

        if (Has("backup", "retention", "restore", "recovery"))
            return new TopicGuidance(
                "Verify backups exist, run on the expected schedule, and that retention meets policy for the in-scope databases.",
                new[]
                {
                    "Review recent backup history for full/diff/log backups per database.",
                    "Confirm the most recent successful backups are within the required RPO and retention window.",
                },
                @"SELECT bs.database_name, bs.type, MAX(bs.backup_finish_date) AS last_backup
FROM msdb.dbo.backupset bs
GROUP BY bs.database_name, bs.type
ORDER BY bs.database_name, bs.type;",
                "Backups run on schedule and retention meets the documented policy.",
                "Backups are missing, stale, or retention is shorter than policy.",
                "Fix or schedule the required backups and align retention with policy.");

        if (Has("job", "agent", "scheduler", "etl"))
            return new TopicGuidance(
                "Inspect SQL Server Agent jobs: they exist, are owned appropriately, are scheduled, and their failures are captured/alerted.",
                new[]
                {
                    "Review the relevant Agent jobs, their owners and schedules.",
                    "Check recent job outcomes and confirm failures raise alerts to the responsible team.",
                },
                @"SELECT j.name AS job_name, SUSER_SNAME(j.owner_sid) AS owner, j.enabled
FROM msdb.dbo.sysjobs j
ORDER BY j.name;",
                "Relevant jobs exist, are owned, scheduled, and failures are alerted.",
                "Jobs are missing, unowned, disabled, or failures go unnoticed.",
                "Create/own/schedule the required jobs and configure failure notifications.");

        if (Has("permission", "role", "login", "privilege", "access control", "least privilege"))
            return new TopicGuidance(
                "Review logins, database users, role memberships and granted permissions to confirm least-privilege access.",
                new[]
                {
                    "Enumerate server logins and their fixed-server-role memberships (especially sysadmin).",
                    "Review database role memberships and explicit permission grants for over-privilege.",
                },
                @"SELECT sp.name AS principal, sp.type_desc, sp.is_disabled
FROM sys.server_principals sp
WHERE sp.type IN ('S','U','G') AND sp.name NOT LIKE '##%'
ORDER BY sp.type_desc, principal;",
                "Access follows least privilege; elevated roles are justified and documented.",
                "Excessive privileges (e.g. broad sysadmin/db_owner) exist without justification.",
                "Remove or reduce unjustified privileges and document any required elevated access.");

        if (Has("encrypt", "tde", "at rest", "always encrypted"))
            return new TopicGuidance(
                "Confirm encryption (TDE, column encryption, or Always Encrypted) is enabled where the standard requires it.",
                new[]
                {
                    "Check database encryption state for TDE across the in-scope databases.",
                    "Where column-level protection is required, confirm the relevant columns are encrypted.",
                },
                @"SELECT DB_NAME(database_id) AS [database], encryption_state, encryption_state_desc
FROM sys.dm_database_encryption_keys;",
                "Encryption is enabled and configured where required by the standard.",
                "Required encryption (TDE/column) is missing or disabled.",
                "Enable the required encryption and manage the associated keys per policy.");

        if (Has("mask", "subsetting", "sensitive", "non-prod", "non prod"))
            return new TopicGuidance(
                "Confirm sensitive data is masked and/or subset in non-production environments.",
                new[]
                {
                    "Identify columns holding sensitive data and confirm masking/subsetting is applied in non-prod.",
                    "Check for Dynamic Data Masking definitions where used.",
                },
                @"SELECT QUOTENAME(OBJECT_SCHEMA_NAME(mc.object_id)) + '.' + QUOTENAME(OBJECT_NAME(mc.object_id)) AS [table],
       c.name AS column_name, mc.masking_function
FROM sys.masked_columns mc
JOIN sys.columns c ON c.object_id = mc.object_id AND c.column_id = mc.column_id
ORDER BY [table], column_name;",
                "Sensitive data is masked or subset in non-production as required.",
                "Sensitive data is exposed unmasked in non-production.",
                "Apply masking/subsetting to the sensitive columns used in non-production.");

        // Default: still item-specific because it references this item's own description/category.
        var areaHint = string.IsNullOrWhiteSpace(category)
            ? "the relevant system catalog views / DMVs or Object Explorer node for this control"
            : $"the objects and settings related to '{category}' (via Object Explorer or the relevant catalog views / DMVs)";
        return new TopicGuidance(
            $"Identify the specific object, setting, job or process implied by {control} and inspect its current configuration on the instance.",
            new[]
            {
                $"Locate {areaHint}.",
                $"Capture the current configuration or definition that evidences whether {control} is met.",
            },
            string.Empty,
            $"{control} is implemented and configured as your organisation's standard requires.",
            $"{control} is missing, disabled, or configured differently from the standard.",
            $"Implement or correct {control} per your organisation's standard and capture documented evidence.");
    }
}
