-- Checklist: tempdb configured appropriately (multiple files, sizing) — SQL Server/MI
-- Scope: SERVER
-- Scoring: 3: Fully compliant (>=2 files, pre-sized, fixed MB growth, equal sizes, matches CPU count <=8). 2: Mostly compliant (>=2 files, minor gaps like % growth, uneven sizes, or count mismatch). 1: Partially compliant (1 file, or zero initial size). 0: Non-compliant or evaluation fails.

DECLARE @Result NVARCHAR(10);
DECLARE @Score INT;
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);
DECLARE @EngineEdition INT;
DECLARE @CpuCount INT;
DECLARE @FileCount INT;
DECLARE @MinSizeMB INT;
DECLARE @MaxSizeMB INT;
DECLARE @HasPercentageGrowth BIT;
DECLARE @HasZeroSize BIT;

SET @EngineEdition = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
SET @DatabaseQueried = 'master';

IF @EngineEdition = 5
BEGIN
    SET @Score = 3;
    SET @Finding = 'Azure SQL Database: tempdb is managed by the platform. Manual configuration is not supported.';
END
ELSE
BEGIN
    BEGIN TRY
        SELECT @CpuCount = cpu_count FROM sys.dm_os_sys_info;
        
        SELECT 
            @FileCount = COUNT(*),
            @MinSizeMB = MIN(size * 8 / 1024),
            @MaxSizeMB = MAX(size * 8 / 1024),
            @HasPercentageGrowth = MAX(CASE WHEN growth > 0 AND is_percent_growth = 1 THEN 1 ELSE 0 END),
            @HasZeroSize = MAX(CASE WHEN size = 0 THEN 1 ELSE 0 END)
        FROM sys.master_files
        WHERE database_id = 2 AND type = 0;

        IF @FileCount IS NULL OR @FileCount = 0
        BEGIN
            SET @Score = 0;
            SET @Finding = 'No tempdb data files found.';
        END
        ELSE IF @FileCount = 1
        BEGIN
            SET @Score = 1;
            SET @Finding = 'tempdb has only 1 data file. Recommended: multiple files matching logical CPU count (max 8).';
        END
        ELSE
        BEGIN
            IF @HasZeroSize = 1
            BEGIN
                SET @Score = 1;
                SET @Finding = 'tempdb has ' + CAST(@FileCount AS NVARCHAR) + ' data files, but one or more files have zero initial size.';
            END
            ELSE IF @HasPercentageGrowth = 1
            BEGIN
                SET @Score = 2;
                SET @Finding = 'tempdb has ' + CAST(@FileCount AS NVARCHAR) + ' pre-sized data files, but autogrowth is set to percentage. Recommended: fixed MB.';
            END
            ELSE IF @MinSizeMB <> @MaxSizeMB
            BEGIN
                SET @Score = 2;
                SET @Finding = 'tempdb has ' + CAST(@FileCount AS NVARCHAR) + ' pre-sized data files with fixed MB growth, but file sizes are uneven (' + CAST(@MinSizeMB AS NVARCHAR) + 'MB to ' + CAST(@MaxSizeMB AS NVARCHAR) + 'MB).';
            END
            ELSE IF @FileCount < @CpuCount AND @CpuCount <= 8
            BEGIN
                SET @Score = 2;
                SET @Finding = 'tempdb has ' + CAST(@FileCount AS NVARCHAR) + ' pre-sized data files with fixed MB growth and equal sizes, but count (' + CAST(@FileCount AS NVARCHAR) + ') is less than logical CPU count (' + CAST(@CpuCount AS NVARCHAR) + ').';
            END
            ELSE IF @FileCount > 8
            BEGIN
                SET @Score = 2;
                SET @Finding = 'tempdb has ' + CAST(@FileCount AS NVARCHAR) + ' data files. Recommended: cap at 8 files to reduce scheduler contention.';
            END
            ELSE
            BEGIN
                SET @Score = 3;
                SET @Finding = 'tempdb is optimally configured: ' + CAST(@FileCount AS NVARCHAR) + ' data files, equal pre-sized sizes (' + CAST(@MinSizeMB AS NVARCHAR) + 'MB each), fixed MB autogrowth, matching CPU count.';
            END
        END
    END TRY
    BEGIN CATCH
        SET @Score = 0;
        SET @Finding = 'Evaluation failed: ' + ERROR_MESSAGE();
    END CATCH;
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;