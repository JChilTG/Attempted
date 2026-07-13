-- Example: conform source SID (carries only a country NAME, which can differ
-- from canonical) to the canonical country table. UPDATE the source() refs and
-- column names to your real objects. Overrides for SID live in the
-- country_conformance_overrides seed with match_key = 'name'
-- (e.g. "United States" -> US, resolving to canonical "United States of America").
{{ config(materialized='view', tags=['staging', 'country_conform']) }}

{{ country_conform(
    source_relation       = source('sid', 'records'),
    source_system         = 'SID',
    match_key             = 'name',
    source_column         = 'country_name',
    canonical_relation    = source('reference', 'country'),
    canonical_code_column = 'country_code',
    canonical_name_column = 'country_name'
) }}
