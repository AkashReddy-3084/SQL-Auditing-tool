/* Checklist 4.2.4 - Surrogate keys used for dimensions (IDENTITY/sequence), not business keys in facts
   Read-only metadata inspection. Executed in the context of one user database. */
SET NOCOUNT ON;

DECLARE @DatabaseQueried sysname = DB_NAME();
DECLARE @Result NVARCHAR(50);
DECLARE @Score INT;
DECLARE @Finding NVARCHAR(MAX);
DECLARE @DimTotal INT = 0;
DECLARE @DimOK INT = 0;
DECLARE @FactTotal INT = 0;
DECLARE @FactOK INT = 0;
DECLARE @ObjTotal INT = 0;
DECLARE @ObjOK INT = 0;
DECLARE @Pct DECIMAL(9,2) = 0;
DECLARE @BadDims NVARCHAR(MAX) = N'';
DECLARE @BadFacts NVARCHAR(MAX) = N'';

IF OBJECT_ID('tempdb..#Dim') IS NOT NULL DROP TABLE #Dim;
IF OBJECT_ID('tempdb..#Fact') IS NOT NULL DROP TABLE #Fact;

CREATE TABLE #Dim
(
    object_id     INT NOT NULL PRIMARY KEY,
    FullName      NVARCHAR(600) NOT NULL,
    PKColumnCount INT NOT NULL,
    IsSurrogate   BIT NOT NULL,
    Reason        NVARCHAR(200) NOT NULL
);

CREATE TABLE #Fact
(
    object_id          INT NOT NULL PRIMARY KEY,
    FullName           NVARCHAR(600) NOT NULL,
    FKColumnCount      INT NOT NULL,
    BusinessKeyFKCount INT NOT NULL,
    IsCompliant        BIT NOT NULL,
    Reason             NVARCHAR(200) NOT NULL
);

/* ---------- Dimension tables ---------- */
INSERT INTO #Dim (object_id, FullName, PKColumnCount, IsSurrogate, Reason)
SELECT  t.object_id,
        QUOTENAME(s.name) + N'.' + QUOTENAME(t.name),
        ISNULL(pk.PKColumnCount, 0),
        CASE WHEN ISNULL(pk.PKColumnCount, 0) = 1 AND ISNULL(pk.SurrogateColumns, 0) = 1
             THEN CAST(1 AS BIT) ELSE CAST(0 AS BIT) END,
        CASE WHEN ISNULL(pk.PKColumnCount, 0) = 0 THEN N'no primary key'
             WHEN ISNULL(pk.PKColumnCount, 0) > 1 THEN N'composite primary key (business key)'
             WHEN ISNULL(pk.SurrogateColumns, 0) = 0 THEN N'primary key is not IDENTITY or sequence-backed'
             ELSE N'surrogate key present'
        END
FROM sys.tables AS t
INNER JOIN sys.schemas AS s
        ON s.schema_id = t.schema_id
OUTER APPLY
(
    SELECT  COUNT(*) AS PKColumnCount,
            SUM(CASE WHEN c.is_identity = 1
                       OR (dc.definition IS NOT NULL AND dc.definition LIKE N'%NEXT VALUE FOR%')
                     THEN 1 ELSE 0 END) AS SurrogateColumns
    FROM sys.indexes AS i
    INNER JOIN sys.index_columns AS ic
            ON ic.object_id = i.object_id
           AND ic.index_id  = i.index_id
    INNER JOIN sys.columns AS c
            ON c.object_id = ic.object_id
           AND c.column_id = ic.column_id
    LEFT JOIN sys.default_constraints AS dc
           ON dc.parent_object_id  = c.object_id
          AND dc.parent_column_id  = c.column_id
    WHERE i.object_id      = t.object_id
      AND i.is_primary_key = 1
) AS pk
WHERE t.is_ms_shipped = 0
  AND t.type = 'U'
  AND (t.name LIKE N'Dim%' OR t.name LIKE N'%[_]Dim' OR t.name LIKE N'%Dimension%');

/* ---------- Fact tables ---------- */
INSERT INTO #Fact (object_id, FullName, FKColumnCount, BusinessKeyFKCount, IsCompliant, Reason)
SELECT  t.object_id,
        QUOTENAME(s.name) + N'.' + QUOTENAME(t.name),
        ISNULL(fk.FKColumnCount, 0),
        ISNULL(fk.BusinessKeyFKCount, 0),
        CASE WHEN ISNULL(fk.FKColumnCount, 0) > 0 AND ISNULL(fk.BusinessKeyFKCount, 0) = 0
             THEN CAST(1 AS BIT) ELSE CAST(0 AS BIT) END,
        CASE WHEN ISNULL(fk.FKColumnCount, 0) = 0
             THEN N'no dimension foreign keys - keys held inline'
             WHEN ISNULL(fk.BusinessKeyFKCount, 0) > 0
             THEN CAST(fk.BusinessKeyFKCount AS NVARCHAR(20)) + N' foreign key column(s) use business keys'
             ELSE N'all foreign keys reference surrogate keys'
        END
FROM sys.tables AS t
INNER JOIN sys.schemas AS s
        ON s.schema_id = t.schema_id
