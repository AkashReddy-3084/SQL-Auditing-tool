-- Checklist: Architecture diagram exists and reflects the actual implementation
-- Scope: DATABASE
-- Scoring: 3 = diagram manually confirmed current (not awarded automatically);
--          2 = one or more stored database diagrams; 1 = diagram infrastructure
--          exists but contains no diagram; 0 = no diagram artifact or evaluation failure.
-- NOTE: This script provides automated evidence. Full compliance requires human review.

DECLARE @EngineEdition INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = N'Fail';
DECLARE @DbName SYSNAME;
DECLARE @Sql NVARCHAR(MAX);
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);

CREATE TABLE #DbResults
(
    DbName SYSNAME NOT NULL,
    DbScore INT NOT NULL,
    Finding NVARCHAR(MAX) NOT NULL
);

IF @EngineEdition = 5
BEGIN
    DECLARE @AzureDiagramCount INT = 0;
    DECLARE @AzureDiagramNames NVARCHAR(MAX);

    IF OBJECT_ID(N'dbo.sysdiagrams', N'U') IS NOT NULL
    BEGIN
        SELECT
            @AzureDiagramCount = COUNT(*),
            @AzureDiagramNames =
                STRING_AGG(CONVERT(NVARCHAR(MAX), QUOTENAME(name)), N', ')
        FROM dbo.sysdiagrams;

        INSERT INTO #DbResults (DbName, DbScore, Finding)
        VALUES
        (
            DB_NAME(),
            CASE WHEN @AzureDiagramCount > 0 THEN 2 ELSE 1 END,
            CASE
                WHEN @AzureDiagramCount > 0
                    THEN CONVERT(NVARCHAR(20), @AzureDiagramCount)
                        + N' stored database diagram(s): '
                        + COALESCE(@AzureDiagramNames, N'names unavailable')
                        + N'; manually confirm scope and currency'
                ELSE N'dbo.sysdiagrams exists but contains no stored diagrams'
            END
        );
    END
    ELSE
    BEGIN
        INSERT INTO #DbResults (DbName, DbScore, Finding)
        VALUES
        (
            DB_NAME(),
            0,
            N'No dbo.sysdiagrams artifact found; external architecture documentation requires manual verification'
        );
    END;
END
ELSE
BEGIN
    DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT name
    FROM sys.databases
    WHERE database_id > 4
      AND state = 0;

    OPEN db_cursor;
    FETCH NEXT FROM db_cursor INTO @DbName;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
DECLARE @DiagramCount INT = 0;
DECLARE @DiagramNames NVARCHAR(MAX);

IF OBJECT_ID(N''dbo.sysdiagrams'', N''U'') IS NOT NULL
BEGIN
    SELECT
        @DiagramCount = COUNT(*),
        @DiagramNames =
            STRING_AGG(CONVERT(NVARCHAR(MAX), QUOTENAME(name)), N'', '')
    FROM dbo.sysdiagrams;

    INSERT INTO #DbResults (DbName, DbScore, Finding)
    VALUES
    (
        DB_NAME(),
        CASE WHEN @DiagramCount > 0 THEN 2 ELSE 1 END,
        CASE
            WHEN @DiagramCount > 0
                THEN CONVERT(NVARCHAR(20), @DiagramCount)
                    + N'' stored database diagram(s): ''
                    + COALESCE(@DiagramNames, N''names unavailable'')
                    + N''; manually confirm scope and currency''
            ELSE N''dbo.sysdiagrams exists but contains no stored diagrams''
        END
    );
END
ELSE
BEGIN
    INSERT INTO #DbResults (DbName, DbScore, Finding)
    VALUES
    (
        DB_NAME(),
        0,
        N''No dbo.sysdiagrams artifact found; external architecture documentation requires manual verification''
    );
END;';

            EXEC sys.sp_executesql @Sql;
        END TRY
        BEGIN CATCH
            INSERT INTO #DbResults (DbName, DbScore, Finding)
            VALUES
            (
                @DbName,
                0,
                N'Database diagram evaluation failed: ' + ERROR_MESSAGE()
            );
        END CATCH;

        FETCH NEXT FROM db_cursor INTO @DbName;
    END;

    CLOSE db_cursor;
    DEALLOCATE db_cursor;
END;

SELECT @DatabaseQueried =
    STRING_AGG(CONVERT(NVARCHAR(MAX), DbName), N', ')
FROM #DbResults;

SELECT @Score = COALESCE(MIN(DbScore), 0)
FROM #DbResults;

SELECT @Finding =
    STRING_AGG(
        CONVERT(NVARCHAR(MAX), QUOTENAME(DbName) + N': ' + Finding),
        N'; '
    )
FROM #DbResults;

SET @DatabaseQueried = COALESCE(@DatabaseQueried, N'');
SET @Finding = COALESCE(
    @Finding,
    N'No online user databases were available for diagram evaluation'
);
SET @Result = CASE WHEN @Score >= 2 THEN N'Pass' ELSE N'Fail' END;

DROP TABLE #DbResults;

SELECT
    @Result AS Result,
    @Score AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding AS Finding;