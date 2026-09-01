-- Checklist: [Keys & Constraints] Primary keys defined on all tables
-- Scope: DATABASE
-- Scoring: 3 = every user table has a primary key; 2 = at least 95% do; 1 = at least 75% do; 0 = under 75%, or the catalog could not be read

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(128) = DB_NAME();
DECLARE @Finding NVARCHAR(MAX) = 'Primary key coverage could not be determined in the current database';

DECLARE @TotalTables INT = -1;
DECLARE @WithPk INT = 0;
DECLARE @WithoutPk INT = 0;
DECLARE @PctWithPk DECIMAL(6, 2) = 0;
DECLARE @MissingList NVARCHAR(MAX) = 'none';

BEGIN TRY
    SELECT @TotalTables = COUNT(*),
           @WithPk = ISNULL(SUM(CASE WHEN has_pk = 1 THEN 1 ELSE 0 END), 0)
    FROM (
        SELECT t.object_id,
               CASE WHEN EXISTS (SELECT 1 FROM sys.key_constraints AS kc
                                WHERE kc.parent_object_id = t.object_id
                                  AND kc.type = 'PK')
                    THEN 1 ELSE 0 END AS has_pk
        FROM sys.tables AS t
        WHERE t.is_ms_shipped = 0
          AND t.temporal_type <> 1
    ) AS table_check;

    SET @MissingList = ISNULL(LEFT((SELECT STRING_AGG(CONVERT(NVARCHAR(MAX), s.name + '.' + t.name) COLLATE Latin1_General_CI_AS, ', ' COLLATE Latin1_General_CI_AS)
                                    FROM sys.tables AS t
                                    INNER JOIN sys.schemas AS s ON s.schema_id = t.schema_id
                                    WHERE t.is_ms_shipped = 0
                                      AND t.temporal_type <> 1
                                      AND NOT EXISTS (SELECT 1 FROM sys.key_constraints AS kc
                                                      WHERE kc.parent_object_id = t.object_id
                                                        AND kc.type = 'PK')), 900), 'none');
END TRY
BEGIN CATCH
    SET @TotalTables = -1;
END CATCH;

SET @WithoutPk = CASE WHEN @TotalTables > 0 THEN @TotalTables - @WithPk ELSE 0 END;

SET @PctWithPk = ISNULL(CONVERT(DECIMAL(6, 2), @WithPk * 100.0 / NULLIF(@TotalTables, 0)), 100.00);

SET @Score = CASE
    WHEN @TotalTables < 0 THEN 0
    WHEN @TotalTables = 0 THEN 3
    WHEN @WithoutPk = 0 THEN 3
    WHEN @PctWithPk >= 95.00 THEN 2
    WHEN @PctWithPk >= 75.00 THEN 1
    ELSE 0
END;

SET @Finding = CASE
    WHEN @TotalTables < 0
        THEN CONCAT('Catalog views in ', @DatabaseQueried, ' could not be read, so primary key coverage was not measured.')
    WHEN @TotalTables = 0
        THEN CONCAT('No user tables found in ', @DatabaseQueried, '; there are no tables that could be missing a primary key.')
    WHEN @WithoutPk = 0
        THEN CONCAT('All ', @TotalTables, ' user table(s) in ', @DatabaseQueried, ' have a primary key defined.')
    ELSE CONCAT(@WithPk, ' of ', @TotalTables, ' user table(s) in ', @DatabaseQueried,
                ' have a primary key (', @PctWithPk, '% coverage); ', @WithoutPk,
                ' table(s) have none: ', @MissingList, '.')
END;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;
