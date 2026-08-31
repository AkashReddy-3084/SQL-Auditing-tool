SET NOCOUNT ON;

DECLARE @Result VARCHAR(10);
DECLARE @Score INT;
DECLARE @DatabaseQueried NVARCHAR(128);
DECLARE @Finding NVARCHAR(MAX);

DECLARE @ServerName NVARCHAR(256) = CONVERT(NVARCHAR(256), COALESCE(SERVERPROPERTY('ServerName'), @@SERVERNAME));
DECLARE @ServerLower NVARCHAR(256) = LOWER(@ServerName);

DECLARE @ServerHasProd BIT = 0;
DECLARE @ServerHasNonProd BIT = 0;
DECLARE @DbProdCount INT = 0;
DECLARE @DbNonProdCount INT = 0;
DECLARE @UserDbCount INT = 0;
DECLARE @SampleProdDbs NVARCHAR(500) = N'';
DECLARE @SampleNonProdDbs NVARCHAR(500) = N'';

IF (
    @ServerLower LIKE '%prod%'
    OR @ServerLower LIKE '%prd%'
    OR @ServerLower LIKE '%live%'
    OR @ServerLower LIKE '%.p.%'
    OR @ServerLower LIKE '%-p-%'
    OR @ServerLower LIKE '%_p_%'
)
    SET @ServerHasProd = 1;

IF (
    @ServerLower LIKE '%dev%'
    OR @ServerLower LIKE '%test%'
    OR @ServerLower LIKE '%tst%'
    OR @ServerLower LIKE '%qa%'
    OR @ServerLower LIKE '%uat%'
    OR @ServerLower LIKE '%stage%'
    OR @ServerLower LIKE '%stg%'
    OR @ServerLower LIKE '%sandbox%'
    OR @ServerLower LIKE '%sbx%'
    OR @ServerLower LIKE '%nonprod%'
    OR @ServerLower LIKE '%non-prod%'
)
    SET @ServerHasNonProd = 1;

IF OBJECT_ID('tempdb..#EnvDbs') IS NOT NULL
    DROP TABLE #EnvDbs;

CREATE TABLE #EnvDbs
(
    DbName SYSNAME NOT NULL,
    IsProdSignal BIT NOT NULL,
    IsNonProdSignal BIT NOT NULL
);

INSERT INTO #EnvDbs (DbName, IsProdSignal, IsNonProdSignal)
SELECT
    d.name,
    CASE
        WHEN LOWER(d.name) LIKE '%prod%'
          OR LOWER(d.name) LIKE '%prd%'
          OR LOWER(d.name) LIKE '%live%'
        THEN 1 ELSE 0
    END,
    CASE
        WHEN LOWER(d.name) LIKE '%dev%'
          OR LOWER(d.name) LIKE '%test%'
          OR LOWER(d.name) LIKE '%tst%'
          OR LOWER(d.name) LIKE '%qa%'
          OR LOWER(d.name) LIKE '%uat%'
          OR LOWER(d.name) LIKE '%stage%'
          OR LOWER(d.name) LIKE '%stg%'
          OR LOWER(d.name) LIKE '%sandbox%'
          OR LOWER(d.name) LIKE '%sbx%'
          OR LOWER(d.name) LIKE '%nonprod%'
          OR LOWER(d.name) LIKE '%non-prod%'
        THEN 1 ELSE 0
    END
FROM sys.databases d
WHERE d.database_id > 4
  AND d.state = 0
  AND d.name NOT IN (N'distribution', N'SSISDB');

SELECT @UserDbCount = COUNT(*) FROM #EnvDbs;
SELECT @DbProdCount = COUNT(*) FROM #EnvDbs WHERE IsProdSignal = 1 AND IsNonProdSignal = 0;
SELECT @DbNonProdCount = COUNT(*) FROM #EnvDbs WHERE IsNonProdSignal = 1 AND IsProdSignal = 0;

