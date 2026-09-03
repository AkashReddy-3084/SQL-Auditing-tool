SET NOCOUNT ON;

IF OBJECT_ID('tempdb..#FileGrowth') IS NOT NULL DROP TABLE #FileGrowth;

CREATE TABLE #FileGrowth (
    DatabaseName sysname NOT NULL,
    FileName sysname NOT NULL,
    FileType nvarchar(60) NOT NULL,
    SizeMB decimal(18, 2) NOT NULL,
    GrowthMode nvarchar(20) NOT NULL,
    GrowthValue int NOT NULL,
    GrowthMB decimal(18, 2) NULL,
    IsPercentGrowth bit NOT NULL,
    IsReadOnly bit NOT NULL,
    IsIssue bit NOT NULL,
    IssueReason nvarchar(200) NULL
);

DECLARE @Result nvarchar(20);
DECLARE @Score int;
DECLARE @DatabaseQueried nvarchar(128);
DECLARE @Finding nvarchar(max);
DECLARE @IsAzure bit = 0;
DECLARE @TotalFiles int = 0;
DECLARE @IssueFiles int = 0;
DECLARE @PercentGrowthFiles int = 0;
DECLARE @TinyFixedFiles int = 0;
DECLARE @DisabledGrowthFiles int = 0;
DECLARE @SampleIssues nvarchar(max) = N'';

IF SERVERPROPERTY('EngineEdition') = 5 SET @IsAzure = 1;
SET @DatabaseQueried = CASE WHEN @IsAzure = 1 THEN DB_NAME() ELSE N'ALL' END;

