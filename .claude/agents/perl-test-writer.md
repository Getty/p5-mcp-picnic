---
name: perl-test-writer
description: "Write tests for MCP::Picnic. Network-free: cover module load, tool registration and the auth state machine without hitting the real Picnic API. Use when adding or extending test coverage."
allowed-tools: Read, Grep, Glob, Edit, Bash
briefing:
  skills:
    - getty-perl-core
    - perl-mcp
---

You write tests for **MCP::Picnic**.

Hard rule: **tests must be network-free.** Never hit the real Picnic API or send real 2FA
SMS in `t/`. Exercise the parts that don't need network:
- **`t/load.t`** — `use_ok` for `MCP::Picnic`. Keep it green; this is the smoke test.
- **Tool registration** — construct `MCP::Picnic->new` with dummy `PICNIC_USER`/`PICNIC_PASS`
  and assert `$mcp->server` builds and exposes every expected tool name.
- **Auth state machine** — drive `_auth_state` (`none` → `pending_2fa` → `authenticated`)
  and assert `_ensure_auth` returns the right gate (error hash vs. `1`) for each state.
- **`_*_to_hash` helpers** — feed a hand-built object/blessed stub mirroring the `WWW::Picnic`
  entity shape and assert the projected hash.

To exercise tool code without a network, stub the `picnic` attribute (pass a mock object, or
`local *WWW::Picnic::method = sub {...}`) and capture what each tool would call. Construction
reads `PICNIC_USER`/`PICNIC_PASS` lazily, so set them in `%ENV` or pass `user`/`pass` directly.

Run `prove -lv t/<file>.t` and fix until green. Apply the loaded skills silently.
