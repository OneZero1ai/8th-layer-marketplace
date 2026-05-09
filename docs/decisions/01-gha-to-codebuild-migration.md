# GHA → CodeBuild + CodeStar Connection migration (design)

**Author**: 8th-Layer.ai cofounder agent
**Date**: 2026-05-08
**Status**: Design pass — no infra created. Awaiting operator approval before cut.
**Repo**: `OneZero1ai/8th-layer-marketplace` (this repo).
**Siblings**:
- `OneZero1ai/8th-layer-agent/docs/decisions/13-gha-to-codebuild-migration.md` — agent repo, 14 CI/release workflows. The playbook origin.
- `OneZero1ai/8th-layer-marketing-website/docs/decisions/01-gha-to-codebuild-migration.md` — marketing-website, single-deploy-workflow case. The directly applicable shape for this repo (S3 + CloudFront, single project, IAM trust swap).

**AWS account**: `8th-layer-app` profile, `124074140789`, `us-east-1`. The same blank-slate account #13 and the marketing-website doc snapshotted (`codestar-connections list-connections` → `[]`, `codebuild list-projects` → `[]`).

Read #13 for the playbook fundamentals (CodeStar Connection model, IAM service-role pattern, dual-trust cutover); read the marketing-website doc for the S3+CloudFront single-deploy mechanics. This doc focuses on what's *different* here: the catalog is read by every Claude Code session that runs `/plugin install 8l-cq`, fleet-wide. A bad publish locks every developer out of `/plugin marketplace add`. That changes the canary, the rollback, and the testing surface — but not the underlying executor mechanics.

---

## Why we're doing this

Same two operator-set reasons as #13 and the marketing-website doc:

1. Avoid GitHub-as-pipeline dependency (`feedback_avoid_github_dependencies.md`). Code stays on GitHub; only the runner moves.
2. Standardise on AWS-native CI so the IL/CMMC story later is "the pipeline is in our boundary."

Out of scope: changing the catalog format, moving the agent repo, restructuring the bucket. **Only the executor changes** — and in this repo's case, "the executor" today is *the operator's laptop* running `bash scripts/publish.sh`. The forward arrow goes manual-script → CodeBuild, not GHA → CodeBuild.

The repo briefly *had* a GHA workflow — `.github/workflows/deploy-pages.yml`, retired in `c3ef37b` (2026-05-01) when the catalog moved off GitHub Pages onto our own CloudFront. The retirement commit explicitly flagged this migration: *"the S3-hosted copy is updated separately when the catalog changes (will be automated via Action targeting the 8th-layer-app S3 bucket later)."* This doc is the "later" decision, with the executor target switched from GHA to CodeBuild to stay consistent with #13 and the marketing-website doc.

---

## Workflow inventory (0 active GHA, 1 manual script)

There is no active `.github/workflows/` directory. The catalog is published by **`scripts/publish.sh`** — 50 lines of bash, run by the operator from a laptop. The script:

