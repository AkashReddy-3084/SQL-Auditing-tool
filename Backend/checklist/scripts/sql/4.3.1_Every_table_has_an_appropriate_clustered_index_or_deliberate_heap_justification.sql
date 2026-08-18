-- Checklist: Every table has an appropriate clustered index (or deliberate heap justification)
-- Scope: DATABASE
-- Scoring: 3: 100% compliant; 2: >=90% compliant; 1: >=50% compliant; 0: <50% compliant. Compliant = has clustered index OR heap has extended property justification.

DECLARE @EngineEdition INT = CAST(SERVERPROPERTY('EngineEdition') AS INT);
DECLARE @Score INT = 0;
DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @DbName NVARCHAR(256);
DECLARE @Sql NVARCHAR(MAX);
DECLARE @DatabaseQueried NVARCHAR(MAX);
DECLARE @Finding NVARCHAR(MAX);

CREATE TABLE #DbResults (
    DbName NVARCHAR(128),
    DbScore INT,
    Finding NVARCHAR(MAX)
);

IF @EngineEdition = 5
BEGIN
    -- Azure SQL Database: evaluate current database only
    SET @DbName = DB_NAME();
    SET @Sql = N'
    DECLARE @TotalTables INT;
    DECLARE @CompliantTables INT;
    DECLARE @HeapNames NVARCHAR(MAX);
    
    SELECT @TotalTables = COUNT(*)
    FROM sys.tables
    WHERE type = ''U'';
    
    SELECT @CompliantTables = COUNT(*)
    FROM sys.tables t
    WHERE type = ''U''
      AND (
          EXISTS (SELECT 1 FROM sys.indexes i WHERE i.object_id = t.object_id AND i.type = 1)
          OR EXISTS (
              SELECT 1 FROM sys.extended_properties ep 
              WHERE ep.major_id = t.object_id 
                AND ep.minor_id = 0 
                AND (ep.name = ''HeapJustification'' OR CAST(ep.value AS NVARCHAR(MAX)) LIKE ''%heap%'' OR CAST(ep.value AS NVARCHAR(MAX)) LIKE ''%justification%'')
          )
      );
      
    SELECT @HeapNames = STRING_AGG(t.name, '', '')
    FROM sys.tables t
    WHERE type = ''U''
      AND NOT EXISTS (SELECT 1 FROM sys.indexes i WHERE i.object_id = t.object_id AND i.type = 1)
      AND NOT EXISTS (
          SELECT 1 FROM sys.extended_properties ep 
          WHERE ep.major_id = t.object_id 
            AND ep.minor_id = 0 
            AND (ep.name = ''HeapJustification'' OR CAST(ep.value AS NVARCHAR(MAX)) LIKE ''%heap%'' OR CAST(ep.value AS NVARCHAR(MAX)) LIKE ''%justification%'')
      );
      
    DECLARE @Pct FLOAT = CASE WHEN @TotalTables = 0 THEN 100.0 ELSE CAST(@CompliantTables AS FLOAT) / @TotalTables * 100.0 END;
    DECLARE @DbScore INT = 0;
    DECLARE @DbFinding NVARCHAR(MAX) = '''';
    
    IF @TotalTables = 0
    BEGIN
        SET @DbScore = 3;
        SET @DbFinding = ''No user tables found'';
    END
    ELSE IF @Pct = 100.0
    BEGIN
        SET @DbScore = 3;
        SET @DbFinding = ''All tables have clustered indexes'';
    END
    ELSE IF @Pct >= 90.0
    BEGIN
        SET @DbScore = 2;
        SET @DbFinding = '''' + CAST(@Pct AS NVARCHAR(10)) + ''% compliant. Non-compliant heaps: '' + ISNULL(@HeapNames, ''None'');
    END
    ELSE IF @Pct >= 50.0
    BEGIN
        SET @DbScore = 1;
        SET @DbFinding = '''' + CAST(@Pct AS NVARCHAR(10)) + ''% compliant. Non-compliant heaps: '' + ISNULL(@HeapNames, ''None'');
    END
    ELSE
    BEGIN
        SET @DbScore = 0;
        SET @DbFinding = '''' + CAST(@Pct AS NVARCHAR(10)) + ''% compliant. Non-compliant heaps: '' + ISNULL(@HeapNames, ''None'');
    END
    
    INSERT INTO #DbResults (DbName, DbScore, Finding)
    VALUES (''' + @DbName + ''', @DbScore, @DbFinding);
    ';
    EXEC sp_executesql @Sql;
