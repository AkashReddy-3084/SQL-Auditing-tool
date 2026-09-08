-- Checklist: Integration tests validate end-to-end ETL
-- Scope: DATABASE
-- Scoring: 3 = test procedures reference ETL/load objects, evidencing end-to-end coverage; 2 = a unit-test framework schema plus test procedures exist but none reference ETL objects; 1 = test procedures exist without a framework or ETL coverage; 0 = no test procedures found

SET NOCOUNT ON;

DECLARE @Result NVARCHAR(10) = 'Fail';
DECLARE @Score INT = 0;
DECLARE @DatabaseQueried NVARCHAR(128) = DB_NAME();
DECLARE @Finding NVARCHAR(MAX) = 'Test artefacts could not be inspected in this database';

DECLARE @TestProcs INT = 0;
DECLARE @TestList NVARCHAR(MAX) = '';
DECLARE @EtlObjects INT = 0;
DECLARE @IntegrationTests INT = 0;
DECLARE @Framework INT = 0;

BEGIN TRY
    SELECT @TestProcs = COUNT(*),
           @TestList = ISNULL(LEFT(STRING_AGG(CONVERT(NVARCHAR(MAX), s.name + '.' + p.name), ', '), 400), '')
    FROM sys.procedures AS p
    INNER JOIN sys.schemas AS s ON s.schema_id = p.schema_id
    WHERE p.is_ms_shipped = 0
      AND (p.name LIKE '%test%' OR p.name LIKE '%spec[_]%' OR s.name LIKE '%test%');
END TRY
BEGIN CATCH
    SET @TestProcs = 0;
END CATCH

BEGIN TRY
    SELECT @EtlObjects = COUNT(*)
    FROM sys.objects
    WHERE is_ms_shipped = 0
      AND type IN ('P', 'V', 'U')
      AND (name LIKE '%etl%' OR name LIKE '%load%' OR name LIKE '%pipeline%'
           OR name LIKE '%staging%' OR name LIKE '%stg[_]%' OR name LIKE '%extract%');
END TRY
BEGIN CATCH
    SET @EtlObjects = 0;
END CATCH

BEGIN TRY
    SELECT @IntegrationTests = COUNT(DISTINCT d.referencing_id)
    FROM sys.sql_expression_dependencies AS d
    INNER JOIN sys.procedures AS p ON p.object_id = d.referencing_id
    INNER JOIN sys.schemas AS s ON s.schema_id = p.schema_id
    WHERE (p.name LIKE '%test%' OR p.name LIKE '%spec[_]%' OR s.name LIKE '%test%')
      AND (d.referenced_entity_name LIKE '%etl%' OR d.referenced_entity_name LIKE '%load%'
           OR d.referenced_entity_name LIKE '%pipeline%' OR d.referenced_entity_name LIKE '%staging%'
           OR d.referenced_entity_name LIKE '%stg[_]%' OR d.referenced_entity_name LIKE '%extract%');
END TRY
BEGIN CATCH
    SET @IntegrationTests = 0;
END CATCH

BEGIN TRY
    SELECT @Framework = COUNT(*)
    FROM sys.schemas
    WHERE name IN ('tSQLt', 'tst', 'unittest', 'tests', 'integrationtest');
END TRY
BEGIN CATCH
    SET @Framework = 0;
END CATCH

SET @Score = CASE WHEN @IntegrationTests > 0 THEN 3
                  WHEN @TestProcs > 0 AND @Framework > 0 THEN 2
                  WHEN @TestProcs > 0 THEN 1
                  ELSE 0 END;

SET @Finding = CASE
    WHEN @TestProcs = 0
        THEN CONCAT('No test procedure found in this database; ', @EtlObjects,
                    ' ETL/load object(s) exist and are therefore untested here')
    ELSE CONCAT(@TestProcs, ' test procedure(s) found (', @TestList, '); ', @IntegrationTests,
                ' of them reference one of the ', @EtlObjects,
                ' ETL/load object(s) in this database; test-framework schemas present = ', @Framework)
    END;

SET @Result = CASE WHEN @Score >= 2 THEN 'Pass' ELSE 'Fail' END;
SELECT @Result AS Result, @Score AS Score, @DatabaseQueried AS DatabaseQueried, @Finding AS Finding;