1. Reads `.claude-plugin/marketplace.json` (the source of truth — also consumed by Claude Code's git-clone install path).
2. Validates it's parseable JSON. (A broken catalog locks every customer's `/plugin marketplace add` until republished — the script's existing comment calls this out explicitly.)
3. `aws s3 cp` to `s3://8l-web-site-us-east-1-124074140789/marketplace.json` with `content-type: application/json` and `cache-control: public, max-age=300`.
4. `aws cloudfront create-invalidation` on distribution `EEUW0F2ICYKFQ` for `/marketplace.json`.
5. Prints the invalidation ID; live in ~30s.

That's the entire deploy surface. **No tarballs are bundled.** The `8l-cq` plugin's `source` field in `marketplace.json` is `git-subdir` pointing at `https://github.com/OneZero1ai/8th-layer-agent.git`, `path: plugins/cq`, `ref: main` — Claude Code clones the agent repo at install time and pulls the plugin from a subdirectory. The marketplace publish step ships *only* the JSON pointer file. The plugin's actual binary surface lives in the agent repo and rides #13's pipeline.

This matters for the canary design below: byte-equivalence testing only needs to compare a single ~1.3KB JSON file, not a tarball tree. That's a much easier validation surface than the marketing-website's `dist/` (hundreds of files, hash-divergent build outputs are a real risk).

The current bucket and distribution are confirmed in `scripts/publish.sh`:

- S3 bucket: `8l-web-site-us-east-1-124074140789` (same bucket as the marketing-website — co-resident)
- Object key: `marketplace.json` (root of the bucket, served at `https://8thlayer.onezero1.ai/marketplace.json`)
- CloudFront distribution: `EEUW0F2ICYKFQ` (same as marketing-website's brand distro)

The bucket co-residency with the marketing-website is significant: **two CodeBuild projects (this one and the marketing-website's) will eventually write to the same S3 bucket.** The marketing-website CodeBuild syncs `dist/` with `--delete --exclude "coming-soon/*"`. If that exclude list doesn't *also* exclude `marketplace.json`, the marketing-website deploy will silently nuke the catalog on every publish. Open question for the operator below; this is the single most important coordination point with the marketing-website migration.

---

## CodeStar Connection setup

Same singleton story as #13 and the marketing-website doc. One **GitHub** connection per AWS account is sufficient — host-level App install, not per-repo. Whichever sibling migration lands first creates the connection; this one just adds the marketplace repo to the App's granted-repos list on the GitHub side. No new connection ARN needed.

Cross-cutting reuse from the siblings:

- **Connection ARN**: same one, three repos behind it (`8th-layer-agent`, `8th-layer-marketing-website`, this repo).
- **Operator GitHub-App grant**: one ceremony covers all three. Operator opens the AWS Connector for GitHub App on the `OneZero1ai` org and adds the marketplace repo when ready.

Reference: <https://docs.aws.amazon.com/dtconsole/latest/userguide/connections-create-github.html>

---

## CodeBuild project shape

**Recommendation: one CodeBuild project, single buildspec.** Mirrors the marketing-website doc's logic:

1. **It's effectively one workflow** — one trigger (push to `main` touching the catalog), one linear shell script. No DAG, no matrix. CodeBuild's `phases:` section renders it cleanly.
2. **Trivial environment** — `aws/codebuild/standard:7.0` (Python 3 for JSON validation, AWS CLI v2 already present). No Node, no Go, no Docker. The build image is grossly overprovisioned for the work; that's fine — we use the same image as the marketing-website project for cache-warmth and image consistency.
3. **No batch builds** — there's nothing to fan out.

Buildspec sketch (not committed — design only):

```yaml
version: 0.2
phases:
  pre_build:
    commands:
      - python3 -c "import json,sys; json.load(open('.claude-plugin/marketplace.json'))"
      - python3 scripts/validate-catalog.py .claude-plugin/marketplace.json   # see Validation section
  build:
    commands:
      - cp .claude-plugin/marketplace.json /tmp/marketplace.json.candidate
      - aws s3api head-object --bucket 8l-web-site-us-east-1-124074140789 --key marketplace.json --query 'ETag' > /tmp/previous.etag || true
      - aws s3 cp s3://8l-web-site-us-east-1-124074140789/marketplace.json /tmp/marketplace.json.previous || true
  post_build:
    commands:
      - aws s3 cp /tmp/marketplace.json.candidate s3://8l-web-site-us-east-1-124074140789/${TARGET_KEY} --content-type "application/json" --cache-control "public, max-age=300"
      - aws cloudfront create-invalidation --distribution-id EEUW0F2ICYKFQ --paths "/${TARGET_KEY}"
artifacts:
  files:
    - /tmp/marketplace.json.previous
    - /tmp/marketplace.json.candidate
  discard-paths: yes
```

`TARGET_KEY` is a CodeBuild env-var defaulting to `marketplace-canary.json` (canary mode) and flipped to `marketplace.json` on cutover (production mode) — see canary section below. Pinning this to an env-var avoids the buildspec needing a PR to switch modes; the operator flips a single CodeBuild project setting.

The artifacts upload of *previous* + *candidate* gives us a forensic trail: any deploy's prior catalog is retrievable from S3 build artifacts indefinitely. This earns its keep in the rollback story.

---

## Trigger semantics

GHA equivalent today: none active. Forward target:

- **Push to `main`** with a path filter on `.claude-plugin/marketplace.json` — `WebhookFilterGroup` with `EVENT = PUSH`, `HEAD_REF = ^refs/heads/main$`, and `FILE_PATH = ^\\.claude-plugin/marketplace\\.json$`. Same shape as #13's path filters; the JSON-only filter prevents the project running on README-only commits.
- **Manual deploy** — `aws codebuild start-build --project-name 8l-marketplace-deploy`. Same UX question as #13 and the marketing-website doc raised: is `make publish` wrapping the AWS CLI acceptable, or do we want a UI surface? Recommendation: `make publish` for V1, consistent answer across all three repos.

There is no PR-build requirement — the catalog is a single JSON file, validated locally via `python3 -c "import json"` and `make publish --dry-run`. PR-time validation can be a tiny GHA workflow (lint-only, no AWS perms) if we want it, but that's a separate decision; the migration target here is the *deploy* path.

---

## IAM migration

There is **no current GHA OIDC role** to migrate from — the operator runs `scripts/publish.sh` with their `8th-layer-app` profile credentials directly. The IAM design is therefore greenfield: we create a service role from scratch.

Two patterns, mirroring the marketing-website doc:

### Pattern A: Single CodeBuild service role with inline S3+CloudFront perms

`8l-marketplace-deploy-codebuild-service-role` with `codebuild.amazonaws.com` trust + base perms (`logs:*` + `codestar-connections:UseConnection`) + the deploy-target perms inline (`s3:PutObject`/`s3:GetObject`/`s3:HeadObject` on `arn:aws:s3:::8l-web-site-us-east-1-124074140789/marketplace*.json`, `cloudfront:CreateInvalidation` on the distro ARN).

**Pro**: One role, simplest possible shape. Marketplace publish is small enough that a separate deploy-target role is over-engineered.
**Con**: No identity stability if a future executor wants the same perms. (Less of an issue here than for the marketing-website case — marketplace deploy will probably never have a second executor.)

### Pattern B: Service role + separate deploy-target role (`marketplace-deployer`)

`8l-marketplace-deploy-codebuild-service-role` (CodeBuild trust + base perms + `sts:AssumeRole` on a deploy-target role) **plus** `marketplace-deployer` (assume-by-CodeBuild-service-role trust + the inline S3/CloudFront perms).

**Pro**: Mirrors the marketing-website's chosen shape (Pattern B in that doc), keeps deploy-target identity stable for any future executor.
**Con**: Marginal complexity over Pattern A; one extra IAM role for a workflow that may never gain a second executor.

**Recommendation: Pattern B** for cross-repo consistency with the marketing-website doc. Same shape across all three migrations means future-DJ inheriting the account in 6 months sees one consistent IAM idiom. The marginal complexity is real but small (one extra resource), and the consistency is worth it.

The S3 IAM scope is *narrower* than the marketing-website's. Marketing-website's role gets `s3:PutObject` on the bucket; this one gets `s3:PutObject` on **`marketplace*.json` only** (note the glob — covers both `marketplace.json` and `marketplace-canary.json` and any future `marketplace-YYYY-MM.json` versioned copies; see canary section). Two separate narrowly-scoped roles writing to the same bucket is preferable to one fat role; if either is compromised it can only deface its own surface.

The CloudFront `CreateInvalidation` perm is also narrower: `marketplace*.json` paths only, not `/*`. This prevents a compromised marketplace-deploy role from invalidating the marketing-website's content (which would force a paid CloudFront cache rebuild).

---

## Canary strategy — the load-bearing piece

**The fleet-impact problem.** Every Claude Code session running `/plugin install 8l-cq` reads `https://8thlayer.onezero1.ai/marketplace.json`. A malformed catalog, a broken `git-subdir` pointer, or a truncated upload locks every developer out of new installs and breaks reinstalls. We can't ship the new pipeline by writing to the same path the fleet reads from until we have byte-level confidence.

The marketing-website's canary-prefix approach (write to `_codebuild-canary/`, compare, then flip) does *not* directly translate, because clients fetch a fixed path — `marketplace.json`, not `_codebuild-canary/marketplace.json`. The fleet is configured for the canonical URL. Three viable canary mechanics, ranked:

### Recommended: blue/green via separate canary key (`marketplace-canary.json`)

CodeBuild publishes to `marketplace.json` *and* (by default during Week 0) `marketplace-canary.json` — two separate S3 keys, two separate CloudFront paths, both invalidated. Operator and a small set of opt-in fleet probes point at the canary URL during Week 0; the broad fleet keeps reading the canonical key (which the manual `scripts/publish.sh` continues to update — dual-publish during cutover).

Once the canary key tracks the manual publish for at least 5 catalog updates with byte-identical content (`aws s3api head-object` ETag match, plus a SHA-256 spot check), Week 1 flips the buildspec's `TARGET_KEY` env var from `marketplace-canary.json` to `marketplace.json`. CodeBuild becomes the production publisher; the manual script gets shelved (kept in the repo for break-glass) but no longer used routinely.

**Why this beats the alternatives:**
- **Real fleet exercise** — the canary URL can be hit by a small set of designated dev/internal sessions (`/plugin marketplace add https://8thlayer.onezero1.ai/marketplace-canary.json`). Synthetic probes from the Strands probe fleet can validate fetch + parse + plugin-install end-to-end without touching production sessions.
- **No path change for the fleet on cutover** — the canonical URL never moves. A bad CodeBuild publish in Week 0 only breaks opt-in canary URLs; production sessions are insulated.
- **Single env-var flip** — Week 0 → Week 1 is a CodeBuild project-config change, not a buildspec PR. Operator self-service.
- **Clean rollback** — see below; rollback is "set `TARGET_KEY` back to `marketplace-canary.json` and re-publish previous content to `marketplace.json` from the artifact trail."

### Alternative 1: Per-version tagged URLs (`marketplace-2026-05.json`)

CodeBuild publishes a versioned key (`marketplace-YYYY-MM.json`) and updates `marketplace.json` to be a copy. Fleet operators who want pinning can point at the versioned URL; the unpinned default tracks the latest. This is *additive* to the canary approach — useful for V2 once the catalog has multiple competing customers, but doesn't solve the Week-0 confidence problem on its own. **Recommend layering on later**, not as the primary canary mechanic.

### Alternative 2: Feature-flagged client read

Push the canary semantic into the plugin/client by having the agent read a config that selects between `marketplace.json` and `marketplace-canary.json`. Adds new code, requires fleet-wide config rollout, defeats the point of moving fast. Reject.

**Recommended canary mechanic: blue/green via separate canary key** with a small operator-controlled opt-in canary URL during Week 0. Synthetic probe validation from Strands. Cutover is a single CodeBuild env-var flip.

---

## Validation — the byte-equivalence check

Before flipping `TARGET_KEY` to `marketplace.json` in Week 1, we need byte-equivalence proof that what CodeBuild produces matches what the manual script produces. Concretely:

1. After every CodeBuild Week-0 build, fetch both S3 keys and SHA-256 them: `aws s3api head-object` ETag match is the cheap path; full content hash is the certain one.
2. Track at least **5 consecutive matches** across actual catalog edits (not just no-op rebuilds — the test is "does the new pipeline produce the same bytes when both pipelines run on the same source?").
3. Force one *failing* CodeBuild build (e.g. inject malformed JSON in a feature branch, run `start-build`) to verify the validation step actually fails out before the S3 write happens. Catalog-corruption is the failure mode this catches.

A `scripts/validate-catalog.py` helper (referenced in the buildspec sketch) does deeper-than-`json.load` validation: schema check, every plugin's `source.url` resolves (HTTP HEAD), every `ref` exists in the agent repo (GraphQL ref lookup). This earns its keep — a `git-subdir` pointer to a non-existent ref breaks installs as silently as a malformed JSON file would, and `json.load` won't catch it.

---

## Rollback plan — fast because fleet-impact

Three rollback shapes, ordered by speed:

1. **CodeBuild misfires during Week 0 (canary-only)**. Impact: opt-in canary URL is broken. No production impact. Fix in a follow-up build, no rollback needed. The blast radius of Week-0 errors is bounded by design.

2. **CodeBuild misfires after Week 1 cutover**. Impact: production catalog is corrupted; every `/plugin install 8l-cq` fleet-wide is broken until we fix it. **Fast revert** is a single `make rollback` (or `aws codebuild start-build --project-name 8l-marketplace-rollback`) that:
   - Reads the prior catalog from the previous build's artifacts (the buildspec's artifact-upload of `marketplace.json.previous`).
   - `aws s3 cp` it back to `marketplace.json`.
   - `aws cloudfront create-invalidation` on `/marketplace.json`.
   - Total time: <60s, dominated by CloudFront invalidation propagation.

   This is faster than re-running the manual script (which requires the operator at a laptop with credentials), and is automatable from the AWS console if needed. The rollback CodeBuild project is a sibling of the deploy project, identical config except the buildspec, and can be created in the same CFN stack.

3. **Catastrophic rollback** (CodeBuild itself is unavailable, or the entire project state is corrupt). Manual `bash scripts/publish.sh` from the operator's laptop, against a known-good catalog from `git log`. The script stays in the repo for break-glass; this is the operational equivalent of "keep the screwdriver in the toolbox after you've installed the power tool."

S3 versioning on the bucket is another safety net (the marketing-website doc didn't cover this; worth confirming the bucket has versioning enabled — open question below). With versioning, `aws s3api list-object-versions --prefix marketplace.json` gives an indefinite history of every published catalog, restorable in one CLI call. **Recommend explicitly enabling bucket versioning before cutover** if it's not already on. Cost is trivial (a few KB per catalog version × N publishes/month).

The single-command revert is realistic: the artifact trail makes "previous" a known-good byte string, not a guess from `git log`. This is faster than the marketing-website's rollback (which requires re-syncing a `dist/` tree) by virtue of being a single 1.3KB file.

---

## Estimate

Per `~/CLAUDE.md` house rule (no single-point estimates):

- **Naive**: 1d to write the buildspec + CFN/Terraform for the CodeBuild deploy project + sibling rollback project + Pattern B service role + `marketplace-deployer` deploy-target role + smoke-test on the canary key. Maybe 0.5d if the CFN module from #13/marketing-website is reusable.
- **Touch-points**: `buildspec.yaml` (deploy) + `buildspec-rollback.yaml` + `ci/codebuild.yaml` (CFN) + `8l-marketplace-deploy-codebuild-service-role` + `marketplace-deployer` + S3 versioning enable (CFN edit on the bucket — co-owned with marketing-website, coordination needed) + `--exclude marketplace.json` patch on the marketing-website CodeBuild buildspec (coordination!) + Strands probe config for canary URL + `make publish` / `make rollback` targets + this decision doc + cutover runbook in `docs/runbooks/` + GHA absence note in README. **~12 logical touch-points.** Above the >5-files threshold; ×2 multiplier applies.
- **Fleet-impact multiplier**: per the brief, fleet-impact testing earns the ×2 on top of the file-count multiplier. The "test" surface is "is `/plugin install 8l-cq` still working for every developer running Claude Code." The realistic test is the Strands probe fleet exercising canary + production URLs, plus a small set of manual `/plugin marketplace add` calls from operator and Dirk's machines. **Effective multiplier: ×3 over naive.**
- **Range**:
  - **Naive** (CFN module reusable, no surprises, marketing-website coordination painless): **3 dev-days** including dual-run setup and probe wiring.
  - **Realistic** (×2 — first attempt at the canary key gets ETag stability wrong; the marketing-website's `--exclude` patch needs a separate PR to that repo and an operator approval gate; S3 versioning enable surfaces a CloudFront cache-bypass quirk on first restoration test): **6 dev-days** ≈ 1.5 calendar weeks, accounting for cross-repo PR coordination and operator approval gates between Week 0 / Week 1 / Week 2.
  - **If unknowns hit** (×3 — synthetic probe fleet not yet wired for canary URL validation and we have to build that path; CodeBuild webhook path-filter regex behaves unexpectedly on the catalog-only filter; rollback artifact-trail mechanic doesn't survive a real cutover failure and we have to redesign): **9 dev-days** ≈ 2 calendar weeks.
- **Excluded**: cost-monitoring dashboard for marketplace-publish CI minutes, branch-protection coordination (n/a — no PR gates), runbook docs for the operator (`docs/runbooks/marketplace-cutover.md` — should exist before Week 1), post-cut audit that no CI minutes are charged elsewhere, FOIA-style retrospective on every catalog change during the cutover window.
- **Past calibration**: no prior CI migration in this repo. The closest reference is the GitHub Pages → CloudFront move (`c3ef37b`, 2026-05-01) — cert provisioning got stuck and the operator described it as "GitHub-as-a-dependency is a fragility we don't need." Same shape risk: the *infrastructure* is small, the *cross-boundary coordination* is what bites. Here the boundary is canary-vs-prod confidence during a window where the fleet is actively reading the catalog.

**Net: budget 6 dev-days, expect 9.** Don't promise <2 weeks externally. The fleet-impact testing surface is what earns the multiplier; rushing it is how every developer's Claude Code breaks at once.

---

## Open questions for the operator

1. **Bucket co-residency conflict.** The marketing-website CodeBuild syncs `dist/` with `--delete --exclude "coming-soon/*"` to the *same bucket* that hosts `marketplace.json`. If the marketing-website migration lands first and its buildspec doesn't *also* exclude `marketplace.json`, the marketing-website deploy will silently nuke the catalog on every publish. **Action needed:** patch the marketing-website buildspec to add `--exclude "marketplace*.json"` *before* either CodeBuild project goes live in production mode. Consider this a hard prerequisite for marketing-website Week 1 cutover, not just an open question. Recommend a paired PR: this repo's PR + a small follow-up PR on `8th-layer-marketing-website` to add the exclude.

2. **S3 bucket versioning.** Is versioning enabled on `8l-web-site-us-east-1-124074140789`? If not, recommend enabling it before cutover — the rollback story leans on versioned objects as a safety net, and storage cost for a JSON catalog is negligible. (`aws s3api get-bucket-versioning --bucket 8l-web-site-us-east-1-124074140789` will answer.)

3. **Pattern A vs Pattern B for IAM.** Recommendation is B for cross-repo consistency with the marketing-website doc. Confirm — A is simpler for this specific case (the marketplace deploy will probably never have a second executor); B is more durable. Same answer across all three migrations is the goal.

4. **Synthetic probe coverage for canary URL.** The Strands probe fleet exists but I don't know whether it's configured to fetch and validate `/plugin marketplace add` against a canary URL. If not, we either (a) wire that path before Week 0 (adds time to estimate), or (b) substitute manual operator+Dirk validation from two laptops as the canary signal (acceptable but lower confidence). Operator preference?

5. **Manual-trigger UX (consistent answer across migrations).** Same question as #13 and the marketing-website doc raised. CodeBuild's manual-trigger equivalent is `aws codebuild start-build` from CLI/console. Recommend `make publish` and `make rollback` Makefile targets in this repo wrapping the AWS CLI; consistent with the proposed `make deploy` for the marketing-website. Operator confirm?

6. **Catalog channels.** README mentions `stable` / `latest` as planned channels. If those land during the migration window, each becomes another `marketplace-<channel>.json` key with its own canary path. Recommend deferring channel infra until *after* the migration cuts — one moving piece at a time. Confirm timeline?

---

## Cross-cutting reuse from #13 and the marketing-website doc

When all three migrations land, the following are **shared** and should be specified once:

- **CodeStar Connection** — single connection ARN; whichever migration lands first creates it. The marketplace repo gets added to the App's granted-repos list when this one cuts.
- **CFN module for CodeBuild projects** — `ci/codebuild.yaml` parameterised on `(name, buildspec_path, source_repo, env)`. This repo's project becomes one more invocation; the rollback project is a near-duplicate invocation of the same module.
- **IAM service role pattern** — `<workflow-name>-codebuild-service-role` with base `logs:*` + `codestar-connections:UseConnection`. Pattern B (separate deploy-target role) consistent across marketing-website and this repo.
- **Operator GitHub-App grant** — one ceremony covers the marketplace repo when added to the granted list.
- **`make <action>` Makefile target convention** — `make deploy` (marketing-website), `make publish` (this repo), `make rollback` (this repo). Consistent shell idiom across repos.

What is **specific to this repo**:

- **The blue/green canary key mechanic** — fleet-impact, not a marketing-site/agent-CI concern.
- **Strands probe fleet integration for canary URL** — also fleet-impact.
- **S3 bucket versioning + artifact-trail rollback** — earns its keep here because the deploy is a single tiny file with high blast radius. Marketing-website might inherit this pattern as nice-to-have; agent-CI doesn't need it.
- **`marketplace*.json` IAM glob scope** — narrowly anticipates versioned channels and canary keys without granting bucket-wide write.
- **The `--exclude "marketplace*.json"` patch on the marketing-website CodeBuild** — coordination obligation owed *to* marketing-website, not from it.

---

## What's *not* in this design

- The buildspec files themselves (`buildspec.yaml`, `buildspec-rollback.yaml`). Land per-PR alongside the CFN entry.
- The CFN/Terraform for the CodeBuild projects + service role + deploy-target role. Strawman in the canary PR.
- The Makefile targets (`make publish`, `make rollback`). Trivial; land with the buildspec PR.
- A `scripts/validate-catalog.py` (deeper validation than `json.load`). Strawman in the canary PR.
- The cutover runbook in `docs/runbooks/marketplace-cutover.md`. Required before Week 1 cutover — separate PR, after Week 0 confidence is established.
- Catalog channel infra (`stable` / `latest`). Out of migration scope; revisit after cutover.
- Cost dashboard / CloudWatch alarms on marketplace-publish CI minutes. Follow-up.

---

## Files referenced

- `scripts/publish.sh` — current deploy executor (manual). 50 lines; read in full.
- `.claude-plugin/marketplace.json` — source of truth for the catalog. Read in full.
- `README.md` — install paths, channel plans. Read for the fleet-impact framing.
- `c3ef37b` — commit retiring the GitHub Pages workflow; established the "automated via Action targeting 8th-layer-app S3 bucket later" intent that this doc realises.
- Sibling decisions:
  - `OneZero1ai/8th-layer-agent/docs/decisions/13-gha-to-codebuild-migration.md`
  - `OneZero1ai/8th-layer-marketing-website/docs/decisions/01-gha-to-codebuild-migration.md` (PR #1, branch `chore/codebuild-migration-design`)
- AWS docs (same as siblings):
  - <https://docs.aws.amazon.com/dtconsole/latest/userguide/connections-create-github.html>
  - <https://docs.aws.amazon.com/codebuild/latest/userguide/sample-github-pull-request.html>
  - <https://docs.aws.amazon.com/codebuild/latest/userguide/build-spec-ref.html>

Design closed 2026-05-08. Awaiting operator approval before any infra is created.
