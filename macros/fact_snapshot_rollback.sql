/*
    fact_snapshot_rollback / fact_snapshot_restore_last_rollback
    ------------------------------------------------------------
    Manual, operator-invoked rollback of a published periodic snapshot fact
    to a prior run or date. Sibling to scd2_rollback (scd2_rollback.sql) -
    same near-instant, logical-first mechanics: un-approving a batch makes
    its rows invisible to the published view immediately (the EXISTS
    semi-join in fact_snapshot_published simply stops matching). No data is
    moved. Operates on audit.fact_approved_batches and its own
    audit.fact_rollback_log, kept separate from the SCD2 audit tables so
    fact and dimension rollback history stay independently auditable.

    Usage (dry run is the DEFAULT - it only reports):

      -- preview a rollback to the state as of a given run
      dbt run-operation fact_snapshot_rollback --args '{
          "model_name": "fact_inventory_snapshot__history",
          "to_batch_id": "01937f2a-...."}'

      -- preview a rollback to end-of-day on a date
      dbt run-operation fact_snapshot_rollback --args '{
          "model_name": "fact_inventory_snapshot__history",
          "to_datetime": "2026-07-01"}'

      -- actually execute (logical rollback only; physical rows remain,
      -- so the rollback is REVERSIBLE until the next run purges them)
      dbt run-operation fact_snapshot_rollback --args '{
          "model_name": "fact_inventory_snapshot__history",
          "to_datetime": "2026-07-01",
          "dry_run": false}'

      -- execute AND physically purge the un-approved rows now
      dbt run-operation fact_snapshot_rollback --args '{
          "model_name": "fact_inventory_snapshot__history",
          "to_datetime": "2026-07-01",
          "dry_run": false,
          "purge": true}'

      -- change your mind (before any purge): re-approve the batches
      -- removed by the most recent rollback of this model
      dbt run-operation fact_snapshot_restore_last_rollback --args '{
          "model_name": "fact_inventory_snapshot__history"}'

    Semantics (identical to scd2_rollback):
      - to_batch_id : keep that batch and everything approved before it;
                      un-approve everything approved after it.
      - to_datetime : ISO format. 'YYYY-MM-DD' means end of that day
                      (23:59:59); pass 'YYYY-MM-DDTHH:MM:SS' for finer cuts.
      - Exactly one of the two must be provided.
      - model_name is the history model's name (= the approval table key).

    Every executed rollback writes one row per un-approved batch to
    audit.fact_rollback_log (who, when, criteria, original approved_at),
    which is both the audit trail and what makes restore possible.

    *** DATA LOSS WARNING ***
    The logical rollback is always reversible. The PHYSICAL purge is not:
    once un-approved rows are deleted (by purge=true, or by the next
    scheduled run's pre-hook), they can only be rebuilt from staging - and
    for rolling-window sources, snapshot dates older than the staging
    retention window are gone for good. A snapshot fact is especially
    exposed here: each purged batch is an ENTIRE period's snapshot, so a
    purge past retention permanently loses that period's measures for every
    entity. Restore (or export the rows) BEFORE the next scheduled run if in
    doubt.
*/


{% macro fact_snapshot_bootstrap_rollback_log() %}
    {% if execute %}
        {% set sql %}
            IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'audit')
                EXEC('CREATE SCHEMA audit');

            IF OBJECT_ID('audit.fact_rollback_log') IS NULL
                CREATE TABLE audit.fact_rollback_log
                (
                    rollback_id          varchar(64)  NOT NULL,
                    model_name           varchar(200) NOT NULL,
                    batch_id             varchar(64)  NOT NULL,
                    original_approved_at datetime2(0) NOT NULL,
                    criteria             varchar(400) NOT NULL,
                    executed_at          datetime2(0) NOT NULL,
                    executed_by          varchar(200) NOT NULL,
                    purged               bit          NOT NULL
                )
                WITH (DISTRIBUTION = ROUND_ROBIN, HEAP);
        {% endset %}
        {% do run_query(sql) %}
    {% endif %}
{% endmacro %}


