SET NOCOUNT ON;
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @DbName NVARCHAR(256);
DECLARE @Sql NVARCHAR(MAX);
DECLARE @DbScore INT;
DECLARE @IsCdcEnabled BIT;
DECLARE @IsCtEnabled BIT;
DECLARE @JobExists INT;
DECLARE @JobEnabled INT;
DECLARE @RetentionDays INT;

CREATE TABLE #DbResults (DbName NVARCHAR(256), DbScore INT);

DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
SELECT name FROM sys.databases
WHERE database_id > 4 AND state = 0;

OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @DbName;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @IsCdcEnabled = 0;
    SET @IsCtEnabled = 0;
    SET @JobExists = 0;
    SET @JobEnabled = 0;
    SET @RetentionDays = 0;
    SET @DbScore = 3; -- Default: feature not enabled

    -- Check if CDC or Change Tracking is enabled in this database
    SET @Sql = N'
        SELECT @IsCdcEnabled = is_cdc_enabled, @IsCtEnabled = is_change_tracking_on
        FROM sys.databases
        WHERE database_id = DB_ID();
    ';
    EXEC sp_executesql @Sql, N'@IsCdcEnabled BIT OUTPUT, @IsCtEnabled BIT OUTPUT', @IsCdcEnabled OUTPUT, @IsCtEnabled OUTPUT;

    IF @IsCdcEnabled = 1 OR @IsCtEnabled = 1
    BEGIN
        -- Check for cleanup job in msdb (on-prem) or assume platform-managed (Azure)
        IF OBJECT_ID('msdb.dbo.sysjobs') IS NOT NULL
        BEGIN
            SET @Sql = N'
                SELECT @JobExists = COUNT(1), @JobEnabled = MAX(CAST(enabled AS INT))
                FROM msdb.dbo.sysjobs
                WHERE name LIKE ''%cleanup%'' AND name LIKE ''%'' + @DbName + ''%'';
            ';
            EXEC sp_executesql @Sql, N'@DbName NVARCHAR(256), @JobExists INT OUTPUT, @JobEnabled INT OUTPUT', @DbName, @JobExists OUTPUT, @JobEnabled OUTPUT;
        END
        ELSE
        BEGIN
            SET @JobExists = 1;
            SET @JobEnabled = 1; -- Azure platform manages cleanup automatically
        END

        IF @JobExists = 0 OR @JobEnabled = 0
        BEGIN
            SET @DbScore = 0; -- Enabled but no cleanup job or job disabled
        END
        ELSE
        BEGIN
            -- Check retention period for Change Tracking
            IF @IsCtEnabled = 1
            BEGIN
                SET @Sql = N'
                    SELECT @RetentionDays = ISNULL(retention_period, 0)
                    FROM sys.change_tracking_databases
                    WHERE database_id = DB_ID();
                ';
                EXEC sp_executesql @Sql, N'@RetentionDays INT OUTPUT', @RetentionDays OUTPUT;

                IF @RetentionDays > 0
                BEGIN
                    SET @DbScore = 2; -- Job enabled and retention configured
                END
                ELSE
                BEGIN
                    SET @DbScore = 1; -- Job exists but retention misconfigured/missing
                END
            END
            ELSE
            BEGIN
                SET @DbScore = 2; -- CDC retention is configured via job step, assume compliant if job exists
            END
        END
    END

    INSERT INTO #DbResults VALUES (@DbName, @DbScore);
    FETCH NEXT FROM db_cursor INTO @DbName;
END
CLOSE db_cursor;
DEALLOCATE db_cursor;

SET @Score = ISNULL((SELECT MIN(DbScore) FROM #DbResults), 3);
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
DROP TABLE #DbResults;
SELECT @Result AS Result, @Score AS Score;