/*
    scd2_dimension
    --------------
    Macro-driven SCD2 generation. Each dimension is declared ONCE in
    vars.scd2_dimensions (dbt_project.yml); every model / test file is a
    one-line shim, so adding dimension number 300 is one vars entry plus
    `dbt run-operation scd2_generate_shims` to stamp the files.

        vars:
          scd2_dimensions:
            - name: dim_customer          # marker; also the consumption table name
              source: stg_customer        # staging model ref'd by the history model
              natural_key: customer_id    # string, or list for composite keys
              # everything below is optional (defaults shown):
              # change_date_column: _landing_extract_date   # becomes valid_from (DATE)
              # hash_column:        attribute_hash          # trusted change-detection hash
              # surrogate_key:      dim_customer_sk         # <name>_sk
              # dist_column:        customer_id             # first natural key column
              # natural_key_cast:   nvarchar(400)           # cast for the surrogate-key concat
              # dedupe_order_by:    attribute_hash          # tie-break inside one extract date
              # volume_guard_factor: 0.5                    # gate: latest extract vs trailing avg
              # volume_guard_window: 7                      # trailing extract count
              # presentation_exclude: [_batch_id, _loaded_at, attribute_hash]
              #   columns omitted from dim_<name>__published and the consumption table

    Shim files (written by scd2_generate_shims into the generated/ dirs):

        models/scd2/generated/dim_customer__history.sql    {{ scd2_history('dim_customer') }}
        models/scd2/generated/dim_customer__candidate.sql  {{ scd2_candidate('dim_customer') }}
        models/scd2/generated/dim_customer__published.sql  {{ scd2_published('dim_customer') }}
        tests/generated/dim_customer__gates.sql            {{ scd2_gate_test('dim_customer') }}

    All architectural behaviour (insert-only history, batch approval,
    purge pre-hook, drift-safe attributes, CTAS+RENAME consumption table,
    rollback) is unchanged from the hand-written dim_entity implementation:
    these macros emit the same SQL, parameterized. config() and ref() are
    called inside the macros - dbt's static parser can't shortcut such
    files, so it falls back to full Jinja rendering at parse time and picks
    both up correctly (slightly slower parses; no functional difference).

    Composite natural keys: every window partition, join and the surrogate
    key concat use all key columns; DISTRIBUTION defaults to HASH(<first
    key column>) - override with dist_column if another column distributes
    better.
*/


