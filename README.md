# kryos-mcp-pg

A capability-gated Postgres MCP server, written in [Kryos](https://github.com/NORTHTEKDevs/kryos-lang).

Every SQL statement is validated against a grant config before it touches the wire. If a grant doesn't permit it, the tool call returns a refusal and Postgres never sees the query. No prompt instructions to ignore. No "please don't drop the table." A small, auditable rule file decides what an LLM is allowed to do.

> **Status:** v0.1.0 — works end-to-end against any Neon Postgres database via Neon's HTTP serverless endpoint. Six MCP tools. Read-only and per-table grants enforced.

---

## The pitch

Most Postgres MCP servers expose one tool: `query(sql)`. The agent gets full read/write/DDL on every table — whatever the connection role can do, the LLM can do.

`kryos-mcp-pg` flips that. The connection role still matters, but a JSON grant file in front of it says:

- `users` — read only, columns `id, email, name, created_at`, auto-injected `WHERE deleted_at IS NULL`
- `orders` — read + write, all columns
- `audit_log` — append only (writes allowed, reads refused)
- everything else — invisible

Combined with shape gates (`deny_select_star`, `require_where_on_writes`, `allow_window`) and a hard `ddl.allowed = false`, the surface an agent can hit is small, explicit, and reviewable.

---

## Demo: seven scenarios in one run

```bash
DATABASE_URL=postgresql://fake:fake@ep-test-host.aws.neon.tech/db \
  KRYOS_MCP_PG_GRANTS=grants.example.json \
  echo '<seven JSON-RPC requests>' | kryos run src/main.kry
```

Output (one response line per request):

| # | Tool call | Result |
|---|---|---|
| 1 | `SELECT id, email FROM users WHERE deleted_at IS NULL` | **WOULD ALLOW** — action=read, tables=[users] |
| 2 | `SELECT * FROM users` | **WOULD REFUSE** — `shape.deny_select_star = true` |
| 3 | `DELETE FROM users` | **WOULD REFUSE** — `shape.require_where_on_writes = true` |
| 4 | `SELECT id FROM secrets` | **WOULD REFUSE** — table not in grants |
| 5 | `DROP TABLE users` | **WOULD REFUSE** — `ddl.allowed = false` |
| 6 | `INSERT INTO audit_log (event) VALUES ($1)` | **WOULD ALLOW** — action=write, tables=[audit_log] |
| 7 | `SELECT name FROM audit_log` | **WOULD REFUSE** — `audit_log` not granted action `read` |

The audit_log case is the point: same table, different action, different verdict. The grant file is the policy. The Kryos process is the enforcer.

---

## Tools

| Tool | Args | Description |
|---|---|---|
| `query` | `sql`, `params?` | Run a SELECT/INSERT/UPDATE/DELETE. Validated, then sent to Neon. |
| `explain` | `sql` | Same validation, wrapped in `EXPLAIN`. |
| `dry_run` | `sql` | Validate without executing. Returns WOULD ALLOW or WOULD REFUSE. |
| `tables` | — | List the granted tables visible to this server. |
| `schema` | `table` | Column list + types via `information_schema.columns`. |
| `grants` | — | Dump the active grant config (limits, shape gates, table list). |

---

## Install

Requires Kryos v1.0+ ([install](https://github.com/NORTHTEKDevs/kryos-lang)):

```bash
git clone https://github.com/NORTHTEKDevs/kryos-mcp-pg
cd kryos-mcp-pg
cp grants.example.json grants.json     # edit for your database
```

Run as an MCP server:

```bash
DATABASE_URL=postgresql://user:pass@ep-foo-bar.region.aws.neon.tech/db \
  KRYOS_MCP_PG_GRANTS=./grants.json \
  kryos run src/main.kry
```

> **v0.1 note:** `kryos build --release` (LLVM AOT) currently fails because the Kryos 1.0 LLVM backend is missing JSON / `http_request` builtins that the Cranelift backend has. Use `kryos run` until upstream lands those bindings — the Cranelift JIT is fast enough for production MCP usage. Tracked in [ROADMAP.md](docs/ROADMAP.md).

### Claude Desktop config

```json
{
  "mcpServers": {
    "pg": {
      "command": "kryos",
      "args": ["run", "/abs/path/to/kryos-mcp-pg/src/main.kry"],
      "env": {
        "DATABASE_URL": "postgresql://...",
        "KRYOS_MCP_PG_GRANTS": "/abs/path/to/grants.json"
      }
    }
  }
}
```

See [`examples/claude-desktop-config.json`](examples/claude-desktop-config.json) for a copy-pasteable version.

---

## Grant file

See [`grants.example.json`](grants.example.json) for the full schema. Minimum:

```json
{
  "connection": { "url_env": "DATABASE_URL" },
  "limits": {
    "statement_timeout_ms": 5000,
    "max_rows": 1000,
    "max_query_bytes": 16384
  },
  "tables": [
    {
      "name": "users",
      "schema": "public",
      "actions": ["read"],
      "columns": ["id", "email", "name"],
      "filter": "deleted_at IS NULL"
    }
  ],
  "ddl": { "allowed": false },
  "shape": {
    "deny_select_star": true,
    "require_where_on_writes": true,
    "allow_window": false
  }
}
```

Field reference:
- `tables[].actions` — any subset of `["read", "write", "ddl"]`. `read` = SELECT/EXPLAIN/WITH. `write` = INSERT/UPDATE/DELETE/MERGE. `ddl` covered separately by `ddl.allowed`.
- `tables[].columns` — informational for v0.1; not yet enforced at the column level (planned for v0.2).
- `tables[].filter` — informational for v0.1; not yet auto-injected (planned for v0.2).
- `shape.deny_select_star` — refuses any `SELECT *`.
- `shape.require_where_on_writes` — refuses bare `UPDATE`/`DELETE`.
- `shape.allow_window` — refuses window-function clauses (`OVER (...)`).

---

## How it works

1. **Startup:** load grants JSON, parse `DATABASE_URL`, extract Neon hostname for the HTTP endpoint.
2. **MCP loop:** read JSON-RPC 2.0 messages from stdin, dispatch by method.
3. **`tools/call query`:** classify SQL action (`read`/`write`/`ddl`), check shape gates, scan referenced tables against the grant list, refuse on first violation.
4. **If allowed:** POST to `https://<host>/sql` with `Neon-Connection-String` header and `{query, params}` body. Format response as a markdown table.

The Kryos `@capabilities(net, env, io)` annotation on `main()` means the compiler proves at compile time that this binary cannot use any other capability — no filesystem writes, no shell-out, no FFI. That's the language-level guarantee. The grant file layers per-table policy on top.

---

## What's enforced where

| Check | Enforced at |
|---|---|
| Process can use net + env + io and nothing else | **Compile time** (Kryos `@capabilities`) |
| SQL action allowed for table | Runtime (this server) |
| Shape gates (no SELECT *, WHERE on writes, etc.) | Runtime (this server) |
| Statement timeout, max rows, max query bytes | Runtime (this server) |
| Whatever your Postgres role can actually do | Postgres (final backstop) |

The runtime grant check fires *before* any SQL hits the network. The Postgres role is the last line of defense, not the first.

---

## Audit log (v0.2-dev)

When `KRYOS_MCP_PG_AUDIT_LOG=/path/to/audit.jsonl` is set, every `query` / `explain` / `dry_run` call appends a JSONL line:

```json
{"ts":1747259820,"tool":"dry_run","verdict":"refused","reason":"DDL refused: ddl.allowed = false in grants","sql":"DROP TABLE users"}
```

Allowed and refused calls both get logged. Unset to disable. (See [docs/ROADMAP.md](docs/ROADMAP.md) for what's landed on `v0.2-dev`.)

## Tests

```bash
bash tests/run_tests.sh
```

32 assertions covering all 7 README scenarios + 9 edge cases (joins onto ungranted tables, UPDATE on read-only tables, window functions, EXPLAIN classification, lowercase SQL, unknown actions like `VACUUM`) + tool-level error handling. Uses the `dry_run` tool throughout — no Neon round-trips, no DB needed. The fake `DATABASE_URL` in the script never connects.

## Limitations (v0.1)

- **Neon-only.** Uses Neon's HTTP serverless endpoint. Plain Postgres needs the wire protocol — planned for v0.2.
- **Column allowlists are informational.** Listed in grants but not yet enforced. SELECT specifics still go to Postgres as written.
- **Auto-injected WHERE filters are informational.** Listed in grants but not yet rewritten into the query.
- **SQL inspection is regex-based.** Not a real parser. Conservative: anything ambiguous is refused.
- **No prepared-statement caching.** Every query is a fresh HTTP POST.
- **No transaction support yet.** Single-statement queries only.

---

## Why Kryos for this

Three reasons this is built in [Kryos](https://github.com/NORTHTEKDevs/kryos-lang) and not TypeScript:

1. **Compile-time capability proofs.** `@capabilities(net, env, io)` is checked by the compiler. There is no path through the binary that opens a file or shells out, even if a future commit adds one — it would fail to compile.
2. **Single static binary.** No Node runtime, no `npm install`, no version drift. ~few MB executable, drop into a Docker image, run.
3. **The MCP server pattern in Kryos is short.** ~700 lines of pure Kryos for the whole thing. Easy to audit, easy to fork.

That said: this is also a deliberate dogfood for Kryos v1.0. If something breaks here, it's a bug in either the grant logic or the language stdlib — and both are fixable.

---

## License

MIT — see [LICENSE](LICENSE).

Built by [Northtek](https://northtek.io). Part of the [`kryos-mcp-*`](https://github.com/NORTHTEKDevs?q=kryos-mcp) family of capability-gated MCP servers.
