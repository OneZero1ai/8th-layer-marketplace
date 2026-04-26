# 8th-Layer.ai — Claude Code plugin marketplace

> **The Network is the Knowledge.** Layer 8 of the OSI model — the Semantic Knowledge Layer for agent fleets.

This is the [federated Claude Code plugin marketplace](https://code.claude.com/docs/en/plugin-marketplaces) for [8th-Layer.ai](https://github.com/OneZero1ai/8th-layer). Customer admins add this marketplace to their Claude Code; developers install the `8th-layer` plugin from it; their Claude Code sessions then connect to their org's 8th-Layer.ai tenant.

## Install

```shell
/plugin marketplace add OneZero1ai/8th-layer-marketplace
/plugin install 8th-layer@8th-layer
```

Verify with `/plugin` and look under the **Installed** tab.

## Enterprise lockdown via managed settings

Customer IT can centrally provision and lock the 8th-Layer.ai connector to all developer Claude Code installs by deploying this `managed-settings.json` snippet via MDM (per [Claude Code's managed-settings docs](https://code.claude.com/docs/en/settings#settings-files)):

```json
{
  "extraKnownMarketplaces": {
    "8th-layer": {
      "source": { "source": "github", "repo": "OneZero1ai/8th-layer-marketplace", "ref": "stable" }
    }
  },
  "enabledPlugins": {
    "8th-layer@8th-layer": true
  },
  "strictKnownMarketplaces": [
    { "source": "github", "repo": "OneZero1ai/8th-layer-marketplace" }
  ],
  "env": {
    "CROSSTALK_TENANT_URL": "https://api.acme-tenant.8th-layer.acme.com",
    "CROSSTALK_CLAIM_ID": "<per-user provisioned via SCIM or admin grant>"
  }
}
```

Result: every developer's Claude Code starts pre-configured with 8th-Layer.ai installed and locked to your tenant. Zero per-user friction.

## Channels (planned)

Two release channels will ship as separate refs in this repo:

| Branch  | Audience                            | Pinning      |
|---------|-------------------------------------|--------------|
| `stable`| Default for production customers    | Tagged SHA   |
| `latest`| Early-access / 8th-Layer.ai internal | `main` HEAD  |

For initial development, only `main` exists; customers point at `main` until V1 ships and `stable` is established.

## How this marketplace works

This is a **federated** marketplace — no Anthropic registration or approval required. Anyone can host a marketplace; we host this one. Customers who add it are pulling from `OneZero1ai/8th-layer-marketplace` directly via Claude Code's git-clone marketplace mechanism.

In parallel, we will also submit the `8th-layer` plugin to the [official Anthropic marketplace](https://claude.com/plugins) ([submit form](https://claude.ai/settings/plugins/submit)) so it appears in the auto-installed `claude-plugins-official` catalog. Both paths are complementary — enterprise customers with MDM use this marketplace; mid-market and individual users discover us via the official marketplace.

See [`docs/decisions/04-connector-distribution.md`](https://github.com/OneZero1ai/8th-layer/blob/main/docs/decisions/04-connector-distribution.md) in the main repo for the full distribution strategy.

## What's in the plugin

The `8th-layer` plugin (Claude Code MCP plugin built from [`connectors/claude-code/`](https://github.com/OneZero1ai/8th-layer/blob/main/docs/specs/connector-claude-code.md) in the main repo) exposes:

- **MCP tools**: `crosstalk_send`, `crosstalk_reply`, `crosstalk_group`, `crosstalk_help`, `crosstalk_find_expert`, `crosstalk_inbox`, `crosstalk_threads`, `crosstalk_close_thread`, `crosstalk_read`, `crosstalk_agents`
- **Slash commands**: `/cx-send`, `/cx-find-expert`, `/cx-inbox`, `/cx-help`
- **Skills**: `crosstalk-share-thread`, `crosstalk-summarize-inbox`, `crosstalk-find-expert`
- **Hooks**: `SessionEnd` hook to propose resolved threads to the 8th-Layer.ai cq layer for cross-team reuse

The connector is a thin client/router shim. All load-bearing logic (signing, audit, FIPS posture, cq publishing, routing) lives on the customer's 8th-Layer.ai tenant API. The connector carries only a JWT, the tenant URL, and harness UX glue.

## Status

V1 ship pending. Marketplace repo and plugin manifest in place; the connector code at [`connectors/claude-code/`](https://github.com/OneZero1ai/8th-layer/tree/main/connectors/claude-code) lands with V1 implementation work.

## Repository

This repo: `OneZero1ai/8th-layer-marketplace` — just the marketplace catalog. Small.

Main repo: `OneZero1ai/8th-layer` — tenant code, connectors, decision docs, specs, vision.

## License

Apache-2.0.
