# Security model

## What this server defends against

The threat model is "an LLM with tool access talking to a Postgres database it shouldn't have full reign over."

Concretely:

| Threat | Defense |
|---|---|
| Prompt-injected agent issuing `DROP TABLE`, `TRUNCATE`, etc. | `ddl.allowed = false` refuses all DDL at validation time, before the wire. |
| Agent trying to read a table it has no business reading | Grant list is allowlist-only. Unlisted tables are invisible. |
| Agent dumping the world via `SELECT *` | `shape.deny_select_star` refuses `*` projections. |
| Agent issuing bare `DELETE FROM users` | `shape.require_where_on_writes` refuses `UPDATE`/`DELETE` without a `WHERE`. |
| Agent burning CPU with window functions | `shape.allow_window` opt-in. Default off. |
| Agent issuing a multi-MB SQL string to OOM the server | `limits.max_query_bytes` hard cap, checked before parse. |
| Agent running a query that hangs Neon for minutes | `limits.statement_timeout_ms` bounds the HTTP request lifetime. |
| Agent reading from `audit_log` to cover its tracks | `actions: ["write"]` only — append-only configuration. |
| Process using filesystem write / shell-out / FFI to escape | Kryos `@capabilities(net, env, io)` is **compile-time** proof the binary cannot do anything else. |

## What this server does **not** defend against

Be honest about the gaps:

- **A weak Postgres role.** If `DATABASE_URL` points at a superuser, a SQL injection through the (small, validated) surface still has more capability than it should. Run as a least-privileged role. Treat the grants file as defense in depth, not the only defense.
- **Per-row authorization.** There is no concept of "agent X can only see their own orders." Use Postgres RLS policies on the role for that.
- **Column-level enforcement (v0.1).** The grants list columns but does not yet check `SELECT` projections against them. Listed columns are agent-facing documentation in v0.1; enforcement lands in v0.2.
- **Auto-injected `WHERE` filters (v0.1).** `tables[].filter` is not yet rewritten into the query. Same v0.2 plan.
- **A real SQL parser.** Validation is regex-based. It is deliberately conservative — ambiguous statements are refused — but it is not the same as having a full pg parser. Adversarial inputs that confuse the heuristic should fail closed (refused). If you find one that fails open, it's a security bug — please file an issue.
- **Statement-timeout enforcement at Postgres.** v0.1 uses the timeout as the HTTP request deadline only. A `SET statement_timeout` push to Postgres is planned.
- **Audit logging.** v0.1 does not write a per-tool-call audit trail. Refusal reasons go back to the caller; nothing is persisted by default. Add this at the agent layer, or wait for v0.2.

## Capability proof

`main.kry` declares `@capabilities(net, env, io)` on `main()`. The Kryos compiler verifies at compile time that no path through the binary uses any capability outside of that set. Concretely: the built binary cannot read your `~/.ssh/id_rsa` even if a future commit accidentally tries to — it would fail to compile.

This is a language-level guarantee. It does not depend on you trusting this codebase or its dependencies. If the project added a dependency that needed `fs_write`, the build would break and you'd see it in CI.

## Reporting a vulnerability

Email `info@northtek.io` with `[kryos-mcp-pg]` in the subject. Please include the failing input and the version (commit SHA) you were on.

Issues that fail closed (validator refuses something it shouldn't) are bugs — file as a normal issue. Issues that fail open (validator allows something it shouldn't) are security bugs — please use email.
