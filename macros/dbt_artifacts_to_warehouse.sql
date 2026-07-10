/*
    Capture dbt metadata into Synapse tables for audit and lineage tracking.

    Tables created in [operations] schema:
    - dbt_run_results: Each model/test execution
    - dbt_manifest_nodes: All nodes (models, tests, sources, macros)
    - dbt_manifest_edges: DAG edges (parent -> child dependencies)

    Wire-up in dbt_project.yml:

        on-run-end:
          - "{{ dbt_artifacts_to_warehouse(results) }}"
*/


{% macro dbt_bootstrap_artifacts_schema() %}
    {% if execute %}
        {% set sql %}
            IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'operations')
                EXEC('CREATE SCHEMA operations');

            IF OBJECT_ID('operations.dbt_run_results') IS NULL
                CREATE TABLE operations.dbt_run_results
                (
                    run_id              varchar(64)   NOT NULL,
                    invocation_id       varchar(64)   NOT NULL,
                    node_id             varchar(255)  NOT NULL,
                    node_name           varchar(200)  NOT NULL,
                    resource_type       varchar(50)   NOT NULL,
                    node_status         varchar(50)   NOT NULL,
                    execution_time      float         NULL,
                    thread_id           varchar(50)   NULL,
                    message             varchar(2000) NULL,
                    failed_at           datetime2(0)  NULL,
                    completed_at        datetime2(0)  NOT NULL,
                    PRIMARY KEY (invocation_id, node_id)
                )
                WITH (DISTRIBUTION = ROUND_ROBIN, HEAP);

            IF OBJECT_ID('operations.dbt_manifest_nodes') IS NULL
                CREATE TABLE operations.dbt_manifest_nodes
                (
                    invocation_id       varchar(64)   NOT NULL,
                    node_id             varchar(255)  NOT NULL,
                    node_name           varchar(200)  NOT NULL,
                    resource_type       varchar(50)   NOT NULL,
                    package_name        varchar(100)  NULL,
                    path                varchar(500)  NULL,
                    description         varchar(2000) NULL,
                    depends_on_nodes    varchar(4000) NULL,
                    tags                varchar(2000) NULL,
                    meta                varchar(2000) NULL,
                    PRIMARY KEY (invocation_id, node_id)
                )
                WITH (DISTRIBUTION = ROUND_ROBIN, HEAP);

            IF OBJECT_ID('operations.dbt_manifest_edges') IS NULL
                CREATE TABLE operations.dbt_manifest_edges
                (
                    invocation_id       varchar(64)   NOT NULL,
                    parent_id           varchar(255)  NOT NULL,
                    parent_name         varchar(200)  NOT NULL,
                    parent_type         varchar(50)   NOT NULL,
                    child_id            varchar(255)  NOT NULL,
                    child_name          varchar(200)  NOT NULL,
                    child_type          varchar(50)   NOT NULL,
                    PRIMARY KEY (invocation_id, parent_id, child_id)
                )
                WITH (DISTRIBUTION = ROUND_ROBIN, HEAP);
        {% endset %}
        {% do run_query(sql) %}
    {% endif %}
{% endmacro %}


