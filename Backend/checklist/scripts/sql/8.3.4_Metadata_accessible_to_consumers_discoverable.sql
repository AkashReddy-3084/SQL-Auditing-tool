-- Checklist: Metadata accessible to consumers (discoverable)
-- Scope: DATABASE
-- Scoring: 0 = No extended properties or metadata views found; 1 = Extended properties exist but no consumer access/views; 2 = Metadata views exist or consumer roles have SELECT on tables; 3 = Comprehensive extended properties + metadata views + explicit consumer access
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
        DECLARE @ExtPropCount INT = 0;
        DECLARE @MetaViewCount INT = 0;
        DECLARE @ConsumerAccess BIT = 0;
        DECLARE @LocalScore INT = 0;

        SELECT @ExtPropCount = COUNT(*) FROM sys.extended_properties WHERE class = 1;

        SELECT @MetaViewCount = COUNT(*) FROM sys.views v
        WHERE v.name LIKE ''%metadata%'' OR v.name LIKE ''%dictionary%'' OR v.name LIKE ''%glossary%'' OR v.name LIKE ''%data_dict%'';

        SELECT @ConsumerAccess = 1 FROM sys.database_permissions dp
        JOIN sys.database_principals p ON dp.grantee_principal_id = p.principal_id
        WHERE dp.permission_name = ''SELECT''
        AND dp.major_id > 0
        AND (p.name = ''public'' OR p.name = ''db_datareader'' OR p.name LIKE ''%reader%'' OR p.name LIKE ''%consumer%'' OR p.name LIKE ''%analyst%'');

        IF @ExtPropCount > 0 SET @LocalScore = 1;
        IF @MetaViewCount > 0 SET @LocalScore = 2;
        IF @ExtPropCount > 0 AND @MetaViewCount > 0 AND @ConsumerAccess = 1 SET @LocalScore = 3;

        INSERT INTO #DbResults VALUES (''' + REPLACE(@DbName, '''', '''''') + ''', @LocalScore);';
        
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