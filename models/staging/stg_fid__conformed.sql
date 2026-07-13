-- Example: conform source FID (carries an ISO alpha-2 country_code) to the
-- canonical country table. UPDATE the source() refs and column names to your
-- real objects. Overrides for FID live in the country_conformance_overrides
-- seed with match_key = 'code' (e.g. non-ISO "UK" -> GB, "EL" -> GR).
{{ config(materialized='view', tags=['staging', 'country_conform']) }}

{{ country_conform(
    source_relation       = source('fid', 'transactions'),
    source_system         = 'FID',
    match_key             = 'code',
    source_column         = 'country_code',
    canonical_relation    = source('reference', 'country'),
    canonical_code_column = 'country_code',
    canonical_name_column = 'country_name'
) }}