OUTER APPLY
(
    SELECT  COUNT(*) AS FKColumnCount,
            SUM(CASE WHEN pt.name IN (N'char', N'varchar', N'nchar', N'nvarchar', N'uniqueidentifier',
                                      N'date', N'datetime', N'datetime2', N'smalldatetime')
                     THEN 1
                     WHEN rc.is_identity = 0
                      AND (rdc.definition IS NULL OR rdc.definition NOT LIKE N'%NEXT VALUE FOR%')
                     THEN 1
                     ELSE 0 END) AS BusinessKeyFKCount
    FROM sys.foreign_keys AS f
    INNER JOIN sys.foreign_key_columns AS fkc
            ON fkc.constraint_object_id = f.object_id
    INNER JOIN sys.columns AS pc
            ON pc.object_id = fkc.parent_object_id
           AND pc.column_id = fkc.parent_column_id
    INNER JOIN sys.types AS pt
            ON pt.user_type_id = pc.user_type_id
    INNER JOIN sys.columns AS rc
            ON rc.object_id = fkc.referenced_object_id
           AND rc.column_id = fkc.referenced_column_id
    LEFT JOIN sys.default_constraints AS rdc
           ON rdc.parent_object_id = rc.object_id
          AND rdc.parent_column_id = rc.column_id
    WHERE f.parent_object_id = t.object_id
) AS fk
WHERE t.is_ms_shipped = 0
  AND t.type = 'U'
  AND (t.name LIKE N'Fact%' OR t.name LIKE N'%[_]Fact' OR t.name LIKE N'%[_]Facts');

SELECT @DimTotal = COUNT(*),
       @DimOK    = SUM(CASE WHEN IsSurrogate = 1 THEN 1 ELSE 0 END)
FROM #Dim;

SELECT @FactTotal = COUNT(*),
       @FactOK    = SUM(CASE WHEN IsCompliant = 1 THEN 1 ELSE 0 END)
FROM #Fact;

SET @DimTotal  = ISNULL(@DimTotal, 0);
SET @DimOK     = ISNULL(@DimOK, 0);
SET @FactTotal = ISNULL(@FactTotal, 0);
SET @FactOK    = ISNULL(@FactOK, 0);
SET @ObjTotal  = @DimTotal + @FactTotal;
SET @ObjOK     = @DimOK + @FactOK;

SELECT @BadDims = STUFF((
        SELECT TOP (5) N', ' + d.FullName + N' (' + d.Reason + N')'
        FROM #Dim AS d
        WHERE d.IsSurrogate = 0
        ORDER BY d.FullName
        FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N'');

SELECT @BadFacts = STUFF((
        SELECT TOP (5) N', ' + f.FullName + N' (' + f.Reason + N')'
        FROM #Fact AS f
        WHERE f.IsCompliant = 0
        ORDER BY f.FullName
        FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N'');

SET @BadDims  = ISNULL(@BadDims, N'none');
SET @BadFacts = ISNULL(@BadFacts, N'none');

IF @ObjTotal = 0
BEGIN
    SET @Result = N'NeedsReview';
    SET @Score  = 0;
    SET @Finding = N'No tables matching dimension (Dim%/%_Dim/%Dimension%) or fact (Fact%/%_Fact/%_Facts) naming conventions were found in database [' + @DatabaseQueried
                 + N']. Surrogate-key usage could not be assessed automatically; manually review the data model to confirm dimensions use IDENTITY or sequence surrogate keys and facts reference them instead of business keys.';
END
ELSE
BEGIN
    SET @Pct = CAST(@ObjOK AS DECIMAL(9,2)) * 100.0 / CAST(@ObjTotal AS DECIMAL(9,2));

    SET @Score = CASE WHEN @Pct >= 100 THEN 3
                      WHEN @Pct >= 80  THEN 2
                      WHEN @Pct >= 50  THEN 1
                      ELSE 0 END;

    SET @Result = CASE WHEN @Score = 3 THEN N'Pass' ELSE N'Fail' END;

    SET @Finding = N'Database [' + @DatabaseQueried + N']: '
                 + CAST(@DimOK AS NVARCHAR(20)) + N' of ' + CAST(@DimTotal AS NVARCHAR(20))
                 + N' dimension table(s) use a single-column IDENTITY or sequence-backed surrogate primary key; '
                 + CAST(@FactOK AS NVARCHAR(20)) + N' of ' + CAST(@FactTotal AS NVARCHAR(20))
                 + N' fact table(s) reference dimensions only through surrogate keys. Overall compliance '
                 + CAST(@Pct AS NVARCHAR(20)) + N'%. Non-compliant dimensions: ' + @BadDims
                 + N'. Non-compliant facts: ' + @BadFacts + N'.';
END

IF OBJECT_ID('tempdb..#Dim') IS NOT NULL DROP TABLE #Dim;
IF OBJECT_ID('tempdb..#Fact') IS NOT NULL DROP TABLE #Fact;

SELECT @Result             AS Result,
       @Score              AS Score,
       @DatabaseQueried    AS DatabaseQueried,
       @Finding            AS Finding;