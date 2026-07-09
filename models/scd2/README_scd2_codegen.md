# YAML-driven SCD2 generation

Define dimensions once in `dbt_project.yml`:

```yaml
vars:
  scd2_dimensions:
    - name: dim_entity
      source: stg_entity
      natural_key: entity_id
      change_date_column: _landing_extract_date
      hash_column: attribute_hash
      presentation_exclude: [_batch_id, _loaded_at, attribute_hash]
```

Generate dbt shim files from that YAML. Stock dbt-core exposes no
file-write function to Jinja, so on standard runtimes the macro prints a
POSIX script - pipe it through `sh` from the project root (drop the
`| sh` to review what would be written):

```bash
dbt --quiet run-operation scd2_generate_shims | sh
```

On runtimes that provide a `write_file` context function, the plain form
writes the files directly:

```bash
dbt run-operation scd2_generate_shims
```

Generated files are written to:

- `models/scd2/generated/*__history.sql`
- `models/scd2/generated/*__candidate.sql`
- `models/scd2/generated/*__published.sql`
- `tests/generated/*__gates.sql`

On `write_file` runtimes you can keep them in sync automatically by calling
it on run start (on stock dbt-core, run the pipe command manually or in CI
instead - as a hook it would only print the script into the logs):

```yaml
on-run-start:
  - "{{ scd2_generate_shims() }}"
  - "{{ scd2_bootstrap_audit() }}"

on-run-end:
  - "{{ scd2_approve_batches(results) }}"
```

Note that dbt parses the project **before** `on-run-start` executes, so
shims for a newly added dimension are picked up by the *next* invocation,
not the run that generated them.

## `dbt_project.yml` snippet for Synapse dedicated SQL pool

```yaml
name: your_project_name
version: 1.0.0
config-version: 2

profile: your_synapse_profile

model-paths: ["models"]
test-paths: ["tests"]
macro-paths: ["macros"]

vars:
  scd2_dimensions:
    - name: dim_entity
      source: stg_entity
      natural_key: entity_id
      change_date_column: _landing_extract_date
      hash_column: attribute_hash
      presentation_exclude:
        - _batch_id
        - _loaded_at
        - attribute_hash
      surrogate_key: dim_entity_sk
      dist_column: entity_id
      natural_key_cast: nvarchar(400)
      dedupe_order_by: attribute_hash
      volume_guard_factor: 0.5
      volume_guard_window: 7

on-run-start:
  # Ensure generated shims always match vars.scd2_dimensions
  - "{{ scd2_generate_shims() }}"
  # Ensure approval table exists
  - "{{ scd2_bootstrap_audit() }}"

on-run-end:
  # Approve successful batches, block failed/skipped/missing gates, refresh published table swap
  - "{{ scd2_approve_batches(results) }}"

models:
  your_project_name:
    +persist_docs:
      relation: true
      columns: true

    scd2:
      +schema: mart

      # Generated shims route into your existing macro-driven materializations
      generated:
        +tags: ["scd2", "generated"]

      # Optional: keep hand-authored shims/docs tagged consistently
      +tags: ["scd2"]

tests:
  your_project_name:
    generated:
      +schema: audit
      +tags: ["scd2", "scd2_gate", "generated"]
```

Notes:
- Use `dbt build` (not `dbt run`) for SCD2 dimensions so gate tests execute in the same invocation; batches are not approved if the gate test did not run or was skipped.
- History/candidate/gate shims must not use a dbt `alias`. The published shim aliases to the marker (`dim_entity`) — the consumption name — and drops any existing consumption table before recreating the view.
- `presentation_exclude` drops columns from `*__published` and the consumer table (`dim_entity`) only. History and candidate views keep every column for gates and audit. Natural keys, `valid_from`, and `dist_column` cannot be excluded.
- History/candidate/published behavior is still controlled by macro `config()` in `scd2_dimension.sql` (`scd2_history`, `scd2_candidate`, `scd2_published`).
- Gate tests are generated into `tests/generated` and use `scd2_gate_test`, which already sets `store_failures=true` and `schema='audit'`.
- Synapse-specific table refresh remains CTAS + `RENAME OBJECT` via `scd2_refresh_published`.

## Synapse dedicated SQL pool requirements

Staging models feeding SCD2 history should enforce these upstream (the macros validate at run time):

| Requirement | Why |
|-------------|-----|
| `change_date_column` is `date` (or consistently cast to `date`) | Becomes `valid_from`; mixed `date`/`datetime` comparisons are fragile |
| `attribute_hash` is non-null `varchar`/`char` | NULL hashes are silently dropped by the change filter (`<> NULL` is unknown) |
| Natural keys are non-null | NULL keys break surrogate-key grain and reconciliation |
| String columns bounded (`nvarchar(≤4000)`, `varchar(≤8000)`) | Dedicated pool rejects `(max)`; drift macro caps metadata but staging should match |
| No `text`, `ntext`, `xml`, `geography`, etc. | Hard compile error in `scd2_synapse_ddl_type` |
| `numeric` vs `decimal` and `datetime2` scale differences | Treated as compatible; true width mismatches (`varchar(50)` vs `varchar(100)`) still fail |
| `audit` schema | Auto-created by `scd2_bootstrap_audit()` on first run |
