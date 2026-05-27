# Validation Contract

This repository validates the composite action with shell syntax checks, action metadata parsing, and merge smoke tests.

## Local Checks

Run these before opening or updating a PR:

```bash
make test
dev.kit repo
```

## CI

The `ci` workflow runs on pull requests and pushes to `production` and `lifecycle-action-integration`. It installs a pinned `yq` binary, runs `make test`, and refreshes repo context with `@udx/dev-kit@0.12.0`.
