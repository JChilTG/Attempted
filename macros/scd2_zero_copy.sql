/*
    Zero-copy SCD2 batch approval machinery.

    Wire-up in dbt_project.yml:

        on-run-start:
          - "{{ scd2_bootstrap_audit() }}"
        on-run-end:
          - "{{ scd2_approve_batches(results) }}"

    The purge macro is attached per-model as a pre_hook.
*/


{% macro scd2_bootstrap_audit() %}
    {% if execute %}
        {% set sql %}
            IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'audit')
                EXEC('CREATE SCHEMA audit');

            IF OBJECT_ID('audit.scd2_approved_batches') IS NULL
                CREATE TABLE audit.scd2_approved_batches
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
    Pre-hook for history models. Deletes rows from any batch that was never
    approved - debris from a failed prior run - so the incremental logic and
    the published view both operate on a clean, approved-only baseline.
    Happy path: no-op.

    Synapse notes:
      - NOT EXISTS rather than NOT IN: NOT IN returns zero rows if the
        subquery ever contains a NULL, which would silently disable the
        purge (or worse). NOT EXISTS has no such failure mode.
      - Plain single-table DELETE with a correlated subquery - dedicated
        pool does not support DELETE...FROM with joins, so none is used.
      - _batch_id in the subquery correlates to the outer (history) table;
        the audit table's column is batch_id, so there is no name collision.
      - Returned as a SQL string (not run_query) so it executes as a normal
        pre-hook inside the model's run. OBJECT_ID guard covers first run.
#}
{% macro scd2_purge_unapproved(relation) %}
    IF OBJECT_ID('{{ relation.schema }}.{{ relation.identifier }}') IS NOT NULL
        DELETE FROM {{ relation }}
        WHERE NOT EXISTS (
            SELECT 1
            FROM audit.scd2_approved_batches
            WHERE model_name = '{{ relation.identifier }}'
              AND batch_id   = _batch_id
        );
{% endmacro %}


{#
    on-run-end approval gate.

    For every model tagged 'scd2_history' that built successfully this
    invocation, approve its batch UNLESS:
      - the dimension's scd2_gate test did not execute in this invocation
      - the gate test failed/errored (error severity)
      - scd2_refresh_published verification fails after approval (approval
        row is rolled back and the run fails)

    Use `dbt build` (not `dbt run`) so gate tests always execute alongside
    history models.
#}


{#- Gate-test status for a marker in this invocation's results, or none if
    the test did not run. -#}
{% macro scd2_gate_test_status(results, marker) %}
    {%- for r in results -%}
        {%- if r.node.resource_type == 'test' and 'scd2_gate' in r.node.tags -%}
            {%- set m = r.node.config.get('meta', {}).get('scd2_model')
                      or r.node.get('meta', {}).get('scd2_model') -%}
            {%- if m == marker -%}
                {%- do return(r.status | lower) -%}
            {%- endif -%}
        {%- endif -%}
    {%- endfor -%}
    {%- do return(none) -%}
{% endmacro %}


{% macro scd2_unapprove_batch(model_name, batch_id) %}
    {%- if execute -%}
        {%- do run_query(
            "delete from audit.scd2_approved_batches " ~
            "where model_name = '" ~ model_name ~ "' and batch_id = '" ~ batch_id ~ "'") -%}
    {%- endif -%}
{% endmacro %}


{% macro scd2_fail_run(message) %}
    {%- do log(message, info=true) -%}
    {{ exceptions.raise_compiler_error(message) }}
{% endmacro %}


{% macro scd2_approve_batches(results) %}
    {% if execute %}

        {# 1. Which scd2_model markers are blocked by a failed gating test? #}
        {% set blocked_markers = [] %}
        {% for r in results %}
            {% if r.node.resource_type == 'test'
                  and r.status | lower in ('fail', 'error')
                  and (r.node.config.severity | default('error') | lower) == 'error' %}
                {% for dep_uid in r.node.depends_on.nodes %}
                    {% set dep = graph.nodes.get(dep_uid) %}
                    {% if dep %}
                        {% set marker = dep.config.get('meta', {}).get('scd2_model')
                                        or dep.get('meta', {}).get('scd2_model') %}
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
                  and 'scd2_history' in r.node.tags
                  and r.status | lower == 'success' %}

                {% set marker = r.node.config.get('meta', {}).get('scd2_model')
                                or r.node.get('meta', {}).get('scd2_model') %}
                {% set gate_status = scd2_gate_test_status(results, marker) if marker else none %}

                {% if marker and gate_status is none %}
                    {% do log('SCD2 gate: batch for ' ~ r.node.name ~
                              ' NOT approved - gate test did not run this invocation. ' ~
                              'Use dbt build (not dbt run) and include tests/generated/*__gates.sql',
                              info=true) %}
                {% elif marker and gate_status == 'skipped' %}
                    {% do log('SCD2 gate: batch for ' ~ r.node.name ~
                              ' NOT approved - gate test was skipped', info=true) %}
                {% elif marker and gate_status not in ('pass', 'success') %}
                    {% do log('SCD2 gate: batch for ' ~ r.node.name ~
                              ' NOT approved - gate test status=' ~ gate_status, info=true) %}
                {% elif marker and marker in blocked_markers %}
                    {% do log('SCD2 gate: batch for ' ~ r.node.name ~ ' NOT approved (failed tests) - published view unchanged, rows will be purged on next run', info=True) %}
                {% else %}
                    {% set sql %}
                        INSERT INTO audit.scd2_approved_batches (model_name, batch_id, approved_at)
                        SELECT '{{ r.node.name }}', '{{ invocation_id }}', SYSUTCDATETIME();
                    {% endset %}
                    {% do run_query(sql) %}
                    {% do log('SCD2 gate: batch approved for ' ~ r.node.name, info=True) %}
                    {#- approved set changed -> rebuild + swap the consumption table -#}
                    {% if marker %}
                        {% set refresh = scd2_refresh_published(marker) %}
                        {% if refresh is mapping and refresh.get('ok') %}
                            {% do log('SCD2 gate: consumption table for ' ~ marker ~
                                      ' refreshed (' ~ refresh.get('row_count', '?') ~ ' rows)', info=true) %}
                        {% else %}
                            {% set err = refresh.get('error', 'unknown refresh failure') if refresh is mapping else 'unknown refresh failure' %}
                            {% do scd2_unapprove_batch(r.node.name, invocation_id) %}
                            {{ scd2_fail_run(
                                'SCD2 gate: consumption table refresh failed for ' ~ marker ~
                                ' after approving batch ' ~ invocation_id ~
                                '. Approval rolled back. ' ~ err) }}
                        {% endif %}
                    {% endif %}
                {% endif %}

            {% endif %}
        {% endfor %}

    {% endif %}
{% endmacro %}
