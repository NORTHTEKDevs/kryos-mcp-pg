# Roadmap

## v0.1 (current)

Six MCP tools, regex-based SQL validator, Neon HTTP execution. See [README.md](../README.md).

## v0.2 (in progress on `v0.2-dev` branch)

The "promote informational fields to enforced + close the silent-mismatch hole" release.

**Landed on v0.2-dev:**
- ~~**Schema-qualified table matching.**~~ Treats `analytics.events` and `public.events` as distinct grant entries. Bare references resolve to `public` only. Joins across schemas validated independently per side. **Tested:** `tests/run_v02_tests.sh` (6 schema-matching assertions).
- ~~**Per-call audit log.**~~ When `KRYOS_MCP_PG_AUDIT_LOG` env var is set, every `query` / `explain` / `dry_run` call appends a JSONL line with `ts`, `tool`, `verdict`, `reason`, `sql`. **Tested:** 8 audit assertions including JSON-validity round-trip.

**Still planned for v0.2:**
- **Column-level enforcement.** Parse the `SELECT` projection list and refuse columns not in `tables[].columns`. Errors with a specific column-name reason. ([gap](GRANTS.md#tables))
- **Auto-injected `WHERE` filters.** Rewrite the query to AND in `tables[].filter` for any reference to that table. Becomes the basis for tenant-isolation patterns. ([gap](GRANTS.md#tables))
- **Plain Postgres wire protocol.** Today the server only works against Neon's HTTP endpoint. v0.2 will add a libpq-style client so any Postgres works. ([gap](../README.md#limitations-v01))
- **`SET statement_timeout` push.** Use the limit as a real Postgres timeout, not just the HTTP deadline.
- **Auto-`LIMIT` on reads.** When `max_rows` is set, append `LIMIT max_rows` to bare reads so the cap happens at Postgres, not at the formatter.
- **`describe_table` tool.** Replace the current `schema` tool's hand-rolled `information_schema.columns` query with a typed-output tool returning columns + types + nullability + PK + FKs.

## v0.3 (planned)

The "explicit transactions and prepared statements" release.

- **Transactions.** A `begin` / `commit` / `rollback` pair of tools, with a per-session transaction state. Required for any agent that needs to do multi-statement consistency.
- **Prepared statement caching.** Reuse plans across repeated tool calls.
- **Per-call cost cap.** A configurable max planner cost. Refuse queries that exceed it (use `EXPLAIN` first, then run).
- **Prometheus metrics endpoint.** Calls allowed, calls refused (by reason), latency p50/p95.
- **JSONB column awareness.** Special-case JSONB column projection so the validator understands `data->>'field'` lookups.

## Not on the roadmap (and why)

- **A full SQL parser in Kryos.** Tempting, but the conservative regex approach is fine for the grant-checking surface. A real parser belongs in the kryos-lang stdlib, not here.
- **Multi-database routing.** This is one server, one Postgres. Run multiple instances with different grants if you need that.
- **A web UI.** This is an MCP server. The agent is the UI.

## Contributing

If you have a use case the v0.2/v0.3 list doesn't cover, file an issue with the SQL workload that would have to work and which gate currently blocks it. PRs welcome — keep it conservative on the validator (refuse on ambiguity) and aggressive on tests (every new gate gets a test in `tests/scenarios.jsonl`).
