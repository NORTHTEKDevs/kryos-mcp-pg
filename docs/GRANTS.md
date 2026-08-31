# Grants reference

The grants file is the policy. The Kryos process is the enforcer. Default for any
table or capability not listed is **DENY**.

The path is `KRYOS_MCP_PG_GRANTS=/path/to/grants.json` (defaults to `./grants.json`).

---

## Top-level shape

```json
{
  "connection": { "url_env": "DATABASE_URL" },
  "limits":     { "statement_timeout_ms": 5000, "max_rows": 1000, "max_query_bytes": 16384 },
  "tables":     [ /* per-table grants */ ],
  "ddl":        { "allowed": false },
  "shape":      { "deny_select_star": true, "require_where_on_writes": true, "allow_window": false }
}
```

Field reference below.

---

## `connection`

| Field | Type | Default | Notes |
|---|---|---|---|
| `url_env` | string | `"DATABASE_URL"` | Name of the env var that holds the Postgres connection string. The server parses the host out and POSTs to `https://<host>/sql` (Neon HTTP serverless endpoint). |

The connection string itself never appears in the grants file — only the name of the env var that holds it.

---

## `limits`

| Field | Type | Default | Notes |
|---|---|---|---|
| `statement_timeout_ms` | int | `5000` | Used as the HTTP request timeout (with a 10s buffer added). Not yet pushed to Postgres as a `SET statement_timeout`. |
| `max_rows` | int | `1000` | Caps display rows. Anything beyond is truncated in the response with a "showing first N" note. The full result is still pulled across the wire (v0.2 will pre-cap with `LIMIT`). |
| `max_query_bytes` | int | `16384` | Hard byte cap on the inbound SQL string. Anything larger is refused before validation. |

---

## `tables[]`

A grant entry per table. **A table not listed here is invisible** — any reference to it from a query is refused.

| Field | Type | Default | Notes |
|---|---|---|---|
| `name` | string | required | The unqualified table name. The validator matches on this. |
| `schema` | string | `"public"` | Reported in `tables` and `grants` tool output. Not yet enforced (v0.2 will check `schema.table` form). |
| `actions` | string[] | `[]` | Subset of `["read", "write"]`. `read` covers `SELECT` / `WITH` / `EXPLAIN`. `write` covers `INSERT` / `UPDATE` / `DELETE` / `MERGE`. DDL is governed by `ddl.allowed`. |
| `columns` | string[] | `["*"]` | Informational in v0.1. Listed in the `tables` tool. v0.2 will enforce this against `SELECT` projections. |
| `filter` | string | `""` | Informational in v0.1. v0.2 will auto-inject this into `WHERE` clauses. |

### Patterns

**Read-only with column awareness:**
```json
{ "name": "users", "actions": ["read"], "columns": ["id", "email"], "filter": "deleted_at IS NULL" }
```

**Read + write:**
```json
{ "name": "orders", "actions": ["read", "write"], "columns": ["*"] }
```

**Append-only (writes allowed, reads refused — useful for audit logs):**
```json
{ "name": "audit_log", "actions": ["write"], "columns": ["*"] }
```

---

## `ddl`

| Field | Type | Default | Notes |
|---|---|---|---|
| `allowed` | bool | `false` | Master switch for `CREATE` / `ALTER` / `DROP` / `TRUNCATE`. When `false`, every DDL statement is refused at validation time, regardless of the connection role's privileges. Leave it `false` unless an agent has a reason to migrate. |

---

## `shape`

Cross-cutting SQL-shape constraints, applied before per-table action checks.

| Field | Type | Default | Notes |
|---|---|---|---|
| `deny_select_star` | bool | `true` | Refuses any query containing `SELECT *`. Forces explicit column lists, which keeps the agent's data exposure narrow and auditable. |
| `require_where_on_writes` | bool | `true` | Refuses bare `UPDATE` / `DELETE` (no `WHERE` clause). Catches the most common runaway-mutation footgun. |
| `allow_window` | bool | `false` | Refuses any `OVER (...)` window clause. Window functions can be expensive and surprising — opt in only when needed. |

---

## What's enforced where

| Check | Layer |
|---|---|
| Process can use net + env + io and nothing else | Compile time (Kryos `@capabilities`) |
| `max_query_bytes` | Server (validator, before parse) |
| Action classification (read/write/ddl) | Server (validator) |
| `ddl.allowed` | Server (validator) |
| `shape.*` gates | Server (validator) |
| Referenced table is in grants | Server (validator) |
| Action allowed for that table | Server (validator) |
| `statement_timeout_ms` (as HTTP timeout) | Server (HTTP client) |
| `max_rows` (display cap) | Server (formatter) |
| Whatever your Postgres role can actually do | Postgres (final backstop) |

The validator runs **before** any HTTP request to Neon. The Postgres role is the last line of defense, not the first.

---

## v0.1 limitations to know about

- `tables[].columns` is informational. The list is exposed by the `tables` tool and is meant for agent-side hinting; column-level validation is v0.2.
- `tables[].filter` is informational. It's exposed but not auto-injected. v0.2 will rewrite the query.
- Schema qualification (e.g. `analytics.events`) is enforced as of v0.2. Bare references resolve to `public`; qualified references must match exactly. A grant for `analytics.events` does NOT match a bare `events` reference. (v0.1 had this as a gap.)
- The validator is regex-based, not a full SQL parser. It's deliberately conservative: anything ambiguous is refused.

See [SECURITY.md](SECURITY.md) for the threat model these checks are designed against.
