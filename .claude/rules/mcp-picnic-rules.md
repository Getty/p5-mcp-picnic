# MCP::Picnic House Rules

The shared house rules come from skilletor — bundle `getty-cpan-dist@getty`: engineering
discipline, the delegation lock, the publish gate, karr coordination, CPAN release. They load
as `.claude/rules/.local.*.md`; if they are missing, run `skilletor sync` and publish nothing
until they load. This file adds what is true only here, and wins where it differs.

## What this repo is

MCP server for the Picnic supermarket API. Read first: before adding a tool, `_build_server`
and an existing `$server->tool(...)` block plus its `_*_to_hash` helper — they are the
template; conform.

## Agent team

| Task | Agent |
|---|---|
| Implement / refactor / debug behavior-relevant code | `mcp-picnic-worker` (default) |
| Write / extend tests | `mcp-picnic-test-writer` |
| Write or improve POD | `mcp-picnic-pod-writer` |
| Commits, `Changes`, card → done, pre-release audit | `mcp-picnic-release-manager` |
| Read-only research, audit, gap analysis | `mcp-picnic-worker` ("read-only, change nothing") |

Behavior-relevant = the tool registry in `_build_server`, the `_ensure_auth`/2FA state
machine, `WWW::Picnic` delegation, the `_*_to_hash` projections, JSON encoding, the three
`bin/` entry points, tests. Pure prose docs and `Changes` notes are not.

## Hazards

- **English only in shipped strings.** All POD, MCP tool `description`s, result messages and
  error text are English — this ships to CPAN and to assistants worldwide. The one exception
  is `bin/mcp-picnic-setup`, which has an `en`/`de` translation table; keep `en` complete and
  primary. (The historic 0.001 code carried German prose — new and edited code is English.)
- **`$self` vs `$tool` in handlers.** A tool handler's first arg is the `MCP::Tool` instance,
  NOT `MCP::Picnic`; `$self` comes from the enclosing closure. A green test suite does not
  catch a handler that rebinds `$self` and only breaks against the live API.
- **Tests must stay network-free.** Never hit the real Picnic API or send a real 2FA SMS from
  `t/`. Stub the `picnic` attribute; drive `_auth_state` directly.
- **Version lives in one place.** `our $VERSION` is only in `lib/MCP/Picnic.pm` (no sibling
  modules); `bin/` reads `$MCP::Picnic::VERSION`. Never hand-edit a version line —
  `[@Author::GETTY]` owns it.

## Perl / architecture specifics — reference, don't restate

Moo patterns, the tool-handler shape, the auth/2FA gate, `WWW::Picnic` delegation and the
`_*_to_hash` projection convention live in skill `mcp-picnic-core`; generic MCP::Server
mechanics in `perl-mcp`; house Perl style in `getty-perl-core` / `getty-perl-moo`; the
build/POD/release workflow in `getty-perl-release-author-getty` / `perl-release-dist-ini`.
All force-loaded for `mcp-picnic-*` agents.
