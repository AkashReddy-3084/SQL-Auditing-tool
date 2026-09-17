# Source-to-Target Mapping — Contoso Data Warehouse

**Version:** 4.0
**Last reviewed:** 2026-08-21
**Owner:** Data Engineering

## dw.DimCustomer

| Target column | Type | Source system | Source column | Transformation |
|---------------|------|---------------|---------------|----------------|
| `CustomerKey` | INT IDENTITY | — | — | Surrogate key |
| `CustomerBusinessKey` | NVARCHAR(30) | Oracle ERP | `SALES.CUSTOMER.CUST_ID` | Trim, upper |
| `LegalName` | NVARCHAR(200) | Oracle ERP | `SALES.CUSTOMER.LEGAL_NAME` | Trim; ERP wins on conflict |
| `IndustryCode` | NVARCHAR(10) | Salesforce | `Account.Industry` | Lookup to `ref.IndustryCode`; Salesforce wins |
| `TaxRegistrationNumber` | NVARCHAR(40) | Oracle ERP | `SALES.CUSTOMER.VAT_NO` | Strip non-alphanumerics |
| `BillingCountryCode` | CHAR(2) | Oracle ERP | `SALES.CUSTOMER.COUNTRY` | ISO-3166 alpha-2; **SCD Type 2** |
| `AccountOwner` | NVARCHAR(120) | Salesforce | `Account.Owner.Name` | Trim |
| `IsInferred` | BIT | — | — | 1 when created by a late-arriving fact |
| `RowEffectiveFrom` / `RowEffectiveTo` | DATETIME2 | — | — | SCD Type 2 validity window |

## dw.DimProduct

| Target column | Type | Source system | Source column | Transformation |
|---------------|------|---------------|---------------|----------------|
| `ProductKey` | INT IDENTITY | — | — | Surrogate key |
| `ProductBusinessKey` | NVARCHAR(30) | Product master CSV | `SKU` | Trim, upper |
| `ProductName` | NVARCHAR(200) | Product master CSV | `Description` | Trim |
| `CategoryCode` | NVARCHAR(10) | Product master CSV | `Category` | Lookup to `ref.ProductCategory` |
| `UnitOfMeasure` | NVARCHAR(10) | Product master CSV | `UOM` | Upper; default `EA` when blank |
| `IsActive` | BIT | Product master CSV | `Status` | 1 when `Status = 'A'`, else 0 |

## dw.FactSalesLine

| Target column | Type | Source system | Source column | Transformation |
|---------------|------|---------------|---------------|----------------|
| `SalesLineKey` | BIGINT IDENTITY | — | — | Surrogate key |
| `OrderDateKey` | INT | Oracle ERP | `SALES.ORDER_HDR.ORDER_DATE` | `yyyymmdd` into `dw.DimDate` |
| `CustomerKey` | INT | — | — | Lookup on `CustomerBusinessKey`, SCD Type 2 as-at order date |
| `ProductKey` | INT | — | — | Lookup on `ProductBusinessKey` |
| `Quantity` | DECIMAL(18,4) | Oracle ERP | `SALES.ORDER_LINE.QTY` | Direct |
| `UnitPriceSource` | DECIMAL(18,4) | Oracle ERP | `SALES.ORDER_LINE.UNIT_PRICE` | Retained unconverted |
| `SourceCurrencyCode` | CHAR(3) | Oracle ERP | `SALES.ORDER_HDR.CURRENCY` | Retained for reproducibility |
| `NetAmountGBP` | DECIMAL(18,4) | Oracle ERP | derived | `Quantity * UnitPriceSource * ExchangeRate` |
| `ExchangeRate` | DECIMAL(18,8) | ECB feed | `stg.ExchangeRate.Rate` | Rate as at order date |
| `EtlRunId` | UNIQUEIDENTIFIER | — | — | Package execution ID, joins to `audit.EtlRunLog` |

## Unmapped source columns

These source columns are deliberately **not** carried into the warehouse:

| Source | Column | Reason |
|--------|--------|--------|
| Oracle ERP | `SALES.CUSTOMER.CREDIT_NOTES` | Free text, no analytical use, may contain personal data |
| Oracle ERP | `SALES.ORDER_HDR.INTERNAL_MEMO` | Free text, not reportable |
| Salesforce | `Account.Description` | Free text, not reportable |
