/*
=====================================================================================
 Checklist Item : 4.4.3 - Filegroups used to organize storage where applicable
                          (SQL Server / Azure SQL Managed Instance)
 Scope          : DATABASE (all accessible online user databases)
 Type           : Read-only T-SQL (catalog views only)
 Output         : Result, Score, DatabaseQueried, Finding
=====================================================================================
*/
SET NOCOUNT ON;

DECLARE @EngineEdition       INT           = CAST(SERVERPROPERTY('EngineEdition') AS INT);
DECLARE @SizeThresholdMB     DECIMAL(18,2) = 10240.00;   -- below 10 GB a single PRIMARY filegroup is an accepted design

DECLARE @Result              NVARCHAR(50);
DECLARE @Score               INT = 0;
DECLARE @DatabaseQueried     NVARCHAR(MAX);
DECLARE @Finding             NVARCHAR(MAX);

DECLARE @DbName              SYSNAME;
DECLARE @Sql                 NVARCHAR(MAX);

DECLARE @TotalDbs            INT = 0;
DECLARE @ErrorDbs            INT = 0;
DECLARE @CollectedDbs        INT = 0;
DECLARE @ApplicableDbs       INT = 0;
DECLARE @CompliantApplicable INT = 0;
DECLARE @SecondaryFgDbs      INT = 0;
DECLARE @DefinedUnusedDbs    INT = 0;
DECLARE @NonCompliantList    NVARCHAR(MAX);
DECLARE @ErrorList           NVARCHAR(MAX);

IF OBJECT_ID('tempdb..#DbFilegroups') IS NOT NULL
    DROP TABLE #DbFilegroups;

CREATE TABLE #DbFilegroups
(
    DatabaseName             SYSNAME        NOT NULL,
    DataSizeMB               DECIMAL(18,2)  NULL,
    RowFilegroupCount        INT            NULL,
    SecondaryFilegroupCount  INT            NULL,
    DataFileCount            INT            NULL,
    ObjectsOnSecondaryFG     INT            NULL,
    ObjectsOnPartitionScheme INT            NULL,
    CollectionError          NVARCHAR(300)  NULL
);

IF @EngineEdition = 5
BEGIN
    /* Azure SQL Database: filegroup layout is fixed by the platform and cannot be configured. */
    SET @Score           = 3;
    SET @DatabaseQueried = DB_NAME();
    SET @Finding         = N'Not applicable on this platform. EngineEdition 5 (Azure SQL Database) exposes a single platform-managed PRIMARY filegroup and does not permit user-defined filegroups or file placement; this checklist item applies to SQL Server and Azure SQL Managed Instance only.';
END
ELSE
BEGIN
    DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT d.name
        FROM sys.databases AS d
        WHERE d.database_id > 4
          AND d.state_desc = N'ONLINE'
          AND d.source_database_id IS NULL
          AND d.is_in_standby = 0
          AND HAS_DBACCESS(d.name) = 1
        ORDER BY d.name;

    OPEN db_cursor;
    FETCH NEXT FROM db_cursor INTO @DbName;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            SET @Sql = N'