{% macro fact_snapshot_rollback(model_name, to_batch_id=none, to_datetime=none, dry_run=true, purge=false) %}
    {% if not execute %}{% do return(none) %}{% endif %}

    {#- exactly one anchor -#}
    {% if (to_batch_id is none) == (to_datetime is none) %}
        {{ exceptions.raise_compiler_error(
            "fact_snapshot_rollback: provide exactly one of to_batch_id or to_datetime.") }}
    {% endif %}

    {% do fact_snapshot_bootstrap_audit() %}
    {% do fact_snapshot_bootstrap_rollback_log() %}

    {% set hist = ref(model_name) %}

    {#- resolve the cutoff (keep everything approved at or before it) -#}
    {% if to_batch_id is not none %}
        {% set res = run_query(
            "select convert(varchar(30), approved_at, 126) " ~
            "from audit.fact_approved_batches " ~
            "where model_name = '" ~ model_name ~ "' and batch_id = '" ~ to_batch_id ~ "'") %}
        {% if res.rows | length == 0 %}
            {{ exceptions.raise_compiler_error(
                "fact_snapshot_rollback: batch_id '" ~ to_batch_id ~ "' was never approved for '" ~
                model_name ~ "'. Query audit.fact_approved_batches for valid anchors.") }}
        {% endif %}
        {% set cutoff = res.rows[0][0] %}
        {% set criteria = 'to_batch_id=' ~ to_batch_id %}
    {% else %}
        {% set cutoff = to_datetime ~ ('T23:59:59' if to_datetime | length == 10 else '') %}
        {% set criteria = 'to_datetime=' ~ to_datetime %}
    {% endif %}

    {% set cutoff_expr = "convert(datetime2(0), '" ~ cutoff ~ "', 126)" %}

    {#- affected batches, with their physical row counts -#}
    {% set affected = run_query(
        "select a.batch_id, convert(varchar(30), a.approved_at, 126), coalesce(h.row_cnt, 0) " ~
        "from audit.fact_approved_batches a " ~
        "left join (select _batch_id, count(*) as row_cnt from " ~ hist ~ " group by _batch_id) h " ~
        "  on h._batch_id = a.batch_id " ~
        "where a.model_name = '" ~ model_name ~ "' and a.approved_at > " ~ cutoff_expr ~ " " ~
        "order by a.approved_at") %}

    {% if affected.rows | length == 0 %}
        {% do log('fact_snapshot_rollback: nothing to roll back - no ' ~ model_name ~
                  ' batches approved after ' ~ cutoff, info=True) %}
        {% do return(none) %}
    {% endif %}

    {% do log('fact_snapshot_rollback: ' ~ ('DRY RUN - ' if dry_run else '') ~ 'rolling back ' ~
              model_name ~ ' to ' ~ cutoff ~ ' will un-approve ' ~
              (affected.rows | length) ~ ' batch(es):', info=True) %}
    {% for row in affected.rows %}
        {% do log('    batch ' ~ row[0] ~ '  approved_at ' ~ row[1] ~ '  rows ' ~ row[2], info=True) %}
    {% endfor %}

    {% if dry_run %}
        {% do log('fact_snapshot_rollback: dry run only - nothing changed. ' ~
                  'Re-run with "dry_run": false to execute.', info=True) %}
        {% do return(none) %}
    {% endif %}

    {#- 1. audit trail first (also enables restore) -#}
    {% do run_query(
        "insert into audit.fact_rollback_log " ~
        "(rollback_id, model_name, batch_id, original_approved_at, criteria, executed_at, executed_by, purged) " ~
        "select '" ~ invocation_id ~ "', a.model_name, a.batch_id, a.approved_at, '" ~ criteria ~ "', " ~
        "sysutcdatetime(), suser_sname(), " ~ ('1' if purge else '0') ~ " " ~
        "from audit.fact_approved_batches a " ~
        "where a.model_name = '" ~ model_name ~ "' and a.approved_at > " ~ cutoff_expr) %}

    {#- 2. logical rollback: published view updates instantly -#}
    {% do run_query(
        "delete from audit.fact_approved_batches " ~
        "where model_name = '" ~ model_name ~ "' and approved_at > " ~ cutoff_expr) %}
    {% do log('fact_snapshot_rollback: approval rows deleted - ' ~ model_name ~
              ' published view now reflects state as of ' ~ cutoff, info=True) %}

    {#- 3. optional physical purge (same statement the pre-hook runs) -#}
    {% if purge %}
        {% do run_query(fact_snapshot_purge_unapproved(hist)) %}
        {% do log('fact_snapshot_rollback: un-approved rows physically purged from ' ~ hist ~
                  ' - this rollback is now IRREVERSIBLE from the warehouse.', info=True) %}
    {% else %}
        {% do log('fact_snapshot_rollback: physical rows retained - reversible via ' ~
                  'fact_snapshot_restore_last_rollback UNTIL the next scheduled run purges them. ' ~
                  'If the rolled-back snapshot dates exceed staging retention, restore or ' ~
                  'export before that run or the periods are permanently lost.', info=True) %}
    {% endif %}

    {#- approved set changed -> rebuild + swap the consumption table -#}
    {% set marker = fact_snapshot_marker_for_model(model_name) %}
    {% if marker %}
        {% set refresh = fact_snapshot_refresh_published(marker) %}
        {% if refresh is not mapping or not refresh.get('ok') %}
            {% set err = refresh.get('error', 'unknown refresh failure') if refresh is mapping else 'unknown refresh failure' %}
            {{ scd2_fail_run(
                'fact_snapshot_rollback: consumption table refresh failed for ' ~ marker ~ '. ' ~ err) }}
        {% endif %}
    {% endif %}

{% endmacro %}


{% macro fact_snapshot_restore_last_rollback(model_name, rollback_id=none) %}
    {% if not execute %}{% do return(none) %}{% endif %}

    {#- default to the most recent rollback event for this model -#}
    {% if rollback_id is none %}
        {% set res = run_query(
            "select top 1 rollback_id from audit.fact_rollback_log " ~
            "where model_name = '" ~ model_name ~ "' order by executed_at desc") %}
        {% if res.rows | length == 0 %}
            {{ exceptions.raise_compiler_error(
                "fact_snapshot_restore_last_rollback: no rollback events logged for '" ~ model_name ~ "'.") }}
        {% endif %}
        {% set rollback_id = res.rows[0][0] %}
    {% endif %}

    {% set hist = ref(model_name) %}

    {#- re-approve, preserving original approval timestamps -#}
    {% do run_query(
        "insert into audit.fact_approved_batches (model_name, batch_id, approved_at) " ~
        "select l.model_name, l.batch_id, l.original_approved_at " ~
        "from audit.fact_rollback_log l " ~
        "where l.rollback_id = '" ~ rollback_id ~ "' and l.model_name = '" ~ model_name ~ "' " ~
        "and not exists (select 1 from audit.fact_approved_batches a " ~
        "                where a.model_name = l.model_name and a.batch_id = l.batch_id)") %}

    {#- verify the physical rows still exist for each restored batch -#}
    {% set orphaned = run_query(
        "select l.batch_id from audit.fact_rollback_log l " ~
        "where l.rollback_id = '" ~ rollback_id ~ "' and l.model_name = '" ~ model_name ~ "' " ~
        "and not exists (select 1 from " ~ hist ~ " h where h._batch_id = l.batch_id)") %}

    {% if orphaned.rows | length > 0 %}
        {% do log('fact_snapshot_restore_last_rollback: WARNING - ' ~ (orphaned.rows | length) ~
                  ' restored batch(es) have NO physical rows left (already purged): ' ~
                  (orphaned.rows | map(attribute=0) | join(', ')) ~
                  '. Their approval rows are cosmetic; the data must be re-loaded from ' ~
                  'staging if still within retention.', info=True) %}
    {% else %}
        {% do log('fact_snapshot_restore_last_rollback: rollback ' ~ rollback_id ~ ' fully reversed - ' ~
                  'all batches re-approved and physical rows intact.', info=True) %}
    {% endif %}

    {#- approved set changed -> rebuild + swap the consumption table -#}
    {% set marker = fact_snapshot_marker_for_model(model_name) %}
    {% if marker %}
        {% set refresh = fact_snapshot_refresh_published(marker) %}
        {% if refresh is not mapping or not refresh.get('ok') %}
            {% set err = refresh.get('error', 'unknown refresh failure') if refresh is mapping else 'unknown refresh failure' %}
            {{ scd2_fail_run(
                'fact_snapshot_restore_last_rollback: consumption table refresh failed for ' ~ marker ~ '. ' ~ err) }}
        {% endif %}
    {% endif %}

{% endmacro %}
