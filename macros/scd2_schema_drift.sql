/*
    scd2_resolve_attributes
    -----------------------
    Schema-drift-safe attribute resolution for insert-only SCD2 history
    models. Called once at the top of a history model; returns a dict:

        {
          'source_projection': [...],  -- expressions to SELECT from staging
          'names':             [...]   -- bare column names for the final SELECT
        }

    The attribute set is the UNION of (staging attributes, per star_exclude)
    and (existing history attributes, per table metadata):

      - column in BOTH            -> selected as-is (types must match exactly)
      - NEW column in staging     -> selected as-is; the history table is
                                     ALTERed to add it (nullable) before the
                                     insert runs. Historical rows are NULL,
                                     which is correct: the attribute wasn't
                                     tracked then.
      - DEPARTED column (in       -> projected as CAST(NULL AS <stored type>).
        history, not in staging)     The column and ALL its historical data
                                     stay in the table forever; new versions
                                     simply carry NULL. If the column later
                                     reappears in staging with the same type,
                                     it resumes populating automatically.
      - TYPE MISMATCH             -> hard compile error with remediation.
                                     Silent implicit conversion / truncation
                                     is how history gets corrupted; dedicated
                                     pool has no ALTER COLUMN, so widening is
                                     a deliberate CTAS rebuild, not something
                                     to do implicitly mid-run.

    Nothing here ever drops a column or a row. This deliberately replaces
    dbt's on_schema_change machinery ('sync_all_columns' DROPS departed
    columns - exactly what an SCD2 history table must never do), so the
    model sets on_schema_change='ignore' and this macro is the single
    authority on schema evolution.

    Synapse notes:
      - ALTER TABLE ... ADD <col> <type> NULL is supported on CCI tables
        and is metadata-only.
      - DDL types are rendered by scd2_synapse_ddl_type() from adapter
        Column metadata (char_size, precision, scale) - NOT column.data_type,
        which drops nvarchar lengths via FabricColumn. No (max) types: capped
        at varchar(8000) / nvarchar(4000) / varbinary(8000).
      - DDL only executes for 'run'/'build' invocations, never during
        compile/docs generation.
      - Identifiers are rendered unquoted; if you have column names needing
        [brackets], add quoting where marked.
*/


{% macro scd2_synapse_normalize_type(ddl_type) %}
    {%- do return(ddl_type | lower | replace(' ', '')) -%}
{% endmacro %}


