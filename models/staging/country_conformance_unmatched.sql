-- Review model: every source country value that could NOT be conformed to
-- the canonical table (no override, no auto match). Add an override row to the
-- country_conformance_overrides seed for each, `dbt seed`, then rebuild.
-- Sort row_count desc to fix the highest-impact gaps first.
{{ config(materialized='view', schema='audit', tags=['country_conform', 'audit']) }}

{{ country_conform_unmatched_report([
    {'relation': ref('stg_fid__conformed'), 'source_system': 'FID',
     'match_key': 'code', 'source_column': 'country_code'},
    {'relation': ref('stg_sid__conformed'), 'source_system': 'SID',
     'match_key': 'name', 'source_column': 'country_name'}
]) }}
