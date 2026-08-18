# Releasing Rabbit Automation Action

The action is released from `production`. Patch releases are immutable
`v1.x.y` tags; `v1` is the movable compatibility tag that callers use.

## Before publishing

1. Merge a focused, reviewed pull request into `production`.
2. Confirm the CI action-contract and workflow-lint jobs pass.
3. Test the exact `production` commit from a caller's non-production
   environment. Use `@production` only for that canary.
4. Add a concise, user-facing entry to `CHANGELOG.md` when the behavior
   changes.

## Publish the release

1. Create a semantic GitHub release from the tested `production` commit, for
   example `v1.0.3`.
2. In the release form, select **Publish this Action to the GitHub
   Marketplace**. GitHub requires this UI step and may require 2FA; a release
   created only through the REST or CLI release API is not enough.
3. Keep `Deployment` as the primary Marketplace category and `Security` as the
   secondary category unless the action's public purpose changes.
4. Verify the Marketplace listing shows the new version, current `action.yml`
   metadata, and current README before changing any caller references.

Publishing triggers `Verify release`, which checks the semantic tag and runs
the action contract from that tag. It confirms the published artifact; it does
not replace the pre-release caller canary or the Marketplace UI verification.

## Promote callers

1. Move the `v1` tag to the tested immutable release commit.
2. Confirm `v1` and the patch tag resolve to the same commit with
   `git ls-remote --tags origin 'v1*'`.
3. Update reusable workflows and callers from `@production` to `@v1`.
4. Run a non-production caller plan using `@v1` before merging the consumer
   change.

Use a new major tag for breaking input, output, safety, or lifecycle-contract
changes. Keep `v1` on the latest compatible patch release; do not rewrite a
patch release tag.
