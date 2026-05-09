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

---

## Addendum 2026-05-09 — operator decision: separate bucket

The body of this doc recommended bucket co-residency on `8l-web-site-us-east-1-124074140789` with `--exclude "marketplace*.json"` mitigations on the marketing-website CodeBuild project (open question #1). After review, the operator chose **option 3 — physical isolation in a dedicated S3 bucket** instead. Reason: physical isolation is permanent; exclude rules are forgotten. A future contributor patching the marketing-website buildspec for an unrelated reason can drop the exclude line in a refactor and silently nuke the catalog on the next deploy. Removing the bucket from the blast radius removes the failure mode entirely. Most invasive of the three options, cleanest long-term.

Two related decisions were also locked alongside this one and are reflected below:

- **S3 versioning** is now enabled on the original shared bucket `8l-web-site-us-east-1-124074140789` (already done by the parent session). Open question #2 is closed.
- **Strands canary probes will be wired up before the cutover** (option 1 from open question #4 — wire the probe path before Week 0, accept the time cost over lower-confidence manual validation).

The rest of this doc — IAM Pattern B, CodeBuild project shape, validation, rollback artifact-trail mechanic — stands as written. The deltas below replace the bucket/URL/sequence specifics.

### New bucket spec

Following the existing convention `8l-web-site-us-east-1-124074140789` (= `<purpose>-<region>-<account>`):

- **Name**: `8l-marketplace-us-east-1-124074140789`
- **Region**: `us-east-1` (same account, `8th-layer-app` profile, `124074140789`)
- **Versioning**: enabled at creation (CFN `VersioningConfiguration: { Status: Enabled }`). The rollback story still leans on it; cost is trivial for ~1.3KB JSON files.
- **Default encryption**: AES256 (SSE-S3). KMS is over-engineered for a public-read CDN origin where the asset is, by design, world-readable via CloudFront.
- **Public access**: fully blocked (`BlockPublicAcls + IgnorePublicAcls + BlockPublicPolicy + RestrictPublicBuckets` all `true`). Public read goes through CloudFront via **Origin Access Control (OAC)** — bucket policy grants `s3:GetObject` only to the marketplace CloudFront distribution's service principal scoped by `aws:SourceArn`. Same shape AWS recommends for any modern static site origin; OAI is legacy.
- **Lifecycle**: noncurrent-version expiration at 365 days. Plenty for rollback; keeps versioning costs trivially bounded.
- **Object key**: `marketplace.json` at the bucket root (canary key remains `marketplace-canary.json` during Week 0, on the *new* bucket).

Migration of the existing `marketplace.json` content from the shared bucket is a one-time `aws s3 cp` (1.3KB; manual; doc-as-runbook step).

### CloudFront topology

**Recommendation: dedicated CloudFront distribution with its own DNS hostname `marketplace.8th-layer.ai`** (DNS managed in Route 53 in the `8th-layer-app` account; ACM cert in `us-east-1` for CloudFront).

- **Why dedicated, not a new behavior on the apex distro `EEUW0F2ICYKFQ`:**
  - **Cache independence.** The marketplace's `cache-control: public, max-age=300` is intentional (5-minute TTL for fast catalog publishing). The marketing-website may want hour/day TTLs. Coupling them via one distro means cache-policy changes for one require regression-thinking about the other. Independent distros decouple that.
  - **Invalidation independence.** The narrowly-scoped IAM perm `cloudfront:CreateInvalidation` on `marketplace*.json` paths becomes `cloudfront:CreateInvalidation` on the *whole* dedicated distro — simpler ARN scoping, no path-prefix accidents. Marketing-website invalidations can never accidentally affect the catalog.
  - **Branding signal.** The hostname `marketplace.8th-layer.ai` is self-documenting in URL form: when an operator pastes `/plugin marketplace add https://marketplace.8th-layer.ai/marketplace.json` into a session, it's unambiguous. With the apex hostname, `8thlayer.onezero1.ai/marketplace.json` could be mistaken for a transient marketing route.
  - **Failure isolation.** A misconfigured marketing-website behavior (cache key, headers, OAC policy) cannot break catalog fetch. The fleet-impact framing in this doc demands this isolation.
  - **Cost.** Negligible — CloudFront has no per-distro fixed fee; price is per-request and per-GB-egress, and a 1.3KB JSON polled by the fleet is a rounding error against marketing-website traffic.

- **Apex-reuse alternative (rejected for V1).** Add an origin pointing at the new bucket and a path-pattern behavior `/marketplace*.json` on the existing distro. Fewer moving parts, but inherits all the coupling concerns above. Acceptable as a fallback if Route53/ACM provisioning for `marketplace.8th-layer.ai` blocks the Week-0 schedule; revisit at the dedicated-distro design step.

- **Distribution settings (sketch):**
  - Origin: the new S3 bucket via OAC (not website-endpoint mode).
  - Default behavior: `GET, HEAD` only; viewer protocol policy = redirect HTTP → HTTPS; compression on.
  - Cache policy: AWS-managed `CachingOptimized` overridden by origin `Cache-Control: public, max-age=300` for `marketplace.json`; `marketplace-canary.json` gets `max-age=60` (faster canary-feedback loop during Week 0).
  - Response-headers policy: `Strict-Transport-Security`, `X-Content-Type-Options: nosniff`, `Content-Security-Policy: default-src 'none'` (the asset is inert JSON, no embedding context).
  - Logging: standard CloudFront access logs to a sibling S3 bucket (or reuse the marketing-website's logs bucket if one exists; out of scope to decide here).

### URL migration

Current canonical URL (in `README.md` and likely cached in fleet sessions): `https://8thlayer.onezero1.ai/marketplace.json`. New canonical URL post-cutover: `https://marketplace.8th-layer.ai/marketplace.json`.

The plugin install URL is referenced in this repo's `README.md` (the operator-facing onboarding command). It is also cached in the runtime state of every Claude Code session that previously ran `/plugin marketplace add https://8thlayer.onezero1.ai/marketplace.json` — Claude Code persists added marketplace URLs in user-local config until the user explicitly re-runs `/plugin marketplace remove` and re-adds the new one. We cannot force every fleet developer to re-add; some sessions will keep hitting the old URL for months.

**Migration plan:**

1. **Day 0 (Week 1 cutover)**: new URL (`marketplace.8th-layer.ai/marketplace.json`) becomes the documented install URL. README and `8l-cq` plugin manifest references updated in the same PR that flips CodeBuild's `TARGET_KEY` to `marketplace.json` on the new bucket.
2. **Day 0 → Day 90**: the old URL `8thlayer.onezero1.ai/marketplace.json` serves a **301 Moved Permanently** redirect to the new URL. Implementation: a CloudFront Function (or small Lambda@Edge) on the *existing* apex distro `EEUW0F2ICYKFQ` matching path `/marketplace.json` exactly, returning `301` with `Location: https://marketplace.8th-layer.ai/marketplace.json`. This keeps cached fleet sessions working transparently.
3. **Day 90+**: the old URL returns **410 Gone** with a small JSON body explaining the permanent move and instructing the user to run `/plugin marketplace remove 8th-layer && /plugin marketplace add https://marketplace.8th-layer.ai/marketplace.json`. The 90-day window is calibrated to "every reasonable user has either upgraded sessions or restarted Claude Code at least once" — long enough that a 410 is an unambiguous "your config is stale," short enough that the redirect mechanism doesn't ossify into permanent infrastructure.
4. **Why 301 not 302**: Claude Code's `/plugin marketplace add` and the underlying HTTP fetch should treat the redirect as definitive and update internal state where it can. 302 invites repeated round-trips per session; 301 lets caches collapse the indirection. (If Claude Code's HTTP client doesn't follow 301 by default, the 410 phase becomes the forcing function — but that's a 90-day-out concern, not a Day-0 blocker.)
5. **Why not just delete the old object on Day 0**: 404 to the fleet on a path the fleet expects = `/plugin install 8l-cq` breaks immediately for every cached session. The 90-day 301 buys grace; the 410 forces cleanup deliberately, with a message.

Open question added below: where exactly does the 8l-cq plugin manifest reference the install URL (if at all)? Need to grep `OneZero1ai/8th-layer-agent/plugins/cq/` for hardcoded URLs and update them as part of the URL-migration PR.

### Strands probes — what they verify

The Strands probe fleet (8l-cq's existing infra) is the canary-confidence mechanism. The probes need to verify, against the canary URL `https://marketplace.8th-layer.ai/marketplace-canary.json` during Week 0 (and the production URL post-cutover):

1. **HTTP 200 + valid JSON.** Cheapest probe: `GET <canary-url>`, assert `200`, assert response body parses as JSON. Runs every minute. Catches: bucket-policy/OAC misconfiguration, CloudFront origin failure, truncated upload, malformed JSON from a bad CodeBuild build.
2. **Schema validation.** Parsed JSON has `name`, `owner`, `metadata`, `plugins` (non-empty list); every plugin entry has `name`, `source`, `version`. The probe carries a small JSON-schema or hand-rolled assertion (the catalog schema is small enough not to need a full schema lib). Runs every 5 minutes (rate-limited; the plugin entries don't change every minute). Catches: a CodeBuild build that wrote *some* JSON but lost catalog structure (e.g. uploaded a stub, uploaded the wrong file, wrote a malformed array).
3. **Plugin-source resolution.** For each plugin entry, perform an HTTP HEAD against `source.url` and a `git ls-remote` against `source.url` for `source.ref` (verifies the ref exists). Runs every 15 minutes. Catches: a `git-subdir` ref pointing at a deleted branch, a 404 on the source repo (private-by-mistake, deleted, etc.).
4. **End-to-end install probe.** A sandboxed Claude Code session in the Strands fleet runs `/plugin marketplace add https://marketplace.8th-layer.ai/marketplace-canary.json` followed by `/plugin install 8l-cq`. Asserts the install completes without error and the plugin's tools are registered. Runs every hour (expensive — a real Claude Code session). Catches: anything the previous three miss — most importantly, regressions in Claude Code's own marketplace fetcher behavior against our content (CSP blocks, header parsing, edge-case JSON shapes that pass validation but break the client).

The first three are HTTP-level checks runnable from any Strands probe agent; (4) requires a Claude Code execution sandbox in the probe fleet — confirm with the operator/Dirk that this exists before relying on it. If it doesn't, manual operator+Dirk validation from two laptops is the Week-0 substitute, with (4) wired as a follow-up before Week 1 cutover.

The probes write their results into the `8l-cq` knowledge graph as a `marketplace-canary` domain — passing checks confirm the canary KU; failing checks flag it. This earns its keep: the probe history becomes the audit trail demonstrating "5 consecutive matches" for the byte-equivalence threshold without manual ETag-tracking by the operator.

### Migration sequence (revised for separate bucket)

- **Week 0 — set-up**:
  - Create new bucket `8l-marketplace-us-east-1-124074140789` (versioning, OAC, AES256, public access blocked).
  - Create new CloudFront distribution + ACM cert + Route53 record for `marketplace.8th-layer.ai`.
  - Create marketplace CodeBuild project + Pattern B IAM roles, scoped to the *new* bucket and *new* distribution.
  - Wire Strands canary probes against `https://marketplace.8th-layer.ai/marketplace-canary.json` (probes run from Day 0 of Week 0).
  - One-time copy the current catalog from old bucket → new bucket as `marketplace.json` (the canonical key in the new bucket).
- **Week 0 → Week 1 — dual-publish**:
  - CodeBuild publishes to `marketplace-canary.json` on the new bucket. Production fleet still reads `marketplace.json` on the *old* bucket via the old URL.
  - Manual `bash scripts/publish.sh` continues writing the old bucket's `marketplace.json` (the path the fleet currently uses) for every catalog edit.
  - Probes run; we collect 5 consecutive byte-identical matches between manual-script output (old bucket) and CodeBuild output (new bucket canary key) across real catalog edits.
- **Week 1 — cutover**:
  - When probes are green and the byte-equivalence threshold is met: flip CodeBuild's `TARGET_KEY` from `marketplace-canary.json` to `marketplace.json` (writes go to the new bucket's canonical key).
  - Update `README.md` and the 8l-cq plugin manifest to reference the new URL `https://marketplace.8th-layer.ai/marketplace.json`.
  - Add the **301 redirect** on the old URL (`8thlayer.onezero1.ai/marketplace.json` → new URL) via CloudFront Function on the apex distro.
  - Existing manual `scripts/publish.sh` is shelved for break-glass only (kept in repo, no longer routine).
- **Week 2 — retire manual path**:
  - Confirm probes have stayed green for one full week post-cutover under the new bucket as the canonical source.
  - Retire `bash scripts/publish.sh` from the routine (still in repo for catastrophic rollback; documented as break-glass in the cutover runbook).
  - Old URL continues serving 301 redirects.
- **Day 90 — final transition**:
  - Old URL flips from 301 to **410 Gone** with the explanatory body.
  - Old bucket's `marketplace.json` object can be deleted (S3 versioning still preserves history if needed).
  - The CloudFront Function on the apex distro for `/marketplace.json` updates to return 410 instead of 301.

### Estimate (revised)

The bucket-move adds work the original estimate didn't account for: a new bucket + new distribution + new DNS + new ACM cert + URL migration with 301/410 logic + a CloudFront Function on the *apex* distro (which means coordinating with the marketing-website CloudFront's IaC). Strands probe wiring is also locked-in (was an "if/else" in the original).

Touch-points added: new bucket CFN + new distribution CFN + ACM cert (us-east-1, automated DNS validation in Route53) + Route53 record + CloudFront Function source + CloudFront Function deploy on apex distro (cross-stack reference) + URL update PR on `8th-layer-agent` plugin manifest. **~7 additional touch-points, bringing total ~19.**

- **Naive** (CFN module reusable, no DNS/cert surprises, plugin-manifest URL change clean): **4 dev-days** ≈ 1 calendar week with operator approval gates.
- **Realistic** (×2 — ACM cert validation hits a Route53 NS-delegation snag, the CloudFront Function deploy on the apex distro requires coordination with the marketing-website's IaC owner, the plugin-manifest URL update needs a versioned 8l-cq release): **8 dev-days** ≈ 2 calendar weeks.
- **Unknowns hit** (×3 — Claude Code's HTTP client behaves unexpectedly with 301 on `/plugin marketplace add` and forces an early move to 410 + user-facing comms; Strands probe-fleet end-to-end install probe (#4) doesn't yet exist and we have to build it; the new dedicated CloudFront distribution surfaces an OAC-vs-OAI quirk that requires a config redesign): **12 dev-days** ≈ 2.5–3 calendar weeks.

**Net: budget 8 dev-days, expect 12.** Up from the original 6/9 by the bucket-move overhead. Don't promise <3 weeks externally on the cutover-to-410 timeline (the calendar is dominated by the 90-day redirect window, not the build work — but the build work itself is now ~2 weeks of focused effort).

### New open questions (from this direction change)

The original open questions #1, #2, and #4 are closed by the operator decisions captured above. New questions surfaced by the separate-bucket direction:

1. **8l-cq plugin manifest URL location.** Where exactly does the plugin advertise the marketplace install URL — in `OneZero1ai/8th-layer-agent/plugins/cq/` somewhere, in the README, in a config? Need to identify and PR the URL update at Week 1 cutover. (Action: grep the agent repo for `8thlayer.onezero1.ai`.)
2. **CloudFront Function on the apex distro — IaC ownership.** The 301-then-410 logic lives on `EEUW0F2ICYKFQ`, which is the marketing-website's distro. Whose IaC owns it after the marketing-website CodeBuild migration lands — this repo or `8th-layer-marketing-website`? Recommendation: define the function in `8th-layer-marketing-website`'s CFN (it owns the distro) but *source* it from this repo's `infra/cf-functions/marketplace-redirect.js` so the redirect logic is co-located with the catalog it serves. Confirm.
3. **Claude Code 301-following behavior.** Does Claude Code's `/plugin marketplace add` / catalog-fetch HTTP client follow 301 transparently, *and* update its internal cached marketplace URL on a 301? If it follows but doesn't update, every session keeps hitting the redirect indefinitely until the 410 phase forces cleanup. Worth a quick test in a sandbox session before Day 0. (Action: test against any 301-redirected URL Claude Code is known to consume; document the observed behavior in the cutover runbook.)
4. **`marketplace.8th-layer.ai` vs `marketplace.onezero1.ai` for the new hostname.** The brand is 8th-Layer.ai but the apex domain in production is `onezero1.ai` (and the existing URL is `8thlayer.onezero1.ai`). Recommendation: use `marketplace.8th-layer.ai` to match brand and signal the post-rebrand future; defer the `8th-layer.ai` apex setup as a sibling task. Confirm — alternative is `marketplace.onezero1.ai`, consistent with the existing apex but off-brand.
5. **Old bucket `marketplace.json` retention.** After Day 90, when the old URL returns 410, do we delete the old bucket's `marketplace.json` object entirely, or leave it (versioning preserves it anyway)? Recommendation: delete it. The 410 layer is on CloudFront/the apex distro's function, not the bucket; deleting the object removes a stale source-of-truth from the marketing-website's bucket and prevents confusion if someone later inspects the bucket directly.