BEGIN TRY
    IF @IsAzure = 1
    BEGIN
        ;WITH files AS (
            SELECT
                DB_NAME() AS DatabaseName,
                mf.name AS FileName,
                mf.type_desc AS FileType,
                CAST(mf.size AS decimal(18, 2)) * 8.0 / 1024.0 AS SizeMB,
                CAST(mf.is_percent_growth AS bit) AS IsPercentGrowth,
                mf.growth AS GrowthValue,
                CASE WHEN mf.is_percent_growth = 1 THEN NULL
                     ELSE CAST(mf.growth AS decimal(18, 2)) * 8.0 / 1024.0
                END AS GrowthMB,
                CAST(DATABASEPROPERTYEX(DB_NAME(), 'Updateability') AS nvarchar(60)) AS Updateability
            FROM sys.database_files AS mf
            WHERE mf.type IN (0, 1)
        )
        INSERT INTO #FileGrowth (
            DatabaseName, FileName, FileType, SizeMB, GrowthMode, GrowthValue, GrowthMB,
            IsPercentGrowth, IsReadOnly, IsIssue, IssueReason
        )
        SELECT
            f.DatabaseName,
            f.FileName,
            f.FileType,
            f.SizeMB,
            CASE
                WHEN f.GrowthValue = 0 THEN 'None'
                WHEN f.IsPercentGrowth = 1 THEN 'Percent'
                ELSE 'FixedMB'
            END AS GrowthMode,
            f.GrowthValue,
            f.GrowthMB,
            f.IsPercentGrowth,
            CASE WHEN f.Updateability = 'READ_ONLY' THEN 1 ELSE 0 END AS IsReadOnly,
            CASE
                WHEN f.GrowthValue = 0 AND f.Updateability <> 'READ_ONLY' THEN 1
                WHEN f.IsPercentGrowth = 1 AND f.SizeMB >= 100 THEN 1
                WHEN f.IsPercentGrowth = 0 AND f.GrowthValue > 0
                     AND (CAST(f.GrowthValue AS decimal(18, 2)) * 8.0 / 1024.0) < 64
                     AND f.SizeMB >= 256 THEN 1
                ELSE 0
            END AS IsIssue,
            CASE
                WHEN f.GrowthValue = 0 AND f.Updateability <> 'READ_ONLY' THEN 'Autogrowth disabled'
                WHEN f.IsPercentGrowth = 1 AND f.SizeMB >= 100 THEN 'Percent autogrowth on non-trivial file'
                WHEN f.IsPercentGrowth = 0 AND f.GrowthValue > 0
                     AND (CAST(f.GrowthValue AS decimal(18, 2)) * 8.0 / 1024.0) < 64
                     AND f.SizeMB >= 256 THEN 'Fixed autogrowth increment under 64 MB on larger file'
                ELSE NULL
            END AS IssueReason
        FROM files AS f;
    END
    ELSE
    BEGIN
        INSERT INTO #FileGrowth (
            DatabaseName, FileName, FileType, SizeMB, GrowthMode, GrowthValue, GrowthMB,
            IsPercentGrowth, IsReadOnly, IsIssue, IssueReason
        )
        SELECT
            d.name AS DatabaseName,
            mf.name AS FileName,
            mf.type_desc AS FileType,
            CAST(mf.size AS decimal(18, 2)) * 8.0 / 1024.0 AS SizeMB,
            CASE
                WHEN mf.growth = 0 THEN 'None'
                WHEN mf.is_percent_growth = 1 THEN 'Percent'
                ELSE 'FixedMB'
            END AS GrowthMode,
            mf.growth AS GrowthValue,
            CASE WHEN mf.is_percent_growth = 1 THEN NULL
                 ELSE CAST(mf.growth AS decimal(18, 2)) * 8.0 / 1024.0
            END AS GrowthMB,
            CAST(mf.is_percent_growth AS bit) AS IsPercentGrowth,
            CASE WHEN d.is_read_only = 1 OR d.is_in_standby = 1 THEN 1 ELSE 0 END AS IsReadOnly,
            CASE
                WHEN mf.growth = 0 AND d.is_read_only = 0 AND d.is_in_standby = 0
                     AND d.state_desc = 'ONLINE' THEN 1
                WHEN mf.is_percent_growth = 1
                     AND (CAST(mf.size AS decimal(18, 2)) * 8.0 / 1024.0) >= 100 THEN 1
                WHEN mf.is_percent_growth = 0 AND mf.growth > 0
                     AND (CAST(mf.growth AS decimal(18, 2)) * 8.0 / 1024.0) < 64
                     AND (CAST(mf.size AS decimal(18, 2)) * 8.0 / 1024.0) >= 256 THEN 1
                ELSE 0
            END AS IsIssue,
            CASE
                WHEN mf.growth = 0 AND d.is_read_only = 0 AND d.is_in_standby = 0
                     AND d.state_desc = 'ONLINE' THEN 'Autogrowth disabled'
                WHEN mf.is_percent_growth = 1
                     AND (CAST(mf.size AS decimal(18, 2)) * 8.0 / 1024.0) >= 100
                    THEN 'Percent autogrowth on non-trivial file'
                WHEN mf.is_percent_growth = 0 AND mf.growth > 0
                     AND (CAST(mf.growth AS decimal(18, 2)) * 8.0 / 1024.0) < 64
                     AND (CAST(mf.size AS decimal(18, 2)) * 8.0 / 1024.0) >= 256
                    THEN 'Fixed autogrowth increment under 64 MB on larger file'
                ELSE NULL
            END AS IssueReason
        FROM sys.master_files AS mf
        INNER JOIN sys.databases AS d
            ON d.database_id = mf.database_id
        WHERE mf.type IN (0, 1)
          AND d.state_desc = 'ONLINE'
          AND HAS_DBACCESS(d.name) = 1;
    END

    SELECT
        @TotalFiles = COUNT(*),
        @IssueFiles = SUM(CASE WHEN IsIssue = 1 THEN 1 ELSE 0 END),
        @PercentGrowthFiles = SUM(CASE WHEN IssueReason LIKE N'Percent%' THEN 1 ELSE 0 END),
        @TinyFixedFiles = SUM(CASE WHEN IssueReason LIKE N'Fixed autogrowth%' THEN 1 ELSE 0 END),
        @DisabledGrowthFiles = SUM(CASE WHEN IssueReason = N'Autogrowth disabled' THEN 1 ELSE 0 END)
    FROM #FileGrowth;

    ;WITH top_issues AS (
        SELECT TOP (8)
            DatabaseName + N'.' + FileName + N' (' + FileType + N', ' + ISNULL(IssueReason, N'') + N')' AS item
        FROM #FileGrowth
        WHERE IsIssue = 1
        ORDER BY
            CASE
                WHEN IssueReason LIKE N'Percent%' THEN 1
                WHEN IssueReason LIKE N'Fixed%' THEN 2
                ELSE 3
            END,
            SizeMB DESC
    )
    SELECT @SampleIssues = STUFF((
        SELECT N'; ' + item
        FROM top_issues
        FOR XML PATH(''), TYPE
    ).value('.', 'nvarchar(max)'), 1, 2, N'');

    IF @TotalFiles = 0
    BEGIN
        SET @Score = 0;
        SET @Finding = N'No database files could be enumerated to assess autogrowth settings.';
    END
    ELSE IF @IssueFiles = 0
    BEGIN
        SET @Score = 3;
        SET @Finding = N'All ' + CAST(@TotalFiles AS nvarchar(20))
            + N' online data/log file(s) use sane autogrowth settings (fixed-size growth, not tiny percent-based increments). Storage growth configuration appears appropriate.';
    END
    ELSE
    BEGIN
        IF @PercentGrowthFiles >= 5 OR (@IssueFiles * 1.0 / NULLIF(@TotalFiles, 0)) >= 0.5
            OR (@PercentGrowthFiles >= 2 AND @TinyFixedFiles >= 2)
            SET @Score = 0;
        ELSE IF @PercentGrowthFiles >= 2 OR @IssueFiles >= 4
            OR (@IssueFiles * 1.0 / NULLIF(@TotalFiles, 0)) >= 0.25
            SET @Score = 1;
        ELSE
            SET @Score = 2;

        SET @Finding = N'Found ' + CAST(@IssueFiles AS nvarchar(20)) + N' of ' + CAST(@TotalFiles AS nvarchar(20))
            + N' file(s) with unsane autogrowth: '
            + CAST(@PercentGrowthFiles AS nvarchar(20)) + N' percent-growth, '
            + CAST(@TinyFixedFiles AS nvarchar(20)) + N' tiny fixed (<64MB on files >=256MB), '
            + CAST(@DisabledGrowthFiles AS nvarchar(20)) + N' growth disabled. Examples: '
            + ISNULL(@SampleIssues, N'n/a')
            + N'. Prefer fixed increments (e.g. 256-1024 MB) and monitor free space/growth trends.';
    END
END TRY
BEGIN CATCH
    SET @Score = 0;
    SET @DatabaseQueried = CASE WHEN @IsAzure = 1 THEN ISNULL(DB_NAME(), N'UNKNOWN') ELSE N'ALL' END;
    SET @Finding = N'Error assessing autogrowth settings: ' + ERROR_MESSAGE();
END CATCH

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

IF OBJECT_ID('tempdb..#FileGrowth') IS NOT NULL DROP TABLE #FileGrowth;

SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;