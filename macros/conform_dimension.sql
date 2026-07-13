/*
    conform_dimension
    -----------------
    Dimension-agnostic conformance engine. Resolves any source's reference to
    a canonical dimension table's PRIMARY KEY (an ISO code for countries, a
    UN/LOCODE for ports, ...), then attaches the canonical name by joining
    that key back to the canonical table. See CONFORMANCE_GUIDE.md for the
    full replication recipe.

    Resolution order per source row (first hit wins):

      1. OVERRIDE   - a row in the entity's override seed for this
                      (source_system, match_key, source_value). Manual escape
                      hatch: hand-edit the seed, `dbt seed`, rebuild. Overrides
                      map to a canonical CODE, so a name variant resolves to the
                      canonical name automatically via the final join.
      2. AUTO MATCH - code sources: normalized equality on the canonical code.
                      name sources: normalized, accent/case-insensitive equality
                      on the canonical name.
      3. UNMATCHED  - no override, no auto match: canonical code is NULL and
                      <entity>_match_status = 'unmatched'. Surface these with
                      conform_unmatched_report() and add an override for each.

    `entity` drives the output column names and the default override seed, so a
    new dimension needs no macro edits - just config:

      - canonical_<entity>_code   (the resolved PK, NULL when unmatched)
      - canonical_<entity>_name   (from the canonical table, NULL when unmatched)
      - <entity>_match_status     ('override' | 'exact_code' | 'exact_name' | 'unmatched')

    Usage (as a model body):

        {{ config(materialized='view', tags=['staging', 'port_conform']) }}
        {{ conform_dimension(
            entity                = 'port',
            source_relation       = source('mft', 'manifests'),
            source_system         = 'MFT',
            match_key             = 'name',
            source_column         = 'port_name',
            canonical_relation    = source('reference', 'port'),
            canonical_code_column = 'locode',
            canonical_name_column = 'port_name'
        ) }}

    Params:
      - overrides_relation   : defaults to ref(entity ~ '_conformance_overrides').
      - override_code_column : the seed column holding the target canonical code.
                               Standardized as 'canonical_code'; country's seed
                               uses 'canonical_country_code', so country_conform
                               passes that through.
      - name_collation       : accent/case-insensitive collation for name
                               matching (default Latin1_General_CI_AI).

    Notes / gotchas (see CONFORMANCE_GUIDE.md §7):
      - Canonical name AND the override grain must be unique on their join key,
        or source rows multiply.
      - Single-column name matching cannot disambiguate ("Portland"): add an
        override, or extend the join to a composite key.
      - Output columns include the source's own columns via m.* - a source
        column already named canonical_<entity>_code / _name / _match_status
        would collide; rename upstream if so.
*/


{#- Normalization applied to CODE comparisons (both sides of the join).
    upper + trim suffices for codes; names use collation instead. -#}
{% macro conform__normalize(expr) %}
    {%- do return('upper(ltrim(rtrim(' ~ expr ~ ')))') -%}
{% endmacro %}


{% macro conform_dimension(
    entity,
    source_relation,
    source_system,
    match_key,
    source_column,
    canonical_relation,
    canonical_code_column,
    canonical_name_column,
    overrides_relation=none,
    override_code_column='canonical_code',
    name_collation='Latin1_General_CI_AI'
) %}

{%- if match_key not in ['code', 'name'] -%}
    {{ exceptions.raise_compiler_error(
        "conform_dimension: match_key must be 'code' or 'name', got '" ~ match_key ~ "'.") }}
{%- endif -%}
{%- set overrides_relation = overrides_relation or ref(entity ~ '_conformance_overrides') -%}
{%- set code_out    = 'canonical_' ~ entity ~ '_code' -%}
{%- set name_out    = 'canonical_' ~ entity ~ '_name' -%}
{%- set status_out  = entity ~ '_match_status' -%}
{%- set status_hit  = 'exact_code' if match_key == 'code' else 'exact_name' -%}

with src as (

    select * from {{ source_relation }}

),

overrides as (

    select
        source_value,
        {{ override_code_column }} as canonical_code
    from {{ overrides_relation }}
    where source_system = '{{ source_system }}'
      and match_key     = '{{ match_key }}'

),

matched as (

    select
        s.*,
        coalesce(
            o.canonical_code,
            {% if match_key == 'code' %}cc.{{ canonical_code_column }}{% else %}cn.{{ canonical_code_column }}{% endif %}
        ) as {{ code_out }},
        case
            when o.canonical_code is not null then 'override'
            when {% if match_key == 'code' %}cc.{{ canonical_code_column }}{% else %}cn.{{ canonical_code_column }}{% endif %} is not null
                then '{{ status_hit }}'
            else 'unmatched'
        end as {{ status_out }}
    from src s

    -- 1. manual overrides (source_system + match_key already filtered above)
    left join overrides o
        on {% if match_key == 'code' -%}
           {{ conform__normalize('s.' ~ source_column) }} = {{ conform__normalize('o.source_value') }}
           {%- else -%}
           ltrim(rtrim(s.{{ source_column }})) collate {{ name_collation }}
             = ltrim(rtrim(o.source_value)) collate {{ name_collation }}
           {%- endif %}

    -- 2. automatic match against the canonical table
    {% if match_key == 'code' -%}
    left join {{ canonical_relation }} cc
        on {{ conform__normalize('s.' ~ source_column) }} = {{ conform__normalize('cc.' ~ canonical_code_column) }}
    {%- else -%}
    left join {{ canonical_relation }} cn
        on ltrim(rtrim(s.{{ source_column }})) collate {{ name_collation }}
         = ltrim(rtrim(cn.{{ canonical_name_column }})) collate {{ name_collation }}
    {%- endif %}

)

select
    m.*,
    canon.{{ canonical_name_column }} as {{ name_out }}
from matched m
left join {{ canonical_relation }} canon
    on m.{{ code_out }} = canon.{{ canonical_code_column }}
{% endmacro %}


/*
    conform_unmatched_report
    ------------------------
    Roll up the source values conform_dimension() could NOT resolve, so you
    know which override rows to add. Point it at your conformed models (the
    ones carrying <entity>_match_status).

    Usage (as a model body):

        {{ config(materialized='view', schema='audit', tags=['port_conform', 'audit']) }}
        {{ conform_unmatched_report('port', [
            {'relation': ref('vms_ports__conformed'), 'source_system': 'VMS',
             'match_key': 'code', 'source_column': 'locode'},
            {'relation': ref('mft_ports__conformed'), 'source_system': 'MFT',
             'match_key': 'name', 'source_column': 'port_name'}
        ]) }}
*/
{% macro conform_unmatched_report(entity, conformed) %}
{%- for c in conformed %}
select
    '{{ c.source_system }}' as source_system,
    '{{ c.match_key }}'     as match_key,
    cast({{ c.source_column }} as nvarchar(200)) as unmatched_value,
    count_big(*) as row_count
from {{ c.relation }}
where {{ entity }}_match_status = 'unmatched'
group by {{ c.source_column }}
{% if not loop.last %}union all{% endif %}
{%- endfor %}
{% endmacro %}
