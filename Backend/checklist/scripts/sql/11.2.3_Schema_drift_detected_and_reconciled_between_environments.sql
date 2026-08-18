-- Checklist: Schema drift detected and reconciled between environments
-- Scope: DATABASE
-- Scoring: 0: No deployment tracking metadata found. 1: Basic version tracking (extended properties or version table). 2: Structured deployment metadata with timestamps/versions. 3: Comprehensive versioning and reconciliation indicators present.
-- NOTE: This script provides automated evidence. Full compliance requires human review.

DECLARE @EngineEdition INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));
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
    -- Azure SQL Database: Evaluate current database only
    SET @DbName = DB_NAME();
    SET @Sql = N'
        DECLARE @PropCount INT = 0;
        DECLARE @TableCount INT = 0;
        DECLARE @VersionProps NVARCHAR(MAX) = '';
        DECLARE @VersionTables NVARCHAR(MAX) = '';

        SELECT @PropCount = COUNT(*)
        FROM sys.extended_properties
        WHERE name LIKE ''%Version%'' OR name LIKE ''%Deployment%'' OR name LIKE ''%Drift%'' OR name LIKE ''%LastDeployed%'';

        SELECT @VersionProps = STRING_AGG(CONVERT(NVARCHAR(128), name), '', '')
        FROM sys.extended_properties
        WHERE name LIKE ''%Version%'' OR name LIKE ''%Deployment%'' OR name LIKE ''%Drift%'' OR name LIKE ''%LastDeployed%'';

        SELECT @TableCount = COUNT(*)
        FROM sys.tables t
        WHERE t.name LIKE ''%Version%'' OR t.name LIKE ''%Deployment%'' OR t.name LIKE ''%Drift%'';

        SELECT @VersionTables = STRING_AGG(CONVERT(NVARCHAR(128), t.name), '', '')
        FROM sys.tables t
        WHERE t.name LIKE ''%Version%'' OR t.name LIKE ''%Deployment%'' OR t.name LIKE ''%Drift%'';

        DECLARE @DbScore INT = 0;
        DECLARE @DbFinding NVARCHAR(MAX) = '';

        IF @PropCount > 0 AND @TableCount > 0
            SET @DbScore = 3;
        ELSE IF @PropCount > 0 OR @TableCount > 0
            SET @DbScore = 2;
        ELSE IF @PropCount > 0
            SET @DbScore = 1;
        ELSE
            SET @DbScore = 0;

        SET @DbFinding = CASE 
            WHEN @DbScore = 3 THEN ''Comprehensive versioning metadata found: Props=['' + @VersionProps + ''], Tables=['' + @VersionTables + '']''
            WHEN @DbScore = 2 THEN ''Structured deployment metadata found: Props=['' + ISNULL(@VersionProps, ''None'') + ''], Tables=['' + ISNULL(@VersionTables, ''None'') + '']''
            WHEN @DbScore = 1 THEN ''Basic version tracking found: Props=['' + @VersionProps + '']''
            ELSE ''No deployment tracking metadata found''
        END;

        INSERT INTO #DbResults (DbName, DbScore, Finding)
        VALUES (@pDbName, @DbScore, @DbFinding);
    ';
    EXEC sp_executesql @Sql, N'@pDbName NVARCHAR(128)', @pDbName = @DbName;
END
ELSE
BEGIN
    -- SQL Server / Azure SQL MI: Iterate user databases
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
                DECLARE @PropCount INT = 0;
                DECLARE @TableCount INT = 0;
                DECLARE @VersionProps NVARCHAR(MAX) = '';
                DECLARE @VersionTables NVARCHAR(MAX) = '';

                SELECT @PropCount = COUNT(*)
                FROM sys.extended_properties
                WHERE name LIKE ''%Version%'' OR name LIKE ''%Deployment%'' OR name LIKE ''%Drift%'' OR name LIKE ''%LastDeployed%'';

                SELECT @VersionProps = STRING_AGG(CONVERT(NVARCHAR(128), name), '', '')
                FROM sys.extended_properties
                WHERE name LIKE ''%Version%'' OR name LIKE ''%Deployment%'' OR name LIKE ''%Drift%'' OR name LIKE ''%LastDeployed%'';

                SELECT @TableCount = COUNT(*)
                FROM sys.tables t
                WHERE t.name LIKE ''%Version%'' OR t.name LIKE ''%Deployment%'' OR t.name LIKE ''%Drift%'';

                SELECT @VersionTables = STRING_AGG(CONVERT(NVARCHAR(128), t.name), '', '')
                FROM sys.tables t
                WHERE t.name LIKE ''%Version%'' OR t.name LIKE ''%Deployment%'' OR t.name LIKE ''%Drift%'';

                DECLARE @DbScore INT = 0;
                DECLARE @DbFinding NVARCHAR(MAX) = '';

                IF @PropCount > 0 AND @TableCount > 0
                    SET @DbScore = 3;
                ELSE IF @PropCount > 0 OR @TableCount > 0
                    SET @DbScore = 2;
                ELSE IF