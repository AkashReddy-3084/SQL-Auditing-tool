-- Checklist: [Keys & Constraints] Foreign keys enforced where integrity matters (or documented trusted-by-ETL exceptions)
-- Scope: DATABASE
-- Scoring: 3 = foreign keys exist and all are enabled and trusted (or the database has fewer than two user tables); 2 = under 5% are disabled or untrusted; 1 = under 25% are disabled or untrusted; 0 = 25% or more are disabled/untrusted, or two or more user tables carry no foreign key at all

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(128) = DB_NAME();
DECLARE @Finding NVARCHAR(MAX) = 'Foreign key enforcement could not be determined in the current database';

DECLARE @TableCount INT = -1;
DECLARE @FkCount INT = 0;
DECLARE @DisabledFks INT = 0;
DECLARE @UntrustedFks INT = 0;
DECLARE @WeakFks INT = 0;
DECLARE @WeakPct DECIMAL(6, 2) = 0;
DECLARE @WeakList NVARCHAR(MAX) = 'none';

BEGIN TRY
    SELECT @TableCount = COUNT(*)
    FROM sys.tables
    WHERE is_ms_shipped = 0
      AND temporal_type <> 1;

    SELECT @FkCount      = COUNT(*),
           @DisabledFks  = ISNULL(SUM(CASE WHEN fk.is_disabled = 1 THEN 1 ELSE 0 END), 0),
           @UntrustedFks = ISNULL(SUM(CASE WHEN fk.is_disabled = 0 AND fk.is_not_trusted = 1 THEN 1 ELSE 0 END), 0)
    FROM sys.foreign_keys AS fk
    INNER JOIN sys.tables AS t ON t.object_id = fk.parent_object_id
    WHERE t.is_ms_shipped = 0;

    SET @WeakList = ISNULL(LEFT((SELECT STRING_AGG(CONVERT(NVARCHAR(MAX),
                                        s.name + '.' + t.name + '.' + fk.name +
                                        CASE WHEN fk.is_disabled = 1 THEN ' (disabled)' ELSE ' (untrusted)' END), ', ')
                                 FROM sys.foreign_keys AS fk
                                 INNER JOIN sys.tables AS t ON t.object_id = fk.parent_object_id
                                 INNER JOIN sys.schemas AS s ON s.schema_id = t.schema_id
                                 WHERE t.is_ms_shipped = 0
                                   AND (fk.is_disabled = 1 OR fk.is_not_trusted = 1)), 900), 'none');
END TRY
BEGIN CATCH
    SET @TableCount = -1;
END CATCH;

SET @WeakFks = @DisabledFks + @UntrustedFks;
SET @WeakPct = ISNULL(CONVERT(DECIMAL(6, 2), @WeakFks * 100.0 / NULLIF(@FkCount, 0)), 0.00);

SET @Score = CASE
    WHEN @TableCount < 0 THEN 0
    WHEN @TableCount < 2 THEN 3
    WHEN @FkCount = 0 THEN 0
    WHEN @WeakFks = 0 THEN 3
    WHEN @WeakPct < 5.00 THEN 2
    WHEN @WeakPct < 25.00 THEN 1
    ELSE 0
END;

SET @Finding = CASE
    WHEN @TableCount < 0
        THEN CONCAT('Catalog views in ', @DatabaseQueried, ' could not be read, so foreign key enforcement was not measured.')
    WHEN @TableCount = 0
        THEN CONCAT('No user tables found in ', @DatabaseQueried, '; referential integrity enforcement is not applicable.')
    WHEN @TableCount = 1
        THEN CONCAT(@DatabaseQueried, ' holds a single user table, so no cross-table foreign key relationship is possible; foreign keys defined = ', @FkCount, '.')
    WHEN @FkCount = 0
        THEN CONCAT('No foreign keys are defined across ', @TableCount, ' user table(s) in ', @DatabaseQueried,
                    '; referential integrity is not enforced by the engine and any ETL-trusted exception is undocumented here.')
    WHEN @WeakFks = 0
        THEN CONCAT('All ', @FkCount, ' foreign key(s) on ', @TableCount, ' user table(s) in ', @DatabaseQueried,
                    ' are enabled and trusted (disabled = 0, untrusted = 0).')
    ELSE CONCAT(@FkCount, ' foreign key(s) on ', @TableCount, ' user table(s) in ', @DatabaseQueried,
                '; ', @DisabledFks, ' disabled and ', @UntrustedFks, ' enabled-but-untrusted (',
                @WeakPct, '% not enforcing integrity): ', @WeakList, '.')
END;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;
