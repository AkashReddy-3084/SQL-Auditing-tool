-- Checklist: ETL packages/pipelines follow consistent naming conventions
-- Scope: SERVER
-- Scoring: 3 = no ETL job or package name deviates from the convention; 2 = under 10% deviate, or the platform exposes no Agent/SSIS catalog metadata; 1 = under 25% deviate; 0 = 25% or more deviate, or no ETL job or package artefacts exist

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'master';
DECLARE @Finding NVARCHAR(MAX) = 'ETL job and package naming evidence was unavailable';
DECLARE @Engine INT = ISNULL(CONVERT(INT, SERVERPROPERTY('EngineEdition')), 0);
DECLARE @Sql NVARCHAR(MAX);
DECLARE @Total INT = 0;
DECLARE @Bad INT = 0;
DECLARE @BadPct DECIMAL(6, 2) = 0;
DECLARE @BadList NVARCHAR(MAX) = '';
DECLARE @ReadError BIT = 0;

CREATE TABLE #EtlName (ObjectName NVARCHAR(256) NOT NULL);

IF @Engine <> 5
BEGIN
    BEGIN TRY
        SET @Sql = N'SELECT j.name FROM msdb.dbo.sysjobs AS j WHERE j.name LIKE N''%ETL%'' OR j.name LIKE N''%SSIS%'' OR j.name LIKE N''%Load%'' OR j.name LIKE N''%Extract%'' OR j.name LIKE N''%Transform%'' OR j.name LIKE N''%Ingest%'' OR j.name LIKE N''%Pipeline%'' OR j.name LIKE N''%Stag%'';';
        INSERT INTO #EtlName (ObjectName) EXEC sp_executesql @Sql;
    END TRY
    BEGIN CATCH
        SET @ReadError = 1;
    END CATCH

    IF DB_ID(N'SSISDB') IS NOT NULL
    BEGIN
        BEGIN TRY
            SET @Sql = N'SELECT pk.name FROM SSISDB.catalog.packages AS pk;';
            INSERT INTO #EtlName (ObjectName) EXEC sp_executesql @Sql;
        END TRY
        BEGIN CATCH
            SET @ReadError = 1;
        END CATCH
    END
END

SELECT @Total = COUNT(*),
       @Bad = ISNULL(SUM(n.IsBad), 0),
       @BadList = ISNULL(LEFT(STRING_AGG(CASE WHEN n.IsBad = 1 THEN CONVERT(NVARCHAR(MAX), n.ObjectName) END, ', '), 400), '')
FROM
(
    SELECT e.ObjectName,
           CASE WHEN e.ObjectName LIKE N'% %'
                  OR e.ObjectName LIKE N'[Pp]ackage[0-9]%'
                  OR e.ObjectName LIKE N'[Jj]ob[_][0-9]%'
                  OR (e.ObjectName NOT LIKE N'%[_]%'
                      AND e.ObjectName NOT LIKE N'%-%'
                      AND e.ObjectName COLLATE Latin1_General_BIN2 NOT LIKE N'%[a-z][A-Z]%')
                THEN 1 ELSE 0 END AS IsBad
    FROM #EtlName AS e
) AS n;

SET @BadPct = CASE WHEN @Total = 0 THEN 0
                   ELSE CONVERT(DECIMAL(6, 2), 100.0 * @Bad / NULLIF(@Total, 0)) END;

IF @Engine = 5
BEGIN
    SET @Score = 2;
    SET @Finding = 'Azure SQL Database exposes no SQL Agent job or SSIS catalog metadata; ETL package naming is governed in the external orchestration service and cannot be read on the instance';
END
ELSE IF @Total = 0
BEGIN
    SET @Score = 0;
    SET @Finding = CONCAT('No SQL Agent ETL job names and no SSIS catalog package names were found on this instance',
                          CASE WHEN @ReadError = 1 THEN '; one or more metadata sources could not be read' ELSE '' END);
END
ELSE
BEGIN
    SET @Score = CASE WHEN @Bad = 0 THEN 3
                      WHEN @BadPct < 10 THEN 2
                      WHEN @BadPct < 25 THEN 1
                      ELSE 0 END;
    SET @Finding = CONCAT('ETL job and package names inspected = ', @Total,
                          '; names breaking the convention (embedded spaces, default names, or neither delimited nor PascalCase) = ', @Bad,
                          ' (', @BadPct, '%)',
                          CASE WHEN @Bad = 0 THEN '; no non-compliant names found'
                               ELSE '; non-compliant: ' + @BadList END);
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;
