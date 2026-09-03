-- Checklist: CDC / Change Tracking configured and maintained correctly where used
-- Scope: DATABASE
-- Scoring: 3 = tracked objects are all consistently configured; 2 = neither mechanism is in use, or tracking is enabled at database level with no tracked table; 1 = under 25% of tracked objects are inconsistent; 0 = 25% or more are inconsistent, or the tracking catalog could not be read

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(128) = DB_NAME();
DECLARE @Finding NVARCHAR(MAX) = 'CDC and Change Tracking evidence was unavailable in this database';
DECLARE @Sql NVARCHAR(MAX);
DECLARE @CdcTables INT = 0;
DECLARE @CdcNames NVARCHAR(MAX) = '';
DECLARE @CdcInstances INT = 0;
DECLARE @CtTables INT = 0;
DECLARE @CtOrphans INT = 0;
DECLARE @CtVersion BIGINT = NULL;
DECLARE @Tracked INT = 0;
DECLARE @Bad INT = 0;
DECLARE @BadPct DECIMAL(6, 2) = 0;
DECLARE @ReadError BIT = 0;

IF COL_LENGTH('sys.tables', 'is_tracked_by_cdc') IS NOT NULL
BEGIN
    BEGIN TRY
        SET @Sql = N'SELECT @c = COUNT(*), @n = ISNULL(LEFT(STRING_AGG(CONVERT(NVARCHAR(MAX), s.name + N''.'' + t.name), N'', ''), 300), N'''') FROM sys.tables AS t INNER JOIN sys.schemas AS s ON s.schema_id = t.schema_id WHERE t.is_tracked_by_cdc = 1;';
        EXEC sp_executesql @Sql, N'@c INT OUTPUT, @n NVARCHAR(MAX) OUTPUT', @c = @CdcTables OUTPUT, @n = @CdcNames OUTPUT;
    END TRY
    BEGIN CATCH
        SET @ReadError = 1;
    END CATCH
END

IF OBJECT_ID('cdc.change_tables') IS NOT NULL
BEGIN
    BEGIN TRY
        SET @Sql = N'SELECT @c = COUNT(*) FROM cdc.change_tables;';
        EXEC sp_executesql @Sql, N'@c INT OUTPUT', @c = @CdcInstances OUTPUT;
    END TRY
    BEGIN CATCH
        SET @ReadError = 1;
    END CATCH
END

BEGIN TRY
    SET @CtVersion = CHANGE_TRACKING_CURRENT_VERSION();
END TRY
BEGIN CATCH
    SET @CtVersion = NULL;
END CATCH

IF OBJECT_ID('sys.change_tracking_tables') IS NOT NULL
BEGIN
    BEGIN TRY
        SET @Sql = N'SELECT @c = COUNT(*), @o = ISNULL(SUM(CASE WHEN t.object_id IS NULL THEN 1 ELSE 0 END), 0) FROM sys.change_tracking_tables AS ct LEFT JOIN sys.tables AS t ON t.object_id = ct.object_id;';
        EXEC sp_executesql @Sql, N'@c INT OUTPUT, @o INT OUTPUT', @c = @CtTables OUTPUT, @o = @CtOrphans OUTPUT;
    END TRY
    BEGIN CATCH
        SET @ReadError = 1;
    END CATCH
END

SET @Tracked = ISNULL(@CdcTables, 0) + ISNULL(@CtTables, 0);
SET @Bad = CASE WHEN ISNULL(@CdcTables, 0) > ISNULL(@CdcInstances, 0)
                THEN ISNULL(@CdcTables, 0) - ISNULL(@CdcInstances, 0) ELSE 0 END + ISNULL(@CtOrphans, 0);
SET @BadPct = CASE WHEN @Tracked = 0 THEN 0
                   ELSE CONVERT(DECIMAL(6, 2), 100.0 * @Bad / NULLIF(@Tracked, 0)) END;

SET @Score = CASE WHEN @ReadError = 1 AND @Tracked = 0 THEN 0
                  WHEN @Tracked = 0 THEN 2
                  WHEN @Bad = 0 THEN 3
                  WHEN @BadPct < 25 THEN 1
                  ELSE 0 END;

SET @Finding = CASE
    WHEN @ReadError = 1 AND @Tracked = 0
        THEN 'The CDC and Change Tracking catalog views in this database could not be read'
    WHEN @Tracked = 0 AND @CtVersion IS NOT NULL
        THEN CONCAT('Change Tracking is enabled on this database (current version ', @CtVersion,
                    ') but no table is tracked, and no table is marked is_tracked_by_cdc')
    WHEN @Tracked = 0
        THEN 'Neither mechanism is in use in this database: 0 tables marked is_tracked_by_cdc and 0 tracked entries in sys.change_tracking_tables'
    ELSE CONCAT('CDC-tracked tables = ', ISNULL(@CdcTables, 0),
                ', capture instances in cdc.change_tables = ', ISNULL(@CdcInstances, 0),
                '; Change Tracking tables = ', ISNULL(@CtTables, 0),
                ', entries pointing at a missing table = ', ISNULL(@CtOrphans, 0),
                '; inconsistently configured tracked objects = ', @Bad, ' (', @BadPct, '%)',
                CASE WHEN LEN(@CdcNames) > 0 THEN '; CDC tables: ' + @CdcNames ELSE '' END)
END;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;
