/*
    country_conform / country_conform_unmatched_report
    ---------------------------------------------------
    Country-specific thin wrappers over the dimension-agnostic conformance
    engine in conform_dimension.sql. The resolution logic (override wins ->
    auto-match on code/name -> unmatched) lives once in conform_dimension();
    these just pin entity='country' and the country override seed's target
    column, so existing callers and output columns are unchanged:

      - canonical_country_code   (ISO alpha-2, NULL when unmatched)
      - canonical_country_name   (from the canonical table, NULL when unmatched)
      - country_match_status     ('override' | 'exact_code' | 'exact_name' | 'unmatched')

    See CONFORMANCE_GUIDE.md to replicate this pattern for another dimension
    (e.g. ports) - typically you call conform_dimension() directly with
    entity='port' rather than writing wrappers like these.

    Usage (as a model body):

        {{ config(materialized='view', tags=['staging', 'country_conform']) }}
        {{ country_conform(
            source_relation      = source('fid', 'transactions'),
            source_system        = 'FID',
            match_key            = 'code',
            source_column        = 'country_code',
            canonical_relation   = source('reference', 'country'),
            canonical_code_column= 'country_code',
            canonical_name_column= 'country_name'
        ) }}
*/


{% macro country_conform(
    source_relation,
    source_system,
    match_key,
    source_column,
    canonical_relation,
    canonical_code_column='country_code',
    canonical_name_column='country_name',
    overrides_relation=none,
    name_collation='Latin1_General_CI_AI'
) %}
{{ conform_dimension(
    entity                = 'country',
    source_relation       = source_relation,
    source_system         = source_system,
    match_key             = match_key,
    source_column         = source_column,
    canonical_relation    = canonical_relation,
    canonical_code_column = canonical_code_column,
    canonical_name_column = canonical_name_column,
    overrides_relation    = overrides_relation,
    override_code_column  = 'canonical_country_code',
    name_collation        = name_collation
) }}
{% endmacro %}


{% macro country_conform_unmatched_report(conformed) %}
{{ conform_unmatched_report('country', conformed) }}
{% endmacro %}
