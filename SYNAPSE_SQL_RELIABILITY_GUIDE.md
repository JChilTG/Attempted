# Synapse Dedicated SQL Pool: SQL Reliability Checklist

## INSERT Statements

- **NO**: `INSERT ... VALUES` with expressions/functions
  ```sql
  INSERT INTO t VALUES (MD5(...), GETDATE(), ...)  -- ❌ FAILS
  ```
- **YES**: `INSERT ... SELECT` with all computation in SELECT
  ```sql
  INSERT INTO t SELECT MD5(...), GETDATE(), ... FROM source  -- ✅ WORKS
  ```

## String Types

- **MAX** types not supported: `varchar(max)`, `nvarchar(max)`, `varbinary(max)`
- **Limits**: `varchar ≤ 8000`, `nvarchar ≤ 4000`
- **Cast fallback**: `CAST(col AS nvarchar(400))` when concatenating keys

## Datetime Handling

- Use **DATE** not DATETIME for logical dates
- For timestamps: `datetime2(0)` or `datetime2(7)`
- Locale-safe CONVERT: use explicit styles
  - `CONVERT(date, col, 23)` — ISO date YYYY-MM-DD
  - `CONVERT(datetime2(0), col, 126)` — ISO 8601 with T separator
- **Avoid**: implicit conversions (depends on session LANGUAGE setting)

## Unsupported Types (Hard Error)

- `text`, `ntext`, `xml`, `geography`, `geometry`, `hierarchyid`, `image`, `sql_variant`, `timestamp`
- Replace with `varchar(n)` or structured columns

## DELETE Restrictions

- **NO**: `DELETE ... FROM ... JOIN` — multi-table deletes
- **YES**: `DELETE ... FROM ... WHERE EXISTS (subquery)` — single-table with correlated subquery
  ```sql
  DELETE FROM t WHERE NOT EXISTS (SELECT 1 FROM other WHERE condition)  -- ✅
  ```

## NULL Safety in Comparisons

- **NO**: `WHERE col IN (SELECT ...)` when subquery may contain NULL
- **YES**: `WHERE EXISTS (SELECT 1 FROM ...)` or `WHERE col IN (SELECT col FROM ... WHERE col IS NOT NULL)`
- **SAFE**: `WHERE <> NULL` fails silently (unknown); use `WHERE col IS NOT NULL`

## Window Functions

- **Grain**: Partition keys must match HASH distribution to avoid shuffle
  - Distribution: `HASH(customer_id)`
  - Partition: `PARTITION BY customer_id`
- **No CTE materialization**: Use CTEs for readability, not optimization
- **LEAD/LAG safe**: Runs locally within distribution; no performance penalty

## MERGE Statements

- Supported on Synapse Dedicated SQL Pool
- Can compute expressions in WHEN ... THEN INSERT/UPDATE branches
- More verbose than INSERT ... SELECT but works for complex logic

## Type Equivalence

- `numeric(p,s)` and `decimal(p,s)` — interchangeable with CAST
- `datetime` and `datetime2(7)` — interchangeable
- `datetime2(n1)` and `datetime2(n2)` — interchangeable (precision may differ)
- **NOT equivalent**: `varchar(50)` vs `varchar(100)` (width mismatch = hard error)

## Transactions & Isolation

- Default isolation: READ COMMITTED
- **NO**: `BEGIN TRAN ... ROLLBACK` inside procedures (may hang in distributed context)
- **YES**: Single statement atomicity; dbt handles transaction wrapping

## CTAS (Create Table As Select)

- Always include distribution: `WITH (DISTRIBUTION = HASH(col))`
- Always include index: `WITH (DISTRIBUTION = HASH(col), CLUSTERED COLUMNSTORE INDEX)`
- **Metadata-only operation**: No data movement until queries run
- RENAME OBJECT swap is sub-second

## Materialized Views

- Native materialized views require `GROUP BY` (no window functions)
- **Workaround**: CTAS table + RENAME for SCD2 with LEAD/LAG

## Statistics & Indexing

- CCI (Clustered Columnstore Index) = default for analytics
- Heap tables OK for temp/staging if short-lived
- **No traditional indexes** (row store) on CCI tables — use CCI for filtering

## Naming & Identifiers

- Reserved words: require brackets `[column_name]`
- Case-insensitive (SQL Server collation)
- Max 128 characters for identifiers
- Avoid special characters except `_`

## Joins & Cardinality

- Broadcast joins: small table copied to each node (< 2GB)
- Shuffle join: large-to-large requires all nodes communicate
- **Minimize shuffles**: Distribute both tables on join key

## Aggregations

- `GROUP BY` → shuffle (if group key not distribution key)
- `SUM`, `AVG`, `MAX`, `MIN` → safe
- **NO**: `COUNT(DISTINCT ...)` without group key (requires two passes)
- **YES**: `COUNT(DISTINCT ...) FILTER (WHERE ...)` is safe

## Schema Evolution

- **ALTER TABLE ADD** `<col> <type> NULL` — metadata-only on CCI
- **ALTER TABLE DROP** — metadata-only (column hidden)
- **NO**: `ALTER COLUMN` (change type/nullability) — requires rebuild
- **Schema drift**: Detect with `INFORMATION_SCHEMA.COLUMNS` queries

## Incremental Loads

- **Append strategy**: Use `INSERT ... SELECT`
- **Watermark guards**: `WHERE col > (SELECT COALESCE(MAX(col), '1900-01-01'))`
- **Dedup**: `SELECT DISTINCT ON (key_cols) ...` or `ROW_NUMBER() ... WHERE rn=1`

## Error Handling

- Set `on_error='skip'` in materialization config only for minor issues
- Always validate in CTEs before final INSERT
- **Pre-validation queries**: `SELECT COUNT(*), NULL_RATIO FROM ...`

## dbt-sqlserver Adapter Specifics

- `incremental_strategy='append'` — only strategy for SCD2
- `on_schema_change='ignore'` — dbt won't auto-sync schema
- `unique_key` — helps dbt optimize incremental logic
- Pre-hooks run before materialization; post-hooks after
- `execute` flag gates runtime SQL vs parse-time

## Testing & Validation

- **Grain test**: `SELECT key, COUNT(*) ... HAVING COUNT(*) > 1` — duplicates = corruption
- **Nulls test**: `SELECT * WHERE col IS NULL` — presence = corruption
- **Reconciliation**: Published ⊆ Source (LEFT JOIN, count mismatches)
- **Volume guard**: Latest extract ≥ 50% × trailing avg (catch truncated files)

## Performance Anti-Patterns

- ❌ Querying without WHERE (full table scan)
- ❌ Joining on non-distribution keys (cross-distribution shuffle)
- ❌ Nested scalar subqueries (runs per row)
- ❌ Dynamic SQL without OPTION (LABEL='...') (can't track workload)

## Configuration Checklist

- [ ] All INSERT statements use `INSERT ... SELECT` (not VALUES with functions)
- [ ] No `(max)` types; all strings bounded
- [ ] No unsupported types (text, xml, geography)
- [ ] CTAS includes DISTRIBUTION and INDEX
- [ ] Window function partitions match HASH distribution
- [ ] DELETE uses single table with EXISTS subquery
- [ ] Datetime columns use CONVERT with explicit style
- [ ] Natural keys are non-NULL
- [ ] Surrogate keys are deterministic (MD5, not NEWID)
