SET NOCOUNT ON;

DECLARE @Result NVARCHAR(50) = N'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(500) = N'SERVER-WIDE';
DECLARE @Finding NVARCHAR(MAX) = N'Storage autogrowth configuration could not be determined.';

DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);

CREATE TABLE #FileGrowth
(
    DatabaseName    SYSNAME         NOT NULL,
    LogicalFileName SYSNAME         NOT NULL,
    FileCategory    NVARCHAR(10)    NOT NULL,
    IsPercentGrowth BIT             NOT NULL,
    GrowthValue     INT             NOT NULL,
    GrowthMB        DECIMAL(18, 2)  NULL,
    GrowthPercent   INT             NULL,
    MaxSizeValue    INT             NOT NULL,
    CurrentSizeMB   DECIMAL(18, 2)  NOT NULL
);

BEGIN TRY
    IF @EngineEdition = 5
    BEGIN
        INSERT INTO #FileGrowth
            (DatabaseName, LogicalFileName, FileCategory, IsPercentGrowth, GrowthValue, GrowthMB, GrowthPercent, MaxSizeValue, CurrentSizeMB)
        SELECT
            DB_NAME(),
            df.name,
            CASE df.type WHEN 0 THEN N'DATA' WHEN 1 THEN N'LOG' ELSE N'OTHER' END,
            df.is_percent_growth,
            df.growth,
            CASE WHEN df.is_percent_growth = 0 THEN CAST(df.growth * 8.0 / 1024.0 AS DECIMAL(18, 2)) END,
            CASE WHEN df.is_percent_growth = 1 THEN df.growth END,
            df.max_size,
            CAST(df.size * 8.0 / 1024.0 AS DECIMAL(18, 2))
        FROM sys.database_files AS df
        WHERE df.type IN (0, 1);

        SET @DatabaseQueried = DB_NAME();
    END
    ELSE
    BEGIN
        INSERT INTO #FileGrowth
            (DatabaseName, LogicalFileName, FileCategory, IsPercentGrowth, GrowthValue, GrowthMB, GrowthPercent, MaxSizeValue, CurrentSizeMB)
        SELECT
            d.name,
            mf.name,
            CASE mf.type WHEN 0 THEN N'DATA' WHEN 1 THEN N'LOG' ELSE N'OTHER' END,
            mf.is_percent_growth,
            mf.growth,
            CASE WHEN mf.is_percent_growth = 0 THEN CAST(mf.growth * 8.0 / 1024.0 AS DECIMAL(18, 2)) END,
            CASE WHEN mf.is_percent_growth = 1 THEN mf.growth END,
            mf.max_size,
            CAST(mf.size * 8.0 / 1024.0 AS DECIMAL(18, 2))
        FROM sys.master_files AS mf
        INNER JOIN sys.databases AS d
            ON d.database_id = mf.database_id
        WHERE mf.type IN (0, 1)
          AND d.state = 0
          AND d.database_id <> 2;
    END
END TRY
BEGIN CATCH
    SET @Finding = N'File metadata could not be read: ' + ERROR_MESSAGE();
END CATCH;

DECLARE @TotalFiles          INT = 0;
DECLARE @DatabaseCount       INT = 0;
DECLARE @PercentGrowthFiles  INT = 0;
DECLARE @SmallFixedFiles     INT = 0;
DECLARE @DisabledGrowthFiles INT = 0;
DECLARE @CappedFiles         INT = 0;
DECLARE @BadFiles            INT = 0;
DECLARE @BadPercent          DECIMAL(9, 2) = 0;

SELECT
    @TotalFiles          = COUNT(*),
    @DatabaseCount       = COUNT(DISTINCT f.DatabaseName),
    @PercentGrowthFiles  = ISNULL(SUM(CASE WHEN f.IsPercentGrowth = 1 AND f.GrowthValue > 0 THEN 1 ELSE 0 END), 0),
    @SmallFixedFiles     = ISNULL(SUM(CASE WHEN f.IsPercentGrowth = 0 AND f.GrowthValue > 0 AND f.GrowthMB < 64 THEN 1 ELSE 0 END), 0),
    @DisabledGrowthFiles = ISNULL(SUM(CASE WHEN f.GrowthValue = 0 THEN 1 ELSE 0 END), 0),
    @CappedFiles         = ISNULL(SUM(CASE WHEN f.MaxSizeValue > 0 AND f.MaxSizeValue <> 268435456 THEN 1 ELSE 0 END), 0)
