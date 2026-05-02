# 8th-Layer.ai — Claude Code plugin marketplace

> **The Network is the Knowledge.** Layer 8 of the OSI model — the Semantic Knowledge Layer for agent fleets.

This is the federated [Claude Code plugin marketplace](https://code.claude.com/docs/en/plugin-marketplaces) for [8th-Layer.ai](https://github.com/OneZero1ai/8th-layer). Customer admins add this marketplace to their Claude Code; developers install the plugin from it; their Claude Code sessions then connect to their org's 8th-Layer.ai tenant.

## Install

The catalog is published two ways. Either works; the HTTP path is recommended for branded distribution:

```shell
# Recommended — branded HTTPS URL, served from our AWS CloudFront
/plugin marketplace add https://8thlayer.onezero1.ai/marketplace.json
/plugin install 8l-cq
```

```shell
# Alternative — git-clone from this repo
/plugin marketplace add OneZero1ai/8th-layer-marketplace
/plugin install 8l-cq
```

The plugin source is the **8th-Layer.ai agent** at [`OneZero1ai/8th-layer-agent`](https://github.com/OneZero1ai/8th-layer-agent) — our fork of [Mozilla.AI's cq](https://github.com/mozilla-ai/cq) (Apache-2.0). The plugin retains cq's name (`cq`) for protocol clarity; the marketplace name (`8th-layer`) reflects our brand. Per the [fork delta](https://github.com/OneZero1ai/8th-layer-agent/blob/main/FORK_DELTA.md), the fork adds enterprise execution capabilities (AIGRP client-side routing, DID-KMS bridge, multi-tenancy hooks) but keeps cq's protocol, schema, and DID model unchanged.

Verify install with `/plugin` (look under the **Installed** tab).

## Enterprise lockdown via managed settings

Customer IT can centrally provision and lock the 8th-Layer.ai agent on all developer Claude Code installs by deploying this `managed-settings.json` snippet via MDM (per [Claude Code's managed-settings docs](https://code.claude.com/docs/en/settings#settings-files)):

```json
{
  "extraKnownMarketplaces": {
    "8th-layer": {
      "source": { "source": "github", "repo": "OneZero1ai/8th-layer-marketplace", "ref": "stable" }
    }
  },
  "enabledPlugins": {
    "8l-cq@8th-layer": true
  },
  "strictKnownMarketplaces": [
    { "source": "github", "repo": "OneZero1ai/8th-layer-marketplace" }
  ],
  "env": {
    "CQ_ADDR": "https://api.acme-tenant.8th-layer.acme.com/cq",
    "CQ_API_KEY": "<per-user provisioned via SCIM or admin grant>"
  }
}
```

Result: every developer's Claude Code starts pre-configured with the 8th-Layer.ai agent installed and locked to your tenant. Zero per-user friction.

## Channels (planned)

Two release channels will ship as separate refs in this repo:

| Branch  | Audience                            | Pinning      |
|---------|-------------------------------------|--------------|
| `stable`| Default for production customers    | Tagged SHA   |
| `latest`| Early-access / 8th-Layer.ai internal | `main` HEAD  |

For initial development, only `main` exists; customers point at `main` until V1 ships and `stable` is established.

## How this marketplace works

This is a **federated** marketplace — no Anthropic registration or approval required. Anyone can host a marketplace; we host this one. Customers who add it are pulling from `OneZero1ai/8th-layer-marketplace` directly via Claude Code's git-clone marketplace mechanism.

In parallel, we will also submit the agent plugin to the [official Anthropic marketplace](https://claude.com/plugins) ([submit form](https://claude.ai/settings/plugins/submit)) so it appears in the auto-installed `claude-plugins-official` catalog. Both paths are complementary — enterprise customers with MDM use this marketplace; mid-market and individual users discover us via the official marketplace.

See [`docs/decisions/04-connector-distribution.md`](https://github.com/OneZero1ai/8th-layer/blob/main/docs/decisions/04-connector-distribution.md) and [`docs/decisions/08-agent-side-fork.md`](https://github.com/OneZero1ai/8th-layer/blob/main/docs/decisions/08-agent-side-fork.md) in the main repo for the distribution + fork strategy.

## What's in the agent

The 8th-Layer.ai agent is a fork of Mozilla.AI's cq plugin, branded for enterprise deployment. From upstream cq it inherits:

- **MCP tools** matching cq's standard verbs: `query`, `propose`, `confirm`, `flag`, `reflect`, `status`, `health`
- **Slash commands** in the `cq:` namespace
- **Skills** for session knowledge mining
- **Lifecycle hooks** (sessionStart, postToolUse, postToolUseFailure, stop)
- **KERI/DID identity model** in unit `provenance`

What our fork adds (per [`FORK_DELTA.md`](https://github.com/OneZero1ai/8th-layer-agent/blob/main/FORK_DELTA.md) — landing incrementally):

- **AIGRP client-side routing** — distributed by design from V1
- **DID-KMS bridge** — Persona's KMS public key derives the proposer DID
- **Multi-tenancy hooks** — agent honors tenant + enterprise + team scope from the JWT context
- **Cross-trust-boundary routing** — agent identifies cross-team / cross-enterprise queries and routes them through the tenant Remote for consent enforcement

The agent works with vanilla cq remotes (drop-in compatibility). 8th-Layer.ai-specific capabilities activate when paired with an 8th-Layer.ai tenant Remote.

## Repository

- This repo: `OneZero1ai/8th-layer-marketplace` — just the marketplace catalog. Small.
- Agent fork: `OneZero1ai/8th-layer-agent` — fork of Mozilla.AI's cq.
- Main repo: `OneZero1ai/8th-layer` — tenant code, decision docs, specs, vision.

## License

Apache-2.0 (inherited from cq upstream).
