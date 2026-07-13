# Conforming a dimension to a canonical table

A reusable recipe for aligning inconsistent source references (codes or names)
to a canonical dimension table, with a hand-editable override table that always
wins. The engine — [`conform_dimension`](macros/conform_dimension.sql) — already
exists in this repo; **country** is a working reference implementation and
**ports** is the worked example for adding a new dimension.

---

## 1. The mental model

Every source row is resolved to the **canonical primary key** (an ISO code for
countries, a UN/LOCODE for ports), then the canonical name is attached by
joining that key back to the canonical table. Resolution is first-hit-wins:

1. **Override** — a row in the dimension's override seed for this
   `(source_system, match_key, source_value)`. The manual escape hatch.
2. **Auto-match** — code sources match on the canonical code; name sources match
   on the canonical name (accent/case-insensitive).
3. **Unmatched** — no override, no auto-match → canonical key is `NULL`, status
   `unmatched`. Surface these and add an override for each.

Overrides map to the canonical **key**, not name-to-name, so one override row
fixes the name too. The name path never reads a source code column, so a
name-only source (like SID) conforms exactly the same way as a coded one.

---

## 2. What's already in the repo

| Part | File | Role |
| ---- | ---- | ---- |
| **Engine** | [macros/conform_dimension.sql](macros/conform_dimension.sql) | `conform_dimension()` (resolution) + `conform_unmatched_report()` — dimension-agnostic, driven by an `entity` arg |
| Country wrapper | [macros/country_conform.sql](macros/country_conform.sql) | Thin `country_conform()` over the engine (`entity='country'`), kept for backward compatibility |
| Override seed | [data/country_conformance_overrides.csv](data/country_conformance_overrides.csv) + [.yml](data/country_conformance_overrides.yml) | Hand-edited mappings + grain/accepted-values tests |
| Conformed models | [stg_fid__conformed.sql](models/staging/stg_fid__conformed.sql) (code), [stg_sid__conformed.sql](models/staging/stg_sid__conformed.sql) (name) | One thin model per source |
| Review model | [country_conformance_unmatched.sql](models/staging/country_conformance_unmatched.sql) | Values still needing an override |

**You do not copy or edit the engine to add a dimension.** New dimensions call
`conform_dimension()` directly with their own `entity`; the country wrapper
exists only so pre-existing `country_conform()` calls keep working — don't write
new wrappers like it.

`conform_dimension(entity='port', …)` emits `canonical_port_code`,
`canonical_port_name`, and `port_match_status`, and defaults its override seed to
`ref('port_conformance_overrides')`.

---

## 3. Worked example: adding ports

Canonical ports table keyed by **UN/LOCODE** (`NLRTM` = Rotterdam, `USNYC` = New
York) with a `port_name`. Two sources:

- **VMS** — a vessel system carrying a LOCODE → conform by **code**.
- **MFT** — a manifest system carrying only a port **name**, often decorated
  ("Port of Rotterdam") → conform by **name** + overrides.

### Step 1 — Point at your canonical table

You already have it. It needs a **unique key** column and a **unique name**
column (name uniqueness is required — a duplicated name matches a source row to
two keys). Make it a dbt node (source or ref) if it isn't already.

### Step 2 — Create the override seed

`data/port_conformance_overrides.csv` (seeds live in `data/` per
[dbt_project.yml](dbt_project.yml)):

```csv
source_system,match_key,source_value,canonical_code,note
MFT,name,Port of Rotterdam,NLRTM,MFT decorates names with "Port of"
MFT,name,New York,USNYC,disambiguate to the seaport LOCODE
VMS,code,RTM,NLRTM,VMS emits the 3-char location part only
```

> Name the target column **`canonical_code`** — that is `conform_dimension`'s
> default `override_code_column`. (Country's seed predates the default and uses
> `canonical_country_code`, which its wrapper passes through explicitly.)

`data/port_conformance_overrides.yml` — copy the country seed's yaml, rename to
`port_conformance_overrides`, keep the `column_types`, the `not_null` /
`accepted_values(['code','name'])` column tests, and the
`dbt_utils.unique_combination_of_columns` grain test on
`[source_system, match_key, source_value]`.

### Step 3 — One conformed model per source

`models/staging/vms_ports__conformed.sql` (code source):

```sql
{{ config(materialized='view', tags=['staging', 'port_conform']) }}
{{ conform_dimension(
    entity                = 'port',
    source_relation       = source('vms', 'positions'),
    source_system         = 'VMS',
    match_key             = 'code',
    source_column         = 'locode',
    canonical_relation    = source('reference', 'port'),
    canonical_code_column = 'locode',
    canonical_name_column = 'port_name'
) }}
```

`models/staging/mft_ports__conformed.sql` (name-only source): identical, but
`match_key='name'`, `source_column='port_name'`, and `source('mft','manifests')`.

