/*
    Zero-copy batch approval machinery for periodic snapshot facts, sibling
    to scd2_zero_copy.sql. Kept on its OWN audit table
    (audit.fact_approved_batches) rather than reusing
    audit.scd2_approved_batches, so fact and dimension approval/rollback
    history stay independently auditable even though model_name values
    could otherwise collide across the two subsystems.

    Wire-up in dbt_project.yml:

        on-run-start:
          - "{{ fact_snapshot_bootstrap_audit() }}"
        on-run-end:
          - "{{ fact_snapshot_approve_batches(results) }}"

    The purge macro is attached per-model as a pre_hook (see
    fact_snapshot_history in fact_snapshot.sql).
*/


{% macro fact_snapshot_bootstrap_audit() %}
    {% if execute %}
        {% set sql %}
            IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'audit')
                EXEC('CREATE SCHEMA audit');

            IF OBJECT_ID('audit.fact_approved_batches') IS NULL
                CREATE TABLE audit.fact_approved_batches
                (
                    model_name  varchar(200) NOT NULL,
                    batch_id    varchar(64)  NOT NULL,
                    approved_at datetime2(0) NOT NULL
                )
                WITH (DISTRIBUTION = ROUND_ROBIN, HEAP);
        {% endset %}
        {% do run_query(sql) %}
    {% endif %}
{% endmacro %}


{#
    Pre-hook for fact history models. Deletes rows from any batch that was
    never approved - debris from a failed prior run - so the incremental
    logic and the published view both operate on a clean, approved-only
    baseline. Happy path: no-op. Same NOT EXISTS / correlated-DELETE
    reasoning as scd2_purge_unapproved.
#}
{% macro fact_snapshot_purge_unapproved(relation) %}
    IF OBJECT_ID('{{ relation.schema }}.{{ relation.identifier }}') IS NOT NULL
        DELETE FROM {{ relation }}
        WHERE NOT EXISTS (
            SELECT 1
            FROM audit.fact_approved_batches
            WHERE model_name = '{{ relation.identifier }}'
              AND batch_id   = _batch_id
        );
{% endmacro %}


{#- Gate-test status for a marker in this invocation's results, or none if
    the test did not run. -#}
{% macro fact_snapshot_gate_test_status(results, marker) %}
    {%- for r in results -%}
        {%- if r.node.resource_type == 'test' and 'fact_snapshot_gate' in r.node.tags -%}
            {%- set m = r.node.config.get('meta', {}).get('fact_snapshot_model')
                      or r.node.get('meta', {}).get('fact_snapshot_model') -%}
            {%- if m == marker -%}
                {%- do return(r.status | lower) -%}
            {%- endif -%}
        {%- endif -%}
    {%- endfor -%}
    {%- do return(none) -%}
{% endmacro %}


{% macro fact_snapshot_unapprove_batch(model_name, batch_id) %}
    {%- if execute -%}
        {%- do run_query(
            "delete from audit.fact_approved_batches " ~
            "where model_name = '" ~ model_name ~ "' and batch_id = '" ~ batch_id ~ "'") -%}
    {%- endif -%}
{% endmacro %}


{#
    on-run-end approval gate. For every model tagged 'fact_snapshot_history'
    that built successfully this invocation, approve its batch UNLESS:
      - the fact's gate test did not execute in this invocation
      - the gate test failed/errored (error severity)
      - fact_snapshot_refresh_published verification fails after approval
        (approval row is rolled back and the run fails)

    Use `dbt build` (not `dbt run`) so gate tests always execute alongside
    history models. Reuses scd2_fail_run - that helper is already generic
    (just logs + raises), nothing SCD2-specific about it.
#}
{% macro fact_snapshot_approve_batches(results) %}
    {% if execute %}

        {# 1. Which fact_snapshot_model markers are blocked by a failed gating test? #}
        {% set blocked_markers = [] %}
        {% for r in results %}
            {% if r.node.resource_type == 'test'
                  and r.status | lower in ('fail', 'error')
                  and (r.node.config.severity | default('error') | lower) == 'error' %}
                {% for dep_uid in r.node.depends_on.nodes %}
                    {% set dep = graph.nodes.get(dep_uid) %}
                    {% if dep %}
                        {% set marker = dep.config.get('meta', {}).get('fact_snapshot_model')
                                        or dep.get('meta', {}).get('fact_snapshot_model') %}
                        {% if marker and marker not in blocked_markers %}
                            {% do blocked_markers.append(marker) %}
                        {% endif %}
                    {% endif %}
                {% endfor %}
            {% endif %}
        {% endfor %}

        {# 2. Approve batches for successful, gated history models #}
        {% for r in results %}
            {% if r.node.resource_type == 'model'
                  and 'fact_snapshot_history' in r.node.tags
                  and r.status | lower == 'success' %}

                {% set marker = r.node.config.get('meta', {}).get('fact_snapshot_model')
                                or r.node.get('meta', {}).get('fact_snapshot_model') %}
                {% set gate_status = fact_snapshot_gate_test_status(results, marker) if marker else none %}

                {% if marker and gate_status is none %}
                    {% do log('fact_snapshot gate: batch for ' ~ r.node.name ~
                              ' NOT approved - gate test did not run this invocation. ' ~
                              'Use dbt build (not dbt run) and include tests/generated/*__gates.sql',
                              info=true) %}
                {% elif marker and gate_status == 'skipped' %}
                    {% do log('fact_snapshot gate: batch for ' ~ r.node.name ~
                              ' NOT approved - gate test was skipped', info=true) %}
                {% elif marker and gate_status not in ('pass', 'success') %}
                    {% do log('fact_snapshot gate: batch for ' ~ r.node.name ~
                              ' NOT approved - gate test status=' ~ gate_status, info=true) %}
                {% elif marker and marker in blocked_markers %}
                    {% do log('fact_snapshot gate: batch for ' ~ r.node.name ~ ' NOT approved (failed tests) - published view unchanged, rows will be purged on next run', info=True) %}
                {% else %}
                    {% set sql %}
                        INSERT INTO audit.fact_approved_batches (model_name, batch_id, approved_at)
                        SELECT '{{ r.node.name }}', '{{ invocation_id }}', SYSUTCDATETIME();
                    {% endset %}
                    {% do run_query(sql) %}
                    {% do log('fact_snapshot gate: batch approved for ' ~ r.node.name, info=True) %}
                    {#- approved set changed -> rebuild + swap the consumption table -#}
                    {% if marker %}
                        {% set refresh = fact_snapshot_refresh_published(marker) %}
                        {% if refresh is mapping and refresh.get('ok') %}
                            {% do log('fact_snapshot gate: consumption table for ' ~ marker ~
                                      ' refreshed (' ~ refresh.get('row_count', '?') ~ ' rows)', info=true) %}
                        {% else %}
                            {% set err = refresh.get('error', 'unknown refresh failure') if refresh is mapping else 'unknown refresh failure' %}
                            {% do fact_snapshot_unapprove_batch(r.node.name, invocation_id) %}
                            {{ scd2_fail_run(
                                'fact_snapshot gate: consumption table refresh failed for ' ~ marker ~
                                ' after approving batch ' ~ invocation_id ~
                                '. Approval rolled back. ' ~ err) }}
                        {% endif %}
                    {% endif %}
                {% endif %}

            {% endif %}
        {% endfor %}

    {% endif %}
{% endmacro %}