SELECT TOP 5 @SampleProdDbs = @SampleProdDbs + CASE WHEN @SampleProdDbs = N'' THEN N'' ELSE N', ' END + DbName
FROM #EnvDbs
WHERE IsProdSignal = 1 AND IsNonProdSignal = 0
ORDER BY DbName;

SELECT TOP 5 @SampleNonProdDbs = @SampleNonProdDbs + CASE WHEN @SampleNonProdDbs = N'' THEN N'' ELSE N', ' END + DbName
FROM #EnvDbs
WHERE IsNonProdSignal = 1 AND IsProdSignal = 0
ORDER BY DbName;

DECLARE @HasProd BIT = CASE WHEN @ServerHasProd = 1 OR @DbProdCount > 0 THEN 1 ELSE 0 END;
DECLARE @HasNonProd BIT = CASE WHEN @ServerHasNonProd = 1 OR @DbNonProdCount > 0 THEN 1 ELSE 0 END;
DECLARE @IsMixed BIT = CASE WHEN @HasProd = 1 AND @HasNonProd = 1 THEN 1 ELSE 0 END;

SET @DatabaseQueried = N'server';

IF @IsMixed = 1
BEGIN
    SET @Score = 1;
    SET @Finding =
        N'Mixed environment signals on instance [' + @ServerName + N']. '
        + N'ServerName prod-token=' + CASE WHEN @ServerHasProd = 1 THEN N'yes' ELSE N'no' END
        + N', nonprod-token=' + CASE WHEN @ServerHasNonProd = 1 THEN N'yes' ELSE N'no' END
        + N'. User DBs=' + CONVERT(NVARCHAR(10), @UserDbCount)
        + N'; prod-named DBs=' + CONVERT(NVARCHAR(10), @DbProdCount)
        + CASE WHEN @SampleProdDbs <> N'' THEN N' [' + @SampleProdDbs + N']' ELSE N'' END
        + N'; nonprod-named DBs=' + CONVERT(NVARCHAR(10), @DbNonProdCount)
        + CASE WHEN @SampleNonProdDbs <> N'' THEN N' [' + @SampleNonProdDbs + N']' ELSE N'' END
        + N'. Dev/Test/Prod workloads appear co-located; separate environments are not evidenced on this instance.';
END
ELSE
BEGIN
    SET @Score = 3;
    IF @HasProd = 1 AND @HasNonProd = 0
        SET @Finding =
            N'Instance [' + @ServerName + N'] shows production-class naming only (no Dev/Test/UAT/Stage tokens on server or user database names). '
            + N'User DBs=' + CONVERT(NVARCHAR(10), @UserDbCount)
            + N'; prod-named DBs=' + CONVERT(NVARCHAR(10), @DbProdCount)
            + CASE WHEN @SampleProdDbs <> N'' THEN N' [' + @SampleProdDbs + N']' ELSE N'' END
            + N'. No mixed Dev/Test/Prod co-location detected on this instance.';
    ELSE IF @HasNonProd = 1 AND @HasProd = 0
        SET @Finding =
            N'Instance [' + @ServerName + N'] shows non-production-class naming only (Dev/Test/UAT/Stage/QA tokens; no prod tokens on server or user database names). '
            + N'User DBs=' + CONVERT(NVARCHAR(10), @UserDbCount)
            + N'; nonprod-named DBs=' + CONVERT(NVARCHAR(10), @DbNonProdCount)
            + CASE WHEN @SampleNonProdDbs <> N'' THEN N' [' + @SampleNonProdDbs + N']' ELSE N'' END
            + N'. No mixed Dev/Test/Prod co-location detected on this instance.';
    ELSE
        SET @Finding =
            N'Instance [' + @ServerName + N'] has no clear Dev/Test/Prod naming tokens on the server name or user database names. '
            + N'User DBs=' + CONVERT(NVARCHAR(10), @UserDbCount)
            + N'. No evidence of mixed environment co-location on this instance from name-based signals.';
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;