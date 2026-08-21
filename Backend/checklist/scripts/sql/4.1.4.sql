SET NOCOUNT ON;

DECLARE @Result NVARCHAR(20) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(MAX) = 'None';
DECLARE @Finding NVARCHAR(MAX) = 'No database found to be queried';

DECLARE @IsAzure BIT = CASE WHEN CONVERT(INT, SERVERPROPERTY('EngineEdition')) = 5 THEN 1 ELSE 0 END;
DECLARE @Total BIGINT = 0, @Suspect BIGINT = 0, @DbCount INT = 0;
DECLARE @DbList NVARCHAR(MAX) = N'';
DECLARE @WorstDb SYSNAME = NULL, @WorstCount BIGINT = -1;
DECLARE @db SYSNAME, @prefix NVARCHAR(300), @sql NVARCHAR(MAX);
DECLARE @t BIGINT, @s BIGINT;

DECLARE @Body NVARCHAR(MAX) = N'SELECT @t_out = COUNT_BIG(*),
       @s_out = ISNULL(SUM(CASE WHEN
            (ty.name IN (''char'',''varchar'',''nchar'',''nvarchar'',''text'',''ntext'')
             AND (n.nm LIKE ''%date%'' OR n.nm LIKE ''%time%'' OR n.nm LIKE ''%dob''
                  OR n.nm LIKE ''%amount%'' OR n.nm LIKE ''%amt'' OR n.nm LIKE ''%qty%''
                  OR n.nm LIKE ''%quantity%'' OR n.nm LIKE ''%price%'' OR n.nm LIKE ''%salary%''
                  OR n.nm LIKE ''%balance%''))
         OR (ty.name IN (''int'',''bigint'',''smallint'',''tinyint'',''decimal'',''numeric'',''float'',''real'')
             AND (n.nm LIKE ''%date%'' OR n.nm LIKE ''%timestamp%'')
             AND n.nm NOT LIKE ''%id'' AND n.nm NOT LIKE ''%key'')
         OR (ty.name IN (''float'',''real'')
             AND (n.nm LIKE ''%amount%'' OR n.nm LIKE ''%price%'' OR n.nm LIKE ''%cost%''
                  OR n.nm LIKE ''%salary%'' OR n.nm LIKE ''%balance%''))
         THEN 1 ELSE 0 END), 0)
FROM {P}sys.columns AS c
INNER JOIN {P}sys.tables AS tb ON tb.object_id = c.object_id AND tb.is_ms_shipped = 0
INNER JOIN {P}sys.types AS ty ON ty.user_type_id = c.user_type_id
CROSS APPLY (VALUES (REPLACE(LOWER(c.name), ''updat'', ''''))) AS n(nm);';

IF @IsAzure = 1
BEGIN
    SET @db = DB_NAME();
    SET @sql = REPLACE(@Body, N'{P}', N'');
    SET @t = NULL; SET @s = NULL;
    BEGIN TRY
        EXEC sp_executesql @sql, N'@t_out BIGINT OUTPUT, @s_out BIGINT OUTPUT', @t_out = @t OUTPUT, @s_out = @s OUTPUT;
    END TRY
    BEGIN CATCH
        SET @t = NULL; SET @s = NULL;
    END CATCH
    IF @t IS NOT NULL
    BEGIN
        SET @Total = @t; SET @Suspect = ISNULL(@s, 0); SET @DbCount = 1;
        SET @DbList = @db; SET @WorstDb = @db; SET @WorstCount = ISNULL(@s, 0);
    END
END
ELSE
BEGIN
    DECLARE db_cur CURSOR LOCAL FAST_FORWARD FOR
        SELECT name FROM sys.databases
        WHERE database_id > 4 AND state = 0 AND source_database_id IS NULL AND HAS_DBACCESS(name) = 1
        ORDER BY name;
    OPEN db_cur;
    FETCH NEXT FROM db_cur INTO @db;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @prefix = QUOTENAME(@db) + N'.';
        SET @sql = REPLACE(@Body, N'{P}', @prefix);
        SET @t = NULL; SET @s = NULL;
        BEGIN TRY
            EXEC sp_executesql @sql, N'@t_out BIGINT OUTPUT, @s_out BIGINT OUTPUT', @t_out = @t OUTPUT, @s_out = @s OUTPUT;
        END TRY
        BEGIN CATCH
            SET @t = NULL; SET @s = NULL;
        END CATCH
        IF @t IS NOT NULL
        BEGIN
            SET @Total = @Total + @t;
            SET @Suspect = @Suspect + ISNULL(@s, 0);
            SET @DbCount = @DbCount + 1;
            IF LEN(@DbList) < 3500
                SET @DbList = @DbList + CASE WHEN LEN(@DbList) = 0 THEN N'' ELSE N', ' END + @db;
            IF ISNULL(@s, 0) > @WorstCount
            BEGIN
                SET @WorstCount = ISNULL(@s, 0);
                SET @WorstDb = @db;
            END
        END
        FETCH NEXT FROM db_cur INTO @db;
    END
    CLOSE db_cur;
    DEALLOCATE db_cur;
END

IF @DbCount = 0
BEGIN
    SET @Result = 'Fail';
    SET @Score = 0;
    SET @DatabaseQueried = 'None';
    SET @Finding = 'No database found to be queried';
END
ELSE
BEGIN
    DECLARE @Pct DECIMAL(9,4) = CASE WHEN @Total = 0 THEN 0 ELSE (@Suspect * 100.0) / @Total END;
    SET @DatabaseQueried = ISNULL(NULLIF(@DbList, N''), 'None');
    SET @Score = CASE WHEN @Suspect = 0 THEN 3
                      WHEN @Pct <= 1.0 THEN 2
                      WHEN @Pct <= 5.0 THEN 1
                      ELSE 0 END;
    SET @Result = CASE WHEN @Score = 3 THEN 'Pass' ELSE 'Fail' END;
    SET @Finding = ISNULL(
        'Scanned ' + CONVERT(NVARCHAR(20), @DbCount) + ' database(s); ' + CONVERT(NVARCHAR(20), @Total)
        + ' user-table column(s) examined; ' + CONVERT(NVARCHAR(20), @Suspect)
        + ' column(s) (' + CONVERT(NVARCHAR(20), @Pct) + '%) carry date/time or numeric semantics but use a character or otherwise incorrect declared type'
        + CASE WHEN @Suspect > 0 AND @WorstDb IS NOT NULL
               THEN '; highest count in database [' + @WorstDb + '] with ' + CONVERT(NVARCHAR(20), @WorstCount) + ' column(s)'
               ELSE '' END + '.',
        'Unable to summarise column type findings.');
END

SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;