{#- Dedicated pool rejects implicit conversions; treat obviously-compatible
    Synapse types as equal so metadata noise (numeric vs decimal, datetime2
  scale) does not block legitimate inserts. -#}
{% macro scd2_synapse_types_equivalent(type_a, type_b) %}
    {%- set a = scd2_synapse_normalize_type(type_a) -%}
    {%- set b = scd2_synapse_normalize_type(type_b) -%}
    {%- if a == b -%}
        {%- do return(true) -%}
    {%- endif -%}
    {%- if a.startswith('decimal(') and b.startswith('numeric(') -%}
        {%- do return(a | replace('decimal', 'numeric', 1) == b) -%}
    {%- endif -%}
    {%- if a.startswith('numeric(') and b.startswith('decimal(') -%}
        {%- do return(b | replace('decimal', 'numeric', 1) == a) -%}
    {%- endif -%}
    {%- if modules.re.match('^datetime2\\(\\d+\\)$', a)
          and modules.re.match('^datetime2\\(\\d+\\)$', b) -%}
        {%- do return(true) -%}
    {%- endif -%}
    {%- if a == 'datetime' and b.startswith('datetime2(') -%}
        {%- do return(true) -%}
    {%- endif -%}
    {%- if b == 'datetime' and a.startswith('datetime2(') -%}
        {%- do return(true) -%}
    {%- endif -%}
    {%- do return(false) -%}
{% endmacro %}


{% macro scd2_synapse_ddl_type(column) %}
    {%- set dt = column.dtype | lower -%}
    {%- set sz = column.char_size | int if column.char_size is not none else none -%}

    {%- if dt in ['text', 'ntext', 'xml', 'geography', 'geometry', 'hierarchyid',
                  'image', 'sql_variant', 'timestamp'] -%}
        {{ exceptions.raise_compiler_error(
            "SCD2 schema drift: column '" ~ column.name ~ "' has type '" ~ column.dtype ~
            "', which dedicated SQL pool does not support. Reshape or cast upstream in staging."
        ) }}
    {%- endif -%}

    {%- if dt in ['varchar', 'nvarchar', 'char', 'nchar'] -%}
        {%- if dt in ['varchar', 'char'] and sz is not none and sz > 8000 -%}
            {{ exceptions.raise_compiler_error(
                "SCD2 schema drift: column '" ~ column.name ~ "' is " ~ column.dtype ~
                "(" ~ sz ~ ") but dedicated SQL pool varchar columns cannot exceed 8000 " ~
                "(and (max) is not supported). Cap the column in staging."
            ) }}
        {%- endif -%}
        {%- if dt in ['nvarchar', 'nchar'] and sz is not none and sz > 4000 -%}
            {{ exceptions.raise_compiler_error(
                "SCD2 schema drift: column '" ~ column.name ~ "' is " ~ column.dtype ~
                "(" ~ sz ~ ") but dedicated SQL pool nvarchar columns cannot exceed 4000 " ~
                "(and (max) is not supported). Cap the column in staging."
            ) }}
        {%- endif -%}
        {%- if sz == -1 -%}
            {%- if dt == 'nvarchar' -%}
                {%- do return('nvarchar(4000)') -%}
            {%- elif dt in ['nchar', 'char'] -%}
                {{ exceptions.raise_compiler_error(
                    "SCD2 schema drift: column '" ~ column.name ~ "' is " ~ column.dtype ~
                    "(max), which dedicated SQL pool does not support. Use a bounded type in staging."
                ) }}
            {%- else -%}
                {%- do return('varchar(8000)') -%}
            {%- endif -%}
        {%- elif dt == 'nvarchar' -%}
            {%- set n = sz if sz and sz > 0 else 4000 -%}
            {%- do return('nvarchar(' ~ ([n, 4000] | min) ~ ')') -%}
        {%- elif dt == 'nchar' -%}
            {%- set n = sz if sz and sz > 0 else 1 -%}
            {%- do return('nchar(' ~ ([n, 4000] | min) ~ ')') -%}
        {%- elif dt == 'char' -%}
            {%- set n = sz if sz and sz > 0 else 1 -%}
            {%- do return('char(' ~ ([n, 8000] | min) ~ ')') -%}
        {%- else -%}
            {%- set n = sz if sz and sz > 0 else 8000 -%}
            {%- do return('varchar(' ~ ([n, 8000] | min) ~ ')') -%}
        {%- endif -%}
    {%- elif dt in ['decimal', 'numeric'] -%}
        {%- if column.numeric_precision is none or column.numeric_scale is none -%}
            {{ exceptions.raise_compiler_error(
                "SCD2 schema drift: column '" ~ column.name ~ "' is " ~ column.dtype ~
                " without precision/scale in metadata - cannot render safe DDL."
            ) }}
        {%- endif -%}
        {%- do return(dt ~ '(' ~ column.numeric_precision ~ ',' ~ column.numeric_scale ~ ')') -%}
    {%- elif dt == 'datetime2' -%}
        {%- set scale = column.numeric_scale if column.numeric_scale is not none else 7 -%}
        {%- do return('datetime2(' ~ scale ~ ')') -%}
    {%- elif dt == 'datetimeoffset' -%}
        {%- set scale = column.numeric_scale if column.numeric_scale is not none else 7 -%}
        {%- do return('datetimeoffset(' ~ scale ~ ')') -%}
    {%- elif dt == 'time' -%}
        {%- set scale = column.numeric_scale if column.numeric_scale is not none else 7 -%}
        {%- do return('time(' ~ scale ~ ')') -%}
    {%- elif dt == 'varbinary' -%}
        {%- if sz == -1 -%}
            {%- do return('varbinary(8000)') -%}
        {%- elif sz is none or sz <= 0 -%}
            {%- do return('varbinary(8000)') -%}
        {%- elif sz > 8000 -%}
            {{ exceptions.raise_compiler_error(
                "SCD2 schema drift: column '" ~ column.name ~ "' is varbinary(" ~ sz ~
                ") but dedicated SQL pool varbinary columns cannot exceed 8000 " ~
                "(and (max) is not supported). Cap the column in staging."
            ) }}
        {%- else -%}
            {%- do return('varbinary(' ~ sz ~ ')') -%}
        {%- endif -%}
    {%- else -%}
        {%- do return(dt) -%}
    {%- endif -%}
{% endmacro %}


{% macro scd2_resolve_attributes(
        source_relation,
        history_relation,
        source_exclude,
        history_meta_cols=['dim_entity_sk', 'entity_id', 'valid_from',
                           'attribute_hash', '_batch_id', '_loaded_at']
) %}

    {%- if not execute -%}
        {%- do return({'source_projection': [], 'names': []}) -%}
    {%- endif -%}

    {%- set history_meta_cols = history_meta_cols | map('lower') | list -%}

    {#- 1. Staging attribute names. Uses the project's star_exclude macro
        when one exists (accepts a comma-separated string, dbt_utils.star-
        style, or a Jinja list of names); otherwise falls back to adapter
        metadata minus the exclude list, so no external macro is required. -#}
    {%- if star_exclude is defined -%}
        {%- set raw = star_exclude(source_relation, source_exclude) -%}
        {%- if raw is string -%}
            {%- set src_attr_names = raw.split(',') | map('trim') | map('lower')
                                     | reject('equalto', '') | list -%}
        {%- else -%}
            {%- set src_attr_names = raw | map('trim') | map('lower') | list -%}
        {%- endif -%}
    {%- else -%}
        {%- set excl = source_exclude | map('lower') | list -%}
        {%- set src_attr_names = [] -%}
        {%- for c in adapter.get_columns_in_relation(source_relation) -%}
            {%- if c.name | lower not in excl -%}
                {%- do src_attr_names.append(c.name | lower) -%}
            {%- endif -%}
        {%- endfor -%}
    {%- endif -%}

    {#- 2. Staging column DDL types from adapter metadata (char_size etc.) -#}
    {%- set src_types = {} -%}
    {%- for c in adapter.get_columns_in_relation(source_relation) -%}
        {%- do src_types.update({c.name | lower: scd2_synapse_ddl_type(c)}) -%}
    {%- endfor -%}

    {#- 3. Existing history table (none on first run) -#}
    {%- set target = adapter.get_relation(
            history_relation.database,
            history_relation.schema,
            history_relation.identifier) -%}

    {%- set hist_types = {} -%}
    {%- set hist_attr_names = [] -%}
    {%- if target is not none -%}
        {%- for c in adapter.get_columns_in_relation(target) -%}
            {%- set n = c.name | lower -%}
            {%- do hist_types.update({n: scd2_synapse_ddl_type(c)}) -%}
            {%- if n not in history_meta_cols -%}
                {%- do hist_attr_names.append(n) -%}
            {%- endif -%}
        {%- endfor -%}
    {%- endif -%}

    {%- set projection = [] -%}
    {%- set names = [] -%}
    {%- set new_cols = [] -%}

    {#- 4. Staging columns, in staging order: shared or new -#}
    {%- for n in src_attr_names -%}
        {%- if n in hist_attr_names -%}
            {%- if not scd2_synapse_types_equivalent(src_types[n], hist_types[n]) -%}
                {{ exceptions.raise_compiler_error(
                    "SCD2 schema drift: type mismatch on column '" ~ n ~
                    "' - staging is " ~ src_types[n] ~ ", history table stores " ~ hist_types[n] ~
                    ". Refusing to insert with an implicit conversion (risk of silent " ~
                    "truncation/corruption of history). Dedicated SQL pool has no ALTER COLUMN: " ~
                    "to widen, CTAS-rebuild the history table with the new type " ~
                    "(CREATE TABLE ..._new WITH (DISTRIBUTION = HASH(entity_id)) AS SELECT ... ; " ~
                    "RENAME OBJECT swap), then re-run. All rows are preserved by the rebuild."
                ) }}
            {%- endif -%}
            {%- do projection.append(n) -%}
            {%- do names.append(n) -%}
        {%- else -%}
            {#- new attribute -#}
            {%- do projection.append(n) -%}
            {%- do names.append(n) -%}
            {%- if target is not none -%}
                {%- do new_cols.append(n) -%}
            {%- endif -%}
        {%- endif -%}
    {%- endfor -%}

    {#- 5. Departed columns: keep them, project NULL of the stored type -#}
    {%- for n in hist_attr_names -%}
        {%- if n not in src_attr_names -%}
            {#- add [bracket] quoting here if your identifiers need it -#}
            {%- do projection.append('cast(null as ' ~ hist_types[n] ~ ') as ' ~ n) -%}
            {%- do names.append(n) -%}
            {%- do log('SCD2 drift: column ' ~ n ~ ' no longer in ' ~ source_relation.identifier ~
                       ' - retained in history, new versions carry NULL', info=True) -%}
        {%- endif -%}
    {%- endfor -%}

    {#- 6. Additive DDL for new columns, before the materialization inserts.
        Real runs only - never during compile / docs generate. -#}
    {%- if new_cols | length > 0 and flags.WHICH in ('run', 'build') -%}
        {%- for n in new_cols -%}
            {%- do run_query('alter table ' ~ target ~ ' add ' ~ n ~ ' ' ~ src_types[n] ~ ' null') -%}
            {%- do log('SCD2 drift: added new attribute column ' ~ n ~ ' (' ~ src_types[n] ~
                       ') to ' ~ target ~ ' - pre-existing history rows are NULL', info=True) -%}
        {%- endfor -%}
    {%- endif -%}

    {%- do return({'source_projection': projection, 'names': names}) -%}

{% endmacro %}