{% macro dbt_artifacts_to_warehouse(results) %}
    {% if execute %}

        {# 1. Capture run results #}
        {% set run_results_data = [] %}
        {% for r in results %}
            {% set data = {
                'run_id': run_started_at.isoformat() if run_started_at else '',
                'invocation_id': invocation_id,
                'node_id': r.node.unique_id,
                'node_name': r.node.name,
                'resource_type': r.node.resource_type,
                'node_status': r.status | lower,
                'execution_time': r.execution_time if r.execution_time else 0,
                'thread_id': r.thread_id if r.thread_id else '',
                'message': (r.message | string)[:2000] if r.message else '',
                'failed_at': r.timing[0].started_at.isoformat() if r.timing and r.failed_at else None,
                'completed_at': r.completed_at.isoformat() if r.completed_at else ''
            } %}
            {% do run_results_data.append(data) %}
        {% endfor %}

        {# 2. Capture manifest nodes #}
        {% set manifest_nodes_data = [] %}
        {% for node_id, node in graph.nodes.items() %}
            {%- set dep_nodes = node.depends_on.nodes | join(', ') | string -%}
            {%- set node_tags = node.tags | join(', ') | string -%}
            {%- set node_meta = node.meta | tojson -%}
            {% set data = {
                'invocation_id': invocation_id,
                'node_id': node_id,
                'node_name': node.name,
                'resource_type': node.resource_type,
                'package_name': node.package_name if node.package_name else '',
                'path': node.path if node.path else '',
                'description': (node.description | string)[:2000] if node.description else '',
                'depends_on_nodes': dep_nodes[:4000],
                'tags': node_tags[:2000],
                'meta': node_meta[:2000]
            } %}
            {% do manifest_nodes_data.append(data) %}
        {% endfor %}

        {# 3. Capture manifest edges (DAG) #}
        {% set manifest_edges_data = [] %}
        {% for node_id, node in graph.nodes.items() %}
            {%- for dep_id in node.depends_on.nodes -%}
                {%- set dep_node = graph.nodes.get(dep_id) -%}
                {%- if dep_node -%}
                    {% set data = {
                        'invocation_id': invocation_id,
                        'parent_id': dep_id,
                        'parent_name': dep_node.name,
                        'parent_type': dep_node.resource_type,
                        'child_id': node_id,
                        'child_name': node.name,
                        'child_type': node.resource_type
                    } %}
                    {% do manifest_edges_data.append(data) %}
                {%- endif -%}
            {%- endfor -%}
        {% endfor %}

        {# 4. Insert run results #}
        {% if run_results_data %}
            {% set insert_results = [] %}
            {% for row in run_results_data %}
                {%- do insert_results.append("SELECT '" ~ row.run_id ~ "', '" ~ row.invocation_id ~ "', '" ~ row.node_id ~ "', '" ~ row.node_name ~ "', '" ~ row.resource_type ~ "', '" ~ row.node_status ~ "', " ~ row.execution_time ~ ", '" ~ row.thread_id ~ "', '" ~ (row.message | replace("'", "''")) ~ "', " ~ ("'" ~ row.failed_at ~ "'" if row.failed_at else "NULL") ~ ", '" ~ row.completed_at ~ "'") -%}
            {% endfor %}

            {% if insert_results %}
                {% set union_query = insert_results | join(' UNION ALL ') %}
                {% set sql %}
                    INSERT INTO operations.dbt_run_results
                    (run_id, invocation_id, node_id, node_name, resource_type, node_status, execution_time, thread_id, message, failed_at, completed_at)
                    {{ union_query }}
                {% endset %}
                {% do run_query(sql) %}
                {% do log('dbt artifacts: ' ~ insert_results | length ~ ' run results captured', info=true) %}
            {% endif %}
        {% endif %}

        {# 5. Insert manifest nodes #}
        {% if manifest_nodes_data %}
            {% set insert_nodes = [] %}
            {% for row in manifest_nodes_data %}
                {%- do insert_nodes.append("SELECT '" ~ row.invocation_id ~ "', '" ~ row.node_id ~ "', '" ~ row.node_name ~ "', '" ~ row.resource_type ~ "', '" ~ row.package_name ~ "', '" ~ row.path ~ "', '" ~ (row.description | replace("'", "''")) ~ "', '" ~ (row.depends_on_nodes | replace("'", "''")) ~ "', '" ~ (row.tags | replace("'", "''")) ~ "', '" ~ (row.meta | replace("'", "''")) ~ "'") -%}
            {% endfor %}

            {% if insert_nodes %}
                {% set union_query = insert_nodes | join(' UNION ALL ') %}
                {% set sql %}
                    INSERT INTO operations.dbt_manifest_nodes
                    (invocation_id, node_id, node_name, resource_type, package_name, path, description, depends_on_nodes, tags, meta)
                    {{ union_query }}
                {% endset %}
                {% do run_query(sql) %}
                {% do log('dbt artifacts: ' ~ insert_nodes | length ~ ' manifest nodes captured', info=true) %}
            {% endif %}
        {% endif %}

        {# 6. Insert manifest edges #}
        {% if manifest_edges_data %}
            {% set insert_edges = [] %}
            {% for row in manifest_edges_data %}
                {%- do insert_edges.append("SELECT '" ~ row.invocation_id ~ "', '" ~ row.parent_id ~ "', '" ~ row.parent_name ~ "', '" ~ row.parent_type ~ "', '" ~ row.child_id ~ "', '" ~ row.child_name ~ "', '" ~ row.child_type ~ "'") -%}
            {% endfor %}

            {% if insert_edges %}
                {% set union_query = insert_edges | join(' UNION ALL ') %}
                {% set sql %}
                    INSERT INTO operations.dbt_manifest_edges
                    (invocation_id, parent_id, parent_name, parent_type, child_id, child_name, child_type)
                    {{ union_query }}
                {% endset %}
                {% do run_query(sql) %}
                {% do log('dbt artifacts: ' ~ insert_edges | length ~ ' DAG edges captured', info=true) %}
            {% endif %}
        {% endif %}

    {% endif %}
{% endmacro %}
