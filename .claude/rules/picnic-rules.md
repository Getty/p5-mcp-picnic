# MCP::Picnic House Rules

Apply to every task in this distribution unless explicitly overridden. Bias: caution over
speed on non-trivial work; use judgment on trivial tasks.

## Engineering discipline

1. **Think before coding** — State assumptions explicitly. When uncertain, ask rather than
   guess. Push back when a simpler approach exists. Stop when confused; name what's unclear.
2. **Simplicity first** — Minimum code that solves the problem. Nothing speculative. No
   abstractions for single-use code.
3. **Surgical changes** — Touch only what you must. Don't "improve" adjacent code or
   formatting. Match the existing style.
4. **Read before you write** — Before adding a tool, read `_build_server` and an existing
   `$server->tool(...)` block plus its `_*_to_hash` helper. They are the template; conform.
5. **Fail loud** — "Done" is wrong if anything was skipped silently. "Tests pass" is wrong if
   any were skipped. Surface uncertainty, don't hide it.

## Language — English only

All POD, MCP tool `description` strings, user-facing messages and error text are **English**.
This distribution ships to CPAN and to AI assistants worldwide; no German prose in shipped
code. The `bin/mcp-picnic-setup` wizard is the one place that may localise (it has an `en`/`de`
translation table) — keep `en` complete and primary.

## Architecture

- **Moo + `namespace::clean`** everywhere. No Moose, no Moose deps.
- **One module.** `lib/MCP/Picnic.pm` holds the whole server: the Moo attributes
  (`user`, `pass`, `country`, `picnic`, `json`, `server`, `_auth_state`), the `_build_server`
  tool registry, the `_*_to_hash` projection helpers and `run_stdio`.
- **MCP layer via `MCP::Server`.** Register every capability with `$server->tool(...)` inside
  `_build_server`. The handler is `code => sub { my ($tool, $args) = @_; ... }` where `$tool`
  is the **`MCP::Tool`** instance — NOT `MCP::Picnic`. Reach the server object through `$self`
  captured from the enclosing closure. Return through the tool: `$tool->text_result($text)` on
  success, `$tool->text_result($text, 1)` on error (the `is_error` flag). `MCP::Tool` auto-wraps
  a bare string return but drops the error flag, so always call `text_result` explicitly.
- **Backend via `WWW::Picnic` only.** Nothing else talks to the Picnic service. Wrap every
  `WWW::Picnic` call in `eval` and turn failures into a returned error message, never an
  uncaught die.
- **Auth gate.** Every tool except `verify_2fa` calls `$self->_ensure_auth` first and returns
  the gate's message when it is blocked. `_auth_state` is a three-state machine:
  `none` → `pending_2fa` → `authenticated`. Login is lazy and automatic on first use; 2FA is
  driven interactively through the `verify_2fa` tool.
- **Entity projection.** Map `WWW::Picnic` objects through a small `_*_to_hash` helper before
  encoding. Encode with `_to_json` (the shared `JSON::MaybeXS` encoder: `utf8`, `canonical`,
  `convert_blessed`). Only expose fields that have a real consumer.
- **Three entry points, all kept working:** `bin/mcp-picnic` (stdio, for Claude Desktop),
  `bin/mcp-picnic-http` (Mojolicious: `/mcp` MCP endpoint + REST), `bin/mcp-picnic-setup`
  (interactive config wizard).

## Versioning — version lives in the single module

`our $VERSION` belongs in `lib/MCP/Picnic.pm` and nowhere else (there are no sibling modules).
The `bin/` scripts read `$MCP::Picnic::VERSION`. Never hand-edit a version line — `[@Author::GETTY]`
owns it.

## Changes

Add a bullet under `{{$NEXT}}` in `Changes` in the SAME change as any user-facing addition
(new tool, new parameter, behaviour change, bug fix). Two-space indent, `  - ` bullets,
present tense. Never hand-edit the version line.

## Release — never without permission

`dzil build` / `dzil test` are fine anytime. `dzil release` and any CPAN upload are STRICTLY
forbidden without the maintainer's explicit go-ahead — even if a plan lists "release" as the
next step. For anything heading toward release: stop and ask. Use the `picnic-release-checker`
agent for the pre-release audit.
