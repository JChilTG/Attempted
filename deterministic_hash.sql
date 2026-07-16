/*
    deterministic_hash
    ------------------
    A deterministic, order-stable change-detection hash for Synapse
    Dedicated SQL Pool that scales to hundreds (or thousands) of columns,
    far beyond the 8000-byte HASHBYTES / nvarchar(4000) limits.

    Why a plain HASHBYTES(CONCAT(...)) breaks in Synapse:
      * HASHBYTES accepts at most 8000 bytes of input. Concatenate a few
        dozen wide columns and you silently overflow -> truncated input ->
        two different rows hash the same.
      * CONCAT treats NULL as '' and glues values with no separator, so
        ('12','34') and ('1','234') produce the same string -> collisions.
      * Un-normalized NULLs / formats make the hash change run-to-run for
        data that never actually changed (the SCD2 "missing or stale in
        dim" trap).

    How this macro avoids all three (a Merkle-style fold):
      1. NORMALIZE every column to a deterministic string (NULL -> a fixed
         sentinel; dates/floats/binary get a canonical, lossless format).
      2. FINGERPRINT each column on its own: hashbytes over ONE normalized
         value (<= 8000 bytes) -> a fixed 64-char hex token. No column can
         ever overflow the limit, and every token is the same width.
      3. FOLD: hash the fixed-width tokens in bounded batches, then hash
         those results, repeating until a single value remains. Because
         every intermediate token is fixed-width, each batch is provably
         under 8000 bytes regardless of the underlying data, and positional
         fixed-width tokens make field-boundary collisions impossible.

    Usage (typically in a staging model that feeds SCD2 history):

        select
            entity_id,
            _landing_extract_date,
            {{ deterministic_hash(
                 relation = ref('raw_shipping_manifest'),
                 exclude  = ['entity_id', 'declaration_no', 'line_no',
                             '_landing_extract_date']
               ) }} as attribute_hash,
            ...
        from {{ ref('raw_shipping_manifest') }}

    The column set and order are discovered from `relation` and sorted by
    name, so the hash is stable no matter how the warehouse orders columns.
    Adding or removing a hashed column intentionally changes the hash (it is
    a real attribute change) - keep key / change-date / metadata columns in
    `exclude`.

    Two column-selection workflows:

      * DENY-LIST (default): hash every column except `exclude` and, unless
        turned off, every column whose name starts with '_' (metadata /
        change-date / batch columns). List only the columns to leave out.

            {{ deterministic_hash(ref('raw'), exclude=['entity_id']) }}

      * ALLOW-LIST: pass `include` to hash ONLY the named columns, in one
        place, so the hash cannot silently absorb a newly added source
        column. Explicitly included columns are always honoured - the
        underscore auto-exclusion never removes them - so you can include a
        '_'-prefixed column without disabling the default.

            {{ deterministic_hash(ref('raw'),
                 include=['cargo_desc', 'gross_weight_kg', 'hs_code']) }}

    Parameters:
      relation            dbt relation to read columns from (ref()/source()/this).
      exclude             list of column names NOT to hash (keys, change
                          date, the hash column itself, ...).
      include             optional allow-list; if given, ONLY these columns
                          hash (still minus `exclude`).
      exclude_underscore  default true: also drop columns whose name starts
                          with '_'. Set false to hash '_'-prefixed columns
                          in a deny-list workflow. Columns named explicitly
                          in `include` are never dropped by this rule.
      algorithm           MD5 | SHA1 | SHA2_256 (default) | SHA2_512.
      null_token          sentinel substituted for NULL (default '<<NULL>>').
      chunk_size          tokens per fold batch; defaults to the largest
                          value that is guaranteed to stay under the
                          8000-byte limit for the chosen algorithm. Override
                          only to tune, never to exceed.
*/


{#- hex width produced by CONVERT(char(N), hashbytes(algo, ..), 2) -#}
{% macro _dethash_hexlen(algorithm) %}
    {%- set a = algorithm | upper -%}
    {%- if   a == 'MD5'      -%}{%- do return(32)  -%}
    {%- elif a == 'SHA1'     -%}{%- do return(40)  -%}
    {%- elif a == 'SHA2_256' -%}{%- do return(64)  -%}
    {%- elif a == 'SHA2_512' -%}{%- do return(128) -%}
    {%- else -%}
        {{ exceptions.raise_compiler_error(
            "deterministic_hash: unsupported algorithm '" ~ algorithm ~
            "'. Use MD5, SHA1, SHA2_256, or SHA2_512.") }}
    {%- endif -%}
{% endmacro %}


{#- One column -> deterministic, NULL-safe, canonical nvarchar (<= 8000 bytes) -#}
{% macro _dethash_normalize(quoted_col, dtype, null_token) %}
    {%- set d = dtype | lower -%}
    {%- if d in ['date', 'datetime', 'datetime2', 'smalldatetime',
                 'datetimeoffset', 'time'] -%}
        {%- set expr = 'convert(nvarchar(33), ' ~ quoted_col ~ ', 126)' -%}
    {%- elif d in ['float', 'real'] -%}
        {#- style 3 = 17 digits, lossless round-trip -#}
        {%- set expr = 'convert(nvarchar(64), ' ~ quoted_col ~ ', 3)' -%}
    {%- elif d in ['binary', 'varbinary', 'image'] -%}
        {#- style 2 = hex, no 0x prefix -#}
        {%- set expr = 'convert(nvarchar(4000), ' ~ quoted_col ~ ', 2)' -%}
    {%- else -%}
        {%- set expr = 'convert(nvarchar(4000), ' ~ quoted_col ~ ')' -%}
    {%- endif -%}
    {%- do return("coalesce(" ~ expr ~ ", N'" ~ null_token ~ "')") -%}
{% endmacro %}


{#- hashbytes(...) wrapped to a fixed-width uppercase hex token -#}
{% macro _dethash_token(algorithm, hexlen, inner_expr) %}
    {%- do return("convert(char(" ~ hexlen ~ "), hashbytes('" ~
                  (algorithm | upper) ~ "', " ~ inner_expr ~ "), 2)") -%}
{% endmacro %}


{% macro deterministic_hash(relation,
                            exclude=[],
                            include=none,
                            exclude_underscore=true,
                            algorithm='SHA2_256',
                            null_token='<<NULL>>',
                            chunk_size=none) %}

    {%- set hexlen = _dethash_hexlen(algorithm) -%}

    {#- largest batch that keeps CONCAT input under 8000 bytes:
        hexlen hex chars * 2 bytes/char per token; also honour CONCAT's
        254-argument ceiling. -#}
    {%- set safe_max = ([ (8000 // (2 * hexlen)), 254 ] | min) -%}
    {%- if chunk_size is none -%}{%- set chunk_size = safe_max -%}{%- endif -%}
    {%- if chunk_size > safe_max -%}
        {{ exceptions.raise_compiler_error(
            "deterministic_hash: chunk_size " ~ chunk_size ~ " would overflow " ~
            "HASHBYTES' 8000-byte limit for " ~ algorithm ~ ". Max is " ~ safe_max ~ ".") }}
    {%- endif -%}

    {#- Parse-time (execute == false): emit a valid placeholder so the model
        compiles; dbt re-renders the model every run and resolves it for real. -#}
    {%- if not execute -%}
        {{ _dethash_token(algorithm, hexlen, "N''") }}
    {%- else -%}

        {%- set excl = exclude | map('lower') | list -%}
        {%- set incl = include | map('lower') | list if include is not none else none -%}

        {#- discover columns, filter, sort by name for order stability.
            Drop order: not in allow-list -> in deny-list -> '_'-prefixed
            (unless explicitly allow-listed, which always wins). -#}
        {%- set chosen = [] -%}
        {%- for c in adapter.get_columns_in_relation(relation) -%}
            {%- set nm = c.name | lower -%}
            {%- set allowed = (incl is none or nm in incl) -%}
            {%- set denied  = nm in excl -%}
            {%- set us_drop = exclude_underscore and nm.startswith('_')
                              and not (incl is not none and nm in incl) -%}
            {%- if allowed and not denied and not us_drop -%}
                {%- do chosen.append(c) -%}
            {%- endif -%}
        {%- endfor -%}
        {%- set chosen = chosen | sort(attribute='name') -%}

        {%- if chosen | length == 0 -%}
            {{ exceptions.raise_compiler_error(
                "deterministic_hash: no columns to hash in " ~ relation ~
                " after applying include/exclude.") }}
        {%- endif -%}

        {#- layer 0: one fixed-width fingerprint per column -#}
        {%- set tokens = [] -%}
        {%- for c in chosen -%}
            {%- set norm = _dethash_normalize(adapter.quote(c.name), c.dtype, null_token) -%}
            {%- do tokens.append(_dethash_token(algorithm, hexlen, norm)) -%}
        {%- endfor -%}

        {#- fold layers until a single token remains -#}
        {%- set ns = namespace(layer=tokens) -%}
        {%- for _ in range(0, 20) -%}
            {%- if ns.layer | length <= 1 -%}{%- break -%}{%- endif -%}
            {%- set nxt = [] -%}
            {%- for i in range(0, ns.layer | length, chunk_size) -%}
                {%- set batch = ns.layer[i:i + chunk_size] -%}
                {%- if batch | length == 1 -%}
                    {%- set inner = batch[0] -%}
                {%- else -%}
                    {%- set inner = 'concat(' ~ (batch | join(', ')) ~ ')' -%}
                {%- endif -%}
                {%- do nxt.append(_dethash_token(algorithm, hexlen, inner)) -%}
            {%- endfor -%}
            {%- set ns.layer = nxt -%}
        {%- endfor -%}

        {{ ns.layer[0] }}
    {%- endif -%}
{% endmacro %}
