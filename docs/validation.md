# Validation Contract

This repository validates the composite action with shell syntax checks, action metadata parsing, lifecycle-resolution scenarios, and config-merge smoke tests.

## Local Checks

Run these before opening or updating a PR:

```bash
make test
rabbit.ci
```

## CI

The `ci` workflow runs on pull requests and pushes to `production` and `lifecycle-action-integration`. It installs a pinned `yq` binary and runs `make test`.