{#- Look up one dimension in vars.scd2_dimensions, validate, apply defaults.
    Returns a dict used by every generator macro below. -#}
{% macro scd2_dimension_config(marker) %}
    {%- set dims = var('scd2_dimensions', []) -%}
    {%- set hit = namespace(d=none) -%}
    {%- for d in dims -%}
        {%- if d.get('name') == marker -%}{%- set hit.d = d -%}{%- endif -%}
    {%- endfor -%}
    {%- if hit.d is none -%}
        {{ exceptions.raise_compiler_error(
            "scd2: no dimension named '" ~ marker ~ "' in vars.scd2_dimensions. " ~
            "Add an entry to dbt_project.yml, minimum: " ~
            "{name: " ~ marker ~ ", source: <staging model>, natural_key: <column or list>}") }}
    {%- endif -%}
    {%- set d = hit.d -%}
    {%- if not d.get('source') or not d.get('natural_key') -%}
        {{ exceptions.raise_compiler_error(
            "scd2: dimension '" ~ marker ~ "' must define both 'source' and 'natural_key' " ~
            "in vars.scd2_dimensions.") }}
    {%- endif -%}
    {%- set nk = d.get('natural_key') -%}
    {%- set key_cols = [nk] if nk is string else nk | list -%}
    {%- set pres_excl = d.get('presentation_exclude', []) -%}
    {%- set pres_excl = [pres_excl] if pres_excl is string else pres_excl | list -%}
    {%- set pres_excl = pres_excl | map('lower') | list -%}
    {%- set dist_col = d.get('dist_column', key_cols[0]) -%}
    {%- set protected = (key_cols | map('lower') | list) + ['valid_from'] -%}
    {%- for col in pres_excl -%}
        {%- if col in protected -%}
            {{ exceptions.raise_compiler_error(
                "scd2: dimension '" ~ marker ~ "' cannot exclude '" ~ col ~
                "' via presentation_exclude (natural keys and valid_from are required " ~
                "in the published view).") }}
        {%- endif -%}
        {%- if col == dist_col | lower -%}
            {{ exceptions.raise_compiler_error(
                "scd2: dimension '" ~ marker ~ "' cannot exclude dist_column '" ~ dist_col ~
                "' via presentation_exclude - the consumption-table CTAS requires " ~
                "DISTRIBUTION = HASH(" ~ dist_col ~ ").") }}
        {%- endif -%}
    {%- endfor -%}
    {%- do return({
        'marker':          marker,
        'source':          d.get('source'),
        'key_cols':        key_cols,
        'change_col':      d.get('change_date_column', '_landing_extract_date'),
        'hash_col':        d.get('hash_column', 'attribute_hash'),
        'sk':              d.get('surrogate_key', marker ~ '_sk'),
        'dist_col':        dist_col,
        'key_cast':        d.get('natural_key_cast', 'nvarchar(400)'),
        'dedupe_order':    d.get('dedupe_order_by', d.get('hash_column', 'attribute_hash')),
        'volume_factor':   d.get('volume_guard_factor', 0.5),
        'volume_window':   d.get('volume_guard_window', 7),
        'presentation_exclude': pres_excl,
        'history_model':   marker ~ '__history',
        'candidate_model': marker ~ '__candidate',
        'published_model': marker ~ '__published'
    }) -%}
{% endmacro %}


{#- History, candidate, and gate models must use the default dbt object name
    (no alias). Approval and purge key off model_name / relation.identifier. -#}
{% macro scd2_assert_alias_forbidden() %}
    {%- set configured = config.get('alias') -%}
    {%- if configured is not none and configured | trim != '' and configured != model.name -%}
        {{ exceptions.raise_compiler_error(
            "scd2: '" ~ model.name ~ "' must not set a dbt alias (found alias='" ~ configured ~
            "'). Approval, purge, and audit tables key off the model name. Remove alias " ~
            "from dbt_project.yml for this model.") }}
    {%- endif -%}
{% endmacro %}


{#- The published (consumption) view must alias to the dimension marker
    (dim_<name>), matching the consumption table refreshed by CTAS. -#}
{% macro scd2_assert_published_alias(marker) %}
    {%- set configured = config.get('alias') -%}
    {%- if configured != marker -%}
        {{ exceptions.raise_compiler_error(
            "scd2: published model '" ~ model.name ~ "' must have alias='" ~ marker ~
            "' (the consumption name). Found alias='" ~ configured ~
            "'. Remove conflicting alias config from dbt_project.yml.") }}
    {%- endif -%}
{% endmacro %}


{#- "a.k1, a.k2" (or "k1, k2" with no alias) -#}
{% macro scd2__key_list(cfg, alias='') %}
    {%- set p = alias ~ '.' if alias else '' -%}
    {%- set out = [] -%}
    {%- for k in cfg.key_cols -%}{%- do out.append(p ~ k) -%}{%- endfor -%}
    {%- do return(out | join(', ')) -%}
{% endmacro %}


{#- "l.k1 = r.k1 and l.k2 = r.k2" -#}
{% macro scd2__key_join(cfg, left, right) %}
    {%- set out = [] -%}
    {%- for k in cfg.key_cols -%}
        {%- do out.append(left ~ '.' ~ k ~ ' = ' ~ right ~ '.' ~ k) -%}
    {%- endfor -%}
    {%- do return(out | join('\n        and ')) -%}
{% endmacro %}


{#- Deterministic MD5 surrogate key over (natural key columns, change date).
    A unique test on this column IS the grain test. -#}
{% macro scd2__surrogate_key_expr(cfg) %}
    {%- set parts = [] -%}
    {%- for k in cfg.key_cols -%}
        {%- do parts.append('cast(' ~ k ~ ' as ' ~ cfg.key_cast ~ ')') -%}
        {%- do parts.append("N'||'") -%}
    {%- endfor -%}
    {%- do parts.append('convert(nvarchar(10), ' ~ cfg.change_col ~ ', 23)') -%}
    {%- do return("convert(char(32), hashbytes('md5', concat(" ~ (parts | join(', ')) ~ ")), 2)") -%}
{% endmacro %}


{#- Human-readable key rendering for gate-test failure rows -#}
{% macro scd2__key_display(cfg, alias='') %}
    {%- set p = alias ~ '.' if alias else '' -%}
    {%- if cfg.key_cols | length == 1 -%}
        {%- do return('cast(' ~ p ~ cfg.key_cols[0] ~ ' as nvarchar(400))') -%}
    {%- else -%}
        {%- set parts = [] -%}
        {%- for k in cfg.key_cols -%}
            {%- do parts.append('cast(' ~ p ~ k ~ ' as nvarchar(400))') -%}
            {%- if not loop.last -%}{%- do parts.append("'|'") -%}{%- endif -%}
        {%- endfor -%}
        {%- do return('concat(' ~ (parts | join(', ')) ~ ')') -%}
    {%- endif -%}
{% endmacro %}


{#- History columns to project in the published view / consumption table,
    minus presentation_exclude. Falls back to alias.* during parse. -#}
{% macro scd2__presentation_columns(cfg, alias='a') %}
    {%- set p = alias ~ '.' -%}
    {%- if not execute or not cfg.presentation_exclude -%}
        {%- do return([p ~ '*']) -%}
    {%- endif -%}
    {%- set exclude = cfg.presentation_exclude -%}
    {%- set out = [] -%}
    {%- for c in adapter.get_columns_in_relation(ref(cfg.history_model)) -%}
        {%- if c.name | lower not in exclude -%}
            {%- do out.append(p ~ adapter.quote(c.name)) -%}
        {%- endif -%}
    {%- endfor -%}
    {#- no metadata yet (history not built, e.g. compile on a fresh target):
        emit * so the rendered SQL stays valid; dbt recreates views every
        run, so the real run re-resolves the explicit list -#}
    {%- if out | length == 0 -%}
        {%- do return([p ~ '*']) -%}
    {%- endif -%}
    {%- do return(out) -%}
{% endmacro %}


{#
    Insert-only SCD2 base table (see the original dim_entity__history header
    for the full design rationale - the SQL here is that model, parameterized).
    Never updated or merged into; valid_to / is_current derive downstream.
#}
{% macro scd2_history(marker) %}
{%- set cfg = scd2_dimension_config(marker) -%}
{{ scd2_assert_alias_forbidden() }}
{{ config(
    materialized='incremental',
    incremental_strategy='append',
    on_schema_change='ignore',
    dist='HASH(' ~ cfg.dist_col ~ ')',
    index='CLUSTERED COLUMNSTORE INDEX',
    pre_hook="{{ scd2_purge_unapproved(this) }}",
    tags=['scd2_history'],
    meta={'scd2_model': marker}
) }}

{#- Drift-safe attribute resolution: union of staging and history columns.
    Runs any additive ALTERs as a side effect (real runs only). -#}
{%- set attrs = scd2_resolve_attributes(
        source_relation   = ref(cfg.source),
        history_relation  = this,
        source_exclude    = cfg.key_cols + [cfg.change_col, cfg.hash_col],
        history_meta_cols = [cfg.sk] + cfg.key_cols + ['valid_from', cfg.hash_col, '_batch_id', '_loaded_at']
) -%}

with source as (

    select
        {{ scd2__key_list(cfg) }},
        {{ cfg.change_col }},
        {{ cfg.hash_col }}{% if attrs.source_projection %},
        {{ attrs.source_projection | join(',\n        ') }}{% endif %}
    from {{ ref(cfg.source) }}

    {% if is_incremental() %}
    -- Only extracts newer than the approved high-water mark. COALESCE guards
    -- the empty-table case. Uses > : a re-supplied extract for an already-
    -- loaded date is ignored (switch to >= + extend dedupe_order_by if your
    -- source revises within an extract date).
    where {{ cfg.change_col }} > (
        select coalesce(max(valid_from), convert(date, '1900-01-01', 23))
        from {{ this }}
    )
    {% endif %}

),

-- Exactly one candidate row per natural key per extract date
deduped as (

    select *
    from (
        select
            s.*,
            row_number() over (
                partition by {{ scd2__key_list(cfg, 's') }}, s.{{ cfg.change_col }}
                order by {{ cfg.dedupe_order }}
            ) as _rn
        from source s
    ) x
    where _rn = 1

),

{% if is_incremental() %}
-- Latest APPROVED version of each entity already in the table
-- (pre-hook guarantees only approved rows remain at this point)
latest_existing as (

    select {{ scd2__key_list(cfg) }}, {{ cfg.hash_col }}
    from (
        select
            {{ scd2__key_list(cfg) }},
            {{ cfg.hash_col }},
            row_number() over (
                partition by {{ scd2__key_list(cfg) }}
                order by valid_from desc
            ) as _rn
        from {{ this }}
    ) t
    where _rn = 1

),
{% endif %}

-- Sequence incoming rows per entity and stitch them onto existing history,
-- so a batch containing multiple extract dates per entity chains correctly
sequenced as (

    select
        d.*,
        {# single-arg COALESCE is invalid T-SQL, so only wrap when the
           incremental branch supplies the second argument #}
        {%- if is_incremental() %}
        coalesce(
            lag(d.{{ cfg.hash_col }}) over (
                partition by {{ scd2__key_list(cfg, 'd') }}
                order by d.{{ cfg.change_col }}
            ),
            e.{{ cfg.hash_col }}
        ) as _prev_hash
        {%- else -%}
        lag(d.{{ cfg.hash_col }}) over (
            partition by {{ scd2__key_list(cfg, 'd') }}
            order by d.{{ cfg.change_col }}
        ) as _prev_hash
        {%- endif %}
    from deduped d
    {% if is_incremental() %}
    left join latest_existing e
        on {{ scd2__key_join(cfg, 'e', 'd') }}
    {% endif %}

)

select
    {{ scd2__surrogate_key_expr(cfg) }} as {{ cfg.sk }},

    {{ scd2__key_list(cfg) }},
    {{ cfg.change_col }} as valid_from,
    {{ cfg.hash_col }}{% if attrs.names %},
    {{ attrs.names | join(',\n    ') }}{% endif %},

    cast('{{ invocation_id }}' as varchar(64)) as _batch_id,
    convert(datetime2(0), '{{ run_started_at.strftime("%Y-%m-%dT%H:%M:%S") }}', 126) as _loaded_at

from sequenced
where _prev_hash is null                     -- new entity
   or _prev_hash <> {{ cfg.hash_col }}       -- genuine change
{% endmacro %}


{#
    SCD2 shape (valid_to / is_current via LEAD) over ALL history rows -
    approved plus pending. TEST TARGET; consumers never read it. h.* means
    drift flows through automatically: dbt recreates views every run, so
    the * re-expands and never goes stale. valid_to is exclusive; open rows
    carry 9999-12-31.
#}
{% macro scd2_candidate(marker) %}
{%- set cfg = scd2_dimension_config(marker) -%}
{{ scd2_assert_alias_forbidden() }}
{{ config(
    materialized='view',
    tags=['scd2_candidate'],
    meta={'scd2_model': marker}
) }}
{%- set part = scd2__key_list(cfg, 'h') %}

select
    h.*,
    coalesce(
        lead(h.valid_from) over (partition by {{ part }} order by h.valid_from),
        convert(date, '9999-12-31', 23)
    ) as valid_to,
    case
        when lead(h.valid_from) over (partition by {{ part }} order by h.valid_from) is null
        then 1 else 0
    end as is_current
from {{ ref(cfg.history_model) }} h
{% endmacro %}


{#
    Approval-gated logical view. The EXISTS filter runs BEFORE the window
    functions, so unapproved rows are invisible AND cannot influence
    valid_to / is_current of approved rows. Consumers read the <marker>
    consumption TABLE that scd2_refresh_published() rebuilds from this view.

    presentation_exclude (vars.scd2_dimensions) drops internal columns from
    this view only; history and candidate retain the full column set for
    gates and audit.
#}
{% macro scd2_published(marker) %}
{%- set cfg = scd2_dimension_config(marker) -%}
{%- set yaml_alias = config.get('alias') -%}
{%- if yaml_alias is not none and yaml_alias | trim != '' and yaml_alias != marker -%}
    {{ exceptions.raise_compiler_error(
        "scd2: published model '" ~ model.name ~ "' cannot use alias='" ~ yaml_alias ~
        "'. It must alias to the consumption name '" ~ marker ~ "'.") }}
{%- endif -%}
{{ config(
    materialized='view',
    alias=marker,
    pre_hook="{{ scd2_prepare_published_view(this) }}",
    tags=['scd2_published'],
    meta={'scd2_model': marker}
) }}
{{ scd2_assert_published_alias(marker) }}
{%- set part = scd2__key_list(cfg, 'a') %}

with approved as (

    select h.*
    from {{ ref(cfg.history_model) }} h
    where exists (
        select 1
        from audit.scd2_approved_batches ab
        where ab.model_name = '{{ cfg.history_model }}'
          and ab.batch_id   = h._batch_id
    )

)

select
    {{ scd2__presentation_columns(cfg, 'a') | join(',\n    ') }},
    coalesce(
        lead(a.valid_from) over (partition by {{ part }} order by a.valid_from),
        convert(date, '9999-12-31', 23)
    ) as valid_to,
    case
        when lead(a.valid_from) over (partition by {{ part }} order by a.valid_from) is null
        then 1 else 0
    end as is_current
from approved a
{% endmacro %}


{#
    Single gating test per dimension, replacing the per-model yml tests AND
    the hand-written reconciliation test. Every check targets the candidate
    view (approved + pending world), so a failure blocks approval of the
    pending batch via the on-run-end gate: the test ref's the candidate
    model, which carries meta.scd2_model, which is what scd2_approve_batches
    matches on.

    Checks:
      1. duplicate surrogate key            (grain violation)
      2. NULL surrogate key / natural key / valid_from
      3. more than one current row per natural key
      4. reconciliation: every entity in the latest extract has a current
         row with the same attribute hash (one-directional by design - see
         the hard-delete note in the README)
      5. volume guard: latest extract vs trailing average
#}
{% macro scd2_gate_test(marker) %}
{%- set cfg = scd2_dimension_config(marker) -%}
{{ scd2_assert_alias_forbidden() }}
{{ config(
    severity='error',
    store_failures=true,
    schema='audit',
    tags=['scd2_gate'],
    meta={'scd2_model': marker}
) }}

with candidate as (

    select * from {{ ref(cfg.candidate_model) }}

),

latest_extract as (

    select {{ scd2__key_list(cfg) }}, {{ cfg.hash_col }}
    from {{ ref(cfg.source) }}
    where {{ cfg.change_col }} = (
        select max({{ cfg.change_col }}) from {{ ref(cfg.source) }}
    )

),

current_dim as (

    select {{ scd2__key_list(cfg) }}, {{ cfg.hash_col }}
    from candidate
    where is_current = 1

),

grain_violations as (

    select
        'duplicate surrogate key (grain violation)' as failure_reason,
        cast({{ cfg.sk }} as nvarchar(400)) as offending_key
    from candidate
    group by {{ cfg.sk }}
    having count(*) > 1

),

null_violations as (

    select
        'null surrogate key, natural key or valid_from' as failure_reason,
        {{ scd2__key_display(cfg) }} as offending_key
    from candidate
    where {{ cfg.sk }} is null
       or valid_from is null
       {% for k in cfg.key_cols %}or {{ k }} is null
       {% endfor %}
),

multi_current as (

    select
        'more than one current row for natural key' as failure_reason,
        {{ scd2__key_display(cfg) }} as offending_key
    from candidate
    where is_current = 1
    group by {{ scd2__key_list(cfg) }}
    having count(*) > 1

),

reconciliation as (

    select
        'missing or stale in dim vs latest extract' as failure_reason,
        {{ scd2__key_display(cfg, 'l') }} as offending_key
    from latest_extract l
    left join current_dim c
        on  {{ scd2__key_join(cfg, 'c', 'l') }}
        and c.{{ cfg.hash_col }} = l.{{ cfg.hash_col }}
    where c.{{ cfg.key_cols[0] }} is null

),

volume_guard as (

    -- latest extract must be at least volume_guard_factor of the trailing
    -- volume_guard_window-extract average; catches truncated files before
    -- they pollute history
    select
        'volume anomaly: latest extract below trailing average threshold' as failure_reason,
        cast(null as nvarchar(400)) as offending_key
    where (
        select count(*) from latest_extract
    ) < {{ cfg.volume_factor }} * coalesce((
        select avg(cast(cnt as float))
        from (
            select top {{ cfg.volume_window }} count(*) as cnt
            from {{ ref(cfg.source) }}
            group by {{ cfg.change_col }}
            order by {{ cfg.change_col }} desc
        ) recent
    ), 0)

)

select failure_reason, offending_key from grain_violations
union all
select failure_reason, offending_key from null_violations
union all
select failure_reason, offending_key from multi_current
union all
select failure_reason, offending_key from reconciliation
union all
select failure_reason, offending_key from volume_guard
{% endmacro %}
