# Review Guidelines - github-rabbit-action

Public GitHub Marketplace composite action (`udx/github-rabbit-action`) that resolves environment/lifecycle, runs safety checks, then `docker run`s the R2A image (`usabilitydynamics/rabbit-automation-action`). `action.yml` is effectively the entire product; treat every change to it as production-facing for all consumers, who float on the `@v5` major tag.

## Critical Areas (extra scrutiny)

- Safety checks in `action.yml` (manual-apply-to-production block and destroy-on-production block): any change that weakens, reorders, or adds bypasses to these checks is a production-destruction risk. Require explicit justification and a test/demo evidence link.
- Lifecycle resolution: `bin/merge-configs.sh`, `bin/lib/*.sh`, `src/configs/lifecycle-policy.yaml`. Production lifecycle must remain gated on protected branches; reject changes that let unprotected branches resolve to production.
- State backend inputs (`state_backend`, `state_backend_config`, `state_prefix_key`, `multi_repo`): wrong defaults or renames silently repoint or collide OpenTofu state across tenants. Renaming or changing the default of ANY input is a breaking change for marketplace consumers.
- Credential handling: AWS creds forwarded from env; GCP creds are copied into the workspace as `gcp-credentials.json`. Watch for changes that widen the credential surface (new copies, echoing env, credentials reaching uploaded artifacts or logs).
- Image resolution: `r2a_version` defaults to `latest`. Flag any change that makes pinning harder; prefer changes that move toward pinned digests.

## Marketplace Contract

- Input/output names, defaults, and `branding:` in `action.yml` are public API. Breaking changes require a new major tag and README migration notes in the same PR.
- README is the consumer contract: behavior changes must update README usage examples in the same PR.
- Consumers reference `@v5` (floating major). Any merged change lands on consumers immediately once the tag moves; review as if deploying to production.

## Conventions to Enforce

- Every `run:` step uses `shell: bash` with `set -euo pipefail`.
- Pass GitHub expressions to steps via `env:` rather than inlining `${{ }}` inside script bodies (script injection risk on inputs and branch names).
- Composite steps keep the numbered banner-comment structure; new steps get a number and description.
- No workflows exist in this repo; there is no CI safety net. Review IS the test gate here, so be more thorough than usual: trace input flow end to end for every changed input.

## Security

- This is a public repo and a supply-chain node for every tenant. Scrutinize any new external download, curl-pipe-to-shell, or unpinned tool install.
- No secrets, tokens, project IDs, or tenant names in examples or defaults.