SELECT
    @pDb AS DatabaseName,
    (SELECT CAST(ISNULL(SUM(CAST(f.size AS BIGINT)), 0) * 8.0 / 1024.0 AS DECIMAL(18,2))
       FROM ' + QUOTENAME(@DbName) + N'.sys.database_files AS f
      WHERE f.type = 0) AS DataSizeMB,
    (SELECT COUNT(*)
       FROM ' + QUOTENAME(@DbName) + N'.sys.filegroups AS fg
      WHERE fg.type = ''FG'') AS RowFilegroupCount,
    (SELECT COUNT(*)
       FROM ' + QUOTENAME(@DbName) + N'.sys.filegroups AS fg
      WHERE fg.type = ''FG'' AND fg.name <> N''PRIMARY'') AS SecondaryFilegroupCount,
    (SELECT COUNT(*)
       FROM ' + QUOTENAME(@DbName) + N'.sys.database_files AS f
      WHERE f.type = 0) AS DataFileCount,
    (SELECT COUNT(*)
       FROM ' + QUOTENAME(@DbName) + N'.sys.indexes AS i
       JOIN ' + QUOTENAME(@DbName) + N'.sys.objects AS o
            ON o.object_id = i.object_id
       JOIN ' + QUOTENAME(@DbName) + N'.sys.filegroups AS fg
            ON fg.data_space_id = i.data_space_id
      WHERE o.is_ms_shipped = 0
        AND o.type = ''U''
        AND fg.name <> N''PRIMARY'') AS ObjectsOnSecondaryFG,
    (SELECT COUNT(*)
       FROM ' + QUOTENAME(@DbName) + N'.sys.indexes AS i
       JOIN ' + QUOTENAME(@DbName) + N'.sys.objects AS o
            ON o.object_id = i.object_id
       JOIN ' + QUOTENAME(@DbName) + N'.sys.partition_schemes AS ps
            ON ps.data_space_id = i.data_space_id
      WHERE o.is_ms_shipped = 0
        AND o.type = ''U'') AS ObjectsOnPartitionScheme,
    CAST(NULL AS NVARCHAR(300)) AS CollectionError;';

            INSERT INTO #DbFilegroups
            (
                DatabaseName, DataSizeMB, RowFilegroupCount, SecondaryFilegroupCount,
                DataFileCount, ObjectsOnSecondaryFG, ObjectsOnPartitionScheme, CollectionError
            )
            EXEC sp_executesql @Sql, N'@pDb SYSNAME', @pDb = @DbName;
        END TRY
        BEGIN CATCH
            INSERT INTO #DbFilegroups (DatabaseName, CollectionError)
            VALUES (@DbName, LEFT(ERROR_MESSAGE(), 300));
        END CATCH

        FETCH NEXT FROM db_cursor INTO @DbName;
    END

    CLOSE db_cursor;
    DEALLOCATE db_cursor;

    SELECT
        @TotalDbs = COUNT(*),
        @ErrorDbs = SUM(CASE WHEN d.CollectionError IS NOT NULL THEN 1 ELSE 0 END)
    FROM #DbFilegroups AS d;

    SELECT
        @CollectedDbs = COUNT(*),
        @ApplicableDbs = SUM(CASE WHEN ISNULL(d.DataSizeMB, 0) >= @SizeThresholdMB THEN 1 ELSE 0 END),
        @CompliantApplicable = SUM(CASE
                                       WHEN ISNULL(d.DataSizeMB, 0) >= @SizeThresholdMB
                                        AND ISNULL(d.SecondaryFilegroupCount, 0) >= 1
                                        AND (ISNULL(d.ObjectsOnSecondaryFG, 0) > 0
                                             OR ISNULL(d.ObjectsOnPartitionScheme, 0) > 0)
                                       THEN 1 ELSE 0
                                   END),
        @SecondaryFgDbs = SUM(CASE WHEN ISNULL(d.SecondaryFilegroupCount, 0) >= 1 THEN 1 ELSE 0 END),
        @DefinedUnusedDbs = SUM(CASE
                                    WHEN ISNULL(d.SecondaryFilegroupCount, 0) >= 1
                                     AND ISNULL(d.ObjectsOnSecondaryFG, 0) = 0
                                     AND ISNULL(d.ObjectsOnPartitionScheme, 0) = 0
                                    THEN 1 ELSE 0
                                END)
    FROM #DbFilegroups AS d
    WHERE d.CollectionError IS NULL;

    SET @CollectedDbs        = ISNULL(@CollectedDbs, 0);
    SET @ApplicableDbs       = ISNULL(@ApplicableDbs, 0);
    SET @CompliantApplicable = ISNULL(@CompliantApplicable, 0);
    SET @SecondaryFgDbs      = ISNULL(@SecondaryFgDbs, 0);
    SET @DefinedUnusedDbs    = ISNULL(@DefinedUnusedDbs, 0);
    SET @ErrorDbs            = ISNULL(@ErrorDbs, 0);

    SELECT @DatabaseQueried = STUFF((
        SELECT N', ' + d.DatabaseName
        FROM #DbFilegroups AS d
        WHERE d.CollectionError IS NULL
        ORDER BY d.DatabaseName
        FOR XML PATH(N''), TYPE).value(N'.', N'NVARCHAR(MAX)'), 1, 2, N'');

    SELECT @NonCompliantList = STUFF((
        SELECT N', ' + d.DatabaseName
               + N' (' + CAST(CAST(ISNULL(d.DataSizeMB, 0) AS DECIMAL(18,0)) AS NVARCHAR(20)) + N' MB data'
               + N', secondary filegroups: ' + CAST(ISNULL(d.SecondaryFilegroupCount, 0) AS NVARCHAR(10))
               + N', objects on secondary filegroups: ' + CAST(ISNULL(d.ObjectsOnSecondaryFG, 0) AS NVARCHAR(10))
               + N', objects on partition schemes: ' + CAST(ISNULL(d.ObjectsOnPartitionScheme, 0) AS NVARCHAR(10)) + N')'
        FROM #DbFilegroups AS d
        WHERE d.CollectionError IS NULL
          AND ISNULL(d.DataSizeMB, 0) >= @SizeThresholdMB
          AND NOT (ISNULL(d.SecondaryFilegroupCount, 0) >= 1
                   AND (ISNULL(d.ObjectsOnSecondaryFG, 0) > 0
                        OR ISNULL(d.ObjectsOnPartitionScheme, 0) > 0))
        ORDER BY d.DatabaseName
        FOR XML PATH(N''), TYPE).value(N'.', N'NVARCHAR(MAX)'), 1, 2, N'');

    SELECT @ErrorList = STUFF((
        SELECT N', ' + d.DatabaseName + N': ' + d.CollectionError
        FROM #DbFilegroups AS d
        WHERE d.CollectionError IS NOT NULL
        ORDER BY d.DatabaseName
        FOR XML PATH(N''), TYPE).value(N'.', N'NVARCHAR(MAX)'), 1, 2, N'');

    IF @CollectedDbs = 0
    BEGIN
        SET @Score           = 0;
        SET @DatabaseQueried = 'None';
        SET @Finding         = 'No database found to be queried';
    END
    ELSE IF @ApplicableDbs = 0
    BEGIN
        SET @Score = 3;
        SET @Finding = N'No user database exceeds the ' + CAST(CAST(@SizeThresholdMB AS DECIMAL(18,0)) AS NVARCHAR(20))
                       + N' MB threshold at which secondary filegroups are expected, so a single PRIMARY filegroup is an acceptable storage design. Databases inspected: '
                       + CAST(@CollectedDbs AS NVARCHAR(10))
                       + N'; databases already using secondary filegroups: ' + CAST(@SecondaryFgDbs AS NVARCHAR(10))
                       + ISNULL(N'. Collection failures: ' + @ErrorList, N'.');
    END
    ELSE IF @CompliantApplicable = @ApplicableDbs
    BEGIN
        SET @Score = 3;
        SET @Finding = N'All ' + CAST(@ApplicableDbs AS NVARCHAR(10))
                       + N' database(s) at or above the ' + CAST(CAST(@SizeThresholdMB AS DECIMAL(18,0)) AS NVARCHAR(20))
                       + N' MB threshold organise storage with secondary filegroups and/or partition schemes holding user objects. Databases inspected: '
                       + CAST(@CollectedDbs AS NVARCHAR(10))
                       + N'; databases with at least one secondary filegroup: ' + CAST(@SecondaryFgDbs AS NVARCHAR(10))
                       + ISNULL(N'. Collection failures: ' + @ErrorList, N'.');
    END
    ELSE
    BEGIN
        IF @CompliantApplicable > 0 AND @CompliantApplicable * 2 >= @ApplicableDbs
            SET @Score = 2;
        ELSE IF @CompliantApplicable > 0 OR @DefinedUnusedDbs > 0
            SET @Score = 1;
        ELSE
            SET @Score = 0;

        SET @Finding = CAST(@CompliantApplicable AS NVARCHAR(10)) + N' of ' + CAST(@ApplicableDbs AS NVARCHAR(10))
                       + N' database(s) at or above the ' + CAST(CAST(@SizeThresholdMB AS DECIMAL(18,0)) AS NVARCHAR(20))
                       + N' MB threshold use secondary filegroups or partition schemes to organise storage; the remainder keep all user data in the PRIMARY filegroup. Databases inspected: '
                       + CAST(@CollectedDbs AS NVARCHAR(10))
                       + N'; databases where secondary filegroups exist but hold no user objects: ' + CAST(@DefinedUnusedDbs AS NVARCHAR(10))
                       + ISNULL(N'. Non-compliant databases: ' + @NonCompliantList, N'.')
                       + ISNULL(N' Collection failures: ' + @ErrorList, N'');
    END
END

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;

SELECT
    @Result          AS Result,
    @Score           AS Score,
    @DatabaseQueried AS DatabaseQueried,
    @Finding         AS Finding;

IF OBJECT_ID('tempdb..#DbFilegroups') IS NOT NULL
    DROP TABLE #DbFilegroups;