# Translation tables

User-facing strings live in `i18n/<lang>.conf`, one flat `key=value` line per
string, read by the same parser as every other table in this repository
(`lib/kv.sh`). English (`en.conf`) is the reference language.

## What a table may contain

A translation is **text**. It is never a command, a dispatcher name or a file
path. Those belong in the registries under `data/`, in typed action columns:

| `action_type` | `action_value` is            | executed by                    |
|---------------|------------------------------|--------------------------------|
| `exec`        | a program and its arguments  | the shell, from the registry   |
| `dispatch`    | a Hyprland dispatcher call   | `hyprctl dispatch`             |
| `doc`         | a path under `docs/`         | the pager or browser           |

A registry row points at its text through a `label_key`; the table supplies
the text for that key. The help renderer's signature makes the separation
structural: it receives a label string and never a command, and a test
asserts that no code path passes a translation to a command position.

## Placeholders

Values may contain `{1}`, `{2}`, … which `i18n_format` replaces with its
positional arguments by plain string substitution. There is no `printf` with
a data-controlled format: `%s` and friends are refused by the coverage gate,
and an argument containing `{2}` or `$x` is inserted as those literal
characters.

## Coverage

Every table declares its key count in a `# keys: N` header, and the gate
(`scripts/check-i18n-coverage.sh`, a permanent stage of `check.sh`) fails when:

- the declared count is not the actual count, or a key repeats;
- a non-English table's key set differs from `en.conf` in either direction;
- a value contains a printf directive;
- a registry references a `label_key` that `en.conf` does not define.

The gate is permanent on purpose. A string added in any later change fails
here until every table carries it, which is the only mechanism that keeps a
second language complete after the change that introduced it has landed.

## Fallback

`i18n_load fr` loads `en.conf` and then `fr.conf` over it. A key the French
table lacks resolves to the English text prefixed with `[en]`, so a
half-translated interface shows exactly where its gaps are instead of hiding
them. A key neither table defines renders as `[the.key]` — never empty, never
a crash.

## Which language a script uses

`bootstrap.sh` reads the session locale (`LANG`, which `apply-system.sh
--locale` sets system-wide), keeps its language part, and loads that table;
`VIVAC_LANG=es` overrides it for one run. `C`, `POSIX` or an unknown
language mean the English reference table. Spanish (`es.conf`) is complete
and gate-checked; a deliberate gap test shows the `[en]` marking end to end.

## Namespaces

Keys are dotted, lowest namespace first: `selector.vm`, `help.hypr.terminal`.
The namespace is documentation for humans and grouping for translators; the
gate does not interpret it.
