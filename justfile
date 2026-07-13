# dbt + Synapse SCD2 Development Justfile
# Run with: just <recipe>
# List recipes: just --list

set dotenv-load

# ============================================================================
# SETUP & VERIFICATION
# ============================================================================

# Verify dbt configuration and Synapse connection
debug:
    dbt debug

# Install dbt dependencies from packages.yml
deps:
    dbt deps

# Parse all dbt models without executing
parse:
    dbt parse

# Clean target, logs, and dbt_packages directories
clean:
    dbt clean

# Full reset: clean + parse
reset: clean parse
    @echo "Project reset complete"

# ============================================================================
# CORE DBT WORKFLOWS
# ============================================================================

# Run all dbt models (staging + SCD2 layer)
run:
    dbt run

# Build all models AND run tests (use this for SCD2 - gates are part of build)
build:
    dbt build

# Run only tests
test:
    dbt test

# Run tests with details on failures
test-debug:
    dbt test --debug

# Run specific model(s) - usage: just run-select stg_entra_membership
run-select MODEL:
    dbt run --select {{MODEL}}

# Build specific model(s) with tests - usage: just build-select dim_entra_membership__history
build-select MODEL:
    dbt build --select {{MODEL}}

# ============================================================================
# SCD2 MACRO WORKFLOWS
# ============================================================================

# Generate SCD2 shim files (models + tests) from vars.scd2_dimensions config
# Outputs shell commands - pipe to sh to execute
scd2-generate:
    dbt --quiet run-operation scd2_generate_shims | sh

# Show what would be generated without executing
scd2-preview:
    dbt --quiet run-operation scd2_generate_shims

# Build all SCD2 dimensions with approval gating (recommended nightly workflow)
scd2-build:
    dbt build --select tag:scd2

# Run only SCD2 models (skip tests)
scd2-run:
    dbt run --select tag:scd2

# Test only SCD2 gate tests
scd2-test:
    dbt test --select tag:scd2_gate

# ============================================================================
# PERIODIC SNAPSHOT FACT WORKFLOWS
# ============================================================================

# Generate fact snapshot shim files (models + tests) from vars.fact_snapshots
# Outputs shell commands - pipe to sh to execute
fact-generate:
    dbt --quiet run-operation fact_snapshot_generate_shims | sh

# Show what would be generated without executing
fact-preview:
    dbt --quiet run-operation fact_snapshot_generate_shims

# Build all snapshot facts with approval gating (recommended nightly workflow)
fact-build:
    dbt build --select tag:fact_snapshot

# Run only fact snapshot models (skip tests)
fact-run:
    dbt run --select tag:fact_snapshot

# Test only fact snapshot gate tests
fact-test:
    dbt test --select tag:fact_snapshot_gate

# Preview a fact rollback to a snapshot date (DRY RUN - reports only)
# usage: just fact-rollback-preview fact_inventory_snapshot__history 2026-07-01
fact-rollback-preview MODEL DATE:
    dbt run-operation fact_snapshot_rollback --args '{"model_name": "{{MODEL}}", "to_datetime": "{{DATE}}"}'

# Execute a fact rollback to a snapshot date (logical only; reversible until next run)
# usage: just fact-rollback fact_inventory_snapshot__history 2026-07-01
fact-rollback MODEL DATE:
    dbt run-operation fact_snapshot_rollback --args '{"model_name": "{{MODEL}}", "to_datetime": "{{DATE}}", "dry_run": false}'

# Execute a fact rollback AND physically purge un-approved rows (IRREVERSIBLE)
# usage: just fact-rollback-purge fact_inventory_snapshot__history 2026-07-01
fact-rollback-purge MODEL DATE:
    dbt run-operation fact_snapshot_rollback --args '{"model_name": "{{MODEL}}", "to_datetime": "{{DATE}}", "dry_run": false, "purge": true}'

# Reverse the most recent fact rollback (re-approve its batches)
# usage: just fact-restore fact_inventory_snapshot__history
fact-restore MODEL:
    dbt run-operation fact_snapshot_restore_last_rollback --args '{"model_name": "{{MODEL}}"}'

# ============================================================================
# DOCUMENTATION & LINEAGE
# ============================================================================

# Generate dbt docs (manifest.json + index.html)
docs-gen:
    dbt docs generate

# Serve dbt docs locally (opens at http://localhost:8000)
docs-serve:
    dbt docs serve

# Generate and open docs in one command
docs: docs-gen docs-serve

# ============================================================================
# DATA QUALITY
# ============================================================================

# Check source freshness (requires sources defined in YAML)
freshness:
    dbt source freshness

# Run snapshot models (incremental SCD2 alternatives)
snapshot:
    dbt snapshot

# ============================================================================
# STAGING LAYER WORKFLOWS
# ============================================================================

# Build only staging models
staging-build:
    dbt build --select tag:staging

# Run only staging models
staging-run:
    dbt run --select tag:staging

# Test only staging layer
staging-test:
    dbt test --select tag:staging

# ============================================================================
# DEVELOPMENT HELPERS
# ============================================================================

# Full development run: parse + build everything
dev: parse build
    @echo "✓ Development build complete"

# Quick compile check (parse + compile)
compile: parse
    dbt compile

# Run dbt with verbose logging (useful for debugging)
debug-run:
    dbt run --debug

# Run dbt build with verbose logging
debug-build:
    dbt build --debug

# Run specific tag - usage: just tag-run staging
tag-run TAG:
    dbt run --select tag:{{TAG}}

# Build specific tag - usage: just tag-build scd2
tag-build TAG:
    dbt build --select tag:{{TAG}}

# ============================================================================
# AUDIT & VALIDATION
# ============================================================================

# Check for model selection issues (useful for debugging selectors)
compile-check:
    dbt compile --select "*"

# Run tests against production data (requires separate target in profiles.yml)
test-prod:
    dbt test --target prod

# Generate freshness report
freshness-report:
    dbt source freshness

# ============================================================================
# UTILITY
# ============================================================================

# Show all available dbt commands
dbt-help:
    dbt --help

# Display all dbt models parsed in project
ls-models:
    dbt ls --resource-type model

# Display all dbt tests
ls-tests:
    dbt ls --resource-type test

# Display all macros
ls-macros:
    dbt ls --resource-type macro

# Show recipe list
help:
    just --list

# ============================================================================
# VSCODE INTEGRATION HELPERS
# ============================================================================

# Recommended workflow for daily development
daily:
    @echo "🔧 Running daily development checks..."
    just parse
    @echo "✓ Project parsed"
    just scd2-build
    @echo "✓ SCD2 dimensions built and tested"
    just fact-build
    @echo "✓ Snapshot facts built and tested"
    just docs-gen
    @echo "✓ Documentation generated"
    @echo "✨ Daily workflow complete!"

# Quick sanity check (compile + run tests)
quick-check: compile test
    @echo "✓ Quick check passed"

# Pre-commit checks (parse + compile + test)
pre-commit: parse compile test
    @echo "✓ Ready to commit"
