/*
    scd2_refresh_published
    ----------------------
    Rebuilds the consumer-facing consumption TABLE (e.g. dim_entity) from
    the approval-gated logical view (e.g. dim_entity__published) and swaps
    it in via RENAME OBJECT. This is the "materialized view" for this
    architecture: Synapse dedicated pool's native CREATE MATERIALIZED VIEW
    requires an aggregate + GROUP BY and forbids window functions and
    EXISTS, so it cannot express the SCD2 derivation - a CTAS-and-swap
    table is the supported equivalent.

    The refresh is only ever triggered when the APPROVED batch set changes:
      - by scd2_approve_batches() at on-run-end, after a batch passes gates
      - by scd2_rollback() / scd2_restore_last_rollback()

    It is deliberately NOT a dbt model: models materialize before
    on-run-end approval, so a dbt table model would always capture the
    previous approved state and lag one batch behind. Triggering from the
    approval machinery keeps table content exactly equal to the approved
    set at all times.

    Failure ordering: the replacement table is fully built BEFORE the
    current table is touched, so a failed CTAS leaves consumers on the
    old table. The swap itself is metadata-only. There is a sub-second
    window between the two RENAMEs where dim_entity does not exist;
    in-flight queries at that instant may error and should retry.

    The consumption table takes the marker name (meta.scd2_model), in the
    same schema as the published view - so consumers keep querying
    dim_entity exactly as before, now as a table.

    Post-CTAS verification (before swap): __new exists and row counts match
    the published view. After swap: consumption table exists with same count.
    On failure the __new table is dropped (when pre-swap) and approval is
    rolled back by scd2_approve_batches.
*/


{% macro scd2_raise_refresh_error(message) %}
    {{ scd2_fail_run('scd2_refresh_published: ' ~ message) }}
{% endmacro %}


{% macro scd2_refresh_published(marker, dist_column=none) %}
    {%- if not execute -%}{%- do return({'ok': true}) -%}{%- endif -%}

    {%- set view_rel = scd2_find_published_relation(marker) -%}
    {%- if view_rel is none -%}
        {%- do return({
            'ok': false,
            'error': 'no model tagged scd2_published with meta.scd2_model = ' ~ marker
        }) -%}
    {%- endif -%}

    {%- set sch  = view_rel.schema -%}
    {%- set tbl  = marker -%}
    {%- set full = sch ~ '.' ~ tbl -%}
    {%- set new_tbl = full ~ '__new' -%}
    {%- if dist_column is none -%}
        {%- set dist_column = scd2_dist_column_for_marker(marker) -%}
    {%- endif -%}
    {%- set dist_quoted = adapter.quote(dist_column) -%}

    {#- 0. one-time migration: if a plain VIEW still occupies the consumer
        name (pre-materialization deployments), remove it -#}
    {%- do run_query("IF OBJECT_ID('" ~ full ~ "', 'V') IS NOT NULL DROP VIEW " ~ full) -%}

    {#- 1. build the replacement FIRST - a failure here leaves the current
        table untouched and consumers unaffected -#}
    {%- do run_query("IF OBJECT_ID('" ~ new_tbl ~ "') IS NOT NULL DROP TABLE " ~ new_tbl) -%}
    {%- do run_query(
        "CREATE TABLE " ~ new_tbl ~ " " ~
        "WITH (DISTRIBUTION = HASH(" ~ dist_quoted ~ "), CLUSTERED COLUMNSTORE INDEX) " ~
        "AS SELECT * FROM " ~ view_rel) -%}

    {#- 2. verify __new exists and row counts match the published view -#}
    {%- set exists_new = run_query(
        "select case when object_id('" ~ new_tbl ~ "', 'U') is not null then 1 else 0 end as object_exists") -%}
    {%- if exists_new.rows[0][0] != 1 -%}
        {%- do return({
            'ok': false,
            'error': 'CTAS completed but ' ~ new_tbl ~ ' was not created'
        }) -%}
    {%- endif -%}

    {%- set counts = run_query(
        "select " ~
        "(select count_big(*) from " ~ view_rel ~ ") as view_cnt, " ~
        "(select count_big(*) from " ~ new_tbl ~ ") as new_cnt") -%}
    {%- set view_cnt = counts.rows[0][0] -%}
    {%- set new_cnt = counts.rows[0][1] -%}
    {%- if view_cnt != new_cnt -%}
        {%- do run_query("IF OBJECT_ID('" ~ new_tbl ~ "') IS NOT NULL DROP TABLE " ~ new_tbl) -%}
        {%- do return({
            'ok': false,
            'error': 'row-count mismatch after CTAS: view=' ~ view_cnt ~
                     ' table=' ~ new_cnt ~ ' (left ' ~ new_tbl ~ ' dropped; consumer table untouched)'
        }) -%}
    {%- endif -%}

    {#- 3. metadata-only swap -#}
    {%- do run_query("IF OBJECT_ID('" ~ full ~ "__old') IS NOT NULL DROP TABLE " ~ full ~ "__old") -%}
    {%- do run_query("IF OBJECT_ID('" ~ full ~ "') IS NOT NULL RENAME OBJECT " ~ full ~ " TO " ~ tbl ~ "__old") -%}
    {%- do run_query("RENAME OBJECT " ~ new_tbl ~ " TO " ~ tbl) -%}
    {%- do run_query("IF OBJECT_ID('" ~ full ~ "__old') IS NOT NULL DROP TABLE " ~ full ~ "__old") -%}

    {#- 4. verify the swapped-in table exists -#}
    {%- set exists_final = run_query(
        "select case when object_id('" ~ full ~ "', 'U') is not null then 1 else 0 end as object_exists") -%}
    {%- if exists_final.rows[0][0] != 1 -%}
        {%- do return({
            'ok': false,
            'error': 'RENAME swap finished but consumption table ' ~ full ~ ' is missing'
        }) -%}
    {%- endif -%}

    {%- set final_cnt = run_query("select count_big(*) as row_cnt from " ~ full) -%}
    {%- if final_cnt.rows[0][0] != view_cnt -%}
        {%- do return({
            'ok': false,
            'error': 'post-swap row-count mismatch on ' ~ full ~
                     ': expected ' ~ view_cnt ~ ' got ' ~ final_cnt.rows[0][0]
        }) -%}
    {%- endif -%}

    {%- do log('scd2_refresh_published: ' ~ full ~ ' rebuilt from ' ~ view_rel ~
               ' (' ~ view_cnt ~ ' rows) and swapped in (CTAS + RENAME)', info=True) -%}
    {%- do return({'ok': true, 'row_count': view_cnt}) -%}
{% endmacro %}


{#- Find the scd2_published model node for a marker and return its relation -#}
{% macro scd2_find_published_relation(marker) %}
    {%- for node in graph.nodes.values() -%}
        {%- if node.resource_type == 'model'
              and 'scd2_published' in node.tags
              and (node.config.get('meta', {}).get('scd2_model') == marker
                   or node.get('meta', {}).get('scd2_model') == marker) -%}
            {%- do return(api.Relation.create(
                    database=node.database,
                    schema=node.schema,
                    identifier=node.get('alias') or node.name)) -%}
        {%- endif -%}
    {%- endfor -%}
    {%- do return(none) -%}
{% endmacro %}


{#- Resolve the scd2_model marker for a model name (used by run-operations
    that only receive the history model's name) -#}
{% macro scd2_marker_for_model(model_name) %}
    {%- for node in graph.nodes.values() -%}
        {%- if node.resource_type == 'model'
              and (node.name == model_name or node.get('alias') == model_name) -%}
            {%- do return(node.config.get('meta', {}).get('scd2_model')
                          or node.get('meta', {}).get('scd2_model')) -%}
        {%- endif -%}
    {%- endfor -%}
    {%- do return(none) -%}
{% endmacro %}


{#- Resolve CTAS distribution key for a marker from vars.scd2_dimensions:
    explicit dist_column wins, then the (first) natural_key column.
    Fallback remains entity_id for markers not declared in vars. -#}
{% macro scd2_dist_column_for_marker(marker) %}
    {%- set dims = var('scd2_dimensions', []) -%}
    {%- for d in dims -%}
        {%- if d.get('name') == marker -%}
            {%- if d.get('dist_column') -%}
                {%- do return(d.get('dist_column')) -%}
            {%- endif -%}
            {%- set nk = d.get('natural_key') -%}
            {%- if nk is string -%}
                {%- do return(nk) -%}
            {%- elif nk -%}
                {%- do return(nk[0]) -%}
            {%- endif -%}
            {%- do return('entity_id') -%}
        {%- endif -%}
    {%- endfor -%}
    {%- do return('entity_id') -%}
{% endmacro %}
