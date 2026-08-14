-- Checklist: Partition alignment supports fast load/switch and purge (sliding window)
-- Scope: DATABASE
-- Scoring: 0=Misaligned indexes; 1=Aligned but non-date boundaries; 2=Aligned+date boundaries, no switch procs; 3=Aligned+date boundaries+switch procs
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @DbName NVARCHAR(256);
DECLARE @Sql NVARCHAR(MAX);

CREATE TABLE #DbResults (DbName NVARCHAR(256), DbScore INT);

DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
SELECT name FROM sys.databases
WHERE database_id > 4 AND state = 0;

OPEN db_cursor;
FETCH NEXT FROM db_cursor INTO @DbName;
WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        SET @Sql = N'USE ' + QUOTENAME(@DbName) + N';
        DECLARE @TotalPartitioned INT = 0;
        DECLARE @AlignedCount INT = 0;
        DECLARE @NonDateBoundaryCount INT = 0;
        DECLARE @SwitchEvidence INT = 0;
        DECLARE @DbScore INT = 3;

        -- Count partitioned tables (heap or clustered index)
        SELECT @TotalPartitioned = COUNT(*)
        FROM sys.tables t
        JOIN sys.indexes i ON t.object_id = i.object_id AND i.index_id <= 1
        JOIN sys.partition_schemes ps ON i.data_space_id = ps.data_space_id
        WHERE t.type = ''U'';

        IF @TotalPartitioned > 0
        BEGIN
            -- Check alignment: all indexes on partitioned tables must use the same partition scheme
            SELECT @AlignedCount = COUNT(*)
            FROM (
                SELECT t.object_id, COUNT(DISTINCT i.data_space_id) AS scheme_count
                FROM sys.tables t
                JOIN sys.indexes i ON t.object_id = i.object_id
                JOIN sys.partition_schemes ps ON i.data_space_id = ps.data_space_id
                WHERE t.type = ''U''
                GROUP BY t.object_id
            ) AS aligned
            WHERE scheme_count = 1;

            -- Check for non-date/time boundaries on partition functions used by partitioned tables
            SELECT @NonDateBoundaryCount = COUNT(DISTINCT t.object_id)
            FROM sys.tables t
            JOIN sys.indexes i ON t.object_id = i.object_id AND i.index_id <= 1
            JOIN sys.partition_schemes ps ON i.data_space_id = ps.data_space_id
            JOIN sys.partition_functions pf ON ps.function_id = pf.function_id
            JOIN sys.types ty ON pf.type_id = ty.user_type_id
            WHERE t.type = ''U''
              AND ty.name NOT IN (''date'',''datetime'',''datetime2'',''smalldatetime'',''datetimeoffset'');

            -- Check for switching/purge procedures
            SELECT @SwitchEvidence = COUNT(*)
            FROM sys.procedures p
            JOIN sys.sql_modules m ON p.object_id = m.object_id
            WHERE m.definition LIKE ''%SWITCH%'' OR m.definition LIKE ''%TRUNCATE%PARTITION%'';

            IF @AlignedCount < @TotalPartitioned SET @DbScore = 0;
            ELSE IF @NonDateBoundaryCount > 0 SET @DbScore = 1;
            ELSE IF @SwitchEvidence = 0 SET @DbScore = 2;
            ELSE SET @DbScore = 3;
        END

        INSERT INTO #DbResults VALUES (''' + REPLACE(@DbName, '''', '''''') + ''', @DbScore);';
        EXEC sp_executesql @Sql;
    END TRY
    BEGIN CATCH
        INSERT INTO #DbResults VALUES (@DbName, 0);
    END CATCH;
    FETCH NEXT FROM db_cursor INTO @DbName;
END
CLOSE db_cursor;
DEALLOCATE db_cursor;

SET @Score = ISNULL((SELECT MIN(DbScore) FROM #DbResults), 0);
SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
DROP TABLE #DbResults;
SELECT @Result AS Result, @Score AS Score;
-- NOTE: This script provides automated evidence. Full compliance requires human review of sliding window procedures and boundary intervals.