-- Checklist: ETL is metadata-driven or well-modularized where appropriate
-- Scope: DATABASE
-- Scoring: 3 = metadata/control tables exist and at least half the ETL modules delegate to other modules or drive work from metadata; 2 = only one of those two signals is present; 1 = ETL modules exist with neither signal; 0 = no ETL modules and no metadata/control tables in this database

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(128) = DB_NAME();
DECLARE @Finding NVARCHAR(MAX) = 'ETL metadata and modularity evidence was unavailable in this database';
DECLARE @MetaTables INT = 0;
DECLARE @MetaList NVARCHAR(MAX) = '';
DECLARE @EtlProcs INT = 0;
DECLARE @Modular INT = 0;
DECLARE @ModularPct DECIMAL(6, 2) = 0;
DECLARE @ReadError BIT = 0;

BEGIN TRY
    SELECT @MetaTables = COUNT(*),
           @MetaList = ISNULL(LEFT(STRING_AGG(CONVERT(NVARCHAR(MAX), s.name + '.' + t.name), ', '), 300), '')
    FROM sys.tables AS t
    INNER JOIN sys.schemas AS s ON s.schema_id = t.schema_id
    WHERE t.is_ms_shipped = 0
      AND (t.name LIKE '%config%' OR t.name LIKE '%control%' OR t.name LIKE '%metadata%'
           OR t.name LIKE '%mapping%' OR t.name LIKE '%parameter%' OR t.name LIKE '%watermark%'
           OR t.name LIKE '%registry%' OR t.name LIKE '%definition%');
END TRY
BEGIN CATCH
    SET @ReadError = 1;
END CATCH

BEGIN TRY
    SELECT @EtlProcs = COUNT(*),
           @Modular = ISNULL(SUM(p.IsModular), 0)
    FROM
    (
        SELECT CASE WHEN mo.definition LIKE '%sp[_]executesql%' THEN 1
                    WHEN EXISTS (SELECT 1
                                 FROM sys.sql_expression_dependencies AS d
                                 INNER JOIN sys.objects AS o ON o.object_id = d.referenced_id
                                 WHERE d.referencing_id = pr.object_id
                                   AND o.type IN ('P', 'FN', 'IF', 'TF')) THEN 1
                    ELSE 0 END AS IsModular
        FROM sys.procedures AS pr
        INNER JOIN sys.sql_modules AS mo ON mo.object_id = pr.object_id
        WHERE pr.is_ms_shipped = 0
          AND (pr.name LIKE '%etl%' OR pr.name LIKE '%load%' OR pr.name LIKE '%stag%'
               OR pr.name LIKE '%transform%' OR pr.name LIKE '%import%' OR pr.name LIKE '%extract%'
               OR pr.name LIKE '%ingest%' OR pr.name LIKE '%populate%' OR pr.name LIKE '%refresh%')
    ) AS p;
END TRY
BEGIN CATCH
    SET @ReadError = 1;
END CATCH

SET @ModularPct = CASE WHEN @EtlProcs = 0 THEN 0
                       ELSE CONVERT(DECIMAL(6, 2), 100.0 * @Modular / NULLIF(@EtlProcs, 0)) END;

SET @Score = CASE WHEN @ReadError = 1 AND @MetaTables = 0 AND @EtlProcs = 0 THEN 0
                  WHEN @MetaTables > 0 AND @ModularPct >= 50 THEN 3
                  WHEN @MetaTables > 0 OR @ModularPct >= 50 THEN 2
                  WHEN @EtlProcs > 0 THEN 1
                  ELSE 0 END;

SET @Finding = CASE
    WHEN @ReadError = 1 AND @MetaTables = 0 AND @EtlProcs = 0
        THEN 'Table and module catalog metadata in this database could not be read'
    WHEN @MetaTables = 0 AND @EtlProcs = 0
        THEN 'No ETL-named stored procedures and no configuration, control, mapping or metadata tables exist in this database; any ETL for it is implemented outside the database'
    ELSE CONCAT('ETL metadata/control/mapping tables = ', @MetaTables,
                CASE WHEN LEN(@MetaList) > 0 THEN ' (' + @MetaList + ')' ELSE '' END,
                '; ETL-named procedures = ', @EtlProcs,
                '; of those, driven by metadata or delegating to other modules = ', @Modular,
                ' (', @ModularPct, '%)')
END;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;