END
ELSE
BEGIN
    -- SQL Server / Azure SQL MI: iterate user databases
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
            DECLARE @TotalTables INT;
            DECLARE @CompliantTables INT;
            DECLARE @HeapNames NVARCHAR(MAX);
            
            SELECT @TotalTables = COUNT(*)
            FROM sys.tables
            WHERE type = ''U'';
            
            SELECT @CompliantTables = COUNT(*)
            FROM sys.tables t
            WHERE type = ''U''
              AND (
                  EXISTS (SELECT 1 FROM sys.indexes i WHERE i.object_id = t.object_id AND i.type = 1)
                  OR EXISTS (
                      SELECT 1 FROM sys.extended_properties ep 
                      WHERE ep.major_id = t.object_id 
                        AND ep.minor_id = 0 
                        AND (ep.name = ''HeapJustification'' OR CAST(ep.value AS NVARCHAR(MAX)) LIKE ''%heap%'' OR CAST(ep.value AS NVARCHAR(MAX)) LIKE ''%justification%'')
                  )
              );
              
            SELECT @HeapNames = STRING_AGG(t.name, '', '')
            FROM sys.tables t
            WHERE type = ''U''
              AND NOT EXISTS (SELECT 1 FROM sys.indexes i WHERE i.object_id = t.object_id AND i.type = 1)
              AND NOT EXISTS (
                  SELECT 1 FROM sys.extended_properties ep 
                  WHERE ep.major_id = t.object_id 
                    AND ep.minor_id = 0 
                    AND (ep.name = ''HeapJustification'' OR CAST(ep.value AS NVARCHAR(MAX)) LIKE ''%heap%'' OR CAST(ep.value AS NVARCHAR(MAX)) LIKE ''%justification%'')
              );
              
            DECLARE @Pct FLOAT = CASE WHEN @TotalTables = 0 THEN 100.0 ELSE CAST(@CompliantTables AS FLOAT) / @TotalTables * 100.0 END;
            DECLARE @DbScore INT = 0;
            DECLARE @DbFinding NVARCHAR(MAX) = '''';
            
            IF @TotalTables = 0
            BEGIN
                SET @DbScore = 3;
                SET @DbFinding = ''No user tables found'';
            END
            ELSE IF @Pct = 100.0
            BEGIN
                SET @DbScore = 3;
                SET @DbFinding = ''All tables have clustered indexes'';
            END
            ELSE IF @Pct >= 90.0
            BEGIN
                SET @DbScore = 2;
                SET @DbFinding = '''' + CAST(@Pct AS NVARCHAR(10)) + ''% compliant. Non-compliant heaps: '' + ISNULL(@HeapNames, ''None'');
            END
            ELSE IF @Pct >= 50.0
            BEGIN
                SET @DbScore = 1;
                SET @DbFinding = '''' + CAST(@Pct AS NVARCHAR(10)) + ''% compliant. Non-compliant heaps: '' + ISNULL(@HeapNames, ''None'');
            END
            ELSE
            BEGIN
                SET @DbScore = 0;
                SET @DbFinding = '''' + CAST(@Pct AS NVARCHAR(10)) + ''% compliant. Non-compliant heaps: '' + ISNULL(@HeapNames, ''None'');
            END
            
            INSERT INTO #DbResults (DbName, DbScore, Finding)
            VALUES (''' + @DbName + ''', @DbScore, @DbFinding);
            ';
            EXEC sp_executesql @Sql;
        END TRY
        BEGIN CATCH
            INSERT INTO #DbResults (DbName, DbScore, Finding)
            VALUES (@