Both output `canonical_port_code`, `canonical_port_name`, `port_match_status`, so
downstream models treat VMS and MFT identically even though MFT never had a code.

### Step 4 — Unmatched review model

`models/staging/port_conformance_unmatched.sql`:

```sql
{{ config(materialized='view', schema='audit', tags=['port_conform', 'audit']) }}
{{ conform_unmatched_report('port', [
    {'relation': ref('vms_ports__conformed'), 'source_system': 'VMS',
     'match_key': 'code', 'source_column': 'locode'},
    {'relation': ref('mft_ports__conformed'), 'source_system': 'MFT',
     'match_key': 'name', 'source_column': 'port_name'}
]) }}
```

### Step 5 — Install, seed, build

```sh
just deps          # if dbt_utils isn't installed yet (grain test)
dbt seed  --select port_conformance_overrides
dbt build --select tag:port_conform
```

Inspect `port_conformance_unmatched`, add an override row per unmatched value,
`dbt seed`, rebuild. Repeat until it's empty (or every remainder is intentional).

---

## 4. `conform_dimension` parameters

| Param | Required | Purpose |
| ----- | -------- | ------- |
| `entity` | yes | Names the outputs (`canonical_<entity>_code/_name`, `<entity>_match_status`) and the default override seed |
| `source_relation` | yes | The source `source()`/`ref()` to conform |
| `source_system` | yes | Value matched against the override seed's `source_system` |
| `match_key` | yes | `'code'` or `'name'` — which auto-match path |
| `source_column` | yes | The source column holding the code or name |
| `canonical_relation` | yes | The canonical table |
| `canonical_code_column` | yes | Canonical PK column (e.g. `country_code`, `locode`) |
| `canonical_name_column` | yes | Canonical name column |
| `overrides_relation` | no | Defaults to `ref(entity ~ '_conformance_overrides')` |
| `override_code_column` | no | Seed's target-code column; default `canonical_code` |
| `name_collation` | no | Accent/case-insensitive collation for name matching; default `Latin1_General_CI_AI` |

### Per-dimension config, country vs port

| Config | Country | Port |
| ------ | ------- | ---- |
| `entity` | `'country'` | `'port'` |
| `canonical_relation` | `source('reference','country')` | `source('reference','port')` |
| `canonical_code_column` | `country_code` | `locode` |
| `canonical_name_column` | `country_name` | `port_name` |
| override seed | `country_conformance_overrides` | `port_conformance_overrides` |
| `override_code_column` | `canonical_country_code` | `canonical_code` (default) |
| sources | FID (code), SID (name) | VMS (code), MFT (name) |

---

## 5. Gotchas

- **Canonical name must be unique.** Name matching joins on it; a duplicate name
  fans one source row into several. Put a `unique` test on the canonical name
  column (see [country_conformance_sources.yml](models/staging/country_conformance_sources.yml)).
- **Ambiguous names — worse for ports than countries.** "Portland" is three
  ports; "Springfield" many places. A single-column name match can't
  disambiguate. Either add an override per ambiguous value, or, if the source
  carries a country/region, extend the join to a composite key
  (`name + country_code`) or pre-filter the canonical join by country. The
  engine matches one column today; composite matching is a small edit to its
  join predicate.
- **Codes that look like NULL.** Country `NA` (Namibia) and similar — the seed
  yaml pins `column_types` to keep codes as text. Do the same for your dimension.
- **Override grain.** Keep the seed unique on
  `(source_system, match_key, source_value)`; the
  `dbt_utils.unique_combination_of_columns` test enforces it. A duplicate
  override multiplies rows on the override join.
- **Collation.** `Latin1_General_CI_AI` gives case/accent-insensitive name
  matching ("Cote"/"Côte"). Change `name_collation` if your columns differ.
- **`m.*` passthrough.** Output includes the source's own columns; a source
  column already named `canonical_<entity>_code/_name` or `<entity>_match_status`
  would collide — rename it upstream.
- **Use `dbt build`, not `dbt run`,** so the seed tests actually execute.

---

## 6. Per-dimension checklist

- [ ] Canonical table is a dbt node with a **unique key** and **unique name**
      column.
- [ ] `data/<entity>_conformance_overrides.csv` (target column `canonical_code`).
- [ ] `data/<entity>_conformance_overrides.yml` with column types + `not_null`,
      `accepted_values`, and grain tests.
- [ ] One `<source>__conformed.sql` per source, calling
      `conform_dimension(entity='<entity>', match_key='code'|'name', …)`.
- [ ] `<entity>_conformance_unmatched.sql` calling `conform_unmatched_report`.
- [ ] `just deps && dbt seed && dbt build --select tag:<entity>_conform`.
- [ ] Unmatched review model empty, or every remaining value is intentional.