FROM #FileGrowth AS f;

SET @BadFiles = @PercentGrowthFiles + @SmallFixedFiles + @DisabledGrowthFiles;

DECLARE @Offenders NVARCHAR(MAX) = N'';

IF @TotalFiles > 0 AND @BadFiles > 0
BEGIN
    SET @BadPercent = CAST(@BadFiles AS DECIMAL(9, 2)) * 100.0 / CAST(@TotalFiles AS DECIMAL(9, 2));

    SELECT @Offenders = STUFF(
        (
            SELECT TOP (5)
                N'; ' + f.DatabaseName + N'.' + f.LogicalFileName + N' [' + f.FileCategory + N'] '
                + CASE
                    WHEN f.GrowthValue = 0 THEN N'autogrowth disabled'
                    WHEN f.IsPercentGrowth = 1 THEN N'percent growth ' + CAST(f.GrowthPercent AS NVARCHAR(10)) + N'%'
                    ELSE N'fixed growth ' + CAST(f.GrowthMB AS NVARCHAR(20)) + N' MB'
                  END
            FROM #FileGrowth AS f
            WHERE f.GrowthValue = 0
               OR f.IsPercentGrowth = 1
               OR (f.IsPercentGrowth = 0 AND f.GrowthMB < 64)
            ORDER BY f.DatabaseName, f.LogicalFileName
            FOR XML PATH(''), TYPE
        ).value('.', 'NVARCHAR(MAX)'), 1, 2, N'');

    SET @Offenders = ISNULL(@Offenders, N'none listed');
END

IF @TotalFiles = 0
BEGIN
    SET @Score = 0;
    SET @Finding = N'No data or log file metadata was returned. Autogrowth settings could not be assessed - verify permissions (VIEW ANY DEFINITION / VIEW DATABASE STATE) and that eligible online databases exist. Storage growth monitoring evidence requires manual review.';
END
ELSE
BEGIN
    IF @EngineEdition <> 5
        SET @DatabaseQueried = N'SERVER-WIDE (' + CAST(@DatabaseCount AS NVARCHAR(10)) + N' online databases, tempdb excluded)';

    IF @BadFiles = 0
    BEGIN
        SET @Score = 3;
        SET @Finding = N'All ' + CAST(@TotalFiles AS NVARCHAR(10)) + N' data/log files across ' + CAST(@DatabaseCount AS NVARCHAR(10))
            + N' database(s) use fixed-size autogrowth of at least 64 MB with autogrowth enabled. Percent-growth files: 0, sub-64 MB fixed-growth files: 0, autogrowth-disabled files: 0. '
            + CAST(@CappedFiles AS NVARCHAR(10)) + N' file(s) have a non-default MAXSIZE cap (informational). Confirm that ongoing storage growth monitoring/alerting is documented.';
    END
    ELSE IF @BadPercent <= 25.00
    BEGIN
        SET @Score = 2;
        SET @Finding = CAST(@BadFiles AS NVARCHAR(10)) + N' of ' + CAST(@TotalFiles AS NVARCHAR(10)) + N' data/log files ('
            + CAST(@BadPercent AS NVARCHAR(10)) + N'%) have questionable autogrowth: ' + CAST(@PercentGrowthFiles AS NVARCHAR(10))
            + N' percent-growth, ' + CAST(@SmallFixedFiles AS NVARCHAR(10)) + N' fixed growth under 64 MB, '
            + CAST(@DisabledGrowthFiles AS NVARCHAR(10)) + N' with autogrowth disabled. Examples: ' + @Offenders + N'.';
    END
    ELSE
    BEGIN
        SET @Score = 1;
        SET @Finding = CAST(@BadFiles AS NVARCHAR(10)) + N' of ' + CAST(@TotalFiles AS NVARCHAR(10)) + N' data/log files ('
            + CAST(@BadPercent AS NVARCHAR(10)) + N'%) have unsafe autogrowth settings: ' + CAST(@PercentGrowthFiles AS NVARCHAR(10))
            + N' percent-growth, ' + CAST(@SmallFixedFiles AS NVARCHAR(10)) + N' fixed growth under 64 MB, '
            + CAST(@DisabledGrowthFiles AS NVARCHAR(10)) + N' with autogrowth disabled. Examples: ' + @Offenders + N'.';
    END
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

DROP TABLE #FileGrowth;

SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;