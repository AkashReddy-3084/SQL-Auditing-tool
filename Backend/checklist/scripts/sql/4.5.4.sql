-- Checklist: [Keys & Constraints] Check constraints enforce domain rules where practical
-- Scope: DATABASE
-- Scoring: 3 = at least 25% of user tables carry a check constraint and none is disabled or untrusted; 2 = at least 10% carry one, with under 25% of constraints disabled or untrusted; 1 = under 10% carry one, or 25% or more of constraints are disabled/untrusted; 0 = user tables exist but no check constraint is defined

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(128) = DB_NAME();
DECLARE @Finding NVARCHAR(MAX) = 'Check constraint coverage could not be determined in the current database';

DECLARE @TableCount INT = -1;
DECLARE @TablesWithCheck INT = 0;
DECLARE @CheckCount INT = 0;
DECLARE @DisabledChecks INT = 0;
DECLARE @UntrustedChecks INT = 0;
DECLARE @WeakChecks INT = 0;
DECLARE @Coverage DECIMAL(6, 2) = 0;
DECLARE @WeakPct DECIMAL(6, 2) = 0;
DECLARE @WeakList NVARCHAR(MAX) = 'none';

BEGIN TRY
    SELECT @TableCount = COUNT(*)
    FROM sys.tables
    WHERE is_ms_shipped = 0
      AND temporal_type <> 1;

    SELECT @CheckCount      = COUNT(*),
           @TablesWithCheck = COUNT(DISTINCT cc.parent_object_id),
           @DisabledChecks  = ISNULL(SUM(CASE WHEN cc.is_disabled = 1 THEN 1 ELSE 0 END), 0),
           @UntrustedChecks = ISNULL(SUM(CASE WHEN cc.is_disabled = 0 AND cc.is_not_trusted = 1 THEN 1 ELSE 0 END), 0)
    FROM sys.check_constraints AS cc
    INNER JOIN sys.tables AS t ON t.object_id = cc.parent_object_id
    WHERE t.is_ms_shipped = 0;

    SET @WeakList = ISNULL(LEFT((SELECT STRING_AGG(CONVERT(NVARCHAR(MAX),
                                        s.name + '.' + t.name + '.' + cc.name +
                                        CASE WHEN cc.is_disabled = 1 THEN ' (disabled)' ELSE ' (untrusted)' END), ', ')
                                 FROM sys.check_constraints AS cc
                                 INNER JOIN sys.tables AS t ON t.object_id = cc.parent_object_id
                                 INNER JOIN sys.schemas AS s ON s.schema_id = t.schema_id
                                 WHERE t.is_ms_shipped = 0
                                   AND (cc.is_disabled = 1 OR cc.is_not_trusted = 1)), 900), 'none');
END TRY
BEGIN CATCH
    SET @TableCount = -1;
END CATCH;

SET @WeakChecks = @DisabledChecks + @UntrustedChecks;
SET @Coverage = ISNULL(CONVERT(DECIMAL(6, 2), @TablesWithCheck * 100.0 / NULLIF(@TableCount, 0)), 0.00);
SET @WeakPct = ISNULL(CONVERT(DECIMAL(6, 2), @WeakChecks * 100.0 / NULLIF(@CheckCount, 0)), 0.00);

SET @Score = CASE
    WHEN @TableCount < 0 THEN 0
    WHEN @TableCount = 0 THEN 3
    WHEN @CheckCount = 0 THEN 0
    WHEN @WeakPct >= 25.00 THEN 1
    WHEN @Coverage >= 25.00 AND @WeakChecks = 0 THEN 3
    WHEN @Coverage >= 10.00 THEN 2
    ELSE 1
END;

SET @Finding = CASE
    WHEN @TableCount < 0
        THEN CONCAT('Catalog views in ', @DatabaseQueried, ' could not be read, so check constraint coverage was not measured.')
    WHEN @TableCount = 0
        THEN CONCAT('No user tables found in ', @DatabaseQueried, '; there are no domain rules to enforce with check constraints.')
    WHEN @CheckCount = 0
        THEN CONCAT('No check constraints exist on any of the ', @TableCount, ' user table(s) in ', @DatabaseQueried,
                    '; domain rules are not enforced by the engine.')
    ELSE CONCAT(@CheckCount, ' check constraint(s) covering ', @TablesWithCheck, ' of ', @TableCount,
                ' user table(s) in ', @DatabaseQueried, ' (', @Coverage, '% table coverage); ',
                @DisabledChecks, ' disabled and ', @UntrustedChecks, ' enabled-but-untrusted (',
                @WeakPct, '% not enforcing): ', @WeakList, '.')
END;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;
