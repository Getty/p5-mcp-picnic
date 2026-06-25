# MCP-Picnic

[![CPAN Version](https://img.shields.io/cpan/v/MCP-Picnic.svg)](https://metacpan.org/pod/MCP::Picnic)
[![License](https://img.shields.io/cpan/l/MCP-Picnic.svg)](https://metacpan.org/pod/MCP::Picnic)

An [MCP](https://modelcontextprotocol.io) (Model Context Protocol) server that gives AI
assistants such as [Claude](https://claude.ai) access to the
[Picnic](https://picnic.app) online supermarket. A lightweight
[Moo](https://metacpan.org/pod/Moo) server built on
[MCP::Server](https://metacpan.org/pod/MCP::Server), wrapping the
[WWW::Picnic](https://metacpan.org/pod/WWW::Picnic) API client. Search products, manage
your cart, pick a delivery slot and check out — by asking your assistant. Picnic's SMS
two-factor login is handled interactively, in the conversation.

## Installation

```bash
cpanm MCP::Picnic
```

## Quick start

The fastest way to wire the server into your MCP client is the bundled setup wizard. It
detects installed clients (Claude Desktop, Claude Code, VS Code, Cursor, Windsurf), asks
for your Picnic credentials and writes the configuration for you:

```bash
mcp-picnic-setup
```

Then restart your client and ask it something like *"show me my Picnic cart"*. On first
use the server logs in automatically; if Picnic requires 2FA it sends an SMS and asks you
for the code (see [Authentication](#authentication)).

## Manual configuration

To configure a client by hand, point it at the `mcp-picnic` command and pass your
credentials as environment variables. For Claude Desktop:

```json
{
  "mcpServers": {
    "picnic": {
      "command": "mcp-picnic",
      "env": {
        "PICNIC_USER": "you@email.de",
        "PICNIC_PASS": "your-password",
        "PICNIC_COUNTRY": "de"
      }
    }
  }
}
```

## Authentication

Picnic often requires two-factor authentication by SMS. The server handles this
interactively, so no out-of-band setup is needed:

1. On the first request a login is attempted automatically.
2. If 2FA is required, Picnic sends an SMS to your phone.
3. The assistant asks you for the code.
4. You provide it; the assistant calls the `verify_2fa` tool.
5. Every further request works normally for the rest of the session.

Credentials come from the environment: `PICNIC_USER`, `PICNIC_PASS` and `PICNIC_COUNTRY`
(`de` for Germany or `nl` for the Netherlands; defaults to `de`).

## Tools

| Tool | What it does |
|------|--------------|
| `search_products`     | Search for products; returns name, price and ID |
| `get_product_details` | Full details for one product ID |
| `get_suggestions`     | Autocomplete suggestions for a partial term |
| `get_cart`            | Current cart: items, total price, selected slot |
| `add_to_cart`         | Add a product (optional `count`) |
| `remove_from_cart`    | Remove a product (optional `count`) |
| `clear_cart`          | Empty the entire cart |
| `get_delivery_slots`  | Available delivery time windows |
| `set_delivery_slot`   | Select a delivery slot |
| `get_user`            | Profile of the logged-in user |
| `get_categories`      | The shop's product categories |
| `verify_2fa`          | Submit the SMS code during 2FA login |

## Entry points

The distribution ships three executables:

| Command | Purpose |
|---------|---------|
| `mcp-picnic`       | stdio MCP server — for Claude Desktop and other local MCP clients |
| `mcp-picnic-http`  | [Mojolicious](https://mojolicious.org) server: an `/mcp` MCP endpoint plus a REST API and an OpenAPI spec (for ChatGPT Actions) |
| `mcp-picnic-setup` | interactive wizard that writes the MCP client configuration |

Run the HTTP server with:

```bash
mcp-picnic-http daemon -l http://*:3000
```

## See also

- [MCP::Server](https://metacpan.org/pod/MCP::Server) — the MCP server framework
- [WWW::Picnic](https://metacpan.org/pod/WWW::Picnic) — the Picnic API client this wraps
- [Picnic](https://picnic.app) — the supermarket
- [Model Context Protocol](https://modelcontextprotocol.io)

## License

This software is copyright (c) 2026 by Torsten Raudssus. It is free software and may be
redistributed under the same terms as Perl itself.
