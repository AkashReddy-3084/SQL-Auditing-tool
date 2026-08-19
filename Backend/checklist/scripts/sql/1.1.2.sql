-- Checklist: Environment separation exists (Dev / Test / Prod) with isolated instances or databases
-- Scope: SERVER
-- Scoring: 3 = Dev, Test, and Prod database evidence; 2 = two environments;
--          1 = one environment indicator; 0 = no environment indicators.
-- NOTE: This script provides automated evidence. Full compliance requires human review.

DECLARE @Result NVARCHAR(10);
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = N'master';
DECLARE @Finding NVARCHAR(MAX);
DECLARE @ServerName NVARCHAR(256) =
    COALESCE(CONVERT(NVARCHAR(256), SERVERPROPERTY('ServerName')), N'unknown');
DECLARE @NormalizedServer NVARCHAR(514) =
    N' ' + LOWER(COALESCE(CONVERT(NVARCHAR(256), SERVERPROPERTY('ServerName')), N'')) + N' ';
DECLARE @ServerEnvironment NVARCHAR(20);
DECLARE @DistinctEnvironmentCount INT;
DECLARE @EnvironmentList NVARCHAR(MAX);
DECLARE @DatabaseEvidence NVARCHAR(MAX);

SET @NormalizedServer = REPLACE(@NormalizedServer, N'\', N' ');
SET @NormalizedServer = REPLACE(@NormalizedServer, N'/', N' ');
SET @NormalizedServer = REPLACE(@NormalizedServer, N'-', N' ');
SET @NormalizedServer = REPLACE(@NormalizedServer, N'_', N' ');
SET @NormalizedServer = REPLACE(@NormalizedServer, N'.', N' ');

SET @ServerEnvironment =
    CASE
        WHEN @NormalizedServer LIKE N'% dev %'
          OR @NormalizedServer LIKE N'% development %' THEN N'Dev'
        WHEN @NormalizedServer LIKE N'% test %'
          OR @NormalizedServer LIKE N'% testing %'
          OR @NormalizedServer LIKE N'% qa %'
          OR @NormalizedServer LIKE N'% uat %'
          OR @NormalizedServer LIKE N'% stage %'
          OR @NormalizedServer LIKE N'% staging %' THEN N'Test'
        WHEN @NormalizedServer LIKE N'% prod %'
          OR @NormalizedServer LIKE N'% production %' THEN N'Prod'
    END;

CREATE TABLE #EnvironmentEvidence
(
    DatabaseName SYSNAME NOT NULL,
    EnvironmentName NVARCHAR(20) NOT NULL
);

INSERT INTO #EnvironmentEvidence (DatabaseName, EnvironmentName)
SELECT
    d.name,
    CASE
        WHEN n.NormalizedName LIKE N'% dev %'
          OR n.NormalizedName LIKE N'% development %' THEN N'Dev'
        WHEN n.NormalizedName LIKE N'% test %'
          OR n.NormalizedName LIKE N'% testing %'
          OR n.NormalizedName LIKE N'% qa %'
          OR n.NormalizedName LIKE N'% uat %'
          OR n.NormalizedName LIKE N'% stage %'
          OR n.NormalizedName LIKE N'% staging %' THEN N'Test'
        WHEN n.NormalizedName LIKE N'% prod %'
          OR n.NormalizedName LIKE N'% production %' THEN N'Prod'
    END
FROM sys.databases AS d
CROSS APPLY
(
    SELECT
        N' ' + REPLACE(REPLACE(REPLACE(REPLACE(
            LOWER(d.name),
            N'-', N' '),
            N'_', N' '),
            N'.', N' '),
            N'/', N' ') + N' ' AS NormalizedName
) AS n
WHERE d.database_id > 4
  AND d.state = 0
  AND
  (
       n.NormalizedName LIKE N'% dev %'
    OR n.NormalizedName LIKE N'% development %'
    OR n.NormalizedName LIKE N'% test %'
    OR n.NormalizedName LIKE N'% testing %'
    OR n.NormalizedName LIKE N'% qa %'
    OR n.NormalizedName LIKE N'% uat %'
    OR n.NormalizedName LIKE N'% stage %'
    OR n.NormalizedName LIKE N'% staging %'
    OR n.NormalizedName LIKE N'% prod %'
    OR n.NormalizedName LIKE N'% production %'
  );

SELECT @DistinctEnvironmentCount = COUNT(DISTINCT EnvironmentName)
FROM #EnvironmentEvidence;

SELECT @EnvironmentList =
    STRING_AGG(CONVERT(NVARCHAR(MAX), EnvironmentName), N', ')
FROM
(
    SELECT DISTINCT EnvironmentName
    FROM #EnvironmentEvidence
) AS e;

SELECT @DatabaseEvidence =
    STRING_AGG(
        CONVERT(NVARCHAR(MAX), QUOTENAME(DatabaseName) + N' (' + EnvironmentName + N')'),
        N', '
    )
FROM #EnvironmentEvidence;

IF EXISTS
(
    SELECT 1 FROM #EnvironmentEvidence WHERE EnvironmentName = N'Dev'
)
AND EXISTS
(
    SELECT 1 FROM #EnvironmentEvidence WHERE EnvironmentName = N'Test'
)
AND EXISTS
(
    SELECT 1 FROM #EnvironmentEvidence WHERE EnvironmentName = N'Prod'
)
BEGIN
    SET @Score = 3;
END
ELSE IF @DistinctEnvironmentCount >= 2
BEGIN
    SET @Score = 2;
END
ELSE IF @DistinctEnvironmentCount = 1 OR @ServerEnvironment IS NOT NULL
BEGIN
    SET @Score = 1;
END
ELSE
BEGIN
    SET @Score = 0;
END;

SET @Finding =
    N'Instance ' + QUOTENAME(@ServerName)
    + N' environment token: ' + COALESCE(@ServerEnvironment, N'none')
    + N'; distinct database environments: '
    + COALESCE(@EnvironmentList, N'none')
    + N'; database evidence: '
    + COALESCE(@DatabaseEvidence, N'none')
    + N'. Naming evidence does not prove physical or logical isolation; confirm isolation manually.';

SET @Result = CASE WHEN @Score >= 2 THEN N'Pass' ELSE N'Fail' END;

DROP TABLE #EnvironmentEvidence;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;