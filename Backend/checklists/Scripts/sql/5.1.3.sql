-- Checklist: DQ KPIs defined: completeness, accuracy, timeliness, consistency, uniqueness, validity
-- Scope: DATABASE
-- Scoring: 3 = 4+ of the six KPI dimensions represented as columns; 2 = 2-3 present; 1 = under 2 present; 0 = no DQ metrics table found

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'None';
DECLARE @Finding NVARCHAR(MAX) = 'No database found to be queried';
DECLARE @DbName SYSNAME;
DECLARE @Sql NVARCHAR(MAX);

CREATE TABLE #DbResults (DbName SYSNAME, DbScore INT, Finding NVARCHAR(MAX));

IF SERVERPROPERTY('EngineEdition') = 5
BEGIN
    DECLARE @DqTableCount INT, @Completeness INT, @Accuracy INT, @Timeliness INT, @Consistency INT, @Uniqueness INT, @Validity INT;

    SELECT @DqTableCount = COUNT(*) FROM sys.tables
    WHERE name LIKE '%dq_%' OR name LIKE '%data_quality%' OR name LIKE '%quality_metric%' OR name LIKE '%quality_score%';

    SELECT @Completeness = MAX(CASE WHEN c.name LIKE '%complete%' THEN 1 ELSE 0 END),
           @Accuracy = MAX(CASE WHEN c.name LIKE '%accura%' THEN 1 ELSE 0 END),
           @Timeliness = MAX(CASE WHEN c.name LIKE '%timel%' THEN 1 ELSE 0 END),
           @Consistency = MAX(CASE WHEN c.name LIKE '%consist%' THEN 1 ELSE 0 END),
           @Uniqueness = MAX(CASE WHEN c.name LIKE '%uniq%' THEN 1 ELSE 0 END),
           @Validity = MAX(CASE WHEN c.name LIKE '%valid%' THEN 1 ELSE 0 END)
    FROM sys.columns c
    JOIN sys.tables t ON t.object_id = c.object_id
    WHERE t.name LIKE '%dq_%' OR t.name LIKE '%data_quality%' OR t.name LIKE '%quality_metric%' OR t.name LIKE '%quality_score%';

    DECLARE @DimCount INT = ISNULL(@Completeness,0) + ISNULL(@Accuracy,0) + ISNULL(@Timeliness,0) + ISNULL(@Consistency,0) + ISNULL(@Uniqueness,0) + ISNULL(@Validity,0);

    INSERT INTO #DbResults (DbName, DbScore, Finding)
    VALUES (
        DB_NAME(),
        CASE WHEN ISNULL(@DqTableCount,0) = 0 THEN 0
             WHEN @DimCount >= 4 THEN 3
             WHEN @DimCount >= 2 THEN 2
             ELSE 1 END,
        CASE WHEN ISNULL(@DqTableCount,0) = 0 THEN 'No DQ metrics table found'
             ELSE CONCAT('DQ metrics tables = ', @DqTableCount, ', KPI dimensions represented = ', @DimCount, ' of 6') END
    );
END
ELSE
BEGIN
    DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT name FROM sys.databases
        WHERE database_id > 4 AND state = 0 AND HAS_DBACCESS(name) = 1;

    OPEN db_cursor;
    FETCH NEXT FROM db_cursor INTO @DbName;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            SET @Sql = N'DECLARE @dt INT, @c1 INT, @c2 INT, @c3 INT, @c4 INT, @c5 INT, @c6 INT;
SELECT @dt = COUNT(*) FROM ' + QUOTENAME(@DbName) + N'.sys.tables
WHERE name LIKE ''%dq_%'' OR name LIKE ''%data_quality%'' OR name LIKE ''%quality_metric%'' OR name LIKE ''%quality_score%'';
SELECT @c1 = MAX(CASE WHEN c.name LIKE ''%complete%'' THEN 1 ELSE 0 END),
       @c2 = MAX(CASE WHEN c.name LIKE ''%accura%'' THEN 1 ELSE 0 END),
       @c3 = MAX(CASE WHEN c.name LIKE ''%timel%'' THEN 1 ELSE 0 END),
       @c4 = MAX(CASE WHEN c.name LIKE ''%consist%'' THEN 1 ELSE 0 END),
       @c5 = MAX(CASE WHEN c.name LIKE ''%uniq%'' THEN 1 ELSE 0 END),
       @c6 = MAX(CASE WHEN c.name LIKE ''%valid%'' THEN 1 ELSE 0 END)
FROM ' + QUOTENAME(@DbName) + N'.sys.columns c
JOIN ' + QUOTENAME(@DbName) + N'.sys.tables t ON t.object_id = c.object_id
WHERE t.name LIKE ''%dq_%'' OR t.name LIKE ''%data_quality%'' OR t.name LIKE ''%quality_metric%'' OR t.name LIKE ''%quality_score%'';
SELECT @p_Db,
       CASE WHEN ISNULL(@dt,0) = 0 THEN 0
            WHEN (ISNULL(@c1,0)+ISNULL(@c2,0)+ISNULL(@c3,0)+ISNULL(@c4,0)+ISNULL(@c5,0)+ISNULL(@c6,0)) >= 4 THEN 3
            WHEN (ISNULL(@c1,0)+ISNULL(@c2,0)+ISNULL(@c3,0)+ISNULL(@c4,0)+ISNULL(@c5,0)+ISNULL(@c6,0)) >= 2 THEN 2
            ELSE 1 END,
       CASE WHEN ISNULL(@dt,0) = 0 THEN ''No DQ metrics table found''
            ELSE CONCAT(''DQ metrics tables = '', @dt, '', KPI dimensions represented = '', (ISNULL(@c1,0)+ISNULL(@c2,0)+ISNULL(@c3,0)+ISNULL(@c4,0)+ISNULL(@c5,0)+ISNULL(@c6,0)), '' of 6'') END;';

            INSERT INTO #DbResults (DbName, DbScore, Finding)
            EXEC sp_executesql @Sql, N'@p_Db SYSNAME', @p_Db = @DbName;
        END TRY
        BEGIN CATCH
            INSERT INTO #DbResults (DbName, DbScore, Finding)
            VALUES (@DbName, 0, CONCAT('Evaluation failed: ', ERROR_MESSAGE()));
        END CATCH;

        FETCH NEXT FROM db_cursor INTO @DbName;
    END

    CLOSE db_cursor;
    DEALLOCATE db_cursor;
END

SET @DatabaseQueried = ISNULL((SELECT STRING_AGG(CONVERT(NVARCHAR(MAX), DbName), ', ') FROM #DbResults), 'None');
SET @Score = ISNULL((SELECT MIN(DbScore) FROM #DbResults), 0);
SET @Finding = ISNULL((SELECT STRING_AGG(CONVERT(NVARCHAR(MAX), DbName) + ': ' + Finding, '; ') FROM #DbResults), 'No database found to be queried');
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;