/*
    fact_snapshot_refresh_published
    --------------------------------
    Rebuilds the consumer-facing consumption TABLE (e.g. fact_inventory_snapshot)
    from the approval-gated logical view (e.g. fact_inventory_snapshot__published)
    and swaps it in via RENAME OBJECT. Sibling to scd2_refresh_published
    (scd2_publish_table.sql) - identical CTAS+RENAME-and-verify mechanics,
    parameterized over the fact_snapshot_published tag / meta key instead of
    the scd2_published ones.

    Same triggering rule as the SCD2 side: only ever called when the
    APPROVED batch set changes (fact_snapshot_approve_batches at
    on-run-end), never as a dbt model itself, for the same reason - a dbt
    table model would materialize before on-run-end approval and always
    lag one batch behind.
*/


{#- Drop the consumption TABLE (and any stale VIEW) so the published model
    can materialize as a view at alias=<marker> after a prior CTAS refresh. -#}
{% macro fact_snapshot_prepare_published_view(relation) %}
    IF OBJECT_ID('{{ relation.schema }}.{{ relation.identifier }}', 'U') IS NOT NULL
        DROP TABLE {{ relation.schema }}.{{ relation.identifier }};
    IF OBJECT_ID('{{ relation.schema }}.{{ relation.identifier }}', 'V') IS NOT NULL
        DROP VIEW {{ relation.schema }}.{{ relation.identifier }};
{% endmacro %}


{#- Find the fact_snapshot_published model node for a marker and return its relation -#}
{% macro fact_snapshot_find_published_relation(marker) %}
    {%- for node in graph.nodes.values() -%}
        {%- if node.resource_type == 'model'
              and 'fact_snapshot_published' in node.tags
              and (node.config.get('meta', {}).get('fact_snapshot_model') == marker
                   or node.get('meta', {}).get('fact_snapshot_model') == marker) -%}
            {%- do return(api.Relation.create(
                    database=node.database,
                    schema=node.schema,
                    identifier=node.get('alias') or node.name)) -%}
        {%- endif -%}
    {%- endfor -%}
    {%- do return(none) -%}
{% endmacro %}


{#- Resolve the fact_snapshot_model marker for a model name (used by
    run-operations that only receive the history model's name) -#}
{% macro fact_snapshot_marker_for_model(model_name) %}
    {%- for node in graph.nodes.values() -%}
        {%- if node.resource_type == 'model'
              and (node.name == model_name or node.get('alias') == model_name) -%}
            {%- do return(node.config.get('meta', {}).get('fact_snapshot_model')
                          or node.get('meta', {}).get('fact_snapshot_model')) -%}
        {%- endif -%}
    {%- endfor -%}
    {%- do return(none) -%}
{% endmacro %}


{#- Resolve CTAS distribution key for a marker from vars.fact_snapshots:
    explicit dist_column wins, then the (first) natural_key column. -#}
{% macro fact_snapshot_dist_column_for_marker(marker) %}
    {%- set facts = var('fact_snapshots', []) -%}
    {%- for d in facts -%}
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


{% macro fact_snapshot_refresh_published(marker, dist_column=none) %}
    {%- if not execute -%}{%- do return({'ok': true}) -%}{%- endif -%}

    {%- set view_rel = fact_snapshot_find_published_relation(marker) -%}
    {%- if view_rel is none -%}
        {%- do return({
            'ok': false,
            'error': 'no model tagged fact_snapshot_published with meta.fact_snapshot_model = ' ~ marker
        }) -%}
    {%- endif -%}

    {%- set sch  = view_rel.schema -%}
    {%- set tbl  = marker -%}
    {%- set full = sch ~ '.' ~ tbl -%}
    {%- set new_tbl = full ~ '__new' -%}
    {%- if dist_column is none -%}
        {%- set dist_column = fact_snapshot_dist_column_for_marker(marker) -%}
    {%- endif -%}
    {%- set dist_quoted = adapter.quote(dist_column) -%}

    {#- 0. one-time migration: if a plain VIEW still occupies the consumer
        name, remove it -#}
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
        "select case when object_id('" ~ new_tbl ~ "', 'U') is not null then 1 else 0 end") -%}
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
        "select case when object_id('" ~ full ~ "', 'U') is not null then 1 else 0 end") -%}
    {%- if exists_final.rows[0][0] != 1 -%}
        {%- do return({
            'ok': false,
            'error': 'RENAME swap finished but consumption table ' ~ full ~ ' is missing'
        }) -%}
    {%- endif -%}

    {%- set final_cnt = run_query("select count_big(*) from " ~ full) -%}
    {%- if final_cnt.rows[0][0] != view_cnt -%}
        {%- do return({
            'ok': false,
            'error': 'post-swap row-count mismatch on ' ~ full ~
                     ': expected ' ~ view_cnt ~ ' got ' ~ final_cnt.rows[0][0]
        }) -%}
    {%- endif -%}

    {%- do log('fact_snapshot_refresh_published: ' ~ full ~ ' rebuilt from ' ~ view_rel ~
               ' (' ~ view_cnt ~ ' rows) and swapped in (CTAS + RENAME)', info=True) -%}
    {%- do return({'ok': true, 'row_count': view_cnt}) -%}
{% endmacro %}
