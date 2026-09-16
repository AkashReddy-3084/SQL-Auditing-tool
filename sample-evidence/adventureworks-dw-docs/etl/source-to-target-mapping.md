# Source-to-Target Mapping — AdventureWorks Data Platform

| Field | Value |
| --- | --- |
| Document version | 2.9 |
| Status | **Approved** |
| Approved by | Data Platform Engineering, change record CHG-2026-0447 |
| Last reviewed | 2026-09-04 |
| Owner | Adaeze Whitfield, Data Engineering |
| Companion document | [etl-design.md](etl-design.md) |

Target instance `(localdb)\MSSQLLocalDB`, database `AdventureWorks2025`.

## 1. Coverage

Mappings below cover the 6 source feeds that populate the platform. Every target table written by
the nightly load appears here; tables not listed are not loaded by ETL.

## 2. Feed: `customers.csv` → `Sales.Customer`

| Source column | Target column | Type | Transformation |
| --- | --- | --- | --- |
| `cust_id` | `CustomerID` | `int` | Direct; business key |
| `person_ref` | `PersonID` | `int` | Lookup against `Person.Person`; unmatched → `dbo.ErrorLog` |
| `store_ref` | `StoreID` | `int` | Lookup against `Sales.Store`; null permitted |
| `territory_code` | `TerritoryID` | `int` | Lookup against `Sales.SalesTerritory` |
| — | `rowguid` | `uniqueidentifier` | Generated on insert |
| — | `ModifiedDate` | `datetime` | Load timestamp |

## 3. Feed: `orders.csv` → `Sales.SalesOrderHeader`

| Source column | Target column | Type | Transformation |
| --- | --- | --- | --- |
| `order_no` | `SalesOrderID` | `int` | Direct; business key |
| `order_dt` | `OrderDate` | `datetime` | Parsed `dd/MM/yyyy`; rejected if unparseable |
| `due_dt` | `DueDate` | `datetime` | Parsed `dd/MM/yyyy` |
| `ship_dt` | `ShipDate` | `datetime` | Nullable; blank → `NULL` |
| `cust_id` | `CustomerID` | `int` | FK to `Sales.Customer` |
| `currency` | `CurrencyRateID` | `int` | Resolved via `Sales.CurrencyRate` on `OrderDate` |
| — | `SubTotal` | `money` | **Recalculated** from `Sales.SalesOrderDetail`, source value discarded |
| — | `TotalDue` | `money` | `SubTotal + TaxAmt + Freight` |

## 4. Feed: `order_lines.csv` → `Sales.SalesOrderDetail`

| Source column | Target column | Type | Transformation |
| --- | --- | --- | --- |
| `order_no` | `SalesOrderID` | `int` | FK to `Sales.SalesOrderHeader` |
| `line_no` | `SalesOrderDetailID` | `int` | Direct |
| `sku` | `ProductID` | `int` | Lookup against `Production.Product` on `ProductNumber` |
| `qty` | `OrderQty` | `smallint` | Rejected if `<= 0` |
| `unit_price` | `UnitPrice` | `money` | Converted to USD |
| `discount_pct` | `UnitPriceDiscount` | `money` | Divided by 100 |

## 5. Feed: `products.csv` → `Production.Product`

| Source column | Target column | Type | Transformation |
| --- | --- | --- | --- |
| `sku` | `ProductNumber` | `nvarchar(25)` | Trimmed, upper-cased; business key |
| `name` | `Name` | `nvarchar(50)` | Trimmed |
| `list_price` | `ListPrice` | `money` | Converted to USD |
| `sell_end` | `SellEndDate` | `datetime` | Null → product treated as active |

## 6. Feed: `people.csv` → `Person.Person`

| Source column | Target column | Type | Transformation |
| --- | --- | --- | --- |
| `person_ref` | `BusinessEntityID` | `int` | Direct; business key |
| `given_name` | `FirstName` | `nvarchar(50)` | Trim, collapse whitespace, title-case |
| `family_name` | `LastName` | `nvarchar(50)` | Trim, collapse whitespace, title-case |
| `person_type` | `PersonType` | `nchar(2)` | Mapped: `EMP`→`EM`, `CUS`→`IN`, `VEN`→`VC` |

## 7. Feed: `vendors.csv` → `Purchasing.Vendor`

| Source column | Target column | Type | Transformation |
| --- | --- | --- | --- |
| `vendor_ref` | `BusinessEntityID` | `int` | Direct; business key |
| `vendor_name` | `Name` | `nvarchar(50)` | Trimmed |
| `credit_rating` | `CreditRating` | `tinyint` | Rejected unless 1–5 |
| `active_flag` | `ActiveFlag` | `bit` | `Y`→1, `N`→0 |

## 8. Rejection handling

Any row failing a lookup, parse or range rule is written to `dbo.ErrorLog` with the source file
name, line number, `ErrorColumn` and `ErrorMessage`. Rejected rows never fail the batch.

## 9. Change history

| Version | Date | Change |
| --- | --- | --- |
| 2.9 | 2026-09-04 | Added the vendors feed |
| 2.7 | 2026-06-22 | Documented `SubTotal` recalculation